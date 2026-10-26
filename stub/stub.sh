# nix-airgap installer.
#
# This runs from inside the bundle. The bundle's first tar header is the line
#   :;sh -c "$(tar -xOf "$0" stub.sh)" airgap "$0" "$@";exit
# so "$1" here is the bundle itself. Everything bundle-specific comes from the
# `manifest` member. Keep this POSIX sh: /bin/sh is dash on Debian and Ubuntu.
set -eu

BUNDLE=$1
shift
NIX_BIN=/nix/var/nix/profiles/default/bin

info() { printf 'airgap: %s\n' "$*" >&2; }
die() {
  printf 'airgap: error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: sh $BUNDLE [options] [project-dir]   (dev shell bundles)
       sh $BUNDLE [options]                 (Home Manager bundles)
       sh $BUNDLE --sbom [dir]

Copies the bundle's store paths into /nix/store with \`nix copy\` (installing
Lix first if the bundle includes it and Nix is missing). The binary cache is
unpacked under \$TMPDIR (default /tmp) first. Then:
  - a dev shell bundle writes an .envrc into project-dir (default: the current
    directory) that loads the shell offline;
  - a Home Manager bundle runs the configuration's activation as you, which
    must be the user it was built for.

Options:
  --dry-run          print what would be done without changing anything
  --list             list the bundle contents
  --sbom             only extract the bundled CycloneDX SBOM (sbom.cdx.json)
                     into dir (default: the current directory); needs only tar
  --force            replace an existing .envrc that nix-airgap did not write
  --no-envrc         only import the store paths (dev shell bundles)
  --backup-ext EXT   Home Manager bundles: rename files that are in the way of
                     managed ones to FILE.EXT (default: airgap.bak)
  -h, --help         show this help
EOF
}

dry_run=0
sbom_only=0
force=0
write_envrc=1
backup_ext=airgap.bak
dir=.
dir_given=0
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) dry_run=1 ;;
    --list)
      tar -tvf "$BUNDLE"
      exit 0
      ;;
    --sbom) sbom_only=1 ;;
    --force) force=1 ;;
    --no-envrc) write_envrc=0 ;;
    --backup-ext)
      [ $# -ge 2 ] || die "--backup-ext needs a value"
      shift
      backup_ext=$1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown option '$1' (see --help)" ;;
    *)
      dir=$1
      dir_given=1
      ;;
  esac
  shift
done

run() {
  if [ "$dry_run" = 1 ]; then
    printf '+ %s\n' "$*" >&2
  else
    "$@"
  fi
}

command -v tar >/dev/null 2>&1 || die "'tar' is required but not installed"
MANIFEST=$(tar -xOf "$BUNDLE" manifest) || die "$BUNDLE has no manifest; is it a nix-airgap bundle?"
manifest() { printf '%s\n' "$MANIFEST" | sed -n "s/^$1=//p"; }

if [ "$sbom_only" = 1 ]; then
  SBOM=$(manifest sbom)
  [ -n "$SBOM" ] || die "this bundle has no SBOM (build it with mkDevShellBundle's sbom option)"
  if [ -e "$dir/$SBOM" ] && [ "$force" = 0 ]; then
    die "$dir/$SBOM already exists (--force replaces it)"
  fi
  run mkdir -p "$dir"
  run tar -xmf "$BUNDLE" -C "$dir" "$SBOM"
  info "extracted $dir/$SBOM"
  exit 0
fi

NAME=$(manifest name)
# Bundles made before `kind` existed are dev shells.
KIND=$(manifest kind)
KIND=${KIND:-devshell}
DRV=$(manifest drv)
CACHE_SHA256=$(manifest cache_sha256)
NAR_SIZE=$(manifest nar_size)
PATHS=$(manifest paths)
ZSTD_LONG=$(manifest zstd_long)
# Bundles made before `compression` existed are always zstd.
COMPRESSION=$(manifest compression)
COMPRESSION=${COMPRESSION:-zstd}
CACHE=$(manifest cache)
CACHE=${CACHE:-cache.tar.zst}
case $COMPRESSION in
  zstd) required="zstd sha256sum" ;;
  none) required="sha256sum" ;;
  *) die "unsupported cache compression '$COMPRESSION'; is this a newer nix-airgap bundle?" ;;
esac
for cmd in $required; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed"
done
LIX_TARBALL=$(manifest lix_tarball)
DIRENV=$(manifest direnv)
[ -n "$CACHE_SHA256" ] || die "this bundle was made by an older nix-airgap (no binary cache); rebuild it"
case $KIND in
  devshell)
    [ -n "$DRV" ] || die "manifest has no drv"
    PRIMARY=$DRV
    # Short id used for this shell's files and GC roots.
    ID=$(basename "$DRV" | cut -c1-12)
    ;;
  home)
    ACTIVATION=$(manifest activation)
    HOME_USER=$(manifest home_user)
    HOME_DIRECTORY=$(manifest home_directory)
    [ -n "$ACTIVATION" ] || die "manifest has no activation package"
    PRIMARY=$ACTIVATION
    [ "$dir_given" = 0 ] || die "Home Manager bundles don't take a project directory"
    # Checked before anything is installed: activation is only valid for the
    # user and home directory the configuration was built for.
    me=$(id -un)
    [ "$me" = "$HOME_USER" ] ||
      die "this Home Manager configuration is for user '$HOME_USER', but you are '$me'; rebuild it with home.username and home.homeDirectory set for this machine"
    [ "${HOME:-}" = "$HOME_DIRECTORY" ] ||
      die "this Home Manager configuration is for home directory '$HOME_DIRECTORY', but \$HOME is '${HOME:-}'"
    ;;
  *) die "unsupported bundle kind '$KIND'; is this a newer nix-airgap bundle?" ;;
esac

if [ "$(id -u)" -eq 0 ]; then
  SUDO=
else
  command -v sudo >/dev/null 2>&1 || die "'sudo' is required to import into /nix/store"
  SUDO=sudo
fi

info "bundle: $NAME ($PATHS store paths, $((NAR_SIZE / 1048576)) MiB unpacked)"

nix() { "$NIX_BIN/nix" --extra-experimental-features nix-command "$@"; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# -- 1. Nix
if [ ! -x "$NIX_BIN/nix" ]; then
  [ -n "$LIX_TARBALL" ] || die "Nix is not installed and this bundle has no Lix installer (rebuild it with includeLix = true)"
  info "Nix not found; installing Lix from the bundle"
  tar -xf "$BUNDLE" -C "$tmp" lix
  chmod +x "$tmp/lix/lix-installer"
  run $SUDO "$tmp/lix/lix-installer" install \
    --nix-package-url "file://$tmp/$LIX_TARBALL" --enable-flakes --no-confirm
fi

# -- 2. Space: the unpacked cache under $TMPDIR, then the same again in the
# store (an upper bound: paths already in the store are skipped).
fs_of() { df -Pk "$1" | awk 'NR == 2 { print $1 }'; }
avail_kb() { df -Pk "$1" | awk 'NR == 2 { print $4 }'; }
store_fs=/nix
[ -d "$store_fs" ] || store_fs=/
need_kb=$((NAR_SIZE / 1024))
if [ "$(fs_of "$tmp")" = "$(fs_of "$store_fs")" ]; then
  checks="$store_fs:$((2 * need_kb))"
else
  checks="$tmp:$need_kb $store_fs:$need_kb"
fi
for check in $checks; do
  where=${check%:*}
  need=${check##*:}
  avail=$(avail_kb "$where")
  [ "$avail" -gt "$need" ] ||
    die "need up to $((need / 1024)) MiB free for $where, only $((avail / 1024)) MiB available (set TMPDIR to unpack elsewhere)"
done

# -- 3. Verify
info "verifying checksum"
actual=$(tar -xOf "$BUNDLE" "$CACHE" | sha256sum | cut -d' ' -f1)
[ "$actual" = "$CACHE_SHA256" ] || die "$CACHE checksum mismatch; the bundle is corrupted"

# -- 4. Unpack the binary cache and nix copy it into the store. The cache is
# not signed, hence --no-check-sigs; the checksum above covers integrity. The
# paths are listed explicitly because with --all, Lix only learns each path's
# hash from the cache, can't order paths by their references, and fails.
# Writes the bundled cache tarball to stdout, decompressed.
cache_tar() {
  if [ "$COMPRESSION" = zstd ]; then
    tar -xOf "$BUNDLE" "$CACHE" | zstd -dcq --long="$ZSTD_LONG"
  else
    tar -xOf "$BUNDLE" "$CACHE"
  fi
}
info "unpacking the binary cache"
if [ "$dry_run" = 1 ]; then
  if [ "$COMPRESSION" = zstd ]; then
    info "+ tar -xOf $BUNDLE $CACHE | zstd -dc --long=$ZSTD_LONG | tar -x -C $tmp/cache"
  else
    info "+ tar -xOf $BUNDLE $CACHE | tar -x -C $tmp/cache"
  fi
  info "+ $SUDO nix copy --no-check-sigs --from file://$tmp/cache --stdin < $tmp/cache/store-paths"
else
  mkdir "$tmp/cache"
  cache_tar | tar -xf - -C "$tmp/cache"
  info "copying store paths into /nix/store"
  $SUDO "$NIX_BIN/nix" --extra-experimental-features nix-command \
    copy --no-check-sigs --from "file://$tmp/cache" --stdin <"$tmp/cache/store-paths"
  rm -rf "$tmp/cache"
  nix path-info "$PRIMARY" >/dev/null 2>&1 || die "nix copy finished but $PRIMARY is not in the store"
fi

# -- 5h. Home Manager: activate as the user. Activation installs home.packages
# into the user's profile, links the managed files and roots the generation.
if [ "$KIND" = home ]; then
  info "activating Home Manager for $HOME_USER (files in the way are renamed to FILE.$backup_ext)"
  run env PATH="$NIX_BIN:$PATH" HOME_MANAGER_BACKUP_EXT="$backup_ext" "$ACTIVATION/activate"
  info "done. Start a new login shell to pick up the new environment."
  exit 0
fi

# -- 5. direnv
if [ -n "$DIRENV" ] && ! command -v direnv >/dev/null 2>&1; then
  info "installing direnv into your Nix profile"
  run nix profile install "$DIRENV"
  info "add this to ~/.bashrc to enable it: eval \"\$(direnv hook bash)\""
fi

if [ "$write_envrc" = 0 ]; then
  info "done (no .envrc written). Activate with:"
  info "  eval \"\$(nix --extra-experimental-features nix-command print-dev-env --option substitute false $DRV)\""
  exit 0
fi

# -- 6. .envrc
run mkdir -p "$dir/.direnv"
envrc=$dir/.envrc
if [ -e "$envrc" ] && ! grep -q '^# nix-airgap:' "$envrc" && [ "$force" = 0 ]; then
  envrc=$dir/.envrc.airgap
  info "$dir/.envrc exists and was not written by nix-airgap; writing $envrc instead (--force replaces it)"
fi
info "writing $envrc"
if [ "$dry_run" = 0 ]; then
  cat >"$envrc" <<EOF
# nix-airgap: $NAME dev shell (generated; safe to delete and regenerate)
# Load it with \`direnv allow\`, or \`source .envrc\` from bash.
airgap_dir=\$(cd "\$(dirname "\${BASH_SOURCE[0]:-.envrc}")" && pwd)
airgap_cache=\$airgap_dir/.direnv/airgap-$ID-env.sh
if [ ! -s "\$airgap_cache" ]; then
  airgap_nix=\$(command -v nix || echo $NIX_BIN/nix)
  "\$airgap_nix" --extra-experimental-features nix-command print-dev-env --option substitute false \\
    --profile "\$airgap_dir/.direnv/airgap-$ID-profile" $DRV \\
    >"\$airgap_cache.tmp" && mv "\$airgap_cache.tmp" "\$airgap_cache"
fi
source "\$airgap_cache"
unset airgap_dir airgap_cache airgap_nix
EOF
fi

# -- 7. GC roots: the --profile above roots the built environment; this roots
# the shell's .drv so the cache can be rebuilt after a garbage collection.
# The root is indirect, so deleting the project directory releases it.
run ln -sfn "$DRV" "$dir/.direnv/airgap-$ID-drv"
if [ "$dry_run" = 0 ]; then
  link=$(cd "$dir/.direnv" && pwd)/airgap-$ID-drv
  root_name=airgap-$(printf '%s' "$link" | sha256sum | cut -c1-32)
  $SUDO ln -sfn "$link" "/nix/var/nix/gcroots/auto/$root_name"
fi

# -- 8. Build the environment once now, which also proves it works offline.
if [ "$dry_run" = 0 ] && command -v bash >/dev/null 2>&1; then
  info "building the shell environment"
  rm -f "$dir/.direnv/airgap-$ID-env.sh"
  bash -c 'source "$1" >/dev/null' airgap "$envrc"
fi

info "done. To use the shell:"
if command -v direnv >/dev/null 2>&1 || [ -n "$DIRENV" ]; then
  info "  cd $dir && direnv allow"
else
  info "  cd $dir && source $(basename "$envrc")   # from bash"
fi
