#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox -debug-info-format none
APP="$PWD/build/GlassSnap.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"
cp "$BIN_DIR/GlassSnap" "$APP/Contents/MacOS/GlassSnap"
# An ignored override can preserve a personal bundle identity across builds.
INFO_PLIST="Resources/Info.plist"
if [[ -f Resources/Info.local.plist ]]; then INFO_PLIST="Resources/Info.local.plist"; fi
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# Use a local signing identity if supplied; otherwise ad-hoc signing is sufficient
# for this personal build. No notarization, network calls, or developer account.
codesign --force --sign "${GLASSSNAP_SIGNING_IDENTITY:--}" --identifier "$APP_IDENTIFIER" "$APP"
if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
printf '\nBuilt %s\n' "$APP"
