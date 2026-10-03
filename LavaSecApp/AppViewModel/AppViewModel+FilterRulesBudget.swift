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
    // MARK: - Filter-rules budget

    /// Snapshot of how the staged selection sits against the tier budget, for
    /// the picker meter. `knownRuleCount` sums per-list rule counts (a
    /// conservative OVER-estimate of the deduped union — the authoritative count
    /// is enforced at compile time); `pendingLists` is the number of selected
    /// lists whose rule count is not yet known (custom not fetched, or catalog
    /// not synced) and must not be silently treated as zero.
    struct FilterRuleBudgetStatus {
        let knownRuleCount: Int
        let budget: Int
        let pendingLists: Int

        /// 0...1, capped, so the bar never renders past 100%.
        var fraction: Double {
            FilterRuleBudget.fraction(knownRuleCount: knownRuleCount, budget: budget)
        }

        /// At or over the displayed budget — drives the orange/error bar.
        var isAtOrOverBudget: Bool { knownRuleCount >= budget }

        /// Rule count to render in the "X of budget" copy. Clamped to the budget
        /// while the selection is still savable (within the soft-ceiling margin)
        /// so a savable selection never reads as "506K of 500K"; shows the true
        /// count once over the ceiling, when a save is no longer possible.
        var displayedRuleCount: Int {
            FilterRuleBudget.displayedRuleCount(knownRuleCount: knownRuleCount, budget: budget)
        }

        /// Nothing is counted yet but lists are still resolving (catalog not
        /// synced / custom not fetched). The meter cannot honestly claim
        /// headroom, so the UI shows a neutral "calculating" state rather than a
        /// confident empty-green bar.
        var isIndeterminate: Bool { pendingLists > 0 && knownRuleCount == 0 }
    }

    /// The subscription-tier filter-rule budget (Free 500K / Plus 2M). The hard
    /// device guardrail (`FilterSnapshotMemoryBudget.maxFilterRuleCount` ≈ 3.26M)
    /// sits above this and is enforced at compile time, never as a paywall.
    var filterRuleBudget: Int {
        configuration.limits.maxFilterRules
    }

    private var stagedEnabledBlocklistIDs: Set<String> {
        filterEditDraft?.enabledBlocklistIDs ?? filterDetailBaseline.enabledBlocklistIDs
    }

    /// Manual blocked + allowed domains are each compiled as a filter rule, so
    /// they consume the same budget as the blocklists and are counted together.
    private var stagedManualRuleCount: Int {
        let baseline = filterDetailBaseline
        let blocked = filterEditDraft?.blockedDomains ?? baseline.blockedDomains
        let allowed = filterEditDraft?.allowedDomains ?? baseline.allowedDomains
        return blocked.count + allowed.count
    }

    /// Selection-time estimate for a set of enabled lists: the sum of per-list
    /// rule counts (known), plus a count of lists whose size is not yet known.
    /// Over-counts the deduped union, so it is a conservative upper bound.
    func projectedFilterRuleCount(forEnabledIDs enabledIDs: Set<String>) -> (known: Int, pendingLists: Int) {
        var known = 0
        var pending = 0
        for id in enabledIDs {
            // entryCount 0 is the unresolved/built-in-fallback placeholder, not a
            // genuinely empty list — treat it as not-yet-known so it counts as
            // pending instead of a misleading known 0.
            if let entryCount = catalogSourcesByID[id]?.entryCount, entryCount > 0 {
                known += entryCount
            } else if let ruleCount = cachedBlockRuleSets[id]?.count {
                known += ruleCount
            } else {
                pending += 1
            }
        }
        return (known, pending)
    }

    func filterRuleBudgetStatus(forEnabledIDs enabledIDs: Set<String>) -> FilterRuleBudgetStatus {
        let projection = projectedFilterRuleCount(forEnabledIDs: enabledIDs)
        return FilterRuleBudgetStatus(
            knownRuleCount: projection.known + stagedManualRuleCount,
            budget: filterRuleBudget,
            pendingLists: projection.pendingLists
        )
    }

    /// Shared native and RN picker copy, including pending counts and tier actions.
    func filterRuleBudgetSelectionText(forEnabledIDs selectedIDs: Set<String>) -> String {
        let status = filterRuleBudgetStatus(forEnabledIDs: selectedIDs)
        let selectionStatusIsError = enabledIDsExceedSoftRuleBudget(selectedIDs)
        let isFreeOverLimit = !configuration.hasLavaSecurityPlus && selectionStatusIsError
        // Nothing counted yet but lists are still resolving — don't imply "0 of
        // budget" headroom we can't vouch for.
        if status.isIndeterminate {
            return (status.pendingLists == 1 ? "Calculating rule usage… (%@ list pending)" : "Calculating rule usage… (%@ lists pending)").lavaLocalizedFormat(status.pendingLists.formatted())
        }

        let used = AppViewModel.abbreviatedRuleCount(status.displayedRuleCount)
        let budget = AppViewModel.abbreviatedRuleCount(status.budget)
        var text: String
        if isFreeOverLimit {
            text = "About %1$@ of %2$@ rules · Upgrade or remove a list".lavaLocalizedFormat(used, budget)
        } else if selectionStatusIsError {
            text = "About %1$@ of %2$@ rules · Remove a list to continue".lavaLocalizedFormat(used, budget)
        } else {
            text = "About %1$@ of %2$@ rules".lavaLocalizedFormat(used, budget)
        }
        if status.pendingLists > 0 {
            text += " " + "(+%@ pending)".lavaLocalizedFormat(status.pendingLists.formatted())
        }
        return text
    }

    var stagedFilterRuleBudgetStatus: FilterRuleBudgetStatus {
        filterRuleBudgetStatus(forEnabledIDs: stagedEnabledBlocklistIDs)
    }

    /// True when the *known* rules for this selection already exceed the soft
    /// ceiling. Pending (unknown) lists are not counted here, by design (smoother
    /// flow over selection-time precision): whatever slips this estimate is caught
    /// exactly — on the deduped union — by the cold-prepare gate on the draft-apply
    /// path, by `toggleBlocklist`'s post-rebuild exact check on the cached in-place
    /// enable (which runs no cold prepare), and by the INV-TIER-1 publish/reuse/
    /// serve gates on the remaining compile-free paths (onboarding writes, refresh
    /// republish, restore).
    func enabledIDsExceedSoftRuleBudget(_ enabledIDs: Set<String>) -> Bool {
        let known = projectedFilterRuleCount(forEnabledIDs: enabledIDs).known + stagedManualRuleCount
        return FilterRuleBudget.exceedsSoftCeiling(knownRuleCount: known, budget: filterRuleBudget)
    }

    /// Tier-appropriate over-budget copy (free offers an upgrade; paid does not).
    func filterRuleBudgetMessage() -> String {
        let budgetText = AppViewModel.abbreviatedRuleCount(filterRuleBudget)
        if configuration.hasLavaSecurityPlus {
            return "Lava Plus includes up to %@ filter rules. Remove a list to add more.".lavaLocalizedFormat(budgetText)
        }
        return "Free protection includes up to %@ filter rules. Remove a list or upgrade to Plus.".lavaLocalizedFormat(budgetText)
    }

    /// INV-TIER-1 status reconcile for the two paths that change the budget or the
    /// selection WITHOUT a compile anywhere on them — a plan change (lapse/upgrade)
    /// and a backup restore. When the live compiled total no longer fits the (new)
    /// budget, report the existing tier message on the existing catalog status
    /// surface so the user learns why before a publish/serve gate bites; the gates
    /// themselves are the enforcement, this is only the explanation. Within budget
    /// ⇒ clear a stale tier message this hub previously surfaced (a Free→Plus
    /// upgrade runs no refresh that would otherwise replace it, so the resolved
    /// error would persist indefinitely); any OTHER status stays untouched.
    func reconcileTierBudgetStatusAfterPlanOrRestoreChange() {
        guard !FilterRuleBudget.fitsTierBudget(
            compiledTotal: liveCompiledTierBudgetRuleCount,
            maxFilterRules: configuration.limits.maxFilterRules
        ) else {
            if let surfaced = lastSurfacedTierBudgetMessage, catalogStatusMessage == surfaced {
                catalogStatusMessage = "Filter will update from Lava Security's source catalog."
                catalogStatusIsError = false
            }
            lastSurfacedTierBudgetMessage = nil
            return
        }

        surfaceTierBudgetStatusMessage()

        // DEBUG-only (not the usual internal-QA pairing): the repo-checks guard rejects any
        // PR line that adds the internal build-flag token to tracked source, and counts-only
        // telemetry isn't worth a guard exception — QA builds still see the status message.
        #if DEBUG
        logVPNDebugEvent("tier-budget-over-after-plan-or-restore", details: [
            "compiledTotal": "\(liveCompiledTierBudgetRuleCount)",
            "maxFilterRules": "\(configuration.limits.maxFilterRules)"
        ])
        #endif
    }

    /// Re-attempt the launch reconcile after the tunnel has had time to settle.
    ///
    /// 🔴 THE RACE THIS EXISTS FOR. The repair needs the tunnel's bootstrap broker, and the
    /// broker is admitted only once the tunnel has COMMITTED fail-closed. On a cold launch the
    /// app's reconcile runs ~11s BEFORE that commit (measured on device, S9), so the first
    /// attempt asks a tunnel that is not yet in the state that would let it help, is refused
    /// `not-fail-closed`, and — because the reconcile runs once per process — never asks again.
    /// The broker was reachable and correct and still never fired.
    func scheduleFailClosedReconcileRetryIfNeeded() {
        guard !isFailClosedReconcileRetryScheduled else { return }
        guard
            FailClosedReconcileRetryPolicy.shouldScheduleRetry(
                attempt: failClosedReconcileRetryAttempt,
                protectionIsEnabled: isProtectionEnabledStatus(vpnStatus)
                    || isAwaitingOnDemandReconnect),
            let delay = FailClosedReconcileRetryPolicy.delaySeconds(
                forAttempt: failClosedReconcileRetryAttempt)
        else {
            return
        }

        let attempt = failClosedReconcileRetryAttempt
        failClosedReconcileRetryAttempt += 1
        isFailClosedReconcileRetryScheduled = true
        logVPNDebugEvent("fail-closed-reconcile-retry-scheduled", details: [
            "attempt": "\(attempt)",
            "delaySeconds": "\(Int(delay))",
        ])

        let epoch = failClosedReconcileRetryEpoch
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            guard epoch == self.failClosedReconcileRetryEpoch else {
                // A reconcile succeeded through another path while this rung slept.
                // Deliberately touches NO shared state on the way out — in particular not
                // `isFailClosedReconcileRetryScheduled`, which a newer ladder may already
                // own. Retiring the ladder is the clearer's job, not the sleeper's.
                self.logVPNDebugEvent(
                    "fail-closed-reconcile-retry-superseded", details: ["attempt": "\(attempt)"])
                return
            }
            self.isFailClosedReconcileRetryScheduled = false
            self.logVPNDebugEvent("fail-closed-reconcile-retry", details: ["attempt": "\(attempt)"])
            // Straight back through the same entry point: it re-checks protection state, and
            // its own catch re-arms the next rung. A success clears the ladder below.
            await self.reconcileTunnelSnapshotAfterLaunch()
        }
    }

    /// Called on a reconcile that actually published. Ends the ladder so a LATER outage starts
    /// from the first rung rather than from an exhausted counter.
    func clearFailClosedReconcileRetryLadder() {
        failClosedReconcileRetryAttempt = 0
        // Invalidate any rung already sleeping, and release the guard so a LATER outage can
        // arm a fresh ladder. Without the bump the sleeper wakes into a recovered device;
        // without the flag reset the next outage could never schedule at all.
        failClosedReconcileRetryEpoch += 1
        isFailClosedReconcileRetryScheduled = false
    }

    /// 🔴 COPY IS A PLACEHOLDER, deliberately, and needs owner-approved wording.
    /// The right message names the state and the way out — filtering is unavailable, the
    /// device is blocking everything to stay safe, and turning protection off and on retries.
    /// Writing that meant inventing a user-facing string and ten translations, which is not
    /// this diff's call; the localization gate requires every locale translated, so a new key
    /// cannot land half-done. This reuses the nearest ALREADY-APPROVED and already-translated
    /// string so the failure stops being silent today, and the wording improves in a copy pass.
    func surfaceSnapshotReconcileFailureStatusMessage() {
        catalogStatusMessage = "We couldn't update your filter".lavaLocalized
        catalogStatusIsError = true
    }

    func surfaceTierBudgetStatusMessage() {
        let message = filterRuleBudgetMessage()
        catalogStatusMessage = message
        catalogStatusIsError = true
        lastSurfacedTierBudgetMessage = message
    }

    /// INV-CHAIN-2 convergence: clear a stored chaining preference this device or account can
    /// no longer honour.
    ///
    /// Mutates `configuration` only — the CALLER persists, so this can be folded into an
    /// existing write rather than adding one. It is a no-op whenever the flag is already off.
    ///
    /// THAT USED TO MEAN "ALWAYS", AND NO LONGER DOES. Before the QA staging surface, nothing
    /// wrote `chainedUpstreamEnabled` and the encrypted backup payload deliberately omits it,
    /// so no build could reach this with the flag on. `stageChainedUpstreamForQA` is now the
    /// first producer, so on a DEBUG or QA build — precisely the builds the S9 battery runs
    /// on — this reconcile is live for the first time: a Plus lapse or an ineligible device
    /// takes the `.disable` outcome and clears the flag a staging call just set. The Release
    /// build's story is unchanged, because the staging surface is not in it.
    ///
    /// Anything reasoning "the reconcile cannot fire pre-Phase-4" is therefore reasoning from
    /// a premise this diff removed — including `stageChainedUpstreamForQA`, which re-reads the
    /// flag after its awaits for exactly this reason (Codex, PR #519).
    ///
    /// Deliberately string-free. The Phase-4/5 localization pass owns the user-facing
    /// explanation; emitting English copy here would either ship untranslated text or fail
    /// the localization gate, and the reconcile has to work before that copy exists.
    ///
    /// Scope: this covers the entitlement axis, which is the one that changes at runtime.
    /// Memory does not change, so the only way to become memory-ineligible is to carry the
    /// app-group configuration onto different hardware; that converges at the next
    /// entitlement event rather than at launch. Reconciling from `loadPersistedConfiguration`
    /// instead would mean persisting from inside the launch read, whose `.unreadable` branch
    /// must never write over the real file (`INV-PERSIST-1`) — that belongs with Phase 4,
    /// where the toggle and the device-local override store make the flow real. Until then
    /// the tunnel latch is what keeps an ineligible device safe, and it needs no help.
    func reconcileChainedUpstreamAfterEligibilityChange(reason: String) {
        // `false` for both, DELIBERATELY, even though the device-local stores exist now
        // (the tunnel reads them at its latch; QA's Reset writes them). Neither may feed
        // this reconcile: exclusion and surrender suspend the FEATURE until the user's
        // Reset and must never clear the user's PREFERENCE — and a Keychain read can be
        // transiently unanswerable, where "unreadable" misread as "false" would revoke the
        // stored flag and present it as the user's own choice (the trap the latch's
        // deviceStateUnavailable refusal exists to prevent). Phase 4's override UI is what
        // makes the override a reconcile input, through its own store surface.
        let outcome = ChainedAvailability.reconcile(
            chainedUpstreamEnabled: configuration.chainedUpstreamEnabled,
            hasLavaSecurityPlus: configuration.hasLavaSecurityPlus,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            experimentalOverrideEnabled: false,
            hasStartupCrashLoopTripped: false
        )

        guard case .disable(let cause) = outcome else {
            return
        }

        configuration.chainedUpstreamEnabled = false
        logVPNDebugEvent("chained-upstream-disabled", details: [
            "reason": reason,
            "cause": cause.rawValue,
        ])
    }

    /// Compact filter-rule count for tight UI: 500K, 1.2M, 2M.
    static func abbreviatedRuleCount(_ count: Int) -> String {
        FilterRuleBudget.abbreviated(count)
    }

    func syncCatalogIfNeeded() async {
        guard catalogVersion == nil else {
            return
        }

        await syncCatalog()
    }

    /// Transitional native accessors. Stored drafts and detail identity belong to
    /// FilterDraftController; active access never depends on the viewed target.
    var filterEditDraft: FilterEditDraft? {
        get { filterDrafts.draft(activeFilterID: activeFilterID) }
        set { filterDrafts.setCurrentDraft(newValue, activeFilterID: activeFilterID) }
    }

    var activeFilterDraft: FilterEditDraft? {
        get { filterDrafts.sessions.drafts[activeFilterID] }
        set { filterDrafts.setDraft(newValue, for: activeFilterID) }
    }

    var filterDetailBaseline: AppConfiguration {
        guard let id = filterEditTargetID, let target = filter(id: id) else {
            return configuration
        }
        var baseline = configuration
        baseline.enabledBlocklistIDs = target.enabledBlocklistIDs
        baseline.customBlocklists = target.customBlocklists
        baseline.blockedDomains = target.blockedDomains
        baseline.allowedDomains = target.allowedDomains
        return baseline
    }

    /// The filter the detail page is currently showing: the non-active "View" target if one is
    /// set, otherwise the active filter. Drives the page title and the rules metric.
    var detailFilter: Filter {
        if let id = filterEditTargetID, let target = filter(id: id) {
            return target
        }
        return library.activeFilter
    }

    /// Whether the detail page is showing a NON-active filter (opened via "View"). Such a
    /// filter is edited library-only — no prepare, no tunnel reload, no auto-refresh.
    var isViewingNonActiveFilter: Bool {
        filterEditTargetID != nil
    }

    /// Whether the ACTIVE filter specifically has an unsaved draft (addressed by its own id, not
    /// the current detail target). Domain History edits the active filter, so it gates on this —
    /// a non-active filter's preserved draft lives under a different key and is irrelevant to it.
    var hasUnsavedActiveFilterDraft: Bool {
        guard let draft = activeFilterDraft else { return false }
        return !FilterConfigurationDiff(from: configuration.filterSelection, to: draft.selection).isEmpty
    }

    /// Open the My-filter detail page for `id` (`nil`/active id = the active filter). Just points
    /// the page at that filter; its own per-filter draft (in the draft controller) resumes if present,
    /// so opening any filter never disturbs another filter's draft.
    func beginViewingFilterDetail(id: String?) {
        filterDrafts.beginViewing(id: id, activeFilterID: activeFilterID)
    }

    /// Called when the detail page disappears (a real pop). Drops a CLEAN draft for the filter the
    /// page was showing (no edits worth keeping); a DIRTY draft stays in its per-filter slot so
    /// re-opening that filter resumes the edit. Then stops targeting (the proxy falls back to the
    /// active filter). Unified across active/non-active — per-filter keying means there's no shared
    /// slot to leak between filters.
    func endViewingFilterDetail() {
        filterDrafts.endViewing(activeFilterID: activeFilterID, hasChanges: filterDraftHasChanges)
    }

    /// Whether the filter the detail page is currently showing has an in-progress edit draft.
    /// (Per-filter storage makes "is editing" simply "this filter has a draft" — the old edit-mode
    /// flag was vestigial.)
    var isFilterEditing: Bool {
        filterEditDraft != nil
    }
}
