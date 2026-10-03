import LavaSecKit

/// In-memory editing sessions. Active identity is supplied by the native library
/// authority; changing the viewed filter never moves or publishes another draft.
public struct FilterDraftSessionState: Equatable {
    /// Uncommitted edits, independently addressed by the native filter identity.
    public private(set) var drafts: [String: FilterEditDraft] = [:]
    /// A non-active detail target; nil follows the supplied active filter identity.
    public private(set) var detailTargetID: String?
    /// A never-persisted filter identity. Its rules use the same per-filter draft owner.
    public private(set) var newFilter: Filter?

    /// Starts with no draft and the active filter as the viewing context.
    public init() {}

    /// Resolves the viewed identity without changing the authoritative active filter.
    public func currentFilterID(activeFilterID: String) -> String {
        detailTargetID ?? activeFilterID
    }

    /// Reads the viewed filter's draft, leaving other filters' edits untouched.
    public func currentDraft(activeFilterID: String) -> FilterEditDraft? {
        drafts[currentFilterID(activeFilterID: activeFilterID)]
    }

    /// Updates one session; nil discards only that filter's uncommitted draft.
    public mutating func setDraft(_ draft: FilterEditDraft?, for filterID: String) {
        drafts[filterID] = draft
    }

    /// Starts a new unsaved filter. Neither its identity nor its contents enter the library.
    public mutating func beginCreating(_ filter: Filter, draft: FilterEditDraft) {
        if let previous = newFilter { drafts[previous.id] = nil }
        newFilter = filter
        detailTargetID = filter.id
        drafts[filter.id] = draft
    }

    /// The identity editor stages alongside the rules until the first successful save.
    public mutating func renameNewFilter(name: String, emoji: String) {
        newFilter?.name = name
        newFilter?.emoji = emoji
    }

    /// Only a successful library write retires the staged identity without discarding the page.
    public mutating func completeCreation() {
        if let newFilter { drafts[newFilter.id] = nil }
        newFilter = nil
    }

    /// Explicit cancellation discards an unsaved identity and its rules together.
    public mutating func discardNewFilter() {
        if let newFilter {
            drafts[newFilter.id] = nil
            if detailTargetID == newFilter.id { detailTargetID = nil }
        }
        newFilter = nil
    }

    /// Opens a detail context while preserving every existing edit session.
    public mutating func beginViewing(id: String?, activeFilterID: String) {
        detailTargetID = (id == nil || id == activeFilterID) ? nil : id
    }

    /// A clean draft can be dropped on a real navigation pop. Dirty drafts remain
    /// keyed to their filter so a later visit resumes that filter's edits.
    public mutating func endViewing(activeFilterID: String, hasChanges: Bool) {
        let leavingID = currentFilterID(activeFilterID: activeFilterID)
        if leavingID == newFilter?.id { discardNewFilter() }
        if !hasChanges { drafts[leavingID] = nil }
        detailTargetID = nil
    }

    /// Invalidates all drafts and the viewed target after a library replacement.
    public mutating func reset() {
        newFilter = nil
        drafts.removeAll()
        detailTargetID = nil
    }
}
