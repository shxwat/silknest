import AppKit
import SceneKit
import simd

/// A fixed, pixel-aligned render tile inside the fixed desktop panel. Camera coordinates remain
/// in the original motion space, so cropping never changes the spider's size or planted contacts.
enum SpiderRenderViewport {
    /// A 3/4 view without moving anything on the ground: points at height z are drawn k·z higher on screen
    /// (an oblique projection), so the spider's face and sides show while its planted feet, hit areas and
    /// motion stay exactly in desktop coordinates. tan(25°).
    static var tilt: Float = 0.466
    static func compact(around point: CGPoint, in display: CGRect, scale: CGFloat, backingScale: CGFloat) -> CGRect {
        let side = max(640,512*scale)
        let alignedSide = (side*backingScale).rounded(.up)/backingScale
        let size = CGSize(width:min(alignedSide,display.width),height:min(alignedSide,display.height))
        let x = min(max(point.x-size.width/2,display.minX),display.maxX-size.width)
        let y = min(max(point.y-size.height/2,display.minY),display.maxY-size.height)
        return CGRect(x:(x*backingScale).rounded(.down)/backingScale,
                      y:(y*backingScale).rounded(.down)/backingScale,width:size.width,height:size.height)
    }

    static func required(around point: CGPoint, in display: CGRect, scale: CGFloat) -> CGRect {
        let padding = max(160,128*scale)
        return CGRect(x:point.x-padding,y:point.y-padding,width:padding*2,height:padding*2).intersection(display)
    }

    static func camera(for rect: CGRect, in display: CGRect, scale: CGFloat) -> (position: V3, extent: Double, projection: SCNMatrix4) {
        // Keep the original camera/view matrix: moving an orthographic camera still changes
        // physically based specular lighting. Crop only its projection instead.
        let extent = Double(display.height/2/scale)
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true; camera.orthographicScale = Double(rect.height/2/scale)
        camera.zNear = 1; camera.zFar = 1600
        var projection = simd_float4x4(camera.projectionTransform(withViewportSize:rect.size))
        projection.columns.3.x = Float((display.width-2*(rect.minX-display.minX)-rect.width)/rect.width)
        projection.columns.3.y = Float((display.height-2*(rect.minY-display.minY)-rect.height)/rect.height)
        // View space: the ground plane (world z = 0) is at z = -1000 in front of the camera.
        let k = tilt
        let shear = simd_float4x4(columns:(SIMD4(1,0,0,0),SIMD4(0,1,0,0),SIMD4(0,k,1,0),SIMD4(0,1000*k,0,1)))
        projection = projection*shear
        return (V3(Float(display.midX/scale),Float(display.midY/scale),1000),extent,SCNMatrix4(projection))
    }
}
