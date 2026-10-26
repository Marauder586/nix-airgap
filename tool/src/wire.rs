//! Small helpers shared by the NAR, export and tar writers.

use std::fmt::Write as _;
use std::io::{self, Read, Write};

/// `usize` to `u64`, which cannot fail on any target Nix supports.
pub fn len64(n: usize) -> u64 {
    u64::try_from(n).unwrap_or(u64::MAX)
}

/// Bytes of padding needed to round `len` up to a multiple of `align`.
pub const fn padding(len: u64, align: u64) -> u64 {
    (align - len % align) % align
}

pub fn zeros(w: &mut impl Write, n: u64) -> io::Result<()> {
    io::copy(&mut io::repeat(0).take(n), w).map(drop)
}

pub fn hex(bytes: &[u8]) -> String {
    bytes
        .iter()
        .fold(String::with_capacity(bytes.len() * 2), |mut s, b| {
            let _ = write!(s, "{b:02x}");
            s
        })
}
