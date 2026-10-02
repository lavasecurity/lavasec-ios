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
    private let authorizationStore: CatalogAuthorizationStore

    internal init(
        cacheDirectoryURL: URL,
        catalogURLs: [URL] = LavaSecAPI.catalogURLs,
        dataFetcher: @escaping BlocklistCatalogDataFetcher = BlocklistCatalogSynchronizer.defaultDataFetcher,
        trustPolicy: CatalogTrustPolicy = .production
    ) {
        self.cacheDirectoryURL = cacheDirectoryURL
        self.catalogURLs = catalogURLs
        self.dataFetcher = dataFetcher
        self.authorizationStore = CatalogAuthorizationStore(
            directory: cacheDirectoryURL.appendingPathComponent("catalog"), policy: trustPolicy)
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

    internal func cachedCatalogData() throws -> Data {
        let url = latestCatalogURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BlocklistCatalogSyncError.noCachedCatalog
        }

        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumCatalogBytes else {
            throw BlocklistCatalogSyncError.invalidCatalog
        }
        return data
    }

    /// Returns a decoded value and the exact bytes from the same `catalog/latest.json` read.
    /// Authorization also consults committed state under its lock. A caller that will later
    /// compare-and-swap needs the returned bytes as its
    /// "expected current" token; decoding through a second read could pair value A with bytes B if
    /// the file changed in between.
    internal func cachedCatalogSnapshot(now: Date = Date()) throws -> (catalog: BlocklistCatalog, data: Data) {
        let data = try cachedCatalogData()
        let catalog = try BlocklistCatalogSynchronizer.makeJSONDecoder().decode(BlocklistCatalog.self, from: data)
        try authorizationStore.validate(catalog, now: now)
        return (catalog, data)
    }

    internal func cachedCatalog() throws -> BlocklistCatalog {
        try cachedCatalogSnapshot().catalog
    }

    internal func cachedCatalogAge(now: Date = Date()) -> TimeInterval? {
        Self.cachedCatalogAge(in: cacheDirectoryURL, now: now)
    }

    internal func hasFreshCachedCatalog(maxAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let age = cachedCatalogAge(now: now) else {
            return false
        }

        guard age >= 0 && age < maxAge else { return false }
        if authorizationStore.policy.requiresSignature || !authorizationStore.policy.publicKeys.isEmpty {
            // A recent file can still be unsigned, expired or untrusted after an upgrade.
            // It must trigger network refresh instead of suppressing sync for seven days.
            return (try? cachedCatalogSnapshot(now: now)) != nil
        }
        return true
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

    // Publication checks do not advance the committed catalog or rollback checkpoint.
    func loadNetworkCatalog() async throws -> LoadedCatalogPayloadValue {
        var lastError: any Error = BlocklistCatalogSyncError.invalidCatalog
        for catalogURL in catalogURLs {
            do {
                try Task.checkCancellation()
                let data = try await dataFetcher(catalogURL)
                try Task.checkCancellation()
                guard data.count <= Self.maximumCatalogBytes else {
                    throw BlocklistCatalogSyncError.invalidCatalog
                }
                let catalog = try BlocklistCatalogSynchronizer.makeJSONDecoder().decode(BlocklistCatalog.self, from: data)
                try authorizationStore.validate(catalog)
                return LoadedCatalogPayloadValue(catalog: catalog, data: data, shouldCache: true)
            } catch {
                if error is CancellationError { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    // Production URLs are tried in order; total failure falls back to the
    // cached catalog, then to the built-in source-URL catalog as last resort.
    // Invalid remote or cached metadata is rejected by the same decoder. Falling back
    // changes catalog provenance, never the runtime's requirement for usable filters.
    func loadRemoteCatalog() async throws -> LoadedCatalogPayloadValue {
        do { return try await loadNetworkCatalog() }
        catch is CancellationError { throw CancellationError() }
        catch { /* Network failure retains the existing protection fallback below. */ }

        if let cached = try? cachedCatalogSnapshot() {
            return LoadedCatalogPayloadValue(catalog: cached.catalog, data: cached.data, shouldCache: false)
        }

        guard authorizationStore.permitsUnsignedFallback else {
            throw BlocklistCatalogSyncError.invalidCatalog
        }

        let catalog = BlocklistCatalog.builtInSourceURLCatalog()
        try authorizationStore.validate(catalog)
        let data = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
        return LoadedCatalogPayloadValue(catalog: catalog, data: data, shouldCache: false)
    }

    internal func saveLatestCatalog(_ data: Data) throws {
        _ = try commitLatestCatalog(data) { true }
    }

    /// Commits a background catalog only if its captured cache basis is still current.
    /// Authorization and the comparison run under the shared catalog lock, before the
    /// caller flips its artifact pointer. A rejected/cancelled fetch never advances trust.
    public static func commitLatestCatalog(_ data: Data, in cacheDirectoryURL: URL,
                                          matching expectedCurrentData: Data?) throws -> Bool {
        try BlocklistCatalogRepository(cacheDirectoryURL: cacheDirectoryURL)
            .commitLatestCatalog(data, matching: expectedCurrentData)
    }

    internal func commitLatestCatalog(_ data: Data, matching expectedCurrentData: Data?) throws -> Bool {
        try commitLatestCatalog(data) {
            !Task.isCancelled && (try? self.cachedCatalogData()) == expectedCurrentData
        }
    }

    private func commitLatestCatalog(_ data: Data, shouldWrite: () -> Bool) throws -> Bool {
        guard data.count <= Self.maximumCatalogBytes else { throw BlocklistCatalogSyncError.invalidCatalog }
        let catalog = try BlocklistCatalogSynchronizer.makeJSONDecoder().decode(BlocklistCatalog.self, from: data)
        return try authorizationStore.commit(catalog, shouldWrite: shouldWrite) {
            try FileManager.default.createDirectory(
                at: latestCatalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: latestCatalogURL, options: [.atomic])
            return true
        }
    }

    /// Compare-and-swap correction of `catalog/latest.json` for a cache-only resolve.
    ///
    /// `expectedCurrentData` is the exact bytes the caller read BEFORE its compile. That compile
    /// can run for seconds (parsing up to tens of MB), and a concurrent `sync` may commit a newer
    /// catalog in that window. Overwriting with a catalog derived from the stale read would ROLL
    /// THE CATALOG BACK — the very divergence `loadCached`'s write-back exists to close, and the
    /// race the cache-only path was documented to avoid. When the bytes changed the concurrent
    /// writer is authoritative, so this is a no-op; when they still match the correction lands,
    /// preserving the freshness mtime (see `saveLatestCatalogPreservingModificationDate`).
    ///
    /// Best-effort only: the compare and the atomic write are not one critical section, so a
    /// writer landing in the (microseconds) gap can still have advisory observations overwritten.
    /// Authorization commits have their own cross-process lock and reject an older signed
    /// revision/renewal, independently of this best-effort cache-correction comparison.
    internal func saveLatestCatalogIfUnchanged(_ data: Data, matching expectedCurrentData: Data) throws {
        guard let current = try? cachedCatalogData(), current == expectedCurrentData else {
            return
        }
        try saveLatestCatalogPreservingModificationDate(data)
    }

    /// Writes `catalog/latest.json` atomically while PRESERVING its previous modification date.
    ///
    /// The mtime is the freshness evidence (`cachedCatalogAge` / `hasFreshCachedCatalog`, the
    /// 7-day window). A cache-only resolve corrects the catalog CONTENT to match the payloads it
    /// actually compiled from disk but VERIFIED NOTHING upstream, so its write must not advance
    /// the freshness clock — that would fake "verified current" from unverified local bytes.
    /// `sync`'s network-verified re-stamp (`refreshCachedCatalogFreshness`) is the deliberate
    /// opposite. A missing previous file (or a failed mtime read) leaves the fresh write's own
    /// mtime; the restore is best-effort, matching `refreshCachedCatalogFreshness`.
    internal func saveLatestCatalogPreservingModificationDate(_ data: Data) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: latestCatalogURL.path)
        let previousModificationDate = attributes?[.modificationDate] as? Date
        try saveLatestCatalog(data)
        guard let previousModificationDate else {
            return
        }
        try? FileManager.default.setAttributes(
            [.modificationDate: previousModificationDate],
            ofItemAtPath: latestCatalogURL.path
        )
    }

    /// Re-stamp `catalog/latest.json`'s modification date to `now` WITHOUT touching its content —
    /// the mtime is the catalog freshness evidence (`cachedCatalogAge` reads it).
    ///
    /// Mechanical contract only; the WHEN (network-verified-unchanged, never cache-fallback, never
    /// on a changed catalog) is owned by the one caller, `BlocklistCatalogSynchronizer.sync` — see
    /// its doc comment for the full rationale + pin. Attribute-only on purpose: no content write
    /// means a concurrent foreground `saveLatestCatalog` (atomic replace = new inode) can never be
    /// clobbered; at worst this re-stamps the racer's just-written file, whose mtime is already
    /// current. Best-effort: a failed re-stamp only leaves the previous (aging) evidence, the
    /// fail-safe direction.
    internal func refreshCachedCatalogFreshness(now: Date = Date()) {
        try? FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: latestCatalogURL.path
        )
    }
}
