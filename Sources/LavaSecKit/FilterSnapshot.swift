import Foundation

public enum FilterAction: String, Codable, Sendable {
    case allow
    case block
}

public enum FilterDecisionReason: String, Codable, Sendable {
    case defaultAllow
    case localAllowlist
    case blocklist
    case threatGuardrail
    case invalidDomain
    /// The domain would otherwise have gone through normal filtering, but protection was
    /// temporarily paused, so the query was forwarded without evaluating allow/block rules.
    /// Kept distinct from `.defaultAllow` so Domain History and the aggregate allow count
    /// can tell "cleared the normal filter" apart from "let through because paused"; the
    /// diagnostics store also excludes it from Top Domains ranking (not a real filter match).
    case pausedAllow
    /// The query was blocked because protection could not serve it safely — the runtime
    /// is fail-closed (no usable rule snapshot is resident: over budget, a build failure,
    /// an upstream that rotated past the catalog's pinned hash, or the brief cold-start
    /// window during a (re)start). This is NOT a curated blocklist match: while fail-closed
    /// EVERY domain is blocked, so these decisions must never be presented or counted as
    /// real blocklist hits. The diagnostics store self-gates on this reason to keep them out
    /// of Domain History and the aggregate block count; the UI labels it "Failed safe".
    case protectionUnavailable
}

public struct FilterDecision: Hashable, Codable, Sendable {
    public let action: FilterAction
    public let reason: FilterDecisionReason

    public init(action: FilterAction, reason: FilterDecisionReason) {
        self.action = action
        self.reason = reason
    }

    public static let defaultAllow = FilterDecision(action: .allow, reason: .defaultAllow)
    public static let pausedAllow = FilterDecision(action: .allow, reason: .pausedAllow)
}

public struct FilterSnapshot: Codable, Sendable {
    public let generatedAt: Date
    public let blockRules: DomainRuleSet
    public let allowRules: DomainRuleSet
    public let nonAllowableThreatRules: DomainRuleSet
    public let resolver: DNSResolverPreset

    public init(
        generatedAt: Date = Date(),
        blockRules: DomainRuleSet,
        allowRules: DomainRuleSet = DomainRuleSet(),
        nonAllowableThreatRules: DomainRuleSet = DomainRuleSet(),
        resolver: DNSResolverPreset = .google
    ) {
        self.generatedAt = generatedAt
        self.blockRules = blockRules
        self.allowRules = allowRules
        self.nonAllowableThreatRules = nonAllowableThreatRules
        self.resolver = resolver
    }

    public func decision(for rawDomain: String) -> FilterDecision {
        guard let normalizedDomain = try? DomainName.normalize(rawDomain) else {
            return FilterDecision(action: .block, reason: .invalidDomain)
        }

        return decision(forNormalizedDomain: normalizedDomain)
    }

    public func decision(forNormalizedDomain normalizedDomain: String) -> FilterDecision {
        if nonAllowableThreatRules.containsNormalized(normalizedDomain) {
            return FilterDecision(action: .block, reason: .threatGuardrail)
        }

        if allowRules.containsNormalized(normalizedDomain) {
            return FilterDecision(action: .allow, reason: .localAllowlist)
        }

        if blockRules.containsNormalized(normalizedDomain) {
            return FilterDecision(action: .block, reason: .blocklist)
        }

        return .defaultAllow
    }

    public func applyingQAProbeSet(_ probeSet: QADomainProbeSet?) -> FilterSnapshot {
        #if DEBUG || LAVA_QA_TOOLS
        guard let probeSet else {
            return self
        }

        var qaBlockRules = blockRules
        var qaAllowRules = allowRules
        var qaThreatRules = nonAllowableThreatRules

        try? qaBlockRules.insert(domain: probeSet.blockedDomain, matchesSubdomains: false)
        try? qaBlockRules.insert(domain: probeSet.exceptionDomain, matchesSubdomains: false)
        try? qaBlockRules.insert(domain: probeSet.guardrailDomain, matchesSubdomains: false)

        try? qaAllowRules.insert(domain: probeSet.exceptionDomain, matchesSubdomains: false)
        try? qaAllowRules.insert(domain: probeSet.guardrailDomain, matchesSubdomains: false)

        try? qaThreatRules.insert(domain: probeSet.guardrailDomain, matchesSubdomains: false)

        return FilterSnapshot(
            generatedAt: generatedAt,
            blockRules: qaBlockRules,
            allowRules: qaAllowRules,
            nonAllowableThreatRules: qaThreatRules,
            resolver: resolver
        )
        #else
        return self
        #endif
    }
}

public protocol FilterRuntimeSnapshot: Sendable {
    var resolver: DNSResolverPreset { get }
    var blockRuleCount: Int { get }
    var allowRuleCount: Int { get }
    var guardrailRuleCount: Int { get }

    func decision(for rawDomain: String) -> FilterDecision
    func decision(forNormalizedDomain normalizedDomain: String) -> FilterDecision
}

extension FilterSnapshot: FilterRuntimeSnapshot {
    public var blockRuleCount: Int {
        blockRules.count
    }

    public var allowRuleCount: Int {
        allowRules.count
    }

    public var guardrailRuleCount: Int {
        nonAllowableThreatRules.count
    }
}

public extension AppConfiguration {
    var allowRuleSet: DomainRuleSet {
        var allowRules = DomainRuleSet()
        for domain in allowedDomains {
            try? allowRules.insert(domain: domain, matchesSubdomains: true)
        }
        return allowRules
    }

    var manualBlockRuleSet: DomainRuleSet {
        var manualBlockRules = DomainRuleSet()
        for domain in blockedDomains {
            try? manualBlockRules.insert(domain: domain, matchesSubdomains: true)
        }
        return manualBlockRules
    }

    func filterSnapshot(
        generatedAt: Date = Date(),
        blockRules: DomainRuleSet = DomainRuleSet(),
        nonAllowableThreatRules: DomainRuleSet = DomainRuleSet()
    ) -> FilterSnapshot {
        var mergedBlockRules = blockRules
        mergedBlockRules.formUnion(manualBlockRuleSet)

        return FilterSnapshot(
            generatedAt: generatedAt,
            blockRules: mergedBlockRules,
            allowRules: allowRuleSet,
            nonAllowableThreatRules: nonAllowableRulesForAllowedDomains(from: nonAllowableThreatRules),
            resolver: resolverPreset
        )
        .applyingQAProbeSet(qaProbeSet)
    }

    func nonAllowableRulesForAllowedDomains(from threatRules: DomainRuleSet) -> DomainRuleSet {
        var effectiveRules = DomainRuleSet()
        for domain in allowedDomains where threatRules.contains(domain) {
            try? effectiveRules.insert(domain: domain, matchesSubdomains: true)
        }
        return effectiveRules
    }
}

