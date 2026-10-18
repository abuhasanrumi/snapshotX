import CoreGraphics
import Foundation

/// What the All-in-One selection does when confirmed.
enum AllInOneMode: String, CaseIterable, Codable, Identifiable {
    case area, scrolling, text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: return "Capture Area"
        case .scrolling: return "Scrolling Capture"
        case .text: return "Capture Text"
        }
    }

    var symbol: String {
        switch self {
        case .area: return "rectangle.dashed"
        case .scrolling: return "arrow.up.and.down.text.horizontal"
        case .text: return "text.viewfinder"
        }
    }

    var confirmTitle: String {
        switch self {
        case .area: return "Capture"
        case .scrolling: return "Start Scrolling"
        case .text: return "Copy Text"
        }
    }
}

/// The last region and mode used in All-in-One, so retaking the same shot is one keystroke.
struct AllInOneMemory: Codable, Equatable {
    private static let key = "allInOne.last.v1"

    var displayID: UInt32
    /// Relative to the display's lower-left corner.
    var rect: CGRect
    var mode: AllInOneMode

    static func load(from defaults: UserDefaults = .standard) -> AllInOneMemory? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AllInOneMemory.self, from: $0) }
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}
