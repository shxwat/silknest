import AppKit

/// macOS's floating screenshot preview holds a saved screenshot back for about five seconds (and drops it
/// if the preview is dragged away). SilkNest can turn it off so screenshots are caught at once, but only
/// when the user says so, and it puts back exactly what macOS had before when that choice is undone or
/// SilkNest is uninstalled.
enum ScreenshotPreview {
    private static let domain = "com.apple.screencapture" as CFString
    private static let key = "show-thumbnail" as CFString
    private static var defaults: UserDefaults { .standard }
    /// The user's answer; nil until asked.
    private static let choiceKey = "instantScreenshots.choice"
    /// macOS's own value before SilkNest first changed it: "on", "off" or "unset" (macOS default, on).
    private static let originalKey = "screenshotPreviewOriginal"

    /// How macOS's setting is read and written (replaced in checks, so they never touch the real one).
    struct Backend {
        var read: () -> Bool?
        var write: (Bool?) -> Void
    }
    static var backend = Backend(
        read: { CFPreferencesAppSynchronize(domain); return CFPreferencesCopyAppValue(key,domain) as? Bool },
        write: { value in
            CFPreferencesSetAppValue(key,value.map { $0 as CFBoolean },domain); CFPreferencesAppSynchronize(domain)
            // The screenshot UI reads the setting when it starts.
            let p = Process(); p.executableURL = URL(fileURLWithPath:"/usr/bin/killall"); p.arguments = ["SystemUIServer"]; try? p.run()
        })

    /// macOS's current value (nil: never set, which means the preview is on).
    static var macOSValue: Bool? { backend.read() }

    static var choice: Bool? { defaults.object(forKey:choiceKey) as? Bool }
    /// Catch screenshots instantly (the preview is off).
    static var instant: Bool { choice == true }

    /// 1.2.2 and earlier turned the preview off without asking.
    private static var changedByEarlierVersion: Bool {
        defaults.object(forKey:"instantScreenshots") as? Bool == true || defaults.bool(forKey:"instantShotsApplied")
    }

    static func setInstant(_ on: Bool) {
        defaults.set(on,forKey:choiceKey)
        if on { rememberOriginal(); if macOSValue != false { write(false) } } else { restoreOriginal() }
    }

    /// At launch: keep the user's choice in force (nothing happens until they have agreed).
    static func applyAtLaunch() {
        guard instant else { return }
        rememberOriginal()
        if macOSValue != false { write(false) }
    }

    private static func rememberOriginal() {
        guard defaults.string(forKey:originalKey) == nil else { return }
        // If an earlier version already switched it off, what macOS had before was its default: on.
        let original = changedByEarlierVersion ? "on" : (macOSValue.map { $0 ? "on" : "off" } ?? "unset")
        defaults.set(original,forKey:originalKey)
    }

    /// Put back what macOS had before SilkNest changed it (nothing to do if SilkNest never changed it).
    static func restoreOriginal() {
        let original = defaults.string(forKey:originalKey) ?? (changedByEarlierVersion ? "on" : nil)
        defer {
            defaults.removeObject(forKey:originalKey)
            defaults.removeObject(forKey:"instantScreenshots"); defaults.removeObject(forKey:"instantShotsApplied")
        }
        guard let original else { return }
        let wanted: Bool? = original == "unset" ? nil : original == "on"
        guard macOSValue != wanted else { return }
        backend.write(wanted)
    }

    private static func write(_ on: Bool) { backend.write(on) }

    /// Ask once: on a first launch, and once for people updating from a version that changed it silently.
    /// Keeping the preview is the default answer.
    /// Checks only: forget the answer and the remembered original.
    static func resetForTesting() { for k in [choiceKey,originalKey,"instantScreenshots","instantShotsApplied"] { defaults.removeObject(forKey:k) } }

    static func askIfNeeded(after delay: Double) {
        guard choice == nil else { return }
        DispatchQueue.main.asyncAfter(deadline:.now()+delay) {
            guard choice == nil else { return }
            NSApp.activate(ignoringOtherApps:true)
            let alert = NSAlert()
            alert.messageText = "Catch screenshots instantly?"
            alert.informativeText = "This turns off macOS's floating screenshot preview. Without it, SilkNest still catches your screenshots, about five seconds later.\n\nYou can change this any time in SilkNest Settings."
            alert.addButton(withTitle:"Keep the Preview")
            alert.addButton(withTitle:"Catch Instantly")
            setInstant(alert.runModal() == .alertSecondButtonReturn)
        }
    }
}
