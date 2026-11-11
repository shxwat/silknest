import AppKit
import Carbon.HIToolbox

/// User-chosen global shortcuts, saved in preferences. Each action has a default the user can restore.
enum ShortcutAction: String, CaseIterable {
    case clipboardHistory, catchCopy, newNote, toggleNotes, addToStack

    var title: String {
        switch self {
        case .clipboardHistory: return "Open the Nest"
        case .catchCopy: return "Catch Copy (when Hunt is off)"
        case .newNote: return "New Silk Note"
        case .toggleNotes: return "Show/Hide Silk Notes"
        case .addToStack: return "Add newest copy to Paste Stack"
        }
    }
    /// Out of the box: ⇧⌘Space (the Nest), ⌥N (new note), ⌃⌥N (show/hide notes) and ⌃⌥V (Paste Stack).
    /// The rest stay unassigned until the user picks keys for them in Settings.
    var defaultShortcut: Shortcut? {
        switch self {
        case .clipboardHistory: return .openNest
        case .newNote: return .newNote
        case .addToStack: return Shortcut(keyCode:UInt32(kVK_ANSI_V),modifiers:UInt32(controlKey|optionKey))
        case .toggleNotes: return Shortcut(keyCode:UInt32(kVK_ANSI_N),modifiers:UInt32(controlKey|optionKey))
        case .catchCopy: return nil
        }
    }
    /// Used, in order, when the default is already taken by macOS on this Mac (never for a user's own choice).
    var fallbacks: [Shortcut] {
        switch self {
        case .clipboardHistory: return [Shortcut(keyCode:UInt32(kVK_ANSI_V),modifiers:UInt32(controlKey|shiftKey)),
                                         Shortcut(keyCode:UInt32(kVK_Space),modifiers:UInt32(controlKey|optionKey))]
        case .newNote: return [Shortcut(keyCode:UInt32(kVK_ANSI_N),modifiers:UInt32(controlKey|optionKey))]
        case .toggleNotes: return [Shortcut(keyCode:UInt32(kVK_ANSI_N),modifiers:UInt32(controlKey|optionKey|shiftKey)),
                                   Shortcut(keyCode:UInt32(kVK_ANSI_N),modifiers:UInt32(controlKey|shiftKey))]
        case .addToStack: return [Shortcut(keyCode:UInt32(kVK_ANSI_V),modifiers:UInt32(controlKey|optionKey|shiftKey)),
                                  Shortcut(keyCode:UInt32(kVK_ANSI_S),modifiers:UInt32(controlKey|optionKey))]
        default: return []
        }
    }
    /// The user picked (or cleared) this shortcut themselves.
    var isCustomized: Bool {
        let d = UserDefaults.standard
        return d.object(forKey:"shortcut.\(rawValue).key") != nil || d.bool(forKey:"shortcut.\(rawValue).cleared")
    }
    /// The saved shortcut, the default, or nil when the user cleared it.
    var shortcut: Shortcut? {
        let d = UserDefaults.standard
        if d.bool(forKey:"shortcut.\(rawValue).cleared") { return nil }
        guard let code = d.object(forKey:"shortcut.\(rawValue).key") as? Int, let mods = d.object(forKey:"shortcut.\(rawValue).mods") as? Int else { return defaultShortcut }
        return Shortcut(keyCode:UInt32(code),modifiers:UInt32(mods))
    }
    func save(_ shortcut: Shortcut?) {
        let d = UserDefaults.standard
        if let shortcut {
            d.set(Int(shortcut.keyCode),forKey:"shortcut.\(rawValue).key"); d.set(Int(shortcut.modifiers),forKey:"shortcut.\(rawValue).mods")
            d.set(false,forKey:"shortcut.\(rawValue).cleared")
        } else { d.set(true,forKey:"shortcut.\(rawValue).cleared") }
    }
    func reset() {
        let d = UserDefaults.standard
        for k in ["key","mods","cleared"] { d.removeObject(forKey:"shortcut.\(rawValue).\(k)") }
    }
}

extension Shortcut {
    /// Enabled macOS keyboard shortcuts (Spotlight, input sources, screenshots, Mission Control…) that use the
    /// same keys. Other apps' shortcuts cannot be read; only macOS's own are checked.
    var systemConflict: Bool {
        guard let prefs = UserDefaults(suiteName:"com.apple.symbolichotkeys")?.dictionary(forKey:"AppleSymbolicHotKeys") else { return false }
        return conflicts(in:prefs)
    }

    /// Whether an enabled entry of a macOS symbolic-hotkeys table uses this key combination.
    func conflicts(in prefs: [String:Any]) -> Bool {
        var flags = 0
        if modifiers & UInt32(cmdKey) != 0 { flags |= 1 << 20 }
        if modifiers & UInt32(shiftKey) != 0 { flags |= 1 << 17 }
        if modifiers & UInt32(optionKey) != 0 { flags |= 1 << 19 }
        if modifiers & UInt32(controlKey) != 0 { flags |= 1 << 18 }
        for case let entry as [String:Any] in prefs.values {
            guard (entry["enabled"] as? Bool) == true || (entry["enabled"] as? Int) == 1,
                  let params = (entry["value"] as? [String:Any])?["parameters"] as? [Int], params.count >= 3 else { continue }
            let deviceIndependent = params[2] & 0x00FF0000
            if params[1] == Int(keyCode) && deviceIndependent == flags { return true }
        }
        return false
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods = 0
        if flags.contains(.command) { mods |= cmdKey }
        if flags.contains(.shift) { mods |= shiftKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.control) { mods |= controlKey }
        let isFunctionKey = (96...122).contains(Int(event.keyCode))
        // A global shortcut needs at least one of ⌘ ⌥ ⌃ (or is a function key), so typing is never captured.
        guard mods & (cmdKey|optionKey|controlKey) != 0 || isFunctionKey else { return nil }
        self.init(keyCode:UInt32(event.keyCode),modifiers:UInt32(mods))
    }

    /// "⌥⇧⌘Space"-style display, in macOS modifier order.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s+Self.keyName(Int(keyCode))
    }

    static func keyName(_ code: Int) -> String {
        let special: [Int:String] = [kVK_Space:"Space",kVK_Return:"↩",kVK_Tab:"⇥",kVK_Delete:"⌫",kVK_Escape:"⎋",kVK_LeftArrow:"←",kVK_RightArrow:"→",
            kVK_UpArrow:"↑",kVK_DownArrow:"↓",kVK_F1:"F1",kVK_F2:"F2",kVK_F3:"F3",kVK_F4:"F4",kVK_F5:"F5",kVK_F6:"F6",kVK_F7:"F7",kVK_F8:"F8",
            kVK_F9:"F9",kVK_F10:"F10",kVK_F11:"F11",kVK_F12:"F12",kVK_ANSI_Grave:"`",kVK_ANSI_Minus:"-",kVK_ANSI_Equal:"=",kVK_ANSI_LeftBracket:"[",
            kVK_ANSI_RightBracket:"]",kVK_ANSI_Semicolon:";",kVK_ANSI_Quote:"'",kVK_ANSI_Comma:",",kVK_ANSI_Period:".",kVK_ANSI_Slash:"/",kVK_ANSI_Backslash:"\\"]
        if let name = special[code] { return name }
        // Letters and digits from the current keyboard layout.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source,kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0, length = 0
        var chars = [UniChar](repeating:0,count:4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            UCKeyTranslate(raw.bindMemory(to:UCKeyboardLayout.self).baseAddress!,UInt16(code),UInt16(kUCKeyActionDisplay),0,UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit),&dead,4,&length,&chars)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits:chars,count:length).uppercased()
    }
}

/// Click, then press the new shortcut. Esc cancels, ⌫ clears.
final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut? { didSet { refresh() } }
    var onChange: ((Shortcut?) -> Void)?
    private var recording = false { didSet { refresh() } }
    private var monitor: Any?

    init(shortcut: Shortcut?) {
        self.shortcut = shortcut
        super.init(frame:NSRect(x:0,y:0,width:150,height:26))
        bezelStyle = .rounded; target = self; action = #selector(toggle)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() { title = recording ? "Press shortcut…" : (shortcut?.display ?? "Not set") }

    @objc private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self else { return event }
            switch Int(event.keyCode) {
            case kVK_Escape: self.stop(); return nil
            case kVK_Delete, kVK_ForwardDelete: self.shortcut = nil; self.onChange?(nil); self.stop(); return nil
            default:
                if let s = Shortcut(event:event) { self.shortcut = s; self.onChange?(s); self.stop() } else { NSSound.beep() }
                return nil
            }
        }
    }
    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
    }
}
