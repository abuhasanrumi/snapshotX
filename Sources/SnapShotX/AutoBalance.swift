import AppKit
import CoreGraphics

/// Picks a background gradient that suits an image: two colors taken from opposite corners of the picture,
/// nudged so they stay pleasant behind it instead of muddy or glaring.
enum AutoBalance {
    static func gradient(for image: CGImage) -> GradientSpec {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return BackgroundCatalog.gradients[0].spec
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Memory order is top row first. Split along the diagonal: one color from each half.
        var sums = [[Double]](repeating: [0, 0, 0, 0], count: 2)
        for y in 0..<side {
            for x in 0..<side {
                let p = (y * side + x) * 4
                let r = Double(pixels[p]) / 255, g = Double(pixels[p + 1]) / 255, b = Double(pixels[p + 2]) / 255
                let color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
                // Colorful pixels count for more, so a mostly white page still yields its accent color.
                let weight = 0.15 + Double(color.saturationComponent)
                let half = x + y < side ? 0 : 1
                sums[half][0] += r * weight; sums[half][1] += g * weight; sums[half][2] += b * weight; sums[half][3] += weight
            }
        }
        let colors = sums.map { s -> RGBAColor in
            let base = NSColor(srgbRed: s[0] / s[3], green: s[1] / s[3], blue: s[2] / s[3], alpha: 1)
            return balanced(base)
        }
        return GradientSpec(colors: colors, angle: 135)
    }

    /// Keeps hue, lifts saturation a little and holds brightness in a comfortable range.
    static func balanced(_ color: NSColor) -> RGBAColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (color.usingColorSpace(.sRGB) ?? color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let saturation = s < 0.08 ? s : min(0.85, max(0.4, s * 1.2 + 0.1)) // leave grays gray
        let brightness = min(0.92, max(0.35, b))
        let out = NSColor(hue: h, saturation: saturation, brightness: brightness, alpha: 1).usingColorSpace(.sRGB) ?? color
        return RGBAColor(r: Double(out.redComponent), g: Double(out.greenComponent), b: Double(out.blueComponent), a: 1)
    }
}
