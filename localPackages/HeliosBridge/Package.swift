// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Helios",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "Helios",
            targets: ["Helios"]
        ),
        // Expose just the xcframework so the app can link the FFI symbols
        // without pulling in the package's HeliosManager.swift
        .library(
            name: "HeliosFFI",
            targets: ["HeliosFFI"]
        ),
    ],
    dependencies: [
        .package(path: "../BitLogger"),
    ],
    targets: [
        // Main Swift target
        .target(
            name: "Helios",
            dependencies: [
                "HeliosFFI",
                .product(name: "BitLogger", package: "BitLogger"),
            ],
            path: "Sources",
            exclude: ["C"],
            sources: [
                "HeliosManager.swift",
            ],
            linkerSettings: [
                .linkedLibrary("resolv"),
                .linkedLibrary("z"),
            ]
        ),
        // Binary framework containing the Rust static library
        // NOTE: Until build-ios.sh is run, this target won't resolve.
        // The HeliosManager uses @_silgen_name for FFI, so it can
        // compile without the xcframework present (symbols resolve at link time).
        .binaryTarget(
            name: "HeliosFFI",
            path: "Frameworks/helios.xcframework"
        ),
    ]
)
