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
| Capture Area | ⌃⌥4 |
| Capture Fullscreen | ⌃⌥3 |
| Capture Window | ⌃⌥5 |
| Scrolling Capture (vertical) | ⌃⌥6 |
| Capture Text (OCR and QR codes) | ⌃⌥T |
| Capture History (30 days) | ⌃⌥H |

All shortcuts can be changed in Settings. After a capture, the Quick Access Overlay offers Annotate, Pin, Copy and Save, and the image can be dragged straight into other apps.

- **Annotate editor:** arrow, line, rectangle, ellipse, pencil, highlighter, text, counter, spotlight, blur, pixelate, crop, plus a Background tool with gradients, padding, corners and shadow. Editable projects save as `.snapshotx` files.
- **Scrolling capture:** drag out a region, scroll the content yourself or turn on Auto-scroll (needs Accessibility), then press Done or the shortcut again.
- **Pinned screenshots:** float above every window. Scroll or pinch to resize, ⌥-scroll for opacity, arrow keys to nudge, Esc to close, right-click to lock so clicks pass through. "Unlock All Pinned Screenshots" is in the menu bar menu.
- **Capture Text:** copies recognized text (or a QR code's contents) to the clipboard. Recognition runs on-device.

## URL scheme

Commands look like `snapshotx://command?parameter=value`. Coordinates start at the lower-left corner of the display. They can be switched off in Settings → General.

| Command | Parameters |
| --- | --- |
| `capture-area` | `x`, `y`, `width`, `height`, `display`, `action` |
| `capture-previous-area` | `action` |
| `capture-fullscreen` | `display`, `action` |
| `capture-window` | `action` |
| `scrolling-capture` | `x`, `y`, `width`, `height`, `display`, `autoscroll`, `action` |
| `capture-text` | `x`, `y`, `width`, `height`, `display`, `filepath`, `linebreaks` |
| `pin` | `filepath` |
| `open-annotate` | `filepath` |
| `open-from-clipboard` | |
| `add-quick-access-overlay` | `filepath` |
| `open-history` | |
| `open-settings` | `tab` (`general`, `screenshots`, `shortcuts`, `permissions`) |

- `display`: 1 is the main display, 2 the next, and so on. Without it, the display under the pointer is used.
- `action`: `copy`, `save`, `annotate` or `pin`. Without it, the normal Quick Access Overlay flow runs.
- `filepath`: must be an absolute path.

A capture started from a URL still plays the shutter sound and shows a toast or the overlay, so it is never silent.

## Troubleshooting

**No menu bar icon.** macOS silently hides menu bar icons that don't fit, which happens on Macs with a notch and a crowded menu bar. SnapShotX notices, explains it once in Settings, and offers **Settings → General → Show SnapShotX in the Dock**: right-click the Dock icon for the same menu. The keyboard shortcuts work either way. Quitting a few other menu bar apps also frees room.

## Not built yet

All-in-One mode, screen recording, the video editor, horizontal scrolling capture, combining images by drag and drop, and Auto Balance for backgrounds.
