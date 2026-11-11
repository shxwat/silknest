import AppKit

/// SILK NOTES: write → hang → remember. Owns the notes, one hanging layer per display, the composer,
/// and persistence. Independent of the clipboard systems; shares the overlay's silk menu and frame tick.
final class NotesController {
    private(set) var notes: [SilkNote] = []
    private let store: NoteStore
    private let composer = NoteComposer()
    private let menu: SilkRadialMenu
    private var layers: [String: SilkNotesLayer] = [:]
    private var editing: UUID?
    private(set) var hidden = false { didSet { UserDefaults.standard.set(hidden,forKey:"notes.hidden"); applyVisibility(); onChange?() } }
    /// Minimum gap between neighbouring tabs on the top edge, in points.
    static let spacing: CGFloat = 10
    var onChange: (() -> Void)?
    /// The app the user is working in (WEBBER's own windows never count).
    private(set) var activeBundle: String?
    private(set) var activeAppName: String?
    private var activationObserver: Any?
    private var spaceObserver: Any?

    init(menu: SilkRadialMenu, store: NoteStore = NoteStore()) {
        self.menu = menu; self.store = store
        notes = store.load()
        hidden = UserDefaults.standard.bool(forKey:"notes.hidden")
        composer.onCommit = { [weak self] text,frame in self?.commit(text,from:frame) }
        noteActive(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] n in
            self?.noteActive(n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.activeSpaceDidChangeNotification,object:nil,queue:.main) { [weak self] _ in
            // Full-screen transitions can change the menu bar / Dock insets without a display change.
            self?.rebuildLayers()
        }
        rebuildLayers()
        // Reminders that came due while SilkNest wasn't running fire shortly after launch.
        DispatchQueue.main.asyncAfter(deadline:.now()+3) { [weak self] in self?.fireDueReminders() }
        scheduleReminders()
    }

    deinit {
        for observer in [activationObserver,spaceObserver].compactMap({ $0 }) {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// App switch: only app-pinned notes change; everything else stays exactly where it is.
    private func noteActive(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        guard app.bundleIdentifier != activeBundle else { return }
        activeBundle = app.bundleIdentifier; activeAppName = app.localizedName
        syncLayers()
    }

    var isComposing: Bool { composer.isOpen }

    // MARK: commands

    /// ⌥N: the composer opens next to the pointer; the active app keeps being the active app.
    func compose() {
        if hidden { hidden = false }
        if composer.isOpen { composer.close(commit:true) }
        editing = nil
        composer.open(near:NSEvent.mouseLocation)
    }

    func toggleHidden() { hidden.toggle() }

    func edit(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        if composer.isOpen { composer.close(commit:true) }
        editing = id
        let at = layer(for:note)?.notePoint(id) ?? NSEvent.mouseLocation
        composer.open(near:NSPoint(x:at.x-NoteComposer.width/2-14,y:at.y),text:note.text)
    }

    /// Pinned notes hang on reinforced silk.
    func togglePin(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].pinned.toggle(); save()
    }

    /// Show this note only while the app the user is in now is active.
    func pinToCurrentApp(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }), let bundle = activeBundle else { return }
        notes[i].mode = .app; notes[i].bundleID = bundle; notes[i].appName = activeAppName
        save()
    }

    func makeGlobal(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].mode = .global; save()
    }

    /// Delete: the strand snaps and the fragment drops away. No confirmation.
    func delete(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        layer(for:note)?.snap(id)
        notes.removeAll { $0.id == id }
        save()
    }

    /// Commit the in-progress thought and finish encrypted writes before normal app termination.
    func flush() { composer.close(commit:true); store.flush() }

    // MARK: creation

    private func commit(_ text: String, from frame: NSRect) {
        if let id = editing, let i = notes.firstIndex(where: { $0.id == id }) {
            notes[i].text = text; notes[i].updatedAt = Date(); editing = nil
            notes[i].remindAt = NoteReminder.date(in:text)
            save(); scheduleReminders(); return
        }
        let center = NSPoint(x:frame.midX,y:frame.midY)
        let screen = NSScreen.screens.first { NSMouseInRect(center,$0.frame,false) } ?? NSScreen.main ?? NSScreen.screens[0]
        // New notes join the start of this display's silk rail (x is the order key; highest comes first).
        let key = (notes.filter { $0.display == screen.displayKey }.map(\.x).max() ?? 0)+1
        var note = SilkNote(text:text,x:key,display:screen.displayKey)
        note.bundleID = activeBundle; note.appName = activeAppName
        note.remindAt = NoteReminder.date(in:text)
        notes.append(note)
        save(); scheduleReminders()
        layer(for:note)?.arrive(note.id,from:center)
    }

    /// Item card → "Hang as note": the copied text becomes a note at the top of the main display.
    func hang(_ text: String) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation,$0.frame,false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        commit(String(text.prefix(2000)),from:NSRect(x:v.midX-40,y:v.maxY-60,width:80,height:40))
    }

    // MARK: done, checklists, reminders

    private var lastDone: SilkNote?, undoToken = 0

    /// Done: the thread snaps and the note falls away; Undo stays offered for a few seconds.
    func done(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }), let at = layer(for:note)?.notePoint(id) else { return }
        lastDone = note
        delete(id)
        undoToken += 1
        let token = undoToken
        menu.open(at:at,toward:-.pi/2,actions:[SilkAction(title:"Done ✓  ·  Undo") { [weak self] in self?.undoDone() }],radius:40,clearance:24,layout:.column)
        DispatchQueue.main.asyncAfter(deadline:.now()+5) { [weak self] in
            guard let self, token == self.undoToken else { return }
            self.lastDone = nil; self.menu.close()
        }
    }

    func undoDone() {
        guard let note = lastDone else { return }
        lastDone = nil; undoToken += 1
        notes.append(note); save(); scheduleReminders()
        if let screen = screen(for:note) { layer(for:note)?.arrive(note.id,from:NSPoint(x:screen.visibleFrame.midX,y:screen.visibleFrame.maxY-40)) }
    }

    func toggleBox(_ id: UUID, line: Int) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].text = NoteReminder.toggle(notes[i].text,line:line); notes[i].updatedAt = Date()
        save()
    }

    private var reminderTimer: Timer?
    /// One timer for the next reminder (nothing polls).
    func scheduleReminders() {
        reminderTimer?.invalidate(); reminderTimer = nil
        guard let next = notes.compactMap(\.remindAt).min() else { return }
        let timer = Timer(fire:max(next,Date().addingTimeInterval(0.5)),interval:0,repeats:false) { [weak self] _ in self?.fireDueReminders() }
        RunLoop.main.add(timer,forMode:.common); reminderTimer = timer
    }

    private func fireDueReminders() {
        let now = Date()
        for note in notes where (note.remindAt ?? .distantFuture) <= now { remind(note.id) }
        scheduleReminders()
    }

    /// The reminder: the note's spider drops down and wiggles the note, and offers Snooze / Done.
    func remind(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].remindAt = nil
        let note = notes[i]
        if hidden { hidden = false }
        save()
        layer(for:note)?.alert(id)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.9) { [weak self] in
            guard let self, let anchor = self.layer(for:note)?.alertAnchor(id) else { return }
            self.menu.open(at:anchor.point,toward:anchor.toward,actions:[
                SilkAction(title:"Snooze 10 min") { [weak self] in self?.snooze(id) },
                SilkAction(title:"Done") { [weak self] in self?.done(id) }
            ],radius:46,clearance:30,layout:.column)
        }
        if Self.notificationsEnabled { ReminderNotifications.post(note) }
    }

    func snooze(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].remindAt = Date().addingTimeInterval(600)
        save(); scheduleReminders()
    }

    /// Optional macOS notifications for reminders (Settings; off by default).
    static var notificationsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey:"noteNotifications") }
        set { UserDefaults.standard.set(newValue,forKey:"noteNotifications"); if newValue { ReminderNotifications.requestPermission() } }
    }

    /// Notes whose text has all these words (Nest search; "note" shows only notes).
    func notes(matching words: [Substring]) -> [SilkNote] {
        notes.filter { n in let hay = n.text.lowercased(); return words.allSatisfy { hay.contains($0) } }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: positions

    /// A knot slid along the rail to a new place: its order key goes between its new neighbours.
    private func moved(_ id: UUID, toIndex index: Int) {
        guard let i = notes.firstIndex(where: { $0.id == id }), let layer = layer(for:notes[i]) else { return }
        var order = layer.visibleIDs.filter { $0 != id }
        order.insert(id,at:min(max(0,index),order.count))
        let keys = Dictionary(uniqueKeysWithValues:notes.map { ($0.id,$0.x) })
        let pos = order.firstIndex(of:id)!
        let above = pos > 0 ? keys[order[pos-1]] : nil, below = pos+1 < order.count ? keys[order[pos+1]] : nil
        switch (above,below) {
        case let (a?,b?): notes[i].x = (a+b)/2
        case let (a?,nil): notes[i].x = a-1
        case let (nil,b?): notes[i].x = b+1
        default: break
        }
        notes[i].position = nil
        notes[i].homeDisplay = nil
        save()
    }

    private func placed(_ id: UUID, at point: CGPoint) {
        guard let i = notes.firstIndex(where: { $0.id == id }), let layer = layer(for:notes[i]) else { return }
        notes[i].position = NotePlacement.normalized(point,in:layer.frame.size)
        notes[i].homeDisplay = nil
        save()
    }

    /// A note dragged off its display: the display under the pointer shows it there, and keeps it on drop.
    private var ghostDisplay: [UUID: String] = [:]
    private func dragAcross(_ id: UUID, point: NSPoint, ended: Bool) -> Bool {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return false }
        let target = NSScreen.screens.first { NSMouseInRect(point,$0.frame,false) }
        let key = target?.displayKey
        // Left the display it was shown on, or came back home: clear the old ghost.
        if let shown = ghostDisplay[id], shown != key { layers[shown]?.dropGhost(id,keep:false); ghostDisplay[id] = nil }
        guard let key, key != notes[i].display, let layer = layers[key] else { return false }
        if ended {
            ghostDisplay[id] = nil
            layer.dropGhost(id,keep:true)
            notes[i].display = key
            notes[i].position = NotePlacement.normalized(CGPoint(x:point.x-layer.frame.minX,y:point.y-layer.frame.minY),in:layer.frame.size)
            notes[i].homeDisplay = nil
            save()
        } else {
            layer.ghost(notes[i],at:point); ghostDisplay[id] = key
        }
        return true
    }

    func returnToTop(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].position = nil
        notes[i].x = (notes.map(\.x).max() ?? 0)+1
        save()
    }

    // MARK: displays

    private func screen(for note: SilkNote) -> NSScreen? { NSScreen.screens.first { $0.displayKey == note.display } }
    private func layer(for note: SilkNote) -> SilkNotesLayer? { layers[note.display] }

    /// One layer per connected display. Notes of a display that is gone move to the primary display
    /// (same relative position) and go back when it reconnects — moved, never duplicated.
    func rebuildLayers() {
        for layer in layers.values { layer.hide() }
        layers = [:]
        let keys = Set(NSScreen.screens.map(\.displayKey))
        if let primary = NSScreen.screens.first?.displayKey {
            notes = NoteVisibility.reassign(notes,connected:keys,primary:primary)
            store.save(notes)
        }
        for screen in NSScreen.screens {
            let layer = SilkNotesLayer(screen:screen)
            layer.onClick = { [weak self] _ in self?.menu.close(animated:false) }
            layer.onDoubleClick = { [weak self] id in self?.edit(id) }
            layer.onDelete = { [weak self] id in self?.delete(id) }
            layer.onContext = { [weak self] id in self?.showMenu(id) }
            layer.onDone = { [weak self] id in self?.done(id) }
            layer.onToggleBox = { [weak self] id,line in self?.toggleBox(id,line:line) }
            layer.onMoved = { [weak self] id,point in self?.placed(id,at:point) }
            layer.onDragAcross = { [weak self] id,point,ended in self?.dragAcross(id,point:point,ended:ended) ?? false }
            layers[layer.screenKey] = layer
        }
        syncLayers()
        applyVisibility()
    }



    /// Every display renders what the visibility resolver decides — nothing else decides visibility.
    private func syncLayers() {
        for screen in NSScreen.screens {
            guard let layer = layers[screen.displayKey] else { continue }
            let input = NoteVisibility.Input(notes:notes,display:screen.displayKey,activeBundle:activeBundle,width:layer.frame.width)
            layer.apply(NoteVisibility.resolve(input),notes:notes)
        }
    }

    private func applyVisibility() {
        for layer in layers.values { hidden ? layer.hide() : layer.show() }
    }

    func clearReminder(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].remindAt = nil; save(); scheduleReminders()
    }

    func showMenu(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }), let at = layer(for:note)?.notePoint(id) else { return }
        // Only the actions that apply to this note right now.
        var actions = [SilkAction(title:"Edit") { [weak self] in self?.edit(id) }]
        actions.append(SilkAction(title:"Copy") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(note.text,forType:.string)
        })
        if note.mode == .app {
            actions.append(SilkAction(title:"Make Global") { [weak self] in self?.makeGlobal(id) })
        } else if let app = activeAppName, activeBundle != nil {
            let short = app.replacingOccurrences(of:"Google ",with:"").replacingOccurrences(of:"Microsoft ",with:"")
            actions.append(SilkAction(title:"Pin to \(short)") { [weak self] in self?.pinToCurrentApp(id) })
        }
        if note.position != nil { actions.append(SilkAction(title:"Return to Top") { [weak self] in self?.returnToTop(id) }) }
        if note.remindAt != nil { actions.append(SilkAction(title:"Remove reminder") { [weak self] in self?.clearReminder(id) }) }
        actions.append(SilkAction(title:"Done ✓") { [weak self] in self?.done(id) })
        actions.append(SilkAction(title:"Delete") { [weak self] in self?.delete(id) })
        menu.open(at:at,toward:-.pi/2,actions:actions,radius:46,clearance:30,layout:.column)
    }

    private func save() {
        syncLayers()
        store.save(notes)
        onChange?()
    }

    /// Driven by the overlay's frame loop. Returns true while notes are animating or under the pointer.
    func tick(dt: CGFloat) -> Bool {
        guard !hidden else { return false }
        let pointer = NSEvent.mouseLocation
        var busy = false
        for layer in layers.values where layer.hasNotes {
            if layer.tick(dt:dt,pointer:pointer,menuOpen:menu.isOpen) { busy = true }
        }
        return busy
    }

    // MARK: automation (development only)

    func automationCompose(_ text: String) { compose(); composer.commitForTesting(text) }
    func automationComposerType(_ text: String) { composer.typeForTesting(text) }
    func automationComposerCommit() { composer.commitOpenForTesting() }
    func automationComposerOpen(_ open: Bool) { if open { compose() } else { composer.close(commit:false) } }
    func automationHoldOpen(_ index: Int?) {
        let id = index.flatMap { notes.indices.contains($0) ? notes[$0].id : nil }
        for layer in layers.values { layer.holdOpen(id) }
    }
    func automationMove(_ index: Int, to slot: Double) {
        guard notes.indices.contains(index) else { return }
        moved(notes[index].id,toIndex:Int(slot))
    }
    func automationPanelsTakingClicks() -> [String] { layers.compactMap { $0.value.takesClicks ? "notes-\($0.key.prefix(4))" : nil } }
    func automationRails() -> [String:String] {
        Dictionary(uniqueKeysWithValues:layers.map { ($0.key.prefix(4).description,"\($0.value.rail.side.rawValue) x=\(Int($0.value.rail.start.x)) y=\(Int($0.value.rail.start.y)) out=\(Int($0.value.rail.outward.x))") })
    }
    func automationMenu(_ id: UUID) { showMenu(id) }
    func automationIndex(_ i: Int) -> UUID? { notes.indices.contains(i) ? notes[i].id : nil }
    func automationState() -> [[String:Any]] {
        notes.map { n in
            let p = layer(for:n)?.notePoint(n.id), t = layer(for:n)?.deleteButtonPoint(n.id)
            return ["id":n.id.uuidString,"x":n.x,"display":n.display,"chars":n.text.count,"pinned":n.pinned,"mode":n.mode.rawValue,
                    "app":n.appName ?? "","remindIn":n.remindAt.map { $0.timeIntervalSinceNow } ?? -1,"showing":layer(for:n)?.isShowing(n.id) ?? false,"screenX":Double(p?.x ?? -1),"screenY":Double(p?.y ?? -1),"trashX":Double(t?.x ?? -1),"trashY":Double(t?.y ?? -1)]
        }
    }
}
