import XCTest
@testable import SnapShotX

final class BackgroundLayoutTests: XCTestCase {
    private func style(padding: Double = 0.1, aspect: BackgroundAspect = .auto, alignment: BackgroundAlignment = .center) -> BackgroundStyle {
        var s = BackgroundStyle()
        s.enabled = true
        s.padding = padding
        s.aspect = aspect
        s.alignment = alignment
        return s
    }

    func testPaddingIsAFractionOfTheShorterSide() {
        let layout = BackgroundLayout.compute(contentSize: CGSize(width: 400, height: 200), style: style(padding: 0.1))
        XCTAssertEqual(layout.canvas, CGSize(width: 440, height: 240))
        XCTAssertEqual(layout.content, CGRect(x: 20, y: 20, width: 400, height: 200))
    }

    func testWideAspectRatioAddsHorizontalSpaceAndCentersContent() {
        let layout = BackgroundLayout.compute(contentSize: CGSize(width: 300, height: 300), style: style(padding: 0, aspect: .sixteenNine))
        XCTAssertEqual(layout.canvas.height, 300)
        XCTAssertEqual(layout.canvas.width, (300 * 16.0 / 9).rounded())
        XCTAssertEqual(layout.content.midX, layout.canvas.width / 2, accuracy: 1)
    }

    func testTallAspectRatioAddsVerticalSpace() {
        let layout = BackgroundLayout.compute(contentSize: CGSize(width: 300, height: 300), style: style(padding: 0, aspect: .nineSixteen))
        XCTAssertEqual(layout.canvas.width, 300)
        XCTAssertEqual(layout.canvas.height, (300 * 16.0 / 9).rounded())
    }

    func testAspectRatioNeverShrinksBelowTheContentPlusPadding() {
        let layout = BackgroundLayout.compute(contentSize: CGSize(width: 800, height: 200), style: style(padding: 0.1, aspect: .square))
        XCTAssertGreaterThanOrEqual(layout.canvas.width, 800 + 40)
        XCTAssertGreaterThanOrEqual(layout.canvas.height, 200 + 40)
        XCTAssertEqual(layout.canvas.width, layout.canvas.height, accuracy: 1)
    }

    func testAlignmentPinsContentToTheChosenCornerKeepingPadding() {
        let topLeft = BackgroundLayout.compute(contentSize: CGSize(width: 300, height: 300), style: style(padding: 0.1, aspect: .sixteenNine, alignment: .topLeft))
        XCTAssertEqual(topLeft.content.minX, 30)
        XCTAssertEqual(topLeft.content.minY, 30)

        let bottomRight = BackgroundLayout.compute(contentSize: CGSize(width: 300, height: 300), style: style(padding: 0.1, aspect: .sixteenNine, alignment: .bottomRight))
        XCTAssertEqual(bottomRight.content.maxX, bottomRight.canvas.width - 30)
        XCTAssertEqual(bottomRight.content.maxY, bottomRight.canvas.height - 30)
    }

    func testContentAlwaysFitsInsideTheCanvas() {
        for aspect in BackgroundAspect.allCases {
            for alignment in BackgroundAlignment.allCases {
                let layout = BackgroundLayout.compute(contentSize: CGSize(width: 640, height: 360), style: style(padding: 0.15, aspect: aspect, alignment: alignment))
                let canvas = CGRect(origin: .zero, size: layout.canvas)
                XCTAssertTrue(canvas.contains(layout.content), "\(aspect) \(alignment)")
            }
        }
    }

    func testCatalogHasTwentyGradients() {
        XCTAssertEqual(BackgroundCatalog.gradients.count, 20)
        XCTAssertEqual(Set(BackgroundCatalog.gradients.map(\.name)).count, 20)
    }

    func testPresetsPersistAndEnableTheBackground() {
        let suite = "snapshotx.presets.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let store = BackgroundPresetStore(defaults: defaults)
        var custom = BackgroundStyle()
        custom.padding = 0.3
        store.add(name: "  Wide  ", style: custom)
        store.add(name: "   ", style: custom)

        let reloaded = BackgroundPresetStore(defaults: defaults)
        XCTAssertEqual(reloaded.items.map(\.name), ["Wide"])
        XCTAssertEqual(reloaded.items.first?.style.padding, 0.3)
        XCTAssertEqual(reloaded.items.first?.style.enabled, true)

        reloaded.remove(reloaded.items[0])
        XCTAssertTrue(BackgroundPresetStore(defaults: defaults).items.isEmpty)
    }
}
