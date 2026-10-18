import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One editor window per capture. Owns the document and the copy, save and drag actions.
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    private static var open: [EditorWindowController] = []

    let document: AnnotationDocument
    private let window: NSWindow
    private let prefs: Preferences
    private let cache = EffectCache()
    private var subtitleReset: DispatchWorkItem?

    static func show(image: CGImage, state: EditorState = EditorState(), title: String,
                     prefs: Preferences, presets: BackgroundPresetStore) {
        let controller = EditorWindowController(image: image, state: state, title: title, prefs: prefs, presets: presets)
        open.append(controller)
        controller.present()
    }

    private init(image: CGImage, state: EditorState, title: String, prefs: Preferences, presets: BackgroundPresetStore) {
        document = AnnotationDocument(image: image, state: state)
        self.prefs = prefs
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()

        let actions = EditorActions(
            copy: { [weak self] in self?.copyToClipboard() },
            save: { [weak self] in self?.saveToFolder() },
            saveAs: { [weak self] in self?.saveAs() },
            saveProject: { [weak self] in self?.saveProject() },
            pin: { [weak self] in self?.pinToScreen() },
            dragFileURL: { [weak self] in self?.writeDragFile() }
        )
        window.contentViewController = NSHostingController(
            rootView: EditorView(document: document, presets: presets, actions: actions)
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 560)
        window.delegate = self
    }

    private func present() {
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let width = min(max(CGFloat(document.baseImage.width) / backing + 120, 1000), visible.width * 0.94)
        let height = min(max(CGFloat(document.baseImage.height) / backing + 150, 640), visible.height * 0.94)
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }

    // MARK: Output

    private func flattened() -> CGImage? {
        Renderer.export(base: document.baseImage, state: document.state, cache: cache)
    }

    private func flash(_ message: String) {
        window.subtitle = message
        subtitleReset?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.window.subtitle = "" }
        subtitleReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func copyToClipboard() {
        guard let image = flattened() else { return flash("Could not render the image") }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
        flash("Copied to clipboard")
    }

    private func pinToScreen() {
        guard let image = flattened() else { return flash("Could not render the image") }
        PinManager.shared.pin(image)
        flash("Pinned to screen")
    }

    private func saveToFolder() {
        guard let image = flattened() else { return flash("Could not render the image") }
        let folder = prefs.saveFolder
        let url = CaptureCoordinator.uniqueURL(in: folder, date: Date())
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try ImageFile.writePNG(image, to: url)
            flash("Saved \(url.lastPathComponent)")
        } catch {
            flash("Save failed: \(error.localizedDescription)")
        }
    }

    private func saveAs() {
        guard let image = flattened() else { return flash("Could not render the image") }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = prefs.saveFolder
        panel.nameFieldStringValue = CaptureCoordinator.fileName(for: Date())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ImageFile.writePNG(image, to: url)
            flash("Saved \(url.lastPathComponent)")
        } catch {
            flash("Save failed: \(error.localizedDescription)")
        }
    }

    private func saveProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ProjectFile.contentType]
        panel.directoryURL = prefs.saveFolder
        panel.nameFieldStringValue = CaptureCoordinator.fileName(for: Date())
            .replacingOccurrences(of: ".png", with: ".\(ProjectFile.fileExtension)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ProjectFile.encode(image: document.baseImage, state: document.state)
            try data.write(to: url, options: .atomic)
            flash("Saved project \(url.lastPathComponent)")
        } catch {
            flash("Save failed: \(error.localizedDescription)")
        }
    }

    private func writeDragFile() -> URL? {
        guard let image = flattened() else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapShotX-Drag", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(CaptureCoordinator.fileName(for: Date()))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try ImageFile.writePNG(image, to: url)
            return url
        } catch {
            return nil
        }
    }
}

/// Without a main menu an accessory app has no ⌘Z, ⌘C, ⌘V or ⌘W, so the editor installs a minimal one.
enum MainMenu {
    @MainActor
    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit SnapShotX", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: NSSelectorFromString("cut:"), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: NSSelectorFromString("paste:"), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}
