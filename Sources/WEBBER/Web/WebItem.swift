import Foundation
import simd

enum WebItemPhase { case attaching, hanging, pulled, detached, released }

/// A caught object hanging from its own silk strand: anchor slot, rest pose, and damped spring state.
final class WebItem {
    let id: Int
    let slot: Int
    let hangLength: Float
    /// Natural, slightly irregular suspended orientation.
    let restTwist: Float
    let restYaw: Float
    var pinned = false
    var phase: WebItemPhase = .attaching
    var phaseTime: Float = 0
    /// Where the spider let go of it (web-local), for the attach motion.
    var attachStart = V3.zero
    var sway: Float = 0
    var swayVelocity: Float = 0
    var twist: Float = 0
    var angularVelocity: Float = 0
    /// Pointer pull during drag-out, web-local offset from the rest position.
    var pull = V3.zero
    /// Brief scale/tension pulse used as physical acknowledgement (Copy Again, attach).
    var pulse: Float = 0
    var releaseVelocity = V3.zero
    var releaseOffset = V3.zero

    init(id: Int, slot: Int) {
        self.id = id; self.slot = slot
        let seed = Float((id*7919)%101)/101
        hangLength = 16+seed*10
        restTwist = (seed-0.5)*0.16
        restYaw = (Float((id*104729)%67)/67-0.5)*0.5
    }

    var attachProgress: Float { phase == .attaching ? smooth(phaseTime/0.65) : 1 }
    var visible: Bool { phase != .detached && !(phase == .released && phaseTime > 0.42) }

    /// Bob position relative to its anchor (before any expansion scaling of the hang).
    func offset(hang: Float) -> V3 {
        V3(sway,-hang,0)+(phase == .pulled ? pull : .zero)+(phase == .released ? releaseOffset : .zero)
    }

    /// Damped spring toward stillness, driven by short local impulses only.
    func step(dt: Float, impulse: Float, time: Float) {
        guard dt > 0 else { return }
        phaseTime += dt
        if phase == .attaching && phaseTime >= 0.65 { phase = .hanging; phaseTime = 0 }
        if phase == .released {
            releaseVelocity.y -= 520*dt
            releaseOffset += releaseVelocity*dt
            return
        }
        let spring: Float = 4.2, damping: Float = 2.9
        let driven = sin(time*1.25+Float(id)*1.77)*impulse
        swayVelocity += (-spring*sway-damping*swayVelocity+driven)*dt
        sway += swayVelocity*dt
        angularVelocity += (-5.0*twist-2.6*angularVelocity+swayVelocity*0.004)*dt
        twist += angularVelocity*dt
        pulse *= exp(-dt*7)
    }

    /// A neighbouring disturbance: a push proportional to strength, signed by side.
    func nudge(_ strength: Float) {
        swayVelocity += strength
        angularVelocity += strength*0.08
    }

    var isSettled: Bool { abs(sway) < 0.02 && abs(swayVelocity) < 0.02 && abs(twist) < 0.002 && pulse < 0.01 && phase == .hanging }
}
