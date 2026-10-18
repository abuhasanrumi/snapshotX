import CoreGraphics
import Foundation
import Vision

/// On-device text and QR code recognition. Nothing leaves the Mac.
enum TextRecognizer {
    struct Line: Equatable {
        var text: String
        /// Vision's normalized box: origin at the bottom-left, 0...1.
        var box: CGRect
    }

    struct Result: Equatable {
        var text: String
        var isQRCode: Bool
        var isEmpty: Bool { text.isEmpty }
    }

    static func recognize(in image: CGImage, keepLineBreaks: Bool) async -> Result {
        await Task.detached(priority: .userInitiated) {
            recognizeSynchronously(image, keepLineBreaks: keepLineBreaks)
        }.value
    }

    static func recognizeSynchronously(_ image: CGImage, keepLineBreaks: Bool) -> Result {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let barcodes = VNDetectBarcodesRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.automaticallyDetectsLanguage = true
        try? handler.perform([barcodes, text])

        // A selected QR code is almost always meant to be read as one.
        let payloads = (barcodes.results ?? []).compactMap { $0.payloadStringValue }
        if !payloads.isEmpty { return Result(text: payloads.joined(separator: "\n"), isQRCode: true) }

        let lines = (text.results ?? []).compactMap { observation -> Line? in
            observation.topCandidates(1).first.map { Line(text: $0.string, box: observation.boundingBox) }
        }
        return Result(text: join(lines, keepLineBreaks: keepLineBreaks), isQRCode: false)
    }

    /// Puts recognized fragments in reading order: top to bottom, and left to right within a visual row.
    static func join(_ lines: [Line], keepLineBreaks: Bool) -> String {
        let byHeight = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[Line]] = []
        var rowAnchor: Line?
        for line in byHeight {
            if let anchor = rowAnchor, abs(line.box.midY - anchor.box.midY) <= 0.6 * max(line.box.height, anchor.box.height) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
                rowAnchor = line
            }
        }
        let rowTexts = rows.map { row in
            row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
        }
        return rowTexts.joined(separator: keepLineBreaks ? "\n" : " ")
    }
}
