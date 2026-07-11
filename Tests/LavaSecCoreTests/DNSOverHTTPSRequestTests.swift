import Foundation
import XCTest
import LavaSecDNS
@testable import LavaSecCore
@testable import LavaSecKit

final class DNSOverHTTPSRequestTests: XCTestCase {
    func testBuildsPostRequestWithDNSMessageHeadersAndZeroedIDBody() throws {
        let query = Data([0x12, 0x34, 0x01, 0x00, 0x00, 0x01])
        let endpoint = URL(string: "https://dns.example/dns-query")!

        let request = DNSOverHTTPSRequest.makePOSTRequest(
            endpoint: endpoint,
            query: query,
            timeoutSeconds: 2
        )

        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/dns-message")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/dns-message")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeoutInterval, 2)
        XCTAssertEqual(request.httpBody, Data([0x00, 0x00, 0x01, 0x00, 0x00, 0x01]))
    }

    func testPrefersHTTP3WithoutRequiringIt() {
        let request = DNSOverHTTPSRequest.makePOSTRequest(
            endpoint: URL(string: "https://dns.example/dns-query")!,
            query: Data([0x12, 0x34, 0x01, 0x00, 0x00, 0x01]),
            timeoutSeconds: 2
        )

        XCTAssertTrue(
            request.assumesHTTP3Capable,
            "DoH requests must opt into HTTP/3 (DoH3); the loader handles H2/H1 fallback natively."
        )
    }

    func testAccepts2xxHTTPResponseAndRestoresOriginalTransactionID() throws {
        let query = Self.dnsQuery(id: 0x1234, domain: "example.com", type: 1, klass: 1)
        let body = Self.dnsResponse(id: 0x0000, flags: 0x8180, domain: "example.com", type: 1, klass: 1)
        let response = HTTPURLResponse(
            url: URL(string: "https://dns.example/dns-query")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "application/dns-message"]
        )!

        let dnsResponse = try DNSOverHTTPSRequest.validatedDNSResponse(
            body: body,
            response: response,
            originalQuery: query
        )

        var expected = body
        expected[0] = 0x12
        expected[1] = 0x34
        XCTAssertEqual(dnsResponse, expected)
    }

    func testAcceptsDNSMessageContentTypeWithParameters() throws {
        let query = Self.dnsQuery(id: 0x1234, domain: "example.com", type: 1, klass: 1)
        let body = Self.dnsResponse(id: 0x0000, flags: 0x8180, domain: "example.com", type: 1, klass: 1)
        let response = HTTPURLResponse(
            url: URL(string: "https://dns.example/dns-query")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "application/dns-message; charset=binary"]
        )!

        let dnsResponse = try DNSOverHTTPSRequest.validatedDNSResponse(
            body: body,
            response: response,
            originalQuery: query
        )

        var expected = body
        expected[0] = 0x12
        expected[1] = 0x34
        XCTAssertEqual(dnsResponse, expected)
    }

    func testAcceptsDNSErrorResponseForOriginalQuestion() throws {
        let query = Self.dnsQuery(id: 0x1234, domain: "missing.example", type: 28, klass: 1)
        let body = Self.dnsResponse(id: 0x0000, flags: 0x8183, domain: "missing.example", type: 28, klass: 1)
        let response = Self.httpDNSResponse()

        let dnsResponse = try DNSOverHTTPSRequest.validatedDNSResponse(
            body: body,
            response: response,
            originalQuery: query
        )

        XCTAssertEqual(dnsResponse[0], 0x12)
        XCTAssertEqual(dnsResponse[1], 0x34)
        XCTAssertEqual(dnsResponse[3] & 0x0F, 0x03)
    }

    func testRejectsDNSResponseForDifferentQuestionName() throws {
        XCTAssertThrowsError(try DNSOverHTTPSRequest.validatedDNSResponse(
            body: Self.dnsResponse(id: 0x0000, flags: 0x8180, domain: "attacker.example", type: 1, klass: 1),
            response: Self.httpDNSResponse(),
            originalQuery: Self.dnsQuery(id: 0x1234, domain: "example.com", type: 1, klass: 1)
        )) { error in
            XCTAssertEqual(error as? DNSOverHTTPSRequest.Error, .malformedDNSResponse)
        }
    }

    func testRejectsDNSResponseForDifferentQuestionType() throws {
        XCTAssertThrowsError(try DNSOverHTTPSRequest.validatedDNSResponse(
            body: Self.dnsResponse(id: 0x0000, flags: 0x8180, domain: "example.com", type: 28, klass: 1),
            response: Self.httpDNSResponse(),
            originalQuery: Self.dnsQuery(id: 0x1234, domain: "example.com", type: 1, klass: 1)
        )) { error in
            XCTAssertEqual(error as? DNSOverHTTPSRequest.Error, .malformedDNSResponse)
        }
    }

    func testRejectsDNSResponseForDifferentQuestionClass() throws {
        XCTAssertThrowsError(try DNSOverHTTPSRequest.validatedDNSResponse(
            body: Self.dnsResponse(id: 0x0000, flags: 0x8180, domain: "example.com", type: 1, klass: 3),
            response: Self.httpDNSResponse(),
            originalQuery: Self.dnsQuery(id: 0x1234, domain: "example.com", type: 1, klass: 1)
        )) { error in
            XCTAssertEqual(error as? DNSOverHTTPSRequest.Error, .malformedDNSResponse)
        }
    }

    func testRejectsDNSPacketWithoutResponseBit() throws {
        XCTAssertThrowsError(try DNSOverHTTPSRequest.validatedDNSResponse(
            body: Self.dnsQuery(id: 0x0000, domain: "example.com", type: 1, klass: 1),
            response: Self.httpDNSResponse(),
            originalQuery: Self.dnsQuery(id: 0x1234, domain: "example.com", type: 1, klass: 1)
        )) { error in
            XCTAssertEqual(error as? DNSOverHTTPSRequest.Error, .malformedDNSResponse)
        }
    }

    func testRejectsDNSResponseWithOpcodeMismatch() throws {
        XCTAssertThrowsError(try DNSOverHTTPSRequest.validatedDNSResponse(
            body: Self.dnsResponse(id: 0x0000, flags: 0x8980, domain: "example.com", type: 1, klass: 1),
            response: Self.httpDNSResponse(),
            originalQuery: Self.dnsQuery(id: 0x1234, domain: "example.com", type: 1, klass: 1)
        )) { error in
            XCTAssertEqual(error as? DNSOverHTTPSRequest.Error, .malformedDNSResponse)
        }
    }

    func testRejectsDNSResponseWithQuestionCountMismatch() throws {
        var body = Self.dnsResponse(id: 0x0000, flags: 0x8180, domain: "example.com", type: 1, klass: 1)
        body[5] = 0x02

        XCTAssertThrowsError(try DNSOverHTTPSRequest.validatedDNSResponse(
            body: body,
            response: Self.httpDNSResponse(),
            originalQuery: Self.dnsQuery(id: 0x1234, domain: "example.com", type: 1, klass: 1)
        )) { error in
            XCTAssertEqual(error as? DNSOverHTTPSRequest.Error, .malformedDNSResponse)
        }
    }

    func testRejectsDNSResponseWithCompressedQuestionName() throws {
        var body = Data([0x00, 0x00, 0x81, 0x80, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        body.append(contentsOf: [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01])

        XCTAssertThrowsError(try DNSOverHTTPSRequest.validatedDNSResponse(
            body: body,
            response: Self.httpDNSResponse(),
            originalQuery: Self.dnsQuery(id: 0x1234, domain: "example.com", type: 1, klass: 1)
        )) { error in
            XCTAssertEqual(error as? DNSOverHTTPSRequest.Error, .malformedDNSResponse)
        }
    }

    func testRejectsNon2xxHTTPResponse() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://dns.example/dns-query")!,
            statusCode: 504,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "application/dns-message"]
        )!

        XCTAssertThrowsError(try DNSOverHTTPSRequest.validatedDNSResponse(
            body: Data([0x00, 0x00, 0x81, 0x80]),
            response: response,
            originalQuery: Data([0x12, 0x34, 0x01, 0x00])
        )) { error in
            XCTAssertEqual(error as? DNSOverHTTPSRequest.Error, .httpStatus(504))
        }
    }

    func testRejectsNonHTTPResponse() throws {
        let response = URLResponse(
            url: URL(string: "https://dns.example/dns-query")!,
            mimeType: "application/dns-message",
            expectedContentLength: 12,
            textEncodingName: nil
        )

        XCTAssertThrowsError(try DNSOverHTTPSRequest.validatedDNSResponse(
            body: Data([0x00, 0x00, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]),
            response: response,
            originalQuery: Data([0x12, 0x34, 0x01, 0x00])
        )) { error in
            XCTAssertEqual(error as? DNSOverHTTPSRequest.Error, .nonHTTPResponse)
        }
    }

    func testRejectsTextHTMLContentType() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://dns.example/dns-query")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "text/html"]
        )!

        XCTAssertThrowsError(try DNSOverHTTPSRequest.validatedDNSResponse(
            body: Data([0x00, 0x00, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]),
            response: response,
            originalQuery: Data([0x12, 0x34, 0x01, 0x00])
        )) { error in
            XCTAssertEqual(error as? DNSOverHTTPSRequest.Error, .invalidContentType("text/html"))
        }
    }

    func testRejectsMissingContentType() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://dns.example/dns-query")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: nil
        )!

        XCTAssertThrowsError(try DNSOverHTTPSRequest.validatedDNSResponse(
            body: Data([0x00, 0x00, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]),
            response: response,
            originalQuery: Data([0x12, 0x34, 0x01, 0x00])
        )) { error in
            XCTAssertEqual(error as? DNSOverHTTPSRequest.Error, .invalidContentType(nil))
        }
    }

    func testRejectsEmptyBody() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://dns.example/dns-query")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "application/dns-message"]
        )!

        XCTAssertThrowsError(try DNSOverHTTPSRequest.validatedDNSResponse(
            body: Data(),
            response: response,
            originalQuery: Data([0x12, 0x34, 0x01, 0x00])
        )) { error in
            XCTAssertEqual(error as? DNSOverHTTPSRequest.Error, .emptyBody)
        }
    }

    func testRejectsBodyShorterThanDNSHeader() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://dns.example/dns-query")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "application/dns-message"]
        )!

        XCTAssertThrowsError(try DNSOverHTTPSRequest.validatedDNSResponse(
            body: Data([0x00, 0x00, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00]),
            response: response,
            originalQuery: Data([0x12, 0x34, 0x01, 0x00])
        )) { error in
            XCTAssertEqual(error as? DNSOverHTTPSRequest.Error, .malformedDNSResponse)
        }
    }

    private static func httpDNSResponse() -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://dns.example/dns-query")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "application/dns-message"]
        )!
    }

    private static func dnsQuery(id: UInt16, domain: String, type: UInt16, klass: UInt16) -> Data {
        dnsMessage(id: id, flags: 0x0100, questionCount: 1, answerCount: 0, domain: domain, type: type, klass: klass)
    }

    private static func dnsResponse(id: UInt16, flags: UInt16, domain: String, type: UInt16, klass: UInt16) -> Data {
        dnsMessage(id: id, flags: flags, questionCount: 1, answerCount: 0, domain: domain, type: type, klass: klass)
    }

    private static func dnsMessage(
        id: UInt16,
        flags: UInt16,
        questionCount: UInt16,
        answerCount: UInt16,
        domain: String,
        type: UInt16,
        klass: UInt16
    ) -> Data {
        var data = Data()
        DNSWireTestSupport.appendUInt16(id, to: &data)
        DNSWireTestSupport.appendUInt16(flags, to: &data)
        DNSWireTestSupport.appendUInt16(questionCount, to: &data)
        DNSWireTestSupport.appendUInt16(answerCount, to: &data)
        DNSWireTestSupport.appendUInt16(0, to: &data)
        DNSWireTestSupport.appendUInt16(0, to: &data)
        appendQuestion(domain: domain, type: type, klass: klass, to: &data)
        return data
    }

    private static func appendQuestion(domain: String, type: UInt16, klass: UInt16, to data: inout Data) {
        for label in domain.split(separator: ".") {
            let bytes = Array(label.utf8)
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(0)
        DNSWireTestSupport.appendUInt16(type, to: &data)
        DNSWireTestSupport.appendUInt16(klass, to: &data)
    }

}
