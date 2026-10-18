import AVFoundation
import CoreVideo
import Foundation

/// One instruction covering the whole edited timeline; the compositor draws every frame from the shared renderer.
final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let renderer: StudioFrameRenderer
    let trackID: CMPersistentTrackID

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, renderer: StudioFrameRenderer) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.renderer = renderer
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
        super.init()
    }
}

final class StudioCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.snapshotx.studio.compositor")

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            guard let instruction = request.videoCompositionInstruction as? StudioInstruction,
                  let source = request.sourceFrame(byTrackID: instruction.trackID),
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "SnapShotX.Studio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No frame to draw"]))
                return
            }
            instruction.renderer.render(source: source, at: request.compositionTime.seconds, into: output)
            request.finish(withComposedVideoFrame: output)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

/// Turns a recording and a project into something AVFoundation can play or export.
struct StudioComposition {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVAudioMix?
    let renderer: StudioFrameRenderer
    /// Length of the edited video.
    let duration: Double

    enum BuildError: LocalizedError {
        case noVideo
        var errorDescription: String? { "The recording has no video track." }
    }

    static func build(asset: AVAsset, project: StudioProject, cursor: CursorTrack?) async throws -> StudioComposition {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw BuildError.noVideo }
        let fullDuration = try await asset.load(.duration).seconds
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let size = naturalSize.applying(transform)
        let sourceSize = CGSize(width: abs(size.width), height: abs(size.height))
        let frameDuration = try await videoTrack.load(.minFrameDuration)

        let range = project.trimRange(duration: fullDuration)
        let timescale: CMTimeScale = 600
        let sourceRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: timescale),
                                      end: CMTime(seconds: range.end, preferredTimescale: timescale))

        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw BuildError.noVideo
        }
        try video.insertTimeRange(sourceRange, of: videoTrack, at: .zero)
        video.preferredTransform = transform

        var parameters: [AVMutableAudioMixInputParameters] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            guard let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try? audio.insertTimeRange(sourceRange, of: track, at: .zero)
            parameters.append(AVMutableAudioMixInputParameters(track: audio))
        }
        var mix: AVMutableAudioMix?
        if !parameters.isEmpty {
            mix = AVMutableAudioMix()
            mix?.inputParameters = parameters
        }

        let renderer = StudioFrameRenderer(project: project, cursor: cursor, sourceSize: sourceSize, timeOffset: range.start)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = StudioCompositor.self
        videoComposition.renderSize = renderer.layout.renderSize
        let fps = frameDuration.isValid && frameDuration.seconds > 0 ? frameDuration : CMTime(value: 1, timescale: 30)
        videoComposition.frameDuration = fps
        videoComposition.instructions = [StudioInstruction(timeRange: CMTimeRange(start: .zero, duration: composition.duration),
                                                           trackID: video.trackID, renderer: renderer)]
        return StudioComposition(composition: composition, videoComposition: videoComposition, audioMix: mix,
                                 renderer: renderer, duration: composition.duration.seconds)
    }
}

// MARK: - Export

enum StudioExporter {
    enum Format: String, CaseIterable, Identifiable {
        case mp4, gif
        var id: String { rawValue }
    }

    enum ExportError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    /// Writes the edited video to `url` and reports progress from 0 to 1.
    static func export(asset: AVAsset, project: StudioProject, cursor: CursorTrack?, to url: URL, format: Format,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let built = try await StudioComposition.build(asset: asset, project: project, cursor: cursor)
        try? FileManager.default.removeItem(at: url)
        switch format {
        case .mp4:
            try await writeMP4(built, to: url, progress: progress)
        case .gif:
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("studio-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: temp) }
            try await writeMP4(built, to: temp) { progress($0 * 0.7) }
            try await GIFExporter.export(from: temp, to: url, fps: 15, maxWidth: 800)
            progress(1)
        }
    }

    private static func writeMP4(_ built: StudioComposition, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: built.composition)
        let videoTracks = try await built.composition.loadTracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.videoComposition = built.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.audioMix = built.audioMix
            reader.add(output)
            audioOutput = output
        }

        let size = built.videoComposition.renderSize
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let pixels = Int(size.width * size.height)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, pixels * 6),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading() else { throw ExportError.failed(reader.error?.localizedDescription ?? "Couldn't read the recording.") }
        guard writer.startWriting() else { throw ExportError.failed(writer.error?.localizedDescription ?? "Couldn't write the file.") }
        writer.startSession(atSourceTime: .zero)

        let total = max(0.001, built.duration)
        let group = DispatchGroup()
        let pump = { (input: AVAssetWriterInput, output: AVAssetReaderOutput, reportsProgress: Bool, label: String) in
            group.enter()
            let queue = DispatchQueue(label: "com.snapshotx.studio.export.\(label)")
            nonisolated(unsafe) let input = input
            nonisolated(unsafe) let output = output
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                    if reportsProgress { progress(min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / total)) }
                    if !input.append(sample) {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }
        pump(videoInput, videoOutput, true, "video")
        if let audioInput, let audioOutput { pump(audioInput, audioOutput, false, "audio") }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }
        if reader.status == .failed { writer.cancelWriting(); throw ExportError.failed(reader.error?.localizedDescription ?? "Reading failed.") }
        await writer.finishWriting()
        if writer.status != .completed { throw ExportError.failed(writer.error?.localizedDescription ?? "Writing failed.") }
        progress(1)
    }
}
