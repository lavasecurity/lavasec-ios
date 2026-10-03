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

    /// Exact entry membership, preserving the distinction between a host and its suffix scope.
    /// Streaming budget callers use this before allocating a new retained rule.
    package func containsRule(_ rule: DomainRule) -> Bool {
        rule.matchesSubdomains ? suffixDomains.contains(rule.domain) : exactDomains.contains(rule.domain)
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

    /// Keeps only threat scopes that intersect an allowed suffix. A threat host
    /// below an allowance retains its own rule; an allowance below a threat
    /// suffix retains the allowed scope. Each lookup walks hostname labels, so
    /// large guardrails never scan every allowed exception for each threat rule.
    package func threatOverlap(withAllowedSuffixes allowedRules: DomainRuleSet) -> DomainRuleSet {
        var overlap = DomainRuleSet()
        for domain in exactDomains where allowedRules.containsNormalized(domain) {
            overlap.exactDomains.insert(domain)
        }
        for domain in suffixDomains where allowedRules.containsNormalized(domain) {
            overlap.suffixDomains.insert(domain)
        }
        for domain in allowedRules.suffixDomains where containsCoveringSuffixRule(domain) {
            overlap.suffixDomains.insert(domain)
        }
        return overlap
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

    /// Counts allow entries whose full matching scope is not covered by threat rules.
    /// A threat at an exact host cannot neutralize a suffix allow: its other descendants
    /// remain reachable. This walks only the allow set, without copying the threat set.
    public func effectiveAllowRuleCount(nonAllowableThreatRules: DomainRuleSet) -> Int {
        exactDomains.reduce(0) { count, domain in
            count + (nonAllowableThreatRules.containsNormalized(domain) ? 0 : 1)
        } + suffixDomains.reduce(0) { count, domain in
            count + (nonAllowableThreatRules.containsCoveringSuffixRule(domain) ? 0 : 1)
        }
    }

    /// Nonredundant threat scopes inside each suffix allow that remains partly reachable.
    /// Retains at most one bounded depth/kind histogram per suffix allow, never the threat table.
    public func allowedSuffixGuardrailCoverage(nonAllowableThreatRules: DomainRuleSet) -> [String: GuardrailScopeCoverage] {
        var counts: [String: GuardrailScopeCoverage] = [:]
        for domain in suffixDomains where !nonAllowableThreatRules.containsCoveringSuffixRule(domain) {
            counts[domain] = GuardrailScopeCoverage()
        }
        guard !counts.isEmpty else { return counts }

        for domain in nonAllowableThreatRules.exactDomains {
            // An enclosing suffix already covers this exact host; removing it opens nothing.
            guard !nonAllowableThreatRules.containsCoveringSuffixRule(domain) else { continue }
            Self.recordGuardrailScope(domain, matchesSubdomains: false, in: &counts)
        }
        for domain in nonAllowableThreatRules.suffixDomains {
            if let dot = domain.firstIndex(of: "."),
               nonAllowableThreatRules.containsCoveringSuffixRule(String(domain[domain.index(after: dot)...])) {
                continue
            }
            Self.recordGuardrailScope(domain, matchesSubdomains: true, in: &counts)
        }
        return counts
    }

    /// Shared with compact tables, which decode one threat host at a time.
    package static func recordGuardrailScope(
        _ domain: String, matchesSubdomains: Bool, in counts: inout [String: GuardrailScopeCoverage]
    ) {
        var remainder = domain
        var depth = 0
        while true {
            if counts[remainder] != nil {
                counts[remainder]?.record(depth: depth, matchesSubdomains: matchesSubdomains)
            }
            guard let dot = remainder.firstIndex(of: ".") else { break }
            remainder = String(remainder[remainder.index(after: dot)...])
            depth += 1
        }
    }

    private func containsCoveringSuffixRule(_ normalizedDomain: String) -> Bool {
        var remainder = normalizedDomain
        if suffixDomains.contains(remainder) { return true }
        while let dotIndex = remainder.firstIndex(of: ".") {
            remainder = String(remainder[remainder.index(after: dotIndex)...])
            if suffixDomains.contains(remainder) { return true }
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
        var reducing = exactDomains.reduce(0) { count, domain in
            count + (blockRules.containsNormalized(domain)
                && !nonAllowableThreatRules.containsNormalized(domain) ? 1 : 0)
        }
        var needsDescendant = Set<String>()
        for domain in suffixDomains where !nonAllowableThreatRules.containsCoveringSuffixRule(domain) {
            if blockRules.containsCoveringSuffixRule(domain) {
                // A covered parent leaves some descendants reachable unless a
                // threat suffix covers the entire allowed scope (checked above).
                reducing += 1
            } else {
                needsDescendant.insert(domain)
            }
        }
        guard !needsDescendant.isEmpty else { return reducing }

        // Walk each block rule once, rather than scanning millions of rules for
        // every allowed parent. Guarded descendants never reduce protection.
        for domain in blockRules.exactDomains where !nonAllowableThreatRules.containsNormalized(domain) {
            reducing += Self.consumeAllowedSuffixes(covering: domain, from: &needsDescendant)
            if needsDescendant.isEmpty { return reducing }
        }
        for domain in blockRules.suffixDomains where !nonAllowableThreatRules.containsCoveringSuffixRule(domain) {
            reducing += Self.consumeAllowedSuffixes(covering: domain, from: &needsDescendant)
            if needsDescendant.isEmpty { return reducing }
        }
        return reducing
    }

    private static func consumeAllowedSuffixes(covering domain: String, from remaining: inout Set<String>) -> Int {
        var matches = 0
        var remainder = domain
        while true {
            if remaining.remove(remainder) != nil { matches += 1 }
            guard let dot = remainder.firstIndex(of: ".") else { break }
            remainder = String(remainder[remainder.index(after: dot)...])
        }
        return matches
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
