import AppKit
import simd

/// Catch Copy as non-blocking flights into the hidden nest. Nothing here ever waits on the user or makes
/// the spider walk: the caught object is wrapped and a tensioned strand pulls it off toward the nest.
///
/// - rich:  spider idle and the pointer nearby → notice, cast, tension, pull, spider catches and wraps, send (~1.6 s)
/// - fast:  spider far from the pointer → short cast, pull, quick wrap, send (~0.8 s)
/// - snap:  a catch is already in flight or the spider is busy → appear, wrap, send (~0.45 s)
final class CatchSequence {
    enum Mode: String { case rich, fast, snap }
    enum Phase: String { case alert, cast, pull, wrap, sendToNest }

    /// Screen point the cocoons are pulled into.
    var nestPoint: () -> NSPoint = { .zero }
    var reduceMotion = false
    /// The object has entered the nest.
    var onArrive: ((ClipboardItem) -> Void)?

    private let motion: SpiderMotion
    var renderer: SpiderRenderer
    private let effects: SilkEffectsLayer
    var space: OverlaySpace
    private var flights: [Flight] = []
    private var glanceTime: Float?
    private var suppressParcel = false

    var isActive: Bool { !flights.isEmpty }
    var phase: Phase? { flights.first?.phase }
    var lastMode: Mode?

    private final class Flight {
        let item: ClipboardItem
        let mode: Mode
        let silk: SilkFlight
        var time: Float
        var source: NSPoint
        var caught = false
        var handedOff = false
        var lastObject = NSPoint.zero
        var phase: Phase = .alert
        init(item: ClipboardItem, mode: Mode, silk: SilkFlight, source: NSPoint, time: Float = 0) {
            self.item = item; self.mode = mode; self.silk = silk; self.source = source; self.time = time
        }
    }

    init(motion: SpiderMotion, renderer: SpiderRenderer, effects: SilkEffectsLayer, space: OverlaySpace) {
        self.motion = motion; self.renderer = renderer; self.effects = effects; self.space = space
    }

    /// The spider can perform a catch (not already pouncing, not paused).
    var spiderAvailable: Bool { !motion.paused && motion.state != .catching && motion.state != .settling }

    /// Start a catch. `source` is the perceived origin of the copied object (screen point).
    func start(_ item: ClipboardItem, from source: NSPoint, mode requested: Mode) {
        let mode: Mode = (requested != .snap && (!spiderAvailable || flights.contains { $0.mode != .snap && !$0.caught })) ? .snap : requested
        let flight = Flight(item:item,mode:mode,silk:effects.makeFlight(image:item.preview),source:source)
        if mode != .snap {
            motion.notice(space.motion(screen:source))
            if mode == .fast { suppressParcel = true }
        }
        flights.append(flight); lastMode = mode
        draw(flight)
    }

    /// A drop onto the spider: already in reach, so it is caught and wrapped where it was dropped.
    func startDropped(_ item: ClipboardItem, at screenPoint: NSPoint) {
        let flight = Flight(item:item,mode:.fast,silk:effects.makeFlight(image:item.preview),source:screenPoint,time:0.15)
        suppressParcel = true
        flights.append(flight); lastMode = .fast
        draw(flight)
    }

    /// Nothing usable (empty, concealed, or already caught): a brief look, no catch.
    func glance(toward source: NSPoint) {
        guard spiderAvailable, flights.isEmpty else { return }
        motion.notice(space.motion(screen:source)); glanceTime = 0
    }

    // MARK: timeline

    private var mouth: NSPoint { space.screen(motion:motion.body(V3(0,33,0))) }
    private var silkOrigin: NSPoint { space.screen(motion:motion.body(V3(0,24,0))) }
    private var catchPoint: NSPoint { space.screen(motion:motion.body(V3(0,54,0))) }

    /// Durations (seconds) per mode: cast start, cast end, pull start, pull end, wrap end, send end.
    private func times(_ mode: Mode, extra x: Float = 0) -> (cast0: Float, cast1: Float, pull0: Float, pull1: Float, wrap1: Float, send1: Float) {
        switch mode {
        case .rich: return (0.05,0.27+x*0.4,0.37+x*0.4,0.75+x,1.35+x,1.65+x)
        case .fast: return (0.03,0.15+x*0.4,0.15+x*0.4,0.35+x,0.53+x,0.81+x)
        case .snap: return (0,0,0,0.08,0.2,0.45)
        }
    }

    /// Extra seconds for a long throw: the silk travels to the real source, so far casts take a little longer.
    private func reach(_ f: Flight) -> Float {
        guard f.mode != .snap else { return 0 }
        let d = Float(hypot(f.source.x-silkOrigin.x,f.source.y-silkOrigin.y))
        return min(0.45,max(0,(d-200)/2200))
    }

    func update(dt: Float) {
        if let t = glanceTime {
            glanceTime = t+dt
            if t+dt > 0.75 { motion.endNotice(); glanceTime = nil }
        }
        for flight in flights { flight.time += dt; draw(flight) }
        let done = flights.filter { $0.time > times($0.mode,extra:reach($0)).send1 }
        for flight in done {
            effects.remove(flight.silk)
            onArrive?(flight.item)
        }
        flights.removeAll { f in done.contains { $0 === f } }
        if flights.isEmpty && motion.state != .catching { suppressParcel = false; renderer.parcelImage = nil }
        renderer.parcelHidden = suppressParcel
    }

    private func draw(_ f: Flight) {
        let k = times(f.mode,extra:reach(f)), t = f.time
        let nest = nestPoint()
        // Fast catches materialise a short cast away from the spider, toward where the user is.
        let source: NSPoint
        switch f.mode {
        case .rich: source = f.source
        case .fast: source = f.source
        case .snap: source = NSPoint(x:mouth.x+18,y:mouth.y+22)
        }

        if t < k.cast1 && f.mode != .snap {
            // Cast: a thin filament is projected outward; the object appears at its far end.
            f.phase = t < k.cast0 ? .alert : .cast
            let extent = CGFloat(smooth((t-k.cast0)/(k.cast1-k.cast0)))
            let distance = hypot(source.x-silkOrigin.x,source.y-silkOrigin.y)
            let appear = CGFloat(smooth((t-mix(k.cast0,k.cast1,0.55))/((k.cast1-k.cast0)*0.45)))
            f.lastObject = source
            f.silk.update(from:silkOrigin,to:source,extent:extent,sag:distance*(0.09-0.04*extent),silkAlpha:1,objectAt:source,
                          scale:0.7+0.3*appear,tilt:0.3*(1-appear),spin:0,alpha:appear,wrapped:0)
        } else if t < k.pull1 {
            // Tension then pull: the strand straightens and reels the object toward the forelegs.
            f.phase = .pull
            if f.mode == .snap {
                let appear = CGFloat(smooth(t/k.pull1))
                f.lastObject = source
                f.silk.update(from:mouth,to:source,extent:0,sag:0,silkAlpha:0,objectAt:source,scale:0.5+0.3*appear,tilt:0,spin:0,alpha:appear,wrapped:0)
                return
            }
            let tight = smooth((t-k.cast1)/max(0.001,k.pull0-k.cast1))
            let u = clamp((t-k.pull0)/(k.pull1-k.pull0)), eased = u*u*(3-2*u)*0.4+u*u*0.6
            let p = NSPoint(x:CGFloat(mix(Float(source.x),Float(catchPoint.x),eased)),y:CGFloat(mix(Float(source.y),Float(catchPoint.y),eased)))
            let distance = hypot(source.x-silkOrigin.x,source.y-silkOrigin.y)
            f.lastObject = p
            // Slight sway and tension while it reels in (none with Reduce Motion).
            let sway = reduceMotion ? 0 : CGFloat(sin(t*17))*distance*0.012*CGFloat(1-tight)
            f.silk.update(from:silkOrigin,to:p,extent:1,sag:distance*0.05*CGFloat(1-tight)+sway,silkAlpha:1,objectAt:p,
                          scale:CGFloat(1-0.4*eased),tilt:CGFloat(sin(u * .pi))*0.2,spin:CGFloat(sin(u*5))*0.07,alpha:1,wrapped:0)
        } else if t < k.wrap1 {
            f.phase = .wrap
            if !f.caught {
                f.caught = true
                if f.mode != .snap && spiderAvailable {
                    if f.mode == .rich { renderer.parcelImage = f.item.preview }
                    _ = motion.catchItem(at:space.motion(screen:catchPoint))
                }
            }
            if f.mode == .rich {
                // The spider's own wrapped parcel shows the object; the flat flight object stays hidden.
                f.silk.update(from:mouth,to:mouth,extent:0,sag:0,silkAlpha:0,objectAt:mouth,scale:0.6,tilt:0,spin:0,alpha:0,wrapped:1)
                return
            }
            let w = CGFloat(clamp((t-k.pull1)/(k.wrap1-k.pull1)))
            let at = f.mode == .snap ? source : mouth
            f.lastObject = at
            f.silk.update(from:at,to:at,extent:0,sag:0,silkAlpha:0,objectAt:at,scale:0.6-0.12*w,tilt:0,spin:w*0.5,alpha:1,wrapped:w*1.05)
        } else {
            // Send: a strand from the hidden nest tensions and pulls the cocoon off the desktop.
            f.phase = .sendToNest
            if f.mode == .rich && !f.handedOff { f.handedOff = true; suppressParcel = true; f.lastObject = mouth }
            let u = clamp((t-k.wrap1)/(k.send1-k.wrap1))
            let start = f.lastObject
            let eased = CGFloat(u*u)
            let p = NSPoint(x:start.x+(nest.x-start.x)*eased,y:start.y+(nest.y-start.y)*eased)
            let tight = CGFloat(smooth(u/0.35))
            // The catch glow leaves the spider and runs up the strand into the nest, cooling from red to gold.
            let run = clamp(u/0.7)
            // When the cocoon is in, the strand breaks and recoils snappily into the nest.
            let snap = clamp((u-0.8)/0.2), back: Float = 1.7
            let recoil = snap > 0 ? 1-(1+(back+1)*pow(snap-1,3)+back*pow(snap-1,2)) : 0
            f.silk.update(from:nest,to:p,extent:CGFloat(max(0,1-recoil)),sag:hypot(nest.x-start.x,nest.y-start.y)*0.06*(1-tight),silkAlpha:CGFloat(1-smooth((u-0.8)/0.2)),
                          objectAt:p,scale:0.9-0.45*eased,tilt:0,spin:eased*0.6,alpha:CGFloat(1-smooth((u-0.7)/0.3)),wrapped:2,
                          pulseAt:f.item.isSecret || run >= 1 ? -1 : CGFloat(1-smooth(run)),pulseHeat:CGFloat(1-run))
        }
    }

    func cancelAll() {
        for flight in flights { effects.remove(flight.silk) }
        flights.removeAll(); suppressParcel = false; renderer.parcelHidden = false; renderer.parcelImage = nil
    }
}
