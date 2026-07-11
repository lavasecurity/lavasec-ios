import Foundation
import LavaSecKit

// DNS response caching, extracted from PacketTunnelProvider. The cache key is
// (resolver identity, query bytes with the transaction ID zeroed) so identical
// questions from different clients share an entry but resolvers never
// cross-pollinate. Stored responses keep their transaction ID zeroed; hits are
// rewritten for the asking query. NOT internally synchronized — the tunnel
// confines all access to its DNS state queue, and the cache preserves that
// contract instead of paying for a lock on the packet path.

/// Resolver-scoped identity for a DNS question with its client-specific transaction ID removed.
public struct DNSCacheKey: Hashable, Sendable {
    internal let resolverIdentifier: String
    internal let canonicalQuery: Data

    /// Returns `nil` when `dnsPayload` is shorter than a DNS header; otherwise canonicalizes its transaction ID.
    public init?(resolverIdentifier: String, dnsPayload: Data) {
        guard dnsPayload.count >= 12 else {
            return nil
        }

        self.resolverIdentifier = resolverIdentifier
        self.canonicalQuery = DNSWireMessage.clearingTransactionID(in: dnsPayload)
    }
}

package enum DNSResponseCachePolicy {
    private static let maximumTTL: TimeInterval = 300
    // RFC 2308 negative entries get a much harder clamp than positive ones so a
    // transient NXDOMAIN can never be pinned for minutes (start conservative).
    private static let maximumNegativeTTL: TimeInterval = 60

    package static func cacheTTL(for response: Data) -> TimeInterval? {
        guard response.count >= 12 else {
            return nil
        }

        let questionCount = Int(readUInt16(response, at: 4))
        let answerCount = Int(readUInt16(response, at: 6))
        let authorityCount = Int(readUInt16(response, at: 8))
        let additionalCount = Int(readUInt16(response, at: 10))
        let resourceRecordCount = answerCount + authorityCount + additionalCount
        guard answerCount > 0 else {
            return negativeCacheTTL(
                for: response,
                questionCount: questionCount,
                authorityCount: authorityCount,
                additionalCount: additionalCount
            )
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

    /// RFC 2308 negative caching for empty-answer responses — NOERROR/NODATA and
    /// NXDOMAIN ONLY. SERVFAIL/REFUSED (rcodes 2/5) must NEVER be cached:
    /// `indicatesResolverFailure` keys encrypted-fallback engagement off exactly
    /// those rcodes, and the tunnel's synthesized SERVFAILs flow through `store()`
    /// too — a cached failure would keep replaying while masking the signal that
    /// recovers from it. The rcode gate here is load-bearing for fail-closed.
    private static func negativeCacheTTL(
        for response: Data,
        questionCount: Int,
        authorityCount: Int,
        additionalCount: Int
    ) -> TimeInterval? {
        let rcode = response[3] & 0x0F
        guard rcode == 0 || rcode == 3 else {
            return nil
        }

        // No SOA in the authority section -> no negative TTL to honor (RFC 2308 §5).
        guard authorityCount > 0 else {
            return nil
        }

        var cursor = 12
        for _ in 0..<questionCount {
            guard skipName(in: response, cursor: &cursor), cursor + 4 <= response.count else {
                return nil
            }
            cursor += 4
        }

        // The answer section is empty on this path, so the authority section starts
        // here. A cache hit replays the WHOLE stored packet, so every non-OPT record
        // it carries (DNSSEC NSEC/RRSIG in authority, glue in additional) bounds the
        // entry's lifetime exactly like the positive path: zero TTLs veto caching,
        // and the minimum across all records caps the expiry alongside the SOA.
        var soaMinimum: UInt32?
        var minimumTTL = UInt32.max
        for recordIndex in 0..<(authorityCount + additionalCount) {
            guard skipName(in: response, cursor: &cursor), cursor + 10 <= response.count else {
                return nil
            }

            let recordType = readUInt16(response, at: cursor)
            let recordTTL = readUInt32(response, at: cursor + 4)
            let dataLength = Int(readUInt16(response, at: cursor + 8))
            cursor += 10

            guard cursor + dataLength <= response.count else {
                return nil
            }

            if recordType != 41, recordTTL == 0 {
                return nil
            }

            if recordType != 41 {
                minimumTTL = min(minimumTTL, recordTTL)
            }

            // RFC 2308: only an AUTHORITY-section SOA anchors the negative TTL.
            // An SOA riding in additional data must not make the response cacheable.
            if recordType == 6, soaMinimum == nil, recordIndex < authorityCount {
                guard let minimumField = soaMinimumField(
                    in: response,
                    rdataStart: cursor,
                    rdataLength: dataLength
                ) else {
                    return nil
                }
                soaMinimum = minimumField
            }

            cursor += dataLength
        }

        // RFC 2308: the negative TTL is min(SOA record TTL, SOA MINIMUM) - here the
        // SOA record TTL participates via the all-records minimum. The pause-window
        // answer-TTL cap rewrites record TTLs in the stored response, so it bounds
        // this min as well.
        guard let soaMinimum, minimumTTL != UInt32.max else {
            return nil
        }

        let negativeTTL = min(minimumTTL, soaMinimum)
        guard negativeTTL > 0 else {
            return nil
        }

        return min(TimeInterval(negativeTTL), maximumNegativeTTL)
    }

    /// True when a cacheable response took the negative path (empty answer section).
    /// Only meaningful after `cacheTTL(for:)` returned non-nil for the same bytes.
    static func isNegativeEntry(_ response: Data) -> Bool {
        response.count >= 12 && readUInt16(response, at: 6) == 0
    }

    /// The MINIMUM field of an SOA RDATA: MNAME and RNAME (either may be
    /// compressed), then five 32-bit fields of which MINIMUM is the last.
    private static func soaMinimumField(
        in response: Data,
        rdataStart: Int,
        rdataLength: Int
    ) -> UInt32? {
        let rdataEnd = rdataStart + rdataLength
        var cursor = rdataStart
        guard skipName(in: response, cursor: &cursor),
              skipName(in: response, cursor: &cursor),
              cursor + 20 <= rdataEnd
        else {
            return nil
        }

        return readUInt32(response, at: cursor + 16)
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

/// Queue-confined response cache that stores canonical wire replies until their DNS-derived expiration time.
public final class DNSResponseCache {
    private struct CachedDNSResponse {
        let response: Data
        let expiresAt: Date
    }

    private let maximumEntryCount: Int
    private let cleanupInterval: TimeInterval
    private var entries: [DNSCacheKey: CachedDNSResponse] = [:]
    private var lastCleanupAt = Date.distantPast

    /// Creates a cache with a positive entry cap and a lazy-expiry sweep interval measured in seconds.
    public init(maximumEntryCount: Int = 512, cleanupInterval: TimeInterval = 30) {
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.cleanupInterval = max(0, cleanupInterval)
    }

    package var count: Int {
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

        // A negative entry's REPLAY must carry the clamped TTL too: the packet's
        // original SOA values would otherwise let the downstream stub resolver
        // negative-cache a transient NXDOMAIN for the full upstream TTL (hours),
        // defeating the 60s clamp for repeat clients. Positive entries keep their
        // original record TTLs - replaying honest positive TTLs is long-standing
        // behavior and ages out harmlessly.
        let responseToStore = DNSResponseCachePolicy.isNegativeEntry(response)
            ? DNSWireMessage.cappingAnswerTTLs(in: response, to: UInt32(cacheTTL))
            : response

        entries[key] = CachedDNSResponse(
            response: DNSWireMessage.clearingTransactionID(in: responseToStore),
            expiresAt: now.addingTimeInterval(cacheTTL)
        )

        removeExpiredEntriesIfNeeded(now: now)
        trimIfNeeded()
    }

    /// Drops every resolver-scoped response immediately, such as after a runtime identity change.
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
        // store() runs this after every insert, so the cache overflows by at most one
        // entry at a time. Evict the soonest-to-expire entry with a single linear pass
        // rather than re-sorting the entire table on every cacheable response once full
        // (the previous O(n log n)-per-write behavior on the serial dnsStateQueue). The
        // loop keeps the same evict-earliest-first semantics if it ever needs to shed
        // more than one (e.g. a future smaller cap), at O(n) per evicted entry.
        while entries.count > maximumEntryCount, let earliestKey = earliestExpiringKey() {
            entries.removeValue(forKey: earliestKey)
        }
    }

    private func earliestExpiringKey() -> DNSCacheKey? {
        var earliestKey: DNSCacheKey?
        var earliestExpiry = Date.distantFuture
        for (key, cached) in entries where cached.expiresAt < earliestExpiry {
            earliestExpiry = cached.expiresAt
            earliestKey = key
        }
        return earliestKey
    }
}
