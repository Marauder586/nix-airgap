//! nix-airgap-tool: the build-time half of nix-airgap.
//!
//! `cache`    writes a store closure as a `file://` binary cache (for
//!            `nix copy --from`) without touching the Nix database, so it can
//!            run inside the build sandbox.
//! `polyglot` writes a tar archive whose first header is also a shell command.

mod base32;
mod cache;
mod drv;
mod nar;
mod tar;
mod wire;

use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const USAGE: &str = "\
Usage:
  nix-airgap-tool cache --out DIR [--registration FILE]... [--drv DRV]... [--stats FILE]
      Write an uncompressed `file://` binary cache (for `nix copy --from`)
      containing the closures listed in closureInfo registration files plus the
      derivation closure (.drv files and their sources, but not their outputs)
      of each --drv.

  nix-airgap-tool polyglot --entry LINE --out FILE NAME=PATH...
      Write a ustar archive whose first header is a pax global header named LINE,
      so the archive can also be run with `sh FILE`.
";

fn main() -> ExitCode {
    match run(&std::env::args().skip(1).collect::<Vec<_>>()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("nix-airgap-tool: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: &[String]) -> Result<(), String> {
    let (cmd, rest) = args.split_first().ok_or(USAGE)?;
    match cmd.as_str() {
        "cache" => cmd_cache(rest),
        "polyglot" => cmd_polyglot(rest),
        "-h" | "--help" => {
            print!("{USAGE}");
            Ok(())
        }
        _ => Err(format!("unknown command '{cmd}'\n\n{USAGE}")),
    }
}

/// Pulls `--flag VALUE` pairs out of `args`, leaving positional arguments.
struct Args {
    flags: Vec<(String, String)>,
    positional: Vec<String>,
}

impl Args {
    fn parse(args: &[String], known: &[&str]) -> Result<Self, String> {
        let mut flags = Vec::new();
        let mut positional = Vec::new();
        let mut it = args.iter();
        while let Some(a) = it.next() {
            if known.contains(&a.as_str()) {
                let v = it.next().ok_or_else(|| format!("{a} needs a value"))?;
                flags.push((a.clone(), v.clone()));
            } else if a.starts_with("--") {
                return Err(format!("unknown flag '{a}'\n\n{USAGE}"));
            } else {
                positional.push(a.clone());
            }
        }
        Ok(Self { flags, positional })
    }

    fn all(&self, name: &str) -> Vec<&str> {
        self.flags
            .iter()
            .filter(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
            .collect()
    }

    fn one(&self, name: &str) -> Result<&str, String> {
        match self.all(name).as_slice() {
            [v] => Ok(v),
            [] => Err(format!("missing {name}")),
            _ => Err(format!("{name} given more than once")),
        }
    }
}

fn cmd_cache(args: &[String]) -> Result<(), String> {
    let a = Args::parse(args, &["--out", "--registration", "--drv", "--stats"])?;
    if !a.positional.is_empty() {
        return Err(format!("unexpected arguments: {:?}", a.positional));
    }
    let registrations: Vec<PathBuf> = a
        .all("--registration")
        .into_iter()
        .map(PathBuf::from)
        .collect();
    let drvs: Vec<PathBuf> = a.all("--drv").into_iter().map(PathBuf::from).collect();

    let closure = cache::Closure::collect(&registrations, &drvs)?;
    let stats = closure.write_cache(Path::new(a.one("--out")?))?;

    let summary = format!("paths={}\nnar_size={}\n", stats.paths, stats.nar_size);
    match a.all("--stats").as_slice() {
        [] => eprint!("{summary}"),
        [p] => std::fs::write(p, summary).map_err(|e| format!("writing {p}: {e}"))?,
        _ => return Err("--stats given more than once".into()),
    }
    Ok(())
}

fn cmd_polyglot(args: &[String]) -> Result<(), String> {
    let a = Args::parse(args, &["--out", "--entry"])?;
    let members = a
        .positional
        .iter()
        .map(|m| {
            let (name, path) = m
                .split_once('=')
                .ok_or_else(|| format!("member '{m}' is not NAME=PATH"))?;
            Ok(tar::Member {
                name: name.to_string(),
                path: PathBuf::from(path),
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    if members.is_empty() {
        return Err("polyglot needs at least one NAME=PATH member".into());
    }
    let out = a.one("--out")?;
    let f = File::create(out).map_err(|e| format!("creating {out}: {e}"))?;
    let mut w = BufWriter::new(f);
    tar::write_polyglot(&mut w, a.one("--entry")?, &members)?;
    w.flush().map_err(|e| format!("writing {out}: {e}"))
}
