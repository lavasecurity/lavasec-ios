import Foundation
import LavaSecKit

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
        catalogCacheOnly: Bool = false,
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
        if catalogCacheOnly {
            // Strictly cache-only: NEVER sync. A sync advances latest.json / moves the catalog
            // cache underneath a concurrent switch's warm-reuse guard (which only skips reuse on
            // isCatalogSyncInFlight), reintroducing the stale-cache race. A cache miss propagates
            // so the (best-effort, background) warm caller simply skips this filter.
            catalogResult = try await synchronizer.loadCached(enabledSourceIDs: enabledIDs)
        } else if hasFreshCache {
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
                ),
                // Persist the exact budget total this gate just evaluated, so a later warm reuse can
                // apply the identical tier rule-limit check without recompiling (Codex #133 r1).
                tierBudgetRuleCount: totalRuleCount
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
    //
    // Publishes a single content-addressed VERSIONED directory (LAV-90 Phase 1),
    // staged off-lock (it is not yet pointed-to, so invisible to readers), with the
    // pointer flip + GC run under the cross-process publish lock so two writers never
    // interleave a flip. The pointer flip is the linearization point for the lock-free
    // reader. This drops the legacy ROOT-level dual-write: the pointer/versioned set is
    // the source of truth and the reader resolves it via the pointer.
    //
    // A pre-existing root set (left by an upgraded-from dual-write build) is deliberately
    // NOT swept here. The tunnel reads `[pointer-resolved, root]` and may still fall back
    // to root when the pointer-resolved store is rejected (e.g. a config-vs-artifact skew
    // during the app's non-atomic refresh, or a GC'd versioned dir). Because that fallback
    // is identity-gated, a stale root is only ever *used* when it matches the reader's
    // config — i.e. it is always safe to keep, and deleting it could drop such a pass into
    // a cold compile / fail-closed. Reclaiming the orphaned root is a separate follow-up
    // (paired with a reader that re-resolves the pointer on a root miss), once the
    // keep-last-known-good tunnel resilience has landed.
    /// How the pointer flip contends for the cross-process publish lock.
    public enum PublishLockMode: Sendable {
        /// Foreground writer: BLOCK until the lock is free (degrade-OPEN if the lock
        /// file is unavailable). The user is waiting and foreground must win.
        case blocking
        /// Background writer: non-blocking try-lock. If the lock is contended (a
        /// foreground writer holds it) or unavailable, ABORT without flipping —
        /// never degrade-open, so a stale background publish can't clobber.
        case tryOrAbort
    }

    /// Outcome of a publish attempt; callers (the background refresh) decide whether to
    /// notify the tunnel based on whether the pointer actually moved.
    public enum PublishOutcome: Sendable {
        /// The pointer was flipped to the freshly-staged versioned dir.
        case published
        /// `tryOrAbort` couldn't take the lock (foreground holds it / unavailable);
        /// the staged dir is retained and reused or reaped next cycle.
        case abortedContended
        /// The lock was held but `supersededWhileLocked` reported a newer on-disk
        /// configuration, so the flip was skipped (degrade-ABORT).
        case abortedSuperseded
        /// A `tryOrAbort` caller was already cancelled (the BGTask expired) before
        /// staging, so nothing was encoded/written or flipped. Distinct from
        /// `abortedContended` so telemetry can tell a deadline apart from lock contention.
        case abortedCancelled
    }

    @discardableResult
    public func persistArtifacts(
        _ preparedSnapshot: PreparedFilterSnapshot,
        containerURL: URL,
        snapshotFilename: String,
        compactSnapshotFilename: String,
        publishLockURL: URL? = nil,
        lockMode: PublishLockMode = .blocking,
        supersededWhileLocked: (@Sendable (_ currentPointerToken: String?) -> Bool)? = nil,
        commitBeforeFlip: (@Sendable () throws -> Void)? = nil,
        // Extra versioned tokens to keep alive during GC. Multi-filter passes each
        // hosted filter's `lastCompiledToken` so a recently-used filter's compiled
        // directory survives, making a switch back to it an instant pointer flip
        // instead of a cold compile. Empty ⇒ today's behaviour (keep live+previous).
        additionalRetainedTokens: [String] = []
    ) throws -> PublishOutcome {
        // FilterArtifactStore is the single owner of artifact paths, atomic
        // writes, and the manifest-last ordering.
        let artifactStore = FilterArtifactStore(
            directoryURL: containerURL,
            preparedSnapshotFilename: snapshotFilename,
            compactSnapshotFilename: compactSnapshotFilename
        )
        // Degrade-abort (background) callers race the BGTask deadline. Staging encodes +
        // writes the full versioned dir (~1.1s for large rule sets); if the task was already
        // cancelled, skip that work entirely rather than staging-then-aborting at the flip.
        // (An expiry DURING staging is still caught by the in-lock supersession check before
        // the pointer moves.) The blocking foreground path is never deadline-bound, so this
        // only applies to `.tryOrAbort`.
        if lockMode == .tryOrAbort, Task.isCancelled {
            return .abortedCancelled
        }
        let writtenAt = Date()
        // Versioned staging runs OFF the lock — it writes not-yet-pointed-to bytes (the
        // versioned dir is invisible until the flip). Two writers stage into DISTINCT
        // content-addressed token dirs, so concurrent staging never collides; the lock
        // below serializes only the flip + GC. The background writer additionally uses
        // `.tryOrAbort` (degrade-abort) so it never stages-then-flips while foreground
        // holds the lock.
        let pointer = try artifactStore.stageVersionedArtifacts(
            preparedSnapshot: preparedSnapshot,
            writtenAt: writtenAt
        )

        // The supersession check + pointer flip are ONE critical section: a foreground
        // write that lands after staging but before the flip is observed here and ABORTS
        // the flip, so the tunnel is never pointed at a snapshot built from a superseded
        // config. Runs inside the held publish lock.
        let flipUnderLock: () throws -> PublishOutcome = {
            // The live pointer at the linearization point. Read FIRST so the supersession
            // check can compare against it: a degrade-abort (background) caller uses it to
            // detect that a concurrent publish moved the pointer since the caller captured
            // its basis — a rollback guard the configuration-generation token cannot provide,
            // because the catalog is not part of the configuration.
            let previousToken = artifactStore.loadArtifactPointer()?.token
            if let supersededWhileLocked, supersededWhileLocked(previousToken) {
                // Published nothing. Do NOT GC on the abort path: narrowing the retain set
                // here could evict the previous dir a lock-free reader is mid-pass on, and we
                // didn't flip. The orphaned staged dir ages out and is reaped (after the grace
                // window) by the next successful publish.
                return .abortedSuperseded
            }
            // Re-stage UNDER the lock so the pointer never flips to a missing directory. Idempotent:
            // a no-op when the token dir is present (the common case — a fresh compile staged it
            // off-lock above, or a warm reuse's dir is still there), but RE-MATERIALIZES it from the
            // in-memory snapshot if it was reaped while we waited for the lock. This matters for a
            // warm-artifact REUSE: it points at an OLD directory whose mtime the GC grace window no
            // longer protects, so a concurrent publisher (not retaining this token) could reap it
            // between the off-lock stage and this flip. A fresh compile's directory is recent and
            // grace-protected, so it is never exposed — for it this stays a pure no-op.
            _ = try artifactStore.stageVersionedArtifacts(preparedSnapshot: preparedSnapshot, writtenAt: writtenAt)
            // Commit any caller-supplied side state (e.g. the background catalog cache's
            // latest.json) ATOMICALLY with the flip: it runs inside the same held lock, only
            // once the supersession check has passed, and BEFORE the pointer moves. A throw
            // here aborts before any state change (no committed side state, no flip), so a
            // caller that detects its own basis went stale can veto the publish without
            // leaving the side state ahead of the pointer.
            try commitBeforeFlip?()
            // GC even if the pointer flip throws, so a failed flip never leaks the
            // freshly-staged dir (it is retained this cycle and reused/reaped next).
            defer {
                artifactStore.collectVersionedGarbage(
                    retaining: ([pointer.token, previousToken].compactMap { $0 }) + additionalRetainedTokens
                )
            }
            try artifactStore.writeArtifactPointer(pointer)
            return .published
        }

        switch lockMode {
        case .blocking:
            return try FilterPublishLock.withExclusiveLock(at: publishLockURL, flipUnderLock)
        case .tryOrAbort:
            return try FilterPublishLock.withTryExclusiveLock(at: publishLockURL, flipUnderLock) ?? .abortedContended
        }
    }

    /// Compile output for a NON-active filter: write its versioned artifact directory
    /// (prepared + compact + manifest) WITHOUT flipping the live pointer, taking the
    /// publish lock, or running GC. The directory is content-addressed and invisible to
    /// readers until some future publish (a switch) flips to it, so this safely warms a
    /// filter the tunnel is not currently serving. Returns the staged pointer; its
    /// `.token` is the filter's `lastCompiledToken`. Off-lock by design — distinct
    /// filters stage into distinct content-addressed token dirs, and staging never moves
    /// the pointer or reaps anything; GC is deferred to the next real publish, which
    /// retains every hosted filter's token. Idempotent: re-staging a complete token
    /// directory is a no-op that returns the same pointer.
    @discardableResult
    public func stageArtifacts(
        _ preparedSnapshot: PreparedFilterSnapshot,
        containerURL: URL,
        snapshotFilename: String,
        compactSnapshotFilename: String
    ) throws -> FilterArtifactPointer {
        // FilterArtifactStore is the single owner of artifact paths, atomic writes, and
        // the manifest-last ordering — constructed identically to persistArtifacts.
        let artifactStore = FilterArtifactStore(
            directoryURL: containerURL,
            preparedSnapshotFilename: snapshotFilename,
            compactSnapshotFilename: compactSnapshotFilename
        )
        return try artifactStore.stageVersionedArtifacts(
            preparedSnapshot: preparedSnapshot,
            writtenAt: Date()
        )
    }

    /// Reclaim orphaned versioned artifact directories left by repeated NON-active warms. Each warm
    /// mints a fresh (`generatedAt`-stamped) token and overwrites the filter's `lastCompiledToken`,
    /// but `stageArtifacts` never GCs — so without this, repeatedly warming the same filter (e.g.
    /// several draft saves without ever switching) leaks a full artifact directory apiece until an
    /// unrelated active publish happens to collect it, breaking the "disk bounded by the filter cap"
    /// invariant. Retains the supplied hosted-filter tokens PLUS the live pointer's token (the
    /// tunnel-facing directory, which can differ from any hosted token mid-switch). Grace-window
    /// protected: a directory staged within the grace interval (e.g. by a concurrent publish about to
    /// flip to it) is never reaped. Off-lock and best-effort, matching `collectVersionedGarbage`'s
    /// documented multi-writer model.
    public func collectWarmArtifactGarbage(
        containerURL: URL,
        snapshotFilename: String,
        compactSnapshotFilename: String,
        retaining retainedTokens: [String]
    ) {
        let artifactStore = FilterArtifactStore(
            directoryURL: containerURL,
            preparedSnapshotFilename: snapshotFilename,
            compactSnapshotFilename: compactSnapshotFilename
        )
        let livePointerToken = artifactStore.loadArtifactPointer()?.token
        // Warm reclamation has no promptness requirement, and the retain set here (live
        // pointer + hosted tokens) does NOT include the just-superseded previous pointer
        // dir the publish GC deliberately keeps — the long warm grace preserves that
        // reader-survives-one-supersession posture (see warmGarbageGraceInterval).
        artifactStore.collectVersionedGarbage(
            retaining: ([livePointerToken].compactMap { $0 }) + retainedTokens,
            graceInterval: FilterArtifactStore.warmGarbageGraceInterval
        )
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
        updatedConfiguration.customBlocklists = customBlocklists(
            updatedConfiguration.customBlocklists,
            applyingHashes: hashes
        )
        return updatedConfiguration
    }

    /// Stamp each custom source's freshly-fetched content hash onto its `lastAcceptedHash`,
    /// matching by source id. The per-source primitive behind
    /// ``configuration(_:applyingCustomBlocklistHashes:)``; the warm path applies it to a
    /// NON-active filter's stored `customBlocklists` so a later switch's warm-reuse gate
    /// (`customBlocklistFingerprints`) matches the staged artifact instead of cold-compiling.
    public static func customBlocklists(
        _ customBlocklists: [CustomBlocklistSource],
        applyingHashes hashes: [String: String]
    ) -> [CustomBlocklistSource] {
        guard !hashes.isEmpty else {
            return customBlocklists
        }

        var updated = customBlocklists
        for index in updated.indices {
            if let hash = hashes[updated[index].id] {
                updated[index].lastAcceptedHash = hash
            }
        }
        return updated
    }
}
