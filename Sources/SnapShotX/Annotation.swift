import AppKit
import CoreGraphics

struct RGBAColor: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255,
                  b: Double(hex & 0xFF) / 255, a: alpha)
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    func with(alpha: Double) -> RGBAColor { RGBAColor(r: r, g: g, b: b, a: alpha) }

    static let red = RGBAColor(hex: 0xFF3B30)
    static let palette: [RGBAColor] = [
        .red, RGBAColor(hex: 0xFF9500), RGBAColor(hex: 0xFFCC00), RGBAColor(hex: 0x34C759),
        RGBAColor(hex: 0x0A84FF), RGBAColor(hex: 0xAF52DE), RGBAColor(hex: 0xFFFFFF), RGBAColor(hex: 0x1C1C1E),
    ]
}

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, crop, arrow, line, rectangle, filledRectangle, ellipse
    case pencil, highlighter, text, counter, spotlight, blur, pixelate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .crop: return "Crop"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .filledRectangle: return "Filled Rectangle"
        case .ellipse: return "Ellipse"
        case .pencil: return "Pencil"
        case .highlighter: return "Highlighter"
        case .text: return "Text"
        case .counter: return "Counter"
        case .spotlight: return "Spotlight"
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .crop: return "crop"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .filledRectangle: return "rectangle.fill"
        case .ellipse: return "circle"
        case .pencil: return "pencil"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .spotlight: return "sun.max"
        case .blur: return "drop"
        case .pixelate: return "squareshape.split.3x3"
        }
    }
}

/// Shape data, in image pixel coordinates with a top-left origin.
enum AnnotationKind: Codable, Equatable {
    case arrow(start: CGPoint, end: CGPoint)
    case line(start: CGPoint, end: CGPoint)
    case rectangle(rect: CGRect, filled: Bool)
    case ellipse(rect: CGRect, filled: Bool)
    case pencil(points: [CGPoint])
    case highlighter(points: [CGPoint])
    case text(origin: CGPoint, string: String)
    case counter(center: CGPoint, number: Int)
    case spotlight(rect: CGRect)
    case blur(rect: CGRect)
    case pixelate(rect: CGRect)
}

enum HandleID: Hashable {
    case start, end, topLeft, topRight, bottomLeft, bottomRight
}

struct Annotation: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: AnnotationKind
    var color: RGBAColor
    /// Stroke width in image pixels.
    var lineWidth: Double
    /// Text size in image pixels. Also sets the radius of counters.
    var fontSize: Double
}

// MARK: - Geometry

enum TextMetrics {
    static func font(size: Double) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }

    static func size(of string: String, fontSize: Double) -> CGSize {
        let text = (string.isEmpty ? " " : string) as NSString
        let rect = text.boundingRect(with: CGSize(width: 10_000, height: 10_000),
                                     options: [.usesLineFragmentOrigin],
                                     attributes: [.font: font(size: fontSize)])
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }
}

func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

extension AnnotationKind {
    func translated(by d: CGVector) -> AnnotationKind {
        func p(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + d.dx, y: point.y + d.dy) }
        func r(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: d.dx, dy: d.dy) }
        switch self {
        case .arrow(let s, let e): return .arrow(start: p(s), end: p(e))
        case .line(let s, let e): return .line(start: p(s), end: p(e))
        case .rectangle(let rect, let filled): return .rectangle(rect: r(rect), filled: filled)
        case .ellipse(let rect, let filled): return .ellipse(rect: r(rect), filled: filled)
        case .pencil(let pts): return .pencil(points: pts.map(p))
        case .highlighter(let pts): return .highlighter(points: pts.map(p))
        case .text(let o, let s): return .text(origin: p(o), string: s)
        case .counter(let c, let n): return .counter(center: p(c), number: n)
        case .spotlight(let rect): return .spotlight(rect: r(rect))
        case .blur(let rect): return .blur(rect: r(rect))
        case .pixelate(let rect): return .pixelate(rect: r(rect))
        }
    }
}

extension Annotation {
    static let highlighterWidthFactor: Double = 5

    var counterRadius: CGFloat { CGFloat(fontSize) * 0.9 }

    var strokeWidthForHitTesting: CGFloat {
        if case .highlighter = kind { return CGFloat(lineWidth * Self.highlighterWidthFactor) }
        return CGFloat(lineWidth)
    }

    var bounds: CGRect {
        let pad = CGFloat(lineWidth) / 2
        switch kind {
        case .arrow(let s, let e), .line(let s, let e):
            return Geometry.normalizedRect(from: s, to: e).insetBy(dx: -max(pad, CGFloat(lineWidth) * 3), dy: -max(pad, CGFloat(lineWidth) * 3))
        case .rectangle(let rect, _), .ellipse(let rect, _):
            return rect.insetBy(dx: -pad, dy: -pad)
        case .spotlight(let rect), .blur(let rect), .pixelate(let rect):
            return rect
        case .pencil(let pts), .highlighter(let pts):
            let outset = strokeWidthForHitTesting / 2
            guard let first = pts.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in pts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -outset, dy: -outset)
        case .text(let origin, let string):
            return CGRect(origin: origin, size: TextMetrics.size(of: string, fontSize: fontSize))
        case .counter(let center, _):
            let r = counterRadius
            return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let half = CGFloat(lineWidth) / 2 + tolerance
        switch kind {
        case .arrow(let s, let e), .line(let s, let e):
            return distance(from: point, toSegment: s, e) <= half
        case .rectangle(let rect, let filled):
            if filled { return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
            let outer = rect.insetBy(dx: -half, dy: -half)
            let inner = rect.insetBy(dx: half, dy: half)
            return outer.contains(point) && !(inner.width > 0 && inner.height > 0 && inner.contains(point))
        case .ellipse(let rect, let filled):
            guard rect.width > 0, rect.height > 0 else { return false }
            let a = rect.width / 2, b = rect.height / 2
            let nx = (point.x - rect.midX) / a, ny = (point.y - rect.midY) / b
            let radial = sqrt(nx * nx + ny * ny)
            if filled { return radial <= 1 + tolerance / min(a, b) }
            return abs(radial - 1) * min(a, b) <= half
        case .pencil(let pts), .highlighter(let pts):
            let reach = strokeWidthForHitTesting / 2 + tolerance
            guard pts.count > 1 else { return pts.first.map { hypot(point.x - $0.x, point.y - $0.y) <= reach } ?? false }
            for i in 0..<(pts.count - 1) where distance(from: point, toSegment: pts[i], pts[i + 1]) <= reach { return true }
            return false
        case .text, .counter:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .spotlight(let rect), .blur(let rect), .pixelate(let rect):
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    func translated(by delta: CGVector) -> Annotation {
        var copy = self
        copy.kind = kind.translated(by: delta)
        return copy
    }

    /// Handles the user can drag to reshape the annotation.
    var handles: [(id: HandleID, point: CGPoint)] {
        switch kind {
        case .arrow(let s, let e), .line(let s, let e):
            return [(.start, s), (.end, e)]
        case .rectangle(let rect, _), .ellipse(let rect, _), .spotlight(let rect), .blur(let rect), .pixelate(let rect):
            return [(.topLeft, CGPoint(x: rect.minX, y: rect.minY)), (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
                    (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)), (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))]
        default:
            return []
        }
    }

    func resized(handle: HandleID, to point: CGPoint) -> Annotation {
        var copy = self
        func reshape(_ rect: CGRect) -> CGRect {
            let opposite: CGPoint
            switch handle {
            case .topLeft: opposite = CGPoint(x: rect.maxX, y: rect.maxY)
            case .topRight: opposite = CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomLeft: opposite = CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomRight: opposite = CGPoint(x: rect.minX, y: rect.minY)
            default: return rect
            }
            return Geometry.normalizedRect(from: opposite, to: point)
        }
        switch kind {
        case .arrow(let s, let e):
            copy.kind = handle == .start ? .arrow(start: point, end: e) : .arrow(start: s, end: point)
        case .line(let s, let e):
            copy.kind = handle == .start ? .line(start: point, end: e) : .line(start: s, end: point)
        case .rectangle(let rect, let filled): copy.kind = .rectangle(rect: reshape(rect), filled: filled)
        case .ellipse(let rect, let filled): copy.kind = .ellipse(rect: reshape(rect), filled: filled)
        case .spotlight(let rect): copy.kind = .spotlight(rect: reshape(rect))
        case .blur(let rect): copy.kind = .blur(rect: reshape(rect))
        case .pixelate(let rect): copy.kind = .pixelate(rect: reshape(rect))
        default: break
        }
        return copy
    }
}

// MARK: - Pencil smoothing

enum PathSmoothing {
    /// Drops near-duplicate points, then rounds corners with Chaikin subdivision. End points are preserved.
    static func smooth(_ points: [CGPoint], minDistance: CGFloat = 2, iterations: Int = 2) -> [CGPoint] {
        var pts = decimate(points, minDistance: minDistance)
        guard pts.count > 2 else { return pts }
        for _ in 0..<iterations {
            var out = [pts[0]]
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                out.append(CGPoint(x: 0.75 * a.x + 0.25 * b.x, y: 0.75 * a.y + 0.25 * b.y))
                out.append(CGPoint(x: 0.25 * a.x + 0.75 * b.x, y: 0.25 * a.y + 0.75 * b.y))
            }
            out.append(pts[pts.count - 1])
            pts = out
        }
        return pts
    }

    static func decimate(_ points: [CGPoint], minDistance: CGFloat) -> [CGPoint] {
        guard var last = points.first else { return [] }
        var out = [last]
        for p in points.dropFirst() where hypot(p.x - last.x, p.y - last.y) >= minDistance {
            out.append(p)
            last = p
        }
        if let final = points.last, out.last != final { out.append(final) }
        return out
    }
}
