#!/usr/bin/env bash
# Install the already-built SoundCast.driver (design doc §7.1/§7.3's
# real single-device virtual output, now that §7.2's go/no-go test
# confirmed self-signed loading works on this Mac) and restart
# coreaudiod. Needs sudo — run this yourself (don't type your password
# through anything other than your own terminal).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

DRIVER_NAME="SoundCast"
BUNDLE="dist/${DRIVER_NAME}.driver"
INSTALL_PATH="/Library/Audio/Plug-Ins/HAL/${DRIVER_NAME}.driver"
OLD_TEST_DRIVER_PATH="/Library/Audio/Plug-Ins/HAL/SoundCastNullDriver.driver"

if [[ ! -d "$BUNDLE" ]]; then
  echo "Run ./build_and_test.sh first — ${BUNDLE} doesn't exist yet." >&2
  exit 1
fi

echo "This will:"
echo "  1. sudo-copy ${BUNDLE} to ${INSTALL_PATH}"
echo "  2. Strip the com.apple.provenance extended attribute (known install gotcha)"
echo "  3. Remove the earlier go/no-go test driver (${OLD_TEST_DRIVER_PATH}), if present"
echo "  4. sudo killall coreaudiod — this restarts the system audio daemon,"
echo "     which will briefly interrupt any audio currently playing on this Mac"
echo
read -p "Proceed? [y/N] " -n 1 -r REPLY
echo
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

echo "== Installing (sudo) =="
sudo rm -rf "$OLD_TEST_DRIVER_PATH"
sudo rm -rf "$INSTALL_PATH"
sudo cp -R "${BUNDLE}" "$INSTALL_PATH"
sudo xattr -d com.apple.provenance "$INSTALL_PATH" 2>/dev/null || true
sudo chown -R root:wheel "$INSTALL_PATH"

echo "== Restarting coreaudiod (sudo) =="
sudo killall coreaudiod
sleep 3

echo
echo "== Results =="
echo "--- coreaudiod log around the restart (SoundCast/driver/error/fail lines) ---"
log show --style compact --predicate 'process == "coreaudiod"' --last 1m 2>&1 \
  | grep -i "soundcast\|${DRIVER_NAME}\|error\|fail" \
  || echo "(no matching lines — if this seems too quiet, see the full dump command below)"
echo
echo "--- is the plugin bundle still present/intact post-restart? ---"
ls -la "$INSTALL_PATH/Contents/MacOS/" 2>&1
echo
echo "--- coreaudiod still alive? ---"
pgrep -x coreaudiod && echo "yes" || echo "NO — something's wrong, check Console.app"
echo
echo "For the full, unfiltered coreaudiod log around this restart, run:"
echo "  log show --style compact --predicate 'process == \"coreaudiod\"' --last 2m"
echo
echo "To uninstall regardless of outcome:"
echo "  sudo rm -rf '$INSTALL_PATH' && sudo killall coreaudiod"
