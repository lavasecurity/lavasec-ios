import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// Executable contract for the durable, explicit protection-restore direction. The shared
/// configuration remains a compatibility mirror that a headless Focus switch may advance, so an
/// accepted user turn-off must never rewrite that `(configuration, library)` pair just to survive
/// relaunch. This sidecar is owned by the app's lifecycle actions alone: absent preserves the
/// legacy configuration fallback, while a valid explicit choice is authoritative.
final class ProtectionRestoreIntentStoreTests: XCTestCase {
    private func withContainer<Result>(
        _ operation: (URL) throws -> Result
    ) throws -> Result {
        try withTemporaryDirectory(prefix: "protection-restore-intent", operation)
    }

    func testAbsentIntentFallsBackToLoadedConfiguration() throws {
        try withContainer { container in
            let outcome = ProtectionRestoreIntentStore.read(containerURL: container)

            XCTAssertEqual(outcome, .absent)
            XCTAssertTrue(
                outcome.resolvedIntent(fallingBackTo: true),
                "A new sidecar must preserve the legacy configuration fallback for existing installs."
            )
            XCTAssertFalse(outcome.resolvedIntent(fallingBackTo: false))
        }
    }

    func testValidStoredIntentIsAuthoritativeOverConfigurationFallback() throws {
        try withContainer { container in
            try ProtectionRestoreIntentStore.persist(isEnabled: true, containerURL: container)

            let outcome = ProtectionRestoreIntentStore.read(containerURL: container)
            XCTAssertEqual(outcome, .stored(isEnabled: true))
            XCTAssertTrue(
                outcome.resolvedIntent(fallingBackTo: false),
                "An accepted explicit ON must not fall back to an older configuration false."
            )
        }
    }

    func testCorruptIntentIsRestoreIneligibleInsteadOfFallingBackToStickyConfigurationTrue() throws {
        try withContainer { container in
            let url = ProtectionRestoreIntentStore.fileURL(containerURL: container)
            try Data("not valid intent JSON".utf8).write(to: url)

            let outcome = ProtectionRestoreIntentStore.read(containerURL: container)
            XCTAssertEqual(outcome, .corrupt)
            XCTAssertFalse(
                outcome.resolvedIntent(fallingBackTo: true),
                "Corruption must never silently turn a stale configuration true back into auto-restore."
            )
        }
    }

    func testUnreadableIntentIsRestoreIneligibleInsteadOfFallingBackToStickyConfigurationTrue() throws {
        try XCTSkipIf(geteuid() == 0, "chmod-based unreadable fixture requires a non-root user")

        try withContainer { container in
            try ProtectionRestoreIntentStore.persist(isEnabled: false, containerURL: container)
            let url = ProtectionRestoreIntentStore.fileURL(containerURL: container)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            }

            let outcome = ProtectionRestoreIntentStore.read(containerURL: container)
            XCTAssertEqual(outcome, .unreadable)
            XCTAssertFalse(
                outcome.resolvedIntent(fallingBackTo: true),
                "An unreadable sidecar is not absence: falling back here would resurrect stale ON intent."
            )
        }
    }

    func testPersistedOffAtomicallySurvivesColdRelaunchAndRefusesRestoreDespiteStickyConfigurationTrue() throws {
        try withContainer { container in
            XCTAssertTrue(
                ProtectionRestoreIntentStore.atomicWritingOptions.contains(.atomic),
                "The explicit-intent crash barrier must use atomic replacement, never an in-place write."
            )
            try ProtectionRestoreIntentStore.persist(isEnabled: false, containerURL: container)

            // A fresh read models a cold process — no in-memory `userProtectionIntent` is carried
            // across this boundary, while the legacy configuration still says true.
            let coldLaunchIntent = ProtectionRestoreIntentStore.read(containerURL: container)
                .resolvedIntent(fallingBackTo: true)
            XCTAssertFalse(coldLaunchIntent)

            var restoreState = ProtectionRestoreIntentState(isEnabled: true)
            restoreState.recoverFromLoadedConfiguration(isEnabled: coldLaunchIntent)
            let request = restoreState.makeRestoreRequest()
            XCTAssertFalse(request.wasEnabled)
            XCTAssertFalse(
                restoreState.allows(request),
                "A cold relaunch must refuse automatic restore after a durable explicit OFF."
            )
        }
    }

    func testLaterExplicitTrueAtomicallySupersedesEarlierFalse() throws {
        try withContainer { container in
            try ProtectionRestoreIntentStore.persist(isEnabled: false, containerURL: container)
            let offBytes = try Data(contentsOf: ProtectionRestoreIntentStore.fileURL(containerURL: container))

            try ProtectionRestoreIntentStore.persist(isEnabled: true, containerURL: container)

            XCTAssertEqual(
                ProtectionRestoreIntentStore.read(containerURL: container),
                .stored(isEnabled: true),
                "A later accepted explicit ON/reconnect must replace an earlier durable OFF."
            )
            XCTAssertNotEqual(
                try Data(contentsOf: ProtectionRestoreIntentStore.fileURL(containerURL: container)),
                offBytes,
                "The replacement must reach disk rather than only changing the current process."
            )
        }
    }

    func testPersistingOffCannotClobberNewerFocusConfigurationOrLibraryPair() throws {
        try withContainer { container in
            let configurationURL = container.appendingPathComponent("app-configuration.json")
            let libraryURL = container.appendingPathComponent("filter-library.json")
            let focusedConfiguration = AppConfiguration(
                enabledBlocklistIDs: ["focused"],
                customBlocklists: [],
                configurationGeneration: 73
            )
            var focusedLibrary = FilterLibrary(
                filters: [
                    Filter(id: "default", name: "Default", enabledBlocklistIDs: ["default"]),
                    Filter(id: "focus", name: "Focus", enabledBlocklistIDs: ["focused"]),
                ],
                activeFilterID: "focus"
            )
            focusedLibrary.configurationGeneration = 73
            let configurationBytes = try JSONEncoder().encode(focusedConfiguration)
            let libraryBytes = try JSONEncoder().encode(focusedLibrary)
            try configurationBytes.write(to: configurationURL)
            try libraryBytes.write(to: libraryURL)

            try ProtectionRestoreIntentStore.persist(isEnabled: false, containerURL: container)

            XCTAssertEqual(
                try Data(contentsOf: configurationURL),
                configurationBytes,
                "Explicit OFF must not rewrite a newer Focus configuration generation."
            )
            XCTAssertEqual(
                try Data(contentsOf: libraryURL),
                libraryBytes,
                "Explicit OFF must not rewrite or collapse the newer multi-filter library."
            )
            let reloadedLibrary = try JSONDecoder().decode(FilterLibrary.self, from: Data(contentsOf: libraryURL))
            XCTAssertEqual(reloadedLibrary.activeFilterID, "focus")
            XCTAssertEqual(reloadedLibrary.filters.map(\.id), ["default", "focus"])
        }
    }

    func testPersistRefusesToReplaceAnExistingUnreadableIntent() throws {
        try XCTSkipIf(geteuid() == 0, "chmod-based unreadable fixture requires a non-root user")

        try withContainer { container in
            try ProtectionRestoreIntentStore.persist(isEnabled: false, containerURL: container)
            let url = ProtectionRestoreIntentStore.fileURL(containerURL: container)
            let originalBytes = try Data(contentsOf: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            }

            XCTAssertThrowsError(
                try ProtectionRestoreIntentStore.persist(isEnabled: true, containerURL: container)
            ) { error in
                XCTAssertTrue(error is ProtectionRestoreIntentStore.ExistingIntentUnreadableError)
            }

            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            XCTAssertEqual(
                try Data(contentsOf: url),
                originalBytes,
                "A failed persistence fence must leave the prior durable user choice untouched."
            )
        }
    }

    func testPersistThrowsWhenItsContainerCannotAcceptTheCrashBarrierFile() throws {
        try withContainer { root in
            let nonDirectory = root.appendingPathComponent("not-a-directory")
            try Data("not a directory".utf8).write(to: nonDirectory)

            XCTAssertThrowsError(
                try ProtectionRestoreIntentStore.persist(isEnabled: false, containerURL: nonDirectory)
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: ProtectionRestoreIntentStore.fileURL(containerURL: nonDirectory).path
                )
            )
        }
    }
}
