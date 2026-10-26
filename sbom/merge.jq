# Merges the SBOMs of a bundle's parts into one, keeping the shell's as the base.
#
# Input (jq -s): [shell SBOM, SBOMs of direnv / extra paths ...]
# $lix[0]: null, or lix.jq's {roots, components, dependencies}.
#
# Each extra SBOM's root (metadata.component) becomes a component, and every
# extra root is added to the shell root's dependsOn, so the dependency graph
# reaches everything in the bundle from the SBOM's root.

def unique_by_ref: group_by(."bom-ref") | map(.[0]);

.[0] as $base
| .[1:] as $parts
| ($lix[0] // {roots: [], components: [], dependencies: []}) as $lx
| $base.metadata.component."bom-ref" as $root
| ([$parts[].metadata.component."bom-ref"] + $lx.roots) as $extra_roots
| $base
| .components = (
    (.components // [])
    + [$parts[] | .metadata.component, (.components // [])[]]
    + $lx.components
    | unique_by_ref
  )
| .dependencies = (
    (.dependencies // [])
    + [$parts[] | (.dependencies // [])[]]
    + $lx.dependencies
    + [{ref: $root, dependsOn: $extra_roots}]
    | group_by(.ref)
    | map({ref: .[0].ref, dependsOn: ([.[].dependsOn[]?] | unique)})
  )
| .metadata.properties = (
    (.metadata.properties // [])
    + [{name: "nix-airgap:bundle-parts", value: ([$root] + $extra_roots | join(" "))}]
  )
