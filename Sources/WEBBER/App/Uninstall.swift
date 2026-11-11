import AppKit
import ServiceManagement

/// Settings → Uninstall SilkNest…: undoes what SilkNest changed on the Mac (the screenshot preview, the
/// login item), optionally deletes its data (history, notes, the key, preferences), moves the app to the
/// Trash and quits. Nothing is deleted without the user's explicit choice.
enum Uninstall {
    /// Set while uninstalling with "delete data": quitting must not write history or notes back.
    private(set) static var deletingData = false

    static func run(from window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Uninstall SilkNest?"
        alert.informativeText = "SilkNest will put macOS's screenshot preview back the way it was, stop opening at login, move itself to the Trash and quit."
        let deleteData = NSButton(checkboxWithTitle:"Also delete my clipboard history, notes and settings",target:nil,action:nil)
        deleteData.state = .off
        alert.accessoryView = deleteData
        alert.addButton(withTitle:"Uninstall"); alert.addButton(withTitle:"Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            perform(deleteData:deleteData.state == .on)
        }
        if let window { alert.beginSheetModal(for:window,completionHandler:finish) } else { finish(alert.runModal()) }
    }

    private static func perform(deleteData: Bool) {
        ScreenshotPreview.restoreOriginal()
        try? SMAppService.mainApp.unregister()
        if deleteData {
            deletingData = true
            try? FileManager.default.removeItem(at:AppData.folder)
            if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName:id) }
        }
        ClipboardItem.purgeExports()
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _,_ in NSApp.terminate(nil) }
    }
}
