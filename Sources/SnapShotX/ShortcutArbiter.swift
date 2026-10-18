import Foundation

/// What is going on right now, as far as a new shortcut press is concerned.
struct CaptureActivity: Equatable {
    var isRecording = false
    var isScrolling = false
    /// A selection overlay (All-in-One, area, window) is on screen.
    var isOverlayOpen = false
    /// The shortcut that opened that overlay.
    var overlayOwner: HotkeyAction?
    /// A capture is running or finishing.
    var isBusy = false
}

enum ShortcutDecision: Equatable {
    /// Nothing is going on: run the action.
    case start
    case stopRecording
    case finishScrolling
    /// The same shortcut that opened the overlay closes it again.
    case closeOverlay
    /// A different shortcut closes the overlay and starts its own capture.
    case switchToAction
    /// Something is running that the action can't interrupt: say so, don't just ignore the key.
    case explain(String)
    /// The previous capture is still finishing.
    case ignore
}

/// The rules for a shortcut pressed while something else is happening, so a press is never dropped silently.
enum ShortcutArbiter {
    static func decide(_ action: HotkeyAction, activity: CaptureActivity) -> ShortcutDecision {
        // Opening history is harmless at any time.
        if action == .openHistory { return .start }

        if activity.isRecording {
            return action == .recordScreen ? .stopRecording : .explain("Stop the recording first")
        }
        if activity.isScrolling {
            return (action == .scrollingCapture || action == .fullPageCapture) ? .finishScrolling : .explain("Finish the scrolling capture first")
        }
        if activity.isOverlayOpen {
            return activity.overlayOwner == action ? .closeOverlay : .switchToAction
        }
        return activity.isBusy ? .ignore : .start
    }
}
