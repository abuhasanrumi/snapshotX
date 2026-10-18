import AppKit
import ImageIO
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
    let presets = BackgroundPresetStore()

    private let service = CaptureService()
    private let selection = SelectionSession()
    private let allInOne: AllInOneSession
    private var busy = false
    private var scrollSession: ScrollingCaptureSession?
    private var recording: RecordingSession?
    /// The shortcut whose capture flow is running, so a second press can tell "close it" from "switch to another".
    private var overlayOwner: HotkeyAction?
    /// The last area picked by hand, relative to its display's lower-left corner, for `capture-previous-area`.
    private var lastArea: (displayID: CGDirectDisplayID, rect: CGRect)?

    var showHistory: () -> Void = {}
    var showPermissions: () -> Void = {}
    var showSettings: (SettingsTab) -> Void = { _ in }
    /// Called when a recording starts or ends, so the menu bar icon can show it.
    var onRecordingChange: (Bool) -> Void = { _ in }

    init(history: HistoryStore, prefs: Preferences, permissions: PermissionManager) {
        self.history = history
        self.prefs = prefs
        self.permissions = permissions
        self.allInOne = AllInOneSession(prefs: prefs)
        self.quickAccess = QuickAccessController(prefs: prefs)
        quickAccess.onOpen = { [weak self] item in self?.open(item) }
        quickAccess.onCopy = { [weak self] item in self?.copyToClipboard(item) ?? false }
        quickAccess.onSave = { [weak self] item in self?.saveToFolder(item) ?? false }
        quickAccess.onAnnotate = { [weak self] item in self?.annotate(item) }
    }

    func perform(_ action: HotkeyAction, command: URLCommand? = nil) {
        if action != .openHistory, arbitrate(action, command: command) { return }
        switch action {
        case .captureArea, .captureWindow, .captureFullscreen, .captureText:
            start(action) { await $0.capture(action, command: command) }
        case .scrollingCapture:
            start(action) {
                await $0.captureScrolling(command: command)
                $0.scrollSession = nil
            }
        case .allInOne:
            start(action) { await $0.captureAllInOne(command: command) }
        case .recordScreen:
            start(action) { await $0.startRecording(command: command) }
        case .openHistory:
            showHistory()
        }
    }

    /// Runs a capture flow, remembering which shortcut started it while it is on screen.
    private func start(_ action: HotkeyAction, _ work: @escaping @MainActor (CaptureCoordinator) async -> Void) {
        busy = true
        overlayOwner = action
        Task {
            await work(self)
            busy = false
            overlayOwner = nil
        }
    }

    /// Decides what a shortcut means when something is already going on, so no press is ever ignored without a reason.
    /// Returns true when the press was handled here and no new capture should start.
    private func arbitrate(_ action: HotkeyAction, command: URLCommand?) -> Bool {
        let activity = CaptureActivity(isRecording: recording != nil, isScrolling: scrollSession != nil,
                                       isOverlayOpen: allInOne.isRunning || selection.isRunning,
                                       overlayOwner: overlayOwner, isBusy: busy)
        switch ShortcutArbiter.decide(action, activity: activity) {
        case .start:
            return false
        case .ignore:
            return true
        case .stopRecording:
            recording?.stop()
        case .finishScrolling:
            scrollSession?.finish()
        case .explain(let message):
            Toast.show(message, symbol: action == .scrollingCapture || scrollSession != nil ? "arrow.up.and.down.text.horizontal" : "record.circle")
        case .closeOverlay:
            closeOverlays()
        case .switchToAction:
            closeOverlays()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                MainActor.assumeIsolated { self?.perform(action, command: command) }
            }
        }
        return true
    }

    private func closeOverlays() {
        if allInOne.isRunning { allInOne.cancel() }
        if selection.isRunning { selection.cancel() }
    }

    // MARK: Recording

    /// A region from the command starts recording straight away. Otherwise All-in-One opens in Record mode.
    private func startRecording(command: URLCommand?) async {
        if let local = command?.rect {
            guard let screen = screen(forDisplay: command?.display), let global = globalRect(local, on: screen) else { return }
            await runRecording(.area(screen: screen, rect: global))
        } else {
            await captureAllInOne(command: command, forcedMode: .record)
        }
    }

    private func runRecording(_ target: RecordingSession.Target) async {
        let session = RecordingSession(permissions: permissions)
        recording = session
        onRecordingChange(true)
        defer {
            recording = nil
            onRecordingChange(false)
        }
        do {
            guard let output = try await session.run(target: target, options: prefs.recording) else { return } // cancelled
            try deliverRecording(output)
        } catch {
            report(error)
        }
    }

    private func deliverRecording(_ output: RecordingOutput) throws {
        let item = try history.addRecording(output)
        if prefs.playSound { Self.shutterSound?.play() }
        let copied = prefs.autoCopy && copyToClipboard(item)
        if prefs.autoSave { _ = saveToFolder(item) }
        quickAccess.add(item: item, url: history.url(for: item), notice: copied ? "Copied" : nil)
    }

    // MARK: All-in-One

    private func captureAllInOne(command: URLCommand?, forcedMode: AllInOneMode? = nil) async {
        let memory = AllInOneMemory.load()
        let result = await allInOne.run(initial: allInOneStart(command: command, memory: memory),
                                        mode: forcedMode ?? memory?.mode ?? .area)
        do {
            switch result {
            case .cancelled:
                return
            case .window(let mode):
                if mode == .record {
                    await recordWindow()
                } else {
                    await capture(.captureWindow, command: command)
                }
            case .fullscreen(let screen, let mode):
                if mode == .record {
                    await runRecording(.display(screen))
                } else {
                    let image = try await service.captureFullscreen(on: screen, showCursor: prefs.showCursor)
                    try deliver(image, post: command?.action)
                }
            case .capture(let mode, let screen, let rect):
                switch mode {
                case .area:
                    remember((screen, rect))
                    let image = try await service.captureArea(on: screen, selection: rect, showCursor: prefs.showCursor)
                    try deliver(image, post: command?.action)
                case .scrolling:
                    await runScrolling(in: (screen, rect), autoScroll: command?.autoscroll ?? false, post: command?.action)
                case .text:
                    let shot = try await service.captureArea(on: screen, selection: rect, showCursor: false)
                    await recognizeText(in: shot, command: command)
                case .record:
                    await runRecording(.area(screen: screen, rect: rect))
                }
            }
        } catch {
            report(error)
        }
    }

    /// Picks a window with the hover picker and records it.
    private func recordWindow() async {
        let candidates = WindowLister.onScreenWindows()
        guard case .window(let id) = await selection.run(.window(candidates)),
              let window = candidates.first(where: { $0.id == id }) else { return }
        await runRecording(.window(id: id, frame: window.frame))
    }

    /// The region All-in-One opens with: the one from a command, otherwise the one used last time.
    private func allInOneStart(command: URLCommand?, memory: AllInOneMemory?) -> (screen: NSScreen, rect: CGRect)? {
        if let local = command?.rect, let screen = screen(forDisplay: command?.display) {
            return globalRect(local, on: screen).map { (screen, $0) }
        }
        guard let memory, let screen = NSScreen.screens.first(where: { $0.displayID == memory.displayID }) else { return nil }
        return globalRect(memory.rect, on: screen).map { (screen, $0) }
    }

    /// A region given relative to a display's lower-left corner, as a global rect clipped to that display.
    private func globalRect(_ local: CGRect, on screen: NSScreen) -> CGRect? {
        let global = CGRect(x: screen.frame.minX + local.minX, y: screen.frame.minY + local.minY,
                            width: local.width, height: local.height).intersection(screen.frame)
        return global.isNull || global.width < 1 || global.height < 1 ? nil : global
    }

    // MARK: Capture

    private func capture(_ action: HotkeyAction, command: URLCommand?) async {
        do {
            let image: CGImage
            switch action {
            case .captureFullscreen:
                guard let screen = screen(forDisplay: command?.display) else { return }
                image = try await service.captureFullscreen(on: screen, showCursor: prefs.showCursor)
            case .captureArea:
                guard let area = await resolveArea(command: command) else { return }
                if command?.rect == nil { remember(area) }
                image = try await service.captureArea(on: area.screen, selection: area.rect, showCursor: prefs.showCursor)
            case .captureWindow:
                let candidates = WindowLister.onScreenWindows()
                guard case .window(let id) = await selection.run(.window(candidates)) else { return }
                image = try await service.captureWindow(id: id, showCursor: prefs.showCursor)
            case .captureText:
                if let url = command?.filepath {
                    guard let file = Self.loadImage(at: url) else { throw ImageFile.WriteError() }
                    await recognizeText(in: file, command: command)
                } else {
                    guard let area = await resolveArea(command: command) else { return }
                    let shot = try await service.captureArea(on: area.screen, selection: area.rect, showCursor: false)
                    await recognizeText(in: shot, command: command)
                }
                return
            default:
                return
            }
            try deliver(image, post: command?.action)
        } catch {
            report(error)
        }
    }

    private func captureScrolling(command: URLCommand?) async {
        guard let area = await resolveArea(command: command) else { return }
        await runScrolling(in: area, autoScroll: command?.autoscroll ?? false, post: command?.action)
    }

    private func runScrolling(in area: (screen: NSScreen, rect: CGRect), autoScroll: Bool, post: PostAction?) async {
        let session = ScrollingCaptureSession(service: service, permissions: permissions, showCursor: prefs.showCursor)
        scrollSession = session
        defer { scrollSession = nil }
        guard let image = await session.run(on: area.screen, selection: area.rect, autoScroll: autoScroll) else { return }
        do {
            try deliver(image, post: post)
        } catch {
            report(error)
        }
    }

    /// The region to capture: the one given in a command, or one the user drags out.
    private func resolveArea(command: URLCommand?) async -> (screen: NSScreen, rect: CGRect)? {
        if let local = command?.rect {
            guard let screen = screen(forDisplay: command?.display), let global = globalRect(local, on: screen) else { return nil }
            return (screen, global)
        }
        guard case .area(let screen, let rect) = await selection.run(.area) else { return nil }
        return (screen, rect)
    }

    private func remember(_ area: (screen: NSScreen, rect: CGRect)) {
        guard let id = area.screen.displayID else { return }
        lastArea = (id, CGRect(x: area.rect.minX - area.screen.frame.minX, y: area.rect.minY - area.screen.frame.minY,
                               width: area.rect.width, height: area.rect.height))
    }

    /// Display 1 is the main display, 2 the next one, and so on. Without a number: the display under the pointer.
    private func screen(forDisplay display: Int?) -> NSScreen? {
        if let display, display >= 1, display <= NSScreen.screens.count { return NSScreen.screens[display - 1] }
        return NSScreen.underMouse
    }

    private func recognizeText(in image: CGImage, command: URLCommand?) async {
        let result = await TextRecognizer.recognize(in: image, keepLineBreaks: command?.linebreaks ?? prefs.ocrKeepLineBreaks)
        guard !result.isEmpty else {
            Toast.show("No text found", symbol: "text.magnifyingglass")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result.text, forType: .string)
        if prefs.playSound { Self.shutterSound?.play() }
        Toast.show(result.isQRCode ? "Copied QR code content" : "Copied \(result.text.count) characters",
                   symbol: result.isQRCode ? "qrcode" : "text.viewfinder")
    }

    private func deliver(_ image: CGImage, post: PostAction? = nil) throws {
        let item = try history.add(image)
        if prefs.playSound { Self.shutterSound?.play() }
        switch post {
        case .copy:
            Toast.show(copyToClipboard(item) ? "Copied to clipboard" : "Copy failed")
        case .save:
            Toast.show(saveToFolder(item) ? "Saved to \(prefs.saveFolder.lastPathComponent)" : "Save failed")
        case .annotate:
            annotate(item)
        case .pin:
            pin(item)
        case nil:
            let copied = prefs.autoCopy && copyToClipboard(item)
            if prefs.autoSave { _ = saveToFolder(item) }
            quickAccess.add(item: item, url: history.url(for: item), notice: copied ? "Copied" : nil)
        }
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
        let pasteboard = NSPasteboard.general
        // A recording is copied as a file, so it can be pasted into Finder, Slack, Mail and so on.
        if item.isRecording {
            pasteboard.clearContents()
            return pasteboard.writeObjects([history.url(for: item) as NSURL])
        }
        guard let image = NSImage(contentsOf: history.url(for: item)) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    /// Copies the capture into the configured save folder with a timestamped name.
    @discardableResult
    func saveToFolder(_ item: CaptureItem) -> Bool {
        let folder = prefs.saveFolder
        let target = Self.uniqueURL(in: folder, date: item.createdAt, ext: item.fileExtension)
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
        panel.allowedContentTypes = [UTType(filenameExtension: item.fileExtension) ?? .png]
        panel.directoryURL = prefs.saveFolder
        panel.nameFieldStringValue = Self.fileName(for: item.createdAt, ext: item.fileExtension)
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

    // MARK: Pin and URL commands

    func pin(_ item: CaptureItem) {
        guard !item.isRecording else { return }
        guard let image = Self.loadImage(at: history.url(for: item)) else { return report(ImageFile.WriteError()) }
        PinManager.shared.pin(image)
    }

    /// Runs a `snapshotx://` command. Anything that captures still plays the shutter sound and either shows
    /// the Quick Access Overlay or a toast, so a link can never take a screenshot silently.
    func handle(_ command: URLCommand) {
        guard prefs.urlSchemeEnabled else {
            Toast.show("snapshotx:// commands are turned off in Settings", symbol: "nosign")
            return
        }
        permissions.refresh()

        func capture(_ action: HotkeyAction, _ command: URLCommand) {
            if action.needsScreenRecording, !permissions.screenRecording {
                showPermissions()
                return
            }
            perform(action, command: command)
        }

        switch command.kind {
        case .allInOne: capture(.allInOne, command)
        case .captureArea: capture(.captureArea, command)
        case .capturePreviousArea:
            var repeated = command
            if let last = lastArea, let index = NSScreen.screens.firstIndex(where: { $0.displayID == last.displayID }) {
                repeated.rect = last.rect
                repeated.display = index + 1
            }
            capture(.captureArea, repeated)
        case .captureFullscreen: capture(.captureFullscreen, command)
        case .captureWindow: capture(.captureWindow, command)
        case .scrollingCapture: capture(.scrollingCapture, command)
        case .recordScreen: capture(.recordScreen, command)
        case .captureText:
            if command.filepath != nil { perform(.captureText, command: command) } else { capture(.captureText, command) }
        case .pin:
            guard let image = imageFromCommandOrPanel(command) else { return }
            PinManager.shared.pin(image)
        case .openAnnotate:
            guard let image = imageFromCommandOrPanel(command) else { return }
            EditorWindowController.show(image: image, title: command.filepath?.lastPathComponent ?? "Annotate",
                                        prefs: prefs, presets: presets)
        case .openFromClipboard:
            guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                Toast.show("No image on the clipboard", symbol: "doc.on.clipboard")
                return
            }
            EditorWindowController.show(image: cgImage, title: "Clipboard", prefs: prefs, presets: presets)
        case .addQuickAccessOverlay:
            guard let url = command.filepath, let image = Self.loadImage(at: url),
                  let item = try? history.add(image) else {
                Toast.show("Couldn't open that image", symbol: "exclamationmark.triangle")
                return
            }
            quickAccess.add(item: item, url: history.url(for: item))
        case .openHistory: showHistory()
        case .openSettings: showSettings(command.tab ?? .general)
        }
    }

    private func imageFromCommandOrPanel(_ command: URLCommand) -> CGImage? {
        if let url = command.filepath { return Self.loadImage(at: url) }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Self.loadImage(at: url)
    }

    // MARK: Annotate

    func annotate(_ item: CaptureItem) {
        if item.isRecording {
            guard item.isVideoFile else { return open(item) }
            let (history, prefs, presets) = (self.history, self.prefs, self.presets)
            Task { await StudioWindowController.show(item: item, history: history, prefs: prefs, presets: presets) }
            return
        }
        let url = history.url(for: item)
        guard let image = Self.loadImage(at: url) else { return report(ImageFile.WriteError()) }
        EditorWindowController.show(image: image, title: "Annotate · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))",
                                    prefs: prefs, presets: presets)
    }

    /// Opens an image to annotate, or an editable `.snapshotx` project.
    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, ProjectFile.contentType]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if url.pathExtension.lowercased() == ProjectFile.fileExtension {
            do {
                let project = try ProjectFile.decode(try Data(contentsOf: url))
                EditorWindowController.show(image: project.image, state: project.state, title: url.lastPathComponent,
                                            prefs: prefs, presets: presets)
            } catch {
                report(error)
            }
        } else if let image = Self.loadImage(at: url) {
            EditorWindowController.show(image: image, title: url.lastPathComponent, prefs: prefs, presets: presets)
        } else {
            report(ImageFile.WriteError())
        }
    }

    private static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func delete(_ item: CaptureItem) {
        history.remove(item)
    }

    // MARK: Helpers

    private static let shutterSound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true)
    }()

    private static func baseName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "SnapShotX \(formatter.string(from: date))"
    }

    static func fileName(for date: Date, ext: String = "png") -> String {
        "\(baseName(for: date)).\(ext)"
    }

    static func uniqueURL(in folder: URL, date: Date, ext: String = "png") -> URL {
        let base = baseName(for: date)
        var candidate = folder.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
