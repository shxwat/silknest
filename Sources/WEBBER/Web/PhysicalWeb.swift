import AppKit
import SceneKit
import simd

struct PhysicalWebDebugOptions: OptionSet {
    let rawValue: Int
    static let anchors = Self(rawValue:1<<0)
}

/// The web is the clipboard UI. One procedural orb web that lives compactly in a corner and can
/// physically spread across the display; caught items hang from it on their own strands.
final class PhysicalWeb {
    let scene = SCNScene()
    let camera = SCNNode()
    let compactSize: CGSize
    private(set) var geometry: WebGeometry
    var debugOptions: PhysicalWebDebugOptions = []

    private(set) var expansion: Float = 0
    private var expansionVelocity: Float = 0
    private(set) var isOpen = false
    private(set) var items: [WebItem] = []
    private(set) var hoveredID: Int?
    var selectedID: Int?
    /// Keyboard focus in the Nest: the object ↩ pastes. Drawn with a warm outline.
    var focusID: Int? { didSet { if focusID != oldValue { quietFrames = 0 } } }
    /// Objects that do not match the current search (drawn faint).
    var dimmedIDs: Set<Int> = [] { didSet { if dimmedIDs != oldValue { quietFrames = 0 } } }
    /// Quick-paste numbers (1–9) shown on objects.
    var badgeNumbers: [Int: Int] = [:] { didSet { if badgeNumbers != oldValue { quietFrames = 0 } } }
    private var ringNodes: [Int: SCNNode] = [:]
    private var badgeNodes: [Int: (number: Int, node: SCNNode)] = [:]

    private let silkNode = SCNNode(), silkShadow = SCNNode(), strandNode = SCNNode(), strandShadow = SCNNode()
    private let objects = SCNNode(), debugRoot = SCNNode()
    private let silkMaterial = PhysicalWeb.lineMaterial(alpha:0.46)
    private let strandMaterial = PhysicalWeb.lineMaterial(alpha:0.7)
    private let shadowMaterial = PhysicalWeb.shadowMaterial()
    private var itemNodes: [Int: SCNNode] = [:]
    private var labelNodes: [Int: SCNNode] = [:]
    private var images: [Int: NSImage] = [:]
    private var captions: [Int: String] = [:]
    private var builtExpansion: Float = -1
    private var time: Float = 0
    private var quietFrames = 0

    init(compactSize: CGSize, expandedBounds: CGRect) {
        self.compactSize = compactSize
        geometry = WebGeometry(compactHub:V3(275,235,0),expandedBounds:expandedBounds)
        scene.background.contents = NSColor.clear
        for (node,order) in [(silkShadow,-3),(silkNode,0),(strandShadow,1),(strandNode,2),(objects,5),(debugRoot,20)] {
            node.renderingOrder = order; scene.rootNode.addChildNode(node)
        }
        camera.camera = SCNCamera(); camera.camera?.usesOrthographicProjection = true
        camera.camera?.zNear = 1; camera.camera?.zFar = 1600
        camera.camera?.wantsHDR = false; camera.camera?.wantsExposureAdaptation = false
        scene.rootNode.addChildNode(camera)
        let hubBead = SCNSphere(radius:2.2); hubBead.segmentCount = 10; hubBead.materials = [strandMaterial]
        let hubNode = SCNNode(geometry:hubBead); hubNode.name = "hub"; hubNode.renderingOrder = 1
        scene.rootNode.addChildNode(hubNode)
        setViewport(CGRect(origin:.zero,size:compactSize))
        _ = update(dt:0,spider:nil)
    }

    // MARK: expansion

    /// The web moved to another display: same compact web, new reach when opened.
    /// The nest corner (web-local). When the web opens, a silk dragline runs from there to the web.
    var tether: V3? { didSet { builtExpansion = -1 } }

    private func tetherEdges(_ e: Float) -> [(V3,V3)] {
        guard let tether, e > 0.02 else { return [] }
        let h = geometry.hub(e)
        guard simd_distance(tether,h) > 1 else { return [] }
        let toward = simd_normalize(tether-h)
        guard let i = geometry.strands.indices.max(by: { simd_dot(geometry.direction($0),toward) < simd_dot(geometry.direction($1),toward) }) else { return [] }
        let tip = h+geometry.direction(i)*geometry.length(i,e)
        // It shoots out of the corner and reaches the web as the web spreads; a little sag, like real silk.
        let end = mix(tether,tip,smooth(min(1,e*1.25)))
        let mid = (tether+end)*0.5-V3(0,simd_distance(tether,end)*0.035,0)
        return [(tether,mid),(mid,end)]
    }

    /// Where the web unfolds from (and folds back into): the spider's thread, or the nest corner.
    func launch(from point: V3) {
        guard simd_distance(point,geometry.compactHub) > 0.5 else { return }
        geometry = WebGeometry(compactHub:point,expandedBounds:geometry.expandedBounds)
        builtExpansion = -1
    }
    static let cornerHub = V3(275,235,0)

    func setExpandedBounds(_ bounds: CGRect) {
        geometry = WebGeometry(compactHub:geometry.compactHub,expandedBounds:bounds)
        builtExpansion = -1
    }

    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        // Opening: nearest strands tension first (a small inward kick), then everything spreads.
        expansionVelocity += open ? -0.35 : 0.25
        for item in items { item.nudge(open ? 0.5 : -0.35) }
    }

    /// True while any part of the web is outside its compact footprint.
    var isExpandedAtAll: Bool { isOpen || expansion > 0.002 || abs(expansionVelocity) > 0.01 }

    /// The panel the web currently renders into (web-local). The camera maps it 1:1 to screen points.
    func setViewport(_ rect: CGRect) {
        camera.simdPosition = V3(Float(rect.midX),Float(rect.midY),1000)
        camera.camera?.orthographicScale = Double(rect.height/2)
    }

    // MARK: per-frame

    /// Advances physics and rebuilds whatever moved. Returns false once everything is still.
    func update(dt: Float, spider: V3?) -> Bool {
        let dt = min(max(0,dt),1/30)
        time += dt
        var changed = dt == 0
        // Slightly underdamped: a short overshoot gives the web a single soft oscillation before it settles.
        let target: Float = isOpen ? 1 : 0
        expansionVelocity += (62*(target-expansion)-11.5*expansionVelocity)*dt
        expansion += expansionVelocity*dt
        if expansion < 0 { expansion = 0; expansionVelocity = max(0,expansionVelocity) }
        if abs(target-expansion) < 0.0005 && abs(expansionVelocity) < 0.002 { expansion = target; expansionVelocity = 0 }
        let e = expansion

        for item in items {
            let anchor = geometry.anchor(slot:item.slot,e)
            let distance = spider.map { simd_distance($0,anchor) } ?? 1000
            let impulse: Float = distance < 110 ? (1-distance/110)*0.16 : 0
            item.step(dt:dt,impulse:impulse,time:time)
            if !item.isSettled || impulse > 0 { changed = true }
        }
        let released = items.filter { $0.phase == .released && $0.phaseTime > 0.45 }
        for item in released { removeNodes(item.id) }
        items.removeAll { item in released.contains { $0 === item } }

        if abs(builtExpansion-e) > 0.0001 {
            let edges = geometry.edges(e)+tetherEdges(e)
            silkNode.geometry = Self.ribbons(edges,width:0.3,material:silkMaterial,shade:true)
            silkShadow.geometry = Self.ribbons(edges.map { ($0.0+V3(0.6,-0.9,-0.5),$0.1+V3(0.6,-0.9,-0.5)) },width:0.4,material:shadowMaterial,shade:false)
            scene.rootNode.childNode(withName:"hub",recursively:false)?.simdPosition = geometry.hub(e)+V3(0,0,0.5)
            builtExpansion = e; changed = true
        }
        if changed || quietFrames < 2 { layoutItems(e) }
        quietFrames = changed ? 0 : quietFrames+1
        debugRoot.isHidden = debugOptions.isEmpty
        return changed || quietFrames < 3
    }

    // MARK: items

    func itemVisualScale(_ item: WebItem) -> Float {
        let base = mix(0.76,1.3,clamp(expansion))
        let focus: Float = item.id == hoveredID || item.id == selectedID || item.id == focusID ? 1.12 : 1
        return base*focus*(1+item.pulse*0.16)
    }

    func hang(_ item: WebItem) -> Float { item.hangLength*mix(1,1.1,clamp(expansion)) }

    /// The bob (top attachment) of an item, web-local.
    func bob(_ item: WebItem) -> V3 {
        let rest = geometry.anchor(slot:item.slot,expansion)+item.offset(hang:hang(item))
        return item.phase == .attaching ? mix(item.attachStart,rest,item.attachProgress) : rest
    }

    func objectCenter(_ item: WebItem) -> V3 {
        let h = Float(images[item.id]?.size.height ?? 40)*itemVisualScale(item)
        return bob(item)-V3(0,h*0.5,0)
    }

    func objectSize(_ item: WebItem) -> CGSize {
        let size = images[item.id]?.size ?? CGSize(width:60,height:40)
        let s = CGFloat(itemVisualScale(item))
        return CGSize(width:size.width*s,height:size.height*s)
    }

    var freeSlot: Int? {
        let used = Set(items.filter { $0.phase != .released }.map(\.slot))
        return (0..<geometry.slots.count).first { !used.contains($0) }
    }

    /// Where the spider should stand to hang an item at `slot` (web-local).
    func approachPoint(slot: Int) -> V3 {
        let anchor = geometry.anchor(slot:slot,expansion)
        let hub = geometry.hub(expansion)
        // Stand on the radial, a little inside the anchor, so the item drops from the mouth to its strand.
        return mix(anchor,hub,0.25)-V3(0,18,0)
    }

    @discardableResult func attach(_ clip: ClipboardItem, slot: Int, from start: V3) -> WebItem {
        let item = WebItem(id:clip.id,slot:slot)
        item.attachStart = start; item.pinned = clip.pinned; item.pulse = 0.6
        images[item.id] = clip.preview; captions[item.id] = clip.caption
        items.append(item)
        let node = makeItemNode(clip.preview)
        objects.addChildNode(node); itemNodes[item.id] = node
        disturb(around:geometry.anchor(slot:slot,expansion),strength:0.42,except:item.id)
        return item
    }

    func item(_ id: Int) -> WebItem? { items.first { $0.id == id } }

    func hitTest(_ p: V3) -> WebItem? {
        items.reversed().first { item in
            guard item.phase == .hanging || item.phase == .attaching else { return false }
            // Generous targets (small objects swing on silk); the hovered one keeps a wider margin so it
            // never slips out from under the pointer between mouse-down and mouse-up.
            let c = objectCenter(item), size = objectSize(item)
            let pad: Float = item.id == hoveredID ? 22 : 12
            return abs(p.x-c.x) < Float(size.width/2)+pad && abs(p.y-c.y) < Float(size.height/2)+pad
        }
    }

    func setHover(_ id: Int?) {
        guard hoveredID != id else { return }
        hoveredID = id; quietFrames = 0
        if let id { item(id)?.nudge(0.02) }
    }

    func acknowledge(_ id: Int) {
        guard let item = item(id) else { return }
        item.pulse = 1; item.nudge(0.3)
        disturb(around:geometry.anchor(slot:item.slot,expansion),strength:0.12,except:id)
    }

    func setPinned(_ id: Int, _ pinned: Bool) {
        guard let item = item(id) else { return }
        item.pinned = pinned; item.pulse = 0.5; item.nudge(pinned ? -0.25 : 0.25)
    }

    /// Remove: the strand snaps, the object drops away and fades.
    func release(_ id: Int) {
        guard let item = item(id), item.phase != .released else { return }
        item.phase = .released; item.phaseTime = 0
        item.releaseVelocity = V3(item.swayVelocity*20,40,0); item.releaseOffset = .zero
        if hoveredID == id { hoveredID = nil }
        if selectedID == id { selectedID = nil }
        disturb(around:geometry.anchor(slot:item.slot,expansion),strength:0.35,except:id)
    }

    // MARK: drag-out

    func beginPull(_ id: Int) {
        guard let item = item(id) else { return }
        item.phase = .pulled; item.phaseTime = 0; item.pull = .zero
    }

    /// The object follows the pointer with resistance; returns the strand's stretch (0…1+).
    @discardableResult func setPull(_ id: Int, toward p: V3) -> Float {
        guard let item = item(id), item.phase == .pulled else { return 0 }
        let rest = geometry.anchor(slot:item.slot,expansion)+V3(item.sway,-hang(item),0)
        let h = Float(images[id]?.size.height ?? 40)*itemVisualScale(item)
        let wanted = p+V3(0,h*0.5,0)-rest
        let distance = simd_length(wanted)
        // Elastic: near the rest it follows closely, further away the silk holds back.
        let follow = distance < 1 ? wanted : wanted/distance*(distance*0.78/(1+distance/260))
        item.pull = follow
        return distance/Self.snapDistance
    }

    static let snapDistance: Float = 95

    /// The strand snaps. The object leaves the web and becomes the native drag image.
    func detach(_ id: Int) {
        guard let item = item(id) else { return }
        item.phase = .detached; item.phaseTime = 0
        disturb(around:geometry.anchor(slot:item.slot,expansion),strength:0.5,except:id)
    }

    /// A cancelled drag: the object is spun back onto its strand.
    func restore(_ id: Int, from p: V3) {
        guard let item = item(id) else { return }
        item.attachStart = p; item.phase = .attaching; item.phaseTime = 0; item.pull = .zero
    }

    /// The drag landed somewhere: forget the object entirely.
    func discard(_ id: Int) {
        removeNodes(id); items.removeAll { $0.id == id }
        if hoveredID == id { hoveredID = nil }
        if selectedID == id { selectedID = nil }
    }

    // MARK: rendering

    private func layoutItems(_ e: Float) {
        var strands: [(V3,V3)] = []
        for item in items {
            guard let node = itemNodes[item.id] else { continue }
            let anchor = geometry.anchor(slot:item.slot,e)
            let b = bob(item)
            node.isHidden = !item.visible
            node.simdPosition = b+V3(0,0,3)
            node.simdScale = V3(repeating:itemVisualScale(item))
            let stretch = item.phase == .pulled ? clamp(simd_length(item.pull)/80) : 0
            node.simdEulerAngles = V3(0,item.restYaw*(1-stretch),item.restTwist+item.twist+sin(time*0.8+Float(item.id))*0.003+item.pull.x*0.002)
            let faded: CGFloat = dimmedIDs.contains(item.id) ? 0.16 : 1
            node.opacity = (item.phase == .released ? CGFloat(1-smooth(item.phaseTime/0.42)) : 1)*faded
            layoutFocus(item,node:node)
            switch item.phase {
            case .attaching:
                // The strand is paid out from the anchor as the object drops into place.
                strands.append((anchor,mix(anchor,b,smooth(item.phaseTime/0.25))))
            case .hanging, .pulled:
                strands.append((anchor,b))
                if item.pinned { strands.append((geometry.reinforcement(slot:item.slot,e),b)) }
            case .released, .detached:
                // Snapped strand recoils toward its anchor.
                let recoil = 1-smooth(item.phaseTime/0.2)
                if recoil > 0 { strands.append((anchor,mix(anchor,anchor+V3(0,-hang(item),0),recoil))) }
            }
            if let label = labelNodes[item.id] {
                let show = item.id == hoveredID && selectedID == nil && item.phase == .hanging && expansion > 0.5
                label.isHidden = !show
                let h = Float(images[item.id]?.size.height ?? 40)*itemVisualScale(item)
                label.simdPosition = b-V3(0,h+11,0)+V3(0,0,4)
            } else if (item.id == hoveredID || item.id == selectedID) && expansion > 0.5, let caption = captions[item.id] {
                let image = ItemPreview.label(caption)
                let plane = SCNPlane(width:image.size.width,height:image.size.height)
                plane.materials = [Self.imageMaterial(image)]
                let label = SCNNode(geometry:plane); label.renderingOrder = 8
                objects.addChildNode(label); labelNodes[item.id] = label
            }
        }
        strandNode.geometry = Self.ribbons(strands,width:0.32,material:strandMaterial,shade:true)
        strandShadow.geometry = Self.ribbons(strands.map { ($0.0+V3(0.6,-1,-0.5),$0.1+V3(0.6,-1,-0.5)) },width:0.42,material:shadowMaterial,shade:false)
    }

    private func disturb(around point: V3, strength: Float, except id: Int) {
        for item in items where item.id != id {
            let d = simd_distance(geometry.anchor(slot:item.slot,expansion),point)
            if d < 160 { item.nudge((1-d/160)*strength*(geometry.anchor(slot:item.slot,expansion).x < point.x ? -1 : 1)) }
        }
    }

    /// The focus outline and the quick-paste number travel with the object (children of its node).
    private func layoutFocus(_ item: WebItem, node: SCNNode) {
        let size = images[item.id]?.size ?? CGSize(width:60,height:40)
        let focused = item.id == focusID && item.phase == .hanging && expansion > 0.5
        if focused && ringNodes[item.id] == nil {
            let image = Self.focusRing(size)
            let plane = SCNPlane(width:image.size.width,height:image.size.height); plane.materials = [Self.imageMaterial(image)]
            let ring = SCNNode(geometry:plane); ring.renderingOrder = 5
            ring.simdPosition = V3(0,-Float(size.height)/2+1.5,-0.5)
            node.addChildNode(ring); ringNodes[item.id] = ring
        }
        ringNodes[item.id]?.isHidden = !focused
        let number = expansion > 0.5 && item.phase == .hanging ? badgeNumbers[item.id] : nil
        if let number {
            if badgeNodes[item.id]?.number != number {
                badgeNodes[item.id]?.node.removeFromParentNode()
                let image = Self.numberBadge(number)
                let plane = SCNPlane(width:image.size.width,height:image.size.height); plane.materials = [Self.imageMaterial(image)]
                let badge = SCNNode(geometry:plane); badge.renderingOrder = 9
                badge.simdPosition = V3(-Float(size.width)/2-9,5,1)
                node.addChildNode(badge); badgeNodes[item.id] = (number,badge)
            }
            badgeNodes[item.id]?.node.isHidden = false
        } else { badgeNodes[item.id]?.node.isHidden = true }
    }

    private static func focusRing(_ size: CGSize) -> NSImage {
        let pad: CGFloat = 7
        return NSImage(size:NSSize(width:size.width+pad*2,height:size.height+pad*2),flipped:false) { r in
            let path = NSBezierPath(roundedRect:r.insetBy(dx:2,dy:2),xRadius:8,yRadius:8)
            NSColor(srgbRed:0.97,green:0.72,blue:0.25,alpha:0.22).setFill(); path.fill()
            NSColor(srgbRed:1,green:0.78,blue:0.32,alpha:0.95).setStroke(); path.lineWidth = 2.4; path.stroke()
            return true
        }
    }

    private static func numberBadge(_ n: Int) -> NSImage {
        NSImage(size:NSSize(width:18,height:18),flipped:false) { r in
            NSColor(srgbRed:0.08,green:0.085,blue:0.11,alpha:0.95).setFill(); NSBezierPath(ovalIn:r.insetBy(dx:0.5,dy:0.5)).fill()
            NSColor(srgbRed:1,green:0.78,blue:0.32,alpha:0.9).setStroke(); let o = NSBezierPath(ovalIn:r.insetBy(dx:1,dy:1)); o.lineWidth = 1.2; o.stroke()
            let s = NSAttributedString(string:"\(n)",attributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:10.5,weight:.bold),.foregroundColor:NSColor(white:1,alpha:0.95)])
            s.draw(at:NSPoint(x:r.midX-s.size().width/2,y:r.midY-s.size().height/2)); return true
        }
    }

    private func removeNodes(_ id: Int) {
        itemNodes[id]?.removeFromParentNode(); itemNodes[id] = nil
        labelNodes[id]?.removeFromParentNode(); labelNodes[id] = nil
        ringNodes[id] = nil; badgeNodes[id] = nil
        images[id] = nil; captions[id] = nil
    }

    private func makeItemNode(_ image: NSImage) -> SCNNode {
        let node = SCNNode()
        let plane = SCNPlane(width:image.size.width,height:image.size.height)
        plane.materials = [Self.imageMaterial(image)]
        let surface = SCNNode(geometry:plane)
        // Hung from its top edge, so it swings about the attachment point.
        surface.simdPosition = V3(0,-Float(image.size.height)/2+1.5,0)
        surface.renderingOrder = 6
        node.addChildNode(surface)
        let bead = SCNSphere(radius:1.5); bead.segmentCount = 8; bead.materials = [strandMaterial]
        let beadNode = SCNNode(geometry:bead); beadNode.renderingOrder = 7; node.addChildNode(beadNode)
        return node
    }

    private static func imageMaterial(_ image: NSImage) -> SCNMaterial {
        let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = image
        m.isDoubleSided = true; m.blendMode = .alpha; m.writesToDepthBuffer = false; m.readsFromDepthBuffer = false
        m.diffuse.mipFilter = .linear; m.diffuse.minificationFilter = .linear
        return m
    }

    private static func lineMaterial(alpha: CGFloat) -> SCNMaterial {
        let m = SCNMaterial(); m.lightingModel = .constant
        m.diffuse.contents = NSColor(srgbRed:0.86,green:0.87,blue:0.84,alpha:alpha)
        m.blendMode = .alpha; m.isDoubleSided = true; m.readsFromDepthBuffer = false; m.writesToDepthBuffer = false
        return m
    }

    private static func shadowMaterial() -> SCNMaterial {
        let m = SCNMaterial(); m.lightingModel = .constant
        m.diffuse.contents = NSColor(white:0,alpha:0.13)
        m.blendMode = .alpha; m.isDoubleSided = true; m.readsFromDepthBuffer = false; m.writesToDepthBuffer = false
        return m
    }

    /// Batched thin silk ribbons in a single draw call. Vertex shade imitates light catching strands
    /// at some angles more than others, so the web glints subtly instead of looking drawn.
    static func ribbons(_ edges: [(V3,V3)], width: Float, material: SCNMaterial, shade: Bool) -> SCNGeometry {
        var positions: [SCNVector3] = [], colors: [SCNVector3] = [], indices: [Int32] = []
        positions.reserveCapacity(edges.count*4); indices.reserveCapacity(edges.count*6)
        let light = simd_normalize(V3(-0.6,0.8,0))
        for (a,b) in edges {
            let delta = b-a, length = simd_length(delta)
            guard length > 0.001 else { continue }
            let dir = delta/length
            let normal = V3(-dir.y,dir.x,0)*width
            let base = Int32(positions.count)
            positions += [SCNVector3(a+normal),SCNVector3(a-normal),SCNVector3(b+normal),SCNVector3(b-normal)]
            let glint = shade ? 0.72+0.34*pow(abs(simd_dot(dir,light)),3) : 1
            let c = SCNVector3(CGFloat(glint),CGFloat(glint),CGFloat(glint))
            colors += [c,c,c,c]
            indices += [base,base+2,base+1,base+1,base+2,base+3]
        }
        guard !positions.isEmpty else { return SCNGeometry() }
        let g = SCNGeometry(sources:[SCNGeometrySource(vertices:positions),SCNGeometrySource(colors:colors)],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        g.materials = [material]; return g
    }
}

extension SCNGeometrySource {
    convenience init(colors: [SCNVector3]) {
        let data = colors.withUnsafeBufferPointer { Data(buffer:$0) }
        self.init(data:data,semantic:.color,vectorCount:colors.count,usesFloatComponents:true,componentsPerVector:3,bytesPerComponent:MemoryLayout<CGFloat>.size,dataOffset:0,dataStride:MemoryLayout<SCNVector3>.stride)
    }
}
