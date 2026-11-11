import SceneKit
import AppKit

struct SpiderDebugOptions: OptionSet {
    let rawValue: Int
    static let targets = Self(rawValue:1<<0)
    static let planted = Self(rawValue:1<<1)
    static let stepping = Self(rawValue:1<<2)
    static let ik = Self(rawValue:1<<3)
    static let forward = Self(rawValue:1<<4)
    static let awareness = Self(rawValue:1<<5)
}

/// Constructed only by Spider Study. The desktop renderer never owns these nodes.
final class SpiderDebugRenderer {
    let root = SCNNode()
    private var markers: [SCNNode] = []
    private var homes: [SCNNode] = []
    private let chains = SCNNode(), direction = SCNNode(), radius = SCNNode()
    private let green = SpiderDebugRenderer.material(NSColor(srgbRed:0.2,green:0.85,blue:0.5,alpha:1))
    private let orange = SpiderDebugRenderer.material(NSColor(srgbRed:1,green:0.56,blue:0.16,alpha:1))
    private let blue = SpiderDebugRenderer.material(NSColor(srgbRed:0.23,green:0.67,blue:1,alpha:1))
    init(scene: SCNScene) {
        scene.rootNode.addChildNode(root)
        for _ in 0..<8 {
            let m = SpiderGeometry.sphere(V3(repeating:1.6),material:green)
            let h = SpiderGeometry.sphere(V3(repeating:1.2),material:blue)
            m.renderingOrder = 100; h.renderingOrder = 100
            root.addChildNode(m); root.addChildNode(h); markers.append(m); homes.append(h)
        }
        for n in [chains,direction,radius] { n.renderingOrder = 100; root.addChildNode(n) }
        root.renderingOrder = 100
    }
    func update(_ motion: SpiderMotion, poses: [LegPose], options: SpiderDebugOptions) {
        root.isHidden = options.isEmpty
        for (i,foot) in motion.feet.enumerated() {
            let show = foot.supported ? options.contains(.planted) : options.contains(.stepping)
            markers[i].isHidden = !show
            markers[i].simdPosition = foot.position+V3(0,0,1)
            markers[i].geometry?.materials = [foot.supported ? green : orange]
            homes[i].isHidden = !options.contains(.targets)
            homes[i].simdPosition = motion.world(foot.home)+V3(0,0,1)
        }
        chains.isHidden = !options.contains(.ik)
        if !chains.isHidden {
            var edges: [(V3,V3)] = []
            for pose in poses { for j in 0..<pose.points.count-1 { edges.append((pose.points[j]+V3(0,0,1),pose.points[j+1]+V3(0,0,1))) } }
            chains.geometry = Self.lines(edges,material:blue)
        }
        direction.isHidden = !options.contains(.forward)
        if !direction.isHidden {
            let a = motion.position+V3(0,0,40), b = motion.world(V3(0,82,40))
            direction.geometry = Self.lines([(a,b),(b,motion.world(V3(-5,72,40))),(b,motion.world(V3(5,72,40)))],material:orange)
        }
        radius.isHidden = !options.contains(.awareness)
        if !radius.isHidden {
            let edges = (0..<64).map { i -> (V3,V3) in
                let a = Float(i)*2 * .pi/64, b = Float(i+1)*2 * .pi/64
                return (motion.position+V3(cos(a),sin(a),0.02)*V3(motion.awarenessRadius,motion.awarenessRadius,1),motion.position+V3(cos(b),sin(b),0.02)*V3(motion.awarenessRadius,motion.awarenessRadius,1))
            }
            radius.geometry = Self.lines(edges,material:blue)
        }
    }
    private static func material(_ color:NSColor) -> SCNMaterial {
        let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = color
        m.readsFromDepthBuffer = false; m.writesToDepthBuffer = false; return m
    }
    private static func lines(_ edges:[(V3,V3)],material:SCNMaterial) -> SCNGeometry {
        let positions = edges.flatMap { [SCNVector3($0.0),SCNVector3($0.1)] }
        let indices = (0..<positions.count).map(Int32.init)
        let g = SCNGeometry(sources:[SCNGeometrySource(vertices:positions)],elements:[SCNGeometryElement(indices:indices,primitiveType:.line)])
        g.materials = [material]; return g
    }
}
