#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ADHOC=false
OPEN=false
for argument in "$@"; do
    case "$argument" in
        --adhoc) ADHOC=true ;;
        --open) OPEN=true ;;
        *) printf 'Unknown option: %s\n' "$argument" >&2; exit 2 ;;
    esac
done
if [[ "$ADHOC" == false ]]; then python3 Scripts/app-maintenance.py check; fi
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
# Production-on-this-Mac builds must never silently fall back to ad-hoc signing.
if [[ "$ADHOC" == true ]]; then
    codesign --force --sign - --identifier "$APP_IDENTIFIER" "$APP"
    printf 'Ad-hoc development build only. Do not install it over your stable signed copy.\n'
else
    python3 Scripts/app-maintenance.py sign "$APP"
fi
if [[ "$OPEN" == true ]]; then open "$APP"; fi
printf '\nBuilt %s\n' "$APP"
