import AppKit
import ApplicationServices

/// Direct paste and text-caret location. Both need the macOS Accessibility permission, which is asked for
/// only when the user first chooses an item to paste; without it WEBBER still copies, and Cmd+V works.
enum PasteAssist {
    /// `WEBBER_FORCE_UNTRUSTED=1` simulates a denied/revoked permission (verification of the copy-only fallback).
    static var trusted: Bool { DevFlags.env("WEBBER_FORCE_UNTRUSTED") == nil && AXIsProcessTrusted() }
    private static var lastAsk: CFTimeInterval = -100

    /// Asked only when the user actually tries to paste: shows the system prompt and opens the exact
    /// Settings pane (an old grant for a previous build does not carry over, so it must be re-enabled).
    static func requestTrustIfNeeded() {
        guard !trusted, CACurrentMediaTime()-lastAsk > 3 else { return }
        lastAsk = CACurrentMediaTime()
        // A short explanation first; macOS's own prompt only appears when the user chooses to continue.
        PermissionWindow.shared.show()
    }

    /// Sends Cmd+V to whichever app is frontmost (WEBBER never takes focus, so that is the user's app).
    static func pasteIntoFrontmostApp() {
        guard trusted else { return }
        let source = CGEventSource(stateID:.combinedSessionState)
        let v: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource:source,virtualKey:v,keyDown:true)
        let up = CGEvent(keyboardEventSource:source,virtualKey:v,keyDown:false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap:.cghidEventTap); up?.post(tap:.cghidEventTap)
    }

    /// Title of the app's focused window: in a browser that is the open tab ("ChatGPT"), in an editor the file.
    /// Trailing " - Google Chrome"-style suffixes are removed and long titles shortened.
    static func focusedWindowTitle(of app: NSRunningApplication) -> String? {
        guard trusted else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element,0.1)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,kAXFocusedWindowAttribute as CFString,&window) == .success, let window,
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement,kAXTitleAttribute as CFString,&title) == .success,
              var text = (title as? String)?.trimmingCharacters(in:.whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let name = app.localizedName {
            for separator in [" - "," – "," — "] {
                if let range = text.range(of:separator+name) { text = String(text[..<range.lowerBound]) }
            }
        }
        text = text.trimmingCharacters(in:.whitespaces)
        guard !text.isEmpty else { return nil }
        return text.count > 32 ? String(text.prefix(31))+"…" : text
    }

    /// Screen rect (AppKit coordinates) of the text caret in the focused app, if it exposes one.
    static func caretRect() -> NSRect? {
        guard trusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system,0.08)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system,kAXFocusedUIElementAttribute as CFString,&focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        let field = element as! AXUIElement
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field,kAXSelectedTextRangeAttribute as CFString,&range) == .success, let range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field,kAXBoundsForRangeParameterizedAttribute as CFString,range,&bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue,.cgRect,&rect), rect.origin.x.isFinite, rect.height > 0 || rect.width >= 0 else { return nil }
        // Accessibility uses top-left origin global coordinates; AppKit uses bottom-left of the primary display.
        guard let primary = NSScreen.screens.first else { return nil }
        let flipped = NSRect(x:rect.minX,y:primary.frame.maxY-rect.maxY,width:max(1,rect.width),height:max(1,rect.height))
        // Reject nonsense (some apps report zero rects at the origin).
        guard flipped.minX != 0 || flipped.minY != 0, NSScreen.screens.contains(where: { $0.frame.intersects(flipped) }) else { return nil }
        return flipped
    }
}
