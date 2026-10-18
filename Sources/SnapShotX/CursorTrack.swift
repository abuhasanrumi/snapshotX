import CoreGraphics
import Foundation

/// Where the mouse was, and when it clicked, during a recording. Coordinates are normalized to the recorded
/// region with the origin at the top-left (so 0.5, 0.5 is the middle) and may fall outside 0...1 when the
/// pointer is outside the region. Times are seconds from the start of the video.
///
/// Recording the cursor separately from the picture is what lets Studio Mode smooth it, resize it, add click
/// effects and zoom toward it.
struct CursorTrack: Codable, Equatable {
    struct Sample: Codable, Equatable {
        var t: Double
        var x: Double
        var y: Double
    }

    struct Click: Codable, Equatable {
        var t: Double
        var x: Double
        var y: Double
        /// 0 left, 1 right, 2 other.
        var button: Int
    }

    /// Display scale at recording time, used to draw the cursor at its natural on-screen size.
    var pixelsPerPoint: Double = 2
    var samples: [Sample] = []
    var clicks: [Click] = []

    var isEmpty: Bool { samples.isEmpty }

    /// A point in AppKit global coordinates (origin bottom-left) as a position inside `region`.
    static func normalize(_ point: CGPoint, in region: CGRect) -> CGPoint {
        guard region.width > 0, region.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (point.x - region.minX) / region.width, y: 1 - (point.y - region.minY) / region.height)
    }

    /// The same track with every time moved earlier by `offset` seconds, dropping what happened before zero.
    func rebased(by offset: Double) -> CursorTrack {
        var copy = self
        copy.samples = samples.compactMap { sample in
            sample.t - offset >= 0 ? Sample(t: sample.t - offset, x: sample.x, y: sample.y) : nil
        }
        copy.clicks = clicks.compactMap { click in
            click.t - offset >= 0 ? Click(t: click.t - offset, x: click.x, y: click.y, button: click.button) : nil
        }
        return copy
    }

    /// The same track with the given spans (in this track's own time) cut out and everything after them moved earlier,
    /// matching a video that had those spans paused.
    func removing(_ spans: [(start: Double, end: Double)]) -> CursorTrack {
        let sorted = spans.sorted { $0.start < $1.start }
        func shift(_ t: Double) -> Double? {
            var offset = 0.0
            for span in sorted where t >= span.start {
                if t < span.end { return nil }
                offset += span.end - span.start
            }
            return t - offset
        }
        var copy = self
        copy.samples = samples.compactMap { s in shift(s.t).map { Sample(t: $0, x: s.x, y: s.y) } }
        copy.clicks = clicks.compactMap { c in shift(c.t).map { Click(t: $0, x: c.x, y: c.y, button: c.button) } }
        return copy
    }

    /// Where the pointer is at `time`. `smoothing` runs from 0 (as recorded, joined by straight lines) to 1 (heavily
    /// smoothed). Smoothing averages the samples around `time` with Gaussian weights, which removes jitter and
    /// hand shake while keeping the path where it went.
    func position(at time: Double, smoothing: Double) -> CGPoint? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if samples.count == 1 { return CGPoint(x: first.x, y: first.y) }

        let sigma = max(0, min(1, smoothing)) * 0.3
        guard sigma > 0.003 else { return interpolated(at: time) }

        let radius = sigma * 3
        let lower = firstIndex(atOrAfter: time - radius)
        var sumX = 0.0, sumY = 0.0, sumWeight = 0.0
        var index = lower
        while index < samples.count, samples[index].t <= time + radius {
            let dt = samples[index].t - time
            let weight = exp(-(dt * dt) / (2 * sigma * sigma))
            sumX += samples[index].x * weight
            sumY += samples[index].y * weight
            sumWeight += weight
            index += 1
        }
        guard sumWeight > 1e-9 else { return interpolated(at: time) }
        // Before the first and after the last sample the window is one-sided, which would drag the path
        // toward the middle. Hold the end points instead.
        if time <= first.t { return CGPoint(x: first.x, y: first.y) }
        if time >= last.t { return CGPoint(x: last.x, y: last.y) }
        return CGPoint(x: sumX / sumWeight, y: sumY / sumWeight)
    }

    /// Straight-line interpolation between the two samples around `time`, holding the ends.
    private func interpolated(at time: Double) -> CGPoint {
        let upper = firstIndex(atOrAfter: time)
        if upper == 0 { return CGPoint(x: samples[0].x, y: samples[0].y) }
        if upper >= samples.count { return CGPoint(x: samples[samples.count - 1].x, y: samples[samples.count - 1].y) }
        let a = samples[upper - 1], b = samples[upper]
        let span = b.t - a.t
        let f = span > 0 ? (time - a.t) / span : 0
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    /// Index of the first sample at or after `time`, by binary search.
    private func firstIndex(atOrAfter time: Double) -> Int {
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].t < time { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
