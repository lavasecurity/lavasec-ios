import Foundation

public enum FilterAction: String, Codable, Sendable, CaseIterable {
    case allow
    case block
}

public enum FilterDecisionReason: String, Codable, Sendable {
    case defaultAllow
    case localAllowlist
    case blocklist
    case threatGuardrail
    case invalidDomain
    /// The query or a reachable answer alias would have been blocked, but protection was
    /// temporarily paused, so the query was allowed. Normal passes retain `.defaultAllow`
    /// or `.localAllowlist`; only pause-overridden blocks receive this reason and are
    /// excluded from Top Domains ranking by the diagnostics store.
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

    /// Allow entries whose full scope is not overridden by a threat guardrail.
    /// Separate from raw table counts: one suffix allow can contain many threat children.
    var effectiveAllowRuleCount: Int { get }

    /// Nonredundant threat scopes within each partly reachable suffix allow. Comparing
    /// retained allow keys detects released children without retaining the threat rules.
    var allowedSuffixGuardrailCoverage: [String: GuardrailScopeCoverage] { get }

    /// Whether this snapshot blocks EVERY lookup — the fail-closed posture, in which the rule
    /// counts are all zero and say nothing about what the user could reach.
    ///
    /// A requirement with NO default extension, deliberately. Recovery from a block-all resident is
    /// always a loosening whatever the counts show (`FilterLooseningReapplyPolicy`), and the
    /// question was previously answered by proxies that each missed a case: first the several
    /// markers recording WHY a block-all resident was installed, then a concrete-type test, which a
    /// resolver-adjusted WRAPPER around a fail-closed snapshot silently failed (review, PR #645). A
    /// defaulted `false` would let the next wrapper miss it the same way; requiring it forces every
    /// conformer — wrappers most of all — to state the answer.
    var blocksEveryLookup: Bool { get }

    func decision(for rawDomain: String) -> FilterDecision
    func decision(forNormalizedDomain normalizedDomain: String) -> FilterDecision
}

extension FilterSnapshot: FilterRuntimeSnapshot {
    /// A real rule snapshot serves its rules; a permissive pass-through built for an empty
    /// configuration blocks nothing either. Neither is the fail-closed posture.
    public var blocksEveryLookup: Bool { false }

    public var blockRuleCount: Int {
        blockRules.count
    }

    public var allowRuleCount: Int {
        allowRules.count
    }

    public var guardrailRuleCount: Int {
        nonAllowableThreatRules.count
    }

    /// Allow entries not wholly covered by threat rules, independent of raw threat count.
    public var effectiveAllowRuleCount: Int {
        allowRules.effectiveAllowRuleCount(nonAllowableThreatRules: nonAllowableThreatRules)
    }

    public var allowedSuffixGuardrailCoverage: [String: GuardrailScopeCoverage] {
        allowRules.allowedSuffixGuardrailCoverage(nonAllowableThreatRules: nonAllowableThreatRules)
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
        threatRules.threatOverlap(withAllowedSuffixes: allowRuleSet)
    }
}


public extension FilterRuntimeSnapshot {
    /// Evaluates a question and its validated reachable alias targets against one snapshot.
    /// Each name keeps its existing allowlist and threat-guardrail precedence; allowing the
    /// question does not implicitly allow a different destination named by the resolver.
    func decision(forNormalizedDomain domain: String, reachableAliasDomains: [String]) -> FilterDecision {
        let original = decision(forNormalizedDomain: domain)
        guard original.action == .allow else { return original }
        for target in reachableAliasDomains {
            let targetDecision = decision(forNormalizedDomain: target)
            if targetDecision.action == .block { return targetDecision }
        }
        return original
    }
}
