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
    // MARK: - Filter draft preparation & apply

    func prepareAndApplyFilterDraft(origin: FilterReviewOrigin = .filters) async {
        // Record which surface is applying so the matching cover (and only it) presents the
        // preparation / failure UI — set at the apply point, not at staging, so it can't go stale.
        filterPreparationOrigin = origin
        // A draft apply is now the retry target (supersedes any earlier switch attempt), and every
        // fresh apply starts retryable — clearing any non-retryable state a prior dead-end switch
        // left, so a transient edit/Domain-History failure still offers "Try Again".
        pendingSwitchFilterID = nil
        filterPreparationFailureIsRetryable = true
        // Reads the draft through the `filterEditDraft` proxy (keyed by the controller’s current filter context). Every
        // caller reaches here with the detail context forced to the active filter
        // (`filterEditTargetID == nil`), so this is the active draft — the same entry the success
        // path clears via `activeFilterDraft`. See `activeFilterDraft` before changing that invariant.
        guard let filterEditDraft else {
            return
        }

        guard filterDraftHasChanges else {
            return
        }

        if let validationMessage = filterDraftValidationMessage {
            filterPreparationState = .failed(message: validationMessage)
            isFilterPreparationScreenPresented = true
            ProtectionHapticFeedback.play(.actionFailed)
            return
        }

        var nextConfiguration = configuration
        nextConfiguration.enabledBlocklistIDs = filterEditDraft.enabledBlocklistIDs
        nextConfiguration.customBlocklists = filterEditDraft.customBlocklists
        nextConfiguration.blockedDomains = filterEditDraft.blockedDomains
        nextConfiguration.allowedDomains = filterEditDraft.allowedDomains

        // Whether this foreground apply ADDED protection — the review filter-update anchor. Computed
        // against the OLD `configuration` before the commit below. `FilterConfigurationDiff` omits
        // custom blocklists, so a paid custom-list add correctly does NOT qualify. Only an ADDED
        // curated blocklist or ADDED blocked domain counts: an added ALLOWED domain is an EXCEPTION
        // that WEAKENS filtering — the very `addedAllowedDomains` that `FilterMyListView`'s
        // `weakensProtection` gates its "reduce your protection" confirmation on — so un-blocking a
        // site must NOT spend a scarce review slot on the opposite of the intended value moment.
        // Consumed at the success tail.
        // pinned: ReviewPromptWiringSourceTests.testFilterUpdateAnchorFiresOnlyWhenProtectionWasAdded
        let reviewFilterUpdateAddedProtection: Bool = {
            let diff = FilterConfigurationDiff(
                from: FilterConfigurationSelection(
                    enabledBlocklistIDs: configuration.enabledBlocklistIDs,
                    blockedDomains: configuration.blockedDomains,
                    allowedDomains: configuration.allowedDomains
                ),
                to: FilterConfigurationSelection(
                    enabledBlocklistIDs: nextConfiguration.enabledBlocklistIDs,
                    blockedDomains: nextConfiguration.blockedDomains,
                    allowedDomains: nextConfiguration.allowedDomains
                )
            )
            return !diff.addedBlocklistIDs.isEmpty
                || !diff.addedBlockedDomains.isEmpty
        }()

        let restoreRequest = makeProtectionRestoreRequest()
        // A draft apply is a wholesale config replacement too: claim the replacement token before the
        // first await so a switch/restore/import that completes mid-flight supersedes it (and vice
        // versa) instead of one silently reverting the other. Claimed AFTER the early-return guards so
        // a no-op apply can't needlessly bump the epoch and supersede a legitimate in-flight replacer.
        // A draft apply drives the preparation cover, like a switch.
        let draftToken = configurationReplacementGate.begin(ownsPreparationCover: true)
        isFilterPreparationScreenPresented = true

        do {
            let progressPresenter = FilterPreparationProgressPresenter()
            let prepared = try await prepareFilterSnapshot(for: nextConfiguration) { update in
                await progressPresenter.present(update) { state in
                    self.filterPreparationState = state
                }
            }

            await progressPresenter.present(
                FilterPreparationProgressUpdate(progress: 0.86, phase: .saving)
            ) { state in
                self.filterPreparationState = state
            }
            await progressPresenter.holdCurrentPhaseIfNeeded()

            // A newer replacement took ownership while we prepared — bail without committing;
            // dismiss our cover if the new owner is a non-cover-driver that won't.
            guard configurationReplacementGate.isCurrent(draftToken) else {
                dismissPreparationCoverIfStrandedBySupersession()
                return
            }
            configuration = nextConfiguration
            updateCustomBlocklistHashes(prepared.customResult.sourceHashes)
            try await persistSharedState(preparedSnapshot: prepared.snapshot)
            // Re-check after the persist's artifact-actor await before the derived-cache tail (see
            // switchToFilter): applyCatalogSyncResult is deferred past the persist + this gate so a
            // superseded apply never desyncs the rule caches against the newer owner's config.
            guard configurationReplacementGate.isCurrent(draftToken) else {
                dismissPreparationCoverIfStrandedBySupersession()
                return
            }
            applyCatalogSyncResult(prepared.catalogResult)
            appendAppNetworkActivity(.changeFilters)

            await notifyTunnelSnapshotUpdated()
            await restoreProtectionIfNeeded(restoreRequest)

            catalogStatusMessage = (protectedRuleCount == 1 ? "Prepared %@ rule for local protection." : "Prepared %@ rules for local protection.").lavaLocalizedFormat(protectedRuleCount.formatted())
            catalogStatusIsError = false
            self.activeFilterDraft = nil
            // notifyTunnelSnapshotUpdated / restoreProtectionIfNeeded above are suspensions since the
            // last ownership check, so recheck BEFORE writing the saving-top frame to the shared cover:
            // a superseded task must not paint a stale 3/4 "Saving" frame over the newer owner's cover
            // (nor keep a stale cover up through the following 500ms render yield). (Codex #284 P2)
            guard configurationReplacementGate.isCurrent(draftToken) else {
                dismissPreparationCoverIfStrandedBySupersession()
                return
            }
            // Saving is done (persist + tunnel reload committed above): land the bar on the top of the
            // saving quarter (3/4) so the terminal Success step is a clean final quarter rather than a
            // jump. Success then sweeps the bar 3/4 → full before the checkmark takes over.
            await progressPresenter.present(
                FilterPreparationProgressUpdate(progress: 1.0, phase: .saving)
            ) { state in
                self.filterPreparationState = state
            }
            // Yield so SwiftUI actually RENDERS (and eases to) the 3/4 saving-top frame. The
            // same-phase present() above returns without suspending, so without this sleep the
            // Success write below lands in the same main-actor turn and SwiftUI coalesces the 3/4
            // state away — the bar would sit at the previous saving value and sweep straight to 100%
            // instead of the intended 3/4 → full final quarter. (Codex #284 P3)
            try? await Task.sleep(nanoseconds: 500_000_000)
            // The render yield is another suspension since the recheck above, so recheck again before
            // the Success confirmation — otherwise a stale task would write Success, fire the haptic,
            // and later dismiss the shared cover, clobbering the newer preparation's UI. (Codex #284 P2)
            guard configurationReplacementGate.isCurrent(draftToken) else {
                dismissPreparationCoverIfStrandedBySupersession()
                return
            }
            filterPreparationState = .preparing(progress: 1, message: "Success")
            ProtectionHapticFeedback.play(.actionSucceeded)
            // A foreground draft apply that added protection is a review anchor. Fired only AFTER the
            // supersession recheck above confirmed THIS apply committed, so a superseded/no-op apply
            // never asks. pinned: ReviewPromptWiringSourceTests.testFilterUpdateAnchorFiresOnlyWhenProtectionWasAdded
            if reviewFilterUpdateAddedProtection {
                noteFilterUpdatedReviewMoment()
            }

            // Hold long enough for the bar to sweep to a full 100% (~0.55s) and then show the
            // checkmark for a beat. The cover view fills the bar, then cross-fades to the glyph.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            // The success hold is another suspension (one this change lengthened to 1.2s): if a newer
            // switch/apply superseded us during it, do NOT clear the state — that would dismiss the
            // newer preparation's cover. Bail via the shared helper instead. (Codex #284 P2)
            guard configurationReplacementGate.isCurrent(draftToken) else {
                dismissPreparationCoverIfStrandedBySupersession()
                return
            }
            filterPreparationState = .idle
            isFilterPreparationScreenPresented = false
        } catch {
            // A newer replacement took ownership while we prepared (it owns the shared cover now),
            // so a superseded apply must NOT stomp it with a spurious failure modal + haptic. Mirror
            // switchToFilter's catch: bail if no longer current (dismissing our cover if the new
            // owner won't). The apply mutates no config/library before the throw, nothing to roll back.
            guard configurationReplacementGate.isCurrent(draftToken) else {
                dismissPreparationCoverIfStrandedBySupersession()
                return
            }
            filterPreparationState = .failed(
                message: Self.filterPreparationFailureMessage(for: error)
            )
            isFilterPreparationScreenPresented = true
            ProtectionHapticFeedback.play(.actionFailed)
        }
    }

    /// Save the current draft to the NON-active filter being viewed. Library-only: writes the
    /// four filter fields into the target's library entry, invalidates its compiled token (so a
    /// later switch recompiles), and persists via the rollback-safe library-only path. No
    /// prepare, no tunnel reload, no replacement gate, and — unlike the active apply — NO
    /// full-screen preparation cover: the filter isn't loaded, so this can't touch live
    /// protection. On a validation or write failure it returns a message for the caller to show
    /// inline (so a non-active save never flips the global catalog-error/protection indicators);
    /// on success it clears the draft (the page drops to view mode) and returns nil. The target
    /// is preserved so the page keeps showing the just-saved filter.
    @discardableResult
    func saveNonActiveFilterDraft() -> String? {
        if let created = filterDrafts.sessions.newFilter, created.id == filterEditTargetID { return saveNewFilterDraft() }
        guard let targetID = filterEditTargetID,
              let draft = filterDrafts.sessions.drafts[targetID],
              library.filter(id: targetID) != nil else {
            return nil
        }
        // A switch can make this filter active while the detail page and its per-filter draft stay
        // mounted. Never route that now-live filter through the library-only save path: doing so
        // would skip snapshot publication and tunnel reload. Re-point the page at active context but
        // keep the target-keyed draft intact so the user can review and save it through the full path.
        guard targetID != library.activeFilterID else {
            filterEditTargetID = nil
            ProtectionHapticFeedback.play(.actionFailed)
            return "This filter is now active. Review your changes, then save again."
        }
        // The target may have become frozen since the draft was started (Plus lapsed while a draft
        // was preserved / mid-edit). A frozen filter is read-only, so report it instead of silently
        // no-op'ing — the detail page also drops the draft on appear, but this covers a lapse that
        // happens while the page stays mounted in edit mode.
        guard !isFilterFrozen(targetID) else {
            ProtectionHapticFeedback.play(.actionFailed)
            return "This filter is locked. Upgrade to Lava Plus to edit it."
        }
        if let validationMessage = filterDraftValidationMessage {
            ProtectionHapticFeedback.play(.actionFailed)
            return validationMessage
        }
        let previousLibrary = library
        library.mutateFilter(id: targetID) { filter in
            filter.enabledBlocklistIDs = draft.enabledBlocklistIDs
            filter.customBlocklists = draft.customBlocklists
            filter.blockedDomains = draft.blockedDomains
            filter.allowedDomains = draft.allowedDomains
            // Its on-disk compiled artifacts no longer match the rules — force a fresh compile
            // the next time this filter is switched to.
            filter.lastCompiledToken = nil
        }
        guard persistLibraryOnlyChange(
            rollingBackTo: previousLibrary,
            refusesIfOnDiskActiveFilterIs: targetID
        ) else {
            ProtectionHapticFeedback.play(.actionFailed)
            return "Couldn't save your changes. Please try again."
        }
        filterDrafts.setDraft(nil, for: targetID)
        ProtectionHapticFeedback.play(.actionSucceeded)
        // The edit invalidated this filter's compiled artifact (token cleared above); re-warm it
        // off the hot path so a later switch stays an instant pointer flip. Fire-and-forget — the
        // inline save remains library-only and warmFilterArtifact never republishes or reloads the
        // tunnel; if the user keeps editing, the post-compile staleness recheck drops any superseded
        // compile, and a switch arriving before the token is stamped just cold-compiles (self-healing).
        Task { await warmFilterArtifact(forFilterID: targetID) }
        return nil
    }
}
