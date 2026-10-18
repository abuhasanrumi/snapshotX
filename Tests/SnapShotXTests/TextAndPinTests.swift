import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
@testable import SnapShotX

final class TextAndPinTests: XCTestCase {
    // MARK: Reading order

    private func line(_ text: String, x: CGFloat, y: CGFloat) -> TextRecognizer.Line {
        TextRecognizer.Line(text: text, box: CGRect(x: x, y: y, width: 0.2, height: 0.05))
    }

    func testFragmentsReadTopToBottomAndLeftToRight() {
        let lines = [line("Bottom", x: 0.1, y: 0.1), line("Right", x: 0.5, y: 0.8), line("Left", x: 0.1, y: 0.805)]
        XCTAssertEqual(TextRecognizer.join(lines, keepLineBreaks: true), "Left Right\nBottom")
    }

    func testDroppingLineBreaksJoinsWithSpaces() {
        let lines = [line("One", x: 0.1, y: 0.8), line("Two", x: 0.1, y: 0.6), line("Three", x: 0.1, y: 0.4)]
        XCTAssertEqual(TextRecognizer.join(lines, keepLineBreaks: false), "One Two Three")
        XCTAssertEqual(TextRecognizer.join([], keepLineBreaks: true), "")
    }

    // MARK: Vision

    private func renderedText(_ text: String) -> CGImage {
        let ctx = CGContext(data: nil, width: 900, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 160))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(at: NSPoint(x: 30, y: 40), withAttributes: [
            .font: NSFont.systemFont(ofSize: 72, weight: .regular), .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    func testRecognizesPrintedText() async {
        let result = await TextRecognizer.recognize(in: renderedText("Hello SnapShotX"), keepLineBreaks: true)
        XCTAssertFalse(result.isQRCode)
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains("Hello"), "got: \(result.text)")
    }

    func testBlankImageHasNoText() async {
        let result = await TextRecognizer.recognize(in: renderedText(""), keepLineBreaks: true)
        XCTAssertTrue(result.isEmpty)
    }

    func testReadsAQRCode() async throws {
        let payload = "https://example.com/snapshotx"
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        let raw = try XCTUnwrap(filter.outputImage)
        let scaled = raw.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let image = try XCTUnwrap(CIContext().createCGImage(scaled, from: scaled.extent))

        let result = await TextRecognizer.recognize(in: image, keepLineBreaks: true)
        XCTAssertTrue(result.isQRCode)
        XCTAssertEqual(result.text, payload)
    }

    // MARK: Pinned screenshot sizing

    func testSmallScreenshotsPinAtNaturalSize() {
        let size = PinLayout.initialSize(imagePixels: CGSize(width: 800, height: 400), backingScale: 2,
                                         screenVisible: CGSize(width: 1440, height: 900))
        XCTAssertEqual(size, CGSize(width: 400, height: 200))
    }

    func testLargeScreenshotsShrinkToFitKeepingAspect() {
        let size = PinLayout.initialSize(imagePixels: CGSize(width: 5760, height: 2880), backingScale: 2,
                                         screenVisible: CGSize(width: 1440, height: 900))
        XCTAssertEqual(size.width, 864) // 60% of the screen width
        XCTAssertEqual(size.width / size.height, 2, accuracy: 0.01)
    }

    func testResizingKeepsAspectAndRespectsLimits() {
        let start = CGSize(width: 400, height: 200)
        XCTAssertEqual(PinLayout.resized(start, byFactor: 1.5, maxSize: CGSize(width: 4000, height: 4000)), CGSize(width: 600, height: 300))
        XCTAssertEqual(PinLayout.resized(start, byFactor: 0.01, maxSize: CGSize(width: 4000, height: 4000)).width, PinLayout.minimumWidth)
        let capped = PinLayout.resized(start, byFactor: 100, maxSize: CGSize(width: 1000, height: 300))
        XCTAssertEqual(capped, CGSize(width: 600, height: 300)) // the height limit wins
    }

    func testResizingKeepsTheCenterFixed() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 200)
        let resized = PinLayout.frame(resizing: frame, to: CGSize(width: 200, height: 100))
        XCTAssertEqual(resized.midX, frame.midX)
        XCTAssertEqual(resized.midY, frame.midY)
        XCTAssertEqual(resized.size, CGSize(width: 200, height: 100))
    }
}
