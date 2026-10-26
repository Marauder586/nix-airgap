# Test consumer for tests/e2e.sh: a Home Manager configuration for the VM's
# "ubuntu" user, bundled with bundleHomeConfigurations, Lix and an SBOM.
# nixpkgs is pinned here (not just in a lock file) because sbomnix evaluates this
# flake on its own, and the SBOM must describe the same derivation that's bundled.
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/ed583b5bcfb5f3b7bf6164b24a62fa133682cffe";
    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    # tests/e2e.sh copies this flake and points this at the repo.
    airgap.url = "github:Marauder586/nix-airgap";
    airgap.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      airgap,
    }:
    {
      homeConfigurations.ubuntu = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        modules = [
          (
            { pkgs, ... }:
            {
              home = {
                username = "ubuntu";
                homeDirectory = "/home/ubuntu";
                stateVersion = "26.05";
                packages = [
                  pkgs.hello
                  pkgs.jq
                ];
                file.".airgap-test".text = "from-home-manager\n";
              };
              # tests/e2e.sh puts its own file here first: it must be backed up.
              xdg.configFile."airgap-test/settings.conf".text = "managed-by-home-manager\n";
              # Takes over ~/.bashrc, which Ubuntu already has: the installer
              # must move the stock one aside.
              programs.bash = {
                enable = true;
                shellAliases.airgap-test = "echo hm-alias-works";
              };
            }
          )
        ];
      };

      packages = airgap.lib.bundleHomeConfigurations self {
        # tests/e2e.sh installs this on a blank VM, so it must bring Lix.
        includeLix = true;
        # Written next to the copied flake by tests/e2e.sh with
        # `nix run .#sbom -- .#airgap-home-ubuntu`.
        sbom = ./sbom.cdx.json;
      };
    };
}
