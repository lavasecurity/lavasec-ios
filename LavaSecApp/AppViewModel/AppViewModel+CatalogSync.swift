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
    // MARK: - Blocklist catalog sync

    func syncCatalog(isBackgroundRefresh: Bool = false) async {
        await catalog.sync(isBackgroundRefresh: isBackgroundRefresh)
    }

    func performCatalogSyncTransaction(
        isBackgroundRefresh: Bool,
        operationID: LatencyOperationID
    ) async -> CatalogSyncTransactionResult {
        let trace = makeLatencyTrace(operationID: operationID, operationKind: "refreshLists")
        let span = trace.beginSpan("action.refreshLists", details: [
            "catalogVersion": catalogVersion ?? "nil",
            "compiledRuleCount": "\(compiledRuleCount)"
        ])
        var actionStatus = "started"
        var transactionResult = CatalogSyncTransactionResult.failed
        let repairToken = FilterArtifactRepairStatusStore.begin(
            at: LavaSecAppGroup.containerURL.map { FilterArtifactRepairStatusStore.url(in: $0) },
            configurationIdentity: FilterArtifactRepairStatus.identity(for: configuration,
                snapshotFingerprint: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil).fingerprint))
        var repairOutcome = FilterArtifactRepairStatus.Outcome.waitingForRetry
        var completedRepairIdentity: String?
        defer {
            FilterArtifactRepairStatusStore.finish(repairToken, outcome: Task.isCancelled ? .waitingForRetry : repairOutcome,
                                                   completedConfigurationIdentity: completedRepairIdentity)
            span.end(details: ["status": actionStatus, "catalogVersion": catalogVersion ?? "nil",
                               "filterRepairOutcome": (Task.isCancelled ? .waitingForRetry : repairOutcome).rawValue])
            // Normal return-path fallback. The hub explicitly releases before the
            // reentrant protection-restore tail below; operation-ID fencing makes this
            // second completion a no-op, including when a newer sync has already begun.
            catalog.complete(operationID: operationID, result: transactionResult)
        }

        guard let cacheURL = catalogCacheURL else {
            actionStatus = "app-group-unavailable"
            catalogStatusMessage = LavaSecAppError.appGroupUnavailable.localizedDescription
            catalogStatusIsError = true
            return transactionResult
        }

        // Captured BEFORE the sync for the background rollback guard: the published pointer
        // this refresh builds forward from. If a concurrent foreground publish moves it
        // before our flip, the background aborts rather than rolling the catalog back to its
        // own older sync (see publishBackgroundRefreshArtifacts). Foreground path: unused.
        let basePublishedPointerToken = isBackgroundRefresh ? currentPublishedArtifactPointerToken() : nil
        // Captured BEFORE the sync for the background catalog-cache commit. The background sync
        // DEFERS its latest.json write (commitsLatestCatalog: false) so it can land atomically
        // with the pointer flip; this baseline lets the commit veto itself if a concurrent
        // foreground sync advanced the shared catalog meanwhile (so the background never clobbers
        // the foreground's catalog). Foreground path: unused.
        let baseLatestCatalogData: Data? = isBackgroundRefresh
            ? try? Data(contentsOf: BlocklistCatalogRepository.latestCatalogURL(in: cacheURL))
            : nil

        let restoreRequest = makeProtectionRestoreRequest()
        catalogStatusMessage = "Fetching from the server..."
        catalogStatusIsError = false
        var shouldAttemptProtectionRestore = false

        do {
            let enabledIDs = configuration.enabledBlocklistIDs
            let customSources = enabledCustomBlocklists(in: configuration)
            // Free-tier (e.g. lapsed Plus) keeps its existing custom lists but their
            // contents are frozen: serve the cached payload and never refresh from
            // the network here. The curated catalog still syncs as usual.
            //
            // A background refresh is ALSO strictly cache-only for custom lists: a
            // network re-fetch would rotate custom-list hashes, diverging the artifact
            // identity from the configuration.json this path never rewrites.
            let refreshesCustomBlocklists = configuration.limits.allowsCustomBlocklists && !isBackgroundRefresh
            let syncTask = Task.detached(priority: .utility) {
                let synchronizer = BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL)
                // Background defers the latest.json commit to publish time (atomic with the
                // pointer flip); foreground commits inline as before.
                let catalogResult = try await synchronizer.sync(
                    enabledSourceIDs: enabledIDs,
                    commitsLatestCatalog: !isBackgroundRefresh
                )
                // Free tier is strictly cache-only: never network-fetch custom lists
                // here. We deliberately don't fall back to a network sync on a cache
                // miss — doing so would re-fetch (and overwrite) every enabled list,
                // not just the missing one, unfreezing the others. If a payload is
                // genuinely absent this throws and the outer handler keeps the last
                // good snapshot instead.
                let customResult = refreshesCustomBlocklists
                    ? try await synchronizer.syncCustomBlocklists(customSources)
                    : try await synchronizer.loadCachedCustomBlocklists(customSources)
                return (catalogResult, customResult)
            }
            // Detached work doesn't inherit cancellation; forward it so an expired
            // background refresh stops the network/compile work promptly instead of
            // running past the system deadline.
            let result = try await withTaskCancellationHandler {
                try await syncTask.value
            } onCancel: {
                syncTask.cancel()
            }

            guard !Task.isCancelled else {
                actionStatus = "cancelled"
                transactionResult = .cancelled
                return transactionResult
            }

            applySyncResults(catalogResult: result.0, customResult: result.1)

            if isBackgroundRefresh {
                // The system may have expired the BGTask while the detached sync ran (the
                // expiration handler calls work.cancel() + setTaskCompleted(false)). Do not
                // stage/flip artifacts or notify the tunnel past the deadline — bail like
                // the cancellation guard above. (A later expiration, mid-publish, is caught
                // before the pointer flip by the in-lock supersession closure below.)
                guard !Task.isCancelled else {
                    actionStatus = "cancelled"
                    transactionResult = .cancelled
                    return transactionResult
                }
                // Hybrid background publish: artifacts-only, never configuration.json,
                // never protection restore. Returns before the foreground persist tail.
                actionStatus = await publishBackgroundRefreshArtifacts(operationID: operationID, basePublishedPointerToken: basePublishedPointerToken, baseLatestCatalogData: baseLatestCatalogData)
                if actionStatus == "bg-over-tier-budget" { repairOutcome = .selectionOverBudget }
                if actionStatus == "bg-published" || actionStatus == "bg-unchanged" || actionStatus == "bg-renewed" { repairOutcome = .published }
                // Phase 2: with the active filter republished + latest.json committed, warm the
                // NON-active filters too (capped, most-stale-first) into the sidecar warm-index.
                // Headless-safe — it records into the sidecar, never filter-library.json, and self-guards
                // on the BGTask deadline + per-run budget. Run it ONLY on "bg-published": that is the one
                // outcome where the background published artifacts and committed latest.json (so it
                // holds the current catalog AND its mtime is fresh). "bg-unchanged" does NOT qualify — it
                // only means the ACTIVE filter's artifact didn't need republishing; latest.json was not
                // committed and the sync may have fallen back to cache or fetched non-active-only changes,
                // so warming would compile against a non-committed catalog and the freshness gate would
                // be unreliable (Codex #138 r6 P1). "bg-renewed" commits only equivalent inputs and
                // remains outside the warm-pass scope. Aborted outcomes never committed either. Also skip if
                // the BGTask deadline already passed (Codex r2).
                if !Task.isCancelled, actionStatus == "bg-published" {
                    await warmNonActiveFiltersInBackground(window: .processing)
                }
                if Task.isCancelled || actionStatus == "bg-cancelled" {
                    transactionResult = .cancelled
                } else if actionStatus == "bg-error" {
                    transactionResult = .failed
                } else {
                    transactionResult = .succeeded
                }
                return transactionResult
            }

            // Refresh changed inputs or repair damaged artifacts. Persist accepted sync
            // metadata even when coverage or the rule budget prevents an artifact flip.
            let snapshotChanged = await snapshotNeedsPublicationAfterSync()
            guard !Task.isCancelled else {
                actionStatus = "cancelled"
                transactionResult = .cancelled
                return transactionResult
            }
            if snapshotChanged {
                let prepared = preparedSnapshotForCurrentConfiguration()
                let canPublish = prepared.summary.coversEnabledBlocklists(in: configuration)
                    && FilterRuleBudget.fitsTierBudget(recordedTotal: prepared.summary.tierBudgetRuleCount,
                                                      maxFilterRules: configuration.limits.maxFilterRules)
                let outcome = try await persistSharedState(preparedSnapshot: prepared)
                if canPublish, case .published = outcome {
                    await notifyTunnelSnapshotUpdated(operationID: operationID)
                }
            }

            // INV-TIER-1 surface: when the freshly-synced union no longer fits the tier budget
            // (upstream growth, or the tier shrank since the lists were enabled), report the
            // actionable tier message on this existing status surface instead of a false
            // "Refreshed". On the changed path the persist above just vetoed the artifact
            // flip; on the UNCHANGED path nothing persisted, but a pre-existing over-budget
            // state (e.g. a prior lapse) is equally worth reporting over "Refreshed". The
            // sync itself succeeded either way, so the cached catalog/payloads stay usable
            // for a later gated compile.
            if FilterRuleBudget.fitsTierBudget(
                compiledTotal: liveCompiledTierBudgetRuleCount,
                maxFilterRules: configuration.limits.maxFilterRules
            ) {
                catalogStatusMessage = "Refreshed"
                catalogStatusIsError = false
                repairOutcome = .published
            } else {
                surfaceTierBudgetStatusMessage()
                repairOutcome = .selectionOverBudget
            }
            // The refresh may have persisted accepted hashes and advanced the generation.
            // Bind its result now, before protection restore can yield to another operation.
            completedRepairIdentity = FilterArtifactRepairStatus.identity(for: configuration,
                snapshotFingerprint: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil).fingerprint)

            // Keep the expensive snapshot reload + reconnect gated on an actual
            // upstream change, but always attempt the protection restore: a successful
            // refresh that finds nothing new must still bring a downed tunnel back
            // online (e.g. on launch after iOS dropped the VPN).
            shouldAttemptProtectionRestore = true
            actionStatus = snapshotChanged ? "refreshed" : "unchanged"
            transactionResult = .succeeded
        } catch {
            if Task.isCancelled {
                // Cancelled refresh (e.g. an expired background BGTask): bail without
                // restoring from cache or touching protection.
                actionStatus = "cancelled"
                transactionResult = .cancelled
                return transactionResult
            }

            // A background refresh must NEVER write shared state, on ANY path. The
            // foreground failure recovery below restores from cache via
            // loadCachedCatalogAfterSyncFailure (which calls persistSharedState) and then
            // the tail arms restoreProtectionIfNeeded — both rewrite configuration.json /
            // protection from this headless model's launch-time config, reopening the
            // config-clobber race this mode exists to avoid. So a failed background refresh
            // bails like the cancellation case: leave the last-good artifacts and config
            // untouched and let the next foreground sync recover.
            if isBackgroundRefresh {
                actionStatus = "bg-sync-failed"
                // Only foreground refresh may rotate an enabled custom source's accepted hash.
                if let syncError = error as? BlocklistCatalogSyncError,
                   case .customBlocklistUnavailable = syncError,
                   configuration.limits.allowsCustomBlocklists {
                    repairOutcome = .customSourceUnavailable
                }
                return transactionResult
            }

            let restoredFromCache = await loadCachedCatalogAfterSyncFailure(
                cacheURL: cacheURL,
                originalError: error,
                operationID: operationID
            )

            shouldAttemptProtectionRestore = restoredFromCache
            actionStatus = restoredFromCache ? "cache-restored" : "error"
        }

        // Release before restore: restoreProtectionIfNeeded can re-enter
        // enableProtection, which joins an in-flight catalog operation. Keeping this
        // operation installed until the bridge returns would make it await itself.
        catalog.complete(operationID: operationID, result: transactionResult)
        if shouldAttemptProtectionRestore {
            await restoreProtectionIfNeeded(restoreRequest)
        }
        return transactionResult
    }

    /// Thrown by the background publish's `commitBeforeFlip` to veto the flip when a concurrent
    /// foreground sync advanced the shared catalog (`latest.json`) since this run's baseline —
    /// declining to clobber it. Aborts the publish without changing catalog or pointer.
    private struct BackgroundCatalogCacheSupersededError: Error {}

    /// Background catalog-refresh publish tail (the BGTask path). Re-reads the LIVE
    /// on-disk configuration, builds the snapshot from it, and publishes ARTIFACTS ONLY
    /// under a degrade-ABORT publish lock with an in-lock generation supersession check —
    /// so a concurrent foreground save always wins and a stale background publish can
    /// never clobber it. NEVER rewrites configuration.json and NEVER restores protection
    /// (both would write shared state from this headless model). Returns a status string
    /// for the action span and swallows its own errors (a failed publish just leaves the
    /// last-good artifacts in place).
    private func publishBackgroundRefreshArtifacts(operationID: LatencyOperationID, basePublishedPointerToken: String?, baseLatestCatalogData: Data?) async -> String {
        // Custom lists are cache-only in the background, so cachedBlockRuleSets holds bytes
        // loaded under THIS config's custom fingerprints (applySyncResults just set the
        // hashes to match what was loaded). Capture them BEFORE reloading the live config.
        let baselineCustomIdentities = enabledCustomBlocklistIdentities(in: configuration)

        // Re-read whatever the foreground last persisted and build against THAT, not the
        // config this headless model launched with.
        loadPersistedConfiguration()

        // Abort if the reload had to reseed the filter library (the on-disk library is
        // pre-upgrade/old-schema, or lost a write race): the foreground migration has not
        // landed yet, so the reseed mirrored Balanced into `configuration` in memory WITHOUT
        // persisting it. Building here would publish Balanced artifacts while
        // app-configuration.json — and its generation — still describe the pre-upgrade filter,
        // a silent flip the generation guard cannot catch (no config was written). Publish
        // nothing until the user's next foreground launch commits the migration.
        guard !didReseedFilterLibraryOnLastLoad else {
            return "bg-premigration"
        }

        // Abort if a foreground/manual custom-list refresh changed any enabled custom
        // source's fingerprint while we synced: cachedBlockRuleSets still holds the OLD
        // bytes, but the snapshot identity is computed from this reloaded config (NEW
        // fingerprint) — publishing would stamp the new identity onto stale bytes, and the
        // tunnel would accept them until a later publish. The generation token does NOT catch
        // this when the foreground write landed before our reload (both ends then read the
        // same new generation); the coverage guard only checks presence, not fingerprint.
        // Fail-closed: a changed/added/removed entry counts as a mismatch.
        guard enabledCustomBlocklistIdentities(in: configuration) == baselineCustomIdentities else {
            return "bg-custom-changed"
        }
        let builtGeneration = configuration.configurationGeneration

        // Build the prepared snapshot OFF the main actor. The merge + filterSnapshot are
        // O(rules); for very large rule sets they would otherwise block the main actor long
        // enough that the BGTask expiration handler (queued on .main) could not preempt before
        // the system deadline. Capture the Sendable inputs here, then build on a detached task
        // (the encode/stage/flip is already off-main on the service actor).
        //
        // The builder merges for the RELOADED enabled set: currentSnapshot uses the merged
        // rules verbatim (configuration.filterSnapshot only unions manual rules, never
        // re-filters by enabled IDs) and applySyncResults built from the launch-time set, so
        // without re-merging a foreground DISABLE in the launch→reload window would over-block
        // the disabled list — over-coverage the subset-only guard can't catch. A source the
        // live config enables but this headless sync didn't fetch is omitted, so the summary
        // reports it uncovered and the coverage guard below aborts (fail-closed). Merging once
        // here also drops the redundant second merge the foreground summary path does.
        let configurationForBuild = configuration
        let ruleSetsForBuild = cachedBlockRuleSets
        let guardrailForBuild = threatGuardrail
        let catalogForBuild = currentCatalog
        let compiledRuleCountForBuild = compiledBlocklistRuleCount
        let prepared = await Task.detached(priority: .utility) {
            Self.buildBackgroundPreparedSnapshot(
                configuration: configurationForBuild,
                cachedBlockRuleSets: ruleSetsForBuild,
                threatGuardrail: guardrailForBuild,
                catalog: catalogForBuild,
                compiledBlocklistRuleCount: compiledRuleCountForBuild
            )
        }.value

        // The off-main build freed the main actor, so an expiration that fired during it has
        // already run work.cancel(); bail before the coverage/persist work (the in-lock check
        // remains the final backstop before the flip).
        guard !Task.isCancelled else {
            return "bg-cancelled"
        }

        // Fail-closed coverage backstop: never point the tunnel at a snapshot that does
        // not cover the live enabled set (e.g. a foreground enable landed for a source
        // this headless sync didn't fetch).
        guard prepared.summary.coversEnabledBlocklists(in: configuration) else {
            return "bg-uncovered"
        }

        // INV-TIER-1: the background refresh republishes without the gated cold prepare, so it
        // must veto an over-budget build itself (upstream growth or a lapse since the last gated
        // compile). Publish nothing and stay silent — background never writes user-facing state;
        // the next foreground refresh surfaces the tier message on its existing status surface.
        // The limit comes from the RELOADED on-disk configuration (isPaid → limits), the same
        // config this build is stamped against.
        // pinned: TierBudgetEnforcementSourceTests.testBackgroundPublishVetoesOverBudgetArtifacts
        guard FilterRuleBudget.fitsTierBudget(
            recordedTotal: prepared.summary.tierBudgetRuleCount,
            maxFilterRules: configuration.limits.maxFilterRules
        ) else {
            return "bg-over-tier-budget"
        }

        // Unchanged inputs skip publication only when the compact artifact is still usable.
        let needsPublication = await snapshotNeedsPublicationAfterSync()
        guard !Task.isCancelled else { return "bg-cancelled" }
        guard needsPublication else {
            // Authorization expiry is not an artifact input. Persist a renewal without
            // churning the pointer: retain the captured cache's observations and replace only
            // its matching authorization. CAS prevents a foreground commit being overwritten.
            // pinned: CatalogAuthorizationTests.testAuthorizationOnlyRenewalCommitsWithCAS
            if let catalogCacheURL, let currentCatalog, let baseLatestCatalogData,
               let baseline = try? BlocklistCatalogSynchronizer.makeJSONDecoder().decode(
                    BlocklistCatalog.self, from: baseLatestCatalogData),
               let renewedCatalog = currentCatalog.authorizationRenewal(preserving: baseline) {
                let renewal = Task.detached(priority: .utility) {
                    guard !Task.isCancelled else { return "bg-cancelled" }
                    do {
                        let data = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(renewedCatalog)
                        return try BlocklistCatalogRepository.commitLatestCatalog(
                            data, in: catalogCacheURL, matching: baseLatestCatalogData)
                            ? "bg-renewed" : "bg-catalog-superseded"
                    } catch { return "bg-error" }
                }
                return await withTaskCancellationHandler {
                    await renewal.value
                } onCancel: { renewal.cancel() }
            }
            return "bg-unchanged"
        }

        // Catalog-cache commit, ATOMIC with the pointer flip. The background sync deferred its
        // latest.json write (commitsLatestCatalog: false); commit it here, under the publish
        // lock, only on success — the tunnel derives its expected identity from latest.json, so
        // committing it ahead of this abortable publish would leave the cached catalog ahead of
        // the pointer (→ the tunnel rejects the last-good artifact → in-extension recompile /
        // fail-closed on large lists). On any abort, latest.json stays consistent with the
        // pointer. If we can't reproduce the resolved catalog bytes, do not publish (a flip
        // without the matching latest.json would itself be inconsistent).
        guard let catalogCacheURL,
              let catalogForCommit = currentCatalog,
              let latestCatalogData = try? BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalogForCommit)
        else {
            return "bg-error"
        }

        let configurationURL = self.configurationURL
        do {
            let outcome = try await persistPreparedSnapshotArtifacts(
                prepared,
                lockMode: .tryOrAbort,
                supersededWhileLocked: { @Sendable currentPointerToken in
                    // Inside the held publish lock, evaluated immediately BEFORE the pointer
                    // flip. ABORT the flip if the BGTask expired since we entered the publish
                    // (do no publish work past the system deadline)...
                    if Task.isCancelled { return true }
                    // ...or if a concurrent publish moved the live pointer since this task
                    // captured its basis. The background builds its catalog from its OWN sync,
                    // not from freshly-published artifacts, so without this it could flip the
                    // pointer back to an older catalog a foreground refresh already superseded
                    // (a rollback). The generation token misses this: the background rebuilt
                    // config from the reloaded file, so generations match. Fail-closed.
                    if currentPointerToken != basePublishedPointerToken { return true }
                    // ...or if a foreground write superseded our basis: re-read the on-disk
                    // generation and abort. If the file can't be read, treat as superseded
                    // (degrade-ABORT).
                    guard let configurationURL,
                          let data = try? Data(contentsOf: configurationURL),
                          let onDisk = try? JSONDecoder().decode(AppConfiguration.self, from: data)
                    else {
                        return true
                    }
                    return onDisk.configurationGeneration != builtGeneration
                },
                commitBeforeFlip: { @Sendable in
                    // Runs under the publish lock, after the supersession check, immediately
                    // BEFORE the pointer flip. The repository serializes the latest.json CAS,
                    // authorization check and commit against foreground catalog writers.
                    // Vetoing leaves the last committed catalog and checkpoint unchanged.
                    guard try BlocklistCatalogRepository.commitLatestCatalog(
                        latestCatalogData, in: catalogCacheURL, matching: baseLatestCatalogData)
                    else {
                        throw BackgroundCatalogCacheSupersededError()
                    }
                }
            )

            switch outcome {
            case .published:
                await notifyTunnelSnapshotUpdated(operationID: operationID)
                return "bg-published"
            case .abortedSuperseded:
                return "bg-superseded"
            case .abortedContended:
                return "bg-contended"
            case .abortedCancelled:
                return "bg-cancelled"
            }
        } catch is BackgroundCatalogCacheSupersededError {
            // A concurrent foreground sync advanced the shared catalog; we declined to clobber
            // it. Nothing was published — latest.json and the pointer are both the foreground's.
            return "bg-catalog-superseded"
        } catch {
            return "bg-error"
        }
    }

    /// Shares warm-readiness validation between foreground and background publication.
    private func snapshotNeedsPublicationAfterSync() async -> Bool {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return true
        }
        let capturedConfiguration = configuration
        let capturedCatalog = currentCatalog
        let validation = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return true }
            return FilterArtifactStore(directoryURL: containerURL).readableStore().needsCompactArtifactRepair(
                configuration: capturedConfiguration, cachedCatalog: capturedCatalog)
        }
        let needsRepair = await withTaskCancellationHandler {
            await validation.value
        } onCancel: {
            validation.cancel()
        }
        return needsRepair || configuration != capturedConfiguration || currentCatalog != capturedCatalog
    }

    func syncCatalogIfStale() async {
        guard let cacheURL = catalogCacheURL else {
            return
        }

        let migratedCache = migrateLowRiskLaunchCacheIfNeeded(cacheURL: cacheURL)
        let maxAge = catalogSyncFreshnessInterval
        // Signature verification and its cross-process file lock must not block the UI.
        let fresh = migratedCache ? false : await Task.detached(priority: .utility) {
            BlocklistCatalogSynchronizer.hasFreshCachedCatalog(in: cacheURL, maxAge: maxAge)
        }.value
        guard !Task.isCancelled, !fresh else { return }

        await syncCatalog()
    }

    func loadCachedCatalogIfAvailable() async {
        guard let cacheURL = catalogCacheURL else {
            return
        }

        migrateLowRiskLaunchCacheIfNeeded(cacheURL: cacheURL)

        do {
            let enabledIDs = configuration.enabledBlocklistIDs
            let customSources = enabledCustomBlocklists(in: configuration)
            let result = try await Task.detached(priority: .utility) {
                let synchronizer = BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL)
                let catalogResult = try await synchronizer.loadCached(enabledSourceIDs: enabledIDs)
                let customResult = try await synchronizer.loadCachedCustomBlocklists(customSources)
                return (catalogResult, customResult)
            }.value

            applySyncResults(catalogResult: result.0, customResult: result.1)
            catalogStatusMessage = "Using saved downloaded filter."
            catalogStatusIsError = false
        } catch {
            catalogStatusMessage = "Filter will update from Lava Security's source catalog."
            catalogStatusIsError = false
        }
    }

    func applySyncResults(
        catalogResult: BlocklistCatalogSyncResult,
        customResult: CustomBlocklistSyncResult
    ) {
        updateCustomBlocklistHashes(customResult.sourceHashes)
        applyCatalogSyncResult(FilterSnapshotPreparationService.combinedCatalogResult(catalogResult: catalogResult, customResult: customResult))
        for sourceID in customResult.sourceRuleSets.keys {
            sourceStates[sourceID] = customResult.usedCachedSourceIDs.contains(sourceID) ? .nosync : .sync
        }
    }

    // Startup serves custom lists cache-first so protection is actionable
    // immediately; this refreshes them from the network afterwards and runs the
    // full refresh pipeline only when content actually changed.
    func scheduleBackgroundCustomBlocklistRefresh() {
        // Free tier freezes custom-list contents: skip the post-turn-on network
        // refresh entirely, matching the cache-only prepare/sync paths. Otherwise a
        // lapsed-Plus user would re-fetch (and overwrite) their lists right after
        // protection connects.
        guard configuration.limits.allowsCustomBlocklists else {
            return
        }

        let customSources = enabledCustomBlocklists(in: configuration)
        guard !customSources.isEmpty, let service = filterSnapshotPreparationService else {
            return
        }

        Task(priority: .utility) { [weak self] in
            guard let refreshed = try? await service.refreshCustomBlocklists(customSources) else {
                return
            }

            guard let self else {
                return
            }

            let changed = customSources.contains { source in
                refreshed.sourceHashes[source.id] != source.lastAcceptedHash
            }
            guard changed else {
                return
            }

            #if DEBUG || LAVA_QA_TOOLS
            logVPNDebugEvent("custom-blocklists-changed-in-background")
            #endif
            await self.syncCatalog()
        }
    }

    func enabledCustomBlocklists(in configuration: AppConfiguration) -> [CustomBlocklistSource] {
        configuration.customBlocklists.filter { source in
            configuration.enabledBlocklistIDs.contains(source.id)
        }
    }

    /// Per-source content fingerprint (id → cacheIdentity) for the enabled custom lists.
    /// `cacheIdentity` folds in the sourceURL, parse format, and lastAcceptedHash, so an
    /// inequality means the cached bytes a background sync loaded no longer describe the
    /// reloaded configuration. Used to fail-closed the background publish (see
    /// `publishBackgroundRefreshArtifacts`).
    func enabledCustomBlocklistIdentities(in configuration: AppConfiguration) -> [String: String] {
        Dictionary(
            enabledCustomBlocklists(in: configuration).map { ($0.id, $0.cacheIdentity) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The content-addressed token of the currently-published filter artifact pointer, or
    /// nil if nothing is published yet. The background refresh captures this before syncing
    /// and re-checks it under the publish lock to detect a concurrent foreground publish
    /// (the catalog-rollback guard in `publishBackgroundRefreshArtifacts`).
    func currentPublishedArtifactPointerToken() -> String? {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return nil
        }

        return FilterArtifactStore(directoryURL: containerURL).loadArtifactPointer()?.token
    }

    @discardableResult
    func migrateLowRiskLaunchCacheIfNeeded(cacheURL: URL) -> Bool {
        // Only the launch-critical default-enabled sources gate a cache refresh.
        // Passing every curated (opt-in) source would force-purge latest.json for
        // any user whose cache predates a catalog expansion, bricking the offline
        // path when the re-fetch fails. Opt-in additions are picked up by the
        // normal catalog sync without a forced low-risk refresh.
        let changed = BlocklistCatalogSynchronizer.migrateLowRiskLaunchCacheIfNeeded(
            in: cacheURL,
            requiredSourceIDs: DefaultCatalog.recommendedDefaultSourceIDs
        )

        if changed {
            currentCatalog = nil
            catalogVersion = nil
            catalogGeneratedAt = nil
            catalogSourcesByID = [:]
            catalogGuardrailEntryCount = 0
        }

        return changed
    }

    func updateCustomBlocklistHashes(_ hashes: [String: String]) {
        configuration = FilterSnapshotPreparationService.configuration(configuration, applyingCustomBlocklistHashes: hashes)
    }

    func applyCatalogSyncResult(_ result: BlocklistCatalogSyncResult) {
        currentCatalog = result.catalog
        catalogVersion = result.catalog.catalogVersion
        catalogGeneratedAt = result.catalog.generatedAt
        catalogSourcesByID = Dictionary(uniqueKeysWithValues: result.catalog.sources.map { ($0.id, $0) })
        catalogGuardrailEntryCount = result.catalog.guardrailEntryCount
        cachedBlockRuleSets = result.sourceRuleSets
        localCustomRuleCounts = result.localCustomRuleCounts
        // Fresh per-source caches now describe the active filter, so any warm-switch rehydration this
        // would have been waiting on is satisfied (this is the chokepoint the warm rehydration, a cold
        // switch/restore/import/draft-apply, and every catalog sync all funnel through). Re-enable
        // in-place edits.
        hasPendingWarmSwitchCacheRehydration = false
        threatGuardrail = result.guardrailRuleSet

        for source in result.catalog.sources {
            sourceStates[source.id] = result.usedCachedSourceIDs.contains(source.id) ? .nosync : .sync
        }

        rebuildEnabledBlockRules()

        // The catalog just (re)applied — reconcile the non-active warm set against it: (re)warm any
        // filters now cold or stale so the instant-switch path survives catalog updates (incl. source
        // rotations under a pinned catalog_version). Fire-and-forget; the reconcile is a cheap
        // manifest-only scan that recompiles only the filters actually affected. FOREGROUND only: a
        // headless BGTask model loaded its library at launch, so warming (which writes lastCompiledToken
        // to filter-library.json) could clobber foreground create/edit/delete — the background-refresh-
        // never-writes-shared-state invariant. Headless warming is the Phase-2 BGTask's job, write-safe.
        if !isHeadless {
            Task { await reconcileWarmNonActiveFilters() }
        }
    }

    func loadCachedCatalogAfterSyncFailure(
        cacheURL: URL,
        originalError: Error,
        operationID: LatencyOperationID
    ) async -> Bool {
        do {
            let enabledIDs = configuration.enabledBlocklistIDs
            let customSources = enabledCustomBlocklists(in: configuration)
            let result = try await Task.detached(priority: .utility) {
                let synchronizer = BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL)
                let catalogResult = try await synchronizer.loadCached(enabledSourceIDs: enabledIDs)
                let customResult = try await synchronizer.loadCachedCustomBlocklists(customSources)
                return (catalogResult, customResult)
            }.value

            applySyncResults(catalogResult: result.0, customResult: result.1)
            try await persistSharedState()
            await notifyTunnelSnapshotUpdated(operationID: operationID)

            catalogStatusMessage = "Using saved downloaded filter. Update failed: \(originalError.localizedDescription)"
            catalogStatusIsError = false
            return true
        } catch {
            catalogStatusMessage = "Could not update filter: \(originalError.localizedDescription)"
            catalogStatusIsError = true
            return false
        }
    }

    func rebuildEnabledBlockRules() {
        let mergedBlocklistRules = FilterSnapshotPreparationService.mergedBlockRules(
            enabledSourceIDs: configuration.enabledBlocklistIDs,
            sourceRuleSets: cachedBlockRuleSets
        )
        var mergedRules = mergedBlocklistRules
        mergedRules.formUnion(configuration.manualBlockRuleSet)

        blockRules = mergedRules
        compiledBlocklistRuleCount = mergedBlocklistRules.count
        compiledRuleCount = mergedRules.count
        protectedRuleCount = mergedRules.effectiveBlockedDomainRuleCount(
            allowRules: configuration.allowRuleSet,
            nonAllowableThreatRules: configuration.nonAllowableRulesForAllowedDomains(from: threatGuardrail)
        )
    }

    func refreshCompiledBlocklistRuleCount() {
        compiledBlocklistRuleCount = FilterSnapshotPreparationService.mergedBlockRules(
            enabledSourceIDs: configuration.enabledBlocklistIDs,
            sourceRuleSets: cachedBlockRuleSets
        ).count
    }

    func estimatedBlocklistRuleCount(fromTotalRuleCount totalRuleCount: Int) -> Int {
        guard totalRuleCount > 0 else {
            return 0
        }

        return max(0, totalRuleCount - configuration.blockedDomains.count)
    }

}
