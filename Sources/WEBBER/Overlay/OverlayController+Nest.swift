import AppKit

/// The Nest's keyboard and search (see NestKeyboard).
extension OverlayController {
    func beginNestKeyboard() {
        nestTarget = NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0 }
        nestKeys.setQuery("")
        nestPage = 0
        web.focusID = nil
        // The newest page is already hanging as the web spreads.
        refreshNestSearch(animated:false)
        nestKeys.takeKeys(NestKeyboard.Handlers(
            query: { [weak self] q in self?.setNestQuery(q) },
            digit: { [weak self] n in self?.nestDigit(n) },
            backspace: { [weak self] in self?.nestBackspace() ?? false },
            paste: { [weak self] plain in self?.pasteNestFocus(plain:plain) },
            move: { [weak self] dx,dy in self?.moveNestFocus(dx:dx,dy:dy) },
            menu: { [weak self] in
                guard let self else { return }
                if self.itemCard.isOpen { self.itemCard.close() } else if let id = self.web.focusID { self.showItemMenu(id) }
            },
            page: { [weak self] delta in self?.turnNestPage(delta) },
            escape: { [weak self] in self?.nestEscape() },
            stack: { [weak self] in
                guard let self else { return }
                let id = self.itemCard.isOpen ? self.itemCard.itemID : self.web.focusID
                if let id, let clip = self.nestItem(id) { self.addToStack(clip,fromNest:true) }
            }))
        nestKeys.pill.show(on:nestSpace.nestScreenFrame)
        renderNestPill()
    }

    func endNestKeyboard() {
        let typing = nestKeys.pill.isKey
        nestKeys.releaseKeys()
        nestKeys.pill.hide(); itemCard.close(notify:false); hoverPreview.hide()
        // Keyboard focus goes straight back to the app the user was in (SilkNest never became active).
        // (Not when the user clicked into another app to close it: that app keeps focus.)
        if typing, let target = nestTarget, NSWorkspace.shared.frontmostApplication == target { target.activate(options:[]) }
        nestKeys.setQuery("")
        web.focusID = nil; web.dimmedIDs = []; web.badgeNumbers = [:]
    }

    func setNestQuery(_ q: String) {
        nestKeys.setQuery(q)
        nestPage = 0
        refreshNestSearch(refocus:true)
    }

    /// Older (1) or newer (-1) items: the web lets one page go and spins out the next from its hub.
    func turnNestPage(_ delta: Int) {
        guard web.isOpen else { return }
        let next = min(max(0,nestPage+delta),max(0,nestPageCount-1))
        guard next != nestPage else { return }
        nestPage = next
        itemCard.close(notify:false); hoverPreview.hide()
        applyNestResults(nestResults,refocus:true,animated:true,started:CACurrentMediaTime())
    }

    /// Scrolling on the Nest's glass (or over an object) turns pages; one swipe or wheel notch = one page.
    func scrollNest(_ event: NSEvent) {
        if event.phase == .began || CACurrentMediaTime()-nestScrollTime > 0.4 { nestScroll = 0 }
        nestScrollTime = CACurrentMediaTime()
        guard event.momentumPhase.isEmpty, !nestScrollUsed || event.phase == .began || !event.hasPreciseScrollingDeltas else { return }
        if event.phase == .began { nestScrollUsed = false }
        nestScroll += event.scrollingDeltaY*(event.hasPreciseScrollingDeltas ? 1 : 12)
        if abs(nestScroll) >= 40 {
            turnNestPage(nestScroll < 0 ? 1 : -1)     // down: older, up: newer
            nestScroll = 0
            nestScrollUsed = event.hasPreciseScrollingDeltas
        }
    }

    private var nestPageSize: Int { max(1,web.geometry.slots.count) }
    private var nestPageCount: Int { max(1,(nestKeys.total+nestPageSize-1)/nestPageSize) }

    /// Recomputes what matches across the whole history (pinned first, then newest), which page hangs in the
    /// web, the 1–9 numbers and the focus. With a query, matching runs on a background queue after a short
    /// pause in typing; an empty query (and opening) is applied at once.
    func refreshNestSearch(refocus: Bool = false, animated: Bool = true) {
        guard web.isOpen else { return }
        let started = CACurrentMediaTime()
        let query = nestKeys.query
        // Silk Notes join a search (after the copies); "note" shows only notes.
        let words = query.lowercased().split(separator:" ")
        let notesOnly = words.contains("note") || words.contains("notes")
        let noteMatches = words.isEmpty ? [] : notes.notes(matching:words.filter { $0 != "note" && $0 != "notes" })
        nestNoteItems = Dictionary(uniqueKeysWithValues:noteMatches.map { n -> (Int,ClipboardItem) in
            let id = -(abs(n.id.uuidString.hashValue % 1_000_000)+1)
            let item = nestNoteItems[id] ?? ClipboardItem(id:id,kind:.text,representations:[(.string,Data(n.text.utf8))],text:n.text,url:nil,fileURLs:[],image:nil)
            item.noteID = n.id; item.sourceName = "Silk Note"
            return (id,item)
        })
        let notePool = noteMatches.compactMap { n in nestNoteItems.values.first { $0.noteID == n.id } }
        let ordered = notesOnly ? notePool : NestKeyboard.ordered(recentItems)+notePool
        searchGeneration += 1
        let generation = searchGeneration
        if query.trimmingCharacters(in:.whitespaces).isEmpty {
            perf.searchComputeMs = 0
            applyNestResults(ordered.map(\.id),refocus:refocus,animated:animated,started:started)
            return
        }
        let entries = ordered.map { NestKeyboard.Entry(id:$0.id,kind:$0.kind,pinned:$0.pinned,haystack:$0.searchableText) }
        // Typing: wait for a short pause, then match off the main thread.
        let debounce: Double = refocus ? 0.03 : 0
        searchQueue.asyncAfter(deadline:.now()+debounce) { [weak self] in
            guard let self, generation == self.currentSearchGeneration() else { return }
            let t = CACurrentMediaTime()
            let ids = NestKeyboard.search(entries,query:query)
            let compute = (CACurrentMediaTime()-t)*1000
            DispatchQueue.main.async {
                guard generation == self.searchGeneration, self.web.isOpen else { return }
                self.perf.searchComputeMs = compute
                self.applyNestResults(ids,refocus:refocus,animated:animated,started:started)
            }
        }
    }

    /// Read on the search queue: a racy read is fine (it only lets a stale search finish early).
    private func currentSearchGeneration() -> Int { searchGeneration }

    private func applyNestResults(_ ids: [Int], refocus: Bool, animated: Bool, started: CFTimeInterval) {
        nestResults = ids
        nestKeys.total = ids.count
        nestPage = min(nestPage,nestPageCount-1)
        let start = nestPage*nestPageSize
        let byID = Dictionary(uniqueKeysWithValues:clipboard.items.map { ($0.id,$0) }).merging(nestNoteItems) { a,_ in a }
        let page = start < ids.count ? ids[start..<min(ids.count,start+nestPageSize)].compactMap { byID[$0] } : []
        syncWeb(to:page,animated:animated)
        let found = page.map(\.id)
        nestKeys.update(matches:found)
        web.dimmedIDs = []
        var badges: [Int: Int] = [:]
        if nestKeys.query.isEmpty { for (i,id) in found.prefix(9).enumerated() { badges[id] = i+1 } }
        web.badgeNumbers = badges
        if refocus || web.focusID == nil || !found.contains(web.focusID!) { web.focusID = found.first }
        renderNestPill()
        perf.searchMs = (CACurrentMediaTime()-started)*1000
    }

    /// Hang exactly these items: others let go at once, new ones spin out of the hub to free anchors.
    /// Items being pulled or dragged out are left alone.
    private func syncWeb(to page: [ClipboardItem], animated: Bool) {
        let wanted = Set(page.map(\.id))
        for item in web.items where (item.phase == .hanging || item.phase == .attaching) && !wanted.contains(item.id) {
            web.discard(item.id)
        }
        let hung = Set(web.items.filter { $0.phase != .released }.map(\.id))
        let hub = web.geometry.hub(web.expansion)
        for clip in page where !hung.contains(clip.id) {
            guard let slot = web.freeSlot else { break }
            let added = web.attach(clip,slot:slot,from:hub)
            if !animated { added.phase = .hanging }
            added.pinned = clip.pinned
        }
    }

    private func renderNestPill() {
        nestKeys.pill.render(query:nestKeys.query,total:nestKeys.total,page:nestPage,pages:nestPageCount,target:nestTarget?.localizedName,
                             canPaste:pasteOnSelect && PasteAssist.trusted)
    }

    private func nestDigit(_ n: Int) {
        if nestKeys.query.isEmpty, n >= 1, let id = web.badgeNumbers.first(where: { $0.value == n })?.key {
            web.focusID = id; pasteNestFocus(plain:false)
        } else { setNestQuery(nestKeys.query+"\(n)") }
    }

    /// ⌫ with an item's card open removes that item; otherwise it edits the search (the field does that).
    private func nestBackspace() -> Bool {
        guard itemCard.isOpen, let id = itemCard.itemID else { return false }
        itemCard.close(); removeItem(id); return true
    }

    /// Esc: close the card, then the menu, then clear the search, then close the Nest.
    func nestEscape() {
        if itemCard.isOpen { itemCard.close() }
        else if menu.isOpen { menu.close() }
        else if !nestKeys.query.isEmpty { setNestQuery("") }
        else { setNestOpen(false) }
    }

    func pasteNestFocus(plain: Bool) {
        if itemCard.isOpen, let id = itemCard.itemID { web.focusID = id; itemCard.close(notify:false) }
        guard let id = web.focusID, let clip = nestItem(id) else { return }
        menu.close(animated:false)
        quickSelect(clip,mode:plain ? .plain : .normal)
        // Without the one-time permission the item is copied (⌘V works); explain once how to paste directly.
        if pasteOnSelect && !PasteAssist.trusted && !askedPastePermission {
            askedPastePermission = true
            PasteAssist.requestTrustIfNeeded()
        }
    }

    /// The nearest matching object in that direction (screen space), weighted toward straight lines.
    private func moveNestFocus(dx: CGFloat, dy: CGFloat) {
        let pool = nestKeys.matches.compactMap { id in web.item(id).map { (id,nestSpace.screen(web:web.objectCenter($0))) } }
        guard !pool.isEmpty else { return }
        guard let current = web.focusID, let here = pool.first(where: { $0.0 == current })?.1 else { web.focusID = pool.first?.0; return }
        var best: (id: Int, score: CGFloat)?
        for (id,p) in pool where id != current {
            let vx = p.x-here.x, vy = p.y-here.y
            let along = vx*dx+vy*dy
            guard along > 4 else { continue }
            let across = abs(vx*dy-vy*dx)
            let score = along+across*2.2
            if best == nil || score < best!.score { best = (id,score) }
        }
        if let best { web.focusID = best.id }
    }

    /// Automation: drive the same handlers the keys do.
    func nestKey(_ name: String) {
        switch name {
        case "return": pasteNestFocus(plain:false)
        case "plain": pasteNestFocus(plain:true)
        case "left": moveNestFocus(dx:-1,dy:0)
        case "right": moveNestFocus(dx:1,dy:0)
        case "up": moveNestFocus(dx:0,dy:1)
        case "down": moveNestFocus(dx:0,dy:-1)
        case "backspace": _ = nestBackspace()
        case "pageDown": turnNestPage(1)
        case "pageUp": turnNestPage(-1)
        default: if let n = Int(name) { nestDigit(n) }
        }
    }
}
