import CoreGraphics
import Foundation

enum ZoomFocus: Codable, Equatable {
    /// Follow the pointer.
    case cursor
    /// Hold on a fixed spot, normalized to the video with the origin at the top-left.
    case point(x: Double, y: Double)
}

struct ZoomSegment: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Seconds in the original video.
    var start: Double
    var end: Double
    var scale: Double = 2
    var focus: ZoomFocus = .cursor

    var duration: Double { end - start }
}

struct CursorStyle: Codable, Equatable {
    var visible = true
    /// 1 is the pointer's natural on-screen size.
    var size = 1.0
    /// 0 is the path as recorded, 1 is heavily smoothed.
    var smoothing = 0.5
    var clickEffect = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 1
        smoothing = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? 0.5
        clickEffect = try c.decodeIfPresent(Bool.self, forKey: .clickEffect) ?? true
    }
}

enum StudioExportPreset: String, Codable, CaseIterable, Identifiable {
    case original, p1080, p720

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original size"
        case .p1080: return "1080p"
        case .p720: return "720p"
        }
    }

    /// The longest side the export may have, or nil for no limit.
    var maxLongEdge: Int? {
        switch self {
        case .original: return nil
        case .p1080: return 1920
        case .p720: return 1280
        }
    }
}

/// Every edit made to a recording in Studio Mode. The original video is never changed.
struct StudioProject: Codable, Equatable {
    var trimStart = 0.0
    /// Nil means "to the end".
    var trimEnd: Double?
    var zooms: [ZoomSegment] = []
    var cursor = CursorStyle()
    var background = BackgroundStyle()
    var preset = StudioExportPreset.original

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        zooms = try c.decodeIfPresent([ZoomSegment].self, forKey: .zooms) ?? []
        cursor = try c.decodeIfPresent(CursorStyle.self, forKey: .cursor) ?? CursorStyle()
        background = try c.decodeIfPresent(BackgroundStyle.self, forKey: .background) ?? BackgroundStyle()
        preset = try c.decodeIfPresent(StudioExportPreset.self, forKey: .preset) ?? .original
    }

    /// The kept part of a video of `duration` seconds, always at least a tenth of a second and inside the video.
    func trimRange(duration: Double) -> (start: Double, end: Double) {
        let minimum = min(0.1, max(0, duration))
        let start = min(max(0, trimStart), max(0, duration - minimum))
        let end = min(max(trimEnd ?? duration, start + minimum), duration)
        return (start, end)
    }
}

// MARK: - Smart zooms

enum SmartZoom {
    /// Zoom segments around clusters of clicks: clicks within `linkGap` seconds of each other share a zoom, which
    /// starts `leadIn` seconds before the first click (so the camera has arrived when it happens) and runs
    /// `tail` seconds past the last. Short zooms are stretched, and overlapping ones are merged.
    static func generate(from clicks: [CursorTrack.Click], duration: Double, scale: Double = 2,
                         leadIn: Double = 0.6, tail: Double = 1.4, linkGap: Double = 2.0,
                         minimumLength: Double = 2.0) -> [ZoomSegment] {
        let times = clicks.map(\.t).filter { $0 >= 0 && $0 <= duration }.sorted()
        guard !times.isEmpty else { return [] }

        var groups: [[Double]] = [[times[0]]]
        for time in times.dropFirst() {
            if time - groups[groups.count - 1].last! > linkGap { groups.append([time]) } else { groups[groups.count - 1].append(time) }
        }

        var segments: [ZoomSegment] = []
        for group in groups {
            var start = max(0, group.first! - leadIn)
            var end = min(duration, group.last! + tail)
            if end - start < minimumLength {
                end = min(duration, start + minimumLength)
                start = max(0, end - minimumLength)
            }
            if var previous = segments.last, start < previous.end + 0.25 {
                previous.end = max(previous.end, end)
                segments[segments.count - 1] = previous
            } else {
                segments.append(ZoomSegment(start: start, end: end, scale: scale))
            }
        }
        return segments
    }
}

// MARK: - Zoom camera

/// Works out which part of the video is on screen at a given time.
enum ZoomCamera {
    /// A region of the video, normalized with the origin at the top-left.
    struct Crop: Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        static let full = Crop(x: 0, y: 0, width: 1, height: 1)
    }

    /// Seconds a zoom takes to ease in, and to ease out.
    static let ramp = 0.6

    private static func smoothstep(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// How far into `segment` the camera is at `time`: 0 outside it, rising to 1 over the ramp and falling back at the end.
    static func weight(of segment: ZoomSegment, at time: Double) -> Double {
        guard segment.duration > 0 else { return 0 }
        let r = min(ramp, segment.duration / 2)
        return smoothstep((time - segment.start) / r) * (1 - smoothstep((time - (segment.end - r)) / r))
    }

    /// The part of the video to show at `time`. Zooms ease in and out, the camera drifts from the middle toward
    /// the focus as it zooms, and the result never leaves the video.
    static func crop(at time: Double, zooms: [ZoomSegment], cursor: CursorTrack?, smoothing: Double) -> Crop {
        var dominant: (segment: ZoomSegment, weight: Double, gain: Double)?
        for segment in zooms {
            let w = weight(of: segment, at: time)
            let gain = (max(1, segment.scale) - 1) * w
            if gain > (dominant?.gain ?? 0) { dominant = (segment, w, gain) }
        }
        guard let dominant, dominant.gain > 1e-6 else { return .full }

        let focus: CGPoint
        switch dominant.segment.focus {
        case .point(let x, let y):
            focus = CGPoint(x: x, y: y)
        case .cursor:
            // The camera follows a smoother path than the visible pointer, so it glides instead of jittering.
            focus = cursor?.position(at: time, smoothing: max(smoothing, 0.8)) ?? CGPoint(x: 0.5, y: 0.5)
        }
        let center = CGPoint(x: 0.5 + (focus.x - 0.5) * dominant.weight, y: 0.5 + (focus.y - 0.5) * dominant.weight)

        let size = 1 / (1 + dominant.gain)
        let cx = min(max(center.x, size / 2), 1 - size / 2)
        let cy = min(max(center.y, size / 2), 1 - size / 2)
        return Crop(x: cx - size / 2, y: cy - size / 2, width: size, height: size)
    }
}

// MARK: - Layout

/// The size of the finished video and where the recording sits in it.
struct StudioLayout: Equatable {
    /// Pixels of the output video. Always even, as H.264 requires.
    var renderSize: CGSize
    /// Where the recording is drawn, in output pixels with a top-left origin.
    var contentRect: CGRect
    var cornerRadius: CGFloat
    var hasBackground: Bool

    static func make(sourceSize: CGSize, background: BackgroundStyle, preset: StudioExportPreset) -> StudioLayout {
        var canvas = sourceSize
        var content = CGRect(origin: .zero, size: sourceSize)
        var radius: CGFloat = 0
        if background.enabled {
            let layout = BackgroundLayout.compute(contentSize: sourceSize, style: background)
            canvas = layout.canvas
            content = layout.content
            radius = CGFloat(background.cornerRadius) * min(sourceSize.width, sourceSize.height)
        }

        var scale: CGFloat = 1
        if let cap = preset.maxLongEdge { scale = min(1, CGFloat(cap) / max(canvas.width, canvas.height)) }

        func even(_ value: CGFloat) -> CGFloat {
            let floored = Int(value.rounded(.down))
            return CGFloat(max(2, floored - floored % 2))
        }
        let render = CGSize(width: even(canvas.width * scale), height: even(canvas.height * scale))
        // Keep the content in proportion if rounding the canvas changed it slightly.
        let fx = render.width / canvas.width, fy = render.height / canvas.height
        let scaledContent = CGRect(x: content.minX * fx, y: content.minY * fy, width: content.width * fx, height: content.height * fy)
        return StudioLayout(renderSize: render, contentRect: scaledContent, cornerRadius: radius * min(fx, fy), hasBackground: background.enabled)
    }
}
