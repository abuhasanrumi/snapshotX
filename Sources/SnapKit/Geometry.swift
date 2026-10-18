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
}
