#!/bin/bash
# Builds FileComparator.app into ./build (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/FileComparator.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FileComparator" "$APP/Contents/MacOS/FileComparator"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# CI stamps the version from the git tag (v1.2.3 -> 1.2.3); local builds keep Info.plist's.
if [ -n "${FC_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $FC_VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${FC_BUILD:-1}" "$APP/Contents/Info.plist"
fi
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Scripts/fcompare "$APP/Contents/Resources/fcompare"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed (app will still run locally)"
echo "Built $(pwd)/$APP"
