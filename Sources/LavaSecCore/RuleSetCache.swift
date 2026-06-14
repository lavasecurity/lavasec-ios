import Foundation

// Persistent cache of PARSED blocklist rules, keyed by the raw payload's full
// SHA-256, the parse format, and BlocklistParsingRules.rulesVersion. A hit
// skips reading and hashing up to 25 MB of raw text and the dominant
// parse + double-normalization pass; entries store post-lavaSecProtectedDomains
// rule lists, so they are safe to use as-is.
//
// versionID is deliberately NOT part of the key: rotating source_url_only
// sources derive it from a 12-character hash prefix and the built-in fallback
// catalog uses a constant, so it can stay fixed while content changes.
public struct RuleSetCache: Sendable {
    public struct Entry: Equatable, Sendable {
        public let ruleSet: DomainRuleSet
        public let payloadByteSize: Int

        public init(ruleSet: DomainRuleSet, payloadByteSize: Int) {
            self.ruleSet = ruleSet
            self.payloadByteSize = payloadByteSize
        }
    }

    static let schemaVersion: UInt16 = 1
    private static let magic = Data("LSRSC1".utf8)

    private let directoryURL: URL

    public init(cacheDirectoryURL: URL) {
        // rulesVersion in the path orphans the whole previous tree on a parser
        // bump; the header carries it too as defense in depth.
        directoryURL = cacheDirectoryURL
            .appendingPathComponent("parsed-rules")
            .appendingPathComponent("v\(BlocklistParsingRules.rulesVersion)")
    }

    public func load(sourceID: String, contentSHA256: String, parseFormat: BlocklistFormat) -> Entry? {
        let url = entryURL(sourceID: sourceID, contentSHA256: contentSHA256, parseFormat: parseFormat)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        guard let entry = Self.decode(data, contentSHA256: contentSHA256, parseFormat: parseFormat) else {
            // Corrupted or stale-layout entries fall back to a fresh parse.
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        return entry
    }

    // Failures must never fail preparation; callers use try? by convention.
    public func store(
        _ ruleSet: DomainRuleSet,
        sourceID: String,
        contentSHA256: String,
        parseFormat: BlocklistFormat,
        payloadByteSize: Int
    ) throws {
        let url = entryURL(sourceID: sourceID, contentSHA256: contentSHA256, parseFormat: parseFormat)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Self.encode(ruleSet, contentSHA256: contentSHA256, parseFormat: parseFormat, payloadByteSize: payloadByteSize)
        try data.write(to: url, options: [.atomic])
        enforceLimits(forSourceID: sourceID)
    }

    public func removeAll(forSourceID sourceID: String) {
        try? FileManager.default.removeItem(at: sourceDirectoryURL(sourceID: sourceID))
    }

    // Keeps the newest entries per source (current plus one previous, matching
    // the raw payload cache's rollback posture).
    public func enforceLimits(forSourceID sourceID: String, keepPerSource: Int = 2) {
        let directory = sourceDirectoryURL(sourceID: sourceID)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }

        let sorted = entries.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
        for stale in sorted.dropFirst(keepPerSource) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    private func sourceDirectoryURL(sourceID: String) -> URL {
        directoryURL.appendingPathComponent(Self.safePathComponent(sourceID))
    }

    private func entryURL(sourceID: String, contentSHA256: String, parseFormat: BlocklistFormat) -> URL {
        sourceDirectoryURL(sourceID: sourceID)
            .appendingPathComponent("\(contentSHA256.prefix(12))-\(parseFormat.rawValue).ruleset")
    }

    static func safePathComponent(_ value: String) -> String {
        String(value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "." ? character : "_"
        })
    }

    // Entry layout (little-endian): magic, schemaVersion UInt16, rulesVersion
    // UInt32, format string, full content hash string, payloadByteSize UInt64,
    // exact count UInt32, suffix count UInt32, per-domain UInt16 lengths, and
    // one contiguous UTF-8 blob of all domains in order.
    static func encode(
        _ ruleSet: DomainRuleSet,
        contentSHA256: String,
        parseFormat: BlocklistFormat,
        payloadByteSize: Int
    ) -> Data {
        let exactDomains = ruleSet.exactDomainList
        let suffixDomains = ruleSet.suffixDomainList

        var data = Data()
        data.append(magic)
        appendUInt16(&data, schemaVersion)
        appendUInt32(&data, UInt32(BlocklistParsingRules.rulesVersion))
        appendString(&data, parseFormat.rawValue)
        appendString(&data, contentSHA256)
        appendUInt64(&data, UInt64(payloadByteSize))
        appendUInt32(&data, UInt32(exactDomains.count))
        appendUInt32(&data, UInt32(suffixDomains.count))

        var blob = Data()
        for domain in exactDomains {
            let bytes = Data(domain.utf8)
            appendUInt16(&data, UInt16(bytes.count))
            blob.append(bytes)
        }
        for domain in suffixDomains {
            let bytes = Data(domain.utf8)
            appendUInt16(&data, UInt16(bytes.count))
            blob.append(bytes)
        }
        appendUInt64(&data, UInt64(blob.count))
        data.append(blob)
        return data
    }

    static func decode(_ data: Data, contentSHA256: String, parseFormat: BlocklistFormat) -> Entry? {
        var reader = RuleSetCacheReader(data: data)
        guard reader.readData(count: magic.count) == magic,
              reader.readUInt16() == schemaVersion,
              reader.readUInt32() == UInt32(BlocklistParsingRules.rulesVersion),
              reader.readString() == parseFormat.rawValue,
              reader.readString() == contentSHA256,
              let payloadByteSize = reader.readUInt64(),
              let exactCount = reader.readUInt32().map(Int.init),
              let suffixCount = reader.readUInt32().map(Int.init),
              exactCount >= 0, suffixCount >= 0, exactCount + suffixCount <= 5_000_000
        else {
            return nil
        }

        var lengths: [Int] = []
        lengths.reserveCapacity(exactCount + suffixCount)
        for _ in 0..<(exactCount + suffixCount) {
            guard let length = reader.readUInt16() else {
                return nil
            }
            lengths.append(Int(length))
        }

        guard let blobLength = reader.readUInt64().map(Int.init),
              blobLength == lengths.reduce(0, +),
              let blob = reader.readData(count: blobLength),
              reader.isAtEnd
        else {
            return nil
        }

        var exactDomains = Set<String>(minimumCapacity: exactCount)
        var suffixDomains = Set<String>(minimumCapacity: suffixCount)
        var cursor = blob.startIndex
        for (index, length) in lengths.enumerated() {
            guard let end = blob.index(cursor, offsetBy: length, limitedBy: blob.endIndex) else {
                return nil
            }
            let domain = String(decoding: blob[cursor..<end], as: UTF8.self)
            cursor = end
            if index < exactCount {
                exactDomains.insert(domain)
            } else {
                suffixDomains.insert(domain)
            }
        }

        return Entry(
            // Cached domains are post-normalization and post-filter; the
            // set-based initializer trusts them without re-normalizing.
            ruleSet: DomainRuleSet(exactDomains: exactDomains, suffixDomains: suffixDomains),
            payloadByteSize: Int(payloadByteSize)
        )
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8((value >> shift) & 0xFF))
        }
    }

    private static func appendUInt64(_ data: inout Data, _ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            data.append(UInt8((value >> shift) & 0xFF))
        }
    }

    private static func appendString(_ data: inout Data, _ value: String) {
        let bytes = Data(value.utf8)
        appendUInt32(&data, UInt32(bytes.count))
        data.append(bytes)
    }
}

private struct RuleSetCacheReader {
    private let data: Data
    private var offset: Data.Index

    init(data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var isAtEnd: Bool {
        offset == data.endIndex
    }

    mutating func readData(count: Int) -> Data? {
        guard count >= 0,
              let end = data.index(offset, offsetBy: count, limitedBy: data.endIndex)
        else {
            return nil
        }

        let slice = data.subdata(in: offset..<end)
        offset = end
        return slice
    }

    mutating func readUInt16() -> UInt16? {
        guard let bytes = readData(count: 2) else {
            return nil
        }
        return UInt16(bytes[bytes.startIndex]) | (UInt16(bytes[bytes.startIndex + 1]) << 8)
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = readData(count: 4) else {
            return nil
        }
        var value: UInt32 = 0
        for (index, byte) in bytes.enumerated() {
            value |= UInt32(byte) << (8 * UInt32(index))
        }
        return value
    }

    mutating func readUInt64() -> UInt64? {
        guard let bytes = readData(count: 8) else {
            return nil
        }
        var value: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            value |= UInt64(byte) << (8 * UInt64(index))
        }
        return value
    }

    mutating func readString() -> String? {
        guard let length = readUInt32().map(Int.init),
              length <= 1_024,
              let bytes = readData(count: length)
        else {
            return nil
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
