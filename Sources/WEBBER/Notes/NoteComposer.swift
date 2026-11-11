import AppKit

/// Accepts typing while the user's working app remains active.
final class ComposerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A small silk fragment with a real, scrollable editor. Return adds a line;
/// Return hangs the thought (Shift-Return for a new line), Escape cancels, and clicking away saves it.
final class NoteComposer: NSObject, NSTextViewDelegate {
    private let panel: ComposerPanel
    private let editor = NSTextView()
    private let scroll = NSScrollView()
    private let placeholder = NSTextField(labelWithString:"What would you like to remember?")
    private let heading = NSTextField(labelWithString:"SILK NOTE")
    private let hint = NSTextField(labelWithString:"↩ save · ⇧↩ new line · esc cancel")
    private let saveButton = NSButton(title:"Hang note",target:nil,action:nil)
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private(set) var isOpen = false
    var onCommit: ((String, NSRect) -> Void)?
    var onClose: (() -> Void)?
    static let width: CGFloat = 320

    override init() {
        panel = ComposerPanel(contentRect:NSRect(x:0,y:0,width:Self.width,height:156),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue:NSWindow.Level.statusBar.rawValue+8)
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false; panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named:.darkAqua)

        let blur = NSVisualEffectView(frame:panel.contentView!.bounds)
        blur.material = .hudWindow; blur.blendingMode = .behindWindow; blur.state = .active
        blur.wantsLayer = true; blur.layer?.cornerRadius = 14; blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.75
        blur.layer?.borderColor = NSColor(srgbRed:1,green:0.76,blue:0.35,alpha:0.28).cgColor
        blur.autoresizingMask = [.width,.height]; panel.contentView = blur

        heading.font = .systemFont(ofSize:10,weight:.semibold)
        heading.textColor = NSColor(srgbRed:1,green:0.76,blue:0.35,alpha:0.9)
        heading.frame = NSRect(x:16,y:126,width:Self.width-32,height:14)
        heading.autoresizingMask = [.width,.minYMargin]; blur.addSubview(heading)

        scroll.frame = NSRect(x:12,y:42,width:Self.width-24,height:76)
        scroll.autoresizingMask = [.width,.height]
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        editor.frame = NSRect(origin:.zero,size:scroll.contentSize)
        editor.isRichText = false; editor.importsGraphics = false; editor.drawsBackground = false
        editor.allowsUndo = true
        editor.font = .systemFont(ofSize:14); editor.textColor = NSColor(white:0.96,alpha:1)
        editor.insertionPointColor = NSColor(srgbRed:1,green:0.76,blue:0.35,alpha:1)
        editor.textContainerInset = NSSize(width:4,height:6)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width:0,height:scroll.contentSize.height)
        editor.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width:scroll.contentSize.width,height:CGFloat.greatestFiniteMagnitude)
        editor.delegate = self
        editor.setAccessibilityLabel("Note text")
        scroll.documentView = editor; blur.addSubview(scroll)
        placeholder.font = editor.font; placeholder.textColor = NSColor(white:1,alpha:0.38)
        placeholder.frame = NSRect(x:21,y:91,width:Self.width-42,height:20)
        placeholder.autoresizingMask = [.width,.minYMargin]
        blur.addSubview(placeholder)

        hint.font = .systemFont(ofSize:10,weight:.medium); hint.textColor = NSColor(white:1,alpha:0.5)
        hint.frame = NSRect(x:16,y:14,width:190,height:14); blur.addSubview(hint)
        saveButton.frame = NSRect(x:Self.width-106,y:8,width:92,height:28)
        saveButton.bezelStyle = .rounded; saveButton.controlSize = .small
        saveButton.font = .systemFont(ofSize:11,weight:.semibold)
        saveButton.contentTintColor = NSColor(srgbRed:1,green:0.76,blue:0.35,alpha:1)
        saveButton.target = self; saveButton.action = #selector(saveNote)
        saveButton.keyEquivalent = "\r"; saveButton.keyEquivalentModifierMask = [.command]
        blur.addSubview(saveButton)
    }

    func open(near point: NSPoint, text: String = "") {
        if isOpen { close(commit:true) }
        editor.string = text
        editor.undoManager?.removeAllActions()
        heading.stringValue = text.isEmpty ? "SILK NOTE" : "EDIT SILK NOTE"
        saveButton.title = text.isEmpty ? "Hang note" : "Save note"
        updateContent()
        guard let screen = NSScreen.screens.first(where:{ NSMouseInRect(point,$0.frame,false) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame.insetBy(dx:12,dy:12)
        let height = min(panel.frame.height,area.height)
        let origin = NSPoint(x:min(max(point.x+14,area.minX),area.maxX-Self.width),
                             y:min(max(point.y-height-12,area.minY),area.maxY-height))
        panel.setFrame(NSRect(origin:origin,size:NSSize(width:Self.width,height:height)),display:true)
        isOpen = true
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location:(text as NSString).length,length:0))
        editor.scrollRangeToVisible(editor.selectedRange())
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] _ in self?.close(commit:true) }
        // A click in another WEBBER window is local, so the global monitor alone cannot catch it.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] event in
            if let self, event.window !== self.panel { self.close(commit:true) }
            return event
        }
    }

    func close(commit: Bool) {
        guard isOpen else { return }
        isOpen = false
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }; outsideMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        let text = editor.string.trimmingCharacters(in:.whitespacesAndNewlines), frame = panel.frame
        panel.orderOut(nil)
        if commit && !text.isEmpty { onCommit?(text,frame) }
        onClose?()
    }

    @objc private func saveNote() {
        guard !editor.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        close(commit:true)
    }

    func commitForTesting(_ text: String) { editor.string = text; close(commit:true) }
    /// Recordings: text appears in the open composer as if typed (keys go to the recording's own app).
    func typeForTesting(_ text: String) { editor.insertText(text,replacementRange:editor.selectedRange()) }
    func commitOpenForTesting() { close(commit:true) }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() { close(commit:false); return true }
        // Return saves (a note is a short thought); Shift- or Option-Return adds a line break.
        if selector == #selector(NSResponder.insertNewline(_:)), NSEvent.modifierFlags.isDisjoint(with:[.shift,.option]) { saveNote(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { textView.insertNewlineIgnoringFieldEditor(nil); return true }
        return false
    }
    func textDidChange(_ notification: Notification) { updateContent() }

    private func updateContent() {
        placeholder.isHidden = !editor.string.isEmpty
        saveButton.isEnabled = !editor.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        guard let layout = editor.layoutManager, let container = editor.textContainer else { return }
        layout.ensureLayout(for:container)
        let contentHeight = max(76,min(240,layout.usedRect(for:container).height+16))
        var frame = panel.frame
        let total = contentHeight+80
        frame.origin.y += frame.height-total; frame.size.height = total
        if isOpen, let screen = panel.screen {
            let area = screen.visibleFrame.insetBy(dx:12,dy:12)
            frame.origin.y = min(max(frame.minY,area.minY),area.maxY-frame.height)
        }
        panel.setFrame(frame,display:true)
        editor.minSize.height = scroll.contentSize.height
    }
}
