import AppKit
import Carbon.HIToolbox

/// Global shortcuts through Carbon hot keys: no Accessibility permission and no key logging.
/// Only the exact registered combinations ever reach WEBBER.
struct Shortcut: Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let catchClipboard = Shortcut(keyCode:UInt32(kVK_ANSI_C),modifiers:UInt32(cmdKey|shiftKey))
    /// Opens the Nest (the default for ShortcutAction.clipboardHistory).
    static let openNest = Shortcut(keyCode:UInt32(kVK_Space),modifiers:UInt32(cmdKey|shiftKey))
    /// The full Nest (secondary).
    static let nest = Shortcut(keyCode:UInt32(kVK_Space),modifiers:UInt32(cmdKey|shiftKey|optionKey))
    /// Plain N, registered only while the pointer is on the spider: opens/closes the Nest.
    static let nestKey = Shortcut(keyCode:UInt32(kVK_ANSI_N),modifiers:0)
    /// Silk Notes: ⌥N writes a note, ⌥⇧N shows/hides them all.
    static let newNote = Shortcut(keyCode:UInt32(kVK_ANSI_N),modifiers:UInt32(optionKey))
    static let toggleNotes = Shortcut(keyCode:UInt32(kVK_ANSI_N),modifiers:UInt32(optionKey|shiftKey))
    /// Registered only while the web is open or a silk menu is showing, so Esc/Delete stay normal otherwise.
    static let escape = Shortcut(keyCode:UInt32(kVK_Escape),modifiers:0)
    static let delete = Shortcut(keyCode:UInt32(kVK_Delete),modifiers:0)
    static let forwardDelete = Shortcut(keyCode:UInt32(kVK_ForwardDelete),modifiers:0)
    /// Taken only while the Paste Stack has items.
    static let paste = Shortcut(keyCode:UInt32(kVK_ANSI_V),modifiers:UInt32(cmdKey))
    static let returnKey = Shortcut(keyCode:UInt32(kVK_Return),modifiers:0)
    static let keypadEnter = Shortcut(keyCode:UInt32(kVK_ANSI_KeypadEnter),modifiers:0)
    static func digit(_ n: Int) -> Shortcut {
        let codes = [kVK_ANSI_1,kVK_ANSI_2,kVK_ANSI_3,kVK_ANSI_4,kVK_ANSI_5,kVK_ANSI_6,kVK_ANSI_7,kVK_ANSI_8,kVK_ANSI_9]
        return Shortcut(keyCode:UInt32(codes[max(0,min(8,n-1))]),modifiers:0)
    }
}

final class ShortcutManager {
    private var handlers: [UInt32: () -> Void] = [:]
    private var releaseHandlers: [UInt32: () -> Void] = [:]
    private var refs: [Shortcut: (id: UInt32, ref: EventHotKeyRef)] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    init() {
        var specs = [EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyReleased))]
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(),{ _,event,context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&hotKey)
            let manager = Unmanaged<ShortcutManager>.fromOpaque(context).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) { manager.releaseHandlers[hotKey.id]?() }
            else { manager.handlers[hotKey.id]?() }
            return noErr
        },2,&specs,context,&eventHandler)
    }

    /// `onRelease` runs when the keys are let go (for tap-versus-hold shortcuts).
    @discardableResult func register(_ shortcut: Shortcut, onRelease: (() -> Void)? = nil, _ handler: @escaping () -> Void) -> Bool {
        unregister(shortcut)
        var ref: EventHotKeyRef?
        let id = nextID; nextID += 1
        let status = RegisterEventHotKey(shortcut.keyCode,shortcut.modifiers,EventHotKeyID(signature:OSType(0x57454242),id:id),GetApplicationEventTarget(),0,&ref)
        guard status == noErr, let ref else { return false }
        refs[shortcut] = (id,ref); handlers[id] = handler; releaseHandlers[id] = onRelease
        return true
    }

    func unregister(_ shortcut: Shortcut) {
        guard let entry = refs.removeValue(forKey:shortcut) else { return }
        UnregisterEventHotKey(entry.ref); handlers[entry.id] = nil; releaseHandlers[entry.id] = nil
    }

    func isRegistered(_ shortcut: Shortcut) -> Bool { refs[shortcut] != nil }

    deinit {
        for entry in refs.values { UnregisterEventHotKey(entry.ref) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
