import XCTest
@testable import LavaSecCore
@testable import LavaSecFilterPipeline

/// Behavioral coverage for the background sync's freshness re-stamp
/// (`BlocklistCatalogSynchronizer.sync(commitsLatestCatalog: false)` →
/// `BlocklistCatalogRepository.refreshCachedCatalogFreshness`). The cached catalog's mtime is the
/// freshness evidence warm-artifact reuse gates on (7-day window); a background run commits
/// `latest.json` only atomically with an artifact flip, so before this re-stamp a catalog that
/// simply stopped changing aged out and every headless warm switch — including the BGTask
/// pending-switch drain — deferred forever. The re-stamp must fire ONLY on a NETWORK-VERIFIED
/// unchanged catalog: a cache-fallback load proves nothing (it would fake freshness from our own
/// stale bytes), and a changed catalog must age until a real commit moves the evidence.
final class BlocklistCatalogFreshnessRefreshTests: XCTestCase {
    private let payload = Data("ads.example.com\ntrack.example.com\n".utf8)
    /// Fixed, whole-second date so encode/decode round-trips are exact.
    private let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)
    /// An mtime well in the past (but a valid, positive age) to make re-stamps observable.
    private let staleModificationDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeCatalog(catalogVersion: String) -> BlocklistCatalog {
        let checksum = BlocklistCatalogSynchronizer.sha256Hex(of: payload)
        let source = CatalogBlocklistSource(
            id: "source-a", name: "Source A", category: "ads", riskLevel: "low", defaultEnabled: true,
            licenseName: "MIT", attribution: "test",
            projectURL: URL(string: "https://example.com")!, sourceURL: URL(string: "https://example.com/list.txt")!,
            versionID: "source-a-v1", entryCount: 2, byteSize: payload.count, sourceHash: checksum,
            acceptedSourceHashes: [CatalogAcceptedSourceHash(sha256: checksum)], normalizedHash: checksum,
            publishedAt: publishedAt, redistributionMode: "allowed", parseFormat: .plainDomains,
            licenseTextURL: nil, noticeURL: nil
        )
        return BlocklistCatalog(
            schemaVersion: 2, catalogVersion: catalogVersion, generatedAt: publishedAt,
            sources: [source], guardrails: []
        )
    }

    /// Seed `catalog/latest.json` with `catalog` and back-date its mtime so a re-stamp is visible.
    private func seedStaleCachedCatalog(_ catalog: BlocklistCatalog, in cacheDir: URL) throws -> URL {
        let catalogDir = cacheDir.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogDir, withIntermediateDirectories: true)
        let latestURL = catalogDir.appendingPathComponent("latest.json")
        try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog).write(to: latestURL)
        try FileManager.default.setAttributes(
            [.modificationDate: staleModificationDate], ofItemAtPath: latestURL.path
        )
        return latestURL
    }

    private func modificationDate(of url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    private func makeTempCacheDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bcfr-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testNetworkVerifiedUnchangedCatalogRestampsFreshnessWithoutContentWrite() async throws {
        let cacheDir = makeTempCacheDir(); defer { try? FileManager.default.removeItem(at: cacheDir) }
        let catalog = makeCatalog(catalogVersion: "v1")
        let latestURL = try seedStaleCachedCatalog(catalog, in: cacheDir)
        let beforeBytes = try Data(contentsOf: latestURL)
        let fetched = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
        let payload = self.payload // Sendable local: the @Sendable dataFetcher must not capture non-Sendable XCTestCase self
        let synchronizer = BlocklistCatalogSynchronizer(
            catalogURL: URL(string: "https://example.com/catalog.json")!,
            cacheDirectoryURL: cacheDir,
            dataFetcher: { url in
                if url.lastPathComponent == "catalog.json" { return fetched }
                if url.lastPathComponent == "list.txt" { return payload }
                throw URLError(.cannotFindHost)
            }
        )

        let result = try await synchronizer.sync(enabledSourceIDs: ["source-a"], commitsLatestCatalog: false)

        // Precondition for the re-stamp predicate: the resolved catalog must equal the cached one
        // (no versionID/hash rotation for a byte-stable source) — if this ever fails, the predicate
        // in sync() can never fire and the re-stamp is dead code.
        let cachedDecoded = try BlocklistCatalogSynchronizer.makeJSONDecoder()
            .decode(BlocklistCatalog.self, from: beforeBytes)
        XCTAssertEqual(result.catalog, cachedDecoded, "A byte-stable source must resolve equal to the cache.")

        let afterBytes = try Data(contentsOf: latestURL)
        XCTAssertEqual(afterBytes, beforeBytes,
                       "The re-stamp must be attribute-only — a background run never rewrites latest.json content.")
        let mtime = try modificationDate(of: latestURL)
        XCTAssertGreaterThan(mtime, staleModificationDate.addingTimeInterval(60),
                             "A network-verified unchanged catalog must re-stamp the freshness mtime.")
        XCTAssertLessThan(abs(mtime.timeIntervalSinceNow), 120,
                          "The re-stamped mtime must be 'now' — verified-current evidence.")
    }

    func testCacheFallbackNeverRestampsFreshness() async throws {
        // Network down: loadRemoteCatalog falls back to the cached catalog (shouldCache == false).
        // Resolving equal to the cache is then a tautology, not upstream verification — the mtime
        // must keep aging so a genuinely unreachable catalog still ages out of the warm window.
        let cacheDir = makeTempCacheDir(); defer { try? FileManager.default.removeItem(at: cacheDir) }
        let catalog = makeCatalog(catalogVersion: "v1")
        let latestURL = try seedStaleCachedCatalog(catalog, in: cacheDir)
        let payload = self.payload // Sendable local: the @Sendable dataFetcher must not capture non-Sendable XCTestCase self
        let synchronizer = BlocklistCatalogSynchronizer(
            catalogURL: URL(string: "https://example.com/catalog.json")!,
            cacheDirectoryURL: cacheDir,
            dataFetcher: { url in
                if url.lastPathComponent == "list.txt" { return payload }
                throw URLError(.cannotFindHost) // catalog fetch fails → cache fallback
            }
        )

        _ = try await synchronizer.sync(enabledSourceIDs: ["source-a"], commitsLatestCatalog: false)

        let mtime = try modificationDate(of: latestURL)
        XCTAssertEqual(mtime.timeIntervalSince1970, staleModificationDate.timeIntervalSince1970, accuracy: 1,
                       "A cache-fallback run must NOT re-stamp freshness — it verified nothing upstream.")
    }

    func testChangedCatalogNeverRestampsFreshness() async throws {
        // Upstream moved (even if the change is invisible to the enabled selection): the cached
        // basis is genuinely behind, so only a real commit — atomic with an artifact flip — may
        // move the freshness evidence. Content must also stay untouched in the non-committing mode.
        let cacheDir = makeTempCacheDir(); defer { try? FileManager.default.removeItem(at: cacheDir) }
        let cached = makeCatalog(catalogVersion: "v1")
        let latestURL = try seedStaleCachedCatalog(cached, in: cacheDir)
        let beforeBytes = try Data(contentsOf: latestURL)
        let fetched = try BlocklistCatalogSynchronizer.makeJSONEncoder()
            .encode(makeCatalog(catalogVersion: "v2"))
        let payload = self.payload // Sendable local: the @Sendable dataFetcher must not capture non-Sendable XCTestCase self
        let synchronizer = BlocklistCatalogSynchronizer(
            catalogURL: URL(string: "https://example.com/catalog.json")!,
            cacheDirectoryURL: cacheDir,
            dataFetcher: { url in
                if url.lastPathComponent == "catalog.json" { return fetched }
                if url.lastPathComponent == "list.txt" { return payload }
                throw URLError(.cannotFindHost)
            }
        )

        _ = try await synchronizer.sync(enabledSourceIDs: ["source-a"], commitsLatestCatalog: false)

        let mtime = try modificationDate(of: latestURL)
        XCTAssertEqual(mtime.timeIntervalSince1970, staleModificationDate.timeIntervalSince1970, accuracy: 1,
                       "A changed catalog must keep aging until a real commit moves the evidence.")
        XCTAssertEqual(try Data(contentsOf: latestURL), beforeBytes,
                       "The non-committing mode must never rewrite latest.json content.")
    }
}
