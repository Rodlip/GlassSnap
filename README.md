<p align="center">
  <img src="docs/icon.png" width="100" alt="GlassSnap icon">
</p>
<h1 align="center">GlassSnap</h1>
<p align="center">A little order. A lot of space.</p>
<p align="center">Native macOS window snapping and switching, finished in Liquid Glass.</p>

GlassSnap is a lightweight menu bar utility inspired by Windows snap layouts and Alt+Tab. Arrange windows, adjust their shared edges, and switch between thumbnail previews—all with native Swift, AppKit, and SwiftUI.

<p align="center">
  <a href="https://github.com/Rodlip/GlassSnap/releases/latest/download/GlassSnap.zip"><img src="https://img.shields.io/badge/Download-GlassSnap%20for%20Mac-0A84FF?style=for-the-badge&logo=apple&logoColor=white" alt="Download GlassSnap for Mac"></a>
</p>
<p align="center"><sub>macOS 26 or later · Apple silicon and Intel · Free</sub></p>

## What it does

- **Snap layouts:** drag a window near the top center of a display and drop it into one of nine layouts, including thirds, quarters, and a wide center column.
- **Shared resizing:** drag the glass handle between windows snapped into the same layout to adjust their ratio together.
- **Option+Tab:** cycle through window previews, release Option to switch, or choose a card with the mouse.
- **Normal close:** click × or press ⌘W in the switcher. Unsaved documents keep their app’s normal save prompts.
- **Minimal glass UI:** centered rows, a border that follows the cards, and a fast fade-in without an expanding animation.
- **Multiple displays:** display-aware positioning, Retina rounding, and layouts suited to ultrawide screens. Geometry tests include 8K dimensions.

## Install

**Easiest:** paste this into Terminal and press Return.

```sh
curl -fsSL https://raw.githubusercontent.com/Rodlip/GlassSnap/main/Scripts/install.sh | bash
```

It downloads the latest release, checks its signature, puts GlassSnap in Applications, and opens it. ([Read the script](Scripts/install.sh).)

**Or download it yourself:**

1. Click **Download** above, then open **GlassSnap.zip** in Downloads.
2. Drag **GlassSnap** into **Applications** and open it.
3. If macOS says it can’t verify the developer, open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**. You only need to do this once. GlassSnap is free and isn’t notarized by Apple.

### First launch

GlassSnap opens its settings and appears in the menu bar.

1. Click **Enable access** and turn on GlassSnap under **Accessibility**. This lets it move and resize windows.
2. Optional: click **Enable previews** and allow **Screen & System Audio Recording** for window thumbnails in Option+Tab.
3. Optional: add GlassSnap under **System Settings → General → Login Items** to start it when you log in.

If GlassSnap isn’t in a permission list, click **+** and choose it in Applications.

For predictable snapping, disable macOS’s **Drag windows to menu bar to fill screen** option under **Desktop & Dock**, and pause conflicting window managers.

## Update

Choose **Check for Updates…** from the GlassSnap menu bar icon, or click **Check for updates** at the bottom of Settings. GlassSnap downloads the new version, checks that it’s signed by the same developer, replaces itself, and reopens.

**You don’t need to grant permissions again.** macOS links Accessibility and Screen Recording to the app’s signature. Every release is signed with the same certificate, so the grants carry over. Running the install command again works too.

GlassSnap only goes online when you ask it to check for updates.

## Uninstall

Quit GlassSnap from its menu, then move **Applications/GlassSnap.app** to the Trash. You can also remove it from the Accessibility and Screen Recording lists in System Settings.

## Build from source

Requires **macOS 26+** and **Xcode 26+ with Swift 6**. No third-party dependencies.

```sh
./Scripts/setup-signing.sh        # one-time local signing setup
./Scripts/update.sh               # test, build, sign, install, and launch
```

The updater installs and opens **/Applications/GlassSnap.app**. A copy built this way updates from your checkout: **Check for Updates…** opens Terminal, pulls, and runs `./Scripts/update.sh`.

### Updating without repeated permission resets

Run `./Scripts/setup-signing.sh` once to create a local code-signing identity in your login Keychain. It creates no Apple account and changes no system trust settings. Only `codesign` is authorized to use this key. If you already have an appropriate identity, pass its exact certificate fingerprint with `--identity`.

For an existing **ad-hoc-signed** installation, migrate once:

```sh
./Scripts/update.sh --migrate-signing
```

macOS may require one final Accessibility and Screen Recording grant after this identity transition. Afterwards, use:

```sh
./Scripts/update.sh
```

The updater runs tests, builds with the saved certificate, verifies the bundle ID and certificate requirement, stages the app, backs up the installed version, replaces `/Applications/GlassSnap.app`, and relaunches it. Failed launch/verification attempts restore the previous version where possible. Backups remain under the ignored `build/update-backups/` directory. Use `--prepare` to build and verify without installing.

Keep the certificate, `.glasssnap-signing.local.json`, bundle ID, and installed path stable. The private key remains in Keychain; local configuration and `Resources/Info.local.plist` are ignored by Git. Do not regenerate the certificate for routine updates. A missing/changed signer fails the update instead of silently falling back to ad-hoc signing. `./Scripts/build.sh --adhoc` is available only for disposable development builds; do not install those over the stable copy.

This preserves [the code identity macOS uses for privacy access](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements); macOS can still require reauthorization after OS policy changes or certificate replacement. A self-signed certificate isn’t notarized, which is why a downloaded copy needs **Open Anyway** once.

#### Removing the local signing key later

You can remove it without uninstalling the already signed app. In **Keychain Access → login → My Certificates**, find **GlassSnap Local Development**, verify its SHA-1 fingerprint against `.glasssnap-signing.local.json`, and delete that certificate and its associated private key. Remove the local JSON configuration afterwards. If you reused another certificate, do not delete it without checking whether other projects depend on it.

Removing the key ends your ability to sign future updates with the same identity. The installed app does not need the private key to run; a future replacement identity may require fresh macOS permission grants. Do not remove the key after each update.

### Publishing a release

Releases use the public bundle ID in `Resources/Info.plist` and must always be signed with the same certificate, or downloaded copies lose their permissions after an update.

```sh
./Scripts/setup-signing.sh --release   # once: reuse your existing signing certificate for releases
./Scripts/release.sh                   # test, build a universal app, sign, and zip it to dist/
./Scripts/release.sh --publish         # same, then create the GitHub release (needs gh)
```

For each new release, raise `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, commit, and push. Publishing tags the pushed commit as `v<version>` and uploads `GlassSnap.zip`, which the download button, install script, and in-app updater all use. If the certificate’s private key is lost, existing users must reinstall and grant permissions again, so keep it safe.

## Controls

| Action | Gesture |
| --- | --- |
| Choose a snap layout | Drag a title bar near the top center, then release over a zone |
| Resize linked windows | Hover their shared edge and drag the handle |
| Switch windows | Hold Option, tap Tab, then release Option |
| Cycle backward | Option+Shift+Tab |
| Select / open a card | Arrow keys / Return, or click |
| Close the selected window | ⌘W or the card’s × |
| Cancel | Escape |

The menu bar also offers settings, direct placement, window restore, and a switcher command that stays open without holding a shortcut.

## Privacy and limits

No accounts, analytics, or background recording. GlassSnap connects to GitHub only when you choose Check for Updates. Thumbnail snapshots stay in memory and are released when the switcher closes. Capture is limited to the current page; there is no idle capture loop.

Some apps enforce minimum sizes or restrict window control. Shared resize handles link windows arranged by GlassSnap during the current run. Minimized, protected, or ambiguous windows may display an icon instead of a preview. Physical 8K performance and every third-party app are not verified by geometry tests alone.

## Development

```sh
./Scripts/test.sh
open Package.swift
```

`Sources/GlassSnap` contains the native app, overlays, Accessibility integration, and switcher. `Sources/SnapGeometry` contains layout calculations and asynchronous selection state. See [manual verification](docs/TESTING.md) for on-device checks.

[MIT license](LICENSE).
