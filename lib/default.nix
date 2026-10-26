{ nixpkgs }:

let
  inherit (nixpkgs) lib;

  # Pinned Lix for includeLix. The installer is only published at an
  # unversioned URL, so when upstream updates it this hash must be bumped
  # (or pass your own `lix` attrset).
  defaultLix = {
    version = "2.95.2";
    installer = {
      version = "3.95.0";
      url = "https://install.lix.systems/lix/lix-installer-x86_64-linux";
      hash = "sha256-V1ZOeKbVcSZmH+Xnk95wpyus+YNd23xcDL+t89shVF4=";
    };
    tarball = {
      url = "https://releases.lix.systems/lix/lix-2.95.2/lix-2.95.2-x86_64-linux.tar.xz";
      hash = "sha256-HzJl0++CHnI/jFOLynG1N7aFU816jNQj5UvcEYWrVhY=";
    };
  };

  # The polyglot entry point: the name field of the bundle's first tar header.
  # It must fit in 100 bytes and may not contain '/'.
  entry = '':;sh -c "$(tar -xOf "$0" stub.sh)" airgap "$0" "$@";exit'';
in
rec {
  inherit defaultLix;

  tool = pkgs: pkgs.callPackage ../tool { };

  /**
    `nix run .#sbom -- [BUNDLE] [OUT]`: one CycloneDX SBOM (default
    ./sbom.cdx.json) of everything a bundle ships, for mkDevShellBundle's `sbom`
    option. BUNDLE is the bundle's flakeref (default `.#airgap`). sbomnix scans
    the shell, direnv and each extra path as the guide does; the Lix installer
    and tarball, which come from Lix rather than this flake, are described from
    their pinned files. See ../sbom/sbom.sh.
  */
  sbomApp =
    pkgs:
    pkgs.writeShellApplication {
      name = "nix-airgap-sbom";
      runtimeInputs = with pkgs; [
        sbomnix
        jq
        coreutils
        gnutar
        gnused
        xz
      ];
      runtimeEnv = {
        LIX_JQ = ../sbom/lix.jq;
        MERGE_JQ = ../sbom/merge.jq;
      };
      text = builtins.readFile ../sbom/sbom.sh;
    };

  /**
    Bundle a dev shell into a single file that is both a tar archive and a
    shell script. On the air-gapped machine, `sh <bundle> [project-dir]`
    imports the closure and writes an .envrc that activates the shell offline.

    The bundle carries the shell's derivation closure (.drv files and sources)
    plus the runtime closure of its direct inputs: exactly what
    `nix print-dev-env <drv>` needs, without the build-time-only outputs.
  */
  mkDevShellBundle =
    {
      pkgs,
      shell,
      name ? shell.name or "dev-shell",
      # Embed the Lix installer so the bundle also works on machines without Nix.
      includeLix ? false,
      lix ? defaultLix,
      # Ship direnv and install it into the user's profile if it is missing.
      includeDirenv ? false,
      # Extra store paths to import alongside the shell.
      extraPaths ? [ ],
      # A CycloneDX SBOM of everything the bundle ships, made with
      #   nix run github:Marauder586/nix-airgap#sbom -- <flakeref of this bundle>
      # The build fails unless it describes exactly this `shell` and also covers
      # direnv, each extra path and Lix whenever they are bundled.
      # `sh <bundle> --sbom` extracts it.
      sbom ? null,
      # zstd settings for the bundled binary cache. `long` is the window log; the
      # target needs about 2^long bytes of RAM to decompress.
      compression ? { },
    }:
    let
      zstd = {
        level = 19;
        long = 31;
      }
      // compression;
      direnv = lib.optionalString includeDirenv "${pkgs.direnv}";
      runtime = pkgs.closureInfo {
        rootPaths = [ shell.inputDerivation ] ++ lib.optional includeDirenv pkgs.direnv ++ extraPaths;
      };
      lixInstaller = pkgs.fetchurl { inherit (lix.installer) url hash; };
      lixTarball = pkgs.fetchurl { inherit (lix.tarball) url hash; };
      lixTarballName = baseNameOf lix.tarball.url;

      # What the SBOM must describe, for `nix run .#sbom` and the build check.
      sbomTargets = {
        inherit shell;
      }
      // lib.optionalAttrs includeDirenv { inherit (pkgs) direnv; }
      // lib.listToAttrs (lib.imap0 (i: p: lib.nameValuePair "extra-${toString i}" p) extraPaths);
      airgapSbom = {
        targets = sbomTargets;
        lix =
          if includeLix then
            {
              version = lix.version or "unknown";
              installer = {
                file = lixInstaller;
                inherit (lix.installer) url;
                version = lix.installer.version or "unknown";
              };
              tarball = {
                file = lixTarball;
                inherit (lix.tarball) url;
              };
            }
          else
            null;
      };
      drvOf = drv: builtins.unsafeDiscardOutputDependency drv.drvPath;
    in
    assert lib.assertMsg (
      !includeLix || pkgs.stdenv.hostPlatform.system == "x86_64-linux" || lix != defaultLix
    ) "nix-airgap: the default Lix pin is x86_64-linux only; pass `lix` for other systems";
    assert lib.assertMsg (
      sbom == null || lib.all lib.isDerivation extraPaths
    ) "nix-airgap: with `sbom` set, extraPaths must be derivations so the SBOM can describe them";
    pkgs.runCommand "${name}-airgap.tar"
      {
        nativeBuildInputs = [
          (tool pkgs)
          pkgs.zstd
          pkgs.jq
        ];
        # Discarding the output dependency gives the .drv file (and through its
        # references, the whole derivation closure) without building outputs.
        drv = drvOf shell;
        registration = "${runtime}/registration";
        stub = ../stub/stub.sh;
        bundleName = name;
        inherit entry direnv;
        zstdLevel = toString zstd.level;
        zstdLong = toString zstd.long;
        lixInstaller = lib.optionalString includeLix "${lixInstaller}";
        lixTarball = lib.optionalString includeLix "${lixTarball}";
        lixTarballName = lib.optionalString includeLix lixTarballName;
        sbom = lib.optionalString (sbom != null) "${sbom}";
        # Everything besides the shell (the SBOM's root) it must also describe.
        sbomRequiredRefs = lib.optionals (sbom != null) (
          map drvOf (lib.attrValues (removeAttrs sbomTargets [ "shell" ]))
        );
        passthru = { inherit shell runtime airgapSbom; };
      }
      ''
        if [ -n "$sbom" ]; then
          if ! sbom_ref=$(jq -er 'select(.bomFormat == "CycloneDX") | .metadata.component."bom-ref"' "$sbom"); then
            echo "nix-airgap: $sbom is not a CycloneDX SBOM with metadata.component.bom-ref" >&2
            exit 1
          fi
          regenerate="regenerate it with: nix run github:Marauder586/nix-airgap#sbom -- <flakeref of this bundle>"
          if [ "$sbom_ref" != "$drv" ]; then
            echo "nix-airgap: the SBOM describes $sbom_ref, but this bundle is $drv." >&2
            echo "nix-airgap: $regenerate" >&2
            exit 1
          fi
          missing=()
          for ref in $sbomRequiredRefs; do
            jq -e --arg r "$ref" 'any(.components[]?; ."bom-ref" == $r)' "$sbom" >/dev/null || missing+=("$ref")
          done
          if [ -n "$lixInstaller" ]; then
            for part in installer:"$lixInstaller" tarball:"$lixTarball"; do
              hash=$(sha256sum "''${part#*:}" | cut -d' ' -f1)
              jq -e --arg r "lix-''${part%%:*}" --arg h "$hash" \
                'any(.components[]?; ."bom-ref" == $r and any(.hashes[]?; .content == $h))' \
                "$sbom" >/dev/null || missing+=("lix-''${part%%:*} (sha256 $hash)")
            done
          fi
          if [ ''${#missing[@]} -gt 0 ]; then
            echo "nix-airgap: the SBOM doesn't cover these bundled parts:" >&2
            printf 'nix-airgap:   %s\n' "''${missing[@]}" >&2
            echo "nix-airgap: $regenerate" >&2
            exit 1
          fi
          cp "$sbom" sbom.cdx.json
        fi

        # An uncompressed binary cache, as `nix copy --to file://...?compression=none`
        # writes it, packed into one zstd tarball: zstd --long finds the duplicate
        # chunks spread across NARs that per-file compression can't.
        nix-airgap-tool cache --registration "$registration" --drv "$drv" \
          --out cache --stats stats
        tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner -C cache -cf - . \
          | zstd -q -T"$NIX_BUILD_CORES" --ultra -"$zstdLevel" --long="$zstdLong" -o cache.tar.zst
        rm -rf cache

        {
          echo "format=2"
          echo "name=$bundleName"
          echo "drv=$drv"
          cat stats
          echo "cache_sha256=$(sha256sum cache.tar.zst | cut -d' ' -f1)"
          echo "zstd_long=$zstdLong"
          echo "direnv=$direnv"
          echo "lix_tarball=''${lixTarballName:+lix/$lixTarballName}"
          echo "sbom=''${sbom:+sbom.cdx.json}"
        } > manifest
        cat manifest

        members=(stub.sh="$stub" manifest=manifest cache.tar.zst=cache.tar.zst)
        if [ -n "$sbom" ]; then
          members+=(sbom.cdx.json=sbom.cdx.json)
        fi
        if [ -n "$lixInstaller" ]; then
          members+=(lix/lix-installer="$lixInstaller" "lix/$lixTarballName=$lixTarball")
        fi
        nix-airgap-tool polyglot --entry "$entry" --out "$out" "''${members[@]}"
        chmod 0555 "$out"
      '';

  /**
    Bundle every dev shell of a flake:
      packages = airgap.lib.bundleDevShells self { };
    gives packages.<system>.airgap-<shell> for each devShells.<system>.<shell>.
    Extra arguments are passed to mkDevShellBundle.
  */
  bundleDevShells =
    flake: args:
    lib.mapAttrs (
      system: shells:
      lib.mapAttrs' (
        shellName: shell:
        lib.nameValuePair "airgap-${shellName}" (
          mkDevShellBundle (
            {
              pkgs = nixpkgs.legacyPackages.${system};
              inherit shell;
              name = shellName;
            }
            // args
          )
        )
      ) shells
    ) (flake.devShells or { });
}
