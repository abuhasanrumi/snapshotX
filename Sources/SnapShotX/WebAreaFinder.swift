import AppKit
import ApplicationServices

/// Finds where a browser shows the web page (not its tabs, address bar or toolbars) by asking the Accessibility
/// API for the page's web area. Works with Safari, Chrome, Edge, Brave, Arc, Firefox and Electron apps.
enum WebAreaFinder {
    /// The web area of the app's front window in AppKit global coordinates, or nil if it has none (or Accessibility is off).
    static func frame(forProcess pid: pid_t) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // Chromium and Electron only build their accessibility tree when an assistive client asks for it.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success
                || AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &window) == .success,
              let window else { return nil }

        // The tree can take a moment to appear the first time, so try a few times.
        for attempt in 0..<6 {
            var budget = 4000
            if let area = findWebArea(in: window as! AXUIElement, depth: 0, budget: &budget), let rect = rect(of: area) {
                return appKitRect(fromAccessibility: rect)
            }
            if attempt < 5 { Thread.sleep(forTimeInterval: 0.25) }
        }
        return nil
    }

    private static func findWebArea(in element: AXUIElement, depth: Int, budget: inout Int) -> AXUIElement? {
        guard depth < 14, budget > 0 else { return nil }
        budget -= 1
        if string(kAXRoleAttribute, of: element) == "AXWebArea" {
            // A page can contain nested web areas (iframes); the outermost one is the page.
            return element
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return nil }
        for child in list {
            if let found = findWebArea(in: child, depth: depth + 1, budget: &budget) { return found }
        }
        return nil
    }

    private static func string(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func rect(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 20, extent.height > 20 else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// Accessibility uses a top-left origin on the primary display; AppKit uses bottom-left.
    static func appKitRect(fromAccessibility rect: CGRect, primaryHeight: CGFloat? = nil) -> CGRect {
        let height = primaryHeight ?? NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}
