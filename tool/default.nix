{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "nix-airgap-tool";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./README.md
      ./clippy.toml
      ./src
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;

  meta = {
    description = "Builds self-installing tar/sh polyglot bundles of Nix store closures";
    license = lib.licenses.mit;
    mainProgram = "nix-airgap-tool";
  };
}
