import AppKit
import QuartzCore

/// The only permanent trace of the hidden nest: a corner of gold web in the screen corner, the nest's
/// little spider sitting on it, a bead of light per catch and a gold pill with the count. Click-through.
final class NestMarker {
    private let panel: OverlayPanel
    private let view: NestMarkerView
    static let size = NSSize(width:120,height:110)

    init(screen: NSScreen, level: NSWindow.Level) {
        let visible = screen.visibleFrame
        let frame = NSRect(x:visible.maxX-Self.size.width,y:visible.minY,width:Self.size.width,height:Self.size.height)
        panel = OverlayPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.colorSpace = .sRGB
        panel.level = level; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        view = NestMarkerView(frame:NSRect(origin:.zero,size:Self.size))
        panel.contentView = view
    }

    /// Where a caught object is pulled to before it vanishes into the nest (screen coordinates).
    /// Where the knot sits on a display (screen coordinates), whether or not the marker is shown there.
    static func knot(onVisibleFrame visible: NSRect) -> NSPoint {
        NSPoint(x:visible.maxX-size.width+NestMarkerView.knotPoint.x,y:visible.minY+NestMarkerView.knotPoint.y)
    }
    var knot: NSPoint { NSPoint(x:panel.frame.minX+view.knot.x,y:panel.frame.minY+view.knot.y) }

    func retarget(_ screen: NSScreen) {
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x:visible.maxX-Self.size.width,y:visible.minY,width:Self.size.width,height:Self.size.height),display:true)
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }

    func setCount(_ count: Int, arrived: Bool) {
        view.count = count
        if arrived { view.bump() } else { view.needsDisplay = true }
    }
}

final class NestMarkerView: NSView {
    var count = 0 { didSet { needsDisplay = true } }
    static let knotPoint = CGPoint(x:84,y:58)
    let knot = NestMarkerView.knotPoint
    private var swing: CGFloat = 0
    private var swingStart: CFTimeInterval = 0
    private var timer: Timer?

    override var isOpaque: Bool { false }

    func bump() {
        swingStart = CACurrentMediaTime(); swing = 1
        timer?.invalidate()
        timer = Timer(timeInterval:1/60,repeats:true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let age = CACurrentMediaTime()-self.swingStart
            self.swing = CGFloat(exp(-age*4.5)*cos(age*15))
            self.needsDisplay = true
            if age > 1.2 { self.swing = 0; t.invalidate() }
        }
        RunLoop.main.add(timer!,forMode:.common)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let empty = count == 0
        let gold = NSColor(srgbRed:1.0,green:0.74,blue:0.26,alpha:1)
        // A corner of web anchored in the screen's corner; the spider sits on it at the knot.
        let corner = CGPoint(x:bounds.maxX+6,y:bounds.minY-6)
        let toKnot = CGPoint(x:knot.x-corner.x,y:knot.y-corner.y)
        let reach = hypot(toKnot.x,toKnot.y), knotAngle = atan2(toKnot.y,toKnot.x)
        let angles: [CGFloat] = [knotAngle-0.62,knotAngle-0.3,knotAngle,knotAngle+0.32,knotAngle+0.6]
        let wobble = swing*1.6
        let radii: [CGFloat] = [reach*0.42,reach*0.7,reach,reach*1.3]
        func point(_ a: CGFloat, _ r: CGFloat) -> CGPoint { CGPoint(x:corner.x+cos(a)*r,y:corner.y+sin(a)*r) }
        let alpha: CGFloat = empty ? 0.18 : 0.34
        let web = NSBezierPath(); web.lineWidth = 0.6; web.lineCapStyle = .round
        for a in angles { web.move(to:corner); web.line(to:point(a,reach*1.42)) }
        for (i,r) in radii.enumerated() {
            // Each ring sags a little between spokes, like real silk; a new catch sets it trembling.
            let sway = wobble*(i % 2 == 0 ? 1 : -1)
            web.move(to:point(angles[0],r))
            for k in 1..<angles.count {
                let a0 = angles[k-1], a1 = angles[k], mid = (a0+a1)/2
                web.curve(to:point(a1,r),controlPoint1:point(mid,r*0.93+sway),controlPoint2:point(mid,r*0.93+sway))
            }
        }
        gold.withAlphaComponent(alpha).setStroke(); web.stroke()
        // A few beads of light on the silk, one per catch (up to five).
        let beads: [(Int,Int)] = [(1,1),(3,1),(0,2),(4,2),(2,3)]
        for (i,(spoke,ring)) in beads.prefix(min(count,5)).enumerated() {
            let p = point(angles[spoke],radii[ring]+wobble*(i % 2 == 0 ? 1.2 : -1.2))
            ctx.saveGState()
            ctx.setShadow(offset:.zero,blur:4,color:gold.withAlphaComponent(0.8).cgColor)
            gold.withAlphaComponent(0.9).setFill(); NSBezierPath(ovalIn:NSRect(x:p.x-1.4,y:p.y-1.4,width:2.8,height:2.8)).fill()
            ctx.restoreGState()
        }
        // Soft glow behind the nest's spider.
        if !empty, let glow = CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB),
                                          colors:[gold.withAlphaComponent(0.3).cgColor,gold.withAlphaComponent(0).cgColor] as CFArray,locations:[0,1]) {
            ctx.drawRadialGradient(glow,startCenter:knot,startRadius:0,endCenter:knot,endRadius:16,options:[])
        }
        MiniSpider.image.draw(in:NSRect(x:knot.x-9,y:knot.y-9,width:18,height:18),from:.zero,operation:.sourceOver,fraction:empty ? 0.55 : 1)
        // How many catches are in the nest: a small gold pill beside the spider.
        guard !empty else { return }
        let text = (count > 999 ? "999+" : "\(count)") as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize:10.5,weight:.bold),
                                                     .foregroundColor:NSColor(srgbRed:0.11,green:0.075,blue:0.02,alpha:1)]
        let size = text.size(withAttributes:attrs)
        let scale = 1+0.14*abs(swing)
        let w = max(18,size.width+11)*scale, h = 16*scale
        let pill = NSRect(x:knot.x-13-w,y:knot.y-h/2+1,width:w,height:h)
        ctx.saveGState()
        ctx.setShadow(offset:CGSize(width:0,height:-1),blur:5,color:NSColor(white:0,alpha:0.5).cgColor)
        let shape = NSBezierPath(roundedRect:pill,xRadius:h/2,yRadius:h/2)
        NSGradient(colors:[NSColor(srgbRed:1,green:0.85,blue:0.5,alpha:1),NSColor(srgbRed:0.95,green:0.66,blue:0.2,alpha:1)])!.draw(in:shape,angle:-90)
        ctx.restoreGState()
        text.draw(at:CGPoint(x:pill.midX-size.width/2,y:pill.midY-size.height/2),withAttributes:attrs)
    }
}

/// The Paste Stack, shown as a short strand of tiny previews beside the nest: the lowest one pastes next.
final class StackMarker {
    private let panel: OverlayPanel
    private let view = StackMarkerView(frame:NSRect(x:0,y:0,width:64,height:250))

    init(screen: NSScreen, level: NSWindow.Level) {
        panel = OverlayPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.colorSpace = .sRGB
        panel.level = level; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        panel.contentView = view
        retarget(screen)
    }

    func retarget(_ screen: NSScreen) {
        let v = screen.visibleFrame
        panel.setFrame(NSRect(x:v.maxX-130,y:v.minY+100,width:64,height:250),display:true)
    }

    func show(_ stack: [ClipboardItem]) {
        view.items = stack.prefix(6).map(\.preview); view.total = stack.count
        view.needsDisplay = true
        if stack.isEmpty { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }
}

final class StackMarkerView: NSView {
    var items: [NSImage] = []
    var total = 0
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let silk = NSColor(srgbRed:0.93,green:0.93,blue:0.9,alpha:0.6)
        let strand = NSBezierPath(); strand.move(to:NSPoint(x:bounds.midX,y:bounds.maxY)); strand.line(to:NSPoint(x:bounds.midX,y:8))
        strand.lineWidth = 0.6; silk.setStroke(); strand.stroke()
        // Next to paste at the bottom, the rest queued above it.
        var y: CGFloat = 12
        for (i,image) in items.enumerated() {
            let fit = min(44/image.size.width,30/image.size.height)
            let size = NSSize(width:image.size.width*fit,height:image.size.height*fit)
            let rect = NSRect(x:bounds.midX-size.width/2,y:y,width:size.width,height:size.height)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width:0,height:-1.5); shadow.shadowColor = NSColor(white:0,alpha:0.4); shadow.set()
            image.draw(in:rect,from:.zero,operation:.sourceOver,fraction:i == 0 ? 1 : 0.8)
            NSGraphicsContext.restoreGraphicsState()
            if i == 0 {
                ("next ⌘V" as NSString).draw(at:NSPoint(x:bounds.midX-20,y:max(0,y-11)),withAttributes:[.font:NSFont.systemFont(ofSize:8,weight:.semibold),.foregroundColor:NSColor(white:1,alpha:0.8)])
            }
            y += size.height+10
        }
        // A small counter at the top of the strand: how many pastes are queued.
        let label = "Stack \(total)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font:NSFont.systemFont(ofSize:9,weight:.bold),.foregroundColor:NSColor(white:0.08,alpha:1)]
        let size = label.size(withAttributes:attrs)
        let pill = NSRect(x:bounds.midX-size.width/2-5,y:bounds.maxY-size.height-6,width:size.width+10,height:size.height+3)
        NSColor(srgbRed:1,green:0.78,blue:0.32,alpha:0.92).setFill(); NSBezierPath(roundedRect:pill,xRadius:pill.height/2,yRadius:pill.height/2).fill()
        label.draw(at:NSPoint(x:pill.minX+5,y:pill.minY+1.5),withAttributes:attrs)
        if total > items.count {
            ("+\(total-items.count)" as NSString).draw(at:NSPoint(x:bounds.midX-8,y:min(bounds.maxY-14,y)),withAttributes:[.font:NSFont.systemFont(ofSize:9,weight:.semibold),.foregroundColor:NSColor(white:1,alpha:0.7)])
        }
    }
}
