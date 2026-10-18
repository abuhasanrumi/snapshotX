import ServiceManagement
import SwiftUI

enum SettingsTab: Hashable {
    case general, screenshots, recording, shortcuts, permissions
}

final class SettingsRouter: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @EnvironmentObject var router: SettingsRouter
    @EnvironmentObject var permissions: PermissionManager
    @EnvironmentObject var statusMonitor: StatusItemMonitor

    var body: some View {
        VStack(spacing: 0) {
            if statusMonitor.isHidden { HiddenIconBanner() }
            SettingsTabBar(selection: $router.tab)
            Divider()
            Group {
                switch router.tab {
                case .general: GeneralTab()
                case .screenshots: ScreenshotsTab()
                case .recording: RecordingTab()
                case .shortcuts: ShortcutsTab()
                case .permissions: PermissionsTab()
                }
            }
            .frame(width: 540, height: 430)
        }
    }
}

/// Large icons over short labels, like a toolbar, instead of a row of text tabs.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    private let tabs: [(tab: SettingsTab, title: String, symbol: String)] = [
        (.general, "General", "gearshape"),
        (.screenshots, "Screenshots", "camera.viewfinder"),
        (.recording, "Recording", "record.circle"),
        (.shortcuts, "Shortcuts", "keyboard"),
        (.permissions, "Permissions", "lock.shield"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.tab) { item in
                let selected = selection == item.tab
                Button { selection = item.tab } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.symbol).font(.system(size: 21))
                        Text(item.title).font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 96, height: 54)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.title)
                .accessibilityLabel(item.title)
            }
        }
        .padding(8)
        .frame(width: 540)
    }
}

/// Shown above every tab while macOS has dropped the menu bar icon for lack of room.
private struct HiddenIconBanner: View {
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("The menu bar icon is hidden").font(.headline)
                Text("Your menu bar is full, so macOS dropped SnapShotX's icon. Shortcuts still work. Show the Dock icon to reach the menu, or quit a few other menu bar apps to make room.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !prefs.showInDock {
                    Button("Show SnapShotX in the Dock") { prefs.showInDock = true }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        // A fixed width, so the window sizes the wrapped text correctly instead of wrapping it one word per line.
        .frame(width: 540, alignment: .leading)
        .background(Color.orange.opacity(0.14))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var prefs: Preferences
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show SnapShotX in the Dock", isOn: $prefs.showInDock)
                Text("Right-click the Dock icon for the same menu as the menu bar icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Allow snapshotx:// commands from links and other apps", isOn: $prefs.urlSchemeEnabled)
                Text("Lets scripts, Shortcuts and launchers trigger captures. A capture started this way still plays the shutter sound and shows its result.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Launch SnapShotX at login", isOn: $launchAtLogin)
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

// MARK: - Screenshots

private struct ScreenshotsTab: View {
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        Form {
            Section("After capture") {
                Toggle("Copy to clipboard", isOn: $prefs.autoCopy)
                Toggle("Save to folder automatically", isOn: $prefs.autoSave)
                LabeledContent("Save folder") {
                    HStack {
                        Text((prefs.saveFolderPath as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Choose…", action: chooseFolder)
                    }
                }
            }
            Section("Capture") {
                Toggle("Include mouse cursor", isOn: $prefs.showCursor)
                Toggle("Play shutter sound", isOn: $prefs.playSound)
            }
            Section("Text recognition") {
                Toggle("Keep line breaks when copying text", isOn: $prefs.ocrKeepLineBreaks)
            }
            Section("Quick Access Overlay") {
                Picker("Position", selection: $prefs.overlayCorner) {
                    ForEach(OverlayCorner.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Auto-close") {
                    HStack {
                        Slider(value: $prefs.overlayAutoCloseSeconds, in: 0...30, step: 1)
                        Text(prefs.overlayAutoCloseSeconds == 0 ? "Never" : "\(Int(prefs.overlayAutoCloseSeconds)) s")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.saveFolder
        if panel.runModal() == .OK, let url = panel.url {
            prefs.saveFolderPath = url.path
        }
    }
}

// MARK: - Recording

private struct RecordingTab: View {
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        Form {
            Section("Output") {
                Picker("Format", selection: $prefs.recording.format) {
                    ForEach(RecordingFormat.allCases) { Text($0.title).tag($0) }
                }
                if prefs.recording.format == .mp4 {
                    Picker("Frame rate", selection: $prefs.recording.fps) {
                        ForEach(RecordingOptions.fpsChoices, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                } else {
                    Picker("GIF frame rate", selection: $prefs.recording.gifFPS) {
                        ForEach(RecordingOptions.gifFPSChoices, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    Picker("GIF width limit", selection: $prefs.recording.gifMaxWidth) {
                        ForEach([480, 640, 800, 1024], id: \.self) { Text("\($0) px").tag($0) }
                    }
                    Text("GIFs have no sound and get large fast. Keep them short.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Show mouse cursor", isOn: $prefs.recording.showCursor)
            }
            Section("Audio (MP4 only)") {
                Toggle("Record microphone", isOn: $prefs.recording.microphone)
                Toggle("Record system audio", isOn: $prefs.recording.systemAudio)
                Text("Both are mixed into a single track. macOS asks for microphone access the first time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Overlays") {
                Toggle("Highlight mouse clicks", isOn: $prefs.recording.highlightClicks)
                Toggle("Show keystrokes", isOn: $prefs.recording.showKeystrokes)
                Toggle("Only show shortcuts (⌘, ⌃, ⌥), not typing", isOn: $prefs.recording.onlyCommandKeys)
                    .disabled(!prefs.recording.showKeystrokes)
                Toggle("Show camera bubble", isOn: $prefs.recording.camera)
                Picker("Camera size", selection: $prefs.recording.cameraSize) {
                    ForEach(CameraBubbleSize.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!prefs.recording.camera)
                Picker("Camera shape", selection: $prefs.recording.cameraShape) {
                    ForEach(CameraBubbleShape.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!prefs.recording.camera)
                Text("Keystrokes need the Accessibility permission. Overlays appear in area and full-screen recordings, not in single-window recordings.")
                    .font(.caption).foregroundStyle(.secondary)
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
            List(HotkeyAction.available) { action in
                HStack {
                    Label(action.title, systemImage: action.symbol)
                    Spacer()
                    if store.flashing == action {
                        Label("Worked", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
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
                .listRowBackground(store.flashing == action ? Color.green.opacity(0.14) : Color.clear)
                .animation(.easeOut(duration: 0.2), value: store.flashing)
            }
            Divider()
            HStack(spacing: 8) {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(message == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
                Spacer()
                IconButton(symbol: "arrow.counterclockwise", help: "Reset all shortcuts to their defaults", size: 26) {
                    store.resetToDefaults()
                    message = nil
                }
            }
            .padding(10)
        }
    }

    /// An error from the last edit, else proof the last shortcut fired, else how to edit.
    private var footer: String {
        if let message { return message }
        if let last = store.lastTriggered {
            return "Last used: \(last.action.title) at \(last.time.formatted(date: .omitted, time: .standard)). Click a shortcut to change it."
        }
        return "Press a shortcut to test it. Click one to record a new key. Esc cancels, ⌫ clears."
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
                Button("Relaunch SnapShotX") { permissions.relaunch() }
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
