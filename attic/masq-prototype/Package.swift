// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Masq",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Masq",
            path: "Sources/Masq",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
