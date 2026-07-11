import Foundation
import LavaSecKit

struct LoadedCatalogPayloadValue: Sendable {
    let catalog: BlocklistCatalog
    let data: Data
    let shouldCache: Bool
}

/// Locates the persisted blocklist catalog metadata.
///
/// Raw blocklist payload caching and rule compilation are owned by
/// ``BlocklistCatalogSynchronizer``.
public struct BlocklistCatalogRepository: Sendable {
    // The catalog is METADATA only (source list + hashes), so a few hundred KB in
    // practice. Cap it before decoding so a compromised/MITM catalog host (incl. the
    // public fallback) can't hand back a multi-GB body that amplifies into an
    // out-of-memory JSON decode in the tight extension/app budget. This is the
    // decode-side guard; a streaming byte ceiling during the download itself is a
    // separate, larger hardening (the body is still materialized by the fetcher).
    internal static let maximumCatalogBytes = 8 * 1024 * 1024

    internal let cacheDirectoryURL: URL
    private let catalogURLs: [URL]
    private let dataFetcher: BlocklistCatalogDataFetcher

    internal init(
        cacheDirectoryURL: URL,
        catalogURLs: [URL] = LavaSecAPI.catalogURLs,
        dataFetcher: @escaping BlocklistCatalogDataFetcher = BlocklistCatalogSynchronizer.defaultDataFetcher
    ) {
        self.cacheDirectoryURL = cacheDirectoryURL
        self.catalogURLs = catalogURLs
        self.dataFetcher = dataFetcher
    }

    internal var latestCatalogURL: URL {
        Self.latestCatalogURL(in: cacheDirectoryURL)
    }

    /// Returns the standard cached-catalog file within a cache directory.
    public static func latestCatalogURL(in cacheDirectoryURL: URL) -> URL {
        cacheDirectoryURL
            .appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent("latest.json")
    }

    internal func cachedCatalog() throws -> BlocklistCatalog {
        let url = latestCatalogURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BlocklistCatalogSyncError.noCachedCatalog
        }

        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumCatalogBytes else {
            throw BlocklistCatalogSyncError.invalidCatalog
        }
        return try BlocklistCatalogSynchronizer.makeJSONDecoder().decode(BlocklistCatalog.self, from: data)
    }

    internal func cachedCatalogAge(now: Date = Date()) -> TimeInterval? {
        Self.cachedCatalogAge(in: cacheDirectoryURL, now: now)
    }

    internal func hasFreshCachedCatalog(maxAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let age = cachedCatalogAge(now: now) else {
            return false
        }

        return age <= maxAge
    }

    internal static func cachedCatalogAge(in cacheDirectoryURL: URL, now: Date = Date()) -> TimeInterval? {
        let url = latestCatalogURL(in: cacheDirectoryURL)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modifiedAt = attributes[.modificationDate] as? Date
        else {
            return nil
        }

        return now.timeIntervalSince(modifiedAt)
    }

    // Production URLs are tried in order; total failure falls back to the
    // cached catalog, then to the built-in source-URL catalog as last resort.
    // The fallback ordering is the fail-open contract that keeps protection
    // startable with no network and no cache.
    func loadRemoteCatalog() async throws -> LoadedCatalogPayloadValue {
        for catalogURL in catalogURLs {
            do {
                let data = try await dataFetcher(catalogURL)
                guard data.count <= Self.maximumCatalogBytes else {
                    // Oversized remote catalog → skip it and fall through to the cache /
                    // built-in fallback rather than decode it.
                    continue
                }
                let catalog = try BlocklistCatalogSynchronizer.makeJSONDecoder().decode(BlocklistCatalog.self, from: data)
                return LoadedCatalogPayloadValue(catalog: catalog, data: data, shouldCache: true)
            } catch {
                continue
            }
        }

        if let data = try? Data(contentsOf: latestCatalogURL),
           data.count <= Self.maximumCatalogBytes,
           let catalog = try? BlocklistCatalogSynchronizer.makeJSONDecoder().decode(BlocklistCatalog.self, from: data) {
            return LoadedCatalogPayloadValue(catalog: catalog, data: data, shouldCache: false)
        }

        let catalog = BlocklistCatalog.builtInSourceURLCatalog()
        let data = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
        return LoadedCatalogPayloadValue(catalog: catalog, data: data, shouldCache: false)
    }

    internal func saveLatestCatalog(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: latestCatalogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: latestCatalogURL, options: [.atomic])
    }
}
