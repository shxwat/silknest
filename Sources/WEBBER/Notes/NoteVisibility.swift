import CoreGraphics
import Foundation

/// Every relevant note remains visible. App-specific notes retract when their app is inactive.
/// Capacity never hides notes behind a counter or bundle.
enum NoteVisibility {
    struct Input {
        var notes: [SilkNote]
        var display: String
        var activeBundle: String?
        var width: CGFloat
    }

    struct Result: Equatable {
        var visible: [(id: UUID, x: CGFloat)]
        var retracted: [UUID]

        static func == (a: Result, b: Result) -> Bool {
            a.visible.map(\.id) == b.visible.map(\.id) && zip(a.visible,b.visible).allSatisfy { abs($0.x-$1.x) < 0.5 }
                && a.retracted == b.retracted
        }
    }

    static func isRelevant(_ note: SilkNote, activeBundle: String?) -> Bool {
        note.mode == .global || (note.bundleID != nil && note.bundleID == activeBundle)
    }

    static func priority(_ a: SilkNote, _ b: SilkNote, activeBundle: String?) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        let aApp = a.mode == .app && a.bundleID == activeBundle, bApp = b.mode == .app && b.bundleID == activeBundle
        if aApp != bApp { return aApp }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    static func resolve(_ input: Input) -> Result {
        let mine = input.notes.filter { $0.display == input.display }
        let retracted = mine.filter { !isRelevant($0,activeBundle:input.activeBundle) }.map(\.id)
        let relevant = mine.filter { isRelevant($0,activeBundle:input.activeBundle) }
            .sorted { priority($0,$1,activeBundle:input.activeBundle) }
        return Result(visible:relevant.map { ($0.id,CGFloat($0.position?.x ?? $0.x)*input.width) },retracted:retracted)
    }

    /// Display fallback: orphaned notes go to the primary display, returning notes go home.
    static func reassign(_ notes: [SilkNote], connected: Set<String>, primary: String) -> [SilkNote] {
        notes.map { n in
            var n = n
            if let home = n.homeDisplay, connected.contains(home) { n.display = home; n.homeDisplay = nil }
            else if !connected.contains(n.display) { n.homeDisplay = n.homeDisplay ?? n.display; n.display = primary }
            return n
        }
    }

}
