import Foundation

/// Recognises secrets in copied text: API keys and tokens, JWTs, private keys, one-time codes and card
/// numbers. Only shapes that are very unlikely to be ordinary text or code are matched: known token prefixes
/// with a long random body, a full JWT, a PEM private-key block, a card number that passes the Luhn check
/// with a known card prefix, and a short code that arrived from a messaging app or says it is a code.
enum SecretDetector {
    enum Kind: String { case apiKey = "API key", token = "Token", jwt = "JWT", privateKey = "Private key", otp = "One-time code", card = "Card number" }

    struct Finding { let kind: Kind; let ranges: [Range<String.Index>] }

    private static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern:p) }

    /// Prefixed keys: (pattern, kind). Bodies must be long and random-looking, so "sk-learn" or "hf_hub"
    /// in a sentence never match.
    private static let prefixed: [(NSRegularExpression, Kind)] = [
        (regex(#"(?<![A-Za-z0-9_-])sk-ant-[A-Za-z0-9_-]{24,}"#),.apiKey),
        (regex(#"(?<![A-Za-z0-9_-])sk-(?:proj-|live_|test_)?[A-Za-z0-9_-]{24,}"#),.apiKey),
        (regex(#"(?<![A-Za-z0-9_])r8_[A-Za-z0-9]{30,}"#),.apiKey),
        (regex(#"(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{36,}"#),.token),
        (regex(#"(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{50,}"#),.token),
        (regex(#"(?<![A-Za-z0-9-])xox[abposr]-[A-Za-z0-9-]{10,}"#),.token),
        (regex(#"(?<![A-Z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Z0-9])"#),.apiKey),
        (regex(#"(?<![A-Za-z0-9_-])AIza[0-9A-Za-z_-]{35}"#),.apiKey),
        (regex(#"(?<![A-Za-z0-9_-])glpat-[0-9A-Za-z_-]{20,}"#),.token),
        (regex(#"(?<![A-Za-z0-9_])hf_[A-Za-z0-9]{30,}"#),.token),
    ]
    private static let jwt = regex(#"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#)
    /// The whole block, header to footer (or to the end of the copy when the footer is missing).
    private static let privateKey = regex(#"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----[\s\S]*?(?:-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----|\z)"#)
    private static let card = regex(#"(?<![0-9])(?:[0-9][ -]?){12,18}[0-9](?![0-9])"#)
    private static let codeOnly = regex(#"^\s*(?:[0-9]{6,8}|[0-9]{3}[ -][0-9]{3})\s*$"#)
    private static let codeInMessage = regex(#"(?<![0-9])[0-9]{4,8}(?![0-9])"#)
    private static let codeWords = regex(#"(?i)\b(otp|one[- ]time|verification code|security code|passcode|login code|sign[- ]in code|2fa|auth(?:entication)? code|confirmation code)\b"#)

    /// Apps whose short numeric copies are almost always one-time codes.
    static let codeSources: Set<String> = ["com.apple.MobileSMS","com.apple.mail","net.whatsapp.WhatsApp","desktop.WhatsApp","ru.keepcoder.Telegram",
                                           "com.google.Authenticator","com.authy.authy-mac","com.apple.Passwords","org.whispersystems.signal-desktop"]

    static func detect(_ text: String, source: String? = nil) -> Finding? {
        guard !text.isEmpty, text.utf8.count <= 100_000 else { return nil }
        let ns = NSRange(text.startIndex...,in:text)
        func ranges(_ r: NSRegularExpression) -> [Range<String.Index>] { r.matches(in:text,range:ns).compactMap { Range($0.range,in:text) } }

        if let m = privateKey.firstMatch(in:text,range:ns), let r = Range(m.range,in:text) { return Finding(kind:.privateKey,ranges:[r]) }
        for (pattern,kind) in prefixed { let found = ranges(pattern); if !found.isEmpty { return Finding(kind:kind,ranges:found) } }
        let jwts = ranges(jwt); if !jwts.isEmpty { return Finding(kind:.jwt,ranges:jwts) }
        let cards = ranges(card).filter { isCardNumber(String(text[$0])) }
        if !cards.isEmpty { return Finding(kind:.card,ranges:cards) }
        if text.count <= 300 {
            if let m = codeOnly.firstMatch(in:text,range:ns), let r = Range(m.range,in:text), let source, codeSources.contains(source) {
                return Finding(kind:.otp,ranges:[r])
            }
            if codeWords.firstMatch(in:text,range:ns) != nil {
                let codes = ranges(codeInMessage); if !codes.isEmpty { return Finding(kind:.otp,ranges:codes) }
            }
        }
        return nil
    }

    /// A card number: 13–19 digits, a known card prefix, and a valid Luhn check digit.
    static func isCardNumber(_ s: String) -> Bool {
        let digits = s.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        let prefix2 = digits[0]*10+digits[1], prefix4 = digits.prefix(4).reduce(0) { $0*10+$1 }
        let knownPrefix = digits[0] == 4 || (51...55).contains(prefix2) || (2221...2720).contains(prefix4) || prefix2 == 34 || prefix2 == 37
            || prefix4 == 6011 || prefix2 == 65 || prefix2 == 60 || prefix2 == 81 || prefix2 == 82 || prefix2 == 35 || prefix2 == 36
        guard knownPrefix, Set(digits).count >= 2 else { return false }
        var sum = 0
        for (i,d) in digits.reversed().enumerated() { sum += i % 2 == 1 ? (d*2 > 9 ? d*2-9 : d*2) : d }
        return sum % 10 == 0
    }

    /// The text with every secret masked: a recognisable start, bullets, and the last characters
    /// ("r8_••••••••Oz4", "•••• •••• •••• 4242", "••••••").
    static func masked(_ text: String, _ finding: Finding) -> String {
        var out = "", cursor = text.startIndex
        for r in finding.ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where r.lowerBound >= cursor {
            out += text[cursor..<r.lowerBound]; out += mask(String(text[r]),finding.kind); cursor = r.upperBound
        }
        return out+text[cursor...]
    }

    static func mask(_ secret: String, _ kind: Kind) -> String {
        switch kind {
        case .privateKey: return (secret.components(separatedBy:"\n").first ?? "-----BEGIN PRIVATE KEY-----")+" ••••••••"
        case .otp: return String(repeating:"•",count:min(8,secret.filter(\.isNumber).count))
        case .card: return "•••• •••• •••• "+String(secret.filter(\.isNumber).suffix(4))
        case .jwt: return "eyJ••••••••"+String(secret.suffix(3))
        case .apiKey, .token:
            let prefixes = ["sk-ant-","sk-proj-","sk-live_","sk-test_","sk-","r8_","ghp_","gho_","ghu_","ghs_","ghr_","github_pat_","xoxb-","xoxp-","xoxa-","xoxo-","xoxs-","xoxr-","AKIA","ASIA","AIza","glpat-","hf_"]
            let start = prefixes.first { secret.hasPrefix($0) } ?? String(secret.prefix(3))
            return start+"••••••••"+String(secret.suffix(3))
        }
    }
}
