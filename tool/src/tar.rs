//! A minimal ustar writer whose first header doubles as a shell command.
//!
//! The first 512-byte header is a pax *global* header (typeflag 'g'). Every tar
//! implementation ignores the name field of a global header, so it can hold an
//! arbitrary line of shell. A shell reading the archive executes that line,
//! which must end in `exit` so the binary data after it is never parsed. Bash
//! only refuses a script whose first line contains a NUL, and the newline at
//! the end of the entry line comes before any.

use crate::wire::{len64, padding, zeros};
use std::fs::{self, File};
use std::io::{self, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

const BLOCK: u64 = 512;
const BLOCK_BYTES: usize = 512;

#[derive(Clone, Debug)]
pub struct Member {
    pub name: String,
    pub path: PathBuf,
}

/// Writes `n` as zero-padded octal followed by a NUL.
fn octal(field: &mut [u8], n: u64) -> Result<(), String> {
    let (nul, digits) = field.split_last_mut().ok_or("empty tar field")?;
    let s = format!("{n:0width$o}", width = digits.len());
    if s.len() != digits.len() {
        return Err(format!(
            "value {n} does not fit in a {}-digit tar field",
            digits.len()
        ));
    }
    digits.copy_from_slice(s.as_bytes());
    *nul = 0;
    Ok(())
}

/// Size field, falling back to GNU base-256 for members of 8 GiB and up.
fn size_field(field: &mut [u8; 12], n: u64) {
    if octal(field, n).is_err() {
        let [flag, _, _, _, tail @ ..] = field;
        *flag = 0x80;
        *tail = n.to_be_bytes();
    }
}

fn header(name: &[u8], mode: u32, size: u64, typeflag: u8) -> Result<[u8; BLOCK_BYTES], String> {
    if name.len() > 100 {
        return Err(format!(
            "tar member name is over 100 bytes: {}",
            String::from_utf8_lossy(name)
        ));
    }
    let mut h = [0u8; BLOCK_BYTES];
    h.get_mut(..name.len())
        .ok_or("tar member name too long")?
        .copy_from_slice(name);
    octal(&mut h[100..108], u64::from(mode))?;
    octal(&mut h[108..116], 0)?; // uid
    octal(&mut h[116..124], 0)?; // gid
    let size_bytes: &mut [u8; 12] = (&mut h[124..136])
        .try_into()
        .map_err(|_| "bad size field")?;
    size_field(size_bytes, size);
    octal(&mut h[136..148], 1)?; // mtime: fixed for reproducible bundles
    h[156] = typeflag;
    h[257..263].copy_from_slice(b"ustar\0");
    h[263..265].copy_from_slice(b"00");
    h[265..269].copy_from_slice(b"root");
    h[297..301].copy_from_slice(b"root");
    h[148..156].fill(b' ');
    let sum: u32 = h.iter().copied().map(u32::from).sum();
    octal(&mut h[148..155], u64::from(sum))?;
    h[155] = b' ';
    Ok(h)
}

fn pad(w: &mut impl Write, len: u64) -> io::Result<()> {
    zeros(w, padding(len, BLOCK))
}

/// A pax record is "<len> <key>=<value>\n", where <len> counts itself.
fn pax_record(key: &str, value: &str) -> String {
    let body = format!(" {key}={value}\n");
    let mut len = body.len() + 1;
    while len.to_string().len() + body.len() != len {
        len += 1;
    }
    format!("{len}{body}")
}

pub fn write_polyglot(w: &mut impl Write, entry: &str, members: &[Member]) -> Result<(), String> {
    if entry.contains('/') || entry.contains('\0') {
        return Err("entry line may not contain '/' or NUL".into());
    }
    let line = format!("{entry}\n");
    let io_err = |e: io::Error| format!("writing tar: {e}");

    let pax = pax_record(
        "comment",
        "nix-airgap bundle; run with: sh <this file> --help",
    );
    w.write_all(&header(line.as_bytes(), 0o644, len64(pax.len()), b'g')?)
        .map_err(io_err)?;
    w.write_all(pax.as_bytes()).map_err(io_err)?;
    pad(w, len64(pax.len())).map_err(io_err)?;

    for m in members {
        let md = fs::metadata(&m.path).map_err(|e| format!("{}: {e}", m.path.display()))?;
        if !md.is_file() {
            return Err(format!(
                "{}: tar members must be regular files",
                m.path.display()
            ));
        }
        let mode = if md.permissions().mode() & 0o100 != 0 {
            0o755
        } else {
            0o644
        };
        w.write_all(&header(m.name.as_bytes(), mode, md.len(), b'0')?)
            .map_err(io_err)?;
        let mut f = File::open(&m.path).map_err(|e| format!("{}: {e}", m.path.display()))?;
        let copied = io::copy(&mut f, w).map_err(io_err)?;
        if copied != md.len() {
            return Err(format!(
                "{}: file changed size while reading",
                m.path.display()
            ));
        }
        pad(w, copied).map_err(io_err)?;
    }
    zeros(w, 2 * BLOCK).map_err(io_err)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pax_record_length_counts_itself() {
        let r = pax_record("comment", "x");
        assert_eq!(r, "13 comment=x\n");
        assert_eq!(r.len(), 13);
    }

    #[test]
    fn first_line_has_no_nul() {
        let mut out = Vec::new();
        let dir = std::env::temp_dir().join(format!("tar-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("f"), "data").unwrap();
        let members = [Member {
            name: "f".into(),
            path: dir.join("f"),
        }];
        write_polyglot(&mut out, ":;echo hi;exit", &members).unwrap();
        let nl = out.iter().position(|&b| b == b'\n').unwrap();
        assert!(!out[..nl].contains(&0));
        assert_eq!(out.len() % BLOCK_BYTES, 0);
        fs::remove_dir_all(&dir).unwrap();
    }
}
