// Renders the SnapShotX app icon (light tile, blue capture corners, coral X) into an .iconset folder.
// Usage: swift scripts/make_icon.swift <output .iconset directory>
// scripts/make_icon.sh wraps this and runs iconutil to produce Resources/AppIcon.icns.
//
// Everything is drawn in a 1024-unit design space (top-left origin) and scaled per size. The tile
// occupies the 824-unit square inset 100 units from each edge, matching the macOS icon template.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func render(size: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let s = CGFloat(size) / 1024
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: s, y: -s)

    func gradient(_ a: UInt32, _ b: UInt32) -> CGGradient {
        CGGradient(colorsSpace: space, colors: [color(a), color(b)] as CFArray, locations: [0, 1])!
    }

    // Tile with a soft drop shadow. The shadow offset is in base space, so it is scaled by hand.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16 * s), blur: 36 * s, color: color(0x000000, 0.3))
    ctx.setFillColor(color(0xEEF1FC))
    ctx.addPath(tile)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.drawLinearGradient(gradient(0xFFFFFF, 0xDCE2F8), start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()

    // Hairline edge.
    ctx.setStrokeColor(color(0x12163A, 0.1))
    ctx.setLineWidth(2)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 101, y: 101, width: 822, height: 822),
                       cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.strokePath()

    // Capture corners.
    ctx.setStrokeColor(color(0x2848FF))
    ctx.setLineWidth(46)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let corners = CGMutablePath()
    corners.move(to: CGPoint(x: 270, y: 400))
    corners.addLine(to: CGPoint(x: 270, y: 330))
    corners.addQuadCurve(to: CGPoint(x: 330, y: 270), control: CGPoint(x: 270, y: 270))
    corners.addLine(to: CGPoint(x: 400, y: 270))

    corners.move(to: CGPoint(x: 624, y: 270))
    corners.addLine(to: CGPoint(x: 694, y: 270))
    corners.addQuadCurve(to: CGPoint(x: 754, y: 330), control: CGPoint(x: 754, y: 270))
    corners.addLine(to: CGPoint(x: 754, y: 400))

    corners.move(to: CGPoint(x: 270, y: 624))
    corners.addLine(to: CGPoint(x: 270, y: 694))
    corners.addQuadCurve(to: CGPoint(x: 330, y: 754), control: CGPoint(x: 270, y: 754))
    corners.addLine(to: CGPoint(x: 400, y: 754))

    corners.move(to: CGPoint(x: 624, y: 754))
    corners.addLine(to: CGPoint(x: 694, y: 754))
    corners.addQuadCurve(to: CGPoint(x: 754, y: 694), control: CGPoint(x: 754, y: 754))
    corners.addLine(to: CGPoint(x: 754, y: 624))
    ctx.addPath(corners)
    ctx.strokePath()

    // The X: stroke outline used as a clip so one vertical gradient covers both strokes.
    ctx.saveGState()
    ctx.setLineWidth(64)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 402, y: 402))
    ctx.addLine(to: CGPoint(x: 622, y: 622))
    ctx.move(to: CGPoint(x: 622, y: 402))
    ctx.addLine(to: CGPoint(x: 402, y: 622))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient(0xFF5C7A, 0xFF9A3D), start: CGPoint(x: 512, y: 402), end: CGPoint(x: 512, y: 622),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot create \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make_icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let files: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in files {
    writePNG(render(size: size), to: output.appendingPathComponent(name))
}
print("Wrote \(files.count) images to \(output.path)")
