import AppKit

/// A small transparent native drag destination follows the spider; the screen-sized renderer is always click-through.
final class SpiderDropView: NSView {
    var onHover: ((NSPoint?) -> Void)?
    var onCatch: ((NSPoint) -> Bool)?
    /// A real drop onto the spider; receives the dragging pasteboard to read like a catch.
    var onDrop: ((NSPoint,NSPasteboard) -> Bool)?
    var accepting = true
    var canCatchAt: ((NSPoint)->Bool)?
    /// Click count: 1 opens the silk menu, 2 opens the Nest.
    var onClick: ((Int) -> Void)?
    override var isOpaque: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .string, .URL, .tiff, .png])
    }
    required init?(coder: NSCoder) { fatalError() }
    private func supported(_ sender: NSDraggingInfo) -> Bool {
        accepting && sender.draggingPasteboard.availableType(from: [.fileURL, .string, .URL, .tiff, .png]) != nil
    }
    private func location(_ sender: NSDraggingInfo) -> NSPoint {
        window?.convertPoint(toScreen: sender.draggingLocation) ?? .zero
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard supported(sender) else { return [] }
        let p = location(sender)
        onHover?(p)
        return (canCatchAt?(p) ?? true) ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onHover?(nil) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { supported(sender) && (canCatchAt?(location(sender)) ?? true) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard supported(sender), canCatchAt?(location(sender)) ?? true else { return false }
        if let onDrop { return onDrop(location(sender),sender.draggingPasteboard) }
        return onCatch?(location(sender)) ?? false
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { onHover?(nil) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Press-and-drag picks the spider up; a click without movement opens its menu (two clicks: the Nest).
    var onGrab: (() -> Void)?
    var onCarry: (() -> Void)?
    var onPutDown: (() -> Void)?
    private(set) var isPressed = false
    private var downPoint = NSPoint.zero
    private var carrying = false
    override func mouseDown(with event: NSEvent) {
        isPressed = true; carrying = false; downPoint = NSEvent.mouseLocation
    }
    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        if !carrying {
            guard hypot(p.x-downPoint.x,p.y-downPoint.y) > 4 else { return }
            carrying = true; onGrab?()
        }
        onCarry?()
    }
    override func mouseUp(with event: NSEvent) {
        if carrying { onPutDown?() } else { onClick?(event.clickCount) }
        isPressed = false; carrying = false
    }
}
