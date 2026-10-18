import CoreGraphics
import Foundation

struct GradientSpec: Codable, Equatable {
    var colors: [RGBAColor]
    /// CSS-style angle: 0 points up, 90 right, 135 toward the bottom-right corner.
    var angle: Double
}

struct NamedGradient: Identifiable {
    var name: String
    var spec: GradientSpec
    var id: String { name }
}

enum BackgroundCatalog {
    private static func make(_ name: String, _ hexes: [UInt32], angle: Double = 135) -> NamedGradient {
        NamedGradient(name: name, spec: GradientSpec(colors: hexes.map { RGBAColor(hex: $0) }, angle: angle))
    }

    static let gradients: [NamedGradient] = [
        make("Aurora", [0x00C9FF, 0x92FE9D]),
        make("Sunset", [0xFF512F, 0xDD2476]),
        make("Lagoon", [0x43CEA2, 0x185A9D]),
        make("Bubblegum", [0xFF9A9E, 0xFECFEF]),
        make("Midnight", [0x232526, 0x414345], angle: 160),
        make("Indigo", [0x4776E6, 0x8E54E9]),
        make("Peach", [0xFFECD2, 0xFCB69F]),
        make("Mint", [0xD4FC79, 0x96E6A1]),
        make("Candy", [0xFA709A, 0xFEE140]),
        make("Cobalt", [0x0F2027, 0x2C5364]),
        make("Lavender", [0xA18CD1, 0xFBC2EB]),
        make("Citrus", [0xF7971E, 0xFFD200]),
        make("Berry", [0x8E2DE2, 0x4A00E0]),
        make("Sky", [0x56CCF2, 0x2F80ED]),
        make("Rose", [0xFF758C, 0xFF7EB3]),
        make("Forest", [0x134E5E, 0x71B280]),
        make("Fire", [0xF12711, 0xF5AF19]),
        make("Ice", [0xE0EAFC, 0xCFDEF3]),
        make("Violet Dusk", [0x654EA3, 0xEAAFC8]),
        make("Graphite", [0x1F1C2C, 0x928DAB]),
    ]

    static let solids: [RGBAColor] = [
        RGBAColor(hex: 0xFFFFFF), RGBAColor(hex: 0xF2F2F7), RGBAColor(hex: 0x8E8E93),
        RGBAColor(hex: 0x1C1C1E), RGBAColor(hex: 0x000000),
    ]
}

enum BackgroundAspect: String, Codable, CaseIterable, Identifiable {
    case auto, square, fourThree, threeTwo, sixteenNine, nineSixteen, fourFive

    var id: String { rawValue }

    /// Width divided by height, or nil to size the canvas around the screenshot.
    var ratio: Double? {
        switch self {
        case .auto: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3
        case .threeTwo: return 3.0 / 2
        case .sixteenNine: return 16.0 / 9
        case .nineSixteen: return 9.0 / 16
        case .fourFive: return 4.0 / 5
        }
    }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .threeTwo: return "3:2"
        case .sixteenNine: return "16:9"
        case .nineSixteen: return "9:16"
        case .fourFive: return "4:5"
        }
    }
}

enum BackgroundAlignment: String, Codable, CaseIterable, Identifiable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    var id: String { rawValue }

    /// -1 pins to the leading edge, 0 centers, 1 pins to the trailing edge.
    var horizontal: Int {
        switch self {
        case .topLeft, .left, .bottomLeft: return -1
        case .top, .center, .bottom: return 0
        case .topRight, .right, .bottomRight: return 1
        }
    }

    var vertical: Int {
        switch self {
        case .topLeft, .top, .topRight: return -1
        case .left, .center, .right: return 0
        case .bottomLeft, .bottom, .bottomRight: return 1
        }
    }
}

struct BackgroundStyle: Codable, Equatable {
    enum Fill: Codable, Equatable {
        case gradient(GradientSpec)
        case solid(RGBAColor)
        case image(path: String)
    }

    var enabled = false
    var fill: Fill = .gradient(BackgroundCatalog.gradients[0].spec)
    /// Space around the screenshot, as a fraction of its shorter side.
    var padding: Double = 0.12
    /// Corner radius, as a fraction of the screenshot's shorter side.
    var cornerRadius: Double = 0.025
    /// Shadow strength from 0 (none) to 1.
    var shadow: Double = 0.6
    var aspect: BackgroundAspect = .auto
    var alignment: BackgroundAlignment = .center
}

struct BackgroundPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var style: BackgroundStyle
}

/// Saved looks the user can reapply to any screenshot.
final class BackgroundPresetStore: ObservableObject {
    private static let key = "background.presets.v1"

    @Published private(set) var items: [BackgroundPreset] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([BackgroundPreset].self, from: data) {
            items = decoded
        }
    }

    func add(name: String, style: BackgroundStyle) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var saved = style
        saved.enabled = true
        items.append(BackgroundPreset(name: trimmed, style: saved))
        save()
    }

    func remove(_ preset: BackgroundPreset) {
        items.removeAll { $0.id == preset.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: Self.key) }
    }
}

/// Where the screenshot sits on the background canvas.
enum BackgroundLayout {
    static func compute(contentSize: CGSize, style: BackgroundStyle) -> (canvas: CGSize, content: CGRect) {
        let padding = CGFloat(style.padding) * min(contentSize.width, contentSize.height)
        var canvasW = contentSize.width + 2 * padding
        var canvasH = contentSize.height + 2 * padding

        if let ratio = style.aspect.ratio {
            if canvasW / canvasH < CGFloat(ratio) {
                canvasW = canvasH * CGFloat(ratio)
            } else {
                canvasH = canvasW / CGFloat(ratio)
            }
        }
        canvasW = canvasW.rounded()
        canvasH = canvasH.rounded()

        func position(_ alignment: Int, canvas: CGFloat, content: CGFloat) -> CGFloat {
            switch alignment {
            case -1: return padding
            case 1: return canvas - content - padding
            default: return ((canvas - content) / 2).rounded()
            }
        }
        let origin = CGPoint(x: position(style.alignment.horizontal, canvas: canvasW, content: contentSize.width),
                             y: position(style.alignment.vertical, canvas: canvasH, content: contentSize.height))
        return (CGSize(width: canvasW, height: canvasH), CGRect(origin: origin, size: contentSize))
    }
}
