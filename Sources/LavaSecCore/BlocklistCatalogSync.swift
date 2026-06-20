import CryptoKit
import Foundation

public enum LavaSecAPI {
    public static let productionBaseURL = URL(string: "https://api.lavasecurity.app")!
    public static let fallbackBaseURL = URL(string: "https://lavasec-api.lavasec.workers.dev")!
    public static let catalogURL = catalogURL(baseURL: productionBaseURL)
    public static let fallbackCatalogURL = catalogURL(baseURL: fallbackBaseURL)
    public static let catalogURLs = [catalogURL, fallbackCatalogURL]

    private static func catalogURL(baseURL: URL) -> URL {
        baseURL
        .appendingPathComponent("v1")
        .appendingPathComponent("catalog")
    }
}

public struct BlocklistCatalog: Equatable, Codable, Sendable {
    public static let builtInSourceURLCatalogVersion = "built-in-source-url-catalog-v1"

    public let schemaVersion: Int
    public let catalogVersion: String
    public let generatedAt: Date
    public let sources: [CatalogBlocklistSource]
    public let guardrails: [CatalogBlocklistSource]

    public init(
        schemaVersion: Int,
        catalogVersion: String,
        generatedAt: Date,
        sources: [CatalogBlocklistSource],
        guardrails: [CatalogBlocklistSource]
    ) {
        self.schemaVersion = schemaVersion
        self.catalogVersion = catalogVersion
        self.generatedAt = generatedAt
        self.sources = sources
        self.guardrails = guardrails
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case catalogVersion = "catalog_version"
        case generatedAt = "generated_at"
        case sources
        case guardrails
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported blocklist catalog schema version: \(schemaVersion)"
            )
        }

        self.schemaVersion = schemaVersion
        catalogVersion = try container.decode(String.self, forKey: .catalogVersion)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        sources = try container.decode([CatalogBlocklistSource].self, forKey: .sources)
        guardrails = try container.decode([CatalogBlocklistSource].self, forKey: .guardrails)
    }

    public static func builtInSourceURLCatalog() -> BlocklistCatalog {
        BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: builtInSourceURLCatalogVersion,
            generatedAt: Date(timeIntervalSince1970: 0),
            sources: DefaultCatalog.curatedSources.map {
                CatalogBlocklistSource(defaultSource: $0)
            },
            guardrails: DefaultCatalog.guardrailSources.map {
                CatalogBlocklistSource(defaultSource: $0, category: "guardrail")
            }
        )
    }
}

public struct CatalogAcceptedSourceHash: Equatable, Codable, Sendable {
    public let sha256: String
    public let byteSize: Int?
    public let entryCount: Int?
    public let reviewedAt: Date?
    public let expiresAt: Date?
    public let status: String

    public init(
        sha256: String,
        byteSize: Int? = nil,
        entryCount: Int? = nil,
        reviewedAt: Date? = nil,
        expiresAt: Date? = nil,
        status: String = "accepted"
    ) {
        self.sha256 = sha256
        self.byteSize = byteSize
        self.entryCount = entryCount
        self.reviewedAt = reviewedAt
        self.expiresAt = expiresAt
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case sha256
        case byteSize = "byte_size"
        case entryCount = "entry_count"
        case reviewedAt = "reviewed_at"
        case expiresAt = "expires_at"
        case status
    }

    func accepts(_ checksumSHA256: String, now: Date = Date()) -> Bool {
        guard status == "accepted", sha256 == checksumSHA256 else {
            return false
        }

        guard let expiresAt else {
            return true
        }

        return expiresAt >= now
    }
}

public struct CatalogBlocklistSource: Identifiable, Equatable, Codable, Sendable {
    public enum CatalogParseFormat: String, Codable, Sendable {
        case auto
        case plainDomains = "plain_domains"
        case hosts
        case adblock
        case dnsmasq

        var blocklistFormat: BlocklistFormat {
            switch self {
            case .auto:
                return .auto
            case .plainDomains:
                return .plainDomains
            case .hosts:
                return .hosts
            case .adblock:
                return .adblock
            case .dnsmasq:
                return .dnsmasq
            }
        }
    }

    public let id: String
    public let name: String
    public let category: String
    public let riskLevel: String
    public let defaultEnabled: Bool
    public let licenseName: String
    public let attribution: String
    public let projectURL: URL
    public let sourceURL: URL
    public let versionID: String
    public let entryCount: Int
    public let byteSize: Int
    public let sourceHash: String
    public let acceptedSourceHashes: [CatalogAcceptedSourceHash]
    public let normalizedHash: String
    public let publishedAt: Date
    public let redistributionMode: String
    public let parseFormat: CatalogParseFormat
    public let licenseTextURL: URL?
    public let noticeURL: URL?

    public init(
        id: String,
        name: String,
        category: String,
        riskLevel: String,
        defaultEnabled: Bool,
        licenseName: String,
        attribution: String,
        projectURL: URL,
        sourceURL: URL,
        versionID: String,
        entryCount: Int,
        byteSize: Int,
        sourceHash: String,
        acceptedSourceHashes: [CatalogAcceptedSourceHash] = [],
        normalizedHash: String,
        publishedAt: Date,
        redistributionMode: String,
        parseFormat: CatalogParseFormat,
        licenseTextURL: URL?,
        noticeURL: URL?
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.riskLevel = riskLevel
        self.defaultEnabled = defaultEnabled
        self.licenseName = licenseName
        self.attribution = attribution
        self.projectURL = projectURL
        self.sourceURL = sourceURL
        self.versionID = versionID
        self.entryCount = entryCount
        self.byteSize = byteSize
        self.sourceHash = sourceHash
        self.acceptedSourceHashes = acceptedSourceHashes
        self.normalizedHash = normalizedHash
        self.publishedAt = publishedAt
        self.redistributionMode = redistributionMode
        self.parseFormat = parseFormat
        self.licenseTextURL = licenseTextURL
        self.noticeURL = noticeURL
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case category
        case riskLevel = "risk_level"
        case defaultEnabled = "default_enabled"
        case licenseName = "license_name"
        case attribution
        case projectURL = "project_url"
        case sourceURL = "source_url"
        case versionID = "version_id"
        case entryCount = "entry_count"
        case byteSize = "byte_size"
        case sourceHash = "source_hash"
        case acceptedSourceHashes = "accepted_source_hashes"
        case normalizedHash = "normalized_hash"
        case publishedAt = "published_at"
        case redistributionMode = "redistribution_mode"
        case parseFormat = "parse_format"
        case licenseTextURL = "license_text_url"
        case noticeURL = "notice_url"
    }

    public init(defaultSource source: BlocklistSource, category: String? = nil) {
        self.init(
            id: source.id,
            name: source.name,
            category: category ?? Self.defaultCategory(for: source),
            riskLevel: source.warningLevel.rawValue,
            defaultEnabled: source.defaultEnabled,
            licenseName: source.licenseName,
            attribution: source.name,
            projectURL: source.sourceURL,
            sourceURL: source.sourceURL,
            versionID: "\(source.id)-source-url",
            entryCount: 0,
            byteSize: 0,
            sourceHash: "",
            acceptedSourceHashes: [],
            normalizedHash: "",
            publishedAt: Date(timeIntervalSince1970: 0),
            redistributionMode: "source_url_only",
            parseFormat: .auto,
            licenseTextURL: source.licenseName.hasPrefix("GPL")
                ? URL(string: "https://www.gnu.org/licenses/gpl-3.0.en.html")
                : nil,
            noticeURL: nil
        )
    }

    public func resolvingDownloadedPayload(
        checksumSHA256: String,
        byteSize: Int,
        entryCount: Int
    ) -> CatalogBlocklistSource {
        let resolvedVersionID = sourceHash == checksumSHA256 && !sourceHash.isEmpty
            ? versionID
            : "\(id)-direct-\(checksumSHA256.prefix(12))"

        return CatalogBlocklistSource(
            id: id,
            name: name,
            category: category,
            riskLevel: riskLevel,
            defaultEnabled: defaultEnabled,
            licenseName: licenseName,
            attribution: attribution,
            projectURL: projectURL,
            sourceURL: sourceURL,
            versionID: resolvedVersionID,
            entryCount: entryCount,
            byteSize: byteSize,
            sourceHash: checksumSHA256,
            acceptedSourceHashes: resolvingAcceptedSourceHashes(
                checksumSHA256: checksumSHA256,
                byteSize: byteSize,
                entryCount: entryCount
            ),
            normalizedHash: checksumSHA256,
            publishedAt: publishedAt,
            redistributionMode: redistributionMode,
            parseFormat: parseFormat,
            licenseTextURL: licenseTextURL,
            noticeURL: noticeURL
        )
    }

    public func acceptsDownloadedHash(_ checksumSHA256: String, now: Date = Date()) -> Bool {
        acceptedSourceHashes.contains { acceptedHash in
            acceptedHash.accepts(checksumSHA256, now: now)
        }
    }

    public func activeAcceptedHashValues(now: Date = Date()) -> [String] {
        acceptedSourceHashes.compactMap { acceptedHash in
            acceptedHash.accepts(acceptedHash.sha256, now: now) ? acceptedHash.sha256 : nil
        }
    }

    var acceptsDirectUpstreamRotation: Bool {
        redistributionMode == "source_url_only"
    }

    private func resolvingAcceptedSourceHashes(
        checksumSHA256: String,
        byteSize: Int,
        entryCount: Int
    ) -> [CatalogAcceptedSourceHash] {
        guard acceptsDirectUpstreamRotation,
              !acceptedSourceHashes.contains(where: { $0.sha256 == checksumSHA256 })
        else {
            return acceptedSourceHashes
        }

        let localAcceptedHash = CatalogAcceptedSourceHash(
            sha256: checksumSHA256,
            byteSize: byteSize,
            entryCount: entryCount,
            reviewedAt: nil
        )
        return [localAcceptedHash] + acceptedSourceHashes
    }

    private static func defaultCategory(for source: BlocklistSource) -> String {
        if source.id.hasPrefix("blocklistproject") {
            return "security"
        }

        return "ads_tracking"
    }
}

public typealias CatalogParseFormat = CatalogBlocklistSource.CatalogParseFormat

public struct BlocklistCatalogFreshnessPolicy: Sendable {
    public static let oneWeekEvaluationWindow: TimeInterval = 7 * 24 * 60 * 60

    public let maxAge: TimeInterval

    public init(maxAge: TimeInterval = Self.oneWeekEvaluationWindow) {
        self.maxAge = maxAge
    }

    public func isFresh(age: TimeInterval?, statusIsError: Bool) -> Bool {
        guard !statusIsError else {
            return false
        }

        guard let age else {
            return true
        }

        return age >= 0 && age < maxAge
    }
}

private struct LoadedBlocklistPayload: Sendable {
    let data: Data
    let usedCache: Bool
    let checksumSHA256: String
}


public struct BlocklistCatalogSyncResult: Sendable {
    public let catalog: BlocklistCatalog
    public let sourceRuleSets: [String: DomainRuleSet]
    public let guardrailRuleSet: DomainRuleSet
    public let metadataBySourceID: [String: SourceSnapshotMetadata]
    public let usedCachedSourceIDs: Set<String>

    public init(
        catalog: BlocklistCatalog,
        sourceRuleSets: [String: DomainRuleSet],
        guardrailRuleSet: DomainRuleSet,
        metadataBySourceID: [String: SourceSnapshotMetadata],
        usedCachedSourceIDs: Set<String>
    ) {
        self.catalog = catalog
        self.sourceRuleSets = sourceRuleSets
        self.guardrailRuleSet = guardrailRuleSet
        self.metadataBySourceID = metadataBySourceID
        self.usedCachedSourceIDs = usedCachedSourceIDs
    }
}

public struct CustomBlocklistSyncResult: Sendable {
    public let sourceRuleSets: [String: DomainRuleSet]
    public let sourceHashes: [String: String]
    public let usedCachedSourceIDs: Set<String>

    public init(
        sourceRuleSets: [String: DomainRuleSet],
        sourceHashes: [String: String],
        usedCachedSourceIDs: Set<String>
    ) {
        self.sourceRuleSets = sourceRuleSets
        self.sourceHashes = sourceHashes
        self.usedCachedSourceIDs = usedCachedSourceIDs
    }
}

public enum BlocklistCatalogSyncError: LocalizedError, Equatable {
    case invalidHTTPStatus(Int)
    case invalidCatalog
    case invalidBlocklistEncoding(String)
    case blocklistTooLarge(sourceID: String, byteSize: Int)
    case checksumMismatch(sourceID: String)
    case noAcceptedSourceHashes(sourceID: String)
    case missingEnabledBlocklistSource(sourceID: String)
    case noCachedCatalog
    case noRulesAvailable
    case customBlocklistUnavailable(displayName: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPStatus(let statusCode):
            "The Lava Security catalog server returned HTTP \(statusCode)."
        case .invalidCatalog:
            "The Lava Security catalog could not be read."
        case .invalidBlocklistEncoding(let sourceID):
            "The downloaded blocklist for \(sourceID) is not valid UTF-8."
        case .blocklistTooLarge(let sourceID, let byteSize):
            "The downloaded blocklist for \(sourceID) is too large (\(byteSize) bytes)."
        case .checksumMismatch(let sourceID):
            "The downloaded blocklist checksum did not match for \(sourceID)."
        case .noAcceptedSourceHashes(let sourceID):
            "No accepted blocklist checksum is available for \(sourceID)."
        case .missingEnabledBlocklistSource(let sourceID):
            "No enabled blocklist source is available for \(sourceID)."
        case .noCachedCatalog:
            "No saved Lava Security catalog is available yet."
        case .noRulesAvailable:
            "No enabled downloaded filters are available yet."
        case .customBlocklistUnavailable(let displayName, let reason):
            "Couldn’t load the custom blocklist “\(displayName)”. \(reason)"
        }
    }
}

/// Thrown when a streamed download exceeds the byte ceiling before its body is fully
/// materialized. Deliberately not a `BlocklistCatalogSyncError` case so it needs no
/// public enum/switch changes: built-in sources fail closed (falling back to cache when
/// one exists), the custom-source path wraps it as `customBlocklistUnavailable` (named),
/// and the catalog loader treats it as just another failed remote attempt.
struct BlocklistDownloadSizeLimitExceeded: LocalizedError {
    let byteSize: Int
    let maximumByteCount: Int

    var errorDescription: String? {
        "The download exceeded the \(maximumByteCount / (1024 * 1024)) MB size limit (\(byteSize) bytes)."
    }
}

public typealias BlocklistCatalogDataFetcher = @Sendable (URL) async throws -> Data

public struct BlocklistCatalogSynchronizer: Sendable {
    public static let maximumBlocklistBytes = 25 * 1024 * 1024

    /// Cap on concurrent source fetch+parse. Sources are network-bound with up to
    /// 25 MB parses, so this bounds peak memory and socket use while still
    /// overlapping the dominant network latency across a multi-list configuration.
    static let maxConcurrentSourceCompilations = 4

    public let catalogURLs: [URL]
    public let cacheDirectoryURL: URL
    private let dataFetcher: BlocklistCatalogDataFetcher
    private let ruleSetCache: RuleSetCache
    private let catalogRepository: BlocklistCatalogRepository

    public init(
        cacheDirectoryURL: URL,
        dataFetcher: @escaping BlocklistCatalogDataFetcher = BlocklistCatalogSynchronizer.defaultDataFetcher
    ) {
        self.catalogURLs = LavaSecAPI.catalogURLs
        self.cacheDirectoryURL = cacheDirectoryURL
        self.dataFetcher = dataFetcher
        self.ruleSetCache = RuleSetCache(cacheDirectoryURL: cacheDirectoryURL)
        self.catalogRepository = BlocklistCatalogRepository(
            cacheDirectoryURL: cacheDirectoryURL,
            catalogURLs: catalogURLs,
            dataFetcher: dataFetcher
        )
    }

    public init(
        catalogURL: URL,
        cacheDirectoryURL: URL,
        dataFetcher: @escaping BlocklistCatalogDataFetcher = BlocklistCatalogSynchronizer.defaultDataFetcher
    ) {
        self.catalogURLs = [catalogURL]
        self.cacheDirectoryURL = cacheDirectoryURL
        self.dataFetcher = dataFetcher
        self.ruleSetCache = RuleSetCache(cacheDirectoryURL: cacheDirectoryURL)
        self.catalogRepository = BlocklistCatalogRepository(
            cacheDirectoryURL: cacheDirectoryURL,
            catalogURLs: catalogURLs,
            dataFetcher: dataFetcher
        )
    }

    public init(
        catalogURLs: [URL],
        cacheDirectoryURL: URL,
        dataFetcher: @escaping BlocklistCatalogDataFetcher = BlocklistCatalogSynchronizer.defaultDataFetcher
    ) {
        self.catalogURLs = catalogURLs
        self.cacheDirectoryURL = cacheDirectoryURL
        self.dataFetcher = dataFetcher
        self.ruleSetCache = RuleSetCache(cacheDirectoryURL: cacheDirectoryURL)
        self.catalogRepository = BlocklistCatalogRepository(
            cacheDirectoryURL: cacheDirectoryURL,
            catalogURLs: catalogURLs,
            dataFetcher: dataFetcher
        )
    }

    public func sync(enabledSourceIDs: Set<String>) async throws -> BlocklistCatalogSyncResult {
        let loadedCatalog = try await catalogRepository.loadRemoteCatalog()
        if loadedCatalog.shouldCache {
            try catalogRepository.saveLatestCatalog(loadedCatalog.data)
        }
        let result = try await compile(
            catalog: loadedCatalog.catalog,
            enabledSourceIDs: enabledSourceIDs,
            allowsNetwork: true,
            includesGuardrails: true
        )

        if !loadedCatalog.shouldCache || result.catalog != loadedCatalog.catalog {
            // Persisting the RESOLVED catalog records rotated versionIDs and
            // hashes, which keeps RuleSetCache's predicted-hash lookups valid
            // on the next run.
            try catalogRepository.saveLatestCatalog(Self.makeJSONEncoder().encode(result.catalog))
        }

        return result
    }

    public func loadCached(
        enabledSourceIDs: Set<String>,
        includesGuardrails: Bool = true
    ) async throws -> BlocklistCatalogSyncResult {
        let catalog = try loadLatestCatalog()
        return try await compile(
            catalog: catalog,
            enabledSourceIDs: enabledSourceIDs,
            allowsNetwork: false,
            includesGuardrails: includesGuardrails
        )
    }

    public func loadCachedCatalogMetadata() throws -> BlocklistCatalog {
        try loadLatestCatalog()
    }

    public func syncCustomBlocklists(_ sources: [CustomBlocklistSource]) async throws -> CustomBlocklistSyncResult {
        try await compileCustomBlocklists(sources, allowsNetwork: true)
    }

    public func loadCachedCustomBlocklists(_ sources: [CustomBlocklistSource]) async throws -> CustomBlocklistSyncResult {
        try await compileCustomBlocklists(sources, allowsNetwork: false)
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { byte in
            String(format: "%02x", byte)
        }.joined()
    }

    public static func latestCatalogURL(in cacheDirectoryURL: URL) -> URL {
        BlocklistCatalogRepository.latestCatalogURL(in: cacheDirectoryURL)
    }

    public static func cachedCatalogAge(
        in cacheDirectoryURL: URL,
        now: Date = Date()
    ) -> TimeInterval? {
        BlocklistCatalogRepository.cachedCatalogAge(in: cacheDirectoryURL, now: now)
    }

    public static func hasFreshCachedCatalog(
        in cacheDirectoryURL: URL,
        maxAge: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        guard let age = cachedCatalogAge(in: cacheDirectoryURL, now: now) else {
            return false
        }

        return age >= 0 && age < maxAge
    }

    public static let inactiveGPLLaunchSourceIDs: Set<String> = [
        "adguard-dns-filter"
    ]

    public static func cachedCatalogRequiresLowRiskLaunchRefresh(
        in cacheDirectoryURL: URL,
        requiredSourceIDs: Set<String>
    ) -> Bool {
        guard let catalog = try? BlocklistCatalogSynchronizer(
            cacheDirectoryURL: cacheDirectoryURL
        ).loadCachedCatalogMetadata() else {
            return false
        }

        let cachedSources = catalog.sources + catalog.guardrails
        let cachedSourceIDs = Set(catalog.sources.map(\.id))
        let hasInactiveGPLSource = cachedSources.contains { source in
            inactiveGPLLaunchSourceIDs.contains(source.id)
        }
        let hasLegacyGuardrails = !catalog.guardrails.isEmpty
        let missesLaunchSources = !requiredSourceIDs.isSubset(of: cachedSourceIDs)

        return hasInactiveGPLSource || hasLegacyGuardrails || missesLaunchSources
    }

    @discardableResult
    public static func migrateLowRiskLaunchCacheIfNeeded(
        in cacheDirectoryURL: URL,
        requiredSourceIDs: Set<String>
    ) -> Bool {
        let fileManager = FileManager.default
        var changed = false

        for sourceID in inactiveGPLLaunchSourceIDs {
            let directoryURL = blocklistDirectoryURL(for: sourceID, in: cacheDirectoryURL)
            if fileManager.fileExists(atPath: directoryURL.path) {
                try? fileManager.removeItem(at: directoryURL)
                changed = true
            }
        }

        guard cachedCatalogRequiresLowRiskLaunchRefresh(
            in: cacheDirectoryURL,
            requiredSourceIDs: requiredSourceIDs
        ) else {
            return changed
        }

        let catalogURL = latestCatalogURL(in: cacheDirectoryURL)
        if fileManager.fileExists(atPath: catalogURL.path) {
            try? fileManager.removeItem(at: catalogURL)
            changed = true
        }

        return changed
    }

    public static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: value) {
                return date
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
        return decoder
    }

    public static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func defaultDataFetcher(url: URL) async throws -> Data {
        // Stream the body to a temp file instead of buffering it in RAM. `data(from:)`
        // fully materializes the response in memory before any size check, so a remote
        // (or MITM / hostile custom-URL) oversized body could spike memory — a real
        // hazard given the sync can run inside the memory-constrained extension budget.
        // `download(from:)` writes the body to disk as it arrives, so peak memory stays
        // bounded regardless of body size; we only load the bytes into `Data` after
        // confirming the on-disk size is within the cap, which preserves the downstream
        // SHA-256 / acceptedHash verification.
        //
        // Scope note: this bounds *memory*. We don't abort mid-download on disk growth —
        // the async `download(from:delegate:)` can't carry a download delegate without
        // the `didFinishDownloadingTo` file-ownership footgun — so a hostile server can
        // still write up to a full body to the sandboxed, transient temp dir before the
        // size check rejects it. That residual is far weaker than the unbounded RAM
        // buffering this replaces.
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BlocklistCatalogSyncError.invalidCatalog
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            throw BlocklistCatalogSyncError.invalidHTTPStatus(httpResponse.statusCode)
        }

        if let byteCount = downloadedFileByteCount(at: tempURL),
           byteCount > maximumBlocklistBytes {
            throw BlocklistDownloadSizeLimitExceeded(
                byteSize: byteCount,
                maximumByteCount: maximumBlocklistBytes
            )
        }

        return try Data(contentsOf: tempURL)
    }

    static func downloadedFileByteCount(at url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    private func compile(
        catalog: BlocklistCatalog,
        enabledSourceIDs: Set<String>,
        allowsNetwork: Bool,
        includesGuardrails: Bool
    ) async throws -> BlocklistCatalogSyncResult {
        // Each source's fetch + parse is independent and writes only to its own
        // per-source cache directory, so they run with bounded concurrency to
        // overlap the dominant network latency. compileSource's leading
        // checkCancellation is the per-child cancellation checkpoint: when one
        // source throws, the throwing task group cancels the in-flight siblings.
        let enabledSources = catalog.sources.filter { enabledSourceIDs.contains($0.id) }
        let guardrailSources = includesGuardrails ? catalog.guardrails : []

        let sourceResults = try await mapBounded(
            enabledSources,
            maxConcurrent: Self.maxConcurrentSourceCompilations
        ) { source in
            try await self.compileSource(
                source,
                allowsNetwork: allowsNetwork,
                usesPredictedHashShortCircuit: true
            )
        }

        let guardrailResults = try await mapBounded(
            guardrailSources,
            maxConcurrent: Self.maxConcurrentSourceCompilations
        ) { source in
            try await self.compileSource(
                source,
                allowsNetwork: allowsNetwork,
                usesPredictedHashShortCircuit: false
            )
        }

        var sourceRuleSets: [String: DomainRuleSet] = [:]
        var metadataBySourceID: [String: SourceSnapshotMetadata] = [:]
        var usedCachedSourceIDs = Set<String>()
        var resolvedSourcesByID: [String: CatalogBlocklistSource] = [:]
        for result in sourceResults {
            sourceRuleSets[result.sourceID] = result.ruleSet
            resolvedSourcesByID[result.sourceID] = result.resolvedSource
            metadataBySourceID[result.sourceID] = result.metadata
            if result.usedCache {
                usedCachedSourceIDs.insert(result.sourceID)
            }
        }

        var guardrailRuleSet = DomainRuleSet()
        var resolvedGuardrailsByID: [String: CatalogBlocklistSource] = [:]
        for result in guardrailResults {
            guardrailRuleSet.formUnion(result.ruleSet)
            resolvedGuardrailsByID[result.sourceID] = result.resolvedSource
            metadataBySourceID[result.sourceID] = result.metadata
            if result.usedCache {
                usedCachedSourceIDs.insert(result.sourceID)
            }
        }

        let resolvedCatalog = BlocklistCatalog(
            schemaVersion: catalog.schemaVersion,
            catalogVersion: catalog.catalogVersion,
            generatedAt: catalog.generatedAt,
            sources: catalog.sources.map { resolvedSourcesByID[$0.id] ?? $0 },
            guardrails: catalog.guardrails.map { resolvedGuardrailsByID[$0.id] ?? $0 }
        )

        return BlocklistCatalogSyncResult(
            catalog: resolvedCatalog,
            sourceRuleSets: sourceRuleSets,
            guardrailRuleSet: guardrailRuleSet,
            metadataBySourceID: metadataBySourceID,
            usedCachedSourceIDs: usedCachedSourceIDs
        )
    }

    private struct CompiledSourceResult: Sendable {
        let sourceID: String
        let ruleSet: DomainRuleSet
        let resolvedSource: CatalogBlocklistSource
        let metadata: SourceSnapshotMetadata
        let usedCache: Bool
    }

    private func compileSource(
        _ source: CatalogBlocklistSource,
        allowsNetwork: Bool,
        usesPredictedHashShortCircuit: Bool
    ) async throws -> CompiledSourceResult {
        try Task.checkCancellation()
        let parseFormat = source.parseFormat.blocklistFormat

        // Parsed-rule cache hit by the catalog's predicted hash skips the
        // payload read, the SHA-256 of up to 25 MB of text, and the parse.
        if usesPredictedHashShortCircuit,
           let predictedHash = source.activeAcceptedHashValues().first,
           let cachedEntry = ruleSetCache.load(sourceID: source.id, contentSHA256: predictedHash, parseFormat: parseFormat) {
            let resolvedSource = source.resolvingDownloadedPayload(
                checksumSHA256: predictedHash,
                byteSize: cachedEntry.payloadByteSize,
                entryCount: cachedEntry.ruleSet.count
            )
            return CompiledSourceResult(
                sourceID: source.id,
                ruleSet: cachedEntry.ruleSet,
                resolvedSource: resolvedSource,
                metadata: metadata(for: resolvedSource, syncState: .nosync),
                usedCache: true
            )
        }

        let payload = try await loadBlocklistPayload(for: source, allowsNetwork: allowsNetwork)
        let ruleSet = try cachedOrParsedRuleSet(
            payload: payload,
            sourceID: source.id,
            parseFormat: parseFormat
        )
        let resolvedSource = source.resolvingDownloadedPayload(
            checksumSHA256: payload.checksumSHA256,
            byteSize: payload.data.count,
            entryCount: ruleSet.count
        )
        return CompiledSourceResult(
            sourceID: source.id,
            ruleSet: ruleSet,
            resolvedSource: resolvedSource,
            metadata: metadata(for: resolvedSource, syncState: payload.usedCache ? .nosync : .sync),
            usedCache: payload.usedCache
        )
    }

    /// Bounded-concurrency map preserving input order in the output. Runs at most
    /// `maxConcurrent` transforms at once; when one throws, the throwing task
    /// group cancels the in-flight siblings (their leading checkCancellation
    /// observes it) and the error propagates.
    private func mapBounded<Item: Sendable, Output: Sendable>(
        _ items: [Item],
        maxConcurrent: Int,
        _ transform: @escaping @Sendable (Item) async throws -> Output
    ) async throws -> [Output] {
        guard !items.isEmpty else {
            return []
        }

        let limit = max(1, min(maxConcurrent, items.count))
        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var nextIndex = 0
            while nextIndex < limit {
                let index = nextIndex
                let item = items[index]
                group.addTask { (index, try await transform(item)) }
                nextIndex += 1
            }

            var outputs = [Output?](repeating: nil, count: items.count)
            while let (index, output) = try await group.next() {
                outputs[index] = output
                if nextIndex < items.count {
                    let nextItemIndex = nextIndex
                    let item = items[nextItemIndex]
                    group.addTask { (nextItemIndex, try await transform(item)) }
                    nextIndex += 1
                }
            }

            return outputs.compactMap { $0 }
        }
    }

    private func loadLatestCatalog() throws -> BlocklistCatalog {
        try catalogRepository.cachedCatalog()
    }

    private func loadBlocklistPayload(
        for source: CatalogBlocklistSource,
        allowsNetwork: Bool
    ) async throws -> LoadedBlocklistPayload {
        let acceptedHashes = source.activeAcceptedHashValues()
        guard !acceptedHashes.isEmpty else {
            throw BlocklistCatalogSyncError.noAcceptedSourceHashes(sourceID: source.id)
        }

        if allowsNetwork {
            if let latestAcceptedHash = acceptedHashes.first,
               let cached = try? acceptedVersionedBlocklist(for: source, acceptedHashes: [latestAcceptedHash]) {
                return cached
            }

            do {
                let data = try await fetchData(from: source.sourceURL)
                try validateBlocklistSize(data.count, sourceID: source.id)
                let checksum = Self.sha256Hex(of: data)
                guard source.acceptsDownloadedHash(checksum) else {
                    if source.acceptsDirectUpstreamRotation {
                        try saveVersionedBlocklist(data, for: source, checksumSHA256: checksum)
                        try saveLatestBlocklist(data, for: source)
                        return LoadedBlocklistPayload(data: data, usedCache: false, checksumSHA256: checksum)
                    }

                    if let cached = try? acceptedCachedBlocklist(for: source, acceptedHashes: acceptedHashes) {
                        return cached
                    }

                    throw BlocklistCatalogSyncError.checksumMismatch(sourceID: source.id)
                }

                try saveVersionedBlocklist(data, for: source, checksumSHA256: checksum)
                try saveLatestBlocklist(data, for: source)
                return LoadedBlocklistPayload(data: data, usedCache: false, checksumSHA256: checksum)
            } catch {
                if !acceptedHashes.isEmpty,
                   let cached = try? acceptedCachedBlocklist(for: source, acceptedHashes: acceptedHashes) {
                    return cached
                }

                throw error
            }
        }

        guard !acceptedHashes.isEmpty else {
            throw BlocklistCatalogSyncError.noAcceptedSourceHashes(sourceID: source.id)
        }

        return try acceptedCachedBlocklist(for: source, acceptedHashes: acceptedHashes)
    }

    private func acceptedCachedBlocklist(
        for source: CatalogBlocklistSource,
        acceptedHashes: [String]
    ) throws -> LoadedBlocklistPayload {
        if let cached = try? acceptedVersionedBlocklist(for: source, acceptedHashes: acceptedHashes) {
            return cached
        }

        return try acceptedLatestBlocklist(for: source)
    }

    private func acceptedVersionedBlocklist(
        for source: CatalogBlocklistSource,
        acceptedHashes: [String]
    ) throws -> LoadedBlocklistPayload {
        for acceptedHash in acceptedHashes {
            let url = versionedBlocklistURL(for: source, checksumSHA256: acceptedHash)
            if let data = try? Data(contentsOf: url),
               Self.sha256Hex(of: data) == acceptedHash {
                try saveLatestBlocklist(data, for: source)
                return LoadedBlocklistPayload(data: data, usedCache: true, checksumSHA256: acceptedHash)
            }
        }

        throw BlocklistCatalogSyncError.checksumMismatch(sourceID: source.id)
    }

    private func acceptedLatestBlocklist(for source: CatalogBlocklistSource) throws -> LoadedBlocklistPayload {
        let payload = try latestBlocklist(for: source)
        guard source.acceptsDownloadedHash(payload.checksumSHA256) else {
            throw BlocklistCatalogSyncError.checksumMismatch(sourceID: source.id)
        }

        return payload
    }

    private func latestBlocklist(for source: CatalogBlocklistSource) throws -> LoadedBlocklistPayload {
        let data = try Data(contentsOf: latestBlocklistURL(for: source.id))
        return LoadedBlocklistPayload(data: data, usedCache: true, checksumSHA256: Self.sha256Hex(of: data))
    }

    private func parsePayload(_ data: Data, source: CatalogBlocklistSource) throws -> DomainRuleSet {
        try parsePayload(data, sourceID: source.id, format: source.parseFormat.blocklistFormat)
    }

    private func parsePayload(_ data: Data, source: CustomBlocklistSource) throws -> DomainRuleSet {
        try parsePayload(data, sourceID: source.id, format: source.parseFormat.blocklistFormat)
    }

    // Skips the parse when the exact payload bytes (by checksum) were parsed
    // before under the same format and parser rules version; stores fresh
    // parses for next time. Store failures never fail preparation.
    private func cachedOrParsedRuleSet(
        payload: LoadedBlocklistPayload,
        sourceID: String,
        parseFormat: BlocklistFormat
    ) throws -> DomainRuleSet {
        if let cachedEntry = ruleSetCache.load(
            sourceID: sourceID,
            contentSHA256: payload.checksumSHA256,
            parseFormat: parseFormat
        ) {
            return cachedEntry.ruleSet
        }

        let ruleSet = try parsePayload(payload.data, sourceID: sourceID, format: parseFormat)
        try? ruleSetCache.store(
            ruleSet,
            sourceID: sourceID,
            contentSHA256: payload.checksumSHA256,
            parseFormat: parseFormat,
            payloadByteSize: payload.data.count
        )
        return ruleSet
    }

    private func parsePayload(_ data: Data, sourceID: String, format: BlocklistFormat) throws -> DomainRuleSet {
        try validateBlocklistSize(data.count, sourceID: sourceID)
        // Decode leniently: a single invalid UTF-8 byte must not reject the whole
        // list, which for an enabled source under fail-CLOSED would block all DNS.
        // Malformed bytes become U+FFFD and fail per-line domain validation in the
        // parser instead, so only the offending line is dropped. (The
        // invalidBlocklistEncoding error stays in the public enum for the app's
        // error UI, but lenient decoding no longer produces it here.)
        let text = String(decoding: data, as: UTF8.self)

        return BlocklistParser()
            .parseRuleSet(text, format: format)
            .ruleSet
            .filteringOutRules(matchedBy: .lavaSecProtectedDomains)
    }

    private func compileCustomBlocklists(
        _ sources: [CustomBlocklistSource],
        allowsNetwork: Bool
    ) async throws -> CustomBlocklistSyncResult {
        let results = try await mapBounded(
            sources,
            maxConcurrent: Self.maxConcurrentSourceCompilations
        ) { source in
            try await self.compileCustomSource(source, allowsNetwork: allowsNetwork)
        }

        var sourceRuleSets: [String: DomainRuleSet] = [:]
        var sourceHashes: [String: String] = [:]
        var usedCachedSourceIDs = Set<String>()
        for result in results {
            sourceRuleSets[result.sourceID] = result.ruleSet
            sourceHashes[result.sourceID] = result.checksumSHA256
            if result.usedCache {
                usedCachedSourceIDs.insert(result.sourceID)
            }
        }

        return CustomBlocklistSyncResult(
            sourceRuleSets: sourceRuleSets,
            sourceHashes: sourceHashes,
            usedCachedSourceIDs: usedCachedSourceIDs
        )
    }

    private struct CompiledCustomSourceResult: Sendable {
        let sourceID: String
        let ruleSet: DomainRuleSet
        let checksumSHA256: String
        let usedCache: Bool
    }

    private func compileCustomSource(
        _ source: CustomBlocklistSource,
        allowsNetwork: Bool
    ) async throws -> CompiledCustomSourceResult {
        try Task.checkCancellation()
        let payload: LoadedBlocklistPayload
        do {
            payload = try await loadCustomBlocklistPayload(for: source, allowsNetwork: allowsNetwork)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession surfaces a cancelled in-flight download as URLError(.cancelled),
            // not CancellationError — propagate it as cancellation too, so a cancelled
            // refresh isn't reported to direct callers as a download failure.
            throw urlError
        } catch let syncError as BlocklistCatalogSyncError {
            // Already a specific, descriptive case (checksum mismatch, too large, …) —
            // propagate as-is so callers can still distinguish them.
            throw syncError
        } catch {
            // A foreign error (URLError download failure, or a no-cache file error):
            // name the specific list and keep the underlying reason so it surfaces as
            // an actionable "Couldn't load 'My List'. <why>" instead of a raw URLError
            // (or, pre-fix, a phantom latest.txt file error).
            throw BlocklistCatalogSyncError.customBlocklistUnavailable(
                displayName: source.displayName,
                reason: error.localizedDescription
            )
        }
        let ruleSet = try cachedOrParsedRuleSet(
            payload: payload,
            sourceID: source.id,
            parseFormat: source.parseFormat.blocklistFormat
        )
        return CompiledCustomSourceResult(
            sourceID: source.id,
            ruleSet: ruleSet,
            checksumSHA256: payload.checksumSHA256,
            usedCache: payload.usedCache
        )
    }

    private func loadCustomBlocklistPayload(
        for source: CustomBlocklistSource,
        allowsNetwork: Bool
    ) async throws -> LoadedBlocklistPayload {
        if allowsNetwork {
            do {
                let data = try await fetchData(from: source.sourceURL)
                try validateBlocklistSize(data.count, sourceID: source.id)
                let checksum = Self.sha256Hex(of: data)
                try saveVersionedCustomBlocklist(data, for: source, checksumSHA256: checksum)
                try saveLatestCustomBlocklist(data, for: source)
                return LoadedBlocklistPayload(data: data, usedCache: false, checksumSHA256: checksum)
            } catch {
                if let cached = try? acceptedCachedCustomBlocklist(for: source) {
                    return cached
                }

                throw error
            }
        }

        return try acceptedCachedCustomBlocklist(for: source)
    }

    private func acceptedCachedCustomBlocklist(for source: CustomBlocklistSource) throws -> LoadedBlocklistPayload {
        if let acceptedHash = source.lastAcceptedHash {
            if let cached = try? versionedCustomBlocklist(for: source, checksumSHA256: acceptedHash) {
                return cached
            }

            let payload = try latestCustomBlocklist(for: source)
            guard payload.checksumSHA256 == acceptedHash else {
                throw BlocklistCatalogSyncError.checksumMismatch(sourceID: source.id)
            }

            try saveVersionedCustomBlocklist(payload.data, for: source, checksumSHA256: acceptedHash)
            return payload
        }

        return try latestCustomBlocklist(for: source)
    }

    private func metadata(for source: CatalogBlocklistSource, syncState: SourceSyncState) -> SourceSnapshotMetadata {
        SourceSnapshotMetadata(
            sourceID: source.id,
            upstreamURL: source.sourceURL,
            upstreamFetchedAt: source.publishedAt,
            cachedAt: source.publishedAt,
            checksumSHA256: source.sourceHash,
            entryCount: source.entryCount,
            syncState: syncState
        )
    }

    private func fetchData(from url: URL) async throws -> Data {
        try await dataFetcher(url)
    }

    private func saveVersionedBlocklist(
        _ data: Data,
        for source: CatalogBlocklistSource,
        checksumSHA256: String
    ) throws {
        try FileManager.default.createDirectory(
            at: blocklistDirectoryURL(for: source.id),
            withIntermediateDirectories: true
        )
        try data.write(to: versionedBlocklistURL(for: source, checksumSHA256: checksumSHA256), options: [.atomic])
    }

    private func saveLatestBlocklist(_ data: Data, for source: CatalogBlocklistSource) throws {
        try FileManager.default.createDirectory(
            at: blocklistDirectoryURL(for: source.id),
            withIntermediateDirectories: true
        )
        try data.write(to: latestBlocklistURL(for: source.id), options: [.atomic])
    }

    private func saveLatestCustomBlocklist(_ data: Data, for source: CustomBlocklistSource) throws {
        try FileManager.default.createDirectory(
            at: customBlocklistDirectoryURL(for: source.id),
            withIntermediateDirectories: true
        )
        try data.write(to: latestCustomBlocklistURL(for: source.id), options: [.atomic])
    }

    private func saveVersionedCustomBlocklist(
        _ data: Data,
        for source: CustomBlocklistSource,
        checksumSHA256: String
    ) throws {
        try FileManager.default.createDirectory(
            at: customBlocklistDirectoryURL(for: source.id),
            withIntermediateDirectories: true
        )
        try data.write(to: versionedCustomBlocklistURL(for: source, checksumSHA256: checksumSHA256), options: [.atomic])
    }

    private func latestCustomBlocklist(for source: CustomBlocklistSource) throws -> LoadedBlocklistPayload {
        let data = try Data(contentsOf: latestCustomBlocklistURL(for: source.id))
        try validateBlocklistSize(data.count, sourceID: source.id)
        return LoadedBlocklistPayload(data: data, usedCache: true, checksumSHA256: Self.sha256Hex(of: data))
    }

    private func versionedCustomBlocklist(
        for source: CustomBlocklistSource,
        checksumSHA256: String
    ) throws -> LoadedBlocklistPayload {
        let data = try Data(contentsOf: versionedCustomBlocklistURL(for: source, checksumSHA256: checksumSHA256))
        try validateBlocklistSize(data.count, sourceID: source.id)
        guard Self.sha256Hex(of: data) == checksumSHA256 else {
            throw BlocklistCatalogSyncError.checksumMismatch(sourceID: source.id)
        }
        return LoadedBlocklistPayload(data: data, usedCache: true, checksumSHA256: checksumSHA256)
    }

    private func validateBlocklistSize(_ byteSize: Int, sourceID: String) throws {
        guard byteSize <= Self.maximumBlocklistBytes else {
            throw BlocklistCatalogSyncError.blocklistTooLarge(sourceID: sourceID, byteSize: byteSize)
        }
    }

    private func blocklistDirectoryURL(for sourceID: String) -> URL {
        Self.blocklistDirectoryURL(for: sourceID, in: cacheDirectoryURL)
    }

    private func customBlocklistDirectoryURL(for sourceID: String) -> URL {
        cacheDirectoryURL
            .appendingPathComponent("custom-blocklists", isDirectory: true)
            .appendingPathComponent(safePathComponent(sourceID), isDirectory: true)
    }

    private func versionedBlocklistURL(for source: CatalogBlocklistSource, checksumSHA256: String) -> URL {
        let hashPrefix = String(checksumSHA256.prefix(12))
        return blocklistDirectoryURL(for: source.id)
            .appendingPathComponent("\(safePathComponent(source.versionID))-\(hashPrefix).txt")
    }

    private func latestBlocklistURL(for sourceID: String) -> URL {
        blocklistDirectoryURL(for: sourceID).appendingPathComponent("latest.txt")
    }

    private func latestCustomBlocklistURL(for sourceID: String) -> URL {
        customBlocklistDirectoryURL(for: sourceID).appendingPathComponent("latest.txt")
    }

    private func versionedCustomBlocklistURL(for source: CustomBlocklistSource, checksumSHA256: String) -> URL {
        customBlocklistDirectoryURL(for: source.id)
            .appendingPathComponent("\(safePathComponent(source.cacheIdentity))-\(String(checksumSHA256.prefix(12))).txt")
    }

    private func safePathComponent(_ value: String) -> String {
        Self.safePathComponent(value)
    }

    private static func blocklistDirectoryURL(for sourceID: String, in cacheDirectoryURL: URL) -> URL {
        cacheDirectoryURL
            .appendingPathComponent("blocklists", isDirectory: true)
            .appendingPathComponent(safePathComponent(sourceID), isDirectory: true)
    }

    private static func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
    }
}
