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
