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

        // Chromium and Electron build their tree lazily after being asked, so the first tries can come back empty.
        for attempt in 0..<12 {
            if let rect = locate(app: app, pid: pid) { return appKitRect(fromAccessibility: rect) }
            if attempt < 11 { Thread.sleep(forTimeInterval: 0.3) }
        }
        return nil
    }

    private static func locate(app: AXUIElement, pid: pid_t) -> CGRect? {
        var windowRef: CFTypeRef?
        let hasWindow = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success
            || AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &windowRef) == .success
        let window = hasWindow ? (windowRef as! AXUIElement?) : nil
        let windowRect = window.flatMap(rect(of:)) ?? frontWindowAccessibilityRect(pid: pid)

        // Fastest and most reliable: ask what is at a point well inside the page, then climb to its web area.
        if let windowRect {
            for fraction in [0.6, 0.5, 0.75] {
                let point = CGPoint(x: windowRect.midX, y: windowRect.minY + windowRect.height * fraction)
                var hit: AXUIElement?
                if AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, let hit,
                   let area = enclosingWebArea(of: hit), let r = rect(of: area) {
                    return r
                }
            }
        }
        // Otherwise search the window's tree.
        if let window {
            var budget = 6000
            if let area = findWebArea(in: window, depth: 0, budget: &budget), let r = rect(of: area) { return r }
        }
        return nil
    }

    private static func enclosingWebArea(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var outermost: AXUIElement?
        for _ in 0..<40 {
            guard let node = current else { break }
            if string(kAXRoleAttribute, of: node) == "AXWebArea" { outermost = node }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success, let parent else { break }
            current = (parent as! AXUIElement)
        }
        return outermost
    }

    /// The process's front window in Accessibility coordinates (top-left origin), from the window list.
    private static func frontWindowAccessibilityRect(pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in list where (window[kCGWindowOwnerPID as String] as? pid_t) == pid && (window[kCGWindowLayer as String] as? Int) == 0 {
            if let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
               let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 100, rect.height > 100 { return rect }
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
