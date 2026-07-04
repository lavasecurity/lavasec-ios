import XCTest
@testable import LavaSecCore

final class RuleSetCacheTests: XCTestCase {
    private let sampleHash = String(repeating: "ab", count: 32)

    func testStoreThenLoadRoundTripsRuleSetAndPayloadSize() throws {
        let cache = RuleSetCache(cacheDirectoryURL: try makeTemporaryDirectory())
        var ruleSet = DomainRuleSet()
        try ruleSet.insert(domain: "ads.example.com", matchesSubdomains: true)
        try ruleSet.insert(domain: "exact.example.com", matchesSubdomains: false)
        try ruleSet.insert(domain: "tracker.example.net", matchesSubdomains: true)

        try cache.store(ruleSet, sourceID: "source-a", contentSHA256: sampleHash, parseFormat: .hosts, payloadByteSize: 4_242)
        let entry = try XCTUnwrap(cache.load(sourceID: "source-a", contentSHA256: sampleHash, parseFormat: .hosts))

        XCTAssertEqual(entry.ruleSet, ruleSet)
        XCTAssertEqual(entry.payloadByteSize, 4_242)
    }

    func testLoadMissesOnDifferentHashOrFormat() throws {
        let cache = RuleSetCache(cacheDirectoryURL: try makeTemporaryDirectory())
        var ruleSet = DomainRuleSet()
        try ruleSet.insert(domain: "ads.example.com", matchesSubdomains: true)
        try cache.store(ruleSet, sourceID: "source-a", contentSHA256: sampleHash, parseFormat: .hosts, payloadByteSize: 10)

        let otherHash = String(repeating: "cd", count: 32)
        XCTAssertNil(cache.load(sourceID: "source-a", contentSHA256: otherHash, parseFormat: .hosts))
        XCTAssertNil(cache.load(sourceID: "source-a", contentSHA256: sampleHash, parseFormat: .adblock))
        XCTAssertNil(cache.load(sourceID: "source-b", contentSHA256: sampleHash, parseFormat: .hosts))
    }

    func testCorruptedEntryIsDeletedAndReturnsNil() throws {
        let directory = try makeTemporaryDirectory()
        let cache = RuleSetCache(cacheDirectoryURL: directory)
        var ruleSet = DomainRuleSet()
        try ruleSet.insert(domain: "ads.example.com", matchesSubdomains: true)
        try cache.store(ruleSet, sourceID: "source-a", contentSHA256: sampleHash, parseFormat: .hosts, payloadByteSize: 10)

        let entryURL = directory
            .appendingPathComponent("parsed-rules")
            .appendingPathComponent("v\(BlocklistParsingRules.rulesVersion)")
            .appendingPathComponent("source-a")
            .appendingPathComponent("\(sampleHash.prefix(12))-hosts.ruleset")
        try Data("corrupted".utf8).write(to: entryURL)

        XCTAssertNil(cache.load(sourceID: "source-a", contentSHA256: sampleHash, parseFormat: .hosts))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: entryURL.path),
            "Corrupted entries must be deleted so the next parse repopulates them."
        )
    }

    func testEnforceLimitsKeepsNewestEntriesPerSource() throws {
        let cache = RuleSetCache(cacheDirectoryURL: try makeTemporaryDirectory())
        var ruleSet = DomainRuleSet()
        try ruleSet.insert(domain: "ads.example.com", matchesSubdomains: true)

        let hashes = (0..<4).map { String(repeating: String(format: "%02x", 16 + $0), count: 32) }
        for hash in hashes {
            try cache.store(ruleSet, sourceID: "source-a", contentSHA256: hash, parseFormat: .hosts, payloadByteSize: 1)
            // Distinct mtimes so newest-first ordering is deterministic.
            Thread.sleep(forTimeInterval: 0.02)
        }

        let surviving = hashes.filter {
            cache.load(sourceID: "source-a", contentSHA256: $0, parseFormat: .hosts) != nil
        }
        XCTAssertEqual(surviving, Array(hashes.suffix(2)), "Only the newest two entries per source survive.")
    }

    func testRemoveAllForSourceClearsOnlyThatSource() throws {
        let cache = RuleSetCache(cacheDirectoryURL: try makeTemporaryDirectory())
        var ruleSet = DomainRuleSet()
        try ruleSet.insert(domain: "ads.example.com", matchesSubdomains: true)
        try cache.store(ruleSet, sourceID: "source-a", contentSHA256: sampleHash, parseFormat: .hosts, payloadByteSize: 1)
        try cache.store(ruleSet, sourceID: "source-b", contentSHA256: sampleHash, parseFormat: .hosts, payloadByteSize: 1)

        cache.removeAll(forSourceID: "source-a")

        XCTAssertNil(cache.load(sourceID: "source-a", contentSHA256: sampleHash, parseFormat: .hosts))
        XCTAssertNotNil(cache.load(sourceID: "source-b", contentSHA256: sampleHash, parseFormat: .hosts))
    }

    func testCachedCompileSkipsPayloadAndParseEntirely() async throws {
        // First compile parses from a stubbed network and populates the parsed
        // cache; the second uses a NEW synchronizer whose fetcher always throws
        // AND whose raw payload files are deleted — only the parsed-rule cache
        // can satisfy it.
        let cacheURL = try makeTemporaryDirectory()
        let payloadText = "ads.example.com\ntracker.example.net\n"
        let payloadData = Data(payloadText.utf8)
        let checksum = BlocklistCatalogSynchronizer.sha256Hex(of: payloadData)
        let source = CatalogBlocklistSource(
            id: "source-a",
            name: "Source A",
            category: "ads",
            riskLevel: "low",
            defaultEnabled: true,
            licenseName: "MIT",
            attribution: "test",
            projectURL: URL(string: "https://example.com")!,
            sourceURL: URL(string: "https://example.com/list.txt")!,
            versionID: "source-a-v1",
            entryCount: 2,
            byteSize: payloadData.count,
            sourceHash: checksum,
            acceptedSourceHashes: [CatalogAcceptedSourceHash(sha256: checksum)],
            normalizedHash: checksum,
            publishedAt: Date(),
            redistributionMode: "allowed",
            parseFormat: .plainDomains,
            licenseTextURL: nil,
            noticeURL: nil
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "test-1",
            generatedAt: Date(),
            sources: [source],
            guardrails: []
        )
        let catalogDirectory = cacheURL.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogDirectory, withIntermediateDirectories: true)
        try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
            .write(to: catalogDirectory.appendingPathComponent("latest.json"))

        let fetchingSynchronizer = BlocklistCatalogSynchronizer(
            catalogURL: URL(string: "https://example.com/catalog.json")!,
            cacheDirectoryURL: cacheURL,
            dataFetcher: { url in
                guard url.lastPathComponent == "list.txt" else {
                    throw URLError(.cannotFindHost)  // catalog fetch falls back to the cached latest.json
                }
                return payloadData
            }
        )
        let first = try await fetchingSynchronizer.sync(enabledSourceIDs: ["source-a"])
        XCTAssertEqual(first.sourceRuleSets["source-a"]?.count, 2)

        // Remove raw payloads; only catalog metadata and the parsed cache remain.
        try FileManager.default.removeItem(at: cacheURL.appendingPathComponent("blocklists", isDirectory: true))

        let offlineSynchronizer = BlocklistCatalogSynchronizer(
            catalogURL: URL(string: "https://example.com/catalog.json")!,
            cacheDirectoryURL: cacheURL,
            dataFetcher: { _ in throw URLError(.notConnectedToInternet) }
        )
        let second = try await offlineSynchronizer.loadCached(enabledSourceIDs: ["source-a"])

        XCTAssertEqual(second.sourceRuleSets["source-a"], first.sourceRuleSets["source-a"])
        XCTAssertTrue(second.usedCachedSourceIDs.contains("source-a"))
    }

    // A parser bump orphans the whole previous parsed-rules/v* tree and nothing else
    // deletes it; the sweep must reap only superseded VERSION trees — never the current
    // tree's entries and never sibling non-version directories.
    func testSweepSupersededVersionTreesReapsOnlyOldVersions() throws {
        let directory = try makeTemporaryDirectory()
        let cache = RuleSetCache(cacheDirectoryURL: directory)
        var ruleSet = DomainRuleSet()
        try ruleSet.insert(domain: "ads.example.com", matchesSubdomains: true)
        try cache.store(ruleSet, sourceID: "source-a", contentSHA256: sampleHash, parseFormat: .hosts, payloadByteSize: 10)

        let parsedRulesURL = directory.appendingPathComponent("parsed-rules")
        let supersededTree = parsedRulesURL.appendingPathComponent("v2/source-old")
        try FileManager.default.createDirectory(at: supersededTree, withIntermediateDirectories: true)
        try Data("orphaned".utf8).write(to: supersededTree.appendingPathComponent("entry.ruleset"))
        let unrelatedSibling = parsedRulesURL.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: unrelatedSibling, withIntermediateDirectories: true)

        cache.sweepSupersededVersionTrees()

        XCTAssertFalse(FileManager.default.fileExists(atPath: parsedRulesURL.appendingPathComponent("v2").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedSibling.path))
        XCTAssertNotNil(
            cache.load(sourceID: "source-a", contentSHA256: sampleHash, parseFormat: .hosts),
            "The CURRENT version tree must survive the sweep."
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
