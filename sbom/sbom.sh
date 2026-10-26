# shellcheck shell=bash
# nix run .#sbom -- [BUNDLE] [OUT]
#
# Writes one CycloneDX SBOM (default ./sbom.cdx.json) of everything the bundle
# BUNDLE (a flakeref, default .#airgap) ships, for mkDevShellBundle's `sbom`:
#
#   - the dev shell, direnv and each extra path: scanned by sbomnix, the way the
#     guide does it, from the bundle's `airgapSbom.targets` attribute. These must
#     be flakerefs (not store paths) so sbomnix adds nixpkgs metadata.
#   - Lix: the installer and release tarball are downloaded from Lix, not built
#     from this flake, so they are described from their pinned files (version,
#     URL, sha256) along with the store paths inside the tarball.
#
# The shell's SBOM is the base, so the result's root is still the shell's .drv;
# everything else is merged in and hung off that root in `dependencies`.
# writeShellApplication runs this with errexit, nounset and pipefail.
# Provided by lib/default.nix: LIX_JQ, MERGE_JQ.

ref=${1:-.#airgap}
out=$(realpath -m "${2:-sbom.cdx.json}")

# sbomnix runs from a temporary directory (it leaves caches and other formats
# behind), so make a local flake path absolute first.
flake=${ref%%#*}
if [[ $flake != *:* ]]; then
  ref="$(realpath "${flake:-.}")${ref#"$flake"}"
fi

if ! targets=$(nix eval --json "$ref.airgapSbom.targets" --apply builtins.attrNames); then
  echo "nix-airgap-sbom: couldn't read $ref.airgapSbom; is $ref a nix-airgap bundle?" >&2
  echo "nix-airgap-sbom: usage: nix run .#sbom -- <flakeref of the bundle, e.g. .#airgap> [out]" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

parts=()
for name in $(jq -r '.[]' <<<"$targets"); do
  echo "nix-airgap-sbom: scanning $name with sbomnix" >&2
  (cd "$tmp" && sbomnix "$ref.airgapSbom.targets.$name" --cdx "$tmp/$name.cdx.json")
  [[ $name == shell ]] || parts+=("$tmp/$name.cdx.json")
done

lix=$(nix eval --json "$ref.airgapSbom.lix")
echo null >"$tmp/lix.json"
if [[ $lix != null ]]; then
  echo "nix-airgap-sbom: describing the bundled Lix installer and tarball" >&2
  installer=$(nix build --no-link --print-out-paths "$ref.airgapSbom.lix.installer.file")
  tarball=$(nix build --no-link --print-out-paths "$ref.airgapSbom.lix.tarball.file")
  tar -tJf "$tarball" | sed -n 's|^[^/]*/store/\([^/]*\)/$|/nix/store/\1|p' | sort -u >"$tmp/lix-paths"
  jq -n \
    --argjson lix "$lix" \
    --arg installer_sha256 "$(sha256sum "$installer" | cut -d' ' -f1)" \
    --arg tarball_sha256 "$(sha256sum "$tarball" | cut -d' ' -f1)" \
    --rawfile paths "$tmp/lix-paths" \
    -f "$LIX_JQ" >"$tmp/lix.json"
fi

jq -s --slurpfile lix "$tmp/lix.json" -f "$MERGE_JQ" \
  "$tmp/shell.cdx.json" "${parts[@]}" >"$out"
echo "wrote $out ($(jq '.components | length' "$out") components)"
