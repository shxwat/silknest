import simd

/// Everything the renderer needs to draw one frame. SpiderMotion is the live source; a snapshot is an
/// immutable copy handed to SceneKit's render thread so the simulation and rendering never share state.
protocol SpiderPose: AnyObject {
    var position: V3 { get }
    var heading: Float { get }
    var bodyOffset: V3 { get }
    var bodyLift: Float { get }
    var bodyOrientation: simd_quatf { get }
    var abdomenPitch: Float { get }
    var palpProbe: Float { get }
    var state: SpiderState { get }
    var catchTime: Float { get }
    var catchTarget: V3 { get }
    var feet: [Foot] { get }
    var bodyScale: Float { get }
    var time: Float { get }
    /// Where the eyes look (the pointer when it is near), else nil.
    var gaze: V3? { get }
    /// 0 awake … 1 asleep, hanging from a thread.
    var sleepAmount: Float { get }
    /// 0…1 slow breathing of the glow (only while someone is near and it is idle).
    var glowBreath: Float { get }
    func bodyPoint(_ local: V3) -> V3
}

extension SpiderMotion: SpiderPose {}

final class SpiderPoseSnapshot: SpiderPose {
    let position: V3, heading: Float, bodyOffset: V3, bodyLift: Float, bodyOrientation: simd_quatf
    let abdomenPitch: Float, palpProbe: Float, state: SpiderState, catchTime: Float, catchTarget: V3
    let feet: [Foot]
    let time: Float
    let bodyScale: Float
    let gaze: V3?, sleepAmount: Float, glowBreath: Float
    init(_ m: SpiderMotion) {
        time = m.time; bodyScale = m.bodyScale
        gaze = m.gaze; sleepAmount = m.sleepAmount; glowBreath = m.glowBreath
        position = m.position; heading = m.heading; bodyOffset = m.bodyOffset; bodyLift = m.bodyLift
        bodyOrientation = m.bodyOrientation; abdomenPitch = m.abdomenPitch; palpProbe = m.palpProbe
        state = m.state; catchTime = m.catchTime; catchTarget = m.catchTarget
        feet = m.feet.map { source in
            let copy = Foot(side:source.side,index:source.index)
            copy.position = source.position; copy.phase = source.phase; copy.progress = source.progress; copy.scale = source.scale
            return copy
        }
    }
    func bodyPoint(_ local: V3) -> V3 { position+rotate(bodyOffset,heading)+V3(0,0,bodyLift)+bodyOrientation.act(local) }
}

struct LegPose {
    let points: [V3]
    static func solve(_ foot: Foot, motion: SpiderPose) -> LegPose {
        let hip = motion.bodyPoint(foot.hip)
        let k = foot.scale
        let coxa = motion.bodyPoint(foot.hip+V3(foot.side*4.3,foot.index<2 ? 1.5 : -1.5,1)*k)
        let reaching = foot.phase == .reaching
        let pole = rotate(V3(foot.side*(reaching ? 0.85 : 0.6),[0.60,0.55,-0.55,-0.65][foot.index],reaching ? 0.42 : 0.92),motion.heading)
        let knee = solveKnee(hip:coxa,foot:foot.position,upper:foot.femurLength,lower:foot.distalLength,pole:pole)
        let distal = foot.position-knee
        let bend = rotate(V3(foot.side*1.0,0,0),motion.heading)*k
        let patella = knee+distal*0.12+V3(0,0,0.6*k)
        let ankle = knee+distal*0.61+bend+V3(0,0,1.5*k)
        let tarsus = knee+distal*0.92+V3(0,0,0.5*k)
        return LegPose(points:[hip,coxa,knee,patella,ankle,tarsus,foot.position])
    }
}
