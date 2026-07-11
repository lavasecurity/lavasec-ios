import CryptoKit
import LavaSecKit
import Foundation

/// Persistable filter snapshot paired with the inputs and summary used for reuse checks.
public struct PreparedFilterSnapshot: Codable, Sendable {
    /// Inputs that identify the configuration and catalog used for compilation.
    public let identity: PreparedFilterSnapshotIdentity
    /// Runtime filter snapshot produced by compilation.
    public let snapshot: FilterSnapshot
    /// Persisted rule counts and source coverage for the snapshot.
    public let summary: PreparedFilterSnapshotSummary

    private enum CodingKeys: String, CodingKey {
        case identity
        case snapshot
        case summary
    }

    /// Creates a prepared snapshot, deriving a summary when one is not supplied.
    public init(
        identity: PreparedFilterSnapshotIdentity,
        snapshot: FilterSnapshot,
        summary: PreparedFilterSnapshotSummary? = nil
    ) {
        self.identity = identity
        self.snapshot = snapshot
        self.summary = summary ?? PreparedFilterSnapshotSummary(snapshot: snapshot)
    }

    /// Decodes a prepared snapshot and rebuilds its table-derived summary fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.identity = try container.decode(PreparedFilterSnapshotIdentity.self, forKey: .identity)
        self.snapshot = try container.decode(FilterSnapshot.self, forKey: .snapshot)
        let decodedSummary = try container.decodeIfPresent(PreparedFilterSnapshotSummary.self, forKey: .summary)
        self.summary = PreparedFilterSnapshotSummary(
            snapshot: snapshot,
            blocklistRuleCount: decodedSummary?.blocklistRuleCount,
            blocklistSourceRuleCounts: decodedSummary?.blocklistSourceRuleCounts,
            // Preserve the persisted budget total: like blocklistRuleCount it cannot be re-derived
            // from the snapshot (it needs the FULL guardrail set), so the snapshot-recomputed summary
            // would otherwise drop it and a warm reuse would always cold-compile.
            tierBudgetRuleCount: decodedSummary?.tierBudgetRuleCount
        )
    }

    package func matches(identity expectedIdentity: PreparedFilterSnapshotIdentity) -> Bool {
        identity == expectedIdentity
    }

    /// Returns whether the snapshot matches the configuration and available catalog inputs.
    public func canReuseForProtectionStartup(
        configuration: AppConfiguration,
        cachedCatalog: BlocklistCatalog?
    ) -> Bool {
        guard snapshot.resolver.transport == configuration.resolverPreset.transport else {
            return false
        }

        if !configuration.enabledBlocklistIDs.isEmpty {
            guard cachedCatalog != nil, summary.coversEnabledBlocklists(in: configuration) else {
                return false
            }
        }

        if let cachedCatalog {
            let expectedIdentity = PreparedFilterSnapshotIdentity.make(
                configuration: configuration,
                catalog: cachedCatalog
            )
            return identity.hasSameSnapshotInputs(as: expectedIdentity)
        }

        return identity.hasSameConfigurationInputs(as: configuration)
    }
}

/// Persisted rule counts and blocklist coverage for a prepared snapshot.
public struct PreparedFilterSnapshotSummary: Codable, Equatable, Sendable {
    /// Total parsed blocklist rules before local rule merging, when recorded.
    public let blocklistRuleCount: Int?
    /// Parsed rule counts keyed by selected blocklist source, when recorded.
    public let blocklistSourceRuleCounts: [String: Int]?
    /// Number of effective block rules in the runtime snapshot.
    public let blockRuleCount: Int
    /// Raw block rules reduced by configured allowed exceptions that overlap blocked rules.
    public let blockedDomainRuleCount: Int
    /// Number of configured allow rules in the runtime snapshot.
    public let allowRuleCount: Int
    /// Number of non-allowable threat rules stored in the runtime snapshot.
    public let guardrailRuleCount: Int
    /// The exact rule total the COLD compile gate budgets against
    /// (`FilterSnapshotPreparationService.prepare`: merged block rules + the FULL guardrail rule
    /// set + allowed exceptions + blocked domains). Persisted so a warm-artifact reuse can apply the
    /// identical tier/device rule-limit gate WITHOUT recompiling — the per-field summary counts
    /// can't reconstruct it (`blockRuleCount` already folds in blocked domains, and
    /// `guardrailRuleCount` is only the allowlist-overlap subset, not the full guardrail set).
    /// Optional so legacy artifacts predating this field decode to `nil`; a reuse path that needs it
    /// then falls back to a cold compile.
    public let tierBudgetRuleCount: Int?

    private enum CodingKeys: String, CodingKey {
        case blocklistRuleCount
        case blocklistSourceRuleCounts
        case blockRuleCount
        case blockedDomainRuleCount
        case allowRuleCount
        case guardrailRuleCount
        case tierBudgetRuleCount
    }

    /// Creates a summary from explicit rule counts and optional source coverage.
    public init(
        blocklistRuleCount: Int?,
        blocklistSourceRuleCounts: [String: Int]? = nil,
        blockRuleCount: Int,
        blockedDomainRuleCount: Int? = nil,
        allowRuleCount: Int,
        guardrailRuleCount: Int,
        tierBudgetRuleCount: Int? = nil
    ) {
        self.blocklistRuleCount = blocklistRuleCount
        self.blocklistSourceRuleCounts = blocklistSourceRuleCounts
        self.blockRuleCount = blockRuleCount
        self.blockedDomainRuleCount = blockedDomainRuleCount ?? blockRuleCount
        self.allowRuleCount = allowRuleCount
        self.guardrailRuleCount = guardrailRuleCount
        self.tierBudgetRuleCount = tierBudgetRuleCount
    }

    /// Decodes current and legacy summaries, defaulting a missing protected count to block count.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blocklistRuleCount = try container.decodeIfPresent(Int.self, forKey: .blocklistRuleCount)
        blocklistSourceRuleCounts = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .blocklistSourceRuleCounts
        )
        blockRuleCount = try container.decode(Int.self, forKey: .blockRuleCount)
        blockedDomainRuleCount = try container.decodeIfPresent(Int.self, forKey: .blockedDomainRuleCount)
            ?? blockRuleCount
        allowRuleCount = try container.decode(Int.self, forKey: .allowRuleCount)
        guardrailRuleCount = try container.decode(Int.self, forKey: .guardrailRuleCount)
        tierBudgetRuleCount = try container.decodeIfPresent(Int.self, forKey: .tierBudgetRuleCount)
    }

    /// Creates a summary from the rule tables in a runtime snapshot.
    public init(
        snapshot: FilterSnapshot,
        blocklistRuleCount: Int? = nil,
        blocklistSourceRuleCounts: [String: Int]? = nil,
        tierBudgetRuleCount: Int? = nil
    ) {
        self.init(
            blocklistRuleCount: blocklistRuleCount,
            blocklistSourceRuleCounts: blocklistSourceRuleCounts,
            blockRuleCount: snapshot.blockRules.count,
            blockedDomainRuleCount: snapshot.blockRules.effectiveBlockedDomainRuleCount(
                allowRules: snapshot.allowRules,
                nonAllowableThreatRules: snapshot.nonAllowableThreatRules
            ),
            allowRuleCount: snapshot.allowRules.count,
            guardrailRuleCount: snapshot.nonAllowableThreatRules.count,
            tierBudgetRuleCount: tierBudgetRuleCount
        )
    }

    /// Returns whether a source count is recorded for every enabled blocklist.
    public func coversEnabledBlocklists(in configuration: AppConfiguration) -> Bool {
        guard !configuration.enabledBlocklistIDs.isEmpty else {
            return true
        }

        guard let blocklistSourceRuleCounts else {
            return false
        }

        return configuration.enabledBlocklistIDs.allSatisfy { blocklistSourceRuleCounts[$0] != nil }
    }
}

/// Stable compilation inputs used to validate and content-address prepared artifacts.
public struct PreparedFilterSnapshotIdentity: Codable, Equatable, Sendable {
    /// Identifiers of blocklists enabled for the snapshot.
    ///
    /// ``make(configuration:catalog:)`` emits canonical sorted order; decoding and direct
    /// initialization preserve the order they receive.
    public let enabledBlocklistIDs: [String]
    /// Manually blocked domains included in the snapshot.
    ///
    /// ``make(configuration:catalog:)`` emits canonical sorted order; decoding and direct
    /// initialization preserve the order they receive.
    public let blockedDomains: [String]
    /// Manually allowed domains included in the snapshot.
    ///
    /// ``make(configuration:catalog:)`` emits canonical sorted order; decoding and direct
    /// initialization preserve the order they receive.
    public let allowedDomains: [String]
    /// Resolver transport selected when the snapshot was compiled.
    public let resolverTransport: DNSResolverTransport
    /// QA probe set included in the snapshot inputs, when configured.
    public let qaProbeSet: QADomainProbeSet?
    /// Catalog revision used for compilation, when a catalog was available.
    public let catalogVersion: String?
    /// Selected catalog source version identifiers keyed by source identifier.
    public let selectedSourceVersionIDs: [String: String]
    /// Selected catalog source hashes keyed by source identifier.
    public let selectedSourceHashes: [String: String]
    /// Enabled custom-source cache identities keyed by source identifier.
    public let customBlocklistFingerprints: [String: String]
    /// Guardrail source version identifiers keyed by source identifier.
    public let guardrailVersionIDs: [String: String]
    /// Guardrail source hashes keyed by source identifier.
    public let guardrailHashes: [String: String]
    // Blocklist parser rules version the artifact was compiled under. Folded into
    // the identity so a parser-behavior change (which bumps
    // BlocklistParsingRules.rulesVersion) invalidates already-compiled compact and
    // prepared artifacts — not just the RuleSetCache — forcing the app to
    // regenerate and the tunnel to reload instead of reusing a stale artifact whose
    // source bytes/hash did not change. Legacy artifacts predating this field decode
    // as 0, which never equals a real version (≥1), so they are always regenerated.
    /// Parser-rules version used to compile the snapshot.
    public let parserRulesVersion: Int

    private enum CodingKeys: String, CodingKey {
        case enabledBlocklistIDs
        case blockedDomains
        case allowedDomains
        case resolverTransport
        case qaProbeSet
        case catalogVersion
        case selectedSourceVersionIDs
        case selectedSourceHashes
        case customBlocklistFingerprints
        case guardrailVersionIDs
        case guardrailHashes
        case parserRulesVersion
    }

    package init(
        enabledBlocklistIDs: [String],
        blockedDomains: [String],
        allowedDomains: [String],
        resolverTransport: DNSResolverTransport = .plainDNS,
        qaProbeSet: QADomainProbeSet?,
        catalogVersion: String?,
        selectedSourceVersionIDs: [String: String],
        selectedSourceHashes: [String: String],
        customBlocklistFingerprints: [String: String] = [:],
        guardrailVersionIDs: [String: String],
        guardrailHashes: [String: String],
        parserRulesVersion: Int = BlocklistParsingRules.rulesVersion
    ) {
        self.enabledBlocklistIDs = enabledBlocklistIDs
        self.blockedDomains = blockedDomains
        self.allowedDomains = allowedDomains
        self.resolverTransport = resolverTransport
        self.qaProbeSet = qaProbeSet
        self.catalogVersion = catalogVersion
        self.selectedSourceVersionIDs = selectedSourceVersionIDs
        self.selectedSourceHashes = selectedSourceHashes
        self.customBlocklistFingerprints = customBlocklistFingerprints
        self.guardrailVersionIDs = guardrailVersionIDs
        self.guardrailHashes = guardrailHashes
        self.parserRulesVersion = parserRulesVersion
    }

    /// Decodes current and legacy identities with compatibility defaults for added fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabledBlocklistIDs = try container.decode([String].self, forKey: .enabledBlocklistIDs)
        self.blockedDomains = try container.decode([String].self, forKey: .blockedDomains)
        self.allowedDomains = try container.decode([String].self, forKey: .allowedDomains)
        self.resolverTransport = try container.decodeIfPresent(
            DNSResolverTransport.self,
            forKey: .resolverTransport
        ) ?? .plainDNS
        self.qaProbeSet = try container.decodeIfPresent(QADomainProbeSet.self, forKey: .qaProbeSet)
        self.catalogVersion = try container.decodeIfPresent(String.self, forKey: .catalogVersion)
        self.selectedSourceVersionIDs = try container.decode(
            [String: String].self,
            forKey: .selectedSourceVersionIDs
        )
        self.selectedSourceHashes = try container.decode([String: String].self, forKey: .selectedSourceHashes)
        self.customBlocklistFingerprints = try container.decodeIfPresent(
            [String: String].self,
            forKey: .customBlocklistFingerprints
        ) ?? [:]
        self.guardrailVersionIDs = try container.decode([String: String].self, forKey: .guardrailVersionIDs)
        self.guardrailHashes = try container.decode([String: String].self, forKey: .guardrailHashes)
        // 0 = artifact compiled before this field existed (genuinely a pre-v2 parser).
        // It never equals a real rules version, so such artifacts are regenerated.
        self.parserRulesVersion = try container.decodeIfPresent(Int.self, forKey: .parserRulesVersion) ?? 0
    }

    /// Builds the canonical identity for a configuration and optional catalog.
    public static func make(
        configuration: AppConfiguration,
        catalog: BlocklistCatalog?
    ) -> PreparedFilterSnapshotIdentity {
        let selectedSources = (catalog?.sources ?? [])
            .filter { configuration.enabledBlocklistIDs.contains($0.id) }
        let guardrailSources = catalog?.guardrails ?? []
        let customFingerprints = Self.customBlocklistFingerprints(for: configuration)

        return PreparedFilterSnapshotIdentity(
            enabledBlocklistIDs: configuration.enabledBlocklistIDs.sorted(),
            blockedDomains: configuration.blockedDomains.sorted(),
            allowedDomains: configuration.allowedDomains.sorted(),
            resolverTransport: configuration.resolverPreset.transport,
            qaProbeSet: configuration.qaProbeSet,
            catalogVersion: catalog?.catalogVersion,
            selectedSourceVersionIDs: Dictionary(uniqueKeysWithValues: selectedSources.map { ($0.id, $0.versionID) }),
            selectedSourceHashes: Dictionary(uniqueKeysWithValues: selectedSources.map { ($0.id, $0.normalizedHash) }),
            customBlocklistFingerprints: customFingerprints,
            guardrailVersionIDs: Dictionary(uniqueKeysWithValues: guardrailSources.map { ($0.id, $0.versionID) }),
            guardrailHashes: Dictionary(uniqueKeysWithValues: guardrailSources.map { ($0.id, $0.normalizedHash) }),
            parserRulesVersion: BlocklistParsingRules.rulesVersion
        )
    }

    package func matches(configuration: AppConfiguration, catalog: BlocklistCatalog?) -> Bool {
        self == Self.make(configuration: configuration, catalog: catalog)
    }

    /// Returns whether configuration inputs and resolver transport match.
    public func hasSameConfiguration(as configuration: AppConfiguration) -> Bool {
        hasSameConfigurationInputs(as: configuration)
            && resolverTransport == configuration.resolverPreset.transport
    }

    /// Returns whether all inputs that affect compiled snapshot rules match another identity.
    public func hasSameSnapshotInputs(as other: PreparedFilterSnapshotIdentity) -> Bool {
        snapshotInputMismatches(against: other).isEmpty
    }

    /// Field-level diff for diagnostics: the names of the snapshot-input fields
    /// that differ from `other`. Field NAMES only (never domain/host values), so
    /// it is safe to log — used to pinpoint why a warm-start artifact reuse was
    /// rejected on device.
    public func snapshotInputMismatches(against other: PreparedFilterSnapshotIdentity) -> [String] {
        var mismatches: [String] = []
        if enabledBlocklistIDs != other.enabledBlocklistIDs { mismatches.append("enabledBlocklistIDs") }
        if blockedDomains != other.blockedDomains { mismatches.append("blockedDomains") }
        if allowedDomains != other.allowedDomains { mismatches.append("allowedDomains") }
        if qaProbeSet != other.qaProbeSet { mismatches.append("qaProbeSet") }
        if catalogVersion != other.catalogVersion { mismatches.append("catalogVersion") }
        if selectedSourceVersionIDs != other.selectedSourceVersionIDs { mismatches.append("selectedSourceVersionIDs") }
        if selectedSourceHashes != other.selectedSourceHashes { mismatches.append("selectedSourceHashes") }
        if customBlocklistFingerprints != other.customBlocklistFingerprints { mismatches.append("customBlocklistFingerprints") }
        if guardrailVersionIDs != other.guardrailVersionIDs { mismatches.append("guardrailVersionIDs") }
        if guardrailHashes != other.guardrailHashes { mismatches.append("guardrailHashes") }
        if parserRulesVersion != other.parserRulesVersion { mismatches.append("parserRulesVersion") }
        return mismatches
    }

    /// Returns whether configuration-derived inputs and the current parser version match.
    public func hasSameConfigurationInputs(as configuration: AppConfiguration) -> Bool {
        // The no-cached-catalog warm-start branch compares against the running
        // binary's parser rules version (configuration carries no artifact version),
        // so an artifact compiled under an older parser is rejected and regenerated.
        parserRulesVersion == BlocklistParsingRules.rulesVersion
            && enabledBlocklistIDs == configuration.enabledBlocklistIDs.sorted()
            && blockedDomains == configuration.blockedDomains.sorted()
            && allowedDomains == configuration.allowedDomains.sorted()
            && qaProbeSet == configuration.qaProbeSet
            && customBlocklistFingerprints == Self.customBlocklistFingerprints(for: configuration)
    }

    private static func customBlocklistFingerprints(for configuration: AppConfiguration) -> [String: String] {
        configuration.customBlocklists
            .filter { configuration.enabledBlocklistIDs.contains($0.id) }
            .reduce(into: [String: String]()) { output, source in
                output[source.id] = source.cacheIdentity
            }
    }

    /// SHA-256 fingerprint of the identity's sorted-key JSON encoding.
    public var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
