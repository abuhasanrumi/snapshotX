@preconcurrency import AVFoundation

/// Folds a recording's separate audio tracks (system audio and microphone) into one track that every player
/// plays together. The video is copied sample for sample, so this is fast and loses no picture quality.
enum AudioMixer {
    enum MixError: LocalizedError {
        case noVideo
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noVideo: return "The recording has no video track."
            case .failed(let reason): return "Mixing the audio failed: \(reason)"
            }
        }
    }

    /// Each source is turned down a little so two loud sources can't clip when summed.
    static let sourceVolume: Float = 0.8

    static func audioTrackCount(in url: URL) async -> Int {
        (try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count) ?? 0
    }

    /// Writes a copy of `input` at `output` with one mixed audio track. Files with fewer than two audio tracks
    /// are copied as they are.
    static func mixAudioTracks(in input: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: input)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw MixError.noVideo }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        try? FileManager.default.removeItem(at: output)
        guard audioTracks.count > 1 else {
            try FileManager.default.copyItem(at: input, to: output)
            return
        }

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioTracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(sourceVolume, at: .zero)
            return parameters
        }
        mixOutput.audioMix = mix
        guard reader.canAdd(videoOutput), reader.canAdd(mixOutput) else { throw MixError.failed("could not read the recording") }
        reader.add(videoOutput)
        reader.add(mixOutput)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let hint = try await videoTrack.load(.formatDescriptions).first
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw MixError.failed("could not write the recording") }
        writer.add(videoInput)
        writer.add(audioInput)

        guard writer.startWriting() else { throw MixError.failed(writer.error?.localizedDescription ?? "unknown error") }
        guard reader.startReading() else { throw MixError.failed(reader.error?.localizedDescription ?? "unknown error") }
        writer.startSession(atSourceTime: .zero)

        async let videoDone: Void = pump(videoOutput, into: videoInput, queue: DispatchQueue(label: "com.snapshotx.mix.video"))
        async let audioDone: Void = pump(mixOutput, into: audioInput, queue: DispatchQueue(label: "com.snapshotx.mix.audio"))
        _ = await (videoDone, audioDone)

        await writer.finishWriting()
        guard writer.status == .completed, reader.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw MixError.failed((writer.error ?? reader.error)?.localizedDescription ?? "unknown error")
        }
    }

    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, queue: DispatchQueue) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
