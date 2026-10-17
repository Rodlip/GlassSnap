# Verification

## Automated

Run `./Scripts/test.sh` for layout coverage, non-overlap, point/pixel rounding, an 8K / Retina / ultrawide / portrait / negative-origin matrix, 60:40 resizing, three-column boundary isolation, minimum-size constraints, and four-window grid resizing.

Run `./Scripts/build.sh` to compile, bundle, and locally sign the application. `codesign --verify --strict build/GlassSnap.app` validates the bundle.

## On-device checks (Accessibility must be enabled)

Use disposable Finder/TextEdit windows to avoid disturbing important work.

- Drag a title bar near the top center, 80–100 points below the edge and to either side of the palette: it should appear immediately and remain open while moving into a zone. Repeat at the exact outer top edge with the configured delay; drag text or resize a window to confirm those actions do not summon the picker.
- Visit every layout and drop into every zone. Check that Dock and menu bar are excluded.
- Fill two halves. Hover the seam and drag to roughly 60:40, then 40:60. Press Escape mid-drag and check both windows restore.
- Move slowly and quickly along a shared edge, including across the glass handle itself: its center should continuously follow the pointer without pausing and jumping by a handle length. Repeat for horizontal edges and while dragging diagonally to resize; at a minimum size, the handle must stay on the accepted seam while following the pointer along it.
- Fill three columns. Drag each seam independently and verify the far column stays fixed.
- Fill quarters. Drag the central vertical and horizontal lines and check all touching windows change together.
- Test the minimum width of each app: no new overlap should remain after a rejected resize.
- Cover a snapped pair with another window, minimize one, or switch Spaces: handles must not intercept the covering app.
- Move a linked window manually, then hover its old seam: it must no longer be linked.
- Repeat on every connected display, including a monitor to the left or above the main monitor. Unplug a display and confirm no stale handles remain.
- Toggle Reduce Motion in macOS; placement should be immediate.
- Open and close Settings repeatedly. With Settings and the palette closed, sample CPU and memory in Activity Monitor. There should be no periodic idle activity attributable to a timer.
- Quit: menu bar item and all overlays must disappear.

Physical 8K performance, third-party application resize latency, and all multi-display arrangements cannot be established by geometry unit tests alone. Record actual hardware and observed results before making performance claims.

## Window switcher

Automated selection regressions cover a release before discovery finishes, repeated Tab presses during discovery, forward/backward wrapping, empty catalogs, and clamping when an app exits.

For on-device verification, enable Accessibility and optionally Screen Recording for this exact build:

- Hold Option, tap Tab repeatedly, then release Option: the highlighted window should become active. Repeat with Shift and with a very quick press/release.
- Open from Settings or the menu bar: the panel should stay open without holding Option. Use arrows, Return, Escape, and mouse selection.
- Open more than eight windows: navigate across pages, then back. Capture should populate only the current page, without unbounded memory growth.
- Check window previews from multiple apps and displays; minimized/protected windows may use icons.
- In a disposable unsaved TextEdit document, use the card × or ⌘W. The switcher should dismiss and TextEdit should show its own save prompt. Choose Cancel manually and verify the document survives. Never test with valuable unsaved work.
- Close a saved disposable window: only that window should close; other app windows should remain.
- Deny capture access: icons/titles and window actions should still work. Deny Accessibility: the panel should show setup guidance without trying to close windows.
- Dismiss while thumbnails load, reopen rapidly, or switch Spaces: stale images/results should not appear in a newer session.
- Close the switcher and sample idle CPU/memory. No capture stream should remain, and thumbnail memory should be released.

- Switcher layout: check one, two, three, and six windows, plus a partially filled final page. The glass should fit the cards with 16-point padding; every row should be centered. Up/down navigation should select the nearest card in the centered neighboring row.

- Five-over-two silhouette: empty bottom-left and bottom-right corners should be transparent, while a continuous rounded glass edge wraps the bottom pair. Opening should visibly fade opacity for 180 ms at the final size; no growth, selection transition, or image fade. Check both Option+Tab and menu-bar opening, rapid dismissal/reopening during the fade, and immediate appearance with Reduce Motion enabled.

## Install and update

Automated coverage: `ReleaseVersionTests` checks tag comparison, and the Python suite checks that release setup picks the single Developer ID certificate, refuses a self-signed or changed release identity, signs with the hardened runtime, stops when notarization isn't accepted, and won't publish from an uncommitted tree.

On-device, using a published release:

- Run the install command on a Mac without GlassSnap: it should install to Applications, open with no Gatekeeper prompt, and show Settings. Grant Accessibility and Screen Recording.
- Download GlassSnap.zip in Safari instead: the first launch should show only the standard “downloaded from the internet” confirmation, with no **Open Anyway** step.
- With an older release installed, choose **Check for Updates…**: confirm, then GlassSnap should quit, reopen at the new version, and keep both permissions (snap a window, open Option+Tab previews) without new prompts.
- Check when already current: it should say you're up to date. Disconnect the network: it should show an error with a link to the releases page and leave the app unchanged.
- Run the install command over an ad-hoc or source-built copy: it should refuse and leave that copy alone.
- Run the install command over the self-signed 0.3.0 release: it should replace it once and explain how to grant permissions again. In 0.3.0, **Check for Updates…** should refuse the Developer ID release and offer the releases page.
- In a source-built copy, **Check for Updates…** should open Terminal and run `./Scripts/update.sh` from that checkout.
- With Settings closed and no update check running, idle CPU should show no network or timer activity.
