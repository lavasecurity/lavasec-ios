import Foundation

// DNS response caching, extracted from PacketTunnelProvider. The cache key is
// (resolver identity, query bytes with the transaction ID zeroed) so identical
// questions from different clients share an entry but resolvers never
// cross-pollinate. Stored responses keep their transaction ID zeroed; hits are
// rewritten for the asking query. NOT internally synchronized — the tunnel
// confines all access to its DNS state queue, and the cache preserves that
// contract instead of paying for a lock on the packet path.

public struct DNSCacheKey: Hashable, Sendable {
    public let resolverIdentifier: String
    public let canonicalQuery: Data

    public init?(resolverIdentifier: String, dnsPayload: Data) {
        guard dnsPayload.count >= 12 else {
            return nil
        }

        self.resolverIdentifier = resolverIdentifier
        self.canonicalQuery = DNSWireMessage.clearingTransactionID(in: dnsPayload)
    }
}

public enum DNSResponseCachePolicy {
    private static let maximumTTL: TimeInterval = 300

    public static func cacheTTL(for response: Data) -> TimeInterval? {
        guard response.count >= 12 else {
            return nil
        }

        let questionCount = Int(readUInt16(response, at: 4))
        let answerCount = Int(readUInt16(response, at: 6))
        let authorityCount = Int(readUInt16(response, at: 8))
        let additionalCount = Int(readUInt16(response, at: 10))
        let resourceRecordCount = answerCount + authorityCount + additionalCount
        guard answerCount > 0 else {
            return nil
        }

        var cursor = 12
        for _ in 0..<questionCount {
            guard skipName(in: response, cursor: &cursor), cursor + 4 <= response.count else {
                return nil
            }
            cursor += 4
        }

        var minimumTTL = UInt32.max
        for _ in 0..<resourceRecordCount {
            guard skipName(in: response, cursor: &cursor), cursor + 10 <= response.count else {
                return nil
            }

            let recordType = readUInt16(response, at: cursor)
            let ttl = readUInt32(response, at: cursor + 4)
            let dataLength = Int(readUInt16(response, at: cursor + 8))
            cursor += 10

            guard cursor + dataLength <= response.count else {
                return nil
            }

            if recordType != 41, ttl == 0 {
                return nil
            }

            if recordType != 41 {
                minimumTTL = min(minimumTTL, ttl)
            }

            cursor += dataLength
        }

        guard minimumTTL != UInt32.max else {
            return nil
        }

        return min(TimeInterval(minimumTTL), maximumTTL)
    }

    private static func skipName(in data: Data, cursor: inout Int) -> Bool {
        var localCursor = cursor
        while localCursor < data.count {
            let length = data[localCursor]
            localCursor += 1

            if length == 0 {
                cursor = localCursor
                return true
            }

            if length & 0xC0 == 0xC0 {
                guard localCursor < data.count else {
                    return false
                }
                let pointer = (Int(length & 0x3F) << 8) | Int(data[localCursor])
                localCursor += 1
                guard isValidCompressedNameTarget(pointer, in: data) else {
                    return false
                }
                cursor = localCursor
                return true
            }

            guard length & 0xC0 == 0, localCursor + Int(length) <= data.count else {
                return false
            }

            localCursor += Int(length)
        }

        return false
    }

    private static func isValidCompressedNameTarget(_ offset: Int, in data: Data) -> Bool {
        guard offset >= 0, offset < data.count else {
            return false
        }

        var cursor = offset
        var visitedOffsets: Set<Int> = []
        while cursor < data.count {
            guard visitedOffsets.insert(cursor).inserted else {
                return false
            }

            let length = data[cursor]
            cursor += 1

            if length == 0 {
                return true
            }

            if length & 0xC0 == 0xC0 {
                guard cursor < data.count else {
                    return false
                }
                let pointer = (Int(length & 0x3F) << 8) | Int(data[cursor])
                guard pointer >= 0, pointer < data.count else {
                    return false
                }
                cursor = pointer
                continue
            }

            guard length & 0xC0 == 0, cursor + Int(length) <= data.count else {
                return false
            }

            cursor += Int(length)
        }

        return false
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }
}

public final class DNSResponseCache {
    private struct CachedDNSResponse {
        let response: Data
        let expiresAt: Date
    }

    private let maximumEntryCount: Int
    private let cleanupInterval: TimeInterval
    private var entries: [DNSCacheKey: CachedDNSResponse] = [:]
    private var lastCleanupAt = Date.distantPast

    public init(maximumEntryCount: Int = 512, cleanupInterval: TimeInterval = 30) {
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.cleanupInterval = max(0, cleanupInterval)
    }

    public var count: Int {
        entries.count
    }

    /// A hit returns the cached response with its transaction ID rewritten
    /// from `query`. Expired entries are evicted lazily and report a miss.
    public func cachedResponse(for key: DNSCacheKey, query: Data, now: Date = Date()) -> Data? {
        guard let cached = entries[key] else {
            return nil
        }

        guard cached.expiresAt > now else {
            entries.removeValue(forKey: key)
            return nil
        }

        return DNSWireMessage.replacingTransactionID(in: cached.response, from: query)
    }

    /// Caches the response when `DNSResponseCachePolicy` yields a TTL; the
    /// stored copy has its transaction ID zeroed. Piggybacks the throttled
    /// expiry sweep and the size trim on the write path, exactly like the
    /// inline implementation it replaces.
    public func store(_ response: Data, for key: DNSCacheKey, now: Date = Date()) {
        guard let cacheTTL = DNSResponseCachePolicy.cacheTTL(for: response) else {
            return
        }

        entries[key] = CachedDNSResponse(
            response: DNSWireMessage.clearingTransactionID(in: response),
            expiresAt: now.addingTimeInterval(cacheTTL)
        )

        removeExpiredEntriesIfNeeded(now: now)
        trimIfNeeded()
    }

    public func removeAll() {
        entries = [:]
    }

    private func removeExpiredEntriesIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastCleanupAt) >= cleanupInterval else {
            return
        }

        lastCleanupAt = now
        entries = entries.filter { _, cached in
            cached.expiresAt > now
        }
    }

    private func trimIfNeeded() {
        guard entries.count > maximumEntryCount else {
            return
        }

        let overflowCount = entries.count - maximumEntryCount
        let keysToRemove = entries
            .sorted { lhs, rhs in
                lhs.value.expiresAt < rhs.value.expiresAt
            }
            .prefix(overflowCount)
            .map { $0.key }

        for key in keysToRemove {
            entries.removeValue(forKey: key)
        }
    }
}
