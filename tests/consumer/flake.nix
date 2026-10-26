# Test consumer for tests/e2e.sh: exercises bundleDevShells with every option on.
# nixpkgs is pinned here (not just in a lock file) because sbomnix evaluates this
# flake on its own, and the SBOM must describe the same derivation that's bundled.
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/ed583b5bcfb5f3b7bf6164b24a62fa133682cffe";
    # tests/e2e.sh copies this flake and points this at the repo.
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
      devShells.x86_64-linux.default = pkgs.mkShell { packages = [ pkgs.go ]; };

      packages = airgap.lib.bundleDevShells self {
        includeLix = true;
        includeDirenv = true;
        # Written next to the copied flake by tests/e2e.sh with
        # `nix run .#sbom -- .#airgap-default`.
        sbom = ./sbom.cdx.json;
      };
    };
}
