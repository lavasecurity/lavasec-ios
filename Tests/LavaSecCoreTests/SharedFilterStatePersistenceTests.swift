import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class SharedFilterStatePersistenceTests: XCTestCase {
    private func makeURLs() -> (config: URL, library: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sfsp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("app-configuration.json"), dir.appendingPathComponent("filter-library.json"))
    }

    private func config(generation: Int) -> AppConfiguration {
        AppConfiguration(enabledBlocklistIDs: ["s1"], customBlocklists: [], configurationGeneration: generation)
    }

    private func library(generation: Int) -> FilterLibrary {
        var lib = FilterLibrary(filters: [Filter(id: "f1", name: "F1", enabledBlocklistIDs: ["s1"])], activeFilterID: "f1")
        lib.configurationGeneration = generation
        return lib
    }

    /// Two-filter library with a caller-chosen active id — `activeFilterID` is set at init, so a
    /// concurrent-switch state has to be built rather than mutated.
    private func library(generation: Int, activeFilterID: String) -> FilterLibrary {
        var lib = FilterLibrary(
            filters: [
                Filter(id: "f1", name: "F1", enabledBlocklistIDs: ["s1"]),
                Filter(id: "f2", name: "F2", enabledBlocklistIDs: ["s1"]),
            ],
            activeFilterID: activeFilterID
        )
        lib.configurationGeneration = generation
        return lib
    }

    func testWritesBothFilesAndBumpsGenerationPastOnDisk() throws {
        let urls = makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.config.deletingLastPathComponent()) }

        // Seed an on-disk config at generation 5 so the bump must exceed it.
        let seeded = try JSONEncoder().encode(config(generation: 5))
        try seeded.write(to: urls.config)

        let written = try SharedFilterStatePersistence.writeConfigurationAndLibrary(
            configuration: config(generation: 2), // in-memory LOWER than on-disk (e.g. post-restore reset)
            library: library(generation: 2),
            configurationURL: urls.config,
            filterLibraryURL: urls.library
        )

        // Monotonic: one past max(in-memory 2, on-disk 5) = 6.
        XCTAssertEqual(written.configuration.configurationGeneration, 6)
        // Library stamped to pair with the config generation.
        XCTAssertEqual(written.library.configurationGeneration, 6)

        // Both files written, decodable, carrying the bumped generation.
        let onDiskConfig = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: urls.config))
        let onDiskLibrary = try JSONDecoder().decode(FilterLibrary.self, from: Data(contentsOf: urls.library))
        XCTAssertEqual(onDiskConfig.configurationGeneration, 6)
        XCTAssertEqual(onDiskLibrary.configurationGeneration, 6)
        XCTAssertEqual(onDiskLibrary.activeFilterID, "f1")
    }

    // MARK: In-lock active-filter precondition

    /// A library-only replace may only touch an IDLE filter. The caller's own
    /// `activeFilterID` cannot answer that: a headless Focus/Shortcut switch commits from another
    /// process and the foreground adopts it asynchronously, so the snapshot can name the previous
    /// filter while disk names the new one. This is the state that models exactly that skew — disk
    /// says `f2` is active, the writer's in-memory library still says `f1`.
    func testRefusesWhenTheTargetIsActiveOnDiskEvenThoughTheCallerThinksOtherwise() throws {
        let urls = makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.config.deletingLastPathComponent()) }

        // Disk: a concurrent switch made f2 active.
        try JSONEncoder().encode(library(generation: 4, activeFilterID: "f2")).write(to: urls.library)

        // Caller: still holds the pre-switch snapshot naming f1, and wants to overwrite f2
        // believing it idle.
        XCTAssertThrowsError(
            try SharedFilterStatePersistence.writeConfigurationAndLibrary(
                configuration: config(generation: 4),
                library: library(generation: 4),      // activeFilterID == "f1"
                configurationURL: urls.config,
                filterLibraryURL: urls.library,
                refusesIfOnDiskActiveFilterIs: "f2"
            )
        ) { error in
            let changed = error as? SharedFilterStatePersistence.ActiveFilterChangedError
            XCTAssertEqual(changed?.activeFilterID, "f2")
        }

        // And nothing was written: the refusal must precede both file writes.
        let stillOnDisk = try JSONDecoder().decode(FilterLibrary.self, from: Data(contentsOf: urls.library))
        XCTAssertEqual(stillOnDisk.activeFilterID, "f2")
        XCTAssertEqual(stillOnDisk.configurationGeneration, 4, "A refused write must not bump the generation.")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: urls.config.path),
            "A refused write must not create the configuration either."
        )
    }

    func testAllowsTheWriteWhenTheTargetIsNotTheOnDiskActiveFilter() throws {
        let urls = makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.config.deletingLastPathComponent()) }
        try JSONEncoder().encode(library(generation: 4)).write(to: urls.library) // active == f1

        let written = try SharedFilterStatePersistence.writeConfigurationAndLibrary(
            configuration: config(generation: 4),
            library: library(generation: 4),
            configurationURL: urls.config,
            filterLibraryURL: urls.library,
            refusesIfOnDiskActiveFilterIs: "f2"   // replacing an idle filter
        )
        XCTAssertEqual(written.configuration.configurationGeneration, 5)
    }

    /// Absent precondition must behave exactly as before for every existing caller.
    func testOmittingThePreconditionLeavesTheWriteUnchanged() throws {
        let urls = makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.config.deletingLastPathComponent()) }
        try JSONEncoder().encode(library(generation: 4, activeFilterID: "f2")).write(to: urls.library)

        // The same state that the precondition refuses is written happily without it.
        let written = try SharedFilterStatePersistence.writeConfigurationAndLibrary(
            configuration: config(generation: 4),
            library: library(generation: 4),
            configurationURL: urls.config,
            filterLibraryURL: urls.library
        )
        XCTAssertEqual(written.configuration.configurationGeneration, 5)
    }

    /// An unreadable library must not read as "not the active filter" and let the write through.
    func testUnreadableLibraryDoesNotSatisfyThePrecondition() throws {
        let urls = makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.config.deletingLastPathComponent()) }
        // No library file at all: onDiskActiveFilterID is nil, so the precondition cannot match and
        // the write proceeds — the caller's own in-memory guard is what covers this case, and the
        // INV-PERSIST-1 fence covers the exists-but-unreadable one.
        let written = try SharedFilterStatePersistence.writeConfigurationAndLibrary(
            configuration: config(generation: 1),
            library: library(generation: 1),
            configurationURL: urls.config,
            filterLibraryURL: urls.library,
            refusesIfOnDiskActiveFilterIs: "f1"
        )
        XCTAssertEqual(written.configuration.configurationGeneration, 2)
    }

    func testRejectsAdvancedBeyondWhenOnDiskAdvancedPastFence() throws {
        let urls = makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.config.deletingLastPathComponent()) }
        // On-disk advanced to generation 5 (a concurrent writer won); the caller fences against its base 3.
        try JSONEncoder().encode(config(generation: 5)).write(to: urls.config)

        XCTAssertThrowsError(
            try SharedFilterStatePersistence.writeConfigurationAndLibrary(
                configuration: config(generation: 3),
                library: library(generation: 3),
                configurationURL: urls.config,
                filterLibraryURL: urls.library,
                rejectsAdvancedBeyond: 3
            )
        ) { error in
            XCTAssertTrue(error is SharedFilterStatePersistence.StaleBaseGenerationError,
                          "An on-disk generation past the fence must abort with StaleBaseGenerationError.")
        }
        // The on-disk config (the newer writer's) must be untouched — never clobbered or re-bumped.
        let onDisk = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: urls.config))
        XCTAssertEqual(onDisk.configurationGeneration, 5)
    }

    func testStaleIdleEditCannotSwitchDiskBackFromAThirdFilter() throws {
        let urls = makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.config.deletingLastPathComponent()) }

        func threeFilterLibrary(generation: Int, active: String, editedB: Bool) -> FilterLibrary {
            var result = FilterLibrary(
                filters: [
                    Filter(id: "a", name: "A", enabledBlocklistIDs: ["a-source"]),
                    Filter(
                        id: "b",
                        name: "B",
                        enabledBlocklistIDs: [editedB ? "b-edited-source" : "b-source"]
                    ),
                    Filter(id: "c", name: "C", enabledBlocklistIDs: ["c-source"]),
                ],
                activeFilterID: active
            )
            result.configurationGeneration = generation
            return result
        }

        // A headless process switched disk A → C while the resident app still held A. That app
        // then edits idle B. The target-only `refusesIf...: B` check correctly passes because C is
        // active, so the reciprocal generation fence is what must stop its stale whole pair from
        // switching disk C → A and clobbering C's committed selection.
        try JSONEncoder().encode(config(generation: 9)).write(to: urls.config)
        try JSONEncoder().encode(
            threeFilterLibrary(generation: 9, active: "c", editedB: false)
        ).write(to: urls.library)

        XCTAssertThrowsError(
            try SharedFilterStatePersistence.writeConfigurationAndLibrary(
                configuration: config(generation: 8),
                library: threeFilterLibrary(generation: 8, active: "a", editedB: true),
                configurationURL: urls.config,
                filterLibraryURL: urls.library,
                rejectsAdvancedBeyond: 8,
                refusesIfOnDiskActiveFilterIs: "b"
            )
        ) { error in
            XCTAssertTrue(error is SharedFilterStatePersistence.StaleBaseGenerationError)
        }

        let survivingConfiguration = try JSONDecoder().decode(
            AppConfiguration.self,
            from: Data(contentsOf: urls.config)
        )
        let survivingLibrary = try JSONDecoder().decode(
            FilterLibrary.self,
            from: Data(contentsOf: urls.library)
        )
        XCTAssertEqual(survivingConfiguration.configurationGeneration, 9)
        XCTAssertEqual(survivingLibrary.activeFilterID, "c")
        XCTAssertEqual(survivingLibrary.filter(id: "b")?.enabledBlocklistIDs, ["b-source"])
    }

    func testAcceptsOnDiskEqualToFence() throws {
        let urls = makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.config.deletingLastPathComponent()) }
        // On-disk == the fence (5): not advanced ⇒ the write proceeds and bumps to 6.
        try JSONEncoder().encode(config(generation: 5)).write(to: urls.config)
        let written = try SharedFilterStatePersistence.writeConfigurationAndLibrary(
            configuration: config(generation: 5),
            library: library(generation: 5),
            configurationURL: urls.config,
            filterLibraryURL: urls.library,
            rejectsAdvancedBeyond: 5
        )
        XCTAssertEqual(written.configuration.configurationGeneration, 6)
    }

    /// The headless rollback fences against the generation IT JUST WROTE (`expectedBaseGeneration` →
    /// `rejectsAdvancedBeyond`): it reverts ONLY its own write, and aborts (leaving the newer state) if a
    /// foreground writer advanced past it in the gap between the config write and the rollback (panel P1).
    func testRollbackFenceRevertsOwnWriteButLeavesANewerForeignWrite() throws {
        let urls = makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.config.deletingLastPathComponent()) }

        // Our commit wrote generation 7. No foreign writer since ⇒ rolling back (writing the previous, lower
        // base) fenced at 7 proceeds and bumps to 8.
        try JSONEncoder().encode(config(generation: 7)).write(to: urls.config)
        let reverted = try SharedFilterStatePersistence.writeConfigurationAndLibrary(
            configuration: config(generation: 2),    // the previous (lower) selection being restored
            library: library(generation: 2),
            configurationURL: urls.config,
            filterLibraryURL: urls.library,
            rejectsAdvancedBeyond: 7                  // == the generation our commit wrote
        )
        XCTAssertEqual(reverted.configuration.configurationGeneration, 8,
                       "With no foreign advance, the rollback reverts our own write (bumps past it).")

        // Now a foreground writer advances on-disk to 9. A rollback still fenced at 7 must ABORT and leave 9.
        try JSONEncoder().encode(config(generation: 9)).write(to: urls.config)
        XCTAssertThrowsError(
            try SharedFilterStatePersistence.writeConfigurationAndLibrary(
                configuration: config(generation: 2),
                library: library(generation: 2),
                configurationURL: urls.config,
                filterLibraryURL: urls.library,
                rejectsAdvancedBeyond: 7
            )
        ) { error in
            XCTAssertTrue(error is SharedFilterStatePersistence.StaleBaseGenerationError,
                          "A rollback must abort when a foreign writer advanced past the generation it wrote.")
        }
        let onDisk = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: urls.config))
        XCTAssertEqual(onDisk.configurationGeneration, 9, "The newer foreign write must survive the aborted rollback.")
    }

    func testBumpsFromInMemoryWhenNoOnDiskConfig() throws {
        let urls = makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.config.deletingLastPathComponent()) }

        let written = try SharedFilterStatePersistence.writeConfigurationAndLibrary(
            configuration: config(generation: 9),
            library: library(generation: 9),
            configurationURL: urls.config,
            filterLibraryURL: urls.library
        )
        // No on-disk config (onDiskConfigurationGeneration == 0) ⇒ one past in-memory 9 = 10.
        XCTAssertEqual(written.configuration.configurationGeneration, 10)
    }

    func testOnDiskConfigurationGenerationReadsZeroWhenMissing() {
        let urls = makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.config.deletingLastPathComponent()) }
        XCTAssertEqual(SharedFilterStatePersistence.onDiskConfigurationGeneration(at: urls.config), 0)
    }

    // INV-PERSIST-1 writer fence: an EXISTING file whose content cannot be read (Data
    // Protection before first unlock on device; permission-denied here, same failing read +
    // intact metadata) must abort the pair write — the caller's in-memory values came from a
    // failed read, and writing them would replace the user's intact data at a winning
    // generation (the 2026-07-14 reboot wipe). RED against the pre-fence writer, which
    // happily replaced the locked file.
    func testWriteRefusesToReplaceExistingUnreadableConfig() throws {
        try XCTSkipIf(geteuid() == 0, "chmod-based unreadable fixture requires a non-root user")
        let urls = makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.config.deletingLastPathComponent()) }

        let seeded = try JSONEncoder().encode(config(generation: 5))
        try seeded.write(to: urls.config)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: urls.config.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: urls.config.path) }

        XCTAssertThrowsError(
            try SharedFilterStatePersistence.writeConfigurationAndLibrary(
                configuration: config(generation: 0), // the "seeded defaults" a blocked load holds
                library: library(generation: 0),
                configurationURL: urls.config,
                filterLibraryURL: urls.library
            )
        ) { error in
            XCTAssertTrue(error is SharedFilterStatePersistence.ExistingStateUnreadableError,
                          "Replacing an existing-but-unreadable config must abort with ExistingStateUnreadableError.")
        }

        // Neither file may have been touched: the locked config's original bytes survive, and
        // the library (written FIRST on the normal path) must not exist — proving the fence
        // runs before any write.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: urls.config.path)
        XCTAssertEqual(try Data(contentsOf: urls.config), seeded, "The locked config must survive byte-identical.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls.library.path),
                       "The library write must not land when the pair's config is unreadable.")
    }

    func testWriteRefusesToReplaceExistingUnreadableLibrary() throws {
        try XCTSkipIf(geteuid() == 0, "chmod-based unreadable fixture requires a non-root user")
        let urls = makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.config.deletingLastPathComponent()) }

        let seededLibrary = try JSONEncoder().encode(library(generation: 5))
        try seededLibrary.write(to: urls.library)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: urls.library.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: urls.library.path) }

        XCTAssertThrowsError(
            try SharedFilterStatePersistence.writeConfigurationAndLibrary(
                configuration: config(generation: 0),
                library: library(generation: 0),
                configurationURL: urls.config,
                filterLibraryURL: urls.library
            )
        ) { error in
            XCTAssertTrue(error is SharedFilterStatePersistence.ExistingStateUnreadableError,
                          "Replacing an existing-but-unreadable library must abort with ExistingStateUnreadableError.")
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: urls.library.path)
        XCTAssertEqual(try Data(contentsOf: urls.library), seededLibrary, "The locked library must survive byte-identical.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls.config.path),
                       "The config write must not land when the pair's library is unreadable.")
    }

    func testRoundTripIsRepeatableAndStaysMonotonic() throws {
        let urls = makeURLs()
        defer { try? FileManager.default.removeItem(at: urls.config.deletingLastPathComponent()) }

        var cfg = config(generation: 0)
        var lib = library(generation: 0)
        for expected in 1...3 {
            let written = try SharedFilterStatePersistence.writeConfigurationAndLibrary(
                configuration: cfg, library: lib, configurationURL: urls.config, filterLibraryURL: urls.library
            )
            XCTAssertEqual(written.configuration.configurationGeneration, expected)
            XCTAssertEqual(written.library.configurationGeneration, expected)
            cfg = written.configuration
            lib = written.library
        }
    }
}
