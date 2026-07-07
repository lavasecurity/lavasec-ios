// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LavaSec",
    // Notification BODY strings (filter-switch + connectivity) are emitted from LavaSecKit code that runs
    // in THREE processes (app, App Intents extension, NE tunnel). The app's Localizable.xcstrings is only in
    // the app bundle, so the extension/tunnel can't reach it — they localize against this package's own
    // catalog via `Bundle.module`. `defaultLocalization` + the bundled string catalog enable that.
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        // Single product: every process keeps linking "LavaSecCore" and gets the split
        // targets transitively; LavaSecCore re-exports them (LavaSecCoreExports.swift) so
        // existing `import LavaSecCore` statements keep seeing the full pre-split API.
        .library(name: "LavaSecCore", targets: ["LavaSecCore", "LavaSecKit", "LavaSecDNS", "LavaSecFilterPipeline", "LavaSecAppServices"])
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
            resources: [.process("Resources")]
        ),
        // DNS layer: wire format, DoH/DoT/DoQ transports, resolver orchestration/
        // probes/backoff, pinned HTTPS fetching. Depends on the foundation layer only —
        // never on the engine layer above it (Phase B2 of the modularization plan).
        .target(
            name: "LavaSecDNS",
            dependencies: ["LavaSecKit"]
        ),
        // Filter pipeline layer: snapshot compile/store/gate, catalog sync + parsing,
        // and the focus-switch engine. Uses the DNS layer's pinned fetcher for catalog
        // downloads; never depends on the app-services remainder above it (Phase B3).
        .target(
            name: "LavaSecFilterPipeline",
            dependencies: ["LavaSecKit", "LavaSecDNS"]
        ),
        // App-services layer: backup, bug report/diagnostics, gamification animations,
        // subscription/auth, QA scenarios, legal notices — app-facing services that the
        // NE tunnel and widget never needed but shipped in their binaries pre-split.
        .target(
            name: "LavaSecAppServices",
            dependencies: ["LavaSecKit", "LavaSecFilterPipeline"]
        ),
        // Pure façade (Phase B4 endpoint): one file of @_exported imports, so every
        // pre-split `import LavaSecCore` keeps seeing the whole API surface. New code
        // imports the specific layer it needs. See lavasec-infra
        // plans/2026-07-07-ios-modularization-scaffolding-plan.md Phase B.
        .target(
            name: "LavaSecCore",
            dependencies: ["LavaSecKit", "LavaSecDNS", "LavaSecFilterPipeline", "LavaSecAppServices"]
        ),
        .testTarget(
            name: "LavaSecCoreTests",
            dependencies: ["LavaSecCore", "LavaSecKit", "LavaSecDNS", "LavaSecFilterPipeline", "LavaSecAppServices"]
        )
    ]
)
