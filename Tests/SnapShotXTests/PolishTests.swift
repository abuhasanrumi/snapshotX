import CoreGraphics
import XCTest
@testable import SnapShotX

final class PolishTests: XCTestCase {
    func testAspectRectKeepsRatioAndStaysInside() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let r = Geometry.aspectRect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 350, y: 150), aspect: 1, within: bounds)
        XCTAssertEqual(r.width / r.height, 1, accuracy: 0.001)
        XCTAssertTrue(bounds.contains(r))
        let back = Geometry.aspectRect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 20, y: 40), aspect: 16.0 / 9, within: bounds)
        XCTAssertEqual(back.width / back.height, 16.0 / 9, accuracy: 0.001)
        XCTAssertEqual(back.maxX, 100, accuracy: 0.001)
        XCTAssertTrue(bounds.contains(back))
    }

    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CGImage {
        let ctx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        return ctx.makeImage()!
    }

    func testAutoBalanceFollowsImageHue() {
        let spec = AutoBalance.gradient(for: solid(30, 90, 220))
        XCTAssertEqual(spec.colors.count, 2)
        for c in spec.colors { XCTAssertGreaterThan(c.b, c.r, "a blue image should give blue-ish colors") }
    }

    func testAutoBalanceLeavesGrayNeutral() {
        let spec = AutoBalance.gradient(for: solid(128, 128, 128))
        for c in spec.colors { XCTAssertEqual(c.r, c.b, accuracy: 0.05) }
    }
}

@MainActor
final class NewActionShortcutTests: XCTestCase {
    func testSavedShortcutsGainTheNewActionDefaultOnce() throws {
        let defaults = UserDefaults(suiteName: "ssx-\(UUID().uuidString)")!
        var saved = ShortcutStore.defaultMap()
        saved[.fullPageCapture] = nil
        let data = try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: saved.map { ($0.key.rawValue, $0.value) }))
        defaults.set(data, forKey: "shortcuts.v1")
        _ = defaults
        let store = ShortcutStore(defaults: defaults)
        XCTAssertNotNil(store.shortcuts[.fullPageCapture], "a user with saved shortcuts should get ⌘⇧2")
        _ = store.set(nil, for: .fullPageCapture)
        let again = ShortcutStore(defaults: defaults)
        XCTAssertNil(again.shortcuts[.fullPageCapture], "clearing it must stick")
    }
}

final class WebAreaGeometryTests: XCTestCase {
    func testAccessibilityRectFlipsToAppKitCoordinates() {
        // A 400x300 area 100 points from the top-left of a 1000-point-tall primary screen.
        let flipped = WebAreaFinder.appKitRect(fromAccessibility: CGRect(x: 50, y: 100, width: 400, height: 300), primaryHeight: 1000)
        XCTAssertEqual(flipped, CGRect(x: 50, y: 600, width: 400, height: 300))
    }
}

@MainActor
final class QuickAccessExpiryTests: XCTestCase {
    private func make() -> (QuickAccessController, CaptureItem, URL) {
        let controller = QuickAccessController(prefs: Preferences(defaults: UserDefaults(suiteName: "qa-\(UUID().uuidString)")!), showsPanel: false)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let item = CaptureItem(id: UUID(), createdAt: Date(), kind: .screenshot, fileName: url.lastPathComponent, pixelWidth: 4, pixelHeight: 4)
        return (controller, item, url)
    }

    func testCardLeavesAfterCopyDelay() async throws {
        let (controller, item, url) = make()
        controller.copiedLifetime = 0.15
        controller.onCopy = { _ in true }
        controller.add(item: item, url: url)
        controller.copy(item.id)
        XCTAssertEqual(controller.entries.count, 1)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(controller.entries.isEmpty)
    }

    func testCardStaysWhenNothingWasCopied() async throws {
        let (controller, item, url) = make()
        controller.copiedLifetime = 0.1
        controller.add(item: item, url: url)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(controller.entries.count, 1)
    }

    func testAutoCopiedCaptureAlsoExpires() async throws {
        let (controller, item, url) = make()
        controller.copiedLifetime = 0.1
        controller.add(item: item, url: url, notice: "Copied")
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertTrue(controller.entries.isEmpty)
    }
}

final class PNGResolutionTests: XCTestCase {
    func testSavedPNGRecordsTheScreenDensity() throws {
        let ctx = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try ImageFile.writePNG(ctx.makeImage()!, to: url)
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        let dpi = try XCTUnwrap(props[kCGImagePropertyDPIWidth] as? Double)
        XCTAssertEqual(dpi, ImageFile.screenDPI, accuracy: 1)
        XCTAssertGreaterThanOrEqual(dpi, 72)
        let data = try XCTUnwrap(ImageFile.pngData(ctx.makeImage()!))
        let fromData = CGImageSourceCreateWithData(data as CFData, nil)!
        XCTAssertEqual((CGImageSourceCopyPropertiesAtIndex(fromData, 0, nil) as! [CFString: Any])[kCGImagePropertyDPIWidth] as? Double ?? 0, dpi, accuracy: 1)
    }
}

final class TextStyleTests: XCTestCase {
    private func base() -> CGImage {
        let ctx = CGContext(data: nil, width: 300, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 120))
        return ctx.makeImage()!
    }

    private func render(_ style: TextStyle, color: RGBAColor = RGBAColor(hex: 0x0A84FF)) -> [UInt8] {
        var state = EditorState()
        state.annotations = [Annotation(kind: .text(origin: CGPoint(x: 20, y: 30), string: "Hello"), color: color, lineWidth: 4, fontSize: 40, textStyle: style)]
        let image = Renderer.export(base: base(), state: state, cache: EffectCache())!
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = out.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                                         bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)! }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return out
    }

    func testEveryStyleDrawsSomethingDifferent() {
        let renders = TextStyle.allCases.map { render($0) }
        for (i, r) in renders.enumerated() {
            XCTAssertTrue(r.contains { $0 < 250 }, "\(TextStyle.allCases[i]) drew nothing")
        }
        XCTAssertNotEqual(render(.plain), render(.bold))
        XCTAssertNotEqual(render(.plain), render(.outline))
        XCTAssertNotEqual(render(.plain), render(.label))
        XCTAssertNotEqual(render(.plain), render(.mono))
    }

    func testLabelFillsABoxBehindTheText() {
        let pixels = render(.label)
        // The top-left padding corner of the box (a little inside the origin) should be the label color, not white.
        let p = ((30 + 3) * 300 + (20 + 6)) * 4
        XCTAssertLessThan(pixels[p], 100)      // red channel of 0A84FF is low
        XCTAssertGreaterThan(pixels[p + 2], 200)
    }

    func testLabelIsLargerThanPlain() {
        let plain = TextMetrics.size(of: "Hello", fontSize: 40, style: .plain)
        let label = TextMetrics.size(of: "Hello", fontSize: 40, style: .label)
        XCTAssertGreaterThan(label.width, plain.width)
        XCTAssertGreaterThan(label.height, plain.height)
    }

    func testOldAnnotationWithoutStyleDecodesAsPlain() throws {
        let a = Annotation(kind: .text(origin: .zero, string: "x"), color: .red, lineWidth: 2, fontSize: 20, textStyle: .label)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any]
        json.removeValue(forKey: "textStyle")
        let decoded = try JSONDecoder().decode(Annotation.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.textStyle, .plain)
        XCTAssertEqual(try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(a)).textStyle, .label)
    }
}

final class ImageCombinerTests: XCTestCase {
    private func solid(_ w: Int, _ h: Int, gray: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func gray(of image: CGImage, x: Int, y: Int) -> UInt8 {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return px[0]
    }

    func testStackedScalesToFirstWidthAndKeepsOrder() throws {
        let top = solid(100, 40, gray: 0), bottom = solid(200, 100, gray: 1)
        let out = try XCTUnwrap(ImageCombiner.combine([top, bottom], axis: .vertical))
        XCTAssertEqual(out.width, 100)
        XCTAssertEqual(out.height, 40 + 50) // the second image is halved to match the width
        XCTAssertEqual(gray(of: out, x: 50, y: 10), 0)
        XCTAssertEqual(gray(of: out, x: 50, y: 70), 255)
    }

    func testSideBySideScalesToFirstHeightAndKeepsOrder() throws {
        let left = solid(60, 50, gray: 1), right = solid(30, 100, gray: 0)
        let out = try XCTUnwrap(ImageCombiner.combine([left, right], axis: .horizontal))
        XCTAssertEqual(out.height, 50)
        XCTAssertEqual(out.width, 60 + 15)
        XCTAssertEqual(gray(of: out, x: 20, y: 25), 255)
        XCTAssertEqual(gray(of: out, x: 70, y: 25), 0)
    }

    func testSpacingIsAdded() throws {
        let out = try XCTUnwrap(ImageCombiner.combine([solid(10, 10, gray: 0), solid(10, 10, gray: 0), solid(10, 10, gray: 0)], axis: .vertical, spacing: 5))
        XCTAssertEqual(out.height, 40)
    }

    func testOneImageIsReturnedAsIs() throws {
        let image = solid(8, 8, gray: 0.5)
        XCTAssertTrue(ImageCombiner.combine([image], axis: .vertical) === image)
        XCTAssertNil(ImageCombiner.combine([], axis: .vertical))
    }
}
