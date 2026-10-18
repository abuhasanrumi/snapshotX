import AppKit
import Carbon.HIToolbox

/// Turns key presses into the labels shown in the keystroke overlay, such as "⇧⌘4" or "⏎".
enum KeystrokeFormatter {
    private static let special: [Int: String] = [
        kVK_Return: "⏎", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
        kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        return symbols
    }

    /// The label for a key press, or nil if it shouldn't be shown (modifier only, or ordinary typing when
    /// `onlyCommandKeys` is on).
    static func describe(keyCode: UInt16, characters: String?, charactersIgnoringModifiers: String?,
                         modifiers: NSEvent.ModifierFlags, onlyCommandKeys: Bool) -> String? {
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        let isShortcut = !flags.isDisjoint(with: [.command, .control, .option])
        if onlyCommandKeys, !isShortcut { return nil }

        let specialName = special[Int(keyCode)]
        let name: String
        if let specialName {
            name = specialName
        } else if isShortcut {
            name = (charactersIgnoringModifiers ?? "").uppercased()
        } else {
            name = characters ?? ""
        }
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }

        if isShortcut { return modifierSymbols(flags) + name }
        if specialName != nil, flags.contains(.shift) { return "⇧" + name }
        return name
    }
}

/// The last few keys pressed, forgotten after a pause.
struct KeystrokeBuffer {
    private(set) var tokens: [String] = []
    private var lastTime: Date?
    let idleTimeout: TimeInterval
    let maxTokens: Int

    init(idleTimeout: TimeInterval = 1.5, maxTokens: Int = 6) {
        self.idleTimeout = idleTimeout
        self.maxTokens = maxTokens
    }

    mutating func add(_ token: String, at time: Date) {
        if let last = lastTime, time.timeIntervalSince(last) > idleTimeout { tokens.removeAll() }
        tokens.append(token)
        if tokens.count > maxTokens { tokens.removeFirst(tokens.count - maxTokens) }
        lastTime = time
    }

    /// What to show at `time`, or nil once the pause is long enough that the keys have faded.
    func text(at time: Date) -> String? {
        guard let lastTime, !tokens.isEmpty, time.timeIntervalSince(lastTime) <= idleTimeout else { return nil }
        return tokens.joined(separator: " ")
    }
}
