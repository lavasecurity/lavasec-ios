import Foundation
import LavaSecKit

/// A native-owned library draft. Forms stage values; only a validated review commits.
public struct FilterLibraryEditSession: Equatable {
    /// Whether this session owns a library draft.
    public private(set) var isEditing = false
    /// Persisted filter identifiers marked for removal at confirmation.
    public private(set) var stagedDeletions: Set<String> = []
    /// The saved library captured when editing began.
    public private(set) var baseline: FilterLibrary?
    /// New filters kept only in this draft until confirmation.
    public private(set) var additions: [Filter] = []
    /// New names keyed by persisted filter identifier.
    public private(set) var renames: [String: String] = [:]
    /// New emojis keyed by persisted filter identifier.
    public private(set) var emojiChanges: [String: String] = [:]
    /// Creates an inactive, empty editing session.
    public init() {}
    /// Whether confirming would change saved library content.
    public var hasChanges: Bool { !stagedDeletions.isEmpty || !additions.isEmpty || !renames.isEmpty || !emojiChanges.isEmpty }
    /// Captures the baseline once; repeated entry preserves the current draft.
    public mutating func beginEditing(library: FilterLibrary? = nil) {
        guard !isEditing else { return }
        isEditing = true
        baseline = library
    }
    /// Discards all draft state after cancellation or successful persistence.
    public mutating func endEditing() { self = Self() }
    /// Toggles a saved filter removal, or discards a newly staged filter.
    public mutating func toggleDeletion(_ id: String) {
        guard isEditing else { return }
        if let index = additions.firstIndex(where: { $0.id == id }) {
            additions.remove(at: index)
            renames[id] = nil
            emojiChanges[id] = nil
        } else if !stagedDeletions.insert(id).inserted { stagedDeletions.remove(id) }
    }
    /// Stages a new filter without changing the saved library.
    public mutating func add(_ filter: Filter) {
        guard isEditing else { return }
        additions.append(filter)
    }
    /// Stages a trimmed name and removes a rename that returns to baseline.
    public mutating func rename(_ id: String, to name: String) {
        guard isEditing else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = additions.firstIndex(where: { $0.id == id }) { additions[index].name = trimmed }
        else { renames[id] = baseline?.filter(id: id)?.name == trimmed ? nil : trimmed }
    }
    /// Stages a complete identity edit so name and emoji share one review boundary.
    public mutating func rename(_ id: String, to name: String, emoji: String) {
        guard isEditing else { return }
        rename(id, to: name)
        if let index = additions.firstIndex(where: { $0.id == id }) { additions[index].emoji = emoji }
        else { emojiChanges[id] = baseline?.filter(id: id)?.emoji == emoji ? nil : emoji }
    }
    /// Includes pending removals for stable row positions until confirmation.
    public var displayedFilters: [Filter] {
        ((baseline?.filters ?? []) + additions).map { filter in
            var result = filter
            if let name = renames[filter.id] { result.name = name }
            if let emoji = emojiChanges[filter.id] { result.emoji = emoji }
            return result
        }
    }
    /// Rejects the entire batch if its baseline or any live constraint changed.
    public func validatedLibrary(current: FilterLibrary, maximumFilters: Int) -> FilterLibrary? {
        guard isEditing, hasChanges, let baseline,
              baseline.strippingLocalCacheState() == current.strippingLocalCacheState() else { return nil }
        let policy = FilterLibraryAccessPolicy(library: current, maximumFilters: maximumFilters)
        guard !stagedDeletions.contains(current.activeFilterID),
              stagedDeletions.allSatisfy({ current.filter(id: $0) != nil && !policy.isFrozen($0) }),
              renames.keys.allSatisfy({ current.filter(id: $0) != nil && !policy.isFrozen($0) }),
              emojiChanges.allSatisfy({ current.filter(id: $0.key) != nil && !policy.isFrozen($0.key)
                  && FilterIdentityPolicy.isValidEmoji($0.value) }) else { return nil }
        // Keep live cache metadata: an unrelated warm-up need not invalidate a name-only review.
        var filters = current.filters.filter { !stagedDeletions.contains($0.id) }
        for index in filters.indices {
            if let name = renames[filters[index].id] { filters[index].name = name }
            if let emoji = emojiChanges[filters[index].id] { filters[index].emoji = emoji }
        }
        filters.append(contentsOf: additions)
        guard !filters.isEmpty, filters.count <= maximumFilters || additions.isEmpty,
              Set(filters.map(\.id)).count == filters.count else { return nil }
        let names = filters.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard names.allSatisfy({ !$0.isEmpty }), Set(names).count == names.count else { return nil }
        return FilterLibrary(filters: filters, activeFilterID: current.activeFilterID,
                             schemaVersion: current.schemaVersion, configurationGeneration: current.configurationGeneration)
    }
}
