{
  description = "Dev shell with an air-gap bundle";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    airgap.url = "github:Marauder586/nix-airgap";
    airgap.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      airgap,
    }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [ pkgs.go ];
      };

      # nix build .#airgap, then on the air-gapped machine: sh result [project-dir]
      packages.x86_64-linux.airgap = airgap.lib.mkDevShellBundle {
        inherit pkgs;
        shell = self.devShells.x86_64-linux.default;
        # includeLix = true;    # also install Lix on machines without Nix
        # includeDirenv = true; # ship direnv for the generated .envrc
        # Bundle a CycloneDX SBOM of everything in the bundle (`sh result --sbom`
        # extracts it). Make it, and remake it whenever the bundle changes, with
        #   nix run github:Marauder586/nix-airgap#sbom -- .#airgap
        # sbom = ./sbom.cdx.json;
      };
    };
}
