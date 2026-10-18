# SnapShotX

A native macOS screenshot tool: capture, annotate, pin, and read text from your screen. Swift, SwiftUI and AppKit, macOS 14 or newer.

## Build

```bash
scripts/build_app.sh        # builds build/SnapShotX.app (ad-hoc signed)
swift test                  # unit tests
scripts/make_icon.sh        # regenerates Resources/AppIcon.icns
```

The app is signed with an identifier-only designated requirement, so macOS keeps the Screen Recording permission across rebuilds.

## What it does

| Feature | Default shortcut |
| --- | --- |
| All-in-One | ⌘⇧5 |
| Capture Area | ⌘⇧4 |
| Capture Fullscreen | ⌘⇧3 |
| Capture Window | ⌘⇧6 |
| Scrolling Capture (vertical) | ⌘⇧7 |
| Capture Text (OCR and QR codes) | ⌘⇧9 |
| Record Screen | ⌘⇧8 |
| Capture History (30 days) | ⌘⇧0 |

All shortcuts can be changed in Settings. ⌘⇧3, ⌘⇧4 and ⌘⇧5 are also macOS's own screenshot shortcuts, so switch those off first (System Settings → Keyboard → Keyboard Shortcuts → Screenshots); Settings → Shortcuts warns while they are on. The numbers are deliberate: a global ⌘⇧T or ⌘⇧H would take over "reopen tab" and "Home" in every other app. After a capture, the Quick Access Overlay offers Annotate, Pin, Copy and Save, and the image can be dragged straight into other apps. The card stays until you close it or take another capture; once the capture has been copied it goes away by itself after 30 seconds.

- **All-in-One:** one shortcut for everything. Drag out a region, drag inside it to move it, drag its edges or corners to resize, or type an exact width and height (Lock keeps the aspect ratio). Pick Area, Scrolling or Text for the region, or jump straight to Window or Fullscreen. Return captures, Esc or the shortcut again closes it, arrow keys nudge. The last region and mode are remembered.
- **Screen recording:** record an area, a window or a whole display as MP4 (H.264) or as a looping GIF. Optional microphone and system audio (mixed into one track), a camera bubble, highlighted clicks and on-screen keystrokes. Press the shortcut again, or Stop, to finish; the menu bar icon turns into a red dot while recording. Pick Record in All-in-One, or press ⌘⇧8. Recordings land in the Quick Access Overlay and history like screenshots; Copy puts the file on the clipboard. Pause and resume from the HUD (the paused stretch is cut out of the video, audio and cursor). A 3, 5 or 10 second countdown runs first (change or turn it off in Settings → Recording, or the All-in-One options menu); click the number to cancel.
- **Studio Mode:** turn on *Studio mode* (Settings → Recording, or the All-in-One toolbar) before recording an MP4. The pointer is recorded separately from the picture, so afterwards you can open the recording with **Edit in Studio** (Quick Access, or the history window) and: trim, add smart zooms that are created from your clicks and follow the cursor (drag, resize or delete them on the timeline), smooth, resize or hide the pointer and its click rings, put the video on a Background, crop the recording to part of the screen, and export MP4 or GIF at original size, 1080p or 720p. Edits are saved next to the recording and the original file is never changed. Studio mode doesn't burn click highlights into the video; keystroke overlays and the camera bubble still do. Recordings made without Studio mode open too, with trim, manual zooms and backgrounds but no cursor effects.
- **Annotate editor:** arrow, line, rectangle, ellipse, pencil, highlighter, text, counter, spotlight, blur, pixelate, crop, plus a Background tool with gradients, padding, corners and shadow. Editable projects save as `.snapshotx` files. Text comes in six styles (plain, bold, outline, label, marker, monospaced): pick one from the style button in the toolbar while the Text tool is active or a text is selected. Drop one or more image files onto the editor to combine them with the current image (below, above, left or right), or use **Combine Images…** in the menu bar menu to join several files stacked or side by side. The result opens in a new editor window; everything is scaled to match the first image.
- **Scrolling capture:** drag out a region, scroll the content yourself or turn on Auto-scroll (needs Accessibility), then press Done or the shortcut again. The arrows button in the controls switches between scrolling down and scrolling sideways (wide tables, timelines). A bar fixed to the bottom of the region, such as a cookie banner, is kept out of the repeats.
- **Full page capture (⌘⇧2):** like a full-page screenshot extension. Bring the page forward in Safari, Chrome, Edge, Brave, Arc or Firefox and press the shortcut: SnapShotX finds the page area (not the tabs or address bar), scrolls to the top, scrolls down by itself and stitches the whole page into one image. It needs Accessibility permission, and the page must be in the front window. Click the Done check or press the shortcut again to stop early. Pages with fixed headers show them once, at the top. Other apps fall back to their front window.
- **Pinned screenshots:** float above every window. Scroll or pinch to resize, ⌥-scroll for opacity, arrow keys to nudge, Esc to close, right-click to lock so clicks pass through. "Unlock All Pinned Screenshots" is in the menu bar menu.
- **Capture Text:** copies recognized text (or a QR code's contents) to the clipboard. Recognition runs on-device.

## URL scheme

Commands look like `snapshotx://command?parameter=value`. Coordinates start at the lower-left corner of the display. They can be switched off in Settings → General.

| Command | Parameters |
| --- | --- |
| `all-in-one` | `x`, `y`, `width`, `height`, `display`, `action` (the region it opens with) |
| `capture-area` | `x`, `y`, `width`, `height`, `display`, `action` |
| `capture-previous-area` | `action` |
| `capture-fullscreen` | `display`, `action` |
| `capture-window` | `action` |
| `scrolling-capture` | `x`, `y`, `width`, `height`, `display`, `autoscroll`, `action` |
| `full-page-capture` | `action` |
| `record-screen` | `x`, `y`, `width`, `height`, `display` (starts at once if a region is given, otherwise opens All-in-One in Record mode) |
| `capture-text` | `x`, `y`, `width`, `height`, `display`, `filepath`, `linebreaks` |
| `pin` | `filepath` |
| `open-annotate` | `filepath` |
| `open-from-clipboard` | |
| `add-quick-access-overlay` | `filepath` |
| `open-history` | |
| `open-settings` | `tab` (`general`, `screenshots`, `recording`, `shortcuts`, `permissions`) |

- `display`: 1 is the main display, 2 the next, and so on. Without it, the display under the pointer is used.
- `action`: `copy`, `save`, `annotate` or `pin`. Without it, the normal Quick Access Overlay flow runs.
- `filepath`: must be an absolute path.

A capture started from a URL still plays the shutter sound and shows a toast or the overlay, so it is never silent.

## Troubleshooting

**Is a shortcut working?** Open **Settings → Shortcuts** and press it: the row flashes "Worked" and the footer shows the last shortcut used. A shortcut pressed while another capture is open switches to it, and pressed twice it closes the overlay. During a recording or a scrolling capture, other shortcuts show a short notice instead of being ignored. A warning triangle next to a shortcut means another app already owns that key combination.

**No menu bar icon.** macOS silently hides menu bar icons that don't fit, which happens on Macs with a notch and a crowded menu bar. SnapShotX notices, explains it once in Settings, and offers **Settings → General → Show SnapShotX in the Dock**: right-click the Dock icon for the same menu. The keyboard shortcuts work either way. Quitting a few other menu bar apps also frees room.

**Image density:** Settings → Saved image density sets the pixels-per-inch written into saved PNGs (Screen 144, 300 or 600). It changes the size other apps and printers use, not the pixel count, which is always what the screen drew.

## Releasing

`scripts/release.sh` builds `build/SnapShotX.dmg`. With `SIGN_IDENTITY="Developer ID Application: …"` set (and a `notarytool` keychain profile, see the script header) it also signs with the hardened runtime, notarizes and staples. Without it you get an ad-hoc signed DMG that only runs cleanly on this Mac. The signed path needs a paid Apple Developer account and has not been run.

## Not built yet

Nothing from the original plan is left. Ideas that were never started: cloud sharing, a Windows or iOS version, and per-window cursor tracking for window recordings.
