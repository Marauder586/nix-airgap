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
    The shared bundle builder behind mkDevShellBundle and mkHomeBundle: a
    file:// binary cache of `runtimeRoots` (plus the derivation closure of
    `drv`, if any), the installer stub, a manifest, and optionally Lix and an
    SBOM, written as one tar/sh polyglot.
  */
  mkBundle =
    {
      pkgs,
      name,
      # "devshell" or "home": tells the installer what to do after copying.
      kind,
      # The bundle's main derivation and its key in the SBOM targets; the SBOM's
      # root must be this derivation.
      primary,
      primaryName,
      # Runtime closures to bundle (closureInfo roots).
      runtimeRoots,
      # A .drv whose derivation closure (not outputs) is bundled too, or null.
      drv ? null,
      # Extra `key=value` manifest entries for the installer.
      manifest ? { },
      includeLix ? false,
      lix ? defaultLix,
      # Everything besides `primary` the SBOM must describe, by name.
      extraSbomTargets ? { },
      sbom ? null,
      compression ? { },
      passthru ? { },
    }:
    let
      zstd =
        if compression == null then
          null
        else
          {
            level = 19;
            long = 31;
          }
          // compression;
      cacheMember = if zstd == null then "cache.tar" else "cache.tar.zst";
      runtime = pkgs.closureInfo { rootPaths = runtimeRoots; };
      lixInstaller = pkgs.fetchurl { inherit (lix.installer) url hash; };
      lixTarball = pkgs.fetchurl { inherit (lix.tarball) url hash; };
      lixTarballName = baseNameOf lix.tarball.url;

      # What the SBOM must describe, for `nix run .#sbom` and the build check.
      sbomTargets = {
        ${primaryName} = primary;
      }
      // extraSbomTargets;
      airgapSbom = {
        primary = primaryName;
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
      drvOf = d: builtins.unsafeDiscardOutputDependency d.drvPath;
    in
    assert lib.assertMsg (
      !includeLix || pkgs.stdenv.hostPlatform.system == "x86_64-linux" || lix != defaultLix
    ) "nix-airgap: the default Lix pin is x86_64-linux only; pass `lix` for other systems";
    assert lib.assertMsg (
      sbom == null || lib.all lib.isDerivation (lib.attrValues extraSbomTargets)
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
        drv = lib.optionalString (drv != null) drv;
        registration = "${runtime}/registration";
        stub = ../stub/stub.sh;
        bundleName = name;
        inherit entry kind;
        extraManifest = lib.concatStrings (lib.mapAttrsToList (k: v: "${k}=${v}\n") manifest);
        compressionKind = if zstd == null then "none" else "zstd";
        zstdLevel = lib.optionalString (zstd != null) (toString zstd.level);
        zstdLong = lib.optionalString (zstd != null) (toString zstd.long);
        inherit cacheMember;
        lixInstaller = lib.optionalString includeLix "${lixInstaller}";
        lixTarball = lib.optionalString includeLix "${lixTarball}";
        lixTarballName = lib.optionalString includeLix lixTarballName;
        sbom = lib.optionalString (sbom != null) "${sbom}";
        sbomRoot = drvOf primary;
        # Everything besides the primary part (the SBOM's root) it must describe.
        sbomRequiredRefs = lib.optionals (sbom != null) (map drvOf (lib.attrValues extraSbomTargets));
        passthru = {
          inherit runtime airgapSbom;
        }
        // passthru;
      }
      ''
        if [ -n "$sbom" ]; then
          if ! sbom_ref=$(jq -er 'select(.bomFormat == "CycloneDX") | .metadata.component."bom-ref"' "$sbom"); then
            echo "nix-airgap: $sbom is not a CycloneDX SBOM with metadata.component.bom-ref" >&2
            exit 1
          fi
          regenerate="regenerate it with: nix run github:Marauder586/nix-airgap#sbom -- <flakeref of this bundle>"
          if [ "$sbom_ref" != "$sbomRoot" ]; then
            echo "nix-airgap: the SBOM describes $sbom_ref, but this bundle is $sbomRoot." >&2
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
        # writes it, packed into one tarball and (by default) zstd: zstd --long
        # finds the duplicate chunks spread across NARs that per-file compression
        # can't.
        drv_args=()
        if [ -n "$drv" ]; then
          drv_args=(--drv "$drv")
        fi
        nix-airgap-tool cache --registration "$registration" "''${drv_args[@]}" \
          --out cache --stats stats
        pack() { tar --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner -C cache -cf - .; }
        if [ "$compressionKind" = zstd ]; then
          pack | zstd -q -T"$NIX_BUILD_CORES" --ultra -"$zstdLevel" --long="$zstdLong" -o "$cacheMember"
        else
          pack > "$cacheMember"
        fi
        rm -rf cache

        {
          echo "format=2"
          echo "kind=$kind"
          echo "name=$bundleName"
          cat stats
          echo "compression=$compressionKind"
          echo "cache=$cacheMember"
          echo "cache_sha256=$(sha256sum "$cacheMember" | cut -d' ' -f1)"
          echo "zstd_long=$zstdLong"
          echo "lix_tarball=''${lixTarballName:+lix/$lixTarballName}"
          echo "sbom=''${sbom:+sbom.cdx.json}"
          printf '%s' "$extraManifest"
        } > manifest
        cat manifest

        members=(stub.sh="$stub" manifest=manifest "$cacheMember=$cacheMember")
        if [ -n "$sbom" ]; then
          members+=(sbom.cdx.json=sbom.cdx.json)
        fi
        if [ -n "$lixInstaller" ]; then
          members+=(lix/lix-installer="$lixInstaller" "lix/$lixTarballName=$lixTarball")
        fi
        nix-airgap-tool polyglot --entry "$entry" --out "$out" "''${members[@]}"
        chmod 0555 "$out"
      '';

  # zstd settings for the bundled binary cache, merged over
  # { level = 19; long = 31; }. `long` is the window log: zstd can match data
  # up to 2^long bytes back, and decompressing takes about
  # min(2^long, unpacked cache size) of RAM (a ~650 MB cache peaks near
  # 650 MB, not 2 GiB). zstd won't decode windows over 2^27 (128 MiB) unless
  # told to, so the installer passes --long. long = 27 caps decompression at
  # ~128 MiB for a few percent more size (~4% on a Go dev shell).
  # null bundles the cache uncompressed, so the target doesn't need zstd.
  # (Documents the `compression` argument of the bundle functions below.)

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
      # See the zstd notes above mkDevShellBundle. null = uncompressed.
      compression ? { },
    }:
    mkBundle {
      inherit
        pkgs
        name
        includeLix
        lix
        sbom
        compression
        ;
      kind = "devshell";
      primary = shell;
      primaryName = "shell";
      runtimeRoots = [ shell.inputDerivation ] ++ lib.optional includeDirenv pkgs.direnv ++ extraPaths;
      drv = builtins.unsafeDiscardOutputDependency shell.drvPath;
      manifest = {
        drv = builtins.unsafeDiscardOutputDependency shell.drvPath;
        direnv = lib.optionalString includeDirenv "${pkgs.direnv}";
      };
      extraSbomTargets =
        lib.optionalAttrs includeDirenv { inherit (pkgs) direnv; }
        // lib.listToAttrs (lib.imap0 (i: p: lib.nameValuePair "extra-${toString i}" p) extraPaths);
      passthru = { inherit shell; };
    };

  /**
    Bundle a Home Manager configuration (the result of
    `home-manager.lib.homeManagerConfiguration`). On the air-gapped machine,
    `sh <bundle>` copies its closure into /nix/store and runs its activation
    script as the configured user, which installs `home.packages` into the
    user's profile and links the managed dotfiles.

    `home.username` and `home.homeDirectory` are fixed when the bundle is built,
    so set them to the target machine's user; the installer refuses to activate
    for anyone else. Files that are in the way of managed ones (like a stock
    ~/.bashrc) are moved aside with a backup extension (default airgap.bak).
  */
  mkHomeBundle =
    {
      pkgs,
      homeConfiguration,
      name ? "home-${homeConfiguration.config.home.username}",
      includeLix ? false,
      lix ? defaultLix,
      extraPaths ? [ ],
      # As for mkDevShellBundle, but rooted at the activation package:
      #   nix run github:Marauder586/nix-airgap#sbom -- <flakeref of this bundle>
      sbom ? null,
      compression ? { },
    }:
    let
      activation = homeConfiguration.activationPackage;
      inherit (homeConfiguration.config.home) username homeDirectory;
    in
    mkBundle {
      inherit
        pkgs
        name
        includeLix
        lix
        sbom
        compression
        ;
      kind = "home";
      primary = activation;
      primaryName = "home";
      runtimeRoots = [ activation ] ++ extraPaths;
      manifest = {
        activation = "${activation}";
        home_user = username;
        home_directory = homeDirectory;
      };
      extraSbomTargets = lib.listToAttrs (
        lib.imap0 (i: p: lib.nameValuePair "extra-${toString i}" p) extraPaths
      );
      passthru = { inherit homeConfiguration activation; };
    };

  /**
    Bundle a flake's dev shells:
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

  /**
    Bundle a flake's Home Manager configurations:
      packages = airgap.lib.bundleHomeConfigurations self { };
    gives packages.<system>.airgap-home-<name> for each homeConfigurations.<name>,
    where <system> is the configuration's own. Extra arguments are passed to
    mkHomeBundle. To combine with bundleDevShells, use lib.recursiveUpdate.
  */
  bundleHomeConfigurations =
    flake: args:
    lib.foldl' lib.recursiveUpdate { } (
      lib.mapAttrsToList (
        hmName: homeConfiguration:
        let
          inherit (homeConfiguration.activationPackage) system;
        in
        {
          ${system}."airgap-home-${hmName}" = mkHomeBundle (
            {
              pkgs = nixpkgs.legacyPackages.${system};
              inherit homeConfiguration;
              name = "home-${hmName}";
            }
            // args
          );
        }
      ) (flake.homeConfigurations or { })
    );
}
