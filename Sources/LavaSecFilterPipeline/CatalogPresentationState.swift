import Foundation

/// Localization-free catalog state for app-side presentation mapping.
///
/// The filter pipeline classifies raw catalog facts but deliberately does not own icons,
/// colors, localized strings, or relative-date formatting. App and controller code map these
/// stable states to platform-specific presentation.
public struct CatalogPresentationState: Equatable, Sendable {
    /// Whether cached catalog data is present and eligible for fresh presentation.
    public enum Freshness: Equatable, Sendable {
        /// No cached catalog age is available.
        case missing
        /// Cached data is nonnegative in age and younger than the maximum age.
        case fresh
        /// Cached data has a negative age or has reached the maximum age.
        case stale
        /// The current catalog status is an error, regardless of cached data age.
        case error
    }

    /// The user-initiated catalog synchronization phase.
    public enum Sync: Equatable, Sendable {
        /// No synchronization is active and there is no result to emphasize.
        case idle
        /// A synchronization is currently in flight.
        case syncing
        /// The latest synchronization succeeded.
        case succeeded
        /// The latest synchronization failed.
        case failed
    }

    /// A rule count classified for singular and plural presentation.
    public enum RuleCount: Equatable, Sendable {
        /// The catalog selection contains no rules.
        case zero
        /// The catalog selection contains exactly one rule.
        case one
        /// The catalog selection contains two or more rules.
        case many(Int)
    }

    /// The catalog's classified cache freshness.
    public let freshness: Freshness
    /// The caller-supplied synchronization phase.
    public let sync: Sync
    /// The catalog's classified rule count.
    public let ruleCount: RuleCount

    /// Classifies catalog facts without producing user-facing copy.
    ///
    /// - Parameters:
    ///   - cacheAge: Age of the cached catalog, or `nil` when no cache age is available.
    ///   - maxAge: Maximum accepted age. An age equal to this boundary is stale.
    ///   - statusIsError: Whether the current catalog status represents an error.
    ///   - sync: The current synchronization phase.
    ///   - ruleCount: Nonnegative number of rules represented by the presentation.
    public init(
        cacheAge: TimeInterval?,
        maxAge: TimeInterval = BlocklistCatalogFreshnessPolicy.oneWeekEvaluationWindow,
        statusIsError: Bool,
        sync: Sync,
        ruleCount: Int
    ) {
        precondition(ruleCount >= 0, "Catalog rule count must be nonnegative")

        if statusIsError {
            freshness = .error
        } else if cacheAge == nil {
            freshness = .missing
        } else if BlocklistCatalogFreshnessPolicy(maxAge: maxAge)
            .isFresh(age: cacheAge, statusIsError: false)
        {
            freshness = .fresh
        } else {
            freshness = .stale
        }

        self.sync = sync
        switch ruleCount {
        case 0:
            self.ruleCount = .zero
        case 1:
            self.ruleCount = .one
        default:
            self.ruleCount = .many(ruleCount)
        }
    }
}
