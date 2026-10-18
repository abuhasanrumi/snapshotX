import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a recording into a looping GIF. GIFs are big, so they're sampled at a low frame rate and scaled down.
enum GIFExporter {
    enum ExportError: LocalizedError {
        case emptyVideo
        case cannotCreateFile

        var errorDescription: String? {
            switch self {
            case .emptyVideo: return "The recording has no frames to turn into a GIF."
            case .cannotCreateFile: return "The GIF file couldn't be created."
            }
        }
    }

    /// The sample times for a clip: evenly spaced, starting at the first frame.
    static func frameTimes(duration: TimeInterval, fps: Int) -> [CMTime] {
        let step = 1.0 / Double(max(1, fps))
        let count = max(1, Int((duration * Double(fps)).rounded(.down)))
        return (0..<count).map { CMTime(seconds: Double($0) * step, preferredTimescale: 600) }
    }

    static func export(from video: URL, to gif: URL, fps: Int, maxWidth: Int) async throws {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw ExportError.emptyVideo }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4) // width-limited, aspect ratio kept

        let times = frameTimes(duration: duration, fps: fps)
        try? FileManager.default.removeItem(at: gif)
        guard let destination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, times.count, nil) else {
            throw ExportError.cannotCreateFile
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)],
        ] as CFDictionary

        var added = 0
        for await result in generator.images(for: times) {
            if case .success(_, let image, _) = result {
                CGImageDestinationAddImage(destination, image, frameProperties)
                added += 1
            }
        }
        guard added > 0 else { throw ExportError.emptyVideo }
        guard CGImageDestinationFinalize(destination) else { throw ExportError.cannotCreateFile }
    }
}
