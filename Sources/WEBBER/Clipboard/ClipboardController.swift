import AppKit

/// The single "catch my clipboard" command, plus the runtime-only set of caught items.
/// Passive mode is the default: nothing observes ordinary Cmd+C.
final class ClipboardController {
    /// History length. Large items live on disk (see HistoryStore), so this costs little memory.
    static let capacity = 1000
    private(set) var items: [ClipboardItem] = []
    private var nextID = 1
    /// Avoids catching the same unchanged pasteboard twice in a row.
    private var lastCaught: (board: String, changeCount: Int)?

    enum CatchOutcome { case caught(ClipboardItem), alreadyCaught, concealed, empty }

    func catchCurrent(_ board: NSPasteboard = .general) -> CatchOutcome {
        if let lastCaught, lastCaught.board == board.name.rawValue, lastCaught.changeCount == board.changeCount, items.contains(where: { $0.id == nextID-1 }) { return .alreadyCaught }
        switch PasteboardReader.read(board,id:nextID) {
        case .empty: return .empty
        case .concealed: return .concealed
        case .item(let item):
            nextID += 1; lastCaught = (board.name.rawValue,board.changeCount)
            if board.name == .general {
                let source = NSWorkspace.shared.frontmostApplication
                item.sourceName = source?.localizedName; item.sourceBundleID = source?.bundleIdentifier
            }
            // Detected secrets: masked and memory-only, or not caught at all (Settings).
            if [.text,.code,.url].contains(item.kind), let text = item.text,
               let finding = SecretDetector.detect(text,source:item.sourceBundleID) {
                if SecretGuard.neverCatchSecrets { return .concealed }
                if SecretGuard.protectSecrets { item.markSecret(finding) }
            }
            // Credentials and password-manager copies stay in memory only.
            item.neverPersist = SecretGuard.isSensitive(item)
            return .caught(item)
        }
    }

    /// Restore saved history at launch; new ids continue after the highest saved one.
    func adopt(_ restored: [ClipboardItem]) {
        // Already limited by HistoryStore (newest first, pinned always kept).
        items = restored
        nextID = (items.map(\.id).max() ?? 0)+1
    }

    func clearUnpinned() {
        let gone = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }
        for item in gone { item.discard(after:30) }
    }

    /// Development-safe capacity policy: the oldest unpinned item is released to make room.
    /// Returns the released item, or nil if there was room. Fails only when everything is pinned.
    func store(_ item: ClipboardItem) -> (stored: Bool, released: ClipboardItem?) {
        var released: ClipboardItem?
        if items.count >= Self.capacity {
            guard let oldest = items.first(where: { !$0.pinned }) else { return (false,nil) }
            remove(oldest); released = oldest
        }
        items.append(item)
        return (true,released)
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        // A drag-out receiver may still be reading the export file; clean it up shortly after.
        item.discard(after:30)
    }

    /// The same content caught earlier, if any.
    func existing(_ item: ClipboardItem) -> ClipboardItem? {
        let fp = item.fingerprint
        return items.first { $0.kind == item.kind && $0.fingerprint == fp }
    }

    /// Make an existing item the newest again (recency orders the Nest).
    func promote(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0 === item }) else { return }
        items.remove(at:index); items.append(item)
        item.timesCopied += 1; item.lastCopied = Date()
    }

    // MARK: Hunt mode

    /// The general pasteboard's change count already seen by Hunt mode (our own writes included).
    private(set) var seenChangeCount = NSPasteboard.general.changeCount

    /// Hunt mode: a new copy happened since we last looked. Returns a new item to catch, nothing for
    /// concealed/empty/duplicate content (a duplicate is promoted to newest instead).
    func huntNewCopy(shouldCatch: (NSRunningApplication?) -> Bool = { _ in true }) -> (item: ClipboardItem?, promoted: ClipboardItem?) {
        let board = NSPasteboard.general
        guard board.changeCount != seenChangeCount else { return (nil,nil) }
        seenChangeCount = board.changeCount
        guard shouldCatch(NSWorkspace.shared.frontmostApplication) else { return (nil,nil) }
        // Never auto-catch from a password manager. A detected secret is caught masked and memory-only
        // (protectSecrets; "never catch secrets" refuses it in catchCurrent); other memory-only copies are skipped.
        guard !Self.huntSkips(frontmost:NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else { return (nil,nil) }
        guard case .caught(let item) = catchCurrent(board), !item.neverPersist || item.isSecret else { return (nil,nil) }
        if let old = existing(item) { promote(old); return (nil,old) }
        return (item,nil)
    }

    /// Hunt never reads a copy made in a password manager or in an app the user excluded
    /// (Settings or the menu bar); the pasteboard is not even opened.
    static func huntSkips(frontmost bundleID: String?, _ defaults: UserDefaults = .standard) -> Bool {
        SecretGuard.fromPasswordManager(bundleID) || ExcludedApps.contains(bundleID,defaults)
    }

    /// A screenshot saved as a file, caught as an image (the original bytes are what Copy Again restores).
    func screenshot(at url: URL) -> ClipboardItem? {
        guard let size = try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,
              size <= PasteboardReader.maxImageBytes else { return nil }
        guard let data = try? Data(contentsOf:url), data.count <= PasteboardReader.maxImageBytes, let image = NSImage(data:data) else { return nil }
        let png = url.pathExtension.lowercased() == "png" ? data : (ItemPreview.png(image) ?? data)
        let item = ClipboardItem(id:nextID,kind:.image,representations:[(.png,png)],text:nil,url:nil,fileURLs:[],image:image)
        nextID += 1
        item.sourceName = "Screenshot"; item.sourceFile = url
        if let old = existing(item) { promote(old); return nil }
        return item
    }

    func copyAgain(_ item: ClipboardItem) {
        item.restore()
        // Our own write must not look like a fresh copy to the duplicate guard.
        lastCaught = (NSPasteboard.general.name.rawValue,NSPasteboard.general.changeCount)
        seenChangeCount = NSPasteboard.general.changeCount
        promote(item)
    }

    /// Smart paste: put plain text on the pasteboard without Hunt mode catching it as a new copy.
    func writeString(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents(); board.setString(text,forType:.string)
        lastCaught = (board.name.rawValue,board.changeCount)
        seenChangeCount = board.changeCount
    }

    enum OCROutcome { case clean, secret, refuse }

    /// The text read from an image has arrived. A secret in it makes the image a secret (memory only,
    /// blurred, removed after two minutes), or, with "Never catch secrets", it must be let go.
    /// Until this runs a new image is not written to disk.
    @discardableResult func applyRecognizedText(_ text: String?, to item: ClipboardItem) -> OCROutcome {
        item.awaitingOCR = false
        guard let text else { return .clean }            // couldn't read it now: stored, read again next launch
        item.recognizedText = text
        return checkImageForSecret(item)
    }

    /// Also used for history restored from disk (images read before secret detection existed).
    func checkImageForSecret(_ item: ClipboardItem) -> OCROutcome {
        guard item.kind == .image, !item.isSecret, let text = item.recognizedText, !text.isEmpty,
              let finding = SecretDetector.detect(text,source:item.sourceBundleID) else { return item.isSecret ? .secret : .clean }
        if SecretGuard.neverCatchSecrets { return .refuse }
        guard SecretGuard.protectSecrets else { return .clean }
        item.markSecret(finding)
        return .secret
    }

    func open(_ item: ClipboardItem) {
        if let target = item.exportedFile() { NSWorkspace.shared.open(target) }
    }
}
