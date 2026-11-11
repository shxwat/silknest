import Foundation

/// Reminders read from a note's own text, entirely on this Mac (no network): "3pm", "tomorrow 10am",
/// "at 17:30", "in 20 min", "in 2 hours". Checklists: lines starting with "[ ]" or "[x]".
enum NoteReminder {
    private static let relative = try! NSRegularExpression(pattern:#"(?i)\bin\s+(\d{1,3})\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours)\b"#)

    /// The first future moment mentioned in the text, or nil.
    static func date(in text: String, now: Date = Date()) -> Date? {
        let ns = NSRange(text.startIndex...,in:text)
        if let m = relative.firstMatch(in:text,range:ns), let n = Range(m.range(at:1),in:text), let u = Range(m.range(at:2),in:text),
           let amount = Double(text[n]) {
            let unit = text[u].lowercased()
            return now.addingTimeInterval(amount*(unit.hasPrefix("h") ? 3600 : 60))
        }
        guard let detector = try? NSDataDetector(types:NSTextCheckingResult.CheckingType.date.rawValue),
              var found = detector.matches(in:text,range:ns).compactMap(\.date).first else { return nil }
        // The detector reads "3pm" and "tomorrow" against the real clock; move it onto `now`'s day
        // (no change in the app, where `now` is the real time).
        let cal = Calendar.current
        let days = cal.dateComponents([.day],from:cal.startOfDay(for:Date()),to:cal.startOfDay(for:now)).day ?? 0
        if days != 0, let moved = cal.date(byAdding:.day,value:days,to:found) { found = moved }
        // A time of day that has already passed today ("3pm" at 4pm) means tomorrow.
        if found < now, now.timeIntervalSince(found) < 24*3600 { return found.addingTimeInterval(24*3600) }
        return found > now ? found : nil
    }

    /// "[ ] milk" / "[x] milk" → (checked, rest); nil for an ordinary line.
    static func checkbox(_ line: Substring) -> (checked: Bool, rest: Substring)? {
        let t = line.drop { $0 == " " }
        if t.hasPrefix("[ ]") { return (false,t.dropFirst(3)) }
        if t.lowercased().hasPrefix("[x]") { return (true,t.dropFirst(3)) }
        return nil
    }

    /// The text with the checkbox on line `index` ticked or cleared.
    static func toggle(_ text: String, line index: Int) -> String {
        var lines = text.components(separatedBy:"\n")
        guard lines.indices.contains(index), let box = checkbox(Substring(lines[index])) else { return text }
        let indent = lines[index].prefix { $0 == " " }
        lines[index] = indent+(box.checked ? "[ ]" : "[x]")+box.rest
        return lines.joined(separator:"\n")
    }
}
