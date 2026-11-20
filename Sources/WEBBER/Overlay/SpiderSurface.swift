import AppKit
import Metal
import QuartzCore
import SceneKit

/// The spider's render surface: a transparent CAMetalLayer that SceneKit draws into only when the overlay's
/// own frame loop has a new pose. Unlike an SCNView it owns no display link of its own, so a resting spider
/// costs no wakeups and no GPU work at all, and the multisample and depth buffers are memoryless (tile memory
/// on Apple silicon): only the resolved image takes real memory.
final class SpiderSurface: NSView {
    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    let renderer: SCNRenderer
    /// 1, 2, 4 or 8 samples (from the display's antialiasing choice).
    var sampleCount = 4 { didSet { if sampleCount != oldValue { attachments = nil } } }
    private var attachments: (color: MTLTexture?, depth: MTLTexture?, size: CGSize, samples: Int)?
    /// Development stats.
    private(set) var framesDrawn = 0, drawMs = 0.0

    override init(frame: NSRect) {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        renderer = SCNRenderer(device:device,options:nil)
        super.init(frame:frame)
        wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.colorspace = CGColorSpace(name:CGColorSpace.sRGB)
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 2
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.needsDisplayOnBoundsChange = false
        layer = metalLayer
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError("Create the rendering surface programmatically") }
    override var isOpaque: Bool { false }
    override func makeBackingLayer() -> CALayer { metalLayer }

    var scene: SCNScene? { get { renderer.scene } set { renderer.scene = newValue } }
    var pointOfView: SCNNode? { get { renderer.pointOfView } set { renderer.pointOfView = newValue } }

    /// Compiles the scene's shaders and uploads its meshes in the background, so the first walk or catch
    /// never stalls on a pipeline compile.
    func warmUp() {
        guard let scene = renderer.scene else { return }
        var nodes: [Any] = [scene]
        scene.rootNode.enumerateHierarchy { node, _ in if node.geometry != nil { nodes.append(node) } }
        renderer.prepare(nodes,completionHandler:{ _ in })
    }

    func setSamples(for mode: SCNAntialiasingMode) {
        switch mode {
        case .none: sampleCount = 1
        case .multisampling2X: sampleCount = 2
        case .multisampling8X: sampleCount = device?.supportsTextureSampleCount(8) == true ? 8 : 4
        default: sampleCount = 4
        }
    }

    private func pixelSize() -> CGSize {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width:max(1,(bounds.width*scale).rounded()),height:max(1,(bounds.height*scale).rounded()))
    }

    private var lastBuffer: MTLCommandBuffer?
    /// The leg mesh is rewritten in shared memory for each frame: make sure the GPU has finished reading the previous
    /// one first (it long has, at 30–120 fps, so this practically never waits).
    func waitForGPU() { lastBuffer?.waitUntilCompleted(); lastBuffer = nil }

    /// Releases the drawables and buffers (the spider is hidden, or the tile changes size).
    func releaseBuffers() { attachments = nil }

    /// Draws the scene as it is now. Returns false when nothing could be drawn (no window or drawable yet).
    @discardableResult func draw() -> Bool {
        guard let device, let queue, window != nil else { return false }
        let size = pixelSize()
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size; attachments = nil }
        // Only on change: setting any layer property opens a Core Animation transaction (a WindowServer commit).
        let scale = window?.backingScaleFactor ?? 2
        if metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
        if attachments == nil || attachments?.size != size || attachments?.samples != sampleCount {
            var color: MTLTexture?, depth: MTLTexture?
            let memoryless: MTLStorageMode = device.hasUnifiedMemory ? .memoryless : .private
            if sampleCount > 1 {
                let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:metalLayer.pixelFormat,width:Int(size.width),height:Int(size.height),mipmapped:false)
                c.textureType = .type2DMultisample; c.sampleCount = sampleCount; c.usage = .renderTarget; c.storageMode = memoryless
                color = device.makeTexture(descriptor:c)
            }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float_stencil8,width:Int(size.width),height:Int(size.height),mipmapped:false)
            if sampleCount > 1 { d.textureType = .type2DMultisample; d.sampleCount = sampleCount }
            d.usage = .renderTarget; d.storageMode = memoryless
            depth = device.makeTexture(descriptor:d)
            attachments = (color,depth,size,sampleCount)
        }
        guard let drawable = metalLayer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return false }
        let start = CACurrentMediaTime()
        let pass = MTLRenderPassDescriptor()
        let color = pass.colorAttachments[0]!
        color.clearColor = MTLClearColor(red:0,green:0,blue:0,alpha:0); color.loadAction = .clear
        if let msaa = attachments?.color {
            color.texture = msaa; color.resolveTexture = drawable.texture; color.storeAction = .multisampleResolve
        } else { color.texture = drawable.texture; color.storeAction = .store }
        pass.depthAttachment.texture = attachments?.depth; pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1; pass.depthAttachment.storeAction = .dontCare
        pass.stencilAttachment.texture = attachments?.depth; pass.stencilAttachment.loadAction = .clear; pass.stencilAttachment.storeAction = .dontCare
        renderer.render(atTime:start,viewport:CGRect(origin:.zero,size:size),commandBuffer:buffer,passDescriptor:pass)
        buffer.present(drawable)
        buffer.commit()
        lastBuffer = buffer
        framesDrawn += 1; drawMs += (CACurrentMediaTime()-start)*1000
        return true
    }
}
