import CoreGraphics
import XCTest
@testable import SnapShotX

@MainActor
final class DocumentTests: XCTestCase {
    private func makeDocument() -> AnnotationDocument {
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return AnnotationDocument(image: ctx.makeImage()!)
    }

    private func arrow() -> Annotation {
        Annotation(kind: .arrow(start: .zero, end: CGPoint(x: 10, y: 10)), color: .red, lineWidth: 4, fontSize: 14)
    }

    func testPerformIsOneUndoStep() {
        let doc = makeDocument()
        doc.perform { $0.annotations.append(arrow()) }
        XCTAssertEqual(doc.state.annotations.count, 1)
        XCTAssertTrue(doc.canUndo)

        doc.undo()
        XCTAssertTrue(doc.state.annotations.isEmpty)
        XCTAssertTrue(doc.canRedo)

        doc.redo()
        XCTAssertEqual(doc.state.annotations.count, 1)
    }

    func testManyLiveUpdatesBetweenBeginAndEndAreOneUndoStep() {
        let doc = makeDocument()
        let annotation = arrow()
        doc.beginChange()
        doc.update { $0.annotations.append(annotation) }
        for x in 1...20 {
            doc.update { $0.annotations[0] = $0.annotations[0].translated(by: CGVector(dx: Double(x), dy: 0)) }
        }
        doc.endChange()

        doc.undo()
        XCTAssertTrue(doc.state.annotations.isEmpty)
        XCTAssertFalse(doc.canUndo)
    }

    func testGestureThatChangesNothingLeavesNoUndoStep() {
        let doc = makeDocument()
        doc.beginChange()
        doc.endChange()
        XCTAssertFalse(doc.canUndo)
    }

    func testNewEditClearsTheRedoStack() {
        let doc = makeDocument()
        doc.perform { $0.annotations.append(arrow()) }
        doc.undo()
        XCTAssertTrue(doc.canRedo)
        doc.perform { $0.crop = CGRect(x: 0, y: 0, width: 10, height: 10) }
        XCTAssertFalse(doc.canRedo)
    }

    func testRemoveSelectedDeletesAndCanBeUndone() {
        let doc = makeDocument()
        let annotation = arrow()
        doc.perform { $0.annotations.append(annotation) }
        doc.selectedID = annotation.id
        doc.removeSelected()
        XCTAssertTrue(doc.state.annotations.isEmpty)
        XCTAssertNil(doc.selectedID)
        doc.undo()
        XCTAssertEqual(doc.state.annotations.first?.id, annotation.id)
    }

    func testChangingColorRecolorsTheSelectedAnnotation() {
        let doc = makeDocument()
        let annotation = arrow()
        doc.perform { $0.annotations.append(annotation) }
        doc.selectedID = annotation.id
        let blue = RGBAColor(hex: 0x0A84FF)
        doc.setColor(blue)
        XCTAssertEqual(doc.state.annotations[0].color, blue)
        XCTAssertEqual(doc.color, blue)
    }

    func testCounterNumbersContinueFromTheHighest() {
        let doc = makeDocument()
        XCTAssertEqual(doc.nextCounterNumber, 1)
        doc.perform {
            $0.annotations.append(Annotation(kind: .counter(center: .zero, number: 1), color: .red, lineWidth: 4, fontSize: 14))
            $0.annotations.append(Annotation(kind: .counter(center: .zero, number: 5), color: .red, lineWidth: 4, fontSize: 14))
        }
        XCTAssertEqual(doc.nextCounterNumber, 6)
    }

    func testStrokeUnitScalesWithImageSize() {
        XCTAssertEqual(makeDocument().strokeUnit, 1) // 200px wide is below the 800px reference
    }
}
