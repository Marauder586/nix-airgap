# nix-airgap

Turn a Nix dev shell into **one file** you can carry into an air gap. The file
is both a tar archive and a shell script:

```console
$ nix build .#airgap          # on a machine with internet
$ sh result ~/my-project      # on the air-gapped machine
$ cd ~/my-project && direnv allow
```

Running it imports the shell's closure into `/nix/store` (installing Lix first,
if you bundled it and Nix is missing) and writes an `.envrc` that activates the
shell with `nix print-dev-env`, entirely offline. `tar -tf result` still lists it
like any other tarball, so it can be inspected before it is run.

## Usage

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    airgap.url = "github:Marauder586/nix-airgap";
    airgap.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, airgap }:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux; in {
      devShells.x86_64-linux.default = pkgs.mkShell { packages = [ pkgs.go ]; };

      packages.x86_64-linux.airgap = airgap.lib.mkDevShellBundle {
        inherit pkgs;
        shell = self.devShells.x86_64-linux.default;
      };
    };
}
```

Or bundle every dev shell at once: `packages = airgap.lib.bundleDevShells self { };`
gives `packages.<system>.airgap-<shell>`. Start a new project with
`nix flake init -t github:Marauder586/nix-airgap`.

### `mkDevShellBundle` options

| Option          | Default                      | Description                                                         |
| --------------- | ---------------------------- | ------------------------------------------------------------------- |
| `pkgs`          | required                     | Used for build tools only; nothing from it is added to the bundle   |
| `shell`         | required                     | A `mkShell` derivation                                              |
| `name`          | `shell.name`                 | Output is `<name>-airgap.tar`                                       |
| `includeLix`    | `false`                      | Embed the Lix installer for machines without Nix (x86_64-linux pin) |
| `lix`           | pinned 2.95.2                | `{ installer = { url; hash; }; tarball = { url; hash; }; }`         |
| `includeDirenv` | `false`                      | Ship direnv and install it into the user's profile if missing       |
| `extraPaths`    | `[ ]`                        | More store paths to import with the shell                           |
| `sbom`          | `null`                       | A CycloneDX SBOM of the whole bundle to include (see [SBOM](#sbom)) |
| `compression`   | `{ level = 19; long = 31; }` | zstd settings (see below); `null` bundles the cache uncompressed    |

### Running the bundle

```
sh <bundle> [--dry-run] [--list] [--force] [--no-envrc] [project-dir]
sh <bundle> --sbom [dir]
```

The target needs `tar`, `sha256sum` and `sudo` (or root), plus `zstd` unless the
bundle was built with `compression = null`, and free space for the unpacked cache
under `$TMPDIR` (default `/tmp`) plus the same again in `/nix/store`. The
installer:

1. installs Lix from the bundle if Nix is missing (when built with `includeLix`),
2. checks free space and the bundle's sha256,
3. unpacks the bundled binary cache and copies it in with
   `sudo nix copy --no-check-sigs --from file://… --stdin < store-paths`
   (not `--all`, which fails on Lix because a cache only tells it each path's hash),
4. installs direnv (when built with `includeDirenv`),
5. writes `.envrc`, or `.envrc.airgap` if you already have an `.envrc` it did not write,
6. adds GC roots so `nix-collect-garbage` does not remove the shell, and
7. builds the environment once, which proves it works offline.

### Home Manager

`mkHomeBundle` bundles a Home Manager configuration the same way. Running the
bundle copies the configuration's closure into `/nix/store` and runs its
activation as you: `home.packages` land in your profile and the managed dotfiles
are linked.

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    airgap.url = "github:Marauder586/nix-airgap";
    airgap.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, home-manager, airgap }: {
    homeConfigurations.alice = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [{
        home = {
          username = "alice"; # the user on the air-gapped machine
          homeDirectory = "/home/alice";
          stateVersion = "26.05";
          packages = [ nixpkgs.legacyPackages.x86_64-linux.jq ];
        };
      }];
    };

    # packages.x86_64-linux.airgap-home-alice
    packages = airgap.lib.bundleHomeConfigurations self { };
  };
}
```

```console
$ nix build .#airgap-home-alice     # online
$ sh result                         # on the air-gapped machine, as alice
```

- `home.username` and `home.homeDirectory` are fixed at build time, so set them
  to the target's user. The installer checks both before installing anything
  and refuses to activate for anyone else.
- Files that are in the way of managed ones (like Ubuntu's stock `~/.bashrc`)
  are renamed to `FILE.airgap.bak`; choose another suffix with `--backup-ext`.
- Home Manager roots the generation it activates, so it survives
  `nix-collect-garbage`. No `.envrc` is written.
- `mkHomeBundle { pkgs; homeConfiguration; }` takes `name`, `includeLix`, `lix`,
  `extraPaths`, `sbom` and `compression` like `mkDevShellBundle`. To combine
  with dev shell bundles, merge the two with `nixpkgs.lib.recursiveUpdate`.
- The SBOM's root is the activation package:
  `nix run github:Marauder586/nix-airgap#sbom -- .#airgap-home-alice`.

### SBOM

`nix run …#sbom` writes one CycloneDX SBOM of **everything the bundle ships**,
and the bundle carries it:

```console
$ nix run github:Marauder586/nix-airgap#sbom -- .#airgap   # bundle flakeref -> ./sbom.cdx.json
```

```nix
packages.x86_64-linux.airgap = airgap.lib.mkDevShellBundle {
  inherit pkgs;
  shell = self.devShells.x86_64-linux.default;
  sbom = ./sbom.cdx.json;
};
```

| Bundled part                             | How it gets into the SBOM                                                                                        |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| The dev shell                            | [sbomnix](https://github.com/tiiuae/sbomnix), as in the guide; its `.drv` is the SBOM's root                     |
| direnv (`includeDirenv`)                 | sbomnix                                                                                                          |
| Each of `extraPaths`                     | sbomnix (they must be derivations when `sbom` is set)                                                            |
| Lix installer and tarball (`includeLix`) | Components with version, download URL and sha256, plus a component for each of the 64 store paths in the tarball |

The parts are merged with the shell's SBOM as the base, and every part's root is
added to the root's `dependencies`. sbomnix runs on the bundle's
`airgapSbom.targets` attribute rather than store paths, so it keeps the nixpkgs
metadata (licenses, descriptions, CPEs). The Lix files come from Lix, not your
nixpkgs, so they have no license data.

On the other side, `sh <bundle> --sbom [dir]` extracts `sbom.cdx.json` and
nothing else. It needs only `tar`, so the SBOM can be reviewed before anything
is installed. `--force` replaces an existing file.

The SBOM is made outside the bundle build because sbomnix needs the Nix daemon
and evaluates nixpkgs for license metadata, which the build sandbox can't do.
To keep a stale or partial SBOM from being shipped, the build fails unless:

- its root (`metadata.component.bom-ref`) is the shell's exact `.drv`, and
- it has a component for direnv's and each extra path's `.drv`, and for the Lix
  installer and tarball with matching sha256, whenever those are bundled.

The error lists whatever is missing. Rerun `nix run …#sbom` whenever the shell,
the bundle options or `flake.lock` change. With a git flake, `git add` the new
`sbom.cdx.json` so the build can see it.

## How it works

**What gets bundled.** `nix print-dev-env <drv>` needs the shell's `.drv` file,
the `.drv` closure it references, and the outputs of the shell's _direct_
inputs. It does not need the build-time outputs of the whole bootstrap chain,
which `nix-store -qR --include-outputs` would pull in. The bundle contains:

- the runtime closure of `shell.inputDerivation` (via `closureInfo`), and
- the derivation closure, found by parsing `.drv` files. `exportReferencesGraph`
  can't be used here, because it adds the outputs of every derivation it sees.

**The binary cache.** `nix-airgap-tool cache` (Rust) writes the same layout as
`nix copy --to file://DIR?compression=none` (`nix-cache-info`, one `.narinfo` per
path, `nar/*.nar`), inside the build sandbox and with no access to the Nix
database. Every path's NAR hash is checked against `closureInfo`'s registration
as it is written. The cache is uncompressed and then packed into a single
`cache.tar.zst`, because zstd `--long` across all the NARs compresses far better
than compressing each NAR on its own (`compression = null` ships it as a plain
`cache.tar` instead).

**Compression and memory.** `compression.long` is zstd's window log: it can
reuse data up to 2^`long` bytes back, and decompressing takes about
min(2^`long`, unpacked cache size) of RAM. With the default `long = 31` (a
2 GiB window), a Go dev shell's ~650 MB cache peaked at ~658 MB while
decompressing, not 2 GiB. zstd refuses windows over 2^27 (128 MiB) unless told
otherwise, which is why the installer passes `--long`. `long = 27` caps
decompression memory at ~128 MiB; on that same shell it was only ~4% larger
(108 vs 104 MiB). `nix flake check` copies a bundle's cache
into scratch stores with both Nix's and Lix's `nix copy` to prove they accept it. The cache is
unsigned; the bundle's sha256 covers integrity.

**The polyglot.** The archive's first header is a pax _global_ header, whose
name field every tar implementation ignores. That field holds:

```sh
:;sh -c "$(tar -xOf "$0" stub.sh)" airgap "$0" "$@";exit
```

A shell runs that line, which runs the installer (`stub/stub.sh`) out of the
archive and exits before reaching any binary data. The manifest's `kind`
(`devshell` or `home`) tells the installer what to do after copying. The other members are
`stub.sh`, `manifest`, `cache.tar.zst` (or `cache.tar` with `compression = null`),
and optionally `sbom.cdx.json` and `lix/`.

## Testing

```console
$ nix flake check      # clippy, rustfmt/nixfmt/shfmt/prettier/taplo, statix, deadnix,
                       # shellcheck, Rust tests, a small bundle, SBOM checks
$ tests/e2e.sh         # full install in a fresh, air-gapped Ubuntu 24.04 QEMU VM
$ nix fmt              # format everything (treefmt.toml)
```

`tests/e2e.sh` needs KVM. It builds the template and `tests/consumer`, then boots
an Ubuntu cloud image with `restrict=on` user networking (no route out) and
checks: installing on a blank machine (Lix + direnv), extracting the SBOM before
Nix exists, using an existing Nix, re-runs, an existing `.envrc`, `--dry-run`, and
surviving `nix-collect-garbage`; and for a real Home Manager configuration
(`tests/consumer-home`): refusing another user, activation (packages, files, bash
config, the stock `.bashrc` backed up), re-runs and GC. Its SBOM is generated with `nix run .#sbom`.
