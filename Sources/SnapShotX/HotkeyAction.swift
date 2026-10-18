import Carbon.HIToolbox

/// Everything the user can trigger from a global shortcut or the menu bar.
enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case allInOne
    case captureArea
    case captureFullscreen
    case captureWindow
    case scrollingCapture
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
        case .recordScreen: return "record.circle"
        case .captureText: return "text.viewfinder"
        case .openHistory: return "clock.arrow.circlepath"
        }
    }

    /// Actions implemented so far. Unavailable ones get no hotkey and no menu entry yet.
    var isAvailable: Bool {
        switch self {
        case .allInOne, .captureArea, .captureFullscreen, .captureWindow, .scrollingCapture, .captureText, .recordScreen, .openHistory:
            return true
        }
    }

    static var available: [HotkeyAction] { allCases.filter(\.isAvailable) }

    /// Needs the Screen Recording permission to do anything useful.
    var needsScreenRecording: Bool { self != .openHistory }

    /// Defaults avoid the system's ⌘⇧3/4/5 so both can coexist.
    var defaultShortcut: Shortcut? {
        let m = UInt32(controlKey | optionKey)
        switch self {
        case .allInOne: return Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: m, label: "A")
        case .captureArea: return Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: m, label: "4")
        case .captureFullscreen: return Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: m, label: "3")
        case .captureWindow: return Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: m, label: "5")
        case .scrollingCapture: return Shortcut(keyCode: UInt32(kVK_ANSI_6), modifiers: m, label: "6")
        case .recordScreen: return Shortcut(keyCode: UInt32(kVK_ANSI_7), modifiers: m, label: "7")
        case .captureText: return Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: m, label: "T")
        case .openHistory: return Shortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: m, label: "H")
        }
    }
}
