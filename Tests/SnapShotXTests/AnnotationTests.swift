import XCTest
@testable import SnapShotX

final class AnnotationTests: XCTestCase {
    private func annotation(_ kind: AnnotationKind, width: Double = 4) -> Annotation {
        Annotation(kind: kind, color: .red, lineWidth: width, fontSize: 20)
    }

    func testLineHitTestUsesDistanceToSegment() {
        let line = annotation(.line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0)))
        XCTAssertTrue(line.hitTest(CGPoint(x: 50, y: 3), tolerance: 2))
        XCTAssertFalse(line.hitTest(CGPoint(x: 50, y: 20), tolerance: 2))
        XCTAssertFalse(line.hitTest(CGPoint(x: 140, y: 0), tolerance: 2))
    }

    func testUnfilledRectangleOnlyHitsItsBorder() {
        let rect = annotation(.rectangle(rect: CGRect(x: 0, y: 0, width: 100, height: 100), filled: false))
        XCTAssertTrue(rect.hitTest(CGPoint(x: 0, y: 50), tolerance: 2))
        XCTAssertFalse(rect.hitTest(CGPoint(x: 50, y: 50), tolerance: 2))
    }

    func testFilledRectangleHitsItsInterior() {
        let rect = annotation(.rectangle(rect: CGRect(x: 0, y: 0, width: 100, height: 100), filled: true))
        XCTAssertTrue(rect.hitTest(CGPoint(x: 50, y: 50), tolerance: 2))
        XCTAssertFalse(rect.hitTest(CGPoint(x: 200, y: 50), tolerance: 2))
    }

    func testUnfilledEllipseHitsRingNotCenter() {
        let ellipse = annotation(.ellipse(rect: CGRect(x: 0, y: 0, width: 100, height: 60), filled: false))
        XCTAssertTrue(ellipse.hitTest(CGPoint(x: 100, y: 30), tolerance: 2))
        XCTAssertFalse(ellipse.hitTest(CGPoint(x: 50, y: 30), tolerance: 2))
    }

    func testPencilHitTestFollowsThePath() {
        let pencil = annotation(.pencil(points: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 0)]))
        XCTAssertTrue(pencil.hitTest(CGPoint(x: 25, y: 25), tolerance: 2))
        XCTAssertFalse(pencil.hitTest(CGPoint(x: 50, y: 0), tolerance: 2))
    }

    func testTranslationMovesEveryKind() {
        let delta = CGVector(dx: 10, dy: -5)
        XCTAssertEqual(annotation(.arrow(start: .zero, end: CGPoint(x: 5, y: 5))).translated(by: delta).kind,
                       .arrow(start: CGPoint(x: 10, y: -5), end: CGPoint(x: 15, y: 0)))
        XCTAssertEqual(annotation(.blur(rect: CGRect(x: 0, y: 0, width: 4, height: 4))).translated(by: delta).kind,
                       .blur(rect: CGRect(x: 10, y: -5, width: 4, height: 4)))
        XCTAssertEqual(annotation(.counter(center: CGPoint(x: 1, y: 1), number: 3)).translated(by: delta).kind,
                       .counter(center: CGPoint(x: 11, y: -4), number: 3))
    }

    func testResizingACornerKeepsTheOppositeCornerFixed() {
        let rect = annotation(.rectangle(rect: CGRect(x: 10, y: 10, width: 40, height: 40), filled: false))
        let resized = rect.resized(handle: .bottomRight, to: CGPoint(x: 100, y: 80))
        XCTAssertEqual(resized.kind, .rectangle(rect: CGRect(x: 10, y: 10, width: 90, height: 70), filled: false))
    }

    func testResizingPastTheOppositeCornerFlipsTheRect() {
        let rect = annotation(.blur(rect: CGRect(x: 10, y: 10, width: 40, height: 40)))
        let resized = rect.resized(handle: .bottomRight, to: CGPoint(x: 0, y: 0))
        XCTAssertEqual(resized.kind, .blur(rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
    }

    func testArrowEndpointHandlesMoveOnlyThatEnd() {
        let arrow = annotation(.arrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 50, y: 50)))
        XCTAssertEqual(arrow.handles.map(\.id), [.start, .end])
        XCTAssertEqual(arrow.resized(handle: .start, to: CGPoint(x: 5, y: 6)).kind,
                       .arrow(start: CGPoint(x: 5, y: 6), end: CGPoint(x: 50, y: 50)))
    }

    func testPencilAndTextHaveNoResizeHandles() {
        XCTAssertTrue(annotation(.pencil(points: [.zero])).handles.isEmpty)
        XCTAssertTrue(annotation(.text(origin: .zero, string: "hi")).handles.isEmpty)
    }

    func testSmoothingKeepsEndpointsAndStaysNearTheOriginalPath() {
        let original = (0...20).map { CGPoint(x: Double($0) * 5, y: $0 % 2 == 0 ? 0 : 3) }
        let smoothed = PathSmoothing.smooth(original)
        XCTAssertEqual(smoothed.first, original.first)
        XCTAssertEqual(smoothed.last, original.last)
        XCTAssertTrue(smoothed.allSatisfy { $0.y >= 0 && $0.y <= 3 })
    }

    func testDecimationDropsNearDuplicatePoints() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 10, y: 0)]
        XCTAssertEqual(PathSmoothing.decimate(points, minDistance: 2), [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)])
    }

    func testShiftConstraintSnapsToFortyFiveDegrees() {
        let end = Geometry.constrainedEnd(from: .zero, to: CGPoint(x: 100, y: 8))
        XCTAssertEqual(end.x, 100.3, accuracy: 0.5)
        XCTAssertEqual(end.y, 0, accuracy: 0.001)
        let diagonal = Geometry.constrainedEnd(from: .zero, to: CGPoint(x: 50, y: 60))
        XCTAssertEqual(diagonal.x, diagonal.y, accuracy: 0.001)
    }

    func testSquareRectUsesTheLongerSide() {
        XCTAssertEqual(Geometry.squareRect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 60)),
                       CGRect(x: 10, y: 10, width: 50, height: 50))
        // Dragging left and slightly down: the 30pt-long side wins, so the square extends 30 left and 30 down.
        XCTAssertEqual(Geometry.squareRect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: -20, y: 15)),
                       CGRect(x: -20, y: 10, width: 30, height: 30))
    }

    func testEditorStateSurvivesJSONRoundTrip() throws {
        var state = EditorState()
        state.annotations = [
            annotation(.arrow(start: .zero, end: CGPoint(x: 9, y: 9))),
            annotation(.text(origin: CGPoint(x: 3, y: 4), string: "Hello")),
            annotation(.pencil(points: [.zero, CGPoint(x: 1, y: 2)])),
            annotation(.counter(center: CGPoint(x: 5, y: 5), number: 2)),
        ]
        state.crop = CGRect(x: 1, y: 2, width: 30, height: 40)
        state.background.enabled = true
        state.background.fill = .solid(RGBAColor(hex: 0x123456))
        let decoded = try JSONDecoder().decode(EditorState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
    }
}
