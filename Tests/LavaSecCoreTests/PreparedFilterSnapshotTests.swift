import Foundation
import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class PreparedFilterSnapshotTests: XCTestCase {
    func testIdentityIsStableForUnorderedSets() {
        let first = AppConfiguration(
            enabledBlocklistIDs: ["b", "a"],
            allowedDomains: ["allow-b.example", "allow-a.example"],
            blockedDomains: ["block-b.example", "block-a.example"]
        )
        let second = AppConfiguration(
            enabledBlocklistIDs: ["a", "b"],
            allowedDomains: ["allow-a.example", "allow-b.example"],
            blockedDomains: ["block-a.example", "block-b.example"]
        )

        XCTAssertEqual(
            PreparedFilterSnapshotIdentity.make(configuration: first, catalog: nil),
            PreparedFilterSnapshotIdentity.make(configuration: second, catalog: nil)
        )
    }

    func testIdentityChangesWhenSelectedSourceVersionChanges() {
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let first = PreparedFilterSnapshotIdentity.make(
            configuration: configuration,
            catalog: Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
        )
        let second = PreparedFilterSnapshotIdentity.make(
            configuration: configuration,
            catalog: Self.catalog(sourceVersionID: "source-v2", guardrailVersionID: "guardrail-v1")
        )

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
    }

    func testIdentityChangesWhenGuardrailVersionChanges() {
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let first = PreparedFilterSnapshotIdentity.make(
            configuration: configuration,
            catalog: Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
        )
        let second = PreparedFilterSnapshotIdentity.make(
            configuration: configuration,
            catalog: Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v2")
        )

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
    }

    func testIdentityDoesNotChangeForResolverOnlyChange() {
        let first = AppConfiguration(resolverPresetID: DNSResolverPreset.google.id)
        let second = AppConfiguration(resolverPresetID: DNSResolverPreset.cloudflare.id)

        XCTAssertEqual(
            PreparedFilterSnapshotIdentity.make(configuration: first, catalog: nil),
            PreparedFilterSnapshotIdentity.make(configuration: second, catalog: nil)
        )
    }

    func testIdentityChangesWhenSwitchingBetweenPlainAndDoHResolverPresets() {
        let plain = AppConfiguration(resolverPresetID: DNSResolverPreset.cloudflare.id)
        let doh = AppConfiguration(resolverPresetID: DNSResolverPreset.cloudflareDoH.id)

        XCTAssertNotEqual(
            PreparedFilterSnapshotIdentity.make(configuration: plain, catalog: nil),
            PreparedFilterSnapshotIdentity.make(configuration: doh, catalog: nil)
        )
    }

    func testIdentityChangesWhenSwitchingBetweenPlainAndDoTResolverPresets() {
        let plain = AppConfiguration(resolverPresetID: DNSResolverPreset.cloudflare.id)
        let dot = AppConfiguration(resolverPresetID: DNSResolverPreset.cloudflareDoT.id)

        XCTAssertNotEqual(
            PreparedFilterSnapshotIdentity.make(configuration: plain, catalog: nil),
            PreparedFilterSnapshotIdentity.make(configuration: dot, catalog: nil)
        )
    }

    func testPreparedSnapshotMatchesIdentity() {
        let configuration = AppConfiguration(blockedDomains: ["block.example"])
        let identity = PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil)
        let prepared = PreparedFilterSnapshot(
            identity: identity,
            snapshot: configuration.filterSnapshot()
        )

        XCTAssertTrue(prepared.matches(identity: identity))
        XCTAssertTrue(prepared.identity.hasSameConfiguration(as: configuration))
        XCTAssertFalse(prepared.identity.hasSameConfiguration(as: AppConfiguration()))
    }

    func testPreparedSnapshotCanBeReusedForMatchingCachedCatalog() {
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let catalog = Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
        let prepared = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: catalog),
            snapshot: configuration.filterSnapshot(),
            summary: PreparedFilterSnapshotSummary(
                snapshot: configuration.filterSnapshot(),
                blocklistRuleCount: 1,
                blocklistSourceRuleCounts: ["source-a": 1]
            )
        )

        XCTAssertTrue(prepared.canReuseForProtectionStartup(configuration: configuration, cachedCatalog: catalog))
    }

    func testDecodedPreparedSnapshotCanBeReusedForMatchingCachedCatalog() throws {
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let catalog = Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
        let prepared = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: catalog),
            snapshot: configuration.filterSnapshot(),
            summary: PreparedFilterSnapshotSummary(
                snapshot: configuration.filterSnapshot(),
                blocklistRuleCount: 7,
                blocklistSourceRuleCounts: ["source-a": 7]
            )
        )

        let decoded = try JSONDecoder().decode(PreparedFilterSnapshot.self, from: JSONEncoder().encode(prepared))

        XCTAssertEqual(decoded.summary.blocklistSourceRuleCounts, ["source-a": 7])
        XCTAssertTrue(decoded.canReuseForProtectionStartup(configuration: configuration, cachedCatalog: catalog))
    }

    func testPreparedSnapshotRejectsChangedCachedCatalog() {
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let prepared = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(
                configuration: configuration,
                catalog: Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
            ),
            snapshot: configuration.filterSnapshot()
        )

        XCTAssertFalse(
            prepared.canReuseForProtectionStartup(
                configuration: configuration,
                cachedCatalog: Self.catalog(sourceVersionID: "source-v2", guardrailVersionID: "guardrail-v1")
            )
        )
    }

    func testPreparedSnapshotRejectsBlocklistReuseWithoutCatalogMetadata() {
        let configuration = AppConfiguration(
            enabledBlocklistIDs: ["source-a"],
            allowedDomains: ["allow.example"],
            blockedDomains: ["block.example"]
        )
        let prepared = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(
                configuration: configuration,
                catalog: Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
            ),
            snapshot: configuration.filterSnapshot(),
            summary: PreparedFilterSnapshotSummary(
                snapshot: configuration.filterSnapshot(),
                blocklistRuleCount: 1,
                blocklistSourceRuleCounts: ["source-a": 1]
            )
        )

        XCTAssertFalse(prepared.canReuseForProtectionStartup(configuration: configuration, cachedCatalog: nil))
        XCTAssertFalse(prepared.canReuseForProtectionStartup(configuration: AppConfiguration(), cachedCatalog: nil))
    }

    func testPreparedSnapshotCanBeReusedWithoutCatalogMetadataForManualRulesOnly() {
        let configuration = AppConfiguration(
            allowedDomains: ["allow.example"],
            blockedDomains: ["block.example"]
        )
        let prepared = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil),
            snapshot: configuration.filterSnapshot()
        )

        XCTAssertTrue(prepared.canReuseForProtectionStartup(configuration: configuration, cachedCatalog: nil))
        XCTAssertFalse(prepared.canReuseForProtectionStartup(configuration: AppConfiguration(), cachedCatalog: nil))
    }

    func testPreparedSnapshotReuseUsesStoredResolverTransportWhenLegacyIdentityIsPlain() {
        let plain = AppConfiguration(resolverPresetID: DNSResolverPreset.cloudflare.id)
        let doh = AppConfiguration(resolverPresetID: DNSResolverPreset.cloudflareDoH.id)
        let prepared = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: plain, catalog: nil),
            snapshot: doh.filterSnapshot()
        )

        XCTAssertFalse(prepared.canReuseForProtectionStartup(configuration: plain, cachedCatalog: nil))
        XCTAssertTrue(prepared.canReuseForProtectionStartup(configuration: doh, cachedCatalog: nil))
    }

    func testPassThroughSnapshotIsNotReusableForFilteredConfiguration() {
        let filtered = AppConfiguration(
            enabledBlocklistIDs: ["source-a"],
            allowedDomains: ["allowed.example.com"],
            blockedDomains: ["manual.example.com"]
        )
        let passThroughConfiguration = AppConfiguration(resolverPresetID: filtered.resolverPresetID)
        let passThrough = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: passThroughConfiguration, catalog: nil),
            snapshot: FilterSnapshot(blockRules: DomainRuleSet(), resolver: filtered.resolverPreset)
        )

        XCTAssertFalse(passThrough.canReuseForProtectionStartup(configuration: filtered, cachedCatalog: nil))
    }

    func testDecodedPreparedSnapshotRecomputesStoredProtectedCount() throws {
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "linkedin.com", matchesSubdomains: true)
        try blockRules.insert(domain: "www.linkedin.com", matchesSubdomains: true)
        try blockRules.insert(domain: "static.linkedin.com", matchesSubdomains: true)
        try blockRules.insert(domain: "manual.example.com", matchesSubdomains: true)

        var allowRules = DomainRuleSet()
        try allowRules.insert(domain: "linkedin.com", matchesSubdomains: true)

        let configuration = AppConfiguration(allowedDomains: ["linkedin.com"])
        let prepared = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil),
            snapshot: FilterSnapshot(blockRules: blockRules, allowRules: allowRules),
            summary: PreparedFilterSnapshotSummary(
                blocklistRuleCount: nil,
                blockRuleCount: 4,
                blockedDomainRuleCount: 1,
                allowRuleCount: 1,
                guardrailRuleCount: 0
            )
        )

        let decoded = try JSONDecoder().decode(PreparedFilterSnapshot.self, from: JSONEncoder().encode(prepared))

        XCTAssertEqual(decoded.summary.blockRuleCount, 4)
        XCTAssertEqual(decoded.summary.allowRuleCount, 1)
        XCTAssertEqual(decoded.summary.blockedDomainRuleCount, 3)
    }

    func testLegacyArtifactWithoutParserRulesVersionIsNotReused() throws {
        // Emulates an on-disk artifact compiled before parserRulesVersion existed:
        // its persisted JSON has no parserRulesVersion key, so it must decode as a
        // legacy version (0) and be rejected for reuse — forcing regeneration on
        // upgrade rather than serving a snapshot built by the old parser (e.g. one
        // that kept only the first host of a multi-host `0.0.0.0 a b c` line).
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let catalog = Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
        let prepared = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: catalog),
            snapshot: configuration.filterSnapshot(),
            summary: PreparedFilterSnapshotSummary(
                snapshot: configuration.filterSnapshot(),
                blocklistRuleCount: 1,
                blocklistSourceRuleCounts: ["source-a": 1]
            )
        )

        // An artifact compiled under the current parser reuses fine.
        XCTAssertTrue(prepared.canReuseForProtectionStartup(configuration: configuration, cachedCatalog: catalog))

        // Strip the parserRulesVersion key to simulate a pre-field artifact.
        let encoded = try JSONEncoder().encode(prepared)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var identity = try XCTUnwrap(object["identity"] as? [String: Any])
        identity.removeValue(forKey: "parserRulesVersion")
        object["identity"] = identity
        let legacy = try JSONDecoder().decode(
            PreparedFilterSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(legacy.identity.parserRulesVersion, 0)
        XCTAssertFalse(legacy.canReuseForProtectionStartup(configuration: configuration, cachedCatalog: catalog))
    }

    func testParserRulesVersionMismatchRejectsManualRulesWarmStartReuse() {
        // The no-cached-catalog (manual-rules-only) warm-start branch must also reject
        // an artifact compiled under an older parser.
        let configuration = AppConfiguration(blockedDomains: ["block.example"])
        let current = PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil)
        XCTAssertTrue(current.hasSameConfigurationInputs(as: configuration))

        let legacy = PreparedFilterSnapshotIdentity(
            enabledBlocklistIDs: current.enabledBlocklistIDs,
            blockedDomains: current.blockedDomains,
            allowedDomains: current.allowedDomains,
            resolverTransport: current.resolverTransport,
            qaProbeSet: current.qaProbeSet,
            catalogVersion: current.catalogVersion,
            selectedSourceVersionIDs: current.selectedSourceVersionIDs,
            selectedSourceHashes: current.selectedSourceHashes,
            customBlocklistFingerprints: current.customBlocklistFingerprints,
            guardrailVersionIDs: current.guardrailVersionIDs,
            guardrailHashes: current.guardrailHashes,
            parserRulesVersion: BlocklistParsingRules.rulesVersion - 1
        )

        XCTAssertFalse(legacy.hasSameConfigurationInputs(as: configuration))
        XCTAssertEqual(legacy.snapshotInputMismatches(against: current), ["parserRulesVersion"])
    }

    private static func catalog(
        sourceVersionID: String,
        guardrailVersionID: String
    ) -> BlocklistCatalog {
        BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "catalog-\(sourceVersionID)-\(guardrailVersionID)",
            generatedAt: Date(timeIntervalSince1970: 1_000),
            sources: [
                source(
                    id: "source-a",
                    name: "Source A",
                    versionID: sourceVersionID,
                    normalizedHash: "source-hash-\(sourceVersionID)"
                )
            ],
            guardrails: [
                source(
                    id: "guardrail-a",
                    name: "Guardrail A",
                    versionID: guardrailVersionID,
                    normalizedHash: "guardrail-hash-\(guardrailVersionID)"
                )
            ]
        )
    }

    private static func source(
        id: String,
        name: String,
        versionID: String,
        normalizedHash: String
    ) -> CatalogBlocklistSource {
        CatalogBlocklistSource(
            id: id,
            name: name,
            category: "security",
            riskLevel: "normal",
            defaultEnabled: false,
            licenseName: "MIT",
            attribution: "",
            projectURL: URL(string: "https://example.com/project")!,
            sourceURL: URL(string: "https://example.com/source.txt")!,
            versionID: versionID,
            entryCount: 10,
            byteSize: 100,
            sourceHash: "source-hash",
            normalizedHash: normalizedHash,
            publishedAt: Date(timeIntervalSince1970: 1_000),
            redistributionMode: "source_url_only",
            parseFormat: .plainDomains,
            licenseTextURL: nil,
            noticeURL: nil
        )
    }
}
