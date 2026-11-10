#!/usr/bin/env bash
# Build the downloadable release zip (run on an Intel Mac):
#   ./scripts/package_release.sh
# Builds the app and the driver, then writes dist/SoundCast-<version>.zip
# containing SoundCast.app, SoundCast.driver, install.sh, uninstall.sh
# and ReadMe.txt.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
NAME="SoundCast-${VERSION}"
OUT="dist/release/${NAME}"

./build.sh
(cd HALPlugin && ./build_and_test.sh)

rm -rf "dist/release" "dist/${NAME}.zip"
mkdir -p "$OUT"
ditto dist/SoundCast.app "$OUT/SoundCast.app"
ditto HALPlugin/dist/SoundCast.driver "$OUT/SoundCast.driver"
cp scripts/release/install.sh scripts/release/uninstall.sh "$OUT/"
chmod +x "$OUT/install.sh" "$OUT/uninstall.sh"
sed "s/__VERSION__/${VERSION}/" scripts/release/ReadMe.txt > "$OUT/ReadMe.txt"

codesign --verify --deep "$OUT/SoundCast.app"
codesign --verify "$OUT/SoundCast.driver"
ditto -c -k --keepParent "$OUT" "dist/${NAME}.zip"
echo "Wrote dist/${NAME}.zip"
