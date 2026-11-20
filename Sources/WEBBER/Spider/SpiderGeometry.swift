import AppKit
import Metal
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
    /// A leg segment as one mesh and one draw call: the tapered tube plus its own setae and spines.
    /// Texture v runs 0 (body side) → 1 (tip side); the limb shader darkens the articulation band near v = 1
    /// and the joint membrane near v = 0, so segments read as real jointed cuticle (no separate joint knobs).
    /// Built in the segment's scaled local space: x/z are divided by `radius`, y by `length` (nominal values),
    /// so hairs keep about their real size on every leg.
    static func limbDetailed(profile: [Float], bend: Float, radius: Float, length: Float, setae: Int, spines: Int, seed: Int, material: SCNMaterial) -> SCNGeometry {
        let columns = 12
        var p: [SCNVector3] = [], n: [SCNVector3] = [], uv: [CGPoint] = [], indices: [Int32] = []
        func surface(_ t: Float, _ a: Float) -> (V3,V3) {
            let rows = Float(profile.count-1), x = t*rows, i = min(Int(x),profile.count-2), f = x-Float(i)
            let r = profile[i]*(1-f)+profile[i+1]*f
            let c = V3(bend*sin(t * .pi),t-0.5,0)
            return (c+V3(cos(a)*r,0,sin(a)*r*0.88),V3(cos(a),0,sin(a)))
        }
        // More rings than the profile: the joint band needs a few rows to stay smooth.
        let rings = max(profile.count,8)
        for row in 0..<rings {
            let t = Float(row)/Float(rings-1)
            for col in 0...columns {
                let a = Float(col)/Float(columns)*2 * .pi
                let (pos,nor) = surface(t,a)
                p.append(SCNVector3(pos)); n.append(SCNVector3(nor)); uv.append(CGPoint(x:CGFloat(col)/CGFloat(columns),y:CGFloat(t)))
            }
        }
        for r in 0..<(rings-1) { for c in 0..<columns {
            let a = Int32(r*(columns+1)+c), b = a+1, d = a+Int32(columns+1), e = b+Int32(columns+1)
            indices += [a,d,b,b,d,e]
        } }
        // Rounded ends that close the tube and overlap the next segment a little: the joint is a smooth,
        // dark articulation instead of a gap or a knob. Heights are in world units (≈ 0.8 × the end radius).
        for distal in [false,true] {
            let r0 = distal ? profile.last! : profile.first!
            let height = r0*radius*0.8/length, v: CGFloat = distal ? 1 : 0
            let ringRows = 4, rowStart = Int32(p.count)
            for k in 0...ringRows {
                let phi = Float(k)/Float(ringRows) * .pi/2
                let rr = r0*cos(phi), y = (distal ? 0.5 : -0.5)+(distal ? 1 : -1)*sin(phi)*height
                let cx = bend*sin((distal ? 1 : 0) * .pi)
                for col in 0...columns {
                    let a = Float(col)/Float(columns)*2 * .pi
                    p.append(SCNVector3(V3(cx+cos(a)*rr,y,sin(a)*rr*0.88)))
                    n.append(SCNVector3(simd_normalize(V3(cos(a)*cos(phi),(distal ? 1 : -1)*sin(phi),sin(a)*cos(phi)))))
                    uv.append(CGPoint(x:CGFloat(col)/CGFloat(columns),y:v))
                }
            }
            for k in 0..<ringRows { for c in 0..<columns {
                let a = rowStart+Int32(k*(columns+1)+c), b = a+1, d = a+Int32(columns+1), e = b+Int32(columns+1)
                indices += distal ? [a,d,b,b,d,e] : [a,b,d,b,e,d]
            } }
        }
        var rng = UInt32(truncatingIfNeeded:seed &* 2654435761 &+ 12345)
        func rand() -> Float { rng = rng &* 1664525 &+ 1013904223; return Float(rng>>8)/Float(1<<24) }
        func hair(t: Float, angle: Float, reach: Float, width: Float, lean: Float, v: CGFloat) {
            let (base,out) = surface(t,angle)
            // Out from the cuticle and leaning toward the tip, as real setae do.
            let world = simd_normalize(out*1+V3(0,lean,0))
            let tip = base+V3(world.x*reach/radius,world.y*reach/length,world.z*reach/radius)
            let axis = simd_normalize(tip-base)
            let side = simd_normalize(simd_cross(axis,V3(0,1,0)+V3(0.001,0,0)))
            let up = simd_cross(axis,side), start = Int32(p.count)
            for i in 0..<3 {
                let k = Float(i)*2 * .pi/3, dir = side*cos(k)+up*sin(k)
                p.append(SCNVector3(base+V3(dir.x*width/radius,dir.y*width/length,dir.z*width/radius))); n.append(SCNVector3(dir))
                uv.append(CGPoint(x:0.5,y:v))
            }
            p.append(SCNVector3(tip)); n.append(SCNVector3(axis)); uv.append(CGPoint(x:0.5,y:v))
            indices += [start,start+1,start+3,start+1,start+2,start+3,start+2,start,start+3]
        }
        for k in 0..<setae {
            let t = 0.08+0.84*(Float(k)+rand()*0.6)/Float(max(1,setae))
            hair(t:t,angle:rand()*2 * .pi,reach:0.8+rand()*0.9,width:0.05,lean:1.6+rand(),v:0.89)
        }
        for k in 0..<spines {
            let t = 0.15+0.7*(Float(k)+0.5)/Float(max(1,spines))
            // Spines stand up from the top and sides, never from underneath.
            hair(t:t,angle:(0.15+0.7*rand()) * .pi,reach:1.6+rand()*1.1,width:0.07,lean:0.9,v:0.975)
        }
        let geometry = SCNGeometry(sources:[SCNGeometrySource(vertices:p),SCNGeometrySource(normals:n),SCNGeometrySource(textureCoordinates:uv)],
                                   elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        geometry.materials = [material]; return geometry
    }

    /// All 48 leg segments as ONE mesh: one draw call per material instead of 48 nodes. Each frame the segments'
    /// local vertices are placed on the CPU (≈20k vertices, a fraction of a millisecond) straight into a Metal
    /// buffer the GPU reads; no per-segment SceneKit nodes, transactions or skinning deformer.
    final class LegMesh {
        let node: SCNNode
        private let buffer: MTLBuffer
        private let local: [SIMD4<Float>], localNormal: [SIMD4<Float>], bone: [UInt16]
        /// First vertex of each bone, so vertices are transformed bone by bone.
        private let ranges: [Range<Int>]
        init?(templates: [SCNGeometry], legs: Int, materials: [SCNMaterial], materialOf: (Int) -> Int) {
            guard let device = MTLCreateSystemDefaultDevice() else { return nil }
            var p: [SIMD4<Float>] = [], n: [SIMD4<Float>] = [], uv: [CGPoint] = [], b: [UInt16] = [], ranges: [Range<Int>] = []
            var elements = [[Int32]](repeating:[],count:materials.count)
            func floats(_ s: SCNGeometrySource) -> [Float] {
                var out = [Float](repeating:0,count:s.vectorCount*s.componentsPerVector)
                s.data.withUnsafeBytes { raw in
                    for i in 0..<s.vectorCount { for c in 0..<s.componentsPerVector {
                        out[i*s.componentsPerVector+c] = raw.load(fromByteOffset:s.dataOffset+i*s.dataStride+c*s.bytesPerComponent,as:Float.self)
                    } }
                }
                return out
            }
            let data = templates.map { g in (floats(g.sources(for:.vertex)[0]),floats(g.sources(for:.normal)[0]),floats(g.sources(for:.texcoord)[0]),g.elements) }
            for leg in 0..<legs { for (j,(pv,nv,tv,els)) in data.enumerated() {
                let base = p.count, count = pv.count/3
                for i in 0..<count {
                    p.append(SIMD4(pv[i*3],pv[i*3+1],pv[i*3+2],1)); n.append(SIMD4(nv[i*3],nv[i*3+1],nv[i*3+2],0))
                    uv.append(CGPoint(x:CGFloat(tv[i*2]),y:CGFloat(tv[i*2+1]))); b.append(UInt16(leg*templates.count+j))
                }
                ranges.append(base..<(base+count))
                for e in els {
                    e.data.withUnsafeBytes { raw in
                        for i in 0..<(e.primitiveCount*3) {
                            let idx = e.bytesPerIndex == 4 ? Int(raw.load(fromByteOffset:i*4,as:Int32.self)) : Int(raw.load(fromByteOffset:i*2,as:Int16.self))
                            elements[materialOf(j)].append(Int32(base+idx))
                        }
                    }
                }
            } }
            local = p; localNormal = n; bone = b; self.ranges = ranges
            // Interleaved position (float3) + normal (float3), shared CPU/GPU memory.
            guard let buffer = device.makeBuffer(length:p.count*24,options:.storageModeShared) else { return nil }
            self.buffer = buffer
            let used = elements.indices.filter { !elements[$0].isEmpty }
            let geometry = SCNGeometry(sources:[SCNGeometrySource(buffer:buffer,vertexFormat:.float3,semantic:.vertex,vertexCount:p.count,dataOffset:0,dataStride:24),
                                                SCNGeometrySource(buffer:buffer,vertexFormat:.float3,semantic:.normal,vertexCount:p.count,dataOffset:12,dataStride:24),
                                                SCNGeometrySource(textureCoordinates:uv)],
                                       elements:used.map { SCNGeometryElement(indices:elements[$0],primitiveType:.triangles) })
            geometry.materials = used.map { materials[$0] }
            node = SCNNode(geometry:geometry)
            // Bounds are fixed (the buffer changes every frame): large enough for anywhere the legs can go.
            node.boundingBox = (SCNVector3(-4000,-4000,-200),SCNVector3(12000,12000,600))
        }
        /// One transform per segment: the segment's local unit tube scaled to `radius`/`length` between a and b.
        func update(_ segments: [(V3,V3,Float)]) {
            let out = buffer.contents().bindMemory(to:Float.self,capacity:local.count*6)
            for (k,seg) in segments.enumerated() where k < ranges.count {
                let (a,b,r) = seg
                let delta = b-a, length = max(0.0001,simd_length(delta))
                let q = length > 0.0001 ? simd_quatf(from:V3(0,1,0),to:delta/length) : simd_quatf()
                let rot = simd_float3x3(q), mid = (a+b)*0.5
                let m = simd_float3x3(rot.columns.0*r,rot.columns.1*length,rot.columns.2*r)
                // Normals: rotation × inverse scale, renormalised.
                let nm = simd_float3x3(rot.columns.0/r,rot.columns.1/length,rot.columns.2/r)
                for i in ranges[k] {
                    let lp = local[i], ln = localNormal[i]
                    let wp = m*V3(lp.x,lp.y,lp.z)+mid
                    let wn = simd_normalize(nm*V3(ln.x,ln.y,ln.z))
                    let o = i*6
                    out[o] = wp.x; out[o+1] = wp.y; out[o+2] = wp.z; out[o+3] = wn.x; out[o+4] = wn.y; out[o+5] = wn.z
                }
            }
        }
    }

    /// Fine longitudinal cuticle streaks for the legs (u around, v along); colour comes from `tint`.
    static func legTexture(tint: V3) -> NSImage {
        let w = 64, h = 8
        let b = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w,pixelsHigh:h,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:w*4,bitsPerPixel:32)!
        var seed: UInt32 = 991
        var streak = [Float](repeating:1,count:w)
        for x in 0..<w { seed = seed &* 1664525 &+ 1013904223; streak[x] = 0.82+0.18*Float(seed>>24)/255 }
        for x in [7,23,38,51] { streak[x] *= 0.6 }
        for y in 0..<h { for x in 0..<w {
            let q = b.bitmapData!+(y*w+x)*4, k = streak[x]
            q[0] = UInt8(min(255,tint.x*255*k)); q[1] = UInt8(min(255,tint.y*255*k)); q[2] = UInt8(min(255,tint.z*255*k)); q[3] = 255
        } }
        let image = NSImage(size:NSSize(width:w,height:h)); image.addRepresentation(b); return image
    }

    /// Procedural cuticle detail as a tangent-space normal map plus a matching roughness map.
    /// `velvet` (abdomen): fine short hairs lying along the body; otherwise (carapace) shallow pits and grain.
    static func cuticle(velvet: Bool, size: Int = 128) -> (normal: NSImage, roughness: NSImage) {
        var hgt = [Float](repeating:0,count:size*size)
        var seed: UInt32 = velvet ? 4242 : 7171
        func rnd() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(seed>>8)/Float(1<<24) }
        if velvet {
            // Thousands of tiny hairs: short strokes along v (front → back), each a soft ridge.
            for _ in 0..<1400 {
                let x0 = rnd()*Float(size), y0 = rnd()*Float(size), len = 3+rnd()*5, amp = 0.4+rnd()*0.6
                for s in 0..<Int(len*2) {
                    let y = Int(y0+Float(s)*0.5) & (size-1), x = Int(x0+Float(s)*0.08) & (size-1)
                    hgt[y*size+x] += amp*(1-Float(s)/(len*2))
                }
            }
        } else {
            for _ in 0..<240 {
                let cx = rnd()*Float(size), cy = rnd()*Float(size), r = 1.2+rnd()*2.4
                for dy in -4...4 { for dx in -4...4 {
                    let d2 = Float(dx*dx+dy*dy)/(r*r)
                    guard d2 < 1 else { continue }
                    let x = (Int(cx)+dx) & (size-1), y = (Int(cy)+dy) & (size-1)
                    hgt[y*size+x] -= (1-d2)*0.9
                }}
            }
            for i in 0..<hgt.count { hgt[i] += (rnd()-0.5)*0.25 }
        }
        let nb = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:size*4,bitsPerPixel:32)!
        let rb = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:size*4,bitsPerPixel:32)!
        let strength: Float = velvet ? 1.4 : 2.2
        for y in 0..<size { for x in 0..<size {
            let h0 = hgt[y*size+x]
            let dx = hgt[y*size+((x+1)&(size-1))]-hgt[y*size+((x+size-1)&(size-1))]
            let dy = hgt[((y+1)&(size-1))*size+x]-hgt[((y+size-1)&(size-1))*size+x]
            let nrm = simd_normalize(V3(-dx*strength,-dy*strength,1))
            let q = nb.bitmapData!+(y*size+x)*4
            q[0] = UInt8(127.5+nrm.x*127); q[1] = UInt8(127.5+nrm.y*127); q[2] = UInt8(127.5+nrm.z*127); q[3] = 255
            // Pits and hair bases are a little rougher than the polished plates between them.
            let rough = UInt8(max(0,min(255,(velvet ? 0.42 : 0.30)*255+abs(h0)*(velvet ? 40 : 70))))
            let r = rb.bitmapData!+(y*size+x)*4
            r[0] = rough; r[1] = rough; r[2] = rough; r[3] = 255
        }}
        let ni = NSImage(size:NSSize(width:size,height:size)); ni.addRepresentation(nb)
        let ri = NSImage(size:NSSize(width:size,height:size)); ri.addRepresentation(rb)
        return (ni,ri)
    }

    /// A soft studio around the spider for real reflections on its glossy cuticle: bright overcast sky,
    /// a large window-like key up and to the left, warm desk bounce below. Cube faces +X −X +Y −Y +Z −Z (z up).
    static func studioEnvironment(size: Int = 16) -> [NSImage] {
        let key = simd_normalize(V3(-0.55,0.35,0.76))
        func color(_ d: V3) -> V3 {
            let up = d.z
            let sky = V3(0.86,0.90,0.97), horizon = V3(0.62,0.60,0.57), desk = V3(0.20,0.17,0.14)
            var c = up > 0 ? mix(horizon,sky,min(1,up*1.6)) : mix(horizon,desk,min(1,-up*2.2))
            let k = max(0,simd_dot(d,key))
            c += V3(1,0.97,0.92)*pow(k,40)*1.4
            return c
        }
        let faces: [(V3,V3,V3)] = [(V3(1,0,0),V3(0,0,-1),V3(0,-1,0)),(V3(-1,0,0),V3(0,0,1),V3(0,-1,0)),
                                   (V3(0,1,0),V3(1,0,0),V3(0,0,1)),(V3(0,-1,0),V3(1,0,0),V3(0,0,-1)),
                                   (V3(0,0,1),V3(1,0,0),V3(0,-1,0)),(V3(0,0,-1),V3(-1,0,0),V3(0,-1,0))]
        return faces.map { (f,u,v) in
            let b = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:size*4,bitsPerPixel:32)!
            for y in 0..<size { for x in 0..<size {
                let a = (Float(x)+0.5)/Float(size)*2-1, c = (Float(y)+0.5)/Float(size)*2-1
                let col = color(simd_normalize(f+u*a+v*c))
                let q = b.bitmapData!+(y*size+x)*4
                q[0] = UInt8(min(255,col.x*255)); q[1] = UInt8(min(255,col.y*255)); q[2] = UInt8(min(255,col.z*255)); q[3] = 255
            }}
            let image = NSImage(size:NSSize(width:size,height:size)); image.addRepresentation(b); return image
        }
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
            // A wide soft penumbra plus a tighter, darker core right under the body (ambient occlusion).
            let r2 = dx*dx+dy*dy
            let alpha = max(0,exp(-r2*5)-exp(-5))*0.17+max(0,exp(-r2*22)-exp(-22))*0.20
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
