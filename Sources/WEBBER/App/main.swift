import AppKit

// The text-reading helper (see TextRecognizer): reads one image from stdin and exits, no UI.
if CommandLine.arguments.dropFirst().first == TextRecognizer.helperFlag { TextRecognizer.runHelper() }

// Before anything opens the history, notes or key: move beta data from …/WEBBER to …/SilkNest.
AppData.prepare()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
