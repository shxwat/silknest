#if DEBUG
import AppKit
import SceneKit
import simd

/// Development only (--beauty=<folder>): large offscreen renders of the live spider in the app's own 3/4 view,
/// for visual review and marketing. Rendered with SCNRenderer into images: no window is shown.
///   rest.png, hunt.png, secret.png, sleep.png, walk/0000.png… (transparent background)
enum BeautyCapture {
    static func run(_ path: String) {
        let out = URL(fileURLWithPath:path)
        try? FileManager.default.createDirectory(at:out.appendingPathComponent("walk"),withIntermediateDirectories:true)
        let zoom: CGFloat = 4.2
        let base = SpiderSpecies.neon
        let species = base.scaled(zoom)
        let size = CGSize(width:1600,height:1200)
        let spider = SpiderRenderer(size:size,species:species)
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = SCNRenderer(device:device,options:nil)
        renderer.scene = spider.scene; renderer.pointOfView = spider.camera
        let ortho = SCNCamera(); ortho.usesOrthographicProjection = true
        ortho.orthographicScale = Double(size.height/2/species.scale); ortho.zNear = 1; ortho.zFar = 1600
        let k = SpiderRenderViewport.tilt
        let shear = simd_float4x4(columns:(SIMD4(1,0,0,0),SIMD4(0,1,0,0),SIMD4(0,k,1,0),SIMD4(0,1000*k,0,1)))
        spider.camera.camera?.projectionTransform = SCNMatrix4(simd_float4x4(ortho.projectionTransform(withViewportSize:size))*shear)
        let motion = SpiderMotion(bounds:CGRect(x:0,y:0,width:40000,height:4000),position:V3(2000,2000,0))
        motion.cruiseSpeed = base.speed; motion.acceleration = base.acceleration; motion.gaitTempo = base.gaitTempo
        motion.bodyScale = 1; motion.ambientIdle = false
        var time: TimeInterval = 0
        func step(_ n: Int) { for _ in 0..<n { motion.update(dt:1/60,cursor:nil); time += 1/60 } }
        func shot(_ name: String) {
            spider.camera.simdPosition = V3(motion.position.x,motion.position.y-6,1000)
            spider.render(motion)
            let image = renderer.snapshot(atTime:time,with:size,antialiasingMode:.multisampling8X)
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff), let png = rep.representation(using:.png,properties:[:]) {
                try? png.write(to:out.appendingPathComponent(name))
            }
        }
        // A 3/4 pose facing down-left, the way it usually rests near the nest corner.
        motion.turn(by:-0.6); step(150)
        shot("rest.png")
        spider.shield = 1; shot("secret.png"); spider.shield = 0
        _ = motion.catchItem(at:motion.world(V3(0,55,0)))
        step(22); spider.lock = 1; shot("hunt.png"); spider.lock = 0
        step(120)
        motion.fallAsleep(); step(360)
        shot("sleep.png")
        motion.wake(jolt:false); step(120)
        // Walking: the camera follows, so it crawls in place across 150 frames (2.5 s).
        motion.crawl(to:motion.world(V3(0,9000,0))); step(60)
        for i in 0..<150 { step(1); shot(String(format:"walk/%04d.png",i)) }
        print("BEAUTY done \(out.path)")
    }
}
#endif
