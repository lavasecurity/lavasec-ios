import Foundation
import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class DomainCheckTests: XCTestCase {
    func testSelectedBlocklistHostnameDecisionsMatchTheRuntimeAfterPublication() throws {
        // PRO mini lists individual DoubleClick hosts, not the parent hostname.
        // Preserve DNS label boundaries and the active engine's precedence rather
        // than infer a parent block from a blocked child or another filter's rules.
        let parsed = BlocklistParser().parse("g.doubleclick.net\nfls.doubleclick.net\ndoubleclick.com\n", format: .plainDomains)
        XCTAssertTrue(parsed.rejectedLines.isEmpty)
        let source = CatalogBlocklistSource(id: "selected-list", name: "Selected list", category: "multi_purpose",
            riskLevel: "normal", defaultEnabled: false, licenseName: "GPL-3.0", attribution: "",
            projectURL: URL(string: "https://example.com/project")!, sourceURL: URL(string: "https://example.com/list.txt")!,
            versionID: "fixture-v1", entryCount: parsed.rules.count, byteSize: 100, sourceHash: "fixture-source",
            normalizedHash: "fixture-normalized", publishedAt: Date(timeIntervalSince1970: 1_000),
            redistributionMode: "source_url_only", parseFormat: .plainDomains, licenseTextURL: nil, noticeURL: nil)
        let catalog = BlocklistCatalog(schemaVersion: 1, catalogVersion: "fixture", generatedAt: Date(),
                                     sources: [source], guardrails: [])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = FilterArtifactStore(directoryURL: root)
        var configuration = AppConfiguration(enabledBlocklistIDs: [source.id], allowedDomains: ["safe.g.doubleclick.net"])
        func publish() throws -> (LocalDomainCheckSnapshot, CompactFilterSnapshot) {
            let runtime = configuration.filterSnapshot(blockRules: parsed.ruleSet)
            let prepared = PreparedFilterSnapshot(identity: .make(configuration: configuration, catalog: catalog),
                snapshot: runtime, summary: PreparedFilterSnapshotSummary(snapshot: runtime,
                    blocklistRuleCount: parsed.rules.count, blocklistSourceRuleCounts: [source.id: parsed.rules.count],
                    tierBudgetRuleCount: parsed.rules.count + configuration.allowedDomains.count + configuration.blockedDomains.count))
            try store.persist(preparedSnapshot: prepared)
            return (try XCTUnwrap(LocalDomainCheckSnapshot.load(configuration: configuration, catalog: catalog, store: store)),
                    try CompactFilterSnapshot.decode(from: Data(contentsOf: store.compactSnapshotURL, options: [.mappedIfSafe])))
        }
        let (check, runtime) = try publish()
        for (raw, action) in [("doubleclick.net", FilterAction.allow), ("https://g.doubleclick.net/path", .block),
                              ("child.fls.doubleclick.net", .block), ("doubleclick.com", .block),
                              ("notg.doubleclick.net", .allow), ("safe.g.doubleclick.net", .allow)] {
            let input = try DomainCheckInput(raw)
            XCTAssertEqual(check.decision(for: input).action, action, raw)
            XCTAssertEqual(check.decision(for: input), runtime.decision(forNormalizedDomain: input.domain), raw)
        }
        configuration.blockedDomains.insert("doubleclick.net")
        XCTAssertFalse(check.matches(configuration: configuration, catalog: catalog))
        let (updated, _) = try publish()
        XCTAssertEqual(updated.decision(for: try DomainCheckInput("doubleclick.net")).action, .block)
        XCTAssertEqual(updated.decision(for: try DomainCheckInput("safe.g.doubleclick.net")).reason, .localAllowlist)
    }

    func testExtractsOnlyTheHostname() throws {
        for raw in ["sites.google.com", " SITES.GOOGLE.COM. \n", "https://sites.google.com/abcfjufn",
                    "https//sites.google.com/abcfjufn", "http//sites.google.com/path",
                    "sites.google.com:443/path?q=private#secret", "//sites.google.com/path"] {
            XCTAssertEqual(try DomainCheckInput(raw).domain, "sites.google.com", raw)
        }
        XCTAssertTrue(try DomainCheckInput("https//sites.google.com/path").repairedScheme)
        XCTAssertTrue(try DomainCheckInput("sites.google.com/path").ignoredURLParts)
        XCTAssertFalse(try DomainCheckInput("sites.google.com").ignoredURLParts)
        XCTAssertEqual(try DomainCheckInput("https://bücher.de/path").domain, "xn--bcher-kva.de")
    }

    func testEmbeddedURLsDoNotBecomeTheAddressScheme() throws {
        for raw in ["example.com/redirect?next=https://other.test",
                    "example.com/https://other.test", "example.com?next=https://other.test",
                    "example.com#https://other.test", "//example.com/redirect?next=https://other.test",
                    "https://example.com/redirect?next=https://other.test"] {
            let input = try DomainCheckInput(raw)
            XCTAssertEqual(input.domain, "example.com", raw)
            XCTAssertTrue(input.ignoredURLParts, raw)
            XCTAssertFalse(input.repairedScheme, raw)
        }
    }

    func testRejectsAmbiguousOrUnsupportedInput() {
        for raw in ["", "example.com evil.test", "example.com\nevil.test", "*.example.com", "localhost",
                    "127.0.0.1", "https://[::1]/", "https://safe.test@evil.test/path",
                    "https://user:password@example.com/", "ftp://example.com/", "javascript:alert(1)",
                    "https://example.com\\@evil.test", "https://%65xample.com", "https://example.com:",
                    "https://example.com:99999", "https:///path", String(repeating: "x", count: 4097)] {
            XCTAssertThrowsError(try DomainCheckInput(raw), raw)
        }
    }

    func testReadOnlySnapshotRequiresAValidCoveredArtifactAndPreservesPrecedence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = FilterArtifactStore(directoryURL: root)
        let configuration = AppConfiguration(enabledBlocklistIDs: [], allowedDomains: ["safe.example.com"],
                                             blockedDomains: ["example.com"])
        let prepared = PreparedFilterSnapshot(identity: .make(configuration: configuration, catalog: nil),
            snapshot: configuration.filterSnapshot(), summary: PreparedFilterSnapshotSummary(
                snapshot: configuration.filterSnapshot(), blocklistRuleCount: 0,
                blocklistSourceRuleCounts: [:], tierBudgetRuleCount: 2))
        XCTAssertNil(try LocalDomainCheckSnapshot.load(configuration: configuration, catalog: nil, store: store))
        try store.persist(preparedSnapshot: prepared)
        let check = try XCTUnwrap(LocalDomainCheckSnapshot.load(configuration: configuration, catalog: nil, store: store))
        XCTAssertEqual(check.decision(for: try DomainCheckInput("https://safe.example.com/path")).reason, .localAllowlist)
        XCTAssertEqual(check.decision(for: try DomainCheckInput("child.example.com")).reason, .blocklist)
        XCTAssertEqual(check.decision(for: try DomainCheckInput("notexample.com")).reason, .defaultAllow)
        var unrelated = configuration
        unrelated.configurationGeneration += 1
        XCTAssertTrue(check.matches(configuration: unrelated, catalog: nil))
        var changed = configuration
        changed.allowedDomains.insert("example.com")
        XCTAssertFalse(check.matches(configuration: changed, catalog: nil))
        XCTAssertNil(try LocalDomainCheckSnapshot.load(configuration: changed, catalog: nil, store: store))
        var data = try Data(contentsOf: store.compactSnapshotURL)
        data[data.count - 1] ^= 1
        try data.write(to: store.compactSnapshotURL)
        XCTAssertNil(try LocalDomainCheckSnapshot.load(configuration: configuration, catalog: nil, store: store))
    }
}
