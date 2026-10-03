import Combine
import Foundation
import LavaSecFilterPipeline
import LavaSecKit
import LavaSecPresentation

enum FilterPreparationState: Equatable {
    case idle
    case preparing(progress: Double, message: String)
    case failed(message: String)

    var isPreparing: Bool {
        if case .preparing = self {
            return true
        }

        return false
    }

    var progress: Double {
        if case .preparing(let progress, _) = self {
            return progress
        }

        return 0
    }

    var message: String {
        switch self {
        case .idle:
            "Ready"
        case .preparing(_, let message), .failed(let message):
            message
        }
    }
}

/// Read-only native inputs for draft editing. Budget and threat policy remain
/// authoritative at their existing native owners; this port exposes no save primitive.
@MainActor
protocol FilterDraftContextProviding: AnyObject {
    var activeFilterID: String { get }
    var configuration: AppConfiguration { get }
    var filterDetailBaseline: AppConfiguration { get }
    var blocklists: [BlocklistSource] { get }
    var threatGuardrail: DomainRuleSet { get }
    func draftRuleBudgetRejection(for ids: Set<String>) -> String?
    func draftCustomBlocklistDisplayKey(for source: CustomBlocklistSource) -> String
}

/// Owns draft sessions and preparation presentation. It has no configuration
/// writer, tunnel manager, persistence store, or accepted-operation task to cancel.
@MainActor
final class FilterDraftController: ObservableObject {
    private weak var context: (any FilterDraftContextProviding)?

    init(context: any FilterDraftContextProviding) {
        self.context = context
    }

    private var filterEditDraft: FilterEditDraft? {
        get {
            guard let context else { return nil }
            return draft(activeFilterID: context.activeFilterID)
        }
        set {
            guard let context else { return }
            setCurrentDraft(newValue, activeFilterID: context.activeFilterID)
        }
    }

    @Published private(set) var sessions = FilterDraftSessionState()
    @Published var preparationState: FilterPreparationState = .idle
    @Published var isPreparationPresented = false
    @Published var preparationOrigin: FilterReviewOrigin = .filters
    @Published var preparationFailureIsRetryable = true
    var pendingSwitchFilterID: String?

    var detailTargetID: String? { sessions.detailTargetID }

    // Keep cheap dirty-state reads independent of native budget estimation. The
    // review uses the same selection diff and adds the current native limits.
    var reviewDiff: FilterConfigurationDiff {
        guard let context else { return FilterDraftReview().diff }
        let baseline = context.filterDetailBaseline.filterSelection
        return FilterConfigurationDiff(from: baseline, to: filterEditDraft?.selection ?? baseline)
    }

    /// Recomputed from the current viewed draft and native limits. No cached
    /// review can become a second writer or stand in for apply-time validation.
    var review: FilterDraftReview {
        guard let context else { return FilterDraftReview() }
        let draft = filterEditDraft
        return FilterDraftReview(
            baseline: context.filterDetailBaseline.filterSelection,
            draft: draft,
            limits: context.configuration.limits,
            ruleBudgetRejection: draft.flatMap { context.draftRuleBudgetRejection(for: $0.enabledBlocklistIDs) }
        )
    }

    func validationMessage(for review: FilterDraftReview) -> String? {
        switch review.validationIssue {
        case .ruleBudget(let message):
            return message
        case .blockedDomainLimit(let limit):
            return "You can keep up to %lld additional blocked domains.".lavaLocalizedFormat(limit)
        case .allowedExceptionLimit(let limit):
            return "You can keep up to %lld allowed exceptions.".lavaLocalizedFormat(limit)
        case nil:
            return nil
        }
    }

    func changeCountText(for diff: FilterConfigurationDiff) -> String {
        let count = diff.changeCount
        return count == 1
            ? "%d change".lavaLocalizedFormat(count)
            : "%d changes".lavaLocalizedFormat(count)
    }

    func draft(activeFilterID: String) -> FilterEditDraft? {
        sessions.currentDraft(activeFilterID: activeFilterID)
    }

    func setDraft(_ draft: FilterEditDraft?, for filterID: String) {
        sessions.setDraft(draft, for: filterID)
    }

    func setCurrentDraft(_ draft: FilterEditDraft?, activeFilterID: String) {
        sessions.setDraft(draft, for: sessions.currentFilterID(activeFilterID: activeFilterID))
    }

    func beginEditing(baseline: AppConfiguration, activeFilterID: String) {
        setCurrentDraft(FilterEditDraft(configuration: baseline), activeFilterID: activeFilterID)
        preparationState = .idle
    }

    func beginCreating(_ filter: Filter, baseline: AppConfiguration) {
        sessions.beginCreating(filter, draft: FilterEditDraft(configuration: baseline))
        preparationState = .idle
    }

    func renameNewFilter(name: String, emoji: String) {
        sessions.renameNewFilter(name: name, emoji: emoji)
    }

    func completeCreation() { sessions.completeCreation() }

    func cancelEditing(activeFilterID: String) {
        setCurrentDraft(nil, activeFilterID: activeFilterID)
        if sessions.detailTargetID == sessions.newFilter?.id { sessions.discardNewFilter() }
        preparationState = .idle
        isPreparationPresented = false
    }

    func beginViewing(id: String?, activeFilterID: String) {
        sessions.beginViewing(id: id, activeFilterID: activeFilterID)
        preparationState = .idle
    }

    /// Retargeting during a native transaction must not reset its preparation UI.
    func retarget(id: String?, activeFilterID: String) {
        sessions.beginViewing(id: id, activeFilterID: activeFilterID)
    }

    func endViewing(activeFilterID: String, hasChanges: Bool) {
        guard !isPreparationPresented, !preparationState.isPreparing else { return }
        sessions.endViewing(activeFilterID: activeFilterID, hasChanges: hasChanges)
    }

    /// Native library replacement invalidates all sessions together. The caller
    /// can retain the value snapshot for its existing rejected-before-write rollback.
    func resetSessions() {
        sessions.reset()
    }

    func restoreSessions(_ snapshot: FilterDraftSessionState) {
        sessions = snapshot
    }

    func addBlocklistsToDraft(_ sourceIDs: Set<String>) -> String? {
        guard let context else { return "Tap Edit before changing your filter." }
        guard var draft = filterEditDraft else {
            return "Tap Edit before changing your filter."
        }

        let updatedIDs = draft.enabledBlocklistIDs.union(sourceIDs)
        if let rejection = context.draftRuleBudgetRejection(for: updatedIDs) {
            return rejection
        }

        draft.enabledBlocklistIDs = updatedIDs
        filterEditDraft = draft
        return nil
    }

    func setDraftBlocklists(_ sourceIDs: Set<String>) -> String? {
        guard let context else { return "Tap Edit before changing your filter." }
        guard var draft = filterEditDraft else {
            return "Tap Edit before changing your filter."
        }

        let updatedIDs = sourceIDs
        if let rejection = context.draftRuleBudgetRejection(for: updatedIDs) {
            return rejection
        }

        draft.enabledBlocklistIDs = updatedIDs
        filterEditDraft = draft
        return nil
    }

    func addCustomBlocklistToDraft(displayName: String, rawURL: String) -> String? {
        guard let context else { return "Tap Edit before changing your filter." }
        guard context.configuration.limits.allowsCustomBlocklists else {
            return "Custom blocklist URLs are included with Lava Plus."
        }

        guard var draft = filterEditDraft else {
            return "Tap Edit before changing your filter."
        }

        do {
            let source = try CustomBlocklistSource(displayName: displayName, rawURL: rawURL)
            if let catalogSourceID = KnownBlocklistURLMatcher.catalogSourceID(for: source.sourceURL) {
                guard context.blocklists.contains(where: { $0.id == catalogSourceID }) else {
                    return "A selected blocklist is no longer available. Choose another list and try again."
                }
                if !draft.enabledBlocklistIDs.contains(catalogSourceID),
                   let rejection = context.draftRuleBudgetRejection(for: draft.enabledBlocklistIDs.union([catalogSourceID])) {
                    return rejection
                }

                draft.customBlocklists.removeAll {
                    $0.sourceURL == source.sourceURL
                        || KnownBlocklistURLMatcher.catalogSourceID(for: $0.sourceURL) == catalogSourceID
                }
                draft.enabledBlocklistIDs.insert(catalogSourceID)
                filterEditDraft = draft
                return nil
            }

            guard !draft.customBlocklists.contains(where: { $0.sourceURL == source.sourceURL }) else {
                return "That custom URL is already added."
            }

            let displayKey = context.draftCustomBlocklistDisplayKey(for: source)
            guard !draft.customBlocklists.contains(where: { existingSource in
                existingSource.sourceURL != source.sourceURL
                    && context.draftCustomBlocklistDisplayKey(for: existingSource) == displayKey
            }) else {
                return "A custom list with that name already exists."
            }

            let updatedIDs = draft.enabledBlocklistIDs.union([source.id])
            if let rejection = context.draftRuleBudgetRejection(for: updatedIDs) {
                return rejection
            }

            draft.customBlocklists.append(source)
            draft.enabledBlocklistIDs = updatedIDs
            filterEditDraft = draft
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removeBlocklistFromDraft(_ sourceID: String) {
        guard var draft = filterEditDraft else {
            return
        }

        draft.enabledBlocklistIDs.remove(sourceID)
        filterEditDraft = draft
    }

    func deleteCustomBlocklistFromDraft(_ sourceID: String) {
        guard var draft = filterEditDraft else {
            return
        }

        draft.enabledBlocklistIDs.remove(sourceID)
        draft.customBlocklists.removeAll { $0.id == sourceID }
        filterEditDraft = draft
    }

    func undoBlocklistDraftChange(_ sourceID: String) {
        guard let context else { return }
        guard var draft = filterEditDraft else {
            return
        }

        let baseline = context.filterDetailBaseline
        if baseline.enabledBlocklistIDs.contains(sourceID) {
            draft.enabledBlocklistIDs.insert(sourceID)
            if let source = baseline.customBlocklists.first(where: { $0.id == sourceID }),
               !draft.customBlocklists.contains(where: { $0.id == sourceID }) {
                draft.customBlocklists.append(source)
            }
        } else {
            draft.enabledBlocklistIDs.remove(sourceID)
        }

        filterEditDraft = draft
    }

    func addBlockedDomainToDraft(_ rawDomain: String) -> DomainDraftResult {
        guard let context else { return .rejected(title: "Edit first", message: "Tap Edit before changing your filter.") }
        guard let draft = filterEditDraft else {
            ProtectionHapticFeedback.play(.selectionRejected)
            return .rejected(title: "Edit first", message: "Tap Edit before changing your filter.")
        }

        let outcome = FilterEditDraftEditor.addBlockedDomain(
            rawDomain,
            to: draft,
            maxBlockedDomains: context.configuration.limits.maxBlockedDomains
        )
        if outcome.result.isAccepted {
            filterEditDraft = outcome.draft
            ProtectionHapticFeedback.play(.selectionConfirmed)
        } else {
            ProtectionHapticFeedback.play(.selectionRejected)
        }
        return outcome.result
    }

    func removeBlockedDomainFromDraft(_ domain: String) {
        guard let draft = filterEditDraft else {
            return
        }

        filterEditDraft = FilterEditDraftEditor.removeBlockedDomain(domain, from: draft)
        ProtectionHapticFeedback.play(.selectionConfirmed)
    }

    func undoBlockedDomainDraftChange(_ domain: String) {
        guard let context else { return }
        guard let draft = filterEditDraft else {
            return
        }

        filterEditDraft = FilterEditDraftEditor.undoBlockedDomainChange(
            domain,
            in: draft,
            configuredBlockedDomains: context.filterDetailBaseline.blockedDomains
        )
    }

    func addAllowedDomainToDraft(_ rawDomain: String) -> DomainDraftResult {
        guard let context else { return .rejected(title: "Edit first", message: "Tap Edit before changing your filter.") }
        guard let draft = filterEditDraft else {
            ProtectionHapticFeedback.play(.selectionRejected)
            return .rejected(title: "Edit first", message: "Tap Edit before changing your filter.")
        }

        let outcome = FilterEditDraftEditor.addAllowedDomain(
            rawDomain,
            to: draft,
            maxAllowedDomains: context.configuration.limits.maxAllowedDomains,
            validator: AllowlistValidator(nonAllowableThreatRules: context.threatGuardrail)
        )
        if outcome.result.isAccepted {
            filterEditDraft = outcome.draft
            ProtectionHapticFeedback.play(.selectionConfirmed)
        } else {
            ProtectionHapticFeedback.play(.selectionRejected)
        }
        return outcome.result
    }

    func removeAllowedDomainFromDraft(_ domain: String) {
        guard let draft = filterEditDraft else {
            return
        }

        filterEditDraft = FilterEditDraftEditor.removeAllowedDomain(domain, from: draft)
        ProtectionHapticFeedback.play(.selectionConfirmed)
    }

    func undoAllowedDomainDraftChange(_ domain: String) {
        guard let context else { return }
        guard let draft = filterEditDraft else {
            return
        }

        filterEditDraft = FilterEditDraftEditor.undoAllowedDomainChange(
            domain,
            in: draft,
            configuredAllowedDomains: context.filterDetailBaseline.allowedDomains
        )
    }
}
