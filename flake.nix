{
  description = "Self-installing air-gap bundles (tar/sh polyglots) for Nix dev shells";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # `nix fmt`: treefmt with the formatters configured in treefmt.toml.
      mkTreefmt =
        pkgs:
        pkgs.writeShellApplication {
          name = "treefmt";
          runtimeInputs = with pkgs; [
            treefmt
            nixfmt
            rustfmt
            shfmt
            prettier
            taplo
          ];
          text = ''exec treefmt "$@"'';
        };
    in
    {
      lib = import ./lib { inherit nixpkgs; };

      packages = forAllSystems (pkgs: {
        default = self.lib.tool pkgs;
        nix-airgap-tool = self.lib.tool pkgs;
        sbom = self.lib.sbomApp pkgs;
      });

      apps = forAllSystems (pkgs: {
        sbom = {
          type = "app";
          program = nixpkgs.lib.getExe (self.lib.sbomApp pkgs);
          meta.description = "Write a CycloneDX SBOM of a dev shell for mkDevShellBundle's sbom option";
        };
      });

      checks = forAllSystems (
        pkgs:
        let
          helloShell = pkgs.mkShell { packages = [ pkgs.hello ]; };
          drvOf = drv: builtins.unsafeDiscardOutputDependency drv.drvPath;
          lixFiles = {
            installer = pkgs.fetchurl { inherit (self.lib.defaultLix.installer) url hash; };
            tarball = pkgs.fetchurl { inherit (self.lib.defaultLix.tarball) url hash; };
          };
          # The parts of a `nix run .#sbom` CycloneDX file that mkDevShellBundle
          # checks: the shell as root, a component per extra part, and the Lix
          # installer and tarball with their sha256.
          fakeSbom =
            {
              shell,
              extras ? [ ],
              lix ? false,
            }:
            pkgs.runCommand "sbom.cdx.json"
              {
                nativeBuildInputs = [ pkgs.jq ];
                root = drvOf shell;
                extraRefs = map drvOf extras;
                lixInstaller = if lix then lixFiles.installer else "";
                lixTarball = if lix then lixFiles.tarball else "";
              }
              ''
                comps='[]'
                for ref in $extraRefs; do
                  comps=$(jq -c --arg r "$ref" '. + [{type: "library", "bom-ref": $r, name: "x"}]' <<<"$comps")
                done
                if [ -n "$lixInstaller" ]; then
                  for part in installer:$lixInstaller tarball:$lixTarball; do
                    comps=$(jq -c --arg r "lix-''${part%%:*}" --arg h "$(sha256sum "''${part#*:}" | cut -d' ' -f1)" \
                      '. + [{type: "application", "bom-ref": $r, name: $r, hashes: [{alg: "SHA-256", content: $h}]}]' <<<"$comps")
                  done
                fi
                jq -n --arg root "$root" --argjson comps "$comps" \
                  '{bomFormat: "CycloneDX", specVersion: "1.4", metadata: {component: {name: "nix-shell", "bom-ref": $root}}, components: $comps}' >$out
              '';
          # A bundle with every optional part, for the SBOM coverage checks.
          fullBundle =
            sbom:
            self.lib.mkDevShellBundle {
              inherit pkgs sbom;
              shell = helloShell;
              includeLix = true;
              includeDirenv = true;
              extraPaths = [ pkgs.jq ];
              compression.level = 3;
            };
        in
        {
          tool = self.lib.tool pkgs;

          clippy = (self.lib.tool pkgs).overrideAttrs (old: {
            pname = "nix-airgap-tool-clippy";
            nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.clippy ];
            buildPhase = "cargo clippy --all-targets --offline -- -D warnings";
            doCheck = false;
            installPhase = "touch $out";
          });

          formatting = pkgs.runCommand "check-formatting" { nativeBuildInputs = [ (mkTreefmt pkgs) ]; } ''
            cp -r ${self} src && chmod -R u+w src && cd src
            HOME=$TMPDIR treefmt --no-cache --fail-on-change
            touch $out
          '';

          lint =
            pkgs.runCommand "check-lint"
              {
                nativeBuildInputs = with pkgs; [
                  statix
                  deadnix
                  shellcheck
                ];
              }
              ''
                cd ${self}
                statix check .
                deadnix --fail .
                shellcheck -s sh stub/stub.sh
                shellcheck tests/*.sh sbom/sbom.sh
                touch $out
              '';

          # Builds a small bundle and checks it is a valid tar and a runnable script.
          bundle =
            let
              bundle = self.lib.mkDevShellBundle {
                inherit pkgs;
                shell = helloShell;
                name = "hello";
                sbom = fakeSbom { shell = helloShell; };
                compression.level = 3;
              };
            in
            pkgs.runCommand "check-bundle"
              {
                nativeBuildInputs = [
                  pkgs.gnutar
                  pkgs.libarchive
                  pkgs.dash
                  pkgs.jq
                  pkgs.zstd
                ];
              }
              ''
                [ "$(tar -tf ${bundle})" = "$(printf 'stub.sh\nmanifest\ncache.tar.zst\nsbom.cdx.json')" ]
                bsdtar -tf ${bundle} >/dev/null
                mkdir x && tar -xf ${bundle} -C x
                [ "$(ls -A x | sort | tr '\n' ' ')" = "cache.tar.zst manifest sbom.cdx.json stub.sh " ]

                # Real Nix and Lix must accept the binary cache the way the
                # installer copies it: nix copy re-checks every NAR hash while
                # copying it into a throwaway store.
                mkdir cache && zstd -dcq --long=31 x/cache.tar.zst | tar -xf - -C cache
                export HOME=$TMPDIR
                drv=$(sed -n 's/^drv=//p' x/manifest)
                for impl in ${pkgs.nix} ${pkgs.lix}; do
                  store="local?root=$TMPDIR/store-$(basename $impl)"
                  $impl/bin/nix --extra-experimental-features nix-command copy --no-check-sigs \
                    --from "file://$PWD/cache" --to "$store" --stdin < cache/store-paths
                  $impl/bin/nix --extra-experimental-features nix-command path-info \
                    --store "$store" "$drv" >/dev/null
                done
                dash ${bundle} --help | grep -q 'Usage:'
                bash ${bundle} --list | grep -q cache.tar.zst
                grep -qx 'compression=zstd' x/manifest

                # --sbom extracts only the SBOM, needs no Nix, and won't clobber.
                dash ${bundle} --sbom out
                [ "$(ls -A out)" = sbom.cdx.json ]
                jq -e '.bomFormat == "CycloneDX"' out/sbom.cdx.json >/dev/null
                ! dash ${bundle} --sbom out 2>err && grep -q 'already exists' err
                dash ${bundle} --sbom --force out
                touch $out
              '';

          # compression = null: an uncompressed cache.tar that needs no zstd on
          # the target, still accepted by Nix and Lix.
          bundle-uncompressed =
            let
              bundle = self.lib.mkDevShellBundle {
                inherit pkgs;
                shell = helloShell;
                name = "hello";
                compression = null;
              };
            in
            pkgs.runCommand "check-bundle-uncompressed"
              {
                # No zstd here on purpose.
                nativeBuildInputs = [
                  pkgs.gnutar
                  pkgs.dash
                ];
              }
              ''
                [ "$(tar -tf ${bundle})" = "$(printf 'stub.sh\nmanifest\ncache.tar')" ]
                mkdir x && tar -xf ${bundle} -C x
                grep -qx 'compression=none' x/manifest
                grep -qx 'cache=cache.tar' x/manifest
                grep -qx "cache_sha256=$(sha256sum x/cache.tar | cut -d' ' -f1)" x/manifest

                mkdir cache && tar -xf x/cache.tar -C cache
                export HOME=$TMPDIR
                drv=$(sed -n 's/^drv=//p' x/manifest)
                for impl in ${pkgs.nix} ${pkgs.lix}; do
                  store="local?root=$TMPDIR/store-$(basename $impl)"
                  $impl/bin/nix --extra-experimental-features nix-command copy --no-check-sigs \
                    --from "file://$PWD/cache" --to "$store" --stdin < cache/store-paths
                  $impl/bin/nix --extra-experimental-features nix-command path-info \
                    --store "$store" "$drv" >/dev/null
                done
                ! command -v zstd
                dash ${bundle} --help | grep -q 'Usage:'
                dash ${bundle} --list | grep -q 'cache.tar$'
                touch $out
              '';

          # An SBOM of a different derivation must fail the build.
          stale-sbom =
            let
              failure = pkgs.testers.testBuildFailure (
                self.lib.mkDevShellBundle {
                  inherit pkgs;
                  shell = helloShell;
                  sbom = fakeSbom { shell = pkgs.mkShell { packages = [ pkgs.jq ]; }; };
                  compression.level = 3;
                }
              );
            in
            pkgs.runCommand "check-stale-sbom" { } ''
              grep -q 'the SBOM describes' ${failure}/testBuildFailure.log
              touch $out
            '';

          # With direnv, an extra path and Lix bundled, an SBOM that covers them
          # all builds; one that only covers the shell must fail and name what's
          # missing.
          sbom-coverage =
            let
              covered = fullBundle (fakeSbom {
                shell = helloShell;
                extras = [
                  pkgs.direnv
                  pkgs.jq
                ];
                lix = true;
              });
              failure = pkgs.testers.testBuildFailure (
                fullBundle (fakeSbom {
                  shell = helloShell;
                })
              );
            in
            pkgs.runCommand "check-sbom-coverage" { } ''
              test -s ${covered}
              log=${failure}/testBuildFailure.log
              grep -q "doesn't cover these bundled parts" $log
              grep -q -- '-direnv-.*\.drv' $log
              grep -q -- '-jq-.*\.drv' $log
              grep -q 'lix-installer' $log
              grep -q 'lix-tarball' $log
              touch $out
            '';
        }
      );

      templates.default = {
        path = ./templates/devshell;
        description = "A dev shell with an air-gap bundle";
      };

      formatter = forAllSystems mkTreefmt;
    };
}
