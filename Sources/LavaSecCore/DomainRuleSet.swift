import Foundation

public struct DomainRule: Hashable, Codable, Sendable {
    public let domain: String
    public let matchesSubdomains: Bool

    public init(domain: String, matchesSubdomains: Bool = true) throws {
        self.domain = try DomainName.normalize(domain)
        self.matchesSubdomains = matchesSubdomains
    }
}

public struct DomainRuleSet: Equatable, Codable, Sendable {
    private var exactDomains: Set<String>
    private var suffixDomains: Set<String>

    public init(exactDomains: Set<String> = [], suffixDomains: Set<String> = []) {
        self.exactDomains = exactDomains
        self.suffixDomains = suffixDomains
    }

    public var isEmpty: Bool {
        exactDomains.isEmpty && suffixDomains.isEmpty
    }

    public var count: Int {
        exactDomains.count + suffixDomains.count
    }

    public var allDomains: Set<String> {
        exactDomains.union(suffixDomains)
    }

    public var exactDomainList: [String] {
        exactDomains.sorted()
    }

    public var suffixDomainList: [String] {
        suffixDomains.sorted()
    }

    public mutating func insert(_ rule: DomainRule) {
        if rule.matchesSubdomains {
            suffixDomains.insert(rule.domain)
        } else {
            exactDomains.insert(rule.domain)
        }
    }

    public mutating func insert(domain: String, matchesSubdomains: Bool = true) throws {
        insert(try DomainRule(domain: domain, matchesSubdomains: matchesSubdomains))
    }

    public mutating func formUnion(_ other: DomainRuleSet) {
        exactDomains.formUnion(other.exactDomains)
        suffixDomains.formUnion(other.suffixDomains)
    }

    public func union(_ other: DomainRuleSet) -> DomainRuleSet {
        var combined = self
        combined.formUnion(other)
        return combined
    }

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

    public func contains(_ rawDomain: String) -> Bool {
        guard let normalized = try? DomainName.normalize(rawDomain) else {
            return false
        }

        return containsNormalized(normalized)
    }

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

    public static func build(from rules: some Sequence<DomainRule>) -> DomainRuleSet {
        var set = DomainRuleSet()
        for rule in rules {
            set.insert(rule)
        }
        return set
    }
}
