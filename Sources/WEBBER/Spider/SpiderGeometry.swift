import AppKit
import SceneKit
import simd

/// Render-thread-only cache. Exact comparisons avoid invalidating SceneKit's transform tree for
/// stationary contacts and constant scales; no pose rounding or animation thresholds are introduced.
final class SpiderNodePose {
    let node: SCNNode
    private var position: V3?, scale: V3?, orientation: SIMD4<Float>?, opacity: CGFloat?
    private var segment: (V3,V3,Float)?
    private var connectedOrientation = simd_quatf()
    init(_ node: SCNNode) { self.node = node }
    func move(_ value: V3) {
        if position != value { node.simdPosition = value; position = value }
    }
    func resize(_ value: V3) {
        if scale != value { node.simdScale = value; scale = value }
    }
    func orient(_ value: simd_quatf) {
        if orientation != value.vector { node.simdOrientation = value; orientation = value.vector }
    }
    func fade(_ value: CGFloat) {
        if opacity != value { node.opacity = value; opacity = value }
    }
    @discardableResult func connect(_ a: V3, _ b: V3, radius: Float) -> simd_quatf {
        if let segment, segment.0 == a, segment.1 == b, segment.2 == radius { return connectedOrientation }
        segment = (a,b,radius)
        let delta = b-a, length = simd_length(delta)
        move((a+b)*0.5)
        orient(length>0.0001 ? simd_quatf(from:V3(0,1,0),to:delta/length) : simd_quatf())
        resize(V3(radius,max(0.0001,length),radius))
        // SceneKit normalizes the stored quaternion; joints use that same stored orientation.
        connectedOrientation = node.simdOrientation
        return connectedOrientation
    }
}

/// Shared, inexpensive meshes. Dimensions are baked into the shell instead of scaling two spheres.
enum SpiderGeometry {
    enum Shell { case abdomen, carapace }
    static func material(_ rgb: V3, roughness: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
        m.roughness.contents = roughness
        m.metalness.contents = 0
        m.emission.contents = NSColor.black
        m.specular.contents = NSColor(white: 0.18, alpha: 1)
        return m
    }
    static func surface(_ phi: Float, _ theta: Float, shell: Shell) -> V3 {
        let y = cos(phi), ring = sin(phi)
        switch shell {
        case .abdomen:
            // Narrow anterior attachment, fuller hind abdomen, flatter underside.
            let width = 14.0 * (1 - 0.28*y)
            let z = sin(theta)*ring*8.5*(1-0.15*y)
            return V3(cos(theta)*ring*width*(1+0.025*sin(phi*3)), y*19.0, z < 0 ? z*0.52 : z)
        case .carapace:
            let x = cos(theta)*ring*12.3*(1-0.20*y)
            let z = sin(theta)*ring*(5.2+max(0,y)*1.4)
            let dorsal = max(0, sin(theta))
            let fovea = exp(-(x*x/9 + pow((y*13.3+2)/2.8,2)))*0.65*dorsal
            let furrows = sin(atan2(x,y*13.7+5)*12)*0.12*dorsal*ring
            return V3(x,y*13.7,z < 0 ? z*0.52 : z-fovea+furrows)
        }
    }
    static func shell(_ type: Shell, material: SCNMaterial) -> SCNNode {
        let rows = 24, columns = 36
        var positions: [SCNVector3] = [], normals: [SCNVector3] = [], uv: [CGPoint] = []
        var indices: [Int32] = []
        for row in 0...rows {
            let phi = Float(row)/Float(rows) * .pi
            for column in 0...columns {
                let theta = Float(column)/Float(columns)*2 * .pi
                let p = surface(phi,theta,shell:type)
                let a = surface(clamp(phi+0.002,0,.pi),theta,shell:type)-surface(clamp(phi-0.002,0,.pi),theta,shell:type)
                let b = surface(phi,theta+0.002,shell:type)-surface(phi,theta-0.002,shell:type)
                let cross = simd_cross(b,a)
                let n = simd_length(cross)>0.00001 ? simd_normalize(cross) : V3(0,row==0 ? 1 : -1,0)
                positions.append(SCNVector3(p)); normals.append(SCNVector3(n))
                uv.append(CGPoint(x:CGFloat(column)/CGFloat(columns),y:CGFloat(row)/CGFloat(rows)))
            }
        }
        for r in 0..<rows { for c in 0..<columns {
            let a = Int32(r*(columns+1)+c), b = a+1, d = a+Int32(columns+1), e = d+1
            indices += [a,b,d,b,e,d]
        } }
        let mesh = SCNGeometry(sources:[SCNGeometrySource(vertices:positions),SCNGeometrySource(normals:normals),SCNGeometrySource(textureCoordinates:uv)],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        mesh.materials = [material]
        return SCNNode(geometry:mesh)
    }
    static func limb(profile: [Float], bend: Float = 0.06, material: SCNMaterial) -> SCNGeometry {
        let columns = 12
        var p: [SCNVector3] = [], n: [SCNVector3] = []
        var indices: [Int32] = []
        for (row,radius) in profile.enumerated() {
            let t = Float(row)/Float(profile.count-1)
            for col in 0..<columns {
                let a = Float(col)/Float(columns)*2 * .pi
                p.append(SCNVector3(cos(a)*radius+bend*sin(t * .pi),t-0.5,sin(a)*radius*0.88))
                n.append(SCNVector3(cos(a),0,sin(a)))
            }
        }
        for r in 0..<(profile.count-1) { for c in 0..<columns {
            let a = Int32(r*columns+c), b = Int32(r*columns+(c+1)%columns), d = a+Int32(columns), e = b+Int32(columns)
            indices += [a,d,b,b,d,e]
        } }
        let geometry = SCNGeometry(sources:[SCNGeometrySource(vertices:p),SCNGeometrySource(normals:n)],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        geometry.materials = [material]; return geometry
    }
    static func connect(_ node: SCNNode, _ a: V3, _ b: V3, radius: Float) {
        let delta = b-a, length = simd_length(delta)
        node.simdPosition = (a+b)*0.5
        node.simdOrientation = length>0.0001 ? simd_quatf(from:V3(0,1,0),to:delta/length) : simd_quatf()
        node.simdScale = V3(radius,max(0.0001,length),radius)
    }
    static func sphere(_ scale: V3, material: SCNMaterial) -> SCNNode {
        let g = SCNSphere(radius:1); g.segmentCount = 14; g.materials = [material]
        let n = SCNNode(geometry:g); n.simdScale = scale; return n
    }
    /// Batched tapered hairs: one draw call for an entire field, rather than one node per hair.
    static func hairs(_ fibers: [(V3,V3)], material: SCNMaterial) -> SCNGeometry {
        var p: [SCNVector3] = [], n: [SCNVector3] = [], indices: [Int32] = []
        for (a,b) in fibers {
            let axis = simd_normalize(b-a)
            let cross = simd_cross(axis,V3(0,1,0))
            let u = simd_length(cross)>0.001 ? simd_normalize(cross) : V3(1,0,0)
            let v = simd_cross(axis,u), base = Int32(p.count)
            for i in 0..<3 {
                let angle = Float(i)*2 * .pi/3
                let normal = u*cos(angle)+v*sin(angle)
                p.append(SCNVector3(a+normal*0.07)); n.append(SCNVector3(normal))
            }
            p.append(SCNVector3(b)); n.append(SCNVector3(axis))
            indices += [base,base+1,base+3,base+1,base+2,base+3,base+2,base,base+3]
        }
        let g = SCNGeometry(sources:[SCNGeometrySource(vertices:p),SCNGeometrySource(normals:n)],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        g.materials = [material]; return g
    }
    static func shellHairs(_ shell: Shell, count: Int, material: SCNMaterial, length: Float = 1) -> SCNNode {
        var fibers: [(V3,V3)] = []
        for i in 0..<count {
            let theta = Float(i)*2.39996
            let phi = acos(1-2*Float(i+1)/Float(count+1))
            let a = surface(phi,theta,shell:shell)
            // Most ventral hairs would never contribute to the desktop silhouette.
            guard a.z > -1 else { continue }
            let normal = simd_normalize(V3(a.x/160,a.y/290,a.z/80))
            fibers.append((a,a+normal*(0.65+Float(i%5)*0.17)*length))
        }
        return SCNNode(geometry:hairs(fibers,material:material))
    }
    static func texture(normal: Bool) -> NSImage {
        let size = 128
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:size*4,bitsPerPixel:32)!
        var seed: UInt32 = 84910
        for i in 0..<(size*size) {
            seed = seed &* 1664525 &+ 1013904223
            let grain = Int((seed>>24)%17)-8, p = bitmap.bitmapData!+i*4
            if normal { p[0] = UInt8(128+grain); p[1] = UInt8(128-grain/2); p[2] = 255 }
            else { let roughness = UInt8(146+grain); p[0] = roughness; p[1] = roughness; p[2] = roughness }
            p[3] = 255
        }
        let image = NSImage(size:NSSize(width:size,height:size)); image.addRepresentation(bitmap); return image
    }
    static func shadowTexture() -> NSImage {
        let size = 96
        let b = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:size*4,bitsPerPixel:32)!
        for y in 0..<size { for x in 0..<size {
            let dx = Float(x-size/2)/Float(size/2), dy = Float(y-size/2)/Float(size/2)
            let alpha = max(0,exp(-(dx*dx+dy*dy)*7)-exp(-7))*0.25
            let p = b.bitmapData!+(y*size+x)*4
            p[0] = 0; p[1] = 0; p[2] = 0; p[3] = UInt8(alpha*255)
        } }
        let image = NSImage(size:NSSize(width:size,height:size)); image.addRepresentation(b); return image
    }
    static func curve(_ points: [V3], radius: Float, material: SCNMaterial) -> SCNGeometry {
        let sides = 5
        var p: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [Int32] = []
        for (i,point) in points.enumerated() {
            let delta = points[min(i+1,points.count-1)]-points[max(i-1,0)]
            let axis = simd_length(delta)>0.0001 ? simd_normalize(delta) : V3(0,1,0)
            let cross = simd_cross(axis,V3(0,0,1))
            let u = simd_length(cross)>0.001 ? simd_normalize(cross) : V3(1,0,0)
            let v = simd_cross(axis,u)
            for j in 0..<sides {
                let a = Float(j)*2 * .pi/Float(sides), n = u*cos(a)+v*sin(a)
                p.append(SCNVector3(point+n*radius)); normals.append(SCNVector3(n))
            }
        }
        for i in 0..<(points.count-1) { for j in 0..<sides {
            let a = Int32(i*sides+j), b = Int32(i*sides+(j+1)%sides), c = a+Int32(sides), d = b+Int32(sides)
            indices += [a,c,b,b,c,d]
        } }
        let g = SCNGeometry(sources:[SCNGeometrySource(vertices:p),SCNGeometrySource(normals:normals)],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        g.materials = [material]; return g
    }
}
