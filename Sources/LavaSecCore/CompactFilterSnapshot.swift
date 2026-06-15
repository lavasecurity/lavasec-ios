import Foundation

public enum CompactFilterSnapshotError: Error, Equatable {
    case invalidMagic
    case unsupportedVersion(UInt32)
    case truncatedData
    case invalidMetadata
    case invalidRuleTable
    case domainTooLong(String)
    case artifactTooLarge
}

public struct CompactFilterSnapshot: FilterRuntimeSnapshot {
    public static let fileVersion: UInt32 = 1

    // Bumped when the stored metadata summary becomes trustworthy for cheap
    // reads. Artifacts without this marker fall back to full-table recompute.
    static let metadataSummarySchemaVersion = 2

    private static let magic = Data("LSCFSNP1".utf8)

    public let identity: PreparedFilterSnapshotIdentity
    public let generatedAt: Date
    public let resolver: DNSResolverPreset
    public let blockRules: CompactDomainRuleSet
    public let allowRules: CompactDomainRuleSet
    public let nonAllowableThreatRules: CompactDomainRuleSet
    public let summary: PreparedFilterSnapshotSummary

    public init(
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
        // counts, which is why reads used to recompute).
        self.summary = PreparedFilterSnapshotSummary(
            blocklistRuleCount: summary?.blocklistRuleCount,
            blocklistSourceRuleCounts: summary?.blocklistSourceRuleCounts,
            blockRuleCount: blockRules.count,
            blockedDomainRuleCount: blockRules.effectiveBlockedDomainRuleCount(
                allowRules: allowRules,
                nonAllowableThreatRules: nonAllowableThreatRules
            ),
            allowRuleCount: allowRules.count,
            guardrailRuleCount: nonAllowableThreatRules.count
        )
    }

    public init(preparedSnapshot: PreparedFilterSnapshot) {
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

    public var blockRuleCount: Int {
        blockRules.count
    }

    public var allowRuleCount: Int {
        allowRules.count
    }

    public var guardrailRuleCount: Int {
        nonAllowableThreatRules.count
    }

    public func matches(identity expectedIdentity: PreparedFilterSnapshotIdentity) -> Bool {
        identity == expectedIdentity
    }

    public func canReuseForProtectionStartup(
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

    public func decision(for rawDomain: String) -> FilterDecision {
        guard let normalizedDomain = try? DomainName.normalize(rawDomain) else {
            return FilterDecision(action: .block, reason: .invalidDomain)
        }

        return decision(forNormalizedDomain: normalizedDomain)
    }

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

    public func encodedData() throws -> Data {
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
        data.reserveCapacity(
            Self.magic.count
                + 8
                + metadataData.count
                + blockRules.encodedSizeEstimate
                + allowRules.encodedSizeEstimate
                + nonAllowableThreatRules.encodedSizeEstimate
        )
        data.append(Self.magic)
        data.appendLittleEndian(Self.fileVersion)
        data.appendLittleEndian(UInt32(metadataData.count))
        data.append(metadataData)
        try blockRules.appendEncodedData(to: &data)
        try allowRules.appendEncodedData(to: &data)
        try nonAllowableThreatRules.appendEncodedData(to: &data)
        return data
    }

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
                guardrailRuleCount: storedSummary.guardrailRuleCount
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
            guardrailRuleCount: summary.guardrailRuleCount
        )
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
            guardrailRuleCount: nonAllowableThreatRules.count
        )
    }
}

public struct CompactFilterSnapshotSummary: Equatable, Sendable {
    public let identity: PreparedFilterSnapshotIdentity
    public let generatedAt: Date
    public let resolver: DNSResolverPreset
    public let blocklistRuleCount: Int?
    public let blocklistSourceRuleCounts: [String: Int]?
    public let blockRuleCount: Int
    public let blockedDomainRuleCount: Int
    public let allowRuleCount: Int
    public let guardrailRuleCount: Int

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
}

public struct CompactDomainRuleSet: Equatable, Sendable {
    fileprivate struct Entry: Equatable, Sendable {
        let offset: UInt32
        let length: UInt16
    }

    private let exactEntries: [Entry]
    private let suffixEntries: [Entry]
    private let domainData: Data

    public init(ruleSet: DomainRuleSet) {
        self.init(
            exactDomains: ruleSet.exactDomainList,
            suffixDomains: ruleSet.suffixDomainList
        )
    }

    public init(
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
    }

    public var count: Int {
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

    public func containsNormalized(_ normalizedDomain: String) -> Bool {
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
        guard exactEntries.count <= Int(UInt32.max),
              suffixEntries.count <= Int(UInt32.max),
              domainData.count <= Int(UInt32.max)
        else {
            throw CompactFilterSnapshotError.artifactTooLarge
        }

        data.appendLittleEndian(UInt32(exactEntries.count))
        data.appendLittleEndian(UInt32(suffixEntries.count))
        for entry in exactEntries {
            data.appendLittleEndian(entry.offset)
            data.appendLittleEndian(entry.length)
        }
        for entry in suffixEntries {
            data.appendLittleEndian(entry.offset)
            data.appendLittleEndian(entry.length)
        }
        data.appendLittleEndian(UInt32(domainData.count))
        data.append(domainData)
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
