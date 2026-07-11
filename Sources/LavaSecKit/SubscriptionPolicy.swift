import Foundation

/// Resource and customization ceilings associated with a subscription tier.
public struct FeatureLimits: Equatable, Codable, Sendable {
    /// Maximum number of user-authored allow-domain rules.
    public let maxAllowedDomains: Int
    /// Maximum number of user-authored block-domain rules.
    public let maxBlockedDomains: Int
    /// Tier ceiling on total compiled filter rules across all enabled blocklists
    /// (the user-facing budget). Replaces the old blocklist *count* cap — rules
    /// are the honest resource (memory) and let users pick any mix that fits.
    /// The hard device guardrail (`FilterSnapshotMemoryBudget.maxFilterRuleCount`)
    /// sits above this for everyone.
    public let maxFilterRules: Int
    /// Whether user-provided blocklist sources may be added.
    public let allowsCustomBlocklists: Bool
    /// Whether a custom DNS resolver may be configured.
    public let allowsCustomDNS: Bool
    /// How many filters the user can host (the multi-filter library). Free tier = the three
    /// seeded default filters (Core / Balanced / Extra); Plus = up to 50. On downgrade, filters
    /// beyond the free cap are *frozen* (kept, read-only, can't be switched to) — never deleted —
    /// mirroring the cache-only freeze used for extra custom blocklists.
    public let maxFilters: Int

    /// Whether the tier has no practical filter ceiling. No tier is currently unlimited (Plus is
    /// capped at 50), so this is false everywhere; kept for the count/messaging seams and in case
    /// a future tier lifts the cap. The count gate uses `maxFilters` directly.
    public var hasUnlimitedFilters: Bool { maxFilters == .max }

    /// Creates an explicit set of tier limits without clamping or cross-field validation.
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

    /// Limits applied to the free tier.
    public static let free = FeatureLimits(
        maxAllowedDomains: 25,
        maxBlockedDomains: 25,
        maxFilterRules: 500_000,
        allowsCustomBlocklists: false,
        allowsCustomDNS: false,
        maxFilters: 3
    )

    /// Limits applied to the paid tier.
    public static let paid = FeatureLimits(
        maxAllowedDomains: 1_000,
        maxBlockedDomains: 1_000,
        maxFilterRules: 2_000_000,
        allowsCustomBlocklists: true,
        allowsCustomDNS: true,
        maxFilters: 50
    )

    /// The Lava Security Plus limits, currently identical to ``paid``.
    public static let plus = paid
}
