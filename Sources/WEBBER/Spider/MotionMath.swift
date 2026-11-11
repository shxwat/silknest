import AppKit
import SceneKit
import simd

typealias V3 = SIMD3<Float>
func clamp(_ x: Float, _ a: Float = 0, _ b: Float = 1) -> Float { min(b, max(a, x)) }
func smooth(_ x: Float) -> Float { let t = clamp(x); return t * t * (3 - 2 * t) }
func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
func mix(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * t }
func angleDelta(_ a: Float, _ b: Float) -> Float { atan2(sin(b-a), cos(b-a)) }
func rotate(_ v: V3, _ angle: Float) -> V3 {
    V3(v.x*cos(angle)-v.y*sin(angle), v.x*sin(angle)+v.y*cos(angle), v.z)
}
func point(_ p: NSPoint) -> V3 { V3(Float(p.x), Float(p.y), 0) }
func nsPoint(_ p: V3) -> NSPoint { NSPoint(x: CGFloat(p.x), y: CGFloat(p.y)) }

/// Two bone solve: the endpoint stays planted while the raised knee absorbs body motion.
func solveKnee(hip: V3, foot: V3, upper: Float, lower: Float, pole: V3) -> V3 {
    let delta = foot - hip
    let distance = max(0.001, simd_length(delta))
    let axis = delta / distance
    let d = min(distance, upper + lower - 0.001)
    let along = (upper*upper - lower*lower + d*d) / (2*d)
    let height = sqrt(max(0, upper*upper - along*along))
    let projected = pole - axis * simd_dot(pole, axis)
    let bend = simd_length(projected) > 0.001 ? simd_normalize(projected) : V3(0,0,1)
    return hip + axis * along + bend * height
}
