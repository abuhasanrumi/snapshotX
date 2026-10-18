import Carbon.HIToolbox

/// Registers system-wide hotkeys through Carbon. This path needs no Accessibility or Input Monitoring permission.
final class HotKeyManager {
    static let shared = HotKeyManager()

    private static let signature: OSType = 0x5353_4858 // 'SSHX'

    var onAction: ((HotkeyAction) -> Void)?

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actionsByID: [UInt32: HotkeyAction] = [:]
    private var handlerInstalled = false

    /// Replaces all registered hotkeys. Returns the actions the system refused to register.
    @discardableResult
    func register(_ shortcuts: [HotkeyAction: Shortcut]) -> Set<HotkeyAction> {
        installHandlerIfNeeded()
        unregisterAll()

        var failures: Set<HotkeyAction> = []
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let shortcut = shortcuts[action] else { continue }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[id] = ref
                actionsByID[id] = action
            } else {
                failures.insert(action)
            }
        }
        return failures
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actionsByID.removeAll()
    }

    fileprivate func fire(id: UInt32) {
        guard let action = actionsByID[id] else { return }
        onAction?(action)
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}

private func hotKeyCallback(_: EventHandlerCallRef?, event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let id = hotKeyID.id
    DispatchQueue.main.async { HotKeyManager.shared.fire(id: id) }
    return noErr
}
