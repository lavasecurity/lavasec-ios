import Foundation
import XCTest
@testable import LavaSecCore

final class CompactFilterSnapshotTests: XCTestCase {
    func testDecodeRejectsUnsortedRuleTable() throws {
        // Two subdomain (suffix) rules of equal length → blockRules has 0 exact + 2
        // suffix entries (6 bytes each), byte-sorted as a/b. The binary-search lookup
        // relies on that order, so a corrupted (unsorted) table must fail CLOSED.
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "a.example.com", matchesSubdomains: true)
        try blockRules.insert(domain: "b.example.com", matchesSubdomains: true)
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let prepared = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil),
            snapshot: FilterSnapshot(blockRules: blockRules)
        )
        let data = try CompactFilterSnapshot(preparedSnapshot: prepared).encodedData()
        XCTAssertNoThrow(try CompactFilterSnapshot.decode(from: data), "the sorted table must decode fine")

        // Layout: magic(8) + version(4) + metaLen(4) + meta(N) + blockRules table
        // [exactCount(4) + suffixCount(4) + suffix entries…]. Swap the two 6-byte
        // suffix-entry records to break the sorted order.
        var bytes = [UInt8](data)
        let metaLen = Int(UInt32(bytes[12]) | (UInt32(bytes[13]) << 8) | (UInt32(bytes[14]) << 16) | (UInt32(bytes[15]) << 24))
        let entryStart = 24 + metaLen
        for offset in 0..<6 {
            bytes.swapAt(entryStart + offset, entryStart + 6 + offset)
        }

        XCTAssertThrowsError(try CompactFilterSnapshot.decode(from: Data(bytes))) { error in
            XCTAssertEqual(error as? CompactFilterSnapshotError, .invalidRuleTable)
        }
    }

    func testCompactSnapshotRoundTripPreservesDecisionOrdering() throws {
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "ads.example.com", matchesSubdomains: true)
        try blockRules.insert(domain: "exact-block.example.com", matchesSubdomains: false)

        var allowRules = DomainRuleSet()
        try allowRules.insert(domain: "trusted.ads.example.com", matchesSubdomains: true)

        var guardrailRules = DomainRuleSet()
        try guardrailRules.insert(domain: "danger.example.com", matchesSubdomains: true)

        let configuration = AppConfiguration(
            enabledBlocklistIDs: ["source-a"],
            allowedDomains: ["trusted.ads.example.com"],
            resolverPresetID: DNSResolverPreset.cloudflareDoH.id
        )
        let prepared = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil),
            snapshot: FilterSnapshot(
                generatedAt: Date(timeIntervalSince1970: 1_234),
                blockRules: blockRules,
                allowRules: allowRules,
                nonAllowableThreatRules: guardrailRules,
                resolver: .cloudflareDoH
            )
        )

        let compact = CompactFilterSnapshot(preparedSnapshot: prepared)
        let decoded = try CompactFilterSnapshot.decode(from: compact.encodedData())
        let summary = try CompactFilterSnapshot.readSummary(from: compact.encodedData())

        XCTAssertTrue(decoded.matches(identity: prepared.identity))
        XCTAssertEqual(decoded.resolver, .cloudflareDoH)
        XCTAssertEqual(decoded.blockRuleCount, 2)
        XCTAssertEqual(decoded.allowRuleCount, 1)
        XCTAssertEqual(decoded.guardrailRuleCount, 1)
        XCTAssertEqual(summary.identity, prepared.identity)
        XCTAssertEqual(summary.resolver, .cloudflareDoH)
        XCTAssertEqual(summary.blockRuleCount, 2)
        XCTAssertEqual(summary.allowRuleCount, 1)
        XCTAssertEqual(summary.guardrailRuleCount, 1)
        XCTAssertEqual(decoded.decision(for: "danger.example.com").reason, .threatGuardrail)
        XCTAssertEqual(decoded.decision(for: "trusted.ads.example.com").reason, .localAllowlist)
        XCTAssertEqual(decoded.decision(for: "cdn.ads.example.com").reason, .blocklist)
        XCTAssertEqual(decoded.decision(for: "exact-block.example.com").reason, .blocklist)
        XCTAssertEqual(decoded.decision(for: "sub.exact-block.example.com").reason, .defaultAllow)
        XCTAssertEqual(decoded.decision(for: "apple.com"), .defaultAllow)
    }

    func testCompactEncodingUsesBinaryArtifactShape() throws {
        var blockRules = DomainRuleSet()
        for index in 0..<2_000 {
            try blockRules.insert(domain: "tracker-\(index).example.com", matchesSubdomains: true)
        }

        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let prepared = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil),
            snapshot: FilterSnapshot(blockRules: blockRules)
        )

        let compactData = try CompactFilterSnapshot(preparedSnapshot: prepared).encodedData()

        XCTAssertEqual(String(decoding: compactData.prefix(8), as: UTF8.self), "LSCFSNP1")
        XCTAssertNotEqual(compactData.first, UInt8(ascii: "{"))
        XCTAssertEqual(try CompactFilterSnapshot.decode(from: compactData).blockRuleCount, 2_000)
    }

    func testCompactSummaryCachesPreparedBlocklistRuleCountSeparatelyFromTotalBlockRules() throws {
        var blocklistRules = DomainRuleSet()
        try blocklistRules.insert(domain: "ads.example.com", matchesSubdomains: true)
        try blocklistRules.insert(domain: "malware.example.com", matchesSubdomains: true)

        var totalBlockRules = blocklistRules
        try totalBlockRules.insert(domain: "manual.example.com", matchesSubdomains: true)

        let configuration = AppConfiguration(
            enabledBlocklistIDs: ["source-a"],
            blockedDomains: ["manual.example.com"]
        )
        let prepared = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil),
            snapshot: FilterSnapshot(blockRules: totalBlockRules),
            summary: PreparedFilterSnapshotSummary(
                blocklistRuleCount: blocklistRules.count,
                blockRuleCount: totalBlockRules.count,
                allowRuleCount: 0,
                guardrailRuleCount: 0
            )
        )

        let summary = try CompactFilterSnapshot.readSummary(
            from: CompactFilterSnapshot(preparedSnapshot: prepared).encodedData()
        )

        XCTAssertEqual(summary.blocklistRuleCount, 2)
        XCTAssertEqual(summary.blockRuleCount, 3)
        XCTAssertEqual(summary.blockedDomainRuleCount, 3)
    }

    func testCompactRoundTripPreservesBlocklistSourceRuleCounts() throws {
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

        let data = try CompactFilterSnapshot(preparedSnapshot: prepared).encodedData()
        let decoded = try CompactFilterSnapshot.decode(from: data)
        let summary = try CompactFilterSnapshot.readSummary(from: data)

        XCTAssertEqual(decoded.summary.blocklistSourceRuleCounts, ["source-a": 7])
        XCTAssertEqual(summary.blocklistSourceRuleCounts, ["source-a": 7])
        XCTAssertTrue(decoded.canReuseForProtectionStartup(configuration: configuration, cachedCatalog: catalog))
        XCTAssertTrue(summary.coversEnabledBlocklists(in: configuration))
    }

    func testDecodeFromNonZeroStartIndexDataResolvesDecisionsCorrectly() throws {
        // The compact reader returns zero-copy slices over the backing Data so
        // the domain table stays file-backed (mmap) instead of a heap copy. The
        // resulting domainData has a non-zero startIndex, and decoding from a
        // Data that is ITSELF a non-zero-startIndex slice (e.g. an mmap region
        // embedded with leading bytes) must still resolve every decision.
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "ads.example.com", matchesSubdomains: true)
        try blockRules.insert(domain: "exact-block.example.com", matchesSubdomains: false)
        var allowRules = DomainRuleSet()
        try allowRules.insert(domain: "trusted.ads.example.com", matchesSubdomains: true)

        let prepared = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(
                configuration: AppConfiguration(enabledBlocklistIDs: ["source-a"]),
                catalog: nil
            ),
            snapshot: FilterSnapshot(blockRules: blockRules, allowRules: allowRules)
        )
        let encoded = try CompactFilterSnapshot(preparedSnapshot: prepared).encodedData()

        // Embed the artifact at a non-zero offset, then slice it back out so the
        // reader operates over a Data whose startIndex != 0.
        var padded = Data(repeating: 0xAB, count: 7)
        padded.append(encoded)
        let offsetData = padded[padded.startIndex.advanced(by: 7)...]
        XCTAssertNotEqual(offsetData.startIndex, 0)

        let decoded = try CompactFilterSnapshot.decode(from: offsetData)
        XCTAssertEqual(decoded.blockRuleCount, 2)
        XCTAssertEqual(decoded.allowRuleCount, 1)
        XCTAssertEqual(decoded.decision(for: "cdn.ads.example.com").reason, .blocklist)
        XCTAssertEqual(decoded.decision(for: "trusted.ads.example.com").reason, .localAllowlist)
        XCTAssertEqual(decoded.decision(for: "exact-block.example.com").reason, .blocklist)
        XCTAssertEqual(decoded.decision(for: "apple.com"), .defaultAllow)
        // Re-encode from the slice-backed snapshot must round-trip to an
        // equivalent snapshot (metadata JSON key order is not byte-stable, so
        // compare decoded rule counts/decisions, not raw bytes).
        let reDecoded = try CompactFilterSnapshot.decode(from: decoded.encodedData())
        XCTAssertEqual(reDecoded.blockRuleCount, 2)
        XCTAssertEqual(reDecoded.decision(for: "cdn.ads.example.com").reason, .blocklist)
    }

    func testSummaryReuseGateMatchesFullSnapshotWithoutMaterializingRuleTables() throws {
        // The live-reload no-op gate decides whether to skip the multi-megabyte
        // decode using ONLY the summary, so the summary's reuse verdict must
        // match the full snapshot's exactly.
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

        let data = try CompactFilterSnapshot(preparedSnapshot: prepared).encodedData()
        let decoded = try CompactFilterSnapshot.decode(from: data)
        let summary = try CompactFilterSnapshot.readSummary(from: data)

        // Identity preserved through the cheap read.
        XCTAssertTrue(summary.identity.hasSameSnapshotInputs(as: decoded.identity))

        // Match on the reusable case.
        XCTAssertTrue(decoded.canReuseForProtectionStartup(configuration: configuration, cachedCatalog: catalog))
        XCTAssertTrue(summary.canReuseForProtectionStartup(configuration: configuration, cachedCatalog: catalog))

        // Match when the resolver transport differs (not reusable).
        let differentTransport = AppConfiguration(
            enabledBlocklistIDs: ["source-a"],
            resolverPresetID: DNSResolverPreset.cloudflareDoH.id
        )
        XCTAssertEqual(
            summary.canReuseForProtectionStartup(configuration: differentTransport, cachedCatalog: catalog),
            decoded.canReuseForProtectionStartup(configuration: differentTransport, cachedCatalog: catalog)
        )

        // Match when an additional list is enabled that the artifact does not
        // cover (the genuine-change case the gate must NOT skip).
        let extraList = AppConfiguration(enabledBlocklistIDs: ["source-a", "source-b"])
        XCTAssertFalse(summary.canReuseForProtectionStartup(configuration: extraList, cachedCatalog: catalog))
        XCTAssertEqual(
            summary.canReuseForProtectionStartup(configuration: extraList, cachedCatalog: catalog),
            decoded.canReuseForProtectionStartup(configuration: extraList, cachedCatalog: catalog)
        )
    }

    func testCompactSummarySubtractsAllowedExceptionThatOverlapsBlockedDomain() throws {
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "ads.example.com", matchesSubdomains: true)
        try blockRules.insert(domain: "cdn.ads.example.com", matchesSubdomains: true)
        try blockRules.insert(domain: "malware.example.com", matchesSubdomains: true)
        try blockRules.insert(domain: "manual.example.com", matchesSubdomains: true)

        var allowRules = DomainRuleSet()
        try allowRules.insert(domain: "ads.example.com", matchesSubdomains: true)

        let configuration = AppConfiguration(
            enabledBlocklistIDs: ["source-a"],
            allowedDomains: ["ads.example.com"],
            blockedDomains: ["manual.example.com"]
        )
        let prepared = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil),
            snapshot: FilterSnapshot(blockRules: blockRules, allowRules: allowRules),
            summary: PreparedFilterSnapshotSummary(snapshot: FilterSnapshot(blockRules: blockRules, allowRules: allowRules))
        )

        let summary = try CompactFilterSnapshot.readSummary(
            from: CompactFilterSnapshot(preparedSnapshot: prepared).encodedData()
        )

        XCTAssertEqual(summary.blockRuleCount, 4)
        XCTAssertEqual(summary.allowRuleCount, 1)
        XCTAssertEqual(summary.blockedDomainRuleCount, 3)
    }

    func testCompactSummaryDoesNotSubtractAllowedExceptionOutsideBlockedDomains() throws {
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "ads.example.com", matchesSubdomains: true)
        try blockRules.insert(domain: "malware.example.com", matchesSubdomains: true)
        try blockRules.insert(domain: "manual.example.com", matchesSubdomains: true)

        var allowRules = DomainRuleSet()
        try allowRules.insert(domain: "school.example.com", matchesSubdomains: true)

        let configuration = AppConfiguration(
            enabledBlocklistIDs: ["source-a"],
            allowedDomains: ["school.example.com"],
            blockedDomains: ["manual.example.com"]
        )
        let prepared = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil),
            snapshot: FilterSnapshot(blockRules: blockRules, allowRules: allowRules),
            summary: PreparedFilterSnapshotSummary(snapshot: FilterSnapshot(blockRules: blockRules, allowRules: allowRules))
        )

        let summary = try CompactFilterSnapshot.readSummary(
            from: CompactFilterSnapshot(preparedSnapshot: prepared).encodedData()
        )

        XCTAssertEqual(summary.blockRuleCount, 3)
        XCTAssertEqual(summary.allowRuleCount, 1)
        XCTAssertEqual(summary.blockedDomainRuleCount, 3)
    }

    func testCompactSummarySubtractsAllowedExceptionEvenWhenGuardrailMatches() throws {
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "danger.example.com", matchesSubdomains: true)

        var allowRules = DomainRuleSet()
        try allowRules.insert(domain: "danger.example.com", matchesSubdomains: true)

        var guardrailRules = DomainRuleSet()
        try guardrailRules.insert(domain: "danger.example.com", matchesSubdomains: true)

        let snapshot = FilterSnapshot(
            blockRules: blockRules,
            allowRules: allowRules,
            nonAllowableThreatRules: guardrailRules
        )
        let prepared = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: AppConfiguration(), catalog: nil),
            snapshot: snapshot,
            summary: PreparedFilterSnapshotSummary(snapshot: snapshot)
        )

        let summary = try CompactFilterSnapshot.readSummary(
            from: CompactFilterSnapshot(preparedSnapshot: prepared).encodedData()
        )

        XCTAssertEqual(summary.blockRuleCount, 1)
        XCTAssertEqual(summary.allowRuleCount, 1)
        XCTAssertEqual(summary.blockedDomainRuleCount, 0)
    }

    func testCompactSummaryRecomputesStoredProtectedCount() throws {
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

        let data = try CompactFilterSnapshot(preparedSnapshot: prepared).encodedData()
        let summary = try CompactFilterSnapshot.readSummary(from: data)
        let decoded = try CompactFilterSnapshot.decode(from: data)

        XCTAssertEqual(summary.blockRuleCount, 4)
        XCTAssertEqual(summary.allowRuleCount, 1)
        XCTAssertEqual(summary.blockedDomainRuleCount, 3)
        XCTAssertEqual(decoded.summary.blockedDomainRuleCount, 3)
    }

    func testCompactDecoderRejectsInvalidData() {
        XCTAssertThrowsError(try CompactFilterSnapshot.decode(from: Data("not lava compact data".utf8)))
    }

    func testCheapSummaryReadMatchesFullDecodeWithoutRuleTableMaterialization() throws {
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "ads.example.com", matchesSubdomains: true)
        try blockRules.insert(domain: "tracker.example.net", matchesSubdomains: true)

        var allowRules = DomainRuleSet()
        try allowRules.insert(domain: "ads.example.com", matchesSubdomains: true)

        let configuration = AppConfiguration(
            enabledBlocklistIDs: ["source-a"],
            allowedDomains: ["ads.example.com"]
        )
        let prepared = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil),
            snapshot: FilterSnapshot(blockRules: blockRules, allowRules: allowRules),
            summary: PreparedFilterSnapshotSummary(
                blocklistRuleCount: 2,
                blocklistSourceRuleCounts: ["source-a": 2],
                blockRuleCount: 2,
                blockedDomainRuleCount: 1,
                allowRuleCount: 1,
                guardrailRuleCount: 0
            )
        )
        let data = try CompactFilterSnapshot(preparedSnapshot: prepared).encodedData()

        let summary = try CompactFilterSnapshot.readSummary(from: data)
        let decoded = try CompactFilterSnapshot.decode(from: data)

        XCTAssertEqual(summary.blockRuleCount, decoded.summary.blockRuleCount)
        XCTAssertEqual(summary.blockedDomainRuleCount, decoded.summary.blockedDomainRuleCount)
        XCTAssertEqual(summary.allowRuleCount, decoded.summary.allowRuleCount)
        XCTAssertEqual(summary.guardrailRuleCount, decoded.summary.guardrailRuleCount)
        XCTAssertEqual(summary.blocklistRuleCount, decoded.summary.blocklistRuleCount)
        XCTAssertEqual(summary.blocklistSourceRuleCounts, decoded.summary.blocklistSourceRuleCounts)
        XCTAssertEqual(summary.identity, decoded.identity)
        XCTAssertEqual(summary.resolver, decoded.resolver)
    }

    func testCheapSummaryReadStillRejectsTruncatedRuleTables() throws {
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "ads.example.com", matchesSubdomains: true)

        let configuration = AppConfiguration(allowedDomains: [])
        let prepared = PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: nil),
            snapshot: FilterSnapshot(blockRules: blockRules)
        )
        let data = try CompactFilterSnapshot(preparedSnapshot: prepared).encodedData()

        let truncated = data.prefix(data.count - 8)
        XCTAssertThrowsError(try CompactFilterSnapshot.readSummary(from: truncated))
    }

    func testCompactSnapshotReuseUsesStoredResolverTransportWhenLegacyIdentityIsPlain() {
        let plain = AppConfiguration(resolverPresetID: DNSResolverPreset.cloudflare.id)
        let doh = AppConfiguration(resolverPresetID: DNSResolverPreset.cloudflareDoH.id)
        let compact = CompactFilterSnapshot(preparedSnapshot: PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: plain, catalog: nil),
            snapshot: doh.filterSnapshot()
        ))

        XCTAssertFalse(compact.canReuseForProtectionStartup(configuration: plain, cachedCatalog: nil))
        XCTAssertTrue(compact.canReuseForProtectionStartup(configuration: doh, cachedCatalog: nil))
    }

    func testCompactSnapshotRejectsBlocklistReuseWithoutCatalogMetadata() throws {
        let configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        let compact = CompactFilterSnapshot(preparedSnapshot: PreparedFilterSnapshot(
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
        ))

        XCTAssertFalse(compact.canReuseForProtectionStartup(configuration: configuration, cachedCatalog: nil))
        XCTAssertTrue(compact.canReuseForProtectionStartup(
            configuration: configuration,
            cachedCatalog: Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
        ))
        let decoded = try CompactFilterSnapshot.decode(from: compact.encodedData())
        XCTAssertTrue(decoded.canReuseForProtectionStartup(
            configuration: configuration,
            cachedCatalog: Self.catalog(sourceVersionID: "source-v1", guardrailVersionID: "guardrail-v1")
        ))
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

    // MARK: - Byte-level `containsNormalized` equivalence

    /// Reference implementation of the pre-optimization `containsNormalized`
    /// semantics: exact-or-suffix membership, then strip leading labels checking
    /// the suffix set. Implemented purely with `String`/`Set`, so it is
    /// independent of the byte-level binary search under test and serves as the
    /// verdict oracle.
    private func referenceContains(
        _ query: String,
        exact: Set<String>,
        suffix: Set<String>
    ) -> Bool {
        if exact.contains(query) || suffix.contains(query) {
            return true
        }
        var remainder = query
        while let dotIndex = remainder.firstIndex(of: ".") {
            remainder = String(remainder[remainder.index(after: dotIndex)...])
            if suffix.contains(remainder) {
                return true
            }
        }
        return false
    }

    func testByteLevelContainsMatchesReferenceAcrossCuratedDomains() {
        let exact: Set<String> = [
            "exact.example.org",
            "single.test",
            "a.co",
            "portal.bank.example",
            "news.example.com",
            "x-ray.example.net",
            "a0.example.net",
            "ab.example.net"
        ]
        let suffix: Set<String> = [
            "example.com",
            "ads.net",
            "tracker.io",
            "a.co",
            "deep.nested.example.org",
            "cdn.example.io",
            "z.example.com",
            "abc.example.net"
        ]

        let ruleSet = CompactDomainRuleSet(
            exactDomains: Array(exact),
            suffixDomains: Array(suffix)
        )

        // Queries span: exact hits, suffix exact hits, single- and multi-label
        // suffix strips, non-matches, prefix collisions (query is a prefix of an
        // entry and vice versa), `-`/digit byte-ordering boundaries, and
        // lexicographic extremes that sort before/after every entry.
        let queries = [
            "exact.example.org",
            "single.test",
            "www.example.com",
            "a.b.c.example.com",
            "example.com",
            "metrics.ads.net",
            "ads.net",
            "tracker.io",
            "sub.tracker.io",
            "a.co",
            "x.a.co",
            "deep.nested.example.org",
            "more.deep.nested.example.org",
            "nested.example.org",
            "cdn.example.io",
            "node.cdn.example.io",
            "example.io",
            "news.example.com",
            "ab.example.net",
            "a0.example.net",
            "x-ray.example.net",
            "abc.example.net",
            "sub.abc.example.net",
            "abcd.example.net",
            "aaaaa.example.test",
            "zzzzz.zzzzz.zzz",
            "co",
            "a.co.uk",
            "portal.bank.example",
            "other.bank.example",
            "z.example.com",
            "really.z.example.com"
        ]

        for query in queries {
            XCTAssertEqual(
                ruleSet.containsNormalized(query),
                referenceContains(query, exact: exact, suffix: suffix),
                "containsNormalized mismatch for query \(query)"
            )
        }
    }

    func testByteLevelContainsMatchesReferenceOnGeneratedCorpus() {
        // Deterministic, reproducible corpus — short labels maximize prefix
        // collisions (stressing the binary search's comparison boundaries), and
        // `-`/digit labels exercise byte ordering versus `String` ordering.
        var rng = SeededGenerator(seed: 0x9E37_79B9_7F4A_7C15)
        let labels = ["a", "b", "ab", "abc", "z", "a0", "a-b", "x", "00", "m", "node", "cdn", "ads"]
        let tlds = ["com", "net", "io", "co", "org", "test"]

        func randomDomain() -> String {
            let labelCount = 2 + Int(rng.next() % 3) // 2...4 labels
            var parts: [String] = []
            for _ in 0..<(labelCount - 1) {
                parts.append(labels[Int(rng.next() % UInt64(labels.count))])
            }
            parts.append(tlds[Int(rng.next() % UInt64(tlds.count))])
            return parts.joined(separator: ".")
        }

        var exact = Set<String>()
        var suffix = Set<String>()
        for _ in 0..<200 {
            if rng.next() % 2 == 0 {
                exact.insert(randomDomain())
            } else {
                suffix.insert(randomDomain())
            }
        }

        let ruleSet = CompactDomainRuleSet(
            exactDomains: Array(exact),
            suffixDomains: Array(suffix)
        )

        for _ in 0..<2_000 {
            let query = randomDomain()
            XCTAssertEqual(
                ruleSet.containsNormalized(query),
                referenceContains(query, exact: exact, suffix: suffix),
                "containsNormalized mismatch for generated query \(query)"
            )
        }
    }

    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            // xorshift64* requires non-zero state.
            state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        }

        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 0x2545_F491_4F6C_DD1D
        }
    }
}
