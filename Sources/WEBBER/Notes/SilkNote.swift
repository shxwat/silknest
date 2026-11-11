import AppKit
import CryptoKit

/// A short thought hung on the spider's silk along the top edge of a display.
/// Plain text only for now; `attachments` holds clipboard item ids for a later phase.
struct NotePosition: Codable, Equatable {
    var x: Double
    var y: Double
}

struct SilkNote: Codable, Equatable {
    enum Mode: String, Codable { case global, app }

    var id = UUID()
    var text: String
    var createdAt = Date()
    var updatedAt = Date()
    /// Persistent rail order key; larger values hang nearer the start of the rail.
    var x: Double
    /// Stable display identifier (CoreGraphics display UUID).
    var display: String
    var pinned = false
    var mode: Mode = .global
    /// Recorded at creation; only used if the user explicitly pins the note to that app.
    var bundleID: String?
    var appName: String?
    var attachments: [Int] = []
    /// Set when its display disconnected and it was moved to the primary display; it goes home on reconnect.
    var homeDisplay: String?
    /// A user-placed handle, relative to the visible display. Nil keeps the default top position.
    var position: NotePosition?
    /// A reminder read from the text ("3pm", "in 20 min"); cleared when done or the text no longer has one.
    var remindAt: Date? = nil

    /// First words, for the collapsed tab.
    var title: String {
        let flat = text.split(whereSeparator:\.isNewline).joined(separator:" ").trimmingCharacters(in:.whitespaces)
        guard flat.count > 22 else { return flat }
        let cut = flat.prefix(22)
        return (cut.lastIndex(of:" ").map { String(cut[..<$0]) } ?? String(cut))+"…"
    }
}

extension NSScreen {
    /// Survives reboots and re-plugging (unlike the display number).
    var displayKey: String {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return localizedName }
        if let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() { return CFUUIDCreateString(nil,uuid) as String }
        return "\(number)"
    }
}

/// Notes on disk: one AES-GCM encrypted, owner-only file next to the clipboard history, same per-Mac key.
/// Nothing leaves the Mac and note text is never logged.
final class NoteStore {
    private let file: URL
    private let key: SymmetricKey?
    private let queue = DispatchQueue(label:"studio.webber.notes",qos:.utility)
    private static let magic = Data("WBN1".utf8)

    init(file custom: URL? = nil, key: SymmetricKey? = HistoryStore.storedKey()) {
        let base = custom?.deletingLastPathComponent() ?? AppData.folder
        try? FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        file = custom ?? base.appendingPathComponent("Notes.enc")
        self.key = key
    }

    func load() -> [SilkNote] {
        guard let key, let data = try? Data(contentsOf:file), data.starts(with:Self.magic),
              let box = try? AES.GCM.SealedBox(combined:data.dropFirst(Self.magic.count)),
              let plain = try? AES.GCM.open(box,using:key),
              let notes = try? JSONDecoder().decode([SilkNote].self,from:plain) else { return [] }
        return notes
    }

    func save(_ notes: [SilkNote]) {
        guard let key else { return }
        queue.async { [file] in
            guard let json = try? JSONEncoder().encode(notes),
                  let sealed = try? AES.GCM.seal(json,using:key).combined else { return }
            // Never truncate the last good copy before the atomic replacement succeeds.
            try? (Self.magic+sealed).write(to:file,options:.atomic)
            try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        }
    }

    func flush() { queue.sync {} }
}
