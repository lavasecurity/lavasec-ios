import Foundation
import XCTest
@testable import LavaSecCore

final class DNSWireMessageTests: XCTestCase {
    func testReadsTransactionID() {
        XCTAssertEqual(DNSWireMessage.transactionID(in: Data([0x12, 0x34])), 0x1234)
        XCTAssertNil(DNSWireMessage.transactionID(in: Data([0x12])))
    }

    func testClearsTransactionID() {
        let query = Data([0x12, 0x34, 0x01, 0x00])

        XCTAssertEqual(
            DNSWireMessage.clearingTransactionID(in: query),
            Data([0x00, 0x00, 0x01, 0x00])
        )
    }

    func testReplacesResponseTransactionIDFromOriginalQuery() {
        let query = Data([0xCA, 0xFE, 0x01, 0x00])
        let response = Data([0x00, 0x00, 0x81, 0x80])

        XCTAssertEqual(
            DNSWireMessage.replacingTransactionID(in: response, from: query),
            Data([0xCA, 0xFE, 0x81, 0x80])
        )
    }

    func testMatchesResponseTransactionID() {
        let query = Data([0xCA, 0xFE, 0x01, 0x00])
        let matchingResponse = Data([0xCA, 0xFE, 0x81, 0x80])
        let staleResponse = Data([0xBA, 0xAD, 0x81, 0x80])

        XCTAssertTrue(DNSWireMessage.matchesTransactionID(in: matchingResponse, query: query))
        XCTAssertFalse(DNSWireMessage.matchesTransactionID(in: staleResponse, query: query))
        XCTAssertFalse(DNSWireMessage.matchesTransactionID(in: Data([0xCA]), query: query))
    }

    func testFirstResponseMatchingTransactionIDSkipsStaleDatagrams() {
        let query = Data([0xCA, 0xFE, 0x01, 0x00])
        let staleResponse = Data([0xBA, 0xAD, 0x81, 0x80])
        let matchingResponse = Data([0xCA, 0xFE, 0x81, 0x80])

        XCTAssertEqual(
            DNSWireMessage.firstResponseMatchingTransactionID(
                in: [staleResponse, matchingResponse],
                query: query
            ),
            matchingResponse
        )
    }

    func testValidPlainDNSResponseMustMatchTransactionAndQuestion() {
        let query = Self.dnsQuery(id: 0xCAFE, domain: "example.com", type: 1, klass: 1)
        let matchingResponse = Self.dnsResponse(id: 0xCAFE, domain: "example.com", type: 1, klass: 1)
        let sameIDWrongQuestion = Self.dnsResponse(id: 0xCAFE, domain: "attacker.example", type: 1, klass: 1)
        let wrongIDSameQuestion = Self.dnsResponse(id: 0xBEEF, domain: "example.com", type: 1, klass: 1)

        XCTAssertTrue(DNSWireMessage.isValidResponse(matchingResponse, matching: query))
        XCTAssertFalse(DNSWireMessage.isValidResponse(sameIDWrongQuestion, matching: query))
        XCTAssertFalse(DNSWireMessage.isValidResponse(wrongIDSameQuestion, matching: query))
    }

    func testValidDoHResponseCanIgnoreTransactionIDButStillMatchesQuestion() {
        let query = Self.dnsQuery(id: 0xCAFE, domain: "example.com", type: 28, klass: 1)
        let matchingResponse = Self.dnsResponse(id: 0x0000, domain: "example.com", type: 28, klass: 1)
        let wrongQuestion = Self.dnsResponse(id: 0x0000, domain: "example.com", type: 1, klass: 1)

        XCTAssertTrue(
            DNSWireMessage.isValidResponse(
                matchingResponse,
                matching: query,
                requiresMatchingTransactionID: false
            )
        )
        XCTAssertFalse(
            DNSWireMessage.isValidResponse(
                wrongQuestion,
                matching: query,
                requiresMatchingTransactionID: false
            )
        )
    }

    func testCappingAnswerTTLsLowersOnlyValuesAboveMaximum() {
        let response = Self.dnsAResponse(id: 0xCAFE, domain: "linkedin.com", ttl: 300)

        let capped = DNSWireMessage.cappingAnswerTTLs(in: response, to: 1)

        XCTAssertEqual(Self.firstAnswerTTL(in: capped), 1)
        XCTAssertEqual(DNSWireMessage.transactionID(in: capped), 0xCAFE)
    }

    func testCappingAnswerTTLsDoesNotRaiseShortOrZeroValues() {
        let shortTTL = Self.dnsAResponse(id: 0xCAFE, domain: "linkedin.com", ttl: 1)
        let zeroTTL = Self.dnsAResponse(id: 0xCAFE, domain: "linkedin.com", ttl: 0)

        XCTAssertEqual(Self.firstAnswerTTL(in: DNSWireMessage.cappingAnswerTTLs(in: shortTTL, to: 1)), 1)
        XCTAssertEqual(Self.firstAnswerTTL(in: DNSWireMessage.cappingAnswerTTLs(in: zeroTTL, to: 1)), 0)
    }

    func testCappingAnswerTTLsAlsoCapsAuthorityAndAdditionalRecords() {
        let response = Self.dnsResponseWithAuthorityAndAdditionalRecords(
            id: 0xCAFE,
            domain: "linkedin.com",
            answerTTL: 300,
            authorityTTL: 600,
            additionalTTL: 900
        )

        let capped = DNSWireMessage.cappingAnswerTTLs(in: response, to: 1)

        XCTAssertEqual(Self.resourceRecordTTLs(in: capped), [1, 1, 1])
    }

    func testSafeTTLCappingFailsOnMalformedResourceRecords() {
        var response = Self.dnsResponseWithAuthorityAndAdditionalRecords(
            id: 0xCAFE,
            domain: "linkedin.com",
            answerTTL: 300,
            authorityTTL: 600,
            additionalTTL: 900
        )
        response.removeLast()

        XCTAssertNil(DNSWireMessage.cappingCacheableTTLs(in: response, to: 1))
        XCTAssertFalse(DNSWireMessage.hasWellFormedResourceRecords(response))
    }

    func testSafeTTLCappingFailsOnOutOfRangeCompressionPointer() {
        let response = Self.dnsResponseWithAnswerNamePointer(
            id: 0xCAFE,
            domain: "linkedin.com",
            pointer: 0xFFFF,
            ttl: 300
        )

        XCTAssertNil(DNSWireMessage.cappingCacheableTTLs(in: response, to: 1))
        XCTAssertFalse(DNSWireMessage.hasWellFormedResourceRecords(response))
    }

    func testSafeTTLCappingFailsOnCompressionPointerLoop() {
        let response = Self.dnsResponseWithAnswerNamePointer(
            id: 0xCAFE,
            domain: "linkedin.com",
            pointer: 0xC01E,
            ttl: 300
        )

        XCTAssertNil(DNSWireMessage.cappingCacheableTTLs(in: response, to: 1))
        XCTAssertFalse(DNSWireMessage.hasWellFormedResourceRecords(response))
    }

    func testSafeTTLCappingDoesNotRewriteEDNSOPTMetadata() throws {
        let response = Self.dnsResponseWithAnswerAndOPTRecord(
            id: 0xCAFE,
            domain: "linkedin.com",
            answerTTL: 300,
            optMetadata: 0x0000_8000
        )

        let capped = try XCTUnwrap(DNSWireMessage.cappingCacheableTTLs(in: response, to: 1))

        XCTAssertEqual(Self.resourceRecordTTLs(in: capped), [1, 0x0000_8000])
        XCTAssertTrue(DNSWireMessage.hasWellFormedResourceRecords(capped))
    }

    func testCappingAnswerTTLsLeavesMalformedMessagesUnchanged() {
        let malformed = Data([0x12, 0x34, 0x81])

        XCTAssertEqual(DNSWireMessage.cappingAnswerTTLs(in: malformed, to: 1), malformed)
    }

    private static func dnsQuery(id: UInt16, domain: String, type: UInt16, klass: UInt16) -> Data {
        dnsMessage(id: id, flags: 0x0100, questionCount: 1, answerCount: 0, domain: domain, type: type, klass: klass)
    }

    private static func dnsResponse(id: UInt16, domain: String, type: UInt16, klass: UInt16) -> Data {
        dnsMessage(id: id, flags: 0x8180, questionCount: 1, answerCount: 0, domain: domain, type: type, klass: klass)
    }

    private static func dnsAResponse(id: UInt16, domain: String, ttl: UInt32) -> Data {
        var data = dnsMessage(id: id, flags: 0x8180, questionCount: 1, answerCount: 1, domain: domain, type: 1, klass: 1)
        data.append(contentsOf: [0xC0, 0x0C])
        appendUInt16(1, to: &data)
        appendUInt16(1, to: &data)
        appendUInt32(ttl, to: &data)
        appendUInt16(4, to: &data)
        data.append(contentsOf: [93, 184, 216, 34])
        return data
    }

    private static func dnsResponseWithAnswerNamePointer(
        id: UInt16,
        domain: String,
        pointer: UInt16,
        ttl: UInt32
    ) -> Data {
        var data = dnsMessage(id: id, flags: 0x8180, questionCount: 1, answerCount: 1, domain: domain, type: 1, klass: 1)
        appendUInt16(pointer, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(1, to: &data)
        appendUInt32(ttl, to: &data)
        appendUInt16(4, to: &data)
        data.append(contentsOf: [93, 184, 216, 34])
        return data
    }

    private static func dnsResponseWithAuthorityAndAdditionalRecords(
        id: UInt16,
        domain: String,
        answerTTL: UInt32,
        authorityTTL: UInt32,
        additionalTTL: UInt32
    ) -> Data {
        var data = dnsMessage(
            id: id,
            flags: 0x8180,
            questionCount: 1,
            answerCount: 1,
            authorityCount: 1,
            additionalCount: 1,
            domain: domain,
            type: 1,
            klass: 1
        )
        appendARecord(namePointer: 0xC00C, ttl: answerTTL, address: [93, 184, 216, 34], to: &data)
        appendARecord(namePointer: 0xC00C, ttl: authorityTTL, address: [93, 184, 216, 35], to: &data)
        appendARecord(namePointer: 0xC00C, ttl: additionalTTL, address: [93, 184, 216, 36], to: &data)
        return data
    }

    private static func dnsResponseWithAnswerAndOPTRecord(
        id: UInt16,
        domain: String,
        answerTTL: UInt32,
        optMetadata: UInt32
    ) -> Data {
        var data = dnsMessage(
            id: id,
            flags: 0x8180,
            questionCount: 1,
            answerCount: 1,
            additionalCount: 1,
            domain: domain,
            type: 1,
            klass: 1
        )
        appendARecord(namePointer: 0xC00C, ttl: answerTTL, address: [93, 184, 216, 34], to: &data)
        data.append(0)
        appendUInt16(41, to: &data)
        appendUInt16(1232, to: &data)
        appendUInt32(optMetadata, to: &data)
        appendUInt16(0, to: &data)
        return data
    }

    private static func appendARecord(
        namePointer: UInt16,
        ttl: UInt32,
        address: [UInt8],
        to data: inout Data
    ) {
        appendUInt16(namePointer, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(1, to: &data)
        appendUInt32(ttl, to: &data)
        appendUInt16(UInt16(address.count), to: &data)
        data.append(contentsOf: address)
    }

    private static func firstAnswerTTL(in data: Data) -> UInt32? {
        guard data.count >= 12 else {
            return nil
        }

        let questionCount = Int(readUInt16(data, at: 4))
        let answerCount = Int(readUInt16(data, at: 6))
        guard answerCount > 0 else {
            return nil
        }

        var cursor = 12
        for _ in 0..<questionCount {
            guard skipName(in: data, cursor: &cursor), cursor + 4 <= data.count else {
                return nil
            }
            cursor += 4
        }

        guard skipName(in: data, cursor: &cursor), cursor + 10 <= data.count else {
            return nil
        }

        return readUInt32(data, at: cursor + 4)
    }

    private static func resourceRecordTTLs(in data: Data) -> [UInt32] {
        guard data.count >= 12 else {
            return []
        }

        let questionCount = Int(readUInt16(data, at: 4))
        let recordCount = Int(readUInt16(data, at: 6))
            + Int(readUInt16(data, at: 8))
            + Int(readUInt16(data, at: 10))
        var cursor = 12
        for _ in 0..<questionCount {
            guard skipName(in: data, cursor: &cursor), cursor + 4 <= data.count else {
                return []
            }
            cursor += 4
        }

        var ttls: [UInt32] = []
        for _ in 0..<recordCount {
            guard skipName(in: data, cursor: &cursor), cursor + 10 <= data.count else {
                return []
            }

            let ttl = readUInt32(data, at: cursor + 4)
            let dataLength = Int(readUInt16(data, at: cursor + 8))
            cursor += 10
            guard cursor + dataLength <= data.count else {
                return []
            }
            ttls.append(ttl)
            cursor += dataLength
        }

        return ttls
    }

    private static func dnsMessage(
        id: UInt16,
        flags: UInt16,
        questionCount: UInt16,
        answerCount: UInt16,
        authorityCount: UInt16 = 0,
        additionalCount: UInt16 = 0,
        domain: String,
        type: UInt16,
        klass: UInt16
    ) -> Data {
        var data = Data()
        appendUInt16(id, to: &data)
        appendUInt16(flags, to: &data)
        appendUInt16(questionCount, to: &data)
        appendUInt16(answerCount, to: &data)
        appendUInt16(authorityCount, to: &data)
        appendUInt16(additionalCount, to: &data)
        for label in domain.split(separator: ".") {
            let bytes = Array(label.utf8)
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(0)
        appendUInt16(type, to: &data)
        appendUInt16(klass, to: &data)
        return data
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

    private static func skipName(in data: Data, cursor: inout Int) -> Bool {
        while cursor < data.count {
            let length = data[cursor]
            cursor += 1

            if length == 0 {
                return true
            }

            if length & 0xC0 == 0xC0 {
                guard cursor < data.count else {
                    return false
                }
                cursor += 1
                return true
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
