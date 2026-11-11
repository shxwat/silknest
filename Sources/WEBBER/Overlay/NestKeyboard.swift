import AppKit
import Carbon.HIToolbox

/// The Nest's keyboard: everything the old list did, without a list.
///   ↩ paste the focused object · ⇧↩ paste as plain text · 1–9 paste by number (when not searching)
///   type to search (text, links, file names, the source app, text inside screenshots; "img", "link",
///   "code", "file", "text" filter by kind) · ← → ↑ ↓ move to the nearest object that way
///   Tab: the object's menu · ⌫ edit the search · Esc clear the search, then close
///   Page Up / Page Down (or scrolling on the Nest): older and newer items — the web holds one page
/// The keys are only taken while the Nest is open; nothing is typed into or read from other apps.
final class NestKeyboard {
    private(set) var query = ""
    private(set) var matches: [Int] = []          // ids hanging now (one page), newest first
    /// Everything that matches across the whole history.
    var total = 0
    private var registered: [Shortcut] = []
    let pill = NestSearchPill()

    struct Handlers {
        var query: (String) -> Void
        var digit: (Int) -> Void
        /// ⌫ on an empty search (or with a card open): true when it was used (removes the card's item).
        var backspace: () -> Bool
        var paste: (_ plain: Bool) -> Void
        var move: (_ dx: CGFloat, _ dy: CGFloat) -> Void
        var menu: () -> Void
        var page: (_ delta: Int) -> Void
        var escape: () -> Void
        /// ⌘↩: queue the focused item on the Paste Stack (the Nest stays open).
        var stack: () -> Void
    }

    /// The search pill becomes the key window (without activating SilkNest, like Spotlight) and takes
    /// the typing. Plain-key global hot keys are not delivered on current macOS, so they are not used.
    func takeKeys(_ h: Handlers) { pill.handlers = h }
    func releaseKeys() { pill.handlers = nil }

    func setQuery(_ q: String) { query = q }

    /// What search needs from one item: plain values, safe to read on a background queue.
    struct Entry { let id: Int; let kind: ClipboardKind; let pinned: Bool; let haystack: String }

    /// Nest order: pinned items first, then newest first (within each group).
    static func ordered(_ newestFirst: [ClipboardItem]) -> [ClipboardItem] {
        newestFirst.filter(\.pinned)+newestFirst.filter { !$0.pinned }
    }

    /// The ids matching `query`, keeping the order of `entries`. Kind words ("img", "link", "code", "file",
    /// "text") and "pin" filter; every other word must appear in the item's searchable text.
    static func search(_ entries: [Entry], query: String) -> [Int] {
        let kinds: [String: Set<ClipboardKind>] = ["img":[.image],"image":[.image],"shot":[.image],"link":[.url],"url":[.url],
                                                   "code":[.code],"file":[.file],"text":[.text,.code]]
        var wanted = Set<ClipboardKind>(), words: [Substring] = [], pinnedOnly = false
        for w in query.lowercased().split(separator:" ") {
            if let k = kinds[String(w)] { wanted.formUnion(k) } else if w == "pin" || w == "pinned" { pinnedOnly = true } else { words.append(w) }
            // ("secret" is a plain word: secrets carry it in their search text.)
        }
        return entries.compactMap { e in
            (!pinnedOnly || e.pinned) && (wanted.isEmpty || wanted.contains(e.kind)) && words.allSatisfy { e.haystack.contains($0) } ? e.id : nil
        }
    }

    /// The same matching on items (keeps their order).
    static func filter(_ items: [ClipboardItem], query: String) -> [ClipboardItem] {
        let ids = Set(search(items.map { Entry(id:$0.id,kind:$0.kind,pinned:$0.pinned,haystack:$0.searchableText) },query:query))
        return items.filter { ids.contains($0.id) }
    }

    func update(matches ids: [Int]) { matches = ids }
}

/// The panel that holds the search: key while the Nest is open, never activates SilkNest.
final class NestSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The silk thread at the top of the Nest: a real search field (type, see the caret) plus what the keys do.
final class NestSearchPill: NSObject, NSTextFieldDelegate {
    private let panel: NestSearchPanel
    private let box = NSVisualEffectView()
    private let field = NSTextField()
    private let hint = NSTextField(labelWithString:"")
    private var keyMonitor: Any?
    var handlers: NestKeyboard.Handlers?
    var isKey: Bool { panel.isKeyWindow }

    override init() {
        panel = NestSearchPanel(contentRect:NSRect(x:0,y:0,width:520,height:46),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:true)
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.ignoresMouseEvents = false
        panel.level = NSWindow.Level(rawValue:NSWindow.Level.statusBar.rawValue+5)
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        panel.animationBehavior = .none; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        box.material = .hudWindow; box.blendingMode = .behindWindow; box.state = .active; box.appearance = NSAppearance(named:.darkAqua)
        box.wantsLayer = true; box.layer?.cornerRadius = 23; box.layer?.masksToBounds = true
        box.layer?.borderWidth = 1; box.layer?.borderColor = NSColor(srgbRed:1,green:0.78,blue:0.32,alpha:0.35).cgColor
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none; field.isEditable = true; field.isSelectable = true
        field.font = .systemFont(ofSize:16,weight:.medium); field.textColor = NSColor(white:1,alpha:0.95)
        field.cell?.isScrollable = true; field.cell?.wraps = false; field.delegate = self
        hint.font = .systemFont(ofSize:12,weight:.medium); hint.textColor = NSColor(white:1,alpha:0.5); hint.alignment = .right
        hint.lineBreakMode = .byTruncatingHead
        box.addSubview(field); box.addSubview(hint); panel.contentView = box
    }

    func show(on screen: NSRect) {
        let w: CGFloat = min(560,screen.width-40), h: CGFloat = 46
        panel.setFrame(NSRect(x:screen.midX-w/2,y:screen.maxY-h-12,width:w,height:h),display:false)
        box.frame = NSRect(x:0,y:0,width:w,height:h)
        field.frame = NSRect(x:22,y:12,width:w*0.45,height:22)
        hint.frame = NSRect(x:22+w*0.45,y:15,width:w*0.55-44,height:17)
        field.stringValue = ""
        panel.orderFrontRegardless()
        panel.makeKey(); panel.makeFirstResponder(field)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] e in self?.key(e) ?? e }
        }
    }

    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
    }

    /// Keys that act on the Nest rather than edit the search. Returns nil when used.
    private func key(_ e: NSEvent) -> NSEvent? {
        guard panel.isKeyWindow, let h = handlers else { return e }
        let mods = e.modifierFlags.intersection([.command,.option,.control,.shift])
        switch Int(e.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if mods.contains(.command) { h.stack() } else { h.paste(mods.contains(.shift)) }
            return nil
        case kVK_Escape: h.escape(); return nil
        case kVK_Tab: h.menu(); return nil
        case kVK_LeftArrow: h.move(-1,0); return nil
        case kVK_RightArrow: h.move(1,0); return nil
        case kVK_UpArrow: h.move(0,1); return nil
        case kVK_DownArrow: h.move(0,-1); return nil
        case kVK_PageDown: h.page(1); return nil
        case kVK_PageUp: h.page(-1); return nil
        case kVK_Delete: return h.backspace() ? nil : e
        default: break
        }
        // 1–9 on an empty search paste by number; with something typed they are part of the search.
        if mods.isEmpty, field.stringValue.isEmpty, let c = e.charactersIgnoringModifiers, c.count == 1, let n = Int(c), n >= 1 {
            h.digit(n); return nil
        }
        return e
    }

    func controlTextDidChange(_ obj: Notification) { handlers?.query(field.stringValue) }

    /// The search changed outside the field (Esc cleared it): show it.
    func setText(_ text: String) { if field.stringValue != text { field.stringValue = text } }

    /// `total`: everything that matches (the whole history when not searching); `page`/`pages`: which part hangs.
    func render(query: String, total: Int, page: Int, pages: Int, target: String?, canPaste: Bool) {
        setText(query)
        let placeholder = total == 0 && query.isEmpty ? "Nothing caught yet" : "Search \(total) item\(total == 1 ? "" : "s")"
        field.placeholderAttributedString = NSAttributedString(string:placeholder,attributes:[
            .foregroundColor:NSColor(white:1,alpha:0.4),.font:NSFont.systemFont(ofSize:16,weight:.medium)])
        let action = canPaste ? "↩ paste\(target.map { " in \($0)" } ?? "")" : "↩ copy"
        let paging = pages > 1 ? "   page \(page+1)/\(pages) ⇅" : ""
        if !query.isEmpty && total == 0 { hint.stringValue = "Nothing caught matches"; return }
        hint.stringValue = query.isEmpty ? "\(action)   ⌘↩ stack   1–9\(paging)" : "\(total) found\(paging)   \(action)"
    }
}
