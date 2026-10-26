//! Writes a `file://` binary cache (what `nix copy --to file://...` produces)
//! from closureInfo registrations and derivation files, without access to the
//! Nix database, so it can run inside the build sandbox.

use crate::wire::hex;
use crate::{base32, drv, nar::NarWriter};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt::Write as _;
use std::fs::{self, File};
use std::io::{self, BufWriter, Write};
use std::path::{Path, PathBuf};

const STORE_DIR: &str = "/nix/store/";
const HASH_LEN: usize = 32;

struct PathInfo {
    references: BTreeSet<String>,
    deriver: String,
    /// "sha256:<nix32 or hex>" from a registration, checked during export.
    nar_hash: Option<String>,
}

pub struct Closure {
    paths: BTreeMap<String, PathInfo>,
}

pub struct Stats {
    pub paths: usize,
    pub nar_size: u64,
}

/// The hash part of a top-level store path, or `None` if `p` is not one.
fn hash_part(p: &str) -> Option<&str> {
    let name = p.strip_prefix(STORE_DIR)?;
    let hash = name.get(..HASH_LEN)?;
    let rest = name.get(HASH_LEN..)?;
    (rest.starts_with('-')
        && rest.len() > 1
        && !rest.contains('/')
        && hash.bytes().all(base32::is_char))
    .then_some(hash)
}

fn check_store_path(p: &str) -> Result<(), String> {
    hash_part(p)
        .map(drop)
        .ok_or_else(|| format!("'{p}' is not a top-level store path"))
}

fn is_drv(p: &str) -> bool {
    Path::new(p)
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("drv"))
}

/// Parses the `registration` file written by nixpkgs' closureInfo
/// (the `nix-store --load-db` format).
fn parse_registration(text: &str, into: &mut BTreeMap<String, PathInfo>) -> Result<(), String> {
    let mut lines = text.lines();
    while let Some(path) = lines.next() {
        if path.is_empty() {
            continue;
        }
        let mut field = |what: &str| {
            lines
                .next()
                .ok_or_else(|| format!("truncated registration at {path} ({what})"))
        };
        let nar_hash = field("narHash")?.to_owned();
        let _nar_size = field("narSize")?;
        let deriver = field("deriver")?.to_owned();
        let n: usize = field("reference count")?
            .parse()
            .map_err(|_| format!("bad reference count for {path}"))?;
        let references = (0..n)
            .map(|_| field("reference").map(str::to_owned))
            .collect::<Result<_, _>>()?;
        check_store_path(path)?;
        into.insert(
            path.to_owned(),
            PathInfo {
                references,
                deriver,
                nar_hash: (!nar_hash.is_empty()).then_some(nar_hash),
            },
        );
    }
    Ok(())
}

/// Finds which of `candidates` (keyed by hash part) appear in `data`, the way
/// Nix scans build outputs for references.
fn scan_references(data: &[u8], candidates: &HashMap<&str, &str>) -> BTreeSet<String> {
    let mut found = BTreeSet::new();
    let mut i = 0;
    'outer: while let Some(window) = data.get(i..i + HASH_LEN) {
        // Check from the end so a bad byte lets us skip past it entirely.
        for (j, &c) in window.iter().enumerate().rev() {
            if !base32::is_char(c) {
                i += j + 1;
                continue 'outer;
            }
        }
        if let Some(p) = std::str::from_utf8(window)
            .ok()
            .and_then(|h| candidates.get(h))
        {
            found.insert((*p).to_owned());
        }
        i += 1;
    }
    found
}

fn nar_bytes(path: &Path) -> io::Result<Vec<u8>> {
    let mut out = Vec::new();
    NarWriter::new(&mut out).dump(path)?;
    Ok(out)
}

/// Adds the path to an I/O error, for `map_err`.
fn err(path: &Path) -> impl Fn(io::Error) -> String + '_ {
    move |e| format!("{}: {e}", path.display())
}

fn base_name(p: &str) -> &str {
    p.strip_prefix(STORE_DIR).unwrap_or(p)
}

/// One path's `.narinfo`, with the fields Nix writes for an uncompressed cache.
fn narinfo(path: &str, info: &PathInfo, nar_hash: &str, nar_size: u64, ca: Option<&str>) -> String {
    let refs: Vec<&str> = info.references.iter().map(|r| base_name(r)).collect();
    let mut s = format!(
        "StorePath: {path}\nURL: nar/{nar_hash}.nar\nCompression: none\n\
         FileHash: sha256:{nar_hash}\nFileSize: {nar_size}\n\
         NarHash: sha256:{nar_hash}\nNarSize: {nar_size}\nReferences: {}\n",
        refs.join(" ")
    );
    if !info.deriver.is_empty() {
        let _ = writeln!(s, "Deriver: {}", base_name(&info.deriver));
    }
    if let Some(ca) = ca {
        let _ = writeln!(s, "CA: {ca}");
    }
    s
}

/// Fails if `sha` doesn't match the hash a registration recorded for `p`.
fn check_nar_hash(p: &str, info: &PathInfo, sha: &[u8]) -> Result<(), String> {
    let Some(expected) = &info.nar_hash else {
        return Ok(());
    };
    let ok = match expected.strip_prefix("sha256:") {
        Some(h) if h.len() == 64 => h == hex(sha),
        Some(h) => h == base32::encode(sha),
        None => return Err(format!("{p}: unsupported narHash '{expected}'")),
    };
    if ok {
        Ok(())
    } else {
        Err(format!(
            "{p}: NAR hash mismatch (registration says {expected})"
        ))
    }
}

impl Closure {
    pub fn collect(registrations: &[PathBuf], drvs: &[PathBuf]) -> Result<Self, String> {
        let mut paths = BTreeMap::new();
        for r in registrations {
            let text =
                fs::read_to_string(r).map_err(|e| format!("reading {}: {e}", r.display()))?;
            parse_registration(&text, &mut paths)?;
        }

        // Walk derivation files. Their references are their inputs; sources that
        // no registration covers get their references by scanning, below.
        let mut queue: Vec<String> = drvs
            .iter()
            .map(|d| d.to_string_lossy().into_owned())
            .collect();
        let mut unregistered = Vec::new();
        while let Some(p) = queue.pop() {
            if paths.contains_key(&p) {
                continue;
            }
            check_store_path(&p)?;
            let references = if is_drv(&p) {
                let contents = fs::read(&p).map_err(|e| format!("reading {p}: {e}"))?;
                let refs = drv::references(&contents).map_err(|e| format!("parsing {p}: {e}"))?;
                queue.extend(refs.iter().cloned());
                refs.into_iter().collect()
            } else {
                unregistered.push(p.clone());
                BTreeSet::new()
            };
            paths.insert(
                p,
                PathInfo {
                    references,
                    deriver: String::new(),
                    nar_hash: None,
                },
            );
        }

        let candidates: HashMap<&str, &str> = paths
            .keys()
            .filter_map(|p| Some((hash_part(p)?, p.as_str())))
            .collect();
        let scanned = unregistered
            .into_iter()
            .map(|p| {
                let data = nar_bytes(Path::new(&p)).map_err(|e| format!("reading {p}: {e}"))?;
                let refs = scan_references(&data, &candidates);
                Ok((p, refs))
            })
            .collect::<Result<Vec<_>, String>>()?;
        for (p, refs) in scanned {
            if let Some(info) = paths.get_mut(&p) {
                info.references = refs;
            }
        }

        let closure = Self { paths };
        closure.check_complete()?;
        Ok(closure)
    }

    fn check_complete(&self) -> Result<(), String> {
        for (p, info) in &self.paths {
            if let Some(missing) = info
                .references
                .iter()
                .find(|r| !self.paths.contains_key(*r))
            {
                return Err(format!(
                    "{p} references {missing}, which is not in the closure"
                ));
            }
        }
        Ok(())
    }

    /// Writes the closure as an uncompressed binary cache in `dir`, the layout
    /// `nix copy --to file://DIR?compression=none` produces, plus a
    /// `store-paths` file listing every path in it.
    pub fn write_cache(&self, dir: &Path) -> Result<Stats, String> {
        let nar_dir = dir.join("nar");
        fs::create_dir_all(&nar_dir).map_err(err(&nar_dir))?;
        let cache_info = dir.join("nix-cache-info");
        fs::write(
            &cache_info,
            format!("StoreDir: {}\n", STORE_DIR.trim_end_matches('/')),
        )
        .map_err(err(&cache_info))?;

        let partial = nar_dir.join(".partial");
        let mut stats = Stats {
            paths: 0,
            nar_size: 0,
        };
        for (p, info) in &self.paths {
            let hash = hash_part(p).ok_or_else(|| format!("'{p}' is not a store path"))?;
            let mut f = BufWriter::new(File::create(&partial).map_err(err(&partial))?);
            let mut nar = NarWriter::new(&mut f);
            nar.dump(Path::new(p))
                .map_err(|e| format!("dumping {p}: {e}"))?;
            let (sha, size) = nar.finish();
            f.flush().map_err(err(&partial))?;
            drop(f);
            check_nar_hash(p, info, &sha)?;

            let nar_hash = base32::encode(&sha);
            let nar_file = nar_dir.join(format!("{nar_hash}.nar"));
            fs::rename(&partial, &nar_file).map_err(err(&nar_file))?;

            // Derivations are content-addressed text; Nix records that as CA.
            let ca = if is_drv(p) {
                let contents = fs::read(p).map_err(|e| format!("reading {p}: {e}"))?;
                Some(format!(
                    "text:sha256:{}",
                    base32::encode(&Sha256::digest(contents))
                ))
            } else {
                None
            };
            let info_file = dir.join(format!("{hash}.narinfo"));
            fs::write(&info_file, narinfo(p, info, &nar_hash, size, ca.as_deref()))
                .map_err(err(&info_file))?;

            stats.paths += 1;
            stats.nar_size += size;
        }

        // `nix copy --from file://... --all` only learns hashes from a cache, so
        // Lix can't order the paths and fails; the installer copies these instead.
        let list = dir.join("store-paths");
        let names = self.paths.keys().fold(String::new(), |mut s, p| {
            s.push_str(p);
            s.push('\n');
            s
        });
        fs::write(&list, names).map_err(err(&list))?;
        Ok(stats)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: &str = "/nix/store/0mdqa9w1p6cmli6976v4wi0sw9r4p5pr-a";

    #[test]
    fn scans_like_nix() {
        let candidates = HashMap::from([(hash_part(A).unwrap(), A)]);
        let data = b"xx /nix/store/0mdqa9w1p6cmli6976v4wi0sw9r4p5pr-a/bin yy";
        assert_eq!(
            scan_references(data, &candidates),
            BTreeSet::from([A.to_owned()])
        );
        assert!(scan_references(b"0mdqa9w1p6cmli6976v4wi0sw9r4p5p", &candidates).is_empty());
    }

    #[test]
    fn validates_store_paths() {
        assert!(check_store_path(A).is_ok());
        assert!(check_store_path("/nix/store/0mdqa9w1p6cmli6976v4wi0sw9r4p5pr").is_err());
        assert!(check_store_path("/nix/store/0mdqa9w1p6cmli6976v4wi0sw9r4p5pr-a/bin").is_err());
        assert!(check_store_path("/tmp/0mdqa9w1p6cmli6976v4wi0sw9r4p5pr-a").is_err());
        assert!(check_store_path("/nix/store/émdqa9w1p6cmli6976v4wi0sw9r4p5pr-a").is_err());
    }

    /// Matches what `nix copy --to file://...?compression=none` wrote for hello
    /// (minus the signature, which we never add).
    #[test]
    fn narinfo_matches_nix() {
        let hello = "/nix/store/2y3s86m1yj9xnypd44vivfz3mwybzlki-hello-2.12.3";
        let info = PathInfo {
            references: BTreeSet::from([
                hello.to_owned(),
                "/nix/store/fsd4vbp9zjd9iaicq2fb9lpc1h5j973y-glibc-2.42-100".to_owned(),
            ]),
            deriver: "/nix/store/v4c5h94di88ccdd9isyzhivdw84k81nh-hello-2.12.3.drv".to_owned(),
            nar_hash: None,
        };
        let h = "08avk9jy3jyvqnkfqcpc7azmv30im8bf6maxz5vbqr44dkfdbr1s";
        assert_eq!(
            narinfo(hello, &info, h, 279_624, None),
            format!(
                "StorePath: {hello}\n\
                 URL: nar/{h}.nar\n\
                 Compression: none\n\
                 FileHash: sha256:{h}\n\
                 FileSize: 279624\n\
                 NarHash: sha256:{h}\n\
                 NarSize: 279624\n\
                 References: 2y3s86m1yj9xnypd44vivfz3mwybzlki-hello-2.12.3 \
                 fsd4vbp9zjd9iaicq2fb9lpc1h5j973y-glibc-2.42-100\n\
                 Deriver: v4c5h94di88ccdd9isyzhivdw84k81nh-hello-2.12.3.drv\n"
            )
        );
    }

    #[test]
    fn parses_registration() {
        let reg = format!("{A}\nsha256:abc\n12\n\n1\n{A}\n");
        let mut m = BTreeMap::new();
        parse_registration(&reg, &mut m).unwrap();
        let info = &m[A];
        assert_eq!(info.references.len(), 1);
        assert_eq!(info.nar_hash.as_deref(), Some("sha256:abc"));
    }
}
