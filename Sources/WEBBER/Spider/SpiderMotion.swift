import AppKit
import simd

enum SpiderState: String {
    case idle, anticipating, crawling, turning, alert, orienting, tracking, watching, catching, settling, paused, held
}
enum FootPhase: String { case planted, queued, lifting, traveling, planting, reaching }

final class Foot {
    let side: Float
    let index: Int
    let group: Int
    /// Anatomy at full size; `scale` shrinks the whole animal (legs, reach, stride) consistently.
    let baseHome: V3, baseHip: V3, baseStep: Float, baseFemur: Float, baseDistal: Float
    var scale: Float = 1
    var home: V3 { baseHome*scale }
    var hip: V3 { baseHip*scale }
    var stepThreshold: Float { baseStep*scale }
    var femurLength: Float { baseFemur*scale }
    var distalLength: Float { baseDistal*scale }
    var position = V3.zero
    var start = V3.zero
    var target = V3.zero
    var progress: Float = 1
    var duration: Float = 0.27
    var delay: Float = 0
    var lift: Float = 6
    var phase: FootPhase = .planted
    var swinging: Bool { [.lifting,.traveling,.planting].contains(phase) }
    var supported: Bool { phase == .planted || (phase == .queued && position.z < 0.35) }
    var reachProgress: Float = 0
    init(side: Float, index: Int) {
        self.side = side; self.index = index
        group = (index + (side > 0 ? 1 : 0)) % 2
        baseHome = V3(side * [47,64,68,54][index], [57,26,-21,-53][index], 0)
        // All eight legs emerge from the cephalothorax, never the abdomen.
        baseHip = V3(side * [7.2,10,10.5,8.5][index], [11,5,-1.5,-7.5][index], 10)
        baseStep = [8,9.5,10.5,9][index]
        baseFemur = [32,35,37,35][index]
        baseDistal = [45,48,49,47][index]
    }
}

/// Contacts, reach gestures, and weight transfer live here; the renderer cannot slide a planted foot.
final class SpiderMotion {
    private(set) var state: SpiderState = .idle
    /// Overall size of the animal (1 = full size). Planted feet stay where they are when it changes;
    /// the gait then re-plants them under the resized body.
    var bodyScale: Float = 1 {
        didSet {
            guard bodyScale != oldValue, oldValue > 0 else { return }
            // Growing/shrinking spreads or draws in the legs about the body, so they always stay in reach.
            let k = bodyScale/oldValue
            func about(_ p: V3) -> V3 { V3(position.x+(p.x-position.x)*k,position.y+(p.y-position.y)*k,p.z*k) }
            for foot in feet {
                foot.scale = bodyScale
                foot.position = about(foot.position); foot.start = about(foot.start); foot.target = about(foot.target)
            }
        }
    }
    /// A point in body space at the current size.
    func body(_ local: V3) -> V3 { world(local*bodyScale) }
    private(set) var position: V3
    private(set) var heading: Float = 0
    private(set) var velocity = V3.zero
    private(set) var angularVelocity: Float = 0
    private(set) var time: Float = 0
    private(set) var stateTime: Float = 0
    private(set) var catchProgress: Float = 0
    private(set) var catchWasTracking = false
    private(set) var catchTarget = V3.zero
    private(set) var bodyLift: Float = 0
    private(set) var bodyPitch: Float = 0
    private(set) var bodyRoll: Float = 0
    private(set) var bodyYaw: Float = 0
    private(set) var bodyOffset = V3.zero
    private(set) var abdomenPitch: Float = 0
    private(set) var frontReadiness: Float = 0
    private(set) var dragActive = false
    /// Attention held on an incoming clipboard object while silk is cast and reeled in.
    private(set) var reeling = false
    var webSurfaceScale: Float = 1
    /// Top crawl speed in motion units per second: quick and purposeful, like a real house spider.
    var cruiseSpeed: Float = 75
    var acceleration: Float = 140
    /// Multiplies swing durations and gait cadence; below 1 is a quicker, lighter step for higher speeds.
    var gaitTempo: Float = 1
    /// The fast tempo only applies at speed: turning in place, orienting and slow steps use the natural
    /// tempo, so legs never snap between positions in a handful of frames.
    var tempo: Float { state == .crawling ? gaitTempo : max(gaitTempo,0.85) }
    /// Idle pause between patrol walks, and optional custom patrol stops (motion units).
    var wanderPause: Float = 6
    var patrolStops: [V3]?
    /// Extra random rest added to `wanderPause` (a real spider sits still for varying, long stretches).
    var wanderJitter: Float = 0
    private var restSeed: UInt32 = 2_654_435_761
    func restInterval() -> Float {
        restSeed = restSeed &* 1_103_515_245 &+ 12_345
        return wanderPause+wanderJitter*Float((restSeed >> 16) & 0x7fff)/32767
    }
    /// Stay put for at least this long (e.g. after being moved, or after stepping out of the way).
    func rest(for seconds: Float) { nextWander = max(nextWander,time+seconds) }
    let awarenessRadius: Float = 175
    var paused = false { didSet { transition(paused ? .paused : .idle) } }
    let feet = [-Float(1),Float(1)].flatMap { side in (0..<4).map { Foot(side:side,index:$0) } }
    var autoPatrol = true
    var bounds: CGRect
    var target: V3
    private var stimulus: V3?
    private var noticingDrag = false
    private var noticeCooldown: Float = 0
    private var nextWander: Float = 5.5
    private var nextAdjustment: Float = 8
    private var gaitGroup = 0
    private var gaitCooldown: Float = 0
    private var catchOrigin = V3.zero
    private var catchDirection = V3(0,1,0)
    private var catchFeet: [V3] = []
    private var wanderIndex = 0
    private var anticipationPrepared = false
    private var turnOnly: Float?
    private var gaitHeight: Float = 0
    private var landingImpulse: Float = 0
    private var previousVelocity = V3.zero
    private var cursorWasNear = false
    private var catchLead: Float = 0.16
    var catchTime: Float { max(0,stateTime-catchLead+0.16) }

    init(bounds: CGRect, position: V3) {
        self.bounds = bounds; self.position = position; target = position
        for foot in feet { foot.position = world(foot.home); foot.target = foot.position }
    }
    /// Idle flourishes (a breath, a palp probe) only while someone is near: a spider nobody is looking at
    /// stays perfectly still, so nothing is rendered and no CPU/GPU is used.
    var ambientIdle = true
    var palpProbe: Float {
        let t = time.truncatingRemainder(dividingBy:13)
        return ambientIdle && state == .idle && t>10 ? sin((t-10)/3 * .pi)*0.5 : 0
    }
    var supportedFeet: Int { feet.filter(\.supported).count }
    func world(_ local: V3) -> V3 { position + rotate(local,heading) }
    var bodyOrientation: simd_quatf {
        simd_quatf(angle:heading+bodyYaw,axis:V3(0,0,1)) * simd_quatf(angle:bodyRoll,axis:V3(0,1,0)) * simd_quatf(angle:bodyPitch,axis:V3(1,0,0))
    }
    func bodyPoint(_ local: V3) -> V3 { position + rotate(bodyOffset,heading) + V3(0,0,bodyLift) + bodyOrientation.act(local) }
    func transition(_ next: SpiderState) {
        guard state != next else { return }; state = next; stateTime = 0
        if next == .anticipating { anticipationPrepared = false }
    }
    func drag(at location: V3?) {
        guard !paused && state != .catching && state != .settling && state != .held else { return }
        if let location {
            stimulus = location; noticingDrag = true
            if !dragActive { transition(.alert); cancelQueuedSteps() }
            dragActive = true
        } else if dragActive {
            dragActive = false; stimulus = nil; noticingDrag = false
            transition(.settling)
        }
    }
    /// Something is arriving from `location`: freeze, then turn toward it and ready the forelegs.
    func notice(_ location: V3) {
        guard !paused && state != .catching && state != .settling && state != .held else { return }
        stimulus = location; noticingDrag = true; reeling = true
        target = position; turnOnly = nil; velocity = .zero
        cancelQueuedSteps(); transition(.alert)
    }
    func endNotice() {
        guard reeling else { return }
        reeling = false; stimulus = nil; noticingDrag = false
        if [.alert,.orienting,.tracking].contains(state) { transition(.settling) }
    }
    /// Picked up by the pointer: the body lifts and the legs draw in and dangle until it is put down.
    /// Whether it was paused when picked up: it can still be moved, and stays paused where it lands.
    private var pausedBeforeHold = false
    func pickUp() {
        pausedBeforeHold = paused
        if paused { paused = false }
        dragActive = false; reeling = false; stimulus = nil; noticingDrag = false
        velocity = .zero; turnOnly = nil; cancelQueuedSteps()
        for foot in feet { foot.phase = .reaching; foot.start = foot.position }
        transition(.held)
    }
    func hold(at location: V3) {
        guard state == .held else { return }
        // While carried it may go right up to the screen edge (and on to another display).
        position = V3(clamp(location.x,Float(bounds.minX)+20,Float(bounds.maxX)-20),clamp(location.y,Float(bounds.minY)+20,Float(bounds.maxY)-20),0)
        target = position
    }
    /// Moves the spider to another display's coordinate space without any walking.
    func relocate(bounds newBounds: CGRect, to location: V3) {
        bounds = newBounds
        let delta = location-position
        position = location; target = location; velocity = .zero
        for foot in feet {
            foot.position += delta; foot.start += delta; foot.target += delta
        }
        if state != .held { position = constrain(location); for foot in feet { foot.position = world(foot.home); foot.target = foot.position; foot.phase = .planted; foot.progress = 1 }; transition(.idle) }
    }
    /// Put down: every foot lands under the body and the spider settles where it was dropped.
    func drop() {
        guard state == .held else { return }
        for foot in feet {
            foot.position = world(foot.home); foot.target = foot.position
            foot.phase = .planted; foot.progress = 1
        }
        target = position; velocity = .zero; landingImpulse -= 1.6
        nextWander = time+restInterval()+2
        transition(.settling)
        if pausedBeforeHold { pausedBeforeHold = false; paused = true }
    }
    @discardableResult func catchItem(at location: V3) -> Bool {
        guard !paused && state != .catching && state != .settling && state != .held else { return false }
        let delta = location-position
        catchDirection = simd_length(delta)>28 ? simd_normalize(V3(delta.x,delta.y,0)) : rotate(V3(0,1,0),heading)
        catchWasTracking = frontReadiness>0.1
        catchTarget = location; catchOrigin = position; catchFeet = feet.map(\.position)
        // Let a rear foot finish landing before the forelegs commit to the pounce.
        catchLead = max(0.16,(feet.filter { $0.index>=2 && $0.swinging }.map { (1-$0.progress)*$0.duration }.max() ?? 0)+0.03)
        dragActive = false; reeling = false; velocity = .zero; stimulus = nil
        cancelQueuedSteps(); catchProgress = 0; transition(.catching)
        return true
    }
    func crawl(to destination: V3) { turnOnly = nil; target = constrain(destination); transition(.anticipating) }
    func turn(by angle: Float) { turnOnly = heading+angle; target = position; transition(.anticipating) }
    func constrain(_ p: V3) -> V3 {
        V3(clamp(p.x,Float(bounds.minX)+90,Float(bounds.maxX)-90),clamp(p.y,Float(bounds.minY)+90,Float(bounds.maxY)-90),0)
    }
    func update(dt rawDT: Float, cursor: V3?) {
        guard !paused else { return }
        let dt = clamp(rawDT,0,1/30)
        guard dt > 0 else { return }
        time += dt; stateTime += dt
        noticeCooldown = max(0,noticeCooldown-dt); gaitCooldown = max(0,gaitCooldown-dt)
        let cursorNear = cursor.map { simd_distance($0,position)<awarenessRadius && simd_distance($0,position)>45 } ?? false
        // Cursor chase: the eyes follow the pointer while it is near (quantised, so a still pointer costs nothing).
        if let cursor, simd_distance(cursor,position) < awarenessRadius*1.3, sleepAmount < 0.5 {
            gaze = V3((cursor.x/4).rounded()*4,(cursor.y/4).rounded()*4,0)
        } else { gaze = nil }
        if cursorNear && !reduceMotion && !asleep && !cursorWasNear && noticeCooldown==0 && !dragActive && [.idle,.anticipating,.turning,.crawling].contains(state), let cursor {
            stimulus = cursor; noticingDrag = false; noticeCooldown = 5
            target = position; turnOnly = nil; velocity = .zero
            cancelQueuedSteps(); transition(.alert)
        }
        cursorWasNear = cursorNear
        if !noticingDrag && [.orienting,.watching].contains(state), cursorNear, let cursor {
            stimulus = mix(stimulus ?? cursor,cursor,min(1,dt*8))
        }
        let before = position, oldHeading = heading
        var catchLift: Float = 0, catchPitch: Float = 0
        switch state {
        case .idle:
            velocity = .zero
            if autoPatrol && time>nextWander {
                let x = Float(bounds.maxX)-115, y = Float(bounds.minY)+115
                let stops = patrolStops ?? [V3(x-170,y,0),V3(x-290,y+25,0),V3(x-120,y+90,0),V3(x,y,0)]
                crawl(to:stops[wanderIndex%stops.count]); wanderIndex += 1
            }
        case .anticipating:
            velocity *= exp(-dt*14)
            catchLift = -0.8*sin(clamp(stateTime/0.30) * .pi)
            if stateTime>0.11 && !anticipationPrepared {
                anticipationPrepared = true
                let delta = target-position, desired = turnOnly ?? atan2(-delta.x,delta.y)
                let turn = angleDelta(heading,desired)
                if abs(turn)>0.3, let front = feet.first(where: { $0.index==0 && $0.side*turn>0 }) {
                    queueStep(front,to:position+rotate(front.home,heading+clamp(turn,-0.22,0.22)),delay:0,duration:0.29,lift:4)
                }
            }
            if stateTime>0.30 { transition(.turning) }
        case .turning, .crawling:
            let delta = target-position, distance = simd_length(delta)
            let desired = turnOnly ?? atan2(-delta.x,delta.y), error = angleDelta(heading,desired)
            steer(toward:desired,dt:dt,speed:1.8)
            if let _ = turnOnly {
                if abs(error)<0.025 && !feet.contains(where: { $0.swinging || $0.phase == .queued }) {
                    turnOnly = nil; velocity = .zero; nextWander = time+restInterval(); transition(.idle)
                }
            } else if state == .turning && abs(error)<0.09 { transition(.crawling) }
            let speed: Float = state == .turning ? 0 : webSurfaceScale*min(cruiseSpeed,sqrt(max(0,distance)*150))*pow(max(0,cos(error)),2)
            let wanted = distance>2 ? simd_normalize(delta)*speed : .zero
            let change = wanted-velocity, length = simd_length(change)
            velocity += length>0 ? change*min(1,acceleration*dt/length) : .zero
            let travel = velocity*dt
            position = constrain(position+travel*supportedTravelFraction(travel))
            if turnOnly == nil && distance<3 && simd_length(velocity)<5 {
                velocity = .zero; target = position; nextWander = time+restInterval(); transition(.idle)
            }
        case .alert:
            // Deliberate stillness before orienting. No cursor pursuit.
            velocity = .zero
            if stateTime>0.18 { transition(.orienting) }
        case .orienting, .tracking, .watching:
            velocity = .zero
            if let stimulus {
                let delta = stimulus-position, desired = atan2(-delta.x,delta.y)
                if simd_length(delta)>28 { steer(toward:desired,dt:dt,speed:noticingDrag ? 1.65 : 1.0) }
                if state == .orienting && (simd_length(delta)<28 || abs(angleDelta(heading,desired))<0.18) {
                    transition(noticingDrag ? .tracking : .watching)
                }
            }
            // If the pointer stays, it keeps watching and slowly turns to face it; it lets go once the pointer leaves.
            if state == .watching {
                if cursorNear, let cursor {
                    cursorAway = 0
                    let delta = cursor-position
                    if simd_length(delta)>28 { steer(toward:atan2(-delta.x,delta.y),dt:dt,speed:0.45) }
                } else { cursorAway += dt }
                if cursorAway > 1.1 || stateTime > 20 { stimulus = nil; nextWander = time+5; transition(.idle) }
            }
        case .catching:
            let t = catchTime
            catchProgress = clamp(t/1.48)
            let crouch = smooth(t/0.15)*(1-smooth((t-0.15)/0.12))
            let lift = sin(clamp((t-0.15)/0.22) * .pi)
            position = constrain(catchOrigin+catchDirection*(8*smooth((t-0.16)/0.095)))
            catchLift = -2.7*crouch+5.5*lift-0.65*exp(-max(0,t-0.38)*12)*smooth((t-0.37)/0.07)
            catchPitch = -0.075*crouch+0.11*lift
            // Only small alignment corrections during a pounce; the drag reaction has already oriented the animal.
            let desired = atan2(-catchDirection.x,catchDirection.y)
            heading += clamp(angleDelta(heading,desired),-dt*0.65,dt*0.65)
            if t>1.48 { frontReadiness = 0; catchProgress = 0; transition(.settling) }
        case .settling:
            velocity = .zero
            if stateTime>0.65 && !feet.contains(where: { $0.swinging || $0.phase == .reaching }) {
                target = position; nextWander = time+5; transition(.idle)
            }
        case .held:
            // Lifted off the desk: legs tucked in and gently paddling, the body slightly raised.
            catchLift = 9
            for foot in feet {
                let tucked = world(V3(foot.home.x*0.72,foot.home.y*0.8,0))
                let paddle = sin(time*7+Float(foot.index)*1.3+foot.side)*1.6
                foot.position = mix(foot.position,tucked+V3(0,paddle,4+paddle*0.5)*bodyScale,min(1,dt*14))
            }
        case .paused: break
        }
        // Sleep: it rises onto a thread and tucks its legs; a copy wakes it with a jolt.
        let sleepTarget: Float = asleep && state == .idle ? 1 : 0
        sleepAmount += (sleepTarget-sleepAmount)*min(1,dt*(sleepTarget > sleepAmount ? 0.7 : 5))
        if abs(sleepAmount-sleepTarget) < 0.002 { sleepAmount = sleepTarget }
        wakeJolt = max(0,wakeJolt-dt*2.2)
        catchLift += (reduceMotion ? 0 : 16*sleepAmount)+(wakeJolt > 0 ? sin(wakeJolt*3 * .pi)*3.5*wakeJolt : 0)
        // Idle life (only while someone is near): the occasional grooming of the face.
        if ambientIdle && state == .idle && !reduceMotion && sleepAmount == 0 && time > nextGroom {
            nextGroom = time+80; if !shyActive { groomTime = 0; for foot in feet where foot.index == 0 { foot.start = foot.position } }
        }
        angularVelocity = angleDelta(oldHeading,heading)/dt
        updateFeet(dt:dt,locomoting:simd_distance(before,position)>0.001 || abs(angularVelocity)>0.01)
        updateReach(dt:dt)
        if sleepAmount > 0.002 {
            for foot in feet {
                let ground = world(foot.home)
                let tucked = world(V3(foot.home.x*0.6,foot.home.y*0.68,0))+V3(0,0,(reduceMotion ? 3 : 11)*bodyScale)
                foot.position = mix(ground,tucked,sleepAmount); foot.phase = .reaching
            }
        } else if sleepWasActive {
            for foot in feet { foot.position = world(foot.home); foot.position.z = 0; foot.phase = .planted; foot.progress = 1 }
        }
        sleepWasActive = sleepAmount > 0.002
        updateWeight(dt:dt,catchLift:catchLift,catchPitch:catchPitch)
        previousVelocity = velocity
    }

    // MARK: moments

    /// System Reduce Motion: big motions (turning to the pointer, wiggles, grooming, rising to sleep) are skipped.
    var reduceMotion = false
    private(set) var gaze: V3?
    private var cursorAway: Float = 0
    /// Feeding frenzy: a tiny happy wiggle after a burst of catches.
    private(set) var wiggleTime: Float = -1
    var wiggleActive: Bool { wiggleTime >= 0 }
    func happyWiggle() {
        guard !reduceMotion, !asleep, [.idle,.watching,.settling].contains(state) else { return }
        wiggleTime = 0
    }
    private(set) var asleep = false
    private(set) var sleepAmount: Float = 0
    private var sleepWasActive = false, wakeJolt: Float = 0
    func fallAsleep() { guard state == .idle, !asleep else { return }; asleep = true }
    /// `jolt`: woken by a copy (a quick start), rather than by the pointer coming near.
    func wake(jolt: Bool) {
        guard asleep else { return }
        asleep = false
        if jolt && !reduceMotion { wakeJolt = 1 }
    }
    private var nextGroom: Float = 45
    private(set) var groomTime: Float = -1
    /// 0…1 slow glow breathing while someone is near and it is idle (quantised so renders stay rare).
    var glowBreath: Float {
        guard ambientIdle && state == .idle && sleepAmount == 0 && !reduceMotion else { return 0 }
        return ((0.5+0.5*sin(time*1.4))*10).rounded()/10
    }
    var momentActive: Bool { wiggleActive || groomTime >= 0 || wakeJolt > 0 || (sleepAmount > 0 && sleepAmount < 1) }
    private func steer(toward desired: Float, dt: Float, speed: Float) {
        let strain = feet.filter(\.supported).map { simd_distance($0.position,world($0.home))/$0.stepThreshold }.max() ?? 0
        let supportLimit: Float = strain>1.9 && supportedFeet<=4 ? 0.25 : 1
        heading += clamp(angleDelta(heading,desired),-dt*speed*supportLimit,dt*speed*supportLimit)
    }
    /// The body waits for a support foot to release rather than dragging it beyond its IK reach.
    private func supportedTravelFraction(_ travel: V3) -> Float {
        let a = simd_length_squared(travel)
        guard a>0.000001 else { return 1 }
        var fraction: Float = 1
        for foot in feet where foot.supported {
            let coxa = bodyPoint(foot.hip+V3(foot.side*4.3,foot.index<2 ? 1.5 : -1.5,1)*bodyScale)
            let delta = coxa-foot.position
            let radius = (foot.femurLength+foot.distalLength)*0.97
            let b = 2*simd_dot(delta,travel), c = simd_length_squared(delta)-radius*radius
            if b>0 && a+b+c>0 {
                let limit = (-b+sqrt(max(0,b*b-4*a*c)))/(2*a)
                fraction = min(fraction,clamp(limit))
            }
        }
        return fraction
    }
    private func updateFeet(dt: Float, locomoting: Bool) {
        guard state != .alert && state != .held else { return }
        for foot in feet {
            if foot.phase == .queued {
                foot.delay = max(0,foot.delay-dt)
                if foot.delay==0 && supportedFeet-(foot.supported ? 1 : 0)>=4 && state != .alert {
                    foot.phase = .lifting; foot.progress = 0; foot.start = foot.position
                }
            }
            guard foot.swinging else { continue }
            foot.progress = min(1,foot.progress+dt/foot.duration)
            let t = foot.progress
            foot.position = mix(foot.start,foot.target,smooth(t))
            // Lift → travel → soft plant. The last fifth is a low, controlled landing.
            let arc = sin(t * .pi)*pow(1-t,0.25)
            foot.position.z += arc*foot.lift
            if t==1 {
                foot.position = foot.target; foot.position.z = 0; foot.phase = .planted
                landingImpulse -= 0.09
            } else { foot.phase = t<0.20 ? .lifting : (t<0.78 ? .traveling : .planting) }
        }
        guard state != .catching && state != .alert else { return }
        if (locomoting || state == .crawling || state == .turning) && gaitCooldown==0 {
            let candidates = feet.filter { $0.group==gaitGroup && $0.phase == .planted }
            let urgency = candidates.map { simd_distance($0.position,world($0.home))/$0.stepThreshold }.max() ?? 0
            if urgency>1 {
                // Keep the two diagonally opposed tetrapods, with short offsets inside each group.
                let ordered = candidates.sorted { simd_distance($0.position,world($0.home)) > simd_distance($1.position,world($1.home)) }
                for (i,foot) in ordered.enumerated() {
                    let outer: Float = foot.side*angularVelocity>0 ? 1.18 : 0.68
                    let futureAngle = heading+angularVelocity*0.16*outer
                    let predicted = position+velocity*0.12*tempo+rotate(foot.home,futureAngle)
                    queueStep(foot,to:predicted,delay:Float(i)*0.016*tempo,duration:(0.17+Float(foot.index)*0.006)*tempo,lift:5.5)
                }
                gaitGroup = 1-gaitGroup; gaitCooldown = 0.10*tempo
            } else if feet.contains(where: { $0.group != gaitGroup && $0.phase == .planted && simd_distance($0.position,world($0.home))>$0.stepThreshold*1.1 }) {
                gaitGroup = 1-gaitGroup
            }
        } else if !locomoting && !feet.contains(where: { $0.swinging || $0.phase == .queued }) {
            if let worst = feet.filter({ $0.phase == .planted }).max(by: { simd_distance($0.position,world($0.home))<simd_distance($1.position,world($1.home)) }), simd_distance(worst.position,world(worst.home))>8*bodyScale {
                queueStep(worst,to:world(worst.home),delay:0,duration:0.32,lift:3.5)
            } else if state == .idle && time>nextAdjustment {
                let foot = feet[Int(time/8)%feet.count]
                if foot.supported { queueStep(foot,to:world(foot.home)+rotate(V3(foot.side*1.4,1,0),heading),delay:0,duration:0.43,lift:2.5) }
                nextAdjustment = time+9.7
            }
        }
    }
    /// "Didn't see that": both front legs come up over the eyes for a moment (a secret was caught).
    private(set) var shyTime: Float = -1
    var shyActive: Bool { shyTime >= 0 }
    func coverEyes() {
        guard state != .held, state != .catching, !shyActive, !reduceMotion else { return }
        shyTime = 0
        for foot in feet where foot.index == 0 { foot.start = foot.position }
    }

    private func updateReach(dt: Float) {
        if state == .held { shyTime = -1; groomTime = -1; return }
        if groomTime >= 0 && !shyActive && state == .idle {
            groomTime += dt
            let t = groomTime, amount = smooth(t/0.3)*(1-smooth((t-1.3)/0.3))
            for foot in feet where foot.index == 0 {
                let rub = sin(t*16+foot.side)*1.6
                let face = body(V3(foot.side*(4+rub*0.4),25+rub,9))
                foot.position = mix(foot.start,face,amount); foot.phase = .reaching
            }
            if t > 1.6 {
                groomTime = -1
                for foot in feet where foot.index == 0 { queueStep(foot,to:world(foot.home),delay:0,duration:0.26,lift:2) }
            }
            return
        } else if groomTime >= 0 && state != .idle { groomTime = -1 }
        if shyActive && state != .catching {
            shyTime += dt
            let t = shyTime
            let amount = smooth(t/0.22)*(1-smooth((t-1.15)/0.28))
            for foot in feet where foot.index == 0 {
                let over = body(V3(foot.side*5.5,30,15))
                foot.position = mix(foot.start,over,amount); foot.phase = .reaching
            }
            if t > 1.45 {
                shyTime = -1
                for foot in feet where foot.index == 0 { queueStep(foot,to:world(foot.home),delay:0,duration:0.26,lift:2) }
            }
            return
        }
        if state == .catching {
            let t = catchTime
            guard t>=0.10 && feet.filter({ $0.index>=2 }).allSatisfy(\.supported) else { return }
            let close = smooth((t-0.19)/0.12), recover = smooth((t-1.08)/0.35)
            for (i,foot) in feet.enumerated() where foot.index<2 {
                // A leg that has not started wrapping is still a real supporting leg.
                if foot.index==1 && t<0.48 { continue }
                if foot.phase != .reaching { catchFeet[i] = foot.position }
                let active: Float = foot.index==0 ? 1 : smooth((t-0.48)/0.13)*(1-smooth((t-0.92)/0.16))
                let capture = body(V3(foot.side*mix(35,6.5,close),mix(59,28,close),mix(5,10,close)))
                let wrap = body(V3(foot.side*(10+sin(t*12)*2),25+cos(t*12+foot.side)*3,8+sin(t*12)*1.5))
                let grab = foot.index==0 ? mix(catchFeet[i],capture,smooth((t-0.1)/0.18)) : mix(catchFeet[i],wrap,active)
                let end = mix(grab,world(foot.home),recover)
                foot.position = end; foot.phase = recover<1 ? .reaching : .planted
                if recover==1 { foot.position.z = 0 }
            }
            return
        }
        let wanted: Float = state == .tracking && (dragActive || reeling) ? 1 : (state == .watching ? 0.22 : 0)
        frontReadiness += (wanted-frontReadiness)*min(1,dt*6)
        for foot in feet where foot.index==0 {
            if wanted>0 && !foot.swinging && (foot.phase == .reaching || supportedFeet>4) {
                if foot.phase != .reaching { foot.start = foot.position; foot.phase = .reaching; foot.reachProgress = 0 }
                foot.reachProgress = min(1,foot.reachProgress+dt*4)
                let reach = V3(foot.side*mix(46,41,wanted),mix(58,61,wanted),mix(1.1,5,wanted))*bodyScale
                foot.position = mix(foot.start,world(reach),smooth(foot.reachProgress))
            } else if foot.phase == .reaching {
                queueStep(foot,to:world(foot.home),delay:0,duration:0.30,lift:2.5)
            }
        }
        // The second pair returns softly after silk wrapping, retaining the rear four supports.
        if state == .settling { for foot in feet where foot.phase == .reaching { queueStep(foot,to:world(foot.home),delay:0,duration:0.29,lift:2.5) } }
    }
    private func updateWeight(dt: Float, catchLift: Float, catchPitch: Float) {
        let stance = feet.filter(\.supported)
        var residual = V3.zero
        for foot in stance { residual += foot.position-world(foot.home) }
        if !stance.isEmpty { residual /= Float(stance.count) }
        let local = rotate(residual,-heading)
        var liftEnergy: Float = 0, sideEnergy: Float = 0
        for foot in feet where foot.swinging {
            let impulse = sin(foot.progress * .pi)
            liftEnergy += impulse; sideEnergy += impulse*foot.side
        }
        landingImpulse *= exp(-dt*18)
        let height = liftEnergy*0.14+landingImpulse
        gaitHeight += (height-gaitHeight)*min(1,dt*14)
        let weightTarget = V3(clamp(local.x*0.1,-1.1,1.1),clamp(local.y*0.05-frontReadiness*0.5,-0.7,0.7),0)
        bodyOffset = mix(bodyOffset,weightTarget,min(1,dt*9))
        let accel = rotate((velocity-previousVelocity)/dt,-heading)
        let pitch = clamp(accel.y*0.0004,-0.027,0.027)+catchPitch
        let roll = clamp(-local.x*0.003+sideEnergy*0.006,-0.035,0.035)
        bodyPitch += (pitch-bodyPitch)*min(1,dt*12)
        bodyRoll += (roll-bodyRoll)*min(1,dt*10)
        bodyYaw += (clamp(angularVelocity*0.013,-0.025,0.025)-bodyYaw)*min(1,dt*8)
        abdomenPitch += (-bodyPitch*0.7-abdomenPitch)*min(1,dt*5)
        // A single very small breath in a long idle; no perpetual all-body wobble.
        let breathTime = time.truncatingRemainder(dividingBy:11)
        let breath: Float = ambientIdle && state == .idle && breathTime>7 ? sin((breathTime-7)/4 * .pi)*0.13 : 0
        bodyLift = catchLift+gaitHeight+breath
        if wiggleTime >= 0 {
            wiggleTime += dt
            let t = wiggleTime, env = sin(clamp(t/0.85) * .pi)
            bodyYaw += sin(t*30)*0.10*env; bodyRoll += sin(t*30+1.2)*0.05*env
            abdomenPitch += sin(t*24)*0.10*env
            bodyLift += abs(sin(t*15))*1.2*env
            if t > 0.85 { wiggleTime = -1 }
        }
    }
    private func queueStep(_ foot: Foot, to target: V3, delay: Float, duration: Float, lift: Float) {
        guard foot.phase == .planted || foot.phase == .reaching else { return }
        foot.start = foot.position; foot.target = target; foot.target.z = 0
        foot.duration = duration; foot.lift = lift; foot.delay = delay; foot.progress = 0; foot.phase = .queued
    }
    private func cancelQueuedSteps() { for foot in feet where foot.phase == .queued { foot.phase = .planted; foot.progress = 1 } }
}
