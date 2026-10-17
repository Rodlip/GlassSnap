#!/bin/bash
# Install or update GlassSnap from the latest GitHub release:
#   curl -fsSL https://raw.githubusercontent.com/Rodlip/GlassSnap/main/Scripts/install.sh | bash
# Releases are signed with GlassSnap's Developer ID and notarized by Apple. An
# existing copy is replaced only by one from the same developer, so macOS keeps
# its Accessibility and Screen Recording permissions.
set -euo pipefail
REPOSITORY="Rodlip/GlassSnap"
DOWNLOAD="https://github.com/$REPOSITORY/releases/latest/download/GlassSnap.zip"
BUNDLE_ID="io.github.rodlip.GlassSnap"
TEAM_ID="2PSR8KLD95"
RELEASE_REQUIREMENT="identifier \"$BUNDLE_ID\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"$TEAM_ID\""

fail() { printf '\nGlassSnap: %s\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || fail "GlassSnap runs on macOS only."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 26 )) || fail "GlassSnap needs macOS 26 or later (this Mac has $(sw_vers -productVersion))."

DESTINATION_DIR="/Applications"
if [[ -d "$HOME/Applications/GlassSnap.app" && ! -d /Applications/GlassSnap.app ]]; then DESTINATION_DIR="$HOME/Applications"; fi
if [[ ! -w "$DESTINATION_DIR" ]]; then DESTINATION_DIR="$HOME/Applications"; mkdir -p "$DESTINATION_DIR"; fi
APP="$DESTINATION_DIR/GlassSnap.app"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'Downloading GlassSnap…\n'
curl -fL --progress-bar "$DOWNLOAD" -o "$work/GlassSnap.zip" || fail "The download failed. Check your connection or https://github.com/$REPOSITORY/releases."
ditto -x -k "$work/GlassSnap.zip" "$work/expanded" || fail "The download couldn’t be unpacked."
candidate="$work/expanded/GlassSnap.app"
[[ -d "$candidate" ]] || fail "The download doesn’t contain GlassSnap.app."
codesign --verify --strict -R="$RELEASE_REQUIREMENT" "$candidate" 2>/dev/null \
    || fail "The download isn’t signed by GlassSnap’s developer. Nothing was installed."

regrant=false
if [[ -d "$APP" ]]; then
    # Same signer, same identity: permissions carry over.
    requirement="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p')"
    if [[ -z "$requirement" ]] || ! codesign --verify --strict -R="$requirement" "$candidate" 2>/dev/null; then
        # 0.3.0 and earlier releases used a self-signed certificate. Moving to
        # Developer ID is allowed once, and needs the permissions granted again.
        installed_id="$(defaults read "$APP/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true)"
        [[ "$installed_id" == "$BUNDLE_ID" && "$requirement" == *'certificate leaf = H"'* ]] \
            || fail "The installed GlassSnap was signed differently (perhaps built from source). Quit it and remove $APP to switch to the release, or keep updating it with ./Scripts/update.sh."
        regrant=true
    fi
    # Quit only this exact copy, politely.
    executable="$APP/Contents/MacOS/GlassSnap"
    pids() { ps -axo pid=,comm= | awk -v path="$executable" '{ pid = $1; $1 = ""; sub(/^ /, ""); if ($0 == path) print pid }'; }
    for pid in $(pids); do kill -TERM "$pid" 2>/dev/null || true; done
    for _ in $(seq 40); do [[ -z "$(pids)" ]] && break; sleep 0.2; done
    [[ -z "$(pids)" ]] || fail "GlassSnap didn’t quit. Quit it from the menu bar, then run this again."
fi

stage="$(mktemp -d "$DESTINATION_DIR/.GlassSnap-install.XXXXXX")"
trap 'rm -rf "$work" "$stage"' EXIT
ditto "$candidate" "$stage/GlassSnap.app"
if [[ -d "$APP" ]]; then mv "$APP" "$stage/previous.app"; fi
if ! mv "$stage/GlassSnap.app" "$APP"; then
    [[ -d "$stage/previous.app" ]] && mv "$stage/previous.app" "$APP"
    fail "Couldn’t move GlassSnap into $DESTINATION_DIR."
fi
open "$APP"

version="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)"
printf '\nGlassSnap %s is installed in %s and running in your menu bar.\n' "$version" "$DESTINATION_DIR"
if [[ "$regrant" == true ]]; then
    printf '\nThis version is signed by Apple Developer ID, so macOS needs your permission once more:\n'
    printf '  1. System Settings → Privacy & Security → Accessibility: select GlassSnap and click –.\n'
    printf '  2. Click “Enable access” in GlassSnap and turn it on again.\n'
    printf '  3. If you use previews, do the same under Screen & System Audio Recording.\n'
    printf 'Later updates keep your permissions.\n'
else
    printf 'First time? Click “Enable access” to allow Accessibility. Later updates: GlassSnap menu → Check for Updates…\n'
fi
