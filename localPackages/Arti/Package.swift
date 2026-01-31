// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tor",  // Keep name "Tor" for drop-in compatibility
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "Tor",
            targets: ["Tor"]
        ),
    ],
    dependencies: [
        .package(path: "../BitLogger"),
    ],
    targets: [
        // Main Swift target
        .target(
            name: "Tor",
            dependencies: [
                "arti",
                .product(name: "BitLogger", package: "BitLogger"),
            ],
            path: "Sources",
            exclude: ["C"],
            sources: [
                "TorManager.swift",
                "TorURLSession.swift",
                "TorNotifications.swift",
            ],
            linkerSettings: [
                .linkedLibrary("resolv"),
                .linkedLibrary("z"),
                // NOTE: sqlite3 is provided by SQLCipher framework (from XMTP CocoaPod)
                // Do not link system sqlite3 as it conflicts with SQLCipher encryption
            ]
        ),
        // Binary framework containing the Rust static library
        .binaryTarget(
            name: "arti",
            path: "Frameworks/arti.xcframework"
        ),
    ]
)
