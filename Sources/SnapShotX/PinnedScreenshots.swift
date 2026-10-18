import AppKit

/// Sizing rules for pinned screenshots. Kept free of AppKit state so they can be tested.
enum PinLayout {
    static let minimumWidth: CGFloat = 80

    /// A pin starts at the screenshot's natural size in points, shrunk to fit within `maxFraction` of the screen.
    static func initialSize(imagePixels: CGSize, backingScale: CGFloat, screenVisible: CGSize, maxFraction: CGFloat = 0.6) -> CGSize {
        let natural = CGSize(width: imagePixels.width / backingScale, height: imagePixels.height / backingScale)
        let limit = CGSize(width: screenVisible.width * maxFraction, height: screenVisible.height * maxFraction)
        let fit = min(1, limit.width / natural.width, limit.height / natural.height)
        return CGSize(width: max(1, (natural.width * fit).rounded()), height: max(1, (natural.height * fit).rounded()))
    }

    /// Scales a size, keeping its aspect ratio between a minimum width and a maximum size.
    static func resized(_ size: CGSize, byFactor factor: CGFloat, maxSize: CGSize) -> CGSize {
        let aspect = size.width / size.height
        var width = size.width * factor
        width = max(minimumWidth, width)
        width = min(width, maxSize.width, maxSize.height * aspect)
        width = max(1, width)
        return CGSize(width: width.rounded(), height: (width / aspect).rounded())
    }

    /// The frame with the new size that keeps the same center.
    static func frame(resizing frame: CGRect, to size: CGSize) -> CGRect {
        CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
    }
}

@MainActor
final class PinManager {
    static let shared = PinManager()

    private var windows: [PinnedWindow] = []
    var onChange: () -> Void = {}

    var count: Int { windows.count }

    func pin(_ image: CGImage) {
        let screen = NSScreen.underMouse ?? NSScreen.main
        let backing = screen?.backingScaleFactor ?? 2
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = PinLayout.initialSize(imagePixels: CGSize(width: image.width, height: image.height),
                                         backingScale: backing, screenVisible: visible.size)
        let cascade = CGFloat(windows.count % 6) * 24
        let frame = CGRect(x: visible.midX - size.width / 2 + cascade, y: visible.midY - size.height / 2 - cascade,
                           width: size.width, height: size.height)

        let window = PinnedWindow(image: image, frame: frame, sizeLimit: CGSize(width: visible.width * 3, height: visible.height * 3))
        window.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            self.windows.removeAll { $0 === window }
            self.onChange()
        }
        windows.append(window)
        window.orderFrontRegardless()
        onChange()
    }

    func closeAll() {
        for window in windows { window.close() }
    }

    func unlockAll() {
        for window in windows { window.setLocked(false) }
    }
}

/// A screenshot floating above every other window. Drag to move, scroll or pinch to resize,
/// ⌥-scroll for opacity, arrow keys to nudge, Esc to close, right-click for more.
final class PinnedWindow: NSPanel {
    var onClose: () -> Void = {}
    private let image: CGImage
    private let sizeLimit: CGSize

    init(image: CGImage, frame: CGRect, sizeLimit: CGSize) {
        self.image = image
        self.sizeLimit = sizeLimit
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = PinnedImageView(image: image)
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        super.close()
        onClose()
    }

    func resize(byFactor factor: CGFloat) {
        let size = PinLayout.resized(frame.size, byFactor: factor, maxSize: sizeLimit)
        setFrame(PinLayout.frame(resizing: frame, to: size), display: true)
    }

    func resetSize() {
        let screen = self.screen ?? NSScreen.main
        let size = PinLayout.initialSize(imagePixels: CGSize(width: image.width, height: image.height),
                                         backingScale: screen?.backingScaleFactor ?? 2,
                                         screenVisible: screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900),
                                         maxFraction: 10)
        setFrame(PinLayout.frame(resizing: frame, to: size), display: true)
    }

    func nudge(dx: CGFloat, dy: CGFloat) {
        setFrameOrigin(NSPoint(x: frame.origin.x + dx, y: frame.origin.y + dy))
    }

    func adjustOpacity(by delta: CGFloat) {
        alphaValue = min(1, max(0.1, alphaValue + delta))
    }

    /// A locked pin ignores the mouse, so clicks pass through to the app underneath.
    func setLocked(_ locked: Bool) {
        ignoresMouseEvents = locked
    }

    func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
    }
}

private final class PinnedImageView: NSView {
    private let image: CGImage

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).addClip()
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
    }

    private var pin: PinnedWindow? { window as? PinnedWindow }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        if event.modifierFlags.contains(.option) {
            pin?.adjustOpacity(by: delta * 0.01)
        } else {
            pin?.resize(byFactor: 1 + delta * 0.01)
        }
    }

    override func magnify(with event: NSEvent) {
        pin?.resize(byFactor: 1 + event.magnification)
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: pin?.nudge(dx: -step, dy: 0)
        case 124: pin?.nudge(dx: step, dy: 0)
        case 125: pin?.nudge(dx: 0, dy: -step)
        case 126: pin?.nudge(dx: 0, dy: step)
        case 53: pin?.close()
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(item("Copy", #selector(copyImage)))
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for percent in [100, 75, 50, 25] {
            let entry = item("\(percent)%", #selector(setOpacity(_:)))
            entry.tag = percent
            submenu.addItem(entry)
        }
        opacity.submenu = submenu
        menu.addItem(opacity)
        menu.addItem(item("Actual Size", #selector(actualSize)))
        menu.addItem(item("Lock (clicks pass through)", #selector(lock)))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(closePin)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func copyImage() { pin?.copyToPasteboard() }
    @objc private func setOpacity(_ sender: NSMenuItem) { pin?.alphaValue = CGFloat(sender.tag) / 100 }
    @objc private func actualSize() { pin?.resetSize() }
    @objc private func lock() { pin?.setLocked(true) }
    @objc private func closePin() { pin?.close() }
}
