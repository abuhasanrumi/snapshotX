import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// Draws one frame of a Studio Mode video: the recording cropped to wherever the zoom camera is pointing,
/// placed on the background with rounded corners and a shadow, with the drawn cursor and click rings on top.
///
/// The live preview and the exported file both come from this one renderer, so what you see is what you get.
/// Everything that doesn't change from frame to frame (background, mask, shadow, cursor artwork) is built once.
final class StudioFrameRenderer: @unchecked Sendable {
    let project: StudioProject
    let cursor: CursorTrack?
    let layout: StudioLayout
    /// Seconds to add to a composition time to get the time in the original recording.
    let timeOffset: Double

    private let backdrop: CIImage
    private let mask: CIImage?
    private let clearCanvas: CIImage
    private let cursorSprite: Sprite
    private let ringSprite: Sprite
    private let renderRect: CGRect
    private let region: ZoomCamera.Crop

    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    /// How much larger than natural size the cursor artwork is drawn, so it stays sharp when zoomed in.
    private static let spriteOversample: CGFloat = 2
    /// Seconds a click ring takes to expand and fade.
    static let ringDuration = 0.5

    private struct Sprite {
        var image: CIImage
        /// The point that sits on the pointer position, in the image's own (bottom-left origin) coordinates.
        var anchor: CGPoint
    }

    init(project: StudioProject, cursor: CursorTrack?, sourceSize: CGSize, timeOffset: Double = 0) {
        self.project = project
        self.cursor = cursor
        self.timeOffset = timeOffset
        let region = project.crop?.clamped() ?? .full
        self.region = region
        let kept = CGSize(width: max(2, (sourceSize.width * region.width).rounded()), height: max(2, (sourceSize.height * region.height).rounded()))
        let layout = StudioLayout.make(sourceSize: kept, background: project.background, preset: project.preset)
        self.layout = layout
        let width = Int(layout.renderSize.width), height = Int(layout.renderSize.height)
        renderRect = CGRect(x: 0, y: 0, width: width, height: height)
        clearCanvas = CIImage(color: .clear).cropped(to: renderRect)

        let background = Self.bitmap(width: width, height: height) { ctx in
            if layout.hasBackground {
                Renderer.drawBackground(in: ctx, style: project.background, canvas: CGRect(x: 0, y: 0, width: width, height: height),
                                        space: Self.space, cache: EffectCache())
            } else {
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        var backdrop = CIImage(cgImage: background)

        if layout.hasBackground {
            let radius = min(layout.cornerRadius, min(layout.contentRect.width, layout.contentRect.height) / 2)
            let shape = Self.bitmap(width: width, height: height) { ctx in
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.addPath(CGPath(roundedRect: layout.contentRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.fillPath()
            }
            let maskImage = CIImage(cgImage: shape)
            mask = maskImage

            let strength = CGFloat(project.background.shadow)
            if strength > 0.001 {
                let blur = min(layout.contentRect.width, layout.contentRect.height) * 0.06 * strength
                let shadow = maskImage
                    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.45 * strength)])
                    .clampedToExtent()
                    .applyingGaussianBlur(sigma: Double(max(0.5, blur * 0.5)))
                    .transformed(by: CGAffineTransform(translationX: 0, y: -blur * 0.5))
                    .cropped(to: renderRect)
                backdrop = shadow.composited(over: backdrop)
            }
        } else {
            mask = nil
        }
        self.backdrop = backdrop

        let pixelsPerPoint = CGFloat(cursor?.pixelsPerPoint ?? 2)
        cursorSprite = Self.makeCursorSprite(naturalHeight: 22 * pixelsPerPoint, oversample: Self.spriteOversample)
        ringSprite = Self.makeRingSprite()
    }

    // MARK: Drawing a frame

    /// Renders the frame for `compositionTime` from `source` into `output`, which must be `layout.renderSize`.
    func render(source: CVPixelBuffer, at compositionTime: Double, into output: CVPixelBuffer) {
        let time = compositionTime + timeOffset
        let sourceWidth = CGFloat(CVPixelBufferGetWidth(source))
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(source))
        let crop = ZoomCamera.crop(at: time, zooms: project.zooms, cursor: cursor, smoothing: project.cursor.smoothing, region: region)

        // Core Image has a bottom-left origin, so rectangles that are top-left based get flipped here.
        let cropTop = CGRect(x: crop.x * sourceWidth, y: crop.y * sourceHeight, width: crop.width * sourceWidth, height: crop.height * sourceHeight)
        let ciCrop = CGRect(x: cropTop.minX, y: sourceHeight - cropTop.maxY, width: cropTop.width, height: cropTop.height)
        let content = layout.contentRect
        let ciContent = CGRect(x: content.minX, y: renderRect.height - content.maxY, width: content.width, height: content.height)
        let scaleX = ciContent.width / ciCrop.width
        let scaleY = ciContent.height / ciCrop.height

        var layer = CIImage(cvPixelBuffer: source)
            .cropped(to: ciCrop)
            .transformed(by: CGAffineTransform(translationX: -ciCrop.minX, y: -ciCrop.minY))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: ciContent.minX, y: ciContent.minY))

        // Where a point of the recording (normalized, top-left origin) lands in the output, in Core Image coordinates.
        func outputPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(x: ciContent.minX + (p.x - crop.x) / crop.width * ciContent.width,
                    y: ciContent.maxY - (p.y - crop.y) / crop.height * ciContent.height)
        }

        if project.cursor.visible, let track = cursor, !track.isEmpty {
            let pixelsPerPoint = CGFloat(track.pixelsPerPoint)

            if project.cursor.clickEffect {
                for click in track.clicks where time >= click.t && time - click.t <= Self.ringDuration {
                    let progress = (time - click.t) / Self.ringDuration
                    let diameter = 44 * pixelsPerPoint * scaleX * CGFloat(0.45 + 1.1 * progress)
                    let alpha = 0.9 * (1 - progress) * (1 - progress)
                    let ring = place(ringSprite, at: outputPoint(CGPoint(x: click.x, y: click.y)), scale: diameter / 128, alpha: alpha)
                    layer = ring.composited(over: layer)
                }
            }
            if let position = track.position(at: time, smoothing: project.cursor.smoothing) {
                let scale = scaleX * CGFloat(project.cursor.size) / Self.spriteOversample
                layer = place(cursorSprite, at: outputPoint(position), scale: scale, alpha: 1).composited(over: layer)
            }
        }

        if let mask {
            layer = layer.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: clearCanvas,
                kCIInputMaskImageKey: mask,
            ])
        }
        let frame = layer.composited(over: backdrop).cropped(to: renderRect)
        Self.context.render(frame, to: output, bounds: renderRect, colorSpace: Self.space)
    }

    private func place(_ sprite: Sprite, at target: CGPoint, scale: CGFloat, alpha: Double) -> CIImage {
        var image = sprite.image
        if alpha < 0.999 {
            image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))])
        }
        return image
            .transformed(by: CGAffineTransform(translationX: -sprite.anchor.x, y: -sprite.anchor.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: target.x, y: target.y))
    }

    // MARK: Artwork

    /// A bitmap drawn with a top-left origin, in pixels.
    private static func bitmap(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        draw(ctx)
        return ctx.makeImage()!
    }

    /// The pointer arrow: black with a white edge, tip at the top-left. 12 by 19 units, plus a margin.
    private static func makeCursorSprite(naturalHeight: CGFloat, oversample: CGFloat) -> Sprite {
        let unit = naturalHeight / 19 * oversample
        let margin: CGFloat = 2
        let width = Int(((12 + margin * 2) * unit).rounded(.up))
        let height = Int(((19 + margin * 2) * unit).rounded(.up))
        let image = bitmap(width: width, height: height) { ctx in
            let points: [(CGFloat, CGFloat)] = [(0, 0), (0, 16.5), (4, 12.8), (6.7, 18.7), (9.2, 17.6), (6.6, 11.8), (11.7, 11.8)]
            let path = CGMutablePath()
            for (index, point) in points.enumerated() {
                let p = CGPoint(x: (point.0 + margin) * unit, y: (point.1 + margin) * unit)
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            ctx.setLineJoin(.round)
            ctx.setLineWidth(2.4 * unit)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.addPath(path)
            ctx.strokePath()
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.addPath(path)
            ctx.fillPath()
        }
        // The tip is at (margin, margin) from the top-left, which is (margin, height - margin) from the bottom-left.
        return Sprite(image: CIImage(cgImage: image), anchor: CGPoint(x: margin * unit, y: CGFloat(height) - margin * unit))
    }

    private static func makeRingSprite() -> Sprite {
        let size = 128
        let image = bitmap(width: size, height: size) { ctx in
            let rect = CGRect(x: 6, y: 6, width: CGFloat(size) - 12, height: CGFloat(size) - 12)
            ctx.setFillColor(CGColor(red: 1, green: 0.8, blue: 0, alpha: 0.28))
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(CGColor(red: 1, green: 0.8, blue: 0, alpha: 1))
            ctx.setLineWidth(8)
            ctx.strokeEllipse(in: rect)
        }
        return Sprite(image: CIImage(cgImage: image), anchor: CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2))
    }
}
