import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class FilterLibraryTests: XCTestCase {

    // MARK: - Filter codec + decode tolerance

    func testFilterCodecRoundTripPreservesAllFields() throws {
        let source = try CustomBlocklistSource(
            id: "custom-1",
            displayName: "Sample",
            rawURL: "https://example.com/list.txt"
        )
        let filter = Filter(
            id: "f1",
            name: "Focus",
            enabledBlocklistIDs: ["a", "b"],
            customBlocklists: [source],
            blockedDomains: ["casino.example"],
            allowedDomains: ["school.example"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastCompiledToken: "fingerprint-123",
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )

        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(Filter.self, from: data)

        XCTAssertEqual(decoded, filter)
        XCTAssertEqual(decoded.lastCompiledToken, "fingerprint-123")
        XCTAssertEqual(decoded.lastSyncedAt, Date(timeIntervalSince1970: 1_700_000_500))
    }

    func testFilterDecodeFillsMissingFieldsWithSafeDefaults() throws {
        // A minimal payload (only id + the four fields absent) must decode, not throw.
        let json = #"{"id":"f9"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Filter.self, from: json)

        XCTAssertEqual(decoded.id, "f9")
        XCTAssertEqual(decoded.name, Filter.defaultFilterName) // blank/missing ⇒ "Default"
        XCTAssertTrue(decoded.enabledBlocklistIDs.isEmpty)
        XCTAssertTrue(decoded.customBlocklists.isEmpty)
        XCTAssertTrue(decoded.blockedDomains.isEmpty)
        XCTAssertTrue(decoded.allowedDomains.isEmpty)
        XCTAssertNil(decoded.lastCompiledToken)
        XCTAssertNil(decoded.lastSyncedAt)
    }

    func testFilterNameFallsBackToDefaultWhenBlank() {
        XCTAssertEqual(Filter(name: "   ").name, Filter.defaultFilterName)
        XCTAssertEqual(Filter(name: "").name, Filter.defaultFilterName)
        XCTAssertEqual(Filter(name: "  Focus  ").name, "Focus") // trims, keeps content
    }

    func testFilterIsEmptyReflectsZeroProtection() throws {
        XCTAssertTrue(Filter().isEmpty)
        XCTAssertFalse(Filter(enabledBlocklistIDs: ["a"]).isEmpty)
        XCTAssertFalse(Filter(blockedDomains: ["x.example"]).isEmpty)
        // A custom list counts ONLY when enabled (its id is in enabledBlocklistIDs).
        // A saved-but-disabled custom source blocks nothing → still empty.
        let source = try CustomBlocklistSource(id: "custom-x", displayName: "S", rawURL: "https://example.com/l.txt")
        XCTAssertTrue(Filter(customBlocklists: [source]).isEmpty, "disabled custom source = zero protection")
        XCTAssertFalse(Filter(enabledBlocklistIDs: ["custom-x"], customBlocklists: [source]).isEmpty,
                       "an enabled custom list blocks")
        // Allowed-only is still empty: an exception with nothing to except is 0 rules.
        XCTAssertTrue(Filter(allowedDomains: ["ok.example"]).isEmpty)
    }

    func testApplyFilterFieldsReportsChangeAndCopiesFourFields() {
        var filter = Filter(enabledBlocklistIDs: ["a"])
        let config = AppConfiguration(
            enabledBlocklistIDs: ["a", "b"],
            allowedDomains: ["ok.example"],
            blockedDomains: ["bad.example"]
        )
        XCTAssertTrue(filter.applyFilterFields(from: config))
        XCTAssertEqual(filter.enabledBlocklistIDs, ["a", "b"])
        XCTAssertEqual(filter.blockedDomains, ["bad.example"])
        XCTAssertEqual(filter.allowedDomains, ["ok.example"])
        // A second apply of identical fields is a no-op (so callers don't churn tokens).
        XCTAssertFalse(filter.applyFilterFields(from: config))
    }

    // MARK: - Migration

    func testMigratingLegacyWrapsConfigIntoSingleDefaultFilter() {
        let config = AppConfiguration(
            enabledBlocklistIDs: ["blocklistproject-basic"],
            allowedDomains: ["school.example"],
            blockedDomains: ["casino.example"]
        )
        let library = FilterLibrary(migratingLegacy: config)

        XCTAssertEqual(library.filters.count, 1)
        XCTAssertEqual(library.activeFilterID, Filter.defaultFilterID)
        let only = library.activeFilter
        XCTAssertEqual(only.id, Filter.defaultFilterID)
        XCTAssertEqual(only.name, Filter.defaultFilterName)
        XCTAssertEqual(only.enabledBlocklistIDs, ["blocklistproject-basic"])
        XCTAssertEqual(only.blockedDomains, ["casino.example"])
        XCTAssertEqual(only.allowedDomains, ["school.example"])
        XCTAssertTrue(library.isValid)
    }

    // MARK: - Invariants

    func testLibraryIsValidRequiresAtLeastOneFilterAndResolvableActive() {
        let f = Filter(id: "f1")
        XCTAssertTrue(FilterLibrary(filters: [f], activeFilterID: "f1").isValid)
        XCTAssertFalse(FilterLibrary(filters: [f], activeFilterID: "missing").isValid)
        XCTAssertFalse(FilterLibrary(filters: [], activeFilterID: "f1").isValid)
    }

    func testNormalizedRepointsDanglingActiveToFirstFilter() {
        let library = FilterLibrary(filters: [Filter(id: "f1"), Filter(id: "f2")], activeFilterID: "gone")
        XCTAssertFalse(library.isValid)
        let normalized = library.normalized()
        XCTAssertTrue(normalized.isValid)
        XCTAssertEqual(normalized.activeFilterID, "f1")
    }

    func testActiveFilterNeverNilEvenWhenDangling() {
        let library = FilterLibrary(filters: [Filter(id: "f1", name: "One")], activeFilterID: "gone")
        XCTAssertEqual(library.activeFilter.id, "f1") // falls back to first
    }

    // MARK: - Mutations preserve invariants

    func testRemoveRefusesActiveAndLastFilter() {
        var library = FilterLibrary(filters: [Filter(id: "f1"), Filter(id: "f2")], activeFilterID: "f1")
        XCTAssertFalse(library.remove(id: "f1"), "must not delete the in-effect filter")
        XCTAssertTrue(library.remove(id: "f2"))
        XCTAssertFalse(library.remove(id: "f1"), "must not delete the last remaining filter")
        XCTAssertEqual(library.filters.count, 1)
        XCTAssertTrue(library.isValid)
    }

    func testSetActiveFilterRejectsUnknownID() {
        var library = FilterLibrary(filters: [Filter(id: "f1"), Filter(id: "f2")], activeFilterID: "f1")
        library.setActiveFilter(id: "nope")
        XCTAssertEqual(library.activeFilterID, "f1")
        library.setActiveFilter(id: "f2")
        XCTAssertEqual(library.activeFilterID, "f2")
    }

    func testAppendIsDeduplicatedByID() {
        var library = FilterLibrary(filters: [Filter(id: "f1")], activeFilterID: "f1")
        library.append(Filter(id: "f1", name: "Dupe"))
        XCTAssertEqual(library.filters.count, 1)
        library.append(Filter(id: "f2"))
        XCTAssertEqual(library.filters.count, 2)
    }

    func testMutateFilterEditsInPlaceByID() {
        var library = FilterLibrary(filters: [Filter(id: "f1"), Filter(id: "f2")], activeFilterID: "f1")
        library.mutateFilter(id: "f2") { $0.lastCompiledToken = "tok-2" }
        XCTAssertEqual(library.filter(id: "f2")?.lastCompiledToken, "tok-2")
        XCTAssertNil(library.filter(id: "f1")?.lastCompiledToken)
    }

    // MARK: - Library codec + decode tolerance

    func testLibraryCodecRoundTrip() throws {
        let library = FilterLibrary(
            filters: [Filter(id: "f1", name: "One"), Filter(id: "f2", name: "Two")],
            activeFilterID: "f2"
        )
        let data = try JSONEncoder().encode(library)
        let decoded = try JSONDecoder().decode(FilterLibrary.self, from: data)
        XCTAssertEqual(decoded, library)
        XCTAssertEqual(decoded.schemaVersion, FilterLibrary.currentSchemaVersion)
    }

    func testLibraryDecodeDefaultsActiveToFirstWhenMissing() throws {
        let json = #"{"filters":[{"id":"f1"},{"id":"f2"}]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FilterLibrary.self, from: json)
        XCTAssertEqual(decoded.activeFilterID, "f1")
        XCTAssertEqual(decoded.schemaVersion, FilterLibrary.currentSchemaVersion)
    }

    // MARK: - Write-race generation marker

    func testLibraryCodecRoundTripsConfigurationGeneration() throws {
        var library = FilterLibrary(filters: [Filter(id: "f1", name: "One")], activeFilterID: "f1")
        library.configurationGeneration = 42
        let decoded = try JSONDecoder().decode(FilterLibrary.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(decoded.configurationGeneration, 42)
        XCTAssertEqual(decoded, library)

        // A pre-stamping library file (no key) decodes to generation 0.
        let legacy = try JSONDecoder().decode(
            FilterLibrary.self,
            from: #"{"filters":[{"id":"f1"}],"activeFilterID":"f1"}"#.data(using: .utf8)!
        )
        XCTAssertEqual(legacy.configurationGeneration, 0)
    }

    func testLostWriteRaceRejectsOnlyAStaleStampedLibrary() {
        let base = FilterLibrary(filters: [Filter(id: "f1", name: "One")], activeFilterID: "f1")

        // Stamped OLDER than the config on disk → it lost the race (its paired config write landed
        // but this library write didn't): stale, reject in favour of the config.
        var stale = base
        stale.configurationGeneration = 3
        XCTAssertTrue(stale.lostWriteRace(againstConfigurationGeneration: 5))

        // Stamped equal (consistent) or newer (a library write that landed while its config didn't)
        // → authoritative, never rejected.
        var equal = base
        equal.configurationGeneration = 5
        XCTAssertFalse(equal.lostWriteRace(againstConfigurationGeneration: 5))
        var newer = base
        newer.configurationGeneration = 7
        XCTAssertFalse(newer.lostWriteRace(againstConfigurationGeneration: 5))

        // Generation 0 (a pre-stamping library) is trusted — rejecting it would needlessly collapse
        // an existing multi-filter library on upgrade.
        XCTAssertFalse(base.lostWriteRace(againstConfigurationGeneration: 5))
    }

    func testStrippingLocalCacheStateZeroesTheConfigurationGeneration() {
        var library = FilterLibrary(filters: [Filter(id: "f1", name: "One")], activeFilterID: "f1")
        library.configurationGeneration = 9
        XCTAssertEqual(library.strippingLocalCacheState().configurationGeneration, 0,
                       "The write-race generation is device-local and must not enter a backup.")
    }

    // MARK: - Backup payload carries the whole library

    func testBackupPayloadRoundTripsTheFilterLibrary() throws {
        let library = FilterLibrary(
            filters: [Filter(id: "f1", name: "One", enabledBlocklistIDs: ["a"]),
                      Filter(id: "f2", name: "Two", blockedDomains: ["x.example"])],
            activeFilterID: "f2"
        )
        let config = AppConfiguration(enabledBlocklistIDs: ["a"], blockedDomains: ["x.example"])

        let payload = BackupConfigurationPayload(configuration: config, filterLibrary: library)
        let decoded = try JSONDecoder().decode(
            BackupConfigurationPayload.self,
            from: JSONEncoder().encode(payload)
        )
        XCTAssertEqual(decoded.restoredFilterLibrary(), library,
                       "Every hosted filter must survive a backup round-trip, not just the active one.")

        // A pre-multi-filter backup carries no library and decodes to nil (caller migrates).
        let legacyJSON = """
        {"schemaVersion":1,"enabledBlocklistIDs":["a"],"allowedDomains":[],"blockedDomains":["x.example"],
         "resolverPresetID":"mullvad-doh","keepDomainDiagnostics":true,"protectionEnabledHint":true}
        """.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(BackupConfigurationPayload.self, from: legacyJSON)
        XCTAssertNil(legacy.restoredFilterLibrary())
    }
}
