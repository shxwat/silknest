// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WEBBER",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "WEBBER", targets: ["WEBBER"])],
    targets: [
        .executableTarget(name: "WEBBER", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
