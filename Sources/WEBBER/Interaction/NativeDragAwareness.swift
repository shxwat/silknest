import AppKit

/// Read only the native drag pasteboard's type/change metadata, never the clipboard or item contents.
final class NativeDragAwareness {
    private let board = NSPasteboard(name:.drag)
    private var baseline: Int?
    private var active = false
    /// Cheap when idle: the drag pasteboard (an IPC round-trip) is only consulted while the button is down.
    func update() -> Bool {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { baseline = nil; active = false; return false }
        let count = board.changeCount
        guard let start = baseline else { baseline = count; return false }
        if count != start { active = board.availableType(from:[.fileURL,.string,.URL,.png,.tiff]) != nil }
        return active
    }
}
