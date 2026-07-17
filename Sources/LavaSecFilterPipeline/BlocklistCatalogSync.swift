import CryptoKit
import LavaSecKit
import LavaSecNetworking
import Foundation

/// Base endpoints used to reach Lava Security services.
public enum LavaSecAPI {
    /// Primary production API base URL.
    public static let productionBaseURL = URL(string: "https://api.lavasecurity.app")!
    /// Fallback API base URL used when the primary service is unavailable.
    public static let fallbackBaseURL = URL(string: "https://lavasec-api.lavasec.workers.dev")!
    internal static let catalogURL = catalogURL(baseURL: productionBaseURL)
    internal static let fallbackCatalogURL = catalogURL(baseURL: fallbackBaseURL)
    internal static let catalogURLs = [catalogURL, fallbackCatalogURL]

    private static func catalogURL(baseURL: URL) -> URL {
        baseURL
        .appendingPathComponent("v1")
        .appendingPathComponent("catalog")
    }
}

/// Versioned metadata describing available blocklist and guardrail sources.
public struct BlocklistCatalog: Equatable, Codable, Sendable {
    internal static let builtInSourceURLCatalogVersion = "built-in-source-url-catalog-v1"

    package let schemaVersion: Int
    /// Identifier for the catalog revision.
    public let catalogVersion: String
    /// Time recorded by the catalog producer for this revision.
    public let generatedAt: Date
    /// Selectable blocklist sources in this catalog.
    public let sources: [CatalogBlocklistSource]
    package let guardrails: [CatalogBlocklistSource]

    package init(
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

    /// Decodes the supported catalog schema and marks decoded guardrail entries.
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

    internal static func builtInSourceURLCatalog() -> BlocklistCatalog {
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

/// Evaluates whether cached catalog metadata is fresh enough to use.
public struct BlocklistCatalogFreshnessPolicy: Sendable {
    /// Default evaluation window of one week.
    public static let oneWeekEvaluationWindow: TimeInterval = 7 * 24 * 60 * 60

    internal let maxAge: TimeInterval

    /// Creates a freshness policy with the maximum accepted cache age.
    public init(maxAge: TimeInterval = Self.oneWeekEvaluationWindow) {
        self.maxAge = maxAge
    }

    /// Returns whether a non-error status and optional cache age are considered fresh.
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

/// Catalog synchronization output used to prepare a filter snapshot.
public struct BlocklistCatalogSyncResult: Sendable {
    /// Resolved catalog, including accepted source rotations.
    public let catalog: BlocklistCatalog
    /// Parsed rule sets keyed by selected source identifier.
    public let sourceRuleSets: [String: DomainRuleSet]
    /// Combined rules supplied by catalog guardrail sources.
    public let guardrailRuleSet: DomainRuleSet
    /// Snapshot metadata keyed by selected source identifier.
    public let metadataBySourceID: [String: SourceSnapshotMetadata]
    /// Source identifiers whose payloads were loaded from cache.
    public let usedCachedSourceIDs: Set<String>

    package init(
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

/// Synchronization output for user-provided blocklist sources.
public struct CustomBlocklistSyncResult: Sendable {
    /// Parsed rule sets keyed by custom source identifier.
    public let sourceRuleSets: [String: DomainRuleSet]
    /// Accepted payload hashes keyed by custom source identifier.
    public let sourceHashes: [String: String]
    /// Custom source identifiers whose payloads were loaded from cache.
    public let usedCachedSourceIDs: Set<String>

    package init(
        sourceRuleSets: [String: DomainRuleSet],
        sourceHashes: [String: String],
        usedCachedSourceIDs: Set<String>
    ) {
        self.sourceRuleSets = sourceRuleSets
        self.sourceHashes = sourceHashes
        self.usedCachedSourceIDs = usedCachedSourceIDs
    }
}

/// Errors produced while fetching, validating, or compiling blocklist sources.
public enum BlocklistCatalogSyncError: LocalizedError, Equatable {
    /// A catalog or source request returned a non-success HTTP status.
    case invalidHTTPStatus(Int)
    /// Catalog metadata could not be validated or decoded.
    case invalidCatalog
    /// A source payload could not be interpreted as supported text.
    case invalidBlocklistEncoding(String)
    /// A source payload exceeded the configured byte budget.
    case blocklistTooLarge(sourceID: String, byteSize: Int)
    /// A source produced more accepted rules than its configured limit.
    case blocklistExceedsRuleLimit(sourceID: String, ruleLimit: Int)
    /// A source payload did not match an accepted checksum.
    case checksumMismatch(sourceID: String)
    /// A catalog source supplied no checksum that could authorize its payload.
    case noAcceptedSourceHashes(sourceID: String)
    /// An enabled source identifier was absent from the resolved inputs.
    case missingEnabledBlocklistSource(sourceID: String)
    /// No saved catalog metadata was available for a cache-only operation.
    case noCachedCatalog
    /// Synchronization completed without any usable rules.
    case noRulesAvailable
    /// A custom source could not be fetched or loaded from cache.
    case customBlocklistUnavailable(displayName: String, reason: String)

    /// Localized description suitable for presenting the synchronization failure.
    public var errorDescription: String? {
        switch self {
        case .invalidHTTPStatus(let statusCode):
            "The Lava Security catalog server returned HTTP \(statusCode)."
        case .invalidCatalog:
            "The Lava Security catalog could not be read."
        case .invalidBlocklistEncoding(let sourceID):
            LavaCoreStrings.localizedFormat("core.catalogSync.invalidBlocklistEncoding", sourceID)
        case .blocklistTooLarge(let sourceID, let byteSize):
            LavaCoreStrings.localizedFormat("core.catalogSync.blocklistTooLarge", sourceID, byteSize)
        case .blocklistExceedsRuleLimit(let sourceID, let ruleLimit):
            LavaCoreStrings.localizedFormat("core.catalogSync.blocklistExceedsRuleLimit", sourceID, ruleLimit)
        case .checksumMismatch(let sourceID):
            "The downloaded blocklist checksum did not match for \(sourceID)."
        case .noAcceptedSourceHashes(let sourceID):
            "No accepted blocklist checksum is available for \(sourceID)."
        case .missingEnabledBlocklistSource(let sourceID):
            "No enabled blocklist source is available for \(sourceID)."
        case .noCachedCatalog:
            "No saved Lava Security catalog is available yet."
        case .noRulesAvailable:
            LavaCoreStrings.localized("core.catalogSync.noRulesAvailable")
        case .customBlocklistUnavailable(let displayName, let reason):
            LavaCoreStrings.localizedFormat("core.catalogSync.customBlocklistUnavailable", displayName, reason)
        }
    }
}

/// Asynchronous byte fetcher used by catalog synchronizers.
public typealias BlocklistCatalogDataFetcher = @Sendable (URL) async throws -> Data

// `BlocklistDownloadSizeLimitExceeded` (previously here) lives in LavaSecNetworking beside its
// throw sites — the streaming body decoders in PinnedPublicHTTPSFetcher.swift.

extension PinnedPublicHTTPSFetcher {
    /// Catalog-facing fetch: the LavaSecNetworking pinned transport plus the catalog sync's
    /// HTTP-success policy. Lives engine-side because `BlocklistCatalogSyncError` is the
    /// sync engine's error vocabulary — the transport target must not depend on it, the
    /// same boundary rule as the `CatalogParseFormat.blocklistFormat` bridge (#302).
    /// Interim (1xx) responses and redirects are already consumed by `fetchResponse`;
    /// what reaches this guard is the final status.
    static func fetch(url: URL, maximumByteCount: Int) async throws -> Data {
        let (status, body) = try await fetchResponse(url: url, maximumByteCount: maximumByteCount)
        guard (200..<300).contains(status) else {
            throw BlocklistCatalogSyncError.invalidHTTPStatus(status)
        }
        return body
    }
}

/// Per-context budget for parsing blocklist sources. The app process has ample
/// memory and admits larger single lists; the packet-tunnel extension's fallback
/// compile runs under a ~50 MiB jetsam budget where the parser's dirty `Set<String>`
/// intermediate (~tens of bytes per rule, an order of magnitude above the 9 B/rule
/// mapped compact form) dominates, so it parses smaller and serially, and rejects
/// (fail-closed) a source too big to parse safely there — the app re-prepares the
/// full snapshot.
public struct BlocklistParseResourceBudget: Sendable {
    /// Hard ceiling on a single source's raw bytes (enforced before parsing).
    package let maximumBlocklistBytes: Int
    /// Hard ceiling on rules accepted from a single source (truncates above it).
    package let maxRulesPerSource: Int
    /// Max sources parsed concurrently (bounds the multiplied parse transient).
    package let maxConcurrentSources: Int

    package init(maximumBlocklistBytes: Int, maxRulesPerSource: Int, maxConcurrentSources: Int) {
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
    internal static let inExtension = BlocklistParseResourceBudget(
        maximumBlocklistBytes: 25 * 1024 * 1024,
        maxRulesPerSource: FilterSnapshotMemoryBudget.maxStreamingCompileRuleCount,
        maxConcurrentSources: 1
    )
}

/// Fetches catalog metadata and compiles selected blocklist payloads into rule sets.
public struct BlocklistCatalogSynchronizer: Sendable {
    /// The app/default raw-bytes ceiling. Also used by the static network fetcher and
    /// surfaced to tests; per-instance enforcement uses `parseBudget.maximumBlocklistBytes`
    /// (smaller inside the extension). See `BlocklistParseResourceBudget`.
    package static let maximumBlocklistBytes = BlocklistParseResourceBudget.default.maximumBlocklistBytes

    internal let catalogURLs: [URL]
    internal let cacheDirectoryURL: URL
    internal let parseBudget: BlocklistParseResourceBudget
    private let dataFetcher: BlocklistCatalogDataFetcher
    private let ruleSetCache: RuleSetCache
    private let catalogRepository: BlocklistCatalogRepository

    /// Creates a synchronizer for the production catalog endpoints and a cache directory.
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

    package init(
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

    package init(
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
    ///
    /// One deliberate side effect in the non-committing mode: when the NETWORK fetch succeeded and
    /// the resolved catalog is value-equal to the cached one, the cached file's mtime — the
    /// freshness evidence warm reuse gates on — is re-stamped WITHOUT a content write. Without it,
    /// a device whose catalog simply stops changing ages past the 7-day freshness window even
    /// though every background run verified it current, and the headless warm switch (and the
    /// background pending-switch drain) defers forever (lavasec-infra
    /// `plans/2026-07-16-deferred-automation-switch-background-warm-and-apply-plan.md`). A
    /// cache-fallback load (`shouldCache == false`) never re-stamps — that would fake freshness
    /// from our own stale bytes. A resolved catalog that DIFFERS (even in sources the user has
    /// not enabled) never re-stamps either: the cached basis is genuinely behind upstream, and
    /// only a real commit may move the evidence.
    /// pinned: BlocklistCatalogFreshnessRefreshTests.testNetworkVerifiedUnchangedCatalogRestampsFreshnessWithoutContentWrite
    /// pinned: BlocklistCatalogFreshnessRefreshTests.testCacheFallbackNeverRestampsFreshness
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

        if !commitsLatestCatalog, loadedCatalog.shouldCache,
           let cachedCatalog = try? loadLatestCatalog(), cachedCatalog == result.catalog {
            // Network-verified unchanged: the cached catalog IS what a fresh resolve produces, so
            // re-stamping its mtime is honest "verified current at <now>" evidence — value
            // equality (not raw-byte compare) because the cache may hold the RESOLVED encoding
            // from a prior commit while the fetch returns upstream bytes. KNOWN RESIDUAL (fail-safe,
            // tracked in the drain plan's residuals): full-catalog equality is deliberately strict —
            // a cache holding a rotated entry for a source the user has SINCE DISABLED never compares
            // equal to a resolve that leaves disabled sources unresolved, so that shape keeps aging
            // and defers at the foreground exactly as before this re-stamp existed. Catalog-wide
            // freshness certifies reuse for ANY filter's selection (a switch target may enable
            // sources outside the current set), so a narrower enabled-selection predicate would
            // over-claim; only a real commit may move the evidence for a diverged cache.
            catalogRepository.refreshCachedCatalogFreshness()
        }

        return result
    }

    /// Compiles selected sources from cached catalog and payload data without network access.
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

    /// Loads cached catalog metadata without compiling source payloads.
    public func loadCachedCatalogMetadata() throws -> BlocklistCatalog {
        try loadLatestCatalog()
    }

    /// Fetches and compiles the supplied custom blocklist sources.
    public func syncCustomBlocklists(_ sources: [CustomBlocklistSource]) async throws -> CustomBlocklistSyncResult {
        try await compileCustomBlocklists(sources, allowsNetwork: true)
    }

    /// Compiles the supplied custom blocklist sources using cached payloads only.
    public func loadCachedCustomBlocklists(_ sources: [CustomBlocklistSource]) async throws -> CustomBlocklistSyncResult {
        try await compileCustomBlocklists(sources, allowsNetwork: false)
    }

    /// What the in-extension streaming compile needs once every source has been
    /// streamed: the resolved catalog (to compute the snapshot identity) and the
    /// per-source rule counts + delivered IDs (for the summary and the missing-source
    /// check). The rule sets themselves are NOT returned — they were handed to the
    /// callbacks one at a time and released.
    internal struct StreamingInExtensionCompileLoad: Sendable {
        internal let resolvedCatalog: BlocklistCatalog
        internal let deliveredBlockSourceIDs: Set<String>
        internal let perSourceRuleCounts: [String: Int]
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
    internal func streamCachedForInExtensionCompile(
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

    package static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { byte in
            String(format: "%02x", byte)
        }.joined()
    }

    /// Returns the standard cached-catalog file within a cache directory.
    public static func latestCatalogURL(in cacheDirectoryURL: URL) -> URL {
        BlocklistCatalogRepository.latestCatalogURL(in: cacheDirectoryURL)
    }

    /// Returns the cached catalog's age from its file modification date, when available.
    public static func cachedCatalogAge(
        in cacheDirectoryURL: URL,
        now: Date = Date()
    ) -> TimeInterval? {
        BlocklistCatalogRepository.cachedCatalogAge(in: cacheDirectoryURL, now: now)
    }

    /// Returns whether cached catalog metadata exists and is younger than the supplied age.
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
    internal static let inactiveGPLLaunchSourceIDs: Set<String> = []

    /// Returns whether cached launch metadata needs a low-risk catalog refresh.
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

    /// Removes inactive launch payloads and stale catalog metadata when needed.
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

    /// Creates the decoder used for catalog timestamps and metadata.
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

    /// Creates the encoder used for persisted catalog metadata.
    public static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Fetches a public HTTPS resource with connection pinning and the default byte ceiling.
    public static func defaultDataFetcher(url: URL) async throws -> Data {
        // SEC-1 connect-time peer-IP validation. This is the app/foreground network path for
        // BOTH the first-party catalog manifest and every (built-in or custom) blocklist
        // source. The extension compiles cache-only (`allowsNetwork: false`) and never invokes
        // it.
        //
        // `PinnedPublicHTTPSFetcher.fetch` runs the fetch over an IP-PINNED `NWConnection`
        // instead of `URLSession`: it re-validates every hop (initial URL + each redirect),
        // resolves each host ONCE, requires every resolved address to be public, and binds the
        // connection to a validated address — so a source or `Location` whose hostname
        // DNS-resolves to a private/loopback/reserved target (the residual `URLSession` +
        // `validatePublicSourceURL` left open, incl. DNS rebinding) is refused fail-closed.
        // TLS keeps its full strength: SNI + certificate validation still run against the
        // hostname, not the pinned IP.
        //
        // Memory stays bounded: the body is decoded incrementally and the download aborts the
        // instant the decoded byte count exceeds `maximumBlocklistBytes` (the same downstream
        // SHA-256 / acceptedHash verification runs on the returned bytes).
        try await PinnedPublicHTTPSFetcher.fetch(url: url, maximumByteCount: maximumBlocklistBytes)
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
        // on the deduped union: FilterSnapshotPreparationService is the cold-compile gate
        // (throws the actionable error), and INV-TIER-1 gates every other publish/reuse/serve
        // point — the refresh republish, warm/startup reuse, and the tunnel's load/compile/LKG
        // reads — since those paths never run the cold prepare. (The in-extension streaming
        // compile parses with no Set at all.)
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
