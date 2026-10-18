import XCTest
@testable import SnapShotX

final class GeometryTests: XCTestCase {
    func testAppKitRectFlipsAroundPrimaryHeight() {
        // A 100x50 window at the top-left of a 1000pt-high primary display.
        let cg = CGRect(x: 20, y: 0, width: 100, height: 50)
        let appKit = Geometry.appKitRect(fromTopLeftRect: cg, primaryScreenHeight: 1000)
        XCTAssertEqual(appKit, CGRect(x: 20, y: 950, width: 100, height: 50))
    }

    func testDisplayLocalRectOnPrimaryScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Selection hugging the bottom-left corner in AppKit space ends up at the bottom-left in top-left space.
        let local = Geometry.displayLocalRect(selection: CGRect(x: 10, y: 10, width: 200, height: 100), screenFrame: screen)
        XCTAssertEqual(local, CGRect(x: 10, y: 790, width: 200, height: 100))
    }

    func testDisplayLocalRectOnSecondaryScreenAboveAndRightOfPrimary() {
        let screen = CGRect(x: 1440, y: 200, width: 1920, height: 1080)
        let selection = CGRect(x: 1500, y: 1180, width: 300, height: 100) // 100pt below the screen's top edge
        let local = Geometry.displayLocalRect(selection: selection, screenFrame: screen)
        XCTAssertEqual(local, CGRect(x: 60, y: 0, width: 300, height: 100))
    }

    func testDisplayLocalRectOnScreenBelowPrimary() {
        let screen = CGRect(x: 0, y: -900, width: 1440, height: 900)
        let selection = CGRect(x: 0, y: -900, width: 100, height: 100) // bottom-left of that screen
        let local = Geometry.displayLocalRect(selection: selection, screenFrame: screen)
        XCTAssertEqual(local, CGRect(x: 0, y: 800, width: 100, height: 100))
    }

    func testTopmostPicksFirstWindowContainingPoint() {
        let front = WindowCandidate(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), title: "", owner: "A")
        let back = WindowCandidate(id: 2, frame: CGRect(x: 0, y: 0, width: 500, height: 500), title: "", owner: "B")
        XCTAssertEqual(Geometry.topmost(at: CGPoint(x: 50, y: 50), in: [front, back])?.id, 1)
        XCTAssertEqual(Geometry.topmost(at: CGPoint(x: 300, y: 300), in: [front, back])?.id, 2)
        XCTAssertNil(Geometry.topmost(at: CGPoint(x: 900, y: 900), in: [front, back]))
    }

    func testNormalizedRectHandlesAnyDragDirection() {
        let expected = CGRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(Geometry.normalizedRect(from: CGPoint(x: 40, y: 60), to: CGPoint(x: 10, y: 20)), expected)
        XCTAssertEqual(Geometry.normalizedRect(from: CGPoint(x: 10, y: 60), to: CGPoint(x: 40, y: 20)), expected)
    }
}
