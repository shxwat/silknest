import AppKit
import Vision
import CryptoKit

/// Local, private history that survives restarts: ~/Library/Application Support/SilkNest/History (see AppData).
///
/// Security:
/// - Every file is encrypted (AES-256-GCM) with a per-Mac random key kept in a separate owner-only
///   file (not in the History folder, not backed up with it). No key → nothing is written at all.
/// - The folder is owner-only (0700) and files 0600, so other accounts on the Mac cannot open them.
/// - The folder is excluded from Time Machine / backups.
/// - Sensitive items (password-manager copies, credential-like text) are never written; see SecretGuard.
/// Writes happen off the main thread.
final class HistoryStore {
    private let folder: URL
    private let queue = DispatchQueue(label:"studio.webber.history",qos:.utility)
    private let key: SymmetricKey?
    private static let magic = Data("WBR1".utf8)

    /// `key` is injectable for tests; the app uses the stored per-Mac key.
    init(folder custom: URL? = nil, key: SymmetricKey? = HistoryStore.storedKey()) {
        folder = custom ?? AppData.folder.appendingPathComponent("History",isDirectory:true)
        self.key = key
        Self.secureFolder(folder)
    }

    /// Owner-only folder and files, kept out of backups.
    private static func secureFolder(_ folder: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try? fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:folder.path)
        try? fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:folder.deletingLastPathComponent().path)
        var url = folder; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        for name in (try? fm.contentsOfDirectory(atPath:folder.path)) ?? [] {
            try? fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:folder.appendingPathComponent(name).path)
        }
    }

    private func seal(_ data: Data) -> Data? {
        guard let key, let box = try? AES.GCM.seal(data,using:key), let combined = box.combined else { return nil }
        return Self.magic+combined
    }
    private func open(_ data: Data) -> Data? {
        guard let key, data.starts(with:Self.magic),
              let box = try? AES.GCM.SealedBox(combined:data.dropFirst(Self.magic.count)) else { return nil }
        return try? AES.GCM.open(box,using:key)
    }
    private func write(_ data: Data, to url: URL) {
        guard let sealed = seal(data) else { return }
        FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600])
        try? sealed.write(to:url,options:.atomic)
        try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }

    /// The 256-bit history key: a separate owner-only (0600) file outside the History folder.
    /// (A Keychain item would make macOS ask for the login password after every app update while
    /// WEBBER is not signed with a Developer ID, and block launch until answered.)
    static func storedKey() -> SymmetricKey? {
        let base = AppData.folder
        try? FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        // The key, the notes and the history all stay off Time Machine and other backups:
        // a backup disk must never hold the key next to the data it unlocks.
        var folder = base; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        let file = base.appendingPathComponent(AppData.keyFile)
        if let data = try? Data(contentsOf:file), data.count == 32 {
            try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            return SymmetricKey(data:data)
        }
        let raw = SymmetricKey(size:.bits256).withUnsafeBytes { Data($0) }
        guard FileManager.default.createFile(atPath:file.path,contents:raw,attributes:[.posixPermissions:0o600]) else { return nil }
        return SymmetricKey(data:raw)
    }

    private struct Record: Codable {
        let id: Int
        let kind: String
        let createdAt: Date
        let pinned: Bool
        let files: [String]
        let reps: [Rep]
        let ocr: String?
        var source: String? = nil
        var sourceBundle: String? = nil
        var times: Int? = nil
        var last: Date? = nil
        /// Kept in the index so a large item can stay on disk at launch (added in 1.2.3).
        var caption: String? = nil
        var fp: String? = nil
        var text: String? = nil
        var thumb: Data? = nil
        struct Rep: Codable { let type: String; let file: String }
    }

    /// Items whose content is larger than this are kept on disk, not in memory, once saved.
    static let offloadBytes = 48_000
    /// What the app does with an item once its files are on disk.
    var onPersisted: ((ClipboardItem, [String], @escaping () -> [(NSPasteboard.PasteboardType, Data)]) -> Void)?

    /// Reads an item's content back from its encrypted files (any thread).
    func loadReps(_ reps: [(type: String, file: String)]) -> [(NSPasteboard.PasteboardType, Data)] {
        reps.compactMap { rep in
            guard let raw = try? Data(contentsOf:folder.appendingPathComponent(rep.file)),
                  let d = raw.starts(with:Self.magic) ? open(raw) : (rep.file.hasSuffix(".bin") ? raw : nil) else { return nil }
            return (NSPasteboard.PasteboardType(rep.type),d)
        }
    }

    // MARK: layout (1.2.3+)
    //
    //   order.enc          the item ids, oldest first (small: a few KB for 1000 items)
    //   <id>.meta.enc      one item's metadata: kind, dates, pin, source, OCR text, caption, fingerprint
    //   <id>-<n>.enc       one item's content, one file per pasteboard representation
    //
    // A new copy writes its own files and the order; nothing else is rewritten. Earlier versions kept every
    // record in one index.enc (index.json before encryption); that is migrated once, with a verified backup.

    static let orderFile = "order.enc"
    static let legacyIndex = "index.enc", legacyPlainIndex = "index.json"
    static func metaFile(_ id: Int) -> String { "\(id).meta.enc" }
    /// The pre-migration History folder, kept beside it until the migrated history has opened once.
    var backupFolder: URL { folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent+" (v1 backup)",isDirectory:true) }

    // Queue-only bookkeeping: what is on disk, so a save writes and deletes only what changed.
    private var writtenMeta: [Int: Int] = [:]          // id → hash of the meta JSON on disk
    private var fileNames: [Int: [String]] = [:]       // id → its content files
    private var writtenOrder: [Int]?
    /// Migration failed this launch: keep writing the single-index format so nothing is lost; retried next launch.
    private var legacyMode = false

    /// Stable output (sorted keys): the same record always encodes to the same bytes, which the change
    /// detection and the migration's read-back comparison rely on.
    static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }

    private static func hash(_ data: Data) -> Int { var h = Hasher(); h.combine(data); return h.finalize() }

    private struct Order: Codable { let v: Int; let ids: [Int] }

    private func record(for item: ClipboardItem) -> (Record,[String]) {
        let names = item.repFiles ?? item.repTypes.indices.map { "\(item.id)-\($0).enc" }
        let r = Record(id:item.id,kind:item.kind.rawValue,createdAt:item.createdAt,pinned:item.pinned,files:item.fileURLs.map(\.path),
                       reps:zip(item.repTypes,names).map { Record.Rep(type:$0.rawValue,file:$1) },ocr:item.recognizedText,
                       source:item.sourceName,sourceBundle:item.sourceBundleID,times:item.timesCopied,last:item.lastCopied,
                       caption:item.caption,fp:item.fingerprint,text:(item.text?.utf8.count ?? 0) <= 20_000 ? item.text : nil,thumb:item.thumbnail)
        return (r,names)
    }

    /// Snapshot on the main thread, write in the background. Only new or changed items are written;
    /// items that are gone have their files deleted. Content already on disk is never re-read.
    func save(_ items: [ClipboardItem]) {
        guard key != nil else { return }
        let encoder = Self.encoder()
        // An image waiting for its text to be read is not written yet: the text may reveal a secret.
        let snapshot = items.filter { !$0.neverPersist && !$0.awaitingOCR }.map { item -> (record: Record, meta: Data?, blobs: [(String,Data)], item: ClipboardItem?) in
            let (r,names) = record(for:item)
            let blobs = item.isOffloaded ? [] : zip(names,item.representations.map(\.1)).map { ($0,$1) }
            let heavy = !item.isOffloaded && item.memoryBytes > Self.offloadBytes
            return (r,try? encoder.encode(r),blobs,heavy ? item : nil)
        }
        queue.async { [self] in
            let fm = FileManager.default
            for entry in snapshot {
                for (name,data) in entry.blobs where !fm.fileExists(atPath:folder.appendingPathComponent(name).path) {
                    write(data,to:folder.appendingPathComponent(name))
                }
            }
            if legacyMode {
                writeLegacyIndex(snapshot.map(\.record))
                let keep = Set(snapshot.flatMap { $0.record.reps.map(\.file) }+[Self.legacyIndex])
                for name in (try? fm.contentsOfDirectory(atPath:folder.path)) ?? [] where !keep.contains(name) {
                    try? fm.removeItem(at:folder.appendingPathComponent(name))
                }
                reportPersisted(snapshot.compactMap { e in e.item.map { ($0,e.record.reps.map { (type:$0.type,file:$0.file) }) } })
                return
            }
            for entry in snapshot {
                let id = entry.record.id
                fileNames[id] = entry.record.reps.map(\.file)
                guard let meta = entry.meta else { continue }
                let h = Self.hash(meta)
                if writtenMeta[id] != h || !fm.fileExists(atPath:folder.appendingPathComponent(Self.metaFile(id)).path) {
                    write(meta,to:folder.appendingPathComponent(Self.metaFile(id))); writtenMeta[id] = h
                }
            }
            let ids = snapshot.map(\.record.id)
            if writtenOrder != ids, let order = try? Self.encoder().encode(Order(v:2,ids:ids)) {
                write(order,to:folder.appendingPathComponent(Self.orderFile)); writtenOrder = ids
            }
            // Removed, released or cleared: delete the item's files (metadata, OCR text, content).
            let keep = Set(ids)
            for gone in Set(writtenMeta.keys).union(fileNames.keys).subtracting(keep) { deleteFiles(of:gone) }
            reportPersisted(snapshot.compactMap { e in e.item.map { ($0,e.record.reps.map { (type:$0.type,file:$0.file) }) } })
        }
    }

    private func deleteFiles(of id: Int) {
        let fm = FileManager.default
        for name in (fileNames[id] ?? [])+[Self.metaFile(id)] { try? fm.removeItem(at:folder.appendingPathComponent(name)) }
        fileNames[id] = nil; writtenMeta[id] = nil
    }

    /// Large content is now safely on disk: let it leave memory.
    private func reportPersisted(_ heavy: [(ClipboardItem,[(type: String, file: String)])]) {
        let written = heavy.filter { _,reps in reps.allSatisfy { FileManager.default.fileExists(atPath:folder.appendingPathComponent($0.file).path) } }
        guard !written.isEmpty else { return }
        DispatchQueue.main.async { [self] in
            for (item,reps) in written { onPersisted?(item,reps.map(\.file)) { [self] in loadReps(reps) } }
        }
    }

    /// Fallback after a failed migration: the previous single-index format.
    private func writeLegacyIndex(_ records: [Record]) {
        if let json = try? Self.encoder().encode(records) { write(json,to:folder.appendingPathComponent(Self.legacyIndex)) }
    }

    func load() -> [ClipboardItem] {
        guard key != nil else { return [] }
        let fm = FileManager.default
        if let sealed = try? Data(contentsOf:folder.appendingPathComponent(Self.orderFile)) {
            guard let data = open(sealed), let order = try? JSONDecoder().decode(Order.self,from:data) else { return [] }
            var records: [Record] = [], hashes: [Int: Int] = [:]
            let decoder = JSONDecoder()
            for id in order.ids {
                guard let raw = try? Data(contentsOf:folder.appendingPathComponent(Self.metaFile(id))), let json = open(raw),
                      let r = try? decoder.decode(Record.self,from:json), r.id == id else { continue }
                records.append(r); hashes[id] = Self.hash(json)
            }
            queue.sync {
                writtenMeta = hashes
                fileNames = Dictionary(uniqueKeysWithValues:records.map { ($0.id,$0.reps.map(\.file)) })
                writtenOrder = order.ids
            }
            let items = decode(records)
            // The migrated history opened: the pre-migration backup is no longer needed.
            if fm.fileExists(atPath:backupFolder.path) { try? fm.removeItem(at:backupFolder) }
            sweepOrphans()
            return items
        }
        // An earlier version's single index (encrypted, or plaintext from before encryption).
        let legacy = folder.appendingPathComponent(Self.legacyPlainIndex)
        let index: Data?
        if let sealed = try? Data(contentsOf:folder.appendingPathComponent(Self.legacyIndex)) { index = open(sealed) }
        else { index = try? Data(contentsOf:legacy) }
        guard let data = index, let records = try? JSONDecoder().decode([Record].self,from:data) else {
            if fm.fileExists(atPath:legacy.path) { try? fm.removeItem(at:legacy) }
            return []
        }
        let items = decode(records)
        if !migrate(items) {
            legacyMode = true
            save(items)        // keeps the legacy index current (and encrypts a plaintext one)
        }
        return items
    }

    /// One-time move from the single index to per-item files. The History folder is first copied to a
    /// backup and checked byte for byte; the new files are written and read back; only then is the old
    /// index removed. Any failure leaves the old index in place (the backup too) and is retried next launch.
    private func migrate(_ items: [ClipboardItem]) -> Bool {
        let fm = FileManager.default
        let backup = backupFolder
        let staging = backup.deletingLastPathComponent().appendingPathComponent("."+backup.lastPathComponent+"-copying",isDirectory:true)
        try? fm.removeItem(at:staging)
        guard (try? fm.copyItem(at:folder,to:staging)) != nil, AppData.identical(folder,staging) == nil else { try? fm.removeItem(at:staging); return false }
        try? fm.removeItem(at:backup)
        guard (try? fm.moveItem(at:staging,to:backup)) != nil else { try? fm.removeItem(at:staging); return false }
        try? fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:backup.path)
        var backupURL = backup; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? backupURL.setResourceValues(values)

        save(items); flush()
        // Read everything back: the order, every record, every content file.
        let encoder = Self.encoder()
        let expected = items.filter { !$0.neverPersist }
        var ok = false
        if let sealed = try? Data(contentsOf:folder.appendingPathComponent(Self.orderFile)), let data = open(sealed),
           let order = try? JSONDecoder().decode(Order.self,from:data), order.ids == expected.map(\.id) {
            ok = expected.allSatisfy { item in
                let (r,_) = record(for:item)
                guard let raw = try? Data(contentsOf:folder.appendingPathComponent(Self.metaFile(item.id))), let json = open(raw),
                      let back = try? JSONDecoder().decode(Record.self,from:json),
                      (try? encoder.encode(back)) == (try? encoder.encode(r)) else { return false }
                return loadReps(r.reps.map { (type:$0.type,file:$0.file) }).count == r.reps.count || item.kind == .file
            }
        }
        if ok {
            for name in [Self.legacyIndex,Self.legacyPlainIndex] { try? fm.removeItem(at:folder.appendingPathComponent(name)) }
            return true
        }
        // Undo: remove the new files; the old index (untouched) stays authoritative.
        queue.sync {
            try? fm.removeItem(at:folder.appendingPathComponent(Self.orderFile))
            for item in expected { try? fm.removeItem(at:folder.appendingPathComponent(Self.metaFile(item.id))) }
            writtenMeta = [:]; writtenOrder = nil
        }
        return false
    }

    /// Files no item refers to (left by a crash between writes) are deleted, in the background.
    private func sweepOrphans() {
        queue.async { [self] in
            var keep: Set<String> = [Self.orderFile]
            for (id,names) in fileNames { keep.insert(Self.metaFile(id)); keep.formUnion(names) }
            for name in (try? FileManager.default.contentsOfDirectory(atPath:folder.path)) ?? [] where !keep.contains(name) {
                try? FileManager.default.removeItem(at:folder.appendingPathComponent(name))
            }
        }
    }

    /// Newest first up to the history limit; pinned items are always kept, whatever their age.
    private func decode(_ records: [Record]) -> [ClipboardItem] {
        var items: [ClipboardItem] = []
        let pinned = records.filter(\.pinned).count
        var unpinnedRoom = max(0,ClipboardController.capacity-pinned)
        for record in records.reversed() {
            guard record.pinned || unpinnedRoom > 0 else { continue }
            if let item = decode(record) { items.append(item); if !record.pinned { unpinnedRoom -= 1 } }
        }
        return items.reversed()
    }

    private func decode(_ r: Record) -> ClipboardItem? {
        autoreleasepool {
            guard let kind = ClipboardKind(rawValue:r.kind) else { return nil }
            if let lazy = decodeLazy(r,kind:kind) { return lazy }
            let reps: [(NSPasteboard.PasteboardType,Data)] = r.reps.compactMap { rep in
                guard let raw = try? Data(contentsOf:folder.appendingPathComponent(rep.file)) else { return nil }
                guard let d = raw.starts(with:Self.magic) ? open(raw) : (rep.file.hasSuffix(".bin") ? raw : nil) else { return nil }
                return (NSPasteboard.PasteboardType(rep.type),d)
            }
            let files = r.files.map { URL(fileURLWithPath:$0) }.filter { FileManager.default.fileExists(atPath:$0.path) }
            if kind == .file && files.isEmpty { return nil }
            // Content files missing or unreadable: skip that entry rather than show an empty ghost.
            if kind != .file && reps.isEmpty { return nil }
            let text = reps.first { $0.0 == .string }.flatMap { String(data:$0.1,encoding:.utf8) }
            let url = kind == .url ? (reps.first { $0.0 == .URL }.flatMap { String(data:$0.1,encoding:.utf8) } ?? text).flatMap(PasteboardReader.webURL) : nil
            let image = kind == .image ? reps.first { $0.0 == .png || $0.0 == .tiff }.flatMap { NSImage(data:$0.1) } : nil
            let item = ClipboardItem(id:r.id,kind:kind,representations:reps,text:text,url:url,fileURLs:files,image:image,createdAt:r.createdAt)
            item.pinned = r.pinned; item.recognizedText = r.ocr; item.thumbnail = r.thumb
            if r.reps.allSatisfy({ $0.file.hasSuffix(".enc") }) { item.repFiles = r.reps.map(\.file) }
            if SecretGuard.isSensitive(item) { return nil }
            item.sourceName = r.source; item.sourceBundleID = r.sourceBundle
            item.timesCopied = r.times ?? 1; item.lastCopied = r.last ?? r.createdAt
            return item
        }
    }

    /// A large item from a 1.2.3+ index: only its metadata is read now; its content stays on disk.
    private func decodeLazy(_ r: Record, kind: ClipboardKind) -> ClipboardItem? {
        guard kind != .file, let caption = r.caption, let fp = r.fp, !r.reps.isEmpty else { return nil }
        // Text kinds need their text in memory for search and preview.
        if kind != .image && r.text == nil { return nil }
        let sizes = r.reps.map { (try? folder.appendingPathComponent($0.file).resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? nil }
        guard !sizes.contains(where: { $0 == nil }) else { return nil }
        guard sizes.reduce(0, { $0+($1 ?? 0) }) > Self.offloadBytes else { return nil }
        let reps = r.reps.map { (type:$0.type,file:$0.file) }
        let url = kind == .url ? (r.text).flatMap(PasteboardReader.webURL) : nil
        let item = ClipboardItem(id:r.id,kind:kind,repTypes:reps.map { NSPasteboard.PasteboardType($0.type) },repFiles:reps.map(\.file),
                                 loader:{ [self] in self.loadReps(reps) },
                                 text:r.text,url:url,fileURLs:[],caption:caption,fingerprint:fp,createdAt:r.createdAt)
        item.pinned = r.pinned; item.recognizedText = r.ocr; item.thumbnail = r.thumb
        if SecretGuard.isSensitive(item) { return nil }
        item.sourceName = r.source; item.sourceBundleID = r.sourceBundle
        item.timesCopied = r.times ?? 1; item.lastCopied = r.last ?? r.createdAt
        return item
    }

    /// Waits for pending writes (tests).
    func flush() { queue.sync {} }

    func clear() {
        queue.async { [self, folder] in
            writtenMeta = [:]; fileNames = [:]; writtenOrder = nil
            for name in (try? FileManager.default.contentsOfDirectory(atPath:folder.path)) ?? [] {
                try? FileManager.default.removeItem(at:folder.appendingPathComponent(name))
            }
        }
    }
}

/// On-device text recognition (Vision). Nothing leaves the Mac.
enum TextRecognizer {
    /// Reads text out of an image, at most 1600 px on the long side (plenty for screen text; a full
    /// Retina screenshot would cost several times the CPU for the same words).
    ///
    /// The reading happens in a short-lived copy of SilkNest started with `--ocr-stdin`: the image goes in
    /// through a pipe and the text comes back the same way (nothing is written to disk). Apple's text model
    /// is large and stays in memory once loaded, so loading it in a helper that exits right after keeps
    /// SilkNest itself small. One image at a time, at background priority.
    /// `completion`: the text, "" when the image has none, nil when it couldn't be read this time.
    static func recognize(image loadImage: @escaping () -> NSImage?, completion: @escaping (String?) -> Void) {
        queue.async { autoreleasepool {
            // Release the full decoded screenshot before waiting for the OCR helper.
            let prepared: CGImage? = autoreleasepool {
                guard let image = loadImage(), let full = image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return nil }
                return downscaled(full,maxSide:1600) ?? full
            }
            guard let cg = prepared else { DispatchQueue.main.async { completion(nil) }; return }
            let text: String?
            switch viaHelper(cg) {
            case .text(let t): text = t
            case .failed: text = nil          // tried again on a later launch
            case .unavailable: text = read(cg) // no helper at all: read it here
            }
            DispatchQueue.main.async { completion(text) }
        } }
    }

    private enum HelperResult { case text(String), failed, unavailable }

    private static let queue = DispatchQueue(label:"studio.webber.ocr",qos:.background)
    static let helperFlag = "--ocr-stdin"

    /// The helper side: PNG on stdin, text on stdout.
    static func runHelper() -> Never {
        // Never outlive SilkNest (it quit or updated) and never run long.
        let parent = getppid(), started = Date()
        Thread.detachNewThread {
            while true {
                if getppid() != parent || Date().timeIntervalSince(started) > 90 { exit(0) }
                Thread.sleep(forTimeInterval:1)
            }
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        if let source = CGImageSourceCreateWithData(data as CFData,nil), let cg = CGImageSourceCreateImageAtIndex(source,0,nil) {
            FileHandle.standardOutput.write(Data(read(cg).utf8))
        }
        exit(0)
    }

    /// Reads text in this process (checks; the app reads through the helper).
    static func readText(_ cg: CGImage) -> String { read(cg) }

    private static func read(_ cg: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.preferBackgroundProcessing = true
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage:cg,options:[:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines)
    }

    private static func viaHelper(_ cg: CGImage) -> HelperResult {
        guard let exe = Bundle.main.executableURL else { return .unavailable }
        let png = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(png as CFMutableData,"public.png" as CFString,1,nil) else { return .failed }
        CGImageDestinationAddImage(dest,cg,nil)
        guard CGImageDestinationFinalize(dest) else { return .failed }
        let p = Process(); p.executableURL = exe; p.arguments = [helperFlag]; p.qualityOfService = .background
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return .unavailable }
        // Never wait forever on a stuck helper.
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+30,execute:watchdog)
        // Read on another thread while writing, so a full pipe can never block either side.
        var result = Data(); let reader = DispatchGroup(); reader.enter()
        DispatchQueue.global(qos:.utility).async { result = output.fileHandleForReading.readDataToEndOfFile(); reader.leave() }
        try? input.fileHandleForWriting.write(contentsOf:png as Data); try? input.fileHandleForWriting.close()
        reader.wait(); p.waitUntilExit(); watchdog.cancel()
        guard p.terminationReason == .exit, p.terminationStatus == 0 else { return .failed }
        return .text(String(decoding:result,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines))
    }

    private static func downscaled(_ cg: CGImage, maxSide: Int) -> CGImage? {
        let side = max(cg.width,cg.height)
        guard side > maxSide else { return nil }
        let k = Double(maxSide)/Double(side), w = Int(Double(cg.width)*k), h = Int(Double(cg.height)*k)
        guard let ctx = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg,in:CGRect(x:0,y:0,width:w,height:h))
        return ctx.makeImage()
    }
}
