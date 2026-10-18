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
