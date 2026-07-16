import Foundation
import XCTest
@testable import LavaSecCore
@testable import LavaSecDNS
@testable import LavaSecKit

/// Executable coverage for `DoHTransport.classifiedResponse` — the mapping from a
/// completed URLSession data task to the transport outcome the resolver records. The
/// response *validation* rules live in `DNSOverHTTPSRequestTests`; these tests pin the
/// error-to-outcome classification that was previously inlined in the dataTask closure
/// and reachable only through live HTTPS I/O.
final class DoHResponseClassificationTests: XCTestCase {
    private let endpoint = URL(string: "https://dns.example/dns-query")!

    func testTimedOutTaskClassifiesAsTimeout() {
        let classified = DoHTransport.classifiedResponse(
            data: nil,
            response: nil,
            error: URLError(.timedOut),
            originalQuery: Self.dnsQuery(id: 0x1234),
            negotiatedHTTPProtocolName: "h3"
        )

        XCTAssertEqual(classified.outcome, .timeout)
        XCTAssertNil(classified.response)
        XCTAssertEqual(
            classified.negotiatedHTTPProtocolName, "h3",
            "the negotiated protocol is reported even for failures so DoH3 health annotations stay accurate"
        )
    }

    func testNonTimeoutLoaderErrorsClassifyAsReceiveFailed() {
        for code: URLError.Code in [.cannotConnectToHost, .networkConnectionLost, .secureConnectionFailed, .cancelled] {
            let classified = DoHTransport.classifiedResponse(
                data: Data([0x00]),
                response: nil,
                error: URLError(code),
                originalQuery: Self.dnsQuery(id: 0x1234),
                negotiatedHTTPProtocolName: nil
            )

            XCTAssertEqual(classified.outcome, .receiveFailed, "\(code)")
            XCTAssertNil(classified.response, "\(code)")
        }
    }

    func testMissingDataOrResponseClassifiesAsReceiveFailed() {
        let missingData = DoHTransport.classifiedResponse(
            data: nil,
            response: successHTTPResponse(),
            error: nil,
            originalQuery: Self.dnsQuery(id: 0x1234),
            negotiatedHTTPProtocolName: nil
        )
        XCTAssertEqual(missingData.outcome, .receiveFailed)

        let missingResponse = DoHTransport.classifiedResponse(
            data: Self.dnsResponse(id: 0x0000),
            response: nil,
            error: nil,
            originalQuery: Self.dnsQuery(id: 0x1234),
            negotiatedHTTPProtocolName: nil
        )
        XCTAssertEqual(missingResponse.outcome, .receiveFailed)

        // Data() passes the `guard let data` check in classifiedResponse but trips
        // `guard !body.isEmpty` in validatedDNSResponse — a distinct path from data == nil.
        let emptyBody = DoHTransport.classifiedResponse(
            data: Data(),
            response: successHTTPResponse(),
            error: nil,
            originalQuery: Self.dnsQuery(id: 0x1234),
            negotiatedHTTPProtocolName: nil
        )
        XCTAssertEqual(emptyBody.outcome, .receiveFailed)
        XCTAssertNil(emptyBody.response)
    }

    func testValidatedBodyClassifiesAsSuccessWithOriginalTransactionIDRestored() throws {
        // The id delta (response 0x0000 vs query 0x1234) is intentional: production
        // validates with `requiresMatchingTransactionID: false` and then rewrites the
        // id from the query, so this pins the id-rewrite leg — not ID-mismatch
        // detection. An id difference alone never fails validation.
        let classified = DoHTransport.classifiedResponse(
            data: Self.dnsResponse(id: 0x0000),
            response: successHTTPResponse(),
            error: nil,
            originalQuery: Self.dnsQuery(id: 0x1234),
            negotiatedHTTPProtocolName: "h2"
        )

        XCTAssertEqual(classified.outcome, .success)
        XCTAssertEqual(classified.negotiatedHTTPProtocolName, "h2")
        let response = try XCTUnwrap(classified.response)
        XCTAssertEqual(response[0], 0x12)
        XCTAssertEqual(response[1], 0x34)
    }

    func testNonSuccessHTTPStatusClassifiesAsHTTPStatusFailure() {
        for statusCode in [400, 429, 500, 503] {
            let classified = DoHTransport.classifiedResponse(
                data: Self.dnsResponse(id: 0x0000),
                response: httpResponse(statusCode: statusCode),
                error: nil,
                originalQuery: Self.dnsQuery(id: 0x1234),
                negotiatedHTTPProtocolName: nil
            )

            XCTAssertEqual(classified.outcome, .httpStatusFailure, "status \(statusCode)")
            XCTAssertNil(classified.response, "status \(statusCode)")
        }
    }

    func testMismatchedQuestionNameClassifiesAsReceiveFailedNeverSuccess() {
        // A 200 whose body answers a DIFFERENT question must never be forwarded:
        // classification maps the validation failure to .receiveFailed. Only the
        // question name is mismatched here (id is held equal at 0x1234), because the
        // question name is the field that actually gates forwarding — production
        // validates with `requiresMatchingTransactionID: false` and rewrites the id,
        // so a transaction-id-only mismatch classifies as .success (pinned by
        // testValidatedBodyClassifiesAsSuccessWithOriginalTransactionIDRestored), not
        // .receiveFailed.
        let classified = DoHTransport.classifiedResponse(
            data: Self.dnsResponse(id: 0x1234, domain: "attacker.example"),
            response: successHTTPResponse(),
            error: nil,
            originalQuery: Self.dnsQuery(id: 0x1234, domain: "example.com"),
            negotiatedHTTPProtocolName: nil
        )

        XCTAssertEqual(classified.outcome, .receiveFailed)
        XCTAssertNil(classified.response)
    }

    func testNonHTTPResponseClassifiesAsReceiveFailed() {
        let classified = DoHTransport.classifiedResponse(
            data: Self.dnsResponse(id: 0x0000),
            response: URLResponse(
                url: endpoint,
                mimeType: "application/dns-message",
                expectedContentLength: 0,
                textEncodingName: nil
            ),
            error: nil,
            originalQuery: Self.dnsQuery(id: 0x1234),
            negotiatedHTTPProtocolName: nil
        )

        XCTAssertEqual(classified.outcome, .receiveFailed)
    }

    // MARK: - Fixtures

    private func successHTTPResponse() -> HTTPURLResponse {
        httpResponse(statusCode: 200)
    }

    private func httpResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: endpoint,
            statusCode: statusCode,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "application/dns-message"]
        )!
    }

    private static func dnsQuery(id: UInt16, domain: String = "example.com") -> Data {
        dnsMessage(id: id, flags: 0x0100, domain: domain)
    }

    private static func dnsResponse(id: UInt16, domain: String = "example.com") -> Data {
        dnsMessage(id: id, flags: 0x8180, domain: domain)
    }

    private static func dnsMessage(id: UInt16, flags: UInt16, domain: String) -> Data {
        var data = Data()
        DNSWireTestSupport.appendUInt16(id, to: &data)
        DNSWireTestSupport.appendUInt16(flags, to: &data)
        DNSWireTestSupport.appendUInt16(1, to: &data)
        DNSWireTestSupport.appendUInt16(0, to: &data)
        DNSWireTestSupport.appendUInt16(0, to: &data)
        DNSWireTestSupport.appendUInt16(0, to: &data)
        for label in domain.split(separator: ".") {
            data.append(UInt8(label.utf8.count))
            data.append(contentsOf: label.utf8)
        }
        data.append(0)
        DNSWireTestSupport.appendUInt16(1, to: &data)
        DNSWireTestSupport.appendUInt16(1, to: &data)
        return data
    }
}
