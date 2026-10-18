@preconcurrency import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageFile {
    struct WriteError: LocalizedError {
        var errorDescription: String? { "Could not write the image to disk." }
    }

    /// Pixels per inch to record in a PNG. Screenshots are captured at the display's pixel density (2x on Retina), and
    /// macOS's own screenshots say 144 for that, so Preview and other apps show them at their true on-screen size
    /// instead of twice as large and soft.
    static var screenDPI: Double { 72 * Double(max(1, NSScreen.main?.backingScaleFactor ?? 2)) }

    /// The density to write into saved files, chosen in Settings. Nil means the screen's own. It only changes the size an
    /// app prints or lays the image out at: the pixels themselves are always exactly what the screen drew.
    nonisolated(unsafe) static var outputDPIOverride: Double?

    static var outputDPI: Double { outputDPIOverride ?? screenDPI }

    private static var pngProperties: CFDictionary {
        [kCGImagePropertyDPIWidth: outputDPI, kCGImagePropertyDPIHeight: outputDPI] as CFDictionary
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw WriteError()
        }
        CGImageDestinationAddImage(destination, image, pngProperties)
        guard CGImageDestinationFinalize(destination) else { throw WriteError() }
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, pngProperties)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    /// A still frame from an MP4, scaled down. Blocks briefly, so it is meant for small previews.
    static func videoThumbnail(url: URL, maxPixelSize: Int) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let box = Box<CGImage>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            // A little in, to skip a blank first frame. Very short clips fall back to the first frame.
            let later = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
            box.value = later
            if later == nil { box.value = try? await generator.image(at: .zero).image }
            done.signal()
        }
        done.wait()
        return box.value
    }

    /// Decodes a downsampled version of the image (or the first frame of an MP4) without loading the full bitmap.
    static func thumbnail(url: URL, maxPixelSize: Int) -> CGImage? {
        if url.pathExtension.lowercased() == "mp4" { return videoThumbnail(url: url, maxPixelSize: maxPixelSize) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
