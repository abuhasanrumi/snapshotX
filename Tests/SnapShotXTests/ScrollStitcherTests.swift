import CoreGraphics
import XCTest
@testable import SnapShotX

final class ScrollStitcherTests: XCTestCase {
    private let width = 120
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A tall page where every row is different, so any wrong alignment shows up as a pixel difference.
    private func makePage(rows: Int, seed: UInt64 = 1) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: rows * width * 4)
        for row in 0..<rows {
            var state = (UInt64(row) &+ seed &* 7919) &* 6364136223846793005 &+ 1442695040888963407
            for x in 0..<width {
                for channel in 0..<3 {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    bytes[(row * width + x) * 4 + channel] = UInt8(truncatingIfNeeded: state >> 33)
                }
            }
        }
        return bytes
    }

    private func image(rows: [UInt8], height: Int) -> CGImage {
        var copy = rows
        let ctx = copy.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        return ctx.makeImage()!
    }

    /// The frame showing page rows `top ..< top + height`, optionally with a fixed header drawn over its top rows.
    private func frame(of page: [UInt8], top: Int, height: Int, header: [UInt8]? = nil) -> CGImage {
        var rows = Array(page[(top * width * 4)..<((top + height) * width * 4)])
        if let header { rows.replaceSubrange(0..<header.count, with: header) }
        return image(rows: rows, height: height)
    }

    private func bytes(of image: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = out.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return out
    }

    private func rows(_ page: [UInt8], _ range: Range<Int>) -> [UInt8] {
        Array(page[(range.lowerBound * width * 4)..<(range.upperBound * width * 4)])
    }

    func testStitchesDownwardScrollingBackIntoTheOriginalPage() throws {
        let page = makePage(rows: 1000)
        let stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.add(frame(of: page, top: 0, height: 300)), .first)
        XCTAssertEqual(stitcher.add(frame(of: page, top: 110, height: 300)), .appended(110))
        XCTAssertEqual(stitcher.add(frame(of: page, top: 230, height: 300)), .appended(120))
        XCTAssertEqual(stitcher.add(frame(of: page, top: 370, height: 300)), .appended(140))
        XCTAssertEqual(stitcher.add(frame(of: page, top: 500, height: 300)), .appended(130))
        XCTAssertEqual(stitcher.height, 800)

        let result = try XCTUnwrap(stitcher.finish())
        XCTAssertEqual(result.height, 800)
        XCTAssertEqual(bytes(of: result), rows(page, 0..<800))
    }

    func testUnchangedFramesAddNothing() {
        let page = makePage(rows: 600)
        let stitcher = ScrollStitcher()
        _ = stitcher.add(frame(of: page, top: 0, height: 300))
        XCTAssertEqual(stitcher.add(frame(of: page, top: 0, height: 300)), .unchanged)
        XCTAssertEqual(stitcher.height, 300)
    }

    func testScrollingUpAddsRowsAboveTheFirstFrame() throws {
        let page = makePage(rows: 1000)
        let stitcher = ScrollStitcher()
        _ = stitcher.add(frame(of: page, top: 400, height: 300))
        XCTAssertEqual(stitcher.add(frame(of: page, top: 300, height: 300)), .appended(100))
        XCTAssertEqual(stitcher.add(frame(of: page, top: 180, height: 300)), .appended(120))

        let result = try XCTUnwrap(stitcher.finish())
        XCTAssertEqual(bytes(of: result), rows(page, 180..<700))
    }

    func testScrollingBackOverKnownContentDoesNotDuplicateIt() throws {
        let page = makePage(rows: 1000)
        let stitcher = ScrollStitcher()
        _ = stitcher.add(frame(of: page, top: 0, height: 300))
        _ = stitcher.add(frame(of: page, top: 150, height: 300))
        _ = stitcher.add(frame(of: page, top: 300, height: 300))
        XCTAssertEqual(stitcher.add(frame(of: page, top: 150, height: 300)), .appended(0)) // back up: nothing new
        // Forward again by 200: the frame ends at row 650, only 50 rows past what was already captured.
        XCTAssertEqual(stitcher.add(frame(of: page, top: 350, height: 300)), .appended(50))

        let result = try XCTUnwrap(stitcher.finish())
        XCTAssertEqual(result.height, 650)
        XCTAssertEqual(bytes(of: result), rows(page, 0..<650))
    }

    func testAJumpWithNoOverlapCannotBeStitched() {
        let page = makePage(rows: 1000)
        let stitcher = ScrollStitcher()
        _ = stitcher.add(frame(of: page, top: 0, height: 300))
        // Scrolled a full frame height in one step, so the two frames share no rows.
        XCTAssertEqual(stitcher.add(frame(of: page, top: 300, height: 300)), .noMatch)
        XCTAssertEqual(stitcher.height, 300)
    }

    func testAFixedHeaderAppearsOnlyOnceAtTheTop() throws {
        let page = makePage(rows: 1000)
        let header = rows(makePage(rows: 40, seed: 99), 0..<40)
        let stitcher = ScrollStitcher()
        for top in [0, 100, 200, 350] {
            _ = stitcher.add(frame(of: page, top: top, height: 300, header: header))
        }
        XCTAssertEqual(stitcher.height, 650)

        var expected = rows(page, 0..<650)
        expected.replaceSubrange(0..<header.count, with: header)
        let result = try XCTUnwrap(stitcher.finish())
        XCTAssertEqual(bytes(of: result), expected)
    }

    func testAnUnrelatedFrameIsRejectedAndTheStitcherRecovers() throws {
        let page = makePage(rows: 1000)
        let stranger = makePage(rows: 400, seed: 12345)
        let stitcher = ScrollStitcher()
        _ = stitcher.add(frame(of: page, top: 0, height: 300))
        XCTAssertEqual(stitcher.add(frame(of: stranger, top: 0, height: 300)), .noMatch)
        XCTAssertEqual(stitcher.height, 300)

        XCTAssertEqual(stitcher.add(frame(of: page, top: 120, height: 300)), .appended(120))
        let result = try XCTUnwrap(stitcher.finish())
        XCTAssertEqual(bytes(of: result), rows(page, 0..<420))
    }

    func testStopsAtTheHeightLimit() {
        let page = makePage(rows: 1000)
        let stitcher = ScrollStitcher(maxHeight: 350)
        _ = stitcher.add(frame(of: page, top: 0, height: 300))
        XCTAssertEqual(stitcher.add(frame(of: page, top: 40, height: 300)), .appended(40))
        XCTAssertEqual(stitcher.add(frame(of: page, top: 120, height: 300)), .full)
        XCTAssertEqual(stitcher.height, 340)
    }

    func testASingleFrameFinishesAsItself() throws {
        let page = makePage(rows: 300)
        let stitcher = ScrollStitcher()
        _ = stitcher.add(frame(of: page, top: 0, height: 300))
        let result = try XCTUnwrap(stitcher.finish())
        XCTAssertEqual(bytes(of: result), page)
    }

    func testNothingAddedMeansNothingToFinish() {
        XCTAssertNil(ScrollStitcher().finish())
    }
}

final class ScrollAxisAndStickyTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    private func page(width: Int, rows: Int, seed: UInt64 = 1) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: rows * width * 4)
        for row in 0..<rows {
            var state = (UInt64(row) &+ seed &* 7919) &* 6364136223846793005 &+ 1442695040888963407
            for x in 0..<width {
                for c in 0..<3 {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    bytes[(row * width + x) * 4 + c] = UInt8(truncatingIfNeeded: state >> 33)
                }
            }
        }
        let ctx = bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: rows, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        return ctx.makeImage()!
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = out.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return out
    }

    func testTransposeTwiceIsIdentityAndSwapsSides() {
        let p = page(width: 50, rows: 30)
        let t = p.transposed()!
        XCTAssertEqual(t.width, 30)
        XCTAssertEqual(t.height, 50)
        XCTAssertEqual(bytes(t.transposed()!), bytes(p))
        // pixel (x: 7, y: 3) of the original is pixel (x: 3, y: 7) of the transpose
        let a = bytes(p), b = bytes(t)
        for c in 0..<3 { XCTAssertEqual(a[(3 * 50 + 7) * 4 + c], b[(7 * 30 + 3) * 4 + c]) }
    }

    func testHorizontalScrollStitchesToTheWidePage() throws {
        let wide = page(width: 120, rows: 500).transposed()! // 500 wide, 120 tall
        let stitcher = ScrollStitcher(axis: .horizontal)
        for left in [0, 90, 180, 270] {
            _ = stitcher.add(wide.cropping(to: CGRect(x: left, y: 0, width: 150, height: 120))!)
        }
        let out = try XCTUnwrap(stitcher.finish())
        XCTAssertEqual(out.width, 420)
        XCTAssertEqual(out.height, 120)
        XCTAssertEqual(bytes(out), bytes(wide.cropping(to: CGRect(x: 0, y: 0, width: 420, height: 120))!))
    }

    func testFixedFooterIsNotRepeated() throws {
        let width = 120, frameHeight = 200, footerRows = 30
        let content = page(width: width, rows: 700)
        let footer = page(width: width, rows: footerRows, seed: 99)
        func frame(top: Int) -> CGImage {
            let ctx = CGContext(data: nil, width: width, height: frameHeight, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(content.cropping(to: CGRect(x: 0, y: top, width: width, height: frameHeight))!,
                     in: CGRect(x: 0, y: 0, width: width, height: frameHeight))
            ctx.draw(footer, in: CGRect(x: 0, y: 0, width: width, height: footerRows)) // bottom-left origin: y 0 is the bottom
            return ctx.makeImage()!
        }
        let stitcher = ScrollStitcher()
        for top in [0, 100, 200, 300, 400] { _ = stitcher.add(frame(top: top)) }
        let out = try XCTUnwrap(stitcher.finish())
        // Content rows 0 ..< 400 + (frameHeight - footerRows) are visible above the footer in the last frame.
        XCTAssertEqual(out.height, 400 + frameHeight - footerRows)
        XCTAssertEqual(bytes(out), bytes(content.cropping(to: CGRect(x: 0, y: 0, width: width, height: out.height))!))
    }
}
