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

use clap::{Parser, Subcommand};
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::process::ExitCode;

#[derive(Parser)]
#[command(
    version,
    about = "Builds self-installing tar/sh polyglot bundles of Nix store closures"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Write a store closure as an uncompressed `file://` binary cache
    ///
    /// The cache (for `nix copy --from`) contains the closures listed in
    /// closureInfo registration files plus the derivation closure (.drv files
    /// and their sources, but not their outputs) of each --drv, and a
    /// `store-paths` file listing every path in it.
    Cache {
        /// Directory to write the cache into.
        #[arg(long, value_name = "DIR")]
        out: PathBuf,
        /// A closureInfo `registration` file; repeatable.
        #[arg(long, value_name = "FILE")]
        registration: Vec<PathBuf>,
        /// A .drv whose derivation closure to include; repeatable.
        #[arg(long, value_name = "DRV")]
        drv: Vec<PathBuf>,
        /// Write `paths=` and `nar_size=` here instead of to stderr.
        #[arg(long, value_name = "FILE")]
        stats: Option<PathBuf>,
    },
    /// Write a tar archive that is also a shell script
    ///
    /// The archive's first header is a pax global header named LINE, which tar
    /// ignores and a shell runs, so the archive can also be run with `sh FILE`.
    Polyglot {
        /// The shell line to put in the first header (no '/', at most 99 bytes).
        #[arg(long, value_name = "LINE")]
        entry: String,
        /// The archive to write.
        #[arg(long, value_name = "FILE")]
        out: PathBuf,
        /// Archive members, in order.
        #[arg(value_name = "NAME=PATH", required = true, value_parser = parse_member)]
        members: Vec<tar::Member>,
    },
}

fn parse_member(s: &str) -> Result<tar::Member, String> {
    let (name, path) = s
        .split_once('=')
        .ok_or_else(|| format!("'{s}' is not NAME=PATH"))?;
    Ok(tar::Member {
        name: name.to_owned(),
        path: PathBuf::from(path),
    })
}

fn main() -> ExitCode {
    match run(Cli::parse().command) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("nix-airgap-tool: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(command: Command) -> Result<(), String> {
    match command {
        Command::Cache {
            out,
            registration,
            drv,
            stats,
        } => {
            let closure = cache::Closure::collect(&registration, &drv)?;
            let stats_text = {
                let s = closure.write_cache(&out)?;
                format!("paths={}\nnar_size={}\n", s.paths, s.nar_size)
            };
            match stats {
                None => eprint!("{stats_text}"),
                Some(p) => std::fs::write(&p, stats_text)
                    .map_err(|e| format!("writing {}: {e}", p.display()))?,
            }
            Ok(())
        }
        Command::Polyglot {
            entry,
            out,
            members,
        } => {
            let f = File::create(&out).map_err(|e| format!("creating {}: {e}", out.display()))?;
            let mut w = BufWriter::new(f);
            tar::write_polyglot(&mut w, &entry, &members)?;
            w.flush()
                .map_err(|e| format!("writing {}: {e}", out.display()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    #[test]
    fn cli_is_consistent() {
        Cli::command().debug_assert();
    }

    #[test]
    fn parses_the_bundle_builders_invocations() {
        let cli = Cli::try_parse_from([
            "nix-airgap-tool",
            "cache",
            "--registration",
            "reg",
            "--drv",
            "/nix/store/x.drv",
            "--out",
            "cache",
            "--stats",
            "stats",
        ])
        .unwrap();
        assert!(matches!(cli.command, Command::Cache { ref drv, .. } if drv.len() == 1));

        let cli = Cli::try_parse_from([
            "nix-airgap-tool",
            "polyglot",
            "--entry",
            ":;exit",
            "--out",
            "o.tar",
            "stub.sh=/a",
            "lix/x=/b",
        ])
        .unwrap();
        let Command::Polyglot { members, .. } = cli.command else {
            panic!("not polyglot");
        };
        assert_eq!(members[1].name, "lix/x");

        assert!(Cli::try_parse_from([
            "nix-airgap-tool",
            "polyglot",
            "--entry",
            "x",
            "--out",
            "o",
            "bad"
        ])
        .is_err());
        assert!(
            Cli::try_parse_from(["nix-airgap-tool", "polyglot", "--entry", "x", "--out", "o"])
                .is_err()
        );
    }
}
