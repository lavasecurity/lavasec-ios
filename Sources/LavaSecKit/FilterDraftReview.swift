/// Read-only review of the current draft against its viewed filter. This value
/// describes presentation eligibility; it does not authorize or commit an apply.
public struct FilterDraftReview: Equatable, Sendable {
    /// First rejection in the existing native budget/block/allow validation order.
    public enum ValidationIssue: Equatable, Sendable {
        /// The native rule-count authority rejected the selected blocklists.
        case ruleBudget(String)
        /// The draft exceeds the current additional blocked-domain limit.
        case blockedDomainLimit(Int)
        /// The draft exceeds the current allowed-exception limit.
        case allowedExceptionLimit(Int)
    }

    /// Selection additions and removals, using the existing native diff semantics.
    public let diff: FilterConfigurationDiff
    /// The first validation failure, or nil when the current draft passes review.
    public let validationIssue: ValidationIssue?
    /// Whether the presentation may offer confirmation of a nonempty valid diff.
    public var canConfirm: Bool { !diff.isEmpty && validationIssue == nil }

    /// An unavailable editor presents no changes and cannot offer confirmation.
    public init() {
        let empty = FilterConfigurationSelection(enabledBlocklistIDs: [], blockedDomains: [], allowedDomains: [])
        diff = FilterConfigurationDiff(from: empty, to: empty)
        validationIssue = nil
    }

    /// Projects current native inputs without retaining any writable configuration.
    /// The caller supplies fresh limits and the native rule-budget decision; custom
    /// source metadata continues to follow the existing selection-diff semantics.
    public init(baseline: FilterConfigurationSelection, draft: FilterEditDraft?,
                limits: FeatureLimits, ruleBudgetRejection: String?) {
        diff = FilterConfigurationDiff(from: baseline, to: draft?.selection ?? baseline)
        guard let draft else {
            validationIssue = nil
            return
        }
        if let ruleBudgetRejection {
            validationIssue = .ruleBudget(ruleBudgetRejection)
        } else if draft.blockedDomains.count > limits.maxBlockedDomains {
            validationIssue = .blockedDomainLimit(limits.maxBlockedDomains)
        } else if draft.allowedDomains.count > limits.maxAllowedDomains {
            validationIssue = .allowedExceptionLimit(limits.maxAllowedDomains)
        } else {
            validationIssue = nil
        }
    }
}
