import Carbon.HIToolbox

/// Everything the user can trigger from a global shortcut or the menu bar.
enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case allInOne
    case captureArea
    case captureFullscreen
    case captureWindow
    case scrollingCapture
    case fullPageCapture
    case recordScreen
    case captureText
    case openHistory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allInOne: return "All-in-One"
        case .captureArea: return "Capture Area"
        case .captureFullscreen: return "Capture Fullscreen"
        case .captureWindow: return "Capture Window"
        case .scrollingCapture: return "Scrolling Capture"
        case .fullPageCapture: return "Full Page Capture"
        case .recordScreen: return "Record Screen"
        case .captureText: return "Capture Text (OCR)"
        case .openHistory: return "Capture History"
        }
    }

    var symbol: String {
        switch self {
        case .allInOne: return "viewfinder"
        case .captureArea: return "rectangle.dashed"
        case .captureFullscreen: return "display"
        case .captureWindow: return "macwindow"
        case .scrollingCapture: return "arrow.up.and.down.text.horizontal"
        case .fullPageCapture: return "doc.text.image"
        case .recordScreen: return "record.circle"
        case .captureText: return "text.viewfinder"
        case .openHistory: return "clock.arrow.circlepath"
        }
    }

    /// Actions implemented so far. Unavailable ones get no hotkey and no menu entry yet.
    var isAvailable: Bool {
        switch self {
        case .allInOne, .captureArea, .captureFullscreen, .captureWindow, .scrollingCapture, .fullPageCapture, .captureText, .recordScreen, .openHistory:
            return true
        }
    }

    static var available: [HotkeyAction] { allCases.filter(\.isAvailable) }

    /// Needs the Screen Recording permission to do anything useful.
    var needsScreenRecording: Bool { self != .openHistory }

    /// ⌘⇧ and a number, following macOS's own ⌘⇧3 and ⌘⇧4 for the first two. Digits rather than letters, because a
    /// global ⌘⇧T, ⌘⇧H or ⌘⇧A would take over "reopen tab", "Home" and similar shortcuts in every other app.
    /// macOS's screenshot shortcuts must be switched off for ⌘⇧3, ⌘⇧4 and ⌘⇧5 to reach SnapShotX.
    var defaultShortcut: Shortcut? {
        let m = UInt32(cmdKey | shiftKey)
        switch self {
        case .fullPageCapture: return Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: m, label: "2")
        case .captureFullscreen: return Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: m, label: "3")
        case .captureArea: return Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: m, label: "4")
        case .allInOne: return Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: m, label: "5")
        case .captureWindow: return Shortcut(keyCode: UInt32(kVK_ANSI_6), modifiers: m, label: "6")
        case .scrollingCapture: return Shortcut(keyCode: UInt32(kVK_ANSI_7), modifiers: m, label: "7")
        case .recordScreen: return Shortcut(keyCode: UInt32(kVK_ANSI_8), modifiers: m, label: "8")
        case .captureText: return Shortcut(keyCode: UInt32(kVK_ANSI_9), modifiers: m, label: "9")
        case .openHistory: return Shortcut(keyCode: UInt32(kVK_ANSI_0), modifiers: m, label: "0")
        }
    }

    /// The ⌃⌥ defaults this app shipped with first. Only used to recognise a saved set that was never customized.
    var legacyDefaultShortcut: Shortcut? {
        let m = UInt32(controlKey | optionKey)
        switch self {
        case .allInOne: return Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: m, label: "A")
        case .captureArea: return Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: m, label: "4")
        case .captureFullscreen: return Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: m, label: "3")
        case .captureWindow: return Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: m, label: "5")
        case .scrollingCapture: return Shortcut(keyCode: UInt32(kVK_ANSI_6), modifiers: m, label: "6")
        case .fullPageCapture: return nil
        case .recordScreen: return Shortcut(keyCode: UInt32(kVK_ANSI_7), modifiers: m, label: "7")
        case .captureText: return Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: m, label: "T")
        case .openHistory: return Shortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: m, label: "H")
        }
    }
}
