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

All shortcuts can be changed in Settings. ⌘⇧3, ⌘⇧4 and ⌘⇧5 are also macOS's own screenshot shortcuts, so switch those off first (System Settings → Keyboard → Keyboard Shortcuts → Screenshots); Settings → Shortcuts warns while they are on. The numbers are deliberate: a global ⌘⇧T or ⌘⇧H would take over "reopen tab" and "Home" in every other app. After a capture, the Quick Access Overlay offers Annotate, Pin, Copy and Save, and the image can be dragged straight into other apps.

- **All-in-One:** one shortcut for everything. Drag out a region, drag inside it to move it, drag its edges or corners to resize, or type an exact width and height (Lock keeps the aspect ratio). Pick Area, Scrolling or Text for the region, or jump straight to Window or Fullscreen. Return captures, Esc or the shortcut again closes it, arrow keys nudge. The last region and mode are remembered.
- **Screen recording:** record an area, a window or a whole display as MP4 (H.264) or as a looping GIF. Optional microphone and system audio (mixed into one track), a camera bubble, highlighted clicks and on-screen keystrokes. Press the shortcut again, or Stop, to finish; the menu bar icon turns into a red dot while recording. Pick Record in All-in-One, or press ⌘⇧8. Recordings land in the Quick Access Overlay and history like screenshots; Copy puts the file on the clipboard. Pausing, a countdown and the Studio Mode editor (trim, smart zooms) are not built yet.
- **Annotate editor:** arrow, line, rectangle, ellipse, pencil, highlighter, text, counter, spotlight, blur, pixelate, crop, plus a Background tool with gradients, padding, corners and shadow. Editable projects save as `.snapshotx` files.
- **Scrolling capture:** drag out a region, scroll the content yourself or turn on Auto-scroll (needs Accessibility), then press Done or the shortcut again.
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

## Not built yet

The video editor (Studio Mode), pausing a recording, a countdown before recording, horizontal scrolling capture, combining images by drag and drop, and Auto Balance for backgrounds.
