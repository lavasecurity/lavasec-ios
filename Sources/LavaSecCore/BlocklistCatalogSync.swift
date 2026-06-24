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
        // Stamp the guardrail tier from STRUCTURAL array membership, not the server-supplied
        // `category` string: guardrail strictness (no rotation acceptance) must not hinge on a
        // freeform field arriving over the unsigned, TLS-only catalog channel.
        guardrails = try container.decode([CatalogBlocklistSource].self, forKey: .guardrails)
            .map { $0.markedAsGuardrail() }
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

    /// Category marker for Lava's own threat-guardrail tier (the can't-be-allowed lists).
    /// Guardrails stay strictly hash-pinned even though they are published source_url_only.
    static let guardrailCategory = "guardrail"

    /// Community lists are fetched directly from the upstream `source_url` over TLS, and the
    /// device accepts whatever bytes the author serves — subject to the size/rule caps applied
    /// at parse time. The catalog hash is ADVISORY (cache identity + audit), NOT a gate. This
    /// retires the stale-pin wedge: a fast-rotating list (blocklistproject-basic, HaGeZi, …)
    /// no longer fails the cold-start compile when its live hash differs from the catalog's
    /// last-pinned one — a single pinned hash can never track a list that rotates faster than
    /// we curate, and verifying a same-origin hash adds nothing over TLS anyway. The threat
    /// GUARDRAIL is excluded: it is Lava-curated, stable, and the safety-critical tier, so it
    /// stays strict (must still match an accepted hash on every path).
    var acceptsDirectUpstreamRotation: Bool {
        redistributionMode == "source_url_only" && category != Self.guardrailCategory
    }

    /// Returns a copy stamped into the guardrail tier. The catalog's `guardrails[]` array is the
    /// STRUCTURAL source of truth for the safety-critical tier; since dropping community
    /// hash-pinning keys strictness off `category == guardrailCategory`, we stamp it from array
    /// membership at the (unsigned, TLS-only) decode boundary so a server bug, schema drift, or a
    /// tampered `category` string can never silently relax a guardrail into community
    /// (rotation-accepting) behavior.
    func markedAsGuardrail() -> CatalogBlocklistSource {
        guard category != Self.guardrailCategory else { return self }
        return CatalogBlocklistSource(
            id: id,
            name: name,
            category: Self.guardrailCategory,
            riskLevel: riskLevel,
            defaultEnabled: defaultEnabled,
            licenseName: licenseName,
            attribution: attribution,
            projectURL: projectURL,
            sourceURL: sourceURL,
            versionID: versionID,
            entryCount: entryCount,
            byteSize: byteSize,
            sourceHash: sourceHash,
            acceptedSourceHashes: acceptedSourceHashes,
            normalizedHash: normalizedHash,
            publishedAt: publishedAt,
            redistributionMode: redistributionMode,
            parseFormat: parseFormat,
            licenseTextURL: licenseTextURL,
            noticeURL: noticeURL
        )
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
        // The bundled source now carries its own taxonomy category; use it so the
        // offline-fallback catalog matches the canonical spec instead of guessing.
        source.category.rawValue
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
    case blocklistExceedsRuleLimit(sourceID: String, ruleLimit: Int)
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
        case .blocklistExceedsRuleLimit(let sourceID, let ruleLimit):
            "The blocklist for \(sourceID) has more than \(ruleLimit) rules. Reduce its size or remove it."
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

/// Per-context budget for parsing blocklist sources. The app process has ample
/// memory and admits larger single lists; the packet-tunnel extension's fallback
/// compile runs under a ~50 MiB jetsam budget where the parser's dirty `Set<String>`
/// intermediate (~tens of bytes per rule, an order of magnitude above the 9 B/rule
/// mapped compact form) dominates, so it parses smaller and serially, and rejects
/// (fail-closed) a source too big to parse safely there — the app re-prepares the
/// full snapshot.
public struct BlocklistParseResourceBudget: Sendable {
    /// Hard ceiling on a single source's raw bytes (enforced before parsing).
    public let maximumBlocklistBytes: Int
    /// Hard ceiling on rules accepted from a single source (truncates above it).
    public let maxRulesPerSource: Int
    /// Max sources parsed concurrently (bounds the multiplied parse transient).
    public let maxConcurrentSources: Int

    public init(maximumBlocklistBytes: Int, maxRulesPerSource: Int, maxConcurrentSources: Int) {
        self.maximumBlocklistBytes = maximumBlocklistBytes
        self.maxRulesPerSource = maxRulesPerSource
        self.maxConcurrentSources = maxConcurrentSources
    }

    /// App/foreground default. ~45 MB admits a full 2M-rule list (the Plus per-source
    /// ceiling) even in verbose `0.0.0.0 domain` hosts form (~22 B/line); the rule cap,
    /// not the byte cap, binds for more compact formats. 4-way concurrency overlaps the
    /// dominant network latency across a multi-list configuration.
    public static let `default` = BlocklistParseResourceBudget(
        maximumBlocklistBytes: 45 * 1024 * 1024,
        maxRulesPerSource: FeatureLimits.plus.maxFilterRules,
        maxConcurrentSources: 4
    )

    /// In-extension streaming compile budget. The streaming compile
    /// (`StreamingCompactSnapshotCompiler`) parses each source straight into the on-disk
    /// compact artifact and NEVER builds a per-source dirty `Set<String>`, so it does NOT
    /// use `maxRulesPerSource` to cap a single source (it parses uncapped via
    /// `streamParsePayload`'s `BlocklistParser(maxRules: .max)`); memory is bounded by the
    /// AGGREGATE entry-array gate, `FilterSnapshotMemoryBudget.maxStreamingCompileRuleCount`,
    /// which throws to fail CLOSED so the app re-prepares the full artifact. Only the 25 MB
    /// `maximumBlocklistBytes` intake cap is consumed here (the streaming path is serial by
    /// construction, so `maxConcurrentSources` is unused too). `maxRulesPerSource` is set to
    /// the aggregate ceiling as a defensive value for any non-streaming caller of this
    /// budget.
    public static let inExtension = BlocklistParseResourceBudget(
        maximumBlocklistBytes: 25 * 1024 * 1024,
        maxRulesPerSource: FilterSnapshotMemoryBudget.maxStreamingCompileRuleCount,
        maxConcurrentSources: 1
    )
}

public struct BlocklistCatalogSynchronizer: Sendable {
    /// The app/default raw-bytes ceiling. Also used by the static network fetcher and
    /// surfaced to tests; per-instance enforcement uses `parseBudget.maximumBlocklistBytes`
    /// (smaller inside the extension). See `BlocklistParseResourceBudget`.
    public static let maximumBlocklistBytes = BlocklistParseResourceBudget.default.maximumBlocklistBytes

    public let catalogURLs: [URL]
    public let cacheDirectoryURL: URL
    public let parseBudget: BlocklistParseResourceBudget
    private let dataFetcher: BlocklistCatalogDataFetcher
    private let ruleSetCache: RuleSetCache
    private let catalogRepository: BlocklistCatalogRepository

    public init(
        cacheDirectoryURL: URL,
        dataFetcher: @escaping BlocklistCatalogDataFetcher = BlocklistCatalogSynchronizer.defaultDataFetcher,
        parseBudget: BlocklistParseResourceBudget = .default
    ) {
        self.catalogURLs = LavaSecAPI.catalogURLs
        self.cacheDirectoryURL = cacheDirectoryURL
        self.dataFetcher = dataFetcher
        self.parseBudget = parseBudget
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
        dataFetcher: @escaping BlocklistCatalogDataFetcher = BlocklistCatalogSynchronizer.defaultDataFetcher,
        parseBudget: BlocklistParseResourceBudget = .default
    ) {
        self.catalogURLs = [catalogURL]
        self.cacheDirectoryURL = cacheDirectoryURL
        self.dataFetcher = dataFetcher
        self.parseBudget = parseBudget
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
        dataFetcher: @escaping BlocklistCatalogDataFetcher = BlocklistCatalogSynchronizer.defaultDataFetcher,
        parseBudget: BlocklistParseResourceBudget = .default
    ) {
        self.catalogURLs = catalogURLs
        self.cacheDirectoryURL = cacheDirectoryURL
        self.dataFetcher = dataFetcher
        self.parseBudget = parseBudget
        self.ruleSetCache = RuleSetCache(cacheDirectoryURL: cacheDirectoryURL)
        self.catalogRepository = BlocklistCatalogRepository(
            cacheDirectoryURL: cacheDirectoryURL,
            catalogURLs: catalogURLs,
            dataFetcher: dataFetcher
        )
    }

    /// `commitsLatestCatalog: false` performs the full fetch + compile (writing the
    /// content-addressed, additive payloads to the cache) but does NOT write `catalog/latest.json`.
    /// The background refresh uses this so the latest.json commit can land ATOMICALLY with the
    /// artifact pointer flip (the tunnel derives its expected snapshot identity from latest.json;
    /// committing it here, ahead of an abortable background publish, would leave the cached
    /// catalog ahead of the pointer → the tunnel rejects the last-good artifact). The resolved
    /// catalog is still returned in the result, so the caller can commit it on publish success.
    /// The foreground keeps committing inline (default true); it always publishes, so its
    /// catalog and pointer stay consistent.
    public func sync(
        enabledSourceIDs: Set<String>,
        commitsLatestCatalog: Bool = true
    ) async throws -> BlocklistCatalogSyncResult {
        let loadedCatalog = try await catalogRepository.loadRemoteCatalog()
        if commitsLatestCatalog, loadedCatalog.shouldCache {
            try catalogRepository.saveLatestCatalog(loadedCatalog.data)
        }
        let result = try await compile(
            catalog: loadedCatalog.catalog,
            enabledSourceIDs: enabledSourceIDs,
            allowsNetwork: true,
            includesGuardrails: true
        )

        if commitsLatestCatalog, !loadedCatalog.shouldCache || result.catalog != loadedCatalog.catalog {
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

    /// What the in-extension streaming compile needs once every source has been
    /// streamed: the resolved catalog (to compute the snapshot identity) and the
    /// per-source rule counts + delivered IDs (for the summary and the missing-source
    /// check). The rule sets themselves are NOT returned — they were handed to the
    /// callbacks one at a time and released.
    public struct StreamingInExtensionCompileLoad: Sendable {
        public let resolvedCatalog: BlocklistCatalog
        public let deliveredBlockSourceIDs: Set<String>
        public let perSourceRuleCounts: [String: Int]
    }

    /// Serial, callback-per-RULE load for the packet-tunnel streaming compile
    /// (`StreamingCompactSnapshotCompiler`). Unlike `loadCached` (which materializes EVERY
    /// enabled source's parsed `DomainRuleSet` into one dictionary at once) AND unlike a
    /// per-source-callback variant (which would still build one full source's dirty
    /// `Set<String>` at a time, capping how large a single source can be), this STREAM-PARSES
    /// each source straight through `BlocklistParser.forEachBlockRule` and hands each accepted,
    /// protected-filtered rule to `onBlockRule` one at a time — NO per-source `DomainRuleSet`
    /// is ever built. The caller folds each rule directly into an on-disk compact blob, so the
    /// only resident growth is the compact entry table (bounded by the caller's aggregate
    /// gate, which throws to stop the parse). The parsed-rules cache is intentionally NOT
    /// consulted here (a cache entry written by the app under the 2M budget would otherwise be
    /// returned uncapped); every source is re-parsed from its cached raw payload (`allowsNetwork:
    /// false`), bounded by the parse budget's 25 MB intake cap. A source ID present in both the
    /// catalog and the custom lists is delivered twice (the tunnel unions them); its
    /// `perSourceRuleCounts` value sums both. Guardrail rules go to `onGuardrailRule` (the
    /// caller intersects them with the small allowlist); the caller passes
    /// `includesGuardrails: false` when there are no allowed domains, since the effective
    /// threat set is then empty regardless.
    public func streamCachedForInExtensionCompile(
        enabledSourceIDs: Set<String>,
        customSources: [CustomBlocklistSource],
        includesGuardrails: Bool,
        onBlockRule: (_ domain: String, _ matchesSubdomains: Bool) throws -> Void,
        onGuardrailRule: (_ domain: String, _ matchesSubdomains: Bool) throws -> Void
    ) async throws -> StreamingInExtensionCompileLoad {
        let catalog = try loadLatestCatalog()
        let enabledSources = catalog.sources.filter { enabledSourceIDs.contains($0.id) }
        let enabledCustomSources = customSources.filter { enabledSourceIDs.contains($0.id) }
        let guardrailSources = includesGuardrails ? catalog.guardrails : []

        var resolvedSourcesByID: [String: CatalogBlocklistSource] = [:]
        var resolvedGuardrailsByID: [String: CatalogBlocklistSource] = [:]
        var perSourceRuleCounts: [String: Int] = [:]
        var delivered = Set<String>()

        for source in enabledSources {
            let (resolved, count) = try await streamParseCatalogSource(source) { rule in
                try onBlockRule(rule.domain, rule.matchesSubdomains)
            }
            resolvedSourcesByID[source.id] = resolved
            perSourceRuleCounts[source.id, default: 0] += count
            delivered.insert(source.id)
        }

        for source in enabledCustomSources {
            let count = try await streamParseCustomSource(source) { rule in
                try onBlockRule(rule.domain, rule.matchesSubdomains)
            }
            perSourceRuleCounts[source.id, default: 0] += count
            delivered.insert(source.id)
        }

        for source in guardrailSources {
            let (resolved, _) = try await streamParseCatalogSource(source) { rule in
                try onGuardrailRule(rule.domain, rule.matchesSubdomains)
            }
            resolvedGuardrailsByID[source.id] = resolved
        }

        let resolvedCatalog = BlocklistCatalog(
            schemaVersion: catalog.schemaVersion,
            catalogVersion: catalog.catalogVersion,
            generatedAt: catalog.generatedAt,
            sources: catalog.sources.map { resolvedSourcesByID[$0.id] ?? $0 },
            guardrails: catalog.guardrails.map { resolvedGuardrailsByID[$0.id] ?? $0 }
        )

        return StreamingInExtensionCompileLoad(
            resolvedCatalog: resolvedCatalog,
            deliveredBlockSourceIDs: delivered,
            perSourceRuleCounts: perSourceRuleCounts
        )
    }

    /// Loads a catalog source's cached raw payload and stream-parses it through
    /// `onRule` (no `DomainRuleSet`). Returns the resolved source (for identity) and the
    /// emitted rule count (for the summary). Network-free.
    private func streamParseCatalogSource(
        _ source: CatalogBlocklistSource,
        onRule: (_ rule: DomainRule) throws -> Void
    ) async throws -> (resolved: CatalogBlocklistSource, count: Int) {
        try Task.checkCancellation()
        let payload = try await loadBlocklistPayload(for: source, allowsNetwork: false)
        let count = try streamParsePayload(
            payload.data,
            sourceID: source.id,
            parseFormat: source.parseFormat.blocklistFormat,
            onRule: onRule
        )
        let resolved = source.resolvingDownloadedPayload(
            checksumSHA256: payload.checksumSHA256,
            byteSize: payload.data.count,
            entryCount: count
        )
        return (resolved, count)
    }

    /// Custom-source counterpart of `streamParseCatalogSource`, mirroring
    /// `compileCustomSource`'s error wrapping. Returns the emitted rule count.
    private func streamParseCustomSource(
        _ source: CustomBlocklistSource,
        onRule: (_ rule: DomainRule) throws -> Void
    ) async throws -> Int {
        try Task.checkCancellation()
        let payload: LoadedBlocklistPayload
        do {
            payload = try await loadCustomBlocklistPayload(for: source, allowsNetwork: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch let syncError as BlocklistCatalogSyncError {
            throw syncError
        } catch {
            throw BlocklistCatalogSyncError.customBlocklistUnavailable(
                displayName: source.displayName,
                reason: error.localizedDescription
            )
        }
        return try streamParsePayload(
            payload.data,
            sourceID: source.id,
            parseFormat: source.parseFormat.blocklistFormat,
            onRule: onRule
        )
    }

    /// Stream-parses raw payload bytes, handing each accepted block rule (after the
    /// `lavaSecProtectedDomains` post-filter, matching `parsePayload`) to `onRule`. No
    /// per-source rule cap is applied — a single source streams uncapped, because the
    /// in-extension AGGREGATE is bounded by the caller's per-rule gate (which throws to stop
    /// the parse), so a too-large source fails CLOSED rather than being silently truncated.
    /// The `parseBudget` 25 MB intake cap bounds the input; the parse holds no `Set`.
    private func streamParsePayload(
        _ data: Data,
        sourceID: String,
        parseFormat: BlocklistFormat,
        onRule: (_ rule: DomainRule) throws -> Void
    ) throws -> Int {
        try validateBlocklistSize(data.count, sourceID: sourceID)
        var count = 0
        try BlocklistParser(maxRules: Int.max).forEachBlockRule(data: data, format: parseFormat) { rule in
            guard !DomainRuleSet.lavaSecProtectedDomains.containsNormalized(rule.domain) else {
                return
            }
            count += 1
            try onRule(rule)
        }
        return count
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

    // Temporary launch holds for GPL catalog sources that must be purged from
    // existing caches. AdGuard is intentionally active under the source-url-only,
    // off-by-default posture, so this set is empty for the catalog launch.
    public static let inactiveGPLLaunchSourceIDs: Set<String> = []

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
        // (or MITM / hostile custom-URL) oversized body could spike memory. (This fetcher
        // is the app/foreground network path only — the extension compiles cache-only,
        // `allowsNetwork: false`, and never invokes it — but bounding download memory in
        // the app is still worthwhile.)
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
            maxConcurrent: parseBudget.maxConcurrentSources
        ) { source in
            try await self.compileSource(
                source,
                allowsNetwork: allowsNetwork,
                usesPredictedHashShortCircuit: true
            )
        }

        let guardrailResults = try await mapBounded(
            guardrailSources,
            maxConcurrent: parseBudget.maxConcurrentSources
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
        // payload read, the SHA-256 of up to 45 MB of text, and the parse.
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
            if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
               Self.sha256Hex(of: data) == acceptedHash {
                try saveLatestBlocklist(data, for: source)
                return LoadedBlocklistPayload(data: data, usedCache: true, checksumSHA256: acceptedHash)
            }
        }

        throw BlocklistCatalogSyncError.checksumMismatch(sourceID: source.id)
    }

    private func acceptedLatestBlocklist(for source: CatalogBlocklistSource) throws -> LoadedBlocklistPayload {
        let payload = try latestBlocklist(for: source)
        // Community (source_url_only, non-guardrail) lists accept the last TLS-fetched, size-
        // validated cached content as-is — the catalog hash is advisory, so a rotated cached
        // list is served (size/rule caps still apply at parse time) instead of wedging the
        // cold-start in-extension compile. This is the cache-only counterpart to the network
        // path's existing `acceptsDirectUpstreamRotation` acceptance. The threat guardrail
        // (acceptsDirectUpstreamRotation == false) stays strict and must match an accepted hash.
        guard source.acceptsDirectUpstreamRotation || source.acceptsDownloadedHash(payload.checksumSHA256) else {
            throw BlocklistCatalogSyncError.checksumMismatch(sourceID: source.id)
        }

        return payload
    }

    private func latestBlocklist(for source: CatalogBlocklistSource) throws -> LoadedBlocklistPayload {
        // Map the cached payload rather than reading it dirty: the streaming parse and
        // SHA-256 touch pages on demand, and a mapped file is clean/reclaimable, so a
        // large raw list doesn't add to the jetsam-counted footprint on the in-extension
        // fallback compile path (which loads cached payloads under the ~50 MiB budget).
        let data = try Data(contentsOf: latestBlocklistURL(for: source.id), options: [.mappedIfSafe])
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
        // Stream the parse off the payload bytes (memory-mapped on cache reads),
        // decoding one line at a time leniently: a single invalid UTF-8 byte must not
        // reject the whole list, which for an enabled source under fail-CLOSED would
        // block all DNS. Malformed bytes become U+FFFD and fail per-line domain
        // validation in the parser instead, so only the offending line is dropped. (The
        // invalidBlocklistEncoding error stays in the public enum for the app's error UI,
        // but lenient decoding no longer produces it here.)
        //
        // This Set-building parse backs the foreground app's `loadCached` path. The per-source
        // cap is `parseBudget.maxRulesPerSource` (app `.default`: the Plus ceiling, 2M) — the
        // tier ceiling, not the higher device memory budget (~3.26M), on purpose, since the
        // parsed intermediate is a dirty `Set<String>` (~tens of bytes/rule). The
        // subscription-tier aggregate (Free 500K / Plus 2M) and the device budget are enforced
        // on the deduped union in FilterSnapshotPreparationService, the authoritative per-user
        // gate. (The in-extension streaming compile parses with no Set at all.)
        //
        // The cap is enforced on UNIQUE rules by counting the deduped set as it is built off
        // the streaming emit, and a source that would EXCEED it surfaces an over-limit error
        // rather than being silently truncated: returning a partial set would cache + serve it
        // under the source's full identity (under-blocking) and mask the overage from the
        // aggregate gate (a source truncated to exactly the cap slips the `> limit` check).
        // Because `forEachBlockRule` emits only valid, accepted rules and duplicates are
        // absorbed by the set, a duplicate, footer/comment, or invalid-domain line never trips
        // the cap — so an in-limit source (even one at exactly the cap with trailing noise)
        // loads in FULL. The set is bounded to `ruleLimit + 1`.
        let ruleLimit = parseBudget.maxRulesPerSource
        var ruleSet = DomainRuleSet()
        var exceededRuleLimit = false
        do {
            try BlocklistParser(maxRules: Int.max).forEachBlockRule(data: data, format: format) { rule in
                guard !DomainRuleSet.lavaSecProtectedDomains.containsNormalized(rule.domain) else {
                    return
                }
                ruleSet.insert(rule)
                if ruleSet.count > ruleLimit {
                    exceededRuleLimit = true
                    throw OverPerSourceRuleLimit()
                }
            }
        } catch is OverPerSourceRuleLimit {
            // Sentinel only — stop the parse as soon as a NEW unique rule exceeds the cap.
        }
        guard !exceededRuleLimit else {
            throw BlocklistCatalogSyncError.blocklistExceedsRuleLimit(sourceID: sourceID, ruleLimit: ruleLimit)
        }
        return ruleSet
    }

    /// Sentinel thrown from the streaming parse callback to stop once a source's unique rule
    /// count exceeds the per-source cap; never escapes `parsePayload`.
    private struct OverPerSourceRuleLimit: Error {}

    private func compileCustomBlocklists(
        _ sources: [CustomBlocklistSource],
        allowsNetwork: Bool
    ) async throws -> CustomBlocklistSyncResult {
        let results = try await mapBounded(
            sources,
            maxConcurrent: parseBudget.maxConcurrentSources
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
        // NOTE: a custom source's `lastAcceptedHash` is NOT a curation pin (the thing this PR
        // drops for catalog community lists) — it is the FREEZE anchor for a downgraded
        // filter (`customListPolicy == .cacheOnly`), which must keep serving exactly the bytes
        // it was frozen at and fail closed otherwise rather than silently re-hash from latest.
        // The custom NETWORK path already accepts upstream rotation (loadCustomBlocklistPayload),
        // so there is no rotation wedge to fix here. Leave the freeze gate intact.
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
        let data = try Data(contentsOf: latestCustomBlocklistURL(for: source.id), options: [.mappedIfSafe])
        try validateBlocklistSize(data.count, sourceID: source.id)
        return LoadedBlocklistPayload(data: data, usedCache: true, checksumSHA256: Self.sha256Hex(of: data))
    }

    private func versionedCustomBlocklist(
        for source: CustomBlocklistSource,
        checksumSHA256: String
    ) throws -> LoadedBlocklistPayload {
        let data = try Data(contentsOf: versionedCustomBlocklistURL(for: source, checksumSHA256: checksumSHA256), options: [.mappedIfSafe])
        try validateBlocklistSize(data.count, sourceID: source.id)
        guard Self.sha256Hex(of: data) == checksumSHA256 else {
            throw BlocklistCatalogSyncError.checksumMismatch(sourceID: source.id)
        }
        return LoadedBlocklistPayload(data: data, usedCache: true, checksumSHA256: checksumSHA256)
    }

    private func validateBlocklistSize(_ byteSize: Int, sourceID: String) throws {
        guard byteSize <= parseBudget.maximumBlocklistBytes else {
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
