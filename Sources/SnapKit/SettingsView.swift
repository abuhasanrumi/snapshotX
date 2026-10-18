import ServiceManagement
import SwiftUI

enum SettingsTab: Hashable {
    case general, shortcuts, permissions
}

final class SettingsRouter: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @EnvironmentObject var router: SettingsRouter
    @EnvironmentObject var permissions: PermissionManager

    var body: some View {
        TabView(selection: $router.tab) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ShortcutsTab()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(SettingsTab.shortcuts)
            PermissionsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("Launch SnapKit at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

private struct ShortcutsTab: View {
    @EnvironmentObject var store: ShortcutStore
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            List(HotkeyAction.allCases) { action in
                HStack {
                    Label(action.title, systemImage: action.symbol)
                    Spacer()
                    if store.registrationFailures.contains(action) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("macOS or another app already uses this shortcut. Pick a different one.")
                    }
                    ShortcutRecorderButton(
                        shortcut: store.shortcut(for: action),
                        onChange: { newValue in
                            switch store.set(newValue, for: action) {
                            case .ok: message = nil
                            case .conflict(let other): message = "That shortcut is already used by \(other.title)."
                            }
                        }
                    )
                }
            }
            Divider()
            HStack {
                Text(message ?? "Click a shortcut to record a new one. Esc cancels, ⌫ clears.")
                    .font(.caption)
                    .foregroundStyle(message == nil ? Color.secondary : Color.red)
                Spacer()
                Button("Reset to Defaults") { store.resetToDefaults(); message = nil }
            }
            .padding(10)
        }
    }
}

private struct ShortcutRecorderButton: View {
    let shortcut: Shortcut?
    let onChange: (Shortcut?) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(recording ? "Type shortcut…" : (shortcut?.display ?? "Not set"))
                .frame(minWidth: 110)
                .foregroundStyle(shortcut == nil && !recording ? Color.secondary : Color.primary)
        }
        .buttonStyle(.bordered)
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: // Esc
                stop()
            case 51, 117: // Delete, Forward Delete
                onChange(nil)
                stop()
            default:
                if let candidate = Shortcut.from(event: event) {
                    onChange(candidate)
                    stop()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Permissions

private struct PermissionsTab: View {
    @EnvironmentObject var permissions: PermissionManager
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: "Screen Recording",
                    detail: "Required for screenshots and screen recordings.",
                    granted: permissions.screenRecording,
                    action: permissions.requestScreenRecording
                )
                PermissionRow(
                    title: "Accessibility",
                    detail: "Optional. Needed later to show keystrokes while recording.",
                    granted: permissions.accessibility,
                    action: permissions.requestAccessibility
                )
            }
            Section {
                Text("macOS often applies a new Screen Recording grant only after the app restarts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Relaunch SnapKit") { permissions.relaunch() }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in permissions.refresh() }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Granted").foregroundStyle(.secondary)
            } else {
                Button("Grant Access", action: action)
            }
        }
        .padding(.vertical, 2)
    }
}
