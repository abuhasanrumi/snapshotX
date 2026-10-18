import AppKit
@preconcurrency import AVFoundation
import ApplicationServices
import QuartzCore
import SwiftUI

/// Rings that pulse where the mouse is clicked. The overlay windows are real windows on screen, so the
/// recording captures them along with everything else.
@MainActor
final class ClickHighlighter {
    private var monitor: Any?
    private var windows: [NSWindow] = []

    func start() {
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            window.contentView = view
            window.orderFrontRegardless()
            return window
        }
        // Mouse events from other apps need no special permission.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.pulse(at: point) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }

    private func pulse(at point: NSPoint) {
        guard let window = windows.first(where: { $0.frame.contains(point) }), let layer = window.contentView?.layer else { return }
        let radius: CGFloat = 26
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        ring.position = CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
        ring.fillColor = NSColor.systemYellow.withAlphaComponent(0.3).cgColor
        ring.strokeColor = NSColor.systemYellow.cgColor
        ring.lineWidth = 4
        layer.addSublayer(ring)

        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.55
        grow.toValue = 1.35
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        ring.add(group, forKey: "pulse")
        CATransaction.commit()
    }
}

/// Shows the keys being pressed in a pill near the bottom of the recording. Global key events need the
/// Accessibility permission, so `start` reports whether it could begin.
@MainActor
final class KeystrokeOverlay: ObservableObject {
    @Published private(set) var text = ""

    private var monitor: Any?
    private var panel: NSPanel?
    private var buffer = KeystrokeBuffer()
    private var fadeWork: DispatchWorkItem?
    private var anchor = CGRect.zero
    private var onlyCommandKeys = true

    /// `anchor` is the recorded region in AppKit global coordinates. Returns false without Accessibility access.
    func start(anchor: CGRect, onlyCommandKeys: Bool) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        self.anchor = anchor
        self.onlyCommandKeys = onlyCommandKeys

        let hosting = NSHostingView(rootView: KeystrokePill(model: self))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        self.panel = panel

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let label = KeystrokeFormatter.describe(
                keyCode: event.keyCode, characters: event.characters,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags, onlyCommandKeys: self?.onlyCommandKeys ?? true)
            guard let label else { return }
            MainActor.assumeIsolated { self?.show(label) }
        }
        return true
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        fadeWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
        buffer = KeystrokeBuffer()
        text = ""
    }

    private func show(_ label: String) {
        let now = Date()
        buffer.add(label, at: now)
        text = buffer.text(at: now) ?? ""
        guard let panel, let hosting = panel.contentView as? NSHostingView<KeystrokePill> else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? anchor
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let y = min(max(anchor.minY + 28, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()

        fadeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.panel?.orderOut(nil)
                self?.text = ""
            }
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + buffer.idleTimeout, execute: work)
    }
}

private struct KeystrokePill: View {
    @ObservedObject var model: KeystrokeOverlay

    var body: some View {
        Text(model.text.isEmpty ? " " : model.text)
            .font(.system(size: 26, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.78)))
            .padding(6)
    }
}

/// A webcam preview in a floating bubble. It is an ordinary window, so the recording captures it like anything else.
/// Drag it anywhere while recording.
@MainActor
final class CameraBubble {
    private var panel: NSPanel?
    private var session: AVCaptureSession?

    /// `anchor` is the recorded region in AppKit global coordinates. Returns false without camera access or a camera.
    func start(size: CameraBubbleSize, shape: CameraBubbleShape, anchor: CGRect) async -> Bool {
        guard await Self.cameraAllowed(), let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }

        let session = AVCaptureSession()
        session.sessionPreset = .medium
        guard session.canAddInput(input) else { return false }
        session.addInput(input)

        let side = size.points
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = CGRect(x: 0, y: 0, width: side, height: side)
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true // like a mirror, which is what people expect from a self view
        }

        let view = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.wantsLayer = true
        view.layer?.addSublayer(preview)
        view.layer?.masksToBounds = true
        view.layer?.cornerRadius = shape == .circle ? side / 2 : side * 0.18
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        view.layer?.borderWidth = 3

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view

        let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? anchor
        let x = min(max(anchor.minX + 24, visible.minX + 8), visible.maxX - side - 8)
        let y = min(max(anchor.minY + 24, visible.minY + 8), visible.maxY - side - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        self.panel = panel
        self.session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() } // blocks, so keep it off the main thread
        return true
    }

    func stop() {
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session?.stopRunning() }
        self.session = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private static func cameraAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// The window number, so the recording can make sure it is not excluded from capture.
    var windowNumber: Int? { panel?.windowNumber }
}
