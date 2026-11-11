import AppKit
import ServiceManagement

/// WEBBER's only window: shortcuts and a few switches. Everything takes effect immediately.
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private weak var overlay: OverlayController?
    private var statusLabels: [ShortcutAction: NSTextField] = [:]
    private var recorders: [ShortcutAction: ShortcutRecorder] = [:]
    private let pasteStatus = NSTextField(labelWithString:"")
    private let pasteButton = NSButton(title:"Enable…",target:nil,action:nil)
    var onChange: (() -> Void)?

    init(overlay: OverlayController) {
        self.overlay = overlay
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:820),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        super.init()
        window.title = "SilkNest Settings"; window.isReleasedWhenClosed = false; window.delegate = self
        build()
    }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps:true)
        window.center(); window.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top:22,left:26,bottom:22,right:26)
        stack.addArrangedSubview(heading("Shortcuts"))
        let grid = NSGridView(); grid.rowSpacing = 10; grid.columnSpacing = 12
        for action in ShortcutAction.allCases {
            let recorder = ShortcutRecorder(shortcut:action.shortcut)
            recorder.onChange = { [weak self] s in action.save(s); self?.apply() }
            recorders[action] = recorder
            let reset = NSButton(title:"Reset",target:self,action:#selector(resetShortcut(_:)))
            reset.bezelStyle = .rounded; reset.tag = ShortcutAction.allCases.firstIndex(of:action)!
            let status = NSTextField(labelWithString:""); status.font = .systemFont(ofSize:11); status.textColor = .systemRed
            statusLabels[action] = status
            grid.addRow(with:[label(action.title),recorder,reset,status])
        }
        grid.column(at:0).width = 210
        for i in 0..<grid.numberOfRows { grid.row(at:i).height = 30; grid.row(at:i).yPlacement = .center }
        stack.addArrangedSubview(grid)
        stack.addArrangedSubview(note("Click a shortcut, then press the new keys. Esc cancels, ⌫ clears."))

        stack.addArrangedSubview(heading("When you choose an item"))
        let returnChoice = NSPopUpButton(); returnChoice.addItems(withTitles:["Paste it into the app (recommended)","Only copy it"])
        returnChoice.selectItem(at:(overlay?.pasteOnSelect ?? false) ? 0 : 1)
        returnChoice.target = self; returnChoice.action = #selector(returnChanged(_:))
        stack.addArrangedSubview(row([label("Return ↩"),returnChoice]))
        pasteButton.target = self; pasteButton.action = #selector(enablePaste); pasteButton.bezelStyle = .rounded
        pasteStatus.font = .systemFont(ofSize:12)
        stack.addArrangedSubview(row([label("Direct paste"),pasteStatus,pasteButton]))
        stack.addArrangedSubview(note("SilkNest uses Accessibility only to trigger paste into the active app."))
        stack.addArrangedSubview(note("It does not record or store your keystrokes or screen contents."))

        stack.addArrangedSubview(heading("Behaviour"))
        stack.addArrangedSubview(toggle("Catch every copy automatically (Hunt)",on:overlay?.huntMode ?? true,#selector(huntChanged(_:))))
        stack.addArrangedSubview(toggle("Catch ⇧⌘3 / ⇧⌘4 screenshots instantly (hides macOS's floating preview)",on:ScreenshotPreview.instant,#selector(instantShotsChanged(_:))))
        stack.addArrangedSubview(toggle("Ignore text that terminals copy on selection (iTerm2…)",on:overlay?.ignoreSelectionCopies ?? true,#selector(selectionChanged(_:))))
        stack.addArrangedSubview(toggle("Remember history after restart",on:overlay?.rememberHistory ?? true,#selector(historyChanged(_:))))
        stack.addArrangedSubview(toggle("Update SilkNest automatically",on:Updater.enabled,#selector(autoUpdateChanged(_:))))
        stack.addArrangedSubview(toggle("Open SilkNest at login",on:SMAppService.mainApp.status == .enabled,#selector(loginChanged(_:))))
        stack.addArrangedSubview(toggle("Show a macOS notification when a Silk Note reminder is due",on:NotesController.notificationsEnabled,#selector(noteNotificationsChanged(_:))))

        stack.addArrangedSubview(heading("Privacy"))
        stack.addArrangedSubview(toggle("Protect secrets (keys, tokens, codes, cards): masked, never saved, gone after 2 min",
                                        on:SecretGuard.protectSecrets,#selector(protectSecretsChanged(_:))))
        stack.addArrangedSubview(toggle("Never catch secrets at all",on:SecretGuard.neverCatchSecrets,#selector(neverCatchSecretsChanged(_:))))
        let clear = NSButton(title:"Clear History…",target:self,action:#selector(clearHistory)); clear.bezelStyle = .rounded
        stack.addArrangedSubview(row([clear,note("Pinned items are kept.")]))
        stack.addArrangedSubview(note("Clipboard history, screenshots, OCR text and notes never leave your Mac."))
        stack.addArrangedSubview(note("SilkNest only connects to silknest.app to check for and download updates."))
        let uninstall = NSButton(title:"Uninstall SilkNest…",target:self,action:#selector(uninstallApp)); uninstall.bezelStyle = .rounded
        stack.addArrangedSubview(row([uninstall,note("Restores macOS's screenshot preview; your data is kept unless you choose otherwise.")]))
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? ""
        stack.addArrangedSubview(note("SilkNest \(version) · silknest.app"))
        window.contentView = stack
    }

    private func heading(_ s: String) -> NSTextField { let l = NSTextField(labelWithString:s); l.font = .systemFont(ofSize:13,weight:.semibold); return l }
    private func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString:s); l.font = .systemFont(ofSize:13); return l }
    private func note(_ s: String) -> NSTextField { let l = NSTextField(labelWithString:s); l.font = .systemFont(ofSize:11); l.textColor = .secondaryLabelColor; return l }
    private func row(_ views: [NSView]) -> NSStackView { let r = NSStackView(views:views); r.spacing = 10; return r }
    private func toggle(_ title: String, on: Bool, _ action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle:title,target:self,action:action); b.state = on ? .on : .off; return b
    }

    /// Re-register shortcuts and show any that could not be taken (in use by another app, or duplicated).
    private func apply() {
        let failed = overlay?.applyShortcuts() ?? []
        for action in ShortcutAction.allCases {
            let active = overlay?.activeShortcuts[action]
            let label = statusLabels[action]
            if failed.contains(action) {
                label?.stringValue = "Used by macOS or another SilkNest action — pick another"; label?.textColor = .systemRed
            } else if let active, let preferred = action.shortcut, active != preferred {
                label?.stringValue = "\(preferred.display) is used by macOS — using \(active.display)"; label?.textColor = .secondaryLabelColor
            } else { label?.stringValue = "" }
            recorders[action]?.shortcut = active ?? action.shortcut
        }
        onChange?()
    }

    private func refresh() {
        apply()
        let trusted = PasteAssist.trusted
        pasteStatus.stringValue = trusted ? "On ✓" : "Off — needs Accessibility"
        pasteStatus.textColor = trusted ? .systemGreen : .secondaryLabelColor
        pasteButton.isHidden = trusted
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    @objc private func resetShortcut(_ sender: NSButton) { ShortcutAction.allCases[sender.tag].reset(); apply() }
    @objc private func returnChanged(_ sender: NSPopUpButton) {
        overlay?.pasteOnSelect = sender.indexOfSelectedItem == 0; onChange?()
        if sender.indexOfSelectedItem == 0 { PasteAssist.requestTrustIfNeeded() }
    }
    @objc private func enablePaste() { PasteAssist.requestTrustIfNeeded() }
    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear your clipboard history?"
        alert.informativeText = "Everything SilkNest has caught will be deleted from this Mac, except pinned items. This can't be undone."
        alert.addButton(withTitle:"Clear History"); alert.addButton(withTitle:"Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for:window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.overlay?.clearHistory(); self?.onChange?() }
        }
    }
    /// macOS writes a saved screenshot only after its floating preview goes away (about 5 seconds);
    /// without the preview the file lands at once and the spider catches it at once.
    @objc private func instantShotsChanged(_ sender: NSButton) { ScreenshotPreview.setInstant(sender.state == .on) }
    @objc private func autoUpdateChanged(_ sender: NSButton) { Updater.enabled = sender.state == .on; if Updater.enabled { Updater.shared.check() } }
    @objc private func uninstallApp() { Uninstall.run(from:window) }
    @objc private func noteNotificationsChanged(_ sender: NSButton) { NotesController.notificationsEnabled = sender.state == .on }
    @objc private func protectSecretsChanged(_ sender: NSButton) { SecretGuard.protectSecrets = sender.state == .on }
    @objc private func neverCatchSecretsChanged(_ sender: NSButton) { SecretGuard.neverCatchSecrets = sender.state == .on }
    @objc private func huntChanged(_ sender: NSButton) { overlay?.huntMode = sender.state == .on; onChange?() }
    @objc private func selectionChanged(_ sender: NSButton) { overlay?.ignoreSelectionCopies = sender.state == .on }
    @objc private func historyChanged(_ sender: NSButton) { overlay?.rememberHistory = sender.state == .on; onChange?() }
    @objc private func loginChanged(_ sender: NSButton) {
        if sender.state == .on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        onChange?()
    }
}
