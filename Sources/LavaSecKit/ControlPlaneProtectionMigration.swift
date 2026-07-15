import Foundation

/// One-shot re-stamp of the EXISTING control-plane files to Class-None
/// (INV-PERSIST-2). New writes get the class from `SharedStateFileProtection` at the write
/// site; this migration covers every file written BEFORE the phase-2 change so an already-
/// installed device also boots with readable control-plane state, not just one that has
/// rewritten every file since updating (lavasec-infra
/// `plans/2026-07-14-reboot-first-unlock-data-reset-incident-plan.md`).
///
/// Changing a file's protection class re-encrypts its content, so the migration MUST run
/// while protected data is available (post-unlock) — the caller gates on
/// `isProtectedDataAvailable`. It runs at most once per install via a `UserDefaults` bool,
/// set ONLY when every apply succeeded, so a partial failure (transient I/O) retries on the
/// next app foreground instead of stranding a mixed-class store.
/// - pinned: ControlPlaneProtectionMigrationTests.testRunIsOneShotAndASecondRunAppliesNothing
///
/// `LavaSecKit` deliberately carries no App-Group constants (they live in
/// `Shared/AppGroup.swift`, outside the package), so the control-plane layout is named here
/// by literal filename — the same values `FilterArtifactStore`'s defaults and the shared
/// pair writer's callers use, target-selection-tested against a fixture container.
/// - pinned: ControlPlaneProtectionMigrationTests.testControlPlaneTargetsSelectExactlyTheControlPlaneFiles
public enum ControlPlaneProtectionMigration {
    /// `UserDefaults` bool key latching a fully-successful migration pass. Versioned (`v1`)
    /// so a future protection-class change can ship as a fresh one-shot key.
    public static let migrationCompletedDefaultsKey = "lavasec.protection.controlPlaneClassMigration.v1" // mobsf-ignore: ios_hardcoded_secret — versioned latch key, not a credential (gitleaks is the secret gate)

    /// Result of scanning the container for control-plane files.
    public struct ControlPlaneTargetScan {
        /// The existing control-plane files the scan found.
        public let targets: [URL]
        /// Whether the scan saw the COMPLETE set. False when a subtree enumeration failed
        /// or a file's type could not be read — files may then be missing from `targets`,
        /// and the caller must NOT latch a one-shot pass on it: latching over an
        /// incomplete scan would strand pre-existing Class-C files forever instead of
        /// retrying on the next foreground (PR #378 review).
        public let scanIsComplete: Bool
    }

    /// The existing control-plane files under `containerURL` that must carry
    /// Class-None (INV-PERSIST-2): the shared config/library pair, tunnel
    /// health, the legacy root artifact trio, and every file under the versioned artifact
    /// area (`filter-artifacts/`, including the publish pointer) and the tunnel's retained
    /// in-extension compile (`catalog-cache/tunnel-compiled-artifact/`).
    ///
    /// Everything else is deliberately EXCLUDED: the privacy stores (DNS events,
    /// diagnostics, activity/incident/debug logs, the rest of `catalog-cache`) stay
    /// Class C, and the advisory lock files stay default-class — they are content-free,
    /// every pre-unlock toucher already degrades on a failed open, and re-stamping them
    /// buys nothing (see INV-PERSIST-2's exclusion note).
    ///
    /// Pure file enumeration — no attribute writes — so it is executable-testable on the
    /// macOS CI host, where the protection APIs do not exist.
    ///
    /// - Parameters:
    ///   - containerURL: The shared App Group container root.
    ///   - fileManager: Injectable for tests; defaults to `.default`.
    /// - Returns: The scan — existing control-plane files (absent ones are skipped, not
    ///   invented) plus whether the scan saw the COMPLETE set.
    public static func controlPlaneTargets(
        containerURL: URL,
        fileManager: FileManager = .default
    ) -> ControlPlaneTargetScan {
        // Root singles: the pair + tunnel health, plus the legacy pre-pointer root trio
        // (still read by the tunnel's readableStore fallback before the first versioned
        // publish and after a rollback).
        let rootFilenames = [
            "app-configuration.json",
            "filter-library.json",
            "tunnel-health.json",
            "filter-snapshot.json",
            "filter-snapshot.compact",
            "filter-artifact-manifest.json",
        ]
        var targets = rootFilenames
            .map { containerURL.appendingPathComponent($0) }
            .filter { fileManager.fileExists(atPath: $0.path) }
        var scanIsComplete = true
        // The whole content-addressed artifact area: token directories' trios AND the
        // `current.json` pointer — the boot tunnel resolves the pointer first, so a locked
        // pointer alone would defeat every readable artifact behind it.
        let artifactScan = regularFiles(
            under: containerURL.appendingPathComponent("filter-artifacts", isDirectory: true),
            fileManager: fileManager
        )
        targets += artifactScan.files
        scanIsComplete = scanIsComplete && artifactScan.complete
        // The tunnel's retained in-extension compile lives under the catalog cache
        // (see `PacketTunnelProvider.tunnelCompiledArtifactDirectoryName`) — only this
        // subdirectory is control-plane; the surrounding catalog-cache downloads stay
        // Class C.
        let retainedCompileScan = regularFiles(
            under: containerURL
                .appendingPathComponent("catalog-cache", isDirectory: true)
                .appendingPathComponent("tunnel-compiled-artifact", isDirectory: true),
            fileManager: fileManager
        )
        targets += retainedCompileScan.files
        scanIsComplete = scanIsComplete && retainedCompileScan.complete
        return ControlPlaneTargetScan(targets: targets, scanIsComplete: scanIsComplete)
    }

    /// Run the one-shot migration: apply Class-None to every existing
    /// control-plane file, latching the completion key ONLY when every apply succeeded.
    ///
    /// Idempotent and cheap to call on every foreground: a latched key returns immediately,
    /// and a partial failure — a refused apply OR an incomplete scan (failed subtree
    /// enumeration) — leaves the key unset so the next call retries the whole
    /// (idempotent) pass. Callers must only invoke this while protected data is available —
    /// the re-encryption needs the class keys unlocked.
    ///
    /// - Parameters:
    ///   - containerURL: The shared App Group container root.
    ///   - defaults: The defaults store holding the one-shot key; injectable for tests.
    /// - Returns: The number of files successfully re-stamped in this pass (0 once latched).
    @discardableResult
    public static func run(containerURL: URL, defaults: UserDefaults = .standard) -> Int {
        guard !defaults.bool(forKey: migrationCompletedDefaultsKey) else {
            return 0
        }
        var appliedCount = 0
        var allApplied = true
        let scan = controlPlaneTargets(containerURL: containerURL)
        for target in scan.targets {
            if SharedStateFileProtection.applyControlPlaneProtection(at: target) {
                appliedCount += 1
            } else {
                allApplied = false
            }
        }
        // Latch ONLY on a complete scan with every apply succeeded: an unenumerable
        // subtree yields an empty target list for that subtree, and latching over it
        // would strand its pre-existing Class-C files forever (PR #378 review).
        if allApplied, scan.scanIsComplete {
            defaults.set(true, forKey: migrationCompletedDefaultsKey)
        }
        return appliedCount
    }

    /// Every regular file under `directoryURL`, recursively; empty-and-complete when the
    /// directory does not exist. Directories themselves are skipped — protection classes
    /// matter per file, and new files under a directory get their class from the writer,
    /// not the parent. `complete` is false when the enumerator could not be created for an
    /// EXISTING directory, when it reported an error mid-walk, or when a visited entry's
    /// type could not be read — any of those can hide files from the result.
    private static func regularFiles(
        under directoryURL: URL,
        fileManager: FileManager
    ) -> (files: [URL], complete: Bool) {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return ([], true)
        }
        var complete = true
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: { _, _ in
                complete = false
                return true
            }
        ) else {
            return ([], false)
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile else {
                complete = false
                continue
            }
            if isRegularFile {
                files.append(url)
            }
        }
        return (files, complete)
    }
}
