import AppKit
import ApplicationServices

/// Development-only (--automation): real input events and Accessibility reads, so verification runs can
/// drive the actual overlay end to end (paste into other apps, drag out to Finder). Never used otherwise.
enum AutomationInput {
    private static func cg(_ p: NSPoint) -> CGPoint { CGPoint(x:p.x,y:(NSScreen.screens.first?.frame.maxY ?? 0)-p.y) }

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID:.hidSystemState)
        let down = CGEvent(keyboardEventSource:src,virtualKey:code,keyDown:true), up = CGEvent(keyboardEventSource:src,virtualKey:code,keyDown:false)
        down?.flags = flags; up?.flags = flags
        down?.post(tap:.cghidEventTap); usleep(12_000); up?.post(tap:.cghidEventTap)
    }

    static func type(_ text: String) {
        let src = CGEventSource(stateID:.hidSystemState)
        for ch in text.utf16 {
            var c = ch
            let down = CGEvent(keyboardEventSource:src,virtualKey:0,keyDown:true), up = CGEvent(keyboardEventSource:src,virtualKey:0,keyDown:false)
            down?.keyboardSetUnicodeString(stringLength:1,unicodeString:&c); up?.keyboardSetUnicodeString(stringLength:1,unicodeString:&c)
            down?.post(tap:.cghidEventTap); up?.post(tap:.cghidEventTap); usleep(15_000)
        }
    }

    static func click(_ p: NSPoint) {
        let at = cg(p)
        CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:at,mouseButton:.left)?.post(tap:.cghidEventTap); usleep(60_000)
        CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:at,mouseButton:.left)?.post(tap:.cghidEventTap); usleep(40_000)
        CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:at,mouseButton:.left)?.post(tap:.cghidEventTap)
    }

    static func rightClick(_ p: NSPoint) {
        let at = cg(p)
        CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:at,mouseButton:.right)?.post(tap:.cghidEventTap); usleep(60_000)
        CGEvent(mouseEventSource:nil,mouseType:.rightMouseDown,mouseCursorPosition:at,mouseButton:.right)?.post(tap:.cghidEventTap); usleep(40_000)
        CGEvent(mouseEventSource:nil,mouseType:.rightMouseUp,mouseCursorPosition:at,mouseButton:.right)?.post(tap:.cghidEventTap)
    }

    /// A real press-move-release drag (runs off the main thread so AppKit can track it).
    static func drag(from a: NSPoint, to b: NSPoint, done: @escaping () -> Void) {
        DispatchQueue.global().async {
            let s = cg(a), e = cg(b)
            CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:s,mouseButton:.left)?.post(tap:.cghidEventTap); usleep(150_000)
            CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:s,mouseButton:.left)?.post(tap:.cghidEventTap); usleep(150_000)
            for i in 1...60 {
                let t = CGFloat(i)/60
                let p = CGPoint(x:s.x+(e.x-s.x)*t,y:s.y+(e.y-s.y)*t)
                CGEvent(mouseEventSource:nil,mouseType:.leftMouseDragged,mouseCursorPosition:p,mouseButton:.left)?.post(tap:.cghidEventTap)
                usleep(16_000)
            }
            usleep(400_000)
            CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:e,mouseButton:.left)?.post(tap:.cghidEventTap)
            DispatchQueue.main.async(execute:done)
        }
    }

    /// The focused element of the frontmost app: role and current text value.
    static func focused() -> [String:Any] {
        let system = AXUIElementCreateSystemWide()
        var el: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system,kAXFocusedUIElementAttribute as CFString,&el) == .success, let el else { return ["error":"no focused element"] }
        let element = el as! AXUIElement
        var role: CFTypeRef?, value: CFTypeRef?
        AXUIElementCopyAttributeValue(element,kAXRoleAttribute as CFString,&role)
        AXUIElementCopyAttributeValue(element,kAXValueAttribute as CFString,&value)
        // Only the length and a hash: verification compares them; the text itself is never reported
        // (the focused field can be any app's content, e.g. a terminal or a password field).
        let text = (value as? String) ?? ""
        var h = Hasher(); h.combine(text)
        return ["app":NSWorkspace.shared.frontmostApplication?.localizedName ?? "?","role":(role as? String) ?? "?","valueLength":text.count,"valueHash":h.finalize()]
    }
}
