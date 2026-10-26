# CycloneDX components for the Lix a bundle embeds (includeLix).
#
# Inputs: $lix ({version, installer: {url, version}, tarball: {url}}),
# $installer_sha256 and $tarball_sha256 (hex), and $paths (the store paths in
# the tarball, one per line).
# Output: {roots, components, dependencies} for merge.jq.

# A store path as a component, splitting "name-1.2.3" the way Nix does.
def store_component:
  (sub("^/nix/store/[0-9a-z]{32}-"; "")) as $base
  | ($base | capture("^(?<name>.+?)-(?<version>[0-9].*)$") // {name: $base}) as $nv
  | {
      type: "library",
      "bom-ref": .,
      name: $nv.name,
      properties: [
        {name: "nix:output_path", value: .},
        {name: "nix-airgap:part-of", value: "lix-tarball"}
      ]
    }
  + (if $nv.version then {version: $nv.version} else {} end);

($paths | split("\n") | map(select(. != ""))) as $store_paths
| {
    roots: ["lix-installer", "lix-tarball"],
    components: [
      {
        type: "application",
        "bom-ref": "lix-installer",
        name: "lix-installer",
        version: $lix.installer.version,
        description: "Lix installer, downloaded from Lix (not built from this flake)",
        hashes: [{alg: "SHA-256", content: $installer_sha256}],
        externalReferences: [{type: "distribution", url: $lix.installer.url}]
      },
      {
        type: "application",
        "bom-ref": "lix-tarball",
        name: "lix",
        version: $lix.version,
        description: "Lix release tarball the installer unpacks into /nix/store",
        hashes: [{alg: "SHA-256", content: $tarball_sha256}],
        externalReferences: [{type: "distribution", url: $lix.tarball.url}]
      }
    ] + ($store_paths | map(store_component)),
    dependencies: [{ref: "lix-tarball", dependsOn: $store_paths}]
  }
