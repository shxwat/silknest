import Foundation

/// Official releases (signed with the "SilkNest Signing" certificate) carry the bundle identifier
/// studio.webber.spider. Every other build — a contributor's ad-hoc build, a local build without the
/// certificate, a bare `swift run` — is a development build: its own bundle identifier, its own data
/// folder and preferences, and no automatic updates, so it never touches or replaces an installed SilkNest.
enum BuildFlavor {
    static let officialID = "studio.webber.spider"
    static let developmentID = "app.silknest.dev"
    static var isOfficial: Bool { Bundle.main.bundleIdentifier == officialID }
}
