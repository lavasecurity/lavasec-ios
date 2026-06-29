// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LavaSec",
    // Notification BODY strings (filter-switch + connectivity) are emitted from LavaSecCore code that runs
    // in THREE processes (app, App Intents extension, NE tunnel). The app's Localizable.xcstrings is only in
    // the app bundle, so the extension/tunnel can't reach it — they localize against this package's own
    // catalog via `Bundle.module`. `defaultLocalization` + the bundled string catalog enable that.
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LavaSecCore", targets: ["LavaSecCore"])
    ],
    targets: [
        .target(
            name: "LavaSecCore",
            // Per-locale .lproj/Localizable.strings (NOT a single .xcstrings: SwiftPM's `swift build`/`test`
            // does not compile string catalogs, so Bundle.module would return the key — .strings resolve in
            // both SwiftPM and Xcode builds).
            resources: [.process("Resources")]
        ),
        .testTarget(name: "LavaSecCoreTests", dependencies: ["LavaSecCore"])
    ]
)
