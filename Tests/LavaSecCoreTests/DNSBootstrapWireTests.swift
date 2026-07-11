import Foundation
import XCTest
import LavaSecDNS
import LavaSecKit

// First executable coverage for the bootstrap-path wire helpers extracted in
// Phase E1 (Sources/LavaSecDNS/DNSBootstrapWire.swift): answer-address
// extraction (with its validate-before-trust gate) and bootstrap answer
// synthesis for encrypted-resolver hostnames. Fixtures are hand-built byte
// arrays with each DNS field called out.
final class DNSBootstrapWireTests: XCTestCase {
    // MARK: - DNSBootstrapAddressExtractor: extraction

    func testExtractsARecordAddressesFromAnswerSection() {
        let query = Self.dnsQuery(id: 0xCAFE, domain: "doh.example", type: 1)
        var response = Self.responseHeader(matching: query, answerCount: 2)
        // Answer 1: NAME → pointer to the question name at offset 12, TYPE A,
        // CLASS IN, TTL 60, RDLENGTH 4, RDATA 94.140.14.14.
        Self.appendRecord(type: 1, klass: 1, rdata: [94, 140, 14, 14], to: &response)
        // Answer 2: same shape, RDATA 94.140.15.15.
        Self.appendRecord(type: 1, klass: 1, rdata: [94, 140, 15, 15], to: &response)

        XCTAssertEqual(
            DNSBootstrapAddressExtractor.addresses(from: response, matching: query, recordType: .a),
            ["94.140.14.14", "94.140.15.15"]
        )
    }

    func testExtractsAAAARecordAddresses() {
        let query = Self.dnsQuery(id: 0xF00D, domain: "doh.example", type: 28)
        var response = Self.responseHeader(matching: query, answerCount: 2)
        // 2001:db8::1 and 2001:db8::2 as raw 16-byte RDATA.
        Self.appendRecord(
            type: 28,
            klass: 1,
            rdata: [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
            to: &response
        )
        Self.appendRecord(
            type: 28,
            klass: 1,
            rdata: [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2],
            to: &response
        )

        XCTAssertEqual(
            DNSBootstrapAddressExtractor.addresses(from: response, matching: query, recordType: .aaaa),
            ["2001:db8::1", "2001:db8::2"]
        )
    }

    func testDeduplicatesRepeatedAddresses() {
        let query = Self.dnsQuery(id: 0x0A0A, domain: "doh.example", type: 1)
        var response = Self.responseHeader(matching: query, answerCount: 3)
        Self.appendRecord(type: 1, klass: 1, rdata: [9, 9, 9, 9], to: &response)
        Self.appendRecord(type: 1, klass: 1, rdata: [9, 9, 9, 9], to: &response)
        Self.appendRecord(type: 1, klass: 1, rdata: [149, 112, 112, 112], to: &response)

        XCTAssertEqual(
            DNSBootstrapAddressExtractor.addresses(from: response, matching: query, recordType: .a),
            ["9.9.9.9", "149.112.112.112"]
        )
    }

    // MARK: - DNSBootstrapAddressExtractor: skipping and trust gates

    func testSkipsAnswersOfOtherTypesClassesAndSizes() {
        let query = Self.dnsQuery(id: 0x1234, domain: "doh.example", type: 1)
        var response = Self.responseHeader(matching: query, answerCount: 4)
        // AAAA answer: wrong TYPE for an A extraction — skipped over its 16 bytes.
        Self.appendRecord(type: 28, klass: 1, rdata: [UInt8](repeating: 0, count: 16), to: &response)
        // Class CH (3) A record: wrong CLASS — skipped.
        Self.appendRecord(type: 1, klass: 3, rdata: [10, 0, 0, 1], to: &response)
        // A record with 6-byte RDATA: wrong size for an IPv4 address — skipped.
        Self.appendRecord(type: 1, klass: 1, rdata: [10, 0, 0, 2, 0, 0], to: &response)
        // The one well-formed IN A answer must still come out.
        Self.appendRecord(type: 1, klass: 1, rdata: [94, 140, 14, 14], to: &response)

        XCTAssertEqual(
            DNSBootstrapAddressExtractor.addresses(from: response, matching: query, recordType: .a),
            ["94.140.14.14"]
        )
    }

    func testIgnoresRecordsOutsideTheAnswerSection() {
        let query = Self.dnsQuery(id: 0x5678, domain: "doh.example", type: 1)
        // ANCOUNT 1, NSCOUNT 1: only the answer record may contribute addresses.
        var response = Self.responseHeader(matching: query, answerCount: 1, authorityCount: 1)
        Self.appendRecord(type: 1, klass: 1, rdata: [94, 140, 14, 14], to: &response)
        // Authority-section A record: must NOT be extracted.
        Self.appendRecord(type: 1, klass: 1, rdata: [6, 6, 6, 6], to: &response)

        XCTAssertEqual(
            DNSBootstrapAddressExtractor.addresses(from: response, matching: query, recordType: .a),
            ["94.140.14.14"]
        )
    }

    func testStopsAtStructurallyTruncatedAnswer() {
        let query = Self.dnsQuery(id: 0x9ABC, domain: "doh.example", type: 1)
        var response = Self.responseHeader(matching: query, answerCount: 2)
        Self.appendRecord(type: 1, klass: 1, rdata: [94, 140, 14, 14], to: &response)
        // Second answer claims 4 RDATA bytes but the buffer ends after 2:
        // extraction keeps what was already validated and stops.
        response.append(contentsOf: [0xC0, 0x0C]) // NAME pointer
        DNSWireTestSupport.appendUInt16(1, to: &response)       // TYPE A
        DNSWireTestSupport.appendUInt16(1, to: &response)       // CLASS IN
        response.append(contentsOf: [0, 0, 0, 60]) // TTL
        DNSWireTestSupport.appendUInt16(4, to: &response)       // RDLENGTH 4...
        response.append(contentsOf: [10, 0])      // ...but only 2 bytes present

        XCTAssertEqual(
            DNSBootstrapAddressExtractor.addresses(from: response, matching: query, recordType: .a),
            ["94.140.14.14"]
        )
    }

    func testRejectsAnswerNameCompressionPointerLoop() {
        let query = Self.dnsQuery(id: 0xDEAD, domain: "doh.example", type: 1)
        var response = Self.responseHeader(matching: query, answerCount: 1)
        // The answer NAME lives right after the echoed question; point it at
        // ITSELF so the pointer chain loops. The loop guard must abort the walk
        // (returning nothing) instead of spinning.
        let answerNameOffset = response.count
        XCTAssertLessThanOrEqual(answerNameOffset, 0x3F, "fixture assumes a 1-byte pointer offset")
        response.append(contentsOf: [0xC0, UInt8(answerNameOffset)])
        DNSWireTestSupport.appendUInt16(1, to: &response)        // TYPE A
        DNSWireTestSupport.appendUInt16(1, to: &response)        // CLASS IN
        response.append(contentsOf: [0, 0, 0, 60]) // TTL
        DNSWireTestSupport.appendUInt16(4, to: &response)        // RDLENGTH
        response.append(contentsOf: [94, 140, 14, 14])

        XCTAssertEqual(
            DNSBootstrapAddressExtractor.addresses(from: response, matching: query, recordType: .a),
            []
        )
    }

    func testRejectsAnswerNamePointerOutOfRange() {
        let query = Self.dnsQuery(id: 0xB00B, domain: "doh.example", type: 1)
        var response = Self.responseHeader(matching: query, answerCount: 1)
        // Pointer target 0x3FFF is far beyond the buffer.
        response.append(contentsOf: [0xFF, 0xFF])
        DNSWireTestSupport.appendUInt16(1, to: &response)
        DNSWireTestSupport.appendUInt16(1, to: &response)
        response.append(contentsOf: [0, 0, 0, 60])
        DNSWireTestSupport.appendUInt16(4, to: &response)
        response.append(contentsOf: [94, 140, 14, 14])

        XCTAssertEqual(
            DNSBootstrapAddressExtractor.addresses(from: response, matching: query, recordType: .a),
            []
        )
    }

    func testReturnsNothingForMissingShortOrMismatchedResponses() {
        let query = Self.dnsQuery(id: 0xCAFE, domain: "doh.example", type: 1)
        var mismatched = Self.responseHeader(matching: Self.dnsQuery(id: 0xBEEF, domain: "doh.example", type: 1), answerCount: 1)
        Self.appendRecord(type: 1, klass: 1, rdata: [94, 140, 14, 14], to: &mismatched)

        // No response at all.
        XCTAssertEqual(DNSBootstrapAddressExtractor.addresses(from: nil, matching: query, recordType: .a), [])
        // Shorter than a DNS header.
        XCTAssertEqual(
            DNSBootstrapAddressExtractor.addresses(from: Data([0xCA, 0xFE, 0x81]), matching: query, recordType: .a),
            []
        )
        // Wire-valid response to a DIFFERENT transaction: the validate-before-trust
        // gate must refuse to read its answers.
        XCTAssertEqual(DNSBootstrapAddressExtractor.addresses(from: mismatched, matching: query, recordType: .a), [])
    }

    // MARK: - DNSBootstrapResponseFactory

    func testSynthesizesPinnedIPv4AnswersForDoHEndpoint() throws {
        let query = Self.dnsQuery(id: 0x4444, domain: "dns.example", type: 1)
        let question = try DNSMessage.parseQuestion(from: query)
        let endpoint = DNSOverHTTPSEndpoint(
            url: try XCTUnwrap(URL(string: "https://dns.example/dns-query")),
            bootstrapIPv4Servers: ["94.140.14.14", "94.140.15.15"],
            bootstrapIPv6Servers: ["2a10:50c0::ad1:ff"]
        )

        let response = try XCTUnwrap(
            DNSBootstrapResponseFactory.response(for: query, question: question, endpoint: endpoint)
        )

        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 0), 0x4444, "transaction ID echoed")
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 2), 0x8180, "QR + RD echoed + RA, NOERROR")
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 4), 1, "QDCOUNT")
        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 6), 2, "one answer per pinned IPv4 server")
        XCTAssertTrue(DNSWireMessage.isValidResponse(response, matching: query))
        // Round trip through the extractor: the synthesized answers must carry
        // exactly the pinned bootstrap addresses.
        XCTAssertEqual(
            DNSBootstrapAddressExtractor.addresses(from: response, matching: query, recordType: .a),
            ["94.140.14.14", "94.140.15.15"]
        )
    }

    func testSynthesizesPinnedIPv6AnswersForDoQEndpointWithCustomTTL() throws {
        let query = Self.dnsQuery(id: 0x6666, domain: "dns.example", type: 28)
        let question = try DNSMessage.parseQuestion(from: query)
        let endpoint = DNSOverQUICEndpoint(
            hostname: "dns.example",
            bootstrapIPv4Servers: ["94.140.14.14"],
            bootstrapIPv6Servers: ["2001:db8::1", "2001:db8::2"]
        )

        let response = try XCTUnwrap(
            DNSBootstrapResponseFactory.response(for: query, question: question, endpoint: endpoint, ttl: 300)
        )

        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 6), 2, "one answer per pinned IPv6 server")
        XCTAssertEqual(
            DNSBootstrapAddressExtractor.addresses(from: response, matching: query, recordType: .aaaa),
            ["2001:db8::1", "2001:db8::2"]
        )
        // First answer TTL: header (12) + question + NAME ptr (2) + TYPE (2) +
        // CLASS (2) = TTL offset.
        let ttlOffset = 12 + (query.count - 12) + 6
        XCTAssertEqual(readUInt32(response, at: ttlOffset), 300, "custom TTL honored")
    }

    func testDoTEndpointOverloadSkipsUnparseableBootstrapAddresses() throws {
        let query = Self.dnsQuery(id: 0x7777, domain: "dns.example", type: 1)
        let question = try DNSMessage.parseQuestion(from: query)
        let endpoint = DNSOverTLSEndpoint(
            hostname: "dns.example",
            bootstrapIPv4Servers: ["not-an-ip", "9.9.9.9"],
            bootstrapIPv6Servers: []
        )

        let response = try XCTUnwrap(
            DNSBootstrapResponseFactory.response(for: query, question: question, endpoint: endpoint)
        )

        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 6), 1, "the unparseable pinned address is dropped")
        XCTAssertEqual(
            DNSBootstrapAddressExtractor.addresses(from: response, matching: query, recordType: .a),
            ["9.9.9.9"]
        )
    }

    func testUnsupportedQuestionTypeYieldsZeroAnswers() throws {
        // TXT (type 16) for the resolver hostname: no bootstrap answer to give,
        // but the transaction still gets a well-formed empty NOERROR response.
        let query = Self.dnsQuery(id: 0x8888, domain: "dns.example", type: 16)
        let question = try DNSMessage.parseQuestion(from: query)
        let endpoint = DNSOverHTTPSEndpoint(
            url: try XCTUnwrap(URL(string: "https://dns.example/dns-query")),
            bootstrapIPv4Servers: ["9.9.9.9"],
            bootstrapIPv6Servers: ["2001:db8::1"]
        )

        let response = try XCTUnwrap(
            DNSBootstrapResponseFactory.response(for: query, question: question, endpoint: endpoint)
        )

        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 6), 0, "ANCOUNT")
        XCTAssertTrue(DNSWireMessage.isValidResponse(response, matching: query))
    }

    func testCopiesRecursionDesiredFromQuery() throws {
        // RD clear in the query → RD clear in the synthesized response.
        let query = Self.dnsQuery(id: 0x9999, domain: "dns.example", type: 1, recursionDesired: false)
        let question = try DNSMessage.parseQuestion(from: query)
        let endpoint = DNSOverHTTPSEndpoint(
            url: try XCTUnwrap(URL(string: "https://dns.example/dns-query")),
            bootstrapIPv4Servers: ["9.9.9.9"],
            bootstrapIPv6Servers: []
        )

        let response = try XCTUnwrap(
            DNSBootstrapResponseFactory.response(for: query, question: question, endpoint: endpoint)
        )

        XCTAssertEqual(DNSWireTestSupport.readUInt16(response, at: 2), 0x8080, "QR + RA only; RD not invented")
    }

    // MARK: - Fixtures

    /// Standard query: header (ID, flags, QD=1) + QNAME labels + QTYPE + QCLASS IN.
    private static func dnsQuery(id: UInt16, domain: String, type: UInt16, recursionDesired: Bool = true) -> Data {
        var data = Data()
        DNSWireTestSupport.appendUInt16(id, to: &data)                                 // transaction ID
        DNSWireTestSupport.appendUInt16(recursionDesired ? 0x0100 : 0x0000, to: &data) // flags
        DNSWireTestSupport.appendUInt16(1, to: &data)                                  // QDCOUNT
        DNSWireTestSupport.appendUInt16(0, to: &data)                                  // ANCOUNT
        DNSWireTestSupport.appendUInt16(0, to: &data)                                  // NSCOUNT
        DNSWireTestSupport.appendUInt16(0, to: &data)                                  // ARCOUNT
        for label in domain.split(separator: ".") {                 // QNAME labels
            let bytes = Array(label.utf8)
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(0)                                              // root label
        DNSWireTestSupport.appendUInt16(type, to: &data)                               // QTYPE
        DNSWireTestSupport.appendUInt16(1, to: &data)                                  // QCLASS IN
        return data
    }

    /// Response header + echoed question for `query` (so the extractor's
    /// validate-before-trust gate passes); records are appended by the caller.
    private static func responseHeader(matching query: Data, answerCount: UInt16, authorityCount: UInt16 = 0) -> Data {
        var data = Data()
        data.append(query[0])                    // transaction ID echoed
        data.append(query[1])
        DNSWireTestSupport.appendUInt16(0x8180, to: &data)          // flags: QR + RD + RA, NOERROR
        DNSWireTestSupport.appendUInt16(1, to: &data)               // QDCOUNT
        DNSWireTestSupport.appendUInt16(answerCount, to: &data)     // ANCOUNT
        DNSWireTestSupport.appendUInt16(authorityCount, to: &data)  // NSCOUNT
        DNSWireTestSupport.appendUInt16(0, to: &data)               // ARCOUNT
        data.append(query[12...])                // question echoed byte-identically
        return data
    }

    /// One resource record: NAME as a compression pointer to offset 12 (the
    /// echoed question name), then TYPE/CLASS/TTL 60/RDLENGTH/RDATA.
    private static func appendRecord(type: UInt16, klass: UInt16, rdata: [UInt8], to data: inout Data) {
        data.append(contentsOf: [0xC0, 0x0C])      // NAME → pointer to offset 12
        DNSWireTestSupport.appendUInt16(type, to: &data)              // TYPE
        DNSWireTestSupport.appendUInt16(klass, to: &data)             // CLASS
        data.append(contentsOf: [0, 0, 0, 60])     // TTL 60
        DNSWireTestSupport.appendUInt16(UInt16(rdata.count), to: &data) // RDLENGTH
        data.append(contentsOf: rdata)             // RDATA
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(DNSWireTestSupport.readUInt16(data, at: offset)) << 16) | UInt32(DNSWireTestSupport.readUInt16(data, at: offset + 2))
    }
}
