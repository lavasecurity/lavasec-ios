import XCTest
@testable import LavaSecCore
@testable import LavaSecFilterPipeline
@testable import LavaSecKit

final class FilterSnapshotPreparationServiceTests: XCTestCase {
    private let payloadText = "ads.example.com\ntracker.example.net\n"

    func testActualPreparationCheckpointsFillEqualDisplayQuarters() async throws {
        actor Updates {
            var values: [FilterPreparationProgressUpdate] = []
            var valuesDuringFetch: [[FilterPreparationProgressUpdate]] = []
            func fetching() { valuesDuringFetch.append(values) }
            func append(_ update: FilterPreparationProgressUpdate) { values.append(update) }
        }
        try await withTemporaryDirectory(prefix: "snapshot-progress") { temporaryRoot in
            let fixture = try makeFixture(in: temporaryRoot)
            let updates = Updates()
            _ = try await fixture.fetchingService(onFetch: { _ in await updates.fetching() }).prepare(
                configuration: fixture.configuration,
                customSources: [],
                catalogFreshnessMaxAge: 3_600,
                reportProgress: { await updates.append($0) }
            )
            let duringFetch = await updates.valuesDuringFetch
            XCTAssertFalse(duringFetch.isEmpty, "Exercise a real cache-miss fetch.")
            for checkpoints in duringFetch {
                XCTAssertEqual(checkpoints.map(\.progress), [0.05],
                               "Download must not complete its quarter before the fetch returns.")
            }
            let actual = await updates.values.map {
                FilterPreparationPresentationPolicy.equalStepsProgress(phase: $0.phase, rawProgress: $0.progress)
            }
            // Test the producer and presentation together: changing a service checkpoint
            // must not silently make one visible phase wider than another again.
            XCTAssertEqual(actual.count, 4)
            for (value, expected) in zip(actual, [0.0, 0.25, 0.25, 0.5]) {
                XCTAssertEqual(value, expected, accuracy: 0.001)
            }
        }
    }

    func testFreshCachePrepareUsesCachedPayloadsWithoutNetwork() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeFixture(in: temporaryRoot)
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
    }

    func testStaleCachePrefersNetworkAndFallsBackToCacheWhenOffline() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeFixture(in: temporaryRoot)
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
    }

    func testPrepareRejectsConfigurationOverDeviceBudget() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeFixture(in: temporaryRoot)
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
    }

    func testPrepareRejectsConfigurationOverTierLimitButUnderDeviceBudget() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeFixture(in: temporaryRoot)
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
    }

    func testDeviceBudgetTakesPriorityOverTierLimitWhenBothExceeded() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeFixture(in: temporaryRoot)
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
    }

    func testPrepareAcceptsConfigurationWithinBudget() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeFixture(in: temporaryRoot)
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

    /// 🔴 DELIBERATE CONTRACT CHANGE, recorded here because this test used to assert the
    /// opposite and a silent rewrite would hide that.
    ///
    /// It previously required that ANY enabled source with no rules fail the whole
    /// preparation. That is what made retiring a catalog entry impossible: nothing prunes
    /// enabled IDs from a saved configuration, so removing a dead list took out every device
    /// that had it selected — the clean-up shipped the outage.
    ///
    /// The contract is now split by whether anything survived:
    ///   * something loaded  -> publish, with the unusable source DECLARED (this test)
    ///   * nothing loaded    -> still fail closed (the test below)
    ///
    /// The weakening is real and bounded: the device enforces less than the user selected,
    /// and the artifact says which list it is not enforcing.
    func testAnUnknownEnabledSourceIsDeclaredWhenOtherSourcesLoad() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeFixture(in: temporaryRoot)
            var configuration = fixture.configuration
            configuration.enabledBlocklistIDs.insert("missing-source")

            let prepared = try await fixture.fetchingService().prepare(
                configuration: configuration,
                customSources: [],
                catalogFreshnessMaxAge: 3_600
            ).snapshot

            XCTAssertEqual(prepared.summary.quarantinedBlocklistIDs, ["missing-source"])
            XCTAssertTrue(
                prepared.summary.coversEnabledBlocklists(in: configuration),
                "Declared, so coverage holds — and the healthy source still protects the user.")
        }
    }

    /// The half of the old contract that MUST survive: if the only enabled source is one we
    /// cannot load, there is nothing to serve and the prepare fails rather than publishing an
    /// artifact that blocks nothing.
    func testMissingEnabledSourceFailsClosedWhenNothingElseLoads() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeFixture(in: temporaryRoot)
            var configuration = fixture.configuration
            configuration.enabledBlocklistIDs = ["missing-source"]

            do {
                _ = try await fixture.fetchingService().prepare(
                    configuration: configuration,
                    customSources: [],
                    catalogFreshnessMaxAge: 3_600
                )
                XCTFail("With nothing loadable, preparation must fail closed.")
            } catch {
                // expected
            }
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
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let customText = "custom.example.com\n"
            let fixture = try makeFixture(in: temporaryRoot, customPayloadText: customText)
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
    }

    func testCacheFirstCustomPolicyServesCachedPayloadWithoutNetwork() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let customText = "custom.example.com\n"
            let fixture = try makeFixture(in: temporaryRoot, customPayloadText: customText)
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
    }

    func testCustomSourceFetchFailureSurfacesNamedListError() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            // No customPayloadText → the fixture fetcher throws URLError for the custom URL,
            // and there is no custom cache (brand-new source). The prepare must fail with an
            // actionable error that NAMES the list (not the masked "latest.txt" file error,
            // and not a bare URLError that doesn't say which list).
            let fixture = try makeFixture(in: temporaryRoot)
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
    }

    func testPersistArtifactsWritesPreparedCompactAndManifestLast() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeFixture(in: temporaryRoot)
            let service = fixture.fetchingService()
            let result = try await service.prepare(
                configuration: fixture.configuration,
                customSources: [],
                catalogFreshnessMaxAge: 3_600
            )

            let container = temporaryRoot.appendingPathComponent("container", isDirectory: true)
            try FileManager.default.createDirectory(
                at: container,
                withIntermediateDirectories: true
            )
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
    }

    func testPersistArtifactsAlsoPublishesVersionedPointer() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeFixture(in: temporaryRoot)
            let service = fixture.fetchingService()
            let result = try await service.prepare(
                configuration: fixture.configuration,
                customSources: [],
                catalogFreshnessMaxAge: 3_600
            )

            let container = temporaryRoot.appendingPathComponent("container", isDirectory: true)
            try FileManager.default.createDirectory(
                at: container,
                withIntermediateDirectories: true
            )
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
    }

    func testPersistArtifactsAbortsFlipWhenSupersededWhileLocked() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            // Kilo #29 (warm-flip rollback arm): when the in-lock supersession check fires, persistArtifacts must
            // NOT flip the pointer and must return .abortedSuperseded — nothing is published, so the tunnel is
            // never pointed at a snapshot built from a superseded basis.
            let fixture = try makeFixture(in: temporaryRoot)
            let service = fixture.fetchingService()
            let result = try await service.prepare(
                configuration: fixture.configuration, customSources: [], catalogFreshnessMaxAge: 3_600)
            let container = temporaryRoot.appendingPathComponent("container", isDirectory: true)
            try FileManager.default.createDirectory(
                at: container,
                withIntermediateDirectories: true
            )

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
    }

    func testPersistArtifactsDoesNotFlipWhenCommitBeforeFlipVetoes() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            // Kilo #29 (warm-flip rollback arm): a commitBeforeFlip veto (e.g. the caller detects its catalog
            // basis moved) throws BEFORE the pointer moves, so the publish leaves no pointer — config-leads-pointer
            // stays fail-closed.
            struct VetoError: Error {}
            let fixture = try makeFixture(in: temporaryRoot)
            let service = fixture.fetchingService()
            let result = try await service.prepare(
                configuration: fixture.configuration, customSources: [], catalogFreshnessMaxAge: 3_600)
            let container = temporaryRoot.appendingPathComponent("container", isDirectory: true)
            try FileManager.default.createDirectory(
                at: container,
                withIntermediateDirectories: true
            )

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
    }

    func testPersistArtifactsPreservesCancellationInsteadOfWrappingItForDiagnostics() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeFixture(in: temporaryRoot)
            let service = fixture.fetchingService()
            let result = try await service.prepare(
                configuration: fixture.configuration, customSources: [],
                catalogFreshnessMaxAge: 3_600)
            let container = temporaryRoot.appendingPathComponent("container", isDirectory: true)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            let diagnosticEvent = FocusSwitchDiagnosticEvent(
                at: Date(timeIntervalSinceReferenceDate: 71_000), clearGeneration: 2)

            do {
                _ = try await service.persistArtifacts(
                    result.snapshot,
                    containerURL: container,
                    snapshotFilename: "filter-snapshot.json",
                    compactSnapshotFilename: "filter-snapshot.compact",
                    commitBeforeFlip: { throw CancellationError() },
                    diagnosticFailureEvent: { diagnosticEvent })
                XCTFail("Cancellation must be surfaced.")
            } catch is CancellationError {
                // expected: task-cancellation identity is part of the caller's control flow
            } catch {
                XCTFail("Expected raw CancellationError, got \(error)")
            }
        }
    }

    func testPersistArtifactsDoesNotDoubleWrapAnExistingDiagnosticFailure() async throws {
        struct BoundaryError: Error {}

        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeFixture(in: temporaryRoot)
            let service = fixture.fetchingService()
            let result = try await service.prepare(
                configuration: fixture.configuration, customSources: [],
                catalogFreshnessMaxAge: 3_600)
            let container = temporaryRoot.appendingPathComponent("container", isDirectory: true)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            let originalEvent = FocusSwitchDiagnosticEvent(
                at: Date(timeIntervalSinceReferenceDate: 72_000), clearGeneration: 3)
            let replacementEvent = FocusSwitchDiagnosticEvent(
                at: Date(timeIntervalSinceReferenceDate: 73_000), clearGeneration: 4)

            do {
                _ = try await service.persistArtifacts(
                    result.snapshot,
                    containerURL: container,
                    snapshotFilename: "filter-snapshot.json",
                    compactSnapshotFilename: "filter-snapshot.compact",
                    commitBeforeFlip: {
                        throw FocusSwitchDiagnosticFailure(
                            underlying: BoundaryError(), event: originalEvent)
                    },
                    diagnosticFailureEvent: { replacementEvent })
                XCTFail("The boundary failure must be surfaced.")
            } catch let failure as FocusSwitchDiagnosticFailure {
                XCTAssertEqual(failure.event, originalEvent)
                XCTAssertTrue(failure.underlying is BoundaryError)
            } catch {
                XCTFail("Expected FocusSwitchDiagnosticFailure, got \(error)")
            }
        }
    }

    func testPersistArtifactsPreservesPreExistingLegacyRootAsPassiveFallback() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeFixture(in: temporaryRoot)
            let service = fixture.fetchingService()
            let result = try await service.prepare(
                configuration: fixture.configuration,
                customSources: [],
                catalogFreshnessMaxAge: 3_600
            )

            let container = temporaryRoot.appendingPathComponent("container", isDirectory: true)
            try FileManager.default.createDirectory(
                at: container,
                withIntermediateDirectories: true
            )

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
    }

    private func makeFixture(
        in temporaryRoot: URL,
        customPayloadText: String? = nil
    ) throws -> Fixture {
        try Fixture(
            cacheURL: temporaryRoot.appendingPathComponent("cache", isDirectory: true),
            payloadText: payloadText,
            customPayloadText: customPayloadText
        )
    }

    private struct Fixture {
        let cacheURL: URL
        let configuration: AppConfiguration
        private let payloadData: Data
        private let customPayloadData: Data?

        init(cacheURL: URL, payloadText: String, customPayloadText: String? = nil) throws {
            self.cacheURL = cacheURL
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

        func fetchingService(onFetch: (@Sendable (URL) async -> Void)? = nil) -> FilterSnapshotPreparationService {
            let payload = payloadData
            let customPayload = customPayloadData
            return FilterSnapshotPreparationService(
                synchronizer: BlocklistCatalogSynchronizer(
                    catalogURL: URL(string: "https://example.com/catalog.json")!,
                    cacheDirectoryURL: cacheURL,
                    dataFetcher: { url in
                        await onFetch?(url)
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

    }

    // MARK: - Coverage can only be honest if "not loaded" is representable

    /// A source that produced NO rule set must produce NO count key.
    ///
    /// `coversEnabledBlocklists` is a key-PRESENCE check — it never reads the value — so a
    /// `0` written for an unloaded source is indistinguishable from a list that loaded and
    /// happened to be empty. That equivalence is what would let a partial artifact claim
    /// full coverage the moment anything relaxes `validateEnabledBlocklistSources` to
    /// survive one unfetchable list.
    func testAnUnloadedSourceGetsNoCountKey() throws {
        var loaded = DomainRuleSet()
        loaded.insert(try DomainRule(domain: "ads.example.com"))

        let counts = FilterSnapshotPreparationService.blocklistSourceRuleCounts(
            enabledSourceIDs: ["loaded-source", "never-loaded-source"],
            sourceRuleSets: ["loaded-source": loaded])

        XCTAssertEqual(counts["loaded-source"], 1)
        XCTAssertNil(
            counts["never-loaded-source"],
            "A source with no rule set must be ABSENT from the counts, not recorded as 0 — "
                + "coverage reads key presence, so a 0 here claims the list was loaded.")
    }

    /// The other half, and the reason the fix is "omit the key" rather than "drop zeros".
    ///
    /// A list that fetched and parsed to nothing (all comments, or an upstream that emptied
    /// itself) IS covered: we hold what it says. Dropping it because its count is zero would
    /// wedge that configuration exactly the way an unfetchable source does.
    func testAnEmptyButLoadedSourceStillGetsACountKey() throws {
        let counts = FilterSnapshotPreparationService.blocklistSourceRuleCounts(
            enabledSourceIDs: ["empty-source"],
            sourceRuleSets: ["empty-source": DomainRuleSet()])

        XCTAssertEqual(
            counts["empty-source"], 0,
            "A loaded-but-empty source is covered and must keep its key with a count of 0.")
    }

    /// The two facts above, read through the predicate that actually consumes them.
    func testCoverageFailsForAnUnloadedSourceAndHoldsForAnEmptyOne() throws {
        let configuration = AppConfiguration(enabledBlocklistIDs: ["a", "b"])

        let missingB = PreparedFilterSnapshotSummary(
            snapshot: configuration.filterSnapshot(),
            blocklistRuleCount: 3,
            blocklistSourceRuleCounts: ["a": 3])
        XCTAssertFalse(
            missingB.coversEnabledBlocklists(in: configuration),
            "An artifact missing an enabled source must not claim coverage.")

        let emptyB = PreparedFilterSnapshotSummary(
            snapshot: configuration.filterSnapshot(),
            blocklistRuleCount: 3,
            blocklistSourceRuleCounts: ["a": 3, "b": 0])
        XCTAssertTrue(
            emptyB.coversEnabledBlocklists(in: configuration),
            "An artifact holding an enabled source that is legitimately empty IS covered.")
    }

    // MARK: - A quarantined source must be DECLARED, never inferred

    /// Legacy artifacts, and every artifact written by a producer that does not set the
    /// field, keep the strict behaviour. An absence is still an absence.
    func testAnUndeclaredMissingSourceStillFailsCoverage() {
        let configuration = AppConfiguration(enabledBlocklistIDs: ["a", "b"])
        let summary = PreparedFilterSnapshotSummary(
            snapshot: configuration.filterSnapshot(),
            blocklistRuleCount: 3,
            blocklistSourceRuleCounts: ["a": 3])

        XCTAssertNil(summary.quarantinedBlocklistIDs)
        XCTAssertFalse(
            summary.coversEnabledBlocklists(in: configuration),
            "With nothing declared, a missing source is still a coverage failure.")
    }

    /// The relaxation, and the only shape of it: the artifact NAMES what it dropped.
    func testADeclaredQuarantinedSourceIsAccounted() {
        let configuration = AppConfiguration(enabledBlocklistIDs: ["a", "b"])
        let summary = PreparedFilterSnapshotSummary(
            snapshot: configuration.filterSnapshot(),
            blocklistRuleCount: 3,
            blocklistSourceRuleCounts: ["a": 3],
            quarantinedBlocklistIDs: ["b"])

        XCTAssertTrue(
            summary.coversEnabledBlocklists(in: configuration),
            "An enabled source the artifact explicitly declares unavailable is accounted for.")
    }

    /// 🔴 THE ANTI-TAUTOLOGY TEST.
    ///
    /// The whole danger of relaxing coverage is that it stops discriminating. Declaring SOME
    /// source quarantined must not excuse a DIFFERENT source's silent absence — otherwise one
    /// dead list would license an artifact missing anything at all, which is the silent
    /// under-block this design exists to prevent.
    func testDeclaringOneQuarantineDoesNotExcuseAnotherAbsence() {
        let configuration = AppConfiguration(enabledBlocklistIDs: ["a", "b", "c"])
        let summary = PreparedFilterSnapshotSummary(
            snapshot: configuration.filterSnapshot(),
            blocklistRuleCount: 3,
            blocklistSourceRuleCounts: ["a": 3],
            quarantinedBlocklistIDs: ["b"])

        XCTAssertFalse(
            summary.coversEnabledBlocklists(in: configuration),
            "\"c\" is neither loaded nor declared, so coverage must still fail. A non-empty "
                + "quarantine set is not a blanket excuse.")
    }

    /// An empty declaration is not a declaration.
    func testAnEmptyQuarantineSetIsStrict() {
        let configuration = AppConfiguration(enabledBlocklistIDs: ["a", "b"])
        let summary = PreparedFilterSnapshotSummary(
            snapshot: configuration.filterSnapshot(),
            blocklistRuleCount: 3,
            blocklistSourceRuleCounts: ["a": 3],
            quarantinedBlocklistIDs: [])

        XCTAssertFalse(summary.coversEnabledBlocklists(in: configuration))
    }

    // MARK: - End to end: a permanently dead source must not deny the device an artifact

    /// THE WEDGE, reproduced and then fixed.
    ///
    /// Before this, one enabled source returning 404 threw the whole prepare away, so the
    /// artifact was never rewritten, coverage never held again, and the tunnel served
    /// block-all with no path back. Measured on a device: five hours, no artifact.
    ///
    /// Now the dead source is quarantined, the surviving list still compiles, and the
    /// artifact DECLARES the omission so coverage holds honestly rather than by accident.
    func testAPermanentlyDeadSourceIsQuarantinedAndTheRestStillCompile() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeQuarantineFixture(in: temporaryRoot)
            let prepared = try await fixture.service.prepare(
                configuration: fixture.configuration,
                customSources: [],
                catalogFreshnessMaxAge: 3600
            ).snapshot

            XCTAssertEqual(
                prepared.summary.quarantinedBlocklistIDs, ["dead-source"],
                "The artifact must NAME the source it dropped.")
            XCTAssertEqual(
                prepared.summary.blocklistSourceRuleCounts?["live-source"], 1,
                "The healthy source must still be compiled in.")
            XCTAssertNil(
                prepared.summary.blocklistSourceRuleCounts?["dead-source"],
                "A quarantined source must not get a count key — absent means never loaded.")
            XCTAssertTrue(
                prepared.summary.coversEnabledBlocklists(in: fixture.configuration),
                "Coverage must hold: every enabled source is either loaded or declared.")
        }
    }

    /// A TRANSIENT failure must still fail the prepare, so the retry path runs.
    ///
    /// This is the safety half. Quarantining on a timeout would drop a list the user asked
    /// for because of a blip that fixes itself — and the fail-closed bootstrap deadlock this
    /// codebase documents looks exactly like a source failure, so it would fire during the
    /// exact window the repair runs in.
    func testATransientFailureStillFailsThePrepare() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeQuarantineFixture(in: temporaryRoot, deadSourceIsTransient: true)
            do {
                _ = try await fixture.service.prepare(
                    configuration: fixture.configuration,
                    customSources: [],
                    catalogFreshnessMaxAge: 3600
                )
                XCTFail("A transient source failure must fail the prepare, not be quarantined.")
            } catch {
                XCTAssertFalse(
                    BlocklistSourceFailureClassification.classify(error).isPermanent,
                    "The surfaced error must be the transient one.")
            }
        }
    }

    /// A preparation error carries the event captured at the service actor's failure boundary,
    /// rather than forcing an async caller to stamp it after the error crosses back to MainActor.
    func testPrepareFailureCarriesItsDiagnosticEvent() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeQuarantineFixture(in: temporaryRoot, deadSourceIsTransient: true)
            let expectedEvent = FocusSwitchDiagnosticEvent(
                at: Date(timeIntervalSinceReferenceDate: 61_000), clearGeneration: 7)

            do {
                _ = try await fixture.service.prepare(
                    configuration: fixture.configuration,
                    customSources: [],
                    catalogFreshnessMaxAge: 3600,
                    diagnosticFailureEvent: { expectedEvent })
                XCTFail("The transient source failure must be surfaced.")
            } catch let failure as FocusSwitchDiagnosticFailure {
                XCTAssertEqual(failure.event, expectedEvent)
                XCTAssertFalse(
                    BlocklistSourceFailureClassification.classify(failure.underlying).isPermanent)
            }
        }
    }

    func testPrepareCancellationCarriesItsDiagnosticEventWithoutChangingClassification() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeQuarantineFixture(in: temporaryRoot)
            let expectedEvent = FocusSwitchDiagnosticEvent(
                at: Date(timeIntervalSinceReferenceDate: 62_000), clearGeneration: 8)
            let task = Task {
                while !Task.isCancelled {
                    await Task.yield()
                }
                return try await fixture.service.prepare(
                    configuration: fixture.configuration,
                    customSources: [],
                    catalogFreshnessMaxAge: 3600,
                    diagnosticFailureEvent: { expectedEvent })
            }
            task.cancel()

            do {
                _ = try await task.value
                XCTFail("Cancellation must be surfaced.")
            } catch let failure as FocusSwitchDiagnosticFailure {
                XCTAssertEqual(failure.event, expectedEvent)
                XCTAssertTrue(
                    failure.underlying is CancellationError,
                    "The outer reconcile must still classify the failure as cancellation.")
            } catch {
                XCTFail("Expected cancellation with its producer event, got \(error)")
            }
        }
    }

    /// 🔴 Quarantining EVERYTHING is fail-open by paperwork, and must fail closed instead.
    ///
    /// An artifact declaring every enabled source unavailable holds no blocklist rules and
    /// admits as much, so coverage would accept it and the tunnel would serve a snapshot that
    /// blocks nothing while reporting healthy.
    func testQuarantiningEverySourceFailsThePrepareInstead() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeQuarantineFixture(in: temporaryRoot, liveSourceIsAlsoDead: true)
            do {
                _ = try await fixture.service.prepare(
                    configuration: fixture.configuration,
                    customSources: [],
                    catalogFreshnessMaxAge: 3600
                )
                XCTFail("With nothing left to compile, the prepare must fail rather than "
                    + "publish an artifact that blocks nothing.")
            } catch {
                // Any refusal is acceptable; publishing is not.
            }
        }
    }

    // MARK: - Quarantine fixture

    private struct QuarantineFixture {
        let configuration: AppConfiguration
        let catalog: BlocklistCatalog
        let service: FilterSnapshotPreparationService
    }

    /// Two enabled catalog sources: one healthy, one that fails. The failure MODE is the
    /// variable, because permanent and transient must take different paths.
    private func makeQuarantineFixture(
        in temporaryRoot: URL,
        deadSourceIsTransient: Bool = false,
        liveSourceIsAlsoDead: Bool = false
    ) throws -> QuarantineFixture {
        let cacheURL = temporaryRoot.appendingPathComponent("cache", isDirectory: true)
        let liveData = Data("ads.example.com\n".utf8)
        let liveChecksum = BlocklistCatalogSynchronizer.sha256Hex(of: liveData)

        func source(id: String, host: String, data: Data, checksum: String) -> CatalogBlocklistSource {
            CatalogBlocklistSource(
                id: id, name: id, category: "ads", riskLevel: "low", defaultEnabled: true,
                licenseName: "MIT", attribution: "test",
                projectURL: URL(string: "https://example.com")!,
                sourceURL: URL(string: "https://\(host)/list.txt")!,
                versionID: "\(id)-v1", entryCount: 1, byteSize: data.count,
                sourceHash: checksum,
                acceptedSourceHashes: [CatalogAcceptedSourceHash(sha256: checksum)],
                normalizedHash: checksum, publishedAt: Date(),
                redistributionMode: "allowed", parseFormat: .plainDomains,
                licenseTextURL: nil, noticeURL: nil)
        }

        let live = source(id: "live-source", host: "live.example.com", data: liveData, checksum: liveChecksum)
        let dead = source(id: "dead-source", host: "dead.example.com", data: liveData, checksum: liveChecksum)
        let catalog = BlocklistCatalog(
            schemaVersion: 2, catalogVersion: "test-1", generatedAt: Date(),
            sources: [dead, live], guardrails: [])

        let catalogDirectory = cacheURL.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogDirectory, withIntermediateDirectories: true)
        try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
            .write(to: catalogDirectory.appendingPathComponent("latest.json"))

        let transient = deadSourceIsTransient
        let liveAlsoDead = liveSourceIsAlsoDead
        let service = FilterSnapshotPreparationService(
            synchronizer: BlocklistCatalogSynchronizer(
                catalogURL: URL(string: "https://example.com/catalog.json")!,
                cacheDirectoryURL: cacheURL,
                dataFetcher: { url in
                    let isDead = url.host == "dead.example.com"
                        || (liveAlsoDead && url.host == "live.example.com")
                    if isDead {
                        // 404 is PERMANENT; a timeout is transient. The distinction is the
                        // whole point of the classification these tests exercise.
                        throw transient
                            ? URLError(.timedOut)
                            : BlocklistCatalogSyncError.invalidHTTPStatus(404)
                    }
                    if url.host == "live.example.com" { return liveData }
                    if url.host == "custom.example.com" { return liveData }
                    throw URLError(.unsupportedURL)
                }
            )
        )

        return QuarantineFixture(
            configuration: AppConfiguration(enabledBlocklistIDs: ["live-source", "dead-source"]),
            catalog: catalog,
            service: service)
    }

    /// Retiring a catalog entry must not wedge the devices that already enabled it.
    ///
    /// Nothing prunes enabled IDs from a saved configuration, and `compile` filters the
    /// catalog by the enabled set — so a REMOVED id produces nothing to fail, never reaches
    /// the failure classifier, and used to surface as `missingEnabledBlocklistSource`. That
    /// made "clean up the dead lists" an action that shipped the outage instead of ending it.
    func testAnEnabledIDNoLongerInTheCatalogIsQuarantinedNotFatal() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeQuarantineFixture(in: temporaryRoot)
            // The user still has a retired list selected alongside the two the catalog knows.
            var configuration = fixture.configuration
            configuration.enabledBlocklistIDs.insert("retired-source")

            let prepared = try await fixture.service.prepare(
                configuration: configuration,
                customSources: [],
                catalogFreshnessMaxAge: 3600
            ).snapshot

            XCTAssertEqual(
                prepared.summary.quarantinedBlocklistIDs, ["dead-source", "retired-source"],
                "A retired catalog entry must be declared alongside the unfetchable one.")
            XCTAssertTrue(
                prepared.summary.coversEnabledBlocklists(in: configuration),
                "The device must still get an artifact when a selected list no longer exists.")
        }
    }

    /// 🔴 A dead CATALOG source must not fail a device whose CUSTOM lists are healthy.
    ///
    /// The "nothing survived" refusal originally lived in `compile`, which sees catalog
    /// sources only — custom sources are compiled separately and afterwards. So a
    /// configuration whose one catalog list is permanently dead was refused even though its
    /// custom lists held rules: the same wedge this work exists to remove, one source kind
    /// over. The refusal now lives where both kinds are visible, and the catalog-level one
    /// fires only when the caller says nothing else can supply rules.
    func testADeadCatalogSourceDoesNotFailADeviceWithHealthyCustomLists() async throws {
        try await withTemporaryDirectory(prefix: "snapshot-preparation") { temporaryRoot in
            let fixture = try makeQuarantineFixture(in: temporaryRoot, liveSourceIsAlsoDead: true)
            let customURL = URL(string: "https://custom.example.com/list.txt")!
            let custom = try CustomBlocklistSource(
                id: "custom-healthy", displayName: "Mine", rawURL: customURL.absoluteString)

            var configuration = fixture.configuration
            configuration.enabledBlocklistIDs.insert(custom.id)
            configuration.customBlocklists = [custom]

            let prepared = try await fixture.service.prepare(
                configuration: configuration,
                customSources: [custom],
                catalogFreshnessMaxAge: 3600
            ).snapshot

            XCTAssertEqual(
                prepared.summary.quarantinedBlocklistIDs,
                ["dead-source", "live-source"],
                "Both catalog sources are dead and must be declared.")
            XCTAssertEqual(
                prepared.summary.blocklistSourceRuleCounts?["custom-healthy"], 1,
                "The healthy custom list must still be compiled in.")
            XCTAssertTrue(prepared.summary.coversEnabledBlocklists(in: configuration))
        }
    }
}
