import Foundation

public struct FilterConfigurationSelection: Equatable, Sendable {
    public var enabledBlocklistIDs: Set<String>
    public var blockedDomains: Set<String>
    public var allowedDomains: Set<String>

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

public struct FilterConfigurationDiff: Equatable, Sendable {
    public let addedBlocklistIDs: [String]
    public let removedBlocklistIDs: [String]
    public let addedBlockedDomains: [String]
    public let removedBlockedDomains: [String]
    public let addedAllowedDomains: [String]
    public let removedAllowedDomains: [String]

    public init(from old: FilterConfigurationSelection, to new: FilterConfigurationSelection) {
        addedBlocklistIDs = Self.sorted(new.enabledBlocklistIDs.subtracting(old.enabledBlocklistIDs))
        removedBlocklistIDs = Self.sorted(old.enabledBlocklistIDs.subtracting(new.enabledBlocklistIDs))
        addedBlockedDomains = Self.sorted(new.blockedDomains.subtracting(old.blockedDomains))
        removedBlockedDomains = Self.sorted(old.blockedDomains.subtracting(new.blockedDomains))
        addedAllowedDomains = Self.sorted(new.allowedDomains.subtracting(old.allowedDomains))
        removedAllowedDomains = Self.sorted(old.allowedDomains.subtracting(new.allowedDomains))
    }

    public var isEmpty: Bool {
        addedBlocklistIDs.isEmpty
            && removedBlocklistIDs.isEmpty
            && addedBlockedDomains.isEmpty
            && removedBlockedDomains.isEmpty
            && addedAllowedDomains.isEmpty
            && removedAllowedDomains.isEmpty
    }

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

public extension AppConfiguration {
    var filterSelection: FilterConfigurationSelection {
        FilterConfigurationSelection(
            enabledBlocklistIDs: enabledBlocklistIDs,
            blockedDomains: blockedDomains,
            allowedDomains: allowedDomains
        )
    }
}
