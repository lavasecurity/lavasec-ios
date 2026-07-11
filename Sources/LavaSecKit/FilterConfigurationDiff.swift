import Foundation

/// The three filter-selection fields compared when presenting configuration changes.
public struct FilterConfigurationSelection: Equatable, Sendable {
    /// Curated blocklist identifiers enabled by the selection.
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
