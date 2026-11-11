import AppKit
import SceneKit
import QuartzCore
import simd

final class SpiderStudy {
    let window: NSWindow
    let motion: SpiderMotion
    let renderer: SpiderRenderer
    let view: ClearSceneView
    private var timer: Timer?
    private var lastTime = CACurrentMediaTime()
    private let status = NSTextField(labelWithString: "IDLE")
    private var tracking = false
    private var darkBackdrop = false
    private let destination = SpiderDropView(frame:NSRect(x:0,y:0,width:350,height:350))
    var onClose: (() -> Void)?
    init() {
        let size = NSSize(width:760,height:640)
        window = NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.colorSpace = .sRGB
        window.title = "SilkNest · Spider study"; window.isReleasedWhenClosed = false
        window.center()
        let canvasSize = NSSize(width:760,height:480)
        motion = SpiderMotion(bounds:CGRect(origin:.zero,size:canvasSize),position:V3(380,225,0))
        motion.autoPatrol = false
        renderer = SpiderRenderer(size:canvasSize,debugAllowed:true)
        view = ClearSceneView(frame:NSRect(x:0,y:160,width:760,height:480))
        view.scene = renderer.scene; view.pointOfView = renderer.camera
        view.backgroundColor = NSColor(calibratedWhite:0.82,alpha:1)
        view.antialiasingMode = .multisampling4X
        let content = NSView(frame:NSRect(origin:.zero,size:size)); window.contentView = content
        content.addSubview(view)
        view.addSubview(destination)
        destination.onHover = { [weak self] p in
            guard let self else { return }
            self.motion.drag(at:p.map { self.scenePoint($0) })
        }
        destination.canCatchAt = { [weak self] p in
            guard let self else { return false }; return simd_distance(self.scenePoint(p),self.motion.position)<80
        }
        destination.onCatch = { [weak self] p in
            guard let self else { return false }
            self.tracking = false
            return self.motion.catchItem(at:self.scenePoint(p))
        }
        let title = NSTextField(labelWithString:"One spider. Five things to get right.")
        title.font = .systemFont(ofSize:17,weight:.medium); title.frame = NSRect(x:24,y:124,width:520,height:24)
        content.addSubview(title)
        status.font = .monospacedSystemFont(ofSize:10,weight:.medium)
        status.textColor = .secondaryLabelColor; status.frame = NSRect(x:610,y:129,width:126,height:18)
        status.alignment = .right; content.addSubview(status)
        let names = ["Idle","Crawl","Turn","Drag over","Catch","Backdrop"]
        for (i,name) in names.enumerated() {
            let button = NSButton(title:name,target:self,action:#selector(action(_:)))
            button.tag = i; button.bezelStyle = .rounded
            button.frame = NSRect(x:24+i*117,y:79,width:108,height:30); content.addSubview(button)
        }
        let debugNames = ["Foot targets","Planted","Stepping","IK","Forward","Awareness"]
        for (i,name) in debugNames.enumerated() {
            let checkbox = NSButton(checkboxWithTitle:name,target:self,action:#selector(toggleDebug(_:)))
            checkbox.tag = i; checkbox.font = .systemFont(ofSize:11)
            checkbox.frame = NSRect(x:24+i*117,y:43,width:113,height:23)
            content.addSubview(checkbox)
        }
        let sample = DragSampleView(frame:NSRect(x:24,y:9,width:118,height:24))
        content.addSubview(sample)
        let note = NSTextField(labelWithString:"Drag onto the spider here or on your desktop. Drops are not saved.")
        note.font = .systemFont(ofSize:11); note.textColor = .secondaryLabelColor
        note.frame = NSRect(x:156,y:12,width:580,height:18); content.addSubview(note)
        timer = Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!,forMode:.common)
        NotificationCenter.default.addObserver(self,selector:#selector(closed),name:NSWindow.willCloseNotification,object:window)
    }
    func show() { NSApp.activate(ignoringOtherApps:true); window.makeKeyAndOrderFront(nil) }
    @objc private func closed() { timer?.invalidate(); onClose?() }
    @objc private func action(_ sender: NSButton) {
        tracking = false; motion.drag(at:nil)
        switch sender.tag {
        case 0: motion.target = motion.position; motion.transition(.idle)
        case 1: motion.crawl(to:motion.position.x>380 ? V3(230,240,0) : V3(520,270,0))
        case 2: motion.turn(by:.pi/2)
        case 3: tracking = true; motion.transition(.idle); motion.drag(at:motion.world(V3(0,65,0)))
        case 4: motion.transition(.idle); _ = motion.catchItem(at:motion.world(V3(0,52,0)))
        default:
            darkBackdrop.toggle()
            view.backgroundColor = NSColor(calibratedWhite:darkBackdrop ? 0.10 : 0.82,alpha:1)
        }
    }
    @objc private func toggleDebug(_ sender:NSButton) {
        let option = SpiderDebugOptions(rawValue:1<<sender.tag)
        if sender.state == .on { renderer.debugOptions.insert(option) }
        else { renderer.debugOptions.remove(option) }
    }
    private func scenePoint(_ p:NSPoint) -> V3 {
        let local = view.convert(window.convertPoint(fromScreen:p),from:nil)
        return V3(Float(local.x),Float(local.y),0)
    }
    private func tick() {
        let now = CACurrentMediaTime(); let dt = Float(now-lastTime); lastTime = now
        guard window.isVisible else { return }
        if tracking {
            let local = view.convert(window.convertPoint(fromScreen:NSEvent.mouseLocation),from:nil)
            motion.drag(at:V3(Float(local.x),Float(local.y),0))
        }
        let mouse = scenePoint(NSEvent.mouseLocation)
        let cursor = view.bounds.contains(NSPoint(x:CGFloat(mouse.x),y:CGFloat(mouse.y))) ? mouse : nil
        motion.update(dt:dt,cursor:cursor); let changed = renderer.renderIfNeeded(motion)
        let hitOrigin = NSPoint(x:CGFloat(motion.position.x)-175,y:CGFloat(motion.position.y)-175)
        if destination.frame.origin != hitOrigin { destination.frame.origin = hitOrigin }
        destination.accepting = motion.state != .catching && motion.state != .settling
        if changed { view.setNeedsDisplay(view.bounds) }
        let label = motion.state.rawValue.uppercased()
        if status.stringValue != label { status.stringValue = label }
    }
    deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }
}
