import Foundation
import simd

/// Pure geometry of the orb web at an expansion amount `e` (0 = compact corner web, 1 = across the display).
/// Everything is in web-local points: the compact web panel's lower-left corner is the origin.
struct WebGeometry {
    struct Strand { let angle: Float; let compactLength: Float; let delay: Float; let reach: Float }
    struct Slot { let strand: Int; let fraction: Float }

    let compactHub: V3
    let expandedHub: V3
    /// The region the opened web may cover (web-local), already inset from the screen edges.
    let expandedBounds: CGRect
    let strands: [Strand]
    let ringFractions: [Float]
    private(set) var slots: [Slot] = []

    init(compactHub: V3, expandedBounds: CGRect) {
        self.compactHub = compactHub; self.expandedBounds = expandedBounds
        // The hub travels toward the middle of the display, staying slightly biased to its corner.
        expandedHub = V3(Float(expandedBounds.midX+expandedBounds.width*0.06),Float(expandedBounds.midY-expandedBounds.height*0.04),0)
        let irregular: [Float] = [-0.06,0.03,-0.035,0.05,-0.02,0.045,-0.04,0.025,0.012,-0.05,0.035,-0.012,0.02,-0.03]
        let count = irregular.count
        strands = (0..<count).map { i in
            let angle = Float(i)*2 * .pi/Float(count)+irregular[i]
            // The first strands to tension are the ones nearest the corner; outer ones follow.
            return Strand(angle:angle,compactLength:152+Float((i*17)%19),delay:0.16*Float((i*5)%count)/Float(count),reach:0.93+0.05*sin(Float(i)*2.3))
        }
        ringFractions = (0..<8).map { 0.16+Float($0)*0.105 }
        // Twelve anchors spread over the web; the first ones are the most readable in the compact web.
        let primary: [Slot] = [(4,0.62),(1,0.58),(8,0.66),(11,0.6),(6,0.84),(2,0.86),(13,0.8),(9,0.88),(3,0.38),(7,0.42),(12,0.4),(10,0.36)].map { Slot(strand:$0.0,fraction:$0.1) }
        // Older items fill further anchors: picked greedily from a lattice so every anchor keeps room
        // to be read and grabbed when the Nest is open.
        let geometry = self
        func openAnchor(_ slot: Slot) -> V3 {
            geometry.expandedHub+geometry.direction(slot.strand)*geometry.expandedLength(slot.strand)*slot.fraction
        }
        let strandCount = strands.count
        // A smaller Nest keeps all 30 anchors by letting them sit a little closer (never under 70 pt).
        for spacing: Float in [96,84,76,70] {
            slots = primary
            var used = primary.map(openAnchor)
            for level in [Float(0.9),0.52,0.72,0.36,0.62,0.82,0.44] {
                for k in 0..<strandCount where slots.count < 30 {
                    let candidate = Slot(strand:(k*5+3) % strandCount,fraction:level)
                    let p = openAnchor(candidate)
                    if used.allSatisfy({ simd_distance($0,p) > spacing }) { slots.append(candidate); used.append(p) }
                }
            }
            if slots.count >= 30 { break }
        }
    }

    func hub(_ e: Float) -> V3 { mix(compactHub,expandedHub,smooth(e)) }
    func direction(_ i: Int) -> V3 { V3(cos(strands[i].angle),sin(strands[i].angle),0) }

    /// Strand length at expansion `e`. Strands extend in a short stagger; `e` slightly above 1 overshoots.
    func length(_ i: Int, _ e: Float) -> Float {
        let s = strands[i]
        let local = max(0,(e-s.delay)/(1-s.delay))
        return mix(s.compactLength,expandedLength(i),local)
    }

    /// Distance from the expanded hub to the screen edge along strand `i`.
    func expandedLength(_ i: Int) -> Float {
        let d = direction(i), h = expandedHub
        var t = Float.greatestFiniteMagnitude
        if d.x > 0.0001 { t = min(t,(Float(expandedBounds.maxX)-h.x)/d.x) }
        if d.x < -0.0001 { t = min(t,(Float(expandedBounds.minX)-h.x)/d.x) }
        if d.y > 0.0001 { t = min(t,(Float(expandedBounds.maxY)-h.y)/d.y) }
        if d.y < -0.0001 { t = min(t,(Float(expandedBounds.minY)-h.y)/d.y) }
        return max(strands[i].compactLength,t*strands[i].reach)
    }

    func radialPoint(_ i: Int, fraction: Float, _ e: Float) -> V3 { hub(e)+direction(i)*length(i,e)*fraction }

    func anchor(slot: Int, _ e: Float) -> V3 {
        let s = slots[slot % slots.count]
        return radialPoint(s.strand,fraction:s.fraction,e)
    }

    /// A second, reinforcing attachment point for pinned items: the same ring on the neighbouring strand.
    func reinforcement(slot: Int, _ e: Float) -> V3 {
        let s = slots[slot % slots.count]
        return radialPoint((s.strand+1)%strands.count,fraction:s.fraction*0.94,e)
    }

    /// Radials and capture spiral as straight-ish segments. Spiral segments sag slightly toward the hub,
    /// carry small irregularities, and a few are missing, as in a real orb web.
    func edges(_ e: Float) -> [(V3,V3)] {
        var result: [(V3,V3)] = []
        let h = hub(e)
        for i in strands.indices { result.append((h,h+direction(i)*length(i,e))) }
        let count = strands.count
        for (k,f) in ringFractions.enumerated() {
            for i in 0..<count {
                let j = (i+1)%count
                let seed = hash(i,k)
                if seed < 0.05 { continue }
                let a = h+direction(i)*length(i,e)*(f+0.022*(hash(k,i)-0.5))
                let b = h+direction(j)*length(j,e)*(f+0.022*(hash(k,j)-0.5))
                let mid = (a+b)*0.5
                let inward = h-mid, inwardLength = simd_length(inward)
                let sag = inwardLength > 0.001 ? inward/inwardLength*simd_distance(a,b)*(0.035+0.03*seed) : .zero
                let m1 = mix(a,b,0.33)+sag*0.85, m2 = mix(a,b,0.67)+sag*0.85
                result += [(a,m1),(m1,m2),(m2,b)]
            }
        }
        return result
    }

    /// Deterministic 0…1 noise, so the same web always has the same imperfections.
    private func hash(_ a: Int, _ b: Int) -> Float {
        let x = sin(Float(a)*12.9898+Float(b)*78.233)*43758.5453
        return x-floor(x)
    }
}
