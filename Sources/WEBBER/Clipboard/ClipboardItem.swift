import AppKit

enum ClipboardKind: String { case text, code, url, image, file }

/// One intentionally caught pasteboard snapshot. Runtime-only: nothing here is written to disk
/// except a temporary export file created on demand for drag-out or Open.
final class ClipboardItem {
    let id: Int
    let kind: ClipboardKind
    let createdAt: Date
    /// The original pasteboard representations, restored verbatim by Copy Again.
    /// Large ones (images, big rich text) are dropped from memory once they are safely in the encrypted
    /// history and read back from disk only when needed, so a history of 1000 items stays small in memory.
    var representations: [(NSPasteboard.PasteboardType, Data)] { storedReps ?? repLoader?() ?? [] }
    private var storedReps: [(NSPasteboard.PasteboardType, Data)]?
    private var repLoader: (() -> [(NSPasteboard.PasteboardType, Data)])?
    /// The pasteboard types held, without loading them; and the history files they live in (once saved).
    private(set) var repTypes: [NSPasteboard.PasteboardType]
    var repFiles: [String]?
    /// Kept on disk only; `representations` reads them back on demand.
    var isOffloaded: Bool { storedReps == nil }
    /// In-memory size of the representations (0 once offloaded).
    var memoryBytes: Int { storedReps?.reduce(0) { $0+$1.1.count } ?? 0 }
    let text: String?
    let url: URL?
    let fileURLs: [URL]
    /// Full-resolution images are only retained by an open preview or an active OCR request.
    /// The original compressed pasteboard bytes remain available for exact Copy Again/export.
    private weak var cachedImage: NSImage?
    private let fallbackImage: NSImage?
    private let originalImageSize: NSSize?
    private lazy var imageDimensions: String = {
        if let size = Self.pixelSize(caption) { return "\(size.0)x\(size.1)" }
        return image?.representations.first.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? ""
    }()
    var image: NSImage? {
        if let image = cachedImage ?? fallbackImage { return image }
        guard let data = representations.first(where: { $0.0 == .png || $0.0 == .tiff })?.1,
              let image = NSImage(data:data) else { return nil }
        if let originalImageSize { image.size = originalImageSize }
        cachedImage = image
        return image
    }
    /// The physical object that hangs in the web, drawn when first needed (only hanging items need one).
    /// The web holds it while the item hangs; otherwise it is redrawn on demand.
    var preview: NSImage {
        if let previewCache { return previewCache }
        let drawn = isSecret && kind == .image ? ItemPreview.secretImage(thumbnailImage)
            : awaitingOCR && kind == .image ? ItemPreview.pendingImage(thumbnailImage)
            : isSecret ? ItemPreview.render(kind:.text,text:displayText,url:nil,fileURLs:[],image:nil)
            : ItemPreview.render(kind:kind,text:text,url:url,fileURLs:fileURLs,image:kind == .image ? thumbnailImage : nil)
        previewCache = drawn
        return drawn
    }
    private weak var previewCache: NSImage?
    /// Images: a small JPEG for the web (kept with the history, so a launch never decodes a screenshot).
    var thumbnail: Data?
    private var thumbnailImage: NSImage? {
        if thumbnail == nil, kind == .image,
           let data = representations.first(where: { $0.0 == .png || $0.0 == .tiff })?.1 ?? fallbackImage.flatMap({ ItemPreview.png($0) }) {
            thumbnail = ItemPreview.thumbnailJPEG(from:data)
        }
        guard let thumbnail, let image = NSImage(data:thumbnail) else { return kind == .image ? image : nil }
        // Draw at the original's proportions in points.
        if let size = Self.pixelSize(caption), size.0 > 0 { image.size = NSSize(width:size.0,height:size.1) }
        return image
    }
    /// Short hover metadata ("image · 1200×800", "42 characters").
    private(set) var caption: String
    /// A secret (API key, token, one-time code, card number…): shown masked, kept in memory only.
    private(set) var secretKind: SecretDetector.Kind?
    private var maskedText: String?
    /// What the Nest shows and searches: the text, masked when it is a secret. Paste uses the real value.
    var displayText: String? { maskedText ?? text }
    var isSecret: Bool { secretKind != nil }

    func markSecret(_ finding: SecretDetector.Finding) {
        if kind == .image {
            // An image whose text holds a secret: shown blurred, its text never searchable.
            secretKind = finding.kind
            caption = "image · contains a secret (\(finding.kind.rawValue))"
            neverPersist = true; previewCache = nil; searchCache = nil; blurredCache = nil
            return
        }
        guard let text else { return }
        secretKind = finding.kind; maskedText = SecretDetector.masked(text,finding)
        caption = "secret · \(finding.kind.rawValue)"
        neverPersist = true; previewCache = nil; searchCache = nil
    }

    /// Set for a Silk Note shown in the Nest's search (a transient item, never stored).
    var noteID: UUID?

    /// A newly caught image is not written to disk until its text has been read and checked for secrets,
    /// and is drawn slightly blurred until then (the catch animation never shows a secret, even briefly).
    var awaitingOCR = false { didSet { if awaitingOCR != oldValue { previewCache = nil } } }
    /// A screenshot caught from a saved file: where that file is (for "move it to the Trash?").
    var sourceFile: URL?

    /// What the Nest shows for an image: blurred when it contains a secret.
    var displayImage: NSImage? {
        guard isSecret, kind == .image else { return image }
        if let blurredCache { return blurredCache }
        let blurred = image.flatMap { ItemPreview.blurred($0) }
        blurredCache = blurred
        return blurred
    }
    private weak var blurredCache: NSImage?
    var pinned = false
    /// Kept in memory only: never written to the history on disk (password managers, credential-like text).
    var neverPersist = false
    /// Where it was copied from, and how it has been used (shown in the Clipboard History info).
    var sourceName: String? { didSet { searchCache = nil } }
    var sourceBundleID: String?
    var timesCopied = 1
    lazy var lastCopied: Date = createdAt
    /// Approximate stored size in bytes.
    var byteSize: Int { representations.reduce(0) { $0+$1.1.count }+fileURLs.reduce(0) { $0+((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) } }
    /// One-line title for lists.
    var title: String {
        switch kind {
        case .text, .code: return ItemPreview.fragment(displayText ?? "",limit:90)
        case .url: return isSecret ? (displayText ?? "Link") : (url?.absoluteString ?? text ?? "Link")
        case .image:
            return "Image (\(imageDimensions))"
        case .file: return fileURLs.count > 1 ? "\(fileURLs[0].lastPathComponent) +\(fileURLs.count-1)" : (fileURLs.first?.lastPathComponent ?? "File")
        }
    }
    /// The copy carried formatting (RTF/HTML) beyond plain text, so "paste as plain" differs.
    var hasRichText: Bool { representations.contains { $0.0 == .rtf || $0.0 == .html || $0.0 == .init("public.rtf") || $0.0 == .init("com.apple.flat-rtfd") } }
    /// Text read out of an image (on-device OCR), once recognised.
    var recognizedText: String? { didSet { searchCache = nil } }
    private var exportURL: URL?

    /// Everything search can match, lowercased: content, link and domain, file names, the app it was copied
    /// from, caption and the text read from an image. Built once (rebuilt when OCR text or the source changes).
    var searchableText: String {
        if let searchCache { return searchCache }
        let built = (noteID != nil ? [text, "silk note note"] : isSecret ? [displayText, sourceName, caption, "secret"]
                     : [text, url?.absoluteString, url?.host, fileURLs.map(\.lastPathComponent).joined(separator:" "), sourceName, caption, kind.rawValue, recognizedText])
            .compactMap { $0 }.joined(separator:" ").lowercased()
        searchCache = built
        return built
    }
    private var searchCache: String?
    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(separator:" ")
        let haystack = searchableText
        return words.allSatisfy { haystack.contains($0) }
    }

    /// Identity of the content, so copying the same thing again is recognised as a duplicate.
    lazy var fingerprint: String = {
        switch kind {
        case .file: return "file:"+fileURLs.map(\.path).joined(separator:"|")
        case .url: return "url:"+(url?.absoluteString ?? "")
        case .text, .code: return "text:"+(text ?? "")
        case .image:
            let data = representations.first { $0.0 == .png || $0.0 == .tiff }?.1 ?? Data()
            var hasher = Hasher(); hasher.combine(data)
            return "image:\(data.count):\(hasher.finalize())"
        }
    }()

    init(id: Int, kind: ClipboardKind, representations: [(NSPasteboard.PasteboardType, Data)], text: String?, url: URL?, fileURLs: [URL], image: NSImage?, createdAt: Date = Date()) {
        self.id = id; self.kind = kind; self.createdAt = createdAt
        storedReps = representations; repTypes = representations.map(\.0)
        self.text = text; self.url = url
        self.fileURLs = fileURLs; cachedImage = image
        originalImageSize = image?.size
        fallbackImage = representations.contains { $0.0 == .png || $0.0 == .tiff } ? nil : image
        caption = ItemPreview.caption(kind:kind,text:text,url:url,fileURLs:fileURLs,image:image)
    }

    /// A history item whose content stays on disk until it is needed (no image is decoded at launch).
    init(id: Int, kind: ClipboardKind, repTypes: [NSPasteboard.PasteboardType], repFiles: [String], loader: @escaping () -> [(NSPasteboard.PasteboardType, Data)],
         text: String?, url: URL?, fileURLs: [URL], caption: String, fingerprint: String, createdAt: Date) {
        self.id = id; self.kind = kind; self.createdAt = createdAt
        storedReps = nil; repLoader = loader; self.repTypes = repTypes; self.repFiles = repFiles
        self.text = text; self.url = url; self.fileURLs = fileURLs
        originalImageSize = nil; fallbackImage = nil
        self.caption = caption
        self.fingerprint = fingerprint
    }

    /// Drop the in-memory copy once the history holds it; `loader` reads it back from disk.
    func offload(files: [String], loader: @escaping () -> [(NSPasteboard.PasteboardType, Data)]) {
        guard storedReps != nil else { return }
        _ = fingerprint; _ = imageDimensions
        repFiles = files; repLoader = loader; storedReps = nil
    }

    /// Read the content back from disk and keep it in memory (the saved history is about to be deleted).
    func keepInMemory() {
        guard storedReps == nil, let repLoader else { return }
        storedReps = repLoader(); repFiles = nil
    }

    /// "image · 1200×800" → (1200, 800).
    private static func pixelSize(_ caption: String) -> (Int,Int)? {
        guard caption.hasPrefix("image · ") else { return nil }
        let parts = caption.dropFirst("image · ".count).split(separator:"×").compactMap { Int($0) }
        return parts.count == 2 && parts[0] > 0 ? (parts[0],parts[1]) : nil
    }

    /// Copy Again: put the exact original representations back on the general pasteboard.
    func restore(to board: NSPasteboard = .general) {
        board.clearContents()
        if kind == .file, !fileURLs.isEmpty { board.writeObjects(fileURLs as [NSURL]); return }
        let item = NSPasteboardItem()
        for (type,data) in representations { item.setData(data,forType:type) }
        board.writeObjects([item])
    }

    /// What a native drag-out carries. Files stay files; images become a real image file.
    func dragWriters() -> [NSPasteboardWriting] {
        switch kind {
        case .file: return fileURLs as [NSURL]
        case .url: return [(url ?? URL(string:"about:blank")!) as NSURL]
        case .text, .code: return [(text ?? "") as NSString]
        case .image:
            let item = NSPasteboardItem()
            for (type,data) in representations where type == .png || type == .tiff { item.setData(data,forType:type) }
            if let file = exportedFile() { item.setString(file.absoluteString,forType:.fileURL) }
            return [item]
        }
    }

    /// Something NSWorkspace can open. Text and images are written once to a private temp file.
    func exportedFile() -> URL? {
        switch kind {
        case .file: return fileURLs.first
        case .url: return url
        case .text, .code, .image: break
        }
        if let exportURL, FileManager.default.fileExists(atPath:exportURL.path) { return exportURL }
        let folder = Self.exportFolder
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file: URL, data: Data?
        if kind == .image {
            file = folder.appendingPathComponent("caught-\(id).png")
            data = representations.first { $0.0 == .png }?.1 ?? image.flatMap { ItemPreview.png($0) }
        } else {
            file = folder.appendingPathComponent("caught-\(id).txt")
            data = text?.data(using:.utf8)
        }
        guard let data, (try? data.write(to:file,options:.atomic)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        exportURL = file; return file
    }

    static var exportFolder: URL { FileManager.default.temporaryDirectory.appendingPathComponent(BuildFlavor.isOfficial ? "WEBBER" : "WEBBER-dev",isDirectory:true) }
    /// Drag-out/Open exports left over from a previous run are deleted at launch.
    static func purgeExports() { try? FileManager.default.removeItem(at:exportFolder) }

    /// Temporary items do not outlive the web: remove any export file when released.
    func discard() {
        if let exportURL { try? FileManager.default.removeItem(at:exportURL) }
        exportURL = nil
    }

    /// Let drag receivers finish reading the file without keeping the whole clipboard payload alive.
    func discard(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline:.now()+delay) { [weak self, exportURL] in
            if let self { self.discard() }
            else if let exportURL { try? FileManager.default.removeItem(at:exportURL) }
        }
    }
}
