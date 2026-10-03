import Foundation
import LavaSecKit

// Native metadata and compatibility forwards. FilterDraftController owns editing
// commands and stored presentation; Domain History staging still coordinates the
// active native context here until the complete-operation extraction in 1D.

extension AppViewModel {
    // MARK: - Filter editing drafts

    func beginFilterEditing() {
        filterDrafts.beginEditing(baseline: filterDetailBaseline, activeFilterID: activeFilterID)
    }

    func cancelFilterEditing() {
        filterDrafts.cancelEditing(activeFilterID: activeFilterID)
    }

    func keepCurrentFiltersAfterPrepareFailure() {
        filterEditDraft = nil
        pendingSwitchFilterID = nil
        filterPreparationState = .idle
        isFilterPreparationScreenPresented = false
    }

    func returnToFilterEditAfterPrepareFailure() {
        filterPreparationState = .idle
        isFilterPreparationScreenPresented = false
    }

    /// Whether the preparation-failure screen should offer "Back to Edit"/"Back to Review".
    /// A filter SWITCH has no edit draft to return to (its only recoveries are "Try Again",
    /// which re-runs the switch, and "Keep Current Filter"), so the secondary button is hidden
    /// for it. An edit apply or a Domain History apply (no pending switch) still offers it.
    var filterPreparationFailureOffersEditReturn: Bool {
        pendingSwitchFilterID == nil
    }

    /// Called from a superseded switch / draft-apply bail. The preparation cover it presented is
    /// only ever dismissed by a cover-driving owner (a switch or a draft apply). If the new owner
    /// is a non-cover-driver (a backup restore or shared-config import) it never touches the cover,
    /// so a silent return would strand the user on the full-screen spinner — dismiss it here. If the
    /// new owner IS another cover-driver, leave the cover to it (it set its own state up).
    func dismissPreparationCoverIfStrandedBySupersession() {
        guard !configurationReplacementGate.currentOwnerOwnsPreparationCover else { return }
        filterPreparationState = .idle
        isFilterPreparationScreenPresented = false
        pendingSwitchFilterID = nil
    }

    /// Resolves a custom blocklist source by ID from the editing view *or* the saved
    /// configuration. A saved list deleted in the draft is still shown as a pending
    /// removal but is hidden from `displayedCustomBlocklists` (the picker rows); this
    /// keeps its name/metadata resolvable so the shelf and review diff show the list
    /// name instead of an opaque source ID.
    func customBlocklistSource(for sourceID: String) -> CustomBlocklistSource? {
        displayedCustomBlocklists.first { $0.id == sourceID }
            ?? filterDetailBaseline.customBlocklists.first { $0.id == sourceID }
    }

    func blocklistName(for sourceID: String) -> String {
        if let catalogSource = catalogSourcesByID[sourceID] {
            return catalogSource.name
        }

        if let customSource = customBlocklistSource(for: sourceID) {
            return customBlocklistPickerTitle(for: customSource)
        }

        return DefaultCatalog.curatedSources.first { $0.id == sourceID }?.name ?? sourceID
    }

    func isBlocklistPendingRemoval(_ sourceID: String) -> Bool {
        guard let filterEditDraft else {
            return false
        }

        return filterDetailBaseline.enabledBlocklistIDs.contains(sourceID)
            && !filterEditDraft.enabledBlocklistIDs.contains(sourceID)
    }

    func isBlocklistNewInDraft(_ sourceID: String) -> Bool {
        guard let filterEditDraft else {
            return false
        }

        return !filterDetailBaseline.enabledBlocklistIDs.contains(sourceID)
            && filterEditDraft.enabledBlocklistIDs.contains(sourceID)
    }

    func isBlockedDomainPendingRemoval(_ domain: String) -> Bool {
        guard let filterEditDraft else {
            return false
        }

        return filterDetailBaseline.blockedDomains.contains(domain)
            && !filterEditDraft.blockedDomains.contains(domain)
    }

    func isBlockedDomainNewInDraft(_ domain: String) -> Bool {
        guard let filterEditDraft else {
            return false
        }

        return !filterDetailBaseline.blockedDomains.contains(domain)
            && filterEditDraft.blockedDomains.contains(domain)
    }

    func isAllowedDomainPendingRemoval(_ domain: String) -> Bool {
        guard let filterEditDraft else {
            return false
        }

        return filterDetailBaseline.allowedDomains.contains(domain)
            && !filterEditDraft.allowedDomains.contains(domain)
    }

    func isAllowedDomainNewInDraft(_ domain: String) -> Bool {
        guard let filterEditDraft else {
            return false
        }

        return !filterDetailBaseline.allowedDomains.contains(domain)
            && filterEditDraft.allowedDomains.contains(domain)
    }

    func stagedBlocklistIDsForDisplay() -> [String] {
        filterDetailBaseline.enabledBlocklistIDs
            .union(filterEditDraft?.enabledBlocklistIDs ?? [])
            .sorted {
                let order = blocklistName(for: $0).localizedStandardCompare(blocklistName(for: $1))
                return order == .orderedSame ? $0 < $1 : order == .orderedAscending
            }
    }

    func stagedBlockedDomainsForDisplay() -> [String] {
        filterDetailBaseline.blockedDomains
            .union(filterEditDraft?.blockedDomains ?? [])
            .sorted {
                let order = $0.localizedStandardCompare($1)
                return order == .orderedSame ? $0 < $1 : order == .orderedAscending
            }
    }

    func stagedAllowedDomainsForDisplay() -> [String] {
        filterDetailBaseline.allowedDomains
            .union(filterEditDraft?.allowedDomains ?? [])
            .sorted {
                let order = $0.localizedStandardCompare($1)
                return order == .orderedSame ? $0 < $1 : order == .orderedAscending
            }
    }

    func addBlocklistsToDraft(_ sourceIDs: Set<String>) -> String? {
        filterDrafts.addBlocklistsToDraft(sourceIDs)
    }

    func setDraftBlocklists(_ sourceIDs: Set<String>) -> String? {
        filterDrafts.setDraftBlocklists(sourceIDs)
    }

    func addCustomBlocklistToDraft(displayName: String, rawURL: String) -> String? {
        filterDrafts.addCustomBlocklistToDraft(displayName: displayName, rawURL: rawURL)
    }

    func removeBlocklistFromDraft(_ sourceID: String) {
        filterDrafts.removeBlocklistFromDraft(sourceID)
    }

    func deleteCustomBlocklistFromDraft(_ sourceID: String) {
        filterDrafts.deleteCustomBlocklistFromDraft(sourceID)
    }

    func undoBlocklistDraftChange(_ sourceID: String) {
        filterDrafts.undoBlocklistDraftChange(sourceID)
    }

    func addBlockedDomainToDraft(_ rawDomain: String) -> DomainDraftResult {
        filterDrafts.addBlockedDomainToDraft(rawDomain)
    }

    func removeBlockedDomainFromDraft(_ domain: String) {
        filterDrafts.removeBlockedDomainFromDraft(domain)
    }

    func undoBlockedDomainDraftChange(_ domain: String) {
        filterDrafts.undoBlockedDomainDraftChange(domain)
    }

    func validateAllowedExceptionDraft(_ rawDomain: String) -> AllowlistValidationResult {
        AllowlistValidator(nonAllowableThreatRules: threatGuardrail).validate(rawDomain)
    }

    func addAllowedDomainToDraft(_ rawDomain: String) -> DomainDraftResult {
        filterDrafts.addAllowedDomainToDraft(rawDomain)
    }

    func stageDomainHistoryDomainAction(_ rawDomain: String, target: DomainHistoryDomainTarget) -> DomainDraftResult {
        // Domain History edits the ACTIVE filter's draft (keyed by activeFilterID). Per-filter
        // storage means a preserved draft for a *different* (non-active) filter is untouched — but
        // an in-progress edit of the ACTIVE filter would still be overwritten, so refuse only in
        // that case rather than losing those edits.
        if hasUnsavedActiveFilterDraft {
            ProtectionHapticFeedback.play(.selectionRejected)
            return .rejected(
                title: "Unsaved filter edits",
                message: "You have unsaved changes to your active filter. Save or discard them in Filters before changing domains here."
            )
        }
        do {
            let result = try configuration.applyingDomainHistoryDomainAction(
                rawDomain,
                target: target,
                allowlistValidator: AllowlistValidator(nonAllowableThreatRules: threatGuardrail)
            )

            // Domain History edits the ACTIVE filter, so write its keyed draft directly and force
            // the detail context to the active filter (target nil) so the review sheet diffs against
            // the active configuration. Domain History lives under the Settings tab while a Filters
            // "View" page may stay mounted on the Guard tab; resetting the target re-points the proxy
            // at the active filter (MyListCover.onAppear re-asserts its own target on return).
            filterEditTargetID = nil
            activeFilterDraft = FilterEditDraft(configuration: result.configuration)
            filterPreparationState = .idle
            isFilterPreparationScreenPresented = false
            ProtectionHapticFeedback.play(.selectionConfirmed)

            switch result.target {
            case .blocked:
                return .accepted(result.normalizedDomain, message: "This domain will be blocked after you confirm.")
            case .allowed:
                return .accepted(result.normalizedDomain, message: "This exception will take effect after you confirm.")
            }
        } catch let actionError as DomainHistoryDomainActionError {
            ProtectionHapticFeedback.play(.selectionRejected)
            return .rejected(
                title: Self.domainHistoryDomainActionRejectionTitle(for: actionError),
                message: actionError.localizedDescription
            )
        } catch {
            ProtectionHapticFeedback.play(.selectionRejected)
            return .rejected(title: "Domain cannot be added", message: error.localizedDescription)
        }
    }

    func removeAllowedDomainFromDraft(_ domain: String) {
        filterDrafts.removeAllowedDomainFromDraft(domain)
    }

    func undoAllowedDomainDraftChange(_ domain: String) {
        filterDrafts.undoAllowedDomainDraftChange(domain)
    }
}
