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
}

public struct FilterDecision: Hashable, Codable, Sendable {
    public let action: FilterAction
    public let reason: FilterDecisionReason

    public init(action: FilterAction, reason: FilterDecisionReason) {
        self.action = action
        self.reason = reason
    }

    public static let defaultAllow = FilterDecision(action: .allow, reason: .defaultAllow)
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

public struct CachedFilterSnapshotCompiler: Sendable {
    public let cacheDirectoryURL: URL
    public let includesGuardrails: Bool

    public init(cacheDirectoryURL: URL, includesGuardrails: Bool = true) {
        self.cacheDirectoryURL = cacheDirectoryURL
        self.includesGuardrails = includesGuardrails
    }

    public func compile(
        baseSnapshot: FilterSnapshot,
        configuration: AppConfiguration
    ) async throws -> FilterSnapshot {
        let synchronizer = BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheDirectoryURL)
        let result = try await synchronizer.loadCached(
            enabledSourceIDs: configuration.enabledBlocklistIDs,
            includesGuardrails: includesGuardrails
        )
        let enabledCustomSources = configuration.customBlocklists.filter { source in
            configuration.enabledBlocklistIDs.contains(source.id)
        }
        let customResult = try await synchronizer.loadCachedCustomBlocklists(enabledCustomSources)
        for sourceID in configuration.enabledBlocklistIDs
            where result.sourceRuleSets[sourceID] == nil && customResult.sourceRuleSets[sourceID] == nil {
            throw BlocklistCatalogSyncError.missingEnabledBlocklistSource(sourceID: sourceID)
        }

        var blockRules = DomainRuleSet()
        for sourceID in configuration.enabledBlocklistIDs {
            if let rules = result.sourceRuleSets[sourceID] {
                blockRules.formUnion(rules)
            }
            if let rules = customResult.sourceRuleSets[sourceID] {
                blockRules.formUnion(rules)
            }
        }
        blockRules.formUnion(configuration.manualBlockRuleSet)

        let effectiveThreatRules = includesGuardrails
            ? configuration.nonAllowableRulesForAllowedDomains(from: result.guardrailRuleSet)
            : DomainRuleSet()

        return FilterSnapshot(
            blockRules: blockRules,
            allowRules: baseSnapshot.allowRules,
            nonAllowableThreatRules: effectiveThreatRules,
            resolver: configuration.resolverPreset
        )
        .applyingQAProbeSet(configuration.qaProbeSet)
    }
}
