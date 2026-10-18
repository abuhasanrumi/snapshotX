import AVFoundation
import SwiftUI

/// Draws the whole, uncropped frame with a draggable rectangle on top, for choosing which part of a recording to keep.
struct StudioCropEditor: View {
    let image: CGImage?
    @Binding var crop: ZoomCamera.Crop
    /// Width over height of the kept area in pixels, or nil for free-form.
    var lockedAspect: Double?

    @State private var origin: ZoomCamera.Crop?

    private enum Handle { case move, topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right }

    var body: some View {
        GeometryReader { geo in
            let fit = fitted(in: geo.size)
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(decorative: image, scale: 1).resizable().frame(width: fit.width, height: fit.height)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.3)).frame(width: fit.width, height: fit.height)
                }
                let rect = CGRect(x: crop.x * fit.width, y: crop.y * fit.height, width: crop.width * fit.width, height: crop.height * fit.height)
                // Dim everything outside the kept area.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: fit))
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Rectangle().stroke(Color.white, lineWidth: 1.5).frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
                Rectangle().fill(Color.white.opacity(0.001)).frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                    .gesture(drag(.move, size: fit))
                handle(.topLeft, at: CGPoint(x: rect.minX, y: rect.minY), size: fit)
                handle(.topRight, at: CGPoint(x: rect.maxX, y: rect.minY), size: fit)
                handle(.bottomLeft, at: CGPoint(x: rect.minX, y: rect.maxY), size: fit)
                handle(.bottomRight, at: CGPoint(x: rect.maxX, y: rect.maxY), size: fit)
                handle(.top, at: CGPoint(x: rect.midX, y: rect.minY), size: fit)
                handle(.bottom, at: CGPoint(x: rect.midX, y: rect.maxY), size: fit)
                handle(.left, at: CGPoint(x: rect.minX, y: rect.midY), size: fit)
                handle(.right, at: CGPoint(x: rect.maxX, y: rect.midY), size: fit)
            }
            .frame(width: fit.width, height: fit.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fitted(in available: CGSize) -> CGSize {
        let aspect = image.map { CGFloat($0.width) / CGFloat($0.height) } ?? 16.0 / 9.0
        let width = min(available.width, available.height * aspect)
        return CGSize(width: max(1, width), height: max(1, width / aspect))
    }

    private func handle(_ kind: Handle, at point: CGPoint, size: CGSize) -> some View {
        Circle().fill(Color.white).overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
            .frame(width: 12, height: 12)
            .padding(8)
            .contentShape(Rectangle())
            .offset(x: point.x - 14, y: point.y - 14)
            .gesture(drag(kind, size: size))
    }

    private func drag(_ kind: Handle, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if origin == nil { origin = crop }
                guard let start = origin else { return }
                crop = Self.resize(start, kind: kind, dx: Double(value.translation.width / size.width),
                                   dy: Double(value.translation.height / size.height),
                                   aspect: lockedAspect.map { $0 * Double(size.height / size.width) })
            }
            .onEnded { _ in origin = nil }
    }

    /// `aspect` here is width over height in normalized units (so it already accounts for the picture's own shape).
    private static func resize(_ start: ZoomCamera.Crop, kind: Handle, dx: Double, dy: Double, aspect: Double?) -> ZoomCamera.Crop {
        var left = start.x, top = start.y, right = start.x + start.width, bottom = start.y + start.height
        let minimum = 0.05
        switch kind {
        case .move:
            let x = min(max(0, start.x + dx), 1 - start.width), y = min(max(0, start.y + dy), 1 - start.height)
            return ZoomCamera.Crop(x: x, y: y, width: start.width, height: start.height)
        case .left: left += dx
        case .right: right += dx
        case .top: top += dy
        case .bottom: bottom += dy
        case .topLeft: left += dx; top += dy
        case .topRight: right += dx; top += dy
        case .bottomLeft: left += dx; bottom += dy
        case .bottomRight: right += dx; bottom += dy
        }
        left = min(max(0, left), right - minimum); right = min(max(left + minimum, right), 1)
        top = min(max(0, top), bottom - minimum); bottom = min(max(top + minimum, bottom), 1)
        var result = ZoomCamera.Crop(x: left, y: top, width: right - left, height: bottom - top)
        if let aspect {
            // Keep the ratio by following the side that moved more, anchored on the opposite corner or edge.
            let height = result.width / aspect
            let anchoredTop = [.bottom, .bottomLeft, .bottomRight, .left, .right].contains(where: { $0 == kind }) ? start.y : start.y + start.height - height
            result.height = min(height, 1)
            result.width = result.height * aspect
            result.y = kind == .top || kind == .topLeft || kind == .topRight ? start.y + start.height - result.height : anchoredTop
            result.x = kind == .left || kind == .topLeft || kind == .bottomLeft ? start.x + start.width - result.width : start.x
            result = result.clamped(minimum: minimum)
        }
        return result
    }

    /// The largest crop of the given pixel aspect that fits in the picture, centered on `around`.
    static func crop(aspect: Double, imageAspect: Double, around: ZoomCamera.Crop) -> ZoomCamera.Crop {
        let target = aspect / imageAspect // normalized width over height
        var width = min(1, target), height = min(1, 1 / target)
        if width / height > target { width = height * target } else { height = width / target }
        let cx = around.x + around.width / 2, cy = around.y + around.height / 2
        return ZoomCamera.Crop(x: cx - width / 2, y: cy - height / 2, width: width, height: height).clamped()
    }
}

extension StudioDocument {
    /// The uncropped frame at the playhead, for the crop editor.
    func fullFrame() async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        return try? await generator.image(at: CMTime(seconds: currentTime, preferredTimescale: 600)).image
    }
}
