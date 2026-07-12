import Foundation
import LavaSecKit

/// Outcome of a headless Focus-driven filter switch. Relocated from `AppViewModel` (LAV-100 Phase 4)
/// so the App Intents extension can report it without the app target.
public enum HeadlessFocusSwitchOutcome: String, Equatable, Sendable {
    /// The requested filter was committed and published.
    case committed
    /// The request was recorded for later foreground reconciliation.
    case deferred
    /// The requested filter was already active.
    case alreadyActive
    /// The request was refused by a fail-closed guard.
    case disallowed
}

/// The pure, extension-safe engine for a Focus-driven warm filter switch.
///
/// This is the relocation of `AppViewModel.performHeadlessFocusFilterSwitch` out of the app target so a
/// `SetFocusFilterIntent` running in the App Intents EXTENSION (the only place an intent runs while the
/// app is closed — WWDC22 §10121) can drive the same switch. It operates on `(configuration, library)`
/// value copies loaded from the App Group container — there is no `AppViewModel`, no `@Published` state,
/// no NetworkExtension. The throwaway headless model's in-memory assignments were already
/// write-only-then-discarded, so plain value locals are behavior-identical; a resident foreground app
/// re-syncs its own in-memory state via the durable pending-switch marker.
///
/// Load-bearing semantics: fail-closed gate (NOT auth-to-edit; the Plus paywall was dropped, so all tiers
/// may switch), the reseed/config-fallback/frozen guards, the durable marker recorded FIRST, warm-only
/// commit (the headless path never cold-compiles), the in-lock catalog-basis veto, and the marker LEFT for
/// the foreground reconcile to clear. The commit is STATE-AGNOSTIC — it no longer defers on a coarse
/// foreground-active flag; the Phase-4 cross-process write lock + generation fence make a concurrent
/// foreground write safe (the loser aborts), so a closed-app switch lands promptly regardless of app state.
/// The commit funnels through the same single writer (`SharedFilterStatePersistence`) + the same artifact
/// publish (`FilterSnapshotPreparationService.persistArtifacts`) the foreground uses, so the two contexts
/// can never drift on write-ordering or generation semantics.
public enum HeadlessFocusFilterSwitchEngine {
    /// Everything the engine needs, supplied by the caller (app or extension) so the App Group
    /// identifier + NetworkExtension stay out of LavaSecCore. Not `Sendable`: it is used entirely on the
    /// calling task; only individual `Sendable` values cross into detached tasks / the publish actor.
    public struct Environment {
        internal let containerURL: URL
        internal let configurationURL: URL
        internal let filterLibraryURL: URL
        internal let catalogCacheURL: URL
        internal let backgroundWarmIndexURL: URL
        internal let publishLockURL: URL
        internal let focusSwitchLockURL: URL
        /// Cross-process CAS lock for the shared (config, library) pair write (LAV-100 Phase 4 P4c).
        internal let configurationWriteLockURL: URL
        /// Cross-process lock for the pending-switch MARKER record/clear (LAV-100 Phase 4).
        internal let pendingMarkerLockURL: URL
        internal let snapshotFilename: String
        internal let compactSnapshotFilename: String
        internal let defaults: UserDefaults
        internal let catalogSyncFreshnessInterval: TimeInterval
        /// Clock, injectable for tests.
        internal let now: @Sendable () -> Date
        /// Post a Darwin notification by name. Production: `DarwinProtectionSignalNotifier().postNotification`.
        /// Used for both the tunnel-reload signal (after a commit) and the foreground reconcile nudge.
        internal let postSignal: @Sendable (String) -> Void
        /// Privacy-safe device-debug logging (no-op in Release).
        internal let log: @Sendable (_ event: String, _ details: [String: String]) -> Void
        /// Post a user-facing notification for a switch OUTCOME — `committed == true` ⇒ "Switched to
        /// <name>"; `committed == false` ⇒ "Couldn't switch to <name>" (a refused switch, e.g. auth-to-edit).
        /// The closure (provided by `FocusSwitchEnvironment`) gates on the caller's category toggle +
        /// closed/backgrounded-only + permission, then posts; the Shortcuts/automation caller's closure
        /// additionally DROPS `committed == false` (its thrown error is that caller's failure feedback —
        /// see `FocusSwitchEnvironment.OutcomeFeedback`). Default no-op (tests / the in-app caller, which
        /// has nothing to notify — the user sees the switch in-UI). Takes the resolved filter NAME (the
        /// engine has the library) so the closure needs no library access.
        internal let notifySwitchOutcome: @Sendable (_ committed: Bool, _ filterName: String) async -> Void

        /// Creates an environment from the shared files, locks, defaults, and callback seams.
        public init(
            containerURL: URL,
            configurationURL: URL,
            filterLibraryURL: URL,
            catalogCacheURL: URL,
            backgroundWarmIndexURL: URL,
            publishLockURL: URL,
            focusSwitchLockURL: URL,
            configurationWriteLockURL: URL,
            pendingMarkerLockURL: URL,
            snapshotFilename: String,
            compactSnapshotFilename: String,
            defaults: UserDefaults,
            catalogSyncFreshnessInterval: TimeInterval,
            now: @escaping @Sendable () -> Date = { Date() },
            postSignal: @escaping @Sendable (String) -> Void = { DarwinProtectionSignalNotifier().postNotification(named: $0) },
            log: @escaping @Sendable (_ event: String, _ details: [String: String]) -> Void = { _, _ in },
            notifySwitchOutcome: @escaping @Sendable (_ committed: Bool, _ filterName: String) async -> Void = { _, _ in }
        ) {
            self.containerURL = containerURL
            self.configurationURL = configurationURL
            self.filterLibraryURL = filterLibraryURL
            self.catalogCacheURL = catalogCacheURL
            self.backgroundWarmIndexURL = backgroundWarmIndexURL
            self.publishLockURL = publishLockURL
            self.focusSwitchLockURL = focusSwitchLockURL
            self.configurationWriteLockURL = configurationWriteLockURL
            self.pendingMarkerLockURL = pendingMarkerLockURL
            self.snapshotFilename = snapshotFilename
            self.compactSnapshotFilename = compactSnapshotFilename
            self.defaults = defaults
            self.catalogSyncFreshnessInterval = catalogSyncFreshnessInterval
            self.now = now
            self.postSignal = postSignal
            self.log = log
            self.notifySwitchOutcome = notifySwitchOutcome
        }
    }

    /// Thrown by the in-lock `commitBeforeFlip` to VETO the pointer flip when a concurrent background
    /// catalog refresh moved the cached catalog past the warm artifact's basis between the off-lock
    /// revalidation and the flip. Distinct type so the commit's catch treats it as a CLEAN DEFER (the
    /// foreground reconcile cold-compiles against the new catalog), not a commit wedge (Codex round-16).
    private struct CatalogMovedError: Error {}

    /// Thrown by the in-lock generation fence when a concurrent (foreground) writer advanced the on-disk
    /// configuration generation PAST the one this commit wrote, between our config write and the pointer
    /// flip. Aborts the flip so we never clobber the newer writer's pointer with our stale-basis artifact —
    /// a generation-fenced CAS for the flip, matching the background catalog-refresh's `supersededWhileLocked`
    /// (LAV-100 Phase 4 P4c review). Distinct from `CatalogMovedError` so the clean-defer log is honest.
    private struct SupersededError: Error {}

    /// The engine's decision: the public outcome plus the SPECIFIC branch reason (e.g.
    /// "deferred-no-warm-artifact", "committed", "disallowed-auth-to-edit"). The reason is recorded into the
    /// Release-visible `FocusSwitchDiagnostics` so a closed-app switch is diagnosable without the QA log.
    private struct SwitchDecision {
        let outcome: HeadlessFocusSwitchOutcome
        let reason: String
        init(_ outcome: HeadlessFocusSwitchOutcome, _ reason: String) {
            self.outcome = outcome
            self.reason = reason
        }
    }

    /// Serialized headless Focus-switch entry. Concurrent invocations (two intents firing) are serialized
    /// by a dedicated app-group flock; the pending-switch marker + the publish lock already make any
    /// interleave safe, so the lock degrades OPEN if unavailable.
    @discardableResult
    public static func performSwitch(toFilterID id: String, env: Environment) async -> HeadlessFocusSwitchOutcome {
        env.log("focus-switch-begin", ["filterID": id])
        let decision = await withFocusSwitchLock(at: env.focusSwitchLockURL) { () async -> SwitchDecision in
            let decision = await runLocked(toFilterID: id, env: env)
            // Record the diagnostic INSIDE the focus-switch lock so the LAST engine decision is also the last
            // diagnostic write: two concurrent intents serialize on the flock, so whichever runs last (and is
            // therefore authoritative on disk) is also the last to record. A trailing UNLOCKED write could
            // otherwise be descheduled and let an earlier-decided outcome overwrite the authoritative one
            // (panel P3). Always-on (NOT QA-gated, so it survives in Release): a privacy-safe record of this
            // attempt's outcome AND the specific branch reason, surfaced in the redacted bug report so the
            // closed-app path is diagnosable on internal TestFlight without a device or the QA device log.
            FocusSwitchDiagnostics.record(
                FocusSwitchDiagnosticRecord(outcome: decision.outcome.rawValue, targetFilterID: id, at: env.now(), reason: decision.reason),
                in: env.defaults
            )
            return decision
        }
        env.log("focus-switch-finished", ["filterID": id, "outcome": decision.outcome.rawValue, "reason": decision.reason])
        return decision.outcome
    }

    // NOTE (panel P1, LAV-100 Phase 4 round 5): there is deliberately NO "cancel on Focus-off" entry point.
    // `SetFocusFilterIntent.perform()` runs with a nil filter on deactivation but carries NO Focus identity,
    // so the off-edge cannot tell WHICH Focus turned off. A single shared marker slot holds only the NEWEST
    // Focus intent, so blindly clearing it on any Focus-off could drop a DIFFERENT, still-active Focus's
    // just-recorded switch (a lost update). A filter is a sticky choice (another Focus or a manual tap is what
    // changes it next), and the foreground reconcile already drops genuinely-stale markers via its
    // lastForegroundSwitch supersession + already-active/target-gone guards; a deferred switch re-applying is
    // the tolerated, self-healing direction. So the intent's nil edge is a pure no-op.

    // MARK: - Core

    private static func runLocked(toFilterID id: String, env: Environment) async -> SwitchDecision {
        let defaults = env.defaults
        let now = env.now()

        // Load (configuration, library, didReseed) from the App Group container — the engine's own
        // working copies (no AppViewModel). A missing/corrupt/migration-needed library reseeds defaults
        // and reports didReseed; the gate below refuses in that case.
        let loaded = loadState(env: env)
        var configuration = loaded.configuration
        let library0 = loaded.library

        // Security boundary, fail-closed: Focus auto-switch is available to ALL tiers (the Plus paywall was
        // dropped — founder 2026-06-29), but it is OFF whenever filter editing requires authentication (an
        // unattended switch would otherwise bypass that gate). A gated-out request is NOT recorded — it must
        // not happen now or on a later reconcile.
        guard !SecurityProtectedSurfaceStorage.isProtected(.filterEditing, defaults: defaults) else {
            // The switch is refused while filter editing is auth-locked — tell the user the auto-switch
            // they expected did NOT happen (only when we can name the target; an unknown id is an edge we
            // stay silent on). The closure gates on the toggle + closed/backgrounded + permission; the
            // Shortcuts/automation caller's closure drops this refusal (its thrown error is that caller's
            // failure feedback — see FocusSwitchEnvironment.OutcomeFeedback).
            if let name = library0.filter(id: id)?.name {
                await env.notifySwitchOutcome(false, name)
            }
            return SwitchDecision(.disallowed, "disallowed-auth-to-edit")
        }

        // A reseeded/migrated load mirrored Balanced into `configuration` WITHOUT persisting (the
        // foreground migration hasn't landed), OR the device-global config file failed to load (a default
        // AppConfiguration would clobber the user's real settings). Committing here — or recording a marker
        // for a target id derived from the reseeded library — would let default rules/settings be written
        // over the user's real state at a winning generation. Refuse so the foreground applies the real
        // switch after its migration commits; a later Focus edge re-fires against the migrated library.
        guard !loaded.didReseed else { return SwitchDecision(.disallowed, "disallowed-config-fallback-or-reseed") }

        var library = library0

        // Target must exist + be switchable (not over the tier's filter cap).
        guard library.filter(id: id) != nil,
              !library.isFrozen(filterID: id, maxFilters: configuration.limits.maxFilters) else {
            return SwitchDecision(.disallowed, "disallowed-target-unavailable")
        }

        // Already-active: the newest Focus intent's target is what's already on disk. RECORD it anyway
        // (overwriting any OLDER pending request to a different filter) so the foreground reconcile can't
        // switch AWAY from the now-desired filter, then nudge the foreground. Best-effort record (the
        // desired filter is already active, so a missing self-heal marker can't produce a wrong state).
        guard id != library.activeFilterID else {
            PendingFilterSwitchStore.record(PendingFilterSwitchRequest(targetFilterID: id, requestedAt: now), in: defaults, lockURL: env.pendingMarkerLockURL)
            env.postSignal(FocusFilterSwitchSignal.darwinNotificationName)
            return SwitchDecision(.alreadyActive, "already-active")
        }

        // Record the durable marker FIRST — the correctness guarantee for everything below. If the write
        // fails (theoretically impossible for this Codable), FAIL CLOSED.
        let request = PendingFilterSwitchRequest(targetFilterID: id, requestedAt: now)
        guard PendingFilterSwitchStore.record(request, in: defaults, lockURL: env.pendingMarkerLockURL) else {
            env.log("record-failed-fail-closed", ["filterID": id])
            return SwitchDecision(.disallowed, "disallowed-record-failed")
        }

        // STATE-AGNOSTIC commit (founder 2026-06-29): the engine no longer defers on a coarse
        // "app foreground-active" flag — that 5-minute window was a Phase-3 coordination from before the
        // cross-process CAS existed and produced a dead zone where a closed-app switch only applied on next
        // foreground. The Phase-4 cross-process write lock + generation fence (SharedFilterStatePersistence,
        // taken by BOTH the foreground publishers AND this commit) now make a concurrent foreground write
        // safe: the loser aborts cleanly rather than clobbering. So we always attempt the warm commit
        // regardless of app state; the marker + foreground reconcile + lastForegroundSwitch settle
        // manual-vs-Focus precedence to the time-correct (newer-wins) result.

        // Plan the transition up front so the warm artifact is validated against the TARGET's mirrored
        // configuration (the config its token was compiled against), NOT the current active config.
        guard let target = library.filter(id: id),
              let plan = FilterSwitchPlan.make(toFilterID: id, configuration: configuration, library: library) else {
            env.postSignal(FocusFilterSwitchSignal.darwinNotificationName)
            return SwitchDecision(.deferred, "deferred-plan-unavailable")
        }

        // Warm-only immediate commit. No valid warm artifact ⇒ defer (the foreground cold-compiles on
        // next activation; the headless path never cold-compiles in an App Intent's short window).
        let warmIndex = loadWarmIndex(env: env)
        guard let reusable = await WarmFilterSnapshotLoader.reusableSnapshotForSwitch(
            target: target,
            configuration: plan.configuration,
            containerURL: env.containerURL,
            cacheURL: env.catalogCacheURL,
            freshnessMaxAge: env.catalogSyncFreshnessInterval,
            backgroundWarmIndex: warmIndex
        ) else {
            env.postSignal(FocusFilterSwitchSignal.darwinNotificationName)
            return SwitchDecision(.deferred, "deferred-no-warm-artifact")
        }

        // Final catalog re-validation before the flip: a BACKGROUND catalog refresh could have committed
        // a new latest.json since the warm load. On a move, DEFER (the foreground cold-compiles against the
        // new catalog).
        guard await WarmFilterSnapshotLoader.stillReusableAgainstCachedCatalog(
            reusable.preparedSnapshot,
            configuration: plan.configuration,
            cacheURL: env.catalogCacheURL,
            freshnessMaxAge: env.catalogSyncFreshnessInterval
        ) else {
            env.postSignal(FocusFilterSwitchSignal.darwinNotificationName)
            return SwitchDecision(.deferred, "deferred-catalog-moved")
        }

        // Snapshot the pre-switch state so a partial commit can be rolled back to a CONSISTENT on-disk
        // selection (mirrors the foreground switch's failure rollback).
        let previousConfiguration = configuration
        let previousLibrary = library
        do {
            // Commit via the SHARED publish path, exactly as the foreground warm reuse does: config
            // (generation-bumped, config-leads-pointer) + library, then a pointer FLIP to the already
            // staged warm dir. Take BOTH halves from the same atomic plan so the synced pair matches.
            configuration = plan.configuration
            library = plan.library

            // In-lock catalog-basis veto (Codex round-16): the off-lock revalidation can pass against the
            // OLD latest.json and then a background catalog refresh can win the publish lock — committing a
            // newer catalog + flipping its pointer — before THIS path reaches the flip. Re-run the SAME
            // basis check INSIDE the held publish lock, immediately before the flip; throwing aborts before
            // any state change. Capture the Sendable inputs as locals — the closure runs off the main actor.
            let basisCacheURL = env.catalogCacheURL
            let basisMaxAge = env.catalogSyncFreshnessInterval
            let basisSnapshot = reusable.preparedSnapshot
            let basisConfiguration = plan.configuration
            try await commit(
                preparedSnapshot: reusable.preparedSnapshot,
                configuration: &configuration,
                library: &library,
                warmIndex: warmIndex,
                env: env,
                commitBeforeFlip: { @Sendable in
                    guard BlocklistCatalogSynchronizer.hasFreshCachedCatalog(in: basisCacheURL, maxAge: basisMaxAge),
                          let cachedCatalog = try? BlocklistCatalogSynchronizer(cacheDirectoryURL: basisCacheURL).loadCachedCatalogMetadata(),
                          basisSnapshot.canReuseForProtectionStartup(configuration: basisConfiguration, cachedCatalog: cachedCatalog)
                    else {
                        throw CatalogMovedError()
                    }
                }
            )
            // The extension can't push to the always-on tunnel (sendProviderMessage is app-only, and a
            // tunnel-side Darwin observer is unreliable when idle — see P4d), so the tunnel POLLS the
            // configuration generation and adopts this committed switch on its next tick. LEAVE the marker
            // for the foreground reconcile to clear so a still-resident foreground re-syncs its stale
            // in-memory state to the committed target.
            //
            // NUDGE the foreground even on a COMMITTED switch (Codex P1, state-agnostic switch): now that the
            // commit can land WHILE the app is foreground-active, a resident AppViewModel would otherwise stay
            // on the old filter (in-memory + UI) until its next scene transition — and any foreground edit
            // before that could persist its stale library/config over this committed switch. The app-direction
            // Darwin signal wakes its reconcile promptly to adopt the committed target and clear the marker.
            // (Under Phase 3 commits were inactive-only, so the next foreground activation reconciled; the
            // state-agnostic path needs the explicit wake.)
            env.postSignal(FocusFilterSwitchSignal.darwinNotificationName)
            // Tell the user the headless switch landed — "Switched to <name>" — but only when the app is
            // closed/backgrounded (the closure's gate); a foreground app shows the change in-UI, so a banner
            // would be redundant. This is the mitigation for iOS's suspended-app extension-launch latency: a
            // late background switch still surfaces. Gated inside on permission + the shared
            // filterChanged toggle (both the Focus extension and the Shortcuts/automation intent post
            // committed switches under that one category — founder 2026-07-12).
            await env.notifySwitchOutcome(true, target.name)
            return SwitchDecision(.committed, "committed")
        } catch is CatalogMovedError {
            // CLEAN DEFER: the in-lock veto aborted the flip before any pointer change. Roll the on-disk
            // config+library back to the previous filter so the selection stays consistent with the un-flipped
            // pointer, then defer: the kept marker drives the foreground reconcile to cold-compile the target
            // against the NEW catalog. FENCE the rollback against our own write — the config write released its
            // lock before the publish lock, so a foreground writer could have advanced the generation in that
            // gap; `try?` swallows the resulting StaleBaseGenerationError abort, leaving the newer state intact
            // (panel P1). `configuration.configurationGeneration` is the generation our commit wrote (this
            // throw originates in commitBeforeFlip, AFTER the config write).
            let fencedGeneration = configuration.configurationGeneration
            configuration = previousConfiguration
            library = previousLibrary
            try? writeConfigurationOnly(configuration: &configuration, library: &library, expectedBaseGeneration: fencedGeneration, env: env)
            env.log("headless-commit-deferred-catalog-moved", ["filterID": id])
            env.postSignal(FocusFilterSwitchSignal.darwinNotificationName)
            return SwitchDecision(.deferred, "deferred-catalog-moved-inlock")
        } catch let supersedingWriterError where
            supersedingWriterError is SupersededError ||
            supersedingWriterError is SharedFilterStatePersistence.StaleBaseGenerationError {
            // CLEAN DEFER — and DO NOT roll back. A concurrent (foreground) writer is NEWER, caught at one of
            // two points: StaleBaseGenerationError — the on-disk generation advanced past our loaded base
            // BEFORE our config write, so nothing of ours was written; or SupersededError — it advanced
            // between our config write and the flip, so our flip never happened. Either way the newer on-disk
            // state is authoritative; rolling back to OUR previous (older) state would bump the generation
            // again and OVERWRITE the newer selection — silently losing the user's update (Codex P1/P2).
            // Leave the newer on-disk state untouched and defer. The kept marker drives the foreground
            // reconcile, where lastForegroundSwitch decides whether this Focus request or the newer manual
            // switch wins.
            env.log("headless-commit-deferred-superseded", ["filterID": id])
            env.postSignal(FocusFilterSwitchSignal.darwinNotificationName)
            return SwitchDecision(.deferred, "deferred-superseded")
        } catch {
            // The config+library MAY have been written BEFORE the artifact pointer flip, so a throw can leave
            // disk SELECTING the target while the pointer still names the previous artifact. Roll the on-disk
            // config+library back so the selection is consistent with the un-flipped pointer; the kept marker
            // drives the foreground reconcile retry. FENCE the rollback against our own write:
            // `configuration.configurationGeneration` holds the loaded base if the write itself threw (nothing
            // landed), or the generation we wrote if the flip threw — either way a foreground writer that
            // advanced past it wins and the rollback is skipped rather than clobbering the user's update.
            let fencedGeneration = configuration.configurationGeneration
            configuration = previousConfiguration
            library = previousLibrary
            do {
                try writeConfigurationOnly(configuration: &configuration, library: &library, expectedBaseGeneration: fencedGeneration, env: env)
                env.log("headless-commit-failed-rolled-back", ["filterID": id, "error": "\(error)"])
            } catch is SharedFilterStatePersistence.StaleBaseGenerationError {
                // A newer writer advanced past our write between the failure and the rollback — leave the newer
                // on-disk state (rolling back would clobber it). Same posture as the superseded clean-defer arm.
                env.log("headless-commit-rollback-skipped-superseded", ["filterID": id])
            } catch let rollbackError {
                env.log("headless-commit-rollback-failed", [
                    "filterID": id,
                    "commitError": "\(error)",
                    "rollbackError": "\(rollbackError)"
                ])
            }
            return SwitchDecision(.deferred, "deferred-commit-failed")
        }
    }

    // MARK: - Commit (mirrors AppViewModel.persistSharedState / persistConfigurationOnly)

    /// Mirror of `AppViewModel.persistSharedState(preparedSnapshot:schedulesAutomaticBackup:false:commitBeforeFlip:)`:
    /// sync the active filter, stamp its compiled token, write the config+library pair through the single
    /// shared writer (config leads pointer), then flip the artifact pointer to the staged warm dir.
    private static func commit(
        preparedSnapshot: PreparedFilterSnapshot,
        configuration: inout AppConfiguration,
        library: inout FilterLibrary,
        warmIndex: BackgroundWarmIndex,
        env: Environment,
        commitBeforeFlip: @escaping @Sendable () throws -> Void
    ) async throws {
        let didRewriteArtifacts = preparedSnapshot.summary.coversEnabledBlocklists(in: configuration)

        // Keep the library's active filter in lockstep with the configuration we're persisting, and record
        // the compiled token so GC keeps this filter's compiled directory warm.
        library.syncActiveFilter(from: configuration)
        if didRewriteArtifacts {
            let token = FilterArtifactStore.versionedToken(for: preparedSnapshot)
            library.mutateFilter(id: library.activeFilterID) { $0.lastCompiledToken = token }
        }

        // Bump the supersession generation + write filter-library.json and configuration.json atomically in
        // the fail-safe order, BEFORE flipping the artifact pointer. The ordering + generation-token +
        // library-stamp logic lives in the single shared writer so the foreground and headless paths can
        // never drift.
        let written = try SharedFilterStatePersistence.writeConfigurationAndLibrary(
            configuration: configuration,
            library: library,
            configurationURL: env.configurationURL,
            filterLibraryURL: env.filterLibraryURL,
            crossProcessLockURL: env.configurationWriteLockURL,
            // Generation-fenced CAS against the LOADED BASE: the extension loaded its base, then awaited warm
            // validation; a foreground writer could have advanced the on-disk config in that window. Abort
            // rather than write our stale device-global config back over theirs (Codex P2). `configuration`
            // here is `plan.configuration`, whose generation is the loaded base (FilterSwitchPlan.make does
            // not bump). The catch in runLocked treats the resulting throw as a clean defer (nothing written).
            rejectsAdvancedBeyond: configuration.configurationGeneration
        )
        configuration = written.configuration
        library = written.library

        guard didRewriteArtifacts else { return }
        // Generation-fenced CAS for the FLIP. The cross-process lock (P4c) makes the read-gen + 2-file
        // writes one atomic slice, but it is RELEASED before persistArtifacts takes the publish lock — so a
        // foreground writer that wins the config-write lock in that gap (now that the switch is state-agnostic,
        // a concurrent foreground write is routine) would advance the on-disk generation past ours. Re-read it UNDER the
        // publish lock immediately before the flip (folded into commitBeforeFlip, which runs there) and
        // abort if it advanced, so we never clobber the newer writer's pointer with our stale-basis
        // artifact. Mirrors the background catalog-refresh's `supersededWhileLocked`; without it the race is
        // still fail-closed + self-healing, but this closes the asymmetry (P4c review P2).
        let writtenGeneration = written.configuration.configurationGeneration
        let configurationURL = env.configurationURL
        let service = FilterSnapshotPreparationService(cacheDirectoryURL: env.catalogCacheURL)
        _ = try await service.persistArtifacts(
            preparedSnapshot,
            containerURL: env.containerURL,
            snapshotFilename: env.snapshotFilename,
            compactSnapshotFilename: env.compactSnapshotFilename,
            publishLockURL: env.publishLockURL,
            lockMode: .blocking,
            supersededWhileLocked: nil,
            commitBeforeFlip: {
                // Generation fence BEFORE the catalog-basis veto: when a foreground supersession AND a catalog
                // move coincide, SupersededError must win — it defers WITHOUT rolling back, so the newer
                // foreground config is preserved. A catalog-only move (no supersession) still throws
                // CatalogMovedError after the fence passes and rolls back safely (panel P2 / round 5).
                guard SharedFilterStatePersistence.onDiskConfigurationGeneration(at: configurationURL) <= writtenGeneration else {
                    throw SupersededError()
                }
                try commitBeforeFlip()
            },
            additionalRetainedTokens: library.retainedWarmArtifactTokens(
                maxFilters: configuration.limits.maxFilters,
                backgroundWarmIndex: warmIndex
            )
        )
    }

    /// Mirror of `AppViewModel.persistConfigurationOnly(schedulesAutomaticBackup: false)`: bump the
    /// generation + write the config+library pair via the single shared writer, no artifact flip. Used to
    /// roll the on-disk selection back to the previous filter after a vetoed/failed commit.
    ///
    /// `expectedBaseGeneration` fences the rollback against OUR OWN write (panel P1): the config write
    /// released its cross-process lock before the publish lock, so a foreground writer could have advanced the
    /// on-disk generation in the gap. Passing the generation THIS commit wrote means the rollback reverts only
    /// if nobody advanced past it; otherwise it aborts (`StaleBaseGenerationError`) and leaves the newer
    /// state, rather than re-bumping the generation and clobbering the user's update.
    private static func writeConfigurationOnly(
        configuration: inout AppConfiguration,
        library: inout FilterLibrary,
        expectedBaseGeneration: Int?,
        env: Environment
    ) throws {
        library.syncActiveFilter(from: configuration)
        let written = try SharedFilterStatePersistence.writeConfigurationAndLibrary(
            configuration: configuration,
            library: library,
            configurationURL: env.configurationURL,
            filterLibraryURL: env.filterLibraryURL,
            crossProcessLockURL: env.configurationWriteLockURL,
            rejectsAdvancedBeyond: expectedBaseGeneration
        )
        configuration = written.configuration
        library = written.library
    }

    // MARK: - Load

    /// Read `(configuration, library, didReseed)` from the App Group container, mirroring
    /// `AppViewModel.loadPersistedConfiguration` + `loadOrMigrateFilterLibrary` for the HEADLESS (read-only)
    /// case: accept only an invariant-valid, current-schema library that did not lose a two-file write
    /// race, mirroring the active filter's four fields into `configuration`; otherwise reseed the three
    /// defaults and report `didReseed` (the gate then refuses, since the headless path never persists a
    /// migration).
    private static func loadState(env: Environment) -> (configuration: AppConfiguration, library: FilterLibrary, didReseed: Bool) {
        var configuration = AppConfiguration()
        var configurationLoaded = false
        if let data = try? Data(contentsOf: env.configurationURL),
           let persisted = try? JSONDecoder().decode(AppConfiguration.self, from: data) {
            configuration = persisted
            configurationLoaded = true
        }

        // FAIL CLOSED if the device-global configuration didn't load: a default `AppConfiguration()` carries
        // DEFAULT resolver/protection/entitlement/logging settings, and committing a switch from it would
        // overwrite the user's real config with defaults. (Before the Plus gate was dropped, a default config
        // had `isPaid == false` and the Plus check caught this implicitly; now we refuse explicitly.) Treat a
        // config-load failure exactly like an unusable library — reseed + `didReseed`, which the gate refuses
        // (Codex). Only proceed on the happy path when BOTH files loaded cleanly.
        if configurationLoaded,
           let data = try? Data(contentsOf: env.filterLibraryURL),
           let persisted = try? JSONDecoder().decode(FilterLibrary.self, from: data) {
            let normalized = persisted.normalized()
            if normalized.isValid,
               normalized.schemaVersion >= FilterLibrary.currentSchemaVersion,
               !normalized.lostWriteRace(againstConfigurationGeneration: configuration.configurationGeneration) {
                mirrorActiveFilter(of: normalized, into: &configuration)
                return (configuration, normalized, false)
            }
        }

        let library = FilterLibrary.seededDefaults(active: .balanced)
        mirrorActiveFilter(of: library, into: &configuration)
        return (configuration, library, true)
    }

    /// Regenerate `configuration`'s four filter-scoped fields from the library's active filter (the
    /// library is the source of truth; the device-global fields are left untouched). Mirror of
    /// `AppViewModel.mirrorActiveFilterIntoConfiguration`.
    private static func mirrorActiveFilter(of library: FilterLibrary, into configuration: inout AppConfiguration) {
        let active = library.activeFilter
        configuration.enabledBlocklistIDs = active.enabledBlocklistIDs
        configuration.customBlocklists = active.customBlocklists
        configuration.blockedDomains = active.blockedDomains
        configuration.allowedDomains = active.allowedDomains
    }

    private static func loadWarmIndex(env: Environment) -> BackgroundWarmIndex {
        BackgroundWarmIndexStore(fileURL: env.backgroundWarmIndexURL).load()
    }

    // MARK: - Lock

    /// Serialize concurrent headless Focus switches with a dedicated app-group flock. Degrade-OPEN if the
    /// lock file is unavailable (same posture as `LavaProtectionCommandService`). The flock is bound to the
    /// open file description, so it stays held across the `await` body and is released on close.
    private static func withFocusSwitchLock<T>(
        at lockURL: URL,
        _ body: () async -> T
    ) async -> T {
        // O_CREAT only (never createFile, which would replace the inode and orphan the lock).
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { return await body() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return await body() }
        defer { flock(descriptor, LOCK_UN) }
        return await body()
    }
}
