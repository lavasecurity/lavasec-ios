import Foundation

/// Whether a queried name is covered by one of the user's own manual block/allow rules.
///
/// A diagnostic aid for the "I added a domain and it still loads" report. The manual rules are a
/// tiny, user-authored suffix set, so a per-query membership check is cheap, and — unlike logging
/// the queried domain — its result is safe to export: no name leaves the device. A logged match
/// proves a query for a covered name reached the filter, and says what the filter decided; the
/// caller dedups to at most four `(rule kind, action)` pairs, so silence before any pair is logged
/// means either the query never reached the filter (an unclaimed-resolver or DoH escape) or no rule
/// covers the name, while silence after a pair is logged also just means that pair is spent.
///
/// The cold `isCovered(normalizedDomain:by:)` form normalizes every raw rule on every call. The
/// DNS serve path must not pay that per query (the paid limits allow 1000 blocked + 1000 allowed
/// rules), so ``ManualDomainRuleSet`` normalizes a rule set ONCE and the provider rebuilds it only
/// when it adopts a new `AppConfiguration`.
public enum ManualDomainRuleMatch {
    /// The manual rule set that covers a queried name.
    public enum RuleKind: String, Sendable, CaseIterable {
        case block
        case allow
    }

    /// Whether `normalizedDomain` is covered by any manual rule: an exact match or a subdomain of
    /// one. Rules are user-authored, so each is normalized with ``DomainName`` before comparison
    /// (lowercased, leading/trailing dots removed); an unnormalizable rule is skipped rather than
    /// matching nothing at large. The leading dot in the suffix test keeps `notexample.com` from
    /// matching rule `example.com`.
    ///
    /// This is the cold, one-shot form and normalizes on every call; the serve path uses
    /// ``ManualDomainRuleSet`` so that normalization is paid once per configuration instead of
    /// once per query.
    public static func isCovered<Rules: Sequence>(
        normalizedDomain: String,
        by rules: Rules
    ) -> Bool where Rules.Element == String {
        isCovered(normalizedDomain: normalizedDomain, byNormalizedRules: normalize(rules))
    }

    /// Normalizes a raw manual rule set once for reuse across many queries. An unnormalizable rule
    /// is dropped, exactly as ``isCovered(normalizedDomain:by:)`` skips it.
    public static func normalize<Rules: Sequence>(
        _ rules: Rules
    ) -> [String] where Rules.Element == String {
        rules.compactMap { try? DomainName.normalize($0) }
    }

    /// Checks `normalizedDomain` against rules already normalized by ``normalize(_:)`` — the
    /// per-query hot path. Same exact/subdomain semantics and leading-dot guard as the cold form.
    public static func isCovered(
        normalizedDomain: String,
        byNormalizedRules rules: [String]
    ) -> Bool {
        let domain = normalizedDomain.lowercased()
        for rule in rules {
            if domain == rule || domain.hasSuffix("." + rule) {
                return true
            }
        }
        return false
    }

    /// The diagnostic owed for one filtered query, or `nil` when none is.
    ///
    /// A fail-closed decision owes nothing: `.protectionUnavailable` blocks EVERY name without
    /// consulting the manual rules (``FailClosedRuntimeSnapshot``), so a covered name is not a
    /// manual-rule match there — logging it would misattribute the block AND spend the
    /// once-per-session `(rule kind, action)` dedup slot before the real rule ever fired
    /// (Kilo review, PR #745). The fail-closed window has its own observability trace in
    /// `recordDiagnostic`.
    /// pinned: ManualDomainRuleMatchTests.testFailClosedDecisionNeverProducesManualRuleCoverage
    public static func coverage(
        normalizedDomain: String,
        for decision: FilterDecision,
        blockedRules: ManualDomainRuleSet,
        allowedRules: ManualDomainRuleSet
    ) -> RuleKind? {
        guard decision.reason != .protectionUnavailable else {
            return nil
        }
        if blockedRules.covers(normalizedDomain: normalizedDomain) {
            return .block
        }
        if allowedRules.covers(normalizedDomain: normalizedDomain) {
            return .allow
        }
        return nil
    }

    /// The number of distinct `(rule kind, action)` pairs the diagnostic can log per session:
    /// 2 rule kinds x 2 actions. Once all are logged nothing further is owed, so the serve-path
    /// helper short-circuits before scanning any rule.
    public static var loggedPairCount: Int {
        RuleKind.allCases.count * FilterAction.allCases.count
    }
}

/// A user's manual rules, normalized once and reused across DNS queries.
///
/// `isCovered(normalizedDomain:by:)` normalizes every raw rule on every call — up to 2000
/// normalizations per query at the paid limits (1000 blocked + 1000 allowed). `PacketTunnelProvider`
/// holds one of these per rule kind and rebuilds it only when it adopts a new `AppConfiguration`
/// (`setAppConfiguration`), the single assignment site of the live configuration, so the per-query
/// path is a suffix scan over already-normalized strings rather than a per-query normalization.
public struct ManualDomainRuleSet: Sendable {
    /// The rules after ``ManualDomainRuleMatch/normalize(_:)``; unnormalizable raw rules are absent.
    public let normalizedRules: [String]

    /// Normalizes a raw rule set (order-insensitive; each rule becomes a lowercased hostname).
    public init<Rules: Sequence>(rawRules: Rules) where Rules.Element == String {
        normalizedRules = ManualDomainRuleMatch.normalize(rawRules)
    }

    /// Whether `normalizedDomain` is covered: an exact match or a subdomain of any rule.
    public func covers(normalizedDomain: String) -> Bool {
        ManualDomainRuleMatch.isCovered(
            normalizedDomain: normalizedDomain,
            byNormalizedRules: normalizedRules
        )
    }
}

/// An immutable snapshot of the two normalized manual rule sets.
///
/// A DNS query reaches the manual-rule diagnostic OFF `dnsStateQueue` (the packet read loop's
/// callback queue, and the wake-replay queue), while `adoptAppConfiguration` rebuilds these sets
/// ON it. Holding both in this immutable, `Sendable` box keeps an adoption coherent — a reader
/// sees the old pair or the new pair, never a new blocked set beside the previous allowed set.
/// The box is read under the provider's lock-guarded `ManualRuleDiagnosticState`; that lock, not
/// a bare reference swap, is what orders the publication against the off-queue reads (Kilo round
/// 3, PR #745), so the serve path still pays no `dnsStateQueue` hop (`INV-QUEUE-1`).
public final class ManualDomainRuleSnapshot: Sendable {
    /// The normalized user-blocked rules adopted with this snapshot.
    public let blocked: ManualDomainRuleSet
    /// The normalized user-allowed rules adopted with this snapshot.
    public let allowed: ManualDomainRuleSet

    /// Creates a snapshot from the two already-normalized manual rule sets.
    public init(blocked: ManualDomainRuleSet, allowed: ManualDomainRuleSet) {
        self.blocked = blocked
        self.allowed = allowed
    }
}
