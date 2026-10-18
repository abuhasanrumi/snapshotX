import CoreGraphics
import Foundation

/// What to do with a screenshot right after it is taken, when a command asks for something specific.
enum PostAction: String, Equatable {
    case copy, save, annotate, pin
}

/// A parsed `snapshotx://command?parameter=value` URL.
///
/// Coordinates follow the same convention as the macOS screen: (0, 0) is the lower-left corner of the display.
struct URLCommand: Equatable {
    enum Kind: String, CaseIterable {
        case allInOne = "all-in-one"
        case captureArea = "capture-area"
        case capturePreviousArea = "capture-previous-area"
        case captureFullscreen = "capture-fullscreen"
        case captureWindow = "capture-window"
        case scrollingCapture = "scrolling-capture"
        case captureText = "capture-text"
        case pin
        case openAnnotate = "open-annotate"
        case openFromClipboard = "open-from-clipboard"
        case addQuickAccessOverlay = "add-quick-access-overlay"
        case openHistory = "open-history"
        case openSettings = "open-settings"
    }

    static let scheme = "snapshotx"

    var kind: Kind
    /// Only set when `width` and `height` are given.
    var rect: CGRect?
    /// 1 is the main display, 2 the next, and so on.
    var display: Int?
    var action: PostAction?
    var filepath: URL?
    var start: Bool?
    var autoscroll: Bool?
    var linebreaks: Bool?
    var tab: SettingsTab?

    init(kind: Kind) {
        self.kind = kind
    }

    static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              let kind = Kind(rawValue: host)
        else { return nil }

        var command = URLCommand(kind: kind)
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { values[item.name.lowercased()] = value }
        }

        func number(_ key: String) -> Double? { values[key].flatMap(Double.init) }
        func flag(_ key: String) -> Bool? {
            guard let raw = values[key]?.lowercased() else { return nil }
            return ["true", "1", "yes"].contains(raw)
        }

        if let width = number("width"), let height = number("height"), width > 0, height > 0 {
            command.rect = CGRect(x: number("x") ?? 0, y: number("y") ?? 0, width: width, height: height)
        }
        if let display = number("display"), display >= 1 { command.display = Int(display) }
        command.action = values["action"].flatMap { PostAction(rawValue: $0.lowercased()) }
        // Only absolute paths are accepted, so a link can't smuggle in a relative or home-relative one.
        if let path = values["filepath"], path.hasPrefix("/") { command.filepath = URL(fileURLWithPath: path) }
        command.start = flag("start")
        command.autoscroll = flag("autoscroll")
        command.linebreaks = flag("linebreaks")
        if let tab = values["tab"]?.lowercased() {
            switch tab {
            case "screenshots": command.tab = .screenshots
            case "shortcuts": command.tab = .shortcuts
            case "permissions": command.tab = .permissions
            default: command.tab = .general
            }
        }
        return command
    }
}
