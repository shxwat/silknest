import AppKit

/// Screenshots saved as files (⇧⌘3, ⇧⌘4, ⇧⌘5, the Screenshot app) never touch the clipboard, so the spider
/// watches for them. (Screenshots copied to the clipboard, ⌃⇧⌘3 / ⌃⇧⌘4, are caught like any other copy.)
///
/// Primary: the folder macOS saves screenshots to (the user's choice in ⇧⌘5 → Options, Desktop by default)
/// is watched directly, and a new file counts as a screenshot when it carries the marker macOS writes on
/// every screenshot (the kMDItemIsScreenCapture extended attribute). That is instant and doesn't depend on
/// Spotlight, which can lag minutes behind or not index the Desktop at all.
/// Backup: a Spotlight query for screenshots anywhere in the home folder.
/// Only screenshots taken while SilkNest is running are reported; nothing is uploaded.
final class ScreenshotWatcher {
    private let query = NSMetadataQuery()
    private let started = Date()
    private var seen = Set<String>()
    private var folder: URL?
    private var source: DispatchSourceFileSystemObject?
    private var locationTimer: Timer?
    private var scanRetries: [DispatchWorkItem] = []
    var onScreenshot: ((URL) -> Void)?
    /// The folder exists but macOS won't let SilkNest look inside it (Files & Folders permission).
    var onFolderDenied: ((URL) -> Void)?

    init() {
        // Historical screenshots are never caught, so don't load their metadata into memory.
        query.predicate = NSPredicate(format:"kMDItemIsScreenCapture == 1 && kMDItemFSCreationDate > %@",started as NSDate)
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        let center = NotificationCenter.default
        center.addObserver(self,selector:#selector(spotlightUpdate),name:.NSMetadataQueryDidFinishGathering,object:query)
        center.addObserver(self,selector:#selector(spotlightUpdate),name:.NSMetadataQueryDidUpdate,object:query)
    }

    func start() {
        if !query.isStarted, DevFlags.env("WEBBER_NO_SPOTLIGHT") == nil { query.start() }
        watchCurrentLocation()
        // The save location can be changed at any time in ⇧⌘5 → Options.
        locationTimer?.invalidate()
        locationTimer = Timer.scheduledTimer(withTimeInterval:10,repeats:true) { [weak self] _ in self?.watchCurrentLocation() }
    }

    func stop() {
        query.stop(); source?.cancel(); source = nil; locationTimer?.invalidate(); locationTimer = nil
        for retry in scanRetries { retry.cancel() }; scanRetries.removeAll()
    }

    /// Where macOS saves screenshots right now.
    static var saveFolder: URL {
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        if let path = CFPreferencesCopyAppValue("location" as CFString,"com.apple.screencapture" as CFString) as? String, !path.isEmpty {
            let url = URL(fileURLWithPath:(path as NSString).expandingTildeInPath,isDirectory:true)
            var dir: ObjCBool = false
            if FileManager.default.fileExists(atPath:url.path,isDirectory:&dir), dir.boolValue { return url }
        }
        return FileManager.default.urls(for:.desktopDirectory,in:.userDomainMask)[0]
    }

    private func watchCurrentLocation() {
        let target = Self.saveFolder.standardizedFileURL
        guard target != folder else { return }
        source?.cancel(); source = nil; folder = target
        // Listing the folder once also lets macOS ask for access to it now, not at the first screenshot.
        guard (try? FileManager.default.contentsOfDirectory(atPath:target.path)) != nil else {
            if FileManager.default.fileExists(atPath:target.path) { onFolderDenied?(target) }
            folder = nil   // try again on the next timer tick (access may be granted later)
            return
        }
        let fd = open(target.path,O_EVTONLY)
        guard fd >= 0 else { folder = nil; return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd,eventMask:[.write,.extend,.rename,.link],queue:.main)
        s.setEventHandler { [weak self] in self?.scanSoon() }
        s.setCancelHandler { close(fd) }
        s.resume(); source = s
    }

    /// macOS may add the screenshot marker a moment after the file appears: look now and again shortly.
    private func scanSoon() {
        // A burst of folder writes needs one set of marker retries, rather than one per event.
        for retry in scanRetries { retry.cancel() }; scanRetries.removeAll()
        scan()
        for delay in [0.25,0.8,2.0] {
            let retry = DispatchWorkItem { [weak self] in self?.scan() }
            scanRetries.append(retry)
            DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:retry)
        }
    }

    private func scan() {
        guard let folder else { return }
        let keys: [URLResourceKey] = [.creationDateKey,.isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:keys,options:[.skipsHiddenFiles]) else { return }
        for url in files where Self.isImage(url) && !seen.contains(url.path) {
            guard let v = try? url.resourceValues(forKeys:Set(keys)), v.isRegularFile == true,
                  let created = v.creationDate, created > started, Self.isScreenCapture(url) else { continue }
            report(url)
        }
    }

    @objc private func spotlightUpdate() {
        query.disableUpdates(); defer { query.enableUpdates() }
        for case let result as NSMetadataItem in query.results {
            guard let path = result.value(forAttribute:NSMetadataItemPathKey) as? String, !seen.contains(path) else { continue }
            let created = result.value(forAttribute:NSMetadataItemFSCreationDateKey) as? Date ?? .distantPast
            // Older screenshots are only remembered as seen, never caught.
            guard created > started else { seen.insert(path); continue }
            let url = URL(fileURLWithPath:path)
            if Self.isImage(url) { report(url) } else { seen.insert(path) }
        }
    }

    private func report(_ url: URL) {
        guard seen.insert(url.path).inserted else { return }
        onScreenshot?(url)
    }

    private static let imageExtensions: Set<String> = ["png","jpg","jpeg","heic","heif","tif","tiff","gif","bmp","pdf"]
    static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }

    /// The marker macOS writes on every screenshot file, whatever it is called or wherever it is saved.
    static func isScreenCapture(_ url: URL) -> Bool {
        getxattr(url.path,"com.apple.metadata:kMDItemIsScreenCapture",nil,0,0,0) > 0
    }

    deinit { NotificationCenter.default.removeObserver(self); stop() }
}
