import AppKit

/// Apps the spider ignores: copies made while one of them is in front are never caught automatically.
/// Only bundle identifiers are kept (in SilkNest's own preferences), never anything that was copied.
/// Catching on purpose (Catch Copy, dropping on the spider) still works, since that is an explicit choice.
/// Password managers are skipped anyway (SecretGuard); this list is for everything else.
enum ExcludedApps {
    static let key = "excludedApps"

    static func bundleIDs(_ defaults: UserDefaults = .standard) -> [String] {
        (defaults.stringArray(forKey:key) ?? []).filter { !$0.isEmpty }
    }

    static func contains(_ bundleID: String?, _ defaults: UserDefaults = .standard) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return bundleIDs(defaults).contains(bundleID)
    }

    static func add(_ bundleID: String, _ defaults: UserDefaults = .standard) {
        guard !bundleID.isEmpty, !contains(bundleID,defaults) else { return }
        defaults.set(bundleIDs(defaults)+[bundleID],forKey:key)
    }

    static func remove(_ bundleID: String, _ defaults: UserDefaults = .standard) {
        defaults.set(bundleIDs(defaults).filter { $0 != bundleID },forKey:key)
    }

    static func toggle(_ bundleID: String, _ defaults: UserDefaults = .standard) {
        contains(bundleID,defaults) ? remove(bundleID,defaults) : add(bundleID,defaults)
    }

    /// The app's name as Finder shows it; the bundle identifier if the app is no longer installed.
    static func displayName(_ bundleID: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier:bundleID).first, let name = running.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleID) {
            return FileManager.default.displayName(atPath:url.path).replacingOccurrences(of:".app",with:"")
        }
        return bundleID
    }

    /// The app chosen in an Open panel, as a bundle identifier (nil for anything that isn't an app bundle).
    static func bundleID(ofAppAt url: URL) -> String? { Bundle(url:url)?.bundleIdentifier }
}
