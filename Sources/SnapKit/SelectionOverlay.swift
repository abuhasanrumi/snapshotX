import AppKit

/// Full-screen dimmed overlays (one per display) used to drag out an area or pick a window.
@MainActor
final class SelectionSession {
    enum Mode {
        case area
        case window([WindowCandidate])
    }

    enum Result {
        /// `rect` is in AppKit global coordinates.
        case area(screen: NSScreen, rect: CGRect)
        case window(UInt32)
        case cancelled
    }

    private(set) var hovered: WindowCandidate?
    private var candidates: [WindowCandidate] = []
    private var isWindowMode = false
    private var windows: [OverlayWindow] = []
    private var continuation: CheckedContinuation<Result, Never>?
    private var previousApp: NSRunningApplication?

    var isRunning: Bool { continuation != nil }

    func run(_ mode: Mode) async -> Result {
        guard continuation == nil else { return .cancelled }
        previousApp = NSWorkspace.shared.frontmostApplication
        switch mode {
        case .area:
            isWindowMode = false
        case .window(let found):
            isWindowMode = true
            candidates = found
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            for screen in NSScreen.screens {
                let window = OverlayWindow(screen: screen, session: self, windowMode: isWindowMode)
                windows.append(window)
                window.orderFrontRegardless()
            }
            NSApp.activate(ignoringOtherApps: true)
            let underMouse = windows.first { $0.frame.contains(NSEvent.mouseLocation) } ?? windows.first
            underMouse?.makeKeyAndOrderFront(nil)
            updateHover(at: NSEvent.mouseLocation)
        }
    }

    func finish(_ result: Result) {
        guard let continuation else { return }
        self.continuation = nil
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        hovered = nil
        candidates = []

        // Hand focus back so the user's app isn't left deactivated.
        if let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp.activate()
        }
        previousApp = nil
        continuation.resume(returning: result)
    }

    func cancel() { finish(.cancelled) }

    func updateHover(at globalPoint: CGPoint) {
        guard isWindowMode else { return }
        let hit = Geometry.topmost(at: globalPoint, in: candidates)
        if hit != hovered {
            hovered = hit
            for window in windows { window.contentView?.needsDisplay = true }
        }
    }

    func hoveredFrame(in view: NSView) -> NSRect? {
        guard let hovered, let window = view.window else { return nil }
        return view.convert(window.convertFromScreen(hovered.frame), from: nil)
    }

    func pickHoveredWindow() {
        if let hovered { finish(.window(hovered.id)) }
    }
}

private final class OverlayWindow: NSWindow {
    init(screen: NSScreen, session: SelectionSession, windowMode: Bool) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                    screen: screen, session: session, windowMode: windowMode)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionView: NSView {
    private let screen: NSScreen
    private unowned let session: SelectionSession
    private let windowMode: Bool

    private var dragStart: NSPoint?
    private var dragRect: NSRect?
    private var mouse: NSPoint?

    init(frame: NSRect, screen: NSScreen, session: SelectionSession, windowMode: Bool) {
        self.screen = screen
        self.session = session
        self.windowMode = windowMode
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: Events

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { session.cancel() } else { super.keyDown(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        session.updateHover(at: NSEvent.mouseLocation)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if windowMode {
            session.updateHover(at: NSEvent.mouseLocation)
            session.pickHoveredWindow()
        } else {
            dragStart = point
            dragRect = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !windowMode, let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        mouse = point
        dragRect = Geometry.normalizedRect(from: start, to: point).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !windowMode else { return }
        defer { dragStart = nil }
        guard let rect = dragRect, rect.width >= 3, rect.height >= 3, let window else {
            dragRect = nil
            needsDisplay = true
            return
        }
        let global = window.convertToScreen(convert(rect, to: nil))
        session.finish(.area(screen: screen, rect: global))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        context.fill(bounds)

        let highlight = windowMode ? session.hoveredFrame(in: self) : dragRect
        if let rect = highlight, rect.width > 0, rect.height > 0 {
            // Punch a hole, then refill with near-zero alpha so the window still receives clicks there.
            context.setBlendMode(.clear)
            context.fill(rect)
            context.setBlendMode(.normal)

            if windowMode {
                context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.22).cgColor)
                context.fill(rect)
                context.setStrokeColor(NSColor.systemBlue.cgColor)
                context.setLineWidth(3)
                context.stroke(rect.insetBy(dx: 1.5, dy: 1.5))
            } else {
                context.setFillColor(NSColor.black.withAlphaComponent(0.01).cgColor)
                context.fill(rect)
                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineWidth(1)
                context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            }
            drawLabel(sizeText(for: rect), near: rect)
        } else if !windowMode, let mouse {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: bounds.minX, y: mouse.y + 0.5))
            context.addLine(to: CGPoint(x: bounds.maxX, y: mouse.y + 0.5))
            context.move(to: CGPoint(x: mouse.x + 0.5, y: bounds.minY))
            context.addLine(to: CGPoint(x: mouse.x + 0.5, y: bounds.maxY))
            context.strokePath()
        }
    }

    private func sizeText(for rect: NSRect) -> String {
        "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
    }

    private func drawLabel(_ text: String, near rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let pill = NSSize(width: size.width + 12, height: size.height + 6)

        var origin = NSPoint(x: rect.minX, y: rect.maxY + 6)
        if origin.y + pill.height > bounds.maxY { origin.y = rect.maxY - pill.height - 6 }
        origin.x = min(max(origin.x, bounds.minX + 4), bounds.maxX - pill.width - 4)

        let pillRect = NSRect(origin: origin, size: pill)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6).fill()
        string.draw(at: NSPoint(x: pillRect.minX + 6, y: pillRect.minY + 3))
    }
}
