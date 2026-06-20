import Foundation

public struct FilterSnapshotPreparationResult: Sendable {
    public let catalogResult: BlocklistCatalogSyncResult
    public let customResult: CustomBlocklistSyncResult
    public let snapshot: PreparedFilterSnapshot

    public init(
        catalogResult: BlocklistCatalogSyncResult,
        customResult: CustomBlocklistSyncResult,
        snapshot: PreparedFilterSnapshot
    ) {
        self.catalogResult = catalogResult
        self.customResult = customResult
        self.snapshot = snapshot
    }
}

public struct FilterPreparationProgressUpdate: Sendable {
    public let progress: Double
    public let phase: FilterPreparationPhase

    public init(progress: Double, phase: FilterPreparationPhase) {
        self.progress = progress
        self.phase = phase
    }
}

// Owns filter snapshot preparation and artifact persistence off the main
// actor: the catalog sync ladder, custom-list handling, rule merge, snapshot
// and summary build, and the prepared-JSON + compact + manifest writes.
// Progress callbacks are MainActor-isolated so callers can update UI state
// directly; everything else runs on this actor's executor.
public enum CustomBlocklistSyncPolicy: Sendable {
    // Refresh semantics: fetch fresh custom payloads, fall back to cache.
    case networkFirst
    // Startup semantics: serve cached custom payloads so protection becomes
    // actionable without waiting on third-party hosts; network only on a miss.
    // Callers schedule a network refresh after protection is up.
    case cacheFirst
    // Frozen semantics: serve cached custom payloads only and never touch the
    // network — not even on a cache miss or stored-hash mismatch. Used when the
    // plan no longer allows custom blocklists (a lapsed Plus user keeps the lists
    // it already had, but their contents are never refreshed). A genuine miss
    // surfaces as an error instead of silently re-downloading the frozen list.
    case cacheOnly
}

public actor FilterSnapshotPreparationService {
    public typealias ProgressHandler = @MainActor @Sendable (FilterPreparationProgressUpdate) async -> Void

    private let synchronizer: BlocklistCatalogSynchronizer

    public init(synchronizer: BlocklistCatalogSynchronizer) {
        self.synchronizer = synchronizer
    }

    public init(cacheDirectoryURL: URL) {
        self.synchronizer = BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheDirectoryURL)
    }

    public func prepare(
        configuration: AppConfiguration,
        customSources: [CustomBlocklistSource],
        catalogFreshnessMaxAge: TimeInterval,
        customListPolicy: CustomBlocklistSyncPolicy = .networkFirst,
        maxDeviceRuleCount: Int = FilterSnapshotMemoryBudget.maxFilterRuleCount,
        tierRuleLimit: FilterRuleTierLimit? = nil,
        reportProgress: ProgressHandler? = nil,
        trace: LatencyTrace? = nil,
        parentSpan: LatencySpan? = nil
    ) async throws -> FilterSnapshotPreparationResult {
        await reportProgress?(FilterPreparationProgressUpdate(progress: 0.05, phase: .downloading))

        // Cache migration stays with the caller: it resets the caller's
        // published catalog state when entries are removed.
        let enabledIDs = configuration.enabledBlocklistIDs
        let hasFreshCache = BlocklistCatalogSynchronizer.hasFreshCachedCatalog(
            in: synchronizer.cacheDirectoryURL,
            maxAge: catalogFreshnessMaxAge
        )
        await reportProgress?(FilterPreparationProgressUpdate(progress: 0.2, phase: .downloading))

        let syncSpan = trace?.beginSpan("prepare.catalogSync", parent: parentSpan, details: [
            "freshCache": "\(hasFreshCache)",
            "enabledSourceCount": "\(enabledIDs.count)",
            "customSourceCount": "\(customSources.count)"
        ])

        // The fallback ladder: a fresh cache prefers cached payloads and falls
        // back to the network; a stale cache prefers the network and falls
        // back to cached payloads.
        let catalogResult: BlocklistCatalogSyncResult
        if hasFreshCache {
            do {
                catalogResult = try await synchronizer.loadCached(enabledSourceIDs: enabledIDs)
            } catch {
                catalogResult = try await synchronizer.sync(enabledSourceIDs: enabledIDs)
            }
        } else {
            do {
                catalogResult = try await synchronizer.sync(enabledSourceIDs: enabledIDs)
            } catch {
                catalogResult = try await synchronizer.loadCached(enabledSourceIDs: enabledIDs)
            }
        }

        let customResult: CustomBlocklistSyncResult
        switch customListPolicy {
        case .networkFirst:
            do {
                customResult = try await synchronizer.syncCustomBlocklists(customSources)
            } catch let networkError {
                do {
                    customResult = try await synchronizer.loadCachedCustomBlocklists(customSources)
                } catch is CancellationError {
                    // Custom compilation starts with Task.checkCancellation(), so a prepare
                    // cancelled during the fallback must propagate cleanly — not be masked as
                    // a download failure by the networkError rethrow below.
                    throw CancellationError()
                } catch {
                    // A brand-new custom source has no cache, so the cache fallback throws a
                    // misleading "latest.txt … no such file" that masks why the *download*
                    // actually failed. Surface the real network error so the user sees the
                    // actionable cause (e.g. host unreachable) instead of a phantom file error.
                    throw networkError
                }
            }
        case .cacheFirst:
            do {
                customResult = try await synchronizer.loadCachedCustomBlocklists(customSources)
            } catch {
                customResult = try await synchronizer.syncCustomBlocklists(customSources)
            }
        case .cacheOnly:
            // Strictly cache-only: a cache miss or hash mismatch propagates rather
            // than falling back to the network, so a frozen (downgraded) list is
            // never re-downloaded or re-hashed behind the user's back.
            customResult = try await synchronizer.loadCachedCustomBlocklists(customSources)
        }
        syncSpan?.end(details: ["sourceCount": "\(catalogResult.sourceRuleSets.count)"])

        let combinedResult = Self.combinedCatalogResult(catalogResult: catalogResult, customResult: customResult)
        // Custom-list hashes must be applied BEFORE the identity is minted so
        // customBlocklistFingerprints match on the next reuse check.
        let snapshotConfiguration = Self.configuration(
            configuration,
            applyingCustomBlocklistHashes: customResult.sourceHashes
        )
        try Self.validateEnabledBlocklistSources(
            in: snapshotConfiguration,
            sourceRuleSets: combinedResult.sourceRuleSets
        )

        await reportProgress?(FilterPreparationProgressUpdate(progress: 0.42, phase: .compiling))
        let mergeSpan = trace?.beginSpan("prepare.mergeRules", parent: parentSpan)
        let mergedBlockRules = Self.mergedBlockRules(
            enabledSourceIDs: snapshotConfiguration.enabledBlocklistIDs,
            sourceRuleSets: combinedResult.sourceRuleSets
        )
        mergeSpan?.end(details: ["mergedRuleCount": "\(mergedBlockRules.count)"])

        // Reject an over-budget configuration BEFORE building the snapshot, so
        // protection fails fast with an actionable message instead of compiling
        // an artifact the tunnel would jetsam on. Filter rules (block + allow +
        // guardrail) drive the resident memory. This is the authoritative cap:
        // it runs on the deduped union, so it is exact where the UI estimate
        // (a per-list sum) is not. The device guardrail is checked first (it is
        // the hard safety floor); the tier limit, if any, binds below it.
        let totalRuleCount = mergedBlockRules.count
            + combinedResult.guardrailRuleSet.count
            + snapshotConfiguration.allowedDomains.count
            + snapshotConfiguration.blockedDomains.count
        if totalRuleCount > maxDeviceRuleCount || (tierRuleLimit.map { totalRuleCount > $0.limit } ?? false) {
            // Key by human-readable list name so the "Largest:" hint names the
            // user's list (e.g. "My Big List") rather than an opaque custom-<uuid>.
            let perSourceRuleCounts = Dictionary(
                Self.blocklistSourceRuleCounts(
                    enabledSourceIDs: snapshotConfiguration.enabledBlocklistIDs,
                    sourceRuleSets: combinedResult.sourceRuleSets
                ).map { (Self.displayName(forSourceID: $0.key, customSources: customSources), $0.value) },
                uniquingKeysWith: { $0 + $1 }
            )
            if totalRuleCount > maxDeviceRuleCount {
                throw FilterSnapshotPreparationError.exceedsDeviceMemoryBudget(
                    ruleCount: totalRuleCount,
                    maxRuleCount: maxDeviceRuleCount,
                    perSourceRuleCounts: perSourceRuleCounts
                )
            }
            // Safe to force-unwrap: the `||` above only reaches here when the
            // tier branch was the true one, which requires a non-nil limit.
            let tier = tierRuleLimit!
            throw FilterSnapshotPreparationError.exceedsTierFilterRuleLimit(
                ruleCount: totalRuleCount,
                limitRuleCount: tier.limit,
                isPaid: tier.isPaid,
                perSourceRuleCounts: perSourceRuleCounts
            )
        }

        await reportProgress?(FilterPreparationProgressUpdate(progress: 0.72, phase: .compiling))
        let buildSpan = trace?.beginSpan("prepare.buildSnapshot", parent: parentSpan)
        let snapshot = snapshotConfiguration.filterSnapshot(
            blockRules: mergedBlockRules,
            nonAllowableThreatRules: combinedResult.guardrailRuleSet
        )
        let preparedSnapshot = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(
                configuration: snapshotConfiguration,
                catalog: combinedResult.catalog
            ),
            snapshot: snapshot,
            summary: PreparedFilterSnapshotSummary(
                snapshot: snapshot,
                blocklistRuleCount: mergedBlockRules.count,
                blocklistSourceRuleCounts: Self.blocklistSourceRuleCounts(
                    enabledSourceIDs: snapshotConfiguration.enabledBlocklistIDs,
                    sourceRuleSets: combinedResult.sourceRuleSets
                )
            )
        )
        buildSpan?.end(details: ["blockRuleCount": "\(preparedSnapshot.summary.blockRuleCount)"])

        return FilterSnapshotPreparationResult(
            catalogResult: combinedResult,
            customResult: customResult,
            snapshot: preparedSnapshot
        )
    }

    // Network-first custom-list sync for the post-startup background refresh;
    // returns the fresh hashes so the caller can detect content changes.
    public func refreshCustomBlocklists(_ sources: [CustomBlocklistSource]) async throws -> CustomBlocklistSyncResult {
        try await synchronizer.syncCustomBlocklists(sources)
    }

    // Encodes and writes the prepared JSON, the compact artifact, and the
    // manifest — in that order. The manifest is the cheap startup decision
    // point and must never describe artifacts that failed to land.
    public func persistArtifacts(
        _ preparedSnapshot: PreparedFilterSnapshot,
        containerURL: URL,
        snapshotFilename: String,
        compactSnapshotFilename: String
    ) throws {
        // FilterArtifactStore is the single owner of artifact paths, atomic
        // writes, and the manifest-last ordering.
        let artifactStore = FilterArtifactStore(
            directoryURL: containerURL,
            preparedSnapshotFilename: snapshotFilename,
            compactSnapshotFilename: compactSnapshotFilename
        )
        try artifactStore.persist(preparedSnapshot: preparedSnapshot)
    }

    // MARK: - Pure helpers (moved verbatim from AppViewModel)

    public static func mergedBlockRules(
        enabledSourceIDs: Set<String>,
        sourceRuleSets: [String: DomainRuleSet]
    ) -> DomainRuleSet {
        var mergedRules = DomainRuleSet()
        for sourceID in enabledSourceIDs {
            guard let rules = sourceRuleSets[sourceID] else {
                continue
            }

            mergedRules.formUnion(rules)
        }

        return mergedRules
    }

    public static func blocklistSourceRuleCounts(
        enabledSourceIDs: Set<String>,
        sourceRuleSets: [String: DomainRuleSet]
    ) -> [String: Int] {
        var sourceRuleCounts: [String: Int] = [:]
        for sourceID in enabledSourceIDs {
            sourceRuleCounts[sourceID] = sourceRuleSets[sourceID]?.count ?? 0
        }

        return sourceRuleCounts
    }

    // Resolves a source ID to a human-readable name for over-budget messages.
    // Custom lists carry the user's chosen name; catalog lists use the curated
    // name; unknown IDs fall back to the raw ID.
    static func displayName(forSourceID id: String, customSources: [CustomBlocklistSource]) -> String {
        if let custom = customSources.first(where: { $0.id == id }) {
            return custom.displayName
        }
        if let catalog = DefaultCatalog.curatedSources.first(where: { $0.id == id }) {
            return catalog.name
        }
        return id
    }

    // Custom rule sets REPLACE a catalog rule set with the same ID here; the
    // tunnel-side CachedFilterSnapshotCompiler unions them instead. The replace
    // semantics are the app's contract for preparation (a custom list overrides
    // the catalog entry it shadows) and are pinned by tests.
    public static func combinedCatalogResult(
        catalogResult: BlocklistCatalogSyncResult,
        customResult: CustomBlocklistSyncResult
    ) -> BlocklistCatalogSyncResult {
        var combinedRuleSets = catalogResult.sourceRuleSets
        for (sourceID, rules) in customResult.sourceRuleSets {
            combinedRuleSets[sourceID] = rules
        }

        return BlocklistCatalogSyncResult(
            catalog: catalogResult.catalog,
            sourceRuleSets: combinedRuleSets,
            guardrailRuleSet: catalogResult.guardrailRuleSet,
            metadataBySourceID: catalogResult.metadataBySourceID,
            usedCachedSourceIDs: catalogResult.usedCachedSourceIDs.union(customResult.usedCachedSourceIDs)
        )
    }

    public static func validateEnabledBlocklistSources(
        in configuration: AppConfiguration,
        sourceRuleSets: [String: DomainRuleSet]
    ) throws {
        for sourceID in configuration.enabledBlocklistIDs where sourceRuleSets[sourceID] == nil {
            throw BlocklistCatalogSyncError.missingEnabledBlocklistSource(sourceID: sourceID)
        }
    }

    public static func configuration(
        _ configuration: AppConfiguration,
        applyingCustomBlocklistHashes hashes: [String: String]
    ) -> AppConfiguration {
        guard !hashes.isEmpty else {
            return configuration
        }

        var updatedConfiguration = configuration
        for index in updatedConfiguration.customBlocklists.indices {
            let sourceID = updatedConfiguration.customBlocklists[index].id
            if let hash = hashes[sourceID] {
                updatedConfiguration.customBlocklists[index].lastAcceptedHash = hash
            }
        }
        return updatedConfiguration
    }
}
