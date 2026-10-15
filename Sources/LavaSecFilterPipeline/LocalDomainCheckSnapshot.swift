import Foundation
import LavaSecKit

/// A read-only view of a published compact artifact; never compiles or performs network I/O.
public struct LocalDomainCheckSnapshot: Sendable {
    public let revision: String
    public let directoryURL: URL
    private let manifest: FilterArtifactManifest
    private let snapshot: CompactFilterSnapshot

    public func matches(configuration: AppConfiguration, catalog: BlocklistCatalog?) -> Bool {
        manifest.reuseRejectionReason(configuration: configuration, cachedCatalog: catalog) == nil
            && FilterRuleBudget.fitsTierBudget(recordedTotal: manifest.summary.tierBudgetRuleCount,
                                              maxFilterRules: configuration.limits.maxFilterRules)
    }

    public func decision(for input: DomainCheckInput) -> FilterDecision {
        snapshot.decision(forNormalizedDomain: input.domain)
    }

    public static func load(configuration: AppConfiguration, catalog: BlocklistCatalog?,
                            store: FilterArtifactStore) throws -> Self? {
        let resolved = store.readableStore()
        guard let manifest = try resolved.loadManifest(),
              manifest.reuseRejectionReason(configuration: configuration, cachedCatalog: catalog) == nil,
              manifest.summary.coversEnabledBlocklists(in: configuration),
              (manifest.summary.quarantinedBlocklistIDs ?? []).isEmpty,
              FilterRuleBudget.fitsTierBudget(recordedTotal: manifest.summary.tierBudgetRuleCount,
                                             maxFilterRules: configuration.limits.maxFilterRules),
              manifest.availableArtifacts.contains(.compact),
              manifest.compactSchemaVersion == CompactFilterSnapshot.fileVersion,
              let expectedHash = manifest.compactPayloadSHA256 else { return nil }
        let data = try Data(contentsOf: resolved.compactSnapshotURL, options: [.mappedIfSafe])
        guard let bootstrap = try? CompactFilterSnapshot.readSyncBootstrapInfo(from: data), bootstrap.hasStoredSummary,
              !FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: bootstrap.totalRuleCount) else { return nil }
        guard try FilterArtifactStore.compactPayloadChecksum(data) == expectedHash else { return nil }
        let summary = try CompactFilterSnapshot.readSummary(from: data)
        let recorded = PreparedFilterSnapshotSummary(blocklistRuleCount: summary.blocklistRuleCount,
            blocklistSourceRuleCounts: summary.blocklistSourceRuleCounts, blockRuleCount: summary.blockRuleCount,
            blockedDomainRuleCount: summary.blockedDomainRuleCount, allowRuleCount: summary.allowRuleCount,
            guardrailRuleCount: summary.guardrailRuleCount, tierBudgetRuleCount: summary.tierBudgetRuleCount,
            quarantinedBlocklistIDs: summary.quarantinedBlocklistIDs)
        guard summary.identity == manifest.snapshotIdentity, summary.generatedAt == manifest.generatedAt,
              recorded == manifest.summary,
              summary.canReuseForProtectionStartup(configuration: configuration, cachedCatalog: catalog),
              !FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: summary.blockRuleCount
                  + summary.allowRuleCount + summary.guardrailRuleCount) else { return nil }
        let snapshot = try CompactFilterSnapshot.decode(from: data)
        return Self(revision: manifest.snapshotIdentity.fingerprint + ":" + expectedHash,
                    directoryURL: resolved.directoryURL, manifest: manifest, snapshot: snapshot)
    }
}
