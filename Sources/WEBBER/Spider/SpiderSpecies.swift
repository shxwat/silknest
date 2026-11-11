import AppKit
import simd

/// One look-and-feel for the same spider rig: colours, proportions, hair, eyes, markings, size and gait.
/// Every species has exactly the same behaviour and features; only the animal changes.
struct SpiderSpecies: Equatable {
    enum Marking: Equatable { case none, hourglass, jumperStripes, chevrons, tarantula }

    let id: String
    let name: String
    let carapace: V3
    let abdomen: V3
    let leg: V3
    /// Patella "knee" band colour (tarantula/house spider rings); nil = same as the leg.
    let band: V3?
    let hinge: V3
    let fiber: V3
    let roughness: CGFloat
    let clearCoat: CGFloat
    let marking: Marking
    let carapaceScale: V3
    let abdomenScale: V3
    let legThickness: Float
    /// Multiplies hair count and length on body and legs.
    let hairiness: Float
    /// Front median eyes (huge on a jumping spider).
    let frontEyes: Float
    /// Neon hunter: emissive limbs, rim light and halo.
    let glow: Bool
    /// Desktop points per motion unit (overall size).
    let scale: CGFloat
    let speed: Float, acceleration: Float, gaitTempo: Float

    /// The original rig colours, used by Spider Study and the render audit.
    static let classic = SpiderSpecies(id:"classic",name:"Classic",carapace:V3(0.045,0.13,0.125),abdomen:V3(0.13,0.07,0.16),leg:V3(0.045,0.13,0.125),band:nil,
        hinge:V3(0.035,0.050,0.055),fiber:V3(0.10,0.12,0.12),roughness:0.72,clearCoat:0.42,marking:.none,carapaceScale:V3(1,1,1),abdomenScale:V3(1,1,1),
        legThickness:1,hairiness:1,frontEyes:1,glow:false,scale:1.25,speed:75,acceleration:140,gaitTempo:1)

    static let neon = SpiderSpecies(id:"neon",name:"Spider",carapace:V3(0.05,0.045,0.04),abdomen:V3(0.06,0.045,0.035),leg:V3(0.16,0.11,0.04),band:nil,
        hinge:V3(0.035,0.050,0.055),fiber:V3(0.10,0.12,0.12),roughness:0.6,clearCoat:0.42,marking:.none,carapaceScale:V3(1,1,1),abdomenScale:V3(1,1,1),
        legThickness:1,hairiness:1,frontEyes:1.55,glow:true,scale:1.25,speed:290,acceleration:1300,gaitTempo:0.42)

    /// WEBBER has one spider: the neon hunter.
    static let all: [SpiderSpecies] = [.neon]
    static func named(_ id: String?) -> SpiderSpecies { all.first { $0.id == id } ?? .neon }
    /// The same spider drawn larger or smaller (development: close-up recordings).
    func scaled(_ factor: CGFloat) -> SpiderSpecies {
        SpiderSpecies(id:id+"@\(factor)",name:name,carapace:carapace,abdomen:abdomen,leg:leg,band:band,hinge:hinge,fiber:fiber,roughness:roughness,
                      clearCoat:clearCoat,marking:marking,carapaceScale:carapaceScale,abdomenScale:abdomenScale,legThickness:legThickness,
                      hairiness:hairiness,frontEyes:frontEyes,glow:glow,scale:scale*factor,speed:speed,acceleration:acceleration,gaitTempo:gaitTempo)
    }

    /// Dorsal markings painted onto the abdomen shell's UVs (u: around the body, dorsal at 0.25; v: front → back).
    func abdomenTexture() -> NSImage? {
        guard marking != .none else { return nil }
        let w: CGFloat = 512, h: CGFloat = 256
        let base = NSColor(srgbRed:CGFloat(abdomen.x),green:CGFloat(abdomen.y),blue:CGFloat(abdomen.z),alpha:1)
        // Drawn flipped so v = 0 (the front of the abdomen) is the top row of the texture.
        return NSImage(size:NSSize(width:w,height:h),flipped:true) { rect in
            base.setFill(); rect.fill()
            let cx = w*0.25
            func at(_ u: CGFloat, _ v: CGFloat) -> NSPoint { NSPoint(x:cx+u*w,y:v*h) }
            switch self.marking {
            case .hourglass:
                NSColor(srgbRed:0.85,green:0.05,blue:0.04,alpha:1).setFill()
                let top = NSBezierPath(); top.move(to:at(-0.05,0.5)); top.line(to:at(0.05,0.5)); top.line(to:at(0,0.64)); top.close(); top.fill()
                let bottom = NSBezierPath(); bottom.move(to:at(0,0.66)); bottom.line(to:at(0.055,0.82)); bottom.line(to:at(-0.055,0.82)); bottom.close(); bottom.fill()
            case .jumperStripes:
                let white = NSColor(srgbRed:0.92,green:0.91,blue:0.88,alpha:1); white.setFill()
                NSBezierPath(roundedRect:NSRect(x:cx-0.14*w,y:0.06*h,width:0.28*w,height:0.09*h),xRadius:8,yRadius:8).fill()
                // Two pairs of small white spots on the rear half, as on Phidippus.
                for (u,v) in [(-0.06,0.58),(0.06,0.58),(-0.045,0.78),(0.045,0.78)] as [(CGFloat,CGFloat)] {
                    NSBezierPath(ovalIn:NSRect(origin:at(u-0.015,v),size:NSSize(width:0.03*w,height:0.06*h))).fill()
                }
            case .chevrons:
                NSColor(srgbRed:0.36,green:0.26,blue:0.16,alpha:1).setFill()
                NSBezierPath(rect:NSRect(x:cx-0.12*w,y:0,width:0.24*w,height:h)).fill()
                NSColor(srgbRed:0.09,green:0.06,blue:0.04,alpha:1).setStroke()
                for k in 0..<6 {
                    let v = 0.18+CGFloat(k)*0.13
                    let c = NSBezierPath(); c.lineWidth = 7; c.move(to:at(-0.1,v)); c.line(to:at(0,v+0.07)); c.line(to:at(0.1,v)); c.stroke()
                }
                // A few lighter flecks for a mottled look.
                NSColor(srgbRed:0.45,green:0.34,blue:0.22,alpha:0.7).setFill()
                for k in 0..<40 { let u = CGFloat((k*37)%100)/100, v = CGFloat((k*61)%100)/100; NSBezierPath(ovalIn:NSRect(x:u*w,y:v*h,width:6,height:4)).fill() }
            case .tarantula:
                // Dark velvet with sparse reddish urticating hairs on the rear.
                NSColor(srgbRed:0.35,green:0.12,blue:0.06,alpha:0.45).setFill()
                for k in 0..<160 { let u = CGFloat((k*53)%100)/100, v = 0.35+0.65*CGFloat((k*29)%100)/100; NSBezierPath(rect:NSRect(x:u*w,y:v*h,width:2,height:5)).fill() }
            case .none: break
            }
            return true
        }
    }
}
