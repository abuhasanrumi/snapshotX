import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut, stored in Carbon terms so it can be handed straight to RegisterEventHotKey.
struct Shortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, shiftKey, optionKey, controlKey).
    var modifiers: UInt32
    /// Printable label for the key, captured at record time (e.g. "4", "T", "Space").
    var label: String

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + label
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    static func cocoaModifiers(from carbon: UInt32) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbon & UInt32(controlKey) != 0 { f.insert(.control) }
        if carbon & UInt32(optionKey) != 0 { f.insert(.option) }
        if carbon & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if carbon & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    private static let specialLabels: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
    ]

    /// Builds a shortcut from a key-down event. Returns nil when the combination isn't a valid global shortcut
    /// (needs ⌃, ⌥ or ⌘ unless it's a function key).
    static func from(event: NSEvent) -> Shortcut? {
        let code = Int(event.keyCode)
        let mods = carbonModifiers(from: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        let hasStrongModifier = mods & UInt32(controlKey | optionKey | cmdKey) != 0
        guard hasStrongModifier || functionKeys.contains(code) else { return nil }
        let label = specialLabels[code]
            ?? event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespaces)
            ?? ""
        guard !label.isEmpty else { return nil }
        return Shortcut(keyCode: UInt32(code), modifiers: mods, label: label)
    }
}
