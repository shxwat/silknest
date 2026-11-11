import AppKit
import ServiceManagement
import Carbon.HIToolbox

/// Developer-only launch flags (--automation, --study, previews, checks). A release build ignores them all,
/// so nothing outside the app can drive it, read its state, or switch it into a test mode.
enum DevFlags {
    #if DEBUG
    static let enabled = true
    #else
    static let enabled = false
    #endif
    static func has(_ flag: String) -> Bool { enabled && CommandLine.arguments.contains(flag) }
    static func value(_ prefix: String) -> String? {
        guard enabled, let a = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return String(a.dropFirst(prefix.count))
    }
    static func env(_ key: String) -> String? { enabled ? ProcessInfo.processInfo.environment[key] : nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlay: OverlayController?
    private var statusItem: NSStatusItem?
    private var study: SpiderStudy?
    private var settings: SettingsWindow?
    private var shortcutItems: [ShortcutAction: NSMenuItem] = [:]
    private var pasteItem: NSMenuItem?, huntItem: NSMenuItem?
    private var historyItem: NSMenuItem?, loginItem: NSMenuItem?
    private var notesItem: NSMenuItem?, clearStackItem: NSMenuItem?
    private var pauseItem: NSMenuItem?, hideItem: NSMenuItem?, webItem: NSMenuItem?
    private let developmentMode = DevFlags.has("--study")
    /// Someone who used SilkNest before this launch (the welcome is marked as shown during launch).
    private let existingUser = UserDefaults.standard.bool(forKey:"welcomed")
    func applicationDidFinishLaunching(_ notification: Notification) {
        ClipboardItem.purgeExports()
        if DevFlags.has("--species-preview") { PreviewCapture.species(); NSApp.terminate(nil); return }
        if DevFlags.has("--sprite-sheet-tilted") { PreviewCapture.spriteSheetTilted(); NSApp.terminate(nil); return }
        if DevFlags.has("--sprite-sheet") { PreviewCapture.spriteSheet(); NSApp.terminate(nil); return }
        if DevFlags.has("--app-icon") { PreviewCapture.appIcon(); NSApp.terminate(nil); return }
        if DevFlags.has("--render-preview") { PreviewCapture.run(); NSApp.terminate(nil); return }
        // One spider only: if WEBBER is already running (e.g. opened twice, or a login item plus a manual
        // launch), this copy quits instead of adding a second overlay.
        let me = NSRunningApplication.current
        if !DevFlags.has("--study"),
           NSRunningApplication.runningApplications(withBundleIdentifier:Bundle.main.bundleIdentifier ?? "").contains(where: { $0 != me && !$0.isTerminated }) {
            NSApp.terminate(nil); return
        }
        guard let screen = NSScreen.main else { NSApp.terminate(nil); return }
        let overlay = OverlayController(screen:screen)
        self.overlay = overlay
        if developmentMode { overlay.onStudy = { [weak self] in self?.showStudy() } }
        overlay.onStateChange = { [weak self] in self?.refreshMenu() }
        overlay.notes.onChange = { [weak self] in self?.refreshMenu() }
        overlay.onOpenSettings = { [weak self] in self?.openSettings() }
        let item = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        item.button?.image = Self.menuBarIcon()
        item.button?.toolTip = "SilkNest"
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let entry = NSMenuItem(title:title,action:action,keyEquivalent:key)
            entry.keyEquivalentModifierMask = modifiers; entry.target = self; menu.addItem(entry); return entry
        }
        if developmentMode {
            _ = add("Open spider study",#selector(openStudy))
            _ = add("Rehearse catch",#selector(catchDemo))
            menu.addItem(.separator())
        }
        // Key equivalents here are display hints; the global shortcuts are registered by the overlay.
        // Only what people reach for every day; switches and rarely used actions live in Settings.
        webItem = add("Open Nest",#selector(toggleNest)); shortcutItems[.clipboardHistory] = webItem
        shortcutItems[.newNote] = add("New Silk Note",#selector(newNote))
        menu.addItem(.separator())
        huntItem = add("Catch Every Copy",#selector(toggleHunt))
        huntItem?.state = overlay.huntMode ? .on : .off
        hideItem = add("Hide Spider",#selector(hide))
        clearStackItem = add("Clear Paste Stack",#selector(clearStack))
        // Menu hints follow the user's own shortcuts (display only; the overlay registers the real ones).
        for (action,item) in shortcutItems {
            let s = overlay.activeShortcuts[action] ?? action.shortcut
            let name = s.map { Shortcut.keyName(Int($0.keyCode)) } ?? ""
            item.keyEquivalent = name == "Space" ? " " : (name.count == 1 ? name.lowercased() : "")
            var mask: NSEvent.ModifierFlags = []
            if let m = s?.modifiers {
                if m & UInt32(cmdKey) != 0 { mask.insert(.command) }
                if m & UInt32(shiftKey) != 0 { mask.insert(.shift) }
                if m & UInt32(optionKey) != 0 { mask.insert(.option) }
                if m & UInt32(controlKey) != 0 { mask.insert(.control) }
            }
            item.keyEquivalentModifierMask = mask
        }
        menu.addItem(.separator())
        _ = add("About SilkNest",#selector(about))
        _ = add("Check for Updates…",#selector(checkForUpdates))
        _ = add("Settings…",#selector(openSettings),",")
        menu.addItem(.separator())
        _ = add("Quit SilkNest",#selector(quit),"q")
        item.menu = menu; statusItem = item
        if developmentMode { showStudy() }
        if DevFlags.has("--automation") { startAutomation() }
        Updater.shared.willRelaunch = { [weak overlay] in
            guard let overlay else { return }
            overlay.notes.flush()
            if overlay.rememberHistory { overlay.history.save(overlay.clipboard.items); overlay.history.flush() }
        }
        Updater.shared.start()
        Updater.shared.announceIfUpdated()
        explainNewSignatureIfNeeded()
        // After the welcome (first launch) or shortly after an update: the one screenshot question.
        if !DevFlags.has("--automation") { ScreenshotPreview.askIfNeeded(after:existingUser ? 4 : 6) }
        // Zero setup: start with the Mac by default (the menu can turn it off).
        refreshMenu()
    }
    func applicationWillTerminate(_ notification: Notification) {
        guard let overlay, !Uninstall.deletingData else { return }
        overlay.notes.flush()
        // A copy caught in the last moment before Quit is saved too (saves are otherwise coalesced).
        if overlay.rememberHistory { overlay.history.save(overlay.clipboard.items); overlay.history.flush() }
    }

    /// The first launch signed with the SilkNest certificate after ad-hoc builds: macOS treats it as a new
    /// app and drops the Accessibility grant. Say why, once, and offer the one switch (it then survives updates).
    private func explainNewSignatureIfNeeded() {
        let d = UserDefaults.standard
        let now = Updater.isCertificateSigned ? "certificate" : "adhoc"
        let before = d.string(forKey:"signingKind")
        d.set(now,forKey:"signingKind")
        guard let overlay, !DevFlags.has("--automation"),
              SignatureTransition.shouldExplain(previous:before,current:now,existingUser:existingUser,alreadyExplained:d.bool(forKey:"newSignatureExplained"),
                                                wantsPaste:overlay.pasteOnSelect,pasteTrusted:PasteAssist.trusted) else { return }
        d.set(true,forKey:"newSignatureExplained")
        DispatchQueue.main.asyncAfter(deadline:.now()+2.5) { PermissionWindow.shared.show(.newSignature) }
    }

    private func refreshMenu() {
        guard let overlay else { return }
        huntItem?.state = overlay.huntMode ? .on : .off
        hideItem?.title = overlay.visible ? "Hide Spider" : "Show Spider"
        webItem?.title = overlay.web.isOpen ? "Close Nest" : "Open Nest"
        notesItem?.title = overlay.notes.hidden ? "Show Silk Notes" : "Hide Silk Notes"
        clearStackItem?.isHidden = overlay.stack.isEmpty
        clearStackItem?.title = "Clear Paste Stack (\(overlay.stack.count))"
    }
    private func showStudy() {
        guard developmentMode else { return }
        if study == nil {
            study = SpiderStudy()
            study?.onClose = { [weak self] in self?.study = nil }
        }
        study?.show()
    }
    @objc private func newNote() { overlay?.notes.compose() }
    @objc private func clearStack() { overlay?.clearStack(); refreshMenu() }
    @objc private func toggleNotes() { overlay?.notes.toggleHidden(); refreshMenu() }
    @objc private func openStudy() { showStudy() }
    @objc private func catchDemo() { overlay?.demoCatch() }
    @objc private func catchCopy() { overlay?.catchClipboard() }
    @objc private func toggleNest() { guard let overlay else { return }; overlay.setNestOpen(!overlay.web.isOpen); refreshMenu() }
    @objc private func pause() { guard let overlay else { return }; overlay.setPaused(!overlay.motion.paused); refreshMenu() }
    @objc private func hide() { guard let overlay else { return }; overlay.visible.toggle(); refreshMenu() }
    @objc private func toggleHistory() { guard let overlay else { return }; overlay.rememberHistory.toggle(); refreshMenu() }
    @objc private func clearHistory() { overlay?.clearHistory(); refreshMenu() }
    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        if service.status == .enabled { try? service.unregister() } else { try? service.register() }
        refreshMenu()
    }
    @objc private func toggleHunt() { guard let overlay else { return }; overlay.huntMode.toggle(); refreshMenu() }
    @objc private func togglePaste() {
        guard let overlay else { return }
        overlay.pasteOnSelect.toggle(); pasteItem?.state = overlay.pasteOnSelect ? .on : .off
        if overlay.pasteOnSelect { PasteAssist.requestTrustIfNeeded() }
    }
    @objc private func openSettings() {
        guard let overlay else { return }
        if settings == nil { settings = SettingsWindow(overlay:overlay); settings?.onChange = { [weak self] in self?.refreshMenu() } }
        settings?.show()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func checkForUpdates() { Updater.shared.check(manual:true) }
    @objc private func about() {
        NSApp.activate(ignoringOtherApps:true)
        NSApp.orderFrontStandardAboutPanel(options:[
            .credits:NSAttributedString(string:"A clipboard manager with a spider.\nEverything stays on your Mac.\nsilknest.app",
                                        attributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.secondaryLabelColor]),
            NSApplication.AboutPanelOptionKey(rawValue:"Copyright"):"© 2026 SilkNest"])
    }

    /// Menu bar icon: a small spider, drawn as a template image so it follows the light/dark menu bar.
    static func menuBarIcon() -> NSImage {
        let image = NSImage(size:NSSize(width:18,height:18),flipped:true) { _ in
            NSColor.black.set()
            NSBezierPath(ovalIn:NSRect(x:7,y:8,width:4,height:6)).fill()
            NSBezierPath(ovalIn:NSRect(x:7.3,y:4.6,width:3.4,height:3.4)).fill()
            let legs = NSBezierPath(); legs.lineWidth = 1.3; legs.lineCapStyle = .round; legs.lineJoinStyle = .round
            for side: CGFloat in [-1,1] {
                let x: CGFloat = 9+side*1.6
                for (hip,knee,foot) in [(5.6,(9+side*4.5,2.4),(9+side*6.2,0.8)),(7.0,(9+side*5.6,5.4),(9+side*8.2,4.6)),
                                         (9.6,(9+side*5.6,10.2),(9+side*8.2,11.8)),(11.2,(9+side*4.4,13.6),(9+side*6.0,16.8))] {
                    legs.move(to:NSPoint(x:x,y:hip)); legs.line(to:NSPoint(x:knee.0,y:knee.1)); legs.line(to:NSPoint(x:foot.0,y:foot.1))
                }
            }
            legs.stroke(); return true
        }
        image.isTemplate = true
        return image
    }

    /// Development-only command channel for driving the real overlay in verification runs.
    /// Commands are names only; no clipboard content is ever sent or printed.
    private func startAutomation() {
        DistributedNotificationCenter.default().addObserver(forName:Notification.Name("studio.webber.automation"),object:nil,queue:.main) { [weak self] note in
            guard let overlay = self?.overlay, let command = note.object as? String else { return }
            overlay.automation(command); self?.refreshMenu()
            DispatchQueue.main.asyncAfter(deadline:.now()+0.05) {
                if let data = try? JSONSerialization.data(withJSONObject:overlay.automationState(),options:[.sortedKeys]), let text = String(data:data,encoding:.utf8) {
                    print("WEBBER-STATE \(text)"); fflush(stdout)
                }
            }
        }
        print("WEBBER: automation channel ready"); fflush(stdout)
    }
}
