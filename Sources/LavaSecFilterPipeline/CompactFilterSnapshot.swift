import Foundation
import LavaSecKit

package enum CompactFilterSnapshotError: Error, Equatable {
    case invalidMagic
    case unsupportedVersion(UInt32)
    case truncatedData
    case invalidMetadata
    case invalidRuleTable
    case domainTooLong(String)
    case artifactTooLarge
}

/// Binary filter snapshot optimized for low-memory runtime lookups.
public struct CompactFilterSnapshot: FilterRuntimeSnapshot {
    package static let fileVersion: UInt32 = 1

    // Bumped when the stored metadata summary becomes trustworthy for cheap
    // reads. Artifacts without this marker fall back to full-table recompute.
    static let metadataSummarySchemaVersion = 2

    private static let magic = Data("LSCFSNP1".utf8)

    /// Inputs that identify the configuration and catalog used to build the snapshot.
    public let identity: PreparedFilterSnapshotIdentity
    package let generatedAt: Date
    /// Resolver configuration used by the runtime snapshot.
    public let resolver: DNSResolverPreset
    package let blockRules: CompactDomainRuleSet
    package let allowRules: CompactDomainRuleSet
    package let nonAllowableThreatRules: CompactDomainRuleSet
    package let summary: PreparedFilterSnapshotSummary

    package init(
        identity: PreparedFilterSnapshotIdentity,
        generatedAt: Date,
        resolver: DNSResolverPreset,
        blockRules: CompactDomainRuleSet,
        allowRules: CompactDomainRuleSet,
        nonAllowableThreatRules: CompactDomainRuleSet,
        summary: PreparedFilterSnapshotSummary? = nil
    ) {
        self.identity = identity
        self.generatedAt = generatedAt
        self.resolver = resolver
        self.blockRules = blockRules
        self.allowRules = allowRules
        self.nonAllowableThreatRules = nonAllowableThreatRules
        // Catalog-level counts come from the caller, but table-derived counts are
        // always recomputed from the actual rule tables so the stored summary is
        // trustworthy by construction (older writers persisted stale protected
        // counts, which is why reads used to recompute). tierBudgetRuleCount is
        // caller-recorded like the catalog-level counts: the tables cannot
        // reconstruct it (resident guardrail = allowlist-overlap subset only),
        // and the tunnel's INV-TIER-1 serve gates bind it, nil failing closed.
        self.summary = PreparedFilterSnapshotSummary(
            blocklistRuleCount: summary?.blocklistRuleCount,
            blocklistSourceRuleCounts: summary?.blocklistSourceRuleCounts,
            blockRuleCount: blockRules.count,
            blockedDomainRuleCount: blockRules.effectiveBlockedDomainRuleCount(
                allowRules: allowRules,
                nonAllowableThreatRules: nonAllowableThreatRules
            ),
            allowRuleCount: allowRules.count,
            guardrailRuleCount: nonAllowableThreatRules.count,
            tierBudgetRuleCount: summary?.tierBudgetRuleCount
        )
    }

    package init(preparedSnapshot: PreparedFilterSnapshot) {
        self.init(
            identity: preparedSnapshot.identity,
            generatedAt: preparedSnapshot.snapshot.generatedAt,
            resolver: preparedSnapshot.snapshot.resolver,
            blockRules: CompactDomainRuleSet(ruleSet: preparedSnapshot.snapshot.blockRules),
            allowRules: CompactDomainRuleSet(ruleSet: preparedSnapshot.snapshot.allowRules),
            nonAllowableThreatRules: CompactDomainRuleSet(ruleSet: preparedSnapshot.snapshot.nonAllowableThreatRules),
            summary: preparedSnapshot.summary
        )
    }

    /// Number of block rules in the snapshot.
    public var blockRuleCount: Int {
        blockRules.count
    }

    /// Number of allow rules in the snapshot.
    public var allowRuleCount: Int {
        allowRules.count
    }

    /// Number of non-allowable threat guardrail rules in the snapshot.
    public var guardrailRuleCount: Int {
        nonAllowableThreatRules.count
    }

    /// Recorded compiled-rule total used for exact tier-budget enforcement.
    ///
    /// A missing value identifies a legacy or otherwise unstamped artifact and must be
    /// treated as not reusable by process-boundary consumers.
    public var tierBudgetRuleCount: Int? {
        summary.tierBudgetRuleCount
    }

    package func matches(identity expectedIdentity: PreparedFilterSnapshotIdentity) -> Bool {
        identity == expectedIdentity
    }

    package func canReuseForProtectionStartup(
        configuration: AppConfiguration,
        cachedCatalog: BlocklistCatalog?
    ) -> Bool {
        guard resolver.transport == configuration.resolverPreset.transport else {
            return false
        }

        if !configuration.enabledBlocklistIDs.isEmpty {
            guard cachedCatalog != nil, summary.coversEnabledBlocklists(in: configuration) else {
                return false
            }
        }

        if let cachedCatalog {
            let expectedIdentity = PreparedFilterSnapshotIdentity.make(
                configuration: configuration,
                catalog: cachedCatalog
            )
            return identity.hasSameSnapshotInputs(as: expectedIdentity)
        }

        return identity.hasSameConfigurationInputs(as: configuration)
    }

    /// Full-snapshot parity for `CompactFilterSnapshotSummary.canServeAsLastKnownGood`.
    /// See that method: serviceable last-known-good for a failed fresh (re)compile —
    /// tolerates ONLY stale catalog/guardrail content hashes while still requiring the same
    /// configuration inputs + coverage + resolver transport (so it never fails OPEN and a
    /// parser bump still forces a regenerate).
    package func canServeAsLastKnownGood(for configuration: AppConfiguration) -> Bool {
        guard resolver.transport == configuration.resolverPreset.transport else {
            return false
        }

        if !configuration.enabledBlocklistIDs.isEmpty {
            guard summary.coversEnabledBlocklists(in: configuration) else {
                return false
            }
        }

        return identity.hasSameConfigurationInputs(as: configuration)
    }

    /// Evaluates a raw domain, blocking invalid input and applying guardrail, allow, then block rules.
    public func decision(for rawDomain: String) -> FilterDecision {
        guard let normalizedDomain = try? DomainName.normalize(rawDomain) else {
            return FilterDecision(action: .block, reason: .invalidDomain)
        }

        return decision(forNormalizedDomain: normalizedDomain)
    }

    /// Evaluates an already normalized domain against the compact rule tables.
    public func decision(forNormalizedDomain normalizedDomain: String) -> FilterDecision {
        if nonAllowableThreatRules.containsNormalized(normalizedDomain) {
            return FilterDecision(action: .block, reason: .threatGuardrail)
        }

        if allowRules.containsNormalized(normalizedDomain) {
            return FilterDecision(action: .allow, reason: .localAllowlist)
        }

        if blockRules.containsNormalized(normalizedDomain) {
            return FilterDecision(action: .block, reason: .blocklist)
        }

        return .defaultAllow
    }

    package func encodedData() throws -> Data {
        let header = try Self.encodedHeader(
            identity: identity,
            generatedAt: generatedAt,
            resolver: resolver,
            summary: summary
        )

        var data = Data()
        data.reserveCapacity(
            header.count
                + blockRules.encodedSizeEstimate
                + allowRules.encodedSizeEstimate
                + nonAllowableThreatRules.encodedSizeEstimate
        )
        data.append(header)
        try blockRules.appendEncodedData(to: &data)
        try allowRules.appendEncodedData(to: &data)
        try nonAllowableThreatRules.appendEncodedData(to: &data)
        return data
    }

    /// Single source of truth for the file PREAMBLE (magic + version + length-prefixed
    /// metadata JSON), shared by `encodedData()` and the in-extension streaming writer
    /// (`writeStreaming`) so neither can drift from the other. The metadata always
    /// carries `summarySchema = metadataSummarySchemaVersion`, so a reader can trust the
    /// stored summary after cross-checking its counts against the rule tables.
    static func encodedHeader(
        identity: PreparedFilterSnapshotIdentity,
        generatedAt: Date,
        resolver: DNSResolverPreset,
        summary: PreparedFilterSnapshotSummary
    ) throws -> Data {
        let metadata = CompactFilterSnapshotMetadata(
            identity: identity,
            generatedAt: generatedAt,
            resolver: resolver,
            summary: summary,
            summarySchema: Self.metadataSummarySchemaVersion
        )
        let metadataData = try JSONEncoder().encode(metadata)
        guard metadataData.count <= Int(UInt32.max) else {
            throw CompactFilterSnapshotError.artifactTooLarge
        }

        var data = Data()
        data.reserveCapacity(Self.magic.count + 8 + metadataData.count)
        data.append(Self.magic)
        data.appendLittleEndian(Self.fileVersion)
        data.appendLittleEndian(UInt32(metadataData.count))
        data.append(metadataData)
        return data
    }

    /// Streams a byte-valid `CompactFilterSnapshot` to `fileHandle` WITHOUT holding the
    /// large block-rule domain blob in heap — the in-extension fallback's whole reason
    /// for existing. The block table's entries (the ~8 B/rule resident cost, supplied by
    /// the caller already sorted byte-lexicographically and deduped) are written through a
    /// bounded buffer, then the domain bytes are stream-copied from `blockDomainDataURL`
    /// (the insertion-order blob the caller built on disk; its bytes need not be sorted —
    /// only the entries do — so duplicate/dead bytes are harmless). `allowRules` and
    /// `nonAllowableThreatRules` are small and encoded in heap via the same
    /// `appendEncodedData` path as `encodedData()`. All format knowledge lives here and in
    /// `CompactDomainRuleSet.emitTablePrefix`, the single source of truth.
    static func writeStreaming(
        to fileHandle: FileHandle,
        identity: PreparedFilterSnapshotIdentity,
        generatedAt: Date,
        resolver: DNSResolverPreset,
        summary: PreparedFilterSnapshotSummary,
        blockExactEntries: [CompactDomainRuleSet.Entry],
        blockSuffixEntries: [CompactDomainRuleSet.Entry],
        blockDomainDataURL: URL,
        blockDomainDataCount: Int,
        allowRules: CompactDomainRuleSet,
        nonAllowableThreatRules: CompactDomainRuleSet
    ) throws {
        try CompactDomainRuleSet.validateTableSizes(
            exactCount: blockExactEntries.count,
            suffixCount: blockSuffixEntries.count,
            domainDataCount: blockDomainDataCount
        )

        try fileHandle.lavaWrite(try encodedHeader(
            identity: identity,
            generatedAt: generatedAt,
            resolver: resolver,
            summary: summary
        ))

        // Block table prefix (counts + entries + blobLen) through a bounded buffer.
        var buffer = Data()
        buffer.reserveCapacity(Self.streamingFlushThreshold + 16)
        try CompactDomainRuleSet.emitTablePrefix(
            exactEntries: blockExactEntries,
            suffixEntries: blockSuffixEntries,
            domainDataCount: blockDomainDataCount,
            into: &buffer,
            flushThreshold: Self.streamingFlushThreshold,
            flush: { chunk in
                try fileHandle.lavaWrite(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        )
        if !buffer.isEmpty {
            try fileHandle.lavaWrite(buffer)
            buffer.removeAll(keepingCapacity: true)
        }

        // Block table domain blob: stream-copy the on-disk insertion-order blob.
        let blobHandle = try FileHandle(forReadingFrom: blockDomainDataURL)
        defer { try? blobHandle.close() }
        var copied = 0
        while true {
            let chunk = try blobHandle.read(upToCount: Self.streamingFlushThreshold) ?? Data()
            if chunk.isEmpty { break }
            try fileHandle.lavaWrite(chunk)
            copied += chunk.count
        }
        guard copied == blockDomainDataCount else {
            // The entries' offsets were computed against a blob of `blockDomainDataCount`
            // bytes; a short/long copy would make them point out of bounds. Fail closed.
            throw CompactFilterSnapshotError.truncatedData
        }

        // Allow + threat tables are small — encode in heap exactly as `encodedData()`.
        var tail = Data()
        try allowRules.appendEncodedData(to: &tail)
        try nonAllowableThreatRules.appendEncodedData(to: &tail)
        try fileHandle.lavaWrite(tail)
    }

    /// Buffer flush size for `writeStreaming` (64 KiB): bounds the heap held while
    /// streaming the block entry table and copying the domain blob.
    static let streamingFlushThreshold = 64 * 1024

    /// Decodes and validates a compact snapshot artifact.
    public static func decode(from data: Data) throws -> CompactFilterSnapshot {
        var reader = CompactBinaryReader(data: data)
        let magic = try reader.readData(count: Self.magic.count)
        guard magic == Self.magic else {
            throw CompactFilterSnapshotError.invalidMagic
        }

        let version = try reader.readUInt32()
        guard version == Self.fileVersion else {
            throw CompactFilterSnapshotError.unsupportedVersion(version)
        }

        let metadataLength = try reader.readUInt32()
        let metadataData = try reader.readData(count: Int(metadataLength))
        guard let metadata = try? JSONDecoder().decode(CompactFilterSnapshotMetadata.self, from: metadataData) else {
            throw CompactFilterSnapshotError.invalidMetadata
        }

        let blockRules = try CompactDomainRuleSet(reader: &reader)
        let allowRules = try CompactDomainRuleSet(reader: &reader)
        let nonAllowableThreatRules = try CompactDomainRuleSet(reader: &reader)
        let summary = Self.summary(
            metadata: metadata,
            blockRules: blockRules,
            allowRules: allowRules,
            nonAllowableThreatRules: nonAllowableThreatRules
        )

        return CompactFilterSnapshot(
            identity: metadata.identity,
            generatedAt: metadata.generatedAt,
            resolver: metadata.resolver,
            blockRules: blockRules,
            allowRules: allowRules,
            nonAllowableThreatRules: nonAllowableThreatRules,
            summary: summary
        )
    }

    /// Reads and validates a snapshot summary without retaining decoded rule tables.
    public static func readSummary(from data: Data) throws -> CompactFilterSnapshotSummary {
        var reader = CompactBinaryReader(data: data)
        let magic = try reader.readData(count: Self.magic.count)
        guard magic == Self.magic else {
            throw CompactFilterSnapshotError.invalidMagic
        }

        let version = try reader.readUInt32()
        guard version == Self.fileVersion else {
            throw CompactFilterSnapshotError.unsupportedVersion(version)
        }

        let metadataLength = try reader.readUInt32()
        let metadataData = try reader.readData(count: Int(metadataLength))
        guard let metadata = try? JSONDecoder().decode(CompactFilterSnapshotMetadata.self, from: metadataData) else {
            throw CompactFilterSnapshotError.invalidMetadata
        }

        // The encoder stores a write-time-verified summary in the metadata
        // header (summarySchema marks it trustworthy), so summary reads only
        // skip-validate the rule tables instead of materializing entry arrays
        // and domain bytes. Counts are cross-checked against the tables so a
        // corrupted artifact still fails selection here rather than at tunnel
        // load. Older artifacts (no schema marker) recompute below.
        if metadata.summarySchema == Self.metadataSummarySchemaVersion,
           let storedSummary = metadata.summary {
            let blockRuleCount = try CompactDomainRuleSet.readSummary(reader: &reader)
            let allowRuleCount = try CompactDomainRuleSet.readSummary(reader: &reader)
            let guardrailRuleCount = try CompactDomainRuleSet.readSummary(reader: &reader)
            guard storedSummary.blockRuleCount == blockRuleCount,
                  storedSummary.allowRuleCount == allowRuleCount,
                  storedSummary.guardrailRuleCount == guardrailRuleCount
            else {
                throw CompactFilterSnapshotError.invalidRuleTable
            }

            return CompactFilterSnapshotSummary(
                identity: metadata.identity,
                generatedAt: metadata.generatedAt,
                resolver: metadata.resolver,
                blocklistRuleCount: storedSummary.blocklistRuleCount,
                blocklistSourceRuleCounts: storedSummary.blocklistSourceRuleCounts,
                blockRuleCount: storedSummary.blockRuleCount,
                blockedDomainRuleCount: storedSummary.blockedDomainRuleCount,
                allowRuleCount: storedSummary.allowRuleCount,
                guardrailRuleCount: storedSummary.guardrailRuleCount,
                // Not cross-checkable against the tables (see the field doc) — trusted the
                // same way the catalog-level counts above are: written by the same encoder
                // that wrote the tables.
                tierBudgetRuleCount: storedSummary.tierBudgetRuleCount
            )
        }

        // Artifacts written before the summary landed in metadata: fall back to
        // the full rule-table decode.
        let blockRules = try CompactDomainRuleSet(reader: &reader)
        let allowRules = try CompactDomainRuleSet(reader: &reader)
        let nonAllowableThreatRules = try CompactDomainRuleSet(reader: &reader)
        let summary = Self.summary(
            metadata: metadata,
            blockRules: blockRules,
            allowRules: allowRules,
            nonAllowableThreatRules: nonAllowableThreatRules
        )

        return CompactFilterSnapshotSummary(
            identity: metadata.identity,
            generatedAt: metadata.generatedAt,
            resolver: metadata.resolver,
            blocklistRuleCount: summary.blocklistRuleCount,
            blocklistSourceRuleCounts: summary.blocklistSourceRuleCounts,
            blockRuleCount: summary.blockRuleCount,
            blockedDomainRuleCount: summary.blockedDomainRuleCount,
            allowRuleCount: summary.allowRuleCount,
            guardrailRuleCount: summary.guardrailRuleCount,
            tierBudgetRuleCount: summary.tierBudgetRuleCount
        )
    }

    /// Cheap, SKIP-ONLY header read for the cold-start sync-bootstrap gate: total rule count
    /// PLUS whether the artifact carries a stored summary (`summarySchema` present). No entry
    /// decode — the table-count fields live at fixed offsets regardless of `summarySchema`.
    ///
    /// `hasStoredSummary` lets the bootstrap EXCLUDE legacy (pre-summary-schema) artifacts: for
    /// those, `readSummary` full-decodes the rule tables (lines ~382) to recompute the summary,
    /// and `reusableCompactSnapshot` then `decode`s them AGAIN — a DOUBLE synchronous decode on
    /// cold start. Legacy artifacts are transient (regenerated on the next publish), so the
    /// bootstrap skips them and lets the async path decode them once, off the critical path.
    public static func readSyncBootstrapInfo(from data: Data) throws -> (totalRuleCount: Int, hasStoredSummary: Bool) {
        var reader = CompactBinaryReader(data: data)
        let magic = try reader.readData(count: Self.magic.count)
        guard magic == Self.magic else {
            throw CompactFilterSnapshotError.invalidMagic
        }
        let version = try reader.readUInt32()
        guard version == Self.fileVersion else {
            throw CompactFilterSnapshotError.unsupportedVersion(version)
        }
        let metadataLength = try reader.readUInt32()
        let metadataData = try reader.readData(count: Int(metadataLength))
        let metadata = try? JSONDecoder().decode(CompactFilterSnapshotMetadata.self, from: metadataData)
        let hasStoredSummary = metadata?.summarySchema == Self.metadataSummarySchemaVersion && metadata?.summary != nil
        let blockRuleCount = try CompactDomainRuleSet.readSummary(reader: &reader)
        let allowRuleCount = try CompactDomainRuleSet.readSummary(reader: &reader)
        let guardrailRuleCount = try CompactDomainRuleSet.readSummary(reader: &reader)
        return (blockRuleCount + allowRuleCount + guardrailRuleCount, hasStoredSummary)
    }

    private static func summary(
        metadata: CompactFilterSnapshotMetadata,
        blockRules: CompactDomainRuleSet,
        allowRules: CompactDomainRuleSet,
        nonAllowableThreatRules: CompactDomainRuleSet
    ) -> PreparedFilterSnapshotSummary {
        PreparedFilterSnapshotSummary(
            blocklistRuleCount: metadata.summary?.blocklistRuleCount,
            blocklistSourceRuleCounts: metadata.summary?.blocklistSourceRuleCounts,
            blockRuleCount: blockRules.count,
            blockedDomainRuleCount: blockRules.effectiveBlockedDomainRuleCount(
                allowRules: allowRules,
                nonAllowableThreatRules: nonAllowableThreatRules
            ),
            allowRuleCount: allowRules.count,
            guardrailRuleCount: nonAllowableThreatRules.count,
            tierBudgetRuleCount: metadata.summary?.tierBudgetRuleCount
        )
    }
}

/// Header-level identity and rule counts for a compact snapshot artifact.
public struct CompactFilterSnapshotSummary: Equatable, Sendable {
    /// Inputs that identify the configuration and catalog used for the artifact.
    public let identity: PreparedFilterSnapshotIdentity
    /// Time the snapshot represented by the artifact was generated.
    public let generatedAt: Date
    /// Resolver configuration stored in the artifact.
    public let resolver: DNSResolverPreset
    /// Total parsed blocklist rules before local rule merging, when recorded.
    public let blocklistRuleCount: Int?
    /// Parsed rule counts keyed by selected blocklist source, when recorded.
    public let blocklistSourceRuleCounts: [String: Int]?
    /// Number of effective block-table entries.
    public let blockRuleCount: Int
    /// Number of blocked-domain entries after overlapping allow rules are applied.
    public let blockedDomainRuleCount: Int
    /// Number of allow-table entries.
    public let allowRuleCount: Int
    /// Number of non-allowable threat guardrail entries.
    public let guardrailRuleCount: Int
    /// The recorded INV-TIER-1 total the writer's gate evaluated (block-merge + FULL
    /// guardrail + allowed + blocked). Carried in the header's metadata JSON — the resident
    /// table counts CANNOT reconstruct it (the resident guardrail is only the
    /// allowlist-overlap subset), which is why the tunnel's tier gates bind this recorded
    /// value and fail closed on nil (a legacy artifact regenerates through a stamping
    /// compile). PR #335 Codex P1.
    public let tierBudgetRuleCount: Int?

    /// Returns whether the summary records every blocklist enabled by a configuration.
    public func coversEnabledBlocklists(in configuration: AppConfiguration) -> Bool {
        guard !configuration.enabledBlocklistIDs.isEmpty else {
            return true
        }

        guard let blocklistSourceRuleCounts else {
            return false
        }

        return configuration.enabledBlocklistIDs.allSatisfy { blocklistSourceRuleCounts[$0] != nil }
    }

    /// Cheap reuse check from the header alone, mirroring
    /// `CompactFilterSnapshot.canReuseForProtectionStartup` without
    /// materializing the rule tables. Lets a live reload decide whether the
    /// on-disk artifact would produce a snapshot identical to one already in
    /// hand, so the multi-megabyte decode can be skipped.
    public func canReuseForProtectionStartup(
        configuration: AppConfiguration,
        cachedCatalog: BlocklistCatalog?
    ) -> Bool {
        guard resolver.transport == configuration.resolverPreset.transport else {
            return false
        }

        if !configuration.enabledBlocklistIDs.isEmpty {
            guard cachedCatalog != nil, coversEnabledBlocklists(in: configuration) else {
                return false
            }
        }

        if let cachedCatalog {
            let expectedIdentity = PreparedFilterSnapshotIdentity.make(
                configuration: configuration,
                catalog: cachedCatalog
            )
            return identity.hasSameSnapshotInputs(as: expectedIdentity)
        }

        return identity.hasSameConfigurationInputs(as: configuration)
    }

    /// Whether this artifact is safe to serve as a LAST-KNOWN-GOOD fallback when a
    /// fresh (re)compile cannot be produced — the rotating-upstream / stale-pinned-hash
    /// wedge: a `source_url_only` blocklist's upstream rotated past the catalog's pinned
    /// hash, so the strict reuse gate (`canReuseForProtectionStartup`) rejects this
    /// artifact on the catalog-hash diff and the in-extension recompile throws
    /// `checksumMismatch` against the stale cached source content.
    ///
    /// This is STRICTLY WEAKER than `canReuseForProtectionStartup` in exactly one way:
    /// it tolerates stale catalog/guardrail content hashes/versions (the catalog-managed
    /// fields). It keeps the resolver-transport and coverage guards and still requires the
    /// SAME CONFIGURATION INPUTS (`hasSameConfigurationInputs`: enabled-list set, manual
    /// block/allow domains, custom-list fingerprints, AND the current parser rules version).
    /// So it never silently fails OPEN — the enabled-list set must match exactly, so we only ever
    /// re-serve the user's own previously-compiled, previously-verified rules — and a
    /// parser-rules bump still forces a regenerate. Serving those rules a few hours
    /// stale beats clearing protection to zero on a cold start. The caller returns the
    /// artifact's own (stale) identity, so the tunnel reloads to fresh rules as soon as
    /// the app republishes a buildable artifact.
    public func canServeAsLastKnownGood(for configuration: AppConfiguration) -> Bool {
        guard resolver.transport == configuration.resolverPreset.transport else {
            return false
        }

        if !configuration.enabledBlocklistIDs.isEmpty {
            guard coversEnabledBlocklists(in: configuration) else {
                return false
            }
        }

        return identity.hasSameConfigurationInputs(as: configuration)
    }
}

package struct CompactDomainRuleSet: Equatable, Sendable {
    // Internal (not fileprivate) so the in-extension streaming writer
    // (`StreamingCompactSnapshotCompiler`) can build entries that point into the blob it
    // streams to disk and hand them to `CompactFilterSnapshot.writeStreaming`.
    struct Entry: Equatable, Sendable {
        let offset: UInt32
        let length: UInt16
    }

    private let exactEntries: [Entry]
    private let suffixEntries: [Entry]
    private let domainData: Data

    package init(ruleSet: DomainRuleSet) {
        self.init(
            exactDomains: ruleSet.exactDomainList,
            suffixDomains: ruleSet.suffixDomainList
        )
    }

    package init(
        exactDomains: [String] = [],
        suffixDomains: [String] = []
    ) {
        var builder = CompactDomainRuleTableBuilder()
        exactEntries = builder.appendDomains(exactDomains)
        suffixEntries = builder.appendDomains(suffixDomains)
        domainData = builder.data
    }

    fileprivate init(reader: inout CompactBinaryReader) throws {
        let exactCount = Int(try reader.readUInt32())
        let suffixCount = Int(try reader.readUInt32())
        exactEntries = try Self.readEntries(count: exactCount, reader: &reader)
        suffixEntries = try Self.readEntries(count: suffixCount, reader: &reader)
        domainData = try reader.readData(count: Int(try reader.readUInt32()))

        guard Self.entriesAreValid(exactEntries, dataCount: domainData.count),
              Self.entriesAreValid(suffixEntries, dataCount: domainData.count)
        else {
            throw CompactFilterSnapshotError.invalidRuleTable
        }

        // The lookup is a binary search, so it silently returns wrong decisions if
        // the on-disk entry tables aren't byte-sorted (a bit-rot or future-writer
        // bug). Verify monotonic order on decode (O(total bytes), once) and fail
        // CLOSED via the throw rather than serve a snapshot that under-blocks.
        guard Self.entriesAreSorted(exactEntries, domainData: domainData),
              Self.entriesAreSorted(suffixEntries, domainData: domainData)
        else {
            throw CompactFilterSnapshotError.invalidRuleTable
        }
    }

    package var count: Int {
        exactEntries.count + suffixEntries.count
    }

    fileprivate static func readSummary(reader: inout CompactBinaryReader) throws -> Int {
        let exactCount = Int(try reader.readUInt32())
        let suffixCount = Int(try reader.readUInt32())
        try reader.skip(count: (exactCount + suffixCount) * 6)
        try reader.skip(count: Int(try reader.readUInt32()))
        return exactCount + suffixCount
    }

    fileprivate var encodedSizeEstimate: Int {
        12 + ((exactEntries.count + suffixEntries.count) * 6) + domainData.count
    }

    package func containsNormalized(_ normalizedDomain: String) -> Bool {
        // Normalized domains are pure ASCII (`DomainName.normalize` restricts
        // every label to `[a-z0-9-]`), so byte-lexicographic ordering is
        // identical to the `String` ordering the entry tables were sorted by.
        // Comparing the query's UTF8 bytes directly against `domainData` avoids
        // materializing a `String` per binary-search step (log-N allocations
        // per query) and a fresh `String` per stripped label — this is the
        // per-query hot path.
        let queryBytes = Array(normalizedDomain.utf8)

        if contains(queryBytes[...], in: exactEntries) || contains(queryBytes[...], in: suffixEntries) {
            return true
        }

        var searchStart = queryBytes.startIndex
        while let dotIndex = queryBytes[searchStart...].firstIndex(of: UInt8(ascii: ".")) {
            searchStart = queryBytes.index(after: dotIndex)
            if contains(queryBytes[searchStart...], in: suffixEntries) {
                return true
            }
        }

        return false
    }

    fileprivate func effectiveBlockedDomainRuleCount(
        allowRules: CompactDomainRuleSet,
        nonAllowableThreatRules: CompactDomainRuleSet
    ) -> Int {
        max(0, count - allowRules.protectionReducingRuleCount(
            blockRules: self,
            nonAllowableThreatRules: nonAllowableThreatRules
        ))
    }

    fileprivate func appendEncodedData(to data: inout Data) throws {
        try Self.validateTableSizes(
            exactCount: exactEntries.count,
            suffixCount: suffixEntries.count,
            domainDataCount: domainData.count
        )
        // In-heap path: `.max` threshold + no-op flush, so `data` is the accumulator and
        // this is byte-identical to the inline layout it replaced.
        try Self.emitTablePrefix(
            exactEntries: exactEntries,
            suffixEntries: suffixEntries,
            domainDataCount: domainData.count,
            into: &data,
            flushThreshold: Int.max,
            flush: { _ in }
        )
        data.append(domainData)
    }

    /// Validates the per-table counts/size fit the UInt32 fields of the on-disk format.
    /// Shared by `appendEncodedData` and `CompactFilterSnapshot.writeStreaming`.
    static func validateTableSizes(exactCount: Int, suffixCount: Int, domainDataCount: Int) throws {
        guard exactCount <= Int(UInt32.max),
              suffixCount <= Int(UInt32.max),
              domainDataCount <= Int(UInt32.max)
        else {
            throw CompactFilterSnapshotError.artifactTooLarge
        }
    }

    /// Single source of truth for a rule table's on-disk PREFIX byte layout
    /// (exactCount, suffixCount, all exact entries, all suffix entries, domainDataLength),
    /// emitted into `buffer` and flushed via `flush` whenever it exceeds `flushThreshold`.
    /// The in-heap encoder passes `flushThreshold: .max` + a no-op flush (so `buffer` is the
    /// caller's accumulator); the streaming writer passes a small threshold + a `FileHandle`
    /// flush so only a bounded buffer is ever resident. The trailing raw domain blob is
    /// appended by the caller. Entries are emitted verbatim, so the caller MUST pass them
    /// already byte-lexicographically sorted (and deduped) — the decoder fails closed on a
    /// non-monotonic table (`entriesAreSorted`).
    static func emitTablePrefix(
        exactEntries: [Entry],
        suffixEntries: [Entry],
        domainDataCount: Int,
        into buffer: inout Data,
        flushThreshold: Int,
        flush: (inout Data) throws -> Void
    ) throws {
        buffer.appendLittleEndian(UInt32(exactEntries.count))
        buffer.appendLittleEndian(UInt32(suffixEntries.count))
        for entry in exactEntries {
            buffer.appendLittleEndian(entry.offset)
            buffer.appendLittleEndian(entry.length)
            if buffer.count >= flushThreshold { try flush(&buffer) }
        }
        for entry in suffixEntries {
            buffer.appendLittleEndian(entry.offset)
            buffer.appendLittleEndian(entry.length)
            if buffer.count >= flushThreshold { try flush(&buffer) }
        }
        buffer.appendLittleEndian(UInt32(domainDataCount))
    }

    private func contains(_ query: ArraySlice<UInt8>, in entries: [Entry]) -> Bool {
        guard !entries.isEmpty else {
            return false
        }

        return query.withUnsafeBufferPointer { queryBuffer in
            domainData.withUnsafeBytes { table -> Bool in
                var low = 0
                var high = entries.count

                while low < high {
                    let mid = low + ((high - low) / 2)
                    let entry = entries[mid]
                    let order = Self.compareEntry(
                        table,
                        offset: Int(entry.offset),
                        length: Int(entry.length),
                        to: queryBuffer
                    )

                    if order == 0 {
                        return true
                    }

                    if order < 0 {
                        low = mid + 1
                    } else {
                        high = mid
                    }
                }

                return false
            }
        }
    }

    /// Lexicographically compares an entry's stored UTF8 bytes (the `length`
    /// bytes of `table` at `offset`) against the query's UTF8 bytes. Returns a
    /// negative value if the entry sorts before the query, zero if equal, and a
    /// positive value if after — reproducing `String`'s ordering for the
    /// ASCII-only normalized domains stored here, so the table's existing
    /// `String`-sorted layout stays valid.
    private static func compareEntry(
        _ table: UnsafeRawBufferPointer,
        offset: Int,
        length: Int,
        to query: UnsafeBufferPointer<UInt8>
    ) -> Int {
        let shared = min(length, query.count)
        var index = 0
        while index < shared {
            let entryByte = table[offset + index]
            let queryByte = query[index]
            if entryByte != queryByte {
                return entryByte < queryByte ? -1 : 1
            }
            index += 1
        }

        if length == query.count {
            return 0
        }
        return length < query.count ? -1 : 1
    }

    private func protectionReducingRuleCount(
        blockRules: CompactDomainRuleSet,
        nonAllowableThreatRules: CompactDomainRuleSet
    ) -> Int {
        exactEntries.reduce(0) { count, entry in
            let domain = domainString(for: entry)
            return count + (Self.allowedRuleReducesProtection(
                domain,
                matchesSubdomains: false,
                blockRules: blockRules,
                nonAllowableThreatRules: nonAllowableThreatRules
            ) ? 1 : 0)
        } + suffixEntries.reduce(0) { count, entry in
            let domain = domainString(for: entry)
            return count + (Self.allowedRuleReducesProtection(
                domain,
                matchesSubdomains: true,
                blockRules: blockRules,
                nonAllowableThreatRules: nonAllowableThreatRules
            ) ? 1 : 0)
        }
    }

    private static func allowedRuleReducesProtection(
        _ normalizedDomain: String,
        matchesSubdomains: Bool,
        blockRules: CompactDomainRuleSet,
        nonAllowableThreatRules: CompactDomainRuleSet
    ) -> Bool {
        if blockRules.containsNormalized(normalizedDomain) {
            return true
        }

        guard matchesSubdomains else {
            return false
        }

        return blockRules.hasRuleAtOrBelow(normalizedDomain)
    }

    private func hasRuleAtOrBelow(_ normalizedDomain: String) -> Bool {
        exactEntries.contains { Self.domain(domainString(for: $0), isEqualToOrSubdomainOf: normalizedDomain) }
            || suffixEntries.contains { Self.domain(domainString(for: $0), isEqualToOrSubdomainOf: normalizedDomain) }
    }

    private static func domain(_ domain: String, isEqualToOrSubdomainOf parentDomain: String) -> Bool {
        domain == parentDomain || domain.hasSuffix(".\(parentDomain)")
    }

    private func domainString(for entry: Entry) -> String {
        let start = domainData.startIndex + Int(entry.offset)
        let end = start + Int(entry.length)
        return String(decoding: domainData[start..<end], as: UTF8.self)
    }

    private static func readEntries(
        count: Int,
        reader: inout CompactBinaryReader
    ) throws -> [Entry] {
        var entries: [Entry] = []
        entries.reserveCapacity(count)

        for _ in 0..<count {
            entries.append(Entry(
                offset: try reader.readUInt32(),
                length: try reader.readUInt16()
            ))
        }

        return entries
    }

    private static func entriesAreValid(_ entries: [Entry], dataCount: Int) -> Bool {
        entries.allSatisfy { entry in
            let offset = Int(entry.offset)
            let length = Int(entry.length)
            return offset >= 0 && length > 0 && offset + length <= dataCount
        }
    }

    // Entries must be in non-decreasing byte-lexicographic order of their stored
    // domain bytes — the invariant the binary-search lookup relies on. Call only
    // after `entriesAreValid` (offsets/lengths must be in-bounds to read here).
    private static func entriesAreSorted(_ entries: [Entry], domainData: Data) -> Bool {
        guard entries.count > 1 else {
            return true
        }

        return domainData.withUnsafeBytes { table -> Bool in
            for index in 1..<entries.count {
                let previous = entries[index - 1]
                let current = entries[index]
                if compareTableSlices(
                    table,
                    offset: Int(previous.offset), length: Int(previous.length),
                    otherOffset: Int(current.offset), otherLength: Int(current.length)
                ) > 0 {
                    return false
                }
            }
            return true
        }
    }

    private static func compareTableSlices(
        _ table: UnsafeRawBufferPointer,
        offset: Int, length: Int,
        otherOffset: Int, otherLength: Int
    ) -> Int {
        let shared = min(length, otherLength)
        var index = 0
        while index < shared {
            let lhs = table[offset + index]
            let rhs = table[otherOffset + index]
            if lhs != rhs {
                return lhs < rhs ? -1 : 1
            }
            index += 1
        }

        if length == otherLength {
            return 0
        }
        return length < otherLength ? -1 : 1
    }
}

private struct CompactFilterSnapshotMetadata: Codable, Equatable, Sendable {
    let identity: PreparedFilterSnapshotIdentity
    let generatedAt: Date
    let resolver: DNSResolverPreset
    let summary: PreparedFilterSnapshotSummary?
    var summarySchema: Int? = nil
}

private struct CompactDomainRuleTableBuilder {
    private(set) var data = Data()

    mutating func appendDomains(_ domains: [String]) -> [CompactDomainRuleSet.Entry] {
        let sortedDomains = domains.sorted()
        var entries: [CompactDomainRuleSet.Entry] = []
        entries.reserveCapacity(sortedDomains.count)

        for domain in sortedDomains {
            let domainBytes = Data(domain.utf8)
            precondition(domainBytes.count <= Int(UInt16.max), "Domain is too long for compact snapshot: \(domain)")
            precondition(data.count <= Int(UInt32.max), "Compact snapshot domain table is too large.")

            entries.append(CompactDomainRuleSet.Entry(
                offset: UInt32(data.count),
                length: UInt16(domainBytes.count)
            ))
            data.append(domainBytes)
        }

        return entries
    }
}

fileprivate struct CompactBinaryReader {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readBytes(count: 2)
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0,
              offset + count <= data.count
        else {
            throw CompactFilterSnapshotError.truncatedData
        }

        let start = data.startIndex + offset
        offset += count
        // Zero-copy slice over the backing buffer (no `subdata` copy). When the
        // backing is the `.mappedIfSafe` artifact, the big domain-table blob
        // stays file-backed/paged instead of becoming a multi-megabyte dirty
        // heap copy — the resident snapshot then costs ~entries only, lifting
        // the on-device domain ceiling. Callers never mutate the result, and
        // `CompactDomainRuleSet.domainString` already indexes via
        // `domainData.startIndex`, so a non-zero slice start is handled.
        let slice = data[start..<(start + count)]
        return slice
    }

    mutating func skip(count: Int) throws {
        guard count >= 0,
              offset + count <= data.count
        else {
            throw CompactFilterSnapshotError.truncatedData
        }

        offset += count
    }

    private mutating func readBytes(count: Int) throws -> [UInt8] {
        Array(try readData(count: count))
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(value & 0x00ff))
        append(UInt8((value >> 8) & 0x00ff))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0x000000ff))
        append(UInt8((value >> 8) & 0x000000ff))
        append(UInt8((value >> 16) & 0x000000ff))
        append(UInt8((value >> 24) & 0x000000ff))
    }
}

extension FileHandle {
    /// Throwing append used by the streaming compact writer and the blob spill. The
    /// non-throwing `write(_:)` is deprecated and TRAPS on error (e.g. disk full) — which
    /// in the packet-tunnel extension would crash the tunnel; `write(contentsOf:)` throws,
    /// so an IO error fails the compile and the caller falls back fail-CLOSED instead.
    func lavaWrite(_ data: Data) throws {
        try write(contentsOf: data)
    }
}
