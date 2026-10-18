import XCTest
@testable import SnapShotX

final class PreferencesTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "snapshotx.prefs.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testDefaultsMatchCleanShotStyleFlow() {
        let prefs = Preferences(defaults: makeDefaults())
        XCTAssertTrue(prefs.autoCopy)
        XCTAssertFalse(prefs.autoSave)
        XCTAssertFalse(prefs.showCursor)
        XCTAssertEqual(prefs.overlayCorner, .bottomLeft)
        XCTAssertEqual(prefs.overlayAutoCloseSeconds, 6)
        XCTAssertTrue(prefs.saveFolderPath.hasSuffix("/Desktop"))
    }

    func testChangesPersistAcrossInstances() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)
        prefs.autoSave = true
        prefs.autoCopy = false
        prefs.overlayCorner = .topRight
        prefs.overlayAutoCloseSeconds = 0
        prefs.saveFolderPath = "/tmp/shots"

        let reloaded = Preferences(defaults: defaults)
        XCTAssertTrue(reloaded.autoSave)
        XCTAssertFalse(reloaded.autoCopy)
        XCTAssertEqual(reloaded.overlayCorner, .topRight)
        XCTAssertEqual(reloaded.overlayAutoCloseSeconds, 0)
        XCTAssertEqual(reloaded.saveFolder.path, "/tmp/shots")
    }
}
