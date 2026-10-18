import XCTest
@testable import SnapShotX

final class CursorTrackTests: XCTestCase {
    /// A pointer drifting along y = 0.5 from x = 0 to x = 1 over 10 seconds, sampled at 60 Hz, with alternating jitter.
    private func jitteryTrack(noise: Double = 0.02) -> CursorTrack {
        var track = CursorTrack()
        for i in 0...600 {
            let t = Double(i) / 60
            let wobble = i % 2 == 0 ? noise : -noise
            track.samples.append(.init(t: t, x: t / 10 + wobble, y: 0.5 - wobble))
        }
        return track
    }

    func testNormalizingFlipsToATopLeftOrigin() {
        let region = CGRect(x: 100, y: 200, width: 400, height: 300)
        XCTAssertEqual(CursorTrack.normalize(CGPoint(x: 300, y: 350), in: region), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(CursorTrack.normalize(CGPoint(x: 100, y: 200), in: region), CGPoint(x: 0, y: 1)) // bottom-left
        XCTAssertEqual(CursorTrack.normalize(CGPoint(x: 500, y: 500), in: region), CGPoint(x: 1, y: 0)) // top-right
        XCTAssertEqual(CursorTrack.normalize(CGPoint(x: 0, y: 0), in: region).x, -0.25, "outside the region is allowed")
    }

    func testRebasingShiftsTimesAndDropsWhatCameBeforeZero() {
        var track = CursorTrack()
        track.samples = [.init(t: 1, x: 0, y: 0), .init(t: 2, x: 1, y: 1), .init(t: 3, x: 2, y: 2)]
        track.clicks = [.init(t: 1.5, x: 0, y: 0, button: 0), .init(t: 2.5, x: 0, y: 0, button: 0)]
        let rebased = track.rebased(by: 2)
        XCTAssertEqual(rebased.samples.map(\.t), [0, 1])
        XCTAssertEqual(rebased.clicks.map(\.t), [0.5])
    }

    func testNoSamplesMeansNoPosition() {
        XCTAssertNil(CursorTrack().position(at: 1, smoothing: 0.5))
    }

    func testASingleSampleIsAlwaysWhereTheCursorIs() {
        var track = CursorTrack()
        track.samples = [.init(t: 0, x: 0.3, y: 0.7)]
        XCTAssertEqual(track.position(at: 5, smoothing: 0.5), CGPoint(x: 0.3, y: 0.7))
    }

    func testWithoutSmoothingThePathIsJoinedByStraightLines() throws {
        var track = CursorTrack()
        track.samples = [.init(t: 0, x: 0, y: 0), .init(t: 2, x: 1, y: 0.5)]
        let mid = try XCTUnwrap(track.position(at: 1, smoothing: 0))
        XCTAssertEqual(mid.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(mid.y, 0.25, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(track.position(at: -3, smoothing: 0)), CGPoint(x: 0, y: 0), "held before the start")
        XCTAssertEqual(try XCTUnwrap(track.position(at: 9, smoothing: 0)), CGPoint(x: 1, y: 0.5), "held after the end")
    }

    func testSmoothingRemovesJitter() throws {
        let track = jitteryTrack()
        var rawError = 0.0, smoothError = 0.0
        for i in stride(from: 60, to: 540, by: 7) {
            let t = Double(i) / 60
            let truth = CGPoint(x: t / 10, y: 0.5)
            let raw = try XCTUnwrap(track.position(at: t, smoothing: 0))
            let smooth = try XCTUnwrap(track.position(at: t, smoothing: 0.5))
            rawError += abs(raw.x - truth.x) + abs(raw.y - truth.y)
            smoothError += abs(smooth.x - truth.x) + abs(smooth.y - truth.y)
        }
        XCTAssertLessThan(smoothError, rawError / 5, "the smoothed path hugs the true path far more closely")
    }

    func testMoreSmoothingIsSmootherStill() throws {
        let track = jitteryTrack()
        func roughness(_ amount: Double) throws -> Double {
            var total = 0.0
            var previous = try XCTUnwrap(track.position(at: 1, smoothing: amount))
            for i in 61...300 {
                let p = try XCTUnwrap(track.position(at: Double(i) / 60, smoothing: amount))
                total += abs(p.x - previous.x) + abs(p.y - previous.y)
                previous = p
            }
            return total
        }
        XCTAssertLessThan(try roughness(0.5), try roughness(0.1))
    }

    func testSmoothingKeepsTheEndPointsWhereTheyWere() throws {
        let track = jitteryTrack()
        XCTAssertEqual(try XCTUnwrap(track.position(at: 0, smoothing: 1)), CGPoint(x: track.samples[0].x, y: track.samples[0].y))
        let last = try XCTUnwrap(track.samples.last)
        XCTAssertEqual(try XCTUnwrap(track.position(at: last.t + 3, smoothing: 1)), CGPoint(x: last.x, y: last.y))
    }

    func testSmoothingNeverLeavesTheRecordedArea() throws {
        let track = jitteryTrack(noise: 0.3)
        let xs = track.samples.map(\.x), ys = track.samples.map(\.y)
        for i in stride(from: 0, through: 600, by: 13) {
            let p = try XCTUnwrap(track.position(at: Double(i) / 60, smoothing: 0.9))
            XCTAssertTrue(p.x >= xs.min()! - 1e-9 && p.x <= xs.max()! + 1e-9)
            XCTAssertTrue(p.y >= ys.min()! - 1e-9 && p.y <= ys.max()! + 1e-9)
        }
    }

    func testTrackSurvivesJSON() throws {
        var track = jitteryTrack()
        track.clicks = [.init(t: 1, x: 0.2, y: 0.3, button: 1)]
        track.pixelsPerPoint = 3
        XCTAssertEqual(try JSONDecoder().decode(CursorTrack.self, from: JSONEncoder().encode(track)), track)
    }
}

final class SmartZoomTests: XCTestCase {
    private func click(_ t: Double) -> CursorTrack.Click { .init(t: t, x: 0.5, y: 0.5, button: 0) }

    func testNoClicksMeansNoZooms() {
        XCTAssertTrue(SmartZoom.generate(from: [], duration: 20).isEmpty)
    }

    func testAZoomStartsBeforeTheClickAndLingersAfter() throws {
        let zooms = SmartZoom.generate(from: [click(5)], duration: 20)
        let zoom = try XCTUnwrap(zooms.first)
        XCTAssertEqual(zooms.count, 1)
        XCTAssertEqual(zoom.start, 4.4, accuracy: 1e-9)
        XCTAssertEqual(zoom.end, 6.4, accuracy: 1e-9)
        XCTAssertEqual(zoom.scale, 2)
        XCTAssertEqual(zoom.focus, .cursor)
    }

    func testClicksCloseTogetherShareOneZoom() throws {
        let zooms = SmartZoom.generate(from: [click(5), click(5.8), click(6.5)], duration: 20)
        XCTAssertEqual(zooms.count, 1)
        XCTAssertEqual(try XCTUnwrap(zooms.first).start, 4.4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(zooms.first).end, 7.9, accuracy: 1e-9)
    }

    func testClicksFarApartGetTheirOwnZooms() {
        let zooms = SmartZoom.generate(from: [click(3), click(10)], duration: 20)
        XCTAssertEqual(zooms.count, 2)
        XCTAssertLessThan(zooms[0].end, zooms[1].start)
    }

    func testOverlappingZoomsAreMerged() throws {
        let zooms = SmartZoom.generate(from: [click(5), click(5.8)], duration: 20, leadIn: 1, linkGap: 0.5)
        XCTAssertEqual(zooms.count, 1, "the second zoom would start inside the first")
        XCTAssertEqual(try XCTUnwrap(zooms.first).start, 4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(zooms.first).end, 7.2, accuracy: 1e-9)
    }

    func testZoomsStayInsideTheVideoAndKeepTheirMinimumLength() throws {
        let early = try XCTUnwrap(SmartZoom.generate(from: [click(0.2)], duration: 20).first)
        XCTAssertEqual(early.start, 0)
        XCTAssertGreaterThanOrEqual(early.duration, 2 - 1e-9)

        let late = try XCTUnwrap(SmartZoom.generate(from: [click(19.8)], duration: 20).first)
        XCTAssertEqual(late.end, 20)
        XCTAssertGreaterThanOrEqual(late.duration, 2 - 1e-9)
    }

    func testClicksOutsideTheVideoAreIgnored() {
        XCTAssertTrue(SmartZoom.generate(from: [click(-1), click(25)], duration: 20).isEmpty)
    }

    func testTheRequestedScaleIsUsed() throws {
        XCTAssertEqual(try XCTUnwrap(SmartZoom.generate(from: [click(5)], duration: 20, scale: 3).first).scale, 3)
    }
}

final class ZoomCameraTests: XCTestCase {
    private func zoom(_ start: Double, _ end: Double, scale: Double = 2, focus: ZoomFocus = .point(x: 0.5, y: 0.5)) -> ZoomSegment {
        ZoomSegment(start: start, end: end, scale: scale, focus: focus)
    }

    private func crop(_ t: Double, _ zooms: [ZoomSegment], cursor: CursorTrack? = nil) -> ZoomCamera.Crop {
        ZoomCamera.crop(at: t, zooms: zooms, cursor: cursor, smoothing: 0)
    }

    func testWithoutZoomsTheWholeVideoShows() {
        XCTAssertEqual(crop(3, []), .full)
        XCTAssertEqual(crop(100, [zoom(1, 2)]), .full, "outside every zoom")
    }

    func testZoomsEaseInHoldAndEaseOut() {
        let segment = zoom(2, 8)
        XCTAssertEqual(ZoomCamera.weight(of: segment, at: 2), 0, accuracy: 1e-9)
        XCTAssertEqual(ZoomCamera.weight(of: segment, at: 5), 1, accuracy: 1e-9)
        XCTAssertEqual(ZoomCamera.weight(of: segment, at: 8), 0, accuracy: 1e-9)
        XCTAssertEqual(ZoomCamera.weight(of: segment, at: 2 + ZoomCamera.ramp / 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ZoomCamera.weight(of: segment, at: 8 - ZoomCamera.ramp / 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ZoomCamera.weight(of: segment, at: 99), 0)
    }

    func testAFullZoomShowsTheScaledMiddle() {
        let c = crop(5, [zoom(2, 8, scale: 2)])
        XCTAssertEqual(c.width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.height, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0.25, accuracy: 1e-9)
    }

    func testHalfwayThroughTheRampTheZoomIsHalfwayThere() {
        let c = crop(2 + ZoomCamera.ramp / 2, [zoom(2, 8, scale: 3)])
        XCTAssertEqual(c.width, 1 / (1 + 0.5 * 2), accuracy: 1e-9)
    }

    func testAFocusInACornerIsClampedInsideTheVideo() {
        let c = crop(5, [zoom(2, 8, scale: 4, focus: .point(x: 0, y: 0))])
        XCTAssertEqual(c.x, 0, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0, accuracy: 1e-9)
        let far = crop(5, [zoom(2, 8, scale: 4, focus: .point(x: 1, y: 1))])
        XCTAssertEqual(far.x + far.width, 1, accuracy: 1e-9)
        XCTAssertEqual(far.y + far.height, 1, accuracy: 1e-9)
    }

    func testAFixedFocusIsCenteredOnceFullyZoomed() {
        let c = crop(5, [zoom(2, 8, scale: 2, focus: .point(x: 0.6, y: 0.4))])
        XCTAssertEqual(c.x + c.width / 2, 0.6, accuracy: 1e-9)
        XCTAssertEqual(c.y + c.height / 2, 0.4, accuracy: 1e-9)
    }

    func testTheCameraFollowsTheCursor() {
        var track = CursorTrack()
        for i in 0...100 { track.samples.append(.init(t: Double(i) / 10, x: 0.3 + Double(i) / 400, y: 0.5)) } // 0.3 to 0.55
        let segment = zoom(2, 8, scale: 2, focus: .cursor)
        let early = crop(3, [segment], cursor: track)
        let late = crop(7, [segment], cursor: track)
        XCTAssertLessThan(early.x, late.x, "the camera moved right with the pointer")
        XCTAssertEqual(late.x + late.width / 2, track.position(at: 7, smoothing: 0)!.x, accuracy: 1e-6)
    }

    func testFollowingTheCursorWithNoCursorDataStaysCentered() {
        let c = crop(5, [zoom(2, 8, scale: 2, focus: .cursor)], cursor: nil)
        XCTAssertEqual(c.x + c.width / 2, 0.5, accuracy: 1e-9)
    }

    func testOverlappingZoomsUseTheStrongerOne() {
        let c = crop(5, [zoom(2, 8, scale: 2), zoom(3, 9, scale: 4)])
        XCTAssertEqual(c.width, 0.25, accuracy: 1e-9)
    }

    func testAScaleBelowOneNeverShrinksTheView() {
        XCTAssertEqual(crop(5, [zoom(2, 8, scale: 0.5)]), .full)
    }

    func testTheCropNeverLeavesTheVideoWhateverTheFocus() {
        for scale in [1.2, 2, 4] {
            for fx in [0.0, 0.3, 0.5, 1.0] {
                for t in stride(from: 0.0, through: 10, by: 0.37) {
                    let c = crop(t, [zoom(1, 9, scale: scale, focus: .point(x: fx, y: 1 - fx))])
                    XCTAssertGreaterThanOrEqual(c.x, -1e-9)
                    XCTAssertGreaterThanOrEqual(c.y, -1e-9)
                    XCTAssertLessThanOrEqual(c.x + c.width, 1 + 1e-9)
                    XCTAssertLessThanOrEqual(c.y + c.height, 1 + 1e-9)
                }
            }
        }
    }
}

final class StudioProjectTests: XCTestCase {
    func testTrimIsClampedInsideTheVideo() {
        var project = StudioProject()
        XCTAssertEqual(project.trimRange(duration: 10).start, 0)
        XCTAssertEqual(project.trimRange(duration: 10).end, 10)

        project.trimStart = -3
        project.trimEnd = 99
        XCTAssertEqual(project.trimRange(duration: 10).start, 0)
        XCTAssertEqual(project.trimRange(duration: 10).end, 10)

        project.trimStart = 4
        project.trimEnd = 4.01 // shorter than a tenth of a second
        let range = project.trimRange(duration: 10)
        XCTAssertEqual(range.end - range.start, 0.1, accuracy: 1e-9)

        project.trimStart = 10
        project.trimEnd = 10
        XCTAssertLessThan(project.trimRange(duration: 10).start, 10, "a trim can't start at the very end")
    }

    func testProjectsSurviveJSONAndPartialFilesGetDefaults() throws {
        var project = StudioProject()
        project.trimStart = 1.5
        project.trimEnd = 8
        project.zooms = [ZoomSegment(start: 2, end: 5, scale: 3, focus: .point(x: 0.2, y: 0.8))]
        project.cursor.size = 2
        project.background.enabled = true
        project.preset = .p720
        XCTAssertEqual(try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(project)), project)

        let fromNothing = try JSONDecoder().decode(StudioProject.self, from: Data("{}".utf8))
        XCTAssertEqual(fromNothing, StudioProject())
        let partial = try JSONDecoder().decode(StudioProject.self, from: Data(#"{"trimStart": 2}"#.utf8))
        XCTAssertEqual(partial.trimStart, 2)
        XCTAssertTrue(partial.cursor.visible)
    }
}

final class StudioLayoutTests: XCTestCase {
    private let source = CGSize(width: 1600, height: 900)

    func testWithoutABackgroundTheOutputIsTheRecording() {
        let layout = StudioLayout.make(sourceSize: source, background: BackgroundStyle(), preset: .original)
        XCTAssertEqual(layout.renderSize, source)
        XCTAssertEqual(layout.contentRect, CGRect(origin: .zero, size: source))
        XCTAssertFalse(layout.hasBackground)
        XCTAssertEqual(layout.cornerRadius, 0)
    }

    func testABackgroundAddsPaddingAroundTheRecording() {
        var style = BackgroundStyle()
        style.enabled = true
        style.padding = 0.1
        let layout = StudioLayout.make(sourceSize: source, background: style, preset: .original)
        XCTAssertEqual(layout.renderSize, CGSize(width: 1780, height: 1080)) // 1600 + 2 * 90, 900 + 2 * 90
        XCTAssertEqual(layout.contentRect, CGRect(x: 90, y: 90, width: 1600, height: 900))
        XCTAssertTrue(layout.hasBackground)
    }

    func testAnAspectRatioReshapesTheCanvasAndKeepsTheRecordingInside() {
        var style = BackgroundStyle()
        style.enabled = true
        style.padding = 0.08
        for aspect in BackgroundAspect.allCases {
            style.aspect = aspect
            let layout = StudioLayout.make(sourceSize: source, background: style, preset: .original)
            XCTAssertTrue(CGRect(origin: .zero, size: layout.renderSize).contains(layout.contentRect), "\(aspect)")
            if let ratio = aspect.ratio {
                XCTAssertEqual(layout.renderSize.width / layout.renderSize.height, CGFloat(ratio), accuracy: 0.01, "\(aspect)")
            }
        }
    }

    func testPresetsCapTheLongEdgeAndKeepTheShape() {
        var style = BackgroundStyle()
        style.enabled = true
        let big = StudioLayout.make(sourceSize: CGSize(width: 3200, height: 1800), background: style, preset: .p720)
        XCTAssertEqual(max(big.renderSize.width, big.renderSize.height), 1280, accuracy: 2)
        let original = StudioLayout.make(sourceSize: CGSize(width: 3200, height: 1800), background: style, preset: .original)
        XCTAssertEqual(big.renderSize.width / big.renderSize.height, original.renderSize.width / original.renderSize.height, accuracy: 0.01)

        let small = StudioLayout.make(sourceSize: CGSize(width: 800, height: 450), background: BackgroundStyle(), preset: .p1080)
        XCTAssertEqual(small.renderSize, CGSize(width: 800, height: 450), "presets never scale up")
    }

    func testOutputSizesAreAlwaysEven() {
        var style = BackgroundStyle()
        style.enabled = true
        for width in [1001, 1333, 1599] {
            for preset in StudioExportPreset.allCases {
                let layout = StudioLayout.make(sourceSize: CGSize(width: width, height: 777), background: style, preset: preset)
                XCTAssertEqual(Int(layout.renderSize.width) % 2, 0)
                XCTAssertEqual(Int(layout.renderSize.height) % 2, 0)
            }
        }
    }

    func testCornerRadiusScalesWithTheOutput() {
        var style = BackgroundStyle()
        style.enabled = true
        style.cornerRadius = 0.05
        let full = StudioLayout.make(sourceSize: source, background: style, preset: .original)
        let half = StudioLayout.make(sourceSize: CGSize(width: 3200, height: 1800), background: style, preset: .p720)
        XCTAssertGreaterThan(full.cornerRadius, 0)
        XCTAssertLessThan(half.cornerRadius, 0.05 * 1800, "scaled down along with the video")
    }
}
