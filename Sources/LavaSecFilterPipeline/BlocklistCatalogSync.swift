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
    // A rule needs at least one input byte. Bound unresolved estimates by the existing
    // download ceiling so later additions of local rules and warm-pass totals have headroom.
    private static let maximumSourceEntryCount = BlocklistParseResourceBudget.default.maximumBlocklistBytes

    package let schemaVersion: Int
    /// Identifier for the catalog revision.
    public let catalogVersion: String
    /// Time recorded by the catalog producer for this revision.
    public let generatedAt: Date
    /// Selectable blocklist sources in this catalog.
    public let sources: [CatalogBlocklistSource]
    package let guardrails: [CatalogBlocklistSource]
    package let authorization: CatalogAuthorization?
    package let withdrawnSources: [String]

    /// Builds a renewal using the prior catalog's artifact inputs. Disabled sources may
    /// retain locally resolved observations absent from a network response; preserve those
    /// bytes rather than treating advisory drift as a definition change or artifact update.
    public func authorizationRenewal(preserving prior: BlocklistCatalog) -> BlocklistCatalog? {
        guard authorization != nil, authorization != prior.authorization,
              schemaVersion == prior.schemaVersion, catalogVersion == prior.catalogVersion,
              sources.map(CatalogSourceDefinition.init).sorted(by: { $0.id < $1.id })
                == prior.sources.map(CatalogSourceDefinition.init).sorted(by: { $0.id < $1.id }),
              guardrails.map(CatalogSourceDefinition.init).sorted(by: { $0.id < $1.id })
                == prior.guardrails.map(CatalogSourceDefinition.init).sorted(by: { $0.id < $1.id }),
              withdrawnSources.sorted() == prior.withdrawnSources.sorted()
        else { return nil }
        return BlocklistCatalog(schemaVersion: prior.schemaVersion, catalogVersion: prior.catalogVersion,
            generatedAt: generatedAt, sources: prior.sources, guardrails: prior.guardrails,
            authorization: authorization, withdrawnSources: prior.withdrawnSources)
    }

    /// Selected catalog identities retired by a locally verified authorization. Custom
    /// sources remain user-owned even if their identifiers overlap a catalog tombstone.
    public func withdrawnBlocklistIDs(in configuration: AppConfiguration) -> Set<String> {
        withdrawnBlocklistIDs(in: configuration, trustPolicy: .production)
    }

    internal func withdrawnBlocklistIDs(in configuration: AppConfiguration, trustPolicy: CatalogTrustPolicy) -> Set<String> {
        verifiedWithdrawnSourceIDs(using: trustPolicy).intersection(configuration.enabledBlocklistIDs)
            .subtracting(configuration.customBlocklists.map(\.id))
    }

    // Compatibility mode deliberately ignores envelopes; it must not turn an unsigned
    // omission into permission to stop enforcing a selected list.
    // pinned: CatalogAuthorizationTests.testWithdrawalsRequireConfiguredVerifiedAuthorization
    internal func verifiedWithdrawnSourceIDs(using policy: CatalogTrustPolicy) -> Set<String> {
        guard let manifest = try? verifyAuthorization(using: policy) else { return [] }
        return Set(manifest.withdrawnSources)
    }

    /// Summed entry counts of this catalog's guardrail sources — an upper bound on the guardrail
    /// rules a compile will process, since overlapping guardrail sources are not deduplicated here.
    ///
    /// The `guardrails` array itself stays `package`: it is the structural source of truth for the
    /// safety-critical tier (see `CatalogBlocklistSource.markedAsGuardrail`) and nothing outside the
    /// package should enumerate or present it. The app needs only the SIZE, to budget background
    /// warm compiles — every such compile loads the full guardrail union whatever the filter enables,
    /// and the figure it later charges against that budget
    /// (`PreparedFilterSnapshot.summary.tierBudgetRuleCount`) includes it (PR #646).
    public var guardrailEntryCount: Int {
        guardrails.reduce(0) { $0 + $1.entryCount }
    }

    package init(
        schemaVersion: Int,
        catalogVersion: String,
        generatedAt: Date,
        sources: [CatalogBlocklistSource],
        guardrails: [CatalogBlocklistSource],
        authorization: CatalogAuthorization? = nil,
        withdrawnSources: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.catalogVersion = catalogVersion
        self.generatedAt = generatedAt
        self.sources = sources
        self.guardrails = guardrails
        self.authorization = authorization
        self.withdrawnSources = withdrawnSources
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case catalogVersion = "catalog_version"
        case generatedAt = "generated_at"
        case sources
        case guardrails
        case authorization = "catalog_authorization"
        case withdrawnSources = "withdrawn_sources"
    }

    /// Decodes bounded catalog metadata and marks decoded guardrail entries.
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
        sources = try Self.decodeBoundedArray(CatalogBlocklistSource.self, from: container, key: .sources, maximum: 512)
        // Stamp the guardrail tier from STRUCTURAL array membership, not the server-supplied
        // `category` string: guardrail strictness (no rotation acceptance) must not hinge on a
        // freeform category field. Catalog authorization is checked separately by the
        // repository; structural tier marking also applies during the legacy rollout.
        guardrails = try Self.decodeBoundedArray(CatalogBlocklistSource.self, from: container, key: .guardrails, maximum: 512 - sources.count)
            .map { $0.markedAsGuardrail() }
        authorization = try container.decodeIfPresent(CatalogAuthorization.self, forKey: .authorization)
        withdrawnSources = try Self.decodeBoundedArray(String.self, from: container, key: .withdrawnSources, maximum: 4096, optional: true)
        try validateDecodedMetadata()
    }

    // Enforce collection limits before allocating Swift element arrays, including in the
    // pre-pin rollout. The outer byte ceiling alone permits millions of tiny withdrawals.
    // pinned: CatalogAuthorizationTests.testWithdrawalDecodeLimitAppliesBeforeAuthorization
    private static func decodeBoundedArray<Element: Decodable>(
        _ type: Element.Type, from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys, maximum: Int, optional: Bool = false
    ) throws -> [Element] {
        if optional {
            if !container.contains(key) { return [] }
            if try container.decodeNil(forKey: key) { return [] }
        }
        var values = try container.nestedUnkeyedContainer(forKey: key)
        if let count = values.count, count > maximum { throw BlocklistCatalogSyncError.invalidCatalog }
        var result: [Element] = []
        while !values.isAtEnd {
            guard result.count < maximum else { throw BlocklistCatalogSyncError.invalidCatalog }
            result.append(try values.decode(type))
        }
        return result
    }

    // All remote and cached readers share this boundary. These checks protect cache paths,
    // dictionary construction and budget arithmetic; they do not authenticate unsigned content.
    // pinned: BlocklistCatalogSyncTests.testCatalogRejectsDuplicateAndUnsafeSourceIdentities
    private func validateDecodedMetadata() throws {
        let entries = sources + guardrails
        guard entries.count <= 512 else { throw BlocklistCatalogSyncError.invalidCatalog }
        let identifierCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var identifiers = Set<String>()
        for source in entries {
            guard !source.id.isEmpty, source.id.utf8.count <= 128,
                  source.id != ".", source.id != "..",
                  source.id.unicodeScalars.allSatisfy({ identifierCharacters.contains($0) }),
                  identifiers.insert(source.id.lowercased()).inserted,
                  // The cache filename adds a hyphen, 12 hash digits and .txt (17 bytes).
                  source.versionID.utf8.count <= 238,
                  source.entryCount >= 0, source.entryCount <= Self.maximumSourceEntryCount, source.byteSize >= 0,
                  source.acceptedSourceHashes.allSatisfy({
                      (0...Self.maximumSourceEntryCount).contains($0.entryCount ?? 0) && ($0.byteSize ?? 0) >= 0
                  }),
                  source.sourceURL.scheme?.lowercased() == "https",
                  let host = source.sourceURL.host, !host.isEmpty else {
                throw BlocklistCatalogSyncError.invalidCatalog
            }
            do {
                try NetworkEndpointValidator.validatePublicSourceURL(source.sourceURL)
            } catch {
                throw BlocklistCatalogSyncError.invalidCatalog
            }
        }
        for id in withdrawnSources {
            guard !id.isEmpty, id.utf8.count <= 128, id != ".", id != "..",
                  id.unicodeScalars.allSatisfy({ identifierCharacters.contains($0) }),
                  identifiers.insert(id.lowercased()).inserted else {
                throw BlocklistCatalogSyncError.invalidCatalog
            }
        }
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
    /// Local custom counts bound to the URL and parser used for this result.
    public let localCustomRuleCounts: [String: LocalFilterRuleCount]
    /// Combined rules supplied by catalog guardrail sources.
    public let guardrailRuleSet: DomainRuleSet
    /// Snapshot metadata keyed by selected source identifier.
    public let metadataBySourceID: [String: SourceSnapshotMetadata]
    /// Source identifiers whose payloads were loaded from cache.
    public let usedCachedSourceIDs: Set<String>
    /// Enabled sources dropped because they are PERMANENTLY unusable, keyed to a stable log
    /// reason. Empty in every ordinary sync.
    ///
    /// The KEYS are load-bearing: the artifact must DECLARE them (see
    /// `PreparedFilterSnapshotSummary.quarantinedBlocklistIDs`) or coverage will refuse it.
    ///
    /// The REASONS are not read by anything yet — every consumer does `Set(…keys)`. They are
    /// carried because the surface that tells the user WHICH list stopped being enforced, and
    /// why, is the next slice; recording the reason at the point it is known is cheaper than
    /// reconstructing it later. Until that lands this map is a set with extra columns, and
    /// saying otherwise would overstate it. (Kilo, #535.)
    public let quarantinedSourceIDs: [String: String]

    package init(
        catalog: BlocklistCatalog,
        sourceRuleSets: [String: DomainRuleSet],
        guardrailRuleSet: DomainRuleSet,
        metadataBySourceID: [String: SourceSnapshotMetadata],
        usedCachedSourceIDs: Set<String>,
        quarantinedSourceIDs: [String: String] = [:],
        localCustomRuleCounts: [String: LocalFilterRuleCount] = [:]
    ) {
        self.catalog = catalog
        self.sourceRuleSets = sourceRuleSets
        self.localCustomRuleCounts = localCustomRuleCounts
        self.guardrailRuleSet = guardrailRuleSet
        self.metadataBySourceID = metadataBySourceID
        self.usedCachedSourceIDs = usedCachedSourceIDs
        self.quarantinedSourceIDs = quarantinedSourceIDs
    }
}

/// Synchronization output for user-provided blocklist sources.
public struct CustomBlocklistSyncResult: Sendable {
    /// Parsed rule sets keyed by custom source identifier.
    public let sourceRuleSets: [String: DomainRuleSet]
    /// Local custom counts bound to the URL and parser used for this result.
    public let localCustomRuleCounts: [String: LocalFilterRuleCount]
    /// Accepted payload hashes keyed by custom source identifier.
    public let sourceHashes: [String: String]
    /// Custom source identifiers whose payloads were loaded from cache.
    public let usedCachedSourceIDs: Set<String>

    package init(
        sourceRuleSets: [String: DomainRuleSet],
        sourceHashes: [String: String],
        usedCachedSourceIDs: Set<String>,
        localCustomRuleCounts: [String: LocalFilterRuleCount] = [:]
    ) {
        self.sourceRuleSets = sourceRuleSets
        self.localCustomRuleCounts = localCustomRuleCounts
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
            LavaCoreStrings.localizedFormat("The Lava Security catalog server returned HTTP %lld.", statusCode)
        case .invalidCatalog:
            LavaCoreStrings.localized("The Lava Security catalog could not be read.")
        case .invalidBlocklistEncoding(let sourceID):
            LavaCoreStrings.localizedFormat("core.catalogSync.invalidBlocklistEncoding", sourceID)
        case .blocklistTooLarge(let sourceID, let byteSize):
            LavaCoreStrings.localizedFormat("core.catalogSync.blocklistTooLarge", sourceID, byteSize)
        case .blocklistExceedsRuleLimit(let sourceID, let ruleLimit):
            LavaCoreStrings.localizedFormat("core.catalogSync.blocklistExceedsRuleLimit", sourceID, ruleLimit)
        case .checksumMismatch(let sourceID):
            LavaCoreStrings.localizedFormat("The downloaded blocklist checksum did not match for %@.", sourceID)
        case .noAcceptedSourceHashes(let sourceID):
            LavaCoreStrings.localizedFormat("No accepted blocklist checksum is available for %@.", sourceID)
        case .missingEnabledBlocklistSource(let sourceID):
            LavaCoreStrings.localizedFormat("No enabled blocklist source is available for %@.", sourceID)
        case .noCachedCatalog:
            LavaCoreStrings.localized("No saved Lava Security catalog is available yet.")
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
    static func fetch(
        url: URL,
        maximumByteCount: Int,
        resolver: @escaping HostAddressResolver = SystemHostResolver.resolve
    ) async throws -> Data {
        let (status, body) = try await fetchResponse(
            url: url, maximumByteCount: maximumByteCount, resolver: resolver)
        guard (200..<300).contains(status) else {
            throw BlocklistCatalogSyncError.invalidHTTPStatus(status)
        }
        return body
    }
}

/// Resolves one hostname through something other than the system resolver, for the single
/// case where the system resolver cannot answer. Returns `nil` when no help is available.
///
/// The app supplies the concrete implementation (it owns the tunnel session); this package
/// only knows there is a fallback it may ask. Keeping the closure here is what lets the
/// ladder live inside the package, where the pinned transport's `package` seam is reachable,
/// without the package taking a dependency on NetworkExtension.
public typealias BootstrapAddressBroker =
    @Sendable (_ hostname: String) async -> (ipv4: [String], ipv6: [String])?

extension BlocklistCatalogSynchronizer {
    /// The default fetcher, plus ONE retry through `broker` when — and only when — the host
    /// did not resolve.
    ///
    /// THE DEADLOCK. With no adoptable artifact the tunnel serves `FailClosedRuntimeSnapshot`,
    /// which answers every query with the block-all address. The download that would END that
    /// state then cannot resolve its own sources, so the outage is permanent: on device (S9)
    /// the only exit was toggling protection off and on. The tunnel can still reach the device
    /// resolvers, so it brokers this one lookup.
    ///
    /// 🔴 The trigger is deliberately narrow: `URLError.cannotFindHost`, which the pinned
    /// fetcher now reports for an ALL-UNSPECIFIED answer — i.e. exactly the sinkhole shape.
    /// A private, loopback or mixed answer still raises `privateNetworkNotAllowed` and is NOT
    /// retried: those are SSRF signals, and retrying them through a second resolver is how a
    /// rebinding attempt gets a second chance.
    ///
    /// 🔴 Brokered addresses are NOT trusted. They go back through the same
    /// `PinnedPublicHTTPSFetcher` gate as any other resolution, so every one must still
    /// classify as public before anything connects. The broker can help or fail to help; it
    /// cannot widen what is reachable.
    public static func bootstrapAwareDataFetcher(
        broker: @escaping BootstrapAddressBroker
    ) -> BlocklistCatalogDataFetcher {
        { url in
            do {
                return try await defaultDataFetcher(url: url)
            } catch let error as URLError where error.code == .cannotFindHost {
                // 🔴 The ASCII form, matching what the fetcher will query the resolver with.
                // `url.host` yields the PERCENT-ENCODED host for an IDN URL, while
                // `pinnedAddresses` normalizes to IDNA-ASCII — so brokering under one form and
                // scoping the resolver to it would refuse the very host it was brokered for
                // (Kilo, #529).
                guard let host = PinnedPublicHTTPSFetcher.asciiHost(from: url), !host.isEmpty,
                    let brokered = await broker(host),
                    // Scoped to the host we brokered FOR. `fetch` follows redirects and
                    // re-resolves each hop, so an unscoped resolver would hand this host's
                    // addresses to a redirect target — connecting to one server under
                    // another's SNI and Host.
                    let resolver = HostAddressResolverFactory.fixed(
                        host: host, ipv4: brokered.ipv4, ipv6: brokered.ipv6)
                else {
                    throw error
                }
                return try await PinnedPublicHTTPSFetcher.fetch(
                    url: url, maximumByteCount: maximumBlocklistBytes, resolver: resolver)
            }
        }
    }
}

/// Per-context budget for parsing blocklist sources. The app process has ample
/// memory and admits larger single lists; the packet-tunnel extension's fallback
/// compile runs under a ~50 MiB jetsam budget where the parser's dirty `Set<String>`
/// intermediate (~tens of bytes per rule, an order of magnitude above the 5 B/rule
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

    /// Checks current publication without reading/writing the catalog or payload caches.
    /// Imports use this admission check; an offline fallback cannot authorize a new list.
    public func fetchPublishedCatalog() async throws -> BlocklistCatalog {
        try await catalogRepository.loadNetworkCatalog().catalog
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
        commitsLatestCatalog: Bool = true,
        failsWhenNoCatalogSourceSurvives: Bool = true
    ) async throws -> BlocklistCatalogSyncResult {
        let loadedCatalog = try await catalogRepository.loadRemoteCatalog()
        let result = try await compile(
            catalog: loadedCatalog.catalog,
            enabledSourceIDs: enabledSourceIDs,
            allowsNetwork: true,
            includesGuardrails: true,
            failsWhenNoCatalogSourceSurvives: failsWhenNoCatalogSourceSurvives
        )

        if commitsLatestCatalog {
            // Persisting the RESOLVED catalog records rotated versionIDs and
            // hashes, which keeps RuleSetCache's predicted-hash lookups valid
            // on the next run. Commit only after compilation succeeds; a failed refresh
            // must not advance catalog authorization beyond the last usable catalog.
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
    ///
    /// PERSISTS THE RESOLVED CATALOG on a real change, mirroring ``sync``. The app stamps an
    /// artifact's identity from the catalog this resolve produced, while the tunnel re-derives the
    /// identity it will accept from the PERSISTED `latest.json` (`loadCachedCatalogMetadata`). When
    /// a cache-only resolve selects a payload whose version/hash differs from the cached entry — a
    /// rotation already on disk that `latest.json` has not recorded — the two sides diverge inside
    /// one `catalogVersion`, and the tunnel refuses EVERY reload of the artifact on
    /// `freshness:selectedSourceHashes` while the app still reports `published` (the 2026-09-02 and
    /// 2026-09-20 field cases; `PublishedArtifactAdoptability` is the diagnostic half). Writing the
    /// resolved catalog back makes the persisted basis the one actually compiled, so the tunnel's
    /// expectation and the app's stamp agree. Only writes on a real change, so an unchanged cache
    /// is untouched.
    ///
    /// The write is a compare-and-swap: the compile can run for seconds, so a concurrent `sync`
    /// that advanced `latest.json` in that window is authoritative and must not be clobbered with
    /// a catalog built from the stale snapshot. And the write PRESERVES the previous mtime —
    /// content is corrected to match the on-disk payloads, but nothing was verified upstream, so
    /// the freshness clock must not move (see the repository methods for both contracts).
    ///
    /// Best-effort: the correction is an adoptability improvement, not part of the resolve, so a
    /// failed write (disk full, app-group/sandbox write error) must not fail an otherwise-successful
    /// offline load and push callers into a network `sync` that also fails offline. On failure the
    /// persisted catalog simply stays as it was, and the next successful write reconciles it.
    public func loadCached(
        enabledSourceIDs: Set<String>,
        includesGuardrails: Bool = true,
        failsWhenNoCatalogSourceSurvives: Bool = true
    ) async throws -> BlocklistCatalogSyncResult {
        let snapshot = try catalogRepository.cachedCatalogSnapshot()
        let result = try await compile(
            catalog: snapshot.catalog,
            enabledSourceIDs: enabledSourceIDs,
            allowsNetwork: false,
            includesGuardrails: includesGuardrails,
            failsWhenNoCatalogSourceSurvives: failsWhenNoCatalogSourceSurvives
        )
        if result.catalog != snapshot.catalog {
            try? catalogRepository.saveLatestCatalogIfUnchanged(
                Self.makeJSONEncoder().encode(result.catalog),
                matching: snapshot.data
            )
        }
        return result
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
    /// each source straight through `BlocklistParser.forEachBlockRule` and hands each accepted
    /// rule to `onBlockRule` one at a time — NO per-source `DomainRuleSet`
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
            guardrails: catalog.guardrails.map { resolvedGuardrailsByID[$0.id] ?? $0 },
            authorization: catalog.authorization,
            withdrawnSources: catalog.withdrawnSources
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

    /// Stream-parses raw payload bytes, handing each accepted block rule to `onRule`,
    /// matching `parsePayload`. No
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
        BlocklistCatalogRepository(cacheDirectoryURL: cacheDirectoryURL)
            .hasFreshCachedCatalog(maxAge: maxAge, now: now)
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
        cachedCatalogRequiresLowRiskLaunchRefresh(in: cacheDirectoryURL,
            requiredSourceIDs: requiredSourceIDs, trustPolicy: .production)
    }

    internal static func cachedCatalogRequiresLowRiskLaunchRefresh(
        in cacheDirectoryURL: URL, requiredSourceIDs: Set<String>, trustPolicy: CatalogTrustPolicy
    ) -> Bool {
        guard let catalog = try? BlocklistCatalogRepository(
            cacheDirectoryURL: cacheDirectoryURL, trustPolicy: trustPolicy).cachedCatalog() else {
            return false
        }

        let cachedSources = catalog.sources + catalog.guardrails
        // An admitted withdrawal satisfies the launch inventory requirement. Purging it
        // would resurrect a bundled source offline (or discard the only enforcing cache).
        // pinned: CatalogAuthorizationTests.testWithdrawalsRequireConfiguredVerifiedAuthorization
        let cachedSourceIDs = Set(catalog.sources.map(\.id)).union(catalog.verifiedWithdrawnSourceIDs(using: trustPolicy))
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
        includesGuardrails: Bool,
        failsWhenNoCatalogSourceSurvives: Bool
    ) async throws -> BlocklistCatalogSyncResult {
        // Each source's fetch + parse is independent and writes only to its own
        // per-source cache directory, so they run with bounded concurrency to
        // overlap the dominant network latency. compileSource's leading
        // checkCancellation is the per-child cancellation checkpoint: when one
        // source throws, the throwing task group cancels the in-flight siblings.
        let enabledSources = catalog.sources.filter { enabledSourceIDs.contains($0.id) }
        let guardrailSources = includesGuardrails ? catalog.guardrails : []

        let sourceOutcomes = try await mapBoundedOutcomes(
            enabledSources,
            maxConcurrent: parseBudget.maxConcurrentSources
        ) { source in
            try await self.compileSource(
                source,
                allowsNetwork: allowsNetwork,
                usesPredictedHashShortCircuit: true
            )
        }

        // Split the failures. A PERMANENT one (a 404, a list past a cap) is quarantined: no
        // number of retries changes it, and throwing here is what left the device with no
        // artifact at all and therefore no DNS. A TRANSIENT one still throws, deliberately —
        // a timeout or a 5xx must fail the prepare so the existing retry path runs, because
        // dropping a list over a blip would under-block for a reason that fixes itself.
        var quarantinedSourceIDs: [String: String] = [:]
        var firstTransientFailure: (any Error)?
        var firstPermanentFailure: (any Error)?
        for index in sourceOutcomes.failures.keys.sorted() {
            let error = sourceOutcomes.failures[index]!
            let source = enabledSources[index]
            if let reason = BlocklistSourceFailureClassification.classify(error).logReason {
                quarantinedSourceIDs[source.id] = reason
                if firstPermanentFailure == nil { firstPermanentFailure = error }
            } else if firstTransientFailure == nil {
                firstTransientFailure = error
            }
        }
        if let firstTransientFailure {
            throw firstTransientFailure
        }

        // 🔴 NOTHING SURVIVED — but only refuse when nothing ELSE could supply rules.
        //
        // This function sees CATALOG sources only; custom sources are compiled separately and
        // afterwards. An unconditional guard here fails a configuration whose catalog list is
        // dead but whose custom lists are healthy and hold rules — the same wedge, one source
        // kind over (Kilo, #535). So the caller says whether a fallback exists, and the
        // combined check lives in `FilterSnapshotPreparationService.prepare`.
        //
        // When there IS nothing else, rethrowing the ORIGINAL error matters: it names the
        // source and the limit, which is what the tier messaging reads to tell the user WHICH
        // list is too big, and a device that can compile nothing is when that name matters
        // most.
        if failsWhenNoCatalogSourceSurvives,
            !quarantinedSourceIDs.isEmpty,
            sourceOutcomes.outputs.isEmpty,
            !enabledSources.isEmpty
        {
            throw firstPermanentFailure ?? BlocklistCatalogSyncError.noRulesAvailable
        }

        let sourceResults = sourceOutcomes.outputs.keys.sorted().compactMap {
            sourceOutcomes.outputs[$0]
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
            guardrails: catalog.guardrails.map { resolvedGuardrailsByID[$0.id] ?? $0 },
            authorization: catalog.authorization,
            withdrawnSources: catalog.withdrawnSources
        )

        return BlocklistCatalogSyncResult(
            catalog: resolvedCatalog,
            sourceRuleSets: sourceRuleSets,
            guardrailRuleSet: guardrailRuleSet,
            metadataBySourceID: metadataBySourceID,
            usedCachedSourceIDs: usedCachedSourceIDs,
            quarantinedSourceIDs: quarantinedSourceIDs
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
        // The CHILDREN no longer throw — each one catches and hands its failure back as a
        // value. The group itself still has to be a throwing one (its body throws at the
        // end), but that is not where the cancellation came from.
        //
        // 🔴 WHY. A task group cancels its in-flight siblings the moment one CHILD throws.
        // For blocklist sources that costs two things that matter:
        //
        //   1. CACHE. A source only writes its `latest.txt` after a COMPLETE fetch. Cancelled
        //      siblings write nothing, so one unfetchable list denied every other list its
        //      cache entry — and the next cold compile, which could have run from cache, had
        //      nothing to run from. The failure reproduced itself on every launch.
        //   2. ATTRIBUTION. The surviving error was whichever source lost the race, not the
        //      source that is actually broken. A device log full of
        //      `latest.txt … no such file` named a RACE LOSER, and any repair keyed on that
        //      signal — "disable the failing list" — could disable an innocent one while the
        //      real culprit stayed enabled.
        //
        // Every source now runs to completion. The error thrown is the first BY ITEM INDEX,
        // not by arrival time, so the same broken configuration reports the same source every
        // run instead of a different one each time.
        return try await withThrowingTaskGroup(of: (Int, Output?, SendableErrorBox?).self) { group in
            var nextIndex = 0
            func addTask(at index: Int) {
                let item = items[index]
                group.addTask {
                    do {
                        return (index, try await transform(item), nil)
                    } catch {
                        return (index, nil, SendableErrorBox(error))
                    }
                }
            }

            while nextIndex < limit {
                addTask(at: nextIndex)
                nextIndex += 1
            }

            var outputs = [Output?](repeating: nil, count: items.count)
            var failures: [Int: any Error] = [:]
            var stoppedEarlyForCancellation = false

            while let (index, output, failure) = try await group.next() {
                if let failure {
                    // Cancellation is the ONE failure that must still be prompt. The caller
                    // is going away; grinding through the remaining sources to be thorough
                    // would spend radio on results nobody will read. Throwing here DOES
                    // cancel the siblings — which is exactly right for this case and exactly
                    // wrong for every other one.
                    if failure.error is CancellationError {
                        throw failure.error
                    }
                    if let urlError = failure.error as? URLError, urlError.code == .cancelled {
                        throw failure.error
                    }
                    failures[index] = failure.error
                } else {
                    outputs[index] = output
                }
                if nextIndex < items.count {
                    if Task.isCancelled {
                        stoppedEarlyForCancellation = true
                    } else {
                        addTask(at: nextIndex)
                        nextIndex += 1
                    }
                }
            }

            // A SHORT RESULT MUST NOT LOOK LIKE A COMPLETE ONE. Stopping the enqueue on
            // cancellation is right; returning what happened to finish would report a
            // successful sync containing only the first concurrency batch, and a caller that
            // trusts it compiles an artifact missing every source never attempted.
            //
            // 🔴 DEFENCE IN DEPTH, NOT A FIX FOR AN OBSERVED DEFECT — and deliberately
            // untested, because I could not build a test that distinguishes its presence.
            // Three attempts (suspending fetcher, self-cancelling fetcher, asserting on the
            // result's SHAPE rather than on throwing) all passed with this block deleted: in
            // every arrangement some enqueued child hits its own leading `checkCancellation`
            // and the carve-out above rethrows first. So the escape may well be unreachable
            // today. The guard is kept because it is free and the invariant is worth stating
            // structurally, but nobody should read it as verified. A vacuous test asserting
            // otherwise would be worse than none.
            if stoppedEarlyForCancellation || Task.isCancelled {
                throw CancellationError()
            }

            if let firstFailedIndex = failures.keys.min() {
                throw failures[firstFailedIndex]!
            }

            return outputs.compactMap { $0 }
        }
    }

    /// `mapBounded`, but handing the per-item failures BACK instead of throwing the first.
    ///
    /// The caller that needs this is source compilation: it has to look at each failure and
    /// decide whether the source is retryably broken or permanently unusable, which is a
    /// judgement `mapBounded` cannot make for it. Everything else about the execution is the
    /// same, cancellation included.
    private func mapBoundedOutcomes<Item: Sendable, Output: Sendable>(
        _ items: [Item],
        maxConcurrent: Int,
        _ transform: @escaping @Sendable (Item) async throws -> Output
    ) async throws -> (outputs: [Int: Output], failures: [Int: any Error]) {
        guard !items.isEmpty else {
            return ([:], [:])
        }

        let limit = max(1, min(maxConcurrent, items.count))
        return try await withThrowingTaskGroup(of: (Int, Output?, SendableErrorBox?).self) { group in
            var nextIndex = 0
            func addTask(at index: Int) {
                let item = items[index]
                group.addTask {
                    do {
                        return (index, try await transform(item), nil)
                    } catch {
                        return (index, nil, SendableErrorBox(error))
                    }
                }
            }

            while nextIndex < limit {
                addTask(at: nextIndex)
                nextIndex += 1
            }

            var outputs: [Int: Output] = [:]
            var failures: [Int: any Error] = [:]

            while let (index, output, failure) = try await group.next() {
                if let failure {
                    // Same carve-out as `mapBounded`: cancellation stays prompt.
                    if failure.error is CancellationError {
                        throw failure.error
                    }
                    if let urlError = failure.error as? URLError, urlError.code == .cancelled {
                        throw failure.error
                    }
                    failures[index] = failure.error
                } else if let output {
                    outputs[index] = output
                }
                if !Task.isCancelled, nextIndex < items.count {
                    addTask(at: nextIndex)
                    nextIndex += 1
                }
            }

            return (outputs, failures)
        }
    }

    /// Carries a per-item failure out of a non-throwing task group.
    ///
    /// A task group's element type must be `Sendable`, and `Result<Output, any Error>` is
    /// not — an existential `Error` carries no such guarantee. Every error this pipeline
    /// actually produces IS a Sendable value type (`BlocklistCatalogSyncError`, `URLError`,
    /// `CancellationError`, `BlocklistDownloadSizeLimitExceeded`), so the box asserts what
    /// the call sites already satisfy rather than widening anything. It is deliberately
    /// private and single-purpose so that assertion cannot travel.
    private struct SendableErrorBox: @unchecked Sendable {
        let error: any Error

        init(_ error: any Error) {
            self.error = error
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
        // tier ceiling, not the higher device memory budget (~5.87M), on purpose, since the
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
        var localCustomRuleCounts: [String: LocalFilterRuleCount] = [:]
        var usedCachedSourceIDs = Set<String>()
        for result in results {
            sourceRuleSets[result.sourceID] = result.ruleSet
            localCustomRuleCounts[result.sourceID] = result.localRuleCount
            sourceHashes[result.sourceID] = result.checksumSHA256
            if result.usedCache {
                usedCachedSourceIDs.insert(result.sourceID)
            }
        }

        return CustomBlocklistSyncResult(
            sourceRuleSets: sourceRuleSets,
            sourceHashes: sourceHashes,
            usedCachedSourceIDs: usedCachedSourceIDs,
            localCustomRuleCounts: localCustomRuleCounts
        )
    }

    private struct CompiledCustomSourceResult: Sendable {
        let sourceID: String
        let ruleSet: DomainRuleSet
        let localRuleCount: LocalFilterRuleCount
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
            localRuleCount: LocalFilterRuleCount(source: source, count: ruleSet.count),
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
