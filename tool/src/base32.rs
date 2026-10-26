//! Nix's base32 encoding (not RFC 4648: different alphabet, reversed order).

const CHARS: &[u8; 32] = b"0123456789abcdfghijklmnpqrsvwxyz";

pub fn encode(bytes: &[u8]) -> String {
    if bytes.is_empty() {
        return String::new();
    }
    let len = (bytes.len() * 8 - 1) / 5 + 1;
    (0..len)
        .rev()
        .map(|n| {
            let b = n * 5;
            let (i, j) = (b / 8, b % 8);
            let lo = bytes.get(i).map_or(0, |&x| u16::from(x) >> j);
            let hi = bytes.get(i + 1).map_or(0, |&x| u16::from(x) << (8 - j));
            // Masked to 5 bits, so the lookup always succeeds.
            CHARS
                .get(usize::from((lo | hi) & 0x1f))
                .map_or('?', |&c| char::from(c))
        })
        .collect()
}

pub fn is_char(c: u8) -> bool {
    CHARS.contains(&c)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};

    #[test]
    fn empty_sha256_matches_nix() {
        // nix hash convert --to nix32 <sha256 of "">
        assert_eq!(
            encode(&Sha256::digest(b"")),
            "0mdqa9w1p6cmli6976v4wi0sw9r4p5prkj7lzfd1877wk11c9c73"
        );
    }
}
