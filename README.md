<p align="center">
  <img src="docs/icon.png" width="100" alt="GlassSnap icon">
</p>
<h1 align="center">GlassSnap</h1>
<p align="center">A little order. A lot of space.</p>
<p align="center">Native macOS window snapping and switching, finished in Liquid Glass.</p>

GlassSnap is a lightweight menu bar utility inspired by Windows snap layouts and Alt+Tab. Arrange windows, adjust their shared edges, and switch between thumbnail previews—all with native Swift, AppKit, and SwiftUI.

## What it does

- **Snap layouts:** drag a window near the top center of a display and drop it into one of nine layouts, including thirds, quarters, and a wide center column.
- **Shared resizing:** drag the glass handle between windows snapped into the same layout to adjust their ratio together.
- **Option+Tab:** cycle through window previews, release Option to switch, or choose a card with the mouse.
- **Normal close:** click × or press ⌘W in the switcher. Unsaved documents keep their app’s normal save prompts.
- **Minimal glass UI:** centered rows, a border that follows the cards, and a fast fade-in without an expanding animation.
- **Multiple displays:** display-aware positioning, Retina rounding, and layouts suited to ultrawide screens. Geometry tests include 8K dimensions.

## Build and install

Requires **macOS 26+** and **Xcode 26+ with Swift 6**. No third-party dependencies.

```sh
./Scripts/build.sh
open build
```

Move **GlassSnap.app** from the build folder into **Applications**, then open it. To launch at login, add that installed copy under **System Settings → General → Login Items → Open at Login**.

Grant **Accessibility** for arranging, selecting, and closing windows. Optionally grant **Screen & System Audio Recording** for thumbnails. If GlassSnap is missing from either permission list, use **+** to select the installed app, then relaunch it.

Local builds use ad-hoc signing. Rebuilding can invalidate macOS permissions; finish building and installing before granting access. A signing identity can be supplied through the `GLASSSNAP_SIGNING_IDENTITY` environment variable. An optional, ignored `Resources/Info.local.plist` overrides the public bundle metadata for personal builds.

For predictable snapping, disable macOS’s **Drag windows to menu bar to fill screen** option under **Desktop & Dock**, and pause conflicting window managers.

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

No accounts, analytics, network service, or background recording. Thumbnail snapshots stay in memory and are released when the switcher closes. Capture is limited to the current page; there is no idle capture loop.

Some apps enforce minimum sizes or restrict window control. Shared resize handles link windows arranged by GlassSnap during the current run. Minimized, protected, or ambiguous windows may display an icon instead of a preview. Physical 8K performance and every third-party app are not verified by geometry tests alone.

## Development

```sh
./Scripts/test.sh
open Package.swift
```

`Sources/GlassSnap` contains the native app, overlays, Accessibility integration, and switcher. `Sources/SnapGeometry` contains layout calculations and asynchronous selection state. See [manual verification](docs/TESTING.md) for on-device checks.

[MIT license](LICENSE).
