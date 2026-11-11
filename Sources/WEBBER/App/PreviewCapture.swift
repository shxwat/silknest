import AppKit
import SceneKit
import simd

/// Reproducible visual checks using the same scene and simulation as the desktop overlay.
enum PreviewCapture {
    /// --species-preview: each selectable spider, same pose, on light and dark desktops.
    static func species() {
        let directory = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/species")
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let size = NSSize(width:420,height:360)
        for species in SpiderSpecies.all {
            let renderer = SpiderRenderer(size:size,species:species)
            renderer.camera.camera?.orthographicScale = Double(size.height/2/species.scale)
            renderer.camera.simdPosition = V3(Float(size.width/2/species.scale),Float(size.height/2/species.scale),1000)
            let view = ClearSceneView(frame:NSRect(origin:.zero,size:size))
            view.scene = renderer.scene; view.pointOfView = renderer.camera
            let window = NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false)
            window.colorSpace = .sRGB; window.contentView = view; window.isOpaque = false; window.backgroundColor = .clear
            window.orderFrontRegardless()
            let motion = SpiderMotion(bounds:CGRect(x:0,y:0,width:size.width/species.scale,height:size.height/species.scale),
                                      position:V3(Float(size.width/2/species.scale),Float(size.height/2/species.scale)-6,0))
            motion.turn(by:-0.5)
            for _ in 0..<150 { motion.update(dt:1/60,cursor:nil) }
            func save(_ name: String) {
                renderer.render(motion)
                let image = view.snapshot()
                if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff), let png = rep.representation(using:.png,properties:[:]) {
                    try? png.write(to:directory.appendingPathComponent("\(species.id)-\(name).png"))
                }
            }
            save("dark")
            // Mid-catch: claws closed, tail striking, wings open, arms shot forward.
            _ = motion.catchItem(at:motion.world(V3(0,54,0)))
            for _ in 0..<26 { motion.update(dt:1/60,cursor:nil) }
            save("catch")
            window.orderOut(nil)
            print("Rendered \(species.name)")
        }
    }

    /// --sprite-sheet: the live neon spider crawling in place (one gait loop) plus a resting pose, for the website.
    static func spriteSheet() {
        let directory = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/sprite")
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let species = SpiderSpecies.neon, cell = NSSize(width:300,height:300)
        let renderer = SpiderRenderer(size:cell,species:species)
        renderer.camera.camera?.orthographicScale = Double(cell.height/2/species.scale)
        let view = ClearSceneView(frame:NSRect(origin:.zero,size:cell))
        view.scene = renderer.scene; view.pointOfView = renderer.camera
        view.antialiasingMode = .multisampling8X; view.backgroundColor = .clear
        let window = NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.colorSpace = .sRGB; window.contentView = view; window.isOpaque = false; window.backgroundColor = .clear
        window.orderFrontRegardless()
        let motion = SpiderMotion(bounds:CGRect(x:0,y:0,width:20000,height:2000),position:V3(300,1000,0))
        motion.cruiseSpeed = species.speed; motion.acceleration = species.acceleration; motion.gaitTempo = species.gaitTempo
        motion.bodyScale = 1
        func shot() -> NSImage {
            renderer.camera.simdPosition = V3(motion.position.x,motion.position.y,1000)
            renderer.render(motion); return view.snapshot()
        }
        func relativeFeet() -> [Float] {
            motion.feet.flatMap { f -> [Float] in let r = rotate(f.position-motion.position,-motion.heading); return [r.x,r.y,f.position.z] }
        }
        for _ in 0..<120 { motion.update(dt:1/60,cursor:nil) }
        let rest = shot()
        motion.crawl(to:V3(19000,1000,0))
        for _ in 0..<150 { motion.update(dt:1/60,cursor:nil) }
        // Record a run of frames, then cut one loop where the leg pose repeats best.
        var frames: [NSImage] = [], feet: [[Float]] = [], xs: [Float] = []
        for i in 0..<120 {
            if i % 2 == 0 { frames.append(shot()); feet.append(relativeFeet()); xs.append(motion.position.x) }
            motion.update(dt:1/60,cursor:nil)
        }
        var best = (index:8,error:Float.infinity)
        for k in 8..<feet.count {
            let e = zip(feet[0],feet[k]).reduce(Float(0)) { $0+($1.0-$1.1)*($1.0-$1.1) }
            if e < best.error { best = (k,e) }
        }
        let loop = Array(frames[0..<best.index])
        let travel = (xs[best.index]-xs[0])*Float(species.scale)
        let all = [rest]+loop
        let columns = 8, rows = Int(ceil(Double(all.count)/Double(columns))), px = 300
        let sheet = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:px*columns,pixelsHigh:px*rows,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:sheet)
        NSGraphicsContext.current?.imageInterpolation = .high
        for (i,image) in all.enumerated() {
            let x = (i % columns)*px, y = (rows-1-i/columns)*px
            image.draw(in:NSRect(x:x,y:y,width:px,height:px))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? sheet.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("spider-sheet.png"))
        let meta: [String:Any] = ["cell":px,"columns":columns,"frames":all.count,"loopFrames":loop.count,"loopSeconds":Double(loop.count)*2/60,
                                  "loopTravelPoints":travel,"cellPoints":cell.width,"heading":motion.heading,"loopError":best.error]
        if let json = try? JSONSerialization.data(withJSONObject:meta,options:[.prettyPrinted,.sortedKeys]) { try? json.write(to:directory.appendingPathComponent("spider-sheet.json")) }
        print("Sprite sheet: \(all.count) frames, loop \(loop.count), travel \(travel)")
        window.orderOut(nil)
    }

    /// --sprite-sheet-tilted: the website spider as the app draws it — the 3/4 view (SpiderRenderViewport.tilt,
    /// a screen-fixed slant) — for 8 walking directions: one row per direction (0°, 45°, … counterclockwise from +x),
    /// first cell resting, then one crawl loop. The page picks the nearest row and rotates only the remainder.
    static func spriteSheetTilted() {
        let directory = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/sprite")
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let species = SpiderSpecies.neon, cell = NSSize(width:300,height:300)
        let renderer = SpiderRenderer(size:cell,species:species)
        let view = ClearSceneView(frame:NSRect(origin:.zero,size:cell))
        view.scene = renderer.scene; view.pointOfView = renderer.camera
        view.antialiasingMode = .multisampling8X; view.backgroundColor = .clear
        let window = NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.colorSpace = .sRGB; window.contentView = view; window.isOpaque = false; window.backgroundColor = .clear
        window.orderFrontRegardless()
        // The app's oblique 3/4 projection for this tile.
        let ortho = SCNCamera(); ortho.usesOrthographicProjection = true
        ortho.orthographicScale = Double(cell.height/2/species.scale); ortho.zNear = 1; ortho.zFar = 1600
        let k = SpiderRenderViewport.tilt
        let shear = simd_float4x4(columns:(SIMD4(1,0,0,0),SIMD4(0,1,0,0),SIMD4(0,k,1,0),SIMD4(0,1000*k,0,1)))
        renderer.camera.camera?.projectionTransform = SCNMatrix4(simd_float4x4(ortho.projectionTransform(withViewportSize:cell))*shear)
        let motion = SpiderMotion(bounds:CGRect(x:0,y:0,width:20000,height:2000),position:V3(300,1000,0))
        motion.cruiseSpeed = species.speed; motion.acceleration = species.acceleration; motion.gaitTempo = species.gaitTempo
        motion.bodyScale = 1
        let directions = 8
        // The spider walks along +x; turning the camera about its view axis shows it walking the other ways,
        // while the slant stays "up" on screen, as on the desktop.
        func shots() -> [NSImage] {
            (0..<directions).map { d in
                renderer.camera.simdPosition = V3(motion.position.x,motion.position.y,1000)
                renderer.camera.simdEulerAngles = V3(0,0,-Float(d)*2*Float.pi/Float(directions))
                renderer.render(motion); return view.snapshot()
            }
        }
        func relativeFeet() -> [Float] {
            motion.feet.flatMap { f -> [Float] in let r = rotate(f.position-motion.position,-motion.heading); return [r.x,r.y,f.position.z] }
        }
        for _ in 0..<120 { motion.update(dt:1/60,cursor:nil) }
        let rest = shots()
        motion.crawl(to:V3(19000,1000,0))
        for _ in 0..<150 { motion.update(dt:1/60,cursor:nil) }
        var frames: [[NSImage]] = [], feet: [[Float]] = [], xs: [Float] = []
        for i in 0..<120 {
            if i % 3 == 0 { frames.append(shots()); feet.append(relativeFeet()); xs.append(motion.position.x) }
            motion.update(dt:1/60,cursor:nil)
        }
        var best = (index:6,error:Float.infinity)
        for j in 6..<feet.count {
            let e = zip(feet[0],feet[j]).reduce(Float(0)) { $0+($1.0-$1.1)*($1.0-$1.1) }
            if e < best.error { best = (j,e) }
        }
        let loop = Array(frames[0..<best.index])
        let travel = (xs[best.index]-xs[0])*Float(species.scale)
        let columns = loop.count+1, px = 220
        let sheet = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:px*columns,pixelsHigh:px*directions,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:sheet)
        NSGraphicsContext.current?.imageInterpolation = .high
        for d in 0..<directions {
            for (c,image) in ([rest[d]]+loop.map { $0[d] }).enumerated() {
                image.draw(in:NSRect(x:c*px,y:(directions-1-d)*px,width:px,height:px))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? sheet.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("spider-tilted.png"))
        let meta: [String:Any] = ["cell":px,"columns":columns,"directions":directions,"loopFrames":loop.count,"loopTravelPoints":travel,"cellPoints":cell.width,"loopError":best.error]
        if let json = try? JSONSerialization.data(withJSONObject:meta,options:[.prettyPrinted,.sortedKeys]) { try? json.write(to:directory.appendingPathComponent("spider-tilted.json")) }
        print("Tilted sprite sheet: \(directions) directions × \(columns) frames, travel \(travel)")
        window.orderOut(nil)
    }

    /// --app-icon: the resting neon spider on a dark macOS-style tile, 1024 px (artifacts/icon/icon-1024.png).
    static func appIcon() {
        let directory = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/icon")
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let species = SpiderSpecies.neon, cell = NSSize(width:512,height:512), zoom: CGFloat = 2.35
        let renderer = SpiderRenderer(size:cell,species:species)
        renderer.camera.camera?.orthographicScale = Double(cell.height/2/species.scale/zoom)
        let view = ClearSceneView(frame:NSRect(origin:.zero,size:cell))
        view.scene = renderer.scene; view.pointOfView = renderer.camera
        view.antialiasingMode = .multisampling8X; view.backgroundColor = .clear
        let window = NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.colorSpace = .sRGB; window.contentView = view; window.isOpaque = false; window.backgroundColor = .clear
        window.orderFrontRegardless()
        let motion = SpiderMotion(bounds:CGRect(x:0,y:0,width:2000,height:2000),position:V3(1000,1000,0))
        motion.bodyScale = 1
        motion.turn(by:-0.42)
        for _ in 0..<200 { motion.update(dt:1/60,cursor:nil) }
        renderer.camera.simdPosition = V3(motion.position.x,motion.position.y-3,1000)
        renderer.render(motion)
        let spider = view.snapshot()
        window.orderOut(nil)
        let px = 1024
        let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:px,pixelsHigh:px,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        // macOS icon grid: an 824 px tile centred in 1024, corner radius ~185.
        let tile = NSRect(x:100,y:100,width:824,height:824)
        let shape = NSBezierPath(roundedRect:tile,xRadius:185,yRadius:185)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width:0,height:-12); shadow.shadowColor = NSColor(white:0,alpha:0.45)
        shadow.set()
        NSColor(srgbRed:0.05,green:0.055,blue:0.075,alpha:1).setFill(); shape.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        NSGraphicsContext.current?.saveGraphicsState()
        shape.addClip()
        NSGradient(colors:[NSColor(srgbRed:0.17,green:0.15,blue:0.12,alpha:1),NSColor(srgbRed:0.05,green:0.055,blue:0.075,alpha:1)])?
            .draw(in:shape,relativeCenterPosition:NSPoint(x:0,y:0.15))
        // a few faint radial silk threads behind the spider
        NSColor(srgbRed:1,green:0.85,blue:0.55,alpha:0.10).setStroke()
        for i in 0..<12 {
            let a = CGFloat(i)/12*2 * .pi+0.13, p = NSBezierPath(); p.lineWidth = 2.2
            p.move(to:NSPoint(x:512,y:512)); p.line(to:NSPoint(x:512+cos(a)*700,y:512+sin(a)*700)); p.stroke()
        }
        for r in stride(from:CGFloat(120),through:420,by:100) {
            let ring = NSBezierPath(); ring.lineWidth = 2
            for i in 0...12 { let a = CGFloat(i)/12*2 * .pi+0.13; let q = NSPoint(x:512+cos(a)*r,y:512+sin(a)*r); i == 0 ? ring.move(to:q) : ring.line(to:q) }
            ring.stroke()
        }
        spider.draw(in:NSRect(x:0,y:0,width:1024,height:1024),from:.zero,operation:.sourceOver,fraction:1)
        NSGraphicsContext.current?.restoreGraphicsState()
        NSColor(white:1,alpha:0.08).setStroke(); shape.lineWidth = 2; shape.stroke()
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("icon-1024.png"))
        print("App icon rendered")
    }

    private static func bitmap(_ image:NSImage) -> NSBitmapImageRep { NSBitmapImageRep(data:image.tiffRepresentation!)! }
    static func run() {
        let directory = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts")
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let size = NSSize(width:640,height:480)
        let renderer = SpiderRenderer(size:size)
        let view = ClearSceneView(frame:NSRect(origin:.zero,size:size))
        view.scene = renderer.scene; view.pointOfView = renderer.camera
        view.antialiasingMode = .multisampling4X; view.backgroundColor = .clear
        let window = NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.colorSpace = .sRGB; window.contentView = view; window.isOpaque = false; window.backgroundColor = .clear
        window.orderFrontRegardless()
        func save(_ name:String,_ motion:SpiderMotion) {
            renderer.render(motion)
            let image = view.snapshot()
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff), let png = bitmap.representation(using:.png,properties:[:]) else { return }
            try? png.write(to:directory.appendingPathComponent(name+".png"))
            print("Rendered \(name)")
        }
        let motion = SpiderMotion(bounds:CGRect(origin:.zero,size:size),position:V3(320,245,0))
        save("01-idle",motion)
        motion.crawl(to:V3(470,320,0))
        for _ in 0..<68 { motion.update(dt:1/60,cursor:nil) }
        save("02-crawl",motion)
        motion.transition(.idle); motion.drag(at:motion.world(V3(0,63,0)))
        for _ in 0..<40 { motion.update(dt:1/60,cursor:nil) }
        save("03-drag",motion)
        _ = motion.catchItem(at:motion.world(V3(0,53,0)))
        for _ in 0..<18 { motion.update(dt:1/60,cursor:nil) }
        save("04-pounce",motion)
        for _ in 0..<42 { motion.update(dt:1/60,cursor:nil) }
        save("05-silk-catch",motion)
        let baseline = SpiderMotion(bounds:CGRect(origin:.zero,size:size),position:V3(320,245,0))
        renderer.render(baseline)
        view.backgroundColor = .clear
        let clear = bitmap(view.snapshot())
        view.backgroundColor = NSColor(srgbRed:0.82,green:0.82,blue:0.82,alpha:1)
        let light = bitmap(view.snapshot())
        view.backgroundColor = NSColor(srgbRed:0.10,green:0.10,blue:0.10,alpha:1)
        let dark = bitmap(view.snapshot())
        var count = 0, brightest: CGFloat = 0, difference: CGFloat = 0
        for y in 0..<clear.pixelsHigh { for x in 0..<clear.pixelsWide {
            guard let a = clear.colorAt(x:x,y:y)?.usingColorSpace(.sRGB), a.alphaComponent>0.999 else { continue }
            count += 1
            let b = light.colorAt(x:x,y:y)!.usingColorSpace(.sRGB)!
            let c = dark.colorAt(x:x,y:y)!.usingColorSpace(.sRGB)!
            brightest = max(brightest,max(a.redComponent,max(a.greenComponent,a.blueComponent)))
            for delta in [abs(a.redComponent-b.redComponent),abs(a.greenComponent-b.greenComponent),abs(a.blueComponent-b.blueComponent),abs(a.redComponent-c.redComponent),abs(a.greenComponent-c.greenComponent),abs(a.blueComponent-c.blueComponent)] { difference = max(difference,delta) }
        } }
        let corner = clear.colorAt(x:0,y:0)!.alphaComponent
        let metrics: [String:Any] = ["opaqueSpiderPixels":count,"brightestOpaqueChannel":brightest,"maxBackgroundColorDifference":difference,"transparentCornerAlpha":corner,"hdr":renderer.camera.camera!.wantsHDR,"adaptiveExposure":renderer.camera.camera!.wantsExposureAdaptation,"debugNodesInOverlay":renderer.debug != nil]
        if let json = try? JSONSerialization.data(withJSONObject:metrics,options:[.prettyPrinted,.sortedKeys]) { try? json.write(to:directory.appendingPathComponent("render-audit.json")) }
        precondition(count>1000 && brightest<0.8 && difference<0.035 && corner==0,"Rendering/compositing regression")
        print("Render audit: \(count) opaque pixels; max channel \(brightest); backdrop delta \(difference); corner alpha \(corner)")
        window.orderOut(nil)
    }
}
