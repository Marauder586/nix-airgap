//! Just enough of an `ATerm` parser to read the references of a `.drv` file.
//!
//! A derivation's store references are exactly its input derivations plus its
//! input sources, so walking these gives the derivation closure without the
//! store database (and without the outputs `exportReferencesGraph` would add).

#[derive(Debug)]
enum Term {
    Str(String),
    List(Vec<Self>),
    Tuple(Vec<Self>),
    App(String, Vec<Self>),
}

struct Parser<'a> {
    s: &'a [u8],
    pos: usize,
}

impl Parser<'_> {
    fn err<T>(&self, msg: &str) -> Result<T, String> {
        Err(format!("{msg} at byte {}", self.pos))
    }

    fn peek(&self) -> Option<u8> {
        self.s.get(self.pos).copied()
    }

    fn expect(&mut self, c: u8) -> Result<(), String> {
        if self.peek() == Some(c) {
            self.pos += 1;
            Ok(())
        } else {
            self.err(&format!("expected '{}'", char::from(c)))
        }
    }

    fn seq(&mut self, close: u8) -> Result<Vec<Term>, String> {
        let mut items = Vec::new();
        if self.peek() == Some(close) {
            self.pos += 1;
            return Ok(items);
        }
        loop {
            items.push(self.term()?);
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(c) if c == close => {
                    self.pos += 1;
                    return Ok(items);
                }
                _ => return self.err("expected ',' or end of sequence"),
            }
        }
    }

    fn term(&mut self) -> Result<Term, String> {
        match self.peek() {
            Some(b'"') => {
                self.pos += 1;
                let mut out = Vec::new();
                loop {
                    match self.peek() {
                        None => return self.err("unterminated string"),
                        Some(b'"') => {
                            self.pos += 1;
                            break;
                        }
                        Some(b'\\') => {
                            let c = *self.s.get(self.pos + 1).ok_or("unterminated escape")?;
                            out.push(match c {
                                b'n' => b'\n',
                                b'r' => b'\r',
                                b't' => b'\t',
                                c => c,
                            });
                            self.pos += 2;
                        }
                        Some(c) => {
                            out.push(c);
                            self.pos += 1;
                        }
                    }
                }
                String::from_utf8(out)
                    .map(Term::Str)
                    .map_err(|_| "non-UTF-8 string".into())
            }
            Some(b'[') => {
                self.pos += 1;
                self.seq(b']').map(Term::List)
            }
            Some(b'(') => {
                self.pos += 1;
                self.seq(b')').map(Term::Tuple)
            }
            Some(c) if c.is_ascii_alphabetic() => {
                let start = self.pos;
                while self.peek().is_some_and(|c| c.is_ascii_alphanumeric()) {
                    self.pos += 1;
                }
                let name = String::from_utf8_lossy(self.s.get(start..self.pos).unwrap_or_default())
                    .into_owned();
                self.expect(b'(')?;
                Ok(Term::App(name, self.seq(b')')?))
            }
            _ => self.err("unexpected input"),
        }
    }
}

/// Returns the input derivations and input sources of a `.drv` file's contents.
pub fn references(contents: &[u8]) -> Result<Vec<String>, String> {
    let mut p = Parser {
        s: contents,
        pos: 0,
    };
    let Term::App(name, args) = p.term()? else {
        return Err("not a derivation".into());
    };
    if name != "Derive" {
        return Err(format!("unsupported derivation format '{name}'"));
    }
    let (Some(Term::List(input_drvs)), Some(Term::List(input_srcs))) = (args.get(1), args.get(2))
    else {
        return Err("malformed Derive(...)".into());
    };
    let mut refs = Vec::new();
    for d in input_drvs {
        match d {
            Term::Tuple(t) => match t.first() {
                Some(Term::Str(path)) => refs.push(path.clone()),
                _ => return Err("malformed input derivation".into()),
            },
            _ => return Err("malformed input derivation".into()),
        }
    }
    for s in input_srcs {
        match s {
            Term::Str(path) => refs.push(path.clone()),
            _ => return Err("malformed input source".into()),
        }
    }
    Ok(refs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_inputs() {
        let drv = br#"Derive([("out","/nix/store/aaa-x","","")],[("/nix/store/bbb-y.drv",["out","dev"])],["/nix/store/ccc-builder.sh"],"x86_64-linux","/bin/sh",["-c","echo \"hi\"\n"],[("out","/nix/store/aaa-x")])"#;
        assert_eq!(
            references(drv).unwrap(),
            vec!["/nix/store/bbb-y.drv", "/nix/store/ccc-builder.sh"]
        );
    }
}
