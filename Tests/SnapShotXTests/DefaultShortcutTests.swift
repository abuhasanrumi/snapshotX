import Carbon.HIToolbox
import XCTest
@testable import SnapShotX

final class DefaultShortcutTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "snapshotx.defaultshortcuts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func save(_ map: [HotkeyAction: Shortcut], to defaults: UserDefaults) {
        let encodable = Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
        defaults.set(try! JSONEncoder().encode(encodable), forKey: "shortcuts.v1")
    }

    // MARK: Defaults

    func testEveryDefaultIsCommandShiftAndADigit() {
        let digits = Set("0123456789")
        for action in HotkeyAction.allCases {
            let shortcut = try! XCTUnwrap(action.defaultShortcut, action.rawValue)
            XCTAssertEqual(shortcut.modifiers, UInt32(cmdKey | shiftKey), action.rawValue)
            XCTAssertTrue(shortcut.label.count == 1 && digits.contains(shortcut.label.first!), "\(action.rawValue): \(shortcut.label)")
        }
    }

    func testTheNumberLayout() {
        let layout = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0, $0.defaultShortcut!.display) })
        XCTAssertEqual(layout[.captureFullscreen], "⇧⌘3")
        XCTAssertEqual(layout[.captureArea], "⇧⌘4")
        XCTAssertEqual(layout[.allInOne], "⇧⌘5")
        XCTAssertEqual(layout[.captureWindow], "⇧⌘6")
        XCTAssertEqual(layout[.scrollingCapture], "⇧⌘7")
        XCTAssertEqual(layout[.recordScreen], "⇧⌘8")
        XCTAssertEqual(layout[.captureText], "⇧⌘9")
        XCTAssertEqual(layout[.openHistory], "⇧⌘0")
    }

    func testNoTwoDefaultsShareKeys() {
        let keys = HotkeyAction.allCases.map { "\($0.defaultShortcut!.keyCode)-\($0.defaultShortcut!.modifiers)" }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testNoDefaultTakesOverALetterShortcutOtherAppsUse() {
        for action in HotkeyAction.allCases {
            XCTAssertFalse(action.defaultShortcut!.label.first!.isLetter, "\(action.rawValue) would shadow an in-app ⌘⇧ shortcut")
        }
    }

    // MARK: Migration

    func testASavedSetOfTheOldDefaultsMovesToTheNewOnes() {
        let defaults = makeDefaults()
        save(ShortcutStore.legacyDefaultMap(), to: defaults) // what Reset to Defaults used to save
        let store = ShortcutStore(defaults: defaults)
        XCTAssertEqual(store.shortcuts, ShortcutStore.defaultMap())
        XCTAssertEqual(ShortcutStore(defaults: defaults).shortcuts, ShortcutStore.defaultMap(), "and the move is saved")
    }

    func testCustomizedShortcutsAreLeftAlone() {
        let defaults = makeDefaults()
        var custom = ShortcutStore.legacyDefaultMap()
        custom[.captureArea] = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey), label: "K")
        save(custom, to: defaults)
        XCTAssertEqual(ShortcutStore(defaults: defaults).shortcuts, custom)
    }

    func testAClearedShortcutIsStillClearedAfterTheChange() {
        let defaults = makeDefaults()
        var custom = ShortcutStore.defaultMap()
        custom[.recordScreen] = nil
        save(custom, to: defaults)
        XCTAssertNil(ShortcutStore(defaults: defaults).shortcut(for: .recordScreen))
    }

    func testNothingSavedUsesTheNewDefaults() {
        XCTAssertEqual(ShortcutStore(defaults: makeDefaults()).shortcuts, ShortcutStore.defaultMap())
    }

    // MARK: macOS screenshot shortcuts

    private func entry(_ enabled: Int) -> [String: Any] { ["enabled": enabled, "value": ["type": "standard"]] }

    func testFactoryDefaultsMeanMacOSOwnsThreeOfOurKeys() {
        let conflicts = SystemShortcuts.conflicts(ShortcutStore.defaultMap(), symbolicHotKeys: nil)
        XCTAssertEqual(conflicts, [.captureFullscreen, .captureArea, .allInOne])
    }

    func testAMissingEntryCountsAsStillOn() {
        let conflicts = SystemShortcuts.conflicts(ShortcutStore.defaultMap(), symbolicHotKeys: ["28": entry(0)])
        XCTAssertEqual(conflicts, [.captureArea, .allInOne], "only ⌘⇧3 was switched off")
    }

    func testSwitchingTheScreenshotShortcutsOffClearsEveryConflict() {
        let off: [String: Any] = ["28": entry(0), "29": entry(0), "30": entry(0), "31": entry(0), "184": entry(0)]
        XCTAssertTrue(SystemShortcuts.conflicts(ShortcutStore.defaultMap(), symbolicHotKeys: off).isEmpty)
    }

    func testEnabledAcceptsBooleansToo() {
        let hotkeys: [String: Any] = ["28": ["enabled": false], "30": ["enabled": true], "184": ["enabled": false]]
        XCTAssertEqual(SystemShortcuts.conflicts(ShortcutStore.defaultMap(), symbolicHotKeys: hotkeys), [.captureArea])
    }

    func testOtherKeysNeverConflict() {
        var shortcuts = ShortcutStore.defaultMap()
        shortcuts = shortcuts.filter { [.captureWindow, .scrollingCapture, .recordScreen, .captureText, .openHistory].contains($0.key) }
        XCTAssertTrue(SystemShortcuts.conflicts(shortcuts, symbolicHotKeys: nil).isEmpty)
    }

    func testTheControlVariantsAreRecognisedToo() {
        let ctrlCmdShift4 = Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(controlKey | cmdKey | shiftKey), label: "4")
        XCTAssertEqual(SystemShortcuts.conflicts([.captureArea: ctrlCmdShift4], symbolicHotKeys: nil), [.captureArea])
        XCTAssertTrue(SystemShortcuts.conflicts([.captureArea: ctrlCmdShift4], symbolicHotKeys: ["31": entry(0)]).isEmpty)
    }

    func testTheStorePublishesConflictsAndIgnoresUnavailableActions() {
        let store = ShortcutStore(defaults: makeDefaults())
        XCTAssertTrue(store.systemConflicts.isEmpty, "nothing is computed until asked")
        store.refreshSystemConflicts(symbolicHotKeys: nil)
        XCTAssertEqual(store.systemConflicts, [.captureFullscreen, .captureArea, .allInOne])
        store.refreshSystemConflicts(symbolicHotKeys: ["28": entry(0), "30": entry(0), "184": entry(0)])
        XCTAssertTrue(store.systemConflicts.isEmpty)
    }
}
