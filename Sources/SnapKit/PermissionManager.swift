import AppKit
import ApplicationServices
import CoreGraphics

/// Tracks the macOS privacy permissions SnapKit depends on.
/// Screen Recording is needed for every capture. Accessibility is needed later for keystroke overlays.
final class PermissionManager: ObservableObject {
    enum Pane: String {
        case screenRecording = "Privacy_ScreenCapture"
        case accessibility = "Privacy_Accessibility"
    }

    @Published private(set) var screenRecording = false
    @Published private(set) var accessibility = false

    private var activationObserver: NSObjectProtocol?

    init() {
        refresh()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    func refresh() {
        let screen = CGPreflightScreenCaptureAccess()
        let ax = AXIsProcessTrusted()
        if screen != screenRecording { screenRecording = screen }
        if ax != accessibility { accessibility = ax }
    }

    func requestScreenRecording() {
        // Shows the system prompt once; afterwards macOS only lets the user flip it in System Settings.
        if !CGRequestScreenCaptureAccess() { open(.screenRecording) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { open(.accessibility) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    func open(_ pane: Pane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }

    /// Screen Recording grants often only take effect after the app restarts.
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
