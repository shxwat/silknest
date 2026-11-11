import AppKit
import CoreImage

/// Draws each caught item as a small physical object: a paper fragment, a code chip, a domain tag,
/// a real thumbnail, or a file icon. Lightly bound with silk so it reads as caught, not as a card.
enum ItemPreview {
    static let pixelScale: CGFloat = 2

    static func render(kind: ClipboardKind, text: String?, url: URL?, fileURLs: [URL], image: NSImage?) -> NSImage {
        switch kind {
        case .text: return note(text ?? "")
        case .code: return code(text ?? "")
        case .url: return link(url)
        case .image: return thumbnail(image)
        case .file: return file(fileURLs)
        }
    }

    static func caption(kind: ClipboardKind, text: String?, url: URL?, fileURLs: [URL], image: NSImage?) -> String {
        switch kind {
        case .text: return "\(text?.count ?? 0) characters"
        case .code:
            let lines = text?.split(separator:"\n").count ?? 0
            return lines == 1 ? "code" : "code · \(lines) lines"
        case .url: return url?.host ?? "link"
        case .image:
            let size = image?.representations.first.map { NSSize(width:$0.pixelsWide,height:$0.pixelsHigh) } ?? .zero
            return "image · \(Int(size.width))×\(Int(size.height))"
        case .file:
            let name = fileURLs.first?.lastPathComponent ?? "file"
            return fileURLs.count > 1 ? "\(name) +\(fileURLs.count-1)" : name
        }
    }

    // MARK: kinds

    private static func note(_ text: String) -> NSImage {
        let size = NSSize(width:66,height:42)
        return draw(size) { rect in
            let body = rect.insetBy(dx:4,dy:4)
            let paper = NSBezierPath()
            // Slightly torn lower edge.
            paper.move(to:NSPoint(x:body.minX,y:body.maxY))
            paper.line(to:NSPoint(x:body.maxX,y:body.maxY))
            paper.line(to:NSPoint(x:body.maxX,y:body.minY+1.5))
            for i in stride(from:CGFloat(0),through:12,by:1) {
                let x = body.maxX-body.width*i/12
                paper.line(to:NSPoint(x:x,y:body.minY+(Int(i)%2==0 ? 0 : 1.6)))
            }
            paper.close()
            shadowed { NSColor(srgbRed:0.96,green:0.95,blue:0.91,alpha:1).setFill(); paper.fill() }
            let words = fragment(text,limit:46)
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping; style.lineSpacing = -0.5
            (words as NSString).draw(with:body.insetBy(dx:4,dy:3.5),options:[.usesLineFragmentOrigin,.truncatesLastVisibleLine],attributes:[
                .font:NSFont.systemFont(ofSize:6.6,weight:.medium),.foregroundColor:NSColor(srgbRed:0.17,green:0.16,blue:0.14,alpha:0.92),.paragraphStyle:style])
            silkBinding(body)
        }
    }

    private static func code(_ text: String) -> NSImage {
        let size = NSSize(width:70,height:42)
        return draw(size) { rect in
            let body = rect.insetBy(dx:4,dy:4)
            let chip = NSBezierPath(roundedRect:body,xRadius:3,yRadius:3)
            shadowed { NSColor(srgbRed:0.09,green:0.11,blue:0.12,alpha:1).setFill(); chip.fill() }
            let lines = text.split(separator:"\n",omittingEmptySubsequences:true).prefix(3).map { line -> String in
                let trimmed = String(line).replacingOccurrences(of:"\t",with:"  ")
                return trimmed.count > 22 ? String(trimmed.prefix(21))+"…" : trimmed
            }
            let font = NSFont.monospacedSystemFont(ofSize:5.6,weight:.regular)
            for (i,line) in lines.enumerated() {
                let color = i==0 ? NSColor(srgbRed:0.55,green:0.86,blue:0.72,alpha:1) : NSColor(srgbRed:0.78,green:0.80,blue:0.80,alpha:0.92)
                (line as NSString).draw(at:NSPoint(x:body.minX+4,y:body.maxY-10-CGFloat(i)*8),withAttributes:[.font:font,.foregroundColor:color])
            }
            silkBinding(body)
        }
    }

    private static func link(_ url: URL?) -> NSImage {
        let host = (url?.host ?? "link").replacingOccurrences(of:"www.",with:"")
        let font = NSFont.systemFont(ofSize:7.4,weight:.semibold)
        let textWidth = min(76,(host as NSString).size(withAttributes:[.font:font]).width)
        let size = NSSize(width:textWidth+30,height:24)
        return draw(size) { rect in
            let body = rect.insetBy(dx:4,dy:4)
            let tag = NSBezierPath(roundedRect:body,xRadius:body.height/2,yRadius:body.height/2)
            shadowed { NSColor(srgbRed:0.93,green:0.94,blue:0.95,alpha:1).setFill(); tag.fill() }
            let glyph = NSRect(x:body.minX+3.5,y:body.midY-5,width:10,height:10)
            NSColor(srgbRed:0.25,green:0.45,blue:0.62,alpha:1).setFill(); NSBezierPath(ovalIn:glyph).fill()
            if let globe = NSImage(systemSymbolName:"globe",accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:7,weight:.semibold)) {
                let tinted = globe.copy() as! NSImage
                tinted.lockFocus(); NSColor.white.set(); NSRect(origin:.zero,size:tinted.size).fill(using:.sourceAtop); tinted.unlockFocus()
                tinted.draw(in:glyph.insetBy(dx:1.6,dy:1.6))
            }
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            (host as NSString).draw(in:NSRect(x:glyph.maxX+3,y:body.midY-5,width:textWidth+2,height:10),withAttributes:[.font:font,.foregroundColor:NSColor(srgbRed:0.13,green:0.15,blue:0.17,alpha:1),.paragraphStyle:style])
            silkBinding(body,strands:1)
        }
    }

    private static func thumbnail(_ image: NSImage?) -> NSImage {
        let source = image?.size ?? NSSize(width:4,height:3)
        let fit = min(60/max(1,source.width),46/max(1,source.height))
        let inner = NSSize(width:max(18,source.width*fit),height:max(18,source.height*fit))
        let size = NSSize(width:inner.width+10,height:inner.height+10)
        return draw(size) { rect in
            let photo = rect.insetBy(dx:5,dy:5)
            shadowed { NSColor.white.setFill(); NSBezierPath(rect:photo.insetBy(dx:-1.2,dy:-1.2)).fill() }
            image?.draw(in:photo,from:.zero,operation:.sourceOver,fraction:1)
            silkBinding(photo)
        }
    }

    private static func file(_ urls: [URL]) -> NSImage {
        let size = NSSize(width:58,height:50)
        let name = urls.first?.lastPathComponent ?? "file"
        let icon = urls.first.map { NSWorkspace.shared.icon(forFile:$0.path) } ?? NSWorkspace.shared.icon(for:.data)
        return draw(size) { rect in
            let iconRect = NSRect(x:rect.midX-15,y:rect.maxY-33,width:30,height:30)
            shadowed { icon.draw(in:iconRect) }
            if urls.count > 1 {
                let badge = NSRect(x:iconRect.maxX-8,y:iconRect.maxY-9,width:10,height:10)
                NSColor(srgbRed:0.27,green:0.29,blue:0.31,alpha:1).setFill(); NSBezierPath(ovalIn:badge).fill()
                ("\(urls.count)" as NSString).draw(in:badge.offsetBy(dx:0,dy:-1),withAttributes:[.font:NSFont.systemFont(ofSize:6,weight:.bold),.foregroundColor:NSColor.white,.paragraphStyle:centered()])
            }
            let style = centered(); style.lineBreakMode = .byTruncatingMiddle
            let label = NSRect(x:rect.minX+2,y:rect.minY+3,width:rect.width-4,height:11)
            NSColor(srgbRed:0.07,green:0.08,blue:0.09,alpha:0.62).setFill()
            let labelWidth = min(label.width,(name as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:6.4,weight:.medium)]).width+8)
            NSBezierPath(roundedRect:NSRect(x:rect.midX-labelWidth/2,y:label.minY,width:labelWidth,height:label.height),xRadius:5.5,yRadius:5.5).fill()
            (name as NSString).draw(in:label.offsetBy(dx:0,dy:-1.2),withAttributes:[.font:NSFont.systemFont(ofSize:6.4,weight:.medium),.foregroundColor:NSColor(white:0.96,alpha:1),.paragraphStyle:style])
            silkBinding(iconRect.insetBy(dx:3,dy:2),strands:1)
        }
    }

    // MARK: drawing

    static func draw(_ size: NSSize, _ body: (NSRect) -> Void) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(size.width*pixelScale),pixelsHigh:Int(size.height*pixelScale),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        body(NSRect(origin:.zero,size:size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size:size); image.addRepresentation(rep); return image
    }

    private static func shadowed(_ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 2.4; shadow.shadowOffset = NSSize(width:0,height:-1)
        shadow.shadowColor = NSColor(white:0,alpha:0.34); shadow.set()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Two or three fine translucent strands crossing the object, as if it had been wrapped.
    private static func silkBinding(_ rect: NSRect, strands: Int = 2) {
        // Strands wrap across the corners only, so the content is never struck through.
        let silk = NSColor(srgbRed:0.97,green:0.97,blue:0.95,alpha:0.42)
        let corners: [(NSPoint,NSPoint)] = [
            (NSPoint(x:rect.minX-1.5,y:rect.minY+rect.height*0.32),NSPoint(x:rect.minX+rect.width*0.24,y:rect.minY-1.5)),
            (NSPoint(x:rect.maxX-rect.width*0.2,y:rect.maxY+1.5),NSPoint(x:rect.maxX+1.5,y:rect.maxY-rect.height*0.36))
        ]
        for (a,b) in corners.prefix(strands) {
            let path = NSBezierPath(); path.lineWidth = 0.4
            path.move(to:a); path.curve(to:b,controlPoint1:NSPoint(x:(a.x+b.x)/2+1,y:(a.y+b.y)/2+1),controlPoint2:NSPoint(x:(a.x+b.x)/2+1,y:(a.y+b.y)/2+1))
            silk.setStroke(); path.stroke()
            let second = path.copy() as! NSBezierPath
            second.transform(using:AffineTransform(translationByX:1.4,byY:1.1)); second.stroke()
        }
    }

    private static func centered() -> NSMutableParagraphStyle { let s = NSMutableParagraphStyle(); s.alignment = .center; return s }

    static func fragment(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator:\.isNewline).joined(separator:" ").trimmingCharacters(in:.whitespaces)
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        return (cut.lastIndex(of:" ").map { String(cut[..<$0]) } ?? String(cut))+"…"
    }

    /// A small JPEG of an image (longest side 240 px) for the object hanging in the web: drawn without
    /// keeping a full screenshot decoded in memory.
    static func thumbnailJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData,nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:240,
                                        kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceShouldCacheImmediately:false]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage:cg).representation(using:.jpeg,properties:[.compressionFactor:0.82])
    }

    /// A blurred copy (CoreImage): heavy for images that contain a secret, lighter while one is being checked.
    static func blurred(_ image: NSImage, strength: Double = 1) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return nil }
        let input = CIImage(cgImage:cg)
        let radius = max(12*strength,Double(max(cg.width,cg.height))/40*strength)
        guard let filter = CIFilter(name:"CIGaussianBlur",parameters:[kCIInputImageKey:input.clampedToExtent(),kCIInputRadiusKey:radius]),
              let output = filter.outputImage?.cropped(to:input.extent),
              let result = CIContext(options:[.useSoftwareRenderer:false]).createCGImage(output,from:input.extent) else { return nil }
        return NSImage(cgImage:result,size:image.size)
    }

    /// A new image whose text is still being checked: drawn softly blurred, so nothing is legible.
    static func pendingImage(_ thumbnail: NSImage?) -> NSImage {
        render(kind:.image,text:nil,url:nil,fileURLs:[],image:thumbnail.flatMap { blurred($0,strength:0.55) } ?? thumbnail)
    }

    /// The hanging object for an image with a secret in it: the thumbnail blurred, with a small label.
    static func secretImage(_ thumbnail: NSImage?) -> NSImage {
        let base = thumbnail.flatMap { blurred($0) } ?? thumbnail
        let inner = render(kind:.image,text:nil,url:nil,fileURLs:[],image:base)
        return draw(inner.size) { rect in
            inner.draw(in:rect)
            let label = NSAttributedString(string:"contains a secret",attributes:[.font:NSFont.systemFont(ofSize:6.5,weight:.semibold),.foregroundColor:NSColor.white])
            let size = label.size()
            let pill = NSRect(x:rect.midX-size.width/2-4,y:rect.midY-size.height/2-1.5,width:size.width+8,height:size.height+3)
            NSColor(white:0,alpha:0.62).setFill(); NSBezierPath(roundedRect:pill,xRadius:pill.height/2,yRadius:pill.height/2).fill()
            label.draw(at:NSPoint(x:pill.minX+4,y:pill.minY+1.5))
        }
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff) else { return nil }
        return rep.representation(using:.png,properties:[:])
    }

    /// The object after wrapping: an oval silk cocoon with the contents faintly visible through it.
    static func cocoon(_ preview: NSImage) -> NSImage {
        draw(NSSize(width:30,height:38)) { rect in
            let body = NSRect(x:rect.midX-11,y:rect.midY-15.5,width:22,height:31)
            let oval = NSBezierPath(ovalIn:body)
            shadowed { NSColor(srgbRed:0.86,green:0.86,blue:0.82,alpha:1).setFill(); oval.fill() }
            NSGraphicsContext.saveGraphicsState(); oval.addClip()
            let fit = max(body.width/max(1,preview.size.width),body.height/max(1,preview.size.height))
            let size = NSSize(width:preview.size.width*fit,height:preview.size.height*fit)
            preview.draw(in:NSRect(x:body.midX-size.width/2,y:body.midY-size.height/2,width:size.width,height:size.height),from:.zero,operation:.sourceOver,fraction:0.55)
            NSColor(srgbRed:0.95,green:0.95,blue:0.92,alpha:0.38).setFill(); body.fill(using:.sourceOver)
            let wraps = NSBezierPath(); wraps.lineWidth = 0.5
            for k in 0..<9 {
                let y = body.minY+CGFloat(k)*3.6
                wraps.move(to:NSPoint(x:body.minX,y:y)); wraps.line(to:NSPoint(x:body.maxX,y:y+5))
            }
            NSColor(white:1,alpha:0.62).setStroke(); wraps.stroke()
            NSGraphicsContext.restoreGraphicsState()
            NSColor(white:1,alpha:0.5).setStroke(); oval.lineWidth = 0.5; oval.stroke()
        }
    }

    /// Small hover label hung beneath an object in the opened web.
    static func label(_ text: String) -> NSImage {
        let font = NSFont.systemFont(ofSize:7.5,weight:.medium)
        let width = min(150,(text as NSString).size(withAttributes:[.font:font]).width+12)
        return draw(NSSize(width:width,height:14)) { rect in
            NSColor(srgbRed:0.06,green:0.07,blue:0.08,alpha:0.62).setFill()
            NSBezierPath(roundedRect:rect.insetBy(dx:0.5,dy:1),xRadius:6,yRadius:6).fill()
            let style = centered(); style.lineBreakMode = .byTruncatingMiddle
            (text as NSString).draw(in:rect.insetBy(dx:5,dy:2.4).offsetBy(dx:0,dy:-0.4),withAttributes:[.font:font,.foregroundColor:NSColor(white:0.95,alpha:1),.paragraphStyle:style])
        }
    }
}
