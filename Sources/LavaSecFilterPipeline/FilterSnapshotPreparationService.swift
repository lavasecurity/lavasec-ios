import Foundation
import LavaSecKit

/// Output of preparing catalog, custom-source, and compiled snapshot state.
public struct FilterSnapshotPreparationResult: Sendable {
    /// Catalog synchronization result used for the snapshot.
    public let catalogResult: BlocklistCatalogSyncResult
    /// Custom-source synchronization result used for the snapshot.
    public let customResult: CustomBlocklistSyncResult
    /// Prepared snapshot and persisted reuse metadata.
    public let snapshot: PreparedFilterSnapshot

    package init(
        catalogResult: BlocklistCatalogSyncResult,
        customResult: CustomBlocklistSyncResult,
        snapshot: PreparedFilterSnapshot
    ) {
        self.catalogResult = catalogResult
        self.customResult = customResult
        self.snapshot = snapshot
    }
}

/// Progress reported while a filter snapshot is prepared.
public struct FilterPreparationProgressUpdate: Sendable {
    /// Fractional completion value reported by the preparation pipeline.
    public let progress: Double
    /// User-facing phase associated with the progress value.
    public let phase: FilterPreparationPhase

    /// Creates a progress update for a preparation phase.
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
/// Network and cache policy used when loading custom blocklists.
public enum CustomBlocklistSyncPolicy: Sendable {
    // Refresh semantics: fetch fresh custom payloads, fall back to cache.
    /// Tries the network first, then falls back to cached payloads.
    case networkFirst
    // Startup semantics: serve cached custom payloads so protection becomes
    // actionable without waiting on third-party hosts; network only on a miss.
    // Callers schedule a network refresh after protection is up.
    /// Tries cached payloads first, then falls back to the network.
    case cacheFirst
    // Frozen semantics: serve cached custom payloads only and never touch the
    // network — not even on a cache miss or stored-hash mismatch. Used when the
    // plan no longer allows custom blocklists (a lapsed Plus user keeps the lists
    // it already had, but their contents are never refreshed). A genuine miss
    // surfaces as an error instead of silently re-downloading the frozen list.
    /// Uses cached payloads only and never performs a network fetch.
    case cacheOnly
}

/// Actor that synchronizes blocklists, compiles snapshots, and publishes filter artifacts.
public actor FilterSnapshotPreparationService {
    /// Main-actor callback used to report preparation progress.
    public typealias ProgressHandler = @MainActor @Sendable (FilterPreparationProgressUpdate) async -> Void

    private let synchronizer: BlocklistCatalogSynchronizer

    package init(synchronizer: BlocklistCatalogSynchronizer) {
        self.synchronizer = synchronizer
    }

    /// Creates a preparation service backed by the supplied blocklist cache directory.
    ///
    /// `dataFetcher` defaults to the ordinary pinned-HTTPS fetch. The app overrides it with
    /// `BlocklistCatalogSynchronizer.bootstrapAwareDataFetcher(broker:)` so a device whose
    /// tunnel is fail-closed can still resolve its blocklist sources — see that method for why
    /// the repair path would otherwise deadlock against its own sinkhole.
    public init(
        cacheDirectoryURL: URL,
        dataFetcher: @escaping BlocklistCatalogDataFetcher =
            BlocklistCatalogSynchronizer.defaultDataFetcher
    ) {
        self.synchronizer = BlocklistCatalogSynchronizer(
            cacheDirectoryURL: cacheDirectoryURL, dataFetcher: dataFetcher)
    }

    /// Synchronizes selected sources, enforces rule budgets, and builds a prepared snapshot.
    /// - Parameter diagnosticFailureEvent: Invoked synchronously in the actor's catch at the
    ///   producing failure boundary. `nil` or an event-capture failure propagates the error raw;
    ///   cancellation is carried as the wrapper's underlying error so callers retain its classification,
    ///   and an already-wrapped diagnostic failure is rethrown unchanged.
    public func prepare(
        configuration: AppConfiguration,
        customSources: [CustomBlocklistSource],
        catalogFreshnessMaxAge: TimeInterval,
        customListPolicy: CustomBlocklistSyncPolicy = .networkFirst,
        catalogCacheOnly: Bool = false,
        maxDeviceRuleCount: Int = FilterSnapshotMemoryBudget.maxFilterRuleCount,
        tierRuleLimit: FilterRuleTierLimit? = nil,
        diagnosticFailureEvent: (@Sendable () -> FocusSwitchDiagnosticEvent?)? = nil,
        reportProgress: ProgressHandler? = nil,
        trace: LatencyTrace? = nil,
        parentSpan: LatencySpan? = nil
    ) async throws -> FilterSnapshotPreparationResult {
        do {
            return try await prepareUnwrapped(
                configuration: configuration,
                customSources: customSources,
                catalogFreshnessMaxAge: catalogFreshnessMaxAge,
                customListPolicy: customListPolicy,
                catalogCacheOnly: catalogCacheOnly,
                maxDeviceRuleCount: maxDeviceRuleCount,
                tierRuleLimit: tierRuleLimit,
                reportProgress: reportProgress,
                trace: trace,
                parentSpan: parentSpan
            )
        } catch let cancellation as CancellationError {
            guard let event = diagnosticFailureEvent?() else { throw cancellation }
            throw FocusSwitchDiagnosticFailure(underlying: cancellation, event: event)
        } catch let diagnosticFailure as FocusSwitchDiagnosticFailure {
            throw diagnosticFailure
        } catch {
            guard let event = diagnosticFailureEvent?() else { throw error }
            throw FocusSwitchDiagnosticFailure(underlying: error, event: event)
        }
    }

    private func prepareUnwrapped(
        configuration: AppConfiguration,
        customSources: [CustomBlocklistSource],
        catalogFreshnessMaxAge: TimeInterval,
        customListPolicy: CustomBlocklistSyncPolicy,
        catalogCacheOnly: Bool,
        maxDeviceRuleCount: Int,
        tierRuleLimit: FilterRuleTierLimit?,
        reportProgress: ProgressHandler?,
        trace: LatencyTrace?,
        parentSpan: LatencySpan?
    ) async throws -> FilterSnapshotPreparationResult {
        await reportProgress?(FilterPreparationProgressUpdate(progress: 0.05, phase: .downloading))

        // Cache migration stays with the caller: it resets the caller's
        // published catalog state when entries are removed.
        let enabledIDs = configuration.enabledBlocklistIDs
        let hasFreshCache = BlocklistCatalogSynchronizer.hasFreshCachedCatalog(
            in: synchronizer.cacheDirectoryURL,
            maxAge: catalogFreshnessMaxAge
        )

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
            catalogResult = try await synchronizer.loadCached(
                enabledSourceIDs: enabledIDs,
                failsWhenNoCatalogSourceSurvives: customSources.isEmpty)
        } else if hasFreshCache {
            do {
                catalogResult = try await synchronizer.loadCached(
                enabledSourceIDs: enabledIDs,
                failsWhenNoCatalogSourceSurvives: customSources.isEmpty)
            } catch {
                catalogResult = try await synchronizer.sync(
                enabledSourceIDs: enabledIDs,
                failsWhenNoCatalogSourceSurvives: customSources.isEmpty)
            }
        } else {
            do {
                catalogResult = try await synchronizer.sync(
                enabledSourceIDs: enabledIDs,
                failsWhenNoCatalogSourceSurvives: customSources.isEmpty)
            } catch {
                catalogResult = try await synchronizer.loadCached(
                enabledSourceIDs: enabledIDs,
                failsWhenNoCatalogSourceSurvives: customSources.isEmpty)
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
        // 🔴 A CATALOG ENTRY THAT NO LONGER EXISTS IS ALSO A DEAD SOURCE, and the sync cannot
        // see it: `compile` filters the catalog by the enabled set, so an ID we have since
        // REMOVED simply produces nothing to fail, never reaches the classifier, and lands
        // here as `missingEnabledBlocklistSource` — wedging the device exactly as an
        // unfetchable source used to.
        //
        // That matters the moment we retire an entry. Nothing prunes enabled IDs from a saved
        // configuration (`AppConfiguration` decodes them verbatim), so removing a dead list
        // from the catalog would take out every device that had it enabled — the tidy-up would
        // ship the outage instead of ending it.
        //
        // Checked against BOTH source kinds, because `enabledBlocklistIDs` carries custom
        // identifiers alongside curated ones; a custom list that is merely failing must not be
        // mistaken for one that no longer exists.
        let knownSourceIDs = Set(combinedResult.catalog.sources.map(\.id))
            .union(customSources.map(\.id))
        var quarantinedSourceIDs = Set(combinedResult.quarantinedSourceIDs.keys)
        for sourceID in snapshotConfiguration.enabledBlocklistIDs
        where combinedResult.sourceRuleSets[sourceID] == nil && !knownSourceIDs.contains(sourceID) {
            quarantinedSourceIDs.insert(sourceID)
        }

        // 🔴 NOTHING SURVIVED means fail closed, and this guard has to live HERE as well as in
        // the sync. The sync's copy only sees sources the catalog still contains, so an ID
        // that was RETIRED never reaches it — and a configuration whose only enabled list is a
        // retired one would sail through, publishing an artifact with no blocklist rules that
        // declares as much, which coverage then accepts. An artifact that blocks nothing while
        // reporting healthy is the fail-open this whole design exists to avoid.
        //
        // A configuration with no blocklists at all is legitimate. Explicit catalog withdrawals
        // are also intentional removals and are excluded below; unexplained losses still fail.
        let loadedEnabledSourceCount = snapshotConfiguration.enabledBlocklistIDs
            .filter { combinedResult.sourceRuleSets[$0] != nil }
            .count
        // An explicit catalog withdrawal is an authorized removal, not a fetch failure.
        // It may retire the last selected catalog source; unrelated missing/custom sources
        // still fail closed. The omission remains declared in the persisted summary.
        // pinned: CatalogAuthorizationTests.testWithdrawalsRequireConfiguredVerifiedAuthorization
        let withdrawnIDs = combinedResult.catalog.withdrawnBlocklistIDs(in: snapshotConfiguration)
        if !quarantinedSourceIDs.subtracting(withdrawnIDs).isEmpty, loadedEnabledSourceCount == 0 {
            throw BlocklistCatalogSyncError.missingEnabledBlocklistSource(
                sourceID: quarantinedSourceIDs.sorted().joined(separator: ","))
        }

        try Self.validateEnabledBlocklistSources(
            in: snapshotConfiguration,
            sourceRuleSets: combinedResult.sourceRuleSets,
            quarantinedSourceIDs: quarantinedSourceIDs
        )

        await reportProgress?(FilterPreparationProgressUpdate(progress: 0.2, phase: .downloading))

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
        // guardrail) drive the resident memory. This is the cold-compile gate of
        // INV-TIER-1: it runs on the deduped union, so it is exact where the UI
        // estimate (a per-list sum) is not, and it is the one gate that THROWS
        // the actionable error (the publish/reuse/serve gates elsewhere refuse
        // silently and rely on reaching this path). The device guardrail is
        // checked first (it is the hard safety floor); the tier limit, if any,
        // binds below it.
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
                tierBudgetRuleCount: totalRuleCount,
                // DECLARE the omissions. Without this the artifact holds fewer sources than
                // the configuration enables and `coversEnabledBlocklists` refuses it — which
                // is exactly right, and exactly the wedge, until the omission is on the
                // record. Empty on every ordinary prepare.
                quarantinedBlocklistIDs: quarantinedSourceIDs.isEmpty ? nil : quarantinedSourceIDs
            )
        )
        buildSpan?.end(details: ["blockRuleCount": "\(preparedSnapshot.summary.blockRuleCount)"])

        await reportProgress?(FilterPreparationProgressUpdate(progress: 0.72, phase: .compiling))

        return FilterSnapshotPreparationResult(
            catalogResult: combinedResult,
            customResult: customResult,
            snapshot: preparedSnapshot
        )
    }

    // Network-first custom-list sync for the post-startup background refresh;
    // returns the fresh hashes so the caller can detect content changes.
    /// Refreshes custom sources from the network with cache fallback handled by the synchronizer.
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
        /// A `tryOrAbort` caller was cancelled before staging or at the in-lock
        /// check after staging. The active pointer never flips; staged files may
        /// remain for reuse or cleanup. Distinct from `abortedContended` so
        /// diagnostics can distinguish cancellation from lock contention.
        case abortedCancelled
    }

    /// Stages an artifact set and publishes its pointer under the requested lock policy.
    /// - Parameter configurationWriteLockURL: Optional outer lock for a paired configuration commit.
    ///   Staging happens before either lock. The order is configuration then publication; a caller
    ///   writing configuration in `commitBeforeFlip` must not acquire that lock again.
    /// - Parameter onPublished: Runs synchronously after the pointer write at the publication
    ///   boundary. It is skipped for every aborted outcome because nothing was published.
    /// - Parameter diagnosticFailureEvent: Invoked synchronously in the actor's catch at the
    ///   producing failure boundary. `nil` or an event-capture failure propagates the error raw;
    ///   cancellation and an already-wrapped diagnostic failure always remain unwrapped.
    @discardableResult
    public func persistArtifacts(
        _ preparedSnapshot: PreparedFilterSnapshot,
        containerURL: URL,
        snapshotFilename: String,
        compactSnapshotFilename: String,
        publishLockURL: URL? = nil,
        configurationWriteLockURL: URL? = nil,
        lockMode: PublishLockMode = .blocking,
        supersededWhileLocked: (@Sendable (_ currentPointerToken: String?) -> Bool)? = nil,
        commitBeforeFlip: (@Sendable () throws -> Void)? = nil,
        onPublished: (@Sendable () -> Void)? = nil,
        diagnosticFailureEvent: (@Sendable () -> FocusSwitchDiagnosticEvent?)? = nil,
        // Extra versioned tokens to keep alive during GC. Multi-filter passes each
        // hosted filter's `lastCompiledToken` so a recently-used filter's compiled
        // directory survives, making a switch back to it an instant pointer flip
        // instead of a cold compile. Empty ⇒ today's behaviour (keep live+previous).
        additionalRetainedTokens: [String] = []
    ) throws -> PublishOutcome {
        do {
            return try persistArtifactsUnwrapped(
                preparedSnapshot,
                containerURL: containerURL,
                snapshotFilename: snapshotFilename,
                compactSnapshotFilename: compactSnapshotFilename,
                publishLockURL: publishLockURL,
                configurationWriteLockURL: configurationWriteLockURL,
                lockMode: lockMode,
                supersededWhileLocked: supersededWhileLocked,
                commitBeforeFlip: commitBeforeFlip,
                onPublished: onPublished,
                additionalRetainedTokens: additionalRetainedTokens
            )
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch let diagnosticFailure as FocusSwitchDiagnosticFailure {
            throw diagnosticFailure
        } catch {
            guard let event = diagnosticFailureEvent?() else { throw error }
            throw FocusSwitchDiagnosticFailure(underlying: error, event: event)
        }
    }

    private func persistArtifactsUnwrapped(
        _ preparedSnapshot: PreparedFilterSnapshot,
        containerURL: URL,
        snapshotFilename: String,
        compactSnapshotFilename: String,
        publishLockURL: URL?,
        configurationWriteLockURL: URL?,
        lockMode: PublishLockMode,
        supersededWhileLocked: (@Sendable (_ currentPointerToken: String?) -> Bool)?,
        commitBeforeFlip: (@Sendable () throws -> Void)?,
        onPublished: (@Sendable () -> Void)?,
        additionalRetainedTokens: [String]
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
            // An intent/BGTask may expire during staging or lock acquisition. Abort before
            // committing side state; there is no cancellation boundary between that write and flip.
            if lockMode == .tryOrAbort, Task.isCancelled { return .abortedCancelled }
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
            // latest.json) immediately before the flip, inside the same held lock and after
            // supersession checks. A veto before writing leaves both unchanged. Multi-file I/O
            // can still partially fail or be terminated; the caller owns recovery of side state.
            // There is no actor suspension between this callback and the pointer write.
            try commitBeforeFlip?()
            // GC even if the pointer flip throws, so a failed flip never leaks the
            // freshly-staged dir (it is retained this cycle and reused/reaped next).
            defer {
                artifactStore.collectVersionedGarbage(
                    retaining: ([pointer.token, previousToken].compactMap { $0 }) + additionalRetainedTokens
                )
            }
            try artifactStore.writeArtifactPointer(pointer)
            onPublished?()
            return .published
        }

        let publish: () throws -> PublishOutcome = {
            switch lockMode {
            case .blocking:
                return try FilterPublishLock.withExclusiveLock(at: publishLockURL, flipUnderLock)
            case .tryOrAbort:
                return try FilterPublishLock.withTryExclusiveLock(at: publishLockURL, flipUnderLock) ?? .abortedContended
            }
        }
        guard let configurationWriteLockURL else { return try publish() }
        // SharedFilterStatePersistence's documented ordering: configuration → publication.
        // A contended headless transaction changes neither the selection nor the live pointer.
        switch lockMode {
        case .blocking:
            return try FilterPublishLock.withExclusiveLock(at: configurationWriteLockURL, publish)
        case .tryOrAbort:
            return try FilterPublishLock.withTryExclusiveLock(at: configurationWriteLockURL, publish) ?? .abortedContended
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

    /// Returns the union of rule sets for the enabled source identifiers.
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

    internal static func blocklistSourceRuleCounts(
        enabledSourceIDs: Set<String>,
        sourceRuleSets: [String: DomainRuleSet]
    ) -> [String: Int] {
        var sourceRuleCounts: [String: Int] = [:]
        for sourceID in enabledSourceIDs {
            // 🔴 NO `?? 0`, and this is the load-bearing line of the whole coverage gate.
            //
            // `CompactFilterSnapshot.Summary.coversEnabledBlocklists` asks ONLY whether the
            // key is present — it never looks at the value. So writing `0` for a source that
            // produced no rule set records "I loaded this list and it had no rules" for a
            // list that was never loaded at all, and coverage then holds for an artifact that
            // is missing it.
            //
            // Today `validateEnabledBlocklistSources` throws first, so the old `?? 0` was
            // unreachable — dead defensive code that was WRONG rather than merely redundant.
            // The moment anything relaxes that validation to survive one unfetchable source,
            // the `?? 0` wakes up and turns `coversEnabledBlocklists` into a tautology: the
            // partial artifact publishes clean, passes the flip veto, every reuse gate, and
            // last-known-good, permanently, because nothing downstream records which sources
            // actually landed. A loud outage becomes a silent protection downgrade.
            //
            // Absent key = never loaded. Key with 0 = loaded, parsed, genuinely no rules
            // (a list of nothing but comments). Those are different facts and the summary
            // has to be able to tell them apart.
            // pinned: FilterSnapshotPreparationServiceTests.testAnUnloadedSourceGetsNoCountKey
            guard let rules = sourceRuleSets[sourceID] else {
                continue
            }
            sourceRuleCounts[sourceID] = rules.count
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
    /// Combines catalog and custom rule sets, with custom sets replacing duplicate identifiers.
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
            usedCachedSourceIDs: catalogResult.usedCachedSourceIDs.union(customResult.usedCachedSourceIDs),
            // Custom sources are never quarantined — only the catalog path classifies —
            // so this is the catalog result's set unchanged.
            quarantinedSourceIDs: catalogResult.quarantinedSourceIDs,
            localCustomRuleCounts: customResult.localCustomRuleCounts
        )
    }

    internal static func validateEnabledBlocklistSources(
        in configuration: AppConfiguration,
        sourceRuleSets: [String: DomainRuleSet],
        quarantinedSourceIDs: Set<String> = []
    ) throws {
        // A quarantined source is EXPECTED to be absent — the sync already decided it is
        // permanently unusable, and the artifact will declare it so coverage still holds.
        // Everything else missing is a real inconsistency and still throws.
        //
        // The default is empty, so every existing caller keeps the strict behaviour.
        for sourceID in configuration.enabledBlocklistIDs
        where sourceRuleSets[sourceID] == nil && !quarantinedSourceIDs.contains(sourceID) {
            throw BlocklistCatalogSyncError.missingEnabledBlocklistSource(sourceID: sourceID)
        }
    }

    /// Returns a configuration with accepted custom-source hashes applied by source identifier.
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
    internal static func customBlocklists(
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
