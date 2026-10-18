import AppKit
import SwiftUI

final class ScrollingHUDModel: ObservableObject {
    @Published var heightPixels = 0
    @Published var status = "Scroll the content, then press Done"
    @Published var autoScroll = false
    @Published var axis = ScrollAxis.vertical
    /// Full-page mode drives everything itself, so the manual controls are hidden.
    var isAutomatic = false
    var onDone: () -> Void = {}
    var onCancel: () -> Void = {}
    /// Asks to turn auto-scroll on or off. Returns the state that actually applies.
    var requestAutoScroll: (Bool) -> Bool = { $0 }
}

/// Captures a region repeatedly while the content scrolls, stitching the frames into one tall image.
/// The user scrolls by hand, or turns on auto-scroll (which needs the Accessibility permission to send scroll events).
@MainActor
final class ScrollingCaptureSession {
    let model = ScrollingHUDModel()

    private let service: CaptureService
    private let permissions: PermissionManager
    private let showCursor: Bool
    private var steadyFrames = 2
    private var finished = false
    private var cancelled = false
    private var outline: NSWindow?
    private var hud: NSPanel?

    init(service: CaptureService, permissions: PermissionManager, showCursor: Bool) {
        self.service = service
        self.permissions = permissions
        self.showCursor = showCursor
    }

    /// Ends the session and keeps what was captured.
    func finish() { finished = true }

    func cancel() {
        cancelled = true
        finished = true
    }

    /// `selection` is in AppKit global coordinates. Returns nil if the user cancelled.
    /// With `fullPage`, scrolls to the start first, then captures all the way to the end without any help.
    func run(on screen: NSScreen, selection: CGRect, autoScroll: Bool, axis: ScrollAxis = .vertical, fullPage: Bool = false) async -> CGImage? {
        model.axis = axis
        model.isAutomatic = fullPage
        steadyFrames = fullPage ? 2 : 3
        model.onDone = { [weak self] in self?.finish() }
        model.onCancel = { [weak self] in self?.cancel() }
        model.requestAutoScroll = { [weak self] wanted in self?.authorizeAutoScroll(wanted) ?? false }
        model.autoScroll = (autoScroll || fullPage) ? authorizeAutoScroll(true) : false
        if fullPage && !model.autoScroll { return nil }

        showOutline(around: selection)
        showHUD(near: selection, on: screen)
        defer { teardown() }

        var stitcher = ScrollStitcher(axis: model.axis)
        var unchangedFrames = 0

        if fullPage { await scrollToStart(on: screen, selection: selection) }

        while !finished {
            // Changing direction mid-capture starts over, since the frames so far were stitched the other way.
            if model.axis != stitcher.axis { stitcher = ScrollStitcher(axis: model.axis); unchangedFrames = 0 }
            if model.autoScroll {
                let length = model.axis == .vertical ? selection.height : selection.width
                postScroll(pixels: Int(min(length * (fullPage ? 0.7 : 0.5), fullPage ? 900 : 500)), at: selection, axis: model.axis)
                try? await Task.sleep(nanoseconds: 450_000_000) // let smooth scrolling settle
                if finished { break }
            }

            let frame: CGImage
            do {
                frame = try await service.captureArea(on: screen, selection: selection, showCursor: showCursor)
            } catch {
                model.status = "Capture failed: \(error.localizedDescription)"
                break
            }

            switch stitcher.add(frame) {
            case .first:
                model.status = "Scroll the content, then press Done"
            case .appended:
                unchangedFrames = 0
                model.status = model.autoScroll ? "Scrolling…" : "Capturing…"
            case .unchanged:
                unchangedFrames += 1
                // In auto-scroll, three frames with no movement means the end of the content.
                if model.autoScroll, unchangedFrames >= steadyFrames { finished = true }
            case .noMatch:
                model.status = "Lost track. Scroll back a little, or slower."
            case .full:
                model.status = "Reached the maximum height"
                finished = true
            }
            model.heightPixels = stitcher.height

            if !model.autoScroll { try? await Task.sleep(nanoseconds: 110_000_000) }
        }

        return cancelled ? nil : stitcher.finish()
    }

    // MARK: Auto-scroll

    private func authorizeAutoScroll(_ wanted: Bool) -> Bool {
        guard wanted else { return false }
        permissions.refresh()
        if permissions.accessibility { return true }
        permissions.requestAccessibility()
        model.status = "Allow Accessibility in System Settings to auto-scroll"
        return false
    }

    /// Scrolls back to the beginning of the content by scrolling up until two frames in a row look the same.
    private func scrollToStart(on screen: NSScreen, selection: CGRect) async {
        model.status = "Going to the top…"
        var previous: GrayFrame?
        var still = 0
        for _ in 0..<80 where !finished {
            postScroll(pixels: -Int(selection.height), at: selection, axis: model.axis)
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let image = try? await service.captureArea(on: screen, selection: selection, showCursor: showCursor),
                  let gray = GrayFrame(image: model.axis == .horizontal ? (image.transposed() ?? image) : image) else { continue }
            if let previous, ShiftEstimator.estimate(from: previous, to: gray) == .unchanged { still += 1 } else { still = 0 }
            previous = gray
            if still >= 2 { break }
        }
        model.status = "Capturing…"
    }

    /// Positive `pixels` scrolls forward (down or right); negative scrolls back.
    private func postScroll(pixels: Int, at selection: CGRect, axis: ScrollAxis = .vertical) {
        guard pixels != 0 else { return }
        // CoreGraphics event coordinates have a top-left origin on the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: selection.midX, y: primaryHeight - selection.midY)
        let vertical = axis == .vertical
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: vertical ? Int32(-pixels) : 0, wheel2: vertical ? 0 : Int32(-pixels), wheel3: 0) else { return }
        event.location = point
        event.post(tap: .cghidEventTap)
    }

    // MARK: Windows

    private func showOutline(around selection: CGRect) {
        let frame = selection.insetBy(dx: -3, dy: -3)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.systemBlue.cgColor
        view.layer?.borderWidth = 3
        view.layer?.cornerRadius = 3
        window.contentView = view
        window.orderFrontRegardless()
        outline = window
    }

    private func showHUD(near selection: CGRect, on screen: NSScreen) {
        let hosting = NSHostingView(rootView: ScrollingHUDView(model: model))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting

        // Below the region if there's room, otherwise above it, otherwise tucked inside the screen's top edge.
        let area = screen.visibleFrame
        var y = selection.minY - size.height - 12
        if y < area.minY { y = selection.maxY + 12 }
        if y + size.height > area.maxY { y = area.maxY - size.height - 12 }
        let x = min(max(selection.midX - size.width / 2, area.minX + 8), area.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        hud = panel
    }

    private func teardown() {
        outline?.orderOut(nil)
        hud?.orderOut(nil)
        outline = nil
        hud = nil
    }
}

struct ScrollingHUDView: View {
    @ObservedObject var model: ScrollingHUDModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status).font(.system(size: 12, weight: .medium))
                Text(model.axis == .vertical ? "\(model.heightPixels) px tall" : "\(model.heightPixels) px wide").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            if !model.isAutomatic {
                IconButton(symbol: model.axis == .vertical ? "arrow.up.and.down" : "arrow.left.and.right",
                           help: model.axis == .vertical ? "Scrolling down. Click for sideways" : "Scrolling sideways. Click for down",
                           size: 28) {
                    model.axis = model.axis == .vertical ? .horizontal : .vertical
                }
            }
            IconButton(symbol: model.autoScroll ? "arrow.down.circle.fill" : "arrow.down.circle",
                       help: model.autoScroll ? "Auto-scroll is on" : "Auto-scroll for me (needs Accessibility)",
                       size: 28, isOn: model.autoScroll) {
                model.autoScroll = model.requestAutoScroll(!model.autoScroll)
            }
            IconButton(symbol: "checkmark", help: "Done", style: .accent, size: 30) { model.onDone() }
            IconButton(symbol: "xmark", help: "Cancel", size: 26) { model.onCancel() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .padding(8)
    }
}
