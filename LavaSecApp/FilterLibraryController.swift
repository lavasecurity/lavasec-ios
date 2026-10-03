import Combine
import Foundation
import LavaSecKit
import LavaSecPresentation

/// Temporary native transaction port for the library presentation cut. It exposes
/// read-only inputs and complete operations; persistence and replacement gates
/// stay with their existing authority until the 1D transaction extraction.
@MainActor
protocol FilterLibraryHubBridging: AnyObject {
    var library: FilterLibrary { get }
    var libraryMaximumFilters: Int { get }
    var libraryHasPlus: Bool { get }
    var libraryChanges: AnyPublisher<Void, Never> { get }
    func filterRuleCount(for filter: Filter) -> Int
    func beginCreatingFilter(duplicatingFilterID: String?) -> String?
    func createFilter(name: String, duplicatingFilterID: String?) -> String?
    func renameFilter(id: String, to name: String, emoji: String?) -> Bool
    func deleteFilter(id: String) -> Bool
    func commitLibraryEdit(_ session: FilterLibraryEditSession) -> Bool
    func restoreFiltersToDefault()
    func applyLibraryFilter(id: String) async
    func beginViewingFilterDetail(id: String?)
    func endViewingFilterDetail()
}

/// One library screen's presentation owner. A navigation pop releases its editing
/// session; sheets/auth covers retain it. No accepted native task is owned here.
@MainActor
final class FilterLibraryController: ObservableObject {
    private weak var hub: (any FilterLibraryHubBridging)?
    private var observation: AnyCancellable?
    @Published private(set) var editSession = FilterLibraryEditSession()

    init(hub: any FilterLibraryHubBridging) {
        self.hub = hub
        observation = hub.libraryChanges.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var filters: [Filter] { isEditing ? editSession.displayedFilters : hub?.library.filters ?? [] }
    var hasChanges: Bool { editSession.hasChanges }
    var activeFilterID: String? { hub?.library.activeFilterID }
    var maximumFilters: Int { hub?.libraryMaximumFilters ?? 0 }
    var hasPlus: Bool { hub?.libraryHasPlus ?? false }
    var isEditing: Bool { editSession.isEditing }
    var stagedDeletions: Set<String> { editSession.stagedDeletions }
    var stagedDeletionNames: [String] {
        filters.filter { stagedDeletions.contains($0.id) }.map(\.name)
    }

    private var accessPolicy: FilterLibraryAccessPolicy? {
        guard let hub else { return nil }
        return FilterLibraryAccessPolicy(library: hub.library, maximumFilters: hub.libraryMaximumFilters)
    }

    // The creation sheet still saves through the hub immediately. A pending
    // deletion does not free its slot until Review commits it.
    var canCreateFilter: Bool { filters.count < maximumFilters }
    var canBeginCreatingFilter: Bool { canCreateFilter && !hasChanges }
    func isFilterFrozen(_ id: String) -> Bool {
        if editSession.additions.contains(where: { $0.id == id }) { return false }
        return accessPolicy?.isFrozen(id) ?? true
    }
    func isFilterNameAvailable(_ name: String, excluding id: String? = nil) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !filters.filter { $0.id != id && !stagedDeletions.contains($0.id) }.contains { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
    }
    func filterRuleCount(for filter: Filter) -> Int { hub?.filterRuleCount(for: filter) ?? 0 }

    func setEditing(_ editing: Bool) {
        if editing { editSession.beginEditing(library: hub?.library) } else { editSession.endEditing() }
    }
    func toggleStagedDeletion(_ id: String) { editSession.toggleDeletion(id) }

    /// Commit once, after reviewing all additions, names, and removals.
    @discardableResult
    func commitStagedDeletions() -> Bool {
        guard hub?.commitLibraryEdit(editSession) == true else { return false }
        editSession.endEditing()
        return true
    }

    func beginCreatingFilter(duplicatingFilterID: String?) -> String? {
        guard canBeginCreatingFilter else { return nil }
        return hub?.beginCreatingFilter(duplicatingFilterID: duplicatingFilterID)
    }

    @discardableResult
    func createFilter(name: String, duplicatingFilterID: String?) -> String? {
        guard isEditing, canCreateFilter, isFilterNameAvailable(name) else { return nil }
        let source = filters.first { $0.id == duplicatingFilterID }
        let filter = Filter(id: "filter-\(UUID().uuidString)", name: name,
                            enabledBlocklistIDs: source?.enabledBlocklistIDs ?? [],
                            customBlocklists: source?.customBlocklists ?? [],
                            blockedDomains: source?.blockedDomains ?? [], allowedDomains: source?.allowedDomains ?? [])
        editSession.add(filter)
        return filter.id
    }
    @discardableResult
    func renameFilter(id: String, to name: String, emoji: String) -> Bool {
        guard isEditing, let filter = filters.first(where: { $0.id == id }),
              !isFilterFrozen(id), !stagedDeletions.contains(id),
              isFilterNameAvailable(name, excluding: id),
              FilterIdentityPolicy.nameForEdit(name, savedName: filter.name) != nil,
              FilterIdentityPolicy.isValidEmoji(emoji) else { return false }
        // Retain the draft even when the sheet saves an unchanged identity.
        editSession.rename(filter.id, to: name, emoji: emoji)
        return true
    }
    func restoreFiltersToDefault() {
        guard !hasChanges else { return }
        hub?.restoreFiltersToDefault()
        editSession.endEditing()
    }
    func switchToFilter(id: String) async { await hub?.applyLibraryFilter(id: id) }
    func beginViewingFilterDetail(id: String?) { hub?.beginViewingFilterDetail(id: id) }
    func endViewingFilterDetail() { hub?.endViewingFilterDetail() }
}
