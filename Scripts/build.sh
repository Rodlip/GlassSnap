#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ADHOC=false
OPEN=false
RELEASE=false
for argument in "$@"; do
    case "$argument" in
        --adhoc) ADHOC=true ;;
        --open) OPEN=true ;;
        --release) RELEASE=true ;;
        *) printf 'Unknown option: %s\n' "$argument" >&2; exit 2 ;;
    esac
done
if [[ "$RELEASE" == true && "$ADHOC" == true ]]; then
    printf 'A release must be signed with the release identity, never ad-hoc.\n' >&2; exit 2
fi
IDENTITY=()
if [[ "$RELEASE" == true ]]; then IDENTITY=(--release); fi
if [[ "$ADHOC" == false ]]; then python3 Scripts/app-maintenance.py check ${IDENTITY[@]+"${IDENTITY[@]}"}; fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
# Releases are universal so they also run on Intel Macs that support macOS 26.
ARCHS=()
if [[ "$RELEASE" == true ]]; then ARCHS=(--arch arm64 --arch x86_64); fi
swift build -c release --disable-sandbox -debug-info-format none ${ARCHS[@]+"${ARCHS[@]}"}
APP="$PWD/build/GlassSnap.app"
if [[ "$RELEASE" == true ]]; then APP="$PWD/build/release/GlassSnap.app"; rm -rf "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path ${ARCHS[@]+"${ARCHS[@]}"})"
cp "$BIN_DIR/GlassSnap" "$APP/Contents/MacOS/GlassSnap"
# An ignored override can preserve a personal bundle identity across builds.
# Releases always use the public metadata.
INFO_PLIST="Resources/Info.plist"
if [[ "$RELEASE" == false && -f Resources/Info.local.plist ]]; then INFO_PLIST="Resources/Info.local.plist"; fi
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
# The public plist is the single source of the version number.
for key in CFBundleShortVersionString CFBundleVersion; do
    plutil -replace "$key" -string "$(plutil -extract "$key" raw Resources/Info.plist)" "$APP/Contents/Info.plist"
done
# Copies built from source update by rebuilding this checkout, not by downloading.
if [[ "$RELEASE" == false ]]; then
    plutil -replace GlassSnapSourceDirectory -string "$PWD" "$APP/Contents/Info.plist"
fi
APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# Production-on-this-Mac builds must never silently fall back to ad-hoc signing.
if [[ "$ADHOC" == true ]]; then
    codesign --force --sign - --identifier "$APP_IDENTIFIER" "$APP"
    printf 'Ad-hoc development build only. Do not install it over your stable signed copy.\n'
else
    python3 Scripts/app-maintenance.py sign ${IDENTITY[@]+"${IDENTITY[@]}"} "$APP"
fi
if [[ "$OPEN" == true ]]; then open "$APP"; fi
printf '\nBuilt %s\n' "$APP"
