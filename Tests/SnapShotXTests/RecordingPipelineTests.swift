import AVFoundation
import ImageIO
import XCTest
@testable import SnapShotX

final class RecordingPipelineTests: XCTestCase {
    private var created: [URL] = []

    override func tearDown() {
        for url in created { try? FileManager.default.removeItem(at: url) }
        created = []
    }

    private func temp(_ name: String, ext: String = "mp4") -> URL {
        let url = SyntheticMedia.tempURL(name, ext: ext)
        created.append(url)
        return url
    }

    // MARK: Sizing

    func testPixelSizesAreEvenAndScaleWithTheDisplay() {
        XCTAssertEqual(RecordingGeometry.pixelSize(points: CGSize(width: 801, height: 601), scale: 2), CGSize(width: 1602, height: 1202))
        XCTAssertEqual(RecordingGeometry.pixelSize(points: CGSize(width: 333.3, height: 201), scale: 1), CGSize(width: 332, height: 200))
        XCTAssertEqual(RecordingGeometry.pixelSize(points: CGSize(width: 0.2, height: 0.2), scale: 1), CGSize(width: 2, height: 2))
    }

    func testBitrateIsClamped() {
        XCTAssertEqual(RecordingGeometry.bitrate(width: 100, height: 100, fps: 15), 2_000_000)
        XCTAssertEqual(RecordingGeometry.bitrate(width: 7680, height: 4320, fps: 60), 40_000_000)
        let typical = RecordingGeometry.bitrate(width: 2880, height: 1800, fps: 30)
        XCTAssertGreaterThan(typical, 2_000_000)
        XCTAssertLessThan(typical, 40_000_000)
    }

    func testOptionsSurviveJSONAndDecodeFromPartialData() throws {
        var options = RecordingOptions()
        options.format = .gif
        options.microphone = true
        options.cameraShape = .roundedSquare
        let decoded = try JSONDecoder().decode(RecordingOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(decoded, options)
    }

    // MARK: Writer

    func testWriterProducesOneVideoTrackAndTheRequestedAudioTracks() async throws {
        let url = temp("both")
        try await SyntheticMedia.makeMovie(at: url, seconds: 1.5,
                                           system: .init(frequency: 440, amplitude: 0.4, channels: 2),
                                           mic: .init(frequency: 880, amplitude: 0.4))
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 2)
        let size = try await video[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 160, height: 90))
    }

    func testVideoOnlyRecordingHasNoAudioTrack() async throws {
        let url = temp("silent")
        try await SyntheticMedia.makeMovie(at: url, seconds: 1)
        let audio = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)
    }

    func testDurationMatchesTheRecordingNotJustTheLastFrame() async throws {
        // Frames stop after 0.5 s (a static screen sends none), but the recording runs 2 s.
        let url = temp("hold")
        try await SyntheticMedia.makeMovie(at: url, seconds: 2, videoSeconds: 0.5)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.25)
    }

    func testFinishingWithoutAnyFrameFails() async throws {
        let writer = try RecordingWriter(url: temp("empty"), width: 160, height: 90, fps: 10, systemAudio: false, microphone: false)
        do {
            _ = try await writer.finish(at: SyntheticMedia.baseTime)
            XCTFail("finishing an empty recording should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no video frames"))
        }
    }

    func testAudioFromBeforeTheFirstFrameIsDropped() async throws {
        let url = temp("early")
        let writer = try RecordingWriter(url: url, width: 160, height: 90, fps: 10, systemAudio: true, microphone: false)
        // One second of audio that predates the video, then video and more audio.
        var early = SyntheticMedia.audioSample(tone: .init(frequency: 440, amplitude: 0.4, channels: 2), offsetFrames: 0)
        for chunk in 0..<10 {
            early = SyntheticMedia.audioSample(tone: .init(frequency: 440, amplitude: 0.4, channels: 2), offsetFrames: chunk * 1024)
            writer.appendSystemAudio(early) // no session yet: all of these must be ignored
        }
        for frame in 0..<10 {
            writer.appendVideo(SyntheticMedia.videoSample(frame: frame, fps: 10, width: 160, height: 90))
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let stop = SyntheticMedia.baseTime + CMTime(seconds: 1, preferredTimescale: 600)
        let summary = try await writer.finish(at: stop)
        XCTAssertEqual(summary.duration, 1, accuracy: 0.01)
        XCTAssertEqual(summary.videoFrames, 10)
    }

    // MARK: Mixing

    func testMixingTwoAudioTracksLeavesOneTrackAndAllVideo() async throws {
        let source = temp("mix-in")
        let mixed = temp("mix-out")
        try await SyntheticMedia.makeMovie(at: source, seconds: 2,
                                           system: .init(frequency: 440, amplitude: 0.4, channels: 2),
                                           mic: .init(frequency: 880, amplitude: 0.4))
        let before = await AudioMixer.audioTrackCount(in: source)
        XCTAssertEqual(before, 2)

        try await AudioMixer.mixAudioTracks(in: source, to: mixed)

        let asset = AVURLAsset(url: mixed)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(audio.count, 1)
        XCTAssertEqual(video.count, 1)
        let originalDuration = try await AVURLAsset(url: source).load(.duration).seconds
        let mixedDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(mixedDuration, originalDuration, accuracy: 0.2)
    }

    func testMixedAudioContainsBothSources() async throws {
        let source = temp("level-in")
        let mixed = temp("level-out")
        try await SyntheticMedia.makeMovie(at: source, seconds: 2,
                                           system: .init(frequency: 440, amplitude: 0.4, channels: 2),
                                           mic: .init(frequency: 880, amplitude: 0.4))
        try await AudioMixer.mixAudioTracks(in: source, to: mixed)

        // Each 0.4-amplitude sine is turned down to 0.32 amplitude, and two unrelated sines add in power:
        // RMS = sqrt(2 * (0.32 / sqrt(2))^2) = 0.32. One source alone would be about 0.23.
        let rms = try await SyntheticMedia.audioRMS(of: mixed)
        XCTAssertGreaterThan(rms, 0.27, "both sources should be audible")
        XCTAssertLessThan(rms, 0.40)
    }

    func testMixingSingleTrackFilesJustCopiesThem() async throws {
        let source = temp("single-in")
        let output = temp("single-out")
        try await SyntheticMedia.makeMovie(at: source, seconds: 1, system: .init(frequency: 440, amplitude: 0.4, channels: 2))
        try await AudioMixer.mixAudioTracks(in: source, to: output)
        let audio = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
    }

    // MARK: GIF

    func testGIFFrameTimesAreEvenlySpaced() {
        let times = GIFExporter.frameTimes(duration: 2, fps: 10)
        XCTAssertEqual(times.count, 20)
        XCTAssertEqual(times[1].seconds - times[0].seconds, 0.1, accuracy: 0.001)
        XCTAssertEqual(GIFExporter.frameTimes(duration: 0.01, fps: 10).count, 1)
    }

    func testGIFExportLoopsForeverAndRespectsTheWidthLimit() async throws {
        let video = temp("gif-in")
        let gif = temp("gif-out", ext: "gif")
        try await SyntheticMedia.makeMovie(at: video, seconds: 2)
        try await GIFExporter.export(from: video, to: gif, fps: 5, maxWidth: 80)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 10, accuracy: 1)
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(first.width, 80)
        XCTAssertEqual(Double(first.width) / Double(first.height), 160.0 / 90.0, accuracy: 0.05)

        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gifProperties = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        XCTAssertEqual(gifProperties?[kCGImagePropertyGIFLoopCount] as? Int, 0)
    }
}

private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(abs(a - b) <= accuracy, "\(a) is not within \(accuracy) of \(b)", file: file, line: line)
}
