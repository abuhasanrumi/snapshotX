import AppKit
import SwiftUI

/// One shortcut for every kind of capture: a dimmed screen with an adjustable region and a toolbar to pick the mode.
/// Drag to select, drag inside to move, drag edges or corners to resize, or type an exact size. The last region
/// and mode are remembered, so retaking the same shot is a single keystroke.
@MainActor
final class AllInOneSession {
    enum Result {
        /// The region is in AppKit global coordinates.
        case capture(mode: AllInOneMode, screen: NSScreen, rect: CGRect)
        /// The mode is the one selected when Fullscreen was chosen, so Record Screen records the display.
        case fullscreen(NSScreen, mode: AllInOneMode)
        /// The user chose Window: hand over to the window picker, with the mode that was selected.
        case window(mode: AllInOneMode)
        case cancelled
    }

    final class Model: ObservableObject {
        @Published var mode: AllInOneMode = .area
        @Published var lockAspect = false
        @Published var widthText = ""
        @Published var heightText = ""
        @Published var hasSelection = false
        var onConfirm: () -> Void = {}
        var onCancel: () -> Void = {}
        var onWindow: () -> Void = {}
        var onFullscreen: () -> Void = {}
        var onApplySize: () -> Void = {}
        var onLockChanged: (Bool) -> Void = { _ in }
    }

    let model = Model()
    private let defaults: UserDefaults
    private let prefs: Preferences

    private(set) var selectionScreen: NSScreen?
    /// In the selection screen's local coordinates (bottom-left origin, points).
    private(set) var selection: CGRect?
    private(set) var lockedAspect: CGFloat = 16.0 / 9

    private var windows: [AllInOneOverlayWindow] = []
    private var toolbar: AllInOneToolbarPanel?
    private var continuation: CheckedContinuation<Result, Never>?
    private var previousApp: NSRunningApplication?

    var isRunning: Bool { continuation != nil }

    init(prefs: Preferences, defaults: UserDefaults = .standard) {
        self.prefs = prefs
        self.defaults = defaults
    }

    /// `initial` is a region in AppKit global coordinates to start from, if any.
    func run(initial: (screen: NSScreen, rect: CGRect)?, mode: AllInOneMode) async -> Result {
        guard continuation == nil else { return .cancelled }
        previousApp = NSWorkspace.shared.frontmostApplication

        model.mode = mode
        model.lockAspect = false
        model.onConfirm = { [weak self] in self?.confirm() }
        model.onCancel = { [weak self] in self?.cancel() }
        model.onWindow = { [weak self] in
            guard let self else { return }
            finish(.window(mode: model.mode))
        }
        model.onFullscreen = { [weak self] in self?.chooseFullscreen() }
        model.onApplySize = { [weak self] in self?.applyTypedSize() }
        model.onLockChanged = { [weak self] on in self?.lockChanged(on) }

        selectionScreen = initial?.screen
        selection = initial.map { local($0.rect, on: $0.screen) }
        syncModel()

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            for screen in NSScreen.screens {
                let window = AllInOneOverlayWindow(screen: screen, session: self)
                windows.append(window)
                window.orderFrontRegardless()
            }
            showToolbar(on: initial?.screen ?? NSScreen.underMouse ?? NSScreen.screens[0])
            NSApp.activate(ignoringOtherApps: true)
            let focus = windows.first { $0.frame.contains(NSEvent.mouseLocation) } ?? windows.first
            focus?.makeKeyAndOrderFront(nil)
            redraw()
        }
    }

    func cancel() { finish(.cancelled) }

    // MARK: Selection

    func selectionInView(for screen: NSScreen) -> CGRect? {
        guard let selection, let selectionScreen, selectionScreen.displayID == screen.displayID else { return nil }
        return selection
    }

    func setSelection(_ rect: CGRect?, on screen: NSScreen?) {
        selection = rect
        selectionScreen = rect == nil ? nil : screen
        syncModel()
        redraw()
    }

    /// Moves the region with the arrow keys.
    func nudge(dx: CGFloat, dy: CGFloat) {
        guard let rect = selection, let screen = selectionScreen else { return }
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        setSelection(SelectionEditor.moved(rect, by: CGVector(dx: dx, dy: dy), within: bounds), on: screen)
    }

    private func local(_ global: CGRect, on screen: NSScreen) -> CGRect {
        global.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    private func syncModel() {
        model.hasSelection = selection != nil
        if let selection {
            model.widthText = "\(Int(selection.width.rounded()))"
            model.heightText = "\(Int(selection.height.rounded()))"
        } else {
            model.widthText = ""
            model.heightText = ""
        }
    }

    private func redraw() {
        for window in windows { window.contentView?.needsDisplay = true }
    }

    private func lockChanged(_ on: Bool) {
        guard on else { return }
        if let selection, selection.height > 0 { lockedAspect = selection.width / selection.height }
    }

    private func applyTypedSize() {
        guard let rect = selection, let screen = selectionScreen else { return }
        let width = Double(model.widthText.trimmingCharacters(in: .whitespaces)).map { CGFloat($0) }
        let height = Double(model.heightText.trimmingCharacters(in: .whitespaces)).map { CGFloat($0) }
        // Only the field that changed drives the aspect ratio when it is locked.
        let widthChanged = width.map { abs($0 - rect.width.rounded()) >= 1 } ?? false
        let heightChanged = height.map { abs($0 - rect.height.rounded()) >= 1 } ?? false
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        let resized = SelectionEditor.withSize(rect, width: widthChanged ? width : nil, height: heightChanged ? height : nil,
                                               within: bounds, lockAspect: model.lockAspect, aspect: lockedAspect)
        setSelection(resized, on: screen)
    }

    // MARK: Finishing

    func confirm() {
        guard let rect = selection, let screen = selectionScreen, rect.width >= 3, rect.height >= 3 else {
            NSSound.beep()
            return
        }
        if let id = screen.displayID {
            AllInOneMemory(displayID: id, rect: rect, mode: model.mode).save(to: defaults)
        }
        finish(.capture(mode: model.mode, screen: screen, rect: rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)))
    }

    private func chooseFullscreen() {
        guard let screen = selectionScreen ?? NSScreen.underMouse else { return cancel() }
        finish(.fullscreen(screen, mode: model.mode))
    }

    private func finish(_ result: Result) {
        guard let continuation else { return }
        self.continuation = nil
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        toolbar?.orderOut(nil)
        toolbar = nil

        if let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp.activate() }
        previousApp = nil
        continuation.resume(returning: result)
    }

    // MARK: Toolbar

    private func showToolbar(on screen: NSScreen) {
        let hosting = NSHostingView(rootView: AllInOneToolbarView(model: model, prefs: prefs))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let panel = AllInOneToolbarPanel(size: size, onCancel: { [weak self] in self?.cancel() })
        panel.contentView = hosting
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 28))
        panel.orderFrontRegardless()
        toolbar = panel
    }
}

// MARK: - Toolbar

private final class AllInOneToolbarPanel: NSPanel {
    private let onCancel: () -> Void

    init(size: NSSize, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    // Needs to take key focus so the size fields accept typing.
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

struct AllInOneToolbarView: View {
    @ObservedObject var model: AllInOneSession.Model
    @ObservedObject var prefs: Preferences

    var body: some View {
        HStack(spacing: 10) {
            // What to do with the region: the highlighted one is what Return does.
            HStack(spacing: 2) {
                ForEach(AllInOneMode.allCases) { mode in
                    IconButton(symbol: mode.symbol, help: mode.title, shape: .square, size: 32, isOn: model.mode == mode) {
                        model.mode = mode
                    }
                }
            }
            if model.mode == .record { recordingOptionsMenu }
            divider
            // These two don't need a region: they act straight away.
            HStack(spacing: 2) {
                IconButton(symbol: "macwindow", help: "Pick a window", shape: .square, size: 32) { model.onWindow() }
                IconButton(symbol: "display", help: "Whole screen", shape: .square, size: 32) { model.onFullscreen() }
            }
            divider
            HStack(spacing: 5) {
                sizeField("W", text: $model.widthText)
                Image(systemName: "multiply").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                sizeField("H", text: $model.heightText)
                IconButton(symbol: model.lockAspect ? "lock.fill" : "lock.open", help: "Lock aspect ratio",
                           shape: .square, size: 28, isOn: model.lockAspect) {
                    model.lockAspect.toggle()
                    model.onLockChanged(model.lockAspect)
                }
            }
            divider
            IconButton(symbol: model.mode.confirmSymbol, help: "\(model.mode.confirmTitle)  ⏎",
                       style: model.mode == .record ? .destructive : .accent, size: 34) { model.onConfirm() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.hasSelection)
            IconButton(symbol: "xmark", help: "Cancel  ⎋", size: 26) { model.onCancel() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .padding(8)
    }

    private var divider: some View { Divider().frame(height: 20) }

    /// The choices that matter most when starting a recording. The rest live in Settings.
    private var recordingOptionsMenu: some View {
        Menu {
            Picker("Format", selection: $prefs.recording.format) {
                ForEach(RecordingFormat.allCases) { Text($0.title).tag($0) }
            }
            Picker("Countdown", selection: $prefs.recording.countdown) {
                ForEach(RecordingOptions.countdownChoices, id: \.self) { Text($0 == 0 ? "No countdown" : "\($0) seconds").tag($0) }
            }
            Divider()
            Toggle("Microphone", isOn: $prefs.recording.microphone)
            Toggle("System audio", isOn: $prefs.recording.systemAudio)
            Toggle("Camera", isOn: $prefs.recording.camera)
            Divider()
            Toggle("Show cursor", isOn: $prefs.recording.showCursor)
            Toggle("Studio mode", isOn: $prefs.recording.studioMode)
            Toggle("Highlight clicks", isOn: $prefs.recording.highlightClicks)
            Toggle("Show keystrokes", isOn: $prefs.recording.showKeystrokes)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Recording options")
    }

    private func sizeField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .multilineTextAlignment(.center)
            .frame(width: 54)
            .onSubmit { model.onApplySize() }
            .disabled(!model.hasSelection)
            .help(label == "W" ? "Width in points" : "Height in points")
    }
}

// MARK: - Overlay

private final class AllInOneOverlayWindow: NSWindow {
    init(screen: NSScreen, session: AllInOneSession) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = AllInOneView(frame: CGRect(origin: .zero, size: screen.frame.size), screen: screen, session: session)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class AllInOneView: NSView {
    private let screen: NSScreen
    private unowned let session: AllInOneSession

    private enum Drag {
        case creating(start: CGPoint)
        case moving(last: CGPoint)
        case resizing(SelectionHandle)
    }

    private var drag: Drag?
    private var mouse: NSPoint?
    private let grab: CGFloat = 8

    init(frame: NSRect, screen: NSScreen, session: AllInOneSession) {
        self.screen = screen
        self.session = session
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: Cursor

    private func cursor(at point: CGPoint) -> NSCursor {
        guard let rect = session.selectionInView(for: screen) else { return .crosshair }
        if let handle = SelectionEditor.handle(at: point, in: rect, tolerance: grab) {
            switch handle {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            default: return .crosshair
            }
        }
        return rect.contains(point) ? .openHand : .crosshair
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouse = point
        cursor(at: point).set()
        needsDisplay = true
    }

    // MARK: Mouse and keys

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53: session.cancel()
        case 36, 76: session.confirm()
        case 123: session.nudge(dx: -step, dy: 0)
        case 124: session.nudge(dx: step, dy: 0)
        case 125: session.nudge(dx: 0, dy: -step)
        case 126: session.nudge(dx: 0, dy: step)
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let rect = session.selectionInView(for: screen) {
            if let handle = SelectionEditor.handle(at: point, in: rect, tolerance: grab) {
                drag = .resizing(handle)
                return
            }
            if rect.contains(point) {
                drag = .moving(last: point)
                NSCursor.closedHand.set()
                return
            }
        }
        drag = .creating(start: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouse = point
        let model = session.model
        switch drag {
        case .creating(let start):
            let rect = SelectionEditor.created(from: start, to: point, within: bounds, lockAspect: model.lockAspect,
                                               aspect: session.lockedAspect)
            session.setSelection(rect, on: screen)
        case .moving(let last):
            guard let rect = session.selectionInView(for: screen) else { return }
            let moved = SelectionEditor.moved(rect, by: CGVector(dx: point.x - last.x, dy: point.y - last.y), within: bounds)
            session.setSelection(moved, on: screen)
            drag = .moving(last: point)
        case .resizing(let handle):
            guard let rect = session.selectionInView(for: screen) else { return }
            let resized = SelectionEditor.resized(rect, handle: handle, to: point, within: bounds,
                                                  lockAspect: model.lockAspect, aspect: session.lockedAspect)
            session.setSelection(resized, on: screen)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            cursor(at: convert(event.locationInWindow, from: nil)).set()
        }
        // A plain click clears the region instead of leaving a speck.
        if let rect = session.selectionInView(for: screen), rect.width < 3 || rect.height < 3 {
            session.setSelection(nil, on: nil)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
        context.fill(bounds)

        if let rect = session.selectionInView(for: screen), rect.width > 0, rect.height > 0 {
            // Punch a hole, then refill with near-zero alpha so the region still receives mouse events.
            context.setBlendMode(.clear)
            context.fill(rect)
            context.setBlendMode(.normal)
            context.setFillColor(NSColor.black.withAlphaComponent(0.01).cgColor)
            context.fill(rect)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1)
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))

            for (_, point) in SelectionEditor.handlePoints(of: rect) {
                let box = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                context.setFillColor(NSColor.white.cgColor)
                context.fill(box)
                context.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor)
                context.stroke(box)
            }
        } else if let mouse {
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: bounds.minX, y: mouse.y + 0.5))
            context.addLine(to: CGPoint(x: bounds.maxX, y: mouse.y + 0.5))
            context.move(to: CGPoint(x: mouse.x + 0.5, y: bounds.minY))
            context.addLine(to: CGPoint(x: mouse.x + 0.5, y: bounds.maxY))
            context.strokePath()
        }
    }
}
