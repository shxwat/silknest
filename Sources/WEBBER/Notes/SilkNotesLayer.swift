import AppKit
import QuartzCore

/// The notes of one display, as little spiders hanging from the top edge (see SilkRailResolver). A note
/// peeks out of its knot into free space only on intent (hover ~0.35 s or click).
/// The panel takes the mouse only over a knot, an open note, or during a drag; everywhere
/// else — including right beside the rail — clicks go to the app underneath.
final class SilkNotesLayer {
    let screenKey: String
    let panel: OverlayPanel
    private let view: SilkNotesView
    private(set) var frame: NSRect
    private var visuals: [UUID: NoteVisual] = [:]
    private let hint = CATextLayer()
    private(set) var rail: SilkRail
    private var order: [UUID] = []
    private var placedIDs: [UUID] = []
    private var hintUntil: CFTimeInterval = 0

    var onClick: ((UUID) -> Void)?
    var onDoubleClick: ((UUID) -> Void)?
    var onContext: ((UUID) -> Void)?
    var onDone: ((UUID) -> Void)?
    var onToggleBox: ((UUID, Int) -> Void)?
    var onDelete: ((UUID) -> Void)?
    /// A note dropped at a display-local position chosen by the user.
    var onMoved: ((UUID, CGPoint) -> Void)?
    /// A drag that left this display: the pointer (screen coordinates) and whether the button came up.
    /// Returns true when another display took the note.
    var onDragAcross: ((UUID, NSPoint, Bool) -> Bool)?
    private var acrossID: UUID?

    init(screen: NSScreen) {
        screenKey = screen.displayKey
        frame = screen.visibleFrame
        rail = SilkRailResolver.resolve(.init(bounds:frame.size))
        panel = OverlayPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.colorSpace = .sRGB
        panel.level = NSWindow.Level(rawValue:NSWindow.Level.statusBar.rawValue+1)
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none; panel.ignoresMouseEvents = true
        view = SilkNotesView(frame:NSRect(origin:.zero,size:frame.size),scale:screen.backingScaleFactor)
        panel.contentView = view
        hint.contentsScale = screen.backingScaleFactor; hint.fontSize = 11; hint.font = NSFont.systemFont(ofSize:11,weight:.medium)
        hint.foregroundColor = NSColor(white:1,alpha:0.85).cgColor; hint.backgroundColor = NSColor(srgbRed:0.07,green:0.08,blue:0.09,alpha:0.82).cgColor
        hint.cornerRadius = 7; hint.alignmentMode = .center; hint.opacity = 0
        hint.string = "Drag a spider anywhere — hover to peek, click to edit"
        hint.bounds = CGRect(x:0,y:0,width:330,height:20)
        view.layer?.addSublayer(hint)
        view.owner = self
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }

    /// A new rail (context changed). Knots glide to their new places with a small settle.
    func setRail(_ next: SilkRail) {
        guard next != rail else { return }
        rail = next
        layoutRoles()
        for v in visuals.values { v.kick(0.6) }
    }

    // MARK: model → visuals

    func apply(_ result: NoteVisibility.Result, notes: [SilkNote]) {
        let mine = notes.filter { $0.display == screenKey }
        let byID = Dictionary(uniqueKeysWithValues:mine.map { ($0.id,$0) })
        for note in mine {
            if let v = visuals[note.id] { v.dying = nil; if v.note != note { v.setNote(note) } }
            else {
                let v = NoteVisual(note:note,scale:view.scale)
                v.pos = rail.start
                visuals[note.id] = v; view.layer?.addSublayer(v.container)
            }
        }
        for (id,v) in visuals where byID[id] == nil && v.dying == nil { v.dying = 0; v.expandTarget = 0 }
        // Rail order is the user's order (x as an ordering key, highest first), not priority order.
        placedIDs = result.visible.map(\.id).filter { byID[$0]?.position != nil }
        order = result.visible.map(\.id).filter { byID[$0]?.position == nil }.sorted { (byID[$0]?.x ?? 0) > (byID[$1]?.x ?? 0) }
        for id in result.retracted { visuals[id]?.role = .retracted }
        layoutRoles()
    }

    private func layoutRoles() {
        for v in visuals.values { v.outward = rail.outward; v.bounds = CGRect(origin:.zero,size:frame.size) }
        for (i,id) in order.enumerated() {
            let point = NotePlacement.defaultPoint(i,in:frame.size)
            visuals[id]?.outward = NotePlacement.outward(at:point,in:frame.size)
            visuals[id]?.role = .shown(point)
        }
        for id in placedIDs {
            guard let v = visuals[id], let position = v.note.position else { continue }
            let point = NotePlacement.point(position,in:frame.size)
            v.outward = NotePlacement.outward(at:point,in:frame.size)
            v.role = .shown(point)
        }
    }

    /// A newly written note travels from the composer to its knot on the rail.
    func arrive(_ id: UUID, from screenPoint: NSPoint) {
        visuals[id]?.pos = CGPoint(x:screenPoint.x-frame.minX,y:screenPoint.y-frame.minY)
        visuals[id]?.kick(0.8)
        if !UserDefaults.standard.bool(forKey:"notes.railHintShown") {
            UserDefaults.standard.set(true,forKey:"notes.railHintShown")
            hintUntil = CACurrentMediaTime()+4.5
        }
    }

    func holdOpen(_ id: UUID?) { for v in visuals.values { v.heldOpen = v.id == id; if v.heldOpen { v.expandTarget = 1 } } }
    func snap(_ id: UUID) { if let v = visuals[id], v.dying == nil { v.dying = 0; v.expandTarget = 0 } }
    /// A reminder is due: the note drops, wiggles and opens.
    func alert(_ id: UUID) {
        guard let v = visuals[id] else { return }
        v.alertTime = 0; v.expandTarget = 1; v.clickOpened = true
        for other in visuals.values where other.id != id { other.expandTarget = 0; other.clickOpened = false }
    }

    /// Verification: the open card's trash button, in screen coordinates.
    func deleteButtonPoint(_ id: UUID) -> NSPoint? {
        guard let v = visuals[id], v.expand > 0.8 else { return nil }
        let f = v.cardFrame, d = NoteArt.deleteRect(cardSize:f.size)
        return NSPoint(x:frame.minX+f.minX+d.midX,y:frame.minY+f.minY+d.midY)
    }

    func notePoint(_ id: UUID) -> NSPoint? {
        guard let v = visuals[id] else { return nil }
        return NSPoint(x:v.pos.x+frame.minX,y:v.pos.y+frame.minY)
    }
    /// Where a note's reminder options hang: below the knot, or beside the card while it is open
    /// (so they never cover the card's header and buttons). Returns the point and the direction.
    func alertAnchor(_ id: UUID) -> (point: NSPoint, toward: CGFloat)? {
        guard let v = visuals[id] else { return nil }
        guard v.expand > 0.5 else { return (NSPoint(x:v.pos.x+frame.minX,y:v.pos.y+frame.minY),-.pi/2) }
        let f = v.cardFrame
        let right = f.maxX+frame.minX+190 < frame.maxX
        return (NSPoint(x:(right ? f.maxX : f.minX)+frame.minX,y:f.midY+frame.minY),right ? 0 : .pi)
    }
    func isShowing(_ id: UUID) -> Bool { visuals[id]?.isPresent ?? false }
    var takesClicks: Bool { panel.isVisible && !panel.ignoresMouseEvents }
    var hasNotes: Bool { !visuals.isEmpty || hint.opacity > 0.01 }
    var visibleIDs: [UUID] { order }

    // MARK: per frame

    @discardableResult func tick(dt: CGFloat, pointer screenPointer: NSPoint, menuOpen: Bool) -> Bool {
        let p = CGPoint(x:screenPointer.x-frame.minX,y:screenPointer.y-frame.minY)
        let pressedID = view.pressed
        let over = visual(at:p)
        for v in visuals.values {
            if v.dying != nil || !v.isPresent { v.hoverTime = 0; v.awayTime = 0; if !v.isPresent { v.expandTarget = 0 }; continue }
            if v.dragging { continue }
            if v.heldOpen { v.expandTarget = 1; continue }
            // A forgiving corridor: knot, card and the gap between them all count as "still here".
            let inside = v === over || (over == nil && v.expand > 0.3 && v.corridor.contains(p))
            if inside { v.hoverTime += dt; v.awayTime = 0 } else { v.hoverTime = 0; v.awayTime += dt }
            if menuOpen && v.id == pressedID { continue }
            if v.expandTarget > 0.5 {
                if v.awayTime > (v.clickOpened ? 0.9 : 0.35) { v.expandTarget = 0; v.clickOpened = false }
            } else if inside && v.hoverTime > 0.35 {
                v.expandTarget = 1
                for other in visuals.values where other.id != v.id && !other.heldOpen { other.expandTarget = 0; other.clickOpened = false }
            }
        }

        // Only a real, ongoing press keeps the (screen-sized) panel: a right-click menu or a lost
        // button-up must never leave it swallowing clicks everywhere.
        let takes = over != nil || (view.pressed != nil && NSEvent.pressedMouseButtons != 0)
        if panel.ignoresMouseEvents == takes { panel.ignoresMouseEvents = !takes }

        var moving = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for v in visuals.values { if v.step(dt:dt) { moving = true } }
        for (id,v) in visuals {
            v.layout()
            if let d = v.dying, d >= 1 { v.container.removeFromSuperlayer(); visuals[id] = nil }
        }
        let now = CACurrentMediaTime()
        let showHint = now < hintUntil && !order.isEmpty
        let anchor = rail.point(0)
        hint.position = CGPoint(x:min(max(anchor.x+rail.outward.x*180,170),frame.width-170),y:min(max(anchor.y-42,16),frame.height-16))
        let target: Float = showHint ? 1 : 0
        if hint.opacity != target { hint.opacity += (target-hint.opacity)*Float(min(1,dt*8)); if abs(hint.opacity-target) < 0.02 { hint.opacity = target }; moving = true }
        CATransaction.commit()
        // Hover intent needs fast ticks until the card opens; a settled card needs no frame loop.
        let waitingForHover = over.map { $0.expandTarget < 0.5 && $0.hoverTime <= 0.35 } ?? false
        return moving || waitingForHover || view.pressed != nil
    }

    // MARK: input from the view

    fileprivate func visual(at p: CGPoint) -> NoteVisual? {
        let candidates = visuals.values.filter { $0.dying == nil && $0.isPresent && $0.containsHit(p) }
        // A neighbouring knot wins over an open card covering it.
        if let knot = candidates.filter({ $0.knotRect.contains(p) }).min(by:{ hypot($0.knotPoint.x-p.x,$0.knotPoint.y-p.y) < hypot($1.knotPoint.x-p.x,$1.knotPoint.y-p.y) }) { return knot }
        return candidates.max { $0.expand < $1.expand }
    }
    fileprivate func clicked(_ v: NoteVisual, at point: CGPoint) {
        if v.expand > 0.8 && v.cardFrame.contains(point) {
            // The trash button in the card's corner deletes; anywhere else on the card edits.
            let f = v.cardFrame
            let local = CGPoint(x:point.x-f.minX,y:point.y-f.minY)
            if NoteArt.deleteRect(cardSize:f.size).insetBy(dx:-4,dy:-6).contains(local) { onDelete?(v.id); return }
            if NoteArt.doneRect(cardSize:f.size).insetBy(dx:-3,dy:-6).contains(local) { onDone?(v.id); return }
            if let line = NoteArt.checkbox(at:local,note:v.note,cardSize:f.size) { onToggleBox?(v.id,line); return }
            onDoubleClick?(v.id); return
        }
        v.clickOpened = v.expandTarget < 0.5; v.expandTarget = v.clickOpened ? 1 : 0; v.awayTime = 0
        for other in visuals.values where other.id != v.id { other.expandTarget = 0; other.clickOpened = false }
        onClick?(v.id)
    }
    fileprivate func doubleClicked(_ v: NoteVisual) { onDoubleClick?(v.id) }
    fileprivate func context(_ v: NoteVisual) { v.expandTarget = 1; v.clickOpened = true; onContext?(v.id) }

    /// The handle follows both pointer axes, without snapping to the shared rail.
    func drag(_ id: UUID, by delta: CGPoint) {
        guard let v = visuals[id] else { return }
        if v.dragOrigin == nil { v.dragOrigin = v.pos }
        let origin = v.dragOrigin!
        v.dragging = true
        v.stretch = .zero; v.expandTarget = 0; v.clickOpened = false
        v.pos = NotePlacement.clamp(CGPoint(x:origin.x+delta.x,y:origin.y+delta.y),in:frame.size)
        v.outward = NotePlacement.outward(at:v.pos,in:frame.size)
        // Over another display: that display shows the note under the pointer; this one lets it go.
        let pointer = NSEvent.mouseLocation
        let away = !NSMouseInRect(pointer,panel.screen?.frame ?? frame,false)
        if away, onDragAcross?(id,pointer,false) == true { acrossID = id; v.container.isHidden = true }
        else if acrossID == id { acrossID = nil; v.container.isHidden = false; _ = onDragAcross?(id,pointer,false) }
    }

    /// Another display's drag is passing over this one: show the note following the pointer.
    func ghost(_ note: SilkNote, at screenPoint: NSPoint) {
        let p = NotePlacement.clamp(CGPoint(x:screenPoint.x-frame.minX,y:screenPoint.y-frame.minY),in:frame.size)
        let v: NoteVisual
        if let existing = visuals[note.id] { v = existing; v.dying = nil } else {
            v = NoteVisual(note:note,scale:view.scale); v.pos = p
            visuals[note.id] = v; view.layer?.addSublayer(v.container)
        }
        v.container.isHidden = false
        v.bounds = CGRect(origin:.zero,size:frame.size)
        v.dragging = true; v.expandTarget = 0; v.role = .shown(p); v.pos = p
        v.outward = NotePlacement.outward(at:p,in:frame.size)
    }
    func dropGhost(_ id: UUID, keep: Bool) {
        guard let v = visuals[id] else { return }
        v.dragging = false
        if keep { v.kick(0.3) } else { v.dying = 0 }
    }

    func dropped(_ id: UUID) {
        guard let v = visuals[id], v.dragOrigin != nil else { return }
        v.dragging = false; v.dragOrigin = nil
        if acrossID == id {
            acrossID = nil
            if onDragAcross?(id,NSEvent.mouseLocation,true) == true { v.container.isHidden = true; v.dying = 1; return }
            v.container.isHidden = false
        }
        v.role = .shown(v.pos)
        v.awayTime = 0; v.kick(0.25)
        onMoved?(id,v.pos)
    }
}

/// Layer-hosting view: forwards clicks, double-clicks, right-clicks and knot drags.
final class SilkNotesView: NSView {
    weak var owner: SilkNotesLayer?
    let scale: CGFloat
    fileprivate var pressed: UUID?
    private var dragging: NoteVisual?
    private var down = CGPoint.zero

    init(frame: NSRect, scale: CGFloat) {
        self.scale = scale
        super.init(frame:frame)
        layer = CALayer(); wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow,from:nil)
        if let v = owner?.visual(at:p) {
            pressed = v.id; down = p
            if event.clickCount >= 2 { owner?.doubleClicked(v); pressed = nil }
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let id = pressed, let owner else { return }
        let p = convert(event.locationInWindow,from:nil)
        if dragging == nil {
            guard hypot(p.x-down.x,p.y-down.y) > 4, let v = owner.visual(at:down) ?? owner.visual(at:p), v.id == id else { return }
            dragging = v; v.dragging = true
        }
        if let v = dragging { owner.drag(v.id,by:CGPoint(x:p.x-down.x,y:p.y-down.y)) }
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        let p = convert(event.locationInWindow,from:nil)
        if let v = dragging { v.dragging = false; dragging = nil; owner?.dropped(v.id); return }
        if pressed != nil, event.clickCount == 1, let v = owner?.visual(at:p) { owner?.clicked(v,at:p) }
    }
    override func rightMouseDown(with event: NSEvent) {
        // Right-click: the note opens and its silk menu appears (Edit, Copy, Pin to <App>, …).
        let p = convert(event.locationInWindow,from:nil)
        if let v = owner?.visual(at:p) { owner?.context(v) }
    }
}

/// One freely movable note: a tiny still spider-knot, and a card that peeks out toward free space.
final class NoteVisual {
    enum Role: Equatable { case shown(CGPoint), retracted }

    let id: UUID
    private(set) var note: SilkNote
    let container = CALayer()
    private let knot = CALayer()
    let glow = CALayer(), card = CALayer()
    private let tether = CAShapeLayer(), link = CAShapeLayer(), brace = CAShapeLayer()
    private let scale: CGFloat
    private var cardSize = CGSize.zero

    var role: Role = .retracted
    /// Knot position (display-local) — eases toward the role's target.
    var pos = CGPoint.zero
    var outward = CGPoint(x:-1,y:0)
    var bounds = CGRect.zero
    var expand: CGFloat = 0
    var expandTarget: CGFloat = 0
    var hoverTime: CGFloat = 0, awayTime: CGFloat = 0
    var clickOpened = false, heldOpen = false
    var dragging = false
    var dragOrigin: CGPoint?
    var stretch = CGPoint.zero
    private var stretchVelocity = CGPoint.zero
    var dying: CGFloat?
    private var presence: CGFloat = 0
    private var pin: CGFloat = 0
    private var settle: CGFloat = 0, settleVelocity: CGFloat = 0
    /// Reuse the exact layer geometry until an input to layout changes.
    private struct LayoutState: Equatable {
        let point: CGPoint
        let presence: CGFloat
        let expand: CGFloat
        let pin: CGFloat
        let dying: CGFloat?
        let outward: CGPoint
        let bounds: CGRect
        let cardSize: CGSize
        let dragging: Bool
    }
    private var lastLayout: LayoutState?

    init(note: SilkNote, scale: CGFloat) {
        id = note.id; self.note = note; self.scale = scale
        pin = note.pinned ? 1 : 0
        for line in [tether,link,brace] { line.fillColor = nil; line.lineCap = .round; line.contentsScale = scale; container.addSublayer(line) }
        tether.strokeColor = NSColor(srgbRed:1,green:0.84,blue:0.55,alpha:0.42).cgColor; tether.lineWidth = 0.6
        tether.shadowColor = NSColor(srgbRed:1,green:0.75,blue:0.3,alpha:1).cgColor; tether.shadowRadius = 2; tether.shadowOpacity = 0.35; tether.shadowOffset = .zero
        link.strokeColor = NSColor(srgbRed:1,green:0.82,blue:0.5,alpha:0.75).cgColor; link.lineWidth = 0.7
        brace.strokeColor = NSColor(srgbRed:0.95,green:0.95,blue:0.92,alpha:0.6).cgColor; brace.lineWidth = 0.55
        card.contentsScale = scale; card.contentsGravity = .resize
        card.shadowColor = NSColor.black.cgColor; card.shadowOpacity = 0.45; card.shadowRadius = 14; card.shadowOffset = CGSize(width:0,height:-5)
        container.addSublayer(card)
        knot.bounds = CGRect(x:0,y:0,width:20,height:20)
        knot.contents = MiniSpider.image.layerContents(forContentsScale:scale); knot.contentsScale = scale
        knot.contentsGravity = .resizeAspect
        // A soft gold glow behind the little spider.
        glow.bounds = CGRect(x:0,y:0,width:16,height:16); glow.cornerRadius = 8
        glow.backgroundColor = NSColor(srgbRed:1,green:0.72,blue:0.25,alpha:0.18).cgColor
        glow.shadowColor = NSColor(srgbRed:1,green:0.72,blue:0.25,alpha:1).cgColor; glow.shadowRadius = 7; glow.shadowOpacity = 0.55; glow.shadowOffset = .zero
        container.addSublayer(glow)
        container.addSublayer(knot)
        setNote(note)
    }

    func setNote(_ note: SilkNote) {
        let textChanged = note != self.note || cardSize == .zero
        if note.pinned != self.note.pinned { kick(0.4) }
        self.note = note
        guard textChanged else { return }
        let full = NoteArt.card(note)
        cardSize = full.size
        card.contents = full.layerContents(forContentsScale:scale); card.bounds = CGRect(origin:.zero,size:cardSize)
    }

    /// A small settle (creation, pin, rail move) — the only motion a resting note ever makes.
    func kick(_ v: CGFloat) { settleVelocity += v*30 }

    var isPresent: Bool { presence > 0.5 && targetPresence > 0.5 }
    private var targetPresence: CGFloat { if case .shown = role { return 1 }; return 0 }
    private var target: CGPoint {
        switch role { case .shown(let p): return p; case .retracted: return pos }
    }

    func step(dt: CGFloat) -> Bool {
        let before = (pos:pos,presence:presence,expand:expand,pin:pin,settle:settle,stretch:stretch)
        let k = min(1,dt*12)
        if !dragging { pos.x += (target.x-pos.x)*k; pos.y += (target.y-pos.y)*k }
        if abs(target.x-pos.x) < 0.05 && abs(target.y-pos.y) < 0.05 { pos = target }
        presence += (targetPresence-presence)*min(1,dt*13)
        if abs(targetPresence-presence) < 0.003 { presence = targetPresence }
        expand += (expandTarget-expand)*min(1,dt*15)
        if abs(expandTarget-expand) < 0.002 { expand = expandTarget }
        let tp: CGFloat = note.pinned ? 1 : 0
        pin += (tp-pin)*min(1,dt*10); if abs(pin-tp) < 0.003 { pin = tp }
        // Tiny damped settle, then stillness.
        settleVelocity += (-160*settle-14*settleVelocity)*dt; settle += settleVelocity*dt
        if abs(settle) < 0.01 && abs(settleVelocity) < 0.05 { settle = 0; settleVelocity = 0 }
        if !dragging {
            stretchVelocity.x += (-180*stretch.x-15*stretchVelocity.x)*dt; stretchVelocity.y += (-180*stretch.y-15*stretchVelocity.y)*dt
            stretch.x += stretchVelocity.x*dt; stretch.y += stretchVelocity.y*dt
            if hypot(stretch.x,stretch.y) < 0.05 && hypot(stretchVelocity.x,stretchVelocity.y) < 0.5 { stretch = .zero; stretchVelocity = .zero }
        }
        if let d = dying { dying = min(1,d+dt/0.36) }
        let alerting = alertTime != nil
        if let t = alertTime { alertTime = t+dt > 1.8 ? nil : t+dt }
        return abs(before.pos.x-pos.x) > 0.0001 || abs(before.pos.y-pos.y) > 0.0001
            || abs(before.presence-presence) > 0.0001 || abs(before.expand-expand) > 0.0001
            || abs(before.pin-pin) > 0.0001 || abs(before.settle-settle) > 0.0001
            || abs(before.stretch.x-stretch.x) > 0.0001 || abs(before.stretch.y-stretch.y) > 0.0001
            || dying != nil || alerting
    }

    /// Reminder due: the little spider drops down its thread and wiggles the note (0…1.8 s).
    var alertTime: CGFloat?
    private var alertOffset: CGPoint {
        guard let t = alertTime else { return .zero }
        let env = sin(min(1,t/1.8) * .pi)
        let drop = 34*env, wiggle = sin(t*22)*5*env
        return CGPoint(x:outward.x*drop+(outward.x == 0 ? wiggle : 0),y:outward.y*drop+(outward.y == 0 ? wiggle : 0))
    }
    var knotPoint: CGPoint {
        CGPoint(x:pos.x+stretch.x+outward.x*settle+alertOffset.x,y:pos.y+stretch.y+outward.y*settle+alertOffset.y)
    }

    /// Where the card sits when open: beside the knot, on the free-space side, kept on screen.
    var cardFrame: CGRect {
        let k = knotPoint
        let reach = 14+cardSize.width/2
        var c = CGPoint(x:k.x+outward.x*reach,y:k.y+outward.y*(14+cardSize.height/2))
        if outward.x == 0 { c.x = k.x }
        let half = CGSize(width:cardSize.width/2,height:cardSize.height/2)
        c.x = min(max(c.x,bounds.minX+half.width+6),bounds.maxX-half.width-6)
        c.y = min(max(c.y,bounds.minY+half.height+6),bounds.maxY-half.height-6)
        return CGRect(x:c.x-half.width,y:c.y-half.height,width:cardSize.width,height:cardSize.height)
    }

    /// Just the knot (14–18 pt), plus the card while it is open.
    var knotRect: CGRect { CGRect(x:knotPoint.x-13,y:knotPoint.y-13,width:26,height:26) }
    func containsHit(_ point: CGPoint) -> Bool {
        knotRect.contains(point) || (expand > 0.5 && cardFrame.insetBy(dx:-4,dy:-4).contains(point))
    }
    var hitRect: CGRect { expand > 0.5 ? knotRect.union(cardFrame.insetBy(dx:-4,dy:-4)) : knotRect }
    var corridor: CGRect { hitRect.union(cardFrame).insetBy(dx:-12,dy:-12) }

    func layout() {
        let state = LayoutState(point:knotPoint,presence:presence,expand:expand,pin:pin,dying:dying,
                                outward:outward,bounds:bounds,cardSize:cardSize,dragging:dragging)
        guard state != lastLayout else { return }
        lastLayout = state
        container.position = .zero
        var k = knotPoint
        var alpha = presence
        if let d = dying { k.y -= 50*d*d; alpha *= 1-d }
        knot.position = k
        knot.opacity = Float(alpha*(0.82+0.18*pin))
        glow.position = k; glow.opacity = Float(alpha*(0.55+0.45*max(pin,expand)))
        let s: CGFloat = 1+0.12*pin
        knot.transform = CATransform3DRotate(CATransform3DMakeScale(s,s,1),atan2(outward.y,outward.x) + .pi/2,0,0,1)
        let strand = CGMutablePath()
        if dying == nil {
            strand.move(to:NotePlacement.anchor(at:k,outward:outward,in:bounds))
            strand.addLine(to:CGPoint(x:k.x-outward.x*9,y:k.y-outward.y*9))
        }
        tether.path = strand; tether.opacity = Float(alpha)
        // The card unfolds out of the knot toward free space.
        let e = expand
        let f = cardFrame
        let from = k
        let to = CGPoint(x:f.midX,y:f.midY)
        card.position = CGPoint(x:from.x+(to.x-from.x)*(0.55+0.45*e),y:from.y+(to.y-from.y)*(0.55+0.45*e))
        card.transform = CATransform3DMakeScale(0.6+0.4*e,0.6+0.4*e,1)
        card.opacity = Float(min(1,e*1.4)*alpha)
        // A short silk link from knot to card edge while open.
        let edge = CGPoint(x:outward.x > 0 ? f.minX : (outward.x < 0 ? f.maxX : f.midX),y:outward.y > 0 ? f.minY : (outward.y < 0 ? f.maxY : card.position.y))
        let path = CGMutablePath()
        if e > 0.05 { path.move(to:k); path.addLine(to:CGPoint(x:k.x+(edge.x-k.x)*e,y:k.y+(edge.y-k.y)*e)) }
        link.path = path; link.opacity = Float(alpha)
        // Pinned: reinforced silk — two short supporting strands from the rail into the knot.
        if pin > 0.01 && dying == nil {
            let b = CGMutablePath()
            let side = CGPoint(x:-outward.y,y:outward.x)
            for sgn: CGFloat in [-1,1] {
                let from = CGPoint(x:k.x+side.x*sgn*9-outward.x*5,y:k.y+side.y*sgn*9-outward.y*5)
                b.move(to:from); b.addLine(to:CGPoint(x:from.x+(k.x-from.x)*pin,y:from.y+(k.y-from.y)*pin))
            }
            brace.path = b; brace.opacity = Float(alpha*pin)
        } else { brace.path = nil }
        container.zPosition = e > 0.01 || dragging ? 10 : 0
    }
}

/// Drawing for note bodies: a small dark fragment with a silk puncture, not a sticky note.
enum NoteArt {
    private static let ink = NSColor(white:0.95,alpha:0.94)
    private static let body = NSColor(srgbRed:0.075,green:0.08,blue:0.09,alpha:0.96)

    static func tab(_ title: String) -> NSImage {
        let font = NSFont.systemFont(ofSize:11,weight:.medium)
        let text = title.isEmpty ? "…" : title
        let w = min(170,max(44,(text as NSString).size(withAttributes:[.font:font]).width+20))
        return ItemPreview.draw(NSSize(width:w,height:24)) { rect in
            fragment(rect.insetBy(dx:1,dy:1))
            let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingTail
            (text as NSString).draw(in:NSRect(x:6,y:4,width:rect.width-12,height:14),withAttributes:[.font:font,.foregroundColor:ink,.paragraphStyle:style])
        }
    }

    /// The trash button in a card's top-right corner (card coordinates, origin bottom-left).
    static func deleteRect(cardSize: CGSize) -> CGRect { CGRect(x:cardSize.width-38,y:cardSize.height-31,width:24,height:22) }

    /// The ✓ Done button, left of the trash.
    static func doneRect(cardSize: CGSize) -> CGRect { CGRect(x:cardSize.width-66,y:cardSize.height-31,width:24,height:22) }

    static let cardWidth: CGFloat = 268
    private static let bodyFont = NSFont.systemFont(ofSize:13.5,weight:.regular)
    private static func bodyStyle() -> NSMutableParagraphStyle { let s = NSMutableParagraphStyle(); s.lineSpacing = 2.5; s.lineBreakMode = .byWordWrapping; return s }

    /// The note's lines laid out on the card (card coordinates): checklist lines get a box.
    /// Shared by drawing and by clicks, so a click lands on the box that is drawn.
    static func bodyLines(_ note: SilkNote) -> (lines: [(index: Int, text: String, rect: NSRect, box: Bool?)], height: CGFloat) {
        let width = cardWidth-36
        let attrs: [NSAttributedString.Key:Any] = [.font:bodyFont,.paragraphStyle:bodyStyle()]
        var out: [(Int,String,NSRect,Bool?)] = [], y: CGFloat = 0
        for (i,raw) in note.text.components(separatedBy:"\n").enumerated() {
            let box = NoteReminder.checkbox(Substring(raw))
            let text = box.map { String($0.rest).trimmingCharacters(in:.whitespaces) } ?? raw
            let w = box == nil ? width : width-20
            let h = max(17,(text.isEmpty ? " " : text as NSString).boundingRect(with:NSSize(width:w,height:10000),options:[.usesLineFragmentOrigin],attributes:attrs).height.rounded(.up))
            if y+h > 212 { break }
            out.append((i,text,NSRect(x:0,y:y,width:width,height:h),box?.checked)); y += h+2
        }
        return (out,max(20,y))
    }

    static func card(_ note: SilkNote) -> NSImage {
        let width = cardWidth
        let layout = bodyLines(note)
        let contentHeight = layout.height
        let height = contentHeight+78
        return ItemPreview.draw(NSSize(width:width,height:height)) { rect in
            let r = rect.insetBy(dx:1,dy:1)
            let shape = NSBezierPath(roundedRect:r,xRadius:12,yRadius:12)
            // Smoked glass with a warm glow from the thread above.
            NSGradient(colors:[NSColor(srgbRed:0.13,green:0.12,blue:0.11,alpha:0.97),NSColor(srgbRed:0.06,green:0.065,blue:0.08,alpha:0.97)])!.draw(in:shape,angle:-90)
            NSGraphicsContext.saveGraphicsState(); shape.addClip()
            NSGradient(colors:[NSColor(srgbRed:1,green:0.74,blue:0.3,alpha:0.16),NSColor.clear])!.draw(in:NSRect(x:r.minX,y:r.maxY-46,width:r.width,height:46),angle:-90)
            NSGraphicsContext.restoreGraphicsState()
            NSColor(srgbRed:1,green:0.8,blue:0.45,alpha:0.32).setStroke(); shape.lineWidth = 0.8; shape.stroke()
            // Header: the little spider, the label, a reminder clock, and the Done / Delete buttons.
            let gold = NSColor(srgbRed:1,green:0.77,blue:0.36,alpha:0.95)
            MiniSpider.image.draw(in:NSRect(x:13,y:height-27,width:16,height:16))
            let label = note.mode == .app ? (note.appName ?? "App note").uppercased() : "SILK NOTE"
            let labelText = (note.pinned ? "◆ " : "")+label
            let labelAttrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:9.5,weight:.bold),.foregroundColor:gold,.kern:1.2]
            (labelText as NSString).draw(at:NSPoint(x:33,y:height-24),withAttributes:labelAttrs)
            let trash = deleteRect(cardSize:NSSize(width:width,height:height)), done = doneRect(cardSize:NSSize(width:width,height:height))
            var right = done.minX-8
            if let at = note.remindAt {
                let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(at) ? "h:mm a" : "EEE h:mm a"
                let clock = "⏰ "+f.string(from:at)
                let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:10,weight:.semibold),.foregroundColor:gold]
                let w = (clock as NSString).size(withAttributes:attrs).width
                let badge = NSRect(x:right-w-10,y:height-27,width:w+10,height:17)
                NSColor(srgbRed:1,green:0.74,blue:0.3,alpha:0.16).setFill(); NSBezierPath(roundedRect:badge,xRadius:8.5,yRadius:8.5).fill()
                (clock as NSString).draw(at:NSPoint(x:badge.minX+5,y:badge.minY+2),withAttributes:attrs)
                right = badge.minX-8
            } else {
                let when = Date().timeIntervalSince(note.updatedAt) < 60 ? "just now" : RelativeDateTimeFormatter().localizedString(for:note.updatedAt,relativeTo:Date())
                let w = (when as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:10)]).width
                (when as NSString).draw(at:NSPoint(x:right-w,y:height-24),withAttributes:[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor(white:1,alpha:0.42)])
            }
            func button(_ rect: NSRect, _ symbol: String, _ tint: NSColor, _ fill: NSColor) {
                fill.setFill(); NSBezierPath(roundedRect:rect,xRadius:6,yRadius:6).fill()
                if let icon = NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:10,weight:.semibold)) {
                    let tinted = NSImage(size:icon.size,flipped:false) { r in icon.draw(in:r); tint.set(); r.fill(using:.sourceAtop); return true }
                    tinted.draw(in:NSRect(x:rect.midX-icon.size.width/2,y:rect.midY-icon.size.height/2,width:icon.size.width,height:icon.size.height))
                }
            }
            button(done,"checkmark",NSColor(srgbRed:0.55,green:0.9,blue:0.6,alpha:1),NSColor(srgbRed:0.4,green:0.85,blue:0.5,alpha:0.16))
            button(trash,"trash",NSColor(srgbRed:1,green:0.5,blue:0.47,alpha:1),NSColor(srgbRed:1,green:0.4,blue:0.38,alpha:0.16))
            // Body, line by line; checklist lines get a tickable box.
            let top = height-42
            for line in layout.lines {
                let frame = NSRect(x:18,y:top-line.rect.maxY,width:line.rect.width,height:line.rect.height)
                var attrs: [NSAttributedString.Key:Any] = [.font:bodyFont,.foregroundColor:ink,.paragraphStyle:bodyStyle()]
                var textFrame = frame
                if let checked = line.box {
                    let box = NSRect(x:frame.minX,y:frame.maxY-15,width:13,height:13)
                    let path = NSBezierPath(roundedRect:box,xRadius:3,yRadius:3)
                    if checked { gold.withAlphaComponent(0.85).setFill(); path.fill() }
                    gold.withAlphaComponent(0.8).setStroke(); path.lineWidth = 1; path.stroke()
                    if checked {
                        let tick = NSBezierPath(); tick.move(to:NSPoint(x:box.minX+3,y:box.midY)); tick.line(to:NSPoint(x:box.minX+5.6,y:box.minY+3.2)); tick.line(to:NSPoint(x:box.maxX-2.6,y:box.maxY-3))
                        NSColor(white:0.08,alpha:1).setStroke(); tick.lineWidth = 1.6; tick.lineCapStyle = .round; tick.stroke()
                        attrs[.foregroundColor] = ink.withAlphaComponent(0.45); attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    }
                    textFrame = NSRect(x:frame.minX+20,y:frame.minY,width:frame.width-20,height:frame.height)
                }
                (line.text as NSString).draw(with:textFrame,options:[.usesLineFragmentOrigin,.truncatesLastVisibleLine],attributes:attrs)
            }
            let line = NSBezierPath(); line.move(to:NSPoint(x:18,y:27)); line.line(to:NSPoint(x:width-18,y:27))
            NSColor(white:1,alpha:0.08).setStroke(); line.lineWidth = 0.5; line.stroke()
            let help = layout.lines.contains { $0.box != nil } ? "Click a box to tick it · elsewhere to edit" : "Click to edit"
            (help as NSString).draw(in:NSRect(x:18,y:10,width:width-36,height:12),withAttributes:[.font:NSFont.systemFont(ofSize:9.5),.foregroundColor:NSColor(white:1,alpha:0.4)])
        }
    }

    /// The checklist line whose box is at `local` (card coordinates), if any.
    static func checkbox(at local: CGPoint, note: SilkNote, cardSize: CGSize) -> Int? {
        let top = cardSize.height-42
        for line in bodyLines(note).lines where line.box != nil {
            let frame = NSRect(x:18,y:top-line.rect.maxY,width:line.rect.width,height:line.rect.height)
            if NSRect(x:frame.minX-4,y:frame.maxY-19,width:22,height:21).contains(local) { return line.index }
        }
        return nil
    }

    /// Dark, slightly worn fragment with a tiny puncture where the silk passes through.
    private static func fragment(_ r: NSRect) {
        let path = NSBezierPath()
        path.move(to:NSPoint(x:r.minX+3,y:r.maxY))
        path.line(to:NSPoint(x:r.maxX-3,y:r.maxY))
        path.curve(to:NSPoint(x:r.maxX,y:r.maxY-3),controlPoint1:NSPoint(x:r.maxX-1,y:r.maxY),controlPoint2:NSPoint(x:r.maxX,y:r.maxY-1))
        path.line(to:NSPoint(x:r.maxX-0.6,y:r.minY+2.5))
        // Softly irregular lower edge.
        let steps = max(4,Int(r.width/14))
        for i in stride(from:steps,through:0,by:-1) {
            let px = r.minX+r.width*CGFloat(i)/CGFloat(steps)
            path.line(to:NSPoint(x:px,y:r.minY+(i % 2 == 0 ? 0 : 1.2)))
        }
        path.line(to:NSPoint(x:r.minX,y:r.maxY-3))
        path.curve(to:NSPoint(x:r.minX+3,y:r.maxY),controlPoint1:NSPoint(x:r.minX,y:r.maxY-1),controlPoint2:NSPoint(x:r.minX+1,y:r.maxY))
        path.close()
        body.setFill(); path.fill()
        NSColor(white:1,alpha:0.12).setStroke(); path.lineWidth = 0.5; path.stroke()
        // Puncture.
        NSColor(white:0,alpha:0.55).setFill()
        NSBezierPath(ovalIn:NSRect(x:r.midX-1.4,y:r.maxY-4.6,width:2.8,height:2.8)).fill()
    }
}

/// A tiny drawn spider (gold legs, dark glossy body) used where a plain silk dot used to be:
/// on note threads and at the nest knot. Head points up the thread it hangs from.
enum MiniSpider {
    static let image: NSImage = draw(size:22)
    /// Same spider with its legs shifted a little: alternated briefly for a leg twitch.
    static let twitch: NSImage = draw(size:22,twitch:true)

    static func draw(size s: CGFloat, twitch: Bool = false) -> NSImage {
        ItemPreview.draw(NSSize(width:s,height:s)) { r in
            let c = NSPoint(x:r.midX,y:r.midY)
            let gold = NSColor(srgbRed:1.0,green:0.72,blue:0.22,alpha:0.95)
            let k = s/22
            // Legs: four per side, the front pairs reaching up, the back pairs reaching down.
            let legs: [(CGFloat,CGFloat,CGFloat,CGFloat)] = [(2.2,2.6,6.5,8.5),(2.6,1.2,8.2,3.2),(2.6,-0.6,8.2,-2.6),(2.2,-2.0,6.6,-7.6)]
            for side: CGFloat in [-1,1] {
                for (n,(hx,hy,fx,fy)) in legs.enumerated() {
                    let hip = NSPoint(x:c.x+side*hx*k,y:c.y+hy*k)
                    let flick: CGFloat = twitch ? (n % 2 == 0 ? 1.1 : -0.9)*side : 0
                    let foot = NSPoint(x:c.x+side*fx*k+flick*0.4*k,y:c.y+fy*k+flick*k)
                    let knee = NSPoint(x:(hip.x+foot.x)/2+side*1.6*k,y:(hip.y+foot.y)/2+1.8*k)
                    let leg = NSBezierPath(); leg.move(to:hip); leg.line(to:knee); leg.line(to:foot)
                    leg.lineWidth = 1.05*k; leg.lineCapStyle = .round; leg.lineJoinStyle = .round
                    gold.setStroke(); leg.stroke()
                }
            }
            // Body: abdomen below, cephalothorax above, with a thin gold rim like the big spider.
            let abdomen = NSBezierPath(ovalIn:NSRect(x:c.x-3.4*k,y:c.y-6.8*k,width:6.8*k,height:7.6*k))
            let head = NSBezierPath(ovalIn:NSRect(x:c.x-2.6*k,y:c.y-0.6*k,width:5.2*k,height:5*k))
            NSColor(srgbRed:0.06,green:0.055,blue:0.05,alpha:1).setFill()
            abdomen.fill(); head.fill()
            gold.withAlphaComponent(0.8).setStroke()
            abdomen.lineWidth = 0.55*k; head.lineWidth = 0.55*k; abdomen.stroke(); head.stroke()
            // A glint on the abdomen.
            NSColor(white:1,alpha:0.35).setFill()
            NSBezierPath(ovalIn:NSRect(x:c.x-1.6*k,y:c.y-3.2*k,width:1.6*k,height:1.4*k)).fill()
            // Deep red eyes with a bright dot, like the big spider.
            for side: CGFloat in [-1,1] {
                NSColor(srgbRed:0.75,green:0.05,blue:0.06,alpha:1).setFill()
                NSBezierPath(ovalIn:NSRect(x:c.x+side*1.1*k-0.75*k,y:c.y+2.6*k,width:1.5*k,height:1.5*k)).fill()
                NSColor(white:1,alpha:0.9).setFill()
                NSBezierPath(ovalIn:NSRect(x:c.x+side*1.1*k-0.45*k,y:c.y+3.25*k,width:0.5*k,height:0.5*k)).fill()
            }
        }
    }
}
