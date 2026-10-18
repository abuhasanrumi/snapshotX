import AVFoundation
import AppKit
import SwiftUI

/// One Studio Mode window per recording.
@MainActor
final class StudioWindowController: NSObject, NSWindowDelegate {
    private static var open: [StudioWindowController] = []

    private let document: StudioDocument
    private let window: NSWindow
    private let prefs: Preferences
    private let title: String

    /// Opens (or brings forward) the editor for a recording in history.
    static func show(item: CaptureItem, history: HistoryStore, prefs: Preferences, presets: BackgroundPresetStore) async {
        let url = history.url(for: item)
        if let existing = open.first(where: { $0.document.asset.url == url }) {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration).seconds, duration > 0,
              let size = try? await track.load(.naturalSize) else {
            Toast.show("Couldn't open this recording", symbol: "exclamationmark.triangle.fill")
            return
        }
        var cursor: CursorTrack?
        if let data = try? Data(contentsOf: history.cursorURL(for: item)) { cursor = try? JSONDecoder().decode(CursorTrack.self, from: data) }
        let document = StudioDocument(videoURL: url, cursor: cursor, projectURL: history.studioURL(for: item),
                                      duration: duration, sourceSize: CGSize(width: abs(size.width), height: abs(size.height)))
        let title = "Studio · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))"
        let controller = StudioWindowController(document: document, prefs: prefs, presets: presets, title: title)
        open.append(controller)
        controller.present()
    }

    private init(document: StudioDocument, prefs: Preferences, presets: BackgroundPresetStore, title: String) {
        self.document = document
        self.prefs = prefs
        self.title = title
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.contentViewController = NSHostingController(
            rootView: StudioView(document: document, presets: presets, onExport: { [weak self] in self?.export($0) })
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 620)
        window.delegate = self
    }

    private func present() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        document.pause()
        document.saveNow()
        Self.open.removeAll { $0 === self }
    }

    private func export(_ format: StudioExporter.Format) {
        let panel = NSSavePanel()
        panel.directoryURL = prefs.saveFolder
        panel.allowedContentTypes = [format == .mp4 ? .mpeg4Movie : .gif]
        panel.nameFieldStringValue = CaptureCoordinator.fileName(for: Date(), ext: format.rawValue)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await document.export(to: url, format: format) }
    }
}
