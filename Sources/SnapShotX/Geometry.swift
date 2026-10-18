import CoreGraphics

/// A window the user can pick in window-capture mode. `frame` is in AppKit global coordinates (origin bottom-left).
struct WindowCandidate: Equatable {
    var id: UInt32
    var frame: CGRect
    var title: String
    var owner: String
}

/// Pure coordinate helpers. AppKit uses a bottom-left origin, while CoreGraphics window lists and
/// ScreenCaptureKit source rects use a top-left origin, so every capture path converts through here.
enum Geometry {
    /// Converts a rect from CoreGraphics global space (top-left origin, relative to the primary display)
    /// to AppKit global space (bottom-left origin).
    static func appKitRect(fromTopLeftRect r: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryScreenHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Converts a selection in AppKit global space to a display-local rect with a top-left origin,
    /// which is what `SCStreamConfiguration.sourceRect` expects.
    static func displayLocalRect(selection: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: selection.minX - screenFrame.minX,
               y: screenFrame.maxY - selection.maxY,
               width: selection.width,
               height: selection.height)
    }

    /// First window containing the point. `windows` must be ordered front to back.
    static func topmost(at point: CGPoint, in windows: [WindowCandidate]) -> WindowCandidate? {
        windows.first { $0.frame.contains(point) }
    }

    static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// A rectangle dragged from `a` toward `b` whose width over height is `aspect`, shrunk if needed to stay inside `bounds`.
    static func aspectRect(from a: CGPoint, to b: CGPoint, aspect: CGFloat, within bounds: CGRect) -> CGRect {
        let sx: CGFloat = b.x >= a.x ? 1 : -1, sy: CGFloat = b.y >= a.y ? 1 : -1
        var width = abs(b.x - a.x), height = abs(b.y - a.y)
        if width / max(height, 0.0001) > aspect { height = width / aspect } else { width = height * aspect }
        let room = CGSize(width: sx > 0 ? bounds.maxX - a.x : a.x - bounds.minX, height: sy > 0 ? bounds.maxY - a.y : a.y - bounds.minY)
        let shrink = min(1, room.width / max(width, 0.0001), room.height / max(height, 0.0001))
        width *= shrink; height *= shrink
        return CGRect(x: sx > 0 ? a.x : a.x - width, y: sy > 0 ? a.y : a.y - height, width: width, height: height)
    }

    /// Snaps the end of a line to the nearest 45° step around `start` (Shift while drawing).
    static func constrainedEnd(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return end }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    /// The square anchored at `start` that reaches `end` along its longer side (Shift while drawing).
    static func squareRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let side = max(abs(end.x - start.x), abs(end.y - start.y))
        let corner = CGPoint(x: start.x + (end.x >= start.x ? side : -side),
                             y: start.y + (end.y >= start.y ? side : -side))
        return normalizedRect(from: start, to: corner)
    }

    static func clamp(_ p: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, rect.minX), rect.maxX), y: min(max(p.y, rect.minY), rect.maxY))
    }
}
