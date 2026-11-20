import AppKit
import SceneKit
import QuartzCore
import simd

/// The same SDR, sRGB render surface is used in both study and real transparent windows.
final class ClearSceneView: SCNView {
    override var isOpaque: Bool { false }
    override init(frame: NSRect, options: [String:Any]? = nil) {
        super.init(frame:frame,options:options)
        backgroundColor = .clear
        autoenablesDefaultLighting = false
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 60
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError("Create the rendering surface programmatically") }
}

enum SpiderStyle { case natural, neon }

final class SpiderRenderer {
    let scene = SCNScene()
    let root = SCNNode()
    let anatomy = SCNNode()
    let abdomen: SCNNode
    let head: SCNNode
    let camera = SCNNode()
    var debugOptions: SpiderDebugOptions = []
    let debug: SpiderDebugRenderer?
    private var legs: [[SCNNode]] = []
    private var palps: [[SCNNode]] = [], fangs: [SCNNode] = []
    private var contacts: [SCNNode] = []
    private lazy var legPoses = legs.map { $0.map(SpiderNodePose.init) }
    private var legMesh: SpiderGeometry.LegMesh?
    private var legSegments: [(V3,V3,Float)] = []
    private lazy var palpPoses = palps.map { $0.map(SpiderNodePose.init) }
    private lazy var contactPoses = contacts.map(SpiderNodePose.init)
    private var appliedScale: Float?
    private let limbHair = SCNNode(), shadow = SCNNode(), parcel = SCNNode(), silkShot = SCNNode(), silkWrap = SCNNode()
    private var lastSignature: [Float] = []
    /// Neon only: soft glow shells that follow the legs and body.
    private var haloMaterial: SCNMaterial?
    private var cachedWrap: SCNGeometry?
    /// While a caught clipboard object is wrapped and carried, the parcel wears its real preview.
    var carrying = false
    /// The catch's parcel is drawn elsewhere (by the silk flight), so the spider's own parcel stays hidden.
    var parcelHidden = false
    var parcelImage: NSImage? {
        didSet {
            guard parcelImage !== oldValue else { return }
            let m = parcel.geometry?.firstMaterial
            m?.diffuse.contents = parcelImage.map { SpiderRenderer.veiled($0) } ?? NSColor(srgbRed:0.19,green:0.19,blue:0.19,alpha:1)
            forceNextRender()
        }
    }
    private let skin: SCNMaterial, hinge: SCNMaterial, fiber: SCNMaterial, silk: SCNMaterial

    let style: SpiderStyle
    let species: SpiderSpecies
    private var legRadius: Float { species.legThickness }
    /// Neon only: 0 = gold hunting glow, 1 = red target-lock glow (during a catch).
    var lock: Float = 0
    private var neonMaterials: [(SCNMaterial, Float)] = []
    private var limb: SCNMaterial
    private var eyeMaterial: SCNMaterial
    private var appliedLock: Float = -1
    /// Eye highlights (they shift toward the pointer: the eyes follow it) with their resting place and eye size.
    /// All eight highlights as one mesh (one draw call), slid together toward the pointer.
    private var glints: (node: SCNNode, base: V3, size: Float)?
    /// Sleep: a thread from the body up off the desk, and the glow dimmed.
    private let sleepThread = SCNNode()
    private var sleep: Float = 0, breath: Float = 0, appliedSleep: Float = -1, appliedBreath: Float = -1
    private var abdomenGlow: SCNMaterial?

    convenience init(size: CGSize, debugAllowed: Bool = false, style: SpiderStyle = .natural) {
        self.init(size:size,debugAllowed:debugAllowed,species:style == .neon ? .neon : .classic)
    }

    init(size: CGSize, debugAllowed: Bool = false, species: SpiderSpecies) {
        self.species = species
        self.style = species.glow ? .neon : .natural
        let style = self.style
        skin = SpiderGeometry.material(species.carapace,roughness:species.roughness)
        if species.roughness > 0.5 { skin.roughness.contents = SpiderGeometry.texture(normal:false) }
        skin.normal.contents = SpiderGeometry.texture(normal:true); skin.normal.intensity = 0.11
        // Glossy chitin: a thin clear coat over the matte hairy base gives real 3D highlights.
        skin.clearCoat.contents = species.clearCoat; skin.clearCoatRoughness.contents = species.clearCoat > 0.8 ? 0.12 : 0.36
        hinge = SpiderGeometry.material(species.hinge,roughness:0.80)
        fiber = SpiderGeometry.material(species.fiber,roughness:0.85)
        silk = SpiderGeometry.material(V3(0.72,0.71,0.68),roughness:0.56)
        silk.diffuse.contents = NSColor(srgbRed:0.72,green:0.71,blue:0.68,alpha:0.50)
        silk.blendMode = .alpha; silk.transparencyMode = .aOne; silk.writesToDepthBuffer = false
        let abdomenSkin = SpiderGeometry.material(species.abdomen,roughness:species.roughness)
        abdomenSkin.roughness.contents = skin.roughness.contents
        abdomenSkin.normal.contents = skin.normal.contents; abdomenSkin.normal.intensity = 0.11
        abdomenSkin.clearCoat.contents = min(1,species.clearCoat+0.03); abdomenSkin.clearCoatRoughness.contents = species.clearCoat > 0.8 ? 0.1 : 0.38
        if let marking = species.abdomenTexture() { abdomenSkin.diffuse.contents = marking }
        abdomen = SpiderGeometry.shell(.abdomen,material:abdomenSkin)
        head = SpiderGeometry.shell(.carapace,material:skin)
        debug = debugAllowed ? SpiderDebugRenderer(scene:scene) : nil
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = nil; scene.lightingEnvironment.intensity = 0
        scene.rootNode.addChildNode(root); root.addChildNode(anatomy)
        anatomy.addChildNode(head); head.simdPosition = V3(0,3,10)
        anatomy.addChildNode(abdomen); abdomen.simdPosition = V3(0,-11.4,11)
        abdomen.pivot = SCNMatrix4MakeTranslation(0,16,0)
        head.simdScale = species.carapaceScale; abdomen.simdScale = species.abdomenScale
        let isSpider = true
        // The golden spider has a smooth, glossy body (spines only on the legs).
        if !species.glow {
            head.addChildNode(SpiderGeometry.shellHairs(.carapace,count:Int(90*species.hairiness),material:fiber,length:min(2.2,species.hairiness)))
            abdomen.addChildNode(SpiderGeometry.shellHairs(.abdomen,count:Int(130*species.hairiness),material:fiber,length:min(2.2,species.hairiness)))
        }
        let pedicel = SpiderGeometry.sphere(V3(2.7,4.5,2.3),material:hinge)
        pedicel.simdPosition = V3(0,-10.5,8)
        head.isHidden = !isSpider; abdomen.isHidden = !isSpider
        let wet = SpiderGeometry.material(V3(repeating:0.018),roughness:0.22)
        limb = style == .neon || species.leg != species.carapace ? skin.copy() as! SCNMaterial : skin
        if species.leg != species.carapace && style != .neon {
            limb.diffuse.contents = NSColor(srgbRed:CGFloat(species.leg.x),green:CGFloat(species.leg.y),blue:CGFloat(species.leg.z),alpha:1)
        }
        eyeMaterial = style == .neon ? wet.copy() as! SCNMaterial : wet
        // Rigid parts of the head and body are merged into a few meshes: fewer draw calls every frame.
        let eyes = SCNNode(), rigid = SCNNode(), fangParts = SCNNode()
        for (i,(x,y,r)) in [(-2.4,14.8,1.15),(2.4,14.8,1.15),(-5.1,13.3,0.7),(5.1,13.3,0.7),(-6.8,10.4,0.6),(6.8,10.4,0.6),(-3.7,16.2,0.6),(3.7,16.2,0.6)].enumerated() {
            // Front median eyes scale per species (a jumping spider's are enormous and face forward).
            let k: Float = i < 2 ? species.frontEyes : 1
            let size = Float(r)*k
            let eye = SpiderGeometry.sphere(V3(size,size*0.8,size*(k > 1.5 ? 0.9 : 0.65)),material:eyeMaterial)
            eye.simdPosition = V3(Float(x)*(i < 2 ? max(1,k*0.75) : 1),Float(y)+(i < 2 && k > 1.5 ? 2.2 : 0),13.5+(i < 2 && k > 1.5 ? 0.8 : 0))
            if isSpider { eyes.addChildNode(eye) }
        }
        let profiles: [[Float]] = [
            [0.55,0.88,1,0.93,0.65], // coxa / trochanter
            [0.62,0.83,1,0.91,0.67,0.48], // muscular femur
            [0.77,1,0.96,0.76], // short patella cuff
            [0.77,0.95,0.84,0.67,0.42], // tapered tibia
            [0.71,0.81,0.62,0.42,0.21], // slender metatarsus
            [0.74,0.67,0.43,0.26] // fine, grounded tarsal tip
        ]
        // Knee bands (red-knee tarantula, house spider rings) colour the patella segment.
        let bandMaterial: SCNMaterial
        if let band = species.band, style != .neon {
            bandMaterial = limb.copy() as! SCNMaterial
            bandMaterial.diffuse.contents = NSColor(srgbRed:CGFloat(band.x),green:CGFloat(band.y),blue:CGFloat(band.z),alpha:1)
        } else { bandMaterial = limb }
        // Each segment is one mesh with its own setae and spines (one draw call); its articulation is drawn
        // by the limb shader as a dark band, so no separate joint spheres are needed.
        let nominal: [(radius: Float, length: Float, setae: Int, spines: Int)] = [(2.8,4.5,0,0),(2.55,35,44,6),(2.1,6,10,0),(1.6,23,36,5),(0.85,15,24,3),(0.43,4,6,0)]
        let hair = species.hairiness
        let templates = profiles.enumerated().map { (i,profile) in
            SpiderGeometry.limbDetailed(profile:profile,bend:i==1 ? 0.12 : 0.04,radius:nominal[i].radius*species.legThickness,length:nominal[i].length,
                                        setae:Int(Float(nominal[i].setae)*hair),spines:Int(Float(nominal[i].spines)*hair),seed:i*31+7,material:i == 2 ? bandMaterial : limb)
        }
        // One mesh draws all 48 segments (see LegMesh); the per-segment nodes are only a fallback.
        if let mesh = SpiderGeometry.LegMesh(templates:templates,legs:8,materials:[limb,bandMaterial],materialOf:{ $0 == 2 && bandMaterial !== limb ? 1 : 0 }) {
            legMesh = mesh; scene.rootNode.addChildNode(mesh.node)
        } else {
            legs = (0..<8).map { _ in templates.map { SCNNode(geometry:$0) } }
            for nodes in legs { for node in nodes { scene.rootNode.addChildNode(node) } }
        }
        scene.rootNode.addChildNode(limbHair)
        if style == .neon {
            let halo = SCNMaterial(); halo.lightingModel = .constant
            halo.diffuse.contents = NSColor.black; halo.isDoubleSided = false
            halo.blendMode = .add; halo.writesToDepthBuffer = false; halo.readsFromDepthBuffer = false
            halo.shaderModifiers = [.fragment:Self.haloShader]
            haloMaterial = halo
            // No leg glow tubes (they shimmered) and no aura: the glow comes from the emissive limbs and rim.
            for (shell,type,scale) in [(head,SpiderGeometry.Shell.carapace,Float(1.18)),(abdomen,.abdomen,Float(1.12))] {
                let glow = SpiderGeometry.shell(type,material:halo)
                glow.simdScale = V3(scale,scale,scale*0.8); glow.renderingOrder = -5
                shell.addChildNode(glow)
            }
        }
        for side: Float in [-1,1] where isSpider {
            let chelicera = SpiderGeometry.sphere(V3(2.5,3.5,2.6),material:hinge)
            chelicera.simdPosition = V3(side*2.8,17,7.5); rigid.addChildNode(chelicera)
            let fang = SCNNode(geometry:SpiderGeometry.curve([V3(side*3,19,7),V3(side*3.5,22,5.5),V3(side*1.2,23.5,4.2)],radius:0.48,material:wet))
            fangParts.addChildNode(fang)
            let palpNodes = (0..<3).map { _ in SCNNode(geometry:templates[4]) }
            for p in palpNodes { anatomy.addChildNode(p) }; palps.append(palpNodes)
            let spinneret = SpiderGeometry.sphere(V3(1.1,2.5,1.1),material:hinge)
            spinneret.simdPosition = V3(side*2,-47.2,7); rigid.addChildNode(spinneret)
        }
        if isSpider {
            rigid.addChildNode(pedicel)
            for group in [rigid,fangParts] { let merged = group.flattenedClone(); anatomy.addChildNode(merged); fangs.append(merged) }
        }
        let texture = SpiderGeometry.shadowTexture()
        func shadowNode(size: CGSize) -> SCNNode {
            let g = SCNPlane(width:size.width,height:size.height)
            let m = SCNMaterial(); m.lightingModel = .constant
            m.diffuse.contents = texture; m.writesToDepthBuffer = false; m.isDoubleSided = true; m.blendMode = .alpha
            g.materials = [m]; return SCNNode(geometry:g)
        }
        shadow.geometry = shadowNode(size:CGSize(width:92,height:116)).geometry
        shadow.renderingOrder = -10; scene.rootNode.addChildNode(shadow)
        for _ in 0..<8 {
            let p = shadowNode(size:CGSize(width:7,height:7)); p.renderingOrder = -9
            scene.rootNode.addChildNode(p); contacts.append(p)
        }
        parcel.geometry = SpiderGeometry.sphere(V3(repeating:4),material:SpiderGeometry.material(V3(repeating:0.19),roughness:0.86)).geometry?.copy() as? SCNGeometry
        parcel.geometry?.firstMaterial = SpiderGeometry.material(V3(repeating:0.19),roughness:0.62)
        parcel.simdScale = V3(repeating:4)
        anatomy.addChildNode(parcel); anatomy.addChildNode(silkShot); anatomy.addChildNode(silkWrap)
        scene.rootNode.addChildNode(sleepThread); sleepThread.isHidden = true
        // Real (hidden) geometry from the start, so warming up the renderer compiles every pipeline the
        // catch and sleep will need; nothing is compiled mid-animation.
        let stub = SpiderGeometry.curve([V3(0,0,0),V3(0,1,0),V3(0,2,0)],radius:0.1,material:silk)
        silkShot.geometry = stub; silkWrap.geometry = stub; sleepThread.geometry = stub
        parcel.isHidden = true; silkShot.isHidden = true; silkWrap.isHidden = true
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.zNear = 1; camera.camera?.zFar = 1600
        // Transparent pixels must never drive exposure: a clear view's histogram is mostly black.
        camera.camera?.wantsHDR = false
        camera.camera?.wantsExposureAdaptation = false
        camera.camera?.exposureOffset = 0
        camera.camera?.bloomIntensity = 0
        scene.rootNode.addChildNode(camera); resize(size)
        if style == .neon {
            // Neon hunter: glowing limbs and hairs, a hot rim on the dark shell, ember eyes.
            // Leg hairs glow only faintly: bright sub-pixel hairs sparkle (flicker) as the spider moves.
            neonMaterials = [(limb,0.62),(fiber,0.3),(hinge,0.7),(skin,0.0),(abdomenSkin,0.0)]
            for (m,_) in neonMaterials { m.shaderModifiers = [.fragment:Self.rimShader] }
            abdomenSkin.shaderModifiers = [.fragment:Self.abdomenShader]; abdomenGlow = abdomenSkin
            // Real cuticle, not plastic: a lacquered shell with fine pits (carapace) and a velvet of tiny hairs
            // under the gloss (abdomen); a clear coat keeps the sharp highlights.
            let plates = SpiderGeometry.cuticle(velvet:false), velvet = SpiderGeometry.cuticle(velvet:true)
            for (m,detail) in [(skin,plates),(abdomenSkin,velvet)] {
                m.normal.contents = detail.normal; m.normal.intensity = m === skin ? 0.28 : 0.32
                m.normal.wrapS = .repeat; m.normal.wrapT = .repeat
                m.normal.contentsTransform = SCNMatrix4MakeScale(m === skin ? 2 : 4,m === skin ? 2 : 2,1)
                m.roughness.contents = detail.roughness; m.roughness.wrapS = .repeat; m.roughness.wrapT = .repeat
                m.roughness.contentsTransform = m.normal.contentsTransform
                m.clearCoat.contents = 0.85; m.clearCoatRoughness.contents = 0.11
                m.clearCoatNormal.contents = nil
            }
            // Legs: fine cuticle streaks; the limb shader adds the joint bands and the rim.
            limb.diffuse.contents = SpiderGeometry.legTexture(tint:species.leg)
            limb.diffuse.wrapS = .repeat; limb.diffuse.wrapT = .clamp
            limb.roughness.contents = 0.48
            limb.shaderModifiers = [.fragment:Self.limbShader]
            // Eyes: glassy domes that mirror the room.
            eyeMaterial.clearCoat.contents = 1.0; eyeMaterial.clearCoatRoughness.contents = 0.02; eyeMaterial.roughness.contents = 0.12
            // Eyes: deep red, each with a bright specular dot.
            let glint = SCNMaterial(); glint.lightingModel = .constant; glint.diffuse.contents = NSColor.white
            let highlights = SCNNode(); var sizes: Float = 0
            for node in eyes.childNodes {
                let s = node.simdScale.x
                let g = SpiderGeometry.sphere(V3(repeating:max(0.2,s*0.26)),material:glint)
                g.simdPosition = node.simdPosition+V3(-s*0.3,s*0.3,s*0.6)
                highlights.addChildNode(g); sizes += s
            }
            let merged = highlights.flattenedClone()
            anatomy.addChildNode(merged)
            glints = (merged,merged.simdPosition,sizes/Float(max(1,highlights.childNodes.count)))
            skin.diffuse.contents = NSColor(srgbRed:CGFloat(species.carapace.x),green:CGFloat(species.carapace.y),blue:CGFloat(species.carapace.z),alpha:1)
            abdomenSkin.diffuse.contents = NSColor(srgbRed:CGFloat(species.abdomen.x),green:CGFloat(species.abdomen.y),blue:CGFloat(species.abdomen.z),alpha:1)
            applyLock()
        }
        if isSpider { anatomy.addChildNode(eyes.flattenedClone()) }
        // Soft studio reflections (image-based light); the direct lights are trimmed to keep the same exposure.
        scene.lightingEnvironment.contents = SpiderGeometry.studioEnvironment()
        scene.lightingEnvironment.intensity = 0.9
        light(type:.ambient,intensity:110,color:V3(0.92,0.94,1),angles:.zero)
        light(type:.directional,intensity:950,color:V3(1,0.96,0.9),angles:V3(-0.55,-0.65,-0.2))
        light(type:.directional,intensity:330,color:V3(0.83,0.9,1),angles:V3(0.7,1.1,1.4))
        // Low grazing light: catches leg segments and the shell rim, so the body reads as volume on any desktop.
        light(type:.directional,intensity:320,color:V3(0.78,0.86,1),angles:V3(-1.25,0,2.4))
    }
    func resize(_ size: CGSize) {
        camera.simdPosition = V3(Float(size.width/2),Float(size.height/2),1000)
        camera.camera?.orthographicScale = Double(size.height/2)
    }
    func forceNextRender() { lastSignature = [] }
    /// True when the pose differs from the last one submitted (cheap; main thread).
    func needsRender(_ motion: SpiderMotion) -> Bool {
        var signature: [Float] = [motion.position.x,motion.position.y,motion.heading,motion.bodyLift,motion.bodyPitch,motion.bodyRoll,motion.bodyYaw,motion.abdomenPitch,motion.bodyOffset.x,motion.bodyOffset.y,motion.palpProbe,motion.catchProgress,Float(debugOptions.rawValue),carrying ? 1 : 0,parcelHidden ? 1 : 0,lock,motion.bodyScale,shield,
                                motion.gaze?.x ?? -1,motion.gaze?.y ?? -1,motion.sleepAmount,motion.glowBreath]
        for foot in motion.feet { signature += [foot.position.x,foot.position.y,foot.position.z,foot.supported ? 1 : 0] }
        if signature.count==lastSignature.count && zip(signature,lastSignature).allSatisfy({ abs($0.0-$0.1)<0.0002 }) { return false }
        lastSignature = signature
        return true
    }
    @discardableResult func renderIfNeeded(_ motion: SpiderMotion) -> Bool {
        var signature: [Float] = [motion.position.x,motion.position.y,motion.heading,motion.bodyLift,motion.bodyPitch,motion.bodyRoll,motion.bodyYaw,motion.abdomenPitch,motion.bodyOffset.x,motion.bodyOffset.y,motion.palpProbe,motion.catchProgress,Float(debugOptions.rawValue),carrying ? 1 : 0,parcelHidden ? 1 : 0]
        for foot in motion.feet { signature += [foot.position.x,foot.position.y,foot.position.z,foot.supported ? 1 : 0] }
        if signature.count==lastSignature.count && zip(signature,lastSignature).allSatisfy({ abs($0.0-$0.1)<0.0002 }) { return false }
        lastSignature = signature
        render(motion); return true
    }
    func render(_ motion: SpiderPose) {
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0; SCNTransaction.disableActions = true
        sleep = motion.sleepAmount; breath = motion.glowBreath
        if style == .neon && (abs(lock-appliedLock) > 0.01 || abs(shield-appliedShield) > 0.01 || abs(sleep-appliedSleep) > 0.01 || abs(breath-appliedBreath) > 0.01) { applyLock() }
        // The eyes follow the pointer: highlights slide toward it.
        let look: V3 = motion.gaze.map { g in
            let d = rotate(g-motion.position,-motion.heading); let l = simd_length(V3(d.x,d.y,0))
            return l > 1 ? V3(d.x/l,d.y/l,0) : .zero
        } ?? .zero
        if let g = glints { g.node.simdPosition = g.base+look*g.size*0.32 }
        // Asleep: hanging from a thread that rises off the desk.
        sleepThread.isHidden = motion.sleepAmount < 0.02
        if !sleepThread.isHidden {
            let top = motion.bodyPoint(V3(0,-6,14))
            sleepThread.geometry = SpiderGeometry.curve([top,top+V3(0,0,90),top+V3(0,0,260)],radius:0.12,material:silk)
            sleepThread.opacity = CGFloat(min(1,motion.sleepAmount*1.4))
        }
        root.simdPosition = motion.position+rotate(motion.bodyOffset,motion.heading)+V3(0,0,motion.bodyLift)
        root.simdOrientation = motion.bodyOrientation
        let k = motion.bodyScale
        let scaleChanged = appliedScale != k
        if scaleChanged { root.simdScale = V3(repeating:k); shadow.simdScale = V3(repeating:k); appliedScale = k }
        abdomen.simdEulerAngles.x = motion.abdomenPitch
        var poses: [LegPose] = []
        let needsDebugPoses = debug != nil && motion is SpiderMotion
        let radii: [Float] = [2.8,2.55,2.1,1.6,0.85,0.43].map { $0*legRadius*k }
        legSegments.removeAll(keepingCapacity:true)
        for (i,foot) in motion.feet.enumerated() {
            let pose = LegPose.solve(foot,motion:motion)
            if needsDebugPoses { poses.append(pose) }
            if legMesh != nil { for j in 0..<6 { legSegments.append((pose.points[j],pose.points[j+1],radii[j])) } }
            else { for j in 0..<6 { legPoses[i][j].connect(pose.points[j],pose.points[j+1],radius:radii[j]) } }
            contactPoses[i].move(V3(foot.position.x,foot.position.y,0.1))
            contactPoses[i].resize(V3(repeating:k))
            contactPoses[i].fade(CGFloat((1-clamp(foot.position.z/6))*0.8))
        }
        legMesh?.update(legSegments)
        let t = motion.state == .catching ? motion.catchTime : 0
        let grip = smooth((t-0.23)/0.13)*(1-smooth((t-1.03)/0.2))
        // Palps are mostly still; one restrained motion every thirteen seconds, or an actual grab.
        let probe = motion.palpProbe
        for (i,nodes) in palps.enumerated() {
            let side: Float = i==0 ? -1 : 1
            let points = [V3(side*5,14,9),V3(side*7.5,18.8,8.8),V3(side*(7-1.4*grip),22,6.8+probe),V3(side*(4.5-1.3*grip),23.5,5.5+probe+grip)]
            for j in 0..<nodes.count { palpPoses[i][j].connect(points[j],points[j+1],radius:[1.3,0.95,0.48][j]) }
        }
        shadow.simdPosition = motion.position+rotate(V3(0,-12*k,0.08),motion.heading)
        shadow.simdEulerAngles.z = motion.heading
        shadow.opacity = CGFloat(0.65*(1-clamp(motion.bodyLift/22)*0.3))
        renderSilk(t:t,motion:motion)
        if let live = motion as? SpiderMotion { debug?.update(live,poses:poses,options:debugOptions) }
        SCNTransaction.commit()
    }
    private func renderSilk(t: Float, motion: SpiderPose) {
        // Carried prey stays wrapped under the chelicerae until it is hung in the web.
        let holding = carrying && (motion.state != .catching || t>1.14)
        let reveal = smooth((t-0.29)/0.12), fade = holding ? 1 : 1-smooth((t-1.14)/0.23)
        parcel.isHidden = parcelHidden || (!holding && (t<0.29 || t>1.37))
        let origin = rotate(motion.catchTarget-motion.position,-motion.heading)
        // A caught clipboard object is wrapped into a larger cocoon so its contents stay recognisable.
        let cocoon: V3 = parcelImage == nil ? V3(3.5,3.0,2.3) : V3(9.5,7.5,4.6)
        let captured = parcelImage == nil ? V3(0,28,8) : V3(0,33,9)
        parcel.simdPosition = holding ? captured : mix(V3(origin.x,origin.y,9),captured,smooth((t-0.29)/0.19))
        let size: Float = holding ? 1 : 0.7+reveal*0.3
        // A slightly flattened cocoon rather than a ball.
        parcel.simdScale = cocoon*size
        parcel.opacity = holding ? 1 : CGFloat(reveal*fade)
        silkShot.isHidden = t<0.46 || t>0.76
        if !silkShot.isHidden {
            let start = V3(0,19,6), end = parcel.simdPosition
            let extent = smooth((t-0.46)/0.075)
            let points = (0...12).map { i -> V3 in
                let u = Float(i)/12*extent
                return mix(start,end,u)+V3(0,0,sin(u * .pi)*0.6)
            }
            silkShot.geometry = SpiderGeometry.curve(points,radius:0.085,material:silk)
            silkShot.opacity = CGFloat(1-smooth((t-0.65)/0.11))
        }
        silkWrap.isHidden = parcelHidden || (!holding && (t<0.54 || t>1.37))
        if !silkWrap.isHidden {
            let extent = holding ? 1 : smooth((t-0.54)/0.35)
            let points = (0...64).map { i -> V3 in
                let u = Float(i)/64*extent, angle = u*6 * .pi
                let latitude = (u-0.5)*1.3
                let c = cos(latitude)
                return parcel.simdPosition+V3(cos(angle)*c*cocoon.x*1.06,sin(angle)*c*cocoon.y*1.06,sin(latitude)*cocoon.z*1.1)
            }
            if holding, let cachedWrap { silkWrap.geometry = cachedWrap }
            else {
                let g = SpiderGeometry.curve(points.map { $0-parcel.simdPosition },radius:0.075,material:silk)
                silkWrap.geometry = g
                if holding { cachedWrap = g } else { cachedWrap = nil }
            }
            silkWrap.simdPosition = parcel.simdPosition
            silkWrap.opacity = CGFloat(holding ? 0.85 : fade*0.8)
        }
    }
    /// Current glow colour: gold while roaming, shifting to red as it locks on to prey.
    var glowColor: NSColor {
        let t = CGFloat(clamp(lock)), s = CGFloat(clamp(shield))
        let hunt = (r:1.0,g:0.6*(1-t)+0.1*t,b:0.1*(1-t)+0.2*t)
        // The secret shield: a cool blue-white, never red.
        let cool = (r:0.72,g:0.86,b:1.0)
        return NSColor(srgbRed:hunt.r*(1-s)+cool.r*s,green:hunt.g*(1-s)+cool.g*s,blue:hunt.b*(1-s)+cool.b*s,alpha:1)
    }
    /// 0…1: the "I'm not looking" shield after a secret is caught: the glow dims and turns cool blue-white.
    var shield: Float = 0
    private var appliedShield: Float = -1
    private func applyLock() {
        appliedLock = lock; appliedShield = shield
        // Dimmed while shielding a secret.
        appliedSleep = sleep; appliedBreath = breath
        let dim = CGFloat((1-0.6*clamp(shield))*(1-0.55*clamp(sleep))*(1+0.25*breath))
        let c = glowColor
        let rim = SCNVector3(c.redComponent*1.6,c.greenComponent*1.6,c.blueComponent*1.6)
        let faint = SCNVector3(rim.x*0.2,rim.y*0.2,rim.z*0.2)
        for (m,emission) in neonMaterials {
            // Hairs are seen almost edge-on, so a full rim makes every hair a bright sparkling line.
            m.setValue(NSValue(scnVector3:m === fiber ? faint : rim),forKey:"rimColor")
            m.setValue(NSNumber(value:emission > 0 ? 1.6 : 2.4),forKey:"rimPower")
            m.emission.contents = emission > 0 ? c.withAlphaComponent(1).blended(withFraction:1-CGFloat(emission)*0.85*dim,of:.black) : NSColor.black
        }
        haloMaterial?.setValue(NSValue(scnVector3:SCNVector3(c.redComponent,c.greenComponent,c.blueComponent)),forKey:"glowColor")
        haloMaterial?.setValue(NSNumber(value:(0.42+0.15*lock+0.3*shield+0.1*breath)*(1-0.6*sleep)),forKey:"glowStrength")
        // The hunt glow rises from inside the abdomen while it locks on (none at rest, none for secrets).
        abdomenGlow?.setValue(NSValue(scnVector3:SCNVector3(c.redComponent,c.greenComponent,c.blueComponent)),forKey:"innerColor")
        abdomenGlow?.setValue(NSNumber(value:lock*(1-shield)*0.7),forKey:"inner")
        eyeMaterial.emission.contents = NSColor(srgbRed:0.62+0.3*CGFloat(lock),green:0.02,blue:0.03,alpha:1)
        eyeMaterial.diffuse.contents = NSColor(srgbRed:0.25,green:0.0,blue:0.01,alpha:1)
    }
    /// Soft tube of light around each limb: brightest straight through the middle, fading to nothing at the rim.
    static let haloShader = """
    #pragma arguments
    float3 glowColor;
    float glowStrength;
    #pragma body
    // Faded against the tilted 3/4 view (SpiderRenderViewport.tilt), so it vanishes at its drawn edge.
    float facing = clamp(dot(normalize(_surface.normal), normalize(float3(0.0, -0.42, 0.91))), 0.0, 1.0);
    float a = pow(facing, 3.0) * glowStrength;
    _output.color = float4(glowColor * a, a);
    """
    static func segmentHairs(count: Int, reach hairLength: Float = 1, radius: Float, length: Float, seed: Int, material: SCNMaterial) -> SCNNode {
        // Built in the segment's scaled local space: x/z are divided by its radius, y by its length.
        var fibers: [(V3,V3)] = []
        for k in 0..<count {
            let a = Float(k)*2.39996+Float(seed)*0.7
            let y = (Float(k)+0.8)/(Float(count)+0.6)-0.5
            let out = V3(cos(a),0,abs(sin(a))*0.6+0.4)
            let base = V3(out.x*0.92,y,out.z*0.92)
            let lean: Float = k % 2 == 0 ? 0.55 : -0.45
            let reach = V3(out.x*1.3*hairLength/radius,lean*hairLength/length,out.z*hairLength/radius)
            let tip = base+reach
            fibers.append((base,tip))
        }
        return SCNNode(geometry:SpiderGeometry.hairs(fibers,material:material))
    }
    /// Legs: rim light like the other glowing parts, then the articulation: a dark band at each segment's tip end
    /// (v → 1, also the spines), a lighter membrane at its body end (v → 0).
    static let limbShader = """
    #pragma arguments
    float3 rimColor;
    float rimPower;
    #pragma body
    float v = _surface.diffuseTexcoord.y;
    float band = smoothstep(0.82, 0.965, v);
    float membrane = 1.0 - smoothstep(0.0, 0.09, v);
    float facing = clamp(dot(normalize(_surface.normal), normalize(float3(0.0, -0.42, 0.91))), 0.0, 1.0);
    _output.color.rgb += rimColor * pow(1.0 - facing, rimPower);
    _output.color.rgb *= 1.0 - 0.74 * band - 0.28 * membrane;
    """
    /// The abdomen: gold rim, plus the hunt glow rising inside it while catching (`inner` 0 at rest).
    static let abdomenShader = """
    #pragma arguments
    float3 rimColor;
    float rimPower;
    float3 innerColor;
    float inner;
    #pragma body
    float facing = clamp(dot(normalize(_surface.normal), normalize(float3(0.0, -0.42, 0.91))), 0.0, 1.0);
    _output.color.rgb += rimColor * pow(1.0 - facing, rimPower);
    _output.color.rgb += innerColor * inner * pow(facing, 2.2);
    """
    static let rimShader = """
    #pragma arguments
    float3 rimColor;
    float rimPower;
    #pragma body
    float facing = clamp(dot(normalize(_surface.normal), normalize(float3(0.0, -0.42, 0.91))), 0.0, 1.0);
    _output.color.rgb += rimColor * pow(1.0 - facing, rimPower);
    """

    /// The preview seen through a few layers of silk.
    static func veiled(_ image: NSImage) -> NSImage {
        ItemPreview.draw(NSSize(width:96,height:64)) { rect in
            NSColor(srgbRed:0.82,green:0.82,blue:0.79,alpha:1).setFill(); rect.fill()
            image.draw(in:rect.insetBy(dx:14,dy:10),from:.zero,operation:.sourceOver,fraction:0.9)
            NSColor(srgbRed:0.95,green:0.95,blue:0.92,alpha:0.28).setFill(); rect.fill(using:.sourceOver)
        }
    }
    private func light(type: SCNLight.LightType,intensity: CGFloat,color:V3,angles:V3) {
        let node = SCNNode(); node.light = SCNLight(); node.light?.type = type
        node.light?.intensity = intensity; node.light?.color = NSColor(srgbRed:CGFloat(color.x),green:CGFloat(color.y),blue:CGFloat(color.z),alpha:1)
        node.simdEulerAngles = angles; scene.rootNode.addChildNode(node)
    }
}
