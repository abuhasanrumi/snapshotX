import CoreGraphics

enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// Geometry for editing a capture region. Coordinates have a bottom-left origin, so "top" means the larger y.
/// `aspect` is width divided by height and only matters when `lockAspect` is true.
enum SelectionEditor {
    static let minimumSide: CGFloat = 8

    static func handlePoints(of r: CGRect) -> [(handle: SelectionHandle, point: CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.maxY)), (.top, CGPoint(x: r.midX, y: r.maxY)),
         (.topRight, CGPoint(x: r.maxX, y: r.maxY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
         (.bottomRight, CGPoint(x: r.maxX, y: r.minY)), (.bottom, CGPoint(x: r.midX, y: r.minY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.minY)), (.left, CGPoint(x: r.minX, y: r.midY))]
    }

    /// The handle under `point`: a corner, or anywhere along an edge. Corners win where they overlap an edge.
    static func handle(at point: CGPoint, in rect: CGRect, tolerance: CGFloat) -> SelectionHandle? {
        let corners: Set<SelectionHandle> = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        var nearest: (handle: SelectionHandle, distance: CGFloat)?
        for (handle, p) in handlePoints(of: rect) where corners.contains(handle) {
            let d = hypot(p.x - point.x, p.y - point.y)
            if d <= tolerance, d < (nearest?.distance ?? .infinity) { nearest = (handle, d) }
        }
        if let nearest { return nearest.handle }

        let withinX = point.x >= rect.minX - tolerance && point.x <= rect.maxX + tolerance
        let withinY = point.y >= rect.minY - tolerance && point.y <= rect.maxY + tolerance
        var edges: [(SelectionHandle, CGFloat)] = []
        if withinY { edges += [(.left, abs(point.x - rect.minX)), (.right, abs(point.x - rect.maxX))] }
        if withinX { edges += [(.bottom, abs(point.y - rect.minY)), (.top, abs(point.y - rect.maxY))] }
        return edges.filter { $0.1 <= tolerance }.min { $0.1 < $1.1 }?.0
    }

    /// A new region dragged from `start` to `end`, kept inside `bounds`.
    static func created(from start: CGPoint, to end: CGPoint, within bounds: CGRect, lockAspect: Bool, aspect: CGFloat) -> CGRect {
        let anchor = Geometry.clamp(start, to: bounds)
        if lockAspect, aspect > 0 { return aspectRect(anchor: anchor, toward: end, aspect: aspect, within: bounds) }
        return Geometry.normalizedRect(from: anchor, to: Geometry.clamp(end, to: bounds))
    }

    static func moved(_ rect: CGRect, by delta: CGVector, within bounds: CGRect) -> CGRect {
        var moved = rect.offsetBy(dx: delta.dx, dy: delta.dy)
        moved.origin.x = min(max(moved.origin.x, bounds.minX), bounds.maxX - moved.width)
        moved.origin.y = min(max(moved.origin.y, bounds.minY), bounds.maxY - moved.height)
        return moved
    }

    /// Drags one handle to `point`. Dragging past the opposite side flips the region.
    static func resized(_ rect: CGRect, handle: SelectionHandle, to point: CGPoint, within bounds: CGRect,
                        lockAspect: Bool, aspect: CGFloat) -> CGRect {
        let p = Geometry.clamp(point, to: bounds)
        var left = rect.minX, right = rect.maxX, bottom = rect.minY, top = rect.maxY

        if lockAspect, aspect > 0 {
            switch handle {
            case .topLeft: return aspectRect(anchor: CGPoint(x: rect.maxX, y: rect.minY), toward: p, aspect: aspect, within: bounds)
            case .topRight: return aspectRect(anchor: CGPoint(x: rect.minX, y: rect.minY), toward: p, aspect: aspect, within: bounds)
            case .bottomRight: return aspectRect(anchor: CGPoint(x: rect.minX, y: rect.maxY), toward: p, aspect: aspect, within: bounds)
            case .bottomLeft: return aspectRect(anchor: CGPoint(x: rect.maxX, y: rect.maxY), toward: p, aspect: aspect, within: bounds)
            case .left, .right:
                if handle == .left { left = p.x } else { right = p.x }
                var width = max(minimumSide, abs(right - left))
                var height = width / aspect
                if height > bounds.height { height = bounds.height; width = height * aspect }
                let y = min(max(rect.midY - height / 2, bounds.minY), bounds.maxY - height)
                return CGRect(x: handle == .left ? rect.maxX - width : rect.minX, y: y, width: width, height: height)
                    .intersection(bounds)
            case .top, .bottom:
                if handle == .top { top = p.y } else { bottom = p.y }
                var height = max(minimumSide, abs(top - bottom))
                var width = height * aspect
                if width > bounds.width { width = bounds.width; height = width / aspect }
                let x = min(max(rect.midX - width / 2, bounds.minX), bounds.maxX - width)
                return CGRect(x: x, y: handle == .bottom ? rect.maxY - height : rect.minY, width: width, height: height)
                    .intersection(bounds)
            }
        }

        switch handle {
        case .topLeft: left = p.x; top = p.y
        case .top: top = p.y
        case .topRight: right = p.x; top = p.y
        case .right: right = p.x
        case .bottomRight: right = p.x; bottom = p.y
        case .bottom: bottom = p.y
        case .bottomLeft: left = p.x; bottom = p.y
        case .left: left = p.x
        }
        return CGRect(x: min(left, right), y: min(bottom, top), width: abs(right - left), height: abs(top - bottom))
    }

    /// Sets the size from typed numbers. The top-left corner stays put and the region grows right and down.
    static func withSize(_ rect: CGRect, width: CGFloat?, height: CGFloat?, within bounds: CGRect,
                         lockAspect: Bool, aspect: CGFloat) -> CGRect {
        var w = max(minimumSide, width ?? rect.width)
        var h = max(minimumSide, height ?? rect.height)
        if lockAspect, aspect > 0 {
            if width != nil { h = w / aspect } else if height != nil { w = h * aspect }
        }
        let room = CGSize(width: bounds.maxX - rect.minX, height: rect.maxY - bounds.minY)
        if lockAspect, aspect > 0 {
            // Shrink both sides together so the ratio survives.
            let scale = min(1, room.width / w, room.height / h)
            w *= scale
            h *= scale
        } else {
            w = min(w, room.width)
            h = min(h, room.height)
        }
        return CGRect(x: rect.minX, y: rect.maxY - h, width: w, height: h)
    }

    /// The largest rectangle with the given aspect ratio that starts at `anchor`, heads toward `point`,
    /// and stays inside `bounds`.
    private static func aspectRect(anchor: CGPoint, toward point: CGPoint, aspect: CGFloat, within bounds: CGRect) -> CGRect {
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        var w = abs(dx), h = abs(dy)
        if w / aspect > h { h = w / aspect } else { w = h * aspect }

        let signX: CGFloat = dx >= 0 ? 1 : -1
        let signY: CGFloat = dy >= 0 ? 1 : -1
        let roomW = signX > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
        let roomH = signY > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
        if w > 0, h > 0 {
            let scale = min(1, roomW / w, roomH / h)
            w *= scale
            h *= scale
        }
        return CGRect(x: signX > 0 ? anchor.x : anchor.x - w, y: signY > 0 ? anchor.y : anchor.y - h, width: w, height: h)
    }
}
