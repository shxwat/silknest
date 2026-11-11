import AppKit
import ApplicationServices

/// The one permission SilkNest asks for (Accessibility, for 1-click paste), explained in plain words
/// before macOS asks. It watches for the switch and confirms by itself; nothing to restart.
final class PermissionWindow: NSObject, NSWindowDelegate {
    static let shared = PermissionWindow()
    private var window: NSWindow?
    private var timer: Timer?
    private let status = NSTextField(labelWithString:"")
    private let dot = NSView()
    private let primary = NSButton(title:"Open System Settings",target:nil,action:nil)
    private let secondary = NSButton(title:"Not Now",target:nil,action:nil)

    enum Reason { case firstTime, newSignature }
    private var reason = Reason.firstTime
    private let titleLabel = NSTextField(labelWithString:"")
    private let bodyLabel = NSTextField(wrappingLabelWithString:"")

    func show(_ reason: Reason = .firstTime) {
        self.reason = reason
        if window == nil { build() }
        applyText()
        refresh()
        NSApp.activate(ignoringOtherApps:true)
        window?.center(); window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval:0.8,repeats:true) { [weak self] _ in self?.refresh() }
    }

    private func build() {
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:440,height:300),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.isReleasedWhenClosed = false; w.delegate = self
        w.isMovableByWindowBackground = true

        let icon = NSImageView(image:NSApp.applicationIconImage); icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant:64).isActive = true; icon.heightAnchor.constraint(equalToConstant:64).isActive = true
        let title = titleLabel; title.font = .systemFont(ofSize:17,weight:.semibold)
        let body = bodyLabel
        body.font = .systemFont(ofSize:12.5); body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 360
        let steps = NSTextField(wrappingLabelWithString:"1.  Click Open System Settings\n2.  Turn on SilkNest under Privacy & Security → Accessibility")
        steps.font = .systemFont(ofSize:12.5)

        dot.wantsLayer = true; dot.layer?.cornerRadius = 4
        dot.widthAnchor.constraint(equalToConstant:8).isActive = true; dot.heightAnchor.constraint(equalToConstant:8).isActive = true
        status.font = .systemFont(ofSize:12,weight:.medium)
        let statusRow = NSStackView(views:[dot,status]); statusRow.spacing = 7; statusRow.alignment = .centerY

        primary.bezelStyle = .rounded; primary.keyEquivalent = "\r"; primary.target = self; primary.action = #selector(openSettings)
        secondary.bezelStyle = .rounded; secondary.target = self; secondary.action = #selector(dismiss)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let buttons = NSStackView(views:[statusRow,spacer,secondary,primary]); buttons.spacing = 10

        let stack = NSStackView(views:[icon,title,body,steps,buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.setCustomSpacing(16,after:steps)
        stack.edgeInsets = NSEdgeInsets(top:34,left:32,bottom:24,right:32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:content.leadingAnchor),stack.trailingAnchor.constraint(equalTo:content.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo:content.topAnchor),stack.bottomAnchor.constraint(equalTo:content.bottomAnchor),
                                     buttons.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-64),
                                     body.widthAnchor.constraint(equalToConstant:376),steps.widthAnchor.constraint(equalToConstant:376)])
        w.contentView = content
        window = w
    }

    private func applyText() {
        switch reason {
        case .firstTime:
            titleLabel.stringValue = "Turn on 1-click paste"
            bodyLabel.stringValue = "When you pick something from your clipboard history, SilkNest can paste it straight into the app you're using. macOS needs your OK for that, once.\n\nSilkNest uses Accessibility only to trigger paste into the active app. It does not record or store your keystrokes or screen contents."
        case .newSignature:
            titleLabel.stringValue = "One last time: turn on 1-click paste"
            bodyLabel.stringValue = "SilkNest now has a permanent signature, so macOS sees it as a new app and switched paste off. Turn it on once more and it stays on through every future update.\n\nSilkNest uses Accessibility only to trigger paste into the active app. It does not record or store your keystrokes or screen contents."
        }
    }

    private func refresh() {
        let on = PasteAssist.trusted
        status.stringValue = on ? "Paste is on" : "Waiting for permission…"
        status.textColor = on ? .systemGreen : .secondaryLabelColor
        dot.layer?.backgroundColor = (on ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        primary.title = on ? "Done" : "Open System Settings"
        primary.action = on ? #selector(dismiss) : #selector(openSettings)
        secondary.isHidden = on
        if on, timer != nil {
            timer?.invalidate(); timer = nil
            DispatchQueue.main.asyncAfter(deadline:.now()+1.6) { [weak self] in self?.window?.orderOut(nil) }
        }
    }

    @objc private func openSettings() {
        // Registers SilkNest in the Accessibility list (macOS shows its own one-time prompt), then opens that pane.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key:true] as CFDictionary)
        if let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func dismiss() { window?.orderOut(nil); timer?.invalidate(); timer = nil }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }
}
