import Foundation
import XCTest
@testable import LavaSecDNS
@testable import LavaSecCore
@testable import LavaSecKit

final class DNSMessageTests: XCTestCase {
    func testQuestionFailureDiagnosticsUseOnlyFixedCategories() {
        let cases: [(DNSMessageError, String)] = [
            (.packetTooShort, "packet-too-short"),
            (.notAQuery, "not-a-query"),
            (.noQuestion, "no-question"),
            (.unsupportedQuestionCount, "unsupported-question-count"),
            (.malformedQuestion, "malformed-question"),
            (.compressedQuestionName, "compressed-question-name"),
            (.invalidDomain, "invalid-domain"),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(DNSMessage.questionParseFailureCategory(error), expected)
        }
        let untrustedError = NSError(domain: "private.example", code: 1,
                                     userInfo: [NSLocalizedDescriptionKey: "private query content"])
        XCTAssertEqual(DNSMessage.questionParseFailureCategory(untrustedError), "unknown")
        XCTAssertThrowsError(try DNSMessage.parseQuestion(from: Data([0]))) { error in
            XCTAssertEqual(DNSMessage.questionParseFailureCategory(error), "packet-too-short")
        }
    }

    private func untrustedQuestion(_ domain: String) throws -> DNSQuestion {
        try DNSQuestion(transactionID: 42, domain: domain, recordType: .a,
                    rawRecordType: 1, questionRange: 12..<31)
    }

    func testQuestionConstructionRejectsInvalidDomains() {
        for domain in ["", ".", "localhost", "1.2.3.4", "bad label.example", "-bad.example", "good..example"] {
            XCTAssertThrowsError(try untrustedQuestion(domain), domain) { error in
                XCTAssertEqual(error as? DNSMessageError, .invalidDomain)
            }
        }
    }

    func testQuestionConstructionKeepsOnlyValidatedCanonicalDomain() throws {
        let question = try untrustedQuestion("BÜCHER.Example.")
        XCTAssertEqual(question.domain, "BÜCHER.Example.")
        XCTAssertEqual(question.normalizedDomain, "xn--bcher-kva.example")
    }

    func testRecordTypeRawValuesAndCodableContract() throws {
        let knownCases: [(type: DNSRecordType, rawValue: UInt16)] = [
            (.unknown, 0),
            (.a, 1),
            (.txt, 16),
            (.aaaa, 28),
            (.srv, 33),
            (.svcb, 64),
            (.https, 65),
        ]

        for knownCase in knownCases {
            XCTAssertEqual(knownCase.type.rawValue, knownCase.rawValue)
            XCTAssertEqual(DNSRecordType(rawValue: knownCase.rawValue), knownCase.type)

            let encoded = try JSONEncoder().encode(knownCase.type)
            XCTAssertEqual(try JSONDecoder().decode(DNSRecordType.self, from: encoded), knownCase.type)
        }

        for unrecognizedRawValue: UInt16 in [2, 63, 66, .max] {
            XCTAssertEqual(DNSRecordType(rawValue: unrecognizedRawValue), .unknown)
        }
    }

    func testParsesQuestion() throws {
        let query = makeQuery(domain: "ads.example.com", type: 1)
        let question = try DNSMessage.parseQuestion(from: query)

        XCTAssertEqual(question.transactionID, 0x1234)
        XCTAssertEqual(question.domain, "ads.example.com")
        XCTAssertEqual(question.recordType, .a)
    }

    func testRejectsMultiQuestionQueries() throws {
        var query = makeQuery(domain: "allowed.example.com", type: 1)
        query[5] = 0x02
        query.appendQuestion(domain: "blocked.example.com", type: 1)

        XCTAssertThrowsError(try DNSMessage.parseQuestion(from: query))
    }

    func testBlockedAResponseUsesZeroAddress() throws {
        let query = makeQuery(domain: "ads.example.com", type: 1)
        let response = try DNSMessage.blockedResponse(for: query, ttl: 60)

        XCTAssertEqual(response[0], 0x12)
        XCTAssertEqual(response[1], 0x34)
        XCTAssertEqual(response.suffix(4), Data([0, 0, 0, 0]))
    }

    func testBlockedHTTPSResponseHasNoAnswers() throws {
        let query = makeQuery(domain: "ads.example.com", type: 65)
        let response = try DNSMessage.blockedResponse(for: query, ttl: 60)

        XCTAssertEqual(response[6], 0)
        XCTAssertEqual(response[7], 0)
    }

    func testLoopbackBlockPreservesQuestionAndReturnsIPv4Loopback() throws {
        let query = makeQuery(domain: "ads.example.com", type: 1)
        let response = try DNSMessage.blockedResponse(for: query, ttl: 1, addressMode: .loopback)
        XCTAssertEqual(response.prefix(2), query.prefix(2))
        XCTAssertEqual(response.subdata(in: 12..<query.count), query.dropFirst(12))
        XCTAssertEqual(readUInt16(response, at: 2), 0x8180)
        XCTAssertEqual(readUInt16(response, at: 6), 1)
        XCTAssertEqual(response.suffix(14), Data([0, 1, 0, 1, 0, 0, 0, 1, 0, 4, 127, 0, 0, 1]))
    }

    func testLoopbackBlockReturnsIPv6LoopbackForValidatedQuestion() throws {
        let query = makeQuery(domain: "ads.example.com", type: 28)
        let question = try DNSMessage.parseQuestion(from: query)
        let response = try DNSMessage.blockedResponse(
            for: query, question: question, ttl: 1, addressMode: .loopback)
        XCTAssertEqual(readUInt16(response, at: 6), 1)
        XCTAssertEqual(response.suffix(16), Data(repeating: 0, count: 15) + Data([1]))
        XCTAssertEqual(response.suffix(26).prefix(10), Data([0, 28, 0, 1, 0, 0, 0, 1, 0, 16]))
    }

    func testLoopbackDoesNotInventAddressRecordsForOtherTypes() throws {
        for type: UInt16 in [16, 33, 64, 65, 255] {
            let query = makeQuery(domain: "ads.example.com", type: type)
            let response = try DNSMessage.blockedResponse(for: query, addressMode: .loopback)
            XCTAssertEqual(response, try DNSMessage.blockedResponse(for: query))
            XCTAssertEqual(readUInt16(response, at: 6), 0)
        }
    }

    func testNegativeBlockModesAreCacheableForEveryQuestionType() throws {
        for mode in [DNSBlockedAddressMode.nxdomain, .nodata] {
            for type: UInt16 in [1, 28, 65, 64, 16, 33, 255, .max] {
                let query = makeQuery(domain: "www.blocked.example", type: type)
                let question = try DNSMessage.parseQuestion(from: query)
                let response = try DNSMessage.blockedResponse(
                    for: query, question: question, ttl: 7, addressMode: mode)
                XCTAssertEqual(response, try DNSMessage.blockedResponse(
                    for: query, ttl: 7, addressMode: mode))
                XCTAssertTrue(DNSWireMessage.isValidResponse(response, matching: query))
                XCTAssertTrue(DNSResolverSmokeProbe.indicatesServedAnswer(response))
                XCTAssertEqual(readUInt16(response, at: 2), mode == .nxdomain ? 0x8583 : 0x8580)
                XCTAssertEqual(Array(response[4..<12]), [0, 1, 0, 0, 0, 1, 0, 0])
                XCTAssertEqual(DNSResponseCachePolicy.cacheTTL(for: response), 7)

                // Decode the authority record independently: parent zone, SOA/IN, TTL,
                // complete RDATA length, then two reserved names and five 32-bit fields.
                let rr = query.count
                let parent = Int(readUInt16(response, at: rr) & 0x3FFF)
                XCTAssertEqual(parent, 16) // skip the wire label "www"
                XCTAssertEqual(Array(response[parent..<(parent + 8)]), [7] + Array("blocked".utf8))
                XCTAssertEqual(Array(response[rr..<(rr + 12)]), [0xC0, 16, 0, 6, 0, 1, 0, 0, 0, 7, 0, 59])
                var soa = Data([4]) + Data("lava".utf8) + Data([7]) + Data("invalid".utf8) + Data([0])
                soa.append(Data([10]) + Data("hostmaster".utf8) + Data([4]) + Data("lava".utf8)
                    + Data([7]) + Data("invalid".utf8) + Data([0]))
                soa.append(contentsOf: [0, 0, 0, 1, 0, 0, 14, 16, 0, 0, 2, 88, 0, 1, 81, 128, 0, 0, 0, 7])
                XCTAssertEqual(response.suffix(from: rr + 12), soa)
            }
        }
    }

    func testNegativeBlockExpiresAndDoesNotClaimDNSSECAuthentication() throws {
        for mode in [DNSBlockedAddressMode.nxdomain, .nodata] {
            var query = makeQuery(domain: "blocked.example", type: 65)
            query[2] = 0 // RD off
            query[3] = 0x30 // AD and CD must not become authenticated policy data
            let response = try DNSMessage.blockedResponse(for: query, ttl: 1, addressMode: mode)
            XCTAssertEqual(readUInt16(response, at: 2), mode == .nxdomain ? 0x8483 : 0x8480)
            let key = try XCTUnwrap(DNSCacheKey(resolverIdentifier: "local-policy", dnsPayload: query))
            let cache = DNSResponseCache()
            let now = Date(timeIntervalSinceReferenceDate: 100)
            cache.store(response, for: key, now: now)
            XCTAssertNotNil(cache.cachedResponse(for: key, query: query, now: now))
            XCTAssertNil(cache.cachedResponse(for: key, query: query, now: now.addingTimeInterval(2)))
            XCTAssertNil(DNSResponseCachePolicy.cacheTTL(for: try DNSMessage.blockedResponse(
                for: query, ttl: 0, addressMode: mode)))
        }
    }

    func testReachableAddressComparisonIsRestrictedAndDualStack() throws {
        for host in ["www.oracle.com", "www.linkedin.com"] {
            let mode = DNSBlockedAddressMode.cloudflare.limitedToQAProbeDomain(host)
            XCTAssertEqual(mode, .cloudflare)
            for type: UInt16 in [1, 28] {
                let query = makeQuery(domain: host, type: type)
                let response = try DNSMessage.blockedResponse(for: query, ttl: 1, addressMode: mode)
                XCTAssertEqual(readUInt16(response, at: 2), 0x8180)
                XCTAssertEqual(readUInt16(response, at: 6), 1)
                let address = type == 1 ? Data([1, 1, 1, 1])
                    : Data([0x26, 0x06, 0x47, 0, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x11])
                XCTAssertEqual(response.suffix(address.count), address)
                XCTAssertEqual(DNSResponseCachePolicy.cacheTTL(for: response), 1)
            }
            let https = makeQuery(domain: host, type: 65)
            XCTAssertEqual(try DNSMessage.blockedResponse(for: https, addressMode: mode),
                           try DNSMessage.blockedResponse(for: https))
        }
        for host in ["oracle.com", "ads.example.com", "www.linkedin.com.example.com", "www.iana.org"] {
            XCTAssertEqual(DNSBlockedAddressMode.cloudflare.limitedToQAProbeDomain(host), .unspecified)
        }
        XCTAssertEqual(DNSBlockedAddressMode.nodata.limitedToQAProbeDomain("ads.example.com"), .nodata)
    }

    // MARK: - Adversarial question parsing
    //
    // `parseQuestion` is the first parser attacker-controlled query bytes reach after
    // IPv4/UDP validation, so every rejection path gets an executable fixture here —
    // mirroring the malformed-input coverage style of IPv4UDPDNSPacketTests.

    func testRejectsPacketShorterThanHeader() {
        for byteCount in [0, 1, 11] {
            XCTAssertThrowsError(try DNSMessage.parseQuestion(from: Data(count: byteCount))) { error in
                XCTAssertEqual(error as? DNSMessageError, .packetTooShort)
            }
        }
    }

    func testRejectsResponsesPresentedAsQueries() {
        var query = makeQuery(domain: "ads.example.com", type: 1)
        query[2] |= 0x80

        XCTAssertThrowsError(try DNSMessage.parseQuestion(from: query)) { error in
            XCTAssertEqual(error as? DNSMessageError, .notAQuery)
        }
    }

    func testRejectsZeroQuestionCount() {
        var query = makeQuery(domain: "ads.example.com", type: 1)
        query[4] = 0
        query[5] = 0

        XCTAssertThrowsError(try DNSMessage.parseQuestion(from: query)) { error in
            XCTAssertEqual(error as? DNSMessageError, .noQuestion)
        }
    }

    func testRejectsHighQuestionCount() {
        // Symmetric high boundary to testRejectsZeroQuestionCount: QDCOUNT == 0 is
        // .noQuestion, QDCOUNT > 1 is .unsupportedQuestionCount. The `questionCount == 1`
        // gate rejects before the question body is walked, so a header claiming two
        // questions throws even though only one is encoded. (OCR review on the 1.2.4 sync)
        var query = makeQuery(domain: "ads.example.com", type: 1)
        query[4] = 0
        query[5] = 2

        XCTAssertThrowsError(try DNSMessage.parseQuestion(from: query)) { error in
            XCTAssertEqual(error as? DNSMessageError, .unsupportedQuestionCount)
        }
    }

    func testRejectsCompressedQuestionName() {
        // A 0xC0-prefixed pointer in the QUESTION section: legal in responses, but a
        // query whose own question needs decompression is malformed for this parser
        // and must be refused before any pointer chase can start.
        var query = Data([0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        query.append(contentsOf: [0xC0, 0x0C])
        query.append(contentsOf: [0x00, 0x01, 0x00, 0x01])

        XCTAssertThrowsError(try DNSMessage.parseQuestion(from: query)) { error in
            XCTAssertEqual(error as? DNSMessageError, .compressedQuestionName)
        }
    }

    func testRejectsMalformedQuestionEncodings() {
        let header: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

        var overlongLabel = Data(header)
        overlongLabel.append(64)
        overlongLabel.append(contentsOf: Array(repeating: UInt8(ascii: "a"), count: 64))
        overlongLabel.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])

        var labelOverrunsBuffer = Data(header)
        labelOverrunsBuffer.append(5)
        labelOverrunsBuffer.append(contentsOf: [UInt8(ascii: "a"), UInt8(ascii: "b")])

        var nameNeverTerminated = Data(header)
        nameNeverTerminated.append(3)
        nameNeverTerminated.append(contentsOf: [UInt8(ascii: "a"), UInt8(ascii: "d"), UInt8(ascii: "s")])

        var truncatedTypeAndClass = Data(header)
        truncatedTypeAndClass.append(3)
        truncatedTypeAndClass.append(contentsOf: [UInt8(ascii: "a"), UInt8(ascii: "d"), UInt8(ascii: "s")])
        truncatedTypeAndClass.append(contentsOf: [0x00, 0x00, 0x01])

        var invalidUTF8Label = Data(header)
        invalidUTF8Label.append(2)
        invalidUTF8Label.append(contentsOf: [0xC3, 0x28])
        invalidUTF8Label.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])

        let fixtures: [(name: String, query: Data)] = [
            ("label length above 63", overlongLabel),
            ("label overruns buffer", labelOverrunsBuffer),
            ("name never terminated", nameNeverTerminated),
            ("truncated qtype/qclass", truncatedTypeAndClass),
            ("invalid UTF-8 label", invalidUTF8Label),
        ]

        for fixture in fixtures {
            XCTAssertThrowsError(try DNSMessage.parseQuestion(from: fixture.query), fixture.name) { error in
                XCTAssertEqual(error as? DNSMessageError, .malformedQuestion, fixture.name)
            }
        }
    }

    func testRejectsDomainsThatFailNormalization() {
        // Well-formed wire encodings whose decoded domain DomainName refuses: the root
        // query (empty), a single label, and an IPv4 literal. These parse but must not
        // reach filtering with a non-canonical domain.
        var rootQuery = Data([0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        rootQuery.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])

        let fixtures: [(name: String, query: Data)] = [
            ("root query", rootQuery),
            ("single label", makeQuery(domain: "localhost", type: 1)),
            ("IPv4 literal", makeQuery(domain: "127.0.0.1", type: 1)),
        ]

        for fixture in fixtures {
            XCTAssertThrowsError(try DNSMessage.parseQuestion(from: fixture.query), fixture.name) { error in
                XCTAssertEqual(error as? DNSMessageError, .invalidDomain, fixture.name)
            }
        }
    }

    func testUnsupportedRecordTypeParsesAsUnknownAndPreservesRawValue() throws {
        let query = makeQuery(domain: "ads.example.com", type: 255)
        let question = try DNSMessage.parseQuestion(from: query)

        XCTAssertEqual(question.recordType, .unknown)
        XCTAssertEqual(question.rawRecordType, 255)
    }

    // MARK: - Blocked-response synthesis

    func testBlockedAAAAResponseUsesSixteenZeroByteAddress() throws {
        let query = makeQuery(domain: "ads.example.com", type: 28)
        let response = try DNSMessage.blockedResponse(for: query, ttl: 300)

        XCTAssertEqual(readUInt16(response, at: 6), 1, "AAAA blocks answer with one zeroed address record")
        XCTAssertEqual(response.suffix(16), Data(repeating: 0, count: 16))

        // The answer record echoes the raw AAAA type, class IN, the caller's TTL
        // (big-endian), and RDLENGTH 16 ahead of the zeroed address.
        let fixedAnswerFields = response.suffix(26).prefix(10)
        XCTAssertEqual(fixedAnswerFields, Data([0x00, 0x1C, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x10]))
        XCTAssertEqual(response.suffix(28).prefix(2), Data([0xC0, 0x0C]), "answer name compresses to the echoed question")
    }

    func testBlockedNonAddressResponsesCarryNoAnswerRecords() throws {
        // txt, srv, svcb, https, and unknown types block with an empty answer section — a
        // zeroed address would be a wrong-typed RDATA, and NXDOMAIN would poison
        // negative caches for the whole name. Type 65 (HTTPS) has its own case in the
        // non-address switch, so it is pinned here alongside svcb (OCR review on the 1.2.4 sync).
        for rawType: UInt16 in [16, 33, 64, 65, 255] {
            let query = makeQuery(domain: "ads.example.com", type: rawType)
            let response = try DNSMessage.blockedResponse(for: query, ttl: 60)

            XCTAssertEqual(readUInt16(response, at: 4), 1, "question is echoed for type \(rawType)")
            XCTAssertEqual(readUInt16(response, at: 6), 0, "no answer records for type \(rawType)")
            XCTAssertEqual(response.count, 12 + (query.count - 12), "response is header + echoed question for type \(rawType)")
            XCTAssertEqual(response.suffix(from: 12), query.suffix(from: 12), "question bytes echo verbatim for type \(rawType)")
        }
    }

    func testBlockedResponseEchoesRecursionDesiredFlag() throws {
        var recursionDesired = makeQuery(domain: "ads.example.com", type: 1)
        recursionDesired[2] = 0x01
        recursionDesired[3] = 0x00
        XCTAssertEqual(readUInt16(try DNSMessage.blockedResponse(for: recursionDesired), at: 2), 0x8180)

        var recursionNotDesired = makeQuery(domain: "ads.example.com", type: 1)
        recursionNotDesired[2] = 0x00
        recursionNotDesired[3] = 0x00
        XCTAssertEqual(readUInt16(try DNSMessage.blockedResponse(for: recursionNotDesired), at: 2), 0x8080)
    }

    func testBlockedResponseRejectsQuestionRangeOutsideQuery() throws {
        let query = makeQuery(domain: "ads.example.com", type: 1)
        let parsed = try DNSMessage.parseQuestion(from: query)

        // A question whose recorded range no longer fits the query (e.g. stale state
        // paired with a different packet) must throw instead of slicing out of bounds.
        for staleRange in [12..<(query.count + 8), -1..<4] {
            let staleQuestion = try DNSQuestion(
                transactionID: parsed.transactionID,
                domain: parsed.domain,
                recordType: parsed.recordType,
                rawRecordType: parsed.rawRecordType,
                questionRange: staleRange
            )

            XCTAssertThrowsError(try DNSMessage.blockedResponse(for: query, question: staleQuestion)) { error in
                XCTAssertEqual(error as? DNSMessageError, .malformedQuestion)
            }
        }
    }

    // MARK: - NODATA synthesis (AAAA suppression while chained)

    func testEmptyResponseIsNoDataAndEchoesTheQuestion() throws {
        let query = makeQuery(domain: "mullvad.net", type: 28)
        let question = try DNSMessage.parseQuestion(from: query)
        let response = try DNSMessage.emptyResponse(for: query, question: question)

        // NODATA: a NOERROR response, question echoed, with ZERO answer/authority/additional
        // records — so the client learns the name has no AAAA and falls back to A rather than
        // attempting a v6 path the chained data path drops. NOT NXDOMAIN (that would poison the
        // whole name's negative cache, killing its A lookups too).
        XCTAssertEqual(response[0], 0x12)
        XCTAssertEqual(response[1], 0x34, "transaction id echoed")
        XCTAssertEqual(readUInt16(response, at: 2) & 0x8000, 0x8000, "QR set — it is a response")
        XCTAssertEqual(readUInt16(response, at: 2) & 0x000F, 0, "RCODE is NOERROR, not NXDOMAIN")
        XCTAssertEqual(readUInt16(response, at: 4), 1, "QDCOUNT echoes the one question")
        XCTAssertEqual(readUInt16(response, at: 6), 0, "ANCOUNT 0 — NODATA")
        XCTAssertEqual(readUInt16(response, at: 8), 0, "NSCOUNT 0")
        XCTAssertEqual(readUInt16(response, at: 10), 0, "ARCOUNT 0")
        XCTAssertEqual(response.count, query.count, "header + echoed question only, no answer appended")
        XCTAssertEqual(response.suffix(from: 12), query.suffix(from: 12), "question echoed verbatim")
    }

    func testEmptyResponsePreservesRecursionDesiredAndIsTypeAgnostic() throws {
        // The synthesizer NODATAs whatever question it is handed — the AAAA scoping is the caller's
        // policy, not this function's. It preserves the RD flag exactly like blockedResponse.
        var recursionDesired = makeQuery(domain: "example.com", type: 1)
        recursionDesired[2] = 0x01
        recursionDesired[3] = 0x00
        let rdQuestion = try DNSMessage.parseQuestion(from: recursionDesired)
        let rdResponse = try DNSMessage.emptyResponse(for: recursionDesired, question: rdQuestion)
        XCTAssertEqual(readUInt16(rdResponse, at: 2), 0x8180, "QR+RD+RA, NOERROR")
        XCTAssertEqual(readUInt16(rdResponse, at: 6), 0, "still NODATA for an A question")

        var recursionNotDesired = makeQuery(domain: "example.com", type: 28)
        recursionNotDesired[2] = 0x00
        recursionNotDesired[3] = 0x00
        let noRDQuestion = try DNSMessage.parseQuestion(from: recursionNotDesired)
        XCTAssertEqual(readUInt16(try DNSMessage.emptyResponse(for: recursionNotDesired, question: noRDQuestion), at: 2), 0x8080)
    }

    func testEmptyResponseRejectsQuestionRangeOutsideQuery() throws {
        let query = makeQuery(domain: "example.com", type: 28)
        let parsed = try DNSMessage.parseQuestion(from: query)
        let staleQuestion = try DNSQuestion(
            transactionID: parsed.transactionID,
            domain: parsed.domain,
            recordType: parsed.recordType,
            rawRecordType: parsed.rawRecordType,
            questionRange: 12..<(query.count + 8)
        )
        XCTAssertThrowsError(try DNSMessage.emptyResponse(for: query, question: staleQuestion)) { error in
            XCTAssertEqual(error as? DNSMessageError, .malformedQuestion)
        }
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private func makeQuery(domain: String, type: UInt16) -> Data {
        var data = Data([0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        for label in domain.split(separator: ".") {
            data.append(UInt8(label.utf8.count))
            data.append(contentsOf: label.utf8)
        }
        data.append(0)
        data.append(UInt8((type >> 8) & 0xFF))
        data.append(UInt8(type & 0xFF))
        data.append(0)
        data.append(1)
        return data
    }
}

private extension Data {
    mutating func appendQuestion(domain: String, type: UInt16) {
        for label in domain.split(separator: ".") {
            append(UInt8(label.utf8.count))
            append(contentsOf: label.utf8)
        }
        append(0)
        append(UInt8((type >> 8) & 0xFF))
        append(UInt8(type & 0xFF))
        append(0)
        append(1)
    }
}
