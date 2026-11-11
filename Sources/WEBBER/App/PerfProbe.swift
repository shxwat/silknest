#if DEBUG
import AppKit
import Darwin

/// Development-only measurements for scripts/perf.sh (built with -DDEBUG, run with --automation).
/// Reports timings and the app's memory footprint; never any clipboard content.
enum PerfProbe {
    /// Physical memory footprint (what Activity Monitor shows as "Memory"), in MB.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to:&info) {
            $0.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint)/1_048_576 : -1
    }

    /// Synthetic history for performance runs: text, code, links and large screenshot-sized images.
    /// Deterministic, so before/after runs measure the same data.
    static func syntheticItems(total: Int, big: Int, firstID: Int) -> [ClipboardItem] {
        var rng = SplitMix(seed:42)
        let words = ["silk","nest","spider","invoice","deploy","fatal","error","budget","meeting","design","render","token","server","client",
                     "screen","report","kernel","window","thread","paste","search","orbit","cobalt","amber","harbor","signal","vector","canvas"]
        func sentence(_ n: Int) -> String { (0..<n).map { _ in words[Int(rng.next()%UInt64(words.count))] }.joined(separator:" ") }
        var items: [ClipboardItem] = []
        let bigEvery = big > 0 ? max(1,total/big) : Int.max
        var bigLeft = big
        for i in 0..<total {
            let id = firstID+i
            let item: ClipboardItem
            if bigLeft > 0 && i % bigEvery == 0 {
                bigLeft -= 1
                let png = screenshotPNG(&rng)
                let image = NSImage(data:png)
                item = ClipboardItem(id:id,kind:.image,representations:[(.png,png)],text:nil,url:nil,fileURLs:[],image:image)
                item.recognizedText = "Screenshot "+sentence(40)
                item.thumbnail = ItemPreview.thumbnailJPEG(from:png)   // as a real catch makes it
                item.sourceName = "Screenshot"
            } else {
                switch i % 4 {
                case 0:
                    let t = sentence(8+Int(rng.next()%60))
                    item = ClipboardItem(id:id,kind:.text,representations:[(.string,Data(t.utf8))],text:t,url:nil,fileURLs:[],image:nil)
                    item.sourceName = "Notes"
                case 1:
                    let t = "func \(words[i%words.count])\(i)() {\n    let x = \(i)\n    print(x)\n}"
                    item = ClipboardItem(id:id,kind:.code,representations:[(.string,Data(t.utf8))],text:t,url:nil,fileURLs:[],image:nil)
                    item.sourceName = "Xcode"
                case 2:
                    let t = "https://\(words[i%words.count]).example.com/\(words[(i*7)%words.count])/\(i)"
                    item = ClipboardItem(id:id,kind:.url,representations:[(.string,Data(t.utf8)),(.URL,Data(t.utf8))],text:t,url:URL(string:t),fileURLs:[],image:nil)
                    item.sourceName = "Safari"
                default:
                    let t = sentence(200+Int(rng.next()%400))
                    item = ClipboardItem(id:id,kind:.text,representations:[(.string,Data(t.utf8))],text:t,url:nil,fileURLs:[],image:nil)
                    item.sourceName = "Mail"
                }
            }
            items.append(item)
        }
        return items
    }

    /// A 2560×1600 PNG with flat panels, text-like stripes and some noise: about the size of a real screenshot.
    private static func screenshotPNG(_ rng: inout SplitMix) -> Data {
        let w = 2560, h = 1600
        guard let ctx = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        ctx.setFillColor(CGColor(red:0.95,green:0.95,blue:0.96,alpha:1)); ctx.fill(CGRect(x:0,y:0,width:w,height:h))
        for _ in 0..<60 {
            let c = CGColor(red:CGFloat(rng.next()%255)/255,green:CGFloat(rng.next()%255)/255,blue:CGFloat(rng.next()%255)/255,alpha:1)
            ctx.setFillColor(c)
            ctx.fill(CGRect(x:Int(rng.next()%UInt64(w)),y:Int(rng.next()%UInt64(h)),width:40+Int(rng.next()%600),height:10+Int(rng.next()%300)))
        }
        if let data = ctx.data {
            let bytes = data.bindMemory(to:UInt8.self,capacity:ctx.bytesPerRow*h)
            for row in stride(from:0,to:h,by:3) where rng.next()%4 == 0 {
                for x in 0..<(w/3) { bytes[row*ctx.bytesPerRow+x*4] = UInt8(truncatingIfNeeded:rng.next()) }
            }
        }
        guard let cg = ctx.makeImage() else { return Data() }
        return NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) ?? Data()
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
#endif
