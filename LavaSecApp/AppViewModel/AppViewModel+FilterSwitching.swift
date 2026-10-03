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
    // MARK: - Filter switching

    func switchToFilter(id: String, stampsForegroundSwitch: Bool = true) async {
        // The four-scoped-field mirroring is the shared FilterSwitchPlan transition (same source of
        // truth as the headless warm switch); it already rejects a no-op / unknown target. The library's
        // active selection is committed on the LIVE library at the commit point below (not from the
        // plan's captured copy) so a concurrent warm-token stamp during the async prepare isn't lost.
        guard !isFilterFrozen(id),
              let plan = FilterSwitchPlan.make(toFilterID: id, configuration: configuration, library: library),
              let target = library.filter(id: id)
        else {
            return
        }
        let restoreRequest = makeProtectionRestoreRequest()

        // Mark a genuine USER switch in flight so the Focus reconcile defers to it (round-18) rather than
        // superseding it mid-prepare. On exit, re-dispatch a reconcile: a Focus marker that deferred to this
        // switch had its Darwin nudge consumed while we held the flag, so without this it would strand until a
        // later scene event (same hazard as the round-17 re-dispatch). By the time the Task runs the flag is
        // cleared and lastForegroundSwitch is stamped (on success), so the reconcile drops a now-stale marker
        // or applies one genuinely newer than this switch. Gated on stampsForegroundSwitch so the reconcile's
        // OWN replay switchToFilter(false) neither sets the flag nor re-dispatches (no loop).
        if stampsForegroundSwitch {
            isForegroundManualSwitchInFlight = true
        }
        defer {
            if stampsForegroundSwitch {
                isForegroundManualSwitchInFlight = false
                Task { @MainActor [weak self] in await self?.reconcilePendingFilterSwitch() }
            }
        }

        let nextConfiguration = plan.configuration

        // A programmatic Focus reconcile apply (`stampsForegroundSwitch == false`, the reconcile's
        // replay) must be SILENT — no full-screen preparation cover, no "Success" state, no haptic —
        // exactly like the committed-adopt path (`applyCommittedOnDiskActiveFilter`). Surfacing the
        // modal cover for every Focus-driven apply is what popped a "Success" page each time the app
        // was opened after a Focus switch (the automation is not a user action). Only a genuine
        // user-initiated switch drives the cover. The compile/commit/persist/tunnel-notify below run
        // identically either way; this gate governs the UI surface ONLY.
        let presentsPreparationCover = stampsForegroundSwitch

        // Snapshot the loaded state so ANY failure restores the previously-loaded filter
        // exactly — a cold-compile failure (before commit) or a mid-publish error (after).
        let previousConfiguration = configuration
        let previousActiveID = library.activeFilterID
        var publicationStarted = false
        // Capture the INITIATION instant NOW — before the (possibly slow) async prepare below — so the
        // foreground-switch supersession stamp records when the USER STARTED this switch, not when it
        // finished. A cold compile can take seconds; stamping completion time would misclassify a Focus
        // request that fired DURING the prepare (genuinely newer than this switch's initiation) as
        // "older" and silently drop it. Stamped only at the commit point on success (Codex round-15).
        let switchInitiatedAt = Date()
        let diagnosticOrderingLockURL = LavaSecAppGroup.containerURL?.appendingPathComponent(
            LavaSecAppGroup.focusDiagnosticOrderingLockFilename)
        let captureDiagnosticFailureEvent: @Sendable () -> FocusSwitchDiagnosticEvent? = {
            guard let lockURL = diagnosticOrderingLockURL else { return nil }
            return FocusSwitchDiagnostics.captureEvent(
                in: LavaSecAppGroup.sharedDefaults, orderingLockURL: lockURL)
        }
        // Capture the diagnostic clear generation at the same attempt boundary. The catch resumes on
        // MainActor after async preparation/rollback; using the catch-time generation would let a
        // pre-clear failure be written as a post-clear record after the clear has completed.
        let diagnosticEvent = diagnosticOrderingLockURL.flatMap { lockURL in
            FocusSwitchDiagnostics.captureEvent(
                in: LavaSecAppGroup.sharedDefaults,
                orderingLockURL: lockURL,
                now: { switchInitiatedAt })
        }
        // Remember the target so the shared failure screen's "Try Again" retries THIS
        // switch (there is no edit draft in the switch path).
        pendingSwitchFilterID = id
        // A fresh attempt is retryable unless it dead-ends on a deleted/frozen target below.
        filterPreparationFailureIsRetryable = true
        // Claim the configuration-replacement token. A later switch/restore/import supersedes
        // it, so this attempt bails at its commit/rollback gate instead of clobbering the
        // newer owner (the silent switch-vs-restore revert as well as overlapping switches).
        // A user switch drives the preparation cover, so a superseded switch knows to dismiss it
        // when the new owner is a non-cover-driver (restore/import). A silent Focus apply owns no
        // cover, so it claims the gate as a non-cover-driver.
        let switchToken = configurationReplacementGate.begin(ownsPreparationCover: presentsPreparationCover)
        // A switch is a Filters-tab action, so the Filters cover (not Domain History) owns it.
        filterPreparationOrigin = .filters
        if presentsPreparationCover {
            isFilterPreparationScreenPresented = true
        }

        do {
            // A silent Focus apply presents no cover, so the presenter skips its phase-visibility
            // holds — the automation commits/publishes without UI-only delay (Codex #44 P2).
            let progressPresenter = FilterPreparationProgressPresenter(presentsCover: presentsPreparationCover)
            // Instant switch-back: reuse the target's still-warm compiled artifacts (a pointer flip)
            // when its lastCompiledToken is valid for the current config + a FRESH cached catalog, else
            // cold-compile. Both yield a PreparedFilterSnapshot the shared tail below commits + publishes
            // identically. A switch to a filter whose proactive warm is still in flight (token not yet
            // stamped) simply cold-compiles — a rare, self-healing redundant compile, not wrong rules;
            // cross-task coalescing was removed to keep this path small (see the LAV-100 plan).
            var publication = try await prepareSwitchPublication(
                target: target,
                configuration: nextConfiguration,
                progressPresenter: progressPresenter,
                presentsPreparationCover: presentsPreparationCover,
                diagnosticFailureEvent: captureDiagnosticFailureEvent
            )

            await progressPresenter.present(
                FilterPreparationProgressUpdate(progress: 0.86, phase: .saving)
            ) { state in
                // Only churn the preparation UI state when a cover is actually showing — a silent
                // Focus apply must not flip filterPreparationState (nothing renders it, and callers
                // like endViewingFilterDetail/guardFiltersHaveIssue observe it).
                if presentsPreparationCover {
                    self.filterPreparationState = state
                }
            }
            await progressPresenter.holdCurrentPhaseIfNeeded()

            // A catalog sync that ran while we prepared (the reuse load + the holds above suspend the
            // main actor) would race a warm flip: the sync recompiles + republishes the active filter's
            // artifacts on the refreshed catalog and advances latest.json, so a warm flip to the
            // pre-refresh artifact would leave latest.json ahead of the pointer (the fail-closed
            // stale-source-hash wedge), and applyReusablePreparedSnapshot would roll currentCatalog
            // back to the stale one. Bail warm→cold on EITHER signal:
            //   • liveness — a sync is in flight RIGHT NOW (started during prepare, about to republish);
            //   • content  — the live catalog no longer matches the one the warm snapshot was validated
            //     against, i.e. a sync STARTED AND FINISHED entirely between the entry gate and here, so
            //     the controller is already idle yet the catalog moved (Codex #133 — liveness alone
            //     can't see a completed sync). The content check is by per-source identity, not the
            //     top-level catalog_version string, so a source rotation (hagezi ~4x/day, catalog hash
            //     pinned) that keeps catalog_version constant is still caught.
            // The cold fallback compiles fresh against the now-current catalog. After this gate passes
            // the catalog is BOTH quiescent and content-matched, so persistSharedState's sub-millisecond
            // pointer flip cannot be out-raced by a freshly triggered (seconds-long) sync — no
            // post-persist drift reconciliation is needed.
            if case .warm(let reusable) = publication {
                let catalogMovedSinceValidation = currentCatalog.map {
                    !reusable.preparedSnapshot.identity.snapshotInputMismatches(
                        against: PreparedFilterSnapshotIdentity.make(configuration: nextConfiguration, catalog: $0)
                    ).isEmpty
                } ?? false
                if catalog.isSyncInFlight || catalogMovedSinceValidation {
                    publication = .compiled(try await prepareFilterSnapshot(
                        for: nextConfiguration,
                        diagnosticFailureEvent: captureDiagnosticFailureEvent))
                }
            }

            // A newer replacement superseded this one while it was preparing. Don't touch
            // config/library (the newer owner has them); dismiss the preparation cover this switch
            // put up ONLY if the newer owner is a non-cover-driver (restore/import) that won't.
            guard configurationReplacementGate.isCurrent(switchToken) else {
                dismissPreparationCoverIfStrandedBySupersession()
                return
            }

            // Commit the switch only after a successful prepare/reuse.
            // `nextConfiguration` is an entry-time snapshot, so merge only the filter plan onto
            // the live configuration before the durable persist. This preserves every device-global
            // setting changed while preparation was suspended (Codex, PR #625).
            //
            // Some device-global settings are also inputs to the prepared snapshot (the resolver,
            // QA probes, and the tier budget). Those setters intentionally do not supersede a filter
            // switch, so they can change during the preparation await. Keep the merged target local
            // while rebuilding: assigning it to `configuration` before the await would let a
            // concurrent settings persist copy the target plan onto the old active filter. Refresh
            // the local target after every rebuild await, then install it only at the commit point.
            var switchConfiguration = applyingFilterPlan(from: nextConfiguration, onto: configuration)
            while true {
                if case .compiled(let prepared) = publication {
                    // A compile may accept newer custom-list contents than the entry snapshot
                    // recorded. Carry those hashes into the local filter plan before rechecking;
                    // otherwise the same successful compile would be rejected and repeated forever.
                    switchConfiguration = FilterSnapshotPreparationService.configuration(
                        switchConfiguration,
                        applyingCustomBlocklistHashes: prepared.customResult.sourceHashes
                    )
                }
                guard switchPublicationMatchesLiveConfiguration(publication, configuration: switchConfiguration) else {
                    publication = .compiled(try await prepareFilterSnapshot(
                        for: switchConfiguration,
                        reportProgress: { update in
                            await progressPresenter.present(update) { state in
                                if presentsPreparationCover {
                                    self.filterPreparationState = state
                                }
                            }
                        },
                        diagnosticFailureEvent: captureDiagnosticFailureEvent))
                    switchConfiguration = applyingFilterPlan(from: nextConfiguration, onto: configuration)
                    continue
                }
                break
            }
            // Rebuilding against live settings is another suspension, so a newer replacement may
            // have taken ownership while it ran. Do not commit this switch over that newer owner.
            guard configurationReplacementGate.isCurrent(switchToken) else {
                dismissPreparationCoverIfStrandedBySupersession()
                return
            }
            // The target may have been deleted, or Plus may have lapsed (freezing it),
            // while the async rebuild ran — re-validate after the final preparation await so a
            // lapsed account can't activate a now-frozen, read-only filter.
            guard let liveTarget = library.filter(id: id), !isFilterFrozen(id) else {
                // Surface the dead end instead of silently dropping the cover. Non-retryable
                // (retrying a gone/frozen target just re-fails), so the failure screen offers
                // only "Keep Current Filter". pendingSwitchFilterID stays set so "Back to Edit"
                // stays hidden; keepCurrentFiltersAfterPrepareFailure clears it. A silent Focus
                // apply shows no cover — it just returns; the reconcile's own gone/frozen guard
                // then drops the now-moot marker on its next pass.
                if presentsPreparationCover {
                    filterPreparationFailureIsRetryable = false
                    filterPreparationState = .failed(message: "That filter is no longer available.")
                    isFilterPreparationScreenPresented = true
                } else {
                    // No cover for a silent apply, so drop the retry target set at entry — otherwise a
                    // later UNRELATED preparation failure would retry this gone/frozen id and hide the
                    // failure screen's edit-return path (filterPreparationFailureOffersEditReturn).
                    pendingSwitchFilterID = nil
                }
                return
            }
            // A library-only edit deliberately does not advance the replacement gate: doing so
            // after its pair write could strand a switch that already committed its own pair but
            // still owes the cache/tunnel tail. Instead, close the pre-commit race precisely at the
            // target. If that target's four scoped fields changed during preparation, the artifact
            // and `nextConfiguration` describe the old rules — abort without persisting or rolling
            // back over the successful edit. A retry captures and prepares the new target. Changes
            // to another filter, and metadata/cache-only changes on this one, remain irrelevant.
            guard liveTarget.hasSameFilterScopedFields(as: target) else {
                if presentsPreparationCover {
                    filterPreparationFailureIsRetryable = true
                    filterPreparationState = .failed(
                        message: "That filter changed while it was being prepared. Try again."
                    )
                    isFilterPreparationScreenPresented = true
                } else {
                    // The durable Focus marker remains the retry authority. Clear only this silent
                    // attempt's UI retry target so an unrelated later failure cannot inherit it.
                    pendingSwitchFilterID = nil
                }
                return
            }
            // An automated foreground retry may have backgrounded during preparation. Keep
            // the prior working selection and durable marker; do not begin a publish there.
            if !stampsForegroundSwitch, UIApplication.shared.applicationState != .active {
                pendingSwitchFilterID = nil
                return
            }
            publicationStarted = true
            configuration = switchConfiguration
            library.setActiveFilter(id: id)
            // A compiled publish carries fresh per-source hashes; a warm reuse validated the existing
            // ones against the current catalog, so it leaves the app's hash tracking untouched.
            if case .compiled(let prepared) = publication {
                updateCustomBlocklistHashes(prepared.customResult.sourceHashes)
            }
            // The derived-cache apply below (applyCatalogSyncResult / applyReusablePreparedSnapshot)
            // mutates rule state — currentCatalog, cachedBlockRuleSets, threatGuardrail, blockRules —
            // that the failure rollback does NOT restore, so it runs only AFTER the throwing persist +
            // the ownership re-check: a failed/superseded switch never leaves those caches describing
            // the target. persistSharedState uses the explicit prepared snapshot, not these caches.
            //
            // For a WARM reuse the target's content-addressed token dir already exists, so the publish
            // is a pointer FLIP, not a recompile: persistSharedState records the (unchanged) compiled
            // token and persistArtifacts' staging step no-ops — it re-materializes the dir from the
            // in-memory snapshot only if it was GC'd between validation and the flip (fail-closed),
            // never serving stale rules (the reuse validation already matched the current catalog).
            let publishOutcome = try await persistSharedState(
                preparedSnapshot: publication.preparedSnapshot,
                diagnosticFailureEvent: captureDiagnosticFailureEvent)
            // persistSharedState's last step awaits the artifact-publish actor, a main-actor
            // suspension. A restore/import/switch/draft-apply that completed during it now owns the
            // live configuration+library. Re-check BEFORE the side-effect tail: applyCatalogSyncResult
            // rebuilds derived rule caches (cachedBlockRuleSets/threatGuardrail/blockRules) against
            // the LIVE configuration, so running it here would leave caches describing THIS switch
            // while config is the newer owner's — a later persist would then serialize wrong rules.
            // The newer owner drives the UI/tunnel; dismiss our cover only if it's a non-cover-driver.
            guard configurationReplacementGate.isCurrent(switchToken) else {
                dismissPreparationCoverIfStrandedBySupersession()
                return
            }
            // Now that the in-process supersession guard above has confirmed THIS switch still owns the gate,
            // an `.abortedSuperseded` here is the CROSS-PROCESS case: a concurrent Focus/App Intents commit won
            // the active-filter race, so the flip degrade-ABORTED and the live pointer + disk name the newer
            // Focus target. Treat it as a deferred, non-winning switch — dismiss OUR cover WITHOUT flashing
            // "Success" for a filter that didn't take, and let the re-dispatched reconcile (the defer above)
            // adopt the genuinely-newer on-disk selection. Marker recovery already preserved correctness (the
            // kept Focus marker's requestedAt necessarily postdates this switch's initiation, so reconcile
            // adopts the Focus target); this only removes the transient wrong-"Success" toast. The NON-current
            // (in-process superseded) case is handled by the gate guard above — NOT here — so this silent
            // dismiss can never clobber a newer in-process cover-driving switch's UI (Codex review, lavasec-ios#29).
            if case .abortedSuperseded = publishOutcome {
                filterEditTargetID = nil
                pendingSwitchFilterID = nil
                filterPreparationState = .idle
                isFilterPreparationScreenPresented = false
                return
            }
            // Stamp the foreground switch time so a pending Focus marker recorded BEFORE this switch was
            // INITIATED is dropped by reconcile rather than reverting the user's newer explicit choice.
            // Stamp the captured INITIATION instant (switchInitiatedAt), NOT Date() here: a slow cold compile
            // can take seconds, and stamping completion time would misclassify a Focus request that fired
            // DURING the prepare — genuinely newer than this switch's initiation — as stale and drop it
            // (Codex round-15). Stamp ONLY HERE — after persistSharedState SUCCEEDED and the post-persist
            // re-check confirms this switch still owns the gate — so a manual switch that threw or was
            // superseded never stamps a timestamp that would clear a still-valid pending Focus request as
            // stale (Codex round-11). ONLY for genuine USER switches: reconcile's replay passes
            // stampsForegroundSwitch: false so a programmatic Focus apply never poisons the supersession
            // timestamp nor suppresses a newer Focus request.
            if stampsForegroundSwitch {
                PendingFilterSwitchStore.recordForegroundSwitch(at: switchInitiatedAt, in: LavaSecAppGroup.sharedDefaults)
            }
            switch publication {
            case .compiled(let prepared):
                applyCatalogSyncResult(prepared.catalogResult)
            case .warm(let reusable):
                // Guard the apply against a catalog sync that moved the live catalog while
                // persistSharedState was suspended on the publish lock/artifact actor. If it moved,
                // applyReusablePreparedSnapshot below would roll currentCatalog + blockRules BACK to the
                // warm snapshot's validation-time catalog, and the background rehydration's catalog
                // re-check (results.catalog == currentCatalog) would then never match — wedging the gate
                // and leaving later publishes built against the stale catalog (Codex #133). When the
                // catalog moved, that sync already applied fresh, correct state for the now-committed
                // target filter (it rebuilds against the live config) and published its own artifacts,
                // so KEEP it: skip the stale reuse apply and the rehydration (caches are already fresh).
                // This needs a sync to fetch + compile within persistSharedState's sub-millisecond flip,
                // which the pre-commit gate's liveness+content checks make unreachable in practice — but
                // the guard keeps the post-persist apply robust WITHOUT re-introducing an inline recompile.
                let catalogMovedDuringPersist = currentCatalog.map {
                    !reusable.preparedSnapshot.identity.snapshotInputMismatches(
                        against: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: $0)
                    ).isEmpty
                } ?? false
                if !catalogMovedDuringPersist {
                    // The reused snapshot already carries the target's compiled rules + the catalog it
                    // was validated against; apply them the same way the warm-startup path does.
                    applyReusablePreparedSnapshot(reusable)
                    // A warm reuse left the per-source rule-set caches (cachedBlockRuleSets) describing
                    // the PREVIOUS filter — it reused the published artifact, not the per-source sets,
                    // whereas a COLD switch leaves them fresh from its catalog sync. Mark the caches
                    // pending so in-place blocklist edits are deferred (they'd otherwise rebuild
                    // blockRules from the wrong filter's caches and publish them — Codex #133), then
                    // rehydrate in the background (the switch itself stays instant; no artifact
                    // re-publish — the pointer already names the correct directory). applyCatalogSyncResult
                    // clears the flag once the rehydration (or any fresh-cache load) lands.
                    hasPendingWarmSwitchCacheRehydration = true
                    let rehydrationToken = switchToken
                    let rehydrationFilterID = id
                    Task { [weak self] in
                        await self?.rehydrateRuleSetCachesAfterWarmSwitch(
                            switchToken: rehydrationToken,
                            filterID: rehydrationFilterID
                        )
                    }
                }
            }
            appendAppNetworkActivity(.changeFilters)

            // Publication made `id` the active filter. Clear the stale non-active routing context
            // before either notification/restore await lets the detail page issue another save;
            // otherwise it can report a library-only success for the live filter and this switch's
            // later configuration sync can overwrite that edit.
            filterEditTargetID = nil
            pendingSwitchFilterID = nil

            await notifyTunnelSnapshotUpdated()
            await restoreProtectionIfNeeded(restoreRequest)

            // A silent Focus apply skips the "Success" cover + haptic entirely — the reconcile
            // adopts the switch invisibly, mirroring applyCommittedOnDiskActiveFilter. Only a genuine
            // user switch flashes the success confirmation.
            if presentsPreparationCover {
                // notify/restore above are suspensions since the last ownership check: recheck BEFORE
                // writing the saving-top frame so a superseded switch/apply can't paint a stale 3/4
                // frame over (or hold up) the newer preparation's cover. (Codex #284 P2)
                guard configurationReplacementGate.isCurrent(switchToken) else {
                    dismissPreparationCoverIfStrandedBySupersession()
                    return
                }
                // Saving is done: land the bar on the top of the saving quarter (3/4) so the terminal
                // Success step is a clean final quarter rather than a jump, then sweep to full.
                await progressPresenter.present(
                    FilterPreparationProgressUpdate(progress: 1.0, phase: .saving)
                ) { state in
                    self.filterPreparationState = state
                }
                // Yield so the 3/4 saving-top frame actually renders + eases before Success —
                // otherwise SwiftUI coalesces it away in the same main-actor turn and the bar sweeps
                // straight to 100% (see the matching note in prepareAndApplyFilterDraft). (Codex #284 P3)
                try? await Task.sleep(nanoseconds: 500_000_000)
                // Recheck ownership after the render yield: a newer switch/apply may have superseded us
                // during it, and a stale task must not write Success / fire the haptic / dismiss the
                // shared cover over the newer preparation's UI. (Codex #284 P2)
                guard configurationReplacementGate.isCurrent(switchToken) else {
                    dismissPreparationCoverIfStrandedBySupersession()
                    return
                }
                filterPreparationState = .preparing(progress: 1, message: "Success")
                ProtectionHapticFeedback.play(.actionSucceeded)

                // Hold long enough for the bar to sweep to a full 100% (~0.55s) and then show the
                // checkmark for a beat (the cover fills the bar, then cross-fades to the glyph).
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                // Same as the draft path: recheck ownership after the lengthened success hold so a
                // stale task never dismisses a newer preparation's cover. (Codex #284 P2)
                guard configurationReplacementGate.isCurrent(switchToken) else {
                    dismissPreparationCoverIfStrandedBySupersession()
                    return
                }
                filterPreparationState = .idle
                isFilterPreparationScreenPresented = false
            }
        } catch {
            // Only the current owner may roll back. A superseded attempt that failed must not
            // restore its previousActiveID over a newer switch/restore/import that committed; it
            // only dismisses its own cover if the new owner won't.
            guard configurationReplacementGate.isCurrent(switchToken) else {
                dismissPreparationCoverIfStrandedBySupersession()
                return
            }
            // Before publication, a failed preparation has changed no shared selection. An
            // inactive automated attempt leaves the headless writer and retry marker alone.
            // After publication starts, even an inactive attempt still owes a fenced rollback
            // and local restoration; otherwise reconcile could mistake the target for success.
            if !publicationStarted, !stampsForegroundSwitch, UIApplication.shared.applicationState != .active {
                pendingSwitchFilterID = nil
                return
            }
            let diagnosticFailure = error as? FocusSwitchDiagnosticFailure
            let failureError = diagnosticFailure?.underlying ?? error
            let failureEvent = diagnosticFailure?.event ?? diagnosticEvent
            let keepsLocalRecords = configuration.keepNetworkActivity
            if publicationStarted {
                // Capture the generation before restoring the plan. This is our successful pair
                // write (or its loaded base when writing failed), including any same-process
                // settings update. A newer cross-process writer wins under the shared CAS lock.
                let rollbackGeneration = configuration.configurationGeneration
                configuration = applyingFilterPlan(from: previousConfiguration, onto: configuration)
                library.setActiveFilter(id: previousActiveID)
                try? persistConfigurationOnly(rejectsAdvancedBeyond: rollbackGeneration)
            }
            // 🔴 RECORD THE FAILURE WHERE RELEASE CAN SEE IT, before the silent path below swallows
            // it. This catch discarded `error` entirely: the only trace a failed Focus apply left
            // was `reconcile-apply-failed-kept-marker`, and `logFocusSwitchEvent` is
            // `#if DEBUG || LAVA_QA_TOOLS` — so on a shipping build the user's automation simply
            // never happens, with nothing anywhere to say why. Device 2026-08-29: 44 attempts over
            // six builds and five days, zero successes, and the error unknown because nothing kept
            // it.
            //
            // Inactive, pre-publication deferrals above preserve the pending request and leave
            // this diagnostic slot untouched. This records the failure-handling paths below.
            // Scoped to the SILENT path. A user-initiated switch already surfaces
            // `filterPreparationState = .failed` below and does not need the slot; writing there
            // too would let ordinary foreground failures evict the automation record the bug
            // report reads. `presentsPreparationCover` is exactly "was this user-initiated".
            if !presentsPreparationCover, let failureEvent {
                Self.withFocusDiagnosticsConsent { consented in
                    FocusSwitchDiagnostics.recordForegroundReconcileFailure(
                        targetFilterID: id,
                        reason: Self.focusReconcileFailureReason(for: failureError),
                        at: failureEvent.at,
                        clearGeneration: failureEvent.clearGeneration,
                        keepingLocalRecords: consented,
                        in: LavaSecAppGroup.sharedDefaults)
                }
            }
            // A silent Focus apply surfaces no failure cover. The fenced rollback restores our pair
            // or preserves a newer writer, and restoring local selection keeps the marker retryable, so
            // the switch self-heals on a later foreground / Focus re-fire without a modal interrupting the
            // user for an automation they didn't trigger.
            if presentsPreparationCover {
                filterPreparationState = .failed(
                    message: Self.filterPreparationFailureMessage(for: failureError)
                )
                isFilterPreparationScreenPresented = true
                ProtectionHapticFeedback.play(.actionFailed)
            } else {
                // No failure cover for a silent apply, so drop the retry target it would have driven.
                pendingSwitchFilterID = nil
            }
        }
    }

    private func switchPublicationMatchesLiveConfiguration(
        _ publication: SwitchPublication,
        configuration: AppConfiguration
    ) -> Bool {
        let preparedSnapshot: PreparedFilterSnapshot
        switch publication {
        case .compiled(let prepared):
            preparedSnapshot = prepared.snapshot
        case .warm(let reusable):
            preparedSnapshot = reusable.preparedSnapshot
        }

        return preparedSnapshot.identity.hasSameConfiguration(as: configuration)
            && preparedSnapshot.snapshot.resolver == configuration.resolverPreset
            && FilterRuleBudget.fitsTierBudget(
                recordedTotal: preparedSnapshot.summary.tierBudgetRuleCount,
                maxFilterRules: configuration.limits.maxFilterRules
            )
    }

    /// A filter switch owns exactly four `AppConfiguration` fields: the filter plan
    /// (`enabledBlocklistIDs`, `customBlocklists`, `blockedDomains`, `allowedDomains`). All other
    /// fields are device-global and must come from the live configuration at commit/rollback time:
    /// protection (`protectionEnabled`); primary resolver selection (`resolverPresetID`,
    /// `customResolverAddress`, `customResolverSecondaryAddress`, `customResolverName`); fallback
    /// resolver settings (`fallbackToDeviceDNS`, `usesEncryptedDeviceDNSFallback`,
    /// `fallbackResolverPresetID`, `fallbackCustomResolverAddress`,
    /// `fallbackCustomResolverSecondaryAddress`, `fallbackCustomResolverName`); privacy toggles
    /// (`keepFilteringCounts`, `keepDomainDiagnostics`, `keepNetworkActivity`,
    /// `keepLavaGuardProgress`); account/diagnostic state (`isPaid`, `qaProbeSet`,
    /// `lavaGuardUnlocks`, `configurationGeneration`); and chained-upstream settings
    /// (`chainedUpstreamEnabled`, `chainedTierOneFallbackEnabled`).
    ///
    /// Preparation can suspend for seconds, so `plannedConfiguration` is intentionally only the
    /// source of filter-plan fields. The destination must be the current `configuration`, not an
    /// entry-time snapshot, or the following persist would durably resurrect stale device-global
    /// values. Keep this inventory and the four assignments aligned with `AppConfiguration`.
    /// pinned: MultiFilterFoundationSourceTests.testFilterSwitchConfigurationOwnershipIsExplicitAndComplete
    private func applyingFilterPlan(
        from plannedConfiguration: AppConfiguration,
        onto liveConfiguration: AppConfiguration
    ) -> AppConfiguration {
        var mergedConfiguration = liveConfiguration
        mergedConfiguration.enabledBlocklistIDs = plannedConfiguration.enabledBlocklistIDs
        mergedConfiguration.customBlocklists = plannedConfiguration.customBlocklists
        mergedConfiguration.blockedDomains = plannedConfiguration.blockedDomains
        mergedConfiguration.allowedDomains = plannedConfiguration.allowedDomains
        return mergedConfiguration
    }

    /// How a filter switch obtains the snapshot it publishes: a warm REUSE of the target's
    /// still-on-disk compiled artifacts (an instant pointer flip), or a cold COMPILE.
    enum SwitchPublication {
        case warm(ReusablePreparedFilterSnapshot)
        case compiled(FilterSnapshotPreparationResult)

        var preparedSnapshot: PreparedFilterSnapshot {
            switch self {
            case .warm(let reusable): return reusable.preparedSnapshot
            case .compiled(let result): return result.snapshot
            }
        }
    }

    /// Prepare the snapshot a switch will publish. Tries a warm-artifact reuse first — when the
    /// target filter's `lastCompiledToken` directory is still on disk AND valid for the target's
    /// CURRENT configuration + catalog — and only cold-compiles on a miss. The reuse validation is
    /// identical to the warm-startup path (manifest `reuseRejectionReason` + the decoded snapshot's
    /// `canReuseForProtectionStartup`), so a catalog/resolver/selection change since that compile
    /// fails the check and falls back to a recompile: a reuse can never serve rules that don't match
    /// the target's current inputs.
    ///
    /// Warm reuse is also skipped entirely while a catalog sync is in flight: that sync is about to
    /// recompile + republish on a refreshed catalog, so a warm flip would race it. Bailing to a cold
    /// compile (which coalesces with / follows the sync) keeps the warm fast path quiescent-only —
    /// instant in the common case, never racing a refresh.
    private func prepareSwitchPublication(
        target: Filter,
        configuration: AppConfiguration,
        progressPresenter: FilterPreparationProgressPresenter,
        // False for a silent Focus reconcile apply: the cold-compile progress must not churn
        // filterPreparationState (nothing renders it, and it would spuriously read as in-progress
        // to endViewingFilterDetail / the Guard issue indicator). See switchToFilter.
        presentsPreparationCover: Bool,
        diagnosticFailureEvent: (@Sendable () -> FocusSwitchDiagnosticEvent?)? = nil
    ) async throws -> SwitchPublication {
        // Reuse the target's warm artifact when one exists (shared with the headless warm switch via
        // warmReusableSnapshotForSwitch — same candidate set + validation). Skipped entirely while a
        // catalog sync is in flight: that sync is about to recompile + republish, so a warm flip would
        // race it; bailing to the cold compile keeps the warm fast path quiescent-only.
        if !catalog.isSyncInFlight,
           let reusable = await warmReusableSnapshotForSwitch(target: target, configuration: configuration) {
            return .warm(reusable)
        }

        let prepared = try await prepareFilterSnapshot(
            for: configuration,
            reportProgress: { update in
                await progressPresenter.present(update) { state in
                    if presentsPreparationCover {
                        self.filterPreparationState = state
                    }
                }
            },
            diagnosticFailureEvent: diagnosticFailureEvent
        )
        return .compiled(prepared)
    }

    /// Resolve a reusable warm snapshot for switching to `target`, trying BOTH candidate tokens — the
    /// library's own `lastCompiledToken` (foreground-warmed) AND a token the BACKGROUND staged into the
    /// sidecar warm-index (Phase 2). A non-nil library token can be STALE (a catalog refresh re-warmed
    /// the filter into the sidecar before the foreground promoted it), so trying only the library token
    /// would cold-compile and never use the fresh sidecar one (Codex #138). Each candidate is validated
    /// identically (manifest per-source hashes + a FRESH cached catalog) by the per-token loader below,
    /// so an invalid candidate falls through to the next / to nil (the caller cold-compiles or defers).
    /// Shared by the foreground switch (`prepareSwitchPublication`) and the headless warm switch.
    func warmReusableSnapshotForSwitch(
        target: Filter,
        configuration: AppConfiguration
    ) async -> ReusablePreparedFilterSnapshot? {
        var candidateTokens: [String] = []
        if let libraryToken = target.lastCompiledToken { candidateTokens.append(libraryToken) }
        if let sidecarToken = loadBackgroundWarmIndex().token(forFilterID: target.id),
           sidecarToken != target.lastCompiledToken {
            candidateTokens.append(sidecarToken)
        }
        for token in candidateTokens {
            if let reusable = await loadReusableWarmSnapshotForSwitch(token: token, configuration: configuration) {
                return reusable
            }
        }
        return nil
    }

    /// Load + validate the prepared snapshot in a SPECIFIC warm token directory (the target filter's
    /// `lastCompiledToken`) for an instant switch. `nil` ⇒ the directory is missing/undecodable, or
    /// the artifact no longer matches `configuration` + the cached catalog (coverage, source hashes,
    /// catalog version, resolver transport) — the caller then cold-compiles. Mirrors
    /// `loadReusablePreparedSnapshotForProtectionStartup`, but reads the token dir (not the live
    /// pointer) and additionally requires the decoded snapshot's content-addressed token to equal the
    /// directory name, so the subsequent `persistSharedState` flips the pointer to THIS validated dir.
    private func loadReusableWarmSnapshotForSwitch(
        token: String,
        configuration: AppConfiguration
    ) async -> ReusablePreparedFilterSnapshot? {
        // Load-bearing warm-reuse validation lives in LavaSecFilterPipeline (WarmFilterSnapshotLoader) so the
        // foreground switch and the headless Focus engine share ONE validation core and can't drift on
        // reuse safety (fresh-cache + manifest/coverage/source-hash + token-match + tier-cap + full
        // guardrail). This wrapper only supplies the App Group URLs the foreground already derives.
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return nil
        }
        return await WarmFilterSnapshotLoader.loadReusable(
            token: token,
            configuration: configuration,
            containerURL: containerURL,
            cacheURL: catalogCacheURL,
            freshnessMaxAge: catalogSyncFreshnessInterval
        )
    }

    /// Background rehydration of the per-source rule-set caches after an instant (warm) switch, so
    /// they describe the now-active filter instead of the previous one. A warm switch reuses the
    /// published artifact and never loads the per-source sets, leaving `cachedBlockRuleSets` stale;
    /// a cold switch leaves them fresh. Without this, an edit path that rebuilds block rules from
    /// those caches would use the wrong filter's sources. Cache-only (no network, no artifact
    /// re-publish) and superseded-checked, so it never clobbers a newer switch/restore/edit or moves
    /// the published pointer. (Codex #133 r4.)
    func rehydrateRuleSetCachesAfterWarmSwitch(switchToken: Int, filterID: String) async {
        guard let cacheURL = catalogCacheURL,
              configurationReplacementGate.isCurrent(switchToken),
              library.activeFilterID == filterID else {
            return
        }
        let enabledIDs = configuration.enabledBlocklistIDs
        let customSources = enabledCustomBlocklists(in: configuration)
        let loadTask = Task.detached(priority: .utility) {
            () -> (BlocklistCatalogSyncResult, CustomBlocklistSyncResult)? in
            let synchronizer = BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL)
            guard let catalogResult = try? await synchronizer.loadCached(enabledSourceIDs: enabledIDs),
                  let customResult = try? await synchronizer.loadCachedCustomBlocklists(customSources) else {
                return nil
            }
            return (catalogResult, customResult)
        }
        guard let results = await loadTask.value else {
            // The per-source caches couldn't be loaded to rehydrate (a rare disk error). The pending
            // flag is still set, so in-place edits stay deferred (fail-safe). Fall back to an
            // authoritative catalog sync — which reloads the caches, republishes, and clears the flag
            // via applyCatalogSyncResult — so the gate self-heals instead of blocking edits until the
            // next incidental sync. Only if this warm switch is still the live owner.
            if configurationReplacementGate.isCurrent(switchToken), library.activeFilterID == filterID {
                await syncCatalog()
            }
            return
        }
        // Re-check after the load that NOTHING the rule caches depend on moved while we loaded. The
        // caches are a function of: the wholesale-replacement epoch (switch/restore/import/draft),
        // the active filter, its selection (enabled IDs + custom sources incl. content hash), and the
        // catalog version. An in-place edit (toggleBlocklist / add/removeCustomBlocklist — Codex r5)
        // or a completed catalog refresh (syncCatalog — Codex r6) mutates these WITHOUT advancing the
        // replacement token, and the latter already wrote fresh caches + newer artifacts; applying our
        // stale `results` over them would rebuild later snapshots from the old catalog. If anything
        // moved, bail — that path owns the caches and drives its own rebuild. Together these conditions
        // are the COMPLETE set of inputs the rule caches derive from. The catalog check is by CONTENT
        // (the loaded result must equal the live currentCatalog, BlocklistCatalog is Equatable), not
        // the top-level catalog_version string, so a source-content rotation that left catalog_version
        // unchanged still defers to the sync that produced the live catalog rather than reverting it.
        guard configurationReplacementGate.isCurrent(switchToken),
              library.activeFilterID == filterID,
              configuration.enabledBlocklistIDs == enabledIDs,
              enabledCustomBlocklists(in: configuration) == customSources,
              results.0.catalog == currentCatalog else {
            return
        }
        applySyncResults(catalogResult: results.0, customResult: results.1)
    }

    func duplicateName(of name: String) -> String {
        "%@ copy".lavaLocalizedFormat(name)
    }
}
