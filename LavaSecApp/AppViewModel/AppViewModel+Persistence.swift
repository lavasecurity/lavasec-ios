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
    // MARK: - Shared-state persistence funnels

    @discardableResult
    func persistSharedState(
        preparedSnapshot: PreparedFilterSnapshot? = nil,
        rewritesRuleArtifacts: Bool = true,
        prioritizesConfigurationDurability: Bool = false,
        schedulesAutomaticBackup: Bool = true,
        // A reviewed restore cannot overwrite an extension commit made after its review.
        expectedConfigurationGeneration: Int? = nil,
        // Optional in-lock veto, evaluated immediately BEFORE the artifact pointer flip (inside the held
        // publish lock). The foreground passes nil — its warm→cold rebind already guarantees a
        // current-basis snapshot — so its behavior is byte-identical. The headless warm switch passes a
        // catalog-basis re-check here so a background refresh that committed a newer catalog after the
        // off-lock revalidation can't be out-raced into flipping a stale-basis warm artifact (Codex round-16).
        //
        // SCOPE: commitBeforeFlip is honored ONLY when `didRewriteArtifacts` (below) is true — i.e. it is
        // co-gated with the artifact pointer FLIP it guards. There is no flip without didRewriteArtifacts, so
        // the veto's reachability is exactly the flip's: it can never be silently skipped while a flip still
        // happens. For the headless commit, didRewriteArtifacts is true because the off-lock
        // `canReuseForProtectionStartup` gate already requires the warm snapshot to COVER the target's enabled
        // blocklists (so `coversEnabledBlocklists` holds). A caller that relies on the in-lock veto must
        // therefore also rewrite artifacts (i.e. actually flip); a config-only persist neither flips nor needs
        // the veto (founder review P2-1).
        commitBeforeFlip: (@Sendable () throws -> Void)? = nil,
        diagnosticFailureEvent: (@Sendable () -> FocusSwitchDiagnosticEvent?)? = nil
    ) async throws -> FilterSnapshotPreparationService.PublishOutcome {
        do {
        // INV-PERSIST-1 (pinned: RebootFirstUnlockGuardSourceTests.testPersistFunnelsRefuseWhileLaunchLoadWasBlocked): while the launch load was
        // blocked by Data Protection, the in-memory pair is a placeholder — refuse every write
        // until the post-unlock reload lands. The writer's own unreadable fence covers the
        // pre-unlock window; this guard closes the post-unlock half, where the files are
        // writable again but this model still holds the placeholder.
        guard !sharedStateUnavailableAtLoad else {
            throw LavaSecAppError.sharedStateUnavailable
        }
        guard let containerURL = LavaSecAppGroup.containerURL else {
            throw LavaSecAppError.appGroupUnavailable
        }

        // rewritesRuleArtifacts is false when the snapshot was just reused from
        // the on-disk artifacts (identical bytes) or when only configuration
        // state changed: re-encoding the prepared JSON and rebuilding the
        // compact artifact were measured as the bulk of warm turn-on cost.
        //
        // INV-TIER-1 flip veto: every foreground pointer flip funnels through here, including
        // the catalog-refresh republish that never runs the gated cold prepare — without this
        // veto a lapsed-Plus (or upstream-grown) over-budget filter keeps re-publishing fresh
        // over-budget artifacts forever (2026-07-10 field case: free tier serving a 558,917-rule
        // union past the 500K budget). Over budget ⇒ config still persists (user data is never
        // mutated here) but the artifact pointer does not move; the tunnel's own INV-TIER-1
        // serve gates and the gated cold prepare provide the actionable failure.
        // pinned: TierBudgetEnforcementSourceTests.testPersistSharedStateVetoesOverBudgetArtifactFlip
        let snapshotToPersist = preparedSnapshot ?? preparedSnapshotForCurrentConfiguration()
        let coversEnabledBlocklists = snapshotToPersist.summary.coversEnabledBlocklists(
            in: configuration)
        let fitsTierBudget = FilterRuleBudget.fitsTierBudget(
            recordedTotal: snapshotToPersist.summary.tierBudgetRuleCount,
            maxFilterRules: configuration.limits.maxFilterRules
        )
        let didRewriteArtifacts = rewritesRuleArtifacts && coversEnabledBlocklists && fitsTierBudget

        // 🔴 A VETO HERE IS SELF-PERPETUATING AND WAS INVISIBLE. The configuration still
        // persists (correct — user data is never mutated here) but the artifact pointer does
        // not move, so the config now names blocklists no published artifact covers. The tunnel
        // finds nothing adoptable, serves block-all, and the config write has advanced the
        // generation — so its 60 s poll re-reloads forever against an artifact that will never
        // appear. That is a total DNS outage which nothing reported: this branch wrote no event,
        // and the tier arm's status message only covers the tier arm.
        //
        // The COVERAGE arm is the one that traps: the tier arm at least has an actionable
        // message and a user-fixable cause. Distinguished here so a field log says WHICH.
        //
        // Behaviour is deliberately unchanged — the veto itself is load-bearing for INV-TIER-1
        // (the 2026-07-10 field case above) and relaxing it would republish an artifact that
        // does not cover the enabled set, which is fail-open. Only the silence is fixed.
        if rewritesRuleArtifacts, !didRewriteArtifacts {
            logVPNDebugEvent("artifact-flip-vetoed", details: [
                "coversEnabledBlocklists": "\(coversEnabledBlocklists)",
                "fitsTierBudget": "\(fitsTierBudget)",
            ])
            if !coversEnabledBlocklists {
                // The tier arm already has its own actionable message via the callers'
                // surfaceTierBudgetStatusMessage; coverage had nothing at all.
                surfaceSnapshotReconcileFailureStatusMessage()
            }
        }

        // Keep the library's active filter in lockstep with the configuration we're
        // persisting (the only two writers of app-configuration.json funnel through here
        // and persistConfigurationOnly), and record the compiled token (deterministic) so
        // GC keeps this filter's compiled directory warm. The artifact publish happens
        // AFTER the config write (below) per the config-leads-pointer ordering; a token
        // recorded for an as-yet-unpublished dir simply forces a recompile on next use.
        syncActiveFilterFromConfiguration()
        if didRewriteArtifacts {
            let token = FilterArtifactStore.versionedToken(for: snapshotToPersist)
            library.mutateFilter(id: library.activeFilterID) { $0.lastCompiledToken = token }
        }

        // Bump the supersession token + write filter-library.json and configuration.json atomically in
        // the fail-safe order, BEFORE flipping the artifact pointer below (config leads the pointer so a
        // concurrent background publish reads the already-advanced generation and degrade-aborts; the
        // brief config-leads-pointer window is fail-closed — a reader sees an under-covering artifact and
        // cold-rebuilds, never wrong rules). The ordering + generation-token + library-stamp logic lives
        // in the single shared writer (SharedFilterStatePersistence) so the foreground and the headless
        // warm switch can never drift; sync the bumped/stamped values back into the published state.
        let written = try writeSharedStateLoggingFenceTrip {
            try SharedFilterStatePersistence.writeConfigurationAndLibrary(
                configuration: configuration,
                library: library,
                configurationURL: containerURL.appendingPathComponent(LavaSecAppGroup.configurationFilename),
                filterLibraryURL: containerURL.appendingPathComponent(LavaSecAppGroup.filterLibraryFilename),
                prioritizesConfigurationDurability: prioritizesConfigurationDurability,
                // Cross-process CAS: serialize against the App Intents extension's commit (LAV-100 Phase 4 P4c).
                crossProcessLockURL: containerURL.appendingPathComponent(LavaSecAppGroup.configurationWriteLockFilename),
                rejectsAdvancedBeyond: expectedConfigurationGeneration
            )
        }
        configuration = written.configuration
        library = written.library
        refreshFilterSwitchShortcutAfterPersist()
        // Suppressed for the headless warm switch: that model skips loadAutomaticBackupPreference /
        // loadEncryptedBackupState, so its isAutomaticBackupEnabled is the default false and touching the
        // backup envelope here would mishandle it (same hazard as the launch-time persists). The
        // foreground reconcile re-seals + schedules the upload for the committed change instead.
        if schedulesAutomaticBackup {
            backup.scheduleAutomaticBackupAfterConfigurationChange()
        }

        // The artifact-publish outcome of the flip below. `.published` for a config-only persist (no flip,
        // so never superseded); the flip path overwrites it. Surfaced to the foreground switch caller so an
        // `.abortedSuperseded` (a concurrent cross-process Focus commit won the active-filter race) is treated
        // as a deferred, non-winning switch rather than a false success (Codex review, lavasec-ios#29).
        var publishOutcome = FilterSnapshotPreparationService.PublishOutcome.published
        if didRewriteArtifacts {
            // Reciprocal flip fence (Codex P1, state-agnostic switch). The cross-process WRITE lock above is
            // released before persistPreparedSnapshotArtifacts takes the artifact PUBLISH lock, so the App
            // Intents extension can commit + flip a NEWER switch in that gap. Before flipping our pointer,
            // confirm the on-disk selection is STILL the filter this staged artifact is for; if a newer write
            // changed the active filter (a concurrent Focus commit), ABORT the flip rather than overwriting the
            // newer pointer with our stale-basis artifact — which would leave app-configuration.json selecting
            // the Focus target while the live pointer named our snapshot. The pending-switch marker then drives
            // the foreground reconcile to apply the newer selection. The extension's commit has the symmetric
            // in-flip fence; this closes the reverse interleaving. We compare the ACTIVE FILTER (not the raw
            // generation) so a concurrent library-only bump that KEPT our filter active (a warm-token promote,
            // which has no marker to recover an aborted flip) does NOT needlessly abort us. A nil read (just
            // wrote the library atomically) is treated as not-superseded — never abort on an uncertain read.
            let flipTargetFilterID = library.activeFilterID
            let filterLibraryURL = containerURL.appendingPathComponent(LavaSecAppGroup.filterLibraryFilename)
            publishOutcome = try await persistPreparedSnapshotArtifacts(
                snapshotToPersist,
                supersededWhileLocked: { @Sendable _ in
                    guard let onDiskActive = SharedFilterStatePersistence.onDiskActiveFilterID(at: filterLibraryURL)
                    else { return false }
                    return onDiskActive != flipTargetFilterID
                },
                commitBeforeFlip: commitBeforeFlip,
                diagnosticFailureEvent: diagnosticFailureEvent
            )
        }
        // WHAT THIS PERSIST ACTUALLY PUBLISHED, which nothing recorded before.
        //
        // The tunnel's `loadSnapshot-store-miss` names the FIELDS that differed between the artifact
        // it found and the identity it wanted, but not which side is stale — and the two directions
        // are indistinguishable in a capture. Field case 2026-09-01: a preset switch persisted, the
        // app appended its `Changed filters` activity (so it neither threw nor aborted), and the
        // tunnel then missed 21 consecutive reloads on the same artifact. Nothing on this side said
        // whether a flip happened, or which artifact it named, so the capture could not decide it.
        //
        // Logged for EVERY outcome, including the config-only persist that never flips: an absent
        // event and a deliberate no-flip read identically otherwise, and the no-flip case is exactly
        // the one that leaves configuration ahead of the pointer.
        //
        // `publishedArtifactToken` is `<fingerprint>-<millis>` and pairs directly with the tunnel's
        // `artifactToken`; both are content hashes of configuration inputs and carry no domain, rule
        // or user text. The active filter's ID is deliberately NOT logged — filter names are
        // user-authored.
        // pinned: FilterSwitchPublishDiagnosticsSourceTests.testThePersistFunnelRecordsWhatItPublished
        // WHETHER THE TUNNEL CAN TAKE WHAT WE JUST PUBLISHED — the one thing every gate above
        // leaves unasked. `coversEnabledBlocklists`, the tier budget and the pointer flip all
        // describe THIS process's view; none of them compares the stamped identity with the one
        // the tunnel derives from the persisted catalog, and that comparison is the whole contract
        // between the two.
        //
        // It can fail while everything here succeeds. The app stamps from the catalog its prepare
        // RESOLVED; the tunnel reads `loadCachedCatalogMetadata()`. `sync` keeps them in step by
        // persisting the resolved catalog, and the CACHE-ONLY prepare — the headless Focus switch —
        // resolves the same way and persists nothing. Field capture 2026-09-02: a Focus switch
        // published, reported `published`, and the tunnel then refused that artifact on
        // `selectedSourceVersionIDs+selectedSourceHashes` for 17 consecutive reloads over five
        // hours. Nothing on this side was wrong, and nothing on this side could say so.
        //
        // Read off the detached task for the same reason `loadCachedCatalogIfAvailable` is: this
        // funnel is @MainActor and `loadCachedCatalogMetadata` decodes latest.json from disk.
        // A nil read is reported as `no-persisted-catalog`, never as a rejection — see the type.
        // pinned: PublishedArtifactAdoptabilityTests.testAnArtifactResolvedPastThePersistedCatalogIsRejectedOnFreshnessAlone
        let publishedIdentity = snapshotToPersist.identity
        // CAPTURED BEFORE THE AWAIT BELOW, like the identity. The catalog read yields the main
        // actor, so a user toggle or a reconcile can mutate `configuration` inside that window;
        // re-reading the property afterwards would compare the stamped identity against a
        // configuration this persist never wrote, and log e.g. `rejected:inputs:enabledBlocklistIDs`
        // for an epoch that never existed (Kilo review, PR #643).
        let configurationAtPublish = configuration
        var persistedCatalogForAdoptability: BlocklistCatalog?
        if let adoptabilityCacheURL = catalogCacheURL {
            persistedCatalogForAdoptability = await Task.detached(priority: .utility) {
                try? BlocklistCatalogSynchronizer(cacheDirectoryURL: adoptabilityCacheURL)
                    .loadCachedCatalogMetadata()
            }.value
        }
        let tunnelAdoptability = PublishedArtifactAdoptability.verdict(
            artifactIdentity: publishedIdentity,
            configuration: configurationAtPublish,
            persistedCatalog: persistedCatalogForAdoptability
        )
        logVPNDebugEvent("snapshot-publish-outcome", details: [
            "didRewriteArtifacts": "\(didRewriteArtifacts)",
            "rewritesRuleArtifacts": "\(rewritesRuleArtifacts)",
            "coversEnabledBlocklists": "\(coversEnabledBlocklists)",
            "fitsTierBudget": "\(fitsTierBudget)",
            "publishOutcome": "\(publishOutcome)",
            "publishedArtifactToken": FilterArtifactStore.versionedToken(for: snapshotToPersist),
            "tunnelAdoptability": tunnelAdoptability.diagnosticValue
        ])
        return publishOutcome
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch let diagnosticFailure as FocusSwitchDiagnosticFailure {
            throw diagnosticFailure
        } catch {
            guard let event = diagnosticFailureEvent?() else { throw error }
            throw FocusSwitchDiagnosticFailure(underlying: error, event: event)
        }
    }

    /// Persist the live configuration + library at a freshly-bumped generation.
    ///
    /// `schedulesAutomaticBackup` is false ONLY for the launch-time generation-bump persists
    /// (migration / `reconcileLoadedLibraryGenerationIfNeeded`): those run during `init`, before
    /// `isAutomaticBackupEnabled` and the encrypted-backup state are loaded, so the re-seal would
    /// clear the upload marker but see the default `isAutomaticBackupEnabled == false` and never
    /// schedule the upload — leaving an auto-backup user's backup looking un-uploaded until a later
    /// edit (Codex r24). Suppressing the backup hook there is safe: a migration only adds the single
    /// Default filter the server's pre-multi-filter payload already restores to, and a reconcile
    /// changes only the (backup-stripped) generation, so neither alters backed-up content — the next
    /// real user change re-seals and uploads normally.
    /// - Parameter refusesIfOnDiskActiveFilterIs: forwarded to the shared writer as an in-lock
    ///   precondition; see `SharedFilterStatePersistence.ActiveFilterChangedError`. Callers that may
    ///   only touch an IDLE filter pass its id, because this model's `library.activeFilterID` is an
    ///   asynchronously-reconciled snapshot and can lag a headless Focus/Shortcut commit.
    /// - Parameter rejectsAdvancedBeyond: forwarded to the shared writer as an in-lock generation
    ///   fence. Library-only callers pass the generation their foreground snapshot loaded so a newer
    ///   headless switch wins instead of being overwritten by that stale whole pair.
    func persistConfigurationOnly(
        schedulesAutomaticBackup: Bool = true,
        rejectsAdvancedBeyond: Int? = nil,
        refusesIfOnDiskActiveFilterIs: String? = nil
    ) throws {
        // INV-PERSIST-1: same placeholder-state refusal as persistSharedState (see there).
        guard !sharedStateUnavailableAtLoad else {
            throw LavaSecAppError.sharedStateUnavailable
        }
        guard let containerURL = LavaSecAppGroup.containerURL else {
            throw LavaSecAppError.appGroupUnavailable
        }

        syncActiveFilterFromConfiguration()

        // Bump the generation + write library (source of truth) then config, via the single shared
        // writer (see SharedFilterStatePersistence) so the ordering + generation token can't drift from
        // persistSharedState / the headless switch. Sync the bumped/stamped values back into state.
        let written = try writeSharedStateLoggingFenceTrip {
            try SharedFilterStatePersistence.writeConfigurationAndLibrary(
                configuration: configuration,
                library: library,
                configurationURL: containerURL.appendingPathComponent(LavaSecAppGroup.configurationFilename),
                filterLibraryURL: containerURL.appendingPathComponent(LavaSecAppGroup.filterLibraryFilename),
                // Cross-process CAS: serialize against the App Intents extension's commit (LAV-100 Phase 4 P4c).
                crossProcessLockURL: containerURL.appendingPathComponent(LavaSecAppGroup.configurationWriteLockFilename),
                rejectsAdvancedBeyond: rejectsAdvancedBeyond,
                refusesIfOnDiskActiveFilterIs: refusesIfOnDiskActiveFilterIs
            )
        }
        configuration = written.configuration
        library = written.library
        refreshFilterSwitchShortcutAfterPersist()
        if schedulesAutomaticBackup {
            backup.scheduleAutomaticBackupAfterConfigurationChange()
        }
    }

    /// Refresh the "Switch Filter" App Shortcut's filter parameter AFTER the library has reached disk
    /// (Codex #325). Both this-app persist funnels — `persistConfigurationOnly` and `persistSharedState`
    /// — call `SharedFilterStatePersistence.writeConfigurationAndLibrary` (the single shared writer) and
    /// then land here, so every list change (create/rename/delete/import, restore-to-default, backup
    /// restore, onboarding seed) refreshes with the CURRENT on-disk list — the shortcut's entity query
    /// reads disk, so refreshing before the write would re-fetch the previous list (r5). Called after the
    /// write, not on `library`'s didSet, for exactly that ordering. Idempotent and cheap, so a config-only
    /// persist harmlessly re-publishes the unchanged list rather than us threading a list-changed flag
    /// through both funnels.
    private func refreshFilterSwitchShortcutAfterPersist() {
        LavaShortcuts.updateAppShortcutParameters()
    }

    /// Route a persist funnel's shared-writer call so a trip of the writer-side
    /// INV-PERSIST-1 fence leaves a loud field breadcrumb before the error propagates.
    ///
    /// The fence (`ExistingStateUnreadableError`) should be UNREACHABLE from this process:
    /// both funnels guard on `sharedStateUnavailableAtLoad`, so the pair was readable when
    /// this model loaded it. A trip therefore means the pair became unreadable AFTER a
    /// successful load — an unmodeled re-lock or I/O fault, exactly the trace the
    /// 2026-07-14 incident never left (plan Phase 4, lavasec-infra
    /// `plans/2026-07-14-reboot-first-unlock-data-reset-incident-plan.md`). Nothing was
    /// overwritten (the fence throws before any write), so the caller's normal error path
    /// still applies — log and rethrow, never swallow.
    // pinned: RebootFirstUnlockGuardSourceTests.testUnreadableClassificationsAndFenceTripsLeaveFieldBreadcrumbs
    private func writeSharedStateLoggingFenceTrip(
        _ write: () throws -> (configuration: AppConfiguration, library: FilterLibrary)
    ) throws -> (configuration: AppConfiguration, library: FilterLibrary) {
        do {
            return try write()
        } catch let error as SharedFilterStatePersistence.ExistingStateUnreadableError {
            LavaSecDeviceDebugLog.append(
                component: "app",
                event: "persist-blocked-existing-unreadable",
                details: [
                    "consequence": "write refused before touching disk (INV-PERSIST-1)",
                    "expectation": "unreachable while the funnels guard on sharedStateUnavailableAtLoad — investigate a post-load re-lock or I/O fault"
                ]
            )
            throw error
        }
    }

    /// Write-through the active filter's four fields from the live `configuration`.
    /// Runs at the persistence boundary so the library's copy of the active filter
    /// never drifts from what's being saved to `app-configuration.json`. If the
    /// contents changed, any cached compile token is now stale, so clear it.
    private func syncActiveFilterFromConfiguration() {
        // The active id should always resolve (normalized on load + invariant-preserving
        // mutations), but repair a dangling id rather than silently skipping the sync —
        // a skipped sync would drift the config and the library apart permanently.
        if library.filter(id: library.activeFilterID) == nil {
            library = library.normalized()
        }
        guard var filter = library.filter(id: library.activeFilterID) else { return }
        // Only publish a library change when the four fields actually moved — a no-op
        // persist (the common case for device-global edits) must not churn @Published.
        guard filter.applyFilterFields(from: configuration) else { return }
        filter.lastCompiledToken = nil
        library.update(filter)
    }

    /// Regenerate the live `configuration`'s four filter-scoped fields from the active
    /// filter (the inverse of `syncActiveFilterFromConfiguration`). Used on load and after
    /// any change to which filter is active — the library is the source of truth, and the
    /// device-global fields on `configuration` are left untouched.
    func mirrorActiveFilterIntoConfiguration() {
        let active = library.activeFilter
        configuration.enabledBlocklistIDs = active.enabledBlocklistIDs
        configuration.customBlocklists = active.customBlocklists
        configuration.blockedDomains = active.blockedDomains
        configuration.allowedDomains = active.allowedDomains
    }

    /// Persist a LIBRARY-ONLY edit (rename / delete / create / warm-token promote — no active-filter or
    /// device-global change). This ADVANCES the shared (config, library) generation via the pair writer.
    ///
    /// It MUST bump the generation, not write the library alone at the current generation: the Focus switch
    /// is now state-agnostic (LAV-100 Phase 4), so the App Intents extension can commit a (config, library)
    /// pair concurrently while the app is foreground. The extension's stale-reader fence (`rejectsAdvancedBeyond`)
    /// watches only the on-disk CONFIG generation — so a library write that left the config generation
    /// unbumped would NOT trip it, and the extension would overwrite this edit with the stale library snapshot
    /// it loaded before the lock (Codex P1: a just-created filter lost / a just-deleted filter resurrected, made
    /// permanent if the app is terminated before the resident in-memory library re-persists). Routing through
    /// `persistConfigurationOnly` bumps the generation so the extension's commit instead fences out
    /// (`deferred-superseded`); the durable pending-switch marker then re-applies the Focus switch onto THIS
    /// updated library on the next foreground reconcile. The config file content is unchanged (a library-only
    /// edit never touches the active filter), so this is purely a generation bump, not a device-global write.
    /// Backup scheduling stays with the caller (`persistLibraryOnlyChange`), so suppress it here to avoid a
    /// double schedule.
    func persistFilterLibrary(refusesIfOnDiskActiveFilterIs: String? = nil) throws {
        try persistConfigurationOnly(
            schedulesAutomaticBackup: false,
            // Reciprocal stale-reader fence: the headless switch already fences its prepared write
            // against foreground generation bumps. A foreground library-only write must likewise
            // refuse when a headless switch advanced disk before its asynchronously-adopted state
            // reached this model; otherwise the stale full pair would switch disk back and could
            // leave the artifact pointer naming a different filter. Every caller rolls its local
            // mutation back on failure, and keyed edit drafts remain available for a retry.
            rejectsAdvancedBeyond: configuration.configurationGeneration,
            refusesIfOnDiskActiveFilterIs: refusesIfOnDiskActiveFilterIs
        )
    }

    // loadCustomizationPreferences + setNotificationCategoryEnabled moved to
    // CustomizationController (Phase D5 peel) with the preference cluster they load/write.

    // Class-None config/library availability does not imply Class-C defaults are
    // readable. Both first-unlock and foreground recovery run this independent load.
    func loadProtectedPreferencesIfAvailable() {
        guard !isHeadless,
              protectedPreferenceRecovery.shouldLoad(
                protectedDataIsAvailable: UIApplication.shared.isProtectedDataAvailable,
                sharedStateIsAvailable: !sharedStateUnavailableAtLoad
              ) else { return }
        customization.loadCustomizationPreferences()
        loadLavaGuardProgress()
        loadSudokuGameState()
        backup.loadAutomaticBackupPreference()
        backup.loadEncryptedBackupState()
        protectedPreferenceRecovery.didLoad()
        refreshLavaGuardProgressFromDiagnostics()
        // Normal init reaches this before the manager's asynchronous status load.
        // Its .invalid placeholder cannot stop usage or end an existing activity;
        // the normal status observation reconciles those once iOS supplies real state.
        if vpnStatus != .invalid {
            synchronizeLavaGuardProgress(currentStatus: vpnStatus)
            reconcileLiveActivity()
        }
    }

    var canUseProtectedPreferences: Bool {
        !isHeadless && protectedPreferenceRecovery.canUsePreferences(
            sharedStateIsAvailable: !sharedStateUnavailableAtLoad
        )
    }

    func loadLavaGuardProgress() {
        guard UIApplication.shared.isProtectedDataAvailable, !sharedStateUnavailableAtLoad else { return }
        guard let data = defaults.data(forKey: lavaGuardProgressDefaultsKeyName),
              let progress = try? JSONDecoder().decode(LavaGuardProgress.self, from: data)
        else {
            lavaGuardProgress = LavaGuardProgress()
            return
        }

        lavaGuardProgress = progress
    }

    func persistLavaGuardProgress() {
        guard canUseProtectedPreferences else { return }
        guard let data = try? JSONEncoder().encode(lavaGuardProgress) else {
            return
        }

        defaults.set(data, forKey: lavaGuardProgressDefaultsKeyName)
    }

    func persistFilterChanges() {
        Task {
            do {
                try await persistSharedState()
                appendAppNetworkActivity(.changeFilters)
                await self.notifyTunnelSnapshotUpdated()
            } catch {
                vpnMessage = error.localizedDescription
                vpnMessageIsError = true
            }
        }
    }

    /// Persist the current config+library pair for an EXPLICIT user reseed (restore-to-default or
    /// onboarding recommended-defaults), then durably drop the reseed-suppression marker ONLY once
    /// the pair has reached disk. The caller lifts the in-memory `libraryOriginatesFromLaunchReseed`
    /// flag first (so this persist's backup hook runs unsuppressed — the user chose these defaults);
    /// this method defers the DURABLE marker clear until the on-disk generation advances, mirroring
    /// `restoreFromBackup`. A persist that fails BEFORE the pair lands leaves the durable marker in
    /// place, so the next launch reads `.present` and keeps suppressing over the un-replaced on-disk
    /// reseed rather than letting automatic backup clobber the last good server copy (INV-PERSIST-2
    /// marker consequence; Codex P1 round 4 on #376). A failure AFTER the pair lands (a post-pair
    /// artifact-publish throw) still drops the marker, keyed on the generation advancing past the
    /// pre-persist basis, not on the throw (Codex P2 round 5 on #376).
    /// - pinned: RebootFirstUnlockGuardSourceTests.testExplicitReseedDefersDurableMarkerDropUntilPersistLands
    func persistFilterReseedDroppingDurableMarkerWhenLanded() {
        Task {
            let generationBeforePersist = configuration.configurationGeneration
            do {
                try await persistSharedState()
                // The reseed pair is durably on disk — now safe to drop the durable marker.
                clearLibraryOriginatesFromLaunchReseed()
                appendAppNetworkActivity(.changeFilters)
                await self.notifyTunnelSnapshotUpdated()
            } catch {
                // persistSharedState is not atomic: the pair write lands (syncing the bumped
                // generation back into `configuration`) BEFORE the artifact-publish step, which can
                // still throw. Key the durable clear on what's ON DISK — the generation advancing
                // past the pre-persist basis — not on the throw (Codex P2 round 5 on #376).
                if configuration.configurationGeneration > generationBeforePersist {
                    clearLibraryOriginatesFromLaunchReseed()
                }
                // else: nothing reached disk — KEEP the durable marker so the next launch
                // re-suppresses over the un-replaced on-disk reseed. The in-memory flag stays lifted
                // for this session (the user asked to reseed); a fresh launch re-derives from the
                // still-present marker.
                vpnMessage = error.localizedDescription
                vpnMessageIsError = true
            }
        }
    }

    func loadPersistedConfiguration() {
        sharedStateUnavailableAtLoad = false
        configurationLoadedFromDisk = false
        if let configurationURL {
            switch SharedStateFileReader.read(AppConfiguration.self, from: configurationURL) {
            case .loaded(let persistedConfiguration):
                configuration = persistedConfiguration
                configurationLoadedFromDisk = true
            case .absent, .corrupt:
                // First launch or real corruption — keeping the default AppConfiguration and
                // letting loadOrMigrateFilterLibrary seed below is the deliberate recovery.
                break
            case .unreadable(let description):
                // The config EXISTS but is locked (Data Protection before first unlock) or
                // transiently unreadable. The default value now in memory is a placeholder,
                // not the user's state — flag it so nothing seeds or persists over the real
                // file (INV-PERSIST-1), and so the load re-runs at first unlock.
                sharedStateUnavailableAtLoad = true
                // Per-file breadcrumb (incident plan Phase 4): post-INV-PERSIST-2 the config
                // carries NSFileProtectionNone, so this firing after the control-plane
                // migration ran signals a live anomaly, not just a pre-migration locked boot
                // — a field log must show WHICH of the pair classified unreadable. The
                // underlying read error rides along (the outcome carries it for exactly this),
                // so a field log can tell a Data-Protection lock apart from a real I/O fault.
                // pinned: RebootFirstUnlockGuardSourceTests.testUnreadableClassificationsAndFenceTripsLeaveFieldBreadcrumbs
                LavaSecDeviceDebugLog.append(
                    component: "app",
                    event: "config-unreadable-at-load",
                    details: [
                        "consequence": "placeholder in memory; persists blocked until recovery reload (INV-PERSIST-1)",
                        "error": description,
                    ]
                )
            }
        }

        loadOrMigrateFilterLibrary()
    }

    /// Re-run the blocked launch load once protected data is readable (INV-PERSIST-1 recovery).
    /// No-op unless `loadPersistedConfiguration` classified the shared state as
    /// existing-but-unreadable, so the normal launch never reloads here. Wired to
    /// `UIApplication.protectedDataDidBecomeAvailableNotification` (fires at first unlock —
    /// exactly when Class-C content becomes readable) and re-checked on every foreground in
    /// case the notification was delivered before this process observed it.
    func reloadSharedStateIfBlockedByDataProtection() {
        guard sharedStateUnavailableAtLoad else { return }
        loadPersistedConfiguration()
        if !sharedStateUnavailableAtLoad {
            recoverUserProtectionIntentFromDurableState()
            LavaSecDeviceDebugLog.append(component: "app", event: "shared-state-reloaded-after-unlock")
            // Rerun the init task's catalog + tunnel tail against the REAL state (Codex P1
            // round 5 + P2 round 7 on #376): the pre-unlock pass loaded the cache/sync and
            // derived rule state (cachedBlockRuleSets, blockRules, counts, source states)
            // against the seeded placeholder — and against a still-LOCKED catalog cache —
            // and, with hasCompletedOnboarding reading false from the locked standard
            // defaults, skipped the post-launch tunnel snapshot reconcile entirely. Both
            // reads are truthful here (this path only runs after a successful protected
            // read). Order mirrors init: catalog first, so the reconcile builds from real
            // rules. The NOT-onboarded neutralize is deliberately not rerun: its one-shot
            // skip stays the documented residual (see init).
            if loadsVPNState {
                Task {
                    await loadCachedCatalogIfAvailable()
                    await syncCatalogIfStale()
                    if hasCompletedOnboarding {
                        await reconcileTunnelSnapshotAfterLaunch()
                    }
                }
            }
        }
    }

    /// Persists a user-accepted explicit direction without touching the Focus-owned
    /// configuration/library pair (INV-PERSIST-3). Call only after the protection lifecycle mutation fence is
    /// owned; callers deliberately let errors escape before their first stop/disarm/start effect.
    func persistExplicitProtectionIntent(isEnabled: Bool) throws {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            throw LavaSecAppError.appGroupUnavailable
        }
        try ProtectionRestoreIntentStore.persist(isEnabled: isEnabled, containerURL: containerURL)
    }

    /// Replaces the launch/recovery restore intent from the dedicated explicit-intent sidecar.
    ///
    /// Existing installs have no sidecar, so only `.absent` retains the historical configuration
    /// fallback. A corrupt or unreadable record is deliberately restore-ineligible (INV-PERSIST-3) rather than
    /// allowing a stale configuration true to surprise-enable protection. The breadcrumbs carry
    /// a stable classification and consequence only — never an App Group path or raw I/O error.
    func recoverUserProtectionIntentFromDurableState() {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            userProtectionIntent.recoverFromLoadedConfiguration(isEnabled: false)
            return
        }

        switch ProtectionRestoreIntentStore.read(containerURL: containerURL) {
        case let .stored(isEnabled):
            userProtectionIntent.recoverFromLoadedConfiguration(isEnabled: isEnabled)
        case .absent:
            userProtectionIntent.recoverFromLoadedConfiguration(isEnabled: configuration.protectionEnabled)
        case .corrupt:
            userProtectionIntent.recoverFromLoadedConfiguration(isEnabled: false)
            LavaSecDeviceDebugLog.append(
                component: "app",
                event: "protection-restore-intent-corrupt-at-load",
                details: [
                    "consequence": "automatic restore suppressed until an explicit user action",
                ]
            )
        case .unreadable:
            userProtectionIntent.recoverFromLoadedConfiguration(isEnabled: false)
            LavaSecDeviceDebugLog.append(
                component: "app",
                event: "protection-restore-intent-unreadable-at-load",
                details: [
                    "consequence": "automatic restore suppressed until an explicit user action",
                ]
            )
        }
    }

    /// Load the filter library, or (first launch on a multi-filter build, or a
    /// corrupt/empty file) migrate the legacy single-filter configuration into a
    /// one-filter "Default" library. Cheap and synchronous — an array-wrap, no parse
    /// or compile — so it is safe in the launch path next to `loadPersistedConfiguration`.
    ///
    /// The library is the source of truth: on load, the active filter's four fields are
    /// mirrored OUT of the library into `configuration` (a derived cache). This makes the
    /// persisted `activeFilterID` + active-filter contents recover together — a process
    /// kill between the library write and the config write is reconciled in the library's
    /// favour. Restore-safe because the backup payload now carries the whole library.
    private func loadOrMigrateFilterLibrary() {
        // Tri-state read (INV-PERSIST-1): only a definitive outcome — absent or
        // readable-but-corrupt — may fall through to the seed/migration below. An
        // existing-but-UNREADABLE library (Data Protection before first unlock) marks the
        // whole load unavailable instead: the reseed then stays a pure in-memory
        // placeholder and the persist at the bottom is skipped, because the "missing"
        // data is really the user's intact, locked filter library (the 2026-07-14 wipe).
        var loadedLibrary: FilterLibrary?
        var libraryWasCorrupt = false
        var reseedReplacesDeliberatelyMigratedLibrary = false
        if let filterLibraryURL {
            switch SharedStateFileReader.read(FilterLibrary.self, from: filterLibraryURL) {
            case .loaded(let persisted):
                loadedLibrary = persisted
            case .absent:
                break
            case .corrupt:
                // Read fine, failed to decode — the one genuine data-loss recovery case, and
                // the only reseed whose persist stamps the durable backup suppression below.
                libraryWasCorrupt = true
            case .unreadable(let description):
                sharedStateUnavailableAtLoad = true
                // Per-file breadcrumb (incident plan Phase 4): the library is the file the
                // 2026-07-14 wipe destroyed — the field log names it distinctly from the
                // config classification above, and carries the underlying read error so a
                // Data-Protection lock is diagnosable apart from a real I/O fault.
                // pinned: RebootFirstUnlockGuardSourceTests.testUnreadableClassificationsAndFenceTripsLeaveFieldBreadcrumbs
                LavaSecDeviceDebugLog.append(
                    component: "app",
                    event: "filter-library-unreadable-at-load",
                    details: [
                        "consequence": "placeholder in memory; persists blocked until recovery reload (INV-PERSIST-1)",
                        "error": description,
                    ]
                )
            }
        }
        if let persisted = loadedLibrary {
            let normalized = persisted.normalized()
            // Accept only an invariant-valid library (>=1 filter, active id resolves) that did NOT
            // lose a two-file write race: a library stamped with an OLDER config generation than the
            // config on disk is stale (e.g. a restore wrote a newer config but this library write
            // never landed), so we reject it and migrate from the durable config instead — keeping
            // the restored device-global config + active filter rather than reverting to the stale
            // library (Codex r20). A corrupt/empty/dangling file likewise falls through to migration.
            if normalized.isValid,
               normalized.schemaVersion >= FilterLibrary.currentSchemaVersion,
               !normalized.lostWriteRace(againstConfigurationGeneration: configuration.configurationGeneration) {
                library = normalized
                // The on-disk library was accepted as-is (no reseed): a headless background
                // publish may proceed against this config.
                didReseedFilterLibraryOnLastLoad = false
                // A persisted library is now live, so an earlier UNREADABLE-launch placeholder
                // is gone — lift the suppression it carried (Codex P2 on #376: without this,
                // the first-unlock recovery reload left automatic backups disabled all
                // session). EXCEPT when the durable marker says this accepted library IS a
                // recovery reseed a prior launch persisted over an absent/corrupt store (Codex
                // P1): then the suppression carries across the relaunch until a user-authoritative
                // clear (restore / restore-to-default / onboarding seed).
                //
                // INV-PERSIST-2 made filter-library.json Class-None, so this accept branch runs
                // pre-first-unlock too. The durable marker is the Class-None ReseedSuppression-
                // MarkerStore FILE, whose existence is readable while the device is locked, so a
                // 1.2.5-native device is decided INLINE here with no protected-data gate — the 1.2.4
                // read-gate + deferred-re-read hack a Class-C UserDefaults marker forced is gone for
                // that device (its locked read was a spurious `false`). The ONE case that still
                // cannot decide inline is a device upgrading from 1.2.4 whose legacy Class-C marker
                // has not migrated to the file yet AND whose first post-upgrade launch is
                // pre-first-unlock: the file marker is absent and the legacy store is unreadable, so
                // lifting would clobber the user's last good server backup with the seeded reseed
                // (Codex P1 on #385). That case FREEZES the suppression and re-derives at unlock.
                // pinned: RebootFirstUnlockGuardSourceTests.testAcceptedLibraryHonorsDurableFileMarker
                switch reseedSuppressionMarkerState() {
                case .present:
                    libraryOriginatesFromLaunchReseed = true
                case .absentConfirmed:
                    libraryOriginatesFromLaunchReseed = false
                case .absentUnconfirmed:
                    // Upgrade-transition conservative freeze (Codex P1 on #385): keep the
                    // suppression and re-derive once protected data is readable
                    // (confirmReseedSuppressionAfterUnlock). A 1.2.5-native device's state lives in
                    // the readable file marker, so it never reaches this branch with a real
                    // suppression — the freeze is harmless there and self-heals at first unlock.
                    libraryOriginatesFromLaunchReseed = true
                    reseedSuppressionAwaitingUnlockConfirmation = true
                }
                // Library is authoritative — regenerate the active filter's mirror in
                // `configuration` from it (the inverse of the persist-boundary sync).
                mirrorActiveFilterIntoConfiguration()
                reconcileLoadedLibraryGenerationIfNeeded()
                return
            }
            // Falling through with a library that READ fine and is invariant-valid, but is
            // old-schema or lost the two-file write race: the reseed below is the DESIGNED
            // upgrade migration replacing it, not recovery from data loss — so it must not
            // suppress automatic backup (suppressing left every later edit in the session
            // out of the local/remote envelope, and manual Back Up Now uploading a stale
            // pre-edit envelope — Codex P2 round 2 on #376).
            reseedReplacesDeliberatelyMigratedLibrary = normalized.isValid
        }
        // An ABSENT library beside a READABLE, decoded config is the pre-library build's
        // legacy upgrade — the same designed migration as the old-schema case above, not
        // data loss. Suppressing here would freeze an existing auto-backup user's re-seals
        // and uploads indefinitely: onboarding never reruns for them, and restore/reset are
        // recovery actions they have no reason to take (Codex P2 round 7 on #376).
        if loadedLibrary == nil, !libraryWasCorrupt, !sharedStateUnavailableAtLoad, configurationLoadedFromDisk {
            reseedReplacesDeliberatelyMigratedLibrary = true
        }

        // No current (>= currentSchemaVersion), invariant-valid library that won the write race →
        // seed the three default filters (Core / Balanced / Extra) with Balanced loaded. This is
        // BOTH the first-launch seed and the on-upgrade migration: a pre-three-defaults library
        // (older schema) or a legacy single-filter config is replaced, so existing users move to
        // Balanced — a deliberate no-back-compat reset while the app is not yet public. Onboarding
        // re-seeds with the user's chosen level active when it runs on a fresh install.
        library = .seededDefaults(active: .balanced)
        // Flag the reseed so a headless background publish ABORTS: this mirrors Balanced into
        // the in-memory `configuration` below but the persist is foreground-only, so the
        // background model would otherwise build + publish Balanced artifacts while
        // app-configuration.json still describes the pre-upgrade filter — and the generation
        // guard would NOT catch it (no config was written, so the on-disk generation is
        // unchanged). The publish path checks this and bails until the foreground migration
        // lands (the user's next launch persists it, after which this stays false).
        didReseedFilterLibraryOnLastLoad = true
        if reseedReplacesDeliberatelyMigratedLibrary {
            // Designed upgrade migration of a readable, coherent library: the reseed IS the
            // intended new state (persisted just below), so automatic backup stays live — the
            // migration and every subsequent edit belong in the next sealed envelope.
            clearLibraryOriginatesFromLaunchReseed()
        } else if sharedStateUnavailableAtLoad {
            // Unreadable (Data-Protection-locked) store: in-memory suppression only. The
            // placeholder is never persisted, so the recovery reload's accept of the user's
            // real library lifts this — a durable marker would wrongly outlive that accept.
            libraryOriginatesFromLaunchReseed = true
        } else {
            // Genuinely-fresh install (both files absent — lifted by the onboarding seed
            // that always follows) or corrupt library (the remote envelope may hold the
            // user's last good library; an automatic upload would clobber it — incident
            // plan latent-3). Suppress IN MEMORY now; the DURABLE stamp (Codex P1) waits
            // until the persist below actually lands — a headless read-only load or a
            // swallowed persist failure must not poison future launches with a marker for
            // a reseed that never reached disk (Codex P2 round 6).
            libraryOriginatesFromLaunchReseed = true
        }
        mirrorActiveFilterIntoConfiguration()
        // Persist the migration only from a foreground instance. The headless
        // background-refresh model is read-only — writing here could race a foreground
        // upgrade/manage action and overwrite a just-created multi-filter library with a
        // singleton migration from this model's launch-time config. (The in-memory library
        // is still populated so the headless model can read it.)
        //
        // Persist via persistConfigurationOnly so the migration BUMPS the generation: a legacy config is
        // itself generation 0, so an un-bumped library write would stamp the freshly-migrated library
        // at generation 0 — the value lostWriteRace TRUSTS. A later config-first restore that's
        // killed before its library write would then leave this generation-0 file to win over the
        // restored config (Codex r23). persistConfigurationOnly bumps the generation first, so the
        // migrated library + config are written together at a non-zero generation that a future
        // restore can supersede. (Library-only edits now route here too — see persistFilterLibrary —
        // so every library write bumps the shared generation.) Suppress the backup hook: this runs during init before the
        // auto-backup flag is loaded, and a migration only adds the Default filter the server copy
        // already restores to (Codex r24) — the next real change re-seals + uploads.
        if !isHeadless {
            // INV-PERSIST-1: a reseed born from an UNREADABLE (not absent/corrupt) load is a
            // placeholder over the user's intact, locked files — never persist it. The persist
            // funnel's own guard would throw anyway; skipping here keeps the launch quiet and
            // leaves recovery to reloadSharedStateIfBlockedByDataProtection at first unlock.
            if !sharedStateUnavailableAtLoad {
                // The durable suppression marker (Codex P1) is stamped BEFORE the persist: the
                // shared writer lands filter-library.json FIRST, so a crash or throw between
                // its two file writes must never leave a durable seeded library behind without
                // its marker — the next launch would accept it with suppression lifted (Codex
                // P2 round 8). The reverse residual — marker present with nothing landed — is
                // self-consistent: the next launch re-encounters the absent/corrupt store and
                // re-derives the same suppression. Round 6's poisoning hazard stays closed:
                // this path cannot pre-stamp against a GOOD on-disk library (it only runs when
                // the foreground load found the store absent/corrupt), and headless read-only
                // loads never reach it. The deliberate migration cleared the in-memory flag
                // above, so it never stamps.
                //
                // And if the STAMP ITSELF fails (transient marker-path/app-group write error), the
                // reseed library must NOT be persisted: a durable seeded library with no durable
                // marker reads `.absentConfirmed` next launch and clobbers (Codex P1 round 5 on
                // #385). Skipping leaves the store absent/corrupt so the next launch re-reseeds and
                // re-stamps; the in-memory library still serves this session. The deliberate
                // migration needs no marker, so it persists unconditionally.
                let markerLanded = libraryOriginatesFromLaunchReseed
                    ? markLibraryOriginatesFromPersistedRecoveryReseed()
                    : true
                if markerLanded {
                    try? persistConfigurationOnly(schedulesAutomaticBackup: false)
                }
            }
        }
    }

    /// After accepting an on-disk library on load, bring the two files onto a single, NON-ZERO
    /// generation. Three cases need it (all one-time — the steady state is library.gen == config.gen
    /// > 0, which no-ops): the library won a write race so the config is stale (Codex r22); the
    /// library is at the generation-0 sentinel a legacy/pre-marker file decodes to (Codex r21); or
    /// both are still 0. In every case advance the in-memory generation to at least the library's so
    /// a headless background publish ABORTS against the unchanged on-disk generation, and — in the
    /// foreground — durably rewrite BOTH files at a bumped generation so a later restore can
    /// supersede this library instead of trusting a stale generation-0 stamp (Codex r23).
    private func reconcileLoadedLibraryGenerationIfNeeded() {
        guard library.configurationGeneration != configuration.configurationGeneration
            || library.configurationGeneration == 0 else {
            return
        }
        configuration.configurationGeneration = max(
            configuration.configurationGeneration,
            library.configurationGeneration
        )
        if !isHeadless {
            // Suppress the backup hook (launch-time, before the auto-backup flag is loaded). A
            // reconcile changes only the backup-stripped generation, so backed-up content is
            // unchanged anyway (Codex r24).
            // INV-PERSIST-1: skipped while the CONFIG side of the pair was unreadable at load —
            // this durable rewrite would pair the accepted library with a placeholder config.
            // The in-memory generation advance above still runs, so the headless-publish abort
            // semantics are unchanged; the rewrite happens on the post-unlock reload instead.
            if !sharedStateUnavailableAtLoad {
                try? persistConfigurationOnly(schedulesAutomaticBackup: false)
            }
        }
    }

    // persistDiagnostics and writeDiagnosticsClearControl (the PST-1 paired-timestamp
    // control write) moved to DiagnosticsController.swift with the clear flows
    // (Phase D4 peel).


}
