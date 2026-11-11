import AppKit
import QuartzCore

struct SilkAction {
    let title: String
    let run: () -> Void
}

/// A tiny contextual menu: short silk strands spun out from a point, each ending in a small labelled node.
/// Its panel takes mouse events only while the pointer is over a node; everywhere else clicks pass through.
final class SilkRadialMenu {
    private let panel: OverlayPanel
    private let view: SilkMenuView
    private var outsideMonitor: Any?
    private var timer: Timer?
    private(set) var isOpen = false
    /// The pointer is on one of the menu's entries (everything else passes through to what is below).
    var isOverEntry: Bool { isOpen && view.hovered != nil }
    var onClose: (() -> Void)?
    /// Where the menu is spun from, re-read every frame so the strands stay attached if it moves (the spider).
    private var anchor: (() -> NSPoint)?

    init() {
        panel = OverlayPanel(contentRect:NSRect(x:0,y:0,width:SilkMenuView.side,height:SilkMenuView.side),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.colorSpace = .sRGB
        panel.level = NSWindow.Level(rawValue:NSWindow.Level.statusBar.rawValue+6)
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none; panel.ignoresMouseEvents = true
        view = SilkMenuView(frame:NSRect(x:0,y:0,width:SilkMenuView.side,height:SilkMenuView.side))
        panel.contentView = view
        view.onPick = { [weak self] action in self?.close(); action.run() }
    }

    enum Layout { case radial, column }

    /// `center` in screen coordinates; `toward` is the direction (radians) the arc of nodes should open into.
    /// `clearance`: strands start this far out, so they never cross the spider's body or an object.
    /// `.column` lists the actions neatly beside the object (easier to read than an arc for longer menus).
    func open(at center: NSPoint, toward direction: CGFloat, actions: [SilkAction], radius: CGFloat = 64, clearance: CGFloat = 0, layout: Layout = .radial, following anchor: (() -> NSPoint)? = nil) {
        close(animated:false)
        self.anchor = anchor
        let side = SilkMenuView.side
        let origin = NSPoint(x:center.x-side/2,y:center.y-side/2)
        panel.setFrameOrigin(origin)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        let limit = screen.map { $0.visibleFrame.offsetBy(dx:-origin.x,dy:-origin.y) }
        view.configure(actions:actions,direction:direction,radius:radius,clearance:clearance,column:layout == .column,limit:limit)
        panel.orderFrontRegardless(); isOpen = true
        view.start = CACurrentMediaTime(); view.closing = nil
        timer = Timer(timeInterval:1/60,repeats:true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!,forMode:.common)
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] _ in self?.close() }
    }

    /// Automation: each entry's title and the centre of its label on screen (verification runs click them for real).
    var automationEntries: [[String:Any]] { isOpen ? view.automationEntries(origin:panel.frame.origin) : [] }

    func close(animated: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }; outsideMonitor = nil
        panel.ignoresMouseEvents = true
        if animated { view.closing = CACurrentMediaTime() } else { finish() }
        onClose?()
    }

    private func finish() { timer?.invalidate(); timer = nil; panel.orderOut(nil); view.closing = nil; drawn = nil }

    /// What the menu last drew: an open menu that is not animating, not hovered differently and not
    /// following a moving anchor is left alone (no redraw every frame).
    private var drawn: (hovered: Int?, origin: NSPoint)?

    private func tick() {
        if let closing = view.closing, CACurrentMediaTime()-closing > 0.16 { finish(); return }
        if let anchor {
            let c = anchor(), side = SilkMenuView.side
            let origin = NSPoint(x:(c.x-side/2).rounded(),y:(c.y-side/2).rounded())
            if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        }
        let local = view.convert(panel.convertPoint(fromScreen:NSEvent.mouseLocation),from:nil)
        let hovered = isOpen ? view.node(at:local) : nil
        // Pass-through everywhere except exactly over a node.
        if panel.ignoresMouseEvents != (hovered == nil) { panel.ignoresMouseEvents = hovered == nil }
        let now = CACurrentMediaTime()
        let animating = view.closing != nil || now-view.start < 0.45
        if animating || drawn?.hovered != hovered || drawn?.origin != panel.frame.origin {
            view.hovered = hovered
            view.needsDisplay = true
            drawn = animating ? nil : (hovered,panel.frame.origin)
        }
    }
}

final class SilkMenuView: NSView {
    static let side: CGFloat = 600
    var onPick: ((SilkAction) -> Void)?
    var start: CFTimeInterval = 0
    var closing: CFTimeInterval?
    var hovered: Int?
    private var actions: [SilkAction] = []
    private var nodes: [NSPoint] = []
    private var labelRects: [NSRect] = []
    private let font = NSFont.systemFont(ofSize:12.5,weight:.medium)
    private var clearance: CGFloat = 0
    /// Frosted pills (real background blur) so labels stay readable over any window or wallpaper.
    private var pills: [NSView] = []
    private var pillLabels: [NSTextField] = []

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Clicks on a pill (or its text) are handled here, never swallowed by the subviews.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    func configure(actions: [SilkAction], direction: CGFloat, radius: CGFloat, clearance: CGFloat = 0, column: Bool = false, limit: NSRect? = nil) {
        self.clearance = clearance
        self.actions = actions
        let c = NSPoint(x:bounds.midX,y:bounds.midY)
        if column {
            // A tidy list beside the object, on the side with more room; strands fan out to each entry.
            let side: CGFloat = cos(direction) >= 0 ? 1 : -1
            // Room to breathe: a clear gap between pills, and a gentle arc so the strands fan out
            // instead of bunching onto one corner of the object.
            let spacing: CGFloat = 32
            let mid = CGFloat(actions.count-1)/2
            // Opening downward (e.g. from a note at the top edge): the list starts level with the object
            // and runs down, so nothing pokes up into the menu bar.
            let top = sin(direction) < -0.5 ? c.y-4 : c.y+mid*spacing
            nodes = actions.indices.map { i in
                let u = CGFloat(i)-mid
                return NSPoint(x:c.x+side*(radius+12-u*u*1.8),y:top-CGFloat(i)*spacing)
            }
        } else {
            let spread = min(CGFloat.pi*0.95,CGFloat(actions.count-1)*0.52)
            nodes = actions.enumerated().map { i,_ in
                let u = actions.count == 1 ? 0.5 : CGFloat(i)/CGFloat(actions.count-1)
                // Irregular strand lengths: hand-spun, not a perfect ring.
                let angle = direction-spread/2+spread*u+[0.04,-0.05,0.03,-0.02,0.05][i%5]
                let r = radius*[1.0,0.9,1.06,0.94,1.02][i%5]
                return NSPoint(x:c.x+cos(angle)*r,y:c.y+sin(angle)*r)
            }
        }
        // Each pill is only as wide as its text; in a column their inner edges line up, so it stays tidy
        // without short labels ballooning to the width of the longest one.
        labelRects = zip(nodes,actions).map { node,action in
            let size = (action.title as NSString).size(withAttributes:[.font:font])
            let dx = node.x-c.x, w = size.width+22, h: CGFloat = 24
            // Labels sit just beyond their node, on the outward side.
            let gap: CGFloat = column ? 10 : 6
            let x = abs(dx) < 14 ? node.x-w/2 : (dx > 0 ? node.x+gap : node.x-gap-w)
            let y = abs(dx) < 14 ? (node.y > c.y ? node.y+6 : node.y-6-h) : node.y-h/2
            return NSRect(x:x,y:y,width:w,height:h)
        }
        // Near a screen edge (an item low in the Nest, the spider in a corner) the whole set slides back
        // inside the visible area; strands still run from the object to each node.
        if let limit, let first = labelRects.first {
            let all = zip(labelRects,nodes).reduce(first) { $0.union($1.0).union(NSRect(x:$1.1.x-4,y:$1.1.y-4,width:8,height:8)) }
            let area = limit.insetBy(dx:10,dy:10)
            var dx: CGFloat = 0, dy: CGFloat = 0
            if all.minX < area.minX { dx = area.minX-all.minX } else if all.maxX > area.maxX { dx = area.maxX-all.maxX }
            if all.minY < area.minY { dy = area.minY-all.minY } else if all.maxY > area.maxY { dy = area.maxY-all.maxY }
            if dx != 0 || dy != 0 {
                nodes = nodes.map { NSPoint(x:$0.x+dx,y:$0.y+dy) }
                labelRects = labelRects.map { $0.offsetBy(dx:dx,dy:dy) }
            }
        }
        for v in pills { v.removeFromSuperview() }
        pills = []; pillLabels = []
        for (rect,action) in zip(labelRects,actions) {
            // Solid tinted pills: a live behind-window blur re-samples the desktop every frame and
            // shimmers while the pills fade in or follow the spider.
            let pill = NSView(frame:rect)
            pill.wantsLayer = true; pill.layer?.cornerRadius = rect.height/2; pill.layer?.masksToBounds = true
            pill.layer?.backgroundColor = NSColor(srgbRed:0.07,green:0.075,blue:0.09,alpha:0.9).cgColor
            pill.layer?.actions = ["backgroundColor":NSNull(),"borderColor":NSNull(),"opacity":NSNull()]
            pill.layer?.borderWidth = 0.5; pill.layer?.borderColor = NSColor(white:1,alpha:0.16).cgColor
            pill.alphaValue = 0
            let label = NSTextField(labelWithString:action.title)
            label.font = font; label.textColor = NSColor(white:1,alpha:0.97); label.alignment = .center
            let shadow = NSShadow(); shadow.shadowColor = NSColor(white:0,alpha:0.6); shadow.shadowBlurRadius = 2; shadow.shadowOffset = NSSize(width:0,height:-0.5)
            label.shadow = shadow
            label.frame = NSRect(x:0,y:(rect.height-17)/2,width:rect.width,height:17)
            pill.addSubview(label)
            addSubview(pill); pills.append(pill); pillLabels.append(label)
        }
    }

    func automationEntries(origin: NSPoint) -> [[String:Any]] {
        zip(actions,labelRects).map { ["title":$0.title,"x":Double(origin.x+$1.midX),"y":Double(origin.y+$1.midY)] }
    }

    func node(at p: NSPoint) -> Int? {
        for (i,rect) in labelRects.enumerated() where rect.insetBy(dx:-4,dy:-4).contains(p) || hypot(p.x-nodes[i].x,p.y-nodes[i].y) < 10 { return i }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        if let i = node(at:convert(event.locationInWindow,from:nil)) { onPick?(actions[i]) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = CACurrentMediaTime()
        let opening = min(1,(now-start)/0.2)
        let shut = closing.map { min(1,(now-$0)/0.15) } ?? 0
        let grow = CGFloat(smoothstep(opening))*(1-CGFloat(smoothstep(shut)))
        guard grow > 0.01 else { pills.forEach { $0.alphaValue = 0 }; return }
        let c = NSPoint(x:bounds.midX,y:bounds.midY)
        for (i,node) in nodes.enumerated() {
            let stagger = CGFloat(smoothstep(min(1,max(0,(opening*1.25-Double(i)*0.06)))))*(1-CGFloat(smoothstep(shut)))
            let d = max(1,hypot(node.x-c.x,node.y-c.y)), k = max(0.18,min(0.85,clearance/d))
            let start = NSPoint(x:c.x+(node.x-c.x)*k,y:c.y+(node.y-c.y)*k)
            let end = NSPoint(x:start.x+(node.x-start.x)*stagger,y:start.y+(node.y-start.y)*stagger)
            // Sag toward gravity until the strand is fully out, then it tightens.
            let sag = (1-stagger)*7+(hovered == i ? 0 : 1.2)
            let mid = NSPoint(x:(start.x+end.x)/2,y:(start.y+end.y)/2-sag)
            let strand = NSBezierPath(); strand.move(to:start); strand.curve(to:end,controlPoint1:mid,controlPoint2:mid)
            strand.lineWidth = hovered == i ? 0.9 : 0.6
            NSColor(white:0,alpha:0.18*stagger).setStroke()
            let shadow = strand.copy() as! NSBezierPath; shadow.transform(using:AffineTransform(translationByX:0.6,byY:-0.8)); shadow.stroke()
            NSColor(srgbRed:0.95,green:0.95,blue:0.92,alpha:0.78*stagger).setStroke(); strand.stroke()
            let dot = NSRect(x:end.x-2.4,y:end.y-2.4,width:4.8,height:4.8)
            NSColor(srgbRed:0.93,green:0.93,blue:0.9,alpha:0.9*stagger).setFill(); NSBezierPath(ovalIn:dot).fill()
            // Pills fade in as their strand arrives; the hovered one brightens.
            let alpha = stagger > 0.6 ? (stagger-0.6)/0.4 : 0
            if i < pills.count {
                pills[i].alphaValue = alpha
                // A dark tint inside the blur keeps white text legible even over white pages.
                pills[i].layer?.backgroundColor = (hovered == i ? NSColor(srgbRed:0.24,green:0.22,blue:0.18,alpha:0.95) : NSColor(srgbRed:0.07,green:0.075,blue:0.09,alpha:0.9)).cgColor
                pills[i].layer?.borderColor = NSColor(white:1,alpha:hovered == i ? 0.45 : 0.16).cgColor
            }
        }
    }

    private func smoothstep(_ x: Double) -> Double { let t = min(1,max(0,x)); return t*t*(3-2*t) }
}
