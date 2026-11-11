import AppKit

/// One card for a Nest object: the object itself, large, with everything you can do with it in a row
/// underneath. Opens on click (or Tab), beside the object, never over its neighbours; Esc or a click
/// elsewhere closes it. Hovering still shows only the preview (HoverPreview).
final class ItemCard {
    struct Action { let title: String; let key: String?; let destructive: Bool; let run: () -> Void }

    private let panel: CardPanel
    private let box = NSVisualEffectView()
    private let imageView = NSImageView()
    private let text = NSTextField(wrappingLabelWithString:"")
    private let meta = NSTextField(labelWithString:"")
    private var buttons: [NSButton] = []
    private var actions: [Action] = []
    private var outside: Any?
    private(set) var itemID: Int?
    var isOpen: Bool { itemID != nil }
    /// When it last closed: a click outside first closes the card, not the whole Nest behind it.
    private(set) var closedAt: CFTimeInterval = 0
    var onClose: (() -> Void)?

    init() {
        panel = CardPanel(contentRect:NSRect(x:0,y:0,width:10,height:10),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue:NSWindow.Level.statusBar.rawValue+6)
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        panel.animationBehavior = .none; panel.isReleasedWhenClosed = false; panel.becomesKeyOnlyIfNeeded = true
        box.material = .hudWindow; box.blendingMode = .behindWindow; box.state = .active; box.appearance = NSAppearance(named:.darkAqua)
        box.wantsLayer = true; box.layer?.cornerRadius = 14; box.layer?.masksToBounds = true
        box.layer?.borderWidth = 1; box.layer?.borderColor = NSColor(srgbRed:1,green:0.78,blue:0.32,alpha:0.32).cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown; imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 7; imageView.layer?.masksToBounds = true
        text.textColor = NSColor(white:1,alpha:0.93); text.maximumNumberOfLines = 12; text.lineBreakMode = .byWordWrapping
        meta.font = .systemFont(ofSize:11,weight:.medium); meta.textColor = NSColor(white:1,alpha:0.5)
        box.addSubview(imageView); box.addSubview(text); box.addSubview(meta)
        panel.contentView = box
    }

    func open(_ item: ClipboardItem, anchor: NSRect, actions: [Action], avoid: [NSRect] = []) {
        close(notify:false)
        self.actions = actions
        let pad: CGFloat = 14, buttonH: CGFloat = 30, gap: CGFloat = 8
        // Buttons first: they decide the card's minimum width.
        for b in buttons { b.removeFromSuperview() }
        buttons = actions.enumerated().map { i,a in
            let b = CardButton(title:"",target:self,action:#selector(pressed(_:))); b.tag = i
            b.isBordered = false; b.wantsLayer = true; b.layer?.cornerRadius = 8
            b.layer?.backgroundColor = (i == 0 ? NSColor(srgbRed:0.95,green:0.70,blue:0.24,alpha:1) : NSColor(white:1,alpha:0.08)).cgColor
            let title = NSMutableAttributedString(string:a.title,attributes:[.font:NSFont.systemFont(ofSize:12.5,weight:.semibold),
                .foregroundColor:i == 0 ? NSColor(srgbRed:0.1,green:0.07,blue:0.02,alpha:1) : (a.destructive ? NSColor(srgbRed:1,green:0.45,blue:0.42,alpha:1) : NSColor(white:1,alpha:0.92))])
            if let k = a.key {
                title.append(NSAttributedString(string:"  \(k)",attributes:[.font:NSFont.systemFont(ofSize:11,weight:.medium),
                    .foregroundColor:i == 0 ? NSColor(srgbRed:0.1,green:0.07,blue:0.02,alpha:0.6) : NSColor(white:1,alpha:0.4)]))
            }
            b.attributedTitle = title
            b.frame.size = NSSize(width:ceil(title.size().width)+22,height:buttonH)
            return b
        }
        let rowWidth = buttons.reduce(0) { $0+$1.frame.width }+gap*CGFloat(max(0,buttons.count-1))
        let maxContent: CGFloat = 460
        var contentW = max(rowWidth,280), contentH: CGFloat
        if item.kind == .image, let image = item.displayImage, image.size.width > 0 {
            let k = min(1,min(max(contentW,maxContent)/image.size.width,300/image.size.height))
            let s = NSSize(width:max(160,image.size.width*k),height:max(80,image.size.height*k))
            contentW = max(contentW,s.width); contentH = s.height
            imageView.image = image; imageView.isHidden = false; text.isHidden = true
            imageView.frame = NSRect(x:pad+(contentW-s.width)/2,y:0,width:s.width,height:s.height)
        } else {
            contentW = max(contentW,maxContent)
            imageView.isHidden = true; text.isHidden = false
            text.font = item.kind == .code ? .monospacedSystemFont(ofSize:12.5,weight:.regular) : .systemFont(ofSize:13.5)
            let body = item.kind == .file ? item.fileURLs.map { ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator:"\n") : (item.displayText ?? item.url?.absoluteString ?? item.title)
            text.stringValue = String(body.prefix(1200)); text.preferredMaxLayoutWidth = contentW
            contentH = min(260,text.sizeThatFits(NSSize(width:contentW,height:260)).height)
            text.frame = NSRect(x:pad,y:0,width:contentW,height:contentH)
        }
        // Layout bottom-up: buttons, meta, content.
        var x = pad
        for b in buttons { b.frame.origin = NSPoint(x:x,y:pad); x += b.frame.width+gap; box.addSubview(b) }
        let metaY = pad+buttonH+10
        var parts = [item.kind.rawValue.capitalized]
        if let s = item.sourceName { parts.append(s) }
        parts.append(RelativeDateTimeFormatter().localizedString(for:item.lastCopied,relativeTo:Date()))
        if item.pinned { parts.append("Pinned") }
        meta.stringValue = parts.joined(separator:"  ·  ")
        meta.frame = NSRect(x:pad,y:metaY,width:contentW,height:16)
        let contentY = metaY+16+10
        imageView.frame.origin.y = contentY; text.frame.origin.y = contentY
        let size = NSSize(width:contentW+pad*2,height:contentY+contentH+pad)
        box.frame = NSRect(origin:.zero,size:size)
        // Next to the object — right, left, above or below — wherever it covers the fewest other objects.
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? NSScreen.main!.visibleFrame
        func fit(_ r: NSRect) -> NSRect {
            NSRect(x:min(max(r.minX,screen.minX+8),screen.maxX-r.width-8),y:min(max(r.minY,screen.minY+8),screen.maxY-r.height-60),width:r.width,height:r.height)
        }
        let w = size.width, h = size.height, g: CGFloat = 16
        let candidates = [NSRect(x:anchor.maxX+g,y:anchor.midY-h/2,width:w,height:h), NSRect(x:anchor.minX-g-w,y:anchor.midY-h/2,width:w,height:h),
                          NSRect(x:anchor.midX-w/2,y:anchor.maxY+g,width:w,height:h), NSRect(x:anchor.midX-w/2,y:anchor.minY-g-h,width:w,height:h)].map(fit)
        func cost(_ r: NSRect) -> CGFloat {
            let covered = (avoid+[anchor.insetBy(dx:-6,dy:-6)]).reduce(CGFloat(0)) { s,o in let i = r.intersection(o); return s+(i.isNull ? 0 : i.width*i.height) }
            return covered*4+hypot(r.midX-anchor.midX,r.midY-anchor.midY)
        }
        let frame = candidates.min { cost($0) < cost($1) }!
        panel.setFrame(frame,display:true)
        panel.alphaValue = 0; panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        itemID = item.id
        outside = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] _ in self?.close() }
    }

    /// The first action (Paste) — what ↩ does while the card is open.
    func runPrimary() { if !actions.isEmpty { run(0) } }
    func run(title: String) { if let i = actions.firstIndex(where: { $0.title == title }) { run(i) } }

    @objc private func pressed(_ sender: NSButton) { run(sender.tag) }
    private func run(_ i: Int) { guard actions.indices.contains(i) else { return }; let a = actions[i]; close(); a.run() }

    func close(notify: Bool = true) {
        if let outside { NSEvent.removeMonitor(outside) }; outside = nil
        guard itemID != nil else { return }
        itemID = nil; panel.orderOut(nil); closedAt = CACurrentMediaTime()
        actions.removeAll()
        imageView.image = nil; text.stringValue = ""; meta.stringValue = ""
        if notify { onClose?() }
    }
}

/// Responds to the first click even though the card never becomes the key window.
private final class CardButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.pointingHand) }
}

/// Takes clicks without ever becoming key or activating SilkNest (the user's app keeps focus).
private final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
