import AppKit
import QuartzCore

/// Click-through layer for catch filaments and objects in flight. Ordered in only while a flight exists,
/// and several flights can run at once so rapid catches never queue behind each other.
final class SilkEffectsLayer {
    private let panel: OverlayPanel
    private let root = CALayer()
    private var screenFrame: NSRect
    private var scale: CGFloat
    private var flights: [SilkFlight] = []

    init(screen: NSScreen, level: NSWindow.Level) {
        screenFrame = screen.frame; scale = screen.backingScaleFactor
        panel = OverlayPanel(contentRect:screen.frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.colorSpace = .sRGB
        panel.level = level; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        let view = NSView(frame:NSRect(origin:.zero,size:screen.frame.size))
        view.layer = root; view.wantsLayer = true; root.backgroundColor = NSColor.clear.cgColor
        panel.contentView = view
        var perspective = CATransform3DIdentity; perspective.m34 = -1/600
        root.sublayerTransform = perspective
    }

    func makeFlight(image: NSImage) -> SilkFlight {
        let flight = SilkFlight(image:image,scale:scale,origin:screenFrame.origin)
        root.addSublayer(flight.container)
        flights.append(flight)
        if flights.count == 1 { panel.orderFrontRegardless() }
        return flight
    }

    func remove(_ flight: SilkFlight) {
        flight.container.removeFromSuperlayer()
        flights.removeAll { $0 === flight }
        if flights.isEmpty { panel.orderOut(nil) }
    }

    func hideAll() { for flight in flights { remove(flight) } }

    func retarget(_ screen: NSScreen) {
        hideAll()
        screenFrame = screen.frame; scale = screen.backingScaleFactor
        panel.setFrame(screen.frame,display:false)
        panel.contentView?.frame = NSRect(origin:.zero,size:screen.frame.size)
    }
}

/// One caught object travelling on silk: the filament, the object, its wrapping, and the cocoon it becomes.
final class SilkFlight {
    let container = CALayer()
    private let shade = CAShapeLayer(), filament = CAShapeLayer(), glint = CAShapeLayer()
    private let object = CALayer()
    /// A bead of light that runs along the strand (the catch glow travelling to the nest).
    private let pulse = CALayer()
    private let wrap = CAShapeLayer()
    private let cocoon: NSImage
    private let preview: NSImage
    private let origin: NSPoint
    private var showingCocoon = false
    private let scale: CGFloat

    init(image: NSImage, scale: CGFloat, origin: NSPoint) {
        preview = image; self.origin = origin; self.scale = scale
        cocoon = ItemPreview.cocoon(image)
        for line in [shade,filament,glint] {
            line.fillColor = nil; line.lineCap = .round; line.contentsScale = scale
            container.addSublayer(line)
        }
        // Silk: very thin, neutral, slightly translucent, with a faint glint and a soft contact shadow.
        shade.strokeColor = NSColor(white:0,alpha:0.16).cgColor; shade.lineWidth = 1.1
        filament.strokeColor = NSColor(srgbRed:0.93,green:0.93,blue:0.90,alpha:0.82).cgColor; filament.lineWidth = 0.7
        // A faint golden highlight along the strand.
        glint.strokeColor = NSColor(srgbRed:1.0,green:0.86,blue:0.55,alpha:0.6).cgColor; glint.lineWidth = 0.4
        object.contentsScale = scale; object.contentsGravity = .resizeAspect
        object.contents = image.layerContents(forContentsScale:scale)
        object.bounds = CGRect(origin:.zero,size:CGSize(width:image.size.width*1.25,height:image.size.height*1.25))
        object.shadowColor = NSColor.black.cgColor; object.shadowOpacity = 0.28; object.shadowRadius = 3; object.shadowOffset = CGSize(width:1,height:-3)
        object.opacity = 0
        wrap.fillColor = nil; wrap.contentsScale = scale; wrap.lineWidth = 0.6
        wrap.strokeColor = NSColor(srgbRed:0.96,green:0.96,blue:0.93,alpha:0.85).cgColor
        wrap.strokeEnd = 0
        object.addSublayer(wrap)
        container.addSublayer(object)
        pulse.bounds = CGRect(x:0,y:0,width:5,height:5); pulse.cornerRadius = 2.5
        pulse.shadowOffset = .zero; pulse.shadowRadius = 5; pulse.shadowOpacity = 1
        pulse.opacity = 0; pulse.contentsScale = scale
        container.addSublayer(pulse)
    }

    /// Screen points. `sag` bows the strand under gravity; 0 is taut. `wrapped` 0…1 spins silk around the object,
    /// and past 1 it has become a small cocoon.
    func update(from start: NSPoint, to end: NSPoint, extent: CGFloat, sag: CGFloat, silkAlpha: CGFloat,
                objectAt center: NSPoint, scale objectScale: CGFloat, tilt: CGFloat, spin: CGFloat, alpha: CGFloat, wrapped: CGFloat,
                pulseAt: CGFloat = -1, pulseHeat: CGFloat = 1) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let a = local(start), tip = local(end)
        let b = CGPoint(x:a.x+(tip.x-a.x)*extent,y:a.y+(tip.y-a.y)*extent)
        let path = CGMutablePath(); path.move(to:a)
        path.addQuadCurve(to:b,control:CGPoint(x:(a.x+b.x)/2,y:(a.y+b.y)/2-sag))
        filament.path = path; glint.path = path
        var offset = CGAffineTransform(translationX:0.8,y:-1.4)
        shade.path = path.copy(using:&offset)
        for line in [shade,filament,glint] { line.opacity = Float(extent > 0.005 ? silkAlpha : 0) }
        // The light bead: `pulseAt` 0 at the strand's start … 1 at its far end; hot red cooling to gold.
        if pulseAt >= 0 && pulseAt <= 1 && extent > 0.005 {
            let t = pulseAt, c = CGPoint(x:(a.x+b.x)/2,y:(a.y+b.y)/2-sag)
            let p = CGPoint(x:(1-t)*(1-t)*a.x+2*(1-t)*t*c.x+t*t*b.x,y:(1-t)*(1-t)*a.y+2*(1-t)*t*c.y+t*t*b.y)
            let h = max(0,min(1,pulseHeat))
            let color = NSColor(srgbRed:1.0,green:0.62*(1-h)+0.18*h,blue:0.12*(1-h)+0.08*h,alpha:1)
            pulse.backgroundColor = color.cgColor; pulse.shadowColor = color.cgColor
            pulse.position = p; pulse.opacity = Float(silkAlpha)
        } else { pulse.opacity = 0 }

        if wrapped >= 1 && !showingCocoon {
            showingCocoon = true
            object.contents = cocoon.layerContents(forContentsScale:scale)
            object.bounds = CGRect(origin:.zero,size:CGSize(width:cocoon.size.width*1.25,height:cocoon.size.height*1.25))
            wrap.isHidden = true
        }
        if !showingCocoon {
            let bounds = object.bounds
            wrap.frame = bounds
            wrap.path = Self.spiral(in:bounds.insetBy(dx:bounds.width*0.06,dy:bounds.height*0.08))
            wrap.strokeEnd = max(0,min(1,wrapped))
        }
        object.position = local(center)
        var t = CATransform3DMakeScale(objectScale,objectScale,1)
        t = CATransform3DRotate(t,spin,0,0,1)
        t = CATransform3DRotate(t,tilt,1,0.3,0)
        object.transform = t
        object.opacity = Float(alpha)
        CATransaction.commit()
    }

    private static func spiral(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let turns = 5.0, steps = 90
        for i in 0...steps {
            let u = Double(i)/Double(steps)
            let angle = u*turns*2 * .pi
            // Diagonal wraps travelling down the object, like silk wound round a parcel.
            let y = rect.maxY-CGFloat(u)*rect.height
            let x = rect.midX+cos(angle)*rect.width*0.5
            let p = CGPoint(x:x,y:y+CGFloat(sin(angle))*rect.height*0.05)
            if i == 0 { path.move(to:p) } else { path.addLine(to:p) }
        }
        return path
    }

    private func local(_ p: NSPoint) -> CGPoint { CGPoint(x:p.x-origin.x,y:p.y-origin.y) }
}
