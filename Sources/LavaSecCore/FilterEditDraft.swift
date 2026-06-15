import Foundation

/// The in-progress edits to a user's filter configuration, before they are
/// confirmed and applied. Mirrors the saved `AppConfiguration` selection so the
/// UI can show a pending diff. Lives in LavaSecCore so the pure draft-mutation
/// logic (`FilterEditDraftEditor`) is unit-testable; the `@Published` wiring and
/// the begin/confirm/cancel + snapshot-rebuild orchestration stay in the app's
/// view model.
public struct FilterEditDraft: Equatable {
    public var enabledBlocklistIDs: Set<String>
    public var customBlocklists: [CustomBlocklistSource]
    public var blockedDomains: Set<String>
    public var allowedDomains: Set<String>

    public init(configuration: AppConfiguration) {
        enabledBlocklistIDs = configuration.enabledBlocklistIDs
        customBlocklists = configuration.customBlocklists
        blockedDomains = configuration.blockedDomains
        allowedDomains = configuration.allowedDomains
    }

    public init(
        enabledBlocklistIDs: Set<String>,
        customBlocklists: [CustomBlocklistSource],
        blockedDomains: Set<String>,
        allowedDomains: Set<String>
    ) {
        self.enabledBlocklistIDs = enabledBlocklistIDs
        self.customBlocklists = customBlocklists
        self.blockedDomains = blockedDomains
        self.allowedDomains = allowedDomains
    }

    public var selection: FilterConfigurationSelection {
        FilterConfigurationSelection(
            enabledBlocklistIDs: enabledBlocklistIDs,
            blockedDomains: blockedDomains,
            allowedDomains: allowedDomains
        )
    }
}

/// Outcome of a draft domain edit, surfaced to the UI as an accept/reject toast.
public struct DomainDraftResult: Equatable {
    public let normalizedDomain: String?
    public let isAccepted: Bool
    public let title: String
    public let message: String

    public static func accepted(_ domain: String, message: String) -> DomainDraftResult {
        DomainDraftResult(
            normalizedDomain: domain,
            isAccepted: true,
            title: "Added \(domain)",
            message: message
        )
    }

    public static func rejected(title: String, message: String) -> DomainDraftResult {
        DomainDraftResult(
            normalizedDomain: nil,
            isAccepted: false,
            title: title,
            message: message
        )
    }
}

/// Pure domain add/remove/undo mutations on a `FilterEditDraft`. Each operation
/// takes the current draft + the inputs it needs (limits, the active
/// configuration's sets, an `AllowlistValidator`) and returns the new draft
/// (plus an accept/reject result for the add operations). No view-model or
/// `@Published` state is touched — the caller assigns the returned draft.
public enum FilterEditDraftEditor {
    public static func addBlockedDomain(
        _ rawDomain: String,
        to draft: FilterEditDraft,
        maxBlockedDomains: Int
    ) -> (draft: FilterEditDraft, result: DomainDraftResult) {
        var draft = draft

        let normalized: String
        do {
            normalized = try DomainName.normalize(rawDomain)
        } catch {
            return (draft, .rejected(title: "Domain cannot be added", message: error.localizedDescription))
        }

        guard !draft.blockedDomains.contains(normalized) else {
            return (draft, .rejected(title: "Already blocked", message: "\(normalized) is already in your blocked domains."))
        }

        guard draft.blockedDomains.count < maxBlockedDomains else {
            return (draft, .rejected(
                title: "Blocked domain limit reached",
                message: "Free protection includes \(maxBlockedDomains) additional blocked domains."
            ))
        }

        draft.blockedDomains.insert(normalized)
        return (draft, .accepted(normalized, message: "This domain will be blocked after you save."))
    }

    public static func removeBlockedDomain(_ domain: String, from draft: FilterEditDraft) -> FilterEditDraft {
        var draft = draft
        draft.blockedDomains.remove(domain)
        return draft
    }

    public static func undoBlockedDomainChange(
        _ domain: String,
        in draft: FilterEditDraft,
        configuredBlockedDomains: Set<String>
    ) -> FilterEditDraft {
        var draft = draft
        if configuredBlockedDomains.contains(domain) {
            draft.blockedDomains.insert(domain)
        } else {
            draft.blockedDomains.remove(domain)
        }
        return draft
    }

    public static func addAllowedDomain(
        _ rawDomain: String,
        to draft: FilterEditDraft,
        maxAllowedDomains: Int,
        validator: AllowlistValidator
    ) -> (draft: FilterEditDraft, result: DomainDraftResult) {
        var draft = draft

        let validation = validator.validate(rawDomain)
        guard validation.isAllowed, let domain = validation.normalizedDomain else {
            return (draft, .rejected(title: "Exception cannot be added", message: validation.message))
        }

        guard !draft.allowedDomains.contains(domain) else {
            return (draft, .rejected(title: "Already allowed", message: "\(domain) is already in your allowed exceptions."))
        }

        guard draft.allowedDomains.count < maxAllowedDomains else {
            return (draft, .rejected(
                title: "Allowed exception limit reached",
                message: "Free protection includes \(maxAllowedDomains) allowed exceptions."
            ))
        }

        draft.allowedDomains.insert(domain)
        return (draft, .accepted(domain, message: "This exception will take effect after you save."))
    }

    public static func removeAllowedDomain(_ domain: String, from draft: FilterEditDraft) -> FilterEditDraft {
        var draft = draft
        draft.allowedDomains.remove(domain)
        return draft
    }

    public static func undoAllowedDomainChange(
        _ domain: String,
        in draft: FilterEditDraft,
        configuredAllowedDomains: Set<String>
    ) -> FilterEditDraft {
        var draft = draft
        if configuredAllowedDomains.contains(domain) {
            draft.allowedDomains.insert(domain)
        } else {
            draft.allowedDomains.remove(domain)
        }
        return draft
    }
}
