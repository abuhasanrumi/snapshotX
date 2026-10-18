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

    let statusMonitor = StatusItemMonitor()

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var historyWindow: HistoryWindowController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.showHistory = { [weak self] in self?.showHistory() }
        coordinator.showPermissions = { [weak self] in self?.showSettings(tab: .permissions) }
        coordinator.showSettings = { [weak self] tab in self?.showSettings(tab: tab) }
        coordinator.onRecordingChange = { [weak self] recording in self?.showRecordingIndicator(recording) }
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

        MainMenu.install(settingsTarget: self, settingsAction: #selector(openSettings))
        applyDockPolicy()
        setUpStatusItem()

        prefs.$showInDock
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyDockPolicy() }
            .store(in: &cancellables)

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

        // Coming back from System Settings, where the screenshot shortcuts may just have been switched off.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.store.refreshSystemConflicts() }
            .store(in: &cancellables)

        if !permissions.screenRecording {
            showSettings(tab: .permissions)
        }

        // Give macOS a moment to lay the icon out, then see whether it actually fits in the menu bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.checkStatusItemVisibility() }
        }
    }

    /// The Dock icon is the way in when the menu bar icon doesn't fit. Its right-click menu matches the menu bar menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        makeMenu()
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
        store.noteTriggered(action)
        log.notice("Shortcut: \(action.rawValue, privacy: .public)")
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
        store.refreshSystemConflicts()
        log.notice("Shortcuts registered: \(active.count - self.store.registrationFailures.count, privacy: .public) of \(active.count, privacy: .public); macOS conflicts: \(self.store.systemConflicts.count, privacy: .public)")
        if !store.registrationFailures.isEmpty {
            log.warning("Could not register: \(self.store.registrationFailures.map(\.rawValue).joined(separator: ", "), privacy: .public)")
        }
    }

    // MARK: Status item and menu

    private func setUpStatusItem() {
        // A variable-length item is a few points narrower than a square one, which matters when the menu bar is tight.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "SnapShotXStatusItem"
        let symbol = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "SnapShotX")?.withSymbolConfiguration(symbol)
        image?.isTemplate = true
        item.button?.image = image
        statusItem = item
        rebuildMenu()
        statusMonitor.watch(item)
    }

    /// Turns the menu bar icon into a red record dot while a recording runs.
    private func showRecordingIndicator(_ recording: Bool) {
        guard let button = statusItem?.button else { return }
        let symbol = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(systemSymbolName: recording ? "record.circle.fill" : "viewfinder", accessibilityDescription: "SnapShotX")?
            .withSymbolConfiguration(symbol)
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = recording ? .systemRed : nil
    }

    private func checkStatusItemVisibility() {
        guard let item = statusItem else { return }
        statusMonitor.refresh(item)
        let width = item.button?.window?.frame.width ?? 0
        log.notice("Menu bar icon showing: \(!self.statusMonitor.isHidden, privacy: .public), width \(Int(width), privacy: .public)")

        // Explain a hidden icon once, in Settings, instead of leaving the app looking like it didn't start.
        // If Settings is already open (for example on Permissions) it just shows the banner, on whatever tab it's on.
        if statusMonitor.isHidden, !prefs.showInDock, !prefs.hiddenIconNoticeSeen {
            prefs.hiddenIconNoticeSeen = true
            if settingsWindow?.isVisible != true { showSettings(tab: .general) }
        }
    }

    private func applyDockPolicy() {
        let policy: NSApplication.ActivationPolicy = prefs.showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    private func rebuildMenu() {
        statusItem?.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
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
            // A key equivalent must be a single character, so keys like Space or F4 are shown only in Settings.
            if let s = store.shortcut(for: action), !store.registrationFailures.contains(action), s.label.count == 1 {
                item.keyEquivalent = s.label.lowercased()
                item.keyEquivalentModifierMask = Shortcut.cocoaModifiers(from: s.modifiers)
            }
            menu.addItem(item)
        }

        let open = NSMenuItem(title: "Open Image or Project…", action: #selector(openFile), keyEquivalent: "")
        open.target = self
        open.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(open)
        let combine = NSMenuItem(title: "Combine Images…", action: #selector(combineImages), keyEquivalent: "")
        combine.target = self
        combine.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
        menu.addItem(combine)

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
        return menu
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

    @objc private func combineImages() {
        DispatchQueue.main.async { [weak self] in self?.coordinator.combineImages() }
    }

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
                    .environmentObject(statusMonitor)
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
