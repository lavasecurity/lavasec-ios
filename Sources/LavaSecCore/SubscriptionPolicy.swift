import Foundation

public struct FeatureLimits: Equatable, Codable, Sendable {
    public let maxAllowedDomains: Int
    public let maxBlockedDomains: Int
    /// Tier ceiling on total compiled filter rules across all enabled blocklists
    /// (the user-facing budget). Replaces the old blocklist *count* cap — rules
    /// are the honest resource (memory) and let users pick any mix that fits.
    /// The hard device guardrail (`FilterSnapshotMemoryBudget.maxFilterRuleCount`)
    /// sits above this for everyone.
    public let maxFilterRules: Int
    public let allowsCustomBlocklists: Bool
    public let allowsCustomDNS: Bool

    public init(
        maxAllowedDomains: Int,
        maxBlockedDomains: Int,
        maxFilterRules: Int,
        allowsCustomBlocklists: Bool,
        allowsCustomDNS: Bool
    ) {
        self.maxAllowedDomains = maxAllowedDomains
        self.maxBlockedDomains = maxBlockedDomains
        self.maxFilterRules = maxFilterRules
        self.allowsCustomBlocklists = allowsCustomBlocklists
        self.allowsCustomDNS = allowsCustomDNS
    }

    public static let free = FeatureLimits(
        maxAllowedDomains: 25,
        maxBlockedDomains: 25,
        maxFilterRules: 500_000,
        allowsCustomBlocklists: false,
        allowsCustomDNS: false
    )

    public static let paid = FeatureLimits(
        maxAllowedDomains: 1_000,
        maxBlockedDomains: 1_000,
        maxFilterRules: 2_000_000,
        allowsCustomBlocklists: true,
        allowsCustomDNS: true
    )

    public static let plus = paid
}
