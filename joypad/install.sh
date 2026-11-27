#!/usr/bin/env bash
# Install a Linux build of the mgba-r fork from its GitHub releases, without sudo.
#
# Usage:
#   install.sh            install the latest release
#   install.sh TAG        install release TAG (remote-<sha>), or switch back to it if kept
#   install.sh --list     show the installed builds and the current one
#
# Layout:
#   ~/.local/opt/mgba-r/<tag>/      one folder per build (bin/, lib/, share/, BUILDINFO)
#   ~/.local/opt/mgba-r/current     symlink to the build in use
#   ~/.local/bin/mgba-r             symlink to current/bin/mgba-qt
#
# The stock /usr/bin/mgba-qt is never touched or shadowed. The newest 3 builds are kept.
# joypad-mcp uses the fork with JOYPAD_MGBA=mgba-r.

set -euo pipefail

REPO=angwdev/mgba-r
OPT="${MGBA_R_HOME:-$HOME/.local/opt/mgba-r}"
BIN_DIR="${MGBA_R_BIN:-$HOME/.local/bin}"
LINK="$BIN_DIR/mgba-r"
KEEP=3
tmp=""   # download folder, removed on exit

say() { printf '%s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "needs '$1' (${2:-})"; }

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

current_tag() { [ -L "$OPT/current" ] && basename "$(readlink "$OPT/current")" || true; }

# Prints the libraries the dynamic loader cannot find (empty when the build is healthy).
missing_libs() { ldd "$1/bin/mgba-qt" 2>/dev/null | awk '/not found/ {print $1}' || true; }

# Installed build folders, newest build first (a folder keeps its build time from the archive).
builds() { find "$OPT" -mindepth 1 -maxdepth 1 -type d -name 'remote-*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-; }

info_field() { sed -n "s/^$2=//p" "$1/BUILDINFO" 2>/dev/null | head -n1; }

list() {
  local cur dir tag mark miss
  local -a dirs
  cur=$(current_tag)
  mapfile -t dirs < <(builds)
  if [ "${#dirs[@]}" -eq 0 ]; then
    say "No builds installed in $OPT."
    return
  fi
  say "Installed in $OPT (newest build first):"
  for dir in "${dirs[@]}"; do
    tag=$(basename "$dir")
    mark=" "; [ "$tag" = "$cur" ] && mark="*"
    miss=$(missing_libs "$dir" | tr '\n' ' ')
    printf ' %s %-18s %-36s upstream %.9s%s\n' "$mark" "$tag" "$(info_field "$dir" version)" \
      "$(info_field "$dir" upstream_commit)" "${miss:+  BROKEN, missing: $miss}"
  done
  [ -n "$cur" ] && say "* current; run it as: $LINK"
}

activate() {
  local tag=$1 tmp
  tmp="$OPT/.current.$$"
  ln -s "$tag" "$tmp"
  mv -T "$tmp" "$OPT/current"
  mkdir -p "$BIN_DIR"
  if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
    die "$LINK exists and is not a symlink; move it away first"
  fi
  ln -sfn "$OPT/current/bin/mgba-qt" "$LINK"
}

prune() {
  local cur n=0 dir
  local -a dirs
  cur=$(current_tag)
  mapfile -t dirs < <(builds)
  for dir in "${dirs[@]}"; do
    n=$((n + 1))
    if [ "$n" -gt "$KEEP" ] && [ "$(basename "$dir")" != "$cur" ]; then
      say "Removing old build $(basename "$dir")"
      rm -rf -- "$dir"
    fi
  done
}

report() {
  local tag=$1 notes fork up
  notes=$(gh release view "$tag" -R "$REPO" --json body --jq .body 2>/dev/null || true)
  # shellcheck disable=SC2016
  fork=$(printf '%s\n' "$notes" | sed -n 's/^| Fork commit | `\([0-9a-f]*\)`.*/\1/p')
  # shellcheck disable=SC2016
  up=$(printf '%s\n' "$notes" | sed -n 's/^| Upstream commit | `\([0-9a-f]*\)`.*/\1/p')
  say "Tag:             $tag"
  say "Fork commit:     ${fork:-$(info_field "$OPT/$tag" fork_commit)}"
  say "Upstream commit: ${up:-$(info_field "$OPT/$tag" upstream_commit)}"
  say "Version:         $("$LINK" --version 2>/dev/null | head -n1 | cut -d' ' -f2- || info_field "$OPT/$tag" version)"
  say "Program:         $LINK -> $(readlink -f "$LINK")"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) say "Note: $BIN_DIR is not on your PATH; use the full path, or JOYPAD_MGBA=$LINK." ;;
  esac
}

main() {
  local tag="" arg miss
  for arg in "$@"; do
    case "$arg" in
      -h|--help) usage; exit 0 ;;
      --list) list; exit 0 ;;
      -*) die "unknown option $arg (try --help)" ;;
      *) [ -z "$tag" ] || die "give at most one tag"; tag=$arg ;;
    esac
  done

  need gh "github-cli"; need tar; need zstd; need sha256sum; need ldd
  mkdir -p "$OPT"

  if [ -z "$tag" ]; then
    tag=$(gh release view -R "$REPO" --json tagName --jq .tagName) || die "cannot read the latest release of $REPO"
  fi
  case "$tag" in remote-*) ;; *) die "'$tag' is not a release tag of the form remote-<sha>" ;; esac

  if [ -d "$OPT/$tag" ]; then
    miss=$(missing_libs "$OPT/$tag")
    # shellcheck disable=SC2086  # one library name per word
    [ -z "$miss" ] || die "$tag is installed but broken (missing: $(printf '%s ' $miss)); an Arch update probably changed a library. Install a newer build, or rebuild: gh workflow run build-linux.yml -R $REPO"
    if [ "$(current_tag)" = "$tag" ] && [ "$(readlink "$LINK" 2>/dev/null)" = "$OPT/current/bin/mgba-qt" ]; then
      say "$tag is already installed and current."
      report "$tag"
      exit 0
    fi
    activate "$tag"
    say "Switched to the installed build $tag."
    report "$tag"
    exit 0
  fi

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/mgba-r-install.XXXXXX")
  trap '[ -z "$tmp" ] || rm -rf -- "$tmp"' EXIT

  say "Downloading $tag from $REPO..."
  gh release download "$tag" -R "$REPO" -D "$tmp" -p '*.tar.zst' -p SHA256SUMS
  (cd "$tmp" && sha256sum --check --strict SHA256SUMS) || die "SHA256SUMS does not match; nothing installed"

  mkdir -p "$tmp/unpack"
  tar --zstd -xf "$tmp"/*.tar.zst -C "$tmp/unpack"
  [ -x "$tmp/unpack/$tag/bin/mgba-qt" ] || die "the archive has no $tag/bin/mgba-qt"

  [ ! -e "$OPT/$tag" ] || die "$OPT/$tag appeared while installing; not overwriting it"
  mv -T "$tmp/unpack/$tag" "$OPT/$tag"

  miss=$(missing_libs "$OPT/$tag")
  if [ -n "$miss" ]; then
    rm -rf -- "${OPT:?}/$tag"
    # shellcheck disable=SC2086
    die "this build needs libraries your system does not have: $(printf '%s ' $miss). Update Arch (yay -Syu) or rebuild: gh workflow run build-linux.yml -R $REPO"
  fi

  activate "$tag"
  prune
  say "Installed $tag."
  report "$tag"
}

main "$@"
