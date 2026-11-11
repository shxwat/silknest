import AppKit

/// Hit-tests only the hanging objects. Click selects an object; pulling it stretches its strand until
/// the strand snaps, at which point the object continues as a real native macOS drag.
final class WebInteractionView: NSView, NSDraggingSource {
    let web: PhysicalWeb
    /// Maps this view's points to web-local points.
    var toWeb: (NSPoint) -> V3 = { V3(Float($0.x),Float($0.y),0) }
    var item: (Int) -> ClipboardItem? = { _ in nil }
    var onClick: ((Int) -> Void)?
    var onDraggedOut: ((Int) -> Void)?
    var onPullStart: (() -> Void)?
    /// Scrolling over an object pages the Nest, like scrolling on its glass.
    var onScroll: ((NSEvent) -> Void)?
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
    private var pressed: Int?
    private var downPoint = NSPoint.zero
    private var downTime: TimeInterval = 0
    private var pulling = false
    private(set) var dragSessionActive = false
    /// True from mouse-down on an object until its pull or drag completes; the panel must keep events meanwhile.
    var isTracking: Bool { pressed != nil || dragSessionActive }

    init(frame: NSRect, web: PhysicalWeb) {
        self.web = web; super.init(frame:frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point,from:superview)
        return isTracking || web.hitTest(toWeb(local)) != nil ? self : nil
    }

    /// The button came up somewhere this view never heard about (the panel stopped taking events
    /// mid-press): let go, so the full-screen panel does not keep swallowing clicks.
    func releaseIfButtonUp() {
        guard let id = pressed, !dragSessionActive, NSEvent.pressedMouseButtons & 1 == 0 else { return }
        if pulling, let item = web.item(id) { web.restore(id,from:web.bob(item)) }
        pressed = nil; pulling = false
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow,from:nil)
        pressed = web.hitTest(toWeb(p))?.id; downPoint = p; downTime = event.timestamp; pulling = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let id = pressed, !dragSessionActive else { return }
        let p = convert(event.locationInWindow,from:nil)
        if !pulling {
            // A click with a little hand/trackpad jitter is still a click, not a pull.
            guard hypot(p.x-downPoint.x,p.y-downPoint.y) > 10 else { return }
            pulling = true; web.beginPull(id); onPullStart?()
        }
        let stretch = web.setPull(id,toward:toWeb(p))
        guard stretch >= 1, let clip = item(id) else { return }
        // The strand snaps here: the very same object continues as a native drag item.
        let size = web.item(id).map { web.objectSize($0) } ?? clip.preview.size
        web.detach(id)
        let items = clip.dragWriters().map { writer -> NSDraggingItem in
            let drag = NSDraggingItem(pasteboardWriter:writer)
            drag.setDraggingFrame(NSRect(x:p.x-size.width/2,y:p.y-size.height/2,width:size.width,height:size.height),contents:clip.preview)
            return drag
        }
        dragSessionActive = true
        let session = beginDraggingSession(with:items,event:event,source:self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        session.draggingFormation = .none
    }

    override func mouseUp(with event: NSEvent) {
        guard let id = pressed, !dragSessionActive else { return }
        let p = convert(event.locationInWindow,from:nil)
        let quick = event.timestamp-downTime < 0.35 && hypot(p.x-downPoint.x,p.y-downPoint.y) < 18
        if pulling {
            // Not pulled far enough: the strand draws the object back.
            if let item = web.item(id) { web.restore(id,from:web.bob(item)) }
            if quick { onClick?(id) }
        } else { onClick?(id) }
        pressed = nil; pulling = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let id = pressed {
            if operation != [] { onDraggedOut?(id) }
            else {
                let local = convert(window?.convertPoint(fromScreen:screenPoint) ?? .zero,from:nil)
                web.restore(id,from:toWeb(local))
            }
        }
        pressed = nil; pulling = false; dragSessionActive = false
    }
}
