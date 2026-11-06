#!/usr/bin/env bash
# Build SoundCast.app for Phase 1: swift build, disassembly-verify the
# Westmere CPU baseline (design doc §8), wrap into a .app bundle, sign
# with the stable local self-signed identity (design doc §7.2).
#
# Run this on the Mac — it does nothing useful anywhere else.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

APP_NAME="SoundCast"
BUILD_CONFIG="release"
IDENTITY_NAME="SoundCast Local Signing"
APP_BUNDLE="dist/${APP_NAME}.app"
CS_KEYCHAIN="$HOME/Library/Keychains/soundcast-build.keychain-db"
PASS_FILE="$HOME/.soundcast_build_keychain.pass"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script builds a macOS app and must be run on a Mac." >&2
  exit 1
fi

echo "== Ensuring local self-signed code-signing identity exists =="
./scripts/create_local_signing_identity.sh

echo "== swift build (-c ${BUILD_CONFIG}) =="
swift build -c "${BUILD_CONFIG}"

BIN_PATH="$(swift build -c "${BUILD_CONFIG}" --show-bin-path)"
EXECUTABLE="${BIN_PATH}/${APP_NAME}"
SMOKETEST_EXECUTABLE="${BIN_PATH}/LocalOutputSmokeTest"
CAPTURETEST_EXECUTABLE="${BIN_PATH}/CaptureSmokeTest"
VIRTUALDEVICETEST_EXECUTABLE="${BIN_PATH}/VirtualDeviceSmokeTest"
AIRPLAYDISCOVERYTEST_EXECUTABLE="${BIN_PATH}/AirPlayDiscoverySmokeTest"

# --- Design doc §8: hard gate, not just a compiler-flag promise -----------
# Disassemble the actual build product and refuse to proceed if it
# contains AVX/AVX2/FMA/F16C instructions — SSE4.2 is the ceiling the
# Mac Pro 5,1's Westmere Xeon supports, and this binary has to run there
# too. This checks the real output, not what we *meant* to compile.
echo "== Verifying Westmere (no AVX/AVX2/FMA/F16C) baseline =="
check_binary_for_avx() {
  local binary_path="$1"
  local disasm
  disasm="$(otool -tV "$binary_path" 2>/dev/null || objdump -d "$binary_path" 2>/dev/null)"
  # VEX/EVEX-prefixed instructions always involve ymm/zmm registers or
  # the vzeroupper/vzeroall family; scanning for the register names and
  # the common "v"-prefixed mnemonics catches both AVX and AVX2/FMA/F16C
  # (F16C ops are vcvtph2ps/vcvtps2ph, which also show up as v-prefixed).
  if echo "$disasm" | grep -Eq '%ymm[0-9]+|%zmm[0-9]+|\bvzeroupper\b|\bvzeroall\b|\bvfmadd|\bvcvtph2ps\b|\bvcvtps2ph\b'; then
    echo "FAIL: ${binary_path} contains AVX/AVX2/FMA/F16C instructions." >&2
    echo "$disasm" | grep -En '%ymm[0-9]+|%zmm[0-9]+|\bvzeroupper\b|\bvzeroall\b|\bvfmadd|\bvcvtph2ps\b|\bvcvtps2ph\b' | head -20 >&2
    return 1
  fi
  echo "OK: ${binary_path} is within the Westmere/SSE4.2 baseline."
  return 0
}

AVX_CHECK_FAILED=0
check_binary_for_avx "$EXECUTABLE" || AVX_CHECK_FAILED=1
check_binary_for_avx "$SMOKETEST_EXECUTABLE" || AVX_CHECK_FAILED=1
check_binary_for_avx "$CAPTURETEST_EXECUTABLE" || AVX_CHECK_FAILED=1
check_binary_for_avx "$VIRTUALDEVICETEST_EXECUTABLE" || AVX_CHECK_FAILED=1
check_binary_for_avx "$AIRPLAYDISCOVERYTEST_EXECUTABLE" || AVX_CHECK_FAILED=1
if [ "$AVX_CHECK_FAILED" -ne 0 ]; then
  echo "Build FAILED the Westmere baseline check. See design doc §8 — check" >&2
  echo "that no dependency or vendored C source is being built without" >&2
  echo "-march=westmere actually reaching the compiler invocation." >&2
  exit 1
fi

echo "== Assembling .app bundle =="
rm -rf "dist"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "$EXECUTABLE" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"
cp "$SMOKETEST_EXECUTABLE" "dist/LocalOutputSmokeTest"
cp "$CAPTURETEST_EXECUTABLE" "dist/CaptureSmokeTest"
cp "$VIRTUALDEVICETEST_EXECUTABLE" "dist/VirtualDeviceSmokeTest"
cp "$AIRPLAYDISCOVERYTEST_EXECUTABLE" "dist/AirPlayDiscoverySmokeTest"

echo "== Signing with local identity '${IDENTITY_NAME}' =="
# The keychain's unlock state doesn't reliably persist across separate
# SSH/security sessions — re-unlock explicitly every run rather than
# assume it's still unlocked from whenever create_local_signing_identity.sh
# last ran (confirmed necessary: codesign failed with errSecInternalComponent
# in a session after the one that created/unlocked it).
security unlock-keychain -p "$(cat "$PASS_FILE")" "$CS_KEYCHAIN"
codesign --force --sign "${IDENTITY_NAME}" --timestamp=none "${APP_BUNDLE}"
codesign --verify --verbose "${APP_BUNDLE}"
# CaptureSmokeTest needs a stable signing identity too — it requests the
# same TCC-gated audio-capture permission as the app, and a differently-
# signed (or unsigned) binary on each rebuild would hit the exact "grant
# doesn't survive a rebuild" problem the whole self-signed-cert setup
# exists to avoid (design doc §7.2). LocalOutputSmokeTest doesn't need
# this (no privacy-gated API), but signing it too is harmless.
codesign --force --sign "${IDENTITY_NAME}" --timestamp=none "dist/CaptureSmokeTest"
codesign --force --sign "${IDENTITY_NAME}" --timestamp=none "dist/LocalOutputSmokeTest"
codesign --force --sign "${IDENTITY_NAME}" --timestamp=none "dist/VirtualDeviceSmokeTest"
codesign --force --sign "${IDENTITY_NAME}" --timestamp=none "dist/AirPlayDiscoverySmokeTest"

echo
echo "Built: ${APP_BUNDLE}"
echo "Run it with: open '${APP_BUNDLE}'"
echo "(First launch will prompt for the system-audio capture permission —"
echo " see README.md for what to expect and how to reset it if needed.)"
echo
echo "Also built: dist/LocalOutputSmokeTest — plays a test tone through the"
echo "same aggregate-device/IOProc code the app uses, no permission prompt"
echo "needed (only capture, not render, needs consent). Run it directly:"
echo "  ./dist/LocalOutputSmokeTest"
echo
echo "Also built: dist/CaptureSmokeTest — exercises the FULL Phase 1"
echo "pipeline (real system-audio capture -> real local multi-output) in"
echo "one CLI run, no menu bar needed. This one DOES need the one-time"
echo "audio-capture permission click:"
echo "  ./dist/CaptureSmokeTest [seconds] [device-uid ...]"
