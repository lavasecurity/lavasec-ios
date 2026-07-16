import Foundation
import XCTest
@testable import LavaSecDNS
@testable import LavaSecCore
@testable import LavaSecKit

final class DNSMessageTests: XCTestCase {
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
            let staleQuestion = DNSQuestion(
                transactionID: parsed.transactionID,
                domain: parsed.domain,
                normalizedDomain: parsed.normalizedDomain,
                recordType: parsed.recordType,
                rawRecordType: parsed.rawRecordType,
                questionRange: staleRange
            )

            XCTAssertThrowsError(try DNSMessage.blockedResponse(for: query, question: staleQuestion)) { error in
                XCTAssertEqual(error as? DNSMessageError, .malformedQuestion)
            }
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
