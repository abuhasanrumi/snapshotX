import XCTest
@testable import SnapShotX

final class URLCommandTests: XCTestCase {
    private func parse(_ string: String) -> URLCommand? {
        URL(string: string).flatMap(URLCommand.parse)
    }

    func testParsesACaptureWithRegionDisplayAndAction() throws {
        let command = try XCTUnwrap(parse("snapshotx://capture-area?x=100&y=120&width=200&height=150&display=2&action=annotate"))
        XCTAssertEqual(command.kind, .captureArea)
        XCTAssertEqual(command.rect, CGRect(x: 100, y: 120, width: 200, height: 150))
        XCTAssertEqual(command.display, 2)
        XCTAssertEqual(command.action, .annotate)
    }

    func testBareCommandHasNoParameters() throws {
        let command = try XCTUnwrap(parse("snapshotx://capture-fullscreen"))
        XCTAssertEqual(command.kind, .captureFullscreen)
        XCTAssertNil(command.rect)
        XCTAssertNil(command.display)
        XCTAssertNil(command.action)
    }

    func testSchemeAndCommandAreCaseInsensitive() {
        XCTAssertEqual(parse("SnapShotX://Capture-Window")?.kind, .captureWindow)
    }

    func testOtherSchemesAndUnknownCommandsAreRejected() {
        XCTAssertNil(parse("cleanshot://capture-area"))
        XCTAssertNil(parse("https://example.com/capture-area"))
        XCTAssertNil(parse("snapshotx://format-disk"))
        XCTAssertNil(parse("snapshotx:capture-area"))
    }

    func testEveryCommandKindRoundTripsThroughItsName() {
        for kind in URLCommand.Kind.allCases {
            XCTAssertEqual(parse("snapshotx://\(kind.rawValue)")?.kind, kind, kind.rawValue)
        }
    }

    func testARegionNeedsAPositiveWidthAndHeight() throws {
        XCTAssertNil(try XCTUnwrap(parse("snapshotx://capture-area?x=10&y=10")).rect)
        XCTAssertNil(try XCTUnwrap(parse("snapshotx://capture-area?width=100")).rect)
        XCTAssertNil(try XCTUnwrap(parse("snapshotx://capture-area?width=0&height=50")).rect)
        XCTAssertEqual(try XCTUnwrap(parse("snapshotx://capture-area?width=100&height=50")).rect,
                       CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    func testDisplayNumbersStartAtOne() throws {
        XCTAssertNil(try XCTUnwrap(parse("snapshotx://capture-area?display=0")).display)
        XCTAssertEqual(try XCTUnwrap(parse("snapshotx://capture-area?display=1")).display, 1)
    }

    func testUnsupportedActionsAreIgnored() throws {
        XCTAssertNil(try XCTUnwrap(parse("snapshotx://capture-area?action=upload")).action)
        XCTAssertEqual(try XCTUnwrap(parse("snapshotx://capture-area?action=PIN")).action, .pin)
    }

    func testFilePathsMustBeAbsoluteAndAreDecoded() throws {
        let spaced = try XCTUnwrap(parse("snapshotx://pin?filepath=/Users/john/Desktop/my%20screenshot.png"))
        XCTAssertEqual(spaced.filepath?.path, "/Users/john/Desktop/my screenshot.png")
        XCTAssertNil(try XCTUnwrap(parse("snapshotx://pin?filepath=../secret.png")).filepath)
        XCTAssertNil(try XCTUnwrap(parse("snapshotx://pin?filepath=~/secret.png")).filepath)
    }

    func testBooleanFlags() throws {
        let command = try XCTUnwrap(parse("snapshotx://scrolling-capture?start=true&autoscroll=1&linebreaks=no"))
        XCTAssertEqual(command.start, true)
        XCTAssertEqual(command.autoscroll, true)
        XCTAssertEqual(command.linebreaks, false)
        XCTAssertNil(command.action)
    }

    func testSettingsTabs() throws {
        XCTAssertEqual(try XCTUnwrap(parse("snapshotx://open-settings?tab=permissions")).tab, .permissions)
        XCTAssertEqual(try XCTUnwrap(parse("snapshotx://open-settings?tab=shortcuts")).tab, .shortcuts)
        XCTAssertEqual(try XCTUnwrap(parse("snapshotx://open-settings?tab=nonsense")).tab, .general)
        XCTAssertNil(try XCTUnwrap(parse("snapshotx://open-settings")).tab)
    }
}
