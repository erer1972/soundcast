#!/usr/bin/env bash
# Remove the installed SoundCast.driver and restart coreaudiod.
# Needs sudo — run this yourself in your own terminal (don't pass your
# password through anything else). Also removes the earlier go/no-go
# test driver and the shared-memory buffers the driver created.
set -euo pipefail

DRIVER_NAME="SoundCast"
INSTALL_PATH="/Library/Audio/Plug-Ins/HAL/${DRIVER_NAME}.driver"
OLD_TEST_DRIVER_PATH="/Library/Audio/Plug-Ins/HAL/SoundCastNullDriver.driver"
SHM_NAMES=(
  /soundcast_output_v1
  /soundcast_output_preset1
  /soundcast_output_preset2
  /soundcast_output_preset3
  /soundcast_output_preset4
)

if [[ ! -d "$INSTALL_PATH" && ! -d "$OLD_TEST_DRIVER_PATH" ]]; then
  echo "Nothing to uninstall: neither ${INSTALL_PATH} nor ${OLD_TEST_DRIVER_PATH} exists."
  exit 0
fi

echo "This will:"
echo "  1. sudo-remove ${INSTALL_PATH} (and ${OLD_TEST_DRIVER_PATH}, if present)"
echo "  2. sudo killall coreaudiod — restarts the system audio daemon, which"
echo "     briefly interrupts any audio currently playing on this Mac"
echo "  3. Remove SoundCast's shared-memory buffers (left behind by the driver)"
echo
echo "Quit SoundCast.app first if it is running (menu bar icon -> Quit SoundCast)."
echo
read -p "Proceed? [y/N] " -n 1 -r REPLY
echo
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# If a SoundCast virtual device is the default output, coreaudiod would
# fall back unpredictably once it vanishes — warn rather than guess.
if system_profiler SPAudioDataType 2>/dev/null | grep -B1 "Default Output Device: Yes" | grep -q "SoundCast"; then
  echo
  echo "WARNING: a SoundCast device is currently your default output."
  echo "Pick another output in System Settings -> Sound first, then re-run."
  exit 1
fi

echo "== Removing driver (sudo) =="
sudo rm -rf "$OLD_TEST_DRIVER_PATH"
sudo rm -rf "$INSTALL_PATH"

echo "== Restarting coreaudiod (sudo) =="
sudo killall coreaudiod
sleep 3

echo "== Removing shared-memory buffers =="
# POSIX shm objects are owned by the audio daemon's user, so removing them
# needs sudo too. macOS has no /dev/shm to rm from, so call shm_unlink()
# directly. Missing ones are fine.
sudo /usr/bin/python3 - "${SHM_NAMES[@]}" <<'PY' || true
import ctypes, ctypes.util, sys
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
for name in sys.argv[1:]:
    rc = libc.shm_unlink(name.encode())
    print(("removed " if rc == 0 else "not present ") + name)
PY

echo
echo "== Results =="
[[ -d "$INSTALL_PATH" ]] && echo "STILL PRESENT: ${INSTALL_PATH}" || echo "driver removed"
pgrep -x coreaudiod >/dev/null && echo "coreaudiod is running" || echo "NO coreaudiod — check Console.app"
echo "Done. To reinstall later: ./build_and_test.sh && ./install_and_check.sh"
