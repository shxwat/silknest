import AppKit
import CryptoKit
import simd

/// Clipboard capture, Copy Again, drag-out payloads, and web geometry/physics.
/// Uses private named pasteboards only; the user's clipboard is never touched.
let testKey = SymmetricKey(size:.bits256)

final class ClipboardWebChecks {
    var failures = 0
    func check(_ condition: Bool, _ label: String, line: Int = #line) { if !condition { print("FAIL \(label) at line \(line)"); failures += 1 } }
    var count = 0
    func board() -> NSPasteboard {
        count += 1
        let b = NSPasteboard(name:NSPasteboard.Name("studio.webber.tests.\(ProcessInfo.processInfo.processIdentifier).\(count)"))
        b.clearContents(); return b
    }
    func read(_ b: NSPasteboard) -> ClipboardItem? { if case .item(let item) = PasteboardReader.read(b,id:1) { return item }; return nil }

    func testKinds() {
        var b = board(); b.setString("fatal error: concurrent map writes",forType:.string)
        check(read(b)?.kind == .text,"plain text")
        b = board(); b.setString("func main() {\n\tm := map[string]int{}\n}",forType:.string)
        check(read(b)?.kind == .code,"code")
        b = board(); b.setString("https://github.com/golang/go/issues",forType:.string)
        let url = read(b)
        check(url?.kind == .url && url?.url?.host == "github.com","url from string")
        b = board(); b.setString("see https://example.com for details",forType:.string)
        check(read(b)?.kind == .text,"sentence containing a url stays text")
        b = board(); b.writeObjects([URL(fileURLWithPath:"/System/Library/CoreServices/SystemVersion.plist") as NSURL])
        let file = read(b)
        check(file?.kind == .file && file?.fileURLs.first?.lastPathComponent == "SystemVersion.plist","file")
        b = board(); b.writeObjects([testImage()])
        let image = read(b)
        check(image?.kind == .image && image?.image != nil,"image")
        check((image?.preview.size.width ?? 0) > 20,"image thumbnail")
        b = board(); b.setString("hunter2",forType:.string); b.setData(Data(),forType:.init("org.nspasteboard.ConcealedType"))
        if case .concealed = PasteboardReader.read(b,id:1) {} else { check(false,"concealed is refused") }
        b = board()
        if case .empty = PasteboardReader.read(b,id:1) {} else { check(false,"empty") }
    }

    func testCopyAgainRestoresExactText() {
        let source = board(); let text = "fatal error: concurrent map writes\n\tgoroutine 7 [running]"
        source.setString(text,forType:.string)
        guard let item = read(source) else { check(false,"read"); return }
        let target = board(); target.setString("other",forType:.string)
        item.restore(to:target)
        check(target.string(forType:.string) == text,"copy again text")
        let files = board(); files.writeObjects([URL(fileURLWithPath:"/System/Library/CoreServices/SystemVersion.plist") as NSURL])
        guard let file = read(files) else { check(false,"file read"); return }
        let fileTarget = board(); file.restore(to:fileTarget)
        let urls = fileTarget.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]
        check(urls?.first?.path == "/System/Library/CoreServices/SystemVersion.plist","copy again file")
    }

    func testDragOutPayloads() {
        let b = board(); b.writeObjects([testImage()])
        guard let image = read(b) else { check(false,"image read"); return }
        let drag = board(); drag.writeObjects(image.dragWriters())
        let fileURL = drag.string(forType:.fileURL).flatMap(URL.init(string:))
        check(fileURL.map { FileManager.default.fileExists(atPath:$0.path) } == true,"image drag provides a real file")
        check(drag.data(forType:.png) != nil || drag.data(forType:.tiff) != nil,"image drag provides image data")
        image.discard()
        check(fileURL.map { !FileManager.default.fileExists(atPath:$0.path) } == true,"export removed on discard")
        let t = board(); t.setString("some note",forType:.string)
        guard let text = read(t) else { return }
        let textDrag = board(); textDrag.writeObjects(text.dragWriters())
        check(textDrag.string(forType:.string) == "some note","text drag")
    }

    func testCapacityReleasesOldestUnpinned() {
        let controller = ClipboardController()
        var first: ClipboardItem?
        for i in 0..<ClipboardController.capacity {
            let b = board(); b.setString("item \(i)",forType:.string)
            guard case .caught(let item) = controller.catchCurrent(b) else { check(false,"catch \(i)"); return }
            if i == 0 { first = item; item.pinned = true }
            check(controller.store(item).released == nil,"room for \(i)")
        }
        let b = board(); b.setString("overflow",forType:.string)
        guard case .caught(let extra) = controller.catchCurrent(b) else { check(false,"overflow catch"); return }
        let result = controller.store(extra)
        check(result.stored && result.released != nil && result.released !== first,"pinned survives, oldest unpinned released")
        check(controller.items.count == ClipboardController.capacity,"capacity held")
        if case .alreadyCaught = controller.catchCurrent(b) {} else { check(false,"same pasteboard twice is not re-caught") }
    }

    func testWebGeometryExpandsAcrossDisplay() {
        let bounds = CGRect(x:-1260,y:20,width:1740,height:1050)
        let g = WebGeometry(compactHub:V3(275,235,0),expandedBounds:bounds)
        var compact: [V3] = [], open: [V3] = []
        for slot in 0..<g.slots.count {
            compact.append(g.anchor(slot:slot,0)); open.append(g.anchor(slot:slot,1))
            let a = g.anchor(slot:slot,0)
            check(a.x > 40 && a.x < 470 && a.y > 60 && a.y < 420,"compact anchor \(slot) inside the corner web")
            let b = g.anchor(slot:slot,1)
            check(bounds.contains(CGPoint(x:CGFloat(b.x),y:CGFloat(b.y))),"open anchor \(slot) on screen")
        }
        func spread(_ points: [V3]) -> Float {
            var minimum = Float.greatestFiniteMagnitude
            for i in points.indices { for j in points.indices where j > i { minimum = min(minimum,simd_distance(points[i],points[j])) } }
            return minimum
        }
        check(spread(open) > 90,"opened items have room to read and grab")
        check(spread(open) > spread(compact)*2,"items separate as the web opens")
        let reach = g.strands.indices.map { g.length($0,1) }.max() ?? 0
        check(reach > 600,"strands extend toward the screen edges")
        check(g.edges(1).count == g.edges(0).count,"same silk, extended rather than replaced")
    }

    func testHangingItemSettles() {
        let item = WebItem(id:3,slot:0); item.phase = .hanging
        item.nudge(0.6)
        var peak: Float = 0
        for _ in 0..<240 { item.step(dt:1/60,impulse:0,time:0); peak = max(peak,abs(item.sway)) }
        check(peak > 0.02 && peak < 1,"restrained sway")
        check(item.isSettled,"motion settles to stillness within four seconds")
    }

    func testDuplicateCopiesArePromotedNotDuplicated() {
        let controller = ClipboardController()
        let a = board(); a.setString("fatal error: concurrent map writes",forType:.string)
        guard case .caught(let first) = controller.catchCurrent(a) else { check(false,"first"); return }
        _ = controller.store(first)
        let b = board(); b.setString("something else",forType:.string)
        guard case .caught(let second) = controller.catchCurrent(b) else { check(false,"second"); return }
        _ = controller.store(second)
        let c = board(); c.setString("fatal error: concurrent map writes",forType:.string)
        guard case .caught(let again) = controller.catchCurrent(c) else { check(false,"again"); return }
        check(controller.existing(again) === first,"same text recognised")
        controller.promote(first)
        check(controller.items.last === first && controller.items.count == 2,"promoted to newest, not duplicated")
        let i1 = board(); i1.writeObjects([testImage()])
        let i2 = board(); i2.writeObjects([testImage()])
        if case .caught(let x) = controller.catchCurrent(i1), case .caught(let y) = controller.catchCurrent(i2) {
            check(x.fingerprint == y.fingerprint,"identical images share a fingerprint")
        } else { check(false,"images read") }
    }

    func testHistorySurvivesRestart() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("webber-history-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:folder) }
        let store = HistoryStore(folder:folder,key:testKey)
        let a = board(); a.setString("fatal error: concurrent map writes",forType:.string)
        let i = board(); i.writeObjects([testImage()])
        let u = board(); u.setString("https://github.com/golang/go",forType:.string)
        guard let text = read(a), case .item(let image) = PasteboardReader.read(i,id:2), case .item(let url) = PasteboardReader.read(u,id:3) else { check(false,"reads"); return }
        image.pinned = true; image.recognizedText = "hello from a screenshot"
        store.save([text,image,url]); store.flush()
        let back = HistoryStore(folder:folder,key:testKey).load()
        check(back.count == 3,"three items restored")
        check(back.first?.text == "fatal error: concurrent map writes","text restored exactly")
        check(back[1].kind == .image && back[1].image != nil && back[1].pinned,"image + pin restored")
        check(back[1].recognizedText == "hello from a screenshot","OCR text restored")
        check(back[2].url?.host == "github.com","url restored")
        let target = board(); back[0].restore(to:target)
        check(target.string(forType:.string) == "fatal error: concurrent map writes","restored item pastes")
    }

    /// A large image leaves memory once saved, still pastes exactly, and stays on disk after a restart.
    func testLargeItemsStayOnDisk() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("webber-offload-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:folder) }
        let store = HistoryStore(folder:folder,key:testKey)
        let big = NSImage(size:NSSize(width:900,height:700))
        big.lockFocus()
        for i in 0..<400 { NSColor(calibratedHue:CGFloat(i%37)/37,saturation:0.8,brightness:0.9,alpha:1).setFill(); NSRect(x:(i*53)%900,y:(i*31)%700,width:40,height:30).fill() }
        big.unlockFocus()
        let b = board(); b.writeObjects([big])
        guard case .item(let image) = PasteboardReader.read(b,id:7) else { check(false,"big image read"); return }
        let original = image.representations.first { $0.0 == .png }?.1 ?? image.representations.first?.1
        check(image.memoryBytes > HistoryStore.offloadBytes,"test image is large")
        var offloaded = false
        store.onPersisted = { item, files, loader in item.offload(files:files,loader:loader); offloaded = true }
        store.save([image]); store.flush()
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        check(offloaded && image.isOffloaded && image.memoryBytes == 0,"large item left memory after saving")
        check(image.representations.first(where: { $0.0 == .png })?.1 == original || image.representations.first?.1 == original,"offloaded item reads back exactly")
        store.save([image]); store.flush()
        check(image.image != nil,"offloaded image still decodes")
        let back = HistoryStore(folder:folder,key:testKey).load()
        check(back.count == 1 && back[0].isOffloaded,"restored without loading content")
        check(back[0].caption == image.caption && back[0].fingerprint == image.fingerprint,"metadata restored from the index")
        check(back[0].image != nil,"restored large image loads on demand")
    }

    /// The Nest is ~60% of the visible display, fits with margins on small and large screens, and
    /// still hangs a useful page of items.
    func testNestSizeFitsDisplays() {
        // 13" MacBook Air (default), MacBook Air 1280×800, 27" 5K, and a short ultrawide.
        for visible in [NSRect(x:0,y:0,width:1470,height:918),NSRect(x:0,y:0,width:1280,height:775),
                        NSRect(x:0,y:0,width:2560,height:1415),NSRect(x:0,y:0,width:3440,height:1415)] {
            let r = OverlaySpace.nestRect(in:visible)
            check(visible.insetBy(dx:13,dy:13).contains(r),"Nest fits inside \(visible.size)")
            check(r.width >= min(640,visible.width-28) && r.height >= min(480,visible.height-28),"Nest not too small on \(visible.size)")
            check(r.width <= 1100 && r.height <= 780,"Nest not sprawling on \(visible.size)")
            check(abs(r.midX-visible.midX) < 1 && abs(r.midY-visible.midY) < 1,"Nest centred on \(visible.size)")
            var bounds = r.insetBy(dx:26,dy:26); bounds.size.height -= OverlaySpace.nestSearchBand
            let geometry = WebGeometry(compactHub:V3(275,235,0),expandedBounds:bounds)
            check(geometry.slots.count >= 20,"at least 20 items per page on \(visible.size) (got \(geometry.slots.count))")
        }
        let air = OverlaySpace.nestRect(in:NSRect(x:0,y:0,width:1470,height:918))
        check(air.width == 882 && air.height == 551,"13-inch Air: 882×551 (got \(air.size))")
    }

    // MARK: storage (per-item files, migration from the single index)

    private func sealed(_ data: Data) -> Data { Data("WBR1".utf8)+(try! AES.GCM.seal(data,using:testKey)).combined! }
    private func tempFolder(_ name: String) -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("webber-\(name)-\(UUID().uuidString)")
        let folder = parent.appendingPathComponent("History")
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        return folder
    }
    private func textItem(_ id: Int, _ text: String) -> ClipboardItem {
        ClipboardItem(id:id,kind:.text,representations:[(.string,Data(text.utf8))],text:text,url:nil,fileURLs:[],image:nil)
    }
    private func files(_ folder: URL) -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath:folder.path)) ?? []) }

    /// A 1.2.2 history (one encrypted index of every record) migrates to per-item files, with a byte-for-byte
    /// backup that is removed only after the migrated history has opened again.
    func testMigrationFromSingleIndex() {
        let folder = tempFolder("migrate"); defer { try? FileManager.default.removeItem(at:folder.deletingLastPathComponent()) }
        let texts = ["first copy","second copy","pinned copy"]
        var records: [String] = []
        for (i,t) in texts.enumerated() {
            let id = i+1
            try! sealed(Data(t.utf8)).write(to:folder.appendingPathComponent("\(id)-0.enc"))
            records.append("{\"id\":\(id),\"kind\":\"text\",\"createdAt\":\(700000000+id),\"pinned\":\(id == 3),\"files\":[],\"reps\":[{\"type\":\"public.utf8-plain-text\",\"file\":\"\(id)-0.enc\"}],\"ocr\":null,\"source\":\"Notes\",\"times\":2}")
        }
        try! sealed(Data("[\(records.joined(separator:","))]".utf8)).write(to:folder.appendingPathComponent("index.enc"))
        let before = Dictionary(uniqueKeysWithValues:files(folder).map { ($0,try! Data(contentsOf:folder.appendingPathComponent($0))) })

        let store = HistoryStore(folder:folder,key:testKey)
        let items = store.load(); store.flush()
        check(items.map(\.text) == texts && items[2].pinned && items[0].sourceName == "Notes" && items[0].timesCopied == 2,"1.2.2 history migrates intact")
        let after = files(folder)
        check(after.contains("order.enc") && !after.contains("index.enc") && after.isSuperset(of:["1.meta.enc","2.meta.enc","3.meta.enc","1-0.enc","2-0.enc","3-0.enc"]),"per-item files written, old index removed")
        let backup = store.backupFolder
        let backupFiles = Dictionary(uniqueKeysWithValues:files(backup).map { ($0,try! Data(contentsOf:backup.appendingPathComponent($0))) })
        check(backupFiles == before,"backup is byte-for-byte the pre-migration folder")
        let perms = (try? FileManager.default.attributesOfItem(atPath:backup.path)[.posixPermissions] as? Int) ?? 0
        check(perms == 0o700,"backup is owner-only")
        for name in after {
            let p = (try? FileManager.default.attributesOfItem(atPath:folder.appendingPathComponent(name).path)[.posixPermissions] as? Int) ?? 0
            check(p == 0o600,"\(name) owner-only")
        }
        let again = HistoryStore(folder:folder,key:testKey).load()
        check(again.map(\.text) == texts && again[2].pinned,"migrated history reopens")
        check(!FileManager.default.fileExists(atPath:backup.path),"backup removed after a successful reopen")
    }

    /// If the backup can't be made, nothing is migrated or lost: the old index keeps working and is retried.
    func testMigrationFailureKeepsOldIndex() {
        let folder = tempFolder("migfail"); let parent = folder.deletingLastPathComponent()
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:parent.path); try? FileManager.default.removeItem(at:parent) }
        try! sealed(Data("kept".utf8)).write(to:folder.appendingPathComponent("1-0.enc"))
        try! sealed(Data("[{\"id\":1,\"kind\":\"text\",\"createdAt\":1,\"pinned\":false,\"files\":[],\"reps\":[{\"type\":\"public.utf8-plain-text\",\"file\":\"1-0.enc\"}]}]".utf8)).write(to:folder.appendingPathComponent("index.enc"))
        let store = HistoryStore(folder:folder,key:testKey)
        try! FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:parent.path)   // no room for a backup
        let items = store.load(); store.flush()
        check(items.map(\.text) == ["kept"] && files(folder).contains("index.enc") && !files(folder).contains("order.enc"),"failed migration leaves the old index")
        store.save(items+[textItem(2,"new while stuck")]); store.flush()
        try! FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:parent.path)
        let later = HistoryStore(folder:folder,key:testKey).load()
        check(later.map(\.text) == ["kept","new while stuck"],"nothing lost; migration retried next launch")
        check(files(folder).contains("order.enc"),"retry migrated")
    }

    /// A new copy writes only its own files and the order; Remove and Clear delete files; pins survive.
    func testIncrementalSaveAndDeletion() {
        let folder = tempFolder("incr"); defer { try? FileManager.default.removeItem(at:folder.deletingLastPathComponent()) }
        let store = HistoryStore(folder:folder,key:testKey)
        var items = (1...40).map { textItem($0,"copy number \($0)") }
        items[4].pinned = true
        store.save(items); store.flush()
        func stamp(_ n: String) -> Date { (try? FileManager.default.attributesOfItem(atPath:folder.appendingPathComponent(n).path)[.modificationDate] as? Date) ?? .distantPast }
        let old = stamp("1.meta.enc")
        Thread.sleep(forTimeInterval:1.1)
        items.append(textItem(41,"one more")); store.save(items); store.flush()
        check(stamp("1.meta.enc") == old,"unchanged items are not rewritten")
        check(files(folder).contains("41.meta.enc") && files(folder).contains("41-0.enc"),"new item written")
        items.removeAll { $0.id == 7 }; store.save(items); store.flush()
        check(!files(folder).contains("7.meta.enc") && !files(folder).contains("7-0.enc"),"Remove deletes the item's files")
        items.removeAll { !$0.pinned }; store.save(items); store.flush()
        check(files(folder) == ["order.enc","5.meta.enc","5-0.enc"],"Clear deletes everything but pinned items (\(files(folder).sorted()))")
        let back = HistoryStore(folder:folder,key:testKey).load()
        check(back.map(\.id) == [5] && back[0].pinned,"pinned item survives Clear")
    }

    /// The 1000 limit: the oldest unpinned item goes first; pinned items never do.
    func testHistoryLimit() {
        let controller = ClipboardController()
        for i in 1...ClipboardController.capacity {
            let item = textItem(i,"item \(i)"); if i <= 3 { item.pinned = true }
            _ = controller.store(item)
        }
        for i in 1...5 { _ = controller.store(textItem(5000+i,"late \(i)")) }
        check(controller.items.count == ClipboardController.capacity,"stays at \(ClipboardController.capacity)")
        check(controller.items.filter(\.pinned).map(\.id) == [1,2,3],"pinned never released")
        check(!controller.items.contains { (4...8).contains($0.id) } && controller.items.contains { $0.id == 9 },"oldest unpinned released first")
    }

    /// Nest search: pinned first then newest; every field searchable; fast over 1000 items.
    func testNestSearch() {
        let old = textItem(1,"quarterly invoice draft"); old.sourceName = "Pages"
        let link = ClipboardItem(id:2,kind:.url,representations:[(.string,Data("https://docs.example.org/guide".utf8))],text:"https://docs.example.org/guide",
                                 url:URL(string:"https://docs.example.org/guide"),fileURLs:[],image:nil)
        let shot = ClipboardItem(id:3,kind:.image,representations:[(.png,ItemPreview.png(testImage())!)],text:nil,url:nil,fileURLs:[],image:testImage())
        shot.recognizedText = "Total due 4,200"; shot.sourceName = "Screenshot"
        let pinned = textItem(4,"pinned snippet"); pinned.pinned = true
        let newest = textItem(5,"newest invoice copy"); newest.sourceName = "Mail"
        let newestFirst = [newest,pinned,shot,link,old]
        let ordered = NestKeyboard.ordered(newestFirst)
        check(ordered.map(\.id) == [4,5,3,2,1],"pinned first, then newest first")
        let entries = ordered.map { NestKeyboard.Entry(id:$0.id,kind:$0.kind,pinned:$0.pinned,haystack:$0.searchableText) }
        func ids(_ q: String) -> [Int] { NestKeyboard.search(entries,query:q) }
        check(ids("invoice") == [5,1],"text, newest first")
        check(ids("pages") == [1] && ids("mail invoice") == [5],"source app is searchable")
        check(ids("example.org") == [2] && ids("docs") == [2],"links and domains")
        check(ids("4,200") == [3] && ids("img total") == [3],"text inside screenshots, kind filter")
        check(ids("pin") == [4] && ids("PINNED snippet") == [4],"pin filter, case-insensitive")
        check(ids("nothing-like-this").isEmpty,"no false matches")
        shot.recognizedText = "Changed later"
        check(shot.searchableText.contains("changed later") && !shot.searchableText.contains("4,200"),"OCR update refreshes search text")
        // 1000 items, typing "screen" one letter at a time.
        let words = ["silk","nest","spider","invoice","deploy","fatal","error","budget","screen","report","kernel","window"]
        let many = (0..<1000).map { i in NestKeyboard.Entry(id:i,kind:.text,pinned:false,haystack:(0..<(20+i%200)).map { words[($0*7+i)%words.count] }.joined(separator:" ")) }
        var worst = 0.0
        for n in 1..."screen".count {
            let t = CACurrentMediaTime(); _ = NestKeyboard.search(many,query:String("screen".prefix(n))); worst = max(worst,(CACurrentMediaTime()-t)*1000)
        }
        check(worst < 25,"search over 1000 items stays under 25 ms per keystroke (worst \(String(format:"%.1f",worst)) ms)")
    }

    // MARK: secrets (fake values, assembled at runtime so no token-shaped string sits in the repo)

    private func fake(_ prefix: String, _ n: Int, _ alphabet: String = "AbCdEfGhJkMnPqRsTuVwXyZ23456789") -> String {
        let a = Array(alphabet); return prefix+String((0..<n).map { a[($0*7+3) % a.count] })
    }

    func testSecretDetection() {
        let samples: [(String,SecretDetector.Kind,String)] = [
            (fake("sk-"+"ant-api03-",40),.apiKey,"Anthropic"),
            (fake("sk-"+"proj-",48),.apiKey,"OpenAI project"),
            (fake("s"+"k-",48),.apiKey,"OpenAI"),
            (fake("r"+"8_",37),.apiKey,"Replicate"),
            (fake("gh"+"p_",36),.token,"GitHub classic"),
            (fake("gh"+"o_",36),.token,"GitHub OAuth"),
            (fake("github"+"_pat_",59),.token,"GitHub fine-grained"),
            (fake("xo"+"xb-",40,"0123456789-abcdefghjk"),.token,"Slack bot"),
            (fake("xo"+"xp-",40,"0123456789-abcdefghjk"),.token,"Slack user"),
            (fake("AK"+"IA",16,"ABCDEFGHJKLMNPQRSTUVWXYZ234567"),.apiKey,"AWS"),
            (fake("AI"+"za",35),.apiKey,"Google"),
            (fake("gl"+"pat-",20),.token,"GitLab"),
            (fake("h"+"f_",34),.token,"Hugging Face"),
            (fake("ey"+"J",20)+"."+fake("ey"+"J",30)+"."+fake("",43),.jwt,"JWT"),
            ("-----BEGIN "+"OPENSSH PRIVATE KEY-----\n"+fake("",64)+"\n-----END OPENSSH PRIVATE KEY-----",.privateKey,"SSH key"),
            ("-----BEGIN "+"RSA PRIVATE KEY-----\n"+fake("",64),.privateKey,"PEM key, no footer"),
            ("4242 4242 4242 4242",.card,"Visa test card"),
            ("5555555555554444",.card,"Mastercard test card"),
            ("Your verification code is 482913. Don't share it.",.otp,"code in a message"),
        ]
        for (value,kind,label) in samples {
            check(SecretDetector.detect(value)?.kind == kind,"detects \(label)")
        }
        check(SecretDetector.detect("482913",source:"com.apple.MobileSMS")?.kind == .otp,"bare code from Messages")
        check(SecretDetector.detect("482 913",source:"com.google.Authenticator")?.kind == .otp,"spaced code from an authenticator")
        let env = "OPENAI_API_KEY="+fake("s"+"k-",48)
        if let f = SecretDetector.detect(env) {
            let m = SecretDetector.masked(env,f)
            check(m.hasPrefix("OPENAI_API_KEY=sk-••••••••") && !m.contains(fake("",20)),"masks the key inside a line, keeps the name")
        } else { check(false,"key inside an env line") }
        let r8 = fake("r"+"8_",37)
        check(SecretDetector.masked(r8,SecretDetector.detect(r8)!) == "r8_••••••••"+String(r8.suffix(3)),"mask shape r8_••••••••xyz")
        check(SecretDetector.masked("4242 4242 4242 4242",SecretDetector.detect("4242 4242 4242 4242")!) == "•••• •••• •••• 4242","card mask keeps last four")
        let pem = "-----BEGIN "+"PRIVATE KEY-----\n"+fake("",64)+"\n-----END PRIVATE KEY-----"
        check(!SecretDetector.masked(pem,SecretDetector.detect(pem)!).contains(fake("",20)),"key body fully masked")

        // Ordinary text and code must not be flagged.
        let normal = [
            "sk-learn is a Python library", "pip install sk-video", "hf_hub_download(repo_id)", "ghp_ is the prefix GitHub uses",
            "let total = 123456", "Order #123456 has shipped", "Call me at +91 98765 43210", "PIN code 560001",
            "4242 4242 4242 4241", "1234 5678 9012 3456", "Invoice 2024-11-10 total 4,200",
            "550e8400-e29b-41d4-a716-446655440000", "commit 9fceb02d0ae598e95dc970b74767f19372d61af8",
            "eyJhbGciOiJIUzI1NiJ9 is just a header", "func main() {\n    fmt.Println(\"AKIA\")\n}",
            "https://github.com/golang/go/issues/1234", "The meeting moved to 10:30, room 4012", "AIza is how Google keys start",
            "-----BEGIN CERTIFICATE-----\nMIIB", "We shipped 15 features this sprint"]
        for text in normal { check(SecretDetector.detect(text) == nil,"not a secret: \(text.prefix(30))") }
        check(SecretDetector.detect("560001",source:"com.apple.Notes") == nil,"6 digits from Notes is not a code")
    }

    func testSecretsAreMaskedAndNeverSaved() {
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey:"protectSecrets"),defaults.object(forKey:"neverCatchSecrets"))
        defer {
            if let p = saved.0 { defaults.set(p,forKey:"protectSecrets") } else { defaults.removeObject(forKey:"protectSecrets") }
            if let n = saved.1 { defaults.set(n,forKey:"neverCatchSecrets") } else { defaults.removeObject(forKey:"neverCatchSecrets") }
        }
        let key = fake("gh"+"p_",36)
        SecretGuard.protectSecrets = true; SecretGuard.neverCatchSecrets = false
        let controller = ClipboardController()
        let b = board(); b.setString(key,forType:.string)
        guard case .caught(let item) = controller.catchCurrent(b) else { check(false,"secret caught"); return }
        check(item.isSecret && item.neverPersist,"secret is memory-only")
        check(item.displayText == "ghp_••••••••"+String(key.suffix(3)) && !item.title.contains(String(key.dropFirst(4).prefix(10))),"shown masked")
        check(!item.searchableText.contains(String(key.dropFirst(4).prefix(10)).lowercased()) && item.searchableText.contains("secret"),"search sees only the mask")
        let target = board(); item.restore(to:target)
        check(target.string(forType:.string) == key,"pasting gives the real value")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("webber-secret-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:folder) }
        let store = HistoryStore(folder:folder,key:testKey); store.save([item]); store.flush()
        check(((try? FileManager.default.contentsOfDirectory(atPath:folder.path)) ?? []).allSatisfy { $0 == "order.enc" },"nothing of the secret on disk")
        SecretGuard.neverCatchSecrets = true
        let c = board(); c.setString(fake("gh"+"p_",36,"QWERTYUPASDFGHJKLZXCVBNM"),forType:.string)
        if case .concealed = controller.catchCurrent(c) {} else { check(false,"never-catch refuses secrets") }
        SecretGuard.neverCatchSecrets = false; SecretGuard.protectSecrets = false
        let d = board(); d.setString(fake("gh"+"p_",36,"MNBVCXZLKJHGFDSAPUYTREWQ"),forType:.string)
        if case .caught(let plain) = controller.catchCurrent(d) { check(!plain.isSecret && !plain.neverPersist,"protection off: a normal copy") }
        else { check(false,"protection off still catches") }
    }

    /// The screenshot preview is changed only with consent, and undoing it restores exactly what macOS had.
    func testScreenshotPreviewOptIn() {
        let real = ScreenshotPreview.backend
        defer { ScreenshotPreview.backend = real; ScreenshotPreview.resetForTesting() }
        var macOS: Bool?, writes = 0
        ScreenshotPreview.backend = .init(read: { macOS }, write: { macOS = $0; writes += 1 })
        func fresh(_ value: Bool?) { ScreenshotPreview.resetForTesting(); macOS = value; writes = 0 }

        fresh(nil)
        ScreenshotPreview.applyAtLaunch()
        check(macOS == nil && writes == 0 && ScreenshotPreview.choice == nil,"nothing changes before the user agrees")
        ScreenshotPreview.setInstant(true)
        check(macOS == false && ScreenshotPreview.instant,"agreeing turns the preview off")
        ScreenshotPreview.setInstant(false)
        check(macOS == nil,"turning it off restores 'never set' exactly")

        fresh(false)                                            // the user had turned the preview off themselves
        ScreenshotPreview.setInstant(true); ScreenshotPreview.setInstant(false)
        check(macOS == false && writes == 0,"a preview the user had off stays off, untouched")

        fresh(true)
        ScreenshotPreview.setInstant(true); ScreenshotPreview.restoreOriginal()
        check(macOS == true,"uninstall restores 'on'")

        fresh(false); UserDefaults.standard.set(true,forKey:"instantScreenshots")   // 1.2.2 turned it off silently
        ScreenshotPreview.setInstant(false)
        check(macOS == true,"declining after 1.2.2 puts the preview back on")
    }

    // MARK: secrets in screenshots

    /// A screenshot-like PNG with these lines of text (dark text on white, like a terminal or editor).
    private func fakeScreenshot(_ lines: [String]) -> (Data, CGImage) {
        let w = 1800, h = 120+lines.count*70
        let ctx = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray:1,alpha:1)); ctx.fill(CGRect(x:0,y:0,width:w,height:h))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:ctx,flipped:false)
        for (i,line) in lines.enumerated() {
            NSAttributedString(string:line,attributes:[.font:NSFont.monospacedSystemFont(ofSize:34,weight:.regular),.foregroundColor:NSColor.black])
                .draw(at:NSPoint(x:40,y:h-90-i*70))
        }
        NSGraphicsContext.restoreGraphicsState()
        let cg = ctx.makeImage()!
        return (NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:])!,cg)
    }
    private func imageItem(_ id: Int, _ png: Data) -> ClipboardItem {
        ClipboardItem(id:id,kind:.image,representations:[(.png,png)],text:nil,url:nil,fileURLs:[],image:NSImage(data:png))
    }

    /// OCR text of fake screenshots goes through the same secret detection as copied text.
    func testSecretsInScreenshots() {
        let shots: [([String],SecretDetector.Kind?,String)] = [
            (["# .env","OPENAI_API_KEY="+fake("s"+"k-",40)],.apiKey,"API key in a screenshot of a .env file"),
            (["git remote set-url origin","token: "+fake("gh"+"p_",36)],.token,"GitHub token on screen"),
            (["Card number","4242 4242 4242 4242","Expires 12/29"],.card,"card number in a screenshot"),
            (["-----BEGIN "+"PRIVATE KEY-----","MIIEvQIBADANBgkqhkiG9w0BAQEFAASC"],.privateKey,"private key block on screen"),
            (["Your verification code is 482913"],.otp,"code in a message screenshot"),
            (["Quarterly budget review moved to 10:30","Room 4012, bring the slides"],nil,"ordinary screenshot"),
            (["func main() {","    print(\"hello\")","}"],nil,"code screenshot"),
        ]
        for (lines,kind,label) in shots {
            let (_,cg) = fakeScreenshot(lines)
            let text = TextRecognizer.readText(cg)
            check(SecretDetector.detect(text)?.kind == kind,"\(label) (read \(text.count) chars)")
        }
    }

    /// A new image reaches the disk only after its text was checked; a secret never does, is blurred and
    /// unsearchable; "never catch secrets" lets it go; images saved earlier are taken off the disk.
    func testScreenshotSecretsNeverReachDisk() {
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey:"protectSecrets"),defaults.object(forKey:"neverCatchSecrets"))
        defer {
            if let p = saved.0 { defaults.set(p,forKey:"protectSecrets") } else { defaults.removeObject(forKey:"protectSecrets") }
            if let n = saved.1 { defaults.set(n,forKey:"neverCatchSecrets") } else { defaults.removeObject(forKey:"neverCatchSecrets") }
        }
        SecretGuard.protectSecrets = true; SecretGuard.neverCatchSecrets = false
        let folder = tempFolder("shotsecret"); defer { try? FileManager.default.removeItem(at:folder.deletingLastPathComponent()) }
        let store = HistoryStore(folder:folder,key:testKey)
        let token = fake("gh"+"p_",36)
        let (secretPNG,secretCG) = fakeScreenshot(["token: "+token])
        let (plainPNG,plainCG) = fakeScreenshot(["Lunch at one, then the design review"])
        let controller = ClipboardController()
        let secret = imageItem(301,secretPNG), plain = imageItem(302,plainPNG)
        for item in [secret,plain] { _ = controller.store(item); item.awaitingOCR = true }
        store.save(controller.items); store.flush()
        check(!files(folder).contains { $0.hasPrefix("301") || $0.hasPrefix("302") },"nothing written before the text is read")

        let pendingLook = secret.preview.tiffRepresentation
        check(controller.applyRecognizedText(TextRecognizer.readText(secretCG),to:secret) == .secret,"secret found in the image's text")
        let plainPending = plain.preview.tiffRepresentation
        check(controller.applyRecognizedText(TextRecognizer.readText(plainCG),to:plain) == .clean,"ordinary image is clean")
        check(plainPending != plain.preview.tiffRepresentation && pendingLook != secret.preview.tiffRepresentation,"blurred while checked; redrawn after (clear, or secret-labelled)")
        let unchecked = imageItem(305,plainPNG); unchecked.awaitingOCR = true
        let blurredLook = unchecked.preview.tiffRepresentation; unchecked.awaitingOCR = false
        check(blurredLook != unchecked.preview.tiffRepresentation,"a flying image is drawn blurred until its check")
        check(secret.isSecret && secret.neverPersist && secret.caption.contains("contains a secret"),"image with a secret is memory-only and labelled")
        check(!secret.searchableText.contains(String(token.dropFirst(4).prefix(8)).lowercased()) && secret.searchableText.contains("secret"),"its text is not searchable")
        let shown = secret.displayImage.flatMap { ItemPreview.png($0) }, original = secret.image.flatMap { ItemPreview.png($0) }
        check(shown != nil && shown != original,"shown blurred")
        store.save(controller.items); store.flush()
        check(!files(folder).contains { $0.hasPrefix("301") },"the secret image never reaches the disk")
        check(files(folder).contains("302.meta.enc") && files(folder).contains("302-0.enc"),"the clean image is saved after its check")
        let leaked = files(folder).contains { name in
            ((try? Data(contentsOf:folder.appendingPathComponent(name))) ?? Data()).range(of:Data(token.utf8)) != nil }
        check(!leaked,"no token bytes on disk")

        // Never catch secrets: the image must be let go.
        SecretGuard.neverCatchSecrets = true
        let refused = imageItem(303,secretPNG); _ = controller.store(refused); refused.awaitingOCR = true
        check(controller.applyRecognizedText(TextRecognizer.readText(secretCG),to:refused) == .refuse,"never-catch refuses the image")
        SecretGuard.neverCatchSecrets = false

        // Saved by an earlier version (OCR text already on disk): found at launch and deleted from disk.
        let old = imageItem(304,secretPNG); old.recognizedText = "token: "+token
        store.save([plain,old]); store.flush()
        check(files(folder).contains("304.meta.enc"),"(earlier version wrote it)")
        let reopened = HistoryStore(folder:folder,key:testKey)
        let restored = reopened.load()
        guard let back = restored.first(where: { $0.id == 304 }) else { check(false,"restored"); return }
        check(ClipboardController().checkImageForSecret(back) == .secret,"restored screenshot with a secret is recognised")
        reopened.save(restored); reopened.flush()
        check(!files(folder).contains { $0.hasPrefix("304") },"its files are deleted from disk")
    }

    /// Paste Stack: first in, first pasted; removal from history leaves the stack; empty means normal paste.
    func testPasteStack() {
        var stack = PasteStack()
        check(stack.isEmpty && stack.next() == nil,"empty stack: nothing to paste (normal ⌘V)")
        let a = textItem(1,"first"), b = textItem(2,"second"), c = textItem(3,"third")
        stack.add(a); stack.add(b); stack.add(c)
        check(stack.count == 3,"three queued")
        check(stack.next() === a && stack.next() === b,"pasted in the order they were added")
        stack.add(a); stack.remove(id:3)
        check(stack.items.map(\.id) == [1],"an item removed from history leaves the stack")
        stack.clear()
        check(stack.isEmpty,"Clear Stack empties it")
        let defaults = UserDefaults.standard
        for k in ["key","mods","cleared"] { defaults.removeObject(forKey:"shortcut.addToStack.\(k)") }
        check(ShortcutAction.addToStack.shortcut?.display == "⌃⌥V","default shortcut ⌃⌥V")
        check(!ShortcutAction.addToStack.fallbacks.isEmpty,"a free fallback when ⌃⌥V is taken")
    }

    /// The one-time Accessibility window: only on the first certificate-signed launch after ad-hoc builds.
    func testSignatureTransitionWindow() {
        func show(_ previous: String?, _ current: String, existing: Bool = true, explained: Bool = false, paste: Bool = true, trusted: Bool = false) -> Bool {
            SignatureTransition.shouldExplain(previous:previous,current:current,existingUser:existing,alreadyExplained:explained,wantsPaste:paste,pasteTrusted:trusted)
        }
        check(show(nil,"certificate"),"1.2.2 → 1.3.0: shown")
        check(show("adhoc","certificate"),"ad-hoc 1.3.0 build → certificate build: shown")
        check(!show("certificate","certificate"),"1.3.0 → 1.3.1: not shown")
        check(!show(nil,"adhoc"),"still ad-hoc: not shown")
        check(!show(nil,"certificate",existing:false),"new user (gets the normal first-run flow): not shown")
        check(!show(nil,"certificate",explained:true),"only once")
        check(!show(nil,"certificate",paste:false),"not when 1-click paste is off")
        check(!show(nil,"certificate",trusted:true),"not when Accessibility already works")
    }

    /// Silk Notes: reminders read from the text, checklists, and notes saved by 1.2.2 still open.
    func testNoteRemindersAndChecklists() {
        var cal = Calendar.current; cal.timeZone = .current
        let now = cal.date(from:DateComponents(year:2026,month:11,day:10,hour:14,minute:0))!
        let in20 = NoteReminder.date(in:"stand up in 20 min",now:now)
        check(in20.map { abs($0.timeIntervalSince(now)-1200) < 1 } == true,"\"in 20 min\"")
        check(NoteReminder.date(in:"deploy in 2 hours",now:now).map { abs($0.timeIntervalSince(now)-7200) < 1 } == true,"\"in 2 hours\"")
        let three = NoteReminder.date(in:"call Sam at 3pm",now:now)
        check(three.map { cal.component(.hour,from:$0) == 15 && cal.isDate($0,inSameDayAs:now) } == true,"\"3pm\" later today")
        let noon = NoteReminder.date(in:"lunch at 12pm",now:now)
        check(noon.map { cal.component(.hour,from:$0) == 12 && $0 > now } == true,"a time already passed today means tomorrow")
        let tomorrow = NoteReminder.date(in:"tomorrow 10am send invoice",now:now)
        check(tomorrow.map { cal.component(.hour,from:$0) == 10 && cal.component(.day,from:$0) == 11 } == true,"\"tomorrow 10am\"")
        check(NoteReminder.date(in:"buy milk and eggs",now:now) == nil,"no time, no reminder")
        // Checklists.
        let list = "Groceries\n[ ] milk\n  [x] eggs\nbread"
        check(NoteReminder.checkbox("[ ] milk")?.checked == false && NoteReminder.checkbox("[x] eggs")?.checked == true && NoteReminder.checkbox("bread") == nil,"checkbox lines")
        check(NoteReminder.toggle(list,line:1) == "Groceries\n[x] milk\n  [x] eggs\nbread","tick a box")
        check(NoteReminder.toggle(list,line:2) == "Groceries\n[ ] milk\n  [ ] eggs\nbread","untick, keeping the indent")
        check(NoteReminder.toggle(list,line:3) == list,"ordinary lines are untouched")
        // A reminder survives saving (encrypted), and 1.2.2 notes (no reminder field) still open.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("webber-notes-\(UUID().uuidString).enc")
        defer { try? FileManager.default.removeItem(at:file) }
        var note = SilkNote(text:"call Sam at 3pm",x:1,display:"test"); note.remindAt = three
        let store = NoteStore(file:file,key:testKey); store.save([note]); store.flush()
        check(NoteStore(file:file,key:testKey).load().first?.remindAt == three,"reminder saved")
        let old = try! JSONDecoder().decode([SilkNote].self,from:Data("[{\"id\":\"\(UUID().uuidString)\",\"text\":\"old note\",\"createdAt\":0,\"updatedAt\":0,\"x\":1,\"display\":\"d\",\"pinned\":false,\"mode\":\"global\",\"attachments\":[]}]".utf8))
        check(old.first?.text == "old note" && old.first?.remindAt == nil,"1.2.2 notes decode")
    }

    func testSearchAndTransforms() {
        let a = board(); a.setString("func main() {\n  go worker()\n}",forType:.string)
        guard let code = read(a) else { check(false,"read"); return }
        check(code.matches("worker"),"search finds content")
        check(code.matches("MAIN go"),"multi-word, case-insensitive")
        check(!code.matches("python"),"no false match")
        let t = { (title: String, input: String) in TextTransform.all.first { $0.title == title }!.apply(input) }
        check(t("UPPERCASE","abc") == "ABC","upper")
        check(t("One Line","a\n  b\n\nc") == "a b c","one line")
        check(t("Pretty JSON","{\"b\":1,\"a\":2}") == "{\n  \"a\" : 2,\n  \"b\" : 1\n}","pretty json")
        check(t("URL Decode","a%20b") == "a b","url decode")
    }

    func testCorruptHistoryStartsEmptyWithoutCrashing() {
        let fm = FileManager.default
        func folder() -> URL { let u = fm.temporaryDirectory.appendingPathComponent("webber-corrupt-\(UUID().uuidString)"); try? fm.createDirectory(at:u,withIntermediateDirectories:true); return u }
        let garbage = folder(); defer { try? fm.removeItem(at:garbage) }
        try? Data("{ this is not json".utf8).write(to:garbage.appendingPathComponent("index.json"))
        check(HistoryStore(folder:garbage,key:testKey).load().isEmpty,"garbage index → empty history")
        let wrongShape = folder(); defer { try? fm.removeItem(at:wrongShape) }
        try? Data("{\"items\":42}".utf8).write(to:wrongShape.appendingPathComponent("index.json"))
        check(HistoryStore(folder:wrongShape,key:testKey).load().isEmpty,"wrong JSON shape → empty history")
        let missing = folder(); defer { try? fm.removeItem(at:missing) }
        let json = "[{\"id\":1,\"kind\":\"text\",\"createdAt\":0,\"pinned\":false,\"files\":[],\"reps\":[{\"type\":\"public.utf8-plain-text\",\"file\":\"gone.bin\"}]},"
            + "{\"id\":2,\"kind\":\"alien\",\"createdAt\":0,\"pinned\":false,\"files\":[],\"reps\":[]},"
            + "{\"id\":3,\"kind\":\"file\",\"createdAt\":0,\"pinned\":false,\"files\":[\"/nonexistent/x.txt\"],\"reps\":[]}]"
        try? Data(json.utf8).write(to:missing.appendingPathComponent("index.json"))
        check(HistoryStore(folder:missing,key:testKey).load().isEmpty,"missing blobs / unknown kind / deleted file are skipped")
        let empty = folder(); defer { try? fm.removeItem(at:empty) }
        check(HistoryStore(folder:empty,key:testKey).load().isEmpty,"no history yet → empty")
    }

    func testSensitiveClipboardIsNeverCaught() {
        let markers = ["org.nspasteboard.ConcealedType","org.nspasteboard.TransientType","org.nspasteboard.AutoGeneratedType","com.agilebits.onepassword"]
        let controller = ClipboardController()
        for marker in markers {
            let b = board(); b.setString("hunter2-secret",forType:.string); b.setData(Data(),forType:.init(marker))
            if case .concealed = controller.catchCurrent(b) {} else { check(false,"\(marker) refused") }
            let img = board(); img.writeObjects([testImage()]); img.setData(Data(),forType:.init(marker))
            if case .concealed = controller.catchCurrent(img) {} else { check(false,"\(marker) image refused") }
        }
        check(controller.items.isEmpty,"nothing sensitive stored")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("webber-sensitive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:folder) }
        let store = HistoryStore(folder:folder,key:testKey); store.save(controller.items); store.flush()
        let written = (try? FileManager.default.contentsOfDirectory(atPath:folder.path)) ?? []
        let leaked = written.contains { name in (try? String(contentsOf:folder.appendingPathComponent(name),encoding:.utf8))?.contains("hunter2") == true }
        check(!leaked,"no sensitive bytes on disk")
    }

    func testTransformsOnlyWhenUseful() {
        func titles(_ s: String) -> Set<String> { Set(TextTransform.applicable(to:s).map(\.title)) }
        check(titles("hello world") == ["UPPERCASE","Title Case"],"plain lowercase sentence")
        check(titles("HELLO") == ["lowercase","Title Case"],"already uppercase")
        check(titles("Hello World") == ["UPPERCASE","lowercase"],"already title case")
        check(titles("12345").isEmpty,"digits: nothing to transform")
        check(titles("   \n  ").isEmpty,"whitespace only: nothing")
        check(titles("{\"a\":1,\"b\":[1,2]}") == ["Pretty JSON"],"compact JSON: only Pretty JSON")
        check(!titles("{\n  \"a\" : 1\n}").contains("Pretty JSON") || TextTransform.all.first { $0.title == "Pretty JSON" }!.apply("{\n  \"a\" : 1\n}") != "{\n  \"a\" : 1\n}","pretty JSON only if it changes")
        check(!titles("42").contains("Pretty JSON"),"bare JSON number is not offered")
        check(titles("a%20b").contains("URL Decode"),"percent-encoded text")
        check(!titles("100% sure").contains("URL Decode"),"a percent sign alone is not encoding")
        check(titles("  padded  ").contains("Trim") && !titles("tidy").contains("Trim"),"trim only when padded")
        check(titles("line one\nline two").contains("One Line") && !titles("single line").contains("One Line"),"one line only for multi-line")
        check(!titles("https://github.com/golang/go").contains("Title Case"),"no Title Case on links")
        check(!titles("func main() { print(1) }").contains("Title Case"),"no Title Case on code")
        for sample in ["hello world","HELLO","{\"a\":1}","a%20b","  x  ","a\nb","https://x.com/A"] {
            for t in TextTransform.applicable(to:sample) {
                let out = t.apply(sample)
                check(out != sample && !out.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,"\(t.title) changes \(sample)")
            }
        }
    }

    func testSecretsAndEncryptionAtRest() {
        check(SecretGuard.fromPasswordManager("com.1password.1password") && !SecretGuard.fromPasswordManager("com.apple.Safari"),"password managers")

        // Secrets never reach disk; everything else is stored encrypted, owner-only.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("webber-sec-\(UUID().uuidString)")
        let store = HistoryStore(folder:folder,key:testKey)
        let a = board(); a.setString("fatal error: concurrent map writes",forType:.string)
        let b = board(); b.setString("api_abcdefghijklmnopqrstuvwxyz0123456789",forType:.string)
        func read(_ b: NSPasteboard, _ id: Int) -> ClipboardItem? { if case .item(let item) = PasteboardReader.read(b,id:id) { return item }; return nil }
        guard let normal = read(a,1), let token = read(b,2) else { check(false,"read"); return }
        // API keys / OTPs are kept like any copy; only password-manager copies are memory-only.
        check(!SecretGuard.isSensitive(token),"tokens are kept")
        let fromVault = read(a,3)!; fromVault.sourceBundleID = "com.1password.1password"
        fromVault.neverPersist = SecretGuard.isSensitive(fromVault)
        check(fromVault.neverPersist,"password manager copy is memory-only")
        store.save([normal,token,fromVault]); store.flush()
        let names = (try? FileManager.default.contentsOfDirectory(atPath:folder.path)) ?? []
        var leaked = false
        for name in names {
            let data = (try? Data(contentsOf:folder.appendingPathComponent(name))) ?? Data()
            if data.range(of:Data("concurrent map".utf8)) != nil || data.range(of:Data("api_abcdef".utf8)) != nil { leaked = true }
            let perms = (try? FileManager.default.attributesOfItem(atPath:folder.appendingPathComponent(name).path)[.posixPermissions] as? Int) ?? 0
            check(perms == 0o600,"file \(name) is owner-only")
        }
        check(!leaked,"no plaintext on disk")
        let dirPerms = (try? FileManager.default.attributesOfItem(atPath:folder.path)[.posixPermissions] as? Int) ?? 0
        check(dirPerms == 0o700,"folder is owner-only")
        let back = HistoryStore(folder:folder,key:testKey).load()
        check(back.count == 2 && Set(back.compactMap(\.text)) == ["fatal error: concurrent map writes","api_abcdefghijklmnopqrstuvwxyz0123456789"],"token and text come back; vault copy does not")
        check(HistoryStore(folder:folder,key:SymmetricKey(size:.bits256)).load().isEmpty,"wrong key reads nothing")
        check(HistoryStore(folder:folder,key:nil).load().isEmpty,"no key reads nothing")
        let none = FileManager.default.temporaryDirectory.appendingPathComponent("webber-nokey-\(UUID().uuidString)")
        HistoryStore(folder:none,key:nil).save([normal])
        check(((try? FileManager.default.contentsOfDirectory(atPath:none.path)) ?? []).isEmpty,"no key → nothing written")
        try? FileManager.default.removeItem(at:folder); try? FileManager.default.removeItem(at:none)
    }

    func testSilkNotesStore() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("webber-notes-\(UUID().uuidString).enc")
        let store = NoteStore(file:file,key:testKey)
        var a = SilkNote(text:"fix refresh token race",x:0.25,display:"D1")
        a.bundleID = "com.microsoft.VSCode"
        let b = SilkNote(text:"deploy webber 1.0 to github release after final QA pass",x:0.8,display:"D2")
        store.save([a,b]); store.flush()
        let raw = (try? Data(contentsOf:file)) ?? Data()
        check(raw.range(of:Data("refresh token".utf8)) == nil,"note text is encrypted on disk")
        let perms = (try? FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? Int) ?? 0
        check(perms == 0o600,"notes file is owner-only")
        let back = NoteStore(file:file,key:testKey).load()
        check(back == [a,b],"notes round-trip with position, display and app")
        check(NoteStore(file:file,key:SymmetricKey(size:.bits256)).load().isEmpty,"wrong key reads nothing")
        check(a.title == "fix refresh token race" && b.title.hasSuffix("…") && b.title.count <= 23,"collapsed title is short")
        check(a.mode == .global && !a.pinned,"global and unpinned by default")
        try? FileManager.default.removeItem(at:file)
    }

    func testNoteVisibilityResolver() {
        let notes = (0..<30).map { SilkNote(text:"Thought \($0)",x:Double($0),display:"D1") }
        var appNote = SilkNote(text:"Code only",x:31,display:"D1")
        appNote.mode = .app; appNote.bundleID = "com.microsoft.VSCode"
        let other = SilkNote(text:"Other display",x:32,display:"D2")
        let all = notes+[appNote,other]
        let codeInput = NoteVisibility.Input(notes:all,display:"D1",activeBundle:"com.microsoft.VSCode",width:800)
        let inCode = NoteVisibility.resolve(codeInput)
        check(inCode.visible.count == 31,"all relevant notes stay visible without a count bundle")
        check(inCode.retracted.isEmpty,"matching app note stays visible")
        let inChrome = NoteVisibility.resolve(.init(notes:all,display:"D1",activeBundle:"com.google.Chrome",width:800))
        check(inChrome.visible.count == 30 && inChrome.retracted == [appNote.id],"only app-specific notes retract")
        check(!inChrome.visible.contains { $0.id == other.id },"other display ignored")
        check(NoteVisibility.resolve(codeInput) == inCode,"visibility is deterministic")
        var placed = notes[0]; placed.position = NotePosition(x:0.1,y:0.5)
        let result = NoteVisibility.resolve(.init(notes:[placed]+Array(notes.dropFirst()),display:"D1",activeBundle:nil,width:800))
        check(result.visible.count == 30 && result.visible.contains { $0.id == placed.id },"user-placed notes remain directly visible")
    }

    func testNoteDisplayFallbackAndPinPersistence() {
        var a = SilkNote(text:"a",x:0.3,display:"EXT"); a.pinned = true; a.mode = .app; a.bundleID = "com.apple.Terminal"; a.appName = "Terminal"
        let b = SilkNote(text:"b",x:0.6,display:"MAIN")
        let away = NoteVisibility.reassign([a,b],connected:["MAIN"],primary:"MAIN")
        check(away[0].display == "MAIN" && away[0].homeDisplay == "EXT" && away[0].x == 0.3,"orphan moves to primary, keeps position")
        let back = NoteVisibility.reassign(away,connected:["MAIN","EXT"],primary:"MAIN")
        check(back[0].display == "EXT" && back[0].homeDisplay == nil && back.count == 2,"returns home on reconnect, no duplicates")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("webber-notes-\(UUID().uuidString).enc")
        let store = NoteStore(file:file,key:testKey); store.save(away); store.flush()
        let loaded = NoteStore(file:file,key:testKey).load()
        check(loaded == away && loaded[0].pinned && loaded[0].mode == .app && loaded[0].bundleID == "com.apple.Terminal","pinned + app mode persist encrypted")
        try? FileManager.default.removeItem(at:file)
    }

    func testShortcutConflictDetection() {
        let cmdShiftSpace = Shortcut(keyCode:49,modifiers:UInt32(0x100|0x200))  // cmdKey | shiftKey
        let table: [String:Any] = ["34":["enabled":true,"value":["parameters":[32,49,0x120000]]],
                                   "60":["enabled":false,"value":["parameters":[32,49,0x40000]]]]
        check(cmdShiftSpace.conflicts(in:table),"enabled macOS shortcut on ⌘⇧Space is detected")
        let ctrlSpace = Shortcut(keyCode:49,modifiers:UInt32(0x1000))
        check(!ctrlSpace.conflicts(in:table),"disabled macOS shortcut is not a conflict")
        let fallbacks = ShortcutAction.clipboardHistory.fallbacks
        check(!fallbacks.isEmpty && fallbacks.allSatisfy { !$0.conflicts(in:table) && $0 != cmdShiftSpace },"clipboard history has free fallbacks")
    }

    func testSilkRailResolver() {
        let screen = CGSize(width:1800,height:1100)
        let rail = SilkRailResolver.resolve(.init(bounds:screen))
        check(rail.side == .top && rail.outward == CGPoint(x:0,y:-1),"top rail previews open downward")
        check(rail.start.y == screen.height-SilkRailResolver.topInset,"spiders hang below app toolbars")
        let toolbar = CGRect(x:0,y:screen.height-96,width:screen.width,height:96)
        for index in 0..<rail.capacity {
            let point = rail.point(index)
            let target = CGRect(x:point.x-13,y:point.y-13,width:26,height:26)
            check(!target.intersects(toolbar),"note click targets leave full-screen toolbar clear")
        }
        check(rail.direction == CGPoint(x:-1,y:0),"notes spread horizontally")
        check(rail.capacity >= 6,"top rail fits notes and overflow")
        for window in [CGRect(x:0,y:0,width:1800,height:1100),CGRect(x:200,y:200,width:900,height:700),CGRect(x:600,y:100,width:1200,height:900)] {
            check(SilkRailResolver.resolve(.init(bounds:screen,window:window)) == rail,"window movement cannot relocate notes")
            check(SilkRailResolver.resolve(.init(bounds:screen,window:window,fullscreen:true)) == rail,"full screen keeps notes at the top")
        }
        for size in [CGSize(width:800,height:600),CGSize(width:1440,height:900),CGSize(width:2560,height:1440)] {
            let row = SilkRailResolver.resolve(.init(bounds:size))
            let area = CGRect(origin:.zero,size:size)
            for index in 0..<row.capacity { check(area.contains(row.point(index)),"all top knots fit on screen") }
        }
    }

    func testImage() -> NSImage {
        let image = NSImage(size:NSSize(width:120,height:80))
        image.lockFocus(); NSColor.systemOrange.setFill(); NSRect(x:0,y:0,width:120,height:80).fill(); image.unlockFocus()
        return image
    }
}

@main
struct ClipboardWebCheckRunner {
    static func main() {
        _ = NSApplication.shared
        let suite = ClipboardWebChecks()
        suite.testKinds()
        suite.testCopyAgainRestoresExactText()
        suite.testDragOutPayloads()
        suite.testCapacityReleasesOldestUnpinned()
        suite.testWebGeometryExpandsAcrossDisplay()
        suite.testHangingItemSettles()
        suite.testDuplicateCopiesArePromotedNotDuplicated()
        suite.testHistorySurvivesRestart()
        suite.testLargeItemsStayOnDisk()
        suite.testNestSizeFitsDisplays()
        suite.testMigrationFromSingleIndex()
        suite.testMigrationFailureKeepsOldIndex()
        suite.testIncrementalSaveAndDeletion()
        suite.testHistoryLimit()
        suite.testNestSearch()
        suite.testSecretDetection()
        suite.testSecretsAreMaskedAndNeverSaved()
        suite.testScreenshotPreviewOptIn()
        suite.testSecretsInScreenshots()
        suite.testScreenshotSecretsNeverReachDisk()
        suite.testPasteStack()
        suite.testNoteRemindersAndChecklists()
        suite.testSignatureTransitionWindow()
        suite.testSearchAndTransforms()
        suite.testCorruptHistoryStartsEmptyWithoutCrashing()
        suite.testSensitiveClipboardIsNeverCaught()
        suite.testTransformsOnlyWhenUseful()
        suite.testSecretsAndEncryptionAtRest()
        suite.testSilkNotesStore()
        suite.testNoteVisibilityResolver()
        suite.testNoteDisplayFallbackAndPinPersistence()
        suite.testShortcutConflictDetection()
        suite.testSilkRailResolver()
        print("33 clipboard/web checks; \(suite.failures) failures")
        exit(suite.failures == 0 ? 0 : 1)
    }
}
