import Foundation

/// The Paste Stack: items queued in order; while it holds anything, each ⌘V pastes the next one.
/// Empty again, ⌘V is the user's normal paste.
struct PasteStack {
    private(set) var items: [ClipboardItem] = []
    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    mutating func add(_ item: ClipboardItem) { items.append(item) }
    /// The next item to paste, taken off the stack.
    mutating func next() -> ClipboardItem? { items.isEmpty ? nil : items.removeFirst() }
    mutating func clear() { items.removeAll() }
    /// An item removed from the history leaves the stack too.
    mutating func remove(id: Int) { items.removeAll { $0.id == id } }
}
