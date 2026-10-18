import AppKit
import OSLog
import UniformTypeIdentifiers

/// Runs a capture from trigger to delivery: select, capture, store in history, copy/save, show the overlay.
@MainActor
final class CaptureCoordinator {
    private let log = Logger(subsystem: "com.snapshotx.app", category: "capture")

    let history: HistoryStore
    let prefs: Preferences
    let permissions: PermissionManager
    let quickAccess: QuickAccessController

    private let service = CaptureService()
    private let selection = SelectionSession()
    private var busy = false

    var showHistory: () -> Void = {}
    var showPermissions: () -> Void = {}

    init(history: HistoryStore, prefs: Preferences, permissions: PermissionManager) {
        self.history = history
        self.prefs = prefs
        self.permissions = permissions
        self.quickAccess = QuickAccessController(prefs: prefs)
        quickAccess.onCopy = { [weak self] item in self?.copyToClipboard(item) ?? false }
        quickAccess.onSave = { [weak self] item in self?.saveToFolder(item) ?? false }
    }

    func perform(_ action: HotkeyAction) {
        switch action {
        case .captureArea, .captureWindow, .captureFullscreen:
            guard !busy, !selection.isRunning else { return }
            busy = true
            Task {
                defer { busy = false }
                await capture(action)
            }
        case .openHistory:
            showHistory()
        case .allInOne, .scrollingCapture, .recordScreen, .captureText:
            break // later milestones
        }
    }

    // MARK: Capture

    private func capture(_ action: HotkeyAction) async {
        do {
            let image: CGImage
            switch action {
            case .captureFullscreen:
                guard let screen = NSScreen.underMouse else { return }
                image = try await service.captureFullscreen(on: screen, showCursor: prefs.showCursor)
            case .captureArea:
                guard case .area(let screen, let rect) = await selection.run(.area) else { return }
                image = try await service.captureArea(on: screen, selection: rect, showCursor: prefs.showCursor)
            case .captureWindow:
                let candidates = WindowLister.onScreenWindows()
                guard case .window(let id) = await selection.run(.window(candidates)) else { return }
                image = try await service.captureWindow(id: id, showCursor: prefs.showCursor)
            default:
                return
            }
            try deliver(image)
        } catch {
            report(error)
        }
    }

    private func deliver(_ image: CGImage) throws {
        let item = try history.add(image)
        if prefs.playSound { Self.shutterSound?.play() }
        if prefs.autoCopy { _ = copyToClipboard(item) }
        if prefs.autoSave { _ = saveToFolder(item) }
        quickAccess.add(item: item, url: history.url(for: item))
    }

    private func report(_ error: Error) {
        log.error("Capture failed: \(error.localizedDescription, privacy: .public)")
        permissions.refresh()
        let declined = (error as NSError).code == -3801 // SCStreamError.userDeclined
        if declined || !permissions.screenRecording {
            showPermissions()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Capture failed"
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Output actions

    @discardableResult
    func copyToClipboard(_ item: CaptureItem) -> Bool {
        guard let image = NSImage(contentsOf: history.url(for: item)) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    /// Copies the capture into the configured save folder with a timestamped name.
    @discardableResult
    func saveToFolder(_ item: CaptureItem) -> Bool {
        let folder = prefs.saveFolder
        let target = Self.uniqueURL(in: folder, date: item.createdAt)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: history.url(for: item), to: target)
            return true
        } catch {
            log.error("Save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func saveAs(_ item: CaptureItem) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = prefs.saveFolder
        panel.nameFieldStringValue = Self.fileName(for: item.createdAt)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: history.url(for: item), to: target)
    }

    func reveal(_ item: CaptureItem) {
        NSWorkspace.shared.activateFileViewerSelecting([history.url(for: item)])
    }

    func open(_ item: CaptureItem) {
        NSWorkspace.shared.open(history.url(for: item))
    }

    func delete(_ item: CaptureItem) {
        history.remove(item)
    }

    // MARK: Helpers

    private static let shutterSound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true)
    }()

    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "SnapShotX \(formatter.string(from: date)).png"
    }

    static func uniqueURL(in folder: URL, date: Date) -> URL {
        let base = fileName(for: date).replacingOccurrences(of: ".png", with: "")
        var candidate = folder.appendingPathComponent("\(base).png")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter).png")
            counter += 1
        }
        return candidate
    }
}
