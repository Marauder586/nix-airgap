//! NAR serialization, byte-compatible with `nix-store --dump`.

use crate::wire::{len64, padding};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

/// Writes Nix wire-format primitives, hashing and counting everything written.
pub struct NarWriter<'a, W: Write> {
    inner: &'a mut W,
    hasher: Sha256,
    size: u64,
}

impl<'a, W: Write> NarWriter<'a, W> {
    pub fn new(inner: &'a mut W) -> Self {
        Self {
            inner,
            hasher: Sha256::new(),
            size: 0,
        }
    }

    /// Returns (sha256, size) of everything written.
    pub fn finish(self) -> ([u8; 32], u64) {
        (self.hasher.finalize().into(), self.size)
    }

    fn raw(&mut self, b: &[u8]) -> io::Result<()> {
        self.inner.write_all(b)?;
        self.hasher.update(b);
        self.size += len64(b.len());
        Ok(())
    }

    fn pad(&mut self, len: u64) -> io::Result<()> {
        for _ in 0..padding(len, 8) {
            self.raw(&[0])?;
        }
        Ok(())
    }

    fn u64(&mut self, n: u64) -> io::Result<()> {
        self.raw(&n.to_le_bytes())
    }

    fn str(&mut self, s: &[u8]) -> io::Result<()> {
        self.u64(len64(s.len()))?;
        self.raw(s)?;
        self.pad(len64(s.len()))
    }

    pub fn dump(&mut self, path: &Path) -> io::Result<()> {
        self.str(b"nix-archive-1")?;
        self.node(path)
    }

    fn node(&mut self, path: &Path) -> io::Result<()> {
        let ctx = |e: io::Error| io::Error::new(e.kind(), format!("{}: {e}", path.display()));
        let md = fs::symlink_metadata(path).map_err(ctx)?;
        self.str(b"(")?;
        self.str(b"type")?;
        let ft = md.file_type();
        if ft.is_symlink() {
            self.str(b"symlink")?;
            self.str(b"target")?;
            self.str(fs::read_link(path).map_err(ctx)?.as_os_str().as_bytes())?;
        } else if ft.is_file() {
            self.str(b"regular")?;
            if md.permissions().mode() & 0o100 != 0 {
                self.str(b"executable")?;
                self.str(b"")?;
            }
            self.str(b"contents")?;
            let len = md.len();
            self.u64(len)?;
            let copied = self.copy_from(File::open(path).map_err(ctx)?)?;
            if copied != len {
                return Err(ctx(io::Error::other("file changed size while reading")));
            }
            self.pad(len)?;
        } else if ft.is_dir() {
            self.str(b"directory")?;
            let mut entries: Vec<_> = fs::read_dir(path)
                .map_err(ctx)?
                .collect::<io::Result<_>>()
                .map_err(ctx)?;
            entries.sort_by(|a, b| a.file_name().as_bytes().cmp(b.file_name().as_bytes()));
            for e in entries {
                self.str(b"entry")?;
                self.str(b"(")?;
                self.str(b"name")?;
                self.str(e.file_name().as_bytes())?;
                self.str(b"node")?;
                self.node(&e.path())?;
                self.str(b")")?;
            }
        } else {
            return Err(ctx(io::Error::other("unsupported file type")));
        }
        self.str(b")")
    }

    fn copy_from(&mut self, mut f: File) -> io::Result<u64> {
        let mut buf = vec![0u8; 1 << 20];
        let mut total = 0;
        loop {
            let n = f.read(&mut buf)?;
            if n == 0 {
                return Ok(total);
            }
            self.raw(buf.get(..n).unwrap_or_default())?;
            total += len64(n);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::hex;
    use std::os::unix::fs::symlink;

    fn nar_sha256(p: &Path) -> String {
        let mut out = Vec::new();
        let mut w = NarWriter::new(&mut out);
        w.dump(p).unwrap();
        hex(&w.finish().0)
    }

    /// Hashes taken from `nix-store --dump <fixture> | sha256sum`.
    #[test]
    fn matches_nix_store_dump() {
        let dir = std::env::temp_dir().join(format!("nar-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("sub")).unwrap();
        fs::write(dir.join("a.txt"), "hello\n").unwrap();
        fs::write(dir.join("empty"), "").unwrap();
        fs::write(dir.join("sub/run.sh"), "#!/bin/sh\necho hi\n").unwrap();
        fs::set_permissions(dir.join("sub/run.sh"), fs::Permissions::from_mode(0o755)).unwrap();
        symlink("../a.txt", dir.join("sub/link")).unwrap();

        assert_eq!(
            nar_sha256(&dir.join("a.txt")),
            "1c37d01af40be2e80691de3cc3df44377a699afbb17c68f080964b2fd071fc13"
        );
        assert_eq!(
            nar_sha256(&dir),
            "2868be1fc55acdfaf3b18fcbdf9922707bd6955f008d01971061a2f3dd2408ef"
        );
        fs::remove_dir_all(&dir).unwrap();
    }
}
