import AppKit
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The screen under the mouse pointer, falling back to the main screen.
    static var underMouse: NSScreen? {
        let point = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(point) } ?? main
    }
}

/// Lists on-screen windows front to back, in AppKit coordinates.
enum WindowLister {
    static func onScreenWindows() -> [WindowCandidate] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let me = getpid()

        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let id = info[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40
            else { return nil }
            return WindowCandidate(
                id: id,
                frame: Geometry.appKitRect(fromTopLeftRect: bounds, primaryScreenHeight: primaryHeight),
                title: info[kCGWindowName as String] as? String ?? "",
                owner: info[kCGWindowOwnerName as String] as? String ?? ""
            )
        }
    }
}

/// Takes still images through ScreenCaptureKit. SnapShotX's own windows (selection overlay, Quick Access
/// Overlay, settings) are always excluded from the result.
@MainActor
final class CaptureService {
    enum CaptureError: LocalizedError {
        case displayNotFound
        case windowNotFound

        var errorDescription: String? {
            switch self {
            case .displayNotFound: return "The display to capture is no longer available."
            case .windowNotFound: return "That window closed before it could be captured."
            }
        }
    }

    func captureFullscreen(on screen: NSScreen, showCursor: Bool) async throws -> CGImage {
        let local = CGRect(origin: .zero, size: screen.frame.size)
        return try await captureDisplay(screen, localRect: local, showCursor: showCursor)
    }

    /// `selection` is in AppKit global coordinates.
    func captureArea(on screen: NSScreen, selection: CGRect, showCursor: Bool) async throws -> CGImage {
        let local = Geometry.displayLocalRect(selection: selection, screenFrame: screen.frame)
        return try await captureDisplay(screen, localRect: local, showCursor: showCursor)
    }

    func captureWindow(id: CGWindowID, showCursor: Bool) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.windowNotFound }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)

        let config = SCStreamConfiguration()
        config.captureResolution = .best
        config.width = max(1, Int((info.contentRect.width * scale).rounded()))
        config.height = max(1, Int((info.contentRect.height * scale).rounded()))
        config.showsCursor = showCursor
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private func captureDisplay(_ screen: NSScreen, localRect: CGRect, showCursor: Bool) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let displayID = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw CaptureError.displayNotFound }

        let me = getpid()
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == me }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        // Ask the system for the display's real pixel density rather than assuming 2x.
        let scale = max(screen.backingScaleFactor, CGFloat(SCShareableContent.info(for: filter).pointPixelScale))
        let config = SCStreamConfiguration()
        config.captureResolution = .best
        config.sourceRect = localRect
        config.width = max(1, Int((localRect.width * scale).rounded()))
        config.height = max(1, Int((localRect.height * scale).rounded()))
        config.showsCursor = showCursor
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
