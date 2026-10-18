import AppKit
import CoreGraphics
import CoreImage
import ImageIO

/// Caches the expensive parts of rendering: blurred and pixelated regions, and background images.
final class EffectCache {
    private struct RegionKey: Hashable {
        var x: Int, y: Int, w: Int, h: Int
        var pixelate: Bool
    }

    private var regions: [RegionKey: CGImage] = [:]
    private var backgrounds: [String: CGImage] = [:]
    private let context = CIContext()

    /// A blurred or pixelated copy of the part of `base` under `rect`, plus the rect it covers.
    func region(of base: CGImage, rect: CGRect, pixelate: Bool) -> (image: CGImage, rect: CGRect)? {
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let r = rect.intersection(bounds).integral.intersection(bounds)
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }

        let key = RegionKey(x: Int(r.minX), y: Int(r.minY), w: Int(r.width), h: Int(r.height), pixelate: pixelate)
        if let cached = regions[key] { return (cached, r) }

        let ciRect = CGRect(x: r.minX, y: CGFloat(base.height) - r.maxY, width: r.width, height: r.height)
        let source = CIImage(cgImage: base).clampedToExtent()
        let maxDimension = CGFloat(max(base.width, base.height))
        let processed: CIImage
        if pixelate {
            processed = source.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: max(10, maxDimension * 0.014),
                kCIInputCenterKey: CIVector(x: ciRect.minX, y: ciRect.minY),
            ])
        } else {
            processed = source.applyingGaussianBlur(sigma: Double(max(14, maxDimension * 0.016)))
        }
        guard let output = context.createCGImage(processed.cropped(to: ciRect), from: ciRect) else { return nil }

        if regions.count > 48 { regions.removeAll() }
        regions[key] = output
        return (output, r)
    }

    func backgroundImage(path: String) -> CGImage? {
        if let cached = backgrounds[path] { return cached }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        backgrounds[path] = image
        return image
    }
}

/// How the final picture is laid out: the crop, the canvas, and where the screenshot sits on it.
struct CompositeGeometry: Equatable {
    var canvasSize: CGSize
    /// Where the (cropped) screenshot sits in canvas coordinates.
    var contentRect: CGRect
    /// The part of the original image that is shown, in image coordinates.
    var crop: CGRect
    var cornerRadius: CGFloat
    var hasBackground: Bool

    func canvasPoint(fromImage p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - crop.minX + contentRect.minX, y: p.y - crop.minY + contentRect.minY)
    }

    func imagePoint(fromCanvas p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - contentRect.minX + crop.minX, y: p.y - contentRect.minY + crop.minY)
    }
}

/// The one drawing path. The editor canvas and the exported file both come from `render`, so they match.
enum Renderer {
    static func geometry(imageSize: CGSize, state: EditorState, ignoreCropAndBackground: Bool = false) -> CompositeGeometry {
        let full = CGRect(origin: .zero, size: imageSize)
        var crop = full
        if !ignoreCropAndBackground, let requested = state.crop {
            let clipped = requested.intersection(full).integral.intersection(full)
            if !clipped.isNull, clipped.width >= 1, clipped.height >= 1 { crop = clipped }
        }

        guard !ignoreCropAndBackground, state.background.enabled else {
            return CompositeGeometry(canvasSize: crop.size, contentRect: CGRect(origin: .zero, size: crop.size),
                                     crop: crop, cornerRadius: 0, hasBackground: false)
        }
        let layout = BackgroundLayout.compute(contentSize: crop.size, style: state.background)
        let radius = CGFloat(state.background.cornerRadius) * min(crop.width, crop.height)
        return CompositeGeometry(canvasSize: layout.canvas, contentRect: layout.content, crop: crop,
                                 cornerRadius: radius, hasBackground: true)
    }

    /// Flattens the edit to a bitmap at its natural resolution.
    static func export(base: CGImage, state: EditorState, cache: EffectCache = EffectCache()) -> CGImage? {
        render(base: base, state: state, scale: 1, cache: cache)
    }

    /// Renders the edit into a bitmap. `scale` is bitmap pixels per canvas pixel.
    static func render(base: CGImage, state: EditorState, scale: CGFloat, ignoreCropAndBackground: Bool = false,
                       hiding hiddenID: UUID? = nil, cache: EffectCache) -> CGImage? {
        let geo = geometry(imageSize: CGSize(width: base.width, height: base.height), state: state,
                           ignoreCropAndBackground: ignoreCropAndBackground)
        let width = max(1, Int((geo.canvasSize.width * scale).rounded()))
        let height = max(1, Int((geo.canvasSize.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        // Work in canvas pixels with a top-left origin.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(width) / geo.canvasSize.width, y: -CGFloat(height) / geo.canvasSize.height)

        if geo.hasBackground {
            drawBackground(in: ctx, style: state.background, canvas: CGRect(origin: .zero, size: geo.canvasSize), space: space, cache: cache)
        }

        let content = geo.contentRect
        let radius = min(geo.cornerRadius, min(content.width, content.height) / 2)
        let contentPath = CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if geo.hasBackground, state.background.shadow > 0 {
            let strength = CGFloat(state.background.shadow)
            let blur = min(content.width, content.height) * 0.06 * strength
            ctx.saveGState()
            // Shadow offsets live in device space, so convert from canvas pixels.
            let deviceScale = CGFloat(width) / geo.canvasSize.width
            ctx.setShadow(offset: CGSize(width: 0, height: -blur * 0.5 * deviceScale), blur: blur * deviceScale,
                          color: CGColor(gray: 0, alpha: 0.45 * strength))
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.addPath(contentPath)
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(contentPath)
        ctx.clip()
        ctx.translateBy(x: content.minX - geo.crop.minX, y: content.minY - geo.crop.minY)
        drawImage(base, annotations: state.annotations, hiding: hiddenID, in: ctx, cache: cache)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    // MARK: Background

    static func drawBackground(in ctx: CGContext, style: BackgroundStyle, canvas: CGRect, space: CGColorSpace, cache: EffectCache) {
        switch style.fill {
        case .solid(let color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(canvas)
        case .gradient(let spec):
            guard let gradient = CGGradient(colorsSpace: space, colors: spec.colors.map(\.cgColor) as CFArray, locations: nil) else { return }
            let radians = spec.angle * .pi / 180
            let direction = CGVector(dx: sin(radians), dy: -cos(radians))
            let halfLength = (abs(canvas.width * direction.dx) + abs(canvas.height * direction.dy)) / 2
            let center = CGPoint(x: canvas.midX, y: canvas.midY)
            ctx.saveGState()
            ctx.clip(to: canvas)
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: center.x - direction.dx * halfLength, y: center.y - direction.dy * halfLength),
                                   end: CGPoint(x: center.x + direction.dx * halfLength, y: center.y + direction.dy * halfLength),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        case .image(let path):
            guard let image = cache.backgroundImage(path: path) else { return }
            // Aspect fill, centered.
            let scale = max(canvas.width / CGFloat(image.width), canvas.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            ctx.saveGState()
            ctx.clip(to: canvas)
            drawUpright(image, in: CGRect(x: canvas.midX - size.width / 2, y: canvas.midY - size.height / 2,
                                          width: size.width, height: size.height), ctx: ctx)
            ctx.restoreGState()
        }
    }

    // MARK: Screenshot and annotations (image coordinates)

    private static func drawImage(_ base: CGImage, annotations: [Annotation], hiding hiddenID: UUID?,
                                  in ctx: CGContext, cache: EffectCache) {
        let imageRect = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        drawUpright(base, in: imageRect, ctx: ctx)

        let visible = annotations.filter { $0.id != hiddenID }

        // Spotlights share one dim layer with a hole per spotlight.
        let spotlights: [CGRect] = visible.compactMap {
            if case .spotlight(let rect) = $0.kind { return rect }
            return nil
        }
        if !spotlights.isEmpty {
            let path = CGMutablePath()
            path.addRect(imageRect)
            for rect in spotlights { path.addRoundedRect(in: rect, cornerWidth: 6, cornerHeight: 6) }
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }

        for annotation in visible { draw(annotation, in: ctx, base: base, cache: cache) }
    }

    private static func draw(_ a: Annotation, in ctx: CGContext, base: CGImage, cache: EffectCache) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let color = a.color.cgColor
        let width = CGFloat(a.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.kind {
        case .line(let s, let e):
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            ctx.move(to: s)
            ctx.addLine(to: e)
            ctx.strokePath()

        case .arrow(let s, let e):
            let length = hypot(e.x - s.x, e.y - s.y)
            guard length > 0 else { return }
            let head = min(max(width * 3.4, 16), length)
            let ux = (e.x - s.x) / length, uy = (e.y - s.y) / length
            let shaftEnd = CGPoint(x: e.x - ux * head * 0.8, y: e.y - uy * head * 0.8)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            ctx.move(to: s)
            ctx.addLine(to: shaftEnd)
            ctx.strokePath()

            let baseCenter = CGPoint(x: e.x - ux * head, y: e.y - uy * head)
            let half = head * 0.45
            ctx.setFillColor(color)
            ctx.move(to: e)
            ctx.addLine(to: CGPoint(x: baseCenter.x - uy * half, y: baseCenter.y + ux * half))
            ctx.addLine(to: CGPoint(x: baseCenter.x + uy * half, y: baseCenter.y - ux * half))
            ctx.closePath()
            ctx.fillPath()

        case .rectangle(let rect, let filled):
            if filled {
                ctx.setFillColor(color)
                ctx.fill(rect)
            } else {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(width)
                ctx.stroke(rect)
            }

        case .ellipse(let rect, let filled):
            if filled {
                ctx.setFillColor(color)
                ctx.fillEllipse(in: rect)
            } else {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(width)
                ctx.strokeEllipse(in: rect)
            }

        case .pencil(let points):
            strokePath(points, color: color, width: width, in: ctx)

        case .highlighter(let points):
            ctx.setBlendMode(.multiply)
            strokePath(points, color: a.color.with(alpha: 0.45).cgColor, width: CGFloat(a.strokeWidthForHitTesting), in: ctx)

        case .text(let origin, let string):
            guard !string.isEmpty else { return }
            let style = a.textStyle
            var attributes: [NSAttributedString.Key: Any] = [.font: TextMetrics.font(size: a.fontSize, style: style), .foregroundColor: a.color.nsColor]
            let pad = TextMetrics.padding(style: style, fontSize: a.fontSize)
            switch style {
            case .outline:
                // A negative stroke width draws the outline and keeps the fill. The edge uses the opposite brightness.
                attributes[.strokeColor] = TextMetrics.contrast(for: a.color)
                attributes[.strokeWidth] = -9
            case .label:
                let box = CGRect(origin: origin, size: TextMetrics.size(of: string, fontSize: a.fontSize, style: style))
                ctx.setFillColor(color)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: a.fontSize * 0.28, cornerHeight: a.fontSize * 0.28, transform: nil))
                ctx.fillPath()
                attributes[.foregroundColor] = TextMetrics.contrast(for: a.color)
            default:
                break
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSAttributedString(string: string, attributes: attributes).draw(at: CGPoint(x: origin.x + pad.width, y: origin.y + pad.height))
            NSGraphicsContext.restoreGraphicsState()

        case .counter(let center, let number):
            let radius = a.counterRadius
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            let textColor: NSColor = a.color.luminance > 0.62 ? .black : .white
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: radius * 1.05, weight: .bold), .foregroundColor: textColor,
            ]
            let label = NSAttributedString(string: "\(number)", attributes: attributes)
            let size = label.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
            NSGraphicsContext.restoreGraphicsState()

        case .blur(let rect):
            if let region = cache.region(of: base, rect: rect, pixelate: false) { drawUpright(region.image, in: region.rect, ctx: ctx) }

        case .pixelate(let rect):
            if let region = cache.region(of: base, rect: rect, pixelate: true) { drawUpright(region.image, in: region.rect, ctx: ctx) }

        case .spotlight:
            break // drawn once for all spotlights
        }
    }

    private static func strokePath(_ points: [CGPoint], color: CGColor, width: CGFloat, in ctx: CGContext) {
        guard let first = points.first else { return }
        if points.count == 1 {
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
            return
        }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.addLines(between: points)
        ctx.strokePath()
    }

    /// `CGContext.draw` assumes a bottom-left origin, so images need a local flip in our top-left space.
    private static func drawUpright(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }
}
