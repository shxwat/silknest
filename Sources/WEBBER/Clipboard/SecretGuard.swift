import AppKit

/// Secrets SilkNest never keeps.
/// Primary protection: copies the source app marks concealed or transient on the macOS pasteboard
/// (org.nspasteboard.ConcealedType / TransientType, as password managers do) are refused by
/// PasteboardReader before anything is read, whichever app made them.
/// Additional protection (this list): copies from known password-manager apps are kept in memory only,
/// even if an app forgets the marker. Everything else — API keys, OTPs, tokens — is caught and stored
/// like any other copy, in the owner-only history folder.
enum SecretGuard {
    static let passwordManagers: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx", "com.agilebits.onepassword4",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
        "com.dashlane.Dashlane", "in.sinew.Enpass-Desktop", "com.nordpass.macos.NordPass", "me.proton.pass.electron",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.keepersecurity.passwordmanager", "com.roboform.mac",
        "com.strongbox.mac"
    ]

    static func fromPasswordManager(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return passwordManagers.contains(bundleID)
    }

    /// Kept in memory only (never written to disk): copies from a password manager, and detected secrets.
    static func isSensitive(_ item: ClipboardItem) -> Bool { fromPasswordManager(item.sourceBundleID) || item.isSecret }

    /// Detected secrets (SecretDetector) are masked, kept in memory only and removed after two minutes.
    /// On by default; off treats them like any copy.
    static var protectSecrets: Bool {
        get { UserDefaults.standard.object(forKey:"protectSecrets") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue,forKey:"protectSecrets") }
    }
    /// Never catch a detected secret at all.
    static var neverCatchSecrets: Bool {
        get { UserDefaults.standard.bool(forKey:"neverCatchSecrets") }
        set { UserDefaults.standard.set(newValue,forKey:"neverCatchSecrets") }
    }
    static let secretLifetime: TimeInterval = 120
}
