import Foundation
import XCTest
import LavaSecDNS

// First executable coverage for the header inspectors + SERVFAIL factory
// extracted in Phase E1 (Sources/LavaSecDNS/DNSMessageTraits.swift).
// DNSResponseFactory.serverFailure is the fail-closed answer of last resort
// (INV-DNS-1 / INV-DNS-2): its shape must stay a real, cacheable-nowhere
// SERVFAIL that clients accept as an answer to THEIR question.
final class DNSMessageTraitsTests: XCTestCase {
    // MARK: - Truncation bit

    func testDetectsTruncationBitInResponseFlags() {
        // Header: ID 0x1234 | flags QR(0x8000) + TC(0x0200) + RD(0x0100) = 0x8300.
        let truncated = Data([0x12, 0x34, 0x83, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        // Same header without TC: flags 0x8100.
        let intact = Data([0x12, 0x34, 0x81, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        XCTAssertTrue(DNSMessageTraits.isTruncated(truncated))
        XCTAssertFalse(DNSMessageTraits.isTruncated(intact))
    }

    func testTruncationCheckToleratesShortBuffers() {
        // Fewer than the 4 bytes needed to read the flags word: never truncated,
        // never a crash.
        XCTAssertFalse(DNSMessageTraits.isTruncated(Data()))
        XCTAssertFalse(DNSMessageTraits.isTruncated(Data([0x12, 0x34, 0x83])))
    }

    // MARK: - SERVFAIL synthesis

    func testServerFailureEchoesQuestionAndSetsServfail() throws {
        let query = Self.dnsAQuery(id: 0xCAFE, domain: "blocked.example", recursionDesired: true)

        let response = try XCTUnwrap(DNSResponseFactory.serverFailure(for: query))

        // ID echoed.
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 0), 0xCAFE)
        // Flags: QR (0x8000) + RD echoed (0x0100) + RA (0x0080) + RCODE 2 = 0x8182.
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 2), 0x8182)
        // Counts: the question echoed, zero answers/authority/additional.
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 4), 1, "QDCOUNT")
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 6), 0, "ANCOUNT")
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 8), 0, "NSCOUNT")
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 10), 0, "ARCOUNT")
        // Question section echoed byte-identically after the 12-byte header.
        XCTAssertEqual(response[12...], query[12...])
        // The resolver-side validator must accept it as an answer to this query.
        XCTAssertTrue(DNSWireMessage.isValidResponse(response, matching: query))
    }

    func testServerFailureCopiesRecursionDesiredFromQuery() throws {
        let query = Self.dnsAQuery(id: 0x0101, domain: "blocked.example", recursionDesired: false)

        let response = try XCTUnwrap(DNSResponseFactory.serverFailure(for: query))

        // RD clear: QR + RA + RCODE 2 = 0x8082.
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 2), 0x8082)
    }

    func testServerFailureForUnparseableQueryFallsBackToHeaderOnly() throws {
        // QDCOUNT 0 makes DNSMessage.parseQuestion throw, but the client still
        // deserves a SERVFAIL for its transaction: header-only, no question echo.
        var noQuestion = Data()
        DNSWireTestSupport.appendUInt16(0xBEEF, to: &noQuestion) // ID
        DNSWireTestSupport.appendUInt16(0x0100, to: &noQuestion) // flags: query, RD
        DNSWireTestSupport.appendUInt16(0, to: &noQuestion)      // QDCOUNT 0 → unparseable
        DNSWireTestSupport.appendUInt16(0, to: &noQuestion)
        DNSWireTestSupport.appendUInt16(0, to: &noQuestion)
        DNSWireTestSupport.appendUInt16(0, to: &noQuestion)

        let response = try XCTUnwrap(DNSResponseFactory.serverFailure(for: noQuestion))

        XCTAssertEqual(response.count, 12, "header-only fallback")
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 0), 0xBEEF, "ID echoed even for unparseable queries")
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 2), 0x8182, "QR + RD + RA + SERVFAIL")
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 4), 0, "no question to echo")
    }

    func testServerFailureForCompressedQuestionNameFallsBackToHeaderOnly() throws {
        // A compression pointer in the question name is rejected by the strict
        // question parser; the factory must still answer the transaction.
        var compressed = Data()
        DNSWireTestSupport.appendUInt16(0x5151, to: &compressed) // ID
        DNSWireTestSupport.appendUInt16(0x0100, to: &compressed) // flags: query, RD
        DNSWireTestSupport.appendUInt16(1, to: &compressed)      // QDCOUNT 1
        DNSWireTestSupport.appendUInt16(0, to: &compressed)
        DNSWireTestSupport.appendUInt16(0, to: &compressed)
        DNSWireTestSupport.appendUInt16(0, to: &compressed)
        compressed.append(contentsOf: [0xC0, 0x0C]) // QNAME: compression pointer (illegal in queries here)
        DNSWireTestSupport.appendUInt16(1, to: &compressed)            // QTYPE A
        DNSWireTestSupport.appendUInt16(1, to: &compressed)            // QCLASS IN

        let response = try XCTUnwrap(DNSResponseFactory.serverFailure(for: compressed))

        XCTAssertEqual(response.count, 12)
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 0), 0x5151)
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 2), 0x8182)
    }

    func testServerFailureReturnsNilBelowHeaderSize() {
        // Shorter than a DNS header there is no transaction to answer.
        XCTAssertNil(DNSResponseFactory.serverFailure(for: Data([0x12, 0x34, 0x01])))
        XCTAssertNil(DNSResponseFactory.serverFailure(for: Data()))
    }

    // MARK: - Fixtures

    private static func dnsAQuery(id: UInt16, domain: String, recursionDesired: Bool) -> Data {
        var data = Data()
        DNSWireTestSupport.appendUInt16(id, to: &data)                                   // transaction ID
        DNSWireTestSupport.appendUInt16(recursionDesired ? 0x0100 : 0x0000, to: &data)   // flags
        DNSWireTestSupport.appendUInt16(1, to: &data)                                    // QDCOUNT
        DNSWireTestSupport.appendUInt16(0, to: &data)                                    // ANCOUNT
        DNSWireTestSupport.appendUInt16(0, to: &data)                                    // NSCOUNT
        DNSWireTestSupport.appendUInt16(0, to: &data)                                    // ARCOUNT
        for label in domain.split(separator: ".") {                   // QNAME labels
            let bytes = Array(label.utf8)
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(0)                                                // root label
        DNSWireTestSupport.appendUInt16(1, to: &data)                                    // QTYPE A
        DNSWireTestSupport.appendUInt16(1, to: &data)                                    // QCLASS IN
        return data
    }

}
