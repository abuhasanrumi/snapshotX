import Carbon.HIToolbox
import Foundation

/// macOS's own screenshot shortcuts. While they're switched on, macOS handles the key before any app sees it,
/// so a SnapShotX shortcut on the same keys would register without error and then never fire.
enum SystemShortcuts {
    private struct Reserved {
        var id: String
        var keyCode: Int
        var modifiers: Int
    }

    private static let cmdShift = cmdKey | shiftKey
    private static let ctrlCmdShift = controlKey | cmdKey | shiftKey

    /// The symbolic hotkey ids macOS uses for screenshots, and the keys they are on by default.
    private static let screenshots = [
        Reserved(id: "28", keyCode: kVK_ANSI_3, modifiers: cmdShift), // save screen to file
        Reserved(id: "29", keyCode: kVK_ANSI_3, modifiers: ctrlCmdShift), // copy screen to clipboard
        Reserved(id: "30", keyCode: kVK_ANSI_4, modifiers: cmdShift), // save selection to file
        Reserved(id: "31", keyCode: kVK_ANSI_4, modifiers: ctrlCmdShift), // copy selection to clipboard
        Reserved(id: "184", keyCode: kVK_ANSI_5, modifiers: cmdShift), // screenshot and recording options
    ]

    /// The actions whose shortcut is one macOS currently has switched on. `symbolicHotKeys` is the
    /// `AppleSymbolicHotKeys` dictionary; an entry that's missing is still on, as it is on a fresh Mac.
    static func conflicts(_ shortcuts: [HotkeyAction: Shortcut], symbolicHotKeys: [String: Any]?) -> Set<HotkeyAction> {
        let active = screenshots.filter { isEnabled($0.id, in: symbolicHotKeys) }
        var result: Set<HotkeyAction> = []
        for (action, shortcut) in shortcuts {
            if active.contains(where: { $0.keyCode == Int(shortcut.keyCode) && $0.modifiers == Int(shortcut.modifiers) }) {
                result.insert(action)
            }
        }
        return result
    }

    private static func isEnabled(_ id: String, in symbolicHotKeys: [String: Any]?) -> Bool {
        guard let entry = symbolicHotKeys?[id] as? [String: Any], let enabled = entry["enabled"] else { return true }
        if let flag = enabled as? Bool { return flag }
        if let number = enabled as? NSNumber { return number.boolValue }
        return true
    }

    static func loadSymbolicHotKeys() -> [String: Any]? {
        CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
    }
}
