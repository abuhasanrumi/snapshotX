import Foundation

enum OverlayCorner: String, CaseIterable, Identifiable {
    case bottomLeft, bottomRight, topLeft, topRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        }
    }

    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
    var isLeft: Bool { self == .bottomLeft || self == .topLeft }
}

/// User-facing settings for capturing and the Quick Access Overlay, persisted to UserDefaults.
final class Preferences: ObservableObject {
    private enum Key {
        static let autoCopy = "prefs.autoCopy"
        static let autoSave = "prefs.autoSave"
        static let saveFolder = "prefs.saveFolder"
        static let showCursor = "prefs.showCursor"
        static let playSound = "prefs.playSound"
        static let overlayCorner = "prefs.overlayCorner"
        static let ocrKeepLineBreaks = "prefs.ocrKeepLineBreaks"
        static let urlSchemeEnabled = "prefs.urlSchemeEnabled"
        static let showInDock = "prefs.showInDock"
        static let hiddenIconNoticeSeen = "prefs.hiddenIconNoticeSeen"
        static let recording = "prefs.recordingOptions.v1"
        static let imageDPI = "prefs.imageDPI"
    }

    private let defaults: UserDefaults

    @Published var autoCopy: Bool { didSet { defaults.set(autoCopy, forKey: Key.autoCopy) } }
    @Published var autoSave: Bool { didSet { defaults.set(autoSave, forKey: Key.autoSave) } }
    @Published var saveFolderPath: String { didSet { defaults.set(saveFolderPath, forKey: Key.saveFolder) } }
    @Published var showCursor: Bool { didSet { defaults.set(showCursor, forKey: Key.showCursor) } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: Key.playSound) } }
    @Published var overlayCorner: OverlayCorner { didSet { defaults.set(overlayCorner.rawValue, forKey: Key.overlayCorner) } }

    /// Keep line breaks in text copied by Capture Text.
    @Published var ocrKeepLineBreaks: Bool { didSet { defaults.set(ocrKeepLineBreaks, forKey: Key.ocrKeepLineBreaks) } }
    /// Lets links and other apps trigger `snapshotx://` commands.
    @Published var urlSchemeEnabled: Bool { didSet { defaults.set(urlSchemeEnabled, forKey: Key.urlSchemeEnabled) } }

    /// Shows a Dock icon (with the full menu) in addition to the menu bar icon.
    @Published var showInDock: Bool { didSet { defaults.set(showInDock, forKey: Key.showInDock) } }
    /// Set once Settings has been opened automatically to explain a hidden menu bar icon.
    @Published var hiddenIconNoticeSeen: Bool { didSet { defaults.set(hiddenIconNoticeSeen, forKey: Key.hiddenIconNoticeSeen) } }

    /// Pixels per inch written into saved PNGs: 0 for the screen's own (144 on Retina), or 300 and 600 for print.
    /// Changes how big other apps show or print the image, never how many pixels it has.
    @Published var imageDPI: Int {
        didSet {
            defaults.set(imageDPI, forKey: Key.imageDPI)
            ImageFile.outputDPIOverride = imageDPI > 0 ? Double(imageDPI) : nil
        }
    }

    /// Format, audio, camera and overlay choices for screen recordings.
    @Published var recording: RecordingOptions {
        didSet {
            if let data = try? JSONEncoder().encode(recording) { defaults.set(data, forKey: Key.recording) }
        }
    }

    var saveFolder: URL { URL(fileURLWithPath: saveFolderPath, isDirectory: true) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.autoCopy: true,
            Key.autoSave: false,
            Key.saveFolder: NSHomeDirectory() + "/Desktop",
            Key.showCursor: false,
            Key.playSound: true,
            Key.overlayCorner: OverlayCorner.bottomLeft.rawValue,
            Key.ocrKeepLineBreaks: true,
            Key.urlSchemeEnabled: true,
            Key.showInDock: false,
            Key.hiddenIconNoticeSeen: false,
        ])
        let savedDPI = defaults.integer(forKey: Key.imageDPI)
        imageDPI = savedDPI
        ImageFile.outputDPIOverride = savedDPI > 0 ? Double(savedDPI) : nil
        recording = defaults.data(forKey: Key.recording).flatMap { try? JSONDecoder().decode(RecordingOptions.self, from: $0) } ?? RecordingOptions()
        showInDock = defaults.bool(forKey: Key.showInDock)
        hiddenIconNoticeSeen = defaults.bool(forKey: Key.hiddenIconNoticeSeen)
        ocrKeepLineBreaks = defaults.bool(forKey: Key.ocrKeepLineBreaks)
        urlSchemeEnabled = defaults.bool(forKey: Key.urlSchemeEnabled)
        autoCopy = defaults.bool(forKey: Key.autoCopy)
        autoSave = defaults.bool(forKey: Key.autoSave)
        saveFolderPath = defaults.string(forKey: Key.saveFolder) ?? NSHomeDirectory() + "/Desktop"
        showCursor = defaults.bool(forKey: Key.showCursor)
        playSound = defaults.bool(forKey: Key.playSound)
        overlayCorner = OverlayCorner(rawValue: defaults.string(forKey: Key.overlayCorner) ?? "") ?? .bottomLeft
    }
}
