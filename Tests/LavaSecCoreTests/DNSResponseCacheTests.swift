import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class DNSResponseCacheTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    // MARK: - DNSCacheKey

    func testCacheKeyCanonicalizesTransactionIDAndRequiresHeader() {
        let queryA = Self.dnsQuery(id: 0xABCD, domain: "example.com")
        let queryB = Self.dnsQuery(id: 0x1234, domain: "example.com")

        let keyA = DNSCacheKey(resolverIdentifier: "doh:one", dnsPayload: queryA)
        let keyB = DNSCacheKey(resolverIdentifier: "doh:one", dnsPayload: queryB)
        let otherResolver = DNSCacheKey(resolverIdentifier: "doh:two", dnsPayload: queryA)

        XCTAssertEqual(keyA, keyB, "Queries differing only in transaction ID must share a cache entry.")
        XCTAssertNotEqual(keyA, otherResolver, "Different resolvers must never share cache entries.")
        XCTAssertNil(DNSCacheKey(resolverIdentifier: "doh:one", dnsPayload: Data([0x00, 0x01])))
    }

    // MARK: - DNSResponseCachePolicy

    func testCacheTTLUsesMinimumAnswerTTLCappedAtFiveMinutes() {
        let short = Self.dnsResponse(id: 0, domain: "example.com", answerTTLs: [120])
        let mixed = Self.dnsResponse(id: 0, domain: "example.com", answerTTLs: [200, 50])
        let long = Self.dnsResponse(id: 0, domain: "example.com", answerTTLs: [900])

        XCTAssertEqual(DNSResponseCachePolicy.cacheTTL(for: short), 120)
        XCTAssertEqual(DNSResponseCachePolicy.cacheTTL(for: mixed), 50)
        XCTAssertEqual(DNSResponseCachePolicy.cacheTTL(for: long), 300)
    }

    func testCacheTTLRejectsUncacheableResponses() {
        // No answers AND no authority SOA: negatively uncacheable too (the SOA-backed
        // empty-answer cases live in the RFC 2308 section below).
        let noAnswers = Self.dnsResponse(id: 0, domain: "example.com", answerTTLs: [])
        let zeroTTL = Self.dnsResponse(id: 0, domain: "example.com", answerTTLs: [0])
        let truncatedHeader = Data([0x00, 0x00, 0x81, 0x80])

        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: noAnswers))
        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: zeroTTL))
        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: truncatedHeader))
    }

    // MARK: - Negative caching (RFC 2308)

    func testNegativeCacheTTLUsesSOAMinimumForNODATAAndNXDOMAIN() {
        let nodata = Self.dnsResponse(
            id: 0, domain: "example.com", answerTTLs: [],
            authoritySOA: (ttl: 900, minimum: 30)
        )
        let nxdomain = Self.dnsResponse(
            id: 0, domain: "example.com", rcode: 3, answerTTLs: [],
            authoritySOA: (ttl: 900, minimum: 30)
        )

        XCTAssertEqual(DNSResponseCachePolicy.cacheTTL(for: nodata), 30)
        XCTAssertEqual(DNSResponseCachePolicy.cacheTTL(for: nxdomain), 30)
    }

    func testNegativeCacheTTLIsBoundBySOARecordTTLAndClampedToSixtySeconds() {
        // The SOA record TTL bounds the min — this is the path the pause-window
        // answer-TTL cap flows through, since the cap rewrites the record TTL.
        let boundByRecordTTL = Self.dnsResponse(
            id: 0, domain: "example.com", rcode: 3, answerTTLs: [],
            authoritySOA: (ttl: 10, minimum: 300)
        )
        // Negative entries clamp at 60s, far below the positive 300s cap, so a
        // transient NXDOMAIN can never be pinned for minutes.
        let clamped = Self.dnsResponse(
            id: 0, domain: "example.com", rcode: 3, answerTTLs: [],
            authoritySOA: (ttl: 3_600, minimum: 3_600)
        )

        XCTAssertEqual(DNSResponseCachePolicy.cacheTTL(for: boundByRecordTTL), 10)
        XCTAssertEqual(DNSResponseCachePolicy.cacheTTL(for: clamped), 60)
    }

    func testServfailAndRefusedAreNeverCacheableEvenWithSOA() throws {
        // FAIL-CLOSED, load-bearing: `indicatesResolverFailure` keys encrypted-fallback
        // engagement off rcodes 2/5, and the tunnel's synthesized SERVFAILs flow into
        // store() — a cached failure would replay while masking the recovery signal.
        let servfail = Self.dnsResponse(
            id: 1, domain: "example.com", rcode: 2, answerTTLs: [],
            authoritySOA: (ttl: 900, minimum: 30)
        )
        let refused = Self.dnsResponse(
            id: 1, domain: "example.com", rcode: 5, answerTTLs: [],
            authoritySOA: (ttl: 900, minimum: 30)
        )
        // The synthesized-SERVFAIL shape (header-only, no records at all).
        var synthesized = Self.dnsQuery(id: 1, domain: "example.com")
        synthesized[2] = 0x81
        synthesized[3] = 0x82

        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: servfail))
        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: refused))
        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: synthesized))

        let cache = DNSResponseCache()
        let query = Self.dnsQuery(id: 1, domain: "example.com")
        let key = try XCTUnwrap(DNSCacheKey(resolverIdentifier: "doh:one", dnsPayload: query))
        cache.store(servfail, for: key, now: now)
        cache.store(refused, for: key, now: now)
        cache.store(synthesized, for: key, now: now)
        XCTAssertEqual(cache.count, 0, "rcodes 2/5 must never enter the cache.")
    }

    func testNegativeEntryIsBoundByEveryReplayedRecordTTL() {
        // A cache hit replays the whole packet, so a shorter-lived non-SOA record
        // (e.g. DNSSEC NSEC/RRSIG in authority) bounds the entry below the SOA values,
        // and a zero-TTL record anywhere vetoes caching - mirroring the positive path.
        let shorterAuthorityRecord = Self.dnsResponse(
            id: 0, domain: "example.com", rcode: 3, answerTTLs: [],
            authoritySOA: (ttl: 900, minimum: 300),
            authorityTTLs: [5]
        )
        let zeroTTLAdditional = Self.dnsResponse(
            id: 0, domain: "example.com", rcode: 3, answerTTLs: [],
            authoritySOA: (ttl: 900, minimum: 30),
            additionalNonOPTTTLs: [0]
        )
        // OPT pseudo-record "TTL" bytes carry EDNS flags: ignored, no veto, no bound.
        let withOPT = Self.dnsResponse(
            id: 0, domain: "example.com", rcode: 3, answerTTLs: [],
            authoritySOA: (ttl: 900, minimum: 30),
            includesOPTAdditional: true
        )

        XCTAssertEqual(DNSResponseCachePolicy.cacheTTL(for: shorterAuthorityRecord), 5)
        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: zeroTTLAdditional))
        XCTAssertEqual(DNSResponseCachePolicy.cacheTTL(for: withOPT), 30)
    }

    func testNegativeResponseWithoutSOAIsNotCached() {
        // NXDOMAIN whose authority holds only a non-SOA record: no negative TTL to honor.
        let nxdomainNoSOA = Self.dnsResponse(
            id: 0, domain: "example.com", rcode: 3, answerTTLs: [],
            authorityTTLs: [300]
        )
        // An SOA in ADDITIONAL data is not an RFC 2308 anchor: authority-section only.
        let additionalSOAOnly = Self.dnsResponse(
            id: 0, domain: "example.com", rcode: 3, answerTTLs: [],
            additionalSOA: (ttl: 900, minimum: 30),
            authorityTTLs: [300]
        )

        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: nxdomainNoSOA))
        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: additionalSOAOnly))
    }

    func testNegativeCacheRejectsZeroTTLsAndMalformedSOA() {
        let zeroRecordTTL = Self.dnsResponse(
            id: 0, domain: "example.com", rcode: 3, answerTTLs: [],
            authoritySOA: (ttl: 0, minimum: 30)
        )
        let zeroMinimum = Self.dnsResponse(
            id: 0, domain: "example.com", rcode: 3, answerTTLs: [],
            authoritySOA: (ttl: 900, minimum: 0)
        )
        // RDLENGTH too short to hold the five 32-bit SOA fields.
        let truncatedRDATA = Self.dnsResponse(
            id: 0, domain: "example.com", rcode: 3, answerTTLs: [],
            authoritySOA: (ttl: 900, minimum: 30),
            soaRDATAShortfall: 4
        )

        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: zeroRecordTTL))
        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: zeroMinimum))
        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: truncatedRDATA))
    }

    func testNegativeEntryStoresReplaysAndExpires() throws {
        let cache = DNSResponseCache()
        let storedQuery = Self.dnsQuery(id: 0xAAAA, domain: "gone.example.com")
        let askingQuery = Self.dnsQuery(id: 0x1234, domain: "gone.example.com")
        let nxdomain = Self.dnsResponse(
            id: 0xAAAA, domain: "gone.example.com", rcode: 3, answerTTLs: [],
            authoritySOA: (ttl: 900, minimum: 30)
        )
        let key = try XCTUnwrap(DNSCacheKey(resolverIdentifier: "doh:one", dnsPayload: storedQuery))

        cache.store(nxdomain, for: key, now: now)

        let hit = try XCTUnwrap(cache.cachedResponse(for: key, query: askingQuery, now: now))
        XCTAssertEqual(hit[0], 0x12)
        XCTAssertEqual(hit[1], 0x34)
        // The replayed packet carries the CLAMPED TTLs (here min(900, 30) = 30), not the
        // upstream SOA values - otherwise the downstream stub resolver would negative-
        // cache the NXDOMAIN for the full upstream TTL, defeating the clamp.
        XCTAssertEqual(
            hit.dropFirst(2),
            DNSWireMessage.cappingAnswerTTLs(in: nxdomain, to: 30).dropFirst(2)
        )
        XCTAssertNil(
            cache.cachedResponse(for: key, query: askingQuery, now: now.addingTimeInterval(31)),
            "A negative entry expires at its SOA-derived TTL."
        )
    }

    func testNegativeReplayNeverCarriesTTLsAboveTheSixtySecondClamp() throws {
        let cache = DNSResponseCache()
        let query = Self.dnsQuery(id: 1, domain: "transient.example.com")
        // Upstream pins the NXDOMAIN for an hour; the replayed packet must not.
        let longNXDOMAIN = Self.dnsResponse(
            id: 1, domain: "transient.example.com", rcode: 3, answerTTLs: [],
            authoritySOA: (ttl: 3_600, minimum: 3_600)
        )
        let key = try XCTUnwrap(DNSCacheKey(resolverIdentifier: "doh:one", dnsPayload: query))

        cache.store(longNXDOMAIN, for: key, now: now)

        let hit = try XCTUnwrap(cache.cachedResponse(for: key, query: query, now: now))
        XCTAssertEqual(
            hit.dropFirst(2),
            DNSWireMessage.cappingAnswerTTLs(in: longNXDOMAIN, to: 60).dropFirst(2)
        )
        XCTAssertNotEqual(
            hit.dropFirst(2),
            longNXDOMAIN.dropFirst(2),
            "The hour-long upstream SOA TTL must have been rewritten before storage."
        )
    }

    func testCacheTTLIgnoresOPTRecords() {
        // OPT (type 41) TTL bytes carry EDNS flags, not a TTL: a zero "TTL"
        // OPT must not veto caching and must not contribute to the minimum.
        let withOPT = Self.dnsResponse(
            id: 0,
            domain: "example.com",
            answerTTLs: [120],
            includesOPTAdditional: true
        )
        let optOnlyAnswer = Self.dnsResponse(
            id: 0,
            domain: "example.com",
            answerTTLs: [],
            optAnswer: true
        )

        XCTAssertEqual(DNSResponseCachePolicy.cacheTTL(for: withOPT), 120)
        XCTAssertNil(
            DNSResponseCachePolicy.cacheTTL(for: optOnlyAnswer),
            "A response whose only records are OPT has no usable TTL."
        )
    }

    func testCacheTTLConsidersAuthorityAndAdditionalRecords() {
        let authorityShortens = Self.dnsResponse(
            id: 0,
            domain: "example.com",
            answerTTLs: [120],
            authorityTTLs: [30]
        )
        let additionalZeroTTLVetoes = Self.dnsResponse(
            id: 0,
            domain: "example.com",
            answerTTLs: [120],
            additionalNonOPTTTLs: [0]
        )

        XCTAssertEqual(DNSResponseCachePolicy.cacheTTL(for: authorityShortens), 30)
        XCTAssertNil(
            DNSResponseCachePolicy.cacheTTL(for: additionalZeroTTLVetoes),
            "A zero-TTL non-OPT record anywhere in the response vetoes caching."
        )
    }

    func testCacheTTLRejectsMalformedWireData() {
        // Compression-pointer loop: the question name points at itself.
        var pointerLoop = Data()
        Self.appendUInt16(0, to: &pointerLoop)
        Self.appendUInt16(0x8180, to: &pointerLoop)
        Self.appendUInt16(1, to: &pointerLoop)
        Self.appendUInt16(1, to: &pointerLoop)
        Self.appendUInt16(0, to: &pointerLoop)
        Self.appendUInt16(0, to: &pointerLoop)
        pointerLoop.append(contentsOf: [0xC0, 0x0C])
        Self.appendUInt16(1, to: &pointerLoop)
        Self.appendUInt16(1, to: &pointerLoop)
        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: pointerLoop))

        // Compression pointer beyond the end of the message.
        var pointerPastEnd = pointerLoop
        pointerPastEnd[13] = 0xF0
        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: pointerPastEnd))

        // ANCOUNT overstates the records actually present.
        var overstatedAnswerCount = Self.dnsResponse(id: 0, domain: "example.com", answerTTLs: [120])
        overstatedAnswerCount[7] = 2
        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: overstatedAnswerCount))

        // RDLENGTH overruns the buffer (single trailing answer: rdlength
        // lives 6 bytes from the end).
        var rdlengthOverrun = Self.dnsResponse(id: 0, domain: "example.com", answerTTLs: [120])
        rdlengthOverrun[rdlengthOverrun.count - 6] = 0x00
        rdlengthOverrun[rdlengthOverrun.count - 5] = 0xC8
        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: rdlengthOverrun))

        // Label length claims more bytes than the message holds.
        var labelOverrun = Data()
        Self.appendUInt16(0, to: &labelOverrun)
        Self.appendUInt16(0x8180, to: &labelOverrun)
        Self.appendUInt16(1, to: &labelOverrun)
        Self.appendUInt16(1, to: &labelOverrun)
        Self.appendUInt16(0, to: &labelOverrun)
        Self.appendUInt16(0, to: &labelOverrun)
        labelOverrun.append(contentsOf: [0x3F, 0x61, 0x62])
        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: labelOverrun))
    }

    // MARK: - DNSResponseCache

    func testHitRewritesTransactionIDForTheAskingQuery() throws {
        let cache = DNSResponseCache()
        let storedQuery = Self.dnsQuery(id: 0xABCD, domain: "example.com")
        let askingQuery = Self.dnsQuery(id: 0x5678, domain: "example.com")
        let response = Self.dnsResponse(id: 0xABCD, domain: "example.com", answerTTLs: [120])
        let key = try XCTUnwrap(DNSCacheKey(resolverIdentifier: "doh:one", dnsPayload: storedQuery))

        cache.store(response, for: key, now: now)
        let hit = try XCTUnwrap(cache.cachedResponse(for: key, query: askingQuery, now: now))

        XCTAssertEqual(hit[0], 0x56)
        XCTAssertEqual(hit[1], 0x78)
        XCTAssertEqual(hit.dropFirst(2), response.dropFirst(2))
    }

    func testExpiredEntriesMissAndAreEvicted() throws {
        let cache = DNSResponseCache()
        let query = Self.dnsQuery(id: 1, domain: "example.com")
        let response = Self.dnsResponse(id: 1, domain: "example.com", answerTTLs: [120])
        let key = try XCTUnwrap(DNSCacheKey(resolverIdentifier: "doh:one", dnsPayload: query))

        cache.store(response, for: key, now: now)

        XCTAssertNotNil(cache.cachedResponse(for: key, query: query, now: now.addingTimeInterval(119)))
        XCTAssertNil(cache.cachedResponse(for: key, query: query, now: now.addingTimeInterval(121)))
        XCTAssertEqual(cache.count, 0, "An expired entry is evicted on the missing lookup.")
    }

    func testUncacheableResponsesAreNotStored() throws {
        let cache = DNSResponseCache()
        let query = Self.dnsQuery(id: 1, domain: "example.com")
        // Empty answers with no authority SOA: neither positively nor negatively cacheable.
        let bareNODATA = Self.dnsResponse(id: 1, domain: "example.com", answerTTLs: [])
        let key = try XCTUnwrap(DNSCacheKey(resolverIdentifier: "doh:one", dnsPayload: query))

        cache.store(bareNODATA, for: key, now: now)

        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.cachedResponse(for: key, query: query, now: now))
    }

    func testTrimEvictsEarliestExpiringEntriesBeyondLimit() throws {
        let cache = DNSResponseCache(maximumEntryCount: 2, cleanupInterval: 3_600)
        var keys: [DNSCacheKey] = []
        for (index, ttl) in [UInt32(100), 200, 300].enumerated() {
            let query = Self.dnsQuery(id: UInt16(index + 1), domain: "host\(index).example.com")
            let response = Self.dnsResponse(id: 0, domain: "host\(index).example.com", answerTTLs: [ttl])
            let key = try XCTUnwrap(DNSCacheKey(resolverIdentifier: "doh:one", dnsPayload: query))
            keys.append(key)
            cache.store(response, for: key, now: now)
        }

        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(
            cache.cachedResponse(for: keys[0], query: Self.dnsQuery(id: 9, domain: "host0.example.com"), now: now),
            "The earliest-expiring entry is trimmed first."
        )
        XCTAssertNotNil(cache.cachedResponse(for: keys[1], query: Self.dnsQuery(id: 9, domain: "host1.example.com"), now: now))
        XCTAssertNotNil(cache.cachedResponse(for: keys[2], query: Self.dnsQuery(id: 9, domain: "host2.example.com"), now: now))
    }

    func testTrimKeepsLongestLivedEntriesUnderSustainedOverflow() throws {
        // Sustained inserts past capacity must hold the table at its cap while always
        // evicting the soonest-to-expire entry first. This exercises the linear-pass
        // trim that replaced the per-write full sort.
        let cache = DNSResponseCache(maximumEntryCount: 3, cleanupInterval: 3_600)
        // Shuffled, distinct TTLs (all within the 300s cache cap so expiries stay
        // distinct) so eviction can't be an artifact of insertion order.
        let ttls: [UInt32] = [250, 50, 200, 100, 300, 150]
        var entries: [(ttl: UInt32, domain: String, key: DNSCacheKey)] = []
        for (index, ttl) in ttls.enumerated() {
            let domain = "host\(index).example.com"
            let query = Self.dnsQuery(id: UInt16(index + 1), domain: domain)
            let response = Self.dnsResponse(id: 0, domain: domain, answerTTLs: [ttl])
            let key = try XCTUnwrap(DNSCacheKey(resolverIdentifier: "doh:one", dnsPayload: query))
            entries.append((ttl, domain, key))
            cache.store(response, for: key, now: now)
        }

        XCTAssertEqual(cache.count, 3, "The linear-pass trim holds the cache at its cap.")

        let survivingTTLs = Set(ttls.sorted(by: >).prefix(3)) // 300, 250, 200
        for entry in entries {
            let hit = cache.cachedResponse(
                for: entry.key,
                query: Self.dnsQuery(id: 99, domain: entry.domain),
                now: now
            )
            if survivingTTLs.contains(entry.ttl) {
                XCTAssertNotNil(hit, "TTL \(entry.ttl)s (longest-lived) should be retained.")
            } else {
                XCTAssertNil(hit, "TTL \(entry.ttl)s should be evicted earliest-expiring-first.")
            }
        }
    }

    func testStoreSweepsExpiredEntriesAfterCleanupInterval() throws {
        let cache = DNSResponseCache(maximumEntryCount: 512, cleanupInterval: 30)
        let queryA = Self.dnsQuery(id: 1, domain: "a.example.com")
        let queryB = Self.dnsQuery(id: 2, domain: "b.example.com")
        let keyA = try XCTUnwrap(DNSCacheKey(resolverIdentifier: "doh:one", dnsPayload: queryA))
        let keyB = try XCTUnwrap(DNSCacheKey(resolverIdentifier: "doh:one", dnsPayload: queryB))

        cache.store(Self.dnsResponse(id: 1, domain: "a.example.com", answerTTLs: [100]), for: keyA, now: now)
        // 150s later: A has expired and the 30s sweep throttle has elapsed —
        // storing B must sweep A out without A ever being looked up again.
        cache.store(
            Self.dnsResponse(id: 2, domain: "b.example.com", answerTTLs: [100]),
            for: keyB,
            now: now.addingTimeInterval(150)
        )

        XCTAssertEqual(cache.count, 1)
    }

    func testStoreSweepThrottleRetainsExpiredEntriesWithinInterval() throws {
        let cache = DNSResponseCache(maximumEntryCount: 512, cleanupInterval: 30)
        let queryA = Self.dnsQuery(id: 1, domain: "a.example.com")
        let queryB = Self.dnsQuery(id: 2, domain: "b.example.com")
        let keyA = try XCTUnwrap(DNSCacheKey(resolverIdentifier: "doh:one", dnsPayload: queryA))
        let keyB = try XCTUnwrap(DNSCacheKey(resolverIdentifier: "doh:one", dnsPayload: queryB))

        cache.store(Self.dnsResponse(id: 1, domain: "a.example.com", answerTTLs: [5]), for: keyA, now: now)
        // 10s later: A has expired but the sweep ran at the first store, so
        // the 30s throttle holds the expired entry until the next window.
        cache.store(
            Self.dnsResponse(id: 2, domain: "b.example.com", answerTTLs: [100]),
            for: keyB,
            now: now.addingTimeInterval(10)
        )

        XCTAssertEqual(cache.count, 2)
    }

    func testRemoveAllClearsEverything() throws {
        let cache = DNSResponseCache()
        let query = Self.dnsQuery(id: 1, domain: "example.com")
        let response = Self.dnsResponse(id: 1, domain: "example.com", answerTTLs: [120])
        let key = try XCTUnwrap(DNSCacheKey(resolverIdentifier: "doh:one", dnsPayload: query))
        cache.store(response, for: key, now: now)

        cache.removeAll()

        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.cachedResponse(for: key, query: query, now: now))
    }

    // MARK: - Wire fixtures

    private static func dnsQuery(id: UInt16, domain: String) -> Data {
        var data = Data()
        appendUInt16(id, to: &data)
        appendUInt16(0x0100, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendQuestion(domain: domain, to: &data)
        return data
    }

    private static func dnsResponse(
        id: UInt16,
        domain: String,
        rcode: UInt16 = 0,
        answerTTLs: [UInt32],
        authoritySOA: (ttl: UInt32, minimum: UInt32)? = nil,
        additionalSOA: (ttl: UInt32, minimum: UInt32)? = nil,
        soaRDATAShortfall: Int = 0,
        authorityTTLs: [UInt32] = [],
        additionalNonOPTTTLs: [UInt32] = [],
        includesOPTAdditional: Bool = false,
        optAnswer: Bool = false
    ) -> Data {
        var data = Data()
        appendUInt16(id, to: &data)
        appendUInt16(0x8180 | rcode, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(UInt16(answerTTLs.count) + (optAnswer ? 1 : 0), to: &data)
        appendUInt16(UInt16(authorityTTLs.count) + (authoritySOA == nil ? 0 : 1), to: &data)
        appendUInt16(
            UInt16(additionalNonOPTTTLs.count)
                + (additionalSOA == nil ? 0 : 1)
                + (includesOPTAdditional ? 1 : 0),
            to: &data
        )
        appendQuestion(domain: domain, to: &data)

        for ttl in answerTTLs {
            appendARecord(ttl: ttl, to: &data)
        }

        if let authoritySOA {
            appendSOARecord(
                ttl: authoritySOA.ttl,
                minimum: authoritySOA.minimum,
                rdataShortfall: soaRDATAShortfall,
                to: &data
            )
        }

        for ttl in authorityTTLs + additionalNonOPTTTLs {
            appendARecord(ttl: ttl, to: &data)
        }

        if let additionalSOA {
            appendSOARecord(ttl: additionalSOA.ttl, minimum: additionalSOA.minimum, to: &data)
        }

        if optAnswer {
            appendOPTRecord(to: &data)
        }

        if includesOPTAdditional {
            appendOPTRecord(to: &data)
        }

        return data
    }

    private static func appendARecord(ttl: UInt32, to data: inout Data) {
        data.append(contentsOf: [0xC0, 0x0C])
        appendUInt16(1, to: &data)
        appendUInt16(1, to: &data)
        appendUInt32(ttl, to: &data)
        appendUInt16(4, to: &data)
        data.append(contentsOf: [1, 2, 3, 4])
    }

    /// SOA in the authority section: compressed MNAME (question pointer), root
    /// RNAME, then serial/refresh/retry/expire/minimum. `rdataShortfall`
    /// truncates RDLENGTH below the real field length for malformed-wire cases.
    private static func appendSOARecord(
        ttl: UInt32,
        minimum: UInt32,
        rdataShortfall: Int = 0,
        to data: inout Data
    ) {
        data.append(contentsOf: [0xC0, 0x0C])
        appendUInt16(6, to: &data)
        appendUInt16(1, to: &data)
        appendUInt32(ttl, to: &data)
        appendUInt16(UInt16(23 - rdataShortfall), to: &data)
        data.append(contentsOf: [0xC0, 0x0C])
        data.append(0x00)
        appendUInt32(1, to: &data)
        appendUInt32(7_200, to: &data)
        appendUInt32(900, to: &data)
        appendUInt32(1_209_600, to: &data)
        appendUInt32(minimum, to: &data)
        if rdataShortfall > 0 {
            data.removeLast(rdataShortfall)
        }
    }

    private static func appendOPTRecord(to data: inout Data) {
        data.append(0x00)
        appendUInt16(41, to: &data)
        appendUInt16(4096, to: &data)
        appendUInt32(0, to: &data)
        appendUInt16(0, to: &data)
    }

    private static func appendQuestion(domain: String, to data: inout Data) {
        for label in domain.split(separator: ".") {
            let bytes = Array(label.utf8)
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(0)
        appendUInt16(1, to: &data)
        appendUInt16(1, to: &data)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
