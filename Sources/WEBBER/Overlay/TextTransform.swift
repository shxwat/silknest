import Foundation

/// Quick text transforms for smart paste. A transform is only offered when it would actually do
/// something useful to this text: no menu entries that paste the same thing back.
struct TextTransform {
    let title: String
    let apply: (String) -> String
    /// Extra requirement beyond "the result differs".
    var accepts: (String) -> Bool = { _ in true }

    static let all: [TextTransform] = [
        // Changing case inside JSON would rename its keys, so case transforms skip JSON.
        TextTransform(title:"UPPERCASE",apply:{ $0.uppercased() },accepts:{ hasLetters($0) && jsonContainer($0) == nil }),
        TextTransform(title:"lowercase",apply:{ $0.lowercased() },accepts:{ hasLetters($0) && jsonContainer($0) == nil }),
        // Title Case on code, links or JSON only damages them.
        TextTransform(title:"Title Case",apply:{ $0.capitalized },accepts:{ hasLetters($0) && !looksStructured($0) }),
        TextTransform(title:"Trim",apply:{ $0.split(separator:"\n",omittingEmptySubsequences:false).map { $0.trimmingCharacters(in:.whitespaces) }.joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines) }),
        TextTransform(title:"One Line",apply:{ $0.split(whereSeparator:\.isNewline).map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }.joined(separator:" ") },
                      accepts:{ $0.contains(where:\.isNewline) }),
        TextTransform(title:"Pretty JSON",apply:prettyJSON,accepts:{ jsonContainer($0) != nil }),
        TextTransform(title:"URL Decode",apply:{ $0.removingPercentEncoding ?? $0 },
                      accepts:{ $0.range(of:"%[0-9A-Fa-f]{2}",options:.regularExpression) != nil && $0.removingPercentEncoding != nil })
    ]

    /// Only the transforms that change this text into something non-empty and meaningful.
    static func applicable(to text: String) -> [TextTransform] {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return [] }
        return all.filter { t in
            guard t.accepts(text) else { return false }
            let out = t.apply(text)
            return out != text && !out.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        }
    }

    private static func hasLetters(_ s: String) -> Bool { s.unicodeScalars.contains { CharacterSet.letters.contains($0) } }
    private static func looksStructured(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in:.whitespacesAndNewlines)
        return jsonContainer(t) != nil || t.hasPrefix("http://") || t.hasPrefix("https://") || t.contains("{") || t.contains(";") || t.contains("()") || t.contains("=>")
    }
    /// Parsed JSON, but only an object or array (a bare number or string is not worth prettifying).
    private static func jsonContainer(_ s: String) -> Any? {
        guard let data = s.trimmingCharacters(in:.whitespacesAndNewlines).data(using:.utf8),
              let object = try? JSONSerialization.jsonObject(with:data,options:[]),
              object is [Any] || object is [String:Any] else { return nil }
        return object
    }
    private static func prettyJSON(_ text: String) -> String {
        guard let object = jsonContainer(text),
              let pretty = try? JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]),
              let out = String(data:pretty,encoding:.utf8) else { return text }
        return out
    }
}
