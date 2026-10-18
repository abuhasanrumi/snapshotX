import XCTest
@testable import SnapShotX

final class SelectionEditorTests: XCTestCase {
    /// A 1000×800 screen. Coordinates have a bottom-left origin.
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    /// minX 100, maxX 300, minY 100, maxY 200. Aspect ratio 2.
    private let rect = CGRect(x: 100, y: 100, width: 200, height: 100)

    // MARK: Creating

    func testDraggingInAnyDirectionMakesTheSameRect() {
        let expected = CGRect(x: 100, y: 100, width: 200, height: 150)
        XCTAssertEqual(SelectionEditor.created(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250), within: bounds, lockAspect: false, aspect: 1), expected)
        XCTAssertEqual(SelectionEditor.created(from: CGPoint(x: 300, y: 250), to: CGPoint(x: 100, y: 100), within: bounds, lockAspect: false, aspect: 1), expected)
    }

    func testCreatingStaysInsideTheScreen() {
        let r = SelectionEditor.created(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 1200, y: 900), within: bounds, lockAspect: false, aspect: 1)
        XCTAssertEqual(r, CGRect(x: 100, y: 100, width: 900, height: 700))
    }

    func testLockedCreationKeepsTheRatio() {
        let r = SelectionEditor.created(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 200), within: bounds, lockAspect: true, aspect: 2)
        XCTAssertEqual(r, CGRect(x: 100, y: 100, width: 300, height: 150))

        let backwards = SelectionEditor.created(from: CGPoint(x: 500, y: 500), to: CGPoint(x: 300, y: 450), within: bounds, lockAspect: true, aspect: 2)
        XCTAssertEqual(backwards, CGRect(x: 300, y: 400, width: 200, height: 100))
    }

    func testLockedCreationNearAnEdgeShrinksInsteadOfOverflowing() {
        let r = SelectionEditor.created(from: CGPoint(x: 900, y: 700), to: CGPoint(x: 1500, y: 1500), within: bounds, lockAspect: true, aspect: 1)
        XCTAssertEqual(r, CGRect(x: 900, y: 700, width: 100, height: 100))
    }

    // MARK: Moving

    func testMovingShiftsTheRect() {
        XCTAssertEqual(SelectionEditor.moved(rect, by: CGVector(dx: 50, dy: -30), within: bounds), CGRect(x: 150, y: 70, width: 200, height: 100))
    }

    func testMovingStopsAtTheScreenEdges() {
        XCTAssertEqual(SelectionEditor.moved(rect, by: CGVector(dx: -500, dy: -500), within: bounds).origin, CGPoint(x: 0, y: 0))
        XCTAssertEqual(SelectionEditor.moved(rect, by: CGVector(dx: 2000, dy: 2000), within: bounds).origin, CGPoint(x: 800, y: 700))
    }

    // MARK: Resizing

    private func resize(_ handle: SelectionHandle, to point: CGPoint, lock: Bool = false, aspect: CGFloat = 2) -> CGRect {
        SelectionEditor.resized(rect, handle: handle, to: point, within: bounds, lockAspect: lock, aspect: aspect)
    }

    func testCornerAndEdgeResizingWithoutLock() {
        XCTAssertEqual(resize(.topRight, to: CGPoint(x: 400, y: 300)), CGRect(x: 100, y: 100, width: 300, height: 200))
        XCTAssertEqual(resize(.left, to: CGPoint(x: 150, y: 999)), CGRect(x: 150, y: 100, width: 150, height: 100))
        XCTAssertEqual(resize(.bottom, to: CGPoint(x: 0, y: 40)), CGRect(x: 100, y: 40, width: 200, height: 160))
    }

    func testResizingPastTheOppositeSideFlipsTheRect() {
        XCTAssertEqual(resize(.right, to: CGPoint(x: 50, y: 0)), CGRect(x: 50, y: 100, width: 50, height: 100))
    }

    func testResizingStopsAtTheScreenEdges() {
        XCTAssertEqual(resize(.topRight, to: CGPoint(x: 2000, y: 2000)), CGRect(x: 100, y: 100, width: 900, height: 700))
    }

    func testLockedCornerResizeKeepsTheOppositeCornerAndTheRatio() {
        let bottomRight = resize(.bottomRight, to: CGPoint(x: 500, y: 0), lock: true)
        XCTAssertEqual(bottomRight, CGRect(x: 100, y: 0, width: 400, height: 200)) // top-left (100, 200) fixed

        let topLeft = resize(.topLeft, to: CGPoint(x: 0, y: 400), lock: true)
        XCTAssertEqual(topLeft, CGRect(x: 0, y: 100, width: 300, height: 150)) // bottom-right (300, 100) fixed
        XCTAssertEqual(topLeft.width / topLeft.height, 2, accuracy: 0.0001)
    }

    func testLockedEdgeResizeScalesTheOtherSideAroundTheCenter() {
        XCTAssertEqual(resize(.right, to: CGPoint(x: 500, y: 0), lock: true), CGRect(x: 100, y: 50, width: 400, height: 200))
        XCTAssertEqual(resize(.left, to: CGPoint(x: 0, y: 0), lock: true), CGRect(x: 0, y: 75, width: 300, height: 150))
        XCTAssertEqual(resize(.top, to: CGPoint(x: 0, y: 300), lock: true), CGRect(x: 0, y: 100, width: 400, height: 200))
    }

    // MARK: Typed sizes

    func testTypingASizeKeepsTheTopLeftCorner() {
        XCTAssertEqual(SelectionEditor.withSize(rect, width: 300, height: nil, within: bounds, lockAspect: false, aspect: 2),
                       CGRect(x: 100, y: 100, width: 300, height: 100))
        XCTAssertEqual(SelectionEditor.withSize(rect, width: nil, height: 150, within: bounds, lockAspect: false, aspect: 2),
                       CGRect(x: 100, y: 50, width: 200, height: 150))
    }

    func testLockedTypedSizeDrivesTheOtherSide() {
        XCTAssertEqual(SelectionEditor.withSize(rect, width: 400, height: nil, within: bounds, lockAspect: true, aspect: 2),
                       CGRect(x: 100, y: 0, width: 400, height: 200))
        XCTAssertEqual(SelectionEditor.withSize(rect, width: nil, height: 150, within: bounds, lockAspect: true, aspect: 2),
                       CGRect(x: 100, y: 50, width: 300, height: 150))
    }

    func testTypedSizesAreClampedIndependentlyWhenUnlocked() {
        let r = SelectionEditor.withSize(rect, width: 5000, height: nil, within: bounds, lockAspect: false, aspect: 2)
        XCTAssertEqual(r, CGRect(x: 100, y: 100, width: 900, height: 100)) // height is untouched
    }

    func testTypedSizesAreClampedTogetherWhenLocked() {
        let r = SelectionEditor.withSize(rect, width: 5000, height: nil, within: bounds, lockAspect: true, aspect: 2)
        XCTAssertEqual(r.width / r.height, 2, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(r.maxX, bounds.maxX)
        XCTAssertGreaterThanOrEqual(r.minY, bounds.minY)
    }

    func testTinyTypedSizesAreRaisedToTheMinimum() {
        let r = SelectionEditor.withSize(rect, width: 1, height: 1, within: bounds, lockAspect: false, aspect: 2)
        XCTAssertEqual(r.size, CGSize(width: SelectionEditor.minimumSide, height: SelectionEditor.minimumSide))
    }

    // MARK: Hit testing

    func testHandlesAreFoundAtCornersAndAlongEdges() {
        func hit(_ x: CGFloat, _ y: CGFloat) -> SelectionHandle? {
            SelectionEditor.handle(at: CGPoint(x: x, y: y), in: rect, tolerance: 8)
        }
        XCTAssertEqual(hit(100, 200), .topLeft)
        XCTAssertEqual(hit(302, 98), .bottomRight)
        XCTAssertEqual(hit(200, 201), .top)
        XCTAssertEqual(hit(99, 150), .left)
        XCTAssertEqual(hit(250, 100), .bottom)
        XCTAssertEqual(hit(300, 160), .right)
    }

    func testCornersWinOverEdgesWhereTheyOverlap() {
        XCTAssertEqual(SelectionEditor.handle(at: CGPoint(x: 100, y: 102), in: rect, tolerance: 8), .bottomLeft)
    }

    func testNothingIsHitInTheMiddleOrFarAway() {
        XCTAssertNil(SelectionEditor.handle(at: CGPoint(x: 200, y: 150), in: rect, tolerance: 8))
        XCTAssertNil(SelectionEditor.handle(at: CGPoint(x: 500, y: 500), in: rect, tolerance: 8))
    }

    // MARK: Memory

    func testMemoryRoundTripsThroughDefaults() {
        let suite = "snapshotx.allinone.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(AllInOneMemory.load(from: defaults))
        let memory = AllInOneMemory(displayID: 42, rect: CGRect(x: 10, y: 20, width: 300, height: 200), mode: .scrolling)
        memory.save(to: defaults)
        XCTAssertEqual(AllInOneMemory.load(from: defaults), memory)
    }

    func testCorruptMemoryIsIgnored() {
        let suite = "snapshotx.allinone.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("nonsense".utf8), forKey: "allInOne.last.v1")
        XCTAssertNil(AllInOneMemory.load(from: defaults))
    }

    func testEveryModeHasADistinctConfirmLabel() {
        XCTAssertEqual(Set(AllInOneMode.allCases.map(\.confirmTitle)).count, AllInOneMode.allCases.count)
    }
}
