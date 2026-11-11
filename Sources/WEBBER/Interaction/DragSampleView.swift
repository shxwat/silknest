import AppKit

/// A real native drag source for rehearsing interaction without leaving the study.
final class DragSampleView: NSView, NSDraggingSource {
    private var dragging = false
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.controlBackgroundColor.setFill()
        let path = NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:5,yRadius:5)
        path.fill(); NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
        ("Drag sample ↗" as NSString).draw(at:NSPoint(x:10,y:5),withAttributes:[.font:NSFont.systemFont(ofSize:11,weight:.medium),.foregroundColor:NSColor.labelColor])
    }
    override func mouseDown(with event:NSEvent) { dragging = false }
    override func mouseDragged(with event:NSEvent) {
        guard !dragging else { return }; dragging = true
        let item = NSPasteboardItem(); item.setString("WEBBER spider motion study",forType:.string)
        let drag = NSDraggingItem(pasteboardWriter:item)
        let image = NSImage(size:bounds.size)
        image.lockFocus(); draw(bounds); image.unlockFocus()
        drag.setDraggingFrame(bounds,contents:image)
        beginDraggingSession(with:[drag],event:event,source:self)
    }
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session:NSDraggingSession,endedAt screenPoint:NSPoint,operation:NSDragOperation) { dragging = false }
}
