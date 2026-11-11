#!/bin/zsh
# Upgrade check: data written by the real 1.2.2 code (commit 726b981) is read by this version.
# Everything happens in a temporary folder with a throwaway key: never ~/Library/Application Support/SilkNest,
# never the user's preferences, keychain or clipboard.
#   - 1.2.2 writes a history (text, code, link, a pinned item, an image with OCR text) and Silk Notes;
#   - this version opens it: every item, pin, image byte and note comes back, its own notes with reminders and
#     checklists round-trip; the history moves to per-item files; the pre-migration folder is kept as a
#     byte-for-byte backup and deleted on the next open.
set -euo pipefail
cd "${0:A:h}/.."
OLD=726b981
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/old" "$T/new" "$T/data/History"
head -c 32 /dev/urandom > "$T/data/key"

OLD_FILES=(Spider/MotionMath.swift Clipboard/ClipboardItem.swift Clipboard/PasteboardReader.swift Clipboard/ClipboardController.swift
  Clipboard/ItemPreview.swift Clipboard/HistoryStore.swift App/AppData.swift Clipboard/SecretGuard.swift Notes/SilkNote.swift
  Notes/NoteVisibility.swift Notes/SilkRailResolver.swift)
for f in $OLD_FILES; do git show "$OLD:Sources/WEBBER/$f" > "$T/old/${f:t}"; done

cat > "$T/old/main.swift" <<'SWIFT'
import AppKit
import CryptoKit
let dir = URL(fileURLWithPath:CommandLine.arguments[1])
let key = SymmetricKey(data:try! Data(contentsOf:dir.appendingPathComponent("key")))
func text(_ id: Int, _ s: String) -> ClipboardItem { ClipboardItem(id:id,kind:.text,representations:[(.string,Data(s.utf8))],text:s,url:nil,fileURLs:[],image:nil) }
let image = NSImage(size:NSSize(width:320,height:200)); image.lockFocus()
NSColor.systemTeal.setFill(); NSRect(x:0,y:0,width:320,height:200).fill(); image.unlockFocus()
let png = NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
let shot = ClipboardItem(id:4,kind:.image,representations:[(.png,png)],text:nil,url:nil,fileURLs:[],image:NSImage(data:png))
shot.recognizedText = "Quarterly review 10:30"
let link = ClipboardItem(id:3,kind:.url,representations:[(.string,Data("https://example.org/docs".utf8)),(.URL,Data("https://example.org/docs".utf8))],
                         text:"https://example.org/docs",url:URL(string:"https://example.org/docs"),fileURLs:[],image:nil)
let pinned = text(5,"keep this one"); pinned.pinned = true
let code = ClipboardItem(id:2,kind:.code,representations:[(.string,Data("func demo() { return 42 }".utf8))],text:"func demo() { return 42 }",url:nil,fileURLs:[],image:nil)
let items = [text(1,"first fake copy"),code,link,shot,pinned]
let store = HistoryStore(folder:dir.appendingPathComponent("History"),key:key); store.save(items); store.flush()
var note = SilkNote(text:"buy milk",x:1,display:"test"); note.pinned = true
let noteStore = NoteStore(file:dir.appendingPathComponent("Notes.enc"),key:key)
noteStore.save([note,SilkNote(text:"call the plumber",x:2,display:"test")]); noteStore.flush()
try! png.write(to:dir.appendingPathComponent("expected.png"))
print("1.2.2 wrote", items.count, "items and 2 notes")
SWIFT
swiftc -swift-version 5 "$T"/old/*.swift -o "$T/old-writer" 2>/dev/null
"$T/old-writer" "$T/data"
# What 1.2.2 left on disk, to compare the backup with.
(cd "$T/data/History" && LC_ALL=C shasum -a 256 $(LC_ALL=C ls)) > "$T/before.txt"
ls "$T/data/History" | grep -q '^index.enc$' || { echo "FAIL 1.2.2 did not write its single index"; exit 1; }

NEW_FILES=(Spider/MotionMath.swift Clipboard/ClipboardItem.swift Clipboard/PasteboardReader.swift Clipboard/ClipboardController.swift
  Clipboard/ItemPreview.swift Clipboard/HistoryStore.swift App/AppData.swift App/BuildFlavor.swift Clipboard/SecretGuard.swift
  Clipboard/SecretDetector.swift Notes/SilkNote.swift Notes/NoteVisibility.swift Notes/SilkRailResolver.swift)
for f in $NEW_FILES; do cp "Sources/WEBBER/$f" "$T/new/${f:t}"; done
cat > "$T/new/main.swift" <<'SWIFT'
import AppKit
import CryptoKit
let dir = URL(fileURLWithPath:CommandLine.arguments[1])
let key = SymmetricKey(data:try! Data(contentsOf:dir.appendingPathComponent("key")))
let history = dir.appendingPathComponent("History")
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { failures += 1 } }
let files = { Set((try? FileManager.default.contentsOfDirectory(atPath:history.path)) ?? []) }
let store = HistoryStore(folder:history,key:key)
let items = store.load(); store.flush()
check(items.map(\.id) == [1,2,3,4,5],"all five items, in order")
check(items[0].text == "first fake copy" && items[1].text == "func demo() { return 42 }" && items[1].kind == .code,"text and code")
check(items[2].url?.absoluteString == "https://example.org/docs","link")
check(items[3].representations.first { $0.0 == .png }?.1 == (try? Data(contentsOf:dir.appendingPathComponent("expected.png"))),"image bytes identical")
check(items[3].recognizedText == "Quarterly review 10:30","text read from the image")
check(items[4].pinned && !items[0].pinned,"pin kept")
check(files().contains("order.enc") && !files().contains("index.enc") && files().contains("1.meta.enc"),"moved to per-item files")
let backup = store.backupFolder
let backupSums = (try? FileManager.default.contentsOfDirectory(atPath:backup.path))?.sorted().map { name -> String in
    let d = try! Data(contentsOf:backup.appendingPathComponent(name))
    return SHA256.hash(data:d).map { String(format:"%02x",$0) }.joined()+"  "+name
} ?? []
check(backupSums.joined(separator:"\n")+"\n" == (try? String(contentsOf:dir.appendingPathComponent("before.txt"),encoding:.utf8)),"backup is byte-for-byte what 1.2.2 wrote")
let notes = NoteStore(file:dir.appendingPathComponent("Notes.enc"),key:key).load()
check(notes.map(\.text) == ["buy milk","call the plumber"] && notes[0].pinned,"Silk Notes")
// 1.3.0 notes: a reminder and a checklist survive a save and reopen, next to the notes 1.2.2 wrote.
var due = SilkNote(text:"stand-up at 10:30\n[ ] agenda\n[x] slides",x:3,display:"test"); due.remindAt = Date(timeIntervalSince1970:1_800_000_000)
let notes13 = NoteStore(file:dir.appendingPathComponent("Notes.enc"),key:key); notes13.save(notes+[due]); notes13.flush()
let reopened = NoteStore(file:dir.appendingPathComponent("Notes.enc"),key:key).load()
check(reopened.count == 3 && reopened[2].text == due.text && reopened[2].remindAt == due.remindAt && reopened[0].pinned && reopened[1].remindAt == nil,
      "notes with a reminder and a checklist round-trip (1.2.2 notes keep no reminder)")
let again = HistoryStore(folder:history,key:key).load()
check(again.map(\.id) == [1,2,3,4,5],"opens again after migration")
check(!FileManager.default.fileExists(atPath:backup.path),"backup deleted after the second open")
print("\(failures) upgrade failures"); exit(Int32(failures))
SWIFT
swiftc -swift-version 5 "$T"/new/*.swift -o "$T/new-reader" 2>/dev/null
cp "$T/before.txt" "$T/data/before.txt"
"$T/new-reader" "$T/data"
