import Foundation
import LavaSecKit

extension LavaAppBridge {
    /// RN and native forms share one draft; confirmation is its only write boundary.
    func libraryCommand(_ name: String, _ input: [String: Any]) async throws -> Any {
        let library = libraryEditor
        if name == "library.cancel" { library.setEditing(false); return NSNull() }
        try await authorize(.filterEditing, "Manage filters")
        if name == "library.edit" { library.setEditing(true); return NSNull() }
        guard library.isEditing else { throw CommandError("Start editing your filters first.") }
        if name == "library.toggleDeletion" {
            guard let id = input["id"] as? String,
                  library.filters.contains(where: { $0.id == id }), id != model.activeFilterID,
                  !library.isFilterFrozen(id) else { throw CommandError("This filter cannot be deleted.") }
            library.toggleStagedDeletion(id)
            return NSNull()
        }
        guard name == "library.form", flow == nil,
              let kind = input["form"] as? String, ["create", "rename", "delete"].contains(kind) else { throw CommandError("This filter action is unavailable.") }
        var next = LavaAppNativeFlow(name: kind == "create" ? "createFilter" : kind == "rename" ? "renameFilter" : "deleteFilters", library: library)
        if kind == "create" {
            guard !library.hasChanges else { throw CommandError("Review or discard your current changes before adding a filter.") }
            guard library.canCreateFilter else { throw CommandError("Maximum filters reached") }
        } else if kind == "rename" {
            guard let id = input["id"] as? String, let filter = library.filters.first(where: { $0.id == id }),
                  !library.isFilterFrozen(id) else { throw CommandError("This filter is locked. Upgrade to Lava Plus to edit it.") }
            next.filterID = id
            next.filterName = filter.name
            next.filterEmoji = filter.emoji
        } else {
            guard library.hasChanges else { throw CommandError("There are no changes to save.") }
        }
        let reviewedSession = library.editSession
        let result: (String?, Bool) = await withCheckedContinuation { continuation in
            var confirmed = false
            var createdID: String?
            var completed = false
            next.createFilterDraft = { templateID in
                guard library.canBeginCreatingFilter else { return false }
                guard let id = self.model.beginCreatingFilter(duplicatingFilterID: templateID) else { return false }
                createdID = id
                return true
            }
            next.confirmLibraryDeletion = {
                guard library.editSession == reviewedSession, library.commitStagedDeletions() else { return false }
                confirmed = true
                return true
            }
            next.onDismiss = {
                guard !completed else { return }
                completed = true
                continuation.resume(returning: (createdID, confirmed))
            }
            flow = next
        }
        return result.0.map { $0 as Any } ?? result.1
    }
    struct StandaloneDomainReview {
        let filterID: String
        let draft: FilterEditDraft
        var applying = false
        var cancelRequested = false
    }
    func cancelStandaloneDomainReview(_ token: String) {
        guard var owned = standaloneDomainReviews[token] else { return }
        if owned.applying {
            // Closing a screen cannot interrupt an accepted native transaction.
            owned.cancelRequested = true
            standaloneDomainReviews[token] = owned
            return
        }
        standaloneDomainReviews[token] = nil
        guard model.filterDrafts.sessions.drafts[owned.filterID] == owned.draft else { return }
        model.filterDrafts.setDraft(nil, for: owned.filterID)
        if reviewedFilter?.filterID == owned.filterID, reviewedFilter?.draft == owned.draft { reviewedFilter = nil }
    }
    private func finishStandaloneDomainReview(_ token: String) {
        guard var owned = standaloneDomainReviews[token] else { return }
        owned.applying = false
        standaloneDomainReviews[token] = owned
        if owned.cancelRequested || model.filterDrafts.sessions.drafts[owned.filterID] != owned.draft {
            cancelStandaloneDomainReview(token)
        }
    }
    struct ReviewedFilter {
        let token: String
        let filterID: String
        let activeID: String
        let baseline: AppConfiguration
        let draft: FilterEditDraft
    }
    func filterCommand(_ name: String, _ input: [String: Any]) async throws -> Any {
        if name == "filter.restoreDefaults" {
            guard !libraryEditor.hasChanges else { throw CommandError("Save or discard your library changes before restoring defaults.") }
            try await authorize(.filterEditing, "Restore default filters")
            model.restoreFiltersToDefault()
            reviewedFilter = nil
            return NSNull()
        }
        if name == "filter.create" {
            try await authorize(.filterEditing, "Create filter")
            guard let id = model.createFilter(name: input["name"] as? String ?? "", duplicatingFilterID: input["duplicate"] as? String) else { throw CommandError("This filter could not be created. Check the name and your plan's filter limit.") }
            return id
        }
        guard let id = input["id"] as? String, model.filter(id: id) != nil else { throw CommandError("That filter is no longer available.") }
        if name == "filter.open" {
            guard !model.isFilterPreparationScreenPresented else { throw CommandError("A filter is still being prepared. Try again when it finishes.") }
            filterPresentationEpoch += 1
            model.beginViewingFilterDetail(id: id)
            // A retained draft must not survive a filter becoming read-only.
            if model.isFilterFrozen(id) { model.cancelFilterEditing(); reviewedFilter = nil }
            return NSNull()
        }
        if name == "filter.switch" {
            guard !model.isFilterFrozen(id) else { throw CommandError("This filter is locked. Upgrade to edit or apply it.") }
            try await authorize(.filterEditing, "Switch filter", fresh: true)
            await model.switchToFilter(id: id)
            return NSNull()
        }
        if name == "filter.close" {
            if (model.filterEditTargetID ?? model.activeFilterID) == id, !model.isFilterPreparationScreenPresented {
                filterPresentationEpoch += 1
                model.endViewingFilterDetail()
            }
            return NSNull()
        }
        if name == "filter.refresh" {
            guard id == model.activeFilterID else { return NSNull() }
            await model.syncCatalog()
            return NSNull()
        }
        if name == "filter.cancel" {
            // Discard is local teardown. A revoked
            // editing grant must not trap the user behind another auth prompt.
            guard (model.filterEditTargetID ?? model.activeFilterID) == id,
                  !model.isFilterPreparationScreenPresented else { return NSNull() }
            model.cancelFilterEditing()
            reviewedFilter = nil
            return NSNull()
        }
        let saving = name == "filter.apply" || name == "filter.save"
        let presentation = filterPresentationEpoch
        if name == "filter.edit" {
            guard !filterEditAuthenticationInFlight else { return NSNull() }
            filterEditAuthenticationInFlight = true
        }
        defer { if name == "filter.edit" { filterEditAuthenticationInFlight = false } }
        // Save (or a standalone domain action) authenticates before Review.
        // Confirmation revalidates that exact draft without forcing a second prompt.
        try await authorize(.filterEditing, saving ? "Save filter" : "Edit filter", fresh: name == "filter.save" || name == "filter.delete")
        if name == "filter.edit", presentation != filterPresentationEpoch { throw CommandError("The displayed filter changed. Reopen it before editing.") }
        if name == "filter.delete" {
            guard model.deleteFilter(id: id) else { throw CommandError("Switch to another filter before deleting this one.") }
            return NSNull()
        }
        if name == "filter.rename" {
            guard !model.isFilterFrozen(id) else { throw CommandError("This filter is locked. Upgrade to Lava Plus to edit it.") }
            guard let title = input["name"] as? String, model.isFilterNameAvailable(title, excluding: id) else { throw CommandError("Choose an unused filter name.") }
            guard model.renameFilter(id: id, to: title, emoji: input["emoji"] as? String) else { throw CommandError("Couldn’t save filter identity. Check the name and emoji, then try again.") }
            return NSNull()
        }
        guard (model.filterEditTargetID ?? model.activeFilterID) == id else { throw CommandError("The displayed filter changed. Reopen it before editing.") }
        guard !model.isFilterFrozen(id) else { throw CommandError("This filter is locked. Upgrade to Lava Plus to edit it.") }
        switch name {
        case "filter.renameForm":
            guard model.filterEditDraft != nil, flow == nil,
                  let filter = model.filter(id: id) else { throw CommandError("Start editing this filter first.") }
            var next = LavaAppNativeFlow(name: "renameFilter", filterID: id,
                                         filterName: filter.name, filterEmoji: filter.emoji)
            let dismissed: Bool = await withCheckedContinuation { continuation in
                next.onDismiss = { continuation.resume(returning: true) }
                flow = next
            }
            return dismissed
        case "filter.edit":
            guard !model.isFilterPreparationScreenPresented else { throw CommandError("A filter is still being prepared. Try again when it finishes.") }
            // Refresh is independent, as in FilterMyListView. A repeated Edit
            // callback cannot replace a draft the first callback already opened.
            if model.filterEditDraft == nil { model.beginFilterEditing() }
        case "filter.save":
            if model.filterDrafts.sessions.newFilter?.id == id {
                if let error = model.saveNewFilterDraft() { throw CommandError(error) }
                return "saved"
            }
            guard model.filterDraftHasChanges else { model.cancelFilterEditing(); return "saved" }
            if model.isViewingNonActiveFilter {
                if let error = model.saveNonActiveFilterDraft() { throw CommandError(error) }
                return "saved"
            }
            let diff = model.filterDraftDiff
            if !diff.removedBlocklistIDs.isEmpty || !diff.removedBlockedDomains.isEmpty || !diff.addedAllowedDomains.isEmpty { return "review" }
            await model.prepareAndApplyFilterDraft(origin: .filters)
            return "saved"
        case "filter.undoList":
            guard model.filterEditDraft != nil, let sourceID = input["sourceID"] as? String else { throw CommandError("Start editing this filter first.") }
            model.filterDrafts.undoBlocklistDraftChange(sourceID)
            reviewedFilter = nil
        case "filter.undoDomain":
            guard model.filterEditDraft != nil, let domain = input["domain"] as? String, let decision = input["decision"] as? String else { throw CommandError("Start editing this filter first.") }
            if decision == "blocked" { model.filterDrafts.undoBlockedDomainDraftChange(domain) }
            else if decision == "allowed" { model.filterDrafts.undoAllowedDomainDraftChange(domain) }
            else { throw CommandError("Unknown domain decision.") }
            reviewedFilter = nil
        case "filter.deleteCustomList":
            guard model.filterEditDraft != nil, let sourceID = input["sourceID"] as? String, model.displayedCustomBlocklists.contains(where: { $0.id == sourceID }) else { throw CommandError("This custom blocklist is no longer available.") }
            model.filterDrafts.deleteCustomBlocklistFromDraft(sourceID)
            reviewedFilter = nil
        case "filter.lists", "filter.customList":
            guard model.filterEditDraft != nil, let ids = input["ids"] as? [String] else { throw CommandError("Start editing this filter first.") }
            let available = Set(model.blocklists.map(\.id) + model.displayedCustomBlocklists.map(\.id))
            guard Set(ids).isSubset(of: available) else { throw CommandError("This blocklist is no longer available.") }
            if name == "filter.customList" {
                // Budget the picker selection without saving its unconfirmed edits.
                pushedCustomEntry = LavaAppNativeFlow(name: "customBlocklist", filterID: id, blocklistSelection: Set(ids))
                return pushedCustomEntry!.id.uuidString
            }
            if let error = model.setDraftBlocklists(Set(ids)) { throw CommandError(error) }
            reviewedFilter = nil
        case "filter.removeList":
            guard model.filterEditDraft != nil, let sourceID = input["sourceID"] as? String else { throw CommandError("Start editing this filter first.") }
            model.removeBlocklistFromDraft(sourceID)
            reviewedFilter = nil
        case "filter.domain":
            guard model.filterEditDraft != nil, let raw = input["domain"] as? String,
                  let decision = input["decision"] as? String, ["blocked", "allowed"].contains(decision) else { throw CommandError("Start editing this filter first.") }
            let domain = input["remove"] as? Bool == true ? try DomainName.normalize(raw) : raw
            // Apply one action to the current native draft. A queued tap must not
            // replace the whole draft with an older React render's domain arrays.
            if input["remove"] as? Bool == true {
                if decision == "blocked" { model.removeBlockedDomainFromDraft(domain) }
                else { model.removeAllowedDomainFromDraft(domain) }
            } else {
                let result = decision == "blocked" ? model.addBlockedDomainToDraft(domain) : model.addAllowedDomainToDraft(domain)
                if !result.isAccepted { return ["isAccepted": false, "title": result.title, "message": result.message] }
            }
            reviewedFilter = nil
        case "filter.review":
            guard let draft = model.filterEditDraft, model.filterDrafts.review.canConfirm else { throw CommandError(model.filterDraftValidationMessage ?? "There are no changes to save.") }
            let review = ReviewedFilter(token: UUID().uuidString, filterID: id, activeID: model.activeFilterID, baseline: model.filterDetailBaseline, draft: draft)
            reviewedFilter = review
            return review.token
        case "filter.apply":
            guard let review = reviewedFilter, review.token == input["review"] as? String, review.filterID == id,
                  review.activeID == model.activeFilterID, review.baseline == model.filterDetailBaseline, review.draft == model.filterEditDraft else {
                throw CommandError("The filter changed since review. Review the current changes before saving.")
            }
            let standaloneToken = input["standaloneReview"] as? String
            if let standaloneToken {
                guard var owned = standaloneDomainReviews[standaloneToken], owned.filterID == id, owned.draft == review.draft else {
                    throw CommandError("The filter changed since review. Review the current changes before saving.")
                }
                owned.applying = true
                standaloneDomainReviews[standaloneToken] = owned
            }
            defer { if let standaloneToken { finishStandaloneDomainReview(standaloneToken) } }
            if model.isViewingNonActiveFilter {
                if let error = model.saveNonActiveFilterDraft() { throw CommandError(error) }
            } else { await model.prepareAndApplyFilterDraft(origin: standaloneToken == nil ? .filters : .domainHistory) }
            if reviewedFilter?.token == review.token { reviewedFilter = nil }
        default: throw CommandError("Unknown filter command.")
        }
        return NSNull()
    }
}
