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
