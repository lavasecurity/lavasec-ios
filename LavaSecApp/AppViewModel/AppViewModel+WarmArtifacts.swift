import Darwin
import Foundation
import SwiftUI
import UIKit
@preconcurrency import CoreHaptics
@preconcurrency import NetworkExtension
@preconcurrency import UserNotifications
import LavaSecKit
import LavaSecFilterPipeline
import LavaSecAppServices

// One concern of `AppViewModel`, split out of the former single-file view model.
// Stored state (`@Published` and otherwise) lives in LavaSecApp/AppViewModel.swift (extensions
// cannot declare stored properties); every file under AppViewModel/ is one `// MARK:` section.

extension AppViewModel {
    // MARK: - Warm artifact preparation & publish

    func currentSnapshot() -> FilterSnapshot {
        configuration.filterSnapshot(
            blockRules: blockRules,
            nonAllowableThreatRules: threatGuardrail
        )
    }

    private func preparedSummary(for snapshot: FilterSnapshot) -> PreparedFilterSnapshotSummary {
        let blocklistRuleCount = preparedBlocklistRuleCount()
        return PreparedFilterSnapshotSummary(
            snapshot: snapshot,
            blocklistRuleCount: blocklistRuleCount,
            blocklistSourceRuleCounts: preparedBlocklistSourceRuleCounts(),
            // Persist the SAME tier-budget total a cold compile would record (block-merge + FULL
            // guardrail + allowed + blocked — mirrors FilterSnapshotPreparationService.prepare), so a
            // warm switch-back to this freshly persisted token passes the tier gate instead of always
            // cold-compiling (Codex #133). threatGuardrail normally holds the full guardrail
            // (snapshot's nonAllowableThreatRules is only the allowlist-overlap subset) — EXCEPT in
            // the startup-warm-reuse window before the launch catalog sync repopulates it, where a
            // persist records a subset-based (lower) total; the artifact is self-consistent and the
            // drift is bounded by the guardrail-tier size (empty in production today). nil blocklist
            // count ⇒ nil budget ⇒ the warm reuse correctly falls back to a cold compile.
            tierBudgetRuleCount: blocklistRuleCount.map {
                $0 + threatGuardrail.count + configuration.allowedDomains.count + configuration.blockedDomains.count
            },
            quarantinedBlocklistIDs: currentCatalog?.withdrawnBlocklistIDs(in: configuration)
        )
    }

    /// The live in-memory equivalent of `preparedSummary`'s `tierBudgetRuleCount` — the same
    /// block-merge + FULL guardrail + allowed + blocked total the cold gate evaluates — computed
    /// from the already-rebuilt published state so INV-TIER-1 status checks (post-sync surface,
    /// plan-change reconcile) never pay a second merge. Transient under-count, accepted:
    /// between a startup warm reuse and the launch catalog sync, `threatGuardrail` holds only
    /// the allowlist-overlap SUBSET (see `loadReusablePreparedSnapshotForProtectionStartup`),
    /// so a status check in that window can miss by up to the guardrail-tier size — a delayed
    /// message, never a false one, and only the STATUS surface: every enforcement gate binds
    /// the recorded `tierBudgetRuleCount` instead. (The guardrail tier is empty in production
    /// today.)
    var liveCompiledTierBudgetRuleCount: Int {
        compiledBlocklistRuleCount
            + threatGuardrail.count
            + configuration.allowedDomains.count
            + configuration.blockedDomains.count
    }

    private func preparedBlocklistRuleCount() -> Int? {
        let withdrawnIDs = currentCatalog?.withdrawnBlocklistIDs(in: configuration) ?? []
        let hasAllEnabledRuleSets = configuration.enabledBlocklistIDs.allSatisfy { sourceID in
            cachedBlockRuleSets[sourceID] != nil || withdrawnIDs.contains(sourceID)
        }

        if configuration.enabledBlocklistIDs.isEmpty || hasAllEnabledRuleSets {
            return FilterSnapshotPreparationService.mergedBlockRules(
                enabledSourceIDs: configuration.enabledBlocklistIDs,
                sourceRuleSets: cachedBlockRuleSets
            ).count
        }

        if compiledBlocklistRuleCount > 0 {
            return compiledBlocklistRuleCount
        }

        return nil
    }

    private func preparedBlocklistSourceRuleCounts() -> [String: Int]? {
        guard !configuration.enabledBlocklistIDs.isEmpty else {
            return [:]
        }

        var sourceRuleCounts: [String: Int] = [:]
        let withdrawnIDs = currentCatalog?.withdrawnBlocklistIDs(in: configuration) ?? []
        for sourceID in configuration.enabledBlocklistIDs.subtracting(withdrawnIDs) {
            guard let rules = cachedBlockRuleSets[sourceID] else {
                return nil
            }
            sourceRuleCounts[sourceID] = rules.count
        }

        return sourceRuleCounts
    }

    func preparedSnapshotForCurrentConfiguration() -> PreparedFilterSnapshot {
        let snapshot = currentSnapshot()
        return PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(
                configuration: configuration,
                catalog: currentCatalog
            ),
            snapshot: snapshot,
            summary: preparedSummary(for: snapshot)
        )
    }

    /// Off-main builder for the BACKGROUND publish path. Equivalent to
    /// `preparedSnapshotForCurrentConfiguration()` for the case the background guarantees —
    /// where the block rules are exactly the merge of the enabled sources' cached rule sets —
    /// so it merges ONCE and reuses that for both the snapshot and the summary rule count,
    /// dropping the redundant second merge `preparedBlocklistRuleCount()` performs.
    ///
    /// `nonisolated static` so it runs on a detached task off the main actor: the merge +
    /// `filterSnapshot` are O(rules) and must not block the main actor past the BGTask
    /// deadline (the foreground path is unaffected and still uses
    /// `preparedSnapshotForCurrentConfiguration()`/`self.blockRules`, which can differ from a
    /// fresh merge in the reuse path). All inputs are Sendable value types the caller captures
    /// on the main actor.
    nonisolated static func buildBackgroundPreparedSnapshot(
        configuration: AppConfiguration,
        cachedBlockRuleSets: [String: DomainRuleSet],
        threatGuardrail: DomainRuleSet,
        catalog: BlocklistCatalog?,
        compiledBlocklistRuleCount: Int
    ) -> PreparedFilterSnapshot {
        // Retired sources are declared omissions, never fabricated zero-rule downloads.
        // pinned: BackgroundCatalogRefreshSourceTests.testBackgroundDeclaresCatalogWithdrawals
        let withdrawnIDs = catalog?.withdrawnBlocklistIDs(in: configuration) ?? []
        let enabledIDs = configuration.enabledBlocklistIDs.subtracting(withdrawnIDs)
        let mergedBlockRules = FilterSnapshotPreparationService.mergedBlockRules(
            enabledSourceIDs: enabledIDs,
            sourceRuleSets: cachedBlockRuleSets
        )
        let snapshot = configuration.filterSnapshot(
            blockRules: mergedBlockRules,
            nonAllowableThreatRules: threatGuardrail
        )

        // Mirror preparedBlocklistRuleCount() / preparedBlocklistSourceRuleCounts(), but reuse
        // the single merge above instead of re-merging. Fail-closed: a missing enabled source
        // yields nil source counts → coversEnabledBlocklists returns false → bg-uncovered.
        let blocklistRuleCount: Int?
        let hasAllEnabledRuleSets = enabledIDs.allSatisfy { cachedBlockRuleSets[$0] != nil }
        if enabledIDs.isEmpty || hasAllEnabledRuleSets {
            blocklistRuleCount = mergedBlockRules.count
        } else if compiledBlocklistRuleCount > 0 {
            blocklistRuleCount = compiledBlocklistRuleCount
        } else {
            blocklistRuleCount = nil
        }

        let blocklistSourceRuleCounts: [String: Int]?
        if enabledIDs.isEmpty {
            blocklistSourceRuleCounts = [:]
        } else {
            var counts: [String: Int] = [:]
            var complete = true
            for sourceID in enabledIDs {
                guard let rules = cachedBlockRuleSets[sourceID] else {
                    complete = false
                    break
                }
                counts[sourceID] = rules.count
            }
            blocklistSourceRuleCounts = complete ? counts : nil
        }

        return PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: catalog),
            snapshot: snapshot,
            summary: PreparedFilterSnapshotSummary(
                snapshot: snapshot,
                blocklistRuleCount: blocklistRuleCount,
                blocklistSourceRuleCounts: blocklistSourceRuleCounts,
                // Same tier-budget total a cold compile records (block-merge + FULL guardrail + allowed
                // + blocked), so a warm switch-back to this background-published token passes the tier
                // gate instead of cold-compiling (Codex #133). nil blocklist count ⇒ nil budget ⇒
                // warm reuse falls back to cold.
                tierBudgetRuleCount: blocklistRuleCount.map {
                    $0 + threatGuardrail.count + configuration.allowedDomains.count + configuration.blockedDomains.count
                },
                quarantinedBlocklistIDs: withdrawnIDs.isEmpty ? nil : withdrawnIDs
            )
        )
    }

    // reusedPersistedArtifacts means the snapshot was decoded from and validated
    // against the on-disk artifacts, so persisting it again would rewrite
    // identical bytes (and force a pointless tunnel reload).
    struct ProtectionStartupSnapshot {
        let preparedSnapshot: PreparedFilterSnapshot
        let reusedPersistedArtifacts: Bool
    }

    func preparedSnapshotForProtectionStartup(
        trace: LatencyTrace? = nil,
        parentSpan: LatencySpan? = nil
    ) async throws -> ProtectionStartupSnapshot {
        if let reusable = await loadReusablePreparedSnapshotForProtectionStartup() {
            applyReusablePreparedSnapshot(reusable)
            catalogStatusMessage = "Using prepared local filter."
            catalogStatusIsError = false

            #if DEBUG
            logVPNDebugEvent("enable-reuse-prepared-snapshot", details: [
                "fingerprint": reusable.preparedSnapshot.identity.fingerprint,
                "blockRuleCount": "\(reusable.preparedSnapshot.snapshot.blockRules.count)",
                "allowRuleCount": "\(reusable.preparedSnapshot.snapshot.allowRules.count)",
                "guardrailRuleCount": "\(reusable.preparedSnapshot.snapshot.nonAllowableThreatRules.count)",
                "catalogVersion": reusable.cachedCatalog?.catalogVersion ?? "nil"
            ])
            #endif

            return ProtectionStartupSnapshot(
                preparedSnapshot: reusable.preparedSnapshot,
                reusedPersistedArtifacts: true
            )
        }

        if currentCatalog != nil || configuration.enabledBlocklistIDs.isEmpty {
            let preparedSnapshot = preparedSnapshotForCurrentConfiguration()

            // INV-TIER-1: this branch wraps the in-memory merge without the gated cold
            // prepare, so it must not hand an over-budget snapshot to the turn-on
            // publish. Over budget (or a nil recorded total — an under-covered build,
            // which the coverage veto would skip anyway) falls through to the gated
            // prepare below, which recomputes and throws the actionable tier error.
            if FilterRuleBudget.fitsTierBudget(
                recordedTotal: preparedSnapshot.summary.tierBudgetRuleCount,
                maxFilterRules: configuration.limits.maxFilterRules
            ) {
                #if DEBUG
                logVPNDebugEvent("enable-use-current-snapshot", details: [
                    "fingerprint": preparedSnapshot.identity.fingerprint,
                    "compiledRuleCount": "\(compiledRuleCount)",
                    // The tier gate's actual inputs, for diagnosing budget field cases.
                    "tierBudgetRuleCount": preparedSnapshot.summary.tierBudgetRuleCount.map(String.init) ?? "nil",
                    "maxFilterRules": "\(configuration.limits.maxFilterRules)",
                    "catalogVersion": currentCatalog?.catalogVersion ?? "nil"
                ])
                #endif

                return ProtectionStartupSnapshot(
                    preparedSnapshot: preparedSnapshot,
                    reusedPersistedArtifacts: false
                )
            }
        }

        #if DEBUG
        logVPNDebugEvent("enable-prepare-snapshot")
        #endif

        let prepared = try await prepareFilterSnapshot(
            for: configuration,
            customListPolicy: .cacheFirst,
            trace: trace,
            parentSpan: parentSpan
        )
        updateCustomBlocklistHashes(prepared.customResult.sourceHashes)
        applyCatalogSyncResult(prepared.catalogResult)
        return ProtectionStartupSnapshot(
            preparedSnapshot: prepared.snapshot,
            reusedPersistedArtifacts: false
        )
    }

    private func loadReusablePreparedSnapshotForProtectionStartup() async -> ReusablePreparedFilterSnapshot? {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return nil
        }

        let cacheURL = catalogCacheURL
        let configuration = configuration
        if let cacheURL {
            migrateLowRiskLaunchCacheIfNeeded(cacheURL: cacheURL)
        }

        return await Task.detached(priority: .utility) {
            // Reuse misses fall through to the full (potentially multi-second)
            // preparation pipeline, so every rejection logs its reason.
            func rejectReuse(_ reason: String) -> ReusablePreparedFilterSnapshot? {
                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "app", event: "enable-reuse-rejected", details: [
                    "reason": reason
                ])
                #endif
                return nil
            }

            let cachedCatalog = cacheURL.flatMap { cacheURL in
                try? BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL).loadCachedCatalogMetadata()
            }

            // Manifest-first gate: a non-reusable artifact set is rejected from
            // the small manifest alone, without decoding the full prepared JSON.
            // The decoded snapshot below stays the authoritative reuse check.
            let artifactStore = FilterArtifactStore(directoryURL: containerURL).readableStore()
            if let manifest = try? artifactStore.loadManifest(),
               let rejection = manifest.reuseRejectionReason(configuration: configuration, cachedCatalog: cachedCatalog) {
                // Field-level reason (names only) so a redundant cold rebuild
                // after refresh is self-diagnosing on the next device repro.
                return rejectReuse("manifest-mismatch:\(rejection)")
            }

            guard let data = try? Data(contentsOf: artifactStore.preparedSnapshotURL) else {
                return rejectReuse("prepared-snapshot-unreadable")
            }
            guard let preparedSnapshot = try? JSONDecoder().decode(PreparedFilterSnapshot.self, from: data) else {
                return rejectReuse("prepared-snapshot-undecodable")
            }

            guard preparedSnapshot.canReuseForProtectionStartup(
                configuration: configuration,
                cachedCatalog: cachedCatalog
            ) else {
                return rejectReuse(cachedCatalog == nil ? "snapshot-mismatch-no-cached-catalog" : "snapshot-mismatch")
            }

            // INV-TIER-1: same tier gate as the warm-SWITCH loader (WarmFilterSnapshotLoader).
            // The reuse identity ignores isPaid, so a downgrade never invalidates an artifact
            // compiled under Plus — without this gate every launch after a lapse keeps serving
            // the oversized filter. Over budget or legacy-nil ⇒ fall through to the startup
            // pipeline, whose gated cold prepare surfaces the actionable tier error.
            guard FilterRuleBudget.fitsTierBudget(
                recordedTotal: preparedSnapshot.summary.tierBudgetRuleCount,
                maxFilterRules: configuration.limits.maxFilterRules
            ) else {
                return rejectReuse("tier-budget")
            }

            return ReusablePreparedFilterSnapshot(
                preparedSnapshot: preparedSnapshot,
                cachedCatalog: cachedCatalog,
                // Startup reuse keeps the snapshot subset (the concurrent launch catalog sync
                // repopulates the full guardrail shortly after); only the warm SWITCH hydrates it.
                fullThreatGuardrail: nil
            )
        }.value
    }

    /// Cache-first gate for turn-on: `true` when a persisted artifact set
    /// satisfies the manifest-level reuse check for the current configuration,
    /// i.e. the VPN can start from cache without waiting on a network catalog
    /// refresh. Manifest-only (no prepared-snapshot decode) so it stays cheap on
    /// the turn-on critical path; `loadReusablePreparedSnapshotForProtectionStartup`
    /// remains the authoritative reuse check that actually loads the snapshot.
    func hasReusableArtifactForCurrentConfiguration() async -> Bool {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return false
        }

        let cacheURL = catalogCacheURL
        let configuration = configuration
        return await Task.detached(priority: .utility) {
            let cachedCatalog = cacheURL.flatMap { cacheURL in
                try? BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL).loadCachedCatalogMetadata()
            }

            let artifactStore = FilterArtifactStore(directoryURL: containerURL).readableStore()
            guard let manifest = try? artifactStore.loadManifest() else {
                return false
            }

            return manifest.reuseRejectionReason(
                configuration: configuration,
                cachedCatalog: cachedCatalog
            ) == nil
        }.value
    }

    func loadPreparedFilterSummaryForCurrentConfiguration() async -> CompactFilterSnapshotSummary? {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return nil
        }

        // Resolve through the pointer (versioned set) with root fallback, consistent
        // with the other warm-start readers; single-file read, captured once.
        let compactSnapshotURL = FilterArtifactStore(directoryURL: containerURL).readableStore().compactSnapshotURL
        let configuration = configuration

        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: compactSnapshotURL),
                  let summary = try? CompactFilterSnapshot.readSummary(from: data),
                  summary.identity.hasSameConfiguration(as: configuration),
                  summary.coversEnabledBlocklists(in: configuration)
            else {
                return nil
            }

            return summary
        }.value
    }

    func applyReusablePreparedSnapshot(_ reusable: ReusablePreparedFilterSnapshot) {
        if let catalog = reusable.cachedCatalog {
            currentCatalog = catalog
            catalogVersion = catalog.catalogVersion
            catalogGeneratedAt = catalog.generatedAt
            catalogSourcesByID = Dictionary(uniqueKeysWithValues: catalog.sources.map { ($0.id, $0) })
            catalogGuardrailEntryCount = catalog.guardrailEntryCount

            for source in catalog.sources where configuration.enabledBlocklistIDs.contains(source.id) {
                sourceStates[source.id] = .nosync
            }
        }

        blockRules = reusable.preparedSnapshot.snapshot.blockRules
        // Prefer the FULL guardrail when the caller hydrated it (the warm switch path): the snapshot's
        // nonAllowableThreatRules is only the allowlist-overlap subset, which would let
        // AllowlistValidator allow a threat domain that isn't already allowed (Codex #133 r2).
        threatGuardrail = reusable.fullThreatGuardrail ?? reusable.preparedSnapshot.snapshot.nonAllowableThreatRules
        compiledRuleCount = reusable.preparedSnapshot.summary.blockRuleCount
        protectedRuleCount = reusable.preparedSnapshot.summary.blockedDomainRuleCount
        if let blocklistRuleCount = reusable.preparedSnapshot.summary.blocklistRuleCount {
            compiledBlocklistRuleCount = blocklistRuleCount
        } else {
            refreshCompiledBlocklistRuleCount()
        }
        if compiledBlocklistRuleCount == 0, !configuration.enabledBlocklistIDs.isEmpty {
            compiledBlocklistRuleCount = estimatedBlocklistRuleCount(fromTotalRuleCount: compiledRuleCount)
        }
    }

    // Preparation (catalog sync ladder, merge, snapshot build) and artifact
    // writes run inside FilterSnapshotPreparationService, off the main actor;
    // this wrapper bridges UI progress reporting and cache migration.
    func prepareFilterSnapshot(
        for configuration: AppConfiguration,
        customListPolicy: CustomBlocklistSyncPolicy = .networkFirst,
        catalogCacheOnly: Bool = false,
        reportProgress: ((FilterPreparationProgressUpdate) async -> Void)? = nil,
        diagnosticFailureEvent: (@Sendable () -> FocusSwitchDiagnosticEvent?)? = nil,
        trace: LatencyTrace? = nil,
        parentSpan: LatencySpan? = nil
    ) async throws -> FilterSnapshotPreparationResult {
        guard let cacheURL = catalogCacheURL, let service = filterSnapshotPreparationService else {
            throw LavaSecAppError.appGroupUnavailable
        }

        migrateLowRiskLaunchCacheIfNeeded(cacheURL: cacheURL)
        let customSources = enabledCustomBlocklists(in: configuration)
        // A plan that no longer allows custom blocklists (e.g. a lapsed Plus
        // subscriber) keeps the lists it already had, but we never refresh their
        // contents from the network — the cached payload is frozen in place. This
        // is strictly cache-only (not cache-first): even a cache miss or stored-hash
        // mismatch must not fall back to a network fetch, which would re-download and
        // re-hash the frozen list. The catalog still syncs normally; only custom-list
        // fetching is held back.
        let effectiveCustomListPolicy: CustomBlocklistSyncPolicy =
            configuration.limits.allowsCustomBlocklists ? customListPolicy : .cacheOnly
        var bridgedProgress: FilterSnapshotPreparationService.ProgressHandler?
        if let reportProgress {
            bridgedProgress = { @MainActor @Sendable update in
                await reportProgress(update)
            }
        }
        return try await service.prepare(
            configuration: configuration,
            customSources: customSources,
            catalogFreshnessMaxAge: catalogSyncFreshnessInterval,
            customListPolicy: effectiveCustomListPolicy,
            catalogCacheOnly: catalogCacheOnly,
            tierRuleLimit: FilterRuleTierLimit(
                limit: configuration.limits.maxFilterRules,
                isPaid: configuration.hasLavaSecurityPlus
            ),
            diagnosticFailureEvent: diagnosticFailureEvent,
            reportProgress: bridgedProgress,
            trace: trace,
            parentSpan: parentSpan
        )
    }

    private func reportFilterPreparationProgress(
        _ reportProgress: ((FilterPreparationProgressUpdate) async -> Void)?,
        progress: Double,
        phase: FilterPreparationPhase
    ) async {
        guard let reportProgress else {
            return
        }

        await reportProgress(FilterPreparationProgressUpdate(progress: progress, phase: phase))
    }

    // Encode and writes run inside FilterSnapshotPreparationService, off the
    // main actor (the encode + compact rebuild was measured at ~1.1s for large
    // rule sets); manifest-last ordering is owned by the service.
    @discardableResult
    func persistPreparedSnapshotArtifacts(
        _ preparedSnapshot: PreparedFilterSnapshot,
        lockMode: FilterSnapshotPreparationService.PublishLockMode = .blocking,
        supersededWhileLocked: (@Sendable (_ currentPointerToken: String?) -> Bool)? = nil,
        commitBeforeFlip: (@Sendable () throws -> Void)? = nil,
        diagnosticFailureEvent: (@Sendable () -> FocusSwitchDiagnosticEvent?)? = nil
    ) async throws -> FilterSnapshotPreparationService.PublishOutcome {
        guard let containerURL = LavaSecAppGroup.containerURL,
              let service = filterSnapshotPreparationService
        else {
            throw LavaSecAppError.appGroupUnavailable
        }

        return try await service.persistArtifacts(
            preparedSnapshot,
            containerURL: containerURL,
            snapshotFilename: LavaSecAppGroup.snapshotFilename,
            compactSnapshotFilename: LavaSecAppGroup.compactSnapshotFilename,
            publishLockURL: containerURL.appendingPathComponent(LavaSecAppGroup.filterArtifactPublishLockFilename),
            lockMode: lockMode,
            supersededWhileLocked: supersededWhileLocked,
            commitBeforeFlip: commitBeforeFlip,
            diagnosticFailureEvent: diagnosticFailureEvent,
            // Keep every hosted filter's last-compiled directory alive so switching back
            // to a recently-used filter is an instant pointer flip, not a cold compile.
            additionalRetainedTokens: retainedFilterArtifactTokens()
        )
    }

    /// The versioned-artifact tokens to keep warm across a publish: EVERY non-frozen hosted
    /// filter's compiled token (active first, the most likely switch-back target). Keeping all
    /// of them warm makes switching to ANY filter — manually or via a Focus auto-switch — an
    /// instant pointer flip, never a cold compile. Frozen filters (lapsed Plus, not switchable)
    /// are excluded; the active filter's freshly-staged token is also retained by the publish
    /// itself. Disk is bounded by the tier filter cap (Free 3 / Plus 10); a disk-pressure
    /// escape hatch (LRU eviction) is a follow-on slice — see the LAV-100 plan.
    private func retainedFilterArtifactTokens() -> [String] {
        let activeID = library.activeFilterID
        var tokens: [String] = []
        if let activeToken = library.filter(id: activeID)?.lastCompiledToken {
            tokens.append(activeToken)
        }
        for filter in library.filters where filter.id != activeID {
            guard !isFilterFrozen(filter.id), let token = filter.lastCompiledToken else { continue }
            tokens.append(token)
        }
        // A background-warmed dir is referenced ONLY by the sidecar warm-index until the foreground
        // promotes it into the library, so retain those tokens too — otherwise the foreground GC would
        // reap a background-warmed artifact before it could be used or promoted (Phase 2). Retain ONLY
        // entries for filters that still exist and are switchable: the foreground doesn't rewrite the
        // sidecar on delete/freeze (background-only writer), so retaining every entry would pin dirs for
        // deleted/frozen filters until a later BGTask rewrites the sidecar (Codex #138 r5). The
        // background's own coherent rewrite already drops them; this keeps the foreground GC from
        // leaking them in the meantime.
        for (filterID, entry) in loadBackgroundWarmIndex().entries
        where library.filter(id: filterID) != nil && !isFilterFrozen(filterID) {
            tokens.append(entry.token)
        }
        return tokens
    }

    /// Compile and persist the on-disk artifact for a NON-active filter so it stays warm —
    /// a later switch (manual or, once wired, Focus-driven) is an instant pointer flip,
    /// never a cold compile. Builds the snapshot from THAT filter's four scoped fields over
    /// the current device-global config, stages its versioned artifact directory WITHOUT
    /// flipping the live (tunnel-facing) pointer, and records the filter's
    /// `lastCompiledToken`. Never touches the active configuration, the live pointer, the
    /// supersession generation, or the tunnel — so it is safe to run alongside the active
    /// switch/refresh paths. The active filter is excluded (it warms through
    /// `persistSharedState`). A filter is also skipped when it is frozen (not switchable),
    /// has custom blocklists (those refresh network-first on switch — a cache-only warm could
    /// stamp a token that warm-reuse later serves with stale custom bytes), or the catalog
    /// cache is STALE (warming cache-only from a stale catalog would stamp a token reused
    /// without a freshness recheck, running protection on old bytes; the filter instead takes
    /// the normal network-first refreshing cold path on its next switch). Best-effort: returns
    /// false on any of those, on failure, or if the filter was edited / removed / switched-to /
    /// frozen while compiling (the staged dir then ages out and a later warm pass retries).
    @discardableResult
    func warmFilterArtifact(forFilterID filterID: String) async -> Bool {
        // Foreground only: this writes filter-library.json (persistLibraryOnlyChange). A headless
        // BGTask model loaded its library at launch, so writing from it could clobber concurrent
        // foreground create/edit/delete changes — the "background refresh never writes shared state"
        // invariant. The background instead records into the sidecar warm-index
        // (warmNonActiveFiltersInBackground), never the library.
        guard !isHeadless,
              let result = await compileAndStageWarmArtifact(forFilterID: filterID) else {
            return false
        }

        // Stamp the token GC keeps warm and that switch-time reuse matches. compileAndStageWarmArtifact
        // already re-validated the filter (fields/active/frozen) and the catalog AFTER its compile, and
        // there is no await between its return and this stamp, so the filter is still the one we
        // compiled (mutateFilter is a no-op for a vanished id). Warmed filters are catalog-only, so
        // there are no custom-list hashes to reconcile.
        let previousLibrary = library
        library.mutateFilter(id: filterID) { $0.lastCompiledToken = result.token }
        let stamped = persistLibraryOnlyChange(rollingBackTo: previousLibrary)

        if stamped, let containerURL = LavaSecAppGroup.containerURL, let service = filterSnapshotPreparationService {
            // Reclaim the directory the PREVIOUS warm of this filter left behind. Each warm mints a
            // fresh generatedAt token and overwrites lastCompiledToken, and stageArtifacts never GCs,
            // so repeated warms (e.g. several draft saves without switching) would otherwise leak a
            // full artifact dir apiece until an unrelated publish collected them — breaking the
            // "disk bounded by the filter cap" invariant (Codex r14). Runs AFTER the stamp so the
            // retain set names the NEW token; the overwritten old token is no longer hosted and is
            // reaped. Retains every hosted filter's token + the live pointer; grace-window protected.
            await service.collectWarmArtifactGarbage(
                containerURL: containerURL,
                snapshotFilename: LavaSecAppGroup.snapshotFilename,
                compactSnapshotFilename: LavaSecAppGroup.compactSnapshotFilename,
                retaining: retainedFilterArtifactTokens()
            )
        }
        return stamped
    }

    /// Shared compile + stage + re-validate core for warming a NON-active filter, used by BOTH the
    /// foreground (`warmFilterArtifact` → stamps the library) and the background
    /// (`warmNonActiveFiltersInBackground` → records the sidecar). Compiles the filter's four scoped
    /// fields cache-only, stages the versioned artifact (no pointer flip), and re-validates AFTER the
    /// await — the filter's rules are byte-for-byte what we compiled, it is still non-active/non-frozen,
    /// and the catalog has not moved (canReuse) — so the returned token always names rules that match
    /// the filter's current config + the current cached catalog. Returns the staged token + its budget
    /// rule count, or nil on any miss. Records NOTHING and runs NO GC: gating on `isHeadless` and the
    /// write/GC belong to the caller. Never touches the live pointer, the active configuration, the
    /// supersession generation, or the tunnel, so it is safe alongside the active switch/refresh paths.
    private func compileAndStageWarmArtifact(forFilterID filterID: String) async -> (token: String, ruleCount: Int)? {
        guard let filter = library.filter(id: filterID),
              filterID != library.activeFilterID,
              !isFilterFrozen(filterID),
              // Catalog-only filters only: custom lists refresh network-first on switch, so a
              // cache-only warm of a custom-list filter could be reused with stale custom bytes.
              filter.customBlocklists.isEmpty,
              let cacheURL = catalogCacheURL,
              // Only warm from a FRESH catalog cache. A cache-only compile from a stale cache would
              // record a token reused WITHOUT a freshness recheck — running on old bytes until an
              // unrelated refresh. When stale, skip so the next switch takes the network-first cold path.
              BlocklistCatalogSynchronizer.hasFreshCachedCatalog(in: cacheURL, maxAge: catalogSyncFreshnessInterval),
              // Stay READ-ONLY w.r.t. the shared catalog cache: prepareFilterSnapshot runs
              // migrateLowRiskLaunchCacheIfNeeded, which can PURGE latest.json (legacy guardrails /
              // inactive GPL / missing required launch sources) expecting a follow-up SYNC a cache-only
              // warm never does — leaving NO cached catalog until a later sync, breaking offline
              // startup/warm reuse (Codex r15). Skip when a migration is pending; synchronous so
              // prepareFilterSnapshot's own (now no-op) migrate can't race in before it.
              !BlocklistCatalogSynchronizer.cachedCatalogRequiresLowRiskLaunchRefresh(
                  in: cacheURL,
                  requiredSourceIDs: DefaultCatalog.recommendedDefaultSourceIDs
              ),
              let containerURL = LavaSecAppGroup.containerURL,
              let service = filterSnapshotPreparationService else {
            return nil
        }

        // Capture the exact fields we compile so a concurrent edit/switch during the (awaiting)
        // compile can't make us record a token onto stale rules.
        let compiledEnabled = filter.enabledBlocklistIDs
        let compiledCustom = filter.customBlocklists
        let compiledBlocked = filter.blockedDomains
        let compiledAllowed = filter.allowedDomains

        var snapshotConfiguration = configuration
        snapshotConfiguration.enabledBlocklistIDs = compiledEnabled
        snapshotConfiguration.customBlocklists = compiledCustom
        snapshotConfiguration.blockedDomains = compiledBlocked
        snapshotConfiguration.allowedDomains = compiledAllowed

        do {
            // Compile against the CURRENT cache only — a warm must never trigger a catalog/custom sync
            // that advances latest.json under a concurrent switch's warm-reuse guard (a cache miss
            // just skips this warm). Freshness is the refresh path's job.
            let prepared = try await prepareFilterSnapshot(
                for: snapshotConfiguration,
                customListPolicy: .cacheOnly,
                catalogCacheOnly: true
            )
            // If the BGTask deadline passed during the (CPU-heavy) compile above, bail BEFORE staging —
            // stageArtifacts writes a versioned directory to the app group, which must not happen past
            // the system deadline (Codex #138 r3). Harmless in the foreground (its warm task is not
            // deadline-cancelled). The caller's per-iteration + pre-save guards cover the later steps.
            if Task.isCancelled { return nil }
            let pointer = try await service.stageArtifacts(
                prepared.snapshot,
                containerURL: containerURL,
                snapshotFilename: LavaSecAppGroup.snapshotFilename,
                compactSnapshotFilename: LavaSecAppGroup.compactSnapshotFilename
            )

            // Re-validate after the compile await: the filter may have been edited, deleted,
            // switched-to (now active), or frozen while we were off compiling. Only keep the token if
            // the filter still exists, is still non-active/non-frozen, and its rules are byte-for-byte
            // what we compiled — otherwise the staged dir is for stale rules and a later warm pass
            // (or a switch-time cold compile) supersedes it.
            guard let current = library.filter(id: filterID),
                  filterID != library.activeFilterID,
                  !isFilterFrozen(filterID),
                  current.enabledBlocklistIDs == compiledEnabled,
                  current.customBlocklists == compiledCustom,
                  current.blockedDomains == compiledBlocked,
                  current.allowedDomains == compiledAllowed else {
                return nil
            }

            // Also re-validate the CATALOG. A sync that advanced latest.json while we were suspended in
            // prepare/stage would leave this artifact built from the PREVIOUS catalog; warm reuse
            // validates against the current cached catalog by per-source hashes, so it would later
            // reject the token and the filter would look warm yet cold-compile on its next switch. Keep
            // only a token reuse will actually honor NOW, using the SAME check the switch reuse path
            // applies (canReuseForProtectionStartup against the freshly re-read cached catalog). On a
            // mismatch, return nil so the racing sync's reconcile — or a later switch — recompiles
            // against the new catalog (Codex r12). The re-read runs off the main actor (small JSON
            // decode), mirroring loadReusableWarmSnapshotForSwitch.
            let recheckCacheURL = cacheURL
            let currentCachedCatalog = await Task.detached(priority: .userInitiated) {
                try? BlocklistCatalogSynchronizer(cacheDirectoryURL: recheckCacheURL).loadCachedCatalogMetadata()
            }.value
            guard let currentCachedCatalog,
                  prepared.snapshot.canReuseForProtectionStartup(
                      configuration: snapshotConfiguration,
                      cachedCatalog: currentCachedCatalog
                  ) else {
                return nil
            }

            let ruleCount = prepared.snapshot.summary.tierBudgetRuleCount
                ?? prepared.snapshot.summary.blocklistRuleCount
                ?? 0
            return (pointer.token, ruleCount)
        } catch {
            return nil
        }
    }

    /// After a catalog (re)apply, bring the non-active warm set back in line with the catalog:
    /// (re)warm filters that are COLD (no token — e.g. created/edited while the cache was stale, when
    /// `warmFilterArtifact` skipped them) OR STALE (their artifact was built against older source
    /// bytes, so a switch's warm-reuse gate would reject it and cold-compile, losing the instant
    /// switch). Staleness is decided PER FILTER by the SAME cheap manifest check the switch path uses
    /// (`reuseRejectionReason`, off the main actor, no full compile) — which keys on the per-SOURCE
    /// content hashes, so it catches a source rotation even when the top-level `catalog_version`
    /// stays pinned (a plain version compare would miss that, so this deliberately does NOT debounce
    /// on the version). Only filters actually affected recompile; a no-op cache-hit apply just does
    /// the cheap manifest reads. The BACKGROUND BGTask refresh (priority-ordered/capped, for when the
    /// app isn't active) is the Phase-2 follow-up.
    func reconcileWarmNonActiveFilters() async {
        // Coalesce overlapping runs (foreground fires this on onAppear AND scene .active, plus after a catalog
        // apply): a concurrent second pass would redundantly re-scan + double-compile the same cold filters.
        // But do NOT simply drop a trigger that arrives mid-pass — a catalog apply landing while a pass is in
        // flight must still re-warm against the new catalog, or the non-active filters stay stale and a
        // closed-app Focus switch to them defers-to-cold (Codex P2). Queue a single rerun instead, mirroring
        // reconcilePendingFilterSwitch.
        guard !isReconcilingWarmNonActiveFilters else {
            pendingWarmReconcileRerun = true
            return
        }
        isReconcilingWarmNonActiveFilters = true
        defer { isReconcilingWarmNonActiveFilters = false }
        // Bound the synchronous drain to the initial pass + one rerun (same storm guard as the pending-switch
        // reconcile) so a burst of triggers can't monopolize this run; a rerun still queued at the cap is
        // re-dispatched fresh on the next tick (the defer has cleared the guard by then).
        var remainingWarmPasses = 2
        repeat {
            remainingWarmPasses -= 1
            pendingWarmReconcileRerun = false
            await reconcileWarmNonActiveFiltersOnce()
        } while pendingWarmReconcileRerun && remainingWarmPasses > 0
        if pendingWarmReconcileRerun {
            Task { @MainActor [weak self] in await self?.reconcileWarmNonActiveFilters() }
        }
    }

    /// One pass of the non-active warm reconcile. The wrapper `reconcileWarmNonActiveFilters` serializes +
    /// re-runs this; the early returns here end the PASS, not the loop.
    private func reconcileWarmNonActiveFiltersOnce() async {
        guard let containerURL = LavaSecAppGroup.containerURL else { return }

        // Snapshot the candidates on the main actor (catalog-only, non-active, non-frozen), each with
        // the configuration its artifact identity is validated against.
        let activeID = library.activeFilterID
        let baseConfiguration = configuration
        let candidates: [(id: String, token: String?, configuration: AppConfiguration)] =
            library.filters.compactMap { filter in
                guard filter.id != activeID, !isFilterFrozen(filter.id), filter.customBlocklists.isEmpty else {
                    return nil
                }
                var cfg = baseConfiguration
                cfg.enabledBlocklistIDs = filter.enabledBlocklistIDs
                cfg.customBlocklists = filter.customBlocklists
                cfg.blockedDomains = filter.blockedDomains
                cfg.allowedDomains = filter.allowedDomains
                return (filter.id, filter.lastCompiledToken, cfg)
            }
        guard !candidates.isEmpty else { return }
        let cacheURL = catalogCacheURL
        // Snapshot the sidecar so a cold/stale LIBRARY filter that the BACKGROUND already warmed can be
        // PROMOTED (a cheap library token write) instead of recompiled from scratch (Phase 2).
        let warmIndex = loadBackgroundWarmIndex()

        // Decide per filter OFF the main actor (manifest + catalog-metadata reads), mirroring
        // loadReusableWarmSnapshotForSwitch — cheap (no full prepared decode, no compile). For each
        // candidate: keep (library token still valid → omit), promote (a sidecar token is valid →
        // carry it), or recompile (neither valid → promoteToken == nil).
        let actions: [(id: String, promoteToken: String?, configuration: AppConfiguration)] =
            await Task.detached(priority: .utility) {
                let cachedCatalog = cacheURL.flatMap {
                    try? BlocklistCatalogSynchronizer(cacheDirectoryURL: $0).loadCachedCatalogMetadata()
                }
                let rootStore = FilterArtifactStore(directoryURL: containerURL)
                func isValid(_ token: String, _ configuration: AppConfiguration) -> Bool {
                    let store = FilterArtifactStore(directoryURL: rootStore.versionedDirectoryURL(token: token))
                    guard let manifest = try? store.loadManifest() else { return false }
                    return manifest.reuseRejectionReason(configuration: configuration, cachedCatalog: cachedCatalog) == nil
                }
                return candidates.compactMap { candidate in
                    if let token = candidate.token, isValid(token, candidate.configuration) {
                        return nil // library token still valid ⇒ keep
                    }
                    if let sideToken = warmIndex.token(forFilterID: candidate.id), isValid(sideToken, candidate.configuration) {
                        return (candidate.id, sideToken, candidate.configuration) // promote the background's work
                    }
                    return (candidate.id, nil, candidate.configuration) // recompile
                }
            }.value

        // Apply on the main actor. Promote is a library-only token write (the artifact dir already
        // exists from the background); recompile goes through warmFilterArtifact. Both re-validate the
        // filter's current fields/active/frozen state before committing, and the switch path re-checks
        // catalog freshness at reuse time, so a catalog move mid-reconcile self-heals via the next apply.
        for action in actions {
            if let token = action.promoteToken {
                promoteWarmTokenIntoLibrary(filterID: action.id, token: token, expectedConfiguration: action.configuration)
            } else {
                await warmFilterArtifact(forFilterID: action.id)
            }
        }
    }

    /// Promote a sidecar (background-warmed) token into `filter-library.json` so the library becomes
    /// the source of truth again and the switch path reuses it directly. A foreground-only library
    /// write (the BGTask never writes the library). Re-validates on the main actor that the filter
    /// still exists, is non-active/non-frozen, and its four scoped fields are unchanged since the
    /// off-main scan — so a concurrent edit can't promote a token for stale rules. Catalog freshness
    /// is re-checked at switch time, so promotion itself needs no fresh-catalog recheck.
    @discardableResult
    private func promoteWarmTokenIntoLibrary(
        filterID: String,
        token: String,
        expectedConfiguration: AppConfiguration
    ) -> Bool {
        guard let current = library.filter(id: filterID),
              filterID != library.activeFilterID,
              !isFilterFrozen(filterID),
              current.enabledBlocklistIDs == expectedConfiguration.enabledBlocklistIDs,
              current.customBlocklists == expectedConfiguration.customBlocklists,
              current.blockedDomains == expectedConfiguration.blockedDomains,
              current.allowedDomains == expectedConfiguration.allowedDomains else {
            return false
        }
        guard current.lastCompiledToken != token else { return true } // already promoted
        let previousLibrary = library
        library.mutateFilter(id: filterID) { $0.lastCompiledToken = token }
        return persistLibraryOnlyChange(rollingBackTo: previousLibrary)
    }

    /// Cheap PRE-compile UPPER-BOUND estimate of a non-active filter's rule count, summed from the
    /// catalog's per-source entry counts, the catalog's GUARDRAIL entry counts, and the filter's own
    /// blocked/allowed domains. Used to enforce the background per-run budget before the expensive
    /// compile (Codex #138 r4). It is only an upper bound: overlapping sources are NOT deduplicated,
    /// so it can OVER-count (the actual compiled count is ≤ this and ≤ the tier cap). Callers must
    /// therefore cap it at the budget and guarantee the coldest candidate one attempt, or an
    /// over-counted filter would be starved (panel finding). An unknown source falls back to its
    /// cached rule-set size, else 0.
    ///
    /// **The guardrail term is what makes this commensurate with what the budget accumulates.** The
    /// warm compile's `loadCached` takes `includesGuardrails` at its DEFAULT of true and does not
    /// gate it on the filter having allowed domains, so every warm compile parses the full guardrail
    /// union; and the figure the caller adds to `rulesCompiled` afterwards is
    /// `PreparedFilterSnapshot.summary.tierBudgetRuleCount`, which by its own definition is merged
    /// block rules **plus the FULL guardrail rule set** plus allowed plus blocked. Omitting
    /// guardrails here therefore compared a smaller quantity against a budget spent in a larger one:
    /// a filter estimated under the app-refresh ceiling could compile substantially past it, overrun
    /// a ~30 s fetch window, and come back as the coldest candidate on the next run — the repeated
    /// expiration that makes iOS throttle the identifier (Codex review, PR #646). It is a per-compile
    /// constant, not a per-filter one, which is exactly why it went unnoticed: it shifts every
    /// candidate equally and changes no ordering, only the level the budget is measured at.
    /// pinned: BackgroundWarmTopUpSourceTests.testTheEstimateCountsTheCatalogGuardrails
    private func estimatedRuleCount(forFilterID filterID: String) -> Int {
        guard let filter = library.filter(id: filterID) else { return 0 }
        var total = filter.blockedDomains.count + filter.allowedDomains.count + catalogGuardrailEntryCount
        for id in filter.enabledBlocklistIDs {
            total += catalogSourcesByID[id]?.entryCount ?? cachedBlockRuleSets[id]?.count ?? 0
        }
        return total
    }

    /// The `BGAppRefreshTask` top-up's entry point: re-warm non-active filters from the catalog
    /// cache ALREADY HELD, with no sync and no network.
    ///
    /// Deliberately NOT gated on the `bg-published` condition the catalog refresh applies before
    /// its own warm pass. That condition exists because after a SYNC you cannot trust
    /// `latest.json` unless the sync committed it — a warm compiled against a non-committed
    /// catalog would record a token whose freshness gate is unreliable. This path runs no sync, so
    /// `latest.json` is simply the last committed catalog, and the decision belongs to
    /// `compileAndStageWarmArtifact`'s own `hasFreshCachedCatalog` gate: a stale cache warms
    /// nothing and the next switch takes the network-first cold path, which is correct.
    ///
    /// See `BackgroundWarmTopUp` for why the index needs topping up more often than every 12
    /// hours, and `lavasec-infra` `plans/2026-09-03-warm-index-coverage-plan.md` Task 4.
    /// pinned: BackgroundWarmTopUpSourceTests.testTheTopUpWarmsFromTheHeldCacheWithoutSyncing
    func topUpWarmIndexFromCachedCatalog() async {
        guard isHeadless else { return }
        logVPNDebugEvent("warm-topup-begin", details: [:])
        // LOAD THE CATALOG BEFORE THE PASS, or its budget guard is a no-op on this path.
        //
        // `estimatedRuleCount` sums `catalogSourcesByID[id]?.entryCount ?? cachedBlockRuleSets[id]?
        // .count ?? 0`, and BOTH dictionaries are populated only by a sync (`applyCatalogSyncResult`)
        // or a prepared-snapshot apply (`applyReusablePreparedSnapshot`). This handler builds its
        // view model with `loadVPNState: false` — so the launch-time `loadCachedCatalogIfAvailable`
        // never runs — and then deliberately runs no sync, leaving both empty. The estimate would
        // collapse to the filter's own blocked/allowed domain counts, a couple of dozen rules for a
        // filter that may compile two million, and the pre-compile skip would never fire.
        //
        // The run would still be bounded, by the post-compile `rulesCompiled >= perRunRuleBudget`
        // break — but that is precisely the "compile first, discover it was too big afterwards"
        // shape the pre-estimate was added to prevent. A `BGProcessingTask` can absorb one oversized
        // compile; a fetch window gets roughly thirty seconds, and repeated expirations are what
        // makes iOS throttle an identifier. Reading the cached catalog is a disk decode with no
        // network, which is what this window IS for (Codex review, PR #646).
        //
        // NOT `loadCachedCatalogIfAvailable()`, which an earlier revision of this PR used and which
        // would have been DESTRUCTIVE here: it begins with `migrateLowRiskLaunchCacheIfNeeded`, and
        // that REMOVES `latest.json` whenever the cache predates a required launch source. The
        // launch path can do that because `syncCatalogIfStale()` follows it and re-fetches; this
        // handler deliberately runs no sync, so a read-only background top-up would have erased the
        // last committed catalog and broken offline startup and every warm reuse until some later
        // network refresh (Codex review, PR #646). Seeding the estimate needs a READ, so this does
        // only the read.
        await seedCatalogSourcesForRuleEstimateWithoutMigration()
        await warmNonActiveFiltersInBackground(window: .appRefresh)
    }

    /// Populate `catalogSourcesByID` and `catalogGuardrailEntryCount` from the PERSISTED catalog, and
    /// nothing else.
    ///
    /// `estimatedRuleCount` reads both to size a filter before compiling it. The launch-time
    /// loader that normally fills them also runs a cache migration that can DELETE `latest.json`, and
    /// is paired with a sync that repairs the deletion — a pairing a no-sync background handler
    /// cannot honour. This reads the same metadata the warm pass's own scan already reads, off the
    /// main actor, and writes only what the estimate needs (PR #646).
    ///
    /// Both halves matter: `sources` sizes the filter's own enabled lists, and `guardrails` sizes the
    /// work every compile does regardless of what the filter enables. Seeding one without the other
    /// is what made the app-refresh budget measure a smaller quantity than it spent — see
    /// `estimatedRuleCount`.
    ///
    /// Deliberately does not touch `currentCatalog`, `catalogVersion`, `cachedBlockRuleSets` or any
    /// status text: this is a short-lived headless model whose launch-time state must not be
    /// persisted over newer on-disk state, and a wider apply is how that happens by accident.
    /// pinned: BackgroundWarmTopUpSourceTests.testTheTopUpSeedsTheEstimateWithoutMigratingTheCache
    private func seedCatalogSourcesForRuleEstimateWithoutMigration() async {
        guard let cacheURL = catalogCacheURL else { return }
        let catalog = await Task.detached(priority: .utility) { () -> BlocklistCatalog? in
            let synchronizer = BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL)
            return try? synchronizer.loadCachedCatalogMetadata()
        }.value
        guard let catalog else { return }
        // Seeded independently of the sources: a catalog can carry guardrails with an empty or
        // unusable `sources` array, and the guardrail term is the one every candidate pays.
        catalogGuardrailEntryCount = catalog.guardrailEntryCount
        guard !catalog.sources.isEmpty else { return }
        catalogSourcesByID = Dictionary(
            catalog.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Single-flight wrapper around the sidecar warm pass.
    ///
    /// THIS PR ADDS THE INDEX'S SECOND WRITER, and that is the whole of its risk. Before it, the
    /// pass had exactly one caller — `BGProcessingTask` `com.lavasec.catalog-refresh` — and iOS does
    /// not re-enter a single identifier while a run is outstanding, so single-writer held by
    /// construction rather than by any guard in the method. A `BGAppRefreshTask` can run alongside
    /// that processing task, and both of the pass's writes replace the whole sidecar, so two
    /// concurrent runs computing from the same `prior` end with the later write dropping the
    /// earlier one's freshly staged entries: fewer warm artifacts, the exact condition the pass
    /// exists to remove (Codex review, PR #646 and `lavasec-infra` infra #209).
    ///
    /// An in-process actor would NOT be sufficient — the two handlers may be in different `BGTask`
    /// lifetimes — so this is an app-group `flock`, degrade-ABORT: a contended run does nothing
    /// rather than waiting (a BGTask has no budget to wait) or proceeding unlocked. `flock` is
    /// released on process death, so a jetsammed holder cannot wedge it.
    ///
    /// **The catalog basis moving mid-pass is deliberately NOT guarded here, and that is not an
    /// oversight.** A pass can compile against catalog G0 and save while G1 is committed, recording
    /// tokens whose basis is already superseded. Those entries are harmless: every reader
    /// re-validates the token it finds — `WarmFilterSnapshotLoader.loadReusableUnwrapped` runs the
    /// manifest gate against the CURRENT cached catalog before it will reuse anything — so a stale
    /// entry costs one deferral and is replaced by the next pass. The same reasoning already
    /// licenses the un-revalidated carry-overs below. Adding a basis re-check before the save would
    /// narrow a window that leads nowhere; the lost-update race above is the one with a durable
    /// wrong outcome, and the lock closes it.
    /// pinned: BackgroundWarmTopUpSourceTests.testTheWarmPassIsSingleFlightAcrossProcesses
    func warmNonActiveFiltersInBackground(
        window: BackgroundWarmPassWindow
    ) async {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return
        }
        // IN-PROCESS EXCLUSION FIRST, and it is not redundant with the flock below.
        //
        // The two BGTask handlers each build their OWN `AppViewModel`, and iOS runs both in the
        // app process — so same-process concurrency is the LIKELY case here, not the exotic one.
        // On Darwin an `flock` held by one process via a different descriptor does not reliably
        // conflict with itself; `FilterPublishLockTests`' cross-process proof spawns a child
        // process for exactly that reason. So the file lock alone would let the common case
        // straight through. A static flag, checked and set synchronously on the main actor with no
        // suspension between the two, closes it; the flock then covers the case the flag cannot
        // see — two launches, or a handler surviving into a new process (PR #646).
        // A CONTENDED PASS REQUESTS A RERUN RATHER THAN BEING DROPPED, because the two callers are
        // not equally valuable and abort-on-contention silently prefers the wrong one. The catalog
        // refresh's post-publish pass is the HIGH-value one: the commit it follows invalidated
        // every warm artifact at once, so if the top-up happens to hold the flag when it arrives,
        // discarding it leaves the newly committed catalog with no warm coverage at all — and the
        // top-up's own artifacts, built for the PREVIOUS catalog, are now rejected by the reuse
        // gate. The index would be emptier than before either pass ran (Codex review, PR #646).
        //
        // Same shape as `reconcileWarmNonActiveFilters`'s `pendingWarmReconcileRerun`: the holder
        // re-runs once on the way out. Bounded to ONE rerun so two handlers cannot ping-pong, and
        // the rerun is cancellation-gated like every other app-group mutation here.
        if Self.isWarmPassInFlight {
            guard let waitBudget = window.contentionWaitBudget else {
                // The short window hands its work over: no budget to wait, and a top-up the next
                // window can repeat.
                Self.warmPassRerunRequestedWindow = Self.widerWarmWindow(
                    Self.warmPassRerunRequestedWindow, window)
                logVPNDebugEvent(
                    "warm-pass-deferred",
                    details: ["reason": "contended-in-process", "window": window.rawValue])
                return
            }
            // The LONG window waits instead, because handing over is not safe for it: the holder may
            // be the short window, which can expire mid-pass and take the queued rerun with it —
            // and by then this caller has returned past its only warm call, leaving the catalog it
            // just published with no warm coverage at all (Codex review, PR #646).
            //
            // The BUDGET is what makes waiting the answer rather than a gesture: it outlasts the
            // only in-process holder this can be waiting on (an `.appRefresh` pass, bounded by the
            // system's fetch-window ceiling), so a holder that finishes at all is waited out. See
            // `BackgroundWarmPassWindow.contentionWaitBudget` — an earlier revision's shorter budget
            // sat below that ceiling, and the expiry below was then the NORMAL outcome rather than
            // the anomaly it is meant to be.
            guard await waitForWarmPassToFinish(within: waitBudget) else {
                // Still held after the holder's own system ceiling — so the holder is not releasing
                // on any bounded schedule and waiting longer cannot help. Leave the request rather
                // than nothing: it is strictly better than dropping the pass, and it is drained by
                // the next processing window.
                //
                // BE HONEST ABOUT WHAT THIS COSTS. Nothing in THIS cycle will run it: an
                // `.appRefresh` holder correctly refuses to drain a `.processing` request (running
                // post-publish work at the fetch budget is the livelock the window split prevents),
                // and the next `.processing` pass needs another `bg-published` cycle. So reaching
                // here means the freshly committed catalog goes without its refill until a later
                // publish or a foreground reconcile — the same residual as the `bg-published` gate
                // itself, recorded on `BackgroundWarmPassWindow.appRefreshRuleBudget` (Codex review,
                // PR #646). The budget above is sized so this is reached only when the holder has
                // outlived its own window, not on an ordinary contended cycle.
                //
                // The window is carried, not just the fact of a request: servicing this under the
                // holder's own policy would run the post-publish refill at the fetch window's budget
                // and with its oversized-candidate refusal (Codex review, PR #646).
                Self.warmPassRerunRequestedWindow = Self.widerWarmWindow(
                    Self.warmPassRerunRequestedWindow, window)
                logVPNDebugEvent(
                    "warm-pass-deferred",
                    details: ["reason": "contention-wait-expired", "window": window.rawValue])
                return
            }
        }
        Self.isWarmPassInFlight = true
        defer { Self.isWarmPassInFlight = false }

        let lockURL = containerURL.appendingPathComponent(
            LavaSecAppGroup.backgroundWarmIndexLockFilename)
        guard let descriptor = FilterPublishLock.tryAcquireExclusiveDescriptor(at: lockURL) else {
            // Cross-PROCESS contention: no in-process holder will drain a rerun flag, so this one
            // genuinely aborts. The other process is mid-pass against the same on-disk state.
            logVPNDebugEvent("warm-pass-skipped", details: ["reason": "contended"])
            return
        }
        defer { FilterPublishLock.releaseDescriptor(descriptor) }

        // A PENDING REQUEST IS CONSUMED ONLY BY A WINDOW THAT CAN SATISFY IT, and otherwise left
        // alone. Two ways to get this wrong, and an earlier revision of this PR managed both:
        //
        // - Clearing unconditionally here discards a `.processing` request that a cancelled owner
        //   deliberately retained, whenever the next acquirer happens to be a fetch task — so the
        //   post-publish refill is lost after all (Codex review, PR #646).
        // - Running it under the requested window regardless would have a fetch task execute
        //   `.processing` policy: tier-cap budget, oversized coldest candidate admitted, inside a
        //   ~30 s window. That is the livelock the window split exists to prevent.
        //
        // So: a `.processing` pass satisfies either request; a `.appRefresh` pass satisfies only an
        // `.appRefresh` request and leaves a processing one standing for the next processing window.
        if Self.widerWarmWindow(Self.warmPassRerunRequestedWindow, window) == window {
            Self.warmPassRerunRequestedWindow = nil
        }
        await warmNonActiveFiltersInBackgroundUnderLock(window: window)
        // Drain a request that arrived while this pass ran — in OUR window, which is only reached
        // when it satisfies the request. Once: a second rerun would be recomputing against state no
        // newer than this one just read.
        //
        // The request is deliberately NOT cleared when this owner is cancelled — one made by a
        // still-live caller must outlive the expiry of whoever happened to hold the pass, so a
        // later window drains it instead of it vanishing with us.
        if let requested = Self.warmPassRerunRequestedWindow,
           !Task.isCancelled,
           Self.widerWarmWindow(requested, window) == window {
            Self.warmPassRerunRequestedWindow = nil
            logVPNDebugEvent(
                "warm-pass-rerun",
                details: ["window": requested.rawValue, "owner": window.rawValue])
            await warmNonActiveFiltersInBackgroundUnderLock(window: window)
        }
    }

    /// Waits, in bounded steps, for an in-process warm pass to release the flag.
    ///
    /// Polling rather than a continuation because the holder is a `BGTask` that can be cancelled or
    /// expire without ever reaching a resume point — a continuation it never resumes would hang
    /// this caller for its whole window, which is the failure this wait exists to avoid.
    private func waitForWarmPassToFinish(within budget: TimeInterval) async -> Bool {
        let stepNanoseconds: UInt64 = 250_000_000
        let deadline = Date().addingTimeInterval(budget)
        while Self.isWarmPassInFlight {
            if Task.isCancelled || Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: stepNanoseconds)
        }
        return !Task.isCancelled
    }

    /// The background (BGTask) warm pass itself, run with the single-flight wrapper's flag and lock
    /// already held. With the active filter just republished and the cache fresh, warm the NON-active
    /// filters too so a later Focus-driven switch is an instant pointer-flip. Headless-safe: it
    /// records each warmed filter in the SIDECAR warm-index, NEVER in filter-library.json (which the
    /// background must not write). Ordered most-stale-first (by the sidecar's last `syncedAt`;
    /// never-warmed sorts first) so a tight BGTask budget spends on the filters most out of date; the
    /// rest are picked up on later runs. Rewrites the sidecar coherently each run: this run's fresh
    /// entries plus carry-over of prior entries for filters still eligible that we did not re-warm,
    /// dropping entries for filters that are gone, now active/frozen, or already warm in the library
    /// (i.e. promoted). One GC after the loop.
    ///
    /// The per-run ceiling is the WINDOW's, not one constant: `BackgroundWarmPassWindow` sizes both
    /// the budget and the admission rule from the length of the window this pass is running in. An
    /// earlier revision of this comment said "capped per run at the free-tier rule ceiling", which
    /// stopped being true once the budget became tier-sized and then window-sized (PR #646).
    private func warmNonActiveFiltersInBackgroundUnderLock(
        window: BackgroundWarmPassWindow
    ) async {
        // Sidecar warming is the BGTask's job; the foreground warms via the library path
        // (warmFilterArtifact). This also keeps the library strictly foreground-owned.
        guard isHeadless,
              let containerURL = LavaSecAppGroup.containerURL,
              let cacheURL = catalogCacheURL,
              let store = backgroundWarmIndexStore,
              let service = filterSnapshotPreparationService else {
            return
        }
        // AUTHORITATIVE STATE, OR NO WRITE (INV-PERSIST-1). This pass enumerates candidates from the
        // in-memory library and then rewrites the sidecar WHOLESALE, so running it against the
        // placeholder a pre-first-unlock launch seeds would drop every real warm entry the user has.
        // Every peer write path guards on this flag (see `persistExplicitProtectionIntent` and the
        // library save paths); the catalog refresh inherits the protection structurally, because its
        // warm pass runs only after a publish that degrade-ABORTs on unreadable state. A sync-free
        // top-up has no such publish in front of it, so it needs the guard stated here — and stating
        // it here rather than at the entry point covers BOTH callers (PR #646).
        guard !sharedStateUnavailableAtLoad else {
            logVPNDebugEvent("warm-pass-skipped", details: ["reason": "shared-state-unreadable"])
            return
        }
        // AND A RESEEDED LIBRARY IS PLACEHOLDER STATE TOO, by a different door. A usable but
        // old-schema or generation-losing library is reseeded to defaults by
        // `loadOrMigrateFilterLibrary` WITHOUT raising `sharedStateUnavailableAtLoad` — the state
        // is readable, it is just not the user's yet, pending a foreground launch that commits the
        // migration. `publishBackgroundRefreshArtifacts` already refuses on this flag
        // (`bg-premigration`); the unreadable guard above does not cover it, so a wholesale sidecar
        // rewrite would drop entries for the still-persisted filters and add entries no on-disk
        // switch can address (Codex review, PR #646).
        guard !didReseedFilterLibraryOnLastLoad else {
            logVPNDebugEvent("warm-pass-skipped", details: ["reason": "library-reseeded"])
            return
        }
        // Honor the BGTask deadline up front: cancellation can be delivered at the caller's `await`
        // into this method, and the candidates/empty-candidates prefix below is synchronous, so without
        // this guard the empty-candidates branch could still rewrite the sidecar past the deadline
        // (panel finding). Every app-group mutation in this method stays behind a !Task.isCancelled gate.
        guard !Task.isCancelled else { return }

        // THE CATALOG IS ALREADY COMMITTED WHEN THIS RUNS, by either of its two callers, and this pass
        // deliberately does not touch latest.json's mtime.
        //
        // The catalog-refresh caller reaches here only on `bg-published`, where the background just
        // COMMITTED the fresh catalog. The `BGAppRefreshTask` top-up runs no sync at all, so
        // latest.json is simply the last committed catalog. In both cases
        // `compileAndStageWarmArtifact`'s own `hasFreshCachedCatalog` gate decides whether that
        // catalog is fresh enough to warm against — a stale cache warms nothing and the next switch
        // takes the network-first cold path, which is correct.
        //
        // We do NOT bump the mtime here: latest.json is only trustworthy-current on a commit or on
        // the sync's NETWORK-VERIFIED unchanged re-stamp (`BlocklistCatalogSynchronizer.sync`'s
        // attribute-only refresh), and both of those already moved it; this warm pass verified
        // nothing upstream and must not fake it.
        let activeID = library.activeFilterID
        let prior = store.load()

        // Snapshot eligible candidates (non-active, non-frozen, catalog-only) with the config their
        // artifact identity is validated against, on the main actor.
        let baseConfiguration = configuration
        let candidates: [(id: String, token: String?, configuration: AppConfiguration)] =
            library.filters.compactMap { filter in
                guard filter.id != activeID, !isFilterFrozen(filter.id), filter.customBlocklists.isEmpty else {
                    return nil
                }
                var cfg = baseConfiguration
                cfg.enabledBlocklistIDs = filter.enabledBlocklistIDs
                cfg.customBlocklists = filter.customBlocklists
                cfg.blockedDomains = filter.blockedDomains
                cfg.allowedDomains = filter.allowedDomains
                return (filter.id, filter.lastCompiledToken, cfg)
            }
        guard !candidates.isEmpty else {
            // No eligible filters: still rewrite the sidecar to drop any now-ineligible entries.
            try? store.save(BackgroundWarmIndex())
            return
        }

        // Classify each eligible candidate OFF the main actor by whether its LIBRARY token and/or its
        // SIDECAR token are still valid for the current catalog (the same manifest check the switch path
        // uses). A filter needs (re)warming only when NEITHER is valid — keying on the sidecar too means
        // the background doesn't recompile a filter it (a prior run) already warmed every single run,
        // and a mis-estimated oversized filter overshoots the budget at most ONCE rather than on every
        // run (Codex #138 r8).
        let scan: [(id: String, libraryValid: Bool, sidecarValid: Bool)] = await Task.detached(priority: .utility) {
            let cachedCatalog = (try? BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL).loadCachedCatalogMetadata())
            let rootStore = FilterArtifactStore(directoryURL: containerURL)
            func tokenValid(_ token: String?, _ configuration: AppConfiguration) -> Bool {
                guard let token else { return false }
                let store = FilterArtifactStore(directoryURL: rootStore.versionedDirectoryURL(token: token))
                guard let manifest = try? store.loadManifest() else { return false }
                return manifest.reuseRejectionReason(configuration: configuration, cachedCatalog: cachedCatalog) == nil
            }
            return candidates.map { candidate in
                (candidate.id,
                 tokenValid(candidate.token, candidate.configuration),
                 tokenValid(prior.token(forFilterID: candidate.id), candidate.configuration))
            }
        }.value

        // To COMPILE: neither token valid (cold or stale in both stores), most-stale-first by the
        // sidecar's last syncedAt (never-warmed ⇒ .distantPast ⇒ coldest, warmed first).
        let needsWarming: [String] = scan
            .filter { !$0.libraryValid && !$0.sidecarValid }
            .sorted { (prior.syncedAt(forFilterID: $0.id) ?? .distantPast) < (prior.syncedAt(forFilterID: $1.id) ?? .distantPast) }
            .map(\.id)
        // Carry-over base: every filter whose LIBRARY token is invalid keeps its prior sidecar entry
        // (it's still the best warm we have) unless replaced this run — including those skipped from
        // warming because their SIDECAR token is already valid. Filters with a valid library token are
        // excluded, so they're dropped (the library owns them).
        let invalidLibraryIDs = Set(scan.filter { !$0.libraryValid }.map(\.id))

        // Warm capped + most-stale-first, recording each in the new sidecar. Respect the BGTask
        // deadline (Task.isCancelled) and the per-run rule budget, which is enforced BEFORE the
        // expensive compile via a cheap pre-estimate (Codex #138 r6). Skip — don't break — a filter
        // that wouldn't fit what remains, so a smaller later one can still use it.
        //
        // WHAT COUNTS AS FITTING NOW DEPENDS ON THE WINDOW, and `BackgroundWarmPassWindow` owns that
        // decision so the two callers cannot drift apart in how they read the same numbers. The long
        // window keeps the tier cap and keeps admitting the coldest candidate whatever its estimate
        // (a heavy-overlap filter would otherwise be starved forever, and its post-compile break
        // still bounds the run); the fetch window does neither, because there the concession is the
        // failure mode rather than the fix. See that type for both rationales.
        // WINDOW-SIZED, not one constant for both callers. The fetch window cannot afford the tier
        // cap, and — more importantly — cannot afford the long window's "always admit the coldest
        // candidate" concession: the coldest sorts first, so an oversized filter would be attempted
        // first, fail to finish, and its expiration would discard the whole run's sidecar write,
        // with the next window selecting the same filter again (Codex review, PR #646).
        let tierRuleCap = configuration.limits.maxFilterRules
        let perRunRuleBudget = window.perRunRuleBudget(tierRuleCap: tierRuleCap)
        var newEntries: [String: BackgroundWarmIndexEntry] = [:]
        var rulesCompiled = 0
        // Counted so a refusal is VISIBLE rather than silent. A filter the fetch window is too
        // short for is not stranded — the next bg-published processing pass has the whole tier cap,
        // and the foreground reconcile has no cap at all — but "this window keeps declining the
        // same filter" is exactly the shape a reader needs to see when a switch keeps deferring
        // (Codex review, PR #646).
        var candidatesRefusedForBudget = 0
        let warmedAt = Date()
        for id in needsWarming {
            if Task.isCancelled { break }
            // The estimate is overlap-inflated and dedup-free, so it is an UPPER bound; how much
            // slack that earns depends on the window (see `BackgroundWarmPassWindow.admitsCandidate`).
            guard window.admitsCandidate(
                estimatedRuleCount: estimatedRuleCount(forFilterID: id),
                rulesCompiled: rulesCompiled,
                tierRuleCap: tierRuleCap
            ) else {
                candidatesRefusedForBudget += 1
                continue
            }
            guard let result = await compileAndStageWarmArtifact(forFilterID: id) else { continue }
            newEntries[id] = BackgroundWarmIndexEntry(token: result.token, syncedAt: warmedAt)
            rulesCompiled += result.ruleCount
            // The pre-estimate can UNDER-estimate (a cached source's local payload rotated beyond the
            // catalog entryCount), letting an actually-over-budget filter through. Stop once the ACTUAL
            // accumulated rules reach the cap so a single underestimated filter can't drag the run into
            // compiling more past it (Codex #138 r8). The just-compiled filter is still recorded — its
            // work is done and it's a valid warm; we simply don't start another compile.
            if rulesCompiled >= perRunRuleBudget { break }
        }

        if candidatesRefusedForBudget > 0 {
            // `guardrailRules` is here to separate the two ways a run refuses everything, which
            // otherwise look identical from a capture. `estimatedRuleCount` adds this catalog-wide
            // constant to EVERY candidate (the compile pays it whatever the filter enables), so a
            // guardrail set large relative to the budget refuses the whole field on its own, and no
            // per-filter reading explains it. That is not a bug when it happens — a compile that
            // really does process that many rules cannot finish a fetch window, and refusing beats
            // overrunning it and having iOS throttle the identifier — but it IS the difference
            // between "these filters are too big" and "this window can no longer warm anything",
            // and only the first is fixed by waiting for a bigger window (PR #646).
            logVPNDebugEvent("warm-pass-budget-refusals", details: [
                "window": window.rawValue,
                "refused": "\(candidatesRefusedForBudget)",
                "perRunRuleBudget": "\(perRunRuleBudget)",
                "guardrailRules": "\(catalogGuardrailEntryCount)"
            ])
        }

        // If the BGTask deadline passed mid-pass, do NOT mutate the app-group further — skip the sidecar
        // rewrite and GC so nothing runs past the system deadline (Codex #138 r2). Any artifacts staged
        // this run are grace-window-protected and reaped by a later run's GC, so skipping leaks nothing.
        guard !Task.isCancelled else { return }

        // Coherent wholesale rewrite: this run's fresh entries + carry-over of prior entries for every
        // filter whose LIBRARY token is invalid (it still relies on the sidecar) that we did NOT replace
        // this run. Keying carry-over on `invalidLibraryIDs` (NOT `needsWarming`) is essential now that
        // `needsWarming` excludes filters with an already-valid SIDECAR token: those skipped-but-warm
        // filters must keep their prior entry, and a stale-library-token filter not reached this run
        // (cap) keeps its still-usable warm rather than being dropped and then GC'd (Codex #138). Filters
        // with a VALID library token are excluded (dropped — the library owns them); gone/active/frozen
        // filters never entered the scan. Carry-overs aren't re-validated — the read path re-checks every
        // token, so a stale carry-over is harmless and self-heals next run.
        let warmedThisRun = Set(newEntries.keys)
        var rewritten = newEntries
        for id in invalidLibraryIDs where !warmedThisRun.contains(id) {
            if let carried = prior.entries[id] { rewritten[id] = carried }
        }
        try? store.save(BackgroundWarmIndex(entries: rewritten))

        // Re-check the deadline immediately before the GC: collectWarmArtifactGarbage is an `await` into
        // the preparation actor (a suspension point), so a cancellation that lands between the post-loop
        // guard above and here would otherwise let the GC removeItem app-group directories past the
        // system deadline (panel finding — the TOCTOU the staging/save guards already close elsewhere).
        guard !Task.isCancelled else { return }

        // One GC after the loop: retain (in-memory library + just-written sidecar + live pointer) UNION
        // the CURRENT on-disk library tokens. The on-disk union is essential here: a foreground
        // create/edit/warm during this (potentially slow) headless pass writes tokens our launch-time
        // in-memory snapshot doesn't have, and once that foreground-staged dir ages out of the grace
        // window the GC would otherwise reap a dir the live library references (Codex #138 r7).
        // grace-window protected for very recent stages on top of that.
        let retain = retainedFilterArtifactTokens() + persistedLibraryArtifactTokens()
        await service.collectWarmArtifactGarbage(
            containerURL: containerURL,
            snapshotFilename: LavaSecAppGroup.snapshotFilename,
            compactSnapshotFilename: LavaSecAppGroup.compactSnapshotFilename,
            retaining: retain
        )
    }


    /// Whether a background warm pass is running in THIS process. `@MainActor`-confined, so the
    /// check-and-set in `warmNonActiveFiltersInBackground` is atomic — there is no suspension point
    /// between them. Static rather than an instance property because each BGTask handler builds its
    /// own `AppViewModel`, so an instance flag would never see the other pass (PR #646).
    static var isWarmPassInFlight = false

    /// The window a queued rerun is owed IN, or `nil` when none is owed.
    ///
    /// A bare Bool was not enough: the holder would service a queued request under ITS OWN window,
    /// so a processing caller whose wait expired had its post-publish refill run with the fetch
    /// window's 400 k budget and oversized-candidate refusal — the high-value pass executed under
    /// the policy chosen for the cheap one (Codex review, PR #646). When two requests overlap the
    /// more capable window wins, since running the wider policy also satisfies the narrower.
    /// `@MainActor`-confined like the in-flight flag it accompanies.
    static var warmPassRerunRequestedWindow: BackgroundWarmPassWindow?

    /// The more capable of two windows — the one whose pass also covers what the other would do.
    static func widerWarmWindow(
        _ lhs: BackgroundWarmPassWindow?, _ rhs: BackgroundWarmPassWindow
    ) -> BackgroundWarmPassWindow {
        guard let lhs else { return rhs }
        return (lhs == .processing || rhs == .processing) ? .processing : rhs
    }

    /// The sidecar warm-index store, or nil if the App Group container is unavailable. The background
    /// BGTask is the only writer; the foreground reads it for the switch read-fallback, GC retention,
    /// and reconcile promotion.
    var backgroundWarmIndexStore: BackgroundWarmIndexStore? {
        backgroundWarmIndexURL.map(BackgroundWarmIndexStore.init(fileURL:))
    }

    /// The currently persisted sidecar warm-index (empty on a miss). Cheap JSON read; callers that
    /// need it more than once in a tight scope should snapshot the result.
    func loadBackgroundWarmIndex() -> BackgroundWarmIndex {
        backgroundWarmIndexStore?.load() ?? BackgroundWarmIndex()
    }

    /// Every `lastCompiledToken` recorded in the CURRENT on-disk `filter-library.json` (empty on a
    /// miss/decode failure). The headless BGTask loads its in-memory library once at launch, so a
    /// foreground create/edit/warm during a long background pass writes tokens this process can't see;
    /// the background GC unions these on-disk tokens into its retain set so it never reaps a directory
    /// the live library references (Codex #138 r7). Not eligibility-filtered: anything the live library
    /// names must be retained (over-retaining is safe; under-retaining reaps a referenced dir).
    func persistedLibraryArtifactTokens() -> [String] {
        guard let url = filterLibraryURL,
              let data = try? Data(contentsOf: url),
              let persisted = try? JSONDecoder().decode(FilterLibrary.self, from: data) else {
            return []
        }
        return persisted.filters.compactMap(\.lastCompiledToken)
    }

    private var backgroundWarmIndexURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.backgroundWarmIndexFilename)
    }


}
