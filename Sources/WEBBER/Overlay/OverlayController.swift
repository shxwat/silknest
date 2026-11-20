import AppKit
import SceneKit
import QuartzCore
import simd

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Product-level experience state. Spider locomotion (SpiderMotion), capture (CatchSequence) and
/// storage (ClipboardController) keep their own state; this is derived from them, never mixed in.
enum ExperienceState: String {
    case roam, nestOpening, nestActive, nestClosing
}

/// Owns the transparent desktop panels and routes commands between the spider, the clipboard and the webs.
/// Every panel is click-through except exactly where the spider, an object, or a silk menu node is.
final class OverlayController {
    /// Non-Retina displays need more samples: thin glowing legs otherwise shimmer pixel to pixel.
    static func antialiasing(for screen: NSScreen) -> SCNAntialiasingMode { screen.backingScaleFactor < 1.5 ? .multisampling8X : .multisampling4X }
    private(set) var space: OverlaySpace
    /// The display the Nest opens on: the one with the pointer, which need not be the spider's.
    private(set) var nestSpace: OverlaySpace
    private(set) var renderer: SpiderRenderer
    let motion: SpiderMotion
    /// The NEST: the large physical web. Hidden in ROAM; it only exists on screen while opened.
    let web: PhysicalWeb
    let clipboard = ClipboardController()
    let panel: OverlayPanel
    let receiver: OverlayPanel
    let dropView: SpiderDropView
    let webPanel: OverlayPanel
    let webInteractionPanel: OverlayPanel
    /// Dark frosted glass behind the opened Nest (a rounded pane, not the whole screen), so the web and
    /// its objects read over any window while the rest of the desktop stays visible.
    private let nestBackdrop: OverlayPanel
    let webInteractionView: WebInteractionView
    let nestMarker: NestMarker
    /// The spider's render view. Replaced by an unattached placeholder while the spider is hidden, so its
    /// GPU resources are released; rebuilt when it is shown again.
    private var sceneView: SpiderSurface
    private let webView: ClearSceneView
    private let effects: SilkEffectsLayer
    private let sequence: CatchSequence
    let menu = SilkRadialMenu()
    /// Silk Notes hanging along the top edge of each display.
    lazy var notes = NotesController(menu:menu,store:DevFlags.has("--automation")
        ? NoteStore(file:FileManager.default.temporaryDirectory.appendingPathComponent("webber-automation-notes.enc"))
        : NoteStore())
    private var notesBusy = false
    let shortcuts = ShortcutManager()
    private var displayLink: DisplayLinkProxy?
    /// The spider's surface needs one more draw (a new tile, camera, or a draw that found no drawable).
    private var surfaceDirty = true
    private var renderRateNow = 0
    /// Development stats: frames drawn and the longest gap between two drawn frames while drawing.
    private var drawStats = (frames:0,longestGap:0.0,last:0.0)
    private var watchdog: Timer?
    private var lastPoseTime: CFTimeInterval = 0
    private var lastWebChange: CFTimeInterval = 0
    private var lastEngaged: CFTimeInterval = 0
    let nestKeys = NestKeyboard()
    /// Which page of the (filtered) history hangs in the open Nest, and the scroll gesture turning it.
    var nestPage = 0
    var nestScroll: CGFloat = 0, nestScrollTime: CFTimeInterval = 0, nestScrollUsed = false
    /// Development measurements (scripts/perf.sh): Nest open latency, last search, history load.
    var perf = (nestOpenStart: 0.0, nestOpenMs: -1.0, searchMs: -1.0, searchComputeMs: -1.0, historyLoadMs: -1.0)
    /// Search runs here while typing; results from an older query are dropped.
    let searchQueue = DispatchQueue(label:"studio.webber.search",qos:.userInitiated)
    var searchGeneration = 0
    /// The current (filtered, ordered) Nest results as ids, and the page shown from them.
    var nestResults: [Int] = []
    /// Silk Notes found by the Nest search, as transient items (never stored in the history).
    var nestNoteItems: [Int: ClipboardItem] = [:]
    func nestItem(_ id: Int) -> ClipboardItem? { clipboard.items.first { $0.id == id } ?? nestNoteItems[id] }
    /// Development only (perf runs while the Mac is in use): clicks elsewhere don't close the Nest.
    var ignoreOutsideClicks = false
    /// Spider moments: recent catch times (frenzy), the last activity (sleep), Reduce Motion.
    var recentCatches: [CFTimeInterval] = [], frenzyToken = 0
    var lastActivity: CFTimeInterval = 0
    private var reduceMotionObserver: Any?
    /// Screen point the open Nest was launched from.
    var nestLaunch = NSPoint.zero
    /// Secret reaction timing (CACurrentMediaTime): no red while catching it, then the shield.
    var secretCatchUntil: CFTimeInterval = 0, shieldFrom: CFTimeInterval = 0, shieldUntil: CFTimeInterval = 0
    /// Development only: open the Nest on the spider's display regardless of the pointer (stable perf runs).
    var nestFollowsSpider = false
    /// The app the user was in when the Nest opened: where ↩ pastes.
    var nestTarget: NSRunningApplication?
    var askedPastePermission = false
    let hoverPreview = HoverPreview()
    let itemCard = ItemCard()
    /// Verification only: keep an automation-shown preview up.
    private var previewPinned = false
    let screenshots = ScreenshotWatcher()
    private var nestOutsideMonitor: Any?
    private var pointerMonitors: [Any] = []
    private var engagedNear = false
    /// Development only (automation "pointer:off"): measurements ignore the real pointer.
    private var ignorePointer = false
    private var traceLeft = 0
    private var trace: [String] = []
    private var screenObserver: Any?
    /// Pointer offset from the spider's centre while it is being carried.
    private var grabOffset = NSPoint.zero
    /// Small territory around its resting spot: it shifts a little, it does not tour the screen.
    private let patrolOffsets: [V3] = [V3(-70,-4,0),V3(0,0,0),V3(-10,80,0),V3(0,0,0),V3(-110,10,0),V3(0,0,0)]
    private var pointerLingerTime: Float = 0
    private var lastTime = CACurrentMediaTime()
    private let dragAwareness = NativeDragAwareness()
    private let verification: OverlayVerification?
    private var nativeDragActive = false
    private var webCheckStarted = false
    private var webPanelShown = false
    var reactionTime: Float = 0
    private var autoPatrolBeforeNest = true
    private var lastCatchTime: CFTimeInterval = 0
    /// Development frame-timing stats: frames, longest gap, and gaps over 1.5× the median interval.
    private var frameStats = (count: 0, longest: 0.0, late: 0, tickCost: 0.0)
    private var slowTicks = 0, tickTotal = 0.0
    var visible = true { didSet { applyVisibility() } }
    /// Hunt mode: every new copy (keyboard, menu or mouse; text, images, files) is caught automatically.
    var huntMode: Bool {
        // On by default: every normal Cmd+C is caught (encrypted history; password-manager copies skipped).
        get { UserDefaults.standard.object(forKey:"huntMode.v2") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue,forKey:"huntMode.v2"); onStateChange?() }
    }
    private var lastHuntCheck: CFTimeInterval = 0
    /// Verification runs (--automation) use a throwaway folder so test items never enter the user's history.
    let history = DevFlags.has("--automation")
        ? HistoryStore(folder:FileManager.default.temporaryDirectory.appendingPathComponent("webber-automation-history"))
        : HistoryStore()
    /// Paste Stack: queued objects; each Cmd+V pastes the next one.
    var stack = PasteStack()
    var persistScheduled = false
    let stackMarker: StackMarker
    /// The plain clipboard list (secondary to the Nest: hold ⇧⌘Space).
    /// Remember caught objects across restarts (local only).
    var rememberHistory: Bool {
        get { UserDefaults.standard.object(forKey:"rememberHistory") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue,forKey:"rememberHistory")
            if newValue { persist(); return }
            // Content kept on disk comes back into memory before the saved history is deleted.
            for item in clipboard.items { item.keepInMemory() }
            history.clear()
        }
    }
    /// Off by default: choosing an item copies it (Cmd+V works, no permission). Turning this on asks for
    /// Accessibility once, so WEBBER can also press Cmd+V for you.
    var menuPatrolHold: Bool?
    var pasteOnSelect: Bool {
        get { UserDefaults.standard.object(forKey:"pasteOnSelect.v2") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue,forKey:"pasteOnSelect.v2") }
    }
    /// Development harness only (--study); a production click opens the silk menu instead.
    var onStudy: (() -> Void)?
    var onStateChange: (() -> Void)?

    /// The chosen spider (look, size, gait). Same behaviour and features for every species.
    private(set) var species = OverlayController.startSpecies()
    /// The saved spider; development builds can draw it larger for close-up recordings (WEBBER_SCALE).
    private static func startSpecies() -> SpiderSpecies {
        let saved = SpiderSpecies.named(UserDefaults.standard.string(forKey:"species"))
        guard let factor = DevFlags.env("WEBBER_SCALE").flatMap(Double.init), factor > 0 else { return saved }
        return saved.scaled(CGFloat(factor))
    }
    var spiderScale: CGFloat { species.scale }
    /// Darting hunter tempo: bursts of speed with a rapid, light gait (feet still never slide).
    /// Click target around the body, sized to the chosen spider.
    private var clickRadius: CGFloat { 46*spiderScale/1.25 }

    init(screen: NSScreen) {
        let species = Self.startSpecies()
        space = OverlaySpace(screen:screen,spiderScale:species.scale)
        nestSpace = space
        let bounds = space.motionBounds
        motion = SpiderMotion(bounds:bounds,position:V3(Float(bounds.maxX)-120,Float(bounds.minY)+110,0))
        verification = OverlayVerification(motion:motion)
        // Desktop tempo: a quick, purposeful house spider. Shorter, faster steps keep feet planted at speed.
        motion.cruiseSpeed = species.speed; motion.acceleration = species.acceleration; motion.gaitTempo = species.gaitTempo
        // ROAM: the spider keeps to the edges near its nest corner, out of the way of real work.
        let corner = V3(Float(bounds.maxX)-110,Float(bounds.minY)+105,0)
        // Mostly still: rests 30–60 s between small, purposeful moves near its spot.
        motion.wanderPause = 30; motion.wanderJitter = 30
        motion.rest(for:25)
        motion.patrolStops = [V3(-70,-4,0),V3(0,0,0),V3(-10,80,0),V3(0,0,0),V3(-110,10,0),V3(0,0,0)].map { [motion] in motion.constrain(corner+$0) }

        web = PhysicalWeb(compactSize:space.compactWebSize,expandedBounds:space.expandedWebBounds)
        nestBackdrop = Self.makePanel(frame:space.nestScreenFrame)
        // The glass takes clicks and scrolling, so a click inside the Nest never falls through to the app
        // underneath (which would also close the Nest). Only clicks outside the pane put it away.
        nestBackdrop.ignoresMouseEvents = false; nestBackdrop.alphaValue = 0
        let glass = Self.nestGlass(size:space.nestScreenFrame.size)
        nestBackdrop.contentView = glass
        webPanel = Self.makePanel(frame:space.compactWebScreenFrame)
        webPanel.ignoresMouseEvents = true
        webView = ClearSceneView(frame:NSRect(origin:.zero,size:space.compactWebSize))
        webView.scene = web.scene; webView.pointOfView = web.camera; webView.backgroundColor = .clear; webView.rendersContinuously = false
        webView.autoresizingMask = [.width,.height]
        // The Nest's view joins its window only while the Nest is open (see showWebPanel).
        webPanel.contentView = NSView(frame:NSRect(x:0,y:0,width:1,height:1))

        renderer = SpiderRenderer(size:screen.frame.size,species:species)
        // Keep the desktop panel fixed for planted feet, but allocate GPU buffers only for the
        // spider's territory. The camera preserves the original 1 unit = spiderScale points mapping.
        let renderSize = screen.frame.size
        let renderFrame = SpiderRenderViewport.compact(around:space.desk(motion:motion.position),
            in:CGRect(origin:.zero,size:renderSize),scale:species.scale,backingScale:screen.backingScaleFactor)
        let renderCamera = SpiderRenderViewport.camera(for:renderFrame,in:CGRect(origin:.zero,size:renderSize),scale:species.scale)
        renderer.camera.camera?.orthographicScale = renderCamera.extent
        renderer.camera.camera?.projectionTransform = renderCamera.projection
        renderer.camera.simdPosition = renderCamera.position
        panel = Self.makePanel(frame:screen.frame)
        panel.ignoresMouseEvents = true
        sceneView = SpiderSurface(frame:renderFrame)
        sceneView.scene = renderer.scene; sceneView.pointOfView = renderer.camera
        sceneView.warmUp()
        switch DevFlags.env("WEBBER_MSAA") {
        case "0": sceneView.setSamples(for:.none)
        case "2": sceneView.setSamples(for:.multisampling2X)
        default: sceneView.setSamples(for:Self.antialiasing(for:screen))
        }
        let renderHost = NSView(frame:NSRect(origin:.zero,size:renderSize))
        renderHost.layer = CALayer(); renderHost.wantsLayer = true
        renderHost.layer?.backgroundColor = NSColor.clear.cgColor
        renderHost.addSubview(sceneView)
        panel.contentView = renderHost
        panel.level = NSWindow.Level(rawValue:webPanel.level.rawValue+2)

        webInteractionPanel = Self.makePanel(frame:space.visibleScreenFrame)
        webInteractionPanel.level = NSWindow.Level(rawValue:webPanel.level.rawValue+1)
        webInteractionPanel.ignoresMouseEvents = true
        webInteractionView = WebInteractionView(frame:NSRect(origin:.zero,size:space.visibleScreenFrame.size),web:web)
        webInteractionPanel.contentView = webInteractionView

        receiver = Self.makePanel(frame:NSRect(x:0,y:0,width:180,height:180))
        receiver.level = NSWindow.Level(rawValue:panel.level.rawValue+1)
        dropView = SpiderDropView(frame:NSRect(x:0,y:0,width:180,height:180))
        dropView.autoresizingMask = [.width,.height]
        receiver.contentView = dropView

        nestMarker = NestMarker(screen:screen,level:NSWindow.Level(rawValue:webPanel.level.rawValue-1))
        stackMarker = StackMarker(screen:screen,level:NSWindow.Level(rawValue:webPanel.level.rawValue-1))
        effects = SilkEffectsLayer(screen:screen,level:NSWindow.Level(rawValue:panel.level.rawValue+3))
        sequence = CatchSequence(motion:motion,renderer:renderer,effects:effects,space:space)
        web.tether = nestSpace.web(screen:nestMarker.knot)
        glass.onScroll = { [weak self] e in self?.scrollNest(e) }
        glass.onClick = { [weak self] in
            guard let self else { return }
            if self.itemCard.isOpen { self.itemCard.close() } else if self.menu.isOpen { self.menu.close() }
        }
        history.onPersisted = { item, files, loader in item.offload(files:files,loader:loader) }
        wire()
        restoreHistory()
        showWelcomeIfNeeded()
        followReduceMotion()
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil,queue:.main) { [weak self] _ in self?.followReduceMotion() }
        screenshots.onScreenshot = { [weak self] url in self?.catchScreenshot(url) }
        screenshots.onFolderDenied = { [weak self] folder in self?.askForScreenshotFolderAccess(folder) }
        if !DevFlags.has("--automation") { ScreenshotPreview.applyAtLaunch() }
        screenshots.start()
        tick()
        applyVisibility()
        // Frame loop on the display's own vsync (up to 120 Hz on ProMotion), not a free-running timer.
        displayLink = DisplayLinkProxy(view:sceneView) { [weak self] in self?.tick() }
        // Hit areas (spider, note knots, Nest objects) follow the pointer on every move, not on the next
        // frame-loop tick: an idle loop runs at 10 Hz, and a click inside that gap would fall through to
        // the app underneath (e.g. switching a browser tab instead of grabbing a note).
        let onMove: (NSEvent) -> Void = { [weak self] _ in
            if self?.ignorePointer == true { return }
            guard let self else { return }
            let since = CACurrentMediaTime()-self.lastTime
            guard since > 0.004 else { return }
            // Resting, with the pointer far from the spider: hit areas still follow within 1/30 s (no click can
            // fall through), but moving the mouse across the screen no longer runs the loop at mouse rate.
            if (self.displayLink?.currentRate ?? 0) <= Self.restRate && since < 1.0/30 {
                let pointer = NSEvent.mouseLocation, spider = self.space.screen(motion:self.motion.position)
                if hypot(pointer.x-spider.x,pointer.y-spider.y) > 360 { return }
            }
            self.tick()
        }
        pointerMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching:[.mouseMoved,.leftMouseDragged],handler:onMove) as Any,
            NSEvent.addLocalMonitorForEvents(matching:[.mouseMoved,.leftMouseDragged]) { onMove($0); return $0 } as Any
        ]
        // Safety net: if the display link ever stops delivering (display asleep, screen change), keep the
        // logic alive at a low rate. It never runs while vsync frames are arriving.
        updateWatchdog()
    }

    deinit {
        for m in pointerMonitors { NSEvent.removeMonitor(m) }
        displayLink?.invalidate(); watchdog?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// Rounded smoked glass with a faint gold silk edge, for the Nest.
    private static func nestGlass(size: NSSize) -> NestGlassView {
        let glass = NestGlassView(frame:NSRect(origin:.zero,size:size))
        glass.material = .hudWindow; glass.blendingMode = .behindWindow; glass.state = .active
        glass.appearance = NSAppearance(named:.darkAqua); glass.autoresizingMask = [.width,.height]
        let radius: CGFloat = 26
        let mask = NSImage(size:NSSize(width:radius*2+1,height:radius*2+1),flipped:false) { rect in
            NSColor.black.setFill(); NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius).fill(); return true
        }
        mask.capInsets = NSEdgeInsets(top:radius,left:radius,bottom:radius,right:radius)
        mask.resizingMode = .stretch
        glass.maskImage = mask
        glass.wantsLayer = true
        let edge = CALayer()
        edge.frame = glass.bounds; edge.autoresizingMask = [.layerWidthSizable,.layerHeightSizable]
        edge.cornerRadius = radius; edge.borderWidth = 1
        edge.borderColor = NSColor(srgbRed:1,green:0.78,blue:0.32,alpha:0.22).cgColor
        glass.layer?.addSublayer(edge)
        return glass
    }

    private static func makePanel(frame: NSRect) -> OverlayPanel {
        let p = OverlayPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.colorSpace = .sRGB
        p.level = .statusBar; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        p.isReleasedWhenClosed = false; p.animationBehavior = .none
        return p
    }

    private func wire() {
        dropView.onHover = { [weak self] p in
            guard let self, !self.sequence.isActive else { return }
            if let p { self.motion.drag(at:self.space.motion(screen:p)) }
            else if !self.nativeDragActive { self.motion.drag(at:nil) }
        }
        dropView.canCatchAt = { [weak self] p in
            guard let self, self.sequence.spiderAvailable else { return false }
            return simd_distance(self.space.motion(screen:p),self.motion.position) < 80
        }
        dropView.onDrop = { [weak self] p,board in self?.acceptDrop(at:p,board:board) ?? false }
        dropView.onClick = { [weak self] clicks in
            guard let self else { return }
            if clicks >= 2 { self.menu.close(animated:false); self.setNestOpen(true) } else { self.showSpiderMenu() }
        }
        // Pick the spider up and put it anywhere: it lifts, legs tuck in, and it lands where released.
        dropView.onGrab = { [weak self] in
            guard let self else { return }
            self.menu.close(animated:false)
            let p = self.space.screen(motion:self.motion.position), m = NSEvent.mouseLocation
            self.grabOffset = NSPoint(x:p.x-m.x,y:p.y-m.y)
            self.motion.pickUp()
        }
        dropView.onCarry = { [weak self] in
            guard let self else { return }
            let m = NSEvent.mouseLocation
            self.motion.hold(at:self.space.motion(screen:NSPoint(x:m.x+self.grabOffset.x,y:m.y+self.grabOffset.y)))
        }
        dropView.onPutDown = { [weak self] in
            guard let self else { return }
            self.motion.drop()
            // Its territory moves with it: patrol around wherever it was put down.
            self.motion.patrolStops = self.patrolOffsets.map { self.motion.constrain(self.motion.position+$0) }
            self.motion.rest(for:40)
        }

        bindWebInteraction()
        screenObserver = NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main) { [weak self] _ in
            self?.screensChanged()
        }
        webInteractionView.item = { [weak self] id in self?.nestItem(id) }
        webInteractionView.onClick = { [weak self] id in self?.showItemMenu(id) }
        webInteractionView.onPullStart = { [weak self] in self?.menu.close() }
        webInteractionView.onScroll = { [weak self] e in self?.scrollNest(e) }
        webInteractionView.onDraggedOut = { [weak self] id in
            guard let self, let clip = self.clipboard.items.first(where: { $0.id == id }) else { return }
            self.clipboard.remove(clip); self.web.discard(id); self.updateNestCount(arrived:false); self.persist()
            self.refreshNestSearch()
        }

        sequence.nestPoint = { [weak self] in self?.nestMarker.knot ?? .zero }
        sequence.onArrive = { [weak self] _ in self?.updateNestCount(arrived:true) }
        itemCard.onClose = { [weak self] in
            guard let self else { return }
            self.web.selectedID = nil
            self.updateModalKeys()
        }
        menu.onClose = { [weak self] in
            guard let self else { return }
            self.web.selectedID = nil
            if let patrol = self.menuPatrolHold { self.motion.autoPatrol = patrol; self.menuPatrolHold = nil }
            self.updateModalKeys()
        }

        _ = applyShortcuts()
    }

    /// Global shortcuts currently held, per action (user-customisable in Settings).
    /// What is actually registered per action (may be a fallback when macOS already uses the default).
    private(set) var activeShortcuts: [ShortcutAction: Shortcut] = [:]
    var lastShortcutFailures: [String] = []
    var onOpenSettings: (() -> Void)?

    /// (Re)registers the user's shortcuts. Returns the actions whose shortcut could not be registered.
    @discardableResult func applyShortcuts() -> Set<ShortcutAction> {
        for s in activeShortcuts.values { shortcuts.unregister(s) }
        activeShortcuts = [:]
        var failed = Set<ShortcutAction>()
        for action in ShortcutAction.allCases {
            guard let preferred = action.shortcut else { continue }
            // The chosen/default shortcut first; if macOS already owns it here, the first free fallback.
            let candidates = [preferred]+(action.isCustomized ? [] : action.fallbacks)
            var registered = false
            for s in candidates where !activeShortcuts.values.contains(s) && !s.systemConflict {
                let release: (() -> Void)? = action == .clipboardHistory ? { [weak self] in self?.historyKeyUp() } : nil
                let ok = shortcuts.register(s,onRelease:release) { [weak self] in
                    guard let self else { return }
                    switch action {
                    case .clipboardHistory: self.historyKeyDown()
                    case .catchCopy: self.catchClipboard()
                    case .newNote: self.notes.compose()
                    case .toggleNotes: self.notes.toggleHidden()
                    case .addToStack: self.addNewestToStack()
                    }
                }
                if ok { activeShortcuts[action] = s; registered = true; break }
            }
            if !registered { failed.insert(action) }
        }
        return failed
    }

    var experience: ExperienceState {
        if web.isOpen { return web.expansion < 0.98 ? .nestOpening : .nestActive }
        if web.isExpandedAtAll { return .nestClosing }
        return .roam
    }

    // MARK: commands

    /// Catch Copy (Cmd+Shift+C or the spider's silk menu). Reads the pasteboard once and stores the item
    /// immediately; the animation that follows is feedback only and never blocks.
    func catchClipboard() {
        if !visible { visible = true }
        guard !motion.paused else { return }
        let pointer = NSEvent.mouseLocation
        switch clipboard.catchCurrent() {
        case .caught(let item) where clipboard.existing(item) != nil:
            if let old = clipboard.existing(item) { clipboard.promote(old); web.acknowledge(old.id) }
            sequence.glance(toward:pointer)
        case .caught(let item):
            let source = NSWorkspace.shared.frontmostApplication
            item.sourceName = source?.localizedName; item.sourceBundleID = source?.bundleIdentifier
            guard store(item) else { sequence.glance(toward:pointer); return }
            sequence.start(item,from:catchSource(),mode:catchMode(pointer:pointer))
            lastCatchTime = CACurrentMediaTime(); noteCatch()
            refreshNestSearch()
        case .alreadyCaught, .empty, .concealed: sequence.glance(toward:pointer)
        }
    }

    /// Full theatre only when the user is near the spider and nothing else is happening.
    private func catchMode(pointer: NSPoint) -> CatchSequence.Mode {
        let spider = space.screen(motion:motion.position)
        let near = hypot(pointer.x-spider.x,pointer.y-spider.y) < 520
        let rapid = CACurrentMediaTime()-lastCatchTime < 3
        if sequence.isActive || rapid || !sequence.spiderAvailable || motion.reduceMotion { return .snap }
        if near && !web.isOpen && motion.state != .crawling { return .rich }
        return .fast
    }

    private func store(_ item: ClipboardItem) -> Bool {
        let result = clipboard.store(item)
        guard result.stored else { return false }
        if let released = result.released { web.release(released.id) }
        // The Nest hangs one page of the history; it is filled when opened (or refreshed if open now).
        // A new image reaches the disk only after its text was read and checked for secrets.
        if item.kind == .image && item.recognizedText == nil { item.awaitingOCR = true }
        recognizeText(item)
        persist()
        if item.isSecret { protectSecret(item) }
        return true
    }

    // MARK: spider moments

    /// Feeding frenzy: three catches within four seconds → a tiny happy wiggle once the burst is over.
    func noteCatch() {
        let now = CACurrentMediaTime()
        lastActivity = now
        if motion.asleep { motion.wake(jolt:true) }
        recentCatches = recentCatches.filter { now-$0 < 4 }+[now]
        guard recentCatches.count >= 3 else { return }
        frenzyToken += 1
        let token = frenzyToken
        frenzyWiggle(token:token,after:1.4,tries:12)
    }

    /// The wiggle waits until the spider has carried the burst home (checked every half second, for a while).
    private func frenzyWiggle(token: Int, after delay: Double, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline:.now()+delay) { [weak self] in
            guard let self, token == self.frenzyToken else { return }
            if self.sequence.isActive || self.motion.state != .idle {
                if tries > 0 { self.frenzyWiggle(token:token,after:0.5,tries:tries-1) }
                return
            }
            self.recentCatches = []
            self.motion.happyWiggle()
        }
    }

    /// Sleep after a long quiet spell (no copies, no pointer near, nothing open); the pointer coming
    /// near wakes it gently, a copy with a jolt (noteCatch).
    private func updateSleep(now: CFTimeInterval) {
        if lastActivity == 0 { lastActivity = now }
        if engagedNear || web.isOpen || menu.isOpen || dropView.isPressed || motion.dragActive {
            lastActivity = now
            if motion.asleep { motion.wake(jolt:false) }
        } else if !motion.asleep && !motion.paused && now-lastActivity > Self.sleepAfter && motion.state == .idle {
            motion.fallAsleep()
        }
    }
    static let sleepAfter: CFTimeInterval = 10*60

    private func followReduceMotion() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        motion.reduceMotion = reduce; sequence.reduceMotion = reduce
    }

    /// A caught secret: the spider covers its eyes once the catch has landed, and the secret leaves the
    /// Nest after two minutes (unless pinned; it is never written to disk either way).
    func protectSecret(_ item: ClipboardItem) {
        // "I'm not looking": no red hunt glow; once the catch lands, the glow dims to a cool shield while
        // the spider covers its eyes.
        let now = CACurrentMediaTime()
        secretCatchUntil = now+2.4; shieldFrom = now+0.9; shieldUntil = now+2.9
        DispatchQueue.main.asyncAfter(deadline:.now()+1.1) { [weak self] in
            guard let self, self.visible, !self.motion.paused else { return }
            self.motion.coverEyes()
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+SecretGuard.secretLifetime) { [weak self, weak item] in
            guard let self, let item, !item.pinned, self.clipboard.items.contains(where: { $0 === item }) else { return }
            self.removeItem(item.id)
        }
    }

    /// Newest first.
    var recentItems: [ClipboardItem] { clipboard.items.reversed() }

    /// The one shortcut: opens the Nest, or puts it away.
    func historyKeyDown() { setNestOpen(!web.isOpen) }
    func historyKeyUp() {}

    func setNestOpen(_ open: Bool) {
        guard open != web.isOpen else { return }
        if open && !visible { visible = true }
        menu.close(animated:false)
        if open {
            // Open where the user is looking: the display with the pointer, even if the spider is elsewhere.
            if let target = pointerScreen ?? NSScreen.screens.first(where: { $0.frame == space.screenFrame }),
               target.frame != nestSpace.screenFrame || target.visibleFrame != nestSpace.visibleScreenFrame { layoutNest(on:target) }
            // Silk shot: on the spider's display the spider shoots a thread and the Nest unfolds from it;
            // elsewhere it comes from that display's nest corner.
            if nestSpace.screenFrame == space.screenFrame && visible {
                let mouth = space.screen(motion:motion.world(V3(0,24,0)))
                nestLaunch = mouth
                web.launch(from:nestSpace.web(screen:mouth)); web.tether = nestSpace.web(screen:mouth)
            } else {
                nestLaunch = NestMarker.knot(onVisibleFrame:nestSpace.visibleScreenFrame)
                web.launch(from:PhysicalWeb.cornerHub); web.tether = nestSpace.web(screen:nestLaunch)
            }
            showWebPanel(true)
            autoPatrolBeforeNest = motion.autoPatrol
            motion.autoPatrol = false
            // The spider reacts: a quick look toward the nest it is about to spread.
            if sequence.spiderAvailable {
                motion.notice(motionPoint(web:web.geometry.expandedHub)); reactionTime = 0.55
            }
        } else { motion.autoPatrol = autoPatrolBeforeNest }
        if let nestOutsideMonitor { NSEvent.removeMonitor(nestOutsideMonitor); self.nestOutsideMonitor = nil }
        if open {
            // The frosted Nest covers the screen: a click on anything else puts it away, so the desktop
            // underneath is never left unusable.
            nestOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] _ in
                guard let self, !self.ignoreOutsideClicks, !self.menu.isOpen, !self.itemCard.isOpen, CACurrentMediaTime()-self.itemCard.closedAt > 0.25 else { return }
                self.setNestOpen(false)
            }
        }
        if open { perf.nestOpenStart = CACurrentMediaTime(); perf.nestOpenMs = -1 }
        web.setOpen(open)
        if open { beginNestKeyboard() } else { endNestKeyboard() }
        updateModalKeys()
        onStateChange?()
    }

    /// Small and unobtrusive while nobody is using it; grows smoothly to full size the moment the user
    /// comes near, clicks, drags, catches, or opens a web — and shrinks back after a few quiet seconds.
    static let restingScale: Float = 0.6
    /// Development (recordings): never relax to the resting size.
    private var stayFullSize = false
    private func updateSize(dt: Float, cursor: V3) {
        // Hysteresis: it grows when the pointer comes close, and only counts as left once the pointer is
        // clearly away — so moving around its edge never makes it pulse bigger and smaller.
        let reach = motion.awarenessRadius*(engagedNear ? 1.35 : 0.8)
        let near = simd_distance(cursor,motion.position) < reach
        engagedNear = near
        motion.ambientIdle = near
        let engaged = near || menu.isOpen || dropView.isPressed || motion.state == .held || motion.state == .catching
            || motion.dragActive || nativeDragActive || sequence.isActive || web.isOpen
        let now = CACurrentMediaTime()
        if engaged { lastEngaged = now }
        let target: Float = now-lastEngaged < 2.5 || stayFullSize ? 1 : Self.restingScale
        // Grow quickly (it noticed you), shrink slowly (it relaxes).
        let rate: Float = target > motion.bodyScale ? 4.5 : 1.6
        let next = motion.bodyScale+(target-motion.bodyScale)*min(1,dt*rate)
        if abs(next-motion.bodyScale) > 0.0005 { motion.bodyScale = abs(target-next) < 0.002 ? target : next }
    }

    /// Paste straight into the app the user is typing in (WEBBER never takes focus, so it is still frontmost).
    func pasteDirectly(after delay: Double) {
        // Without Accessibility the item is already on the clipboard (Cmd+V works). Never nag here:
        // the Clipboard History footer offers "Enable Paste" for the one-time permission.
        guard PasteAssist.trusted else { return }
        DispatchQueue.main.asyncAfter(deadline:.now()+delay) { PasteAssist.pasteIntoFrontmostApp() }
    }

    /// Nest "Paste": put the item back, fold the Nest away, and paste where the text cursor is.
    func pasteItem(_ id: Int) {
        guard let clip = nestItem(id) else { return }
        clipboard.copyAgain(clip); web.acknowledge(id)
        setNestOpen(false)
        pasteDirectly(after:0.08)
    }

    /// Terminals that copy the moment you select text (iTerm2's default, kitty, WezTerm…).
    static let copyOnSelectApps: Set<String> = ["com.googlecode.iterm2","net.kovidgoyal.kitty","com.github.wez.wezterm",
        "org.alacritty","io.alacritty","dev.warp.Warp-Stable","com.mitchellh.ghostty","co.zeit.hyper"]
    var ignoreSelectionCopies: Bool {
        get { UserDefaults.standard.object(forKey:"ignoreSelectionCopies") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue,forKey:"ignoreSelectionCopies") }
    }

    /// A copy the user meant: ⌘C (a key press just before), a right-click "Copy", or any app that does not
    /// copy merely on selection. Plain selections in copy-on-select terminals are ignored.
    func isIntentionalCopy(from app: NSRunningApplication?) -> Bool {
        // Terminals copy *text* on selection; an image on the clipboard (a ⌃⇧⌘4 screenshot) is always meant.
        if NSPasteboard.general.availableType(from:PasteboardReader.imageTypes) != nil { return true }
        guard ignoreSelectionCopies, let id = app?.bundleIdentifier, Self.copyOnSelectApps.contains(id) else { return true }
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.keyDown)
        let sinceRightClick = CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.rightMouseDown)
        return sinceKey < 1.0 || sinceRightClick < 8
    }

    /// Hunt mode: the pasteboard changed (any app, any input method) → catch it without a shortcut.
    private func hunt(now: CFTimeInterval) {
        guard now-lastHuntCheck > 0.25 else { return }
        lastHuntCheck = now
        armStackPaste()
        guard huntMode else { return }
        let result = clipboard.huntNewCopy { [weak self] app in self?.isIntentionalCopy(from:app) ?? true }
        if let old = result.promoted { web.acknowledge(old.id); refreshNestSearch(); persist(); return }
        guard let item = result.item, !motion.paused else { return }
        catchNew(item,now:now)
    }

    /// A screenshot saved as a file: caught like any copy (Hunt mode only).
    func catchScreenshot(_ url: URL) {
        guard huntMode, !motion.paused else { return }
        // Spotlight can report the file a moment before the screenshot has finished writing it.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { [weak self] in
            guard let self else { return }
            if let item = self.clipboard.screenshot(at:url) { self.catchNew(item,now:CACurrentMediaTime()); return }
            // The file exists but macOS would not let us read it: the folder's access was not allowed.
            if FileManager.default.fileExists(atPath:url.path) && (try? Data(contentsOf:url)) == nil {
                self.askForScreenshotFolderAccess(url.deletingLastPathComponent())
            }
        }
    }

    /// Once: explain why a saved screenshot was not caught and open the exact Settings pane.
    private func askForScreenshotFolderAccess(_ folder: URL) {
        guard !UserDefaults.standard.bool(forKey:"askedScreenshotAccess") else { return }
        UserDefaults.standard.set(true,forKey:"askedScreenshotAccess")
        let center = space.screen(motion:motion.position)
        let toward = atan2(space.screenFrame.midY-center.y,space.screenFrame.midX-center.x)
        menu.open(at:center,toward:toward,actions:[
            SilkAction(title:"I can't see screenshots in \(folder.lastPathComponent)") {},
            SilkAction(title:"Allow access in Settings") {
                if let u = URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") { NSWorkspace.shared.open(u) }
            }
        ],radius:130,clearance:80)
    }

    private func catchNew(_ item: ClipboardItem, now: CFTimeInterval) {
        guard store(item) else { return }
        let pointer = NSEvent.mouseLocation
        // Never theatrical while the user is working: short catches, straight into the nest.
        let mode: CatchSequence.Mode = catchMode(pointer:pointer) == .rich ? .fast : catchMode(pointer:pointer)
        sequence.start(item,from:catchSource(),mode:mode)
        lastCatchTime = now; noteCatch()
        refreshNestSearch()
    }

    func copyAgain(_ id: Int) {
        guard let clip = clipboard.items.first(where: { $0.id == id }) else { return }
        clipboard.copyAgain(clip)
        web.acknowledge(id)
        // A tiny acknowledgement from the spider: a glance toward the object.
        if sequence.spiderAvailable, !sequence.isActive, let item = web.item(id) {
            motion.notice(motionPoint(web:web.objectCenter(item))); reactionTime = 0.45
        }
    }

    func openItem(_ id: Int) {
        guard let clip = clipboard.items.first(where: { $0.id == id }) else { return }
        clipboard.open(clip); web.acknowledge(id)
    }

    func togglePin(_ id: Int) {
        guard let clip = clipboard.items.first(where: { $0.id == id }) else { return }
        clip.pinned.toggle(); web.setPinned(id,clip.pinned)
        persist()
    }

    func removeItem(_ id: Int) {
        guard let clip = clipboard.items.first(where: { $0.id == id }) else { return }
        clipboard.remove(clip); web.release(id); updateNestCount(arrived:false)
        if stack.items.contains(where: { $0.id == id }) { stack.remove(id:id); stackMarker.show(stack.items); onStateChange?() }
        persist()
        refreshNestSearch()
    }

    func setPaused(_ paused: Bool) {
        motion.paused = paused
        onStateChange?()
    }

    func updateNestCount(arrived: Bool) { nestMarker.setCount(clipboard.items.count,arrived:arrived) }

    // MARK: silk menus

    func showSpiderMenu() {
        let center = space.screen(motion:motion.position)
        let toward = atan2(space.screenFrame.midY-center.y,space.screenFrame.midX-center.x)
        // Few, short labels held well clear of the body: Catch Copy only matters when Hunt is off.
        var actions: [SilkAction] = []
        if !huntMode { actions.append(SilkAction(title:"Catch Copy") { [weak self] in self?.catchClipboard() }) }
        actions += [
            SilkAction(title:web.isOpen ? "Close Nest" : "Nest") { [weak self] in guard let self else { return }; self.setNestOpen(!self.web.isOpen) },
            SilkAction(title:huntMode ? "Hunt: On" : "Hunt: Off") { [weak self] in guard let self else { return }; self.huntMode.toggle() },
            SilkAction(title:motion.paused ? "Resume" : "Pause") { [weak self] in guard let self else { return }; self.setPaused(!self.motion.paused) },
            SilkAction(title:"Settings") { [weak self] in self?.onOpenSettings?() },
            SilkAction(title:"Hide") { [weak self] in self?.visible = false; self?.onStateChange?() }
        ]
        if !stack.isEmpty { actions.insert(SilkAction(title:"Clear Stack (\(stack.count))") { [weak self] in self?.clearStack() },at:0) }
        if let study = onStudy { actions.append(SilkAction(title:"Study") { study() }) }
        // The spider stays put while its menu is open, and the strands follow it if it is still moving.
        if menuPatrolHold == nil { menuPatrolHold = motion.autoPatrol; motion.autoPatrol = false }
        menu.open(at:center,toward:toward,actions:actions,radius:122,clearance:78,following:{ [weak self] in
            guard let self else { return center }
            return self.space.screen(motion:self.motion.position)
        })
        updateModalKeys()
    }

    /// Click (or Tab) on a Nest object: its card — the object large, with every action in one row.
    func showItemMenu(_ id: Int) {
        guard let item = web.item(id), let clip = nestItem(id) else { return }
        menu.close(animated:false); hoverPreview.hide()
        web.selectedID = id; web.focusID = id
        let center = nestSpace.screen(web:web.objectCenter(item)), size = web.objectSize(item)
        let anchor = NSRect(x:center.x-size.width/2,y:center.y-size.height/2,width:size.width,height:size.height)
        let target = nestTarget?.localizedName
        var actions = [ItemCard.Action(title:target.map { "Paste in \($0)" } ?? "Paste",key:"↩",destructive:false) { [weak self] in self?.pasteItem(id) }]
        if let noteID = clip.noteID {
            actions.append(.init(title:"Open note",key:nil,destructive:false) { [weak self] in self?.setNestOpen(false); self?.notes.edit(noteID) })
            let others = web.items.filter { $0.id != id && $0.phase == .hanging }.map { o -> NSRect in
                let c = nestSpace.screen(web:web.objectCenter(o)), s = web.objectSize(o)
                return NSRect(x:c.x-s.width/2-10,y:c.y-s.height/2-10,width:s.width+20,height:s.height+20)
            }
            itemCard.open(clip,anchor:anchor,actions:actions,avoid:others); updateModalKeys(); return
        }
        if clip.kind == .image {
            if !(clip.recognizedText ?? "").isEmpty { actions.append(.init(title:"Paste Text",key:"⇧↩",destructive:false) { [weak self] in self?.quickSelect(clip,mode:.text) }) }
        } else if clip.kind != .file {
            // Only when it makes a difference: "Plain" if the copy carried formatting, "Transform" if any
            // transform would change this text.
            if clip.hasRichText { actions.append(.init(title:"Plain",key:"⇧↩",destructive:false) { [weak self] in self?.quickSelect(clip,mode:.plain) }) }
            if let text = plainText(clip), !TextTransform.applicable(to:text).isEmpty {
                actions.append(.init(title:"Transform",key:nil,destructive:false) { [weak self] in DispatchQueue.main.async { self?.showTransformMenu(clip,at:center) } })
            }
        }
        actions.append(.init(title:"Add to Stack",key:"⌘↩",destructive:false) { [weak self] in self?.addToStack(clip,fromNest:true) })
        if (clip.kind == .text || clip.kind == .code), !clip.isSecret, let text = clip.text {
            actions.append(.init(title:"Hang as note",key:nil,destructive:false) { [weak self] in self?.setNestOpen(false); self?.notes.hang(text) })
        }
        actions += [
            .init(title:clip.pinned ? "Unpin" : "Pin",key:nil,destructive:false) { [weak self] in self?.togglePin(id) },
            .init(title:"Open",key:nil,destructive:false) { [weak self] in self?.openItem(id) },
            .init(title:"Remove",key:"⌫",destructive:true) { [weak self] in self?.removeItem(id); self?.refreshNestSearch() }
        ]
        let others = web.items.filter { $0.id != id && $0.phase == .hanging }.map { o -> NSRect in
            let c = nestSpace.screen(web:web.objectCenter(o)), s = web.objectSize(o)
            return NSRect(x:c.x-s.width/2-10,y:c.y-s.height/2-10,width:s.width+20,height:s.height+20)
        }
        itemCard.open(clip,anchor:anchor,actions:actions,avoid:others)
        updateModalKeys()
    }

    /// Esc and Delete are only taken while a web or silk menu is showing.
    private func updateModalKeys() {
        // Esc is taken globally only while the Nest, a silk menu or an item card is showing.
        if web.isOpen || menu.isOpen || itemCard.isOpen {
            if !shortcuts.isRegistered(.escape) {
                shortcuts.register(.escape) { [weak self] in
                    guard let self else { return }
                    if self.itemCard.isOpen { self.itemCard.close() }
                    else if self.menu.isOpen { self.menu.close() }
                    else if !self.nestKeys.query.isEmpty { self.setNestQuery("") }
                    else { self.setNestOpen(false) }
                }
            }
        } else { shortcuts.unregister(.escape) }
        // While the Nest is open its keyboard owns ⌫ (it removes the item whose menu is open, else edits the search).
        if menu.isOpen && web.selectedID != nil && !web.isOpen {
            for key in [Shortcut.delete,.forwardDelete] {
                shortcuts.register(key) { [weak self] in
                    guard let self, let id = self.web.selectedID else { return }
                    self.menu.close(); self.removeItem(id)
                }
            }
        } else if !web.isOpen { shortcuts.unregister(.delete); shortcuts.unregister(.forwardDelete) }
    }

    // MARK: input sources

    /// Where the copy actually happened: the text caret if the app exposes it, else the pointer.
    /// The silk is cast all the way there (only a pointer right on top of the spider falls back to a readable throw).
    func catchSource() -> NSPoint {
        let pointer = PasteAssist.caretRect().map { NSPoint(x:$0.midX,y:$0.midY) } ?? NSEvent.mouseLocation
        let spider = space.screen(motion:motion.position)
        guard hypot(pointer.x-spider.x,pointer.y-spider.y) > 140 else { return richSource(pointer) }
        let screen = NSScreen.screens.first { NSMouseInRect(pointer,$0.frame,false) }?.frame ?? space.screenFrame
        let inset = space.screenFrame.insetBy(dx:30,dy:30)
        // Stay on the spider's display (the silk cannot cross to another monitor).
        return screen == space.screenFrame ? NSPoint(x:min(max(pointer.x,inset.minX),inset.maxX),y:min(max(pointer.y,inset.minY),inset.maxY)) : richSource(pointer)
    }

    /// Where the copied thing "came from" for the full catch: toward the pointer, at a readable distance.
    private func richSource(_ pointer: NSPoint) -> NSPoint {
        let spider = space.screen(motion:motion.position)
        var dx = pointer.x-spider.x, dy = pointer.y-spider.y
        var distance = hypot(dx,dy)
        if distance < 140 {
            dx = space.visibleScreenFrame.midX-spider.x; dy = space.visibleScreenFrame.midY-spider.y
            distance = max(1,hypot(dx,dy))
        }
        let reach = min(max(distance,220),460)
        var p = NSPoint(x:spider.x+dx/distance*reach,y:spider.y+dy/distance*reach)
        let inset = space.visibleScreenFrame.insetBy(dx:50,dy:50)
        p.x = min(max(p.x,inset.minX),inset.maxX); p.y = min(max(p.y,inset.minY),inset.maxY)
        return p
    }

    private func acceptDrop(at point: NSPoint, board: NSPasteboard) -> Bool {
        guard sequence.spiderAvailable, case .caught(let item) = clipboard.catchCurrent(board), store(item) else { return false }
        _ = motion.catchItem(at:space.motion(screen:point))
        sequence.startDropped(item,at:point)
        lastCatchTime = CACurrentMediaTime(); noteCatch()
        return true
    }

    // MARK: frame loop

    /// The resting loop: only the clipboard check (every 0.25 s) and clocks need it. Pointer moves wake the
    /// loop on their own (the mouse monitors call tick), so the spider still notices you at once.
    static let restRate: Float = 4

    private static let movingStates: Set<SpiderState> = [.anticipating,.crawling,.turning,.alert,.orienting,.tracking,.catching,.settling,.held]

    private func setRenderViewport(_ rect: CGRect) {
        guard rect != sceneView.frame else { return }
        let camera = SpiderRenderViewport.camera(for:rect,in:CGRect(origin:.zero,size:space.screenFrame.size),scale:spiderScale)
        applyCamera(camera)
        sceneView.frame = rect
        renderer.forceNextRender(); surfaceDirty = true
    }

    private func updateRenderViewport(now: CFTimeInterval) {
        let display = CGRect(origin:.zero,size:space.screenFrame.size)
        let point = space.desk(motion:motion.position)
        // Dragging can cross the whole display in one event; expand before showing that pose.
        // Walking, the small tile simply re-centres on the spider when it nears an edge (same size, so no
        // buffers are reallocated): a full-display surface would cost ~10× the memory and fill rate.
        let required = SpiderRenderViewport.required(around:point,in:display,scale:spiderScale)
        let backing = panel.screen?.backingScaleFactor ?? 2
        if motion.state == .held {
            if sceneView.frame != display { setRenderViewport(display) }
        } else if !sceneView.frame.contains(required) || (sceneView.frame == display && !sequence.isActive && now-lastPoseTime > 0.5) {
            setRenderViewport(SpiderRenderViewport.compact(around:point,in:display,scale:spiderScale,backingScale:backing))
        }
    }

    /// The fallback protects vsync delivery; the idle run-loop timer already drives itself reliably.
    private func updateWatchdog() {
        guard (displayLink?.currentRate ?? 120) > Self.restRate else {
            watchdog?.invalidate(); watchdog = nil; return
        }
        guard watchdog == nil else { return }
        watchdog = Timer(timeInterval:1.0/20,repeats:true) { [weak self] _ in
            guard let self, CACurrentMediaTime()-self.lastTime > 0.2 else { return }
            self.tick()
        }
        RunLoop.main.add(watchdog!,forMode:.common)
    }

    private func tick() {
        let now = CACurrentMediaTime(); let rawGap = now-lastTime; let dt = Float(min(rawGap,0.25)); lastTime = now
        frameStats.count += 1; frameStats.longest = max(frameStats.longest,rawGap)
        if rawGap > 1.5/120 && rawGap > 0.0125 { frameStats.late += 1 }
        defer {
            let cost = CACurrentMediaTime()-now
            frameStats.tickCost = max(frameStats.tickCost,cost); tickTotal += cost
            if cost > 0.004 { slowTicks += 1 }
        }
        // Notes live independently of the spider (they stay even when the spider is hidden).
        notesBusy = notes.tick(dt:CGFloat(dt))
        guard visible else {
            displayLink?.setRate(notesBusy || notes.isComposing ? 120 : Self.restRate)
            updateWatchdog()
            return
        }
        if DevFlags.has("--web-check") && !webCheckStarted && motion.time > 0.35 { webCheckStarted = true; startWebCheck() }
        // Development measurements (automation "pointer:off") run as if the pointer were far away.
        let cursor = ignorePointer ? V3(-100000,-100000,0) : space.motion(screen:NSEvent.mouseLocation)
        if let verification { verification.update(dt:dt) }
        else if !motion.paused {
            nativeDragActive = dragAwareness.update()
            if !sequence.isActive {
                if nativeDragActive { motion.drag(at:simd_distance(cursor,motion.position) < motion.awarenessRadius ? cursor : nil) }
                else if motion.dragActive && NSEvent.pressedMouseButtons & 1 == 0 { motion.drag(at:nil) }
            }
            if reactionTime > 0 {
                reactionTime -= dt
                if reactionTime <= 0 && !sequence.isActive { motion.endNotice() }
            }
            motion.webSurfaceScale = web.isExpandedAtAll && simd_distance(motion.position,motionPoint(web:web.geometry.hub(web.expansion))) < 170 ? 0.8 : 1
            let interactionCursor = !sequence.isActive && !nativeDragActive && !menu.isOpen ? cursor : nil
            // Long frames (the idle 10 Hz loop) are simulated in ≤1/30 s steps so time stays true.
            let steps = max(1,Int((dt*30).rounded(.up)))
            for _ in 0..<steps { motion.update(dt:dt/Float(steps),cursor:interactionCursor) }
            stepAsideIfInTheWay(cursor:cursor,dt:dt)
        }
        sequence.update(dt:motion.paused ? 0 : dt)
        updateSize(dt:dt,cursor:cursor)
        updateSleep(now:now)
        if traceLeft > 0 {
            traceLeft -= 1
            trace.append("\(motion.state.rawValue) h=\(String(format:"%.3f",motion.heading)) s=\(String(format:"%.3f",motion.bodyScale)) x=\(String(format:"%.1f",motion.position.x)) dt=\(String(format:"%.4f",dt))")
            if traceLeft == 0 { print("WEBBER-TRACE\n"+trace.joined(separator:"\n")); fflush(stdout); trace = [] }
        }
        hunt(now:now)
        // Target lock: the glow runs hot red while the spider is catching, then cools back to gold.
        // Hunting: hot red while catching (never for a secret), cooling back to gold.
        let secretCatch = now < secretCatchUntil
        let locking: Float = (sequence.isActive || motion.state == .catching || motion.dragActive) && !secretCatch ? 1 : 0
        let lock = renderer.lock+(locking-renderer.lock)*min(1,dt*(locking > renderer.lock ? 14 : 3))
        if abs(lock-renderer.lock) > 0.004 { renderer.lock = lock }
        let shielding: Float = now < shieldUntil && now > shieldFrom ? 1 : 0
        let shield = renderer.shield+(shielding-renderer.shield)*min(1,dt*(shielding > renderer.shield ? 6 : 2.5))
        if abs(shield-renderer.shield) > 0.004 { renderer.shield = shield }

        // Nest: only rendered while opened (or folding away). In ROAM nothing of it is on screen.
        if web.isExpandedAtAll || webPanelShown {
            let webChanged = web.update(dt:dt,spider:nestSpace.screenFrame == space.screenFrame ? webPoint(motion:motion.position) : nil)
            if perf.nestOpenMs < 0, web.isOpen, web.expansion >= 0.98 { perf.nestOpenMs = (now-perf.nestOpenStart)*1000 }
            // The glass fades with the web's own expansion: it comes and goes with the silk.
            let glass = CGFloat(min(1,max(0,web.expansion)))*0.94
            if abs(nestBackdrop.alphaValue-glass) > 0.01 { nestBackdrop.alphaValue = glass }
            if !web.isExpandedAtAll && !web.isOpen { showWebPanel(false) }
            else if webChanged { webView.setNeedsDisplay(webView.bounds); lastWebChange = now }
        } else { _ = web.update(dt:dt,spider:nil) }

        // Hand SceneKit an immutable pose; it is applied on SceneKit's render thread, so the main thread
        // never waits on the scene lock while a frame is being encoded.
        // SceneKit only redraws on its own when the graph changes, so the view renders continuously while
        // poses are arriving and stops a moment after the spider is still (no idle GPU work).
        updateRenderViewport(now:now)
        // Drawn right here, only when the pose (or the tile) changed: nothing else ever wakes the GPU.
        if renderer.needsRender(motion) || surfaceDirty {
            sceneView.waitForGPU()
            renderer.render(motion)
            if sceneView.draw() {
                surfaceDirty = false
                drawStats.frames += 1
                if drawStats.last > 0 && now-drawStats.last < 0.25 { drawStats.longestGap = max(drawStats.longestGap,now-drawStats.last) }
                drawStats.last = now
            } else { surfaceDirty = true }
            lastPoseTime = now
        }
        let animating = now-lastPoseTime < 0.3
        // Energy: full rate only for real motion. Idle micro-movements (breathing, a palp twitch) render at
        // 60 fps (smooth on ProMotion), and with nothing moving at all the loop itself drops to 10 Hz.
        // "Busy" means something is actually moving; paused or quietly watching is not.
        let movingStates = Self.movingStates
        // An open Nest or menu that is standing still is not "busy": the web redraws only when it moves,
        // and the menu animates itself. (A still, open Nest keeps a 60 Hz loop below for instant keys.)
        let webMoving = web.isExpandedAtAll && (now-lastWebChange < 0.5 || !web.isOpen)
        let busy = movingStates.contains(motion.state) || motion.dragActive || sequence.isActive || webMoving || motion.shyActive || motion.momentActive
            || dropView.isPressed || nativeDragActive
        let loopBusy = busy || notesBusy || notes.isComposing
        // 120 fps only when the user is looking at it or using it; a spider strolling on its own runs at 60.
        // A catch runs at 60 fps unless the pointer is right there too (it is quick, and 60 is smooth for it).
        let interactive = engagedNear || motion.dragActive || web.isExpandedAtAll || menu.isOpen || dropView.isPressed || nativeDragActive
        let renderRate = busy ? (interactive ? 120 : (motion.state == .crawling || motion.state == .turning) && !sequence.isActive ? 30 : 60) : (animating ? 60 : 2)
        renderRateNow = renderRate
        displayLink?.setRate(loopBusy ? (interactive || notesBusy || notes.isComposing ? 120 : renderRate == 30 ? 30 : 60)
                             : (animating || webPanelShown || menu.isOpen ? 60 : Self.restRate))
        updateWatchdog()
        // The Nest's 3D view sleeps entirely while the Nest is folded away.
        let nestRate = webPanelShown ? 120 : 2
        if webView.preferredFramesPerSecond != nestRate { webView.preferredFramesPerSecond = nestRate }
        let p = space.screen(motion:motion.position)

        // Carried across to another display: the spider (and everything tied to a screen) follows the pointer.
        if motion.state == .held, let target = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation,$0.frame,false) }),
           target.frame != space.screenFrame {
            let m = NSEvent.mouseLocation
            retarget(to:target,spiderAt:NSPoint(x:m.x+grabOffset.x,y:m.y+grabOffset.y))
        }

        // Spider hit area: a small disc for clicks, the awareness radius during a native drag.
        let dragging = nativeDragActive || motion.dragActive
        let radius = dragging ? CGFloat(motion.awarenessRadius)*space.spiderScale : 90
        if receiver.frame.width != radius*2 { receiver.setContentSize(NSSize(width:radius*2,height:radius*2)) }
        let hitOrigin = NSPoint(x:p.x-radius,y:p.y-radius)
        let pointer = NSEvent.mouseLocation
        let distance = hypot(pointer.x-p.x,pointer.y-p.y)
        // The click target only has to be under the spider when the pointer could reach it: moving a window is a
        // WindowServer round-trip, so a walking spider no longer drags it along every frame while you're elsewhere.
        if receiver.frame.origin != hitOrigin && (dragging || motion.state == .held || dropView.isPressed || distance < radius+240) {
            receiver.setFrameOrigin(hitOrigin)
        }
        let held = motion.state == .held || dropView.isPressed
        let passThrough = held ? false : (dragging ? distance > radius-2 : (distance > clickRadius || menu.isOpen))
        if receiver.ignoresMouseEvents != passThrough { receiver.ignoresMouseEvents = passThrough }
        dropView.accepting = sequence.spiderAvailable

        // Nest objects: the interaction panel takes events only over a visible object (or while one is held).
        webInteractionView.releaseIfButtonUp()
        let nestVisible = web.isOpen && web.expansion > 0.5
        let overObject = nestVisible && !nativeDragActive && web.hitTest(nestSpace.web(screen:pointer)) != nil
        // With an item's menu open, another object can still be clicked: its menu replaces the current one.
        let webInteractive = (webInteractionView.isTracking && !webInteractionView.dragSessionActive) || (overObject && !menu.isOverEntry)
        if webInteractionPanel.ignoresMouseEvents == webInteractive { webInteractionPanel.ignoresMouseEvents = !webInteractive }
        let hoveredItem = overObject ? web.hitTest(nestSpace.web(screen:pointer)) : nil
        if !webInteractionView.isTracking && !menu.isOpen { web.setHover(hoveredItem?.id) }
        // A bigger look at what is under the pointer (not while its menu is open or it is being pulled).
        if let h = hoveredItem, !menu.isOpen, !itemCard.isOpen, !webInteractionView.isTracking, let clip = nestItem(h.id) {
            let c = nestSpace.screen(web:web.objectCenter(h)), sz = web.objectSize(h)
            hoverPreview.update(item:clip,anchor:NSRect(x:c.x-sz.width/2,y:c.y-sz.height/2,width:sz.width,height:sz.height),now:CACurrentMediaTime())
        } else if !previewPinned { hoverPreview.update(item:nil,anchor:.zero,now:0) }
    }

    private func bindWebInteraction() {
        let viewOrigin = nestSpace.desk(screen:webInteractionPanel.frame.origin)
        webInteractionView.toWeb = { [nestSpace] p in nestSpace.web(desk:NSPoint(x:p.x+viewOrigin.x,y:p.y+viewOrigin.y)) }
    }

    /// Spider (motion) and Nest (web) points can be on different displays: convert through screen points.
    func webPoint(motion v: V3) -> V3 { nestSpace.web(screen:space.screen(motion:v)) }
    func motionPoint(web v: V3) -> V3 { space.motion(screen:nestSpace.screen(web:v)) }

    /// Lay the Nest out on a display: its panels, its reach, and the dragline from that display's own
    /// nest corner (the marker's knot on the spider's display).
    func layoutNest(on screen: NSScreen) {
        nestSpace = screen.frame == space.screenFrame ? space : OverlaySpace(screen:screen,spiderScale:spiderScale)
        web.setExpandedBounds(nestSpace.expandedWebBounds)
        web.setViewport(CGRect(origin:.zero,size:nestSpace.compactWebSize))
        bindWebInteraction()
        let knot = nestSpace.screenFrame == space.screenFrame ? nestMarker.knot : NestMarker.knot(onVisibleFrame:nestSpace.visibleScreenFrame)
        web.tether = nestSpace.web(screen:knot)
    }

    /// The display under the pointer (where the user is looking), else the spider's.
    private var pointerScreen: NSScreen? {
        if nestFollowsSpider { return NSScreen.screens.first { $0.frame == space.screenFrame } }
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m,$0.frame,false) }
    }

    /// Change the spider. Its position, state, caught items and pins all carry over; only the animal changes.
    func setSpecies(_ next: SpiderSpecies) {
        guard next != species else { return }
        species = next
        UserDefaults.standard.set(next.id,forKey:"species")
        let screen = NSScreen.screens.first { $0.frame == space.screenFrame } ?? NSScreen.main!
        let here = space.screen(motion:motion.position)
        let fresh = SpiderRenderer(size:screen.frame.size,species:next)
        fresh.lock = renderer.lock
        renderer = fresh; sequence.renderer = fresh
        sceneView.scene = fresh.scene; sceneView.pointOfView = fresh.camera; surfaceDirty = true; sceneView.warmUp()
        motion.cruiseSpeed = next.speed; motion.acceleration = next.acceleration; motion.gaitTempo = next.gaitTempo
        // New size: re-map the same desktop spot into the new motion scale.
        retarget(to:screen,spiderAt:here)
        // The new spider announces itself with a quick look around.
        if sequence.spiderAvailable { motion.turn(by:.pi/5) }
    }

    /// Moves the whole overlay (spider, its render surface, the nest, effects) onto another display.
    /// Everything screen-bound is re-laid out; caught items, pins and the spider's state carry over.
    func retarget(to screen: NSScreen, spiderAt point: NSPoint) {
        if web.isOpen { web.setOpen(false) }
        showWebPanel(false)
        menu.close(animated:false); sequence.cancelAll()
        space = OverlaySpace(screen:screen,spiderScale:spiderScale)
        sequence.space = space
        motion.relocate(bounds:space.motionBounds,to:space.motion(screen:point))
        motion.patrolStops = patrolOffsets.map { motion.constrain(motion.position+$0) }
        // Fixed desktop panel, with the same mapping in a compact render tile (full-size during a drag).
        panel.setFrame(screen.frame,display:false)
        panel.contentView?.frame = NSRect(origin:.zero,size:screen.frame.size)
        let display = CGRect(origin:.zero,size:screen.frame.size)
        let renderFrame = motion.state == .held ? display : SpiderRenderViewport.compact(around:space.desk(motion:motion.position),
            in:display,scale:spiderScale,backingScale:screen.backingScaleFactor)
        sceneView.frame = renderFrame
        if DevFlags.env("WEBBER_MSAA") == nil { sceneView.setSamples(for:Self.antialiasing(for:screen)) }
        let renderCamera = SpiderRenderViewport.camera(for:renderFrame,in:display,scale:spiderScale)
        applyCamera(renderCamera)
        nestMarker.retarget(screen); effects.retarget(screen); stackMarker.retarget(screen)
        layoutNest(on:screen)
        renderer.forceNextRender()
        onStateChange?()
    }

    /// A display was added, removed or rearranged: stay on the current one if it still exists.
    private func screensChanged() {
        notes.rebuildLayers()
        if web.isOpen { setNestOpen(false) }
        if let spiderScreen = NSScreen.screens.first(where: { $0.frame == space.screenFrame }) { layoutNest(on:spiderScreen) }
        if let same = NSScreen.screens.first(where: { $0.frame == space.screenFrame }) {
            if same.visibleFrame.offsetBy(dx:-same.frame.minX,dy:-same.frame.minY) != space.visibleDesk {
                retarget(to:same,spiderAt:space.screen(motion:motion.position))
            }
            return
        }
        guard let main = NSScreen.main ?? NSScreen.screens.first else { return }
        let corner = NSPoint(x:main.visibleFrame.maxX-150,y:main.visibleFrame.minY+140)
        retarget(to:main,spiderAt:corner)
    }

    /// If the pointer keeps resting on the spider (the user is working there, not reaching for it),
    /// it quietly steps a short way aside along the edge, then settles again.
    private func stepAsideIfInTheWay(cursor: V3, dt: Float) {
        let near = simd_distance(cursor,motion.position) < 62
        let busy = menu.isOpen || dropView.isPressed || sequence.isActive || web.isOpen || NSEvent.pressedMouseButtons != 0
        guard near, !busy, motion.state == .idle || motion.state == .watching else { pointerLingerTime = 0; return }
        pointerLingerTime += dt
        guard pointerLingerTime > 1.8 else { return }
        pointerLingerTime = 0
        var away = motion.position-cursor; away.z = 0
        let dir = simd_length(away) > 1 ? simd_normalize(away) : V3(-1,0,0)
        let spot = motion.constrain(motion.position+dir*150)
        motion.crawl(to:spot)
        motion.patrolStops = patrolOffsets.map { motion.constrain(spot+$0) }
        motion.rest(for:45)
    }

    /// The Nest's render surface exists only while it is open (it is the largest piece of memory SilkNest
    /// uses), and covers only the pane, the corner and the dragline between them.
    private func showWebPanel(_ shown: Bool) {
        guard shown != webPanelShown else { return }
        webPanelShown = shown
        // Covers the pane and where the web is launched from (the spider, or the nest corner).
        let frame = shown ? nestSpace.nestRenderScreenFrame(knot:nestLaunch) : NSRect(origin:nestSpace.compactWebScreenFrame.origin,size:NSSize(width:1,height:1))
        let origin = nestSpace.desk(screen:frame.origin)
        let viewport = CGRect(x:origin.x-nestSpace.webOrigin.x,y:origin.y-nestSpace.webOrigin.y,width:frame.width,height:frame.height)
        if shown {
            // Back in its window only while open: a windowless SCNView runs no display link of its own.
            if webPanel.contentView !== webView { webPanel.contentView = webView }
            webView.scene = web.scene; webView.pointOfView = web.camera
            // Two drawables instead of three: the web only redraws while it moves, so double buffering
            // is enough, and each drawable is a full Retina surface of the Nest area.
            (webView.layer as? CAMetalLayer)?.maximumDrawableCount = 2
        }
        SCNTransaction.begin(); SCNTransaction.disableActions = true
        web.setViewport(viewport)
        SCNTransaction.commit()
        webPanel.setFrame(frame,display:false)
        // The pointer layer covers the same area while open; closed, the panels shrink so their window
        // surfaces are released too, and the hanging objects (textures, previews) are let go.
        webInteractionPanel.setFrame(frame,display:false)
        webInteractionView.frame = NSRect(origin:.zero,size:frame.size)
        bindWebInteraction()
        if !shown {
            webView.scene = nil
            webPanel.contentView = NSView(frame:NSRect(x:0,y:0,width:1,height:1))
            nestBackdrop.setFrame(frame,display:false)
            for item in web.items { web.discard(item.id) }
        }
        if shown && visible {
            nestBackdrop.setFrame(nestSpace.nestScreenFrame,display:false)
            nestBackdrop.level = NSWindow.Level(rawValue:webPanel.level.rawValue-1)
            nestBackdrop.orderFrontRegardless()
            webPanel.orderFrontRegardless(); webInteractionPanel.orderFrontRegardless()
        } else { nestBackdrop.orderOut(nil); nestBackdrop.alphaValue = 0; webPanel.orderOut(nil); webInteractionPanel.orderOut(nil) }
        webView.setNeedsDisplay(webView.bounds)
    }

    private func applyVisibility() {
        let panels = [panel,receiver]
        if visible {
            // The spider's render surface comes back (it was released while hidden).
            if sceneView.superview == nil { attachSpiderView() }
            for p in panels { p.orderFrontRegardless() }
            nestMarker.show()
            if webPanelShown { webPanel.orderFrontRegardless(); webInteractionPanel.orderFrontRegardless() }
        } else {
            menu.close(animated:false)
            shortcuts.unregister(.nestKey)
            for p in panels+[webPanel,webInteractionPanel] { p.orderOut(nil) }
            nestMarker.hide(); sequence.cancelAll()
            // Hidden: release the spider's render view and its GPU resources; notes keep running on a timer.
            detachSpiderView()
        }
    }

    private func detachSpiderView() {
        guard sceneView.superview != nil else { return }
        displayLink?.invalidate()
        displayLink = DisplayLinkProxy(view:nil) { [weak self] in self?.tick() }
        sceneView.scene = nil; sceneView.releaseBuffers(); sceneView.removeFromSuperview()
        sceneView = SpiderSurface(frame:NSRect(x:0,y:0,width:1,height:1))
        updateWatchdog()
    }

    private func attachSpiderView() {
        let screen = NSScreen.screens.first { $0.frame == space.screenFrame } ?? NSScreen.main!
        let display = CGRect(origin:.zero,size:space.screenFrame.size)
        let rect = SpiderRenderViewport.compact(around:space.desk(motion:motion.position),in:display,scale:spiderScale,backingScale:screen.backingScaleFactor)
        let view = SpiderSurface(frame:rect)
        view.scene = renderer.scene; view.pointOfView = renderer.camera; view.warmUp()
        view.setSamples(for:Self.antialiasing(for:screen))
        panel.contentView?.addSubview(view)
        sceneView = view
        let camera = SpiderRenderViewport.camera(for:rect,in:display,scale:spiderScale)
        applyCamera(camera)
        renderer.forceNextRender(); surfaceDirty = true
        displayLink?.invalidate()
        displayLink = DisplayLinkProxy(view:view) { [weak self] in self?.tick() }
        updateWatchdog()
    }

    /// The camera for the current render tile (main thread, applied to the next draw).
    private func applyCamera(_ camera: (position: V3, extent: Double, projection: SCNMatrix4)) {
        renderer.camera.simdPosition = camera.position
        renderer.camera.camera?.orthographicScale = camera.extent
        renderer.camera.camera?.projectionTransform = camera.projection
        surfaceDirty = true
    }

    func demoCatch() { _ = motion.catchItem(at:motion.world(V3(0,55,0))) }

    /// Developer replay (--web-check): catches this project's README.md as a file.
    private func startWebCheck() {
        let board = NSPasteboard(name:NSPasteboard.Name("studio.webber.web-check"))
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("README.md") as NSURL])
        catchFrom(board,pointer:NSPoint(x:space.visibleScreenFrame.midX,y:space.visibleScreenFrame.midY))
    }

    private func catchFrom(_ board: NSPasteboard, pointer: NSPoint) {
        guard case .caught(let item) = clipboard.catchCurrent(board), store(item) else { return }
        sequence.start(item,from:catchSource(),mode:catchMode(pointer:pointer))
        lastCatchTime = CACurrentMediaTime(); noteCatch()
        refreshNestSearch()
    }

    // MARK: development automation (only with --automation)

    func automationState() -> [String:Any] {
        [
            "experience":experience.rawValue,
            "notes":notes.automationState(),
            "rails":notes.automationRails(),
            "shortcutsActive":activeShortcuts.keys.map(\.rawValue).sorted(),
            "frames":["count":frameStats.count,"longestGapMs":frameStats.longest*1000,"lateOver12ms":frameStats.late,"worstTickMs":frameStats.tickCost*1000,"slowTicksOver4ms":slowTicks,"meanTickMs":tickTotal/Double(max(1,frameStats.count))*1000,"posesRendered":drawStats.frames,"longestRenderGapMs":drawStats.longestGap*1000,"drawMsTotal":sceneView.drawMs],
            "spider":["state":motion.state.rawValue,"x":Double(motion.position.x),"y":Double(motion.position.y),"paused":motion.paused],
            "sequence":sequence.phase?.rawValue ?? "none",
            "lastCatchMode":sequence.lastMode?.rawValue ?? "none",
            "web":["open":web.isOpen,"expansion":Double(web.expansion),"panelShown":webPanelShown],
            "screens":NSScreen.screens.map { ["x":Double($0.frame.minX),"y":Double($0.frame.minY),"w":Double($0.frame.width),"h":Double($0.frame.height)] },
            "currentScreen":["x":Double(space.screenFrame.minX),"y":Double(space.screenFrame.minY)],
            "frontmost":NSWorkspace.shared.frontmostApplication?.localizedName ?? "?",
            "focused":AutomationInput.focused(),
            "nestQuery":nestKeys.query,"nestFocus":web.focusID ?? -1,"nestMatches":nestKeys.matches,
            "shortcutFailures":lastShortcutFailures,
            "trusted":PasteAssist.trusted,
            "loopRate":displayLink?.currentRate ?? 0,
            "sceneFPS":renderRateNow,
            "spiderState":motion.state.rawValue,
            "stackCount":stack.count,
            "nestItems":web.items.map { ["id":$0.id,"x":Double(nestSpace.screen(web:web.objectCenter($0)).x),"y":Double(nestSpace.screen(web:web.objectCenter($0)).y)] },
            "accessibilityTrusted":PasteAssist.trusted,
            "menuOpen":menu.isOpen,
            "menuEntries":menu.automationEntries,
            "cardItem":itemCard.itemID ?? -1,
            "previewID":hoverPreview.shownID ?? -1,
            // Which of SilkNest's own panels would take a click right now (verification of click-through).
            "takingClicks":([("spider",receiver),("nestObjects",webInteractionPanel)] as [(String,NSWindow)]).filter { !$0.1.ignoresMouseEvents && $0.1.isVisible }.map(\.0)+notes.automationPanelsTakingClicks(),
            "hotkeys":["catch":shortcuts.isRegistered(.catchClipboard),"open":shortcuts.isRegistered(.openNest),"nest":shortcuts.isRegistered(.nest),"esc":shortcuts.isRegistered(.escape)],
            "items":clipboard.items.map { ["id":$0.id,"kind":$0.kind.rawValue,"pinned":$0.pinned,"secret":$0.isSecret,"awaitingOCR":$0.awaitingOCR] as [String:Any] },
            "spiderScreen":["x":Double(space.screen(motion:motion.position).x),"y":Double(space.screen(motion:motion.position).y)],
            "perf":perfState()
        ]
    }

    private func perfState() -> [String:Any] {
        #if DEBUG
        return ["footprintMB":PerfProbe.footprintMB(),"nestOpenMs":perf.nestOpenMs,"searchMs":perf.searchMs,"searchComputeMs":perf.searchComputeMs,"historyLoadMs":perf.historyLoadMs,
                "historyCount":clipboard.items.count,"inMemoryContentMB":Double(clipboard.items.reduce(0) { $0+$1.memoryBytes })/1_048_576,
                "nestTotal":nestKeys.total,"visible":visible]
        #else
        return [:]
        #endif
    }

    func automation(_ command: String) {
        let parts = command.split(separator:":").map(String.init)
        switch parts.first {
        case "screen" where parts.count == 2:
            if let i = Int(parts[1]), NSScreen.screens.indices.contains(i) {
                let f = NSScreen.screens[i].visibleFrame
                retarget(to:NSScreen.screens[i],spiderAt:NSPoint(x:f.midX,y:f.midY))
            }
        case "nestType" where parts.count >= 2: setNestQuery(nestKeys.query+parts.dropFirst().joined(separator:":"))
        case "nestKey" where parts.count == 2: nestKey(parts[1])
        case "patrol" where parts.count == 2: motion.autoPatrol = parts[1] == "on"
        case "pause" where parts.count == 2: setPaused(parts[1] == "on")
        case "reapplyShortcuts": lastShortcutFailures = applyShortcuts().map(\.rawValue)
        case "key" where parts.count == 3:
            // key:<virtual keycode>:<flags bits: 1 ⌘, 2 ⇧, 4 ⌥, 8 ⌃>
            if let code = UInt16(parts[1]), let bits = Int(parts[2]) {
                var f: CGEventFlags = []
                if bits & 1 != 0 { f.insert(.maskCommand) }; if bits & 2 != 0 { f.insert(.maskShift) }
                if bits & 4 != 0 { f.insert(.maskAlternate) }; if bits & 8 != 0 { f.insert(.maskControl) }
                AutomationInput.key(code,flags:f)
            }
        case "type" where parts.count >= 2: AutomationInput.type(parts.dropFirst().joined(separator:":"))
        case "click" where parts.count == 3: if let x = Double(parts[1]), let y = Double(parts[2]) { AutomationInput.click(NSPoint(x:x,y:y)) }
        case "rightClick" where parts.count == 3: if let x = Double(parts[1]), let y = Double(parts[2]) { AutomationInput.rightClick(NSPoint(x:x,y:y)) }
        case "dragItem" where parts.count == 4:
            // dragItem:<nest index>:<x>:<y> — a real mouse drag from a hanging object to a screen point.
            if let i = Int(parts[1]), web.items.indices.contains(i), let x = Double(parts[2]), let y = Double(parts[3]) {
                let from = nestSpace.screen(web:web.objectCenter(web.items[i]))
                AutomationInput.drag(from:from,to:NSPoint(x:x,y:y)) { print("WEBBER: drag finished"); fflush(stdout) }
            }
        case "preview" where parts.count == 2:
            if let i = Int(parts[1]), web.items.indices.contains(i), let clip = clipboard.items.first(where: { $0.id == web.items[i].id }) {
                let h = web.items[i]; let c = nestSpace.screen(web:web.objectCenter(h)), sz = web.objectSize(h)
                let r = NSRect(x:c.x-sz.width/2,y:c.y-sz.height/2,width:sz.width,height:sz.height)
                previewPinned = true; hoverPreview.update(item:clip,anchor:r,now:0); hoverPreview.update(item:clip,anchor:r,now:1)
            }
        case "cardAction" where parts.count == 2: itemCard.run(title:parts[1])
        case "quit": NSApp.terminate(nil)
        case "itemMenu" where parts.count == 2:
            if let i = Int(parts[1]), web.items.indices.contains(i) { showItemMenu(web.items[i].id) }
        case "settings": onOpenSettings?()
        case "stack" where parts.count == 2: if let i = Int(parts[1]), clipboard.items.indices.contains(i) { addToStack(clipboard.items[i]) }
        case "trace": traceLeft = 240
        case "resetStats": frameStats = (0,0,0,0); slowTicks = 0; tickTotal = 0; drawStats = (0,0,0)
        case "walk": motion.autoPatrol = false; motion.crawl(to:motion.constrain(motion.position+V3(-420,180,0)))
        case "walkBack": motion.crawl(to:motion.constrain(motion.position+V3(420,-180,0)))
        case "catch": catchClipboard()
        case "sample" where parts.count >= 3:
            // sample:<text|url|image>:<content or PNG path> — caught from a private pasteboard,
            // never the user's clipboard (marketing captures and verification runs).
            let board = NSPasteboard(name:NSPasteboard.Name("studio.webber.sample.\(UUID().uuidString)"))
            board.clearContents()
            let value = parts.dropFirst(2).joined(separator:":")
            switch parts[1] {
            case "url": board.setString(value,forType:.string); board.setString(value,forType:.URL)
            case "image": if let data = try? Data(contentsOf:URL(fileURLWithPath:value)) { board.setData(data,forType:.png) }
            default: board.setString(value.replacingOccurrences(of:"\\n",with:"\n"),forType:.string)
            }
            if case .caught(let item) = clipboard.catchCurrent(board) {
                // Same rule as a real copy: content caught before is promoted, not added twice.
                if let old = clipboard.existing(item) { clipboard.promote(old); web.acknowledge(old.id) }
                else { catchNew(item,now:CACurrentMediaTime()) }
            }
            board.releaseGlobally()
        case "quick": setNestOpen(!web.isOpen)
        case "nest": setNestOpen(!web.isOpen)
        case "esc": if menu.isOpen { menu.close() } else { setNestOpen(false) }
        case "spiderMenu": showSpiderMenu()
        case "note" where parts.count >= 2: notes.automationCompose(parts.dropFirst().joined(separator:":"))
        case "noteDelete" where parts.count == 2: if let i = Int(parts[1]), notes.notes.indices.contains(i) { notes.delete(notes.notes[i].id) }
        case "noteEdit" where parts.count >= 3:
            if let i = Int(parts[1]), notes.notes.indices.contains(i) { notes.edit(notes.notes[i].id) }
        case "notesToggle": notes.toggleHidden()
        case "composerType" where parts.count >= 2: notes.automationComposerType(parts.dropFirst().joined(separator:":"))
        case "composerCommit": notes.automationComposerCommit()
        case "composer" where parts.count == 2: notes.automationComposerOpen(parts[1] == "open")
        case "noteOpen" where parts.count == 2: notes.automationHoldOpen(Int(parts[1]))
        case "noteMenu" where parts.count == 2: if let id = Int(parts[1]).flatMap(notes.automationIndex) { notes.automationMenu(id) }
        case "notePin" where parts.count == 2: if let id = Int(parts[1]).flatMap(notes.automationIndex) { notes.togglePin(id) }
        case "noteApp" where parts.count == 2: if let id = Int(parts[1]).flatMap(notes.automationIndex) { notes.pinToCurrentApp(id) }
        case "noteGlobal" where parts.count == 2: if let id = Int(parts[1]).flatMap(notes.automationIndex) { notes.makeGlobal(id) }
        case "noteMove" where parts.count == 3: if let i = Int(parts[1]), let f = Double(parts[2]) { notes.automationMove(i,to:f) }
        case "seed" where parts.count == 3:
            // seed:<total>:<large> — synthetic history for performance runs (throwaway automation data only).
            #if DEBUG
            if let total = Int(parts[1]), let big = Int(parts[2]) {
                let first = (clipboard.items.map(\.id).max() ?? 0)+1
                for item in PerfProbe.syntheticItems(total:total,big:big,firstID:first) { _ = clipboard.store(item) }
                updateNestCount(arrived:false); history.save(clipboard.items); history.flush()
                print("WEBBER: seeded \(clipboard.items.count)"); fflush(stdout)
            }
            #endif
        case "outsideClose" where parts.count == 2: ignoreOutsideClicks = parts[1] == "off"
        case "sleep": motion.fallAsleep()
        case "place" where parts.count == 3:
            // place:<x>:<y> — the spider to a screen point (AppKit coordinates) on its display.
            if let x = Double(parts[1]), let y = Double(parts[2]), let screen = NSScreen.screens.first(where: { $0.frame == space.screenFrame }) {
                retarget(to:screen,spiderAt:NSPoint(x:x,y:y)); motion.autoPatrol = false
            }
        case "rich" where parts.count >= 2:
            // rich:<text> — a full catch of fake text from a private pasteboard (recordings).
            let board = NSPasteboard(name:NSPasteboard.Name("studio.webber.rich.\(UUID().uuidString)"))
            board.clearContents(); board.setString(parts.dropFirst().joined(separator:":"),forType:.string)
            catchFrom(board,pointer:NSEvent.mouseLocation); board.releaseGlobally()
        // What ⌃⌥V and a stacked ⌘V do (a process's own synthetic key presses don't reach its global hotkeys).
        case "stackNewest": addNewestToStack()
        case "stackPaste": if !stack.isEmpty { pasteNextFromStack() }
        case "stackPop":
            // The Paste Stack's next item, as ⌘V would take it — without pressing ⌘V anywhere (recordings).
            if let next = stack.next() { web.acknowledge(next.id); stackMarker.show(stack.items); onStateChange?() }
        case "noteAlert" where parts.count == 2: if let i = Int(parts[1]), notes.notes.indices.contains(i) { notes.remind(notes.notes[i].id) }
        case "wake": noteCatch()
        case "fullSize" where parts.count == 2: stayFullSize = parts[1] == "on"
        case "wiggle": motion.happyWiggle()
        case "reduceMotion" where parts.count == 2: motion.reduceMotion = parts[1] == "on"; sequence.reduceMotion = motion.reduceMotion
        case "nestOnSpider" where parts.count == 2: nestFollowsSpider = parts[1] == "on"
        case "pointer" where parts.count == 2: ignorePointer = parts[1] == "off"
        case "visible" where parts.count == 2: visible = parts[1] == "on"; onStateChange?()
        case "testclip" where parts.count == 2:
            // Fills a private pasteboard (never the user's clipboard) and catches from it.
            let board = NSPasteboard(name:NSPasteboard.Name("studio.webber.automation"))
            board.clearContents()
            let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            switch parts[1] {
            case "text": board.setString("fatal error: concurrent map writes",forType:.string)
            case "code": board.setString("func main() {\n\tm := map[string]int{}\n\tgo func() { m[\"a\"] = 1 }()\n}",forType:.string)
            case "url": board.setString("https://github.com/golang/go/issues",forType:.string)
            case "file": board.writeObjects([root.appendingPathComponent("PRODUCT_DIRECTION.md") as NSURL])
            case "image":
                if let image = NSImage(contentsOf:root.appendingPathComponent("artifacts/test-photo.png")) { board.writeObjects([image]) }
            default: return
            }
            catchFrom(board,pointer:NSEvent.mouseLocation)
        default: break
        }
    }
}

/// Vsync-driven callback (macOS 14 display link) for the overlay's frame loop.
final class DisplayLinkProxy: NSObject {
    private var link: CADisplayLink?
    private let callback: () -> Void
    /// `view: nil` runs on a plain timer only (the spider is hidden, nothing on screen needs vsync).
    init(view: NSView?, callback: @escaping () -> Void) {
        self.callback = callback
        super.init()
        guard let view else { rate = 0; setRate(OverlayController.restRate); return }
        link = view.displayLink(target:self,selector:#selector(step(_:)))
        link?.preferredFrameRateRange = CAFrameRateRange(minimum:60,maximum:120,preferred:120)
        link?.add(to:.main,forMode:.common)
    }
    @objc private func step(_ link: CADisplayLink) { callback() }
    private var rate: Float = 120
    var currentRate: Float { rate }
    private var idleTimer: Timer?
    /// At 10 Hz or less the vsync link is paused entirely (it would otherwise wake every refresh) and a plain
    /// low-rate timer keeps the logic alive; above that the display link drives frames on vsync.
    func setRate(_ fps: Float) {
        guard fps != rate else { return }
        rate = fps
        if link == nil {
            idleTimer?.invalidate()
            idleTimer = Timer(timeInterval:1/Double(max(1,fps)),repeats:true) { [weak self] _ in self?.callback() }
            idleTimer?.tolerance = fps > 30 ? 0.002 : 0.02
            RunLoop.main.add(idleTimer!,forMode:.common)
            return
        }
        if fps <= 10 {
            link?.isPaused = true
            idleTimer?.invalidate()
            idleTimer = Timer(timeInterval:1/Double(fps),repeats:true) { [weak self] _ in self?.callback() }
            // Generous tolerance lets macOS fold these wakeups into ones it is doing anyway.
            idleTimer?.tolerance = 0.06
            if let idleTimer { RunLoop.main.add(idleTimer,forMode:.common) }
        } else {
            idleTimer?.invalidate(); idleTimer = nil
            link?.preferredFrameRateRange = CAFrameRateRange(minimum:min(fps,30),maximum:fps,preferred:fps)
            link?.isPaused = false
        }
    }
    func invalidate() { link?.invalidate(); link = nil; idleTimer?.invalidate(); idleTimer = nil }
}

/// The Nest's glass pane: swallows clicks inside the Nest (they must never reach the app underneath)
/// and turns scrolling into paging. It never becomes key or activates SilkNest.
final class NestGlassView: NSVisualEffectView {
    var onScroll: ((NSEvent) -> Void)?
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
}
