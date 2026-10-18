import AppKit
import Combine
import OSLog
import SwiftUI

/// Owns the long-lived pieces of the app: the status item, windows, hotkeys, permissions and capture pipeline.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.snapshotx.app", category: "app")

    let store = ShortcutStore()
    let permissions = PermissionManager()
    let router = SettingsRouter()
    let prefs = Preferences()
    let history = HistoryStore()
    private(set) lazy var coordinator = CaptureCoordinator(history: history, prefs: prefs, permissions: permissions)

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var historyWindow: HistoryWindowController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.showHistory = { [weak self] in self?.showHistory() }
        coordinator.showPermissions = { [weak self] in self?.showSettings(tab: .permissions) }
        coordinator.showSettings = { [weak self] tab in self?.showSettings(tab: tab) }
        historyWindow = HistoryWindowController(
            store: history,
            actions: HistoryActions(
                annotate: { [weak self] in self?.coordinator.annotate($0) },
                pin: { [weak self] in self?.coordinator.pin($0) },
                copy: { [weak self] in self?.coordinator.copyToClipboard($0) },
                saveAs: { [weak self] in self?.coordinator.saveAs($0) },
                reveal: { [weak self] in self?.coordinator.reveal($0) },
                open: { [weak self] in self?.coordinator.open($0) },
                delete: { [weak self] in self?.coordinator.delete($0) }
            )
        )

        MainMenu.install()
        setUpStatusItem()

        HotKeyManager.shared.onAction = { [weak self] action in
            MainActor.assumeIsolated { self?.perform(action) }
        }
        applyHotkeys()

        store.$shortcuts
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyHotkeys()
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        permissions.$screenRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        if !permissions.screenRecording {
            showSettings(tab: .permissions)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(tab: .general)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = URLCommand.parse(url) else {
                Toast.show("Unknown snapshotx:// command", symbol: "questionmark.circle")
                continue
            }
            coordinator.handle(command)
        }
    }

    // MARK: Actions

    func perform(_ action: HotkeyAction) {
        permissions.refresh()
        if action.needsScreenRecording && !permissions.screenRecording {
            log.notice("\(action.rawValue, privacy: .public): Screen Recording not granted, opening Permissions")
            showSettings(tab: .permissions)
            return
        }
        coordinator.perform(action)
    }

    private func applyHotkeys() {
        let active = store.shortcuts.filter { $0.key.isAvailable }
        store.registrationFailures = HotKeyManager.shared.register(active)
        if !store.registrationFailures.isEmpty {
            log.warning("Could not register: \(self.store.registrationFailures.map(\.rawValue).joined(separator: ", "), privacy: .public)")
        }
    }

    // MARK: Status item and menu

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "SnapShotX")
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if !permissions.screenRecording {
            let item = NSMenuItem(title: "Grant Screen Recording Access…", action: #selector(openPermissions), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        for action in HotkeyAction.available {
            if action == .openHistory { menu.addItem(.separator()) }
            let item = NSMenuItem(title: action.title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            if let s = store.shortcut(for: action), !store.registrationFailures.contains(action) {
                item.keyEquivalent = s.label.lowercased()
                item.keyEquivalentModifierMask = Shortcut.cocoaModifiers(from: s.modifiers)
            }
            menu.addItem(item)
        }

        let open = NSMenuItem(title: "Open Image or Project…", action: #selector(openFile), keyEquivalent: "")
        open.target = self
        open.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(open)

        menu.addItem(.separator())
        let closePins = NSMenuItem(title: "Close All Pinned Screenshots", action: #selector(closePinned), keyEquivalent: "")
        closePins.target = self
        menu.addItem(closePins)
        let unlockPins = NSMenuItem(title: "Unlock All Pinned Screenshots", action: #selector(unlockPinned), keyEquivalent: "")
        unlockPins.target = self
        menu.addItem(unlockPins)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit SnapShotX", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = HotkeyAction(rawValue: raw) else { return }
        // Let the menu finish closing so it never ends up in the capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { self?.perform(action) }
        }
    }

    @objc fileprivate func closePinned() { PinManager.shared.closeAll() }
    @objc fileprivate func unlockPinned() { PinManager.shared.unlockAll() }

    @objc private func openFile() {
        DispatchQueue.main.async { [weak self] in self?.coordinator.openFile() }
    }

    @objc private func openSettings() { showSettings(tab: .general) }
    @objc private func openPermissions() { showSettings(tab: .permissions) }

    func showHistory() { historyWindow?.show() }

    // MARK: Settings window

    func showSettings(tab: SettingsTab) {
        router.tab = tab
        if settingsWindow == nil {
            let hosting = NSHostingController(
                rootView: SettingsView()
                    .environmentObject(router)
                    .environmentObject(store)
                    .environmentObject(permissions)
                    .environmentObject(prefs)
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = "SnapShotX Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AppController: NSMenuItemValidation {
    /// The pinned-screenshot commands only make sense while something is pinned.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(closePinned), #selector(unlockPinned): return PinManager.shared.count > 0
        default: return true
        }
    }
}
