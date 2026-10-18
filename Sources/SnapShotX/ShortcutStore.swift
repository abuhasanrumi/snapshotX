import Foundation

/// Source of truth for which shortcut is bound to which action. Persists to UserDefaults.
final class ShortcutStore: ObservableObject {
    enum SetResult: Equatable {
        case ok
        case conflict(HotkeyAction)
    }

    private static let defaultsKey = "shortcuts.v1"

    @Published private(set) var shortcuts: [HotkeyAction: Shortcut]
    /// Actions whose shortcut the system refused to register (usually taken by another app).
    @Published var registrationFailures: Set<HotkeyAction> = []

    /// Actions whose shortcut macOS also uses for its own screenshots. While that is switched on, macOS gets the key first.
    @Published private(set) var systemConflicts: Set<HotkeyAction> = []

    func refreshSystemConflicts(symbolicHotKeys: [String: Any]? = SystemShortcuts.loadSymbolicHotKeys()) {
        let available = shortcuts.filter { $0.key.isAvailable }
        let found = SystemShortcuts.conflicts(available, symbolicHotKeys: symbolicHotKeys)
        if found != systemConflicts { systemConflicts = found }
    }

    struct Trigger: Equatable {
        var action: HotkeyAction
        var time: Date
    }

    /// The most recent shortcut or menu command, so Settings can show that a shortcut really fired.
    @Published private(set) var lastTriggered: Trigger?
    /// The action to highlight briefly after it fires.
    @Published private(set) var flashing: HotkeyAction?

    func noteTriggered(_ action: HotkeyAction, at time: Date = Date()) {
        lastTriggered = Trigger(action: action, time: time)
        flashing = action
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.flashing == action { self?.flashing = nil }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            // Only keys present in storage are honoured, so a user-cleared shortcut stays cleared.
            var map: [HotkeyAction: Shortcut] = [:]
            for (raw, shortcut) in decoded {
                if let action = HotkeyAction(rawValue: raw) { map[action] = shortcut }
            }
            // A saved set that is exactly the old ⌃⌥ defaults was never customized (Reset to Defaults saves it),
            // so it moves to the current defaults. Anything the user changed stays as they set it.
            if map == Self.legacyDefaultMap() {
                shortcuts = Self.defaultMap()
                save()
            } else {
                shortcuts = map
            }
        } else {
            shortcuts = Self.defaultMap()
        }
    }

    static func legacyDefaultMap() -> [HotkeyAction: Shortcut] {
        var map: [HotkeyAction: Shortcut] = [:]
        for action in HotkeyAction.allCases {
            if let s = action.legacyDefaultShortcut { map[action] = s }
        }
        return map
    }

    static func defaultMap() -> [HotkeyAction: Shortcut] {
        var map: [HotkeyAction: Shortcut] = [:]
        for action in HotkeyAction.allCases {
            if let s = action.defaultShortcut { map[action] = s }
        }
        return map
    }

    func shortcut(for action: HotkeyAction) -> Shortcut? { shortcuts[action] }

    func conflictingAction(for shortcut: Shortcut, excluding action: HotkeyAction) -> HotkeyAction? {
        shortcuts.first { $0.key != action && $0.value.keyCode == shortcut.keyCode && $0.value.modifiers == shortcut.modifiers }?.key
    }

    @discardableResult
    func set(_ shortcut: Shortcut?, for action: HotkeyAction) -> SetResult {
        if let shortcut, let other = conflictingAction(for: shortcut, excluding: action) {
            return .conflict(other)
        }
        shortcuts[action] = shortcut
        save()
        return .ok
    }

    func resetToDefaults() {
        shortcuts = Self.defaultMap()
        save()
    }

    private func save() {
        let encodable = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
