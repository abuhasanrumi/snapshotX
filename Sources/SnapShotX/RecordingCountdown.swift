import AppKit
import SwiftUI

private final class CountdownModel: ObservableObject {
    @Published var remaining: Int
    init(_ value: Int) { remaining = value }
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel

    var body: some View {
        Text("\(model.remaining)")
            .font(.system(size: 64, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 130, height: 130)
            .background(Circle().fill(Color.black.opacity(0.7)))
            .overlay(alignment: .bottom) {
                Text("Click to cancel").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    .padding(.bottom, 14)
            }
            .padding(10)
    }
}

/// A big number counting down in the middle of the area about to be recorded. Clicking it cancels.
@MainActor
enum RecordingCountdown {
    /// Returns false if the user cancelled. The window is gone by the time this returns, so it is never in the video.
    static func run(seconds: Int, over region: CGRect, isCancelled: () -> Bool = { false }) async -> Bool {
        guard seconds > 0 else { return true }
        let model = CountdownModel(seconds)
        let hosting = NSHostingView(rootView: CountdownView(model: model))
        let size = NSSize(width: 150, height: 150)
        let panel = CountdownPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        panel.setFrameOrigin(NSPoint(x: region.midX - size.width / 2, y: region.midY - size.height / 2))
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil)
        }

        for value in stride(from: seconds, through: 1, by: -1) {
            model.remaining = value
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if panel.wasClicked || Task.isCancelled || isCancelled() { return false }
        }
        panel.orderOut(nil)
        // Give the window server a moment to take it off screen before capture starts.
        try? await Task.sleep(nanoseconds: 200_000_000)
        return true
    }
}

private final class CountdownPanel: NSPanel {
    var wasClicked = false
    override var canBecomeKey: Bool { false }
    override func mouseDown(with event: NSEvent) { wasClicked = true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { wasClicked = true }
        super.sendEvent(event)
    }
}
