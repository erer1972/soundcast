#!/usr/bin/env bash
# Remove SoundCast.app and the SoundCast audio driver.
# Run in Terminal:  bash ~/Downloads/SoundCast-*/uninstall.sh
set -euo pipefail
APP_DST="/Applications/SoundCast.app"
DRV_DST="/Library/Audio/Plug-Ins/HAL/SoundCast.driver"

echo "This removes SoundCast.app and its audio driver (needs your password)."
read -p "Continue? [y/N] " -n 1 -r REPLY; echo
[[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

if pgrep -x SoundCast >/dev/null; then
  # Quitting SoundCast puts your previous sound output back.
  osascript -e 'quit app "SoundCast"' >/dev/null 2>&1 || true
  sleep 2
fi
rm -rf "$APP_DST" 2>/dev/null || sudo rm -rf "$APP_DST"
if [[ -d "$DRV_DST" ]]; then
  sudo rm -rf "$DRV_DST"
  sudo killall coreaudiod
  sleep 3
fi
sudo /usr/bin/python3 - <<'PY' || true
import ctypes, ctypes.util
libc = ctypes.CDLL(ctypes.util.find_library("c"))
libc.shm_unlink(b"/soundcast_output_v1")
PY
echo "SoundCast removed."
