import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// Behavioural harness for the encrypted-backup currency invariants: which changes re-seal a
/// backup (and clear its "uploaded" marker) and which must NOT. These exercise the pure logic
/// the reseal path in `AppViewModel.refreshLocalEncryptedBackupEnvelope` delegates to —
/// `BackupConfigurationPayload.hasSameBackupContent(as:)` plus the cache-state stripping — so
/// the "a protection toggle / compile-token restamp must not churn the upload marker" rule is
/// executed rather than only asserted in source.
final class BackupCurrencyTests: XCTestCase {

    private func makeFilter(
        id: String,
        name: String,
        enabled: Set<String> = ["blocklistproject-basic"],
        blocked: Set<String> = ["casino.example"],
        lastCompiledToken: String? = nil,
        lastSyncedAt: Date? = nil
    ) -> Filter {
        Filter(
            id: id,
            name: name,
            enabledBlocklistIDs: enabled,
            blockedDomains: blocked,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastCompiledToken: lastCompiledToken,
            lastSyncedAt: lastSyncedAt
        )
    }

    private func makeConfiguration(
        protectionEnabled: Bool = true,
        enabled: Set<String> = ["blocklistproject-basic"],
        blocked: Set<String> = ["casino.example"],
        resolverPresetID: String = DNSResolverPreset.cloudflareDoH.id
    ) -> AppConfiguration {
        AppConfiguration(
            protectionEnabled: protectionEnabled,
            enabledBlocklistIDs: enabled,
            blockedDomains: blocked,
            resolverPresetID: resolverPresetID,
            keepDomainDiagnostics: true
        )
    }

    // MARK: - Cache-state stripping

    func testStrippingLocalCacheStateClearsTokensButKeepsContent() {
        let filter = makeFilter(
            id: "f1",
            name: "Focus",
            lastCompiledToken: "fingerprint-abc",
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        let stripped = filter.strippingLocalCacheState()

        XCTAssertNil(stripped.lastCompiledToken)
        XCTAssertNil(stripped.lastSyncedAt)
        // Everything that defines the filter is preserved.
        XCTAssertEqual(stripped.id, filter.id)
        XCTAssertEqual(stripped.name, filter.name)
        XCTAssertEqual(stripped.enabledBlocklistIDs, filter.enabledBlocklistIDs)
        XCTAssertEqual(stripped.blockedDomains, filter.blockedDomains)
        XCTAssertEqual(stripped.createdAt, filter.createdAt)
    }

    func testLibraryStrippingClearsEveryFilterAndKeepsActiveID() {
        let library = FilterLibrary(
            filters: [
                makeFilter(id: "f1", name: "Focus", lastCompiledToken: "t1", lastSyncedAt: Date()),
                makeFilter(id: "f2", name: "Travel", lastCompiledToken: "t2", lastSyncedAt: Date())
            ],
            activeFilterID: "f2"
        )
        let stripped = library.strippingLocalCacheState()

        XCTAssertEqual(stripped.activeFilterID, "f2")
        XCTAssertEqual(stripped.filters.count, 2)
        XCTAssertTrue(stripped.filters.allSatisfy { $0.lastCompiledToken == nil && $0.lastSyncedAt == nil })
    }

    func testPayloadStripsLibraryCacheTokensAtConstruction() {
        let library = FilterLibrary(
            filters: [makeFilter(id: "f1", name: "Focus", lastCompiledToken: "warm-dir", lastSyncedAt: Date())],
            activeFilterID: "f1"
        )
        let payload = BackupConfigurationPayload(configuration: makeConfiguration(), filterLibrary: library)

        let carried = payload.filterLibrary?.filters.first
        XCTAssertNotNil(carried)
        XCTAssertNil(carried?.lastCompiledToken, "Compile tokens are device-local and must not enter a backup.")
        XCTAssertNil(carried?.lastSyncedAt)
    }

    // MARK: - hasSameBackupContent: what does NOT re-seal

    func testCompileTokenOnlyChangeIsSameContent() {
        // Two libraries identical except a hosted filter's compile token: the maintenance persist
        // that restamps the token must look like NO content change (no re-seal, no marker churn).
        let warm = FilterLibrary(
            filters: [makeFilter(id: "f1", name: "Focus", lastCompiledToken: "old")],
            activeFilterID: "f1"
        )
        let recompiled = FilterLibrary(
            filters: [makeFilter(id: "f1", name: "Focus", lastCompiledToken: "new")],
            activeFilterID: "f1"
        )
        let a = BackupConfigurationPayload(configuration: makeConfiguration(), filterLibrary: warm)
        let b = BackupConfigurationPayload(configuration: makeConfiguration(), filterLibrary: recompiled)

        XCTAssertEqual(a, b, "Cache tokens are stripped, so the payloads are byte-identical.")
        XCTAssertTrue(a.hasSameBackupContent(as: b))
    }

    func testProtectionToggleOnlyIsSameContent() {
        // Toggling protection (pause/resume, Live Activity button) is a frequent, advisory-only
        // change: it must NOT re-seal and flip an uploaded backup to "not uploaded".
        let library = FilterLibrary(filters: [makeFilter(id: "f1", name: "Focus")], activeFilterID: "f1")
        let on = BackupConfigurationPayload(
            configuration: makeConfiguration(protectionEnabled: true), filterLibrary: library
        )
        let off = BackupConfigurationPayload(
            configuration: makeConfiguration(protectionEnabled: false), filterLibrary: library
        )

        XCTAssertNotEqual(on.protectionEnabledHint, off.protectionEnabledHint, "The hint itself differs…")
        XCTAssertTrue(on.hasSameBackupContent(as: off), "…but content comparison ignores it, so no re-seal.")
    }

    // MARK: - hasSameBackupContent: what DOES re-seal

    func testFilterSelectionChangeIsDifferentContent() {
        let before = FilterLibrary(
            filters: [makeFilter(id: "f1", name: "Focus", enabled: ["blocklistproject-basic"])],
            activeFilterID: "f1"
        )
        let after = FilterLibrary(
            filters: [makeFilter(id: "f1", name: "Focus", enabled: ["blocklistproject-basic", "oisd-small"])],
            activeFilterID: "f1"
        )
        let a = BackupConfigurationPayload(
            configuration: makeConfiguration(enabled: ["blocklistproject-basic"]), filterLibrary: before
        )
        let b = BackupConfigurationPayload(
            configuration: makeConfiguration(enabled: ["blocklistproject-basic", "oisd-small"]), filterLibrary: after
        )

        XCTAssertFalse(a.hasSameBackupContent(as: b), "A real blocklist change must re-seal.")
    }

    func testResolverChangeIsDifferentContent() {
        let library = FilterLibrary(filters: [makeFilter(id: "f1", name: "Focus")], activeFilterID: "f1")
        let a = BackupConfigurationPayload(
            configuration: makeConfiguration(resolverPresetID: DNSResolverPreset.cloudflareDoH.id),
            filterLibrary: library
        )
        let b = BackupConfigurationPayload(
            configuration: makeConfiguration(resolverPresetID: DNSResolverPreset.mullvadDoH.id),
            filterLibrary: library
        )

        XCTAssertFalse(a.hasSameBackupContent(as: b), "A resolver change is real restorable content.")
    }

    func testAddingAHostedFilterIsDifferentContent() {
        let single = FilterLibrary(filters: [makeFilter(id: "f1", name: "Focus")], activeFilterID: "f1")
        let twoFilters = FilterLibrary(
            filters: [makeFilter(id: "f1", name: "Focus"), makeFilter(id: "f2", name: "Travel")],
            activeFilterID: "f1"
        )
        let a = BackupConfigurationPayload(configuration: makeConfiguration(), filterLibrary: single)
        let b = BackupConfigurationPayload(configuration: makeConfiguration(), filterLibrary: twoFilters)

        XCTAssertFalse(a.hasSameBackupContent(as: b), "A new hosted filter must back up.")
    }

    // MARK: - Restore migrates EVERY hosted filter's known custom blocklists

    /// A curated source whose URL the matcher recognises, used to prove a custom list pinned to
    /// that URL migrates back to the catalog id on restore. Derived from the catalog so it stays
    /// valid if the curated set changes.
    private func knownCatalogSourceFixture() throws -> (catalogID: String, rawURL: String) {
        for source in DefaultCatalog.curatedSources {
            if let catalogID = KnownBlocklistURLMatcher.catalogSourceID(for: source.sourceURL),
               catalogID == source.id {
                return (catalogID, source.sourceURL.absoluteString)
            }
        }
        throw XCTSkip("No curated source canonicalises to a matcher key in this catalog build.")
    }

    func testRestoreMigratesKnownCustomBlocklistsInEveryFilter() throws {
        let fixture = try knownCatalogSourceFixture()
        let pinnedActive = try CustomBlocklistSource(
            id: "custom-active", displayName: "Pinned (active)", rawURL: fixture.rawURL
        )
        let pinnedHosted = try CustomBlocklistSource(
            id: "custom-hosted", displayName: "Pinned (hosted)", rawURL: fixture.rawURL
        )

        let library = FilterLibrary(
            filters: [
                Filter(
                    id: "active", name: "Active",
                    enabledBlocklistIDs: [pinnedActive.id],
                    customBlocklists: [pinnedActive]
                ),
                Filter(
                    id: "hosted", name: "Hosted",
                    enabledBlocklistIDs: [pinnedHosted.id],
                    customBlocklists: [pinnedHosted]
                )
            ],
            activeFilterID: "active"
        )

        let migrated = library.migratingKnownCustomBlocklistsToCatalogSources()

        for filter in migrated.filters {
            XCTAssertTrue(
                filter.customBlocklists.isEmpty,
                "The known custom list should be dropped from \(filter.id)."
            )
            XCTAssertTrue(
                filter.enabledBlocklistIDs.contains(fixture.catalogID),
                "The catalog id should replace the custom id in \(filter.id)'s enabled set."
            )
            XCTAssertFalse(filter.enabledBlocklistIDs.contains("custom-active"))
            XCTAssertFalse(filter.enabledBlocklistIDs.contains("custom-hosted"))
        }
        XCTAssertEqual(migrated.activeFilterID, "active", "Migration preserves the active pointer + order.")
    }

    func testMigrationLeavesUnknownCustomListsUntouched() throws {
        let unknown = try CustomBlocklistSource(
            id: "custom-unknown", displayName: "Private", rawURL: "https://private.example.com/list.txt"
        )
        let library = FilterLibrary(
            filters: [
                Filter(
                    id: "f1", name: "Focus",
                    enabledBlocklistIDs: [unknown.id],
                    customBlocklists: [unknown]
                )
            ],
            activeFilterID: "f1"
        )

        let migrated = library.migratingKnownCustomBlocklistsToCatalogSources()
        let filter = try XCTUnwrap(migrated.filter(id: "f1"))
        XCTAssertEqual(filter.customBlocklists, [unknown], "An unrecognised custom list is left in place.")
        XCTAssertTrue(filter.enabledBlocklistIDs.contains(unknown.id))
    }
}
