// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LavaSec",
    // Notification BODY strings (filter-switch + connectivity) are emitted from LavaSecKit code that runs
    // in THREE processes (app, App Intents extension, NE tunnel). The app's Localizable.xcstrings is only in
    // the app bundle, so the extension/tunnel can't reach it — they localize against this package's own
    // catalog via `Bundle.module`. `defaultLocalization` + the bundled string catalog enable that.
    defaultLocalization: "en",
    // iOS 18 / macOS 15 floor (founder decision 2026-07-08, pre-public so the gate is
    // free): unblocks the INV-QUEUE-1 actors migration — `assumeIsolated` on a custom
    // DispatchSerialQueue executor needs SE-0424 (Swift 6 runtime), which iOS 17 lacks
    // (it traps on the CORRECT queue; see the #320 analysis).
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        // Compatibility product: existing consumers keep linking LavaSecCore while
        // post-split consumers select the narrow product that owns each symbol.
        .library(name: "LavaSecCore", targets: ["LavaSecCore", "LavaSecKit", "LavaSecNetworking", "LavaSecDNS", "LavaSecFilterPipeline", "LavaSecPresentation", "LavaSecAppServices"]),
        .library(name: "LavaSecKit", targets: ["LavaSecKit"]),
        .library(name: "LavaSecNetworking", targets: ["LavaSecNetworking"]),
        .library(name: "LavaSecDNS", targets: ["LavaSecDNS"]),
        .library(name: "LavaSecFilterPipeline", targets: ["LavaSecFilterPipeline"]),
        .library(name: "LavaSecPresentation", targets: ["LavaSecPresentation"]),
        .library(name: "LavaSecAppServices", targets: ["LavaSecAppServices"])
    ],
    targets: [
        // Foundation layer: models, pure policies, persistence plumbing, localized
        // strings. Must not depend on the engine layers — the compiler now enforces
        // the dependency direction that used to be convention.
        .target(
            name: "LavaSecKit",
            // Per-locale .lproj/Localizable.strings (NOT a single .xcstrings: SwiftPM's `swift build`/`test`
            // does not compile string catalogs, so Bundle.module would return the key — .strings resolve in
            // both SwiftPM and Xcode builds). They live in LavaSecKit because every Bundle.module
            // string lookup (LavaCoreStrings and its callers) lives here.
            resources: [.process("Resources")],
            // `DNSEventLog` uses the system SQLite via `import SQLite3` (the SDK ships the module
            // map); this links libsqlite3 for the target and every consumer of the LavaSecCore
            // product. No third-party dependency is added.
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Shared outbound HTTPS transport. Owns the resolve-once, public-address-only
        // connection pinning seam and depends only on the foundation validation policy.
        .target(
            name: "LavaSecNetworking",
            dependencies: ["LavaSecKit"]
        ),
        // DNS layer: wire format, DoH/DoT/DoQ transports, resolver orchestration/
        // probes/backoff. Depends on the foundation layer only — never on the engine
        // layer above it (Phase B2 of the modularization plan).
        .target(
            name: "LavaSecDNS",
            dependencies: ["LavaSecKit"]
        ),
        // Filter pipeline layer: snapshot compile/store/gate, catalog sync + parsing,
        // and the focus-switch engine. Uses the networking layer's pinned fetcher for
        // catalog downloads; never depends on DNS or app services (Phase B3).
        .target(
            name: "LavaSecFilterPipeline",
            dependencies: ["LavaSecKit", "LavaSecNetworking"]
        ),
        // UI animation value types and policy. State vocabulary stays in Kit because it
        // crosses the app, widget, and tunnel through ActivityKit attributes.
        .target(
            name: "LavaSecPresentation",
            dependencies: ["LavaSecKit"]
        ),
        // App-services layer: backup, bug report/diagnostics, subscription/auth, QA
        // scenarios, legal notices — app-facing services that the NE tunnel and widget
        // never needed but shipped in their binaries pre-split.
        .target(
            name: "LavaSecAppServices",
            dependencies: ["LavaSecKit", "LavaSecFilterPipeline"]
        ),
        // Compatibility façade for callers outside the production process targets. The
        // tunnel links only its four narrow products, so re-exporting Presentation here
        // cannot introduce UI policy into the Network Extension. See lavasec-infra
        // plans/2026-07-07-ios-modularization-scaffolding-plan.md Phase B.
        .target(
            name: "LavaSecCore",
            dependencies: ["LavaSecKit", "LavaSecNetworking", "LavaSecDNS", "LavaSecFilterPipeline", "LavaSecPresentation", "LavaSecAppServices"]
        ),
        .testTarget(
            name: "LavaSecCoreTests",
            dependencies: ["LavaSecCore", "LavaSecKit", "LavaSecNetworking", "LavaSecDNS", "LavaSecFilterPipeline", "LavaSecPresentation", "LavaSecAppServices"]
        ),
        // Compiler proof that the compatibility façade alone exposes every real layer.
        .testTarget(
            name: "LavaSecCoreFacadeCompileTests",
            dependencies: ["LavaSecCore"]
        )
    ]
)
