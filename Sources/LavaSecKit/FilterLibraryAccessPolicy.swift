import Foundation

/// Library eligibility shared by presentation and native mutation backstops.
/// Build from current authoritative inputs when an operation is attempted.
public struct FilterLibraryAccessPolicy {
    private let library: FilterLibrary
    private let maximumFilters: Int

    /// Captures the library and the current tier's filter limit for one evaluation.
    public init(library: FilterLibrary, maximumFilters: Int) {
        self.library = library
        self.maximumFilters = maximumFilters
    }

    /// Whether the current library has room for one more filter.
    public var canCreate: Bool { library.filters.count < maximumFilters }

    /// Keeps the active filter and the first remaining tier slots usable. Excess
    /// filters remain readable when an entitlement lapses; they are never deleted.
    public func isFrozen(_ id: String) -> Bool {
        guard library.filters.count > maximumFilters, id != library.activeFilterID else { return false }
        let nonActive = library.filters.map(\.id).filter { $0 != library.activeFilterID }
        return !nonActive.prefix(max(maximumFilters - 1, 0)).contains(id)
    }

    /// Rejects blank or duplicate names, allowing a rename to retain its own name.
    public func isNameAvailable(_ name: String, excluding excludedID: String? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !library.filters.contains { filter in
            filter.id != excludedID
                && filter.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
    }
}
