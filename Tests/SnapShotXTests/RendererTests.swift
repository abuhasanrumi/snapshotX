import CoreGraphics
import XCTest
@testable import SnapShotX

final class RendererTests: XCTestCase {
    /// Left half white, right half black, so effects have something to act on.
    private func twoToneImage(width: Int = 200, height: Int = 100) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return ctx.makeImage()!
    }

    /// RGBA at a top-left based pixel.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let i = (y * image.width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
    }

    private func export(_ state: EditorState, base: CGImage? = nil) -> CGImage {
        Renderer.export(base: base ?? twoToneImage(), state: state)!
    }

    func testUneditedExportMatchesTheOriginalOrientationAndSize() {
        let image = export(EditorState())
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 100)
        XCTAssertGreaterThan(pixel(image, 10, 50).r, 250) // left is white
        XCTAssertLessThan(pixel(image, 190, 50).r, 5) // right is black
    }

    func testFilledRectangleLandsWhereItWasDrawn() {
        var state = EditorState()
        state.annotations = [Annotation(kind: .rectangle(rect: CGRect(x: 10, y: 10, width: 30, height: 20), filled: true),
                                        color: RGBAColor(hex: 0xFF0000), lineWidth: 4, fontSize: 14)]
        let image = export(state)
        let inside = pixel(image, 20, 20)
        XCTAssertGreaterThan(inside.r, 240)
        XCTAssertLessThan(inside.g, 20)
        let outside = pixel(image, 20, 60) // below the rectangle, still white
        XCTAssertGreaterThan(outside.g, 240)
    }

    func testCropShrinksTheCanvasAndShowsTheRightRegion() {
        var state = EditorState()
        state.crop = CGRect(x: 100, y: 0, width: 100, height: 100) // right, black half
        let image = export(state)
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 100)
        XCTAssertLessThan(pixel(image, 50, 50).r, 5)
    }

    func testBackgroundGrowsTheCanvasAndFillsThePadding() {
        var state = EditorState()
        state.background.enabled = true
        state.background.fill = .solid(RGBAColor(hex: 0x00FF00))
        state.background.padding = 0.2
        state.background.shadow = 0
        let image = export(state)
        XCTAssertEqual(image.width, 240) // 200 + 2 * (0.2 * 100)
        XCTAssertEqual(image.height, 140)
        let corner = pixel(image, 2, 2)
        XCTAssertLessThan(corner.r, 10)
        XCTAssertGreaterThan(corner.g, 240)
        XCTAssertGreaterThan(pixel(image, 40, 70).r, 250) // screenshot's white half sits inside the padding
    }

    func testRoundedCornersRevealTheBackgroundAtTheCorner() {
        var state = EditorState()
        state.background.enabled = true
        state.background.fill = .solid(RGBAColor(hex: 0x00FF00))
        state.background.padding = 0.2
        state.background.cornerRadius = 0.1
        state.background.shadow = 0
        let image = export(state)
        // Content starts at (20, 20); its very corner pixel is outside the rounded clip.
        let corner = pixel(image, 20, 20)
        XCTAssertGreaterThan(corner.g, 200)
        XCTAssertLessThan(corner.r, 60)
    }

    func testPixelateChangesTheBoundaryBetweenTwoTones() {
        var state = EditorState()
        // The region starts at x = 78 so the hard edge at x = 100 falls inside a 10px block, not on a block boundary.
        state.annotations = [Annotation(kind: .pixelate(rect: CGRect(x: 78, y: 0, width: 44, height: 100)),
                                        color: .red, lineWidth: 4, fontSize: 14)]
        let image = export(state)
        // Originally x = 99 is white and x = 100 is black. Pixelation maps both into the same block, so they now match
        // (which tone the block takes depends on how CIPixellate samples it, so only the merge is asserted).
        XCTAssertEqual(pixel(image, 99, 50).r, pixel(image, 100, 50).r)
        XCTAssertGreaterThan(pixel(image, 10, 50).r, 250) // outside the region is untouched
        XCTAssertLessThan(pixel(image, 190, 50).r, 5)
    }

    func testBlurSoftensTheHardEdge() {
        var state = EditorState()
        state.annotations = [Annotation(kind: .blur(rect: CGRect(x: 60, y: 0, width: 80, height: 100)),
                                        color: .red, lineWidth: 4, fontSize: 14)]
        let image = export(state)
        let mid = pixel(image, 100, 50).r
        XCTAssertGreaterThan(mid, 40)
        XCTAssertLessThan(mid, 215)
        XCTAssertGreaterThan(pixel(image, 10, 50).r, 250) // outside the blur is untouched
    }

    func testSpotlightDimsEverythingOutsideItsRect() {
        var state = EditorState()
        state.annotations = [Annotation(kind: .spotlight(rect: CGRect(x: 10, y: 10, width: 40, height: 40)),
                                        color: .red, lineWidth: 4, fontSize: 14)]
        let image = export(state)
        XCTAssertGreaterThan(pixel(image, 30, 30).r, 250) // inside the spotlight stays bright
        let dimmed = pixel(image, 80, 80).r // white area outside it is darkened
        XCTAssertLessThan(dimmed, 200)
        XCTAssertGreaterThan(dimmed, 60)
    }

    func testGeometryMapsImagePointsThroughCropAndPadding() {
        var state = EditorState()
        state.crop = CGRect(x: 50, y: 20, width: 100, height: 60)
        state.background.enabled = true
        state.background.padding = 0.1
        let geo = Renderer.geometry(imageSize: CGSize(width: 200, height: 100), state: state)
        let canvasPoint = geo.canvasPoint(fromImage: CGPoint(x: 50, y: 20))
        XCTAssertEqual(canvasPoint, geo.contentRect.origin)
        XCTAssertEqual(geo.imagePoint(fromCanvas: canvasPoint), CGPoint(x: 50, y: 20))
    }

    func testIgnoringCropAndBackgroundShowsTheWholeImage() {
        var state = EditorState()
        state.crop = CGRect(x: 0, y: 0, width: 10, height: 10)
        state.background.enabled = true
        let geo = Renderer.geometry(imageSize: CGSize(width: 200, height: 100), state: state, ignoreCropAndBackground: true)
        XCTAssertEqual(geo.canvasSize, CGSize(width: 200, height: 100))
        XCTAssertFalse(geo.hasBackground)
    }

    func testProjectFileRoundTripKeepsPixelsAndEdits() throws {
        var state = EditorState()
        state.annotations = [Annotation(kind: .text(origin: CGPoint(x: 5, y: 5), string: "Hi"), color: .red, lineWidth: 4, fontSize: 20)]
        state.crop = CGRect(x: 0, y: 0, width: 50, height: 50)
        let data = try ProjectFile.encode(image: twoToneImage(), state: state)
        let decoded = try ProjectFile.decode(data)
        XCTAssertEqual(decoded.state, state)
        XCTAssertEqual(decoded.image.width, 200)
        XCTAssertGreaterThan(pixel(decoded.image, 10, 50).r, 250)
        XCTAssertLessThan(pixel(decoded.image, 190, 50).r, 5)
    }

    func testGarbageIsNotAProject() {
        XCTAssertThrowsError(try ProjectFile.decode(Data("not json".utf8)))
    }
}
