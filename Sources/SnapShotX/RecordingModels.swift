import CoreGraphics
import Foundation

enum RecordingFormat: String, CaseIterable, Codable, Identifiable {
    case mp4, gif

    var id: String { rawValue }
    var title: String { self == .mp4 ? "MP4 video" : "GIF" }
    var fileExtension: String { rawValue }
}

enum CameraBubbleSize: String, CaseIterable, Codable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Diameter or side length in points.
    var points: CGFloat {
        switch self {
        case .small: return 140
        case .medium: return 200
        case .large: return 280
        }
    }
}

enum CameraBubbleShape: String, CaseIterable, Codable, Identifiable {
    case circle, roundedSquare

    var id: String { rawValue }
    var title: String { self == .circle ? "Circle" : "Rounded square" }
}

/// Everything the user can choose about a recording. Saved as one value in Preferences.
struct RecordingOptions: Codable, Equatable {
    var format: RecordingFormat = .mp4
    /// Frame rate for MP4 recordings.
    var fps = 30
    var showCursor = true
    var systemAudio = false
    var microphone = false
    var highlightClicks = true
    var showKeystrokes = false
    /// Only show shortcuts (those using ⌘, ⌃ or ⌥) and not ordinary typing.
    var onlyCommandKeys = true
    var camera = false
    var cameraSize: CameraBubbleSize = .medium
    var cameraShape: CameraBubbleShape = .circle
    /// Frame rate of GIF output.
    var gifFPS = 15
    /// Widest a GIF gets, in pixels.
    var gifMaxWidth = 800

    static let fpsChoices = [15, 24, 30, 60]
    static let gifFPSChoices = [10, 15, 20, 25]
}

/// Sizing rules for the video file.
enum RecordingGeometry {
    /// Device pixels for a region measured in points. H.264 needs even dimensions.
    static func pixelSize(points: CGSize, scale: CGFloat) -> CGSize {
        func even(_ value: CGFloat) -> CGFloat {
            let floored = Int(value.rounded(.down))
            return CGFloat(max(2, floored - floored % 2))
        }
        return CGSize(width: even(points.width * scale), height: even(points.height * scale))
    }

    /// A bitrate that keeps screen content sharp without huge files: about 0.1 bit per pixel per frame.
    static func bitrate(width: Int, height: Int, fps: Int) -> Int {
        let raw = Double(width) * Double(height) * Double(fps) * 0.1
        return Int(min(40_000_000, max(2_000_000, raw)))
    }
}

enum DurationFormat {
    /// "0:07", "12:34", or "1:02:03" for an hour or more.
    static func string(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// A finished recording on disk.
struct RecordingOutput: Equatable {
    var url: URL
    var duration: TimeInterval
    var pixelSize: CGSize
    var format: RecordingFormat
}
