import AppKit
import CryptoKit
import Security

/// Automatic updates from silknest.app. Only a small version file is fetched; nothing about the user
/// or their clipboard is ever sent.
///
/// An update is installed only if all of these hold, in this order:
///   1. version.json carries a valid Ed25519 signature over "version|sha256" from SilkNest's release key
///      (the private half never ships; only the public half is built into the app). This is what proves
///      the update comes from the publisher; it is checked before anything is downloaded;
///   2. the version is newer than this one (an old signed file cannot roll the app back);
///   3. the zip comes from silknest.app over HTTPS and matches the signed SHA-256 byte for byte;
///   4. the app inside passes a strict code-signature check against this app's own designated requirement:
///      once SilkNest is signed with its certificate, only builds signed with that same certificate are
///      accepted (see updateRequirement; the certificate is self-signed, not Developer ID, not notarized).
///
/// It checks 20 seconds after launch, every 3 hours, and when the Mac wakes. The new app replaces this one
/// in place; if this copy can't be replaced (opened from a disk image or Downloads, or a folder it can't
/// write to), the update goes into Applications instead and opens from there. If that fails too, a small
/// window says so once per version, with the one-line fix. History, notes and settings are never touched.
final class Updater {
    static let shared = Updater()
    static let feed = URL(string:"https://silknest.app/version.json")!
    private static let publicKey = "lgjZ7Kd7r8C5eE7vWr+qh8BlfiVFXTgGxZa1Ay3UugU="
    static let installCommand = "curl -fsSL https://silknest.app/install.sh | sh"
    private var timer: Timer?
    private var busy = false
    private var lastCheck: Date = .distantPast
    /// Called just before the app is replaced, to save notes and history.
    var willRelaunch: (() -> Void)?

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey:"autoUpdate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue,forKey:"autoUpdate") }
    }
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0" }

    func start() {
        // Development builds never update (they would be replaced by the official app).
        guard BuildFlavor.isOfficial, !DevFlags.has("--automation"), Bundle.main.bundleURL.pathExtension == "app" else { return }
        DispatchQueue.main.asyncAfter(deadline:.now()+20) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval:3*3600,repeats:true) { [weak self] _ in self?.check() }
        // A laptop that sleeps more than it runs still hears about updates soon after it wakes.
        NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.lastCheck) > 30*60 else { return }
            DispatchQueue.main.asyncAfter(deadline:.now()+15) { self.check() }
        }
    }

    private struct Feed: Decodable { let version: String; let url: String; let sha256: String; let signature: String }

    /// `manual`: from "Check for Updates…" — runs even with automatic updates off, and always says what happened.
    func check(manual: Bool = false) {
        guard BuildFlavor.isOfficial else {
            if manual { say("Updates are off in this build","This is a development build of SilkNest; it doesn't update itself.") }
            return
        }
        guard (Self.enabled || manual), !busy else { return }
        busy = true; lastCheck = Date()
        var request = URLRequest(url:Self.feed); request.cachePolicy = .reloadIgnoringLocalCacheData; request.timeoutInterval = 20
        URLSession.shared.dataTask(with:request) { [weak self] data, _, _ in
            guard let self else { return }
            guard let data, let feed = try? JSONDecoder().decode(Feed.self,from:data), self.verify(feed),
                  let url = URL(string:feed.url), url.scheme == "https", url.host == Self.feed.host else {
                self.busy = false
                if manual { self.say("Couldn't reach silknest.app","Check your internet connection and try again.") }
                return
            }
            guard Self.isNewer(feed.version,than:Self.currentVersion) else {
                self.busy = false
                if manual { self.say("SilkNest is up to date","You have version \(Self.currentVersion), the latest.") }
                return
            }
            self.download(url,feed:feed,manual:manual)
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator:".").map { Int($0) ?? 0 }, y = b.split(separator:".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count,y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private func verify(_ feed: Feed) -> Bool {
        guard let keyData = Data(base64Encoded:Self.publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation:keyData),
              let sig = Data(base64Encoded:feed.signature) else { return false }
        return key.isValidSignature(sig,for:Data("\(feed.version)|\(feed.sha256)".utf8))
    }

    private func download(_ url: URL, feed: Feed, manual: Bool) {
        URLSession.shared.downloadTask(with:url) { [weak self] file, _, _ in
            guard let self else { return }
            guard let file, let data = try? Data(contentsOf:file),
                  SHA256.hash(data:data).map({ String(format:"%02x",$0) }).joined() == feed.sha256.lowercased() else {
                self.busy = false
                if manual { self.say("The update didn't download","SilkNest will try again later.") }
                return
            }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("SilkNest-update-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
            let zip = work.appendingPathComponent("SilkNest.zip")
            let fresh = work.appendingPathComponent("SilkNest.app")
            guard (try? data.write(to:zip)) != nil, Self.run("/usr/bin/ditto",["-x","-k",zip.path,work.path]), Self.signatureIsValid(fresh) else {
                try? FileManager.default.removeItem(at:work); self.busy = false
                if manual { self.say("The update didn't pass its checks","Nothing was changed. SilkNest will try again later.") }
                return
            }
            DispatchQueue.main.async { self.install(fresh,work:work,version:feed.version,manual:manual) }
        }.resume()
    }

    static let bundleRequirement = "identifier \"studio.webber.spider\""

    /// What an update must satisfy: this app's own designated requirement. Signed with the SilkNest
    /// certificate, that is "this identifier, signed by that certificate", so only builds from the same
    /// certificate are accepted (and macOS keeps privacy permissions such as Accessibility across them).
    /// An ad-hoc build (1.2.2 and earlier, or a local build without the certificate) only has the
    /// identifier, which is how it accepts the first certificate-signed update.
    static func updateRequirement() -> String {
        var me: SecCode?, staticMe: SecStaticCode?, dr: SecRequirement?, text: CFString?
        guard SecCodeCopySelf([],&me) == errSecSuccess, let me, SecCodeCopyStaticCode(me,[],&staticMe) == errSecSuccess, let staticMe,
              SecCodeCopyDesignatedRequirement(staticMe,[],&dr) == errSecSuccess, let dr,
              SecRequirementCopyString(dr,[],&text) == errSecSuccess, let text else { return bundleRequirement }
        let requirement = text as String
        // An implicit ad-hoc requirement pins one exact build (cdhash): no update could ever match it.
        guard requirement.contains("studio.webber.spider"), !requirement.contains("cdhash") else { return bundleRequirement }
        return requirement
    }

    /// Whether this copy is signed with a certificate (not ad-hoc).
    static var isCertificateSigned: Bool { updateRequirement().contains("certificate") }

    static func signatureIsValid(_ app: URL, requirement text: String = updateRequirement()) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL,[],&code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString,[],&requirement) == errSecSuccess else { return false }
        let flags = SecCSFlags(rawValue:kSecCSCheckAllArchitectures|kSecCSCheckNestedCode|kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code,flags,requirement) == errSecSuccess
    }

    /// Where the new app goes: over this one when possible, otherwise into Applications.
    static func destination(for current: URL) -> URL? {
        let fm = FileManager.default
        // Opened straight from a disk image or Downloads, macOS runs a read-only copy from a random path.
        let translocated = current.path.contains("/AppTranslocation/") || current.path.hasPrefix("/Volumes/")
        if !translocated, fm.isWritableFile(atPath:current.deletingLastPathComponent().path) { return current }
        for folder in [URL(fileURLWithPath:"/Applications"),fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            try? fm.createDirectory(at:folder,withIntermediateDirectories:true)
            if fm.isWritableFile(atPath:folder.path) { return folder.appendingPathComponent("SilkNest.app") }
        }
        return nil
    }

    private func install(_ fresh: URL, work: URL, version: String, manual: Bool) {
        let fm = FileManager.default
        guard let target = Self.destination(for:Bundle.main.bundleURL) else {
            try? fm.removeItem(at:work); busy = false
            notice(version:version,manual:manual); return
        }
        willRelaunch?()
        let old = work.appendingPathComponent("SilkNest-old.app")
        let hadOld = fm.fileExists(atPath:target.path)
        do {
            if hadOld { try fm.moveItem(at:target,to:old) }
            do { try fm.moveItem(at:fresh,to:target) } catch {
                if hadOld { try? fm.moveItem(at:old,to:target) }
                throw error
            }
        } catch {
            try? fm.removeItem(at:work); busy = false
            notice(version:version,manual:manual); return
        }
        UserDefaults.standard.set(Self.currentVersion,forKey:"updatedFrom")
        // Open the new version once this one has quit.
        let p = Process(); p.executableURL = URL(fileURLWithPath:"/bin/sh")
        p.arguments = ["-c","sleep 1; /usr/bin/open \"$0\"; rm -rf \"$1\"",target.path,work.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: telling the user

    /// The update is ready but couldn't be installed: say so once per version (every time when asked).
    private func notice(version: String, manual: Bool) {
        let key = "updateNoticeShown-\(version)"
        guard manual || !UserDefaults.standard.bool(forKey:key) else { return }
        UserDefaults.standard.set(true,forKey:key)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps:true)
            let alert = NSAlert()
            alert.messageText = "SilkNest \(version) is ready"
            alert.informativeText = "SilkNest couldn't replace itself where it's installed. Paste this line into Terminal to update — your history, notes and settings stay as they are:\n\n\(Self.installCommand)"
            alert.addButton(withTitle:"Copy Command"); alert.addButton(withTitle:"Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Self.installCommand,forType:.string)
            }
        }
    }

    private func say(_ title: String, _ text: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps:true)
            let alert = NSAlert(); alert.messageText = title; alert.informativeText = text
            alert.runModal()
        }
    }

    /// Right after an update: a small note in the corner that it happened.
    func announceIfUpdated() {
        guard let from = UserDefaults.standard.string(forKey:"updatedFrom") else { return }
        UserDefaults.standard.removeObject(forKey:"updatedFrom")
        guard from != Self.currentVersion else { return }
        DispatchQueue.main.asyncAfter(deadline:.now()+1.5) { UpdateToast.show("SilkNest updated to \(Self.currentVersion)") }
    }

    @discardableResult private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath:tool); p.arguments = args
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit(); return p.terminationStatus == 0
    }
}

/// A short-lived note under the menu bar, top right. Click-through; fades out by itself.
enum UpdateToast {
    private static var panel: NSPanel?

    static func show(_ text: String) {
        // The screen with the menu bar, where people look for news about a menu-bar app.
        guard let screen = NSScreen.screens.first else { return }
        let label = NSTextField(labelWithString:text)
        label.font = .systemFont(ofSize:13,weight:.semibold); label.textColor = NSColor(white:1,alpha:0.95)
        let size = label.intrinsicContentSize
        let w = size.width+62, h: CGFloat = 44
        let v = screen.visibleFrame
        let p = NSPanel(contentRect:NSRect(x:v.maxX-w-16,y:v.maxY-h-12,width:w,height:h),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue:NSWindow.Level.statusBar.rawValue+8)
        p.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary,.ignoresCycle]
        p.animationBehavior = .none; p.isReleasedWhenClosed = false
        let box = NSVisualEffectView(frame:NSRect(x:0,y:0,width:w,height:h))
        box.material = .hudWindow; box.blendingMode = .behindWindow; box.state = .active; box.appearance = NSAppearance(named:.darkAqua)
        box.wantsLayer = true; box.layer?.cornerRadius = 12; box.layer?.masksToBounds = true
        box.layer?.borderWidth = 1; box.layer?.borderColor = NSColor(srgbRed:1,green:0.78,blue:0.32,alpha:0.4).cgColor
        let icon = NSImageView(frame:NSRect(x:14,y:(h-22)/2,width:22,height:22)); icon.image = MiniSpider.image
        label.frame = NSRect(x:44,y:(h-size.height)/2,width:size.width+4,height:size.height)
        box.addSubview(icon); box.addSubview(label); p.contentView = box
        panel?.orderOut(nil); panel = p
        p.alphaValue = 0; p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline:.now()+4.5) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; p.animator().alphaValue = 0 }) { p.orderOut(nil); if panel === p { panel = nil } }
        }
    }
}
