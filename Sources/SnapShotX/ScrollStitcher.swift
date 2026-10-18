import CoreGraphics

/// A frame reduced to grayscale with a fixed number of columns. Rows stay at full resolution so
/// vertical offsets can be measured to the pixel.
struct GrayFrame {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init?(image: CGImage, columns: Int = 96) {
        let w = min(columns, image.width)
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: w * h)
        let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }
        self.init(width: w, height: h, pixels: buffer)
    }

    /// Sum of absolute differences between a row here and a row in another frame.
    func difference(row: Int, with other: GrayFrame, row otherRow: Int) -> Int {
        let a = row * width, b = otherRow * other.width
        var total = 0
        for x in 0..<width { total += abs(Int(pixels[a + x]) - Int(other.pixels[b + x])) }
        return total
    }

    /// A hash of the row's coarsely quantized pixels, and whether the row has enough contrast to identify it.
    func signature(row: Int) -> (hash: UInt64, informative: Bool) {
        var hash: UInt64 = 14_695_981_039_346_656_037
        var low: UInt8 = 255, high: UInt8 = 0
        let start = row * width
        for x in 0..<width {
            let v = pixels[start + x]
            low = min(low, v)
            high = max(high, v)
            hash = (hash ^ UInt64(v >> 3)) &* 1_099_511_628_211
        }
        return (hash, Int(high) - Int(low) >= 24)
    }
}

/// Measures how far the content moved between two frames of the same screen region.
enum ShiftEstimator {
    enum Result: Equatable {
        /// Nothing moved.
        case unchanged
        /// Positive: the content scrolled down, so new content appeared at the bottom. Negative: it scrolled up.
        case shift(Int)
        /// No offset explains the change (scrolled too far, or the content itself changed).
        case none
    }

    /// Mean difference per pixel below which two rows count as the same row.
    static let rowTolerance = 6

    static func estimate(from previous: GrayFrame, to new: GrayFrame) -> Result {
        guard previous.width == new.width, previous.height == new.height else { return .none }
        let h = previous.height, w = previous.width
        let tolerance = rowTolerance * w

        var identical = 0
        for y in 0..<h where previous.difference(row: y, with: new, row: y) <= w { identical += 1 }
        if identical * 100 >= h * 98 { return .unchanged }

        // Index the previous frame's distinctive rows by signature.
        var index: [UInt64: [Int]] = [:]
        for y in 0..<h {
            let s = previous.signature(row: y)
            guard s.informative, (index[s.hash]?.count ?? 0) < 4 else { continue }
            index[s.hash, default: []].append(y)
        }

        // Each distinctive row in the new frame votes for the shift that would line it up.
        var newInformative = [Bool](repeating: false, count: h)
        var votes: [Int: Int] = [:]
        for r in 0..<h {
            let s = new.signature(row: r)
            newInformative[r] = s.informative
            guard s.informative, let rows = index[s.hash] else { continue }
            for p in rows where p != r { votes[p - r, default: 0] += 1 }
        }

        let minimumOverlap = max(24, h / 10)
        var best: (shift: Int, matched: Int)?
        let candidates = votes.filter { $0.value >= 3 }.sorted { $0.value > $1.value }.prefix(5)
        for (shift, _) in candidates {
            guard h - abs(shift) >= minimumOverlap else { continue }
            var matched = 0, informative = 0
            for r in 0..<h where newInformative[r] {
                let p = r + shift
                guard p >= 0, p < h else { continue }
                informative += 1
                if previous.difference(row: p, with: new, row: r) <= tolerance { matched += 1 }
            }
            guard informative >= 3, matched >= 3, matched * 100 >= informative * 60 else { continue }
            if let current = best {
                if matched > current.matched || (matched == current.matched && abs(shift) < abs(current.shift)) {
                    best = (shift, matched)
                }
            } else {
                best = (shift, matched)
            }
        }
        return best.map { .shift($0.shift) } ?? .none
    }
}

/// Builds one tall image from frames taken while the content scrolls underneath a fixed region.
/// Tracks where each frame sits on the page, so scrolling back over content you already have adds nothing.
final class ScrollStitcher {
    enum Outcome: Equatable {
        case first
        /// New rows added (0 when the frame only revisited known content).
        case appended(Int)
        case unchanged
        /// Frame couldn't be lined up. The stitcher keeps its last good frame so scrolling back can recover.
        case noMatch
        /// The height limit was reached.
        case full
    }

    private var strips: [CGImage] = []
    private var lastFrame: CGImage?
    private var lastGray: GrayFrame?
    /// Position of the last accepted frame's top edge, and the extent covered so far, in page pixels.
    private var offset = 0
    private var top = 0
    private var bottom = 0
    private let maxHeight: Int

    init(maxHeight: Int = 40_000) {
        self.maxHeight = maxHeight
    }

    var height: Int { bottom - top }
    var width: Int { strips.first?.width ?? 0 }

    func add(_ frame: CGImage) -> Outcome {
        guard let gray = GrayFrame(image: frame) else { return .noMatch }

        guard let previousGray = lastGray, let previousFrame = lastFrame else {
            strips = [frame]
            lastFrame = frame
            lastGray = gray
            offset = 0
            top = 0
            bottom = frame.height
            return .first
        }
        guard frame.width == previousFrame.width, frame.height == previousFrame.height else { return .noMatch }

        switch ShiftEstimator.estimate(from: previousGray, to: gray) {
        case .unchanged:
            return .unchanged
        case .none:
            return .noMatch
        case .shift(let shift):
            let h = frame.height, w = frame.width
            let newOffset = offset + shift
            var added = 0

            if newOffset + h > bottom {
                added = min(h, newOffset + h - bottom)
                guard height + added <= maxHeight else { return .full }
                if let strip = frame.cropping(to: CGRect(x: 0, y: h - added, width: w, height: added)) {
                    strips.append(strip)
                    bottom += added
                }
            } else if newOffset < top {
                added = min(h, top - newOffset)
                guard height + added <= maxHeight else { return .full }
                if let strip = frame.cropping(to: CGRect(x: 0, y: 0, width: w, height: added)) {
                    strips.insert(strip, at: 0)
                    top -= added
                }
            }
            offset = newOffset
            lastFrame = frame
            lastGray = gray
            return .appended(added)
        }
    }

    /// The stitched image, or nil if no frame was added.
    func finish() -> CGImage? {
        guard let first = strips.first else { return nil }
        guard strips.count > 1 else { return first }
        let width = first.width
        let total = strips.reduce(0) { $0 + $1.height }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        var y = total // CGContext's origin is bottom-left, so the first strip goes at the top.
        for strip in strips {
            y -= strip.height
            ctx.draw(strip, in: CGRect(x: 0, y: y, width: width, height: strip.height))
        }
        return ctx.makeImage()
    }
}
