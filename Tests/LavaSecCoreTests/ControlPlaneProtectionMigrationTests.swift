import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// Executable tests for the INV-PERSIST-2 one-shot migration: target selection over a
/// fixture App Group container (control-plane files IN, privacy stores OUT) and the
/// one-shot/latch semantics. The attribute write itself is iOS-only and vacuously
/// succeeds here (`SharedStateFileProtectionTests` covers that fallback), which is
/// exactly what lets the latch/count semantics execute on the macOS CI host.
final class ControlPlaneProtectionMigrationTests: XCTestCase {
    private func makeFixtureContainer() throws -> (container: URL, controlPlane: Set<String>) {
        let fileManager = FileManager.default
        let container = fileManager.temporaryDirectory.appendingPathComponent("cppm-\(UUID().uuidString)")
        var controlPlane: Set<String> = []

        func place(_ relativePath: String, isControlPlane: Bool) throws {
            let url = container.appendingPathComponent(relativePath)
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fixture \(relativePath)".utf8).write(to: url)
            if isControlPlane {
                controlPlane.insert(url.standardizedFileURL.path)
            }
        }

        // The shared pair + tunnel health.
        try place("app-configuration.json", isControlPlane: true)
        try place("filter-library.json", isControlPlane: true)
        try place("tunnel-health.json", isControlPlane: true)
        // The legacy root artifact trio (pre-pointer layout, still the readableStore fallback).
        try place("filter-snapshot.json", isControlPlane: true)
        try place("filter-snapshot.compact", isControlPlane: true)
        try place("filter-artifact-manifest.json", isControlPlane: true)
        // The versioned artifact area: a token directory's trio + the publish pointer.
        let token = "fixture-token-1234"
        try place("filter-artifacts/\(token)/filter-snapshot.json", isControlPlane: true)
        try place("filter-artifacts/\(token)/filter-snapshot.compact", isControlPlane: true)
        try place("filter-artifacts/\(token)/filter-artifact-manifest.json", isControlPlane: true)
        try place("filter-artifacts/current.json", isControlPlane: true)
        // The tunnel's retained in-extension compile, under the catalog cache.
        try place("catalog-cache/tunnel-compiled-artifact/filter-snapshot.compact", isControlPlane: true)

        // Privacy-store decoys: recorded user activity stays Class C (INV-PERSIST-2).
        try place("dns-events.sqlite", isControlPlane: false)
        try place("diagnostics.json", isControlPlane: false)
        try place("network-activity-log.json", isControlPlane: false)
        // The catalog cache OUTSIDE the retained-compile subdirectory is also excluded.
        try place("catalog-cache/latest-catalog.json", isControlPlane: false)

        return (container, controlPlane)
    }

    func testControlPlaneTargetsSelectExactlyTheControlPlaneFiles() throws {
        let (container, expected) = try makeFixtureContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let scan = ControlPlaneProtectionMigration.controlPlaneTargets(containerURL: container)
        let targetPaths = Set(scan.targets.map(\.standardizedFileURL.path))

        XCTAssertEqual(
            targetPaths, expected,
            "The migration must re-stamp exactly the control-plane set — a missed file stays boot-unreadable; an extra file drags a privacy store to Class None."
        )
        XCTAssertTrue(scan.scanIsComplete, "A clean fixture container must scan complete.")
    }

    func testRunIsOneShotAndASecondRunAppliesNothing() throws {
        let (container, expected) = try makeFixtureContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let suiteName = "cppm-defaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let appliedCount = ControlPlaneProtectionMigration.run(containerURL: container, defaults: defaults)

        XCTAssertEqual(appliedCount, expected.count, "Every control-plane target must be re-stamped on the first pass.")
        XCTAssertTrue(
            defaults.bool(forKey: ControlPlaneProtectionMigration.migrationCompletedDefaultsKey),
            "A fully-successful pass must latch the one-shot key (partial failure leaves it unset for the next-foreground retry)."
        )
        XCTAssertEqual(
            ControlPlaneProtectionMigration.run(containerURL: container, defaults: defaults), 0,
            "A latched migration must be a no-op — the per-foreground trigger relies on this being free."
        )
    }

    func testUnenumerableSubtreeLeavesTheLatchUnset() throws {
        // chmod 000 removes traverse permission for non-root users; root bypasses
        // permission checks entirely, so the enumeration would spuriously succeed.
        try XCTSkipIf(geteuid() == 0, "Permission-based unreadability cannot be simulated as root.")

        let (container, expected) = try makeFixtureContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let suiteName = "cppm-defaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Make the retained-compile subtree unenumerable: its files may be missing from the
        // scan, so a pass over the remaining targets must NOT latch — latching would strand
        // that subtree's pre-existing Class-C files forever (PR #378 review).
        let retainedCompileDir = container
            .appendingPathComponent("catalog-cache", isDirectory: true)
            .appendingPathComponent("tunnel-compiled-artifact", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: retainedCompileDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: retainedCompileDir.path)
        }

        let blockedScan = ControlPlaneProtectionMigration.controlPlaneTargets(containerURL: container)
        XCTAssertFalse(blockedScan.scanIsComplete, "An unenumerable subtree must mark the scan incomplete.")

        ControlPlaneProtectionMigration.run(containerURL: container, defaults: defaults)
        XCTAssertFalse(
            defaults.bool(forKey: ControlPlaneProtectionMigration.migrationCompletedDefaultsKey),
            "An incomplete scan must leave the one-shot key unset so the next foreground retries."
        )

        // Once the subtree is enumerable again, the retry completes and latches.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: retainedCompileDir.path)
        let appliedOnRetry = ControlPlaneProtectionMigration.run(containerURL: container, defaults: defaults)
        XCTAssertEqual(appliedOnRetry, expected.count, "The retry must re-stamp the full set.")
        XCTAssertTrue(
            defaults.bool(forKey: ControlPlaneProtectionMigration.migrationCompletedDefaultsKey),
            "A complete, fully-applied retry must latch."
        )
    }
}
