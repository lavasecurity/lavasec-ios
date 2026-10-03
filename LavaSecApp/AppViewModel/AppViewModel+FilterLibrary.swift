import Darwin
import Foundation
import SwiftUI
import UIKit
@preconcurrency import CoreHaptics
@preconcurrency import NetworkExtension
@preconcurrency import UserNotifications
import LavaSecKit
import LavaSecPresentation
import LavaSecFilterPipeline
import LavaSecAppServices

// One concern of `AppViewModel`, split out of the former single-file view model.
// Stored state (`@Published` and otherwise) lives in LavaSecApp/AppViewModel.swift (extensions
// cannot declare stored properties); every file under AppViewModel/ is one `// MARK:` section.

extension AppViewModel {
    // MARK: - Multi-filter library

    private var filterLibraryAccessPolicy: FilterLibraryAccessPolicy {
        FilterLibraryAccessPolicy(library: library, maximumFilters: configuration.limits.maxFilters)
    }

    /// Whether the user can create another filter. Free holds up to three (the seeded
    /// Core / Balanced / Extra defaults); Plus hosts up to 10. The "+ new filter" affordance
    /// gates on this — a free user at the cap trips the paywall, a Plus user at the cap sees a
    /// "maximum reached" note.
    var canCreateFilter: Bool {
        filterLibraryAccessPolicy.canCreate
    }

    /// A filter is *frozen* when the user holds more filters than their tier allows (Plus
    /// lapsed): the excess non-active filters are kept and readable but cannot be switched to.
    /// The active filter is never frozen, and a library that fits the cap (e.g. Free with its
    /// three seeded filters) freezes nothing — all are switchable.
    func isFilterFrozen(_ id: String) -> Bool {
        if filterDrafts.sessions.newFilter?.id == id { return false }
        return filterLibraryAccessPolicy.isFrozen(id)
    }

    /// The library's filters in order, for the All-filters list.
    var filters: [Filter] {
        library.filters
    }

    var activeFilterID: String {
        library.activeFilterID
    }

    func filter(id: String) -> Filter? {
        filterDrafts.sessions.newFilter.flatMap { $0.id == id ? $0 : nil } ?? library.filter(id: id)
    }

    /// Whether `name` is free to use for a filter — no other filter already has it (trimmed,
    /// case-insensitive). `excluding` skips one filter (the one being renamed). A blank name is
    /// never "available" (the UI requires a non-empty name). Filter names are unique so the All
    /// filters list, the share/import pickers, and the import "add as new" flow never show two
    /// indistinguishable rows.
    func isFilterNameAvailable(_ name: String, excluding excludedID: String? = nil) -> Bool {
        filterLibraryAccessPolicy.isNameAvailable(name, excluding: excludedID)
    }

    /// A filter name based on `base` that isn't already taken: `base`, then "base 2", "base 3"… .
    /// Used when a name is derived (duplicate / import default) rather than user-entered.
    ///
    /// Delegates to ``SharedFilterNamePolicy`` so derived names and imported shared-filter names
    /// cannot drift into two different numbering conventions. The empty-base fallback stays here
    /// because the policy lives in a package that deliberately does not localize.
    /// pinned: SharedFilterNamePolicyTests.testMatchesTheAppsExistingDerivedNameConvention
    func uniqueFilterName(basedOn base: String, excludingFilterID excludedID: String? = nil) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.isEmpty ? "Filter".lavaLocalized : trimmed
        return SharedFilterNamePolicy.nextAvailableName(
            base: root,
            existingNames: library.filters
                .filter { $0.id != excludedID }
                .map(\.name)
        )
    }

    /// Creation is an editor session, not a saved placeholder. The saved library,
    /// active filter, shortcuts and backup remain unchanged until its first save.
    func beginCreatingFilter(duplicatingFilterID: String?) -> String? {
        guard canCreateFilter else { return nil }
        if let id = duplicatingFilterID, library.filter(id: id) == nil { return nil }
        let name = SharedFilterNamePolicy.nextAvailableName(base: "Untitled".lavaLocalized,
            existingNames: library.filters.map(\.name), numberedFromOne: true)
        let source = duplicatingFilterID.flatMap { library.filter(id: $0) }
        let filter = Filter(id: "filter-\(UUID().uuidString)", name: name,
            enabledBlocklistIDs: source?.enabledBlocklistIDs ?? [],
            customBlocklists: source?.customBlocklists ?? [],
            blockedDomains: source?.blockedDomains ?? [], allowedDomains: source?.allowedDomains ?? [])
        var baseline = configuration
        baseline.enabledBlocklistIDs = filter.enabledBlocklistIDs
        baseline.customBlocklists = filter.customBlocklists
        baseline.blockedDomains = filter.blockedDomains
        baseline.allowedDomains = filter.allowedDomains
        filterDrafts.beginCreating(filter, baseline: baseline)
        return filter.id
    }

    /// Revalidate the cap and identity at the write boundary. A failed write keeps
    /// the complete draft available for retry and cannot publish a placeholder.
    func saveNewFilterDraft() -> String? {
        guard var filter = filterDrafts.sessions.newFilter,
              let draft = filterDrafts.sessions.drafts[filter.id] else { return "This filter is no longer available." }
        guard canCreateFilter else { return "Maximum filters reached" }
        guard isFilterNameAvailable(filter.name) else { return "You already have a filter with that name." }
        if let rejection = filterDraftValidationMessage { return rejection }
        filter.enabledBlocklistIDs = draft.enabledBlocklistIDs
        filter.customBlocklists = draft.customBlocklists
        filter.blockedDomains = draft.blockedDomains
        filter.allowedDomains = draft.allowedDomains
        let previous = library
        library.append(filter)
        guard persistLibraryOnlyChange(rollingBackTo: previous) else { return "Couldn't save your changes. Please try again." }
        filterDrafts.completeCreation()
        ProtectionHapticFeedback.play(.actionSucceeded)
        Task { await warmFilterArtifact(forFilterID: filter.id) }
        return nil
    }

    /// Create a new filter, optionally duplicating an existing one's contents. Writes
    /// the library only (a new filter is never the active one, so nothing compiles or
    /// republishes). Returns the new filter's id, or `nil` if blocked (at the filter cap, a
    /// duplicate name, or a persistence failure). Callers gate on ``canCreateFilter`` first to
    /// show the paywall, and validate the name with ``isFilterNameAvailable`` so the duplicate
    /// rejection here is a backstop, not the primary UX.
    @discardableResult
    func createFilter(name: String, duplicatingFilterID: String? = nil) -> String? {
        guard canCreateFilter else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // An explicit name must be unique (UI enforces; reject as a backstop). A blank name derives
        // a unique default from the duplicated filter (or a generic base).
        let resolvedName: String
        if trimmed.isEmpty {
            let base = duplicatingFilterID
                .flatMap { library.filter(id: $0)?.name }
                .map(duplicateName(of:)) ?? "Filter".lavaLocalized
            resolvedName = uniqueFilterName(basedOn: base)
        } else {
            guard FilterIdentityPolicy.isValidName(name), isFilterNameAvailable(trimmed) else { return nil }
            resolvedName = trimmed
        }
        let newID = "filter-\(UUID().uuidString)"
        let newFilter: Filter
        if let duplicatingFilterID, let source = library.filter(id: duplicatingFilterID) {
            newFilter = Filter(
                id: newID,
                name: resolvedName,
                enabledBlocklistIDs: source.enabledBlocklistIDs,
                customBlocklists: source.customBlocklists,
                blockedDomains: source.blockedDomains,
                allowedDomains: source.allowedDomains
            )
        } else {
            newFilter = Filter(id: newID, name: resolvedName)
        }
        let previousLibrary = library
        library.append(newFilter)
        guard persistLibraryOnlyChange(rollingBackTo: previousLibrary) else { return nil }
        // Warm the new (non-active) filter off the hot path so a later switch — manual or a
        // Focus auto-switch — is an instant pointer flip, not a cold compile. Fire-and-forget:
        // creation stays library-only/non-blocking, and warmFilterArtifact never republishes or
        // touches the live tunnel/pointer (it only stages the new filter's own artifact dir). A switch
        // arriving before the token is stamped just cold-compiles (a rare, self-healing redundant compile).
        Task { await warmFilterArtifact(forFilterID: newID) }
        return newID
    }

    /// Publish a complete reviewed library batch through the existing locked persistence funnel.
    func commitLibraryEdit(_ session: FilterLibraryEditSession) -> Bool {
        guard let next = session.validatedLibrary(current: library, maximumFilters: configuration.limits.maxFilters) else { return false }
        let previous = library
        library = next
        guard persistLibraryOnlyChange(rollingBackTo: previous) else { return false }
        for filter in session.additions { Task { await warmFilterArtifact(forFilterID: filter.id) } }
        return true
    }

    /// Persist a library-only mutation (create / rename / delete) and schedule an encrypted
    /// backup, so hosted filters are captured by the backup the same way config changes are.
    /// The caller has ALREADY applied its mutation to the in-memory `library`; `previousLibrary`
    /// is the pre-mutation snapshot so a failed write can be rolled back.
    @discardableResult
    func persistLibraryOnlyChange(
        rollingBackTo previousLibrary: FilterLibrary,
        refusesIfOnDiskActiveFilterIs: String? = nil
    ) -> Bool {
        guard (try? persistFilterLibrary(refusesIfOnDiskActiveFilterIs: refusesIfOnDiskActiveFilterIs)) != nil else {
            // A failed write must not leave the mutation live in the published library: the UI
            // would show a change reported as failed, and a later successful config write
            // (persistSharedState) would persist it. Roll back so the in-memory library matches
            // what actually reached disk.
            library = previousLibrary
            return false
        }
        backup.scheduleAutomaticBackupAfterConfigurationChange()
        // (The "Switch Filter" App Shortcut parameter is refreshed by refreshFilterSwitchShortcutAfterPersist,
        // called from the shared persist funnels AFTER the library reaches disk — this path routed through
        // persistFilterLibrary → persistConfigurationOnly above — Codex #325.)
        return true
    }

    /// Rename a filter (library-only; no recompile). No-ops on a blank name, unknown id, a
    /// duplicate name (filter names are unique), or a frozen (lapsed-Plus, read-only) filter —
    /// enforced here, below the UI, so a stale sheet or a direct caller can't mutate a frozen
    /// filter or create a name collision.
    @discardableResult
    func renameFilter(id: String, to name: String, emoji: String? = nil) -> Bool {
        if filterDrafts.sessions.newFilter?.id == id {
            guard FilterIdentityPolicy.isValidName(name), emoji.map(FilterIdentityPolicy.isValidEmoji) ?? true,
                  isFilterNameAvailable(name, excluding: id) else { return false }
            filterDrafts.renameNewFilter(name: FilterIdentityPolicy.normalizedName(name),
                emoji: emoji ?? filterDrafts.sessions.newFilter!.emoji)
            return true
        }
        guard let saved = library.filter(id: id),
              let resolvedName = FilterIdentityPolicy.nameForEdit(name, savedName: saved.name),
              emoji.map(FilterIdentityPolicy.isValidEmoji) ?? true,
              !isFilterFrozen(id),
              isFilterNameAvailable(resolvedName, excluding: id) else { return false }
        let previousLibrary = library
        library.mutateFilter(id: id) {
            $0.name = resolvedName
            if let emoji { $0.emoji = emoji }
        }
        return persistLibraryOnlyChange(rollingBackTo: previousLibrary)
    }

    /// Delete a filter. Refuses the in-effect filter (switch first), the last remaining
    /// filter (the ≥1 invariant), and a frozen (read-only) filter — the freeze is enforced
    /// here, below the UI. Library-only; no recompile. Returns whether a deletion happened.
    @discardableResult
    func deleteFilter(id: String) -> Bool {
        guard !isFilterFrozen(id) else { return false }
        let previousLibrary = library
        guard library.remove(id: id) else { return false }
        guard persistLibraryOnlyChange(rollingBackTo: previousLibrary) else { return false }
        // Drop the deleted filter's per-filter draft (its key is gone).
        filterDrafts.setDraft(nil, for: id)
        return true
    }

    /// "Restore to default": reset the library to the three seeded default filters
    /// (Core / Balanced / Extra) with Balanced loaded. Mirrors Balanced into the live config and
    /// persists via the normal config-edit path — `persistSharedState` writes config + library
    /// together at one bumped generation and reloads the tunnel, so this never trips the
    /// library/config write-race. Replaces any custom filters the user made (a deliberate reset,
    /// gated behind a confirm dialog in the UI).
    func restoreFiltersToDefault() {
        // Restore is a wholesale config+library replacement, so it must claim the replacement
        // gate like switch/import/restore-backup/draft-apply: advancing the epoch makes any
        // in-flight replacer (e.g. a switch suspended at its prepare) bail at its commit instead
        // of silently reverting this restore.
        _ = configurationReplacementGate.begin()
        // Like every other foreground config writer, this can race a headless Focus commit. The cross-process
        // write lock + generation fence (SharedFilterStatePersistence, taken by both sides) make that safe —
        // the loser aborts cleanly — and the headless path records its pending-switch marker first, so the
        // foreground reconcile re-applies any Focus target afterward (last-writer-wins, never wrong rules or a
        // wedge). No per-writer bracketing or foreground-active gating needed.
        // This supersedes any in-flight warm switch and drives its own coverage below (rebuild from
        // cache + startOnboardingDefaultBlocklistSyncIfNeeded fills any missing source), so the
        // superseded warm switch's stale-cache deferral no longer applies — clear it (the superseded
        // rehydration will bail without clearing). Otherwise a warm switch whose target's sources were
        // all already cached would leave the flag wrongly stuck after this reseed.
        hasPendingWarmSwitchCacheRehydration = false
        // The whole library is reseeded, so every per-filter draft + the detail target are now
        // invalid — wipe them so a preserved edit can't resume over a freshly seeded filter.
        filterDrafts.resetSessions()
        library = .seededDefaults(active: .balanced)
        // An EXPLICIT user reset lifts the launch-reseed automatic-backup suppression — but the
        // DURABLE marker drops only AFTER the reseed pair reaches disk, exactly like
        // restoreFromBackup (INV-PERSIST-2 marker consequence). Lift the IN-MEMORY flag now so this
        // persist's backup hook runs unsuppressed (the user chose these defaults, so they belong in
        // the next sealed envelope); a persist that fails BEFORE the pair lands must keep the durable
        // marker, or the next launch reads the un-replaced on-disk reseed as user-authoritative
        // (.absentConfirmed) and automatic backup clobbers the last good server copy — the same
        // hazard restoreFromBackup defers its marker drop to avoid (Codex P1 round 4 on #376).
        // Clearing the durable marker BEFORE the write, as this path used to, reopened that window:
        // post-#385 a durable file-marker clear definitely lands (unlike the pre-#385 best-effort
        // Class-C key it replaced), so a failed reset persist now reliably strands the on-disk
        // reseed with no marker.
        // pinned: RebootFirstUnlockGuardSourceTests.testExplicitReseedDefersDurableMarkerDropUntilPersistLands
        libraryOriginatesFromLaunchReseed = false
        mirrorActiveFilterIntoConfiguration()
        rebuildEnabledBlockRules()
        persistFilterReseedDroppingDurableMarkerWhenLanded()
        // Balanced may enable a curated source not yet cached on this device — fetch any missing
        // ones so the published snapshot covers Balanced rather than under-covering until a later
        // sync (the onboarding/switch paths do the same).
        startOnboardingDefaultBlocklistSyncIfNeeded()
    }

    /// Switch the active filter: mirror the target's four fields into the live config,
    /// prepare + publish, and reload the tunnel. A cold target shows the preparation
    /// screen ("Applying protection…"); on failure the previously-loaded filter is kept
    /// (never a half-applied state). Refuses a no-op, an unknown id, or a frozen filter.
}
