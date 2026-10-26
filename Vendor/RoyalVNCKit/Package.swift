// swift-tools-version: 6.0
// Vendored RoyalVNCKit 1.1.0 (upstream archived). See PATCHES.md.

import PackageDescription

let package = Package(
    name: "RoyalVNCKit",
    platforms: [.iOS("27.1")],
    products: [
        .library(name: "RoyalVNCKit", targets: ["RoyalVNCKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/royalapplications/CryptoSwift.git",
                 revision: "a59b4d91ebb22011656c830f874fe7152e183a57")
    ],
    targets: [
        .target(name: "RoyalVNCKitC"),
        .target(name: "d3des"),
        .target(name: "Z", linkerSettings: [.linkedLibrary("z")]),
        .target(
            name: "RoyalVNCKit",
            dependencies: ["RoyalVNCKitC", "d3des", "Z", "CryptoSwift"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
