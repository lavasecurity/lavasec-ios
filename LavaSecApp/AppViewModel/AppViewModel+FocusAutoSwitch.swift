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
    // MARK: - Focus auto-switch coordination (LAV-100 Phase 3)

    // `HeadlessFocusSwitchOutcome` lives in LavaSecFilterPipeline with the headless switch engine
    // (LAV-100 Phase 4). The foreground reconcile + the non-active warm-keep helper below STAY here.

    /// Foreground-only: keep the non-active filters — including the seeded defaults (Core/Balanced/Extra) —
    /// WARM whenever the app comes to the foreground, so a closed-app Focus switch to any of them can commit
    /// instantly (warm) instead of deferring to a foreground cold-compile. `reconcileWarmNonActiveFilters` is
    /// a cheap manifest-only scan that recompiles ONLY filters that are actually cold or stale, so running it
    /// on every activation is near-free in the steady state (everything already warm ⇒ no work, no writes).
    /// This complements the existing after-catalog-apply warm pass; together they ensure the defaults are
    /// warm after install + on every open, not only right after a catalog refresh.
    func warmNonActiveFiltersOnAppForeground() {
        guard !isHeadless else { return }
        Task {
            // SAMPLE BEFORE THE REPAIR, and only here. A headless switch that deferred while the
            // app was closed is often the reason the user opened the app at all, and
            // `reconcileWarmNonActiveFilters` recompiles the missing artifacts on the way in — so
            // a post-reconcile sample would report `complete` for exactly the visit whose switch
            // had just failed (PR #644).
            //
            // There is deliberately no second, post-repair sample. "Did this foreground fix it?"
            // is already answered by the NEXT foreground's on-entry reading, which is also the one
            // that predicts the next headless switch; taking it here instead cost an `await`
            // inside the reconcile's serialized region, where a trigger arriving during it could
            // be dropped — the diagnostic causing the deferral it exists to report.
            recordWarmIndexCoverage(await warmIndexCoverageReport())
            await reconcileWarmNonActiveFilters()
        }
    }

    /// WHETHER A HEADLESS SWITCH COULD HAVE APPLIED, recorded where a bug report can read it.
    ///
    /// `HeadlessFocusFilterSwitchEngine` never cold-compiles: a Focus or Shortcut switch is a
    /// pointer flip to a warm artifact, or it defers to the next foreground. So the switch is only
    /// as reliable as the warm index is WHOLE — and one catalog refresh invalidates every entry at
    /// once, because `stillReusableAgainstCachedCatalog` re-checks the basis just before the flip.
    ///
    /// Nothing reported that. Field capture 2026-09-02 (`lavasec-infra`
    /// `plans/2026-09-03-warm-index-coverage-plan.md`): the catalog moved at 12:17, a switch fired
    /// at 20:30 with no valid warm artifact and deferred as designed, and neither log export could
    /// say whether coverage had been whole — so the deferral was indistinguishable from a bug in
    /// the switch itself, which is where three separate remedies were aimed before this.
    ///
    /// The target set and every gate below are the switch path's own, not an approximation of it —
    /// a diagnostic that disagrees with the path it describes sends the next reader after the
    /// wrong subsystem, which is the failure above (Codex + Kilo review, PR #644). Concretely:
    /// non-active and non-frozen targets, because the engine rejects a frozen filter as
    /// `disallowed-target-unavailable`; BOTH candidate tokens per filter, library then sidecar, in
    /// `reusableSnapshotForSwitch`'s order; the `hasFreshCachedCatalog` precondition, without
    /// which a stale-but-present catalog would report covered while every flip deferred; and the
    /// `INV-TIER-1` rule-budget gate, which the manifest gate does NOT cover — a filter compiled
    /// while Plus was active is refused after a lapse, so a lapsed user would otherwise read
    /// `complete` while every switch deferred to the paywall.
    ///
    /// What is NOT modelled is everything `loadReusable` decides BELOW its prepared-snapshot
    /// decode: a missing or undecodable snapshot, a snapshot that does not hash back to its own
    /// directory, and failed guardrail hydration. Stated as a boundary rather than a list with a
    /// count, so it cannot drift the next time a gate lands under the decode (Kilo review,
    /// PR #644). The boundary is the decode itself: it would cost hundreds of thousands of rules
    /// parsed per filter on every foreground — orders of magnitude more than the whole rest of
    /// this pass — to detect on-disk corruption that has its own reporting. Everything reachable
    /// from the small manifest is checked; that is why this reads the manifest rather than
    /// calling the loader outright.
    ///
    /// Emitted on FOREGROUND only. The same reads happen inside `reconcileWarmNonActiveFilters`'s
    /// scan, but repeating them in the BGTask's budgeted window would spend the deadline on
    /// telemetry; the foreground can afford a per-filter manifest read and is where a user lands
    /// before exporting logs anyway.
    ///
    /// Sampled TWICE, and the on-entry sample is the load-bearing one — see the call site.
    /// pinned: FilterSwitchPublishDiagnosticsSourceTests.testTheForegroundRecordsWarmIndexCoverage
    private func warmIndexCoverageReport() async -> WarmIndexCoverage.Report? {
        guard let containerURL = LavaSecAppGroup.containerURL,
              let cacheURL = catalogCacheURL,
              let store = backgroundWarmIndexStore else {
            return nil
        }
        let activeID = library.activeFilterID
        let baseConfiguration = configuration
        let freshnessMaxAge = catalogSyncFreshnessInterval
        // The switch targets, with the filter's OWN configuration exactly as the warm scan builds
        // it: an artifact is valid for the filter it was compiled for, not for the active one. The
        // eligibility predicate is the engine's — non-active, non-frozen — so a filter no switch
        // could ever select never shows up as a permanent gap.
        let targets: [(target: WarmIndexCoverage.Target, configuration: AppConfiguration)] =
            library.filters.compactMap { filter in
                guard filter.id != activeID, !isFilterFrozen(filter.id) else { return nil }
                var cfg = baseConfiguration
                cfg.enabledBlocklistIDs = filter.enabledBlocklistIDs
                cfg.customBlocklists = filter.customBlocklists
                cfg.blockedDomains = filter.blockedDomains
                cfg.allowedDomains = filter.allowedDomains
                // `WarmFilterSnapshotLoader.loadReusableUnwrapped`'s own outright refusal: warm
                // reuse is declined only when custom lists CAN refresh AND this filter has an
                // ENABLED custom source, because the cold path would then network-refresh bytes
                // the artifact's fingerprint recorded at their last-accepted hash.
                let refreshesCustomSources = cfg.limits.allowsCustomBlocklists
                    && cfg.customBlocklists.contains { cfg.enabledBlocklistIDs.contains($0.id) }
                return (
                    WarmIndexCoverage.Target(
                        filterID: filter.id,
                        libraryToken: filter.lastCompiledToken,
                        refreshesCustomSourcesOnSwitch: refreshesCustomSources),
                    cfg)
            }
        let index = store.load()
        let report = await Task.detached(priority: .utility) {
            // The same precondition the flip path applies before it will reuse ANY token: a token
            // warmed while the cache was fresh must not pointer-flip to a stale-catalog artifact
            // long after, so a stale cache means every target defers to a cold compile.
            let isCachedCatalogFresh = BlocklistCatalogSynchronizer.hasFreshCachedCatalog(
                in: cacheURL, maxAge: freshnessMaxAge)
            let cachedCatalog = try? BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL)
                .loadCachedCatalogMetadata()
            let rootStore = FilterArtifactStore(directoryURL: containerURL)
            // DEDUPLICATED WITH THE ENGINE'S OWN FIRST-MATCH SEMANTICS. `FilterLibrary`'s decoder
            // does a bare `decodeIfPresent([Filter].self)` with no dedup, so a restored or
            // corrupted library can carry a repeated filter ID with different fields or tokens.
            // A switch resolves that ID through `FilterLibrary.filter(id:)`, which returns the
            // FIRST match and ignores the rest — so counting the duplicate as a second target
            // reports a filter no switch can ever address, and validates its token against the
            // first entry's configuration besides. Deduplicating here rather than uniquing only
            // the configuration lookup keeps the target set and the lookup describing the same
            // filters (Codex review, PR #644).
            var seenFilterIDs: Set<String> = []
            let distinctTargets = targets.filter { seenFilterIDs.insert($0.target.filterID).inserted }
            // `uniqueKeysWithValues` is safe now that the ids are distinct, but the uniquing form
            // stays: it TRAPS on a duplicate key, and crashing the app from a diagnostic is the
            // one outcome this whole path must not have.
            let configurationsByID = Dictionary(
                distinctTargets.map { ($0.target.filterID, $0.configuration) },
                uniquingKeysWith: { first, _ in first })
            return WarmIndexCoverage.evaluate(
                targets: distinctTargets.map { $0.target },
                warmIndex: index,
                isCachedCatalogFresh: isCachedCatalogFresh,
                artifactRejection: { filterID, token in
                    // Keyed by FILTER ID, not by token — two filters with identical rules share
                    // one content-addressed token, so a token alone cannot name the configuration
                    // to validate against.
                    guard let configuration = configurationsByID[filterID] else {
                        return .artifactUnreadable
                    }
                    let staged = FilterArtifactStore(
                        directoryURL: rootStore.versionedDirectoryURL(token: token))
                    // Missing/corrupt directory — NOT the tier case. A re-warm fixes this one, so
                    // it must not borrow the tier reason's precedence (Codex review, PR #644).
                    guard let manifest = try? staged.loadManifest() else { return .artifactUnreadable }
                    // The flip path's own manifest gate, run against the same persisted catalog.
                    if let rejection = manifest.reuseRejectionReason(
                        configuration: configuration, cachedCatalog: cachedCatalog) {
                        // ONLY `freshness:` means the CATALOG moved. `reuseRejectionReason` also
                        // returns `schemaVersion` / `compactSchemaVersion` (an app update bumped
                        // the compact format), `resolverTransport`, `noCachedCatalog`, `coverage`,
                        // `inputs:` and `configInputs` — all of which mean the artifact was built
                        // for a different configuration or build. Collapsing them into
                        // `basis-moved` would blame a catalog that never moved, and after an app
                        // update it would do so for EVERY filter at once (Codex review, PR #644).
                        return rejection.hasPrefix("freshness:") ? .basisMoved : .artifactMismatched
                    }
                    // INV-TIER-1, which the manifest gate does NOT cover and which
                    // `loadReusableUnwrapped` applies separately: a filter compiled while Plus was
                    // active exceeds the free-tier cap after a lapse, and the switch falls back to
                    // a cold compile that surfaces the paywall. Reading it from the manifest's own
                    // summary keeps this a small-file check — the loader reads it off the DECODED
                    // prepared snapshot, which is the one thing this pass must not do per filter
                    // per foreground (Codex review, #644).
                    // INV-TIER-1, which the manifest gate does NOT cover and which
                    // `loadReusableUnwrapped` applies separately: a filter compiled while Plus was
                    // active exceeds the free-tier cap after a lapse, and the switch falls back to
                    // a cold compile that surfaces the paywall.
                    //
                    // `fitsTierBudget(recordedTotal:)` ALSO fails closed on `nil`, which means a
                    // legacy artifact that never recorded its total — a recompile fixes that, the
                    // paywall does not, and the tier reason wins ties. Separate the two before
                    // labelling, or a legacy artifact sends the reader to a paywall it does not
                    // need (PR #644).
                    guard let recordedTotal = manifest.summary.tierBudgetRuleCount else {
                        return .artifactMismatched
                    }
                    guard FilterRuleBudget.fitsTierBudget(
                        recordedTotal: recordedTotal,
                        maxFilterRules: configuration.limits.maxFilterRules) else {
                        return .tierBudgetExceeded
                    }
                    return nil
                })
        }.value
        return report
    }

    /// The state a switch would have found, recorded on foreground entry before any repair.
    ///
    /// A `nil` report means the App Group container, the catalog cache or the warm-index store was
    /// unavailable — which is itself a state where every headless switch defers, so it is recorded
    /// rather than skipped. An absent event would be indistinguishable from an app that simply
    /// never came to the foreground (PR #644).
    /// pinned: FilterSwitchPublishDiagnosticsSourceTests.testTheForegroundRecordsWarmIndexCoverage
    private func recordWarmIndexCoverage(_ report: WarmIndexCoverage.Report?) {
        logVPNDebugEvent(
            "warm-index-coverage",
            details: ["coverage": report?.diagnosticValue ?? "unavailable"])
    }

    /// Publish a lightweight "the app is in the foreground RIGHT NOW" flag to the shared app-group defaults
    /// (`LavaAppForegroundPublication`), read by the headless switch banner posters (the Focus extension AND
    /// the Shortcuts/automation intent) to gate their notifications to closed/backgrounded only (a
    /// foreground app shows the switch in-UI, so a banner would be redundant). Set true on scene .active /
    /// onAppear, false on .background — and cleared at process start (`LavaSecApp.init`) and on
    /// willTerminate, because a crash or a force-quit from the app switcher while visible skips the
    /// .background clear; the poster additionally stops trusting an assert older than
    /// `LavaAppForegroundPublication.maxTrustedAge`, since after a hard crash the next process to run can be
    /// the Focus EXTENSION, which can't safely clear the flag (Codex review #361). NOT the removed
    /// `AppForegroundActivityState` switch-defer machinery — this never affects a switch; a wrong read just
    /// shows/suppresses one banner.
    func setAppForegroundActive(_ active: Bool) {
        guard !isHeadless else { return }
        // Observation cancellation belongs to synchronous UIApplication notifications.
        // A deferred SwiftUI scene callback must not revive a suspended sampler.
        // INV-PERSIST-1 recovery re-check: no-op on every normal foreground (guarded on the
        // launch load having been blocked by Data Protection); heals a pre-unlock-launched
        // process whose protectedDataDidBecomeAvailable notification was missed.
        if active {
            reloadSharedStateIfBlockedByDataProtection()
            loadProtectedPreferencesIfAvailable()
            if UIApplication.shared.isProtectedDataAvailable {
                backup.refreshUnavailableBackupStateAfterUnlock()
            }
            // Belt-and-braces re-derive of an upgrade-transition suppression freeze (Codex P1 on
            // #385), for a first-unlock notification delivered before this process observed it.
            confirmReseedSuppressionAfterUnlock()
            // INV-PERSIST-2 one-shot migration: re-stamping a file's protection class
            // re-encrypts its content, so it can only run POST-unlock — hence the
            // isProtectedDataAvailable gate here rather than at launch (which can be a
            // pre-unlock prewarm). One-shot latching + retry-on-partial-failure live in
            // the migration type itself, so this hook stays a bare trigger; detached at
            // utility priority because scene activation must never block on a
            // whole-container attribute walk.
            if UIApplication.shared.isProtectedDataAvailable, let containerURL = LavaSecAppGroup.containerURL {
                Task.detached(priority: .utility) {
                    ControlPlaneProtectionMigration.run(containerURL: containerURL)
                }
            }
        }
        let defaults = LavaSecAppGroup.sharedDefaults
        // GUARDED on protected data (INV-PERSIST-2): the foreground-active flag lives in the
        // Class-C shared-defaults SUITE (the same suite the tunnel's locked-content canary
        // probes), which is unwritable while the device is locked. A pre-first-unlock
        // prewarm/notification foreground therefore cannot persist it — and writing the locked
        // suite is exactly the discipline the 2026-07-14 incident hardened, matching the
        // language pin below (rather than relying on the CFPreferences write to fail silently).
        // Skipping the write while locked is also SEMANTICALLY right: the user cannot be looking
        // at the app while the device is locked, so the flag correctly stays absent/false
        // pre-unlock, and the reader's stamp lease (`maxTrustedAge`) bounds any staleness from a
        // re-lock that races the `.background` clear.
        // pinned: RebootFirstUnlockGuardSourceTests.testForegroundActivePublishIsGuardedOnProtectedData
        if UIApplication.shared.isProtectedDataAvailable {
            LavaAppForegroundPublication.publish(active, to: defaults)
        }
        if active {
            // Pin the language the app UI is CURRENTLY resolved to (honoring any iOS per-app language
            // override) so the App Intents extension, NE tunnel, and Live Activity widget — separate
            // processes that don't inherit that override — localize in the SAME language as the app, not
            // the system language. Refreshed on every foreground so a language change in iOS Settings
            // takes effect on the user's next return to the app.
            // GUARDED on protected data: a pre-first-unlock foreground (prewarm / notification launch)
            // resolves this process's bundle against a still-locked AppleLanguages state — publishing
            // THAT would overwrite the user's pin (zh-Hant → en) in the shared suite, the notification/
            // Live Activity half of the 2026-07-14 incident's language flip (plan Phase 3). Skip it; the
            // next post-unlock foreground republishes the correct resolution.
            // pinned: RebootFirstUnlockGuardSourceTests.testLanguagePinPublishIsGuardedOnProtectedData
            if UIApplication.shared.isProtectedDataAvailable {
                LavaNotificationLanguage.publish(LavaNotificationLanguage.currentAppLocalization(), to: defaults)
            }
        }
    }

    /// Foreground-only: apply any pending Focus switch recorded by the headless path. Run on appear, on
    /// becoming active, and on the headless wake nudge. The pending-switch marker is the feature's
    /// correctness guarantee: this is the AUTHORITATIVE clear site — it clears only after confirming the
    /// target is active (headless committed it) or applying the switch through the normal foreground
    /// path (which cold-compiles if no warm artifact exists). Compare-and-clear so a newer Focus request
    /// recorded meanwhile is never dropped. The background BGTask drain (`BackgroundPendingSwitchDrain`,
    /// LavaSecFilterPipeline) additionally clears the SAME two moot cases this pass clears (auth gate
    /// closed / superseded by a newer manual switch), under the same marker flock and compare-and-clear
    /// rules; every other outcome there leaves the marker for THIS reconcile, so the re-sync/clear
    /// protocol below is unchanged.
    func reconcilePendingFilterSwitch() async {
        // A resident background app can receive the Darwin nudge, but cannot safely own a
        // cold rebuild through suspension. The state-agnostic headless engine still handles
        // warm switches; leave its marker for the next foreground reconcile.
        guard !isHeadless, UIApplication.shared.applicationState == .active else { return }
        // Re-entrancy guard: the three wake triggers (onAppear, scene .active, Darwin nudge) could
        // otherwise both read the same marker and launch duplicate switchToFilter attempts (the
        // replacement gate makes the loser bail, but it still does redundant work). One drives a marker
        // at a time — but a trigger that arrives while a run is in flight sets pendingReconcileRerun so
        // the in-flight run loops once more, instead of stranding a newer marker (recorded during a slow
        // cold-compile apply) until the next scene-phase event (Codex P2).
        guard !isReconcilingPendingFilterSwitch else {
            pendingReconcileRerun = true
            return
        }
        isReconcilingPendingFilterSwitch = true
        defer { isReconcilingPendingFilterSwitch = false }
        // Bound each SYNCHRONOUS drain to the initial pass + one re-run (mirrors the protection-status refresh
        // loop's storm guard), so a rapid Focus-toggle burst can't monopolize this run in one unbroken
        // sequence. Cap at 2 ("loops once more", above — Codex round-16 audit).
        var remainingReconcilePasses = 2
        repeat {
            remainingReconcilePasses -= 1
            pendingReconcileRerun = false
            await applyPendingFilterSwitchOnce()
        } while pendingReconcileRerun && remainingReconcilePasses > 0
        // Hitting the cap with a re-run STILL queued means a newer marker landed during the final pass and
        // its Darwin nudge was already consumed by the re-entrancy guard above — so do NOT drop it (that would
        // strand the newest durable marker, leaving an active foreground app on the previous filter until a
        // later scene/Focus event). Re-dispatch a FRESH reconcile on the next runloop tick: the defer has reset
        // the guard by the time it runs, so it re-enters cleanly and drains the queue, while the per-run cap
        // keeps any single synchronous burst bounded (Codex round-17). Best-effort promptness only — the
        // durable marker stays the correctness guarantee, so even if the app backgrounds before this Task runs
        // the next onAppear/.active reconcile applies it.
        if pendingReconcileRerun {
            Task { @MainActor [weak self] in await self?.reconcilePendingFilterSwitch() }
        }
    }

    /// One pass of the pending-switch reconcile. The wrapper `reconcilePendingFilterSwitch` serializes +
    /// re-runs this; the early returns here end the PASS, not the loop.
    private func applyPendingFilterSwitchOnce() async {
        let defaults = LavaSecAppGroup.sharedDefaults
        guard let request = PendingFilterSwitchStore.current(in: defaults) else { return }

        // Re-check the SAME fail-closed SECURITY gate the headless record path enforces. Focus auto-switch is
        // available to all tiers (the Plus paywall was dropped), but a marker recorded while editing was
        // unprotected must NOT apply if filter editing has since become auth-protected — an unattended switch
        // would otherwise bypass the auth-to-edit boundary (the record-time gate alone does not survive a gate
        // change between record and reconcile). Gate now closed ⇒ the request is moot; drop it. Invariant: a
        // disallowed switch must not happen now or on a later reconcile.
        guard !SecurityProtectedSurfaceStorage.isProtected(.filterEditing, defaults: defaults,
            projectionURL: LavaSecAppGroup.securityGateProjectionURL) else {
            PendingFilterSwitchStore.clearIfMatches(request, in: defaults, lockURL: pendingFilterSwitchMarkerLockURL)
            return
        }

        // ADOPT a cross-process commit before deciding (LAV-100). The App Intents extension commits the switch
        // to DISK; a resident app that was SUSPENDED in the background couldn't receive the post-commit Darwin
        // nudge, so its in-memory (configuration, library) is STALE. Without re-reading disk here, the
        // already-active check below compares the marker against a stale `activeFilterID`, misses that the
        // extension already applied the switch WARM on disk, and falls through to `switchToFilter` — which then
        // cold-compiles (its warm-reuse reads the in-memory `lastCompiledToken`, but the extension stamped the
        // token on disk) and shows the recompile sheet on return to foreground. Reloading lets the already-active
        // branch recognize the committed switch and just re-notify+clear (a pointer the tunnel poll already
        // adopted, or adopts within its interval). GATED so it's a no-op on the common path: only when the
        // on-disk generation is NEWER than ours (another process wrote since we loaded), and NOT while a user
        // switch is in flight — that path owns the in-memory state and the reconcile defers to it below.
        if !isForegroundManualSwitchInFlight,
           let configurationURL, let filterLibraryURL, let containerURL = LavaSecAppGroup.containerURL,
           SharedFilterStatePersistence.onDiskConfigurationGeneration(at: configurationURL) > configuration.configurationGeneration {
            // A newer on-disk commit exists (the App Intents extension wrote config/library while this resident
            // app was suspended — its post-commit Darwin nudge couldn't reach a suspended run loop). Adopt it
            // ONLY if the headless commit COMPLETED: the extension flips the artifact pointer LAST, so require
            // the live pointer to name the on-disk active filter's compiled artifact. If it's mid-commit (the
            // config-leads-pointer window, which may still roll back via the in-lock catalog/failure path),
            // DEFER — `return`, do NOT fall through to the switchToFilter path below, which would race the
            // extension's in-flight commit and cold-recompile (Codex P2). The kept marker + the next reconcile
            // (the post-flip nudge) adopt it cleanly once it lands; a rollback leaves config+pointer consistent
            // and the active-change gate below no-ops it.
            guard let pointerToken = FilterArtifactStore(directoryURL: containerURL).loadArtifactPointer()?.token,
                  SharedFilterStatePersistence.onDiskActiveFilterCompiledToken(at: filterLibraryURL) == pointerToken
            else {
                return
            }
            // Re-read disk to adopt the committed switch into the stale in-memory (configuration, library).
            let previousActiveID = library.activeFilterID
            // Capture BEFORE the reload (mirrors switchToFilter): whether protection should be re-established.
            let restoreRequest = makeProtectionRestoreRequest()
            loadPersistedConfiguration()
            // RE-VALIDATE completeness AFTER the reload (closes the check-then-reload TOCTOU, Codex P2): a
            // back-to-back commit C can land between the pre-check above and this reload, so
            // loadPersistedConfiguration could pick up an in-flight C whose pointer hasn't flipped. If the
            // reloaded active filter's artifact is no longer the one the live pointer names, disk is mid-commit
            // — DEFER (keep the marker, return) so the tail / already-active branch never act on a switch that
            // may still roll back; a later reconcile re-evaluates once the flip lands. The kept marker + the
            // next reconcile re-read heal the (transient) in-memory state if that commit rolls back.
            guard library.filter(id: library.activeFilterID)?.lastCompiledToken
                    == FilterArtifactStore(directoryURL: containerURL).loadArtifactPointer()?.token else {
                return
            }
            // Only when the adopt ACTUALLY moved the active filter (Codex P2: a bare generation bump that left
            // the active filter unchanged — the extension's catalog-moved/failed-commit ROLLBACK — must be a
            // no-op so the rehydration flag isn't set spuriously and left stuck). Run the FULL warm-switch tail
            // (not a piecemeal patch): without it the already-active branch below would cold-recompile / the
            // app would consume stale blockRules on an immediate edit (Codex found 4 such gaps on the partial
            // version). The extension already persisted + flipped the pointer, so this is the TAIL only.
            if library.activeFilterID != previousActiveID {
                let adoptToken = configurationReplacementGate.begin()
                await applyCommittedOnDiskActiveFilter(adoptToken: adoptToken, restoreRequest: restoreRequest)
            }
        }

        // A foreground switch INITIATED after this Focus request was recorded is the user's newer explicit
        // choice and wins — drop the stale marker rather than reverting their manual switch. The stamp is
        // the switch's INITIATION instant (not its completion), so a Focus request that fired DURING a slow
        // manual switch — i.e. after the user started it — still wins over that switch (Codex round-15).
        // The precedence rule itself (including the exact-tie `<=` that favors the MANUAL switch) lives in
        // the SHARED `PendingFilterSwitchStore.isSupersededByForegroundSwitch` — one behaviorally-tested
        // implementation for this reconcile AND the BGTask drain (`BackgroundPendingSwitchDrain`), so the
        // two marker drains can never drift on who wins a manual-vs-automation race.
        if PendingFilterSwitchStore.isSupersededByForegroundSwitch(request, in: defaults) {
            PendingFilterSwitchStore.clearIfMatches(request, in: defaults, lockURL: pendingFilterSwitchMarkerLockURL)
            return
        }

        // Target gone or frozen (deleted, or Plus-cap froze it) ⇒ the request is moot; clear it.
        guard library.filter(id: request.targetFilterID) != nil, !isFilterFrozen(request.targetFilterID) else {
            PendingFilterSwitchStore.clearIfMatches(request, in: defaults, lockURL: pendingFilterSwitchMarkerLockURL)
            return
        }
        // Already active: a headless immediate commit applied this switch (or a manual switch did). A
        // headless commit could NOT schedule the encrypted-backup upload (its model never loaded the
        // backup state), so schedule it here on the foreground — which HAS the backup state loaded — so
        // an auto-backup user's Focus-driven config change is re-sealed + uploaded rather than waiting
        // for the next foreground edit (Codex P2). Safe to call even if a concurrent foreground switch to the
        // same target also schedules: scheduleAutomaticBackupAfterConfigurationChange CANCELS-AND-REPLACES the
        // single debounced automaticBackupTask and content-gates its re-seal, so overlapping calls coalesce to
        // one upload rather than double-firing (founder review P2-2). Then clear the (now-applied) marker.
        guard request.targetFilterID != library.activeFilterID else {
            backup.scheduleAutomaticBackupAfterConfigurationChange()
            // Re-notify the tunnel BEFORE clearing: disk shows the target active, but the running tunnel may
            // still hold the OLD in-memory snapshot if the headless commit's notify was killed (App Intent
            // terminated after persistSharedState) or swallowed a send error. Clearing without this would
            // remove the only retry path until an unrelated update / VPN restart (Codex round-10). Idempotent
            // when the tunnel already has it (a lock-free pointer re-read); a no-op when protection is off.
            // This brings the already-active branch to parity with the foreground switch path, which always
            // notifies after a commit; if the notify itself fails, the same reconnect fallback applies.
            //
            // Pair/pointer matching was checked before adoption above. Termination inside the
            // synchronous multi-file commit remains recoverable by reconcileTunnelSnapshotAfterLaunch;
            // no actor await now separates the headless pair write from its pointer flip.
            await notifyTunnelSnapshotUpdated()
            PendingFilterSwitchStore.clearIfMatches(request, in: defaults, lockURL: pendingFilterSwitchMarkerLockURL)
            return
        }
        // Do NOT supersede an IN-FLIGHT user-initiated switch (round-18): it claimed the replacement gate
        // first but hasn't stamped lastForegroundSwitch yet (the stamp lands only on success), so the stale
        // check above couldn't see it. Applying here would begin a NEWER gate epoch and make the user's
        // in-flight manual switch bail as superseded — letting this (older) Focus request wrongly win. Defer:
        // KEEP the marker; that switch's completion re-dispatches a reconcile (switchToFilter's defer), which
        // re-evaluates with lastForegroundSwitch now stamped — dropping this marker if the manual switch was
        // newer, or applying it if it is genuinely newer than the manual switch.
        guard !isForegroundManualSwitchInFlight else {
            logFocusSwitchEvent("reconcile-deferred-manual-switch-in-flight", details: ["filterID": request.targetFilterID])
            return
        }
        // Apply through the normal foreground switch, cold-compiling on a warm miss; for a resident
        // foreground re-syncing an already-committed headless switch it's a fast warm pointer-flip.
        // stampsForegroundSwitch: false — this is replaying a Focus automation, NOT a user-initiated
        // switch, so it must not poison the lastForegroundSwitch supersession timestamp and suppress a
        // newer Focus request recorded during this (possibly slow) apply. The same flag makes the apply
        // SILENT: no full-screen preparation cover / "Success" modal / haptic (mirrors the committed-
        // adopt path). Surfacing that modal for an automated switch is what popped a "Success" page
        // every time the user opened the app after a Focus switch — the user never initiated it.
        // Log every reconcile-driven apply so a transient failure that keeps re-recording (Focus re-fires,
        // each cold-compile fails) surfaces as a repeating reconcile-apply for the same filter in QA dumps.
        // A failed apply is silent too; the kept marker (below) retries it on the next foreground / Focus edge.
        guard UIApplication.shared.applicationState == .active else { return }
        logFocusSwitchEvent("reconcile-apply", details: ["filterID": request.targetFilterID])
        await switchToFilter(id: request.targetFilterID, stampsForegroundSwitch: false)
        // Clear the marker ONLY if the switch actually took effect. switchToFilter returns Void and LEAVES
        // the active filter unchanged on a preparation/publish failure (a cold-compile network blip, a
        // transient catalog miss). Clearing unconditionally would silently DROP the user's Focus automation
        // with no retry (Codex round-8). Keeping the marker on failure lets the next foreground — or a Focus
        // re-fire — retry until it succeeds (a silent self-heal now, no modal). The compare-and-clear
        // below still protects a NEWER marker recorded during this apply.
        guard library.activeFilterID == request.targetFilterID else {
            logFocusSwitchEvent("reconcile-apply-failed-kept-marker", details: ["filterID": request.targetFilterID])
            return
        }
        PendingFilterSwitchStore.clearIfMatches(request, in: defaults, lockURL: pendingFilterSwitchMarkerLockURL)
    }

    /// Adopt — in the RESIDENT foreground app — a Focus switch the App Intents extension already committed to
    /// disk (config + library written, artifact pointer flipped) while the app was suspended. This runs the
    /// post-commit TAIL of a warm switch ONLY: the caller has already `loadPersistedConfiguration()`'d the new
    /// (config, library) from disk and begun the replacement epoch (`adoptToken`); there is NO prepare/compile,
    /// NO `persistSharedState` (the extension already persisted + flipped — re-persisting would churn the warm
    /// path), and NO `lastForegroundSwitch` stamp (this is not a user-initiated foreground switch — stamping
    /// would wrongly out-rank a genuine later manual switch). It deliberately does NOT touch the preparation UI
    /// cover or play a haptic — the adopt is SILENT (no recompile sheet), which is the whole point.
    ///
    /// Why a shared tail (not a piecemeal patch of the already-active branch): `loadPersistedConfiguration`
    /// moved config/library, but `blockRules`/`threatGuardrail`/`cachedBlockRuleSets`/sourceStates/counts still
    /// describe the PREVIOUS filter. Applying the on-disk filter's warm snapshot SYNCHRONOUSLY here sets
    /// blockRules + the full threatGuardrail in one main-actor pass, eliminating the stale window an immediate
    /// allowlist/blocklist edit would otherwise serialize into a wrong-rules publish (Codex found 4 such gaps
    /// closing them one at a time).
    private func applyCommittedOnDiskActiveFilter(
        adoptToken: Int,
        restoreRequest: ProtectionRestoreRequest
    ) async {
        let adoptedFilterID = library.activeFilterID
        // Re-validate the adopted target exists + is switchable (a concurrent edit/delete could have landed).
        guard let target = library.filter(id: adoptedFilterID), !isFilterFrozen(adoptedFilterID) else { return }

        // Apply the adopted filter's warm snapshot from disk (the extension already published this token's
        // dir + flipped the pointer to it). Loads by the now-on-disk `lastCompiledToken`. A concurrent newer
        // switch during the async load supersedes us — bail without clobbering its state.
        if let reusable = await warmReusableSnapshotForSwitch(target: target, configuration: configuration),
           configurationReplacementGate.isCurrent(adoptToken),
           library.activeFilterID == adoptedFilterID {
            // Guard against a catalog refresh that landed DURING the async warm load: applying a snapshot
            // validated against the PRE-refresh catalog would roll currentCatalog/blockRules BACK over the
            // active filter the refresh just rebuilt + published. Mirrors switchToFilter's
            // catalogMovedDuringPersist check (Codex P2). On a move, skip the apply — the rehydration below
            // (its syncCatalog fallback) heals to the fresh catalog.
            let catalogMovedDuringLoad = currentCatalog.map {
                !reusable.preparedSnapshot.identity.snapshotInputMismatches(
                    against: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: $0)
                ).isEmpty
            } ?? false
            if !catalogMovedDuringLoad {
                applyReusablePreparedSnapshot(reusable)
            }
        }
        guard configurationReplacementGate.isCurrent(adoptToken) else { return }

        // The per-source caches (cachedBlockRuleSets) are still the previous filter's even after the snapshot
        // apply (applyReusablePreparedSnapshot doesn't populate them) — defer in-place edits + rehydrate in the
        // background, exactly like a warm switchToFilter. applyCatalogSyncResult clears the flag once fresh
        // caches land; the rehydration's syncCatalog fallback self-heals if the warm load above failed.
        hasPendingWarmSwitchCacheRehydration = true
        Task { [weak self] in
            await self?.rehydrateRuleSetCachesAfterWarmSwitch(switchToken: adoptToken, filterID: adoptedFilterID)
        }

        // Drop any non-active detail target so the detail accessors fall back to the now-active filter (else
        // saving its draft would go through the library-only saveNonActiveFilterDraft and never publish).
        filterEditTargetID = nil
        pendingSwitchFilterID = nil

        appendAppNetworkActivity(.changeFilters)
        await notifyTunnelSnapshotUpdated()
        await restoreProtectionIfNeeded(restoreRequest)
        backup.scheduleAutomaticBackupAfterConfigurationChange()
    }

    // The headless Focus warm-switch orchestration (FocusWarmSwitchCatalogMovedError,
    // nudgeForegroundReconcile, performHeadlessFocusFilterSwitch, warmSnapshotStillReusableAgainstCachedCatalog)
    // lives in LavaSecFilterPipeline.HeadlessFocusFilterSwitchEngine (LAV-100 Phase 4) so it can run in the
    // App Intents extension with no AppViewModel. The foreground reconcile + persist paths below STAY here.
}
