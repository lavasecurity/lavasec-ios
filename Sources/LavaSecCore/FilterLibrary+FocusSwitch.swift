import Foundation

/// Pure `FilterLibrary` operations shared by the foreground switch (`AppViewModel`) and the headless
/// Focus engine (`HeadlessFocusFilterSwitchEngine`). Relocating these out of `AppViewModel` (LAV-100
/// Phase 4) is what lets the switch engine run with NO `AppViewModel` while keeping ONE definition of
/// each rule — so the two execution contexts can never drift on switch semantics, the freeze rule, or
/// warm-artifact GC retention.
public extension FilterLibrary {
    /// Write-through the active filter's four scoped fields from `configuration` (the persist-boundary
    /// sync). Repairs a dangling active id by normalizing first. Returns whether the library actually
    /// changed, so a `@Published` caller can avoid churning state on the common no-op. If the fields
    /// changed, the active filter's cached compile token is cleared (it is now stale).
    ///
    /// Was `AppViewModel.syncActiveFilterFromConfiguration()`; now a pure mutation so the headless
    /// engine and the foreground persist paths share one definition.
    @discardableResult
    mutating func syncActiveFilter(from configuration: AppConfiguration) -> Bool {
        // The active id should always resolve (normalized on load + invariant-preserving mutations),
        // but repair a dangling id rather than silently skipping the sync — a skipped sync would drift
        // the config and the library apart permanently.
        if filter(id: activeFilterID) == nil {
            self = normalized()
        }
        guard var active = filter(id: activeFilterID) else { return false }
        // Only report a change when the four fields actually moved — a no-op persist (the common case
        // for device-global edits) must not churn the caller's published state.
        guard active.applyFilterFields(from: configuration) else { return false }
        active.lastCompiledToken = nil
        update(active)
        return true
    }

    /// Whether `filterID` is frozen — i.e. excluded by the tier filter cap (`maxFilters`) and therefore
    /// not switchable. The active filter takes one slot; the first `cap - 1` other filters by order stay
    /// usable, the rest freeze. Was `AppViewModel.isFilterFrozen(_:)`.
    func isFrozen(filterID id: String, maxFilters cap: Int) -> Bool {
        guard filters.count > cap, id != activeFilterID else { return false }
        let nonActive = filters.map(\.id).filter { $0 != activeFilterID }
        return !nonActive.prefix(max(cap - 1, 0)).contains(id)
    }

    /// The versioned-artifact tokens to keep warm across a publish: the active filter's token first (the
    /// most likely switch-back target), then every NON-frozen hosted filter's `lastCompiledToken`, then
    /// the sidecar warm-index entries for filters that still exist and are switchable. Keeping all of
    /// them warm makes a switch to ANY filter an instant pointer flip rather than a cold compile. Was
    /// `AppViewModel.retainedFilterArtifactTokens()`.
    func retainedWarmArtifactTokens(
        maxFilters cap: Int,
        backgroundWarmIndex: BackgroundWarmIndex
    ) -> [String] {
        let activeID = activeFilterID
        var tokens: [String] = []
        if let activeToken = filter(id: activeID)?.lastCompiledToken {
            tokens.append(activeToken)
        }
        for f in filters where f.id != activeID {
            guard !isFrozen(filterID: f.id, maxFilters: cap), let token = f.lastCompiledToken else { continue }
            tokens.append(token)
        }
        // A background-warmed dir is referenced ONLY by the sidecar warm-index until the foreground
        // promotes it into the library, so retain those tokens too. Retain ONLY entries for filters that
        // still exist and are switchable (the foreground doesn't rewrite the sidecar on delete/freeze).
        for (filterID, entry) in backgroundWarmIndex.entries
        where filter(id: filterID) != nil && !isFrozen(filterID: filterID, maxFilters: cap) {
            tokens.append(entry.token)
        }
        return tokens
    }
}
