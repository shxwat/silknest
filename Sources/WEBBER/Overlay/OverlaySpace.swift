import AppKit

/// Coordinate spaces shared by the overlay panels.
/// - screen: AppKit global points.
/// - desk: points relative to the display's lower-left corner.
/// - motion: the spider simulation's units; one unit is `spiderScale` desk points, which is how the
///   spider is drawn larger without its planted feet sliding.
/// - web: points relative to the compact web panel's lower-left corner.
struct OverlaySpace {
    let screenFrame: NSRect
    let visibleDesk: NSRect
    let spiderScale: CGFloat
    let webOrigin: NSPoint
    let compactWebSize = NSSize(width:500,height:440)

    init(screen: NSScreen, spiderScale: CGFloat) {
        screenFrame = screen.frame
        visibleDesk = screen.visibleFrame.offsetBy(dx:-screen.frame.minX,dy:-screen.frame.minY)
        self.spiderScale = spiderScale
        webOrigin = NSPoint(x:visibleDesk.maxX-compactWebSize.width-10,y:visibleDesk.minY+6)
    }

    func desk(screen p: NSPoint) -> NSPoint { NSPoint(x:p.x-screenFrame.minX,y:p.y-screenFrame.minY) }
    func screen(desk p: NSPoint) -> NSPoint { NSPoint(x:p.x+screenFrame.minX,y:p.y+screenFrame.minY) }
    func motion(desk p: NSPoint) -> V3 { V3(Float(p.x/spiderScale),Float(p.y/spiderScale),0) }
    func desk(motion v: V3) -> NSPoint { NSPoint(x:CGFloat(v.x)*spiderScale,y:CGFloat(v.y)*spiderScale) }
    func web(desk p: NSPoint) -> V3 { V3(Float(p.x-webOrigin.x),Float(p.y-webOrigin.y),0) }
    func desk(web v: V3) -> NSPoint { NSPoint(x:CGFloat(v.x)+webOrigin.x,y:CGFloat(v.y)+webOrigin.y) }

    func motion(screen p: NSPoint) -> V3 { motion(desk:desk(screen:p)) }
    func screen(motion v: V3) -> NSPoint { screen(desk:desk(motion:v)) }
    func web(screen p: NSPoint) -> V3 { web(desk:desk(screen:p)) }
    func screen(web v: V3) -> NSPoint { screen(desk:desk(web:v)) }
    func web(motion v: V3) -> V3 { web(desk:desk(motion:v)) }
    func motion(web v: V3) -> V3 { motion(desk:desk(web:v)) }

    var motionBounds: CGRect {
        CGRect(x:visibleDesk.minX/spiderScale,y:visibleDesk.minY/spiderScale,width:visibleDesk.width/spiderScale,height:visibleDesk.height/spiderScale)
    }
    var compactWebScreenFrame: NSRect { NSRect(origin:screen(desk:webOrigin),size:compactWebSize) }
    var visibleScreenFrame: NSRect { visibleDesk.offsetBy(dx:screenFrame.minX,dy:screenFrame.minY) }
    /// The opened Nest: a compact pane in the middle of the display, about 60% of its visible area
    /// (clamped so it stays usable on a 13" MacBook Air and doesn't sprawl on a large monitor). The web is
    /// thrown out of the display's nest corner on a silk dragline and spreads inside it. Desk points.
    var nestDesk: NSRect { Self.nestRect(in:visibleDesk) }

    static func nestRect(in visible: NSRect) -> NSRect {
        let room = visible.insetBy(dx:14,dy:14)
        let width = min(room.width,min(1100,max(640,visible.width*0.6)))
        let height = min(room.height,min(780,max(480,visible.height*0.6)))
        return NSRect(x:(room.midX-width/2).rounded(),y:(room.midY-height/2).rounded(),width:width.rounded(),height:height.rounded())
    }
    var nestScreenFrame: NSRect { nestDesk.offsetBy(dx:screenFrame.minX,dy:screenFrame.minY) }
    /// What the open web needs to draw: the pane, the folded web in the corner it grows from, and the
    /// dragline between them — not the whole display (the render surface is what costs memory).
    func nestRenderScreenFrame(knot: NSPoint) -> NSRect {
        // The folded web around its launch point is up to ~170 pt across.
        let k = NSRect(x:knot.x-170,y:knot.y-170,width:340,height:340)
        return nestScreenFrame.union(k).insetBy(dx:-8,dy:-8).intersection(visibleScreenFrame).integral
    }
    /// Room kept clear at the top of the pane for the search pill.
    static let nestSearchBand: CGFloat = 52
    /// The opened web's extent in web-local points.
    var expandedWebBounds: CGRect {
        var r = nestDesk.insetBy(dx:26,dy:26); r.size.height -= Self.nestSearchBand
        return r.offsetBy(dx:-webOrigin.x,dy:-webOrigin.y)
    }
    var visibleWebViewport: CGRect { visibleDesk.offsetBy(dx:-webOrigin.x,dy:-webOrigin.y) }
}
