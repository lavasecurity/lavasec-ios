import XCTest
@testable import LavaSecCore

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
        let noAnswers = Self.dnsResponse(id: 0, domain: "example.com", answerTTLs: [])
        let zeroTTL = Self.dnsResponse(id: 0, domain: "example.com", answerTTLs: [0])
        let truncatedHeader = Data([0x00, 0x00, 0x81, 0x80])

        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: noAnswers))
        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: zeroTTL))
        XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: truncatedHeader))
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
        let servfailLike = Self.dnsResponse(id: 1, domain: "example.com", answerTTLs: [])
        let key = try XCTUnwrap(DNSCacheKey(resolverIdentifier: "doh:one", dnsPayload: query))

        cache.store(servfailLike, for: key, now: now)

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
        answerTTLs: [UInt32],
        authorityTTLs: [UInt32] = [],
        additionalNonOPTTTLs: [UInt32] = [],
        includesOPTAdditional: Bool = false,
        optAnswer: Bool = false
    ) -> Data {
        var data = Data()
        appendUInt16(id, to: &data)
        appendUInt16(0x8180, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(UInt16(answerTTLs.count) + (optAnswer ? 1 : 0), to: &data)
        appendUInt16(UInt16(authorityTTLs.count), to: &data)
        appendUInt16(UInt16(additionalNonOPTTTLs.count) + (includesOPTAdditional ? 1 : 0), to: &data)
        appendQuestion(domain: domain, to: &data)

        for ttl in answerTTLs + authorityTTLs + additionalNonOPTTTLs {
            data.append(contentsOf: [0xC0, 0x0C])
            appendUInt16(1, to: &data)
            appendUInt16(1, to: &data)
            appendUInt32(ttl, to: &data)
            appendUInt16(4, to: &data)
            data.append(contentsOf: [1, 2, 3, 4])
        }

        if optAnswer {
            appendOPTRecord(to: &data)
        }

        if includesOPTAdditional {
            appendOPTRecord(to: &data)
        }

        return data
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
