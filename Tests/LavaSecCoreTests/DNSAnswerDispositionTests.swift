import Foundation
import LavaSecCore
import XCTest

final class DNSAnswerDispositionTests: XCTestCase {
    /// A reply carrying `rcode`.
    ///
    /// Built from a REAL query rather than a hand-written header: `fullRCode` walks the
    /// question section to reach the additional section, so a header claiming `QDCOUNT` 1 with
    /// no question behind it is unparseable and every case would read `nil` — passing the
    /// too-short test for the wrong reason while proving nothing about the rcode split.
    private func response(rcode: UInt8) -> Data {
        var bytes = [UInt8](DNSResolverSmokeProbe.query(
            transactionID: 0x1234, domain: "example.com",
            recordType: DNSRecordType.a.rawValue))
        bytes[2] |= 0x80  // QR
        bytes[3] = (bytes[3] & 0xF0) | (rcode & 0x0F)
        return Data(bytes)
    }

    /// The distinction the failure trace turns on: NXDOMAIN is a correct answer, SERVFAIL and
    /// REFUSED are the resolver declining to give one. Folding them together would file
    /// authoritative negatives as failures and make ordinary browsing look broken.
    func testAnAuthoritativeNegativeIsNotAResolverFailure() {
        XCTAssertEqual(DNSAnswerDisposition.disposition(ofResponse: response(rcode: 0)), .resolved)
        XCTAssertEqual(
            DNSAnswerDisposition.disposition(ofResponse: response(rcode: 3)), .nameDoesNotExist)
        XCTAssertEqual(
            DNSAnswerDisposition.disposition(ofResponse: response(rcode: 2)), .resolverFailure,
            "SERVFAIL")
        XCTAssertEqual(
            DNSAnswerDisposition.disposition(ofResponse: response(rcode: 5)), .resolverFailure,
            "REFUSED")
        // Everything else non-zero is a failure too — no silent gap between the named codes.
        for rcode: UInt8 in [1, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15] {
            XCTAssertEqual(
                DNSAnswerDisposition.disposition(ofResponse: response(rcode: rcode)),
                .resolverFailure, "rcode \(rcode)")
        }
    }

    /// The FULL 12-bit code (RFC 6891), not the header nibble.
    ///
    /// BADMODE is 19, whose low nibble is 3 — a nibble-only read files a resolver failure as
    /// "the name does not exist" and sends the next investigation somewhere it should not go.
    func testAnExtendedRCodeIsNotReadAsNXDomain() {
        var bytes = [UInt8](response(rcode: 3))
        bytes[11] = 1  // ARCOUNT = 1
        var withOPT = Data(bytes)
        // OPT record: extended RCODE high byte 1 → full code (1 << 4) | 3 == 19.
        withOPT.append(contentsOf: [0x00, 0x00, 0x29, 0x10, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00])

        XCTAssertEqual(
            DNSAnswerDisposition.disposition(ofResponse: withOPT), .resolverFailure,
            "BADMODE is a failure, not an authoritative negative")
    }

    func testAResponseTooShortToCarryACodeIsUnclassified() {
        XCTAssertNil(DNSAnswerDisposition.disposition(ofResponse: Data()))
        XCTAssertNil(DNSAnswerDisposition.disposition(ofResponse: Data([0x12, 0x34, 0x81, 0x80])))
    }

    /// Guards the helper itself: if `response(rcode:)` ever stopped producing a parseable
    /// message, every case above would read `nil` and the suite would pass while asserting
    /// nothing about the split it exists for.
    func testTheFixtureIsParseable() {
        XCTAssertNotNil(DNSAnswerDisposition.disposition(ofResponse: response(rcode: 0)))
    }
}
