import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// The useful part: history that survives restarts, text from images, smart paste and the Paste Stack.
extension OverlayController {

    // MARK: history

    func restoreHistory() {
        guard rememberHistory else { return }
        let loadStart = CACurrentMediaTime()
        let restored = history.load()
        perf.historyLoadMs = (CACurrentMediaTime()-loadStart)*1000
        // Count only; clipboard contents are never logged.
        if DevFlags.env("WEBBER_DIAG") != nil { print("WEBBER: restored \(restored.count) items"); fflush(stdout) }
        guard !restored.isEmpty else { return }
        clipboard.adopt(restored)
        for item in clipboard.items where item.kind == .image {
            if item.recognizedText == nil { recognizeText(item) }
            // Images read before secret detection existed: checked now; a secret is taken off the disk.
            else {
                let outcome = clipboard.checkImageForSecret(item)
                if outcome != .clean { handleOCR(outcome,item) }
            }
        }
        updateNestCount(arrived:false)
        // Rewrites the index with the metadata that lets large items stay on disk, and moves them out of memory.
        persist()
    }

    /// Coalesced save, a moment after the last change.
    func persist() {
        guard rememberHistory, !persistScheduled, !Uninstall.deletingData else { return }
        persistScheduled = true
        DispatchQueue.main.asyncAfter(deadline:.now()+0.6) { [weak self] in
            guard let self else { return }
            self.persistScheduled = false
            self.history.save(self.clipboard.items)
        }
    }

    func clearHistory() {
        for item in clipboard.items where !item.pinned { web.release(item.id) }
        clipboard.clearUnpinned()
        updateNestCount(arrived:false)
        // The next save deletes the files of everything that is gone; pinned items keep theirs.
        persist()
        refreshNestSearch()
    }

    // MARK: text from images

    func recognizeText(_ item: ClipboardItem) {
        guard item.kind == .image, item.recognizedText == nil else { return }
        TextRecognizer.recognize(image: { [weak item] in item?.image }) { [weak self, weak item] text in
            // "" = read, nothing found: remembered, so the image is never read again on the next launch.
            // nil = couldn't read it this time: stored as is, tried again next launch.
            guard let self, let item else { return }
            self.handleOCR(self.clipboard.applyRecognizedText(text,to:item),item)
        }
    }

    /// After an image's text was checked: a secret is protected like a copied secret (and anything of it
    /// already on disk is deleted by the next save); "never catch secrets" lets the image go.
    func handleOCR(_ outcome: ClipboardController.OCROutcome, _ item: ClipboardItem) {
        // Hanging in the open Nest with its pending (blurred) look: hang it again with its real look.
        if outcome != .refuse, web.item(item.id) != nil { web.discard(item.id); refreshNestSearch() }
        switch outcome {
        case .refuse: removeItem(item.id)
        case .secret: protectSecret(item); refreshNestSearch(); persist(); offerToTrashScreenshot(item)
        case .clean: persist()
        }
    }

    /// A screenshot saved as a file turned out to contain a secret: the spider asks, once for that file,
    /// whether to move the file to the Trash. Nothing happens unless the user says yes.
    func offerToTrashScreenshot(_ item: ClipboardItem) {
        guard let file = item.sourceFile, FileManager.default.fileExists(atPath:file.path), visible else { return }
        item.sourceFile = nil
        let center = space.screen(motion:motion.position)
        let toward = atan2(space.screenFrame.midY-center.y,space.screenFrame.midX-center.x)
        DispatchQueue.main.asyncAfter(deadline:.now()+1.8) { [weak self] in
            self?.menu.open(at:center,toward:toward,actions:[
                SilkAction(title:"This screenshot contains a secret.") {},
                SilkAction(title:"Move the file to Trash") { NSWorkspace.shared.recycle([file]) { _,_ in } },
                SilkAction(title:"Keep the file") {}
            ],radius:130,clearance:80)
        }
    }

    // MARK: smart paste

    /// The plain-text form of an object: its text, its URL, the text in an image, or file paths.
    func plainText(_ item: ClipboardItem) -> String? {
        switch item.kind {
        case .text, .code: return item.text
        case .url: return item.url?.absoluteString ?? item.text
        case .image: return item.recognizedText.flatMap { $0.isEmpty ? nil : $0 }
        case .file: return item.fileURLs.map(\.path).joined(separator:"\n")
        }
    }

    /// How a chosen item is pasted: as-is, as plain text, as the text read from an image, or queued on the stack.
    enum PasteMode { case normal, plain, text, stack }

    func quickSelect(_ item: ClipboardItem, mode: PasteMode) {
        web.acknowledge(item.id)
        switch mode {
        case .stack: addToStack(item); return
        case .normal: clipboard.copyAgain(item)
        case .plain, .text:
            guard let text = plainText(item) else { clipboard.copyAgain(item); break }
            clipboard.writeString(text); clipboard.promote(item)
        }
        if web.isOpen { setNestOpen(false) }
        if pasteOnSelect { pasteDirectly(after:0.08) }
        persist()
        onStateChange?()
    }

    /// Paste a transformed copy of a text object (the stored object is unchanged).
    func paste(transformed text: String) {
        clipboard.writeString(text)
        if web.isOpen { setNestOpen(false) }
        if pasteOnSelect { pasteDirectly(after:0.08) }
    }

    func showTransformMenu(_ item: ClipboardItem, at center: NSPoint) {
        guard let source = plainText(item) else { return }
        let options = TextTransform.applicable(to:source)
        guard !options.isEmpty else { return }
        let toward = atan2(space.screenFrame.midY-center.y,space.screenFrame.midX-center.x)
        menu.open(at:center,toward:toward,actions:options.map { t in
            SilkAction(title:t.title) { [weak self] in self?.paste(transformed:t.apply(source)) }
        },radius:110,clearance:40,layout:.column)
    }

    // MARK: Paste Stack

    /// Queue an object. While the stack has items, each Cmd+V pastes the next one in order.
    /// From the Nest (card action or ⌘↩) the Nest stays open, so several items can be queued in a row.
    func addToStack(_ item: ClipboardItem, fromNest: Bool = false) {
        stack.add(item)
        stackMarker.show(stack.items)
        web.acknowledge(item.id)
        if fromNest { itemCard.close(notify:false) }
        // Cmd+V is only taken over when WEBBER can actually paste; otherwise it would swallow the user's paste.
        if PasteAssist.trusted { armStackPaste() } else { PasteAssist.requestTrustIfNeeded() }
        onStateChange?()
    }

    /// The global shortcut (⌃⌥V by default): queue the newest copy. Copy, ⌃⌥V, copy, ⌃⌥V… then ⌘V ⌘V.
    func addNewestToStack() {
        guard let newest = clipboard.items.last else { return }
        addToStack(newest)
        if !motion.paused, motion.state == .idle || motion.state == .watching { motion.notice(motion.position+V3(0,40,0)); reactionTime = 0.3 }
    }

    func clearStack() {
        stack.clear(); stackMarker.show(stack.items)
        shortcuts.unregister(.paste)
        onStateChange?()
    }

    func armStackPaste() {
        guard PasteAssist.trusted, !stack.isEmpty, !shortcuts.isRegistered(.paste) else { return }
        shortcuts.register(.paste) { [weak self] in self?.pasteNextFromStack() }
    }

    // MARK: first run

    /// One short, friendly introduction, once: what happens automatically and the one shortcut to remember.
    func showWelcomeIfNeeded() {
        guard !UserDefaults.standard.bool(forKey:"welcomed"), !DevFlags.has("--automation") else { return }
        UserDefaults.standard.set(true,forKey:"welcomed")
        DispatchQueue.main.asyncAfter(deadline:.now()+1.2) { [weak self] in
            guard let self else { return }
            let center = self.space.screen(motion:self.motion.position)
            let toward = atan2(self.space.screenFrame.midY-center.y,self.space.screenFrame.midX-center.x)
            // Three facts and two explicit choices; nothing is switched on behind the user's back.
            var actions = [
                SilkAction(title:"Copy anything — I catch it") {},
                SilkAction(title:"\((self.activeShortcuts[.clipboardHistory] ?? ShortcutAction.clipboardHistory.shortcut)?.display ?? "⇧⌘Space") — your Nest") { [weak self] in self?.setNestOpen(true) }
            ]
            if !PasteAssist.trusted {
                actions.append(SilkAction(title:"Turn on 1-click paste") { PasteAssist.requestTrustIfNeeded() })
            }
            actions.append(SilkAction(title:"Start SilkNest at login") { try? SMAppService.mainApp.register() })
            self.menu.open(at:center,toward:toward,actions:actions,radius:130,clearance:80)
        }
    }

    func pasteNextFromStack() {
        guard let next = stack.next() else { shortcuts.unregister(.paste); return }
        clipboard.copyAgain(next); web.acknowledge(next.id)
        stackMarker.show(stack.items)
        // Let our own Cmd+V through to the app, then catch the next one.
        shortcuts.unregister(.paste)
        PasteAssist.pasteIntoFrontmostApp()
        if !stack.isEmpty {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [weak self] in
                guard let self, !self.stack.isEmpty else { return }
                self.armStackPaste()
            }
        }
        onStateChange?()
    }
}
