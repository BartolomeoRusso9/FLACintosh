// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FLACintosh",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        // The parser and its model are a library on purpose: they are the
        // part worth testing, and they must stay runnable without a window.
        .library(name: "SyncedLyrics", targets: ["SyncedLyrics"]),
        .executable(name: "FLACintosh", targets: ["FLACintosh"]),
        .executable(name: "LyricsCheck", targets: ["LyricsCheck"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sbooth/SFBAudioEngine", from: "0.7.0"),
    ],
    targets: [
        .target(
            name: "SyncedLyrics",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "FLACintosh",
            dependencies: [
                "SyncedLyrics",
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Not a test target: both XCTest and swift-testing ship inside
        // Xcode.app, so `swift test` cannot build with only the Command Line
        // Tools. `swift run LyricsCheck` needs nothing but the toolchain.
        .executableTarget(
            name: "LyricsCheck",
            dependencies: ["SyncedLyrics"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
