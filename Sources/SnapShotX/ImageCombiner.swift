import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// Joins several images into one, side by side or stacked.
enum ImageCombiner {
    enum Axis: String, CaseIterable, Identifiable {
        case vertical, horizontal
        var id: String { rawValue }
        var title: String { self == .vertical ? "Stacked, top to bottom" : "Side by side, left to right" }
    }

    /// Everything is scaled to match the first image (its width when stacking, its height side by side), so the
    /// first image keeps its sharpness and the others fit it. `spacing` is in pixels, filled with transparency.
    static func combine(_ images: [CGImage], axis: Axis, spacing: Int = 0) -> CGImage? {
        guard let first = images.first else { return nil }
        guard images.count > 1 else { return first }

        // Size of each image after scaling to the reference.
        let sizes: [CGSize] = images.map { image in
            switch axis {
            case .vertical:
                let scale = CGFloat(first.width) / CGFloat(image.width)
                return CGSize(width: CGFloat(first.width), height: max(1, (CGFloat(image.height) * scale).rounded()))
            case .horizontal:
                let scale = CGFloat(first.height) / CGFloat(image.height)
                return CGSize(width: max(1, (CGFloat(image.width) * scale).rounded()), height: CGFloat(first.height))
            }
        }
        let gap = CGFloat(max(0, spacing)) * CGFloat(images.count - 1)
        let total = axis == .vertical
            ? CGSize(width: CGFloat(first.width), height: sizes.reduce(0) { $0 + $1.height } + gap)
            : CGSize(width: sizes.reduce(0) { $0 + $1.width } + gap, height: CGFloat(first.height))
        guard total.width <= 30_000, total.height <= 60_000,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(total.width), height: Int(total.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high

        var cursor: CGFloat = 0
        for (image, size) in zip(images, sizes) {
            // CGContext's origin is bottom-left; the first image goes at the top (or left).
            let rect: CGRect = axis == .vertical
                ? CGRect(x: 0, y: total.height - cursor - size.height, width: size.width, height: size.height)
                : CGRect(x: cursor, y: 0, width: size.width, height: size.height)
            ctx.draw(image, in: rect)
            cursor += (axis == .vertical ? size.height : size.width) + CGFloat(max(0, spacing))
        }
        return ctx.makeImage()
    }

    /// Reads dropped file URLs (or images) from drag-and-drop providers, keeping the order they were dropped in.
    static func loadImages(from providers: [NSItemProvider], completion: @escaping @MainActor ([CGImage]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [(Int, CGImage)] = []
        for (index, provider) in providers.enumerated() where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let u = item as? URL { url = u }
                guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
                lock.lock(); found.append((index, image)); lock.unlock()
            }
        }
        group.notify(queue: .main) {
            let images = found.sorted { $0.0 < $1.0 }.map(\.1)
            MainActor.assumeIsolated { completion(images) }
        }
    }
}
