import Foundation

/// The first launch signed with the SilkNest certificate after ad-hoc builds (1.2.2 → 1.3.0): macOS sees a
/// new app and drops the Accessibility grant, so SilkNest explains it once. Later certificate builds keep the
/// grant and never show it again.
enum SignatureTransition {
    /// - previous: the signing kind recorded by the last launch ("adhoc", "certificate", or nil before 1.3.0)
    /// - current: this launch's kind
    static func shouldExplain(previous: String?, current: String, existingUser: Bool, alreadyExplained: Bool,
                              wantsPaste: Bool, pasteTrusted: Bool) -> Bool {
        current == "certificate" && previous != "certificate" && existingUser && !alreadyExplained && wantsPaste && !pasteTrusted
    }
}
