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
            tierBudgetRuleCount: decodedSummary?.tierBudgetRuleCount,
            quarantinedBlocklistIDs: decodedSummary?.quarantinedBlocklistIDs
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
    /// Enabled blocklists this artifact DELIBERATELY does not contain, because the source
    /// could not be fetched and never will be as configured (a 404, a list past a cap,
    /// or an identity explicitly withdrawn by the admitted catalog).
    ///
    /// 🔴 THIS IS WHAT MAKES A PARTIAL ARTIFACT HONEST RATHER THAN A LIE. Coverage exists so
    /// the resolver never serves a snapshot while believing it enforces a list it does not
    /// hold. Simply relaxing that check to survive one dead source would turn it into a
    /// tautology — the artifact would publish clean, pass every reuse gate and
    /// last-known-good, permanently, with nothing recording what was dropped.
    ///
    /// So the omission is not INFERRED from an absence, it is DECLARED. `coversEnabledBlocklists`
    /// accepts an enabled source only if the artifact either holds its rules or names it here.
    /// An empty or nil set means the strict old behaviour, which is the safe default for every
    /// artifact written before this field existed and for every writer that forgets it.
    public let quarantinedBlocklistIDs: Set<String>?

    private enum CodingKeys: String, CodingKey {
        case blocklistRuleCount
        case blocklistSourceRuleCounts
        case blockRuleCount
        case blockedDomainRuleCount
        case allowRuleCount
        case guardrailRuleCount
        case tierBudgetRuleCount
        case quarantinedBlocklistIDs
    }

    /// Creates a summary from explicit rule counts and optional source coverage.
    public init(
        blocklistRuleCount: Int?,
        blocklistSourceRuleCounts: [String: Int]? = nil,
        blockRuleCount: Int,
        blockedDomainRuleCount: Int? = nil,
        allowRuleCount: Int,
        guardrailRuleCount: Int,
        tierBudgetRuleCount: Int? = nil,
        quarantinedBlocklistIDs: Set<String>? = nil
    ) {
        self.blocklistRuleCount = blocklistRuleCount
        self.blocklistSourceRuleCounts = blocklistSourceRuleCounts
        self.blockRuleCount = blockRuleCount
        self.blockedDomainRuleCount = blockedDomainRuleCount ?? blockRuleCount
        self.allowRuleCount = allowRuleCount
        self.guardrailRuleCount = guardrailRuleCount
        self.tierBudgetRuleCount = tierBudgetRuleCount
        self.quarantinedBlocklistIDs = quarantinedBlocklistIDs
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
        // Legacy artifacts decode as nil, which reads as "nothing quarantined" — the strict
        // predicate. An old artifact can never gain coverage it did not have.
        quarantinedBlocklistIDs = try container.decodeIfPresent(
            Set<String>.self, forKey: .quarantinedBlocklistIDs)
    }

    /// Creates a summary from the rule tables in a runtime snapshot.
    public init(
        snapshot: FilterSnapshot,
        blocklistRuleCount: Int? = nil,
        blocklistSourceRuleCounts: [String: Int]? = nil,
        tierBudgetRuleCount: Int? = nil,
        quarantinedBlocklistIDs: Set<String>? = nil
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
            tierBudgetRuleCount: tierBudgetRuleCount,
            quarantinedBlocklistIDs: quarantinedBlocklistIDs
        )
    }

    /// Returns whether every enabled blocklist is ACCOUNTED FOR — either its rules are in
    /// this artifact, or it is declared quarantined.
    public func coversEnabledBlocklists(in configuration: AppConfiguration) -> Bool {
        guard !configuration.enabledBlocklistIDs.isEmpty else {
            return true
        }

        guard let blocklistSourceRuleCounts else {
            return false
        }

        let quarantined = quarantinedBlocklistIDs ?? []
        return configuration.enabledBlocklistIDs.allSatisfy {
            blocklistSourceRuleCounts[$0] != nil || quarantined.contains($0)
        }
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
    /// Overlap semantics used by threat exceptions; legacy artifacts must recompile.
    public let threatOverlapVersion: Int

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
        case threatOverlapVersion
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
        parserRulesVersion: Int = BlocklistParsingRules.rulesVersion,
        threatOverlapVersion: Int = 1
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
        self.threatOverlapVersion = threatOverlapVersion
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
        self.threatOverlapVersion = try container.decodeIfPresent(Int.self, forKey: .threatOverlapVersion) ?? 0
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
        if threatOverlapVersion != other.threatOverlapVersion { mismatches.append("threatOverlapVersion") }
        return mismatches
    }

    /// Snapshot-input fields that decide WHICH RULES THE USER ASKED FOR.
    ///
    /// A difference in any of these means the artifact is a DIFFERENT FILTER — the wrong enabled
    /// set, the wrong manual rules, custom lists whose content the user supplied, or rules a
    /// different parser produced. Serving it would enforce something the user did not choose, so
    /// these are never tolerable and no caller may weaken them.
    public static let selectionInputFieldNames: Set<String> = [
        "enabledBlocklistIDs",
        "blockedDomains",
        "allowedDomains",
        "qaProbeSet",
        "customBlocklistFingerprints",
        "parserRulesVersion",
        "threatOverlapVersion"
    ]

    /// Snapshot-input fields that decide only HOW FRESH the catalog-managed content is.
    ///
    /// These name the version and content hash of the very same sources the selection already
    /// pins. A difference means the artifact is a STALE COPY OF THE RIGHT FILTER — the lists the
    /// user chose, compiled from content that has since moved. `canServeAsLastKnownGood` has
    /// always treated exactly this set as tolerable, on the reasoning that serving the user's own
    /// previously-verified rules a few hours stale beats having no filter at all.
    public static let freshnessInputFieldNames: Set<String> = [
        "catalogVersion",
        "selectedSourceVersionIDs",
        "selectedSourceHashes",
        "guardrailVersionIDs",
        "guardrailHashes"
    ]

    /// The mismatching fields that change WHICH rules were asked for, ignoring freshness drift.
    ///
    /// Every snapshot input belongs to exactly one of the two sets above, and this partition is
    /// asserted by `PreparedFilterSnapshotIdentityClassificationTests` against
    /// `snapshotInputMismatches` itself — a new input field fails that test until it is classified,
    /// rather than silently defaulting into "tolerable".
    public func selectionMismatches(against other: PreparedFilterSnapshotIdentity) -> [String] {
        snapshotInputMismatches(against: other).filter {
            !Self.freshnessInputFieldNames.contains($0)
        }
    }

    /// Whether the two identities ask for the SAME rules and differ only in catalog freshness.
    ///
    /// Read this as "this artifact is the user's filter, just not the newest copy of it". It is
    /// deliberately NOT a licence to skip a fresh compile — it ranks a stale-but-correct artifact
    /// ABOVE a fresh-but-wrong one, which is the ordering a filter switch needs and the ordering
    /// the reload path lacked (field 2026-09-01: a switch to a lighter preset was rejected on
    /// these two fields alone, so the tunnel kept a heavier preset resident for 40 minutes and
    /// went on enforcing a filter the user had turned off).
    public func differsOnlyInCatalogFreshness(from other: PreparedFilterSnapshotIdentity) -> Bool {
        let mismatches = snapshotInputMismatches(against: other)
        return !mismatches.isEmpty && mismatches.allSatisfy(Self.freshnessInputFieldNames.contains)
    }

    /// `nil` when nothing differs, else a privacy-safe reason naming the CLASS of the difference
    /// and the fields in it (e.g. `freshness:selectedSourceHashes+catalogVersion`).
    ///
    /// The class is the part a capture could not previously act on. `inputs:` covered two opposite
    /// outcomes: an artifact for a DIFFERENT filter, which is never serviceable, and a stale copy
    /// of the RIGHT one, which `canServeAsLastKnownGood` accepts and which
    /// `serveLastKnownGoodOrFailClosed` now prefers over a superseded resident. The 2026-09-01
    /// filter-switch wedge was the second and read exactly like the first.
    ///
    /// Field NAMES only, never domain or host values, so it is safe to log.
    public func reuseMismatchReason(against other: PreparedFilterSnapshotIdentity) -> String? {
        let mismatches = snapshotInputMismatches(against: other)
        guard !mismatches.isEmpty else { return nil }
        let kind = differsOnlyInCatalogFreshness(from: other) ? "freshness" : "inputs"
        return "\(kind):\(mismatches.joined(separator: "+"))"
    }

    /// Returns whether configuration-derived inputs and the current parser version match.
    public func hasSameConfigurationInputs(as configuration: AppConfiguration) -> Bool {
        // The no-cached-catalog warm-start branch compares against the running
        // binary's parser rules version (configuration carries no artifact version),
        // so an artifact compiled under an older parser is rejected and regenerated.
        threatOverlapVersion == 1
            && parserRulesVersion == BlocklistParsingRules.rulesVersion
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
