import AVFoundation
import CoreMedia

/// Writes screen frames and audio into an H.264 MP4. All appends are serialized on one queue, so callers can
/// feed it from ScreenCaptureKit and AVCapture callbacks on any thread.
///
/// Timing rules: the first video frame starts the file's timeline, audio from before that is dropped, frames
/// must arrive in increasing order, and on finish the last frame is repeated up to the stop time, because a
/// screen that stops changing sends no frames and the video would otherwise end early.
final class RecordingWriter: @unchecked Sendable {
    enum WriterError: LocalizedError {
        case cannotAddInput
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cannotAddInput: return "The recording file couldn't be set up."
            case .failed(let reason): return "Writing the recording failed: \(reason)"
            }
        }
    }

    struct Summary: Equatable {
        var duration: TimeInterval
        var videoFrames: Int
        /// The host-clock time of the first frame, which is time zero of the video.
        var start: CMTime = .zero
    }

    private let queue = DispatchQueue(label: "com.snapshotx.recording-writer")
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var systemAudio: AVAssetWriterInput?
    private var microphone: AVAssetWriterInput?

    private let frameDuration: CMTime
    private var sessionStart: CMTime?
    private var lastVideo: (buffer: CVPixelBuffer, time: CMTime)?
    private var videoFrames = 0
    private var finished = false

    init(url: URL, width: Int, height: Int, fps: Int, systemAudio: Bool, microphone: Bool) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))

        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: RecordingGeometry.bitrate(width: width, height: height, fps: fps),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ] as [String: Any],
        ])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(video) else { throw WriterError.cannotAddInput }
        writer.add(video)

        if systemAudio { self.systemAudio = try Self.addAudioInput(to: writer, channels: 2, bitrate: 128_000) }
        if microphone { self.microphone = try Self.addAudioInput(to: writer, channels: 1, bitrate: 96_000) }
        guard writer.startWriting() else { throw WriterError.failed(writer.error?.localizedDescription ?? "unknown error") }
    }

    private static func addAudioInput(to writer: AVAssetWriter, channels: Int, bitrate: Int) throws -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate,
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw WriterError.cannotAddInput }
        writer.add(input)
        return input
    }

    // MARK: Appending

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        queue.async { [self] in
            guard !finished, writer.status == .writing else { return }
            if sessionStart == nil {
                writer.startSession(atSourceTime: time)
                sessionStart = time
            }
            if let last = lastVideo, time <= last.time { return }
            guard video.isReadyForMoreMediaData else { return } // drop rather than stall the capture
            if adaptor.append(pixels, withPresentationTime: time) {
                lastVideo = (pixels, time)
                videoFrames += 1
            }
        }
    }

    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) { appendAudio(sampleBuffer, to: \.systemAudio) }
    func appendMicrophone(_ sampleBuffer: CMSampleBuffer) { appendAudio(sampleBuffer, to: \.microphone) }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, to input: KeyPath<RecordingWriter, AVAssetWriterInput?>) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        queue.async { [self] in
            guard !finished, writer.status == .writing, let start = sessionStart, time >= start,
                  let target = self[keyPath: input], target.isReadyForMoreMediaData else { return }
            target.append(sampleBuffer)
        }
    }

    // MARK: Finishing

    /// Ends the file at `stopTime` (on the same clock as the sample timestamps).
    func finish(at stopTime: CMTime) async throws -> Summary {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Summary, Error>) in
            queue.async { [self] in
                guard !finished else { return continuation.resume(throwing: WriterError.failed("already finished")) }
                finished = true

                guard let start = sessionStart, let last = lastVideo else {
                    writer.cancelWriting()
                    return continuation.resume(throwing: WriterError.failed("no video frames were captured"))
                }
                // Hold the last frame until the stop time so the video is as long as the audio.
                let end = max(stopTime, last.time + frameDuration)
                let holdTime = end - frameDuration
                if holdTime > last.time, video.isReadyForMoreMediaData {
                    _ = adaptor.append(last.buffer, withPresentationTime: holdTime)
                }
                writer.endSession(atSourceTime: end)
                video.markAsFinished()
                systemAudio?.markAsFinished()
                microphone?.markAsFinished()

                let summary = Summary(duration: CMTimeGetSeconds(end - start), videoFrames: videoFrames, start: start)
                writer.finishWriting { [writer] in
                    if writer.status == .completed {
                        continuation.resume(returning: summary)
                    } else {
                        continuation.resume(throwing: WriterError.failed(writer.error?.localizedDescription ?? "unknown error"))
                    }
                }
            }
        }
    }

    /// Stops without producing a file.
    func cancel() {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            writer.cancelWriting()
        }
    }
}
