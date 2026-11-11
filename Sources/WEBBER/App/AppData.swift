import Foundation
import CryptoKit

/// Where SilkNest keeps its data: ~/Library/Application Support/SilkNest (history, notes, the key).
///
/// Builds up to 1.1.4 used …/WEBBER. On the first launch of a newer build that folder is copied to a
/// temporary folder, the copy is checked (every file byte for byte, and every encrypted file must open
/// with the key), and only then is it moved into place and the old folder renamed to "WEBBER (migrated)".
/// The next launch that finds the new folder intact deletes that backup, so no second copy of anyone's
/// clipboard stays on the Mac. If any step fails, this launch keeps using the old folder untouched and
/// the migration is tried again next time. It never runs again once it has succeeded.
enum AppData {
    /// Development builds keep their data apart ("SilkNest Dev"), see BuildFlavor.
    static var name: String { BuildFlavor.isOfficial ? "SilkNest" : "SilkNest Dev" }
    static let legacyName = "WEBBER", backupName = "WEBBER (migrated)"
    static let keyFile = ".history.key"
    static let migratedFlag = "dataMigratedToSilkNest"

    enum Outcome: Equatable { case fresh, current, migrated, backupRemoved, failed(String) }

    /// The folder every store uses. Set once, by `prepare`, before anything is loaded.
    private(set) static var folder: URL = defaultRoot.appendingPathComponent(name,isDirectory:true)

    static var defaultRoot: URL {
        #if DEBUG
        // Automation runs must never touch the real data.
        if CommandLine.arguments.contains("--automation") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("webber-automation-support",isDirectory:true)
        }
        #endif
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
    }

    @discardableResult
    static func prepare(root: URL = defaultRoot, defaults: UserDefaults = .standard) -> Outcome {
        let fm = FileManager.default
        let new = root.appendingPathComponent(name,isDirectory:true)
        let old = root.appendingPathComponent(legacyName,isDirectory:true)
        let backup = root.appendingPathComponent(backupName,isDirectory:true)
        folder = new

        if hasKey(new) {
            // Already on the new folder. A backup left by the migration goes once the data has opened again.
            guard fm.fileExists(atPath:backup.path), verify(new) == nil else { return .current }
            try? fm.removeItem(at:backup)
            return .backupRemoved
        }

        // Only the official app ever had a beta …/WEBBER folder to move.
        guard name == "SilkNest" || root != defaultRoot, !defaults.bool(forKey:migratedFlag), hasKey(old) else { return .fresh }

        let staging = root.appendingPathComponent(".\(name)-migrating",isDirectory:true)
        try? fm.removeItem(at:staging)
        do { try fm.copyItem(at:old,to:staging) } catch {
            try? fm.removeItem(at:staging); folder = old; return .failed("copy")
        }
        if let problem = identical(old,staging) ?? verify(staging) {
            try? fm.removeItem(at:staging); folder = old; return .failed(problem)
        }
        // An empty folder may already be there (nothing was ever written to it); anything else is left alone.
        if fm.fileExists(atPath:new.path) {
            let contents = (try? fm.contentsOfDirectory(atPath:new.path)) ?? []
            guard contents.allSatisfy({ $0 == ".DS_Store" }) else { try? fm.removeItem(at:staging); folder = old; return .failed("target in use") }
            try? fm.removeItem(at:new)
        }
        do { try fm.moveItem(at:staging,to:new) } catch {
            try? fm.removeItem(at:staging); folder = old; return .failed("move")
        }
        secure(new)
        defaults.set(true,forKey:migratedFlag)
        try? fm.removeItem(at:backup)
        if (try? fm.moveItem(at:old,to:backup)) != nil { secure(backup) }
        return .migrated
    }

    private static func hasKey(_ folder: URL) -> Bool {
        (try? Data(contentsOf:folder.appendingPathComponent(keyFile)))?.count == 32
    }

    /// Owner-only and kept out of Time Machine, like the original.
    private static func secure(_ folder: URL) {
        try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:folder.path)
        var url = folder; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static func files(in folder: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey]) else { return [] }
        let base = folder.standardizedFileURL.path
        return e.compactMap { item in
            guard let url = item as? URL, (try? url.resourceValues(forKeys:[.isRegularFileKey]))?.isRegularFile == true else { return nil }
            return String(url.standardizedFileURL.path.dropFirst(base.count))
        }.sorted()
    }

    /// nil when `copy` holds exactly the files of `original`, byte for byte.
    static func identical(_ original: URL, _ copy: URL) -> String? {
        let a = files(in:original), b = files(in:copy)
        guard a == b else { return "file list differs" }
        for path in a {
            guard let x = try? Data(contentsOf:URL(fileURLWithPath:original.path+path)),
                  let y = try? Data(contentsOf:URL(fileURLWithPath:copy.path+path)), x == y else { return "content differs" }
        }
        return nil
    }

    /// nil when the key loads and every encrypted history and notes file opens with it.
    static func verify(_ folder: URL) -> String? {
        guard let raw = try? Data(contentsOf:folder.appendingPathComponent(keyFile)), raw.count == 32 else { return "key" }
        let key = SymmetricKey(data:raw)
        let magics = [Data("WBR1".utf8),Data("WBN1".utf8)]
        for path in files(in:folder) {
            guard let data = try? Data(contentsOf:URL(fileURLWithPath:folder.path+path)) else { return "unreadable" }
            guard let magic = magics.first(where: { data.starts(with:$0) }) else { continue }
            guard let box = try? AES.GCM.SealedBox(combined:data.dropFirst(magic.count)),
                  (try? AES.GCM.open(box,using:key)) != nil else { return "does not decrypt" }
        }
        return nil
    }
}
