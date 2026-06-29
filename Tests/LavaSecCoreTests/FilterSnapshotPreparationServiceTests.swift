import XCTest
@testable import LavaSecCore

final class FilterSnapshotPreparationServiceTests: XCTestCase {
    private let payloadText = "ads.example.com\ntracker.example.net\n"

    func testFreshCachePrepareUsesCachedPayloadsWithoutNetwork() async throws {
        let fixture = try Fixture(payloadText: payloadText)
        _ = try await fixture.fetchingService().prepare(
            configuration: fixture.configuration,
            customSources: [],
            catalogFreshnessMaxAge: 3_600
        )

        // Second prepare: network unavailable, catalog cache fresh.
        let offline = fixture.offlineService()
        let result = try await offline.prepare(
            configuration: fixture.configuration,
            customSources: [],
            catalogFreshnessMaxAge: 3_600
        )

        XCTAssertEqual(result.snapshot.summary.blocklistRuleCount, 2)
        XCTAssertTrue(result.catalogResult.usedCachedSourceIDs.contains("source-a"))
        XCTAssertEqual(result.snapshot.summary.blocklistSourceRuleCounts?["source-a"], 2)
    }

    func testStaleCachePrefersNetworkAndFallsBackToCacheWhenOffline() async throws {
        let fixture = try Fixture(payloadText: payloadText)
        _ = try await fixture.fetchingService().prepare(
            configuration: fixture.configuration,
            customSources: [],
            catalogFreshnessMaxAge: 3_600
        )

        // maxAge 0 marks the cache stale: the ladder tries the network first
        // and must fall back to cached payloads when it fails.
        let offline = fixture.offlineService()
        let result = try await offline.prepare(
            configuration: fixture.configuration,
            customSources: [],
            catalogFreshnessMaxAge: 0
        )

        XCTAssertEqual(result.snapshot.summary.blocklistRuleCount, 2)
        XCTAssertTrue(result.catalogResult.usedCachedSourceIDs.contains("source-a"))
    }

    func testPrepareRejectsConfigurationOverDeviceBudget() async throws {
        let fixture = try Fixture(payloadText: payloadText)
        // Prime the cache so the offline prepare reaches the merge/budget stage.
        _ = try await fixture.fetchingService().prepare(
            configuration: fixture.configuration,
            customSources: [],
            catalogFreshnessMaxAge: 3_600
        )

        do {
            // source-a compiles to 2 rules; a device budget of 1 forces a rejection.
            _ = try await fixture.offlineService().prepare(
                configuration: fixture.configuration,
                customSources: [],
                catalogFreshnessMaxAge: 3_600,
                maxDeviceRuleCount: 1
            )
            XCTFail("Over-budget configuration must be rejected before building the snapshot.")
        } catch let error as FilterSnapshotPreparationError {
            guard case let .exceedsDeviceMemoryBudget(ruleCount, maxRuleCount, perSource) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertGreaterThan(ruleCount, maxRuleCount)
            XCTAssertEqual(maxRuleCount, 1)
            XCTAssertEqual(perSource["source-a"], 2)
            XCTAssertNotNil(error.errorDescription)
        }
    }

    func testPrepareRejectsConfigurationOverTierLimitButUnderDeviceBudget() async throws {
        let fixture = try Fixture(payloadText: payloadText)
        _ = try await fixture.fetchingService().prepare(
            configuration: fixture.configuration,
            customSources: [],
            catalogFreshnessMaxAge: 3_600
        )

        do {
            // source-a compiles to 2 rules: under the device budget (1_000) but
            // over the tier limit (1) → a tier error, not a device error.
            _ = try await fixture.offlineService().prepare(
                configuration: fixture.configuration,
                customSources: [],
                catalogFreshnessMaxAge: 3_600,
                maxDeviceRuleCount: 1_000,
                tierRuleLimit: FilterRuleTierLimit(limit: 1, isPaid: false)
            )
            XCTFail("Over-tier configuration must be rejected before building the snapshot.")
        } catch let error as FilterSnapshotPreparationError {
            guard case let .exceedsTierFilterRuleLimit(ruleCount, limitRuleCount, isPaid, perSource) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertGreaterThan(ruleCount, limitRuleCount)
            XCTAssertEqual(limitRuleCount, 1)
            XCTAssertFalse(isPaid)
            XCTAssertEqual(perSource["source-a"], 2)
            XCTAssertNotNil(error.errorDescription)
        }
    }

    func testDeviceBudgetTakesPriorityOverTierLimitWhenBothExceeded() async throws {
        let fixture = try Fixture(payloadText: payloadText)
        _ = try await fixture.fetchingService().prepare(
            configuration: fixture.configuration,
            customSources: [],
            catalogFreshnessMaxAge: 3_600
        )

        do {
            // Over both caps → the device (hard) error wins.
            _ = try await fixture.offlineService().prepare(
                configuration: fixture.configuration,
                customSources: [],
                catalogFreshnessMaxAge: 3_600,
                maxDeviceRuleCount: 1,
                tierRuleLimit: FilterRuleTierLimit(limit: 1, isPaid: true)
            )
            XCTFail("Over-budget configuration must be rejected before building the snapshot.")
        } catch let error as FilterSnapshotPreparationError {
            guard case .exceedsDeviceMemoryBudget = error else {
                return XCTFail("Expected the device error to take priority, got: \(error)")
            }
        }
    }

    func testPrepareAcceptsConfigurationWithinBudget() async throws {
        let fixture = try Fixture(payloadText: payloadText)
        let result = try await fixture.fetchingService().prepare(
            configuration: fixture.configuration,
            customSources: [],
            catalogFreshnessMaxAge: 3_600,
            maxDeviceRuleCount: 1_000,
            tierRuleLimit: FilterRuleTierLimit(limit: 1_000, isPaid: false)
        )
        XCTAssertEqual(result.snapshot.summary.blocklistRuleCount, 2)
        // The cold gate persists the exact budget total it evaluated, so a warm reuse can apply the
        // same tier limit without recompiling. It must be populated, bounded by the limit just
        // accepted, and at least the block-rule count, and it must survive a codec round-trip.
        let budget = try XCTUnwrap(result.snapshot.summary.tierBudgetRuleCount)
        XCTAssertLessThanOrEqual(budget, 1_000, "An accepted prepare must record a budget within the tier limit.")
        XCTAssertGreaterThanOrEqual(budget, result.snapshot.summary.blockRuleCount)
        let decoded = try JSONDecoder().decode(
            PreparedFilterSnapshot.self,
            from: JSONEncoder().encode(result.snapshot)
        )
        XCTAssertEqual(decoded.summary.tierBudgetRuleCount, budget, "tierBudgetRuleCount must survive a round-trip.")
        // A legacy artifact predating the field decodes to nil (the warm path then cold-compiles).
        let legacy = try JSONDecoder().decode(
            PreparedFilterSnapshotSummary.self,
            from: Data(#"{"blockRuleCount":5,"allowRuleCount":0,"guardrailRuleCount":1}"#.utf8)
        )
        XCTAssertNil(legacy.tierBudgetRuleCount)
    }

    func testDisplayNameResolvesCustomCatalogAndFallback() throws {
        let custom = try CustomBlocklistSource(displayName: "My Big List", rawURL: "https://example.com/list.txt")
        XCTAssertEqual(
            FilterSnapshotPreparationService.displayName(forSourceID: custom.id, customSources: [custom]),
            "My Big List"
        )
        let catalog = try XCTUnwrap(DefaultCatalog.curatedSources.first)
        XCTAssertEqual(
            FilterSnapshotPreparationService.displayName(forSourceID: catalog.id, customSources: []),
            catalog.name
        )
        XCTAssertEqual(
            FilterSnapshotPreparationService.displayName(forSourceID: "unknown-xyz", customSources: []),
            "unknown-xyz"
        )
    }

    func testMissingEnabledSourceFailsClosed() async throws {
        let fixture = try Fixture(payloadText: payloadText)
        var configuration = fixture.configuration
        configuration.enabledBlocklistIDs.insert("missing-source")

        do {
            _ = try await fixture.fetchingService().prepare(
                configuration: configuration,
                customSources: [],
                catalogFreshnessMaxAge: 3_600
            )
            XCTFail("An enabled source with no rules must fail preparation (fail-closed).")
        } catch {
            // expected
        }
    }

    func testCustomRuleSetReplacesCatalogRuleSetWithSameID() {
        // Pinned contract: app preparation REPLACES a catalog rule set shadowed
        // by a custom list with the same id (the tunnel-side compiler unions
        // instead — a deliberate, documented divergence).
        var catalogRules = DomainRuleSet()
        try? catalogRules.insert(domain: "catalog.example.com", matchesSubdomains: true)
        var customRules = DomainRuleSet()
        try? customRules.insert(domain: "custom.example.com", matchesSubdomains: true)

        let combined = FilterSnapshotPreparationService.combinedCatalogResult(
            catalogResult: BlocklistCatalogSyncResult(
                catalog: BlocklistCatalog(
                    schemaVersion: 2,
                    catalogVersion: "test",
                    generatedAt: Date(),
                    sources: [],
                    guardrails: []
                ),
                sourceRuleSets: ["shared-id": catalogRules],
                guardrailRuleSet: DomainRuleSet(),
                metadataBySourceID: [:],
                usedCachedSourceIDs: []
            ),
            customResult: CustomBlocklistSyncResult(
                sourceRuleSets: ["shared-id": customRules],
                sourceHashes: [:],
                usedCachedSourceIDs: []
            )
        )

        XCTAssertEqual(combined.sourceRuleSets["shared-id"], customRules)
        XCTAssertFalse(combined.sourceRuleSets["shared-id"]?.contains("catalog.example.com") ?? true)
    }

    func testCustomHashesApplyToConfigurationBeforeIdentityIsMinted() async throws {
        let customText = "custom.example.com\n"
        let fixture = try Fixture(payloadText: payloadText, customPayloadText: customText)
        let customSource = try CustomBlocklistSource(
            id: "custom-1",
            displayName: "Custom",
            rawURL: "https://example.com/custom.txt"
        )
        var configuration = fixture.configuration
        configuration.customBlocklists = [customSource]
        configuration.enabledBlocklistIDs.insert("custom-1")

        let result = try await fixture.fetchingService().prepare(
            configuration: configuration,
            customSources: [customSource],
            catalogFreshnessMaxAge: 3_600
        )

        let expectedHash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(customText.utf8))
        XCTAssertEqual(result.customResult.sourceHashes["custom-1"], expectedHash)
        XCTAssertEqual(
            result.snapshot.identity.customBlocklistFingerprints["custom-1"]?.contains(expectedHash),
            true,
            "Custom hashes must reach the identity so the next startup's reuse check matches."
        )
    }

    func testCacheFirstCustomPolicyServesCachedPayloadWithoutNetwork() async throws {
        let customText = "custom.example.com\n"
        let fixture = try Fixture(payloadText: payloadText, customPayloadText: customText)
        let customSource = try CustomBlocklistSource(
            id: "custom-1",
            displayName: "Custom",
            rawURL: "https://example.com/custom.txt"
        )
        var configuration = fixture.configuration
        configuration.customBlocklists = [customSource]
        configuration.enabledBlocklistIDs.insert("custom-1")

        // First prepare populates the custom payload cache from the network.
        let first = try await fixture.fetchingService().prepare(
            configuration: configuration,
            customSources: [customSource],
            catalogFreshnessMaxAge: 3_600
        )
        let expectedHash = try XCTUnwrap(first.customResult.sourceHashes["custom-1"])

        // Startup policy with the hash recorded and the network gone: cached
        // payload must serve, keeping protection actionable offline.
        var acceptedSource = customSource
        acceptedSource.lastAcceptedHash = expectedHash
        configuration.customBlocklists = [acceptedSource]
        let result = try await fixture.offlineService().prepare(
            configuration: configuration,
            customSources: [acceptedSource],
            catalogFreshnessMaxAge: 3_600,
            customListPolicy: .cacheFirst
        )

        XCTAssertEqual(result.customResult.sourceHashes["custom-1"], expectedHash)
        XCTAssertTrue(result.customResult.usedCachedSourceIDs.contains("custom-1"))
        XCTAssertEqual(result.snapshot.summary.blocklistSourceRuleCounts?["custom-1"], 1)
    }

    func testCustomSourceFetchFailureSurfacesNamedListError() async throws {
        // No customPayloadText → the fixture fetcher throws URLError for the custom URL,
        // and there is no custom cache (brand-new source). The prepare must fail with an
        // actionable error that NAMES the list (not the masked "latest.txt" file error,
        // and not a bare URLError that doesn't say which list).
        let fixture = try Fixture(payloadText: payloadText)
        let customSource = try CustomBlocklistSource(
            id: "custom-1",
            displayName: "My List",
            rawURL: "https://example.com/custom.txt"
        )
        var configuration = fixture.configuration
        configuration.customBlocklists = [customSource]
        configuration.enabledBlocklistIDs.insert("custom-1")

        do {
            _ = try await fixture.fetchingService().prepare(
                configuration: configuration,
                customSources: [customSource],
                catalogFreshnessMaxAge: 3_600
            )
            XCTFail("A custom source that can't be fetched and has no cache must fail preparation.")
        } catch {
            let ns = error as NSError
            XCTAssertFalse(
                ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError,
                "Custom-source fetch failure was masked by the no-cache latest.txt read error: \(error)"
            )
            guard case let .customBlocklistUnavailable(displayName, reason) = (error as? BlocklistCatalogSyncError) else {
                return XCTFail("Expected a named customBlocklistUnavailable error, got \(error)")
            }
            XCTAssertEqual(displayName, "My List")
            XCTAssertFalse(reason.isEmpty, "the underlying network reason must be preserved")
            XCTAssertTrue(
                error.localizedDescription.contains("My List"),
                "the surfaced message must name the list: \(error.localizedDescription)"
            )
        }
    }

    func testPersistArtifactsWritesPreparedCompactAndManifestLast() async throws {
        let fixture = try Fixture(payloadText: payloadText)
        let service = fixture.fetchingService()
        let result = try await service.prepare(
            configuration: fixture.configuration,
            customSources: [],
            catalogFreshnessMaxAge: 3_600
        )

        let container = try Fixture.makeTemporaryDirectory()
        try await service.persistArtifacts(
            result.snapshot,
            containerURL: container,
            snapshotFilename: "filter-snapshot.json",
            compactSnapshotFilename: "filter-snapshot.compact"
        )

        // The published artifacts live in the pointer-resolved versioned store now that
        // the root dual-write is dropped; read through readableStore() (pointer -> versioned).
        let store = FilterArtifactStore(directoryURL: container).readableStore()
        let manifest = try XCTUnwrap(store.loadManifest())
        XCTAssertEqual(manifest.snapshotIdentityFingerprint, result.snapshot.identity.fingerprint)
        XCTAssertEqual(manifest.availableArtifacts, [.prepared, .compact])

        let selection = try XCTUnwrap(store.reusableArtifact(
            configuration: fixture.configuration,
            cachedCatalog: result.catalogResult.catalog
        ))
        XCTAssertEqual(selection.kind, .compact)
    }

    func testPersistArtifactsAlsoPublishesVersionedPointer() async throws {
        let fixture = try Fixture(payloadText: payloadText)
        let service = fixture.fetchingService()
        let result = try await service.prepare(
            configuration: fixture.configuration,
            customSources: [],
            catalogFreshnessMaxAge: 3_600
        )

        let container = try Fixture.makeTemporaryDirectory()
        try await service.persistArtifacts(
            result.snapshot,
            containerURL: container,
            snapshotFilename: "filter-snapshot.json",
            compactSnapshotFilename: "filter-snapshot.compact"
        )

        let store = FilterArtifactStore(directoryURL: container)

        // A pointer was flipped, naming a versioned dir whose manifest matches.
        let pointer = try XCTUnwrap(store.loadArtifactPointer())
        XCTAssertEqual(pointer.snapshotIdentityFingerprint, result.snapshot.identity.fingerprint)
        let versioned = try XCTUnwrap(store.currentVersionedStore())
        XCTAssertEqual(try versioned.loadManifest()?.snapshotIdentity, result.snapshot.identity)

        // The legacy root dual-write is dropped: persistArtifacts writes NO root-level
        // trio (on a fresh container the root files are simply absent).
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.manifestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.preparedSnapshotURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.compactSnapshotURL.path))

        // readableStore() resolves the published versioned dir.
        XCTAssertEqual(store.readableStore().directoryURL, versioned.directoryURL)
    }

    func testPersistArtifactsAbortsFlipWhenSupersededWhileLocked() async throws {
        // Kilo #29 (warm-flip rollback arm): when the in-lock supersession check fires, persistArtifacts must
        // NOT flip the pointer and must return .abortedSuperseded — nothing is published, so the tunnel is
        // never pointed at a snapshot built from a superseded basis.
        let fixture = try Fixture(payloadText: payloadText)
        let service = fixture.fetchingService()
        let result = try await service.prepare(
            configuration: fixture.configuration, customSources: [], catalogFreshnessMaxAge: 3_600)
        let container = try Fixture.makeTemporaryDirectory()

        let outcome = try await service.persistArtifacts(
            result.snapshot,
            containerURL: container,
            snapshotFilename: "filter-snapshot.json",
            compactSnapshotFilename: "filter-snapshot.compact",
            supersededWhileLocked: { _ in true }
        )

        guard case .abortedSuperseded = outcome else {
            return XCTFail("Expected .abortedSuperseded, got \(outcome)")
        }
        XCTAssertNil(
            FilterArtifactStore(directoryURL: container).loadArtifactPointer(),
            "An aborted (superseded) flip must publish no pointer."
        )
    }

    func testPersistArtifactsDoesNotFlipWhenCommitBeforeFlipVetoes() async throws {
        // Kilo #29 (warm-flip rollback arm): a commitBeforeFlip veto (e.g. the caller detects its catalog
        // basis moved) throws BEFORE the pointer moves, so the publish leaves no pointer — config-leads-pointer
        // stays fail-closed.
        struct VetoError: Error {}
        let fixture = try Fixture(payloadText: payloadText)
        let service = fixture.fetchingService()
        let result = try await service.prepare(
            configuration: fixture.configuration, customSources: [], catalogFreshnessMaxAge: 3_600)
        let container = try Fixture.makeTemporaryDirectory()

        do {
            _ = try await service.persistArtifacts(
                result.snapshot,
                containerURL: container,
                snapshotFilename: "filter-snapshot.json",
                compactSnapshotFilename: "filter-snapshot.compact",
                commitBeforeFlip: { throw VetoError() }
            )
            XCTFail("A commitBeforeFlip veto must propagate as a throw.")
        } catch is VetoError {
            // expected
        }
        XCTAssertNil(
            FilterArtifactStore(directoryURL: container).loadArtifactPointer(),
            "A vetoed commitBeforeFlip must publish no pointer."
        )
    }

    func testPersistArtifactsPreservesPreExistingLegacyRootAsPassiveFallback() async throws {
        let fixture = try Fixture(payloadText: payloadText)
        let service = fixture.fetchingService()
        let result = try await service.prepare(
            configuration: fixture.configuration,
            customSources: [],
            catalogFreshnessMaxAge: 3_600
        )

        let container = try Fixture.makeTemporaryDirectory()

        // Simulate an upgrade from a dual-write build: a populated legacy root set already
        // exists on disk before the new (versioned-only) publisher runs.
        let seedStore = FilterArtifactStore(
            directoryURL: container,
            preparedSnapshotFilename: "filter-snapshot.json",
            compactSnapshotFilename: "filter-snapshot.compact"
        )
        try seedStore.persist(preparedSnapshot: result.snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: seedStore.manifestURL.path))

        try await service.persistArtifacts(
            result.snapshot,
            containerURL: container,
            snapshotFilename: "filter-snapshot.json",
            compactSnapshotFilename: "filter-snapshot.compact"
        )

        // The publish flips the pointer to the versioned set...
        let versioned = try XCTUnwrap(seedStore.currentVersionedStore())
        XCTAssertEqual(try versioned.loadManifest()?.snapshotIdentity, result.snapshot.identity)
        XCTAssertEqual(seedStore.readableStore().directoryURL, versioned.directoryURL)

        // ...and DELIBERATELY preserves the pre-existing legacy root as a passive,
        // identity-gated fallback (it is never swept here; deleting it could drop a
        // root-falling-back reader into a cold compile). Reclaiming it is a follow-up.
        XCTAssertTrue(FileManager.default.fileExists(atPath: seedStore.manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: seedStore.preparedSnapshotURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: seedStore.compactSnapshotURL.path))
    }

    private struct Fixture {
        let cacheURL: URL
        let configuration: AppConfiguration
        private let payloadData: Data
        private let customPayloadData: Data?

        init(payloadText: String, customPayloadText: String? = nil) throws {
            cacheURL = try Self.makeTemporaryDirectory()
            payloadData = Data(payloadText.utf8)
            customPayloadData = customPayloadText.map { Data($0.utf8) }

            let checksum = BlocklistCatalogSynchronizer.sha256Hex(of: payloadData)
            let source = CatalogBlocklistSource(
                id: "source-a",
                name: "Source A",
                category: "ads",
                riskLevel: "low",
                defaultEnabled: true,
                licenseName: "MIT",
                attribution: "test",
                projectURL: URL(string: "https://example.com")!,
                sourceURL: URL(string: "https://example.com/list.txt")!,
                versionID: "source-a-v1",
                entryCount: 2,
                byteSize: payloadData.count,
                sourceHash: checksum,
                acceptedSourceHashes: [CatalogAcceptedSourceHash(sha256: checksum)],
                normalizedHash: checksum,
                publishedAt: Date(),
                redistributionMode: "allowed",
                parseFormat: .plainDomains,
                licenseTextURL: nil,
                noticeURL: nil
            )
            let catalog = BlocklistCatalog(
                schemaVersion: 2,
                catalogVersion: "test-1",
                generatedAt: Date(),
                sources: [source],
                guardrails: []
            )
            let catalogDirectory = cacheURL.appendingPathComponent("catalog", isDirectory: true)
            try FileManager.default.createDirectory(at: catalogDirectory, withIntermediateDirectories: true)
            try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
                .write(to: catalogDirectory.appendingPathComponent("latest.json"))

            configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        }

        func fetchingService() -> FilterSnapshotPreparationService {
            let payload = payloadData
            let customPayload = customPayloadData
            return FilterSnapshotPreparationService(
                synchronizer: BlocklistCatalogSynchronizer(
                    catalogURL: URL(string: "https://example.com/catalog.json")!,
                    cacheDirectoryURL: cacheURL,
                    dataFetcher: { url in
                        if url.lastPathComponent == "list.txt" {
                            return payload
                        }
                        if url.lastPathComponent == "custom.txt", let customPayload {
                            return customPayload
                        }
                        throw URLError(.cannotFindHost)
                    }
                )
            )
        }

        func offlineService() -> FilterSnapshotPreparationService {
            FilterSnapshotPreparationService(
                synchronizer: BlocklistCatalogSynchronizer(
                    catalogURL: URL(string: "https://example.com/catalog.json")!,
                    cacheDirectoryURL: cacheURL,
                    dataFetcher: { _ in throw URLError(.notConnectedToInternet) }
                )
            )
        }

        static func makeTemporaryDirectory() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }
}
