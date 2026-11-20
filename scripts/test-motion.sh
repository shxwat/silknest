#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p .build
swiftc -swift-version 5 -parse-as-library Sources/WEBBER/Spider/MotionMath.swift Sources/WEBBER/Spider/SpiderMotion.swift Sources/WEBBER/Spider/SpiderRig.swift Sources/WEBBER/Spider/SpiderSpecies.swift Tests/WEBBERTests/SpiderMotionTests.swift -o .build/motion-checks
.build/motion-checks
swiftc -swift-version 5 -parse-as-library Sources/WEBBER/Spider/MotionMath.swift Sources/WEBBER/Clipboard/ClipboardItem.swift Sources/WEBBER/Clipboard/PasteboardReader.swift Sources/WEBBER/Clipboard/ClipboardController.swift Sources/WEBBER/Clipboard/ItemPreview.swift Sources/WEBBER/Clipboard/HistoryStore.swift Sources/WEBBER/App/AppData.swift Sources/WEBBER/App/BuildFlavor.swift Sources/WEBBER/App/SignatureTransition.swift Sources/WEBBER/Clipboard/SecretGuard.swift Sources/WEBBER/Clipboard/ExcludedApps.swift Sources/WEBBER/Clipboard/SecretDetector.swift Sources/WEBBER/Clipboard/PasteStack.swift Sources/WEBBER/App/ScreenshotPreview.swift Sources/WEBBER/Notes/SilkNote.swift Sources/WEBBER/Notes/NoteReminder.swift Sources/WEBBER/Notes/NoteVisibility.swift Sources/WEBBER/Notes/SilkRailResolver.swift Sources/WEBBER/Shortcuts/ShortcutManager.swift Sources/WEBBER/Shortcuts/ShortcutSettings.swift Sources/WEBBER/Overlay/TextTransform.swift Sources/WEBBER/Overlay/OverlaySpace.swift Sources/WEBBER/Overlay/NestKeyboard.swift Sources/WEBBER/Web/WebGeometry.swift Sources/WEBBER/Web/WebItem.swift Tests/WEBBERTests/ClipboardWebTests.swift -o .build/clipboard-checks
.build/clipboard-checks
