import Foundation

struct LoadedCatalogPayloadValue: Sendable {
    let catalog: BlocklistCatalog
    let data: Data
    let shouldCache: Bool
}

// Owns catalog METADATA only: fetching, caching, freshness, and reads of
// catalog/latest.json. Raw blocklist payload caching and rule compilation stay
// with BlocklistCatalogSynchronizer; cheap metadata reads (the warm-start reuse
// gate, freshness checks) no longer drag the payload/compile machinery along.
public struct BlocklistCatalogRepository: Sendable {
    public let cacheDirectoryURL: URL
    private let catalogURLs: [URL]
    private let dataFetcher: BlocklistCatalogDataFetcher

    public init(
        cacheDirectoryURL: URL,
        catalogURLs: [URL] = LavaSecAPI.catalogURLs,
        dataFetcher: @escaping BlocklistCatalogDataFetcher = BlocklistCatalogSynchronizer.defaultDataFetcher
    ) {
        self.cacheDirectoryURL = cacheDirectoryURL
        self.catalogURLs = catalogURLs
        self.dataFetcher = dataFetcher
    }

    public var latestCatalogURL: URL {
        Self.latestCatalogURL(in: cacheDirectoryURL)
    }

    public static func latestCatalogURL(in cacheDirectoryURL: URL) -> URL {
        cacheDirectoryURL
            .appendingPathComponent("catalog", isDirectory: true)
            .appendingPathComponent("latest.json")
    }

    public func cachedCatalog() throws -> BlocklistCatalog {
        let url = latestCatalogURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BlocklistCatalogSyncError.noCachedCatalog
        }

        let data = try Data(contentsOf: url)
        return try BlocklistCatalogSynchronizer.makeJSONDecoder().decode(BlocklistCatalog.self, from: data)
    }

    public func cachedCatalogAge(now: Date = Date()) -> TimeInterval? {
        Self.cachedCatalogAge(in: cacheDirectoryURL, now: now)
    }

    public func hasFreshCachedCatalog(maxAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let age = cachedCatalogAge(now: now) else {
            return false
        }

        return age <= maxAge
    }

    public static func cachedCatalogAge(in cacheDirectoryURL: URL, now: Date = Date()) -> TimeInterval? {
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
                let catalog = try BlocklistCatalogSynchronizer.makeJSONDecoder().decode(BlocklistCatalog.self, from: data)
                return LoadedCatalogPayloadValue(catalog: catalog, data: data, shouldCache: true)
            } catch {
                continue
            }
        }

        if let data = try? Data(contentsOf: latestCatalogURL),
           let catalog = try? BlocklistCatalogSynchronizer.makeJSONDecoder().decode(BlocklistCatalog.self, from: data) {
            return LoadedCatalogPayloadValue(catalog: catalog, data: data, shouldCache: false)
        }

        let catalog = BlocklistCatalog.builtInSourceURLCatalog()
        let data = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
        return LoadedCatalogPayloadValue(catalog: catalog, data: data, shouldCache: false)
    }

    public func saveLatestCatalog(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: latestCatalogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: latestCatalogURL, options: [.atomic])
    }
}
