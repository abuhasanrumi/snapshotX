import AVFoundation
import XCTest
@testable import SnapShotX

final class StudioExportTests: XCTestCase {
    private func movie(seconds: Double = 2) async throws -> URL {
        let url = SyntheticMedia.tempURL("studio-src")
        try await SyntheticMedia.makeMovie(at: url, seconds: seconds, width: 160, height: 90)
        return url
    }

    private func export(_ project: StudioProject, cursor: CursorTrack? = nil, seconds: Double = 2) async throws -> URL {
        let src = try await movie(seconds: seconds)
        let out = SyntheticMedia.tempURL("studio-out")
        try await StudioExporter.export(asset: AVURLAsset(url: src), project: project, cursor: cursor, to: out, format: .mp4) { _ in }
        return out
    }

    private func frame(of url: URL, at t: Double) async throws -> CGImage {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        return try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    func testTrimShortensVideo() async throws {
        var project = StudioProject()
        project.trimStart = 0.5
        project.trimEnd = 1.5
        let out = try await export(project)
        let d = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(d, 1.0, accuracy: 0.25)
    }

    func testOriginalSizeWithoutBackground() async throws {
        let out = try await export(StudioProject())
        let track = try await AVURLAsset(url: out).loadTracks(withMediaType: .video)[0]
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 160)
        XCTAssertEqual(size.height, 90)
    }

    func testBackgroundAddsPaddingAndCenterShowsVideo() async throws {
        var project = StudioProject()
        project.background.enabled = true
        project.background.fill = .solid(RGBAColor(r: 1, g: 0, b: 0, a: 1))
        project.background.shadow = 0
        let out = try await export(project)
        let img = try await frame(of: out, at: 0.3)
        XCTAssertGreaterThan(img.width, 160)
        let corner = pixel(img, 2, 2)
        XCTAssertGreaterThan(corner.r, 180)
        XCTAssertLessThan(corner.g, 80)
        let center = pixel(img, img.width / 2, img.height / 2)
        XCTAssertFalse(center.r > 180 && center.g < 80 && center.b < 80, "center should be the recording, not the background")
    }

    func testCropChangesOutputSizeAndShowsOnlyRegion() async throws {
        var project = StudioProject()
        project.crop = ZoomCamera.Crop(x: 0.5, y: 0, width: 0.5, height: 1)
        let out = try await export(project)
        let track = try await AVURLAsset(url: out).loadTracks(withMediaType: .video)[0]
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 80)
        XCTAssertEqual(size.height, 90)
        // The source's green channel rises left to right, so the kept right half starts bright.
        let img = try await frame(of: out, at: 0.3)
        XCTAssertGreaterThan(pixel(img, 1, 45).g, 100)
    }

    func testZoomMagnifiesCenter() async throws {
        var project = StudioProject()
        project.zooms = [ZoomSegment(start: 0, end: 2, scale: 2, focus: .point(x: 0.5, y: 0.5))]
        let out = try await export(project)
        let plain = try await export(StudioProject())
        let zoomed = try await frame(of: out, at: 1.0)
        let normal = try await frame(of: plain, at: 1.0)
        // The synthetic image is a horizontal red gradient in x; zoomed, the left edge is brighter in green than the unzoomed edge.
        XCTAssertGreaterThan(pixel(zoomed, 1, 45).g, pixel(normal, 1, 45).g + 20)
    }
}

@MainActor
final class StudioCropModelTests: XCTestCase {
    func testZoomStaysInsideCropRegion() {
        let region = ZoomCamera.Crop(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let zoom = ZoomSegment(start: 0, end: 4, scale: 3, focus: .point(x: 0.99, y: 0.99))
        let crop = ZoomCamera.crop(at: 2, zooms: [zoom], cursor: nil, smoothing: 0.5, region: region)
        XCTAssertGreaterThanOrEqual(crop.x, 0.25 - 1e-9)
        XCTAssertLessThanOrEqual(crop.x + crop.width, 0.75 + 1e-9)
        XCTAssertLessThanOrEqual(crop.y + crop.height, 0.75 + 1e-9)
        XCTAssertLessThan(crop.width, 0.5)
    }

    func testNoZoomShowsWholeRegion() {
        let region = ZoomCamera.Crop(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
        let crop = ZoomCamera.crop(at: 0, zooms: [], cursor: nil, smoothing: 0, region: region)
        XCTAssertEqual(crop, region)
    }

    func testAspectSnapFitsAndKeepsRatio() {
        let crop = StudioCropEditor.crop(aspect: 1, imageAspect: 16.0 / 9, around: .full)
        XCTAssertEqual(crop.width * 16.0 / 9 / crop.height / 1, 1, accuracy: 0.01)
        XCTAssertEqual(crop.height, 1, accuracy: 1e-9)
    }
}

@MainActor
final class StudioRecordingTests: XCTestCase {
    func testOptionsDecodeWithoutStudioKey() throws {
        let json = #"{"format":"mp4","fps":30}"#.data(using: .utf8)!
        let options = try JSONDecoder().decode(RecordingOptions.self, from: json)
        XCTAssertFalse(options.studioMode)
        XCTAssertEqual(options.fps, 30)
        XCTAssertTrue(options.highlightClicks)
    }

    func testHistoryWritesAndRemovesSidecar() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        let store = HistoryStore(directory: dir)
        let video = dir.appendingPathComponent("src.mp4")
        try Data([0]).write(to: video)
        let track = CursorTrack(samples: [.init(t: 0, x: 0.5, y: 0.5)], clicks: [])
        let item = try store.addRecording(RecordingOutput(url: video, duration: 1, pixelSize: CGSize(width: 10, height: 10), format: .mp4, cursor: track))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.cursorURL(for: item).path))
        store.remove(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.cursorURL(for: item).path))
    }
}

final class PauseTests: XCTestCase {
    func testPausedSpanIsCutOut() async throws {
        let url = SyntheticMedia.tempURL("paused")
        let base = SyntheticMedia.baseTime
        let writer = try RecordingWriter(url: url, width: 160, height: 90, fps: 10, systemAudio: true, microphone: false)
        let tone = SyntheticMedia.Tone(frequency: 440, amplitude: 0.5, channels: 2)
        func at(_ s: Double) -> CMTime { base + CMTime(seconds: s, preferredTimescale: 600) }
        for frame in 0..<10 { writer.appendVideo(SyntheticMedia.videoSample(frame: frame, fps: 10, width: 160, height: 90)); try await Task.sleep(nanoseconds: 5_000_000) }
        writer.pause(at: at(1))
        for frame in 10..<20 { writer.appendVideo(SyntheticMedia.videoSample(frame: frame, fps: 10, width: 160, height: 90)); try await Task.sleep(nanoseconds: 5_000_000) }
        writer.resume(at: at(2))
        for frame in 20..<30 { writer.appendVideo(SyntheticMedia.videoSample(frame: frame, fps: 10, width: 160, height: 90)); try await Task.sleep(nanoseconds: 5_000_000) }
        for chunk in 0..<Int(3 * 48_000 / 1024) {
            writer.appendSystemAudio(SyntheticMedia.audioSample(tone: tone, offsetFrames: chunk * 1024))
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let summary = try await writer.finish(at: at(3))
        XCTAssertEqual(summary.duration, 2.0, accuracy: 0.15)
        XCTAssertEqual(summary.pauses.count, 1)
        let asset = AVURLAsset(url: url)
        let d = try await asset.load(.duration).seconds
        XCTAssertEqual(d, 2.0, accuracy: 0.2)
    }

    func testCursorSpansRemoved() {
        var track = CursorTrack()
        for i in 0..<40 { track.samples.append(.init(t: Double(i) * 0.1, x: 0.1, y: 0.1)) }
        track.clicks = [.init(t: 1.5, x: 0, y: 0, button: 0), .init(t: 3.5, x: 0, y: 0, button: 0)]
        let cut = track.removing([(start: 1, end: 3)])
        XCTAssertEqual(cut.clicks.count, 1)
        XCTAssertEqual(cut.clicks[0].t, 1.5, accuracy: 1e-9)
        XCTAssertEqual(cut.samples.last!.t, 1.9, accuracy: 1e-9)
    }
}
