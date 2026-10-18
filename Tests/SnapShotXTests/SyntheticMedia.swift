import AVFoundation
@testable import SnapShotX
import CoreMedia
import CoreVideo

/// Builds small, fully synthetic recordings so the writing, mixing and GIF code can be tested without a screen,
/// a microphone or any permission.
enum SyntheticMedia {
    struct Tone {
        var frequency: Double
        var amplitude: Float
        var channels = 1
    }

    /// The base clock value the fake recording starts at, to prove the file doesn't depend on it starting at zero.
    static let baseTime = CMTime(seconds: 5_000, preferredTimescale: 600)

    static func videoSample(frame: Int, fps: Int, width: Int, height: Int) -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixelBuffer)
        let buffer = pixelBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let shade = UInt8(truncatingIfNeeded: 40 + frame * 12)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * rowBytes + x * 4
                p[0] = shade                      // blue changes every frame
                p[1] = UInt8(truncatingIfNeeded: x * 255 / max(1, width))
                p[2] = UInt8(truncatingIfNeeded: y * 255 / max(1, height))
                p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                                        presentationTimeStamp: baseTime + CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format!,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return sample!
    }

    /// `frames` frames of a sine tone as interleaved Float32 PCM at 48 kHz, starting `offsetFrames` into the recording.
    static func audioSample(tone: Tone, offsetFrames: Int, frames: Int = 1024) -> CMSampleBuffer {
        let rate = 48_000.0
        var description = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * tone.channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * tone.channels),
            mChannelsPerFrame: UInt32(tone.channels), mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)

        var samples = [Float](repeating: 0, count: frames * tone.channels)
        for i in 0..<frames {
            let value = tone.amplitude * Float(sin(2 * .pi * tone.frequency * Double(offsetFrames + i) / rate))
            for c in 0..<tone.channels { samples[i * tone.channels + c] = value }
        }
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0,
                                           blockBufferOut: &block)
        CMBlockBufferReplaceDataBytes(with: samples, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount)

        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
            presentationTimeStamp: baseTime + CMTime(value: CMTimeValue(offsetFrames), timescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &sample)
        return sample!
    }

    /// Writes a recording of `seconds` of video (frames only in the first `videoSeconds`) and the given audio tones.
    /// Returns the stop time that was passed to the writer.
    @discardableResult
    static func makeMovie(at url: URL, seconds: Double, videoSeconds: Double? = nil, fps: Int = 10,
                          width: Int = 160, height: Int = 90, system: Tone? = nil, mic: Tone? = nil) async throws -> CMTime {
        let writer = try RecordingWriter(url: url, width: width, height: height, fps: fps,
                                         systemAudio: system != nil, microphone: mic != nil)
        let videoFrames = Int((videoSeconds ?? seconds) * Double(fps))
        for frame in 0..<videoFrames {
            writer.appendVideo(videoSample(frame: frame, fps: fps, width: width, height: height))
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        let chunks = Int(seconds * 48_000 / 1024)
        for chunk in 0..<chunks {
            if let system { writer.appendSystemAudio(audioSample(tone: system, offsetFrames: chunk * 1024)) }
            if let mic { writer.appendMicrophone(audioSample(tone: mic, offsetFrames: chunk * 1024)) }
            try await Task.sleep(nanoseconds: 1_500_000)
        }
        let stop = baseTime + CMTime(seconds: seconds, preferredTimescale: 600)
        _ = try await writer.finish(at: stop)
        return stop
    }

    /// RMS of the first audio track after decoding it to PCM.
    static func audioRMS(of url: URL) async throws -> Float {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .audio)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        reader.startReading()
        var sum: Double = 0
        var count = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            let floats = UnsafeBufferPointer(start: UnsafeRawPointer(pointer!).assumingMemoryBound(to: Float.self),
                                             count: length / MemoryLayout<Float>.size)
            // Skip the first block: encoders prime with a little silence.
            if count == 0 { count = 1; continue }
            for value in floats { sum += Double(value * value); count += 1 }
        }
        return Float((sum / Double(max(1, count - 1))).squareRoot())
    }

    static func tempURL(_ name: String, ext: String = "mp4") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("snapshotx-\(name)-\(UUID().uuidString).\(ext)")
    }
}
