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
    /// How many filters the user can host (the multi-filter library). Free tier = the three
    /// seeded default filters (Core / Balanced / Extra); Plus = up to 10. On downgrade, filters
    /// beyond the free cap are *frozen* (kept, read-only, can't be switched to) — never deleted —
    /// mirroring the cache-only freeze used for extra custom blocklists.
    public let maxFilters: Int

    /// Whether the tier has no practical filter ceiling. No tier is currently unlimited (Plus is
    /// capped at 10), so this is false everywhere; kept for the count/messaging seams and in case
    /// a future tier lifts the cap. The count gate uses `maxFilters` directly.
    public var hasUnlimitedFilters: Bool { maxFilters == .max }

    public init(
        maxAllowedDomains: Int,
        maxBlockedDomains: Int,
        maxFilterRules: Int,
        allowsCustomBlocklists: Bool,
        allowsCustomDNS: Bool,
        maxFilters: Int = 3
    ) {
        self.maxAllowedDomains = maxAllowedDomains
        self.maxBlockedDomains = maxBlockedDomains
        self.maxFilterRules = maxFilterRules
        self.allowsCustomBlocklists = allowsCustomBlocklists
        self.allowsCustomDNS = allowsCustomDNS
        self.maxFilters = maxFilters
    }

    public static let free = FeatureLimits(
        maxAllowedDomains: 25,
        maxBlockedDomains: 25,
        maxFilterRules: 500_000,
        allowsCustomBlocklists: false,
        allowsCustomDNS: false,
        maxFilters: 3
    )

    public static let paid = FeatureLimits(
        maxAllowedDomains: 1_000,
        maxBlockedDomains: 1_000,
        maxFilterRules: 2_000_000,
        allowsCustomBlocklists: true,
        allowsCustomDNS: true,
        maxFilters: 10
    )

    public static let plus = paid
}
