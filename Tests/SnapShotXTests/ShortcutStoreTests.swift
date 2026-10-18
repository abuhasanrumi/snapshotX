import Carbon.HIToolbox
import XCTest
@testable import SnapShotX

final class ShortcutStoreTests: XCTestCase {
    private func makeStore() -> (ShortcutStore, UserDefaults) {
        let suite = "snapshotx.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (ShortcutStore(defaults: defaults), defaults)
    }

    func testDefaultsCoverEveryActionWithUniqueShortcuts() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.shortcuts.count, HotkeyAction.allCases.count)
        let unique = Set(store.shortcuts.values.map { [$0.keyCode, $0.modifiers] })
        XCTAssertEqual(unique.count, store.shortcuts.count)
    }

    func testConflictIsRejectedAndLeavesStoreUnchanged() {
        let (store, _) = makeStore()
        let areaShortcut = store.shortcut(for: .captureArea)!
        XCTAssertEqual(store.set(areaShortcut, for: .captureWindow), .conflict(.captureArea))
        XCTAssertNotEqual(store.shortcut(for: .captureWindow), areaShortcut)
    }

    func testRebindingSameActionToItsOwnShortcutIsAllowed() {
        let (store, _) = makeStore()
        let current = store.shortcut(for: .captureArea)!
        XCTAssertEqual(store.set(current, for: .captureArea), .ok)
    }

    func testClearedShortcutSurvivesReload() {
        let (store, defaults) = makeStore()
        store.set(nil, for: .recordScreen)
        let reloaded = ShortcutStore(defaults: defaults)
        XCTAssertNil(reloaded.shortcut(for: .recordScreen))
        XCTAssertNotNil(reloaded.shortcut(for: .captureArea))
    }

    func testCustomShortcutPersists() {
        let (store, defaults) = makeStore()
        let custom = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey), label: "K")
        XCTAssertEqual(store.set(custom, for: .openHistory), .ok)
        XCTAssertEqual(ShortcutStore(defaults: defaults).shortcut(for: .openHistory), custom)
    }

    func testResetRestoresDefaults() {
        let (store, _) = makeStore()
        store.set(nil, for: .allInOne)
        store.resetToDefaults()
        XCTAssertEqual(store.shortcut(for: .allInOne), HotkeyAction.allInOne.defaultShortcut)
    }

    func testDisplayStringOrdersModifiersLikeMacOS() {
        let s = Shortcut(keyCode: 0, modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey), label: "A")
        XCTAssertEqual(s.display, "⌃⌥⇧⌘A")
    }
}
