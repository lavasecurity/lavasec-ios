import Foundation

/// A domain rule whose public initializer validates and normalizes its hostname.
public struct DomainRule: Hashable, Codable, Sendable {
    /// The matched hostname; the public initializer stores its normalized form.
    public let domain: String
    /// Whether the rule also matches subdomains of ``domain``.
    public let matchesSubdomains: Bool

    /// Creates a rule after validating and normalizing its hostname.
    public init(domain: String, matchesSubdomains: Bool = true) throws {
        self.domain = try DomainName.normalize(domain)
        self.matchesSubdomains = matchesSubdomains
    }
}

/// A deduplicated collection of exact-host and host-plus-subdomain matching rules.
public struct DomainRuleSet: Equatable, Codable, Sendable {
    private var exactDomains: Set<String>
    private var suffixDomains: Set<String>

    /// Creates a set from already normalized exact and suffix hostnames.
    public init(exactDomains: Set<String> = [], suffixDomains: Set<String> = []) {
        self.exactDomains = exactDomains
        self.suffixDomains = suffixDomains
    }

    /// Whether neither exact nor suffix rules are present.
    public var isEmpty: Bool {
        exactDomains.isEmpty && suffixDomains.isEmpty
    }

    /// The total number of distinct exact and suffix rules.
    public var count: Int {
        exactDomains.count + suffixDomains.count
    }

    /// Every hostname present in either rule category, with duplicates collapsed.
    public var allDomains: Set<String> {
        exactDomains.union(suffixDomains)
    }

    /// Exact-match hostnames in ascending lexical order.
    public var exactDomainList: [String] {
        exactDomains.sorted()
    }

    /// Host-plus-subdomain match hostnames in ascending lexical order.
    public var suffixDomainList: [String] {
        suffixDomains.sorted()
    }

    /// Inserts a validated rule into its exact or suffix category.
    public mutating func insert(_ rule: DomainRule) {
        if rule.matchesSubdomains {
            suffixDomains.insert(rule.domain)
        } else {
            exactDomains.insert(rule.domain)
        }
    }

    /// Validates and inserts a hostname, throwing when it is not a valid domain rule.
    public mutating func insert(domain: String, matchesSubdomains: Bool = true) throws {
        insert(try DomainRule(domain: domain, matchesSubdomains: matchesSubdomains))
    }

    /// Adds every exact and suffix rule from `other` to this set.
    public mutating func formUnion(_ other: DomainRuleSet) {
        exactDomains.formUnion(other.exactDomains)
        suffixDomains.formUnion(other.suffixDomains)
    }

    /// Returns a copy containing the rules from both sets.
    public func union(_ other: DomainRuleSet) -> DomainRuleSet {
        var combined = self
        combined.formUnion(other)
        return combined
    }

    /// Returns rules whose normalized hostnames are not matched by `protectedRules`.
    public func filteringOutRules(matchedBy protectedRules: DomainRuleSet) -> DomainRuleSet {
        var filtered = DomainRuleSet()
        for domain in exactDomains where !protectedRules.containsNormalized(domain) {
            try? filtered.insert(domain: domain, matchesSubdomains: false)
        }
        for domain in suffixDomains where !protectedRules.containsNormalized(domain) {
            try? filtered.insert(domain: domain, matchesSubdomains: true)
        }
        return filtered
    }

    /// Validates a hostname and reports whether an exact or enclosing suffix rule matches it.
    public func contains(_ rawDomain: String) -> Bool {
        guard let normalized = try? DomainName.normalize(rawDomain) else {
            return false
        }

        return containsNormalized(normalized)
    }

    /// Reports whether an already normalized hostname matches an exact or enclosing suffix rule.
    public func containsNormalized(_ normalizedDomain: String) -> Bool {
        if exactDomains.contains(normalizedDomain) || suffixDomains.contains(normalizedDomain) {
            return true
        }

        var remainder = normalizedDomain
        while let dotIndex = remainder.firstIndex(of: ".") {
            remainder = String(remainder[remainder.index(after: dotIndex)...])
            if suffixDomains.contains(remainder) {
                return true
            }
        }

        return false
    }

    /// Counts blocked rules after subtracting allow rules that reduce protection outside threat guardrails.
    public func effectiveBlockedDomainRuleCount(
        allowRules: DomainRuleSet,
        nonAllowableThreatRules: DomainRuleSet = DomainRuleSet()
    ) -> Int {
        max(0, count - allowRules.protectionReducingRuleCount(
            blockRules: self,
            nonAllowableThreatRules: nonAllowableThreatRules
        ))
    }

    private func protectionReducingRuleCount(
        blockRules: DomainRuleSet,
        nonAllowableThreatRules: DomainRuleSet
    ) -> Int {
        exactDomains.reduce(0) { count, domain in
            count + (Self.allowedRuleReducesProtection(
                domain,
                matchesSubdomains: false,
                blockRules: blockRules,
                nonAllowableThreatRules: nonAllowableThreatRules
            ) ? 1 : 0)
        } + suffixDomains.reduce(0) { count, domain in
            count + (Self.allowedRuleReducesProtection(
                domain,
                matchesSubdomains: true,
                blockRules: blockRules,
                nonAllowableThreatRules: nonAllowableThreatRules
            ) ? 1 : 0)
        }
    }

    private static func allowedRuleReducesProtection(
        _ normalizedDomain: String,
        matchesSubdomains: Bool,
        blockRules: DomainRuleSet,
        nonAllowableThreatRules: DomainRuleSet
    ) -> Bool {
        if nonAllowableThreatRules.containsNormalized(normalizedDomain) {
            return false
        }

        if matchesSubdomains && nonAllowableThreatRules.hasRuleAtOrBelow(normalizedDomain) {
            return false
        }

        if blockRules.containsNormalized(normalizedDomain) {
            return true
        }

        guard matchesSubdomains else {
            return false
        }

        return blockRules.hasRuleAtOrBelow(normalizedDomain)
    }

    private func hasRuleAtOrBelow(_ normalizedDomain: String) -> Bool {
        exactDomains.contains { Self.domain($0, isEqualToOrSubdomainOf: normalizedDomain) }
            || suffixDomains.contains { Self.domain($0, isEqualToOrSubdomainOf: normalizedDomain) }
    }

    private static func domain(_ domain: String, isEqualToOrSubdomainOf parentDomain: String) -> Bool {
        domain == parentDomain || domain.hasSuffix(".\(parentDomain)")
    }

    /// Builds a deduplicated set from a sequence of validated rules.
    public static func build(from rules: some Sequence<DomainRule>) -> DomainRuleSet {
        var set = DomainRuleSet()
        for rule in rules {
            set.insert(rule)
        }
        return set
    }
}
