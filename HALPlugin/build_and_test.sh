#!/usr/bin/env bash
# Build and self-sign SoundCast.driver, then build the standalone
# shared-memory diagnostic. No sudo is needed; install_and_check.sh
# separately installs the driver and restarts coreaudiod.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This builds a HAL driver and must be run on a Mac." >&2
  exit 1
fi

DRIVER_NAME="SoundCast"
BUNDLE="dist/${DRIVER_NAME}.driver"
TEST_BINARY="test_shm_flow"
IDENTITY_NAME="SoundCast Local Signing"
CS_KEYCHAIN="$HOME/Library/Keychains/soundcast-build.keychain-db"
PASS_FILE="$HOME/.soundcast_build_keychain.pass"

echo "== Ensuring local self-signed code-signing identity exists =="
../scripts/create_local_signing_identity.sh

echo "== Compiling =="
rm -rf dist
mkdir -p "${BUNDLE}/Contents/MacOS"
# -march=westmere: same hard constraint as everything else in this
# project (design doc §8) — this runs inside coreaudiod, so an illegal
# instruction here doesn't just crash our own process, it crashes
# system audio on the whole Mac.
clang -dynamiclib \
  -arch x86_64 \
  -march=westmere -mno-avx -mno-avx2 -mno-fma -mno-f16c \
  -framework CoreAudio -framework CoreFoundation \
  -o "${BUNDLE}/Contents/MacOS/${DRIVER_NAME}" \
  src/driver.c
cp src/Info.plist "${BUNDLE}/Contents/Info.plist"

echo "== Building shared-memory flow diagnostic =="
clang \
  -arch x86_64 \
  -march=westmere -mno-avx -mno-avx2 -mno-fma -mno-f16c \
  -framework CoreAudio -framework CoreFoundation \
  -o "${TEST_BINARY}" \
  test_shm_flow.c

echo "== Verifying Westmere baseline on the compiled driver =="
DISASM="$(otool -tV "${BUNDLE}/Contents/MacOS/${DRIVER_NAME}" 2>/dev/null)"
if echo "$DISASM" | grep -Eq '%ymm[0-9]+|%zmm[0-9]+|\bvzeroupper\b|\bvzeroall\b|\bvfmadd|\bvcvtph2ps\b|\bvcvtps2ph\b'; then
  echo "FAIL: driver binary contains AVX/AVX2/FMA/F16C instructions. Not installing." >&2
  exit 1
fi
echo "OK: driver binary is within the Westmere/SSE4.2 baseline."

echo "== Verifying Westmere baseline on the diagnostic =="
TEST_DISASM="$(otool -tV "${TEST_BINARY}" 2>/dev/null)"
if echo "$TEST_DISASM" | grep -Eq '%ymm[0-9]+|%zmm[0-9]+|\bvzeroupper\b|\bvzeroall\b|\bvfmadd|\bvcvtph2ps\b|\bvcvtps2ph\b'; then
  echo "FAIL: diagnostic contains AVX/AVX2/FMA/F16C instructions. Not installing." >&2
  exit 1
fi
echo "OK: diagnostic is within the Westmere/SSE4.2 baseline."

echo "== Signing with local identity '${IDENTITY_NAME}' =="
security unlock-keychain -p "$(cat "$PASS_FILE")" "$CS_KEYCHAIN"
codesign --force --sign "${IDENTITY_NAME}" --timestamp=none "${BUNDLE}"
codesign --verify --verbose "${BUNDLE}" || true

echo
echo "Built and signed: ${BUNDLE}"
echo "Built diagnostic: ./${TEST_BINARY}"
echo "Next: run ./install_and_check.sh (needs your sudo password) to actually"
echo "install it and restart coreaudiod."
