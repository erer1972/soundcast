#!/usr/bin/env bash
# Copy this source tree to the Mac Pro (and optionally build it there).
# Run on the development machine, not on the Mac.
#
#   ./sync.sh                 copy changed files
#   ./sync.sh --build         copy, then ./build.sh and HALPlugin/build_and_test.sh on the Mac
#   ./sync.sh --dry-run       show what would change, copy nothing
#   ./sync.sh --force         copy even if the Mac has NEWER versions of some files
#
# Environment: MAC_HOST (default "macpro", an ssh alias), MAC_DIR (default "soundcast",
# relative to the remote home directory).
#
# Safety: if a file on the Mac is newer than the local copy, that usually
# means it was edited there by hand. The script lists such files and stops
# instead of overwriting them, unless --force is given. Build output
# (.build, dist) and compiled test binaries are never copied or deleted.
set -euo pipefail
export LC_ALL=C
cd "$(dirname "${BASH_SOURCE[0]}")"

MAC_HOST="${MAC_HOST:-macpro}"
MAC_DIR="${MAC_DIR:-soundcast}"
DO_BUILD=0; DRY=0; FORCE=0
for arg in "$@"; do
  case "$arg" in
    --build) DO_BUILD=1 ;;
    --dry-run) DRY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

EXCLUDES=(--exclude '.build/' --exclude 'dist/' --exclude 'HALPlugin/dist/' \
          --exclude 'HALPlugin/test_shm_flow' --exclude '.git/' --exclude '.DS_Store' \
          --exclude '.swiftpm/')
DEST="${MAC_HOST}:${MAC_DIR}/"

if ! ssh -o ConnectTimeout=8 -o BatchMode=yes "$MAC_HOST" true 2>/dev/null; then
  echo "Can't reach ${MAC_HOST} over ssh (asleep, off the network, or key not loaded)." >&2
  exit 1
fi

# Files that differ by content...
changed=$(rsync -rcn --itemize-changes "${EXCLUDES[@]}" ./ "$DEST" | grep -E '^[<>]f' | cut -c13- | sort || true)
# ...minus the ones rsync would copy if only older remote files were replaced.
# What's left differs AND is newer on the Mac.
would_copy=$(rsync -rcn --update --itemize-changes "${EXCLUDES[@]}" ./ "$DEST" | grep -E '^[<>]f' | cut -c13- | sort || true)
remote_newer=$(comm -23 <(printf '%s\n' "$changed") <(printf '%s\n' "$would_copy") | sed '/^$/d' || true)

if [[ -z "$changed" ]]; then
  echo "Mac Pro is already up to date."
else
  echo "Files that differ:"; printf '  %s\n' $changed
fi

if [[ -n "$remote_newer" && $FORCE -eq 0 ]]; then
  echo
  echo "STOPPED: these are NEWER on the Mac than here (edited there?):"
  printf '  %s\n' $remote_newer
  echo "Copy them back first (e.g. scp ${MAC_HOST}:${MAC_DIR}/<file> <file>), or re-run with --force to overwrite."
  exit 1
fi

if [[ $DRY -eq 1 ]]; then echo "(dry run — nothing copied)"; exit 0; fi

if [[ -n "$changed" ]]; then
  rsync -rct "${EXCLUDES[@]}" ./ "$DEST"
  echo "Copied."
fi

if [[ $DO_BUILD -eq 1 ]]; then
  echo "== Building app on ${MAC_HOST} =="
  ssh "$MAC_HOST" "cd ${MAC_DIR} && ./build.sh" 2>&1 | grep -E 'error|warning:|Build complete|Built:|OK:|FAIL|Westmere' || true
  echo "== Building driver on ${MAC_HOST} (not installed) =="
  ssh "$MAC_HOST" "cd ${MAC_DIR}/HALPlugin && ./build_and_test.sh" 2>&1 | grep -E 'error|warning:|OK:|Built|FAIL' || true
  echo "Install the driver yourself on the Mac: cd ~/${MAC_DIR}/HALPlugin && ./install_and_check.sh"
fi
