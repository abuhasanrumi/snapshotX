import AppKit

/// Tracks whether the menu bar icon is actually showing. On a Mac with a notch, or a menu bar crowded with
/// other apps' icons, macOS silently hides icons that don't fit. There is no API to claim more room,
/// so the app watches for it and offers other ways in (the Dock icon, and a notice in Settings).
@MainActor
final class StatusItemMonitor: ObservableObject {
    @Published private(set) var isHidden = false

    private var observer: NSObjectProtocol?
    private weak var item: NSStatusItem?

    /// Starts watching the window that hosts the status item's button.
    func watch(_ item: NSStatusItem) {
        self.item = item
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: item.button?.window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let item = self.item else { return }
                self.refresh(item)
            }
        }
        refresh(item)
    }

    func refresh(_ item: NSStatusItem) {
        let visible = Self.isShowing(item)
        if isHidden == visible { isHidden = !visible }
    }

    static func isShowing(_ item: NSStatusItem) -> Bool {
        guard item.isVisible, let window = item.button?.window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }
}
