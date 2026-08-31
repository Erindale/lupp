// swift-tools-version: 6.0
import PackageDescription

// Lupp builds with the Command Line Tools alone — no Xcode, no asset catalogs,
// no offline Metal compiler. `swift build` produces the binary; `build.sh` wraps
// it in a .app. Shaders are compiled at runtime from source (see Renderer.swift).
let package = Package(
    name: "Lupp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Lupp",
            path: "Sources/Lupp",
            // AppKit under Swift 6 strict concurrency is mostly ceremony for a
            // single-window app whose work is already main-thread bound.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
