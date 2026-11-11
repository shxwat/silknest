import AppKit

/// A larger look at a Nest object while the pointer rests on it: the full image, or the text itself.
/// Click-through, no focus, appears after a short rest and leaves the moment the pointer moves away.
final class HoverPreview {
    private let panel: NSPanel
    private let box = NSVisualEffectView()
    private let imageView = NSImageView()
    private let text = NSTextField(wrappingLabelWithString:"")
    private let meta = NSTextField(labelWithString:"")
    private(set) var shownID: Int?
    private var pendingID: Int?
    private var pendingSince: CFTimeInterval = 0
    static let delay: CFTimeInterval = 0.35

    init() {
        panel = NSPanel(contentRect:NSRect(x:0,y:0,width:10,height:10),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue:NSWindow.Level.statusBar.rawValue+5)
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        panel.animationBehavior = .none; panel.isReleasedWhenClosed = false
        box.material = .hudWindow; box.blendingMode = .behindWindow; box.state = .active; box.appearance = NSAppearance(named:.darkAqua)
        box.wantsLayer = true; box.layer?.cornerRadius = 12; box.layer?.masksToBounds = true
        box.layer?.borderWidth = 0.5; box.layer?.borderColor = NSColor(white:1,alpha:0.18).cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown; imageView.wantsLayer = true; imageView.layer?.cornerRadius = 6; imageView.layer?.masksToBounds = true
        text.font = .monospacedSystemFont(ofSize:12.5,weight:.regular); text.textColor = NSColor(white:1,alpha:0.92); text.maximumNumberOfLines = 14
        text.lineBreakMode = .byWordWrapping
        meta.font = .systemFont(ofSize:11,weight:.medium); meta.textColor = NSColor(white:1,alpha:0.5)
        box.addSubview(imageView); box.addSubview(text); box.addSubview(meta)
        panel.contentView = box
    }

    /// Called every tick with the hovered object (or nil) and where it hangs on screen.
    func update(item: ClipboardItem?, anchor: NSRect, now: CFTimeInterval) {
        guard let item else { pendingID = nil; hide(); return }
        if item.id != pendingID { pendingID = item.id; pendingSince = now; if shownID != item.id { hide() } }
        guard shownID != item.id, now-pendingSince >= Self.delay else { return }
        show(item,anchor:anchor)
    }

    func hide() {
        guard shownID != nil else { return }
        shownID = nil; panel.orderOut(nil)
        imageView.image = nil; text.stringValue = ""; meta.stringValue = ""
    }

    private func show(_ item: ClipboardItem, anchor: NSRect) {
        let pad: CGFloat = 12, maxW: CGFloat = 460
        var size: NSSize
        if item.kind == .image, let image = item.displayImage, image.size.width > 0 {
            let k = min(1,min(maxW/image.size.width,320/image.size.height))
            let s = NSSize(width:max(120,image.size.width*k),height:max(60,image.size.height*k))
            imageView.image = image; imageView.isHidden = false; text.isHidden = true
            imageView.frame = NSRect(x:pad,y:pad+20,width:s.width,height:s.height)
            size = NSSize(width:s.width+pad*2,height:s.height+pad*2+20)
        } else {
            imageView.isHidden = true; text.isHidden = false
            text.font = item.kind == .code ? .monospacedSystemFont(ofSize:12.5,weight:.regular) : .systemFont(ofSize:13.5)
            let body = item.kind == .file ? item.fileURLs.map { ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator:"\n") : (item.displayText ?? item.url?.absoluteString ?? item.title)
            text.stringValue = String(body.prefix(1200))
            text.preferredMaxLayoutWidth = maxW-pad*2
            let fit = text.sizeThatFits(NSSize(width:maxW-pad*2,height:300))
            text.frame = NSRect(x:pad,y:pad+20,width:maxW-pad*2,height:min(300,fit.height))
            size = NSSize(width:maxW,height:min(300,fit.height)+pad*2+20)
        }
        var parts = [item.kind.rawValue.capitalized]
        if let s = item.sourceName { parts.append(s) }
        parts.append(RelativeDateTimeFormatter().localizedString(for:item.lastCopied,relativeTo:Date()))
        meta.stringValue = parts.joined(separator:"  ·  ")
        meta.frame = NSRect(x:pad,y:8,width:size.width-pad*2,height:16)
        box.frame = NSRect(origin:.zero,size:size)
        // Beside the object, on the side with more room, kept on screen.
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? NSScreen.main!.visibleFrame
        var x = anchor.maxX+14
        if x+size.width > screen.maxX-8 { x = anchor.minX-14-size.width }
        let y = min(max(anchor.midY-size.height/2,screen.minY+8),screen.maxY-size.height-8)
        x = min(max(x,screen.minX+8),screen.maxX-size.width-8)
        panel.setFrame(NSRect(x:x,y:y,width:size.width,height:size.height),display:true)
        panel.orderFrontRegardless(); shownID = item.id
    }
}
