#!/usr/bin/env bash
# SoundCast installer for the downloaded release.
# Run in Terminal:  bash ~/Downloads/SoundCast-*/install.sh
# Copies SoundCast.app to /Applications, installs the SoundCast audio
# driver (asks for your Mac password once) and starts the app.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SRC="$HERE/SoundCast.app"
DRV_SRC="$HERE/SoundCast.driver"
APP_DST="/Applications/SoundCast.app"
DRV_DST="/Library/Audio/Plug-Ins/HAL/SoundCast.driver"

if [[ "$(uname -m)" != "x86_64" ]] || sysctl -n sysctl.proc_translated 2>/dev/null | grep -q 1; then
  echo "This version of SoundCast supports Intel Macs only (this Mac has Apple silicon)." >&2
  exit 1
fi
if [[ ! -d "$APP_SRC" || ! -d "$DRV_SRC" ]]; then
  echo "SoundCast.app or SoundCast.driver is missing next to this script." >&2
  echo "Unzip the whole download and run install.sh from inside that folder." >&2
  exit 1
fi

echo "This will:"
echo "  1. Copy SoundCast.app to /Applications"
echo "  2. Install the SoundCast audio driver (needs your password)"
echo "  3. Restart the Mac's audio system (sound stops for a few seconds)"
echo "  4. Start SoundCast"
read -p "Continue? [y/N] " -n 1 -r REPLY; echo
[[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

if pgrep -x SoundCast >/dev/null; then
  echo "== Quitting the running SoundCast =="
  osascript -e 'quit app "SoundCast"' >/dev/null 2>&1 || true
  sleep 2
fi

echo "== Installing the app =="
if [[ -w /Applications ]]; then
  rm -rf "$APP_DST"; ditto "$APP_SRC" "$APP_DST"
else
  sudo rm -rf "$APP_DST"; sudo ditto "$APP_SRC" "$APP_DST"
fi
# Downloaded files are marked "from the internet"; clear that so macOS
# doesn't block this self-signed (not notarized) app.
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || sudo xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true

echo "== Installing the driver (password) =="
sudo rm -rf "$DRV_DST"
sudo ditto "$DRV_SRC" "$DRV_DST"
sudo xattr -dr com.apple.quarantine "$DRV_DST" 2>/dev/null || true
sudo xattr -dr com.apple.provenance "$DRV_DST" 2>/dev/null || true
sudo chown -R root:wheel "$DRV_DST"

echo "== Restarting the audio system =="
sudo killall coreaudiod
sleep 4

if system_profiler SPAudioDataType 2>/dev/null | grep -q "SoundCast"; then
  echo "Driver loaded: the SoundCast output is available."
else
  echo "WARNING: macOS did not load the SoundCast driver."
  echo "SoundCast still works, but captures all Mac audio instead"
  echo "(no volume keys or lip-sync on the SoundCast output)."
fi

echo "== Starting SoundCast =="
open "$APP_DST"
echo
echo "Done. Look for the SoundCast icon in the menu bar."
echo "First run: allow Local Network access (needed for Apple TV and Sonos)."
