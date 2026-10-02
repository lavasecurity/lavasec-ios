import Foundation

/// The three filter-selection fields compared when presenting configuration changes.
public struct FilterConfigurationSelection: Equatable, Sendable {
    /// Curated and custom blocklist identifiers enabled by the selection.
    public private(set) var enabledBlocklistIDs: Set<String>
    /// User-authored domain rules blocked by the selection.
    public private(set) var blockedDomains: Set<String>
    /// User-authored domain rules allowed by the selection.
    public private(set) var allowedDomains: Set<String>

    /// Creates a selection snapshot from its blocklist and domain-rule sets.
    public init(
        enabledBlocklistIDs: Set<String>,
        blockedDomains: Set<String>,
        allowedDomains: Set<String>
    ) {
        self.enabledBlocklistIDs = enabledBlocklistIDs
        self.blockedDomains = blockedDomains
        self.allowedDomains = allowedDomains
    }
}

/// Sorted additions and removals between two filter configuration selections.
public struct FilterConfigurationDiff: Equatable, Sendable {
    /// Blocklist identifiers present only in the new selection.
    public let addedBlocklistIDs: [String]
    /// Blocklist identifiers present only in the old selection.
    public let removedBlocklistIDs: [String]
    /// Block-domain rules present only in the new selection.
    public let addedBlockedDomains: [String]
    /// Block-domain rules present only in the old selection.
    public let removedBlockedDomains: [String]
    /// Allow-domain rules present only in the new selection.
    public let addedAllowedDomains: [String]
    /// Allow-domain rules present only in the old selection.
    public let removedAllowedDomains: [String]

    /// Computes changes from `old` to `new`, sorted with `localizedStandardCompare`.
    public init(from old: FilterConfigurationSelection, to new: FilterConfigurationSelection) {
        addedBlocklistIDs = Self.sorted(new.enabledBlocklistIDs.subtracting(old.enabledBlocklistIDs))
        removedBlocklistIDs = Self.sorted(old.enabledBlocklistIDs.subtracting(new.enabledBlocklistIDs))
        addedBlockedDomains = Self.sorted(new.blockedDomains.subtracting(old.blockedDomains))
        removedBlockedDomains = Self.sorted(old.blockedDomains.subtracting(new.blockedDomains))
        addedAllowedDomains = Self.sorted(new.allowedDomains.subtracting(old.allowedDomains))
        removedAllowedDomains = Self.sorted(old.allowedDomains.subtracting(new.allowedDomains))
    }

    /// Whether every addition and removal collection is empty.
    public var isEmpty: Bool {
        addedBlocklistIDs.isEmpty
            && removedBlocklistIDs.isEmpty
            && addedBlockedDomains.isEmpty
            && removedBlockedDomains.isEmpty
            && addedAllowedDomains.isEmpty
            && removedAllowedDomains.isEmpty
    }

    /// The total number of added and removed entries across all three selection fields.
    public var changeCount: Int {
        addedBlocklistIDs.count
            + removedBlocklistIDs.count
            + addedBlockedDomains.count
            + removedBlockedDomains.count
            + addedAllowedDomains.count
            + removedAllowedDomains.count
    }

    private static func sorted(_ values: Set<String>) -> [String] {
        values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Projects an app configuration into the fields used by ``FilterConfigurationDiff``.
public extension AppConfiguration {
    /// A snapshot of this configuration's enabled blocklists and user domain rules.
    var filterSelection: FilterConfigurationSelection {
        FilterConfigurationSelection(
            enabledBlocklistIDs: enabledBlocklistIDs,
            blockedDomains: blockedDomains,
            allowedDomains: allowedDomains
        )
    }
}

/// Before/after filter content shared by import replacement and backup restore reviews.
public struct FilterReplacementSummary: Equatable, Sendable {
    /// Existing filter, or nil when adding a filter.
    public let before: Filter?
    /// Incoming filter, or nil when removing a filter.
    public let after: Filter?
    /// Curated/custom selection and manual-domain additions and removals.
    public let selectionDiff: FilterConfigurationDiff
    /// Removed or changed custom definitions, including a changed URL under an existing ID.
    public let removedCustomBlocklists: [CustomBlocklistSource]
    /// Added or changed custom definitions that the incoming filter will store.
    public let addedCustomBlocklists: [CustomBlocklistSource]

    /// Selection removals not already represented by a deleted custom source.
    public var removedBlocklistIDs: [String] {
        let described = Set(removedCustomBlocklists.map(\.id)).subtracting((after?.customBlocklists ?? []).map(\.id))
        return selectionDiff.removedBlocklistIDs.filter { !described.contains($0) }
    }

    /// Selection additions not already represented by a newly added custom source.
    public var addedBlocklistIDs: [String] {
        let described = Set(addedCustomBlocklists.map(\.id)).subtracting((before?.customBlocklists ?? []).map(\.id))
        return selectionDiff.addedBlocklistIDs.filter { !described.contains($0) }
    }

    /// Existing custom sources whose accepted content version changes during replacement.
    public var changedCustomContentVersionIDs: [String] {
        (after?.customBlocklists ?? []).compactMap { source in
            guard let previous = before?.customBlocklists.first(where: { $0.id == source.id }),
                  previous.lastAcceptedHash != source.lastAcceptedHash else { return nil }
            return source.id
        }.sorted()
    }

    /// Captures portable filter content and reuses the existing selection diff.
    public init(before: Filter?, after: Filter?) {
        self.before = before?.strippingLocalCacheState()
        self.after = after?.strippingLocalCacheState()
        let empty = FilterConfigurationSelection(enabledBlocklistIDs: [], blockedDomains: [], allowedDomains: [])
        selectionDiff = FilterConfigurationDiff(from: before?.selection ?? empty, to: after?.selection ?? empty)
        removedCustomBlocklists = (before?.customBlocklists ?? []).filter { !(after?.customBlocklists.contains($0) ?? false) }
        addedCustomBlocklists = (after?.customBlocklists ?? []).filter { !(before?.customBlocklists.contains($0) ?? false) }
    }

    /// Whether replacement adds/removes a filter, renames it or changes any filter content.
    public var hasChanges: Bool {
        before?.id != after?.id || before?.name != after?.name
            || !selectionDiff.isEmpty || !removedCustomBlocklists.isEmpty || !addedCustomBlocklists.isEmpty
    }
}
