import Foundation
import LavaSecCore
import XCTest

final class DNSQuestionAddressShapeTests: XCTestCase {
    private func query(recordType: UInt16, domain: String = "example.com") -> Data {
        DNSResolverSmokeProbe.query(transactionID: 0x1234, domain: domain, recordType: recordType)
    }

    /// The split that matters: A apart from AAAA. A failure trace carries no domain, so this is
    /// the whole of what a capture gets to reason with — if the queries a user loses are all one
    /// family, that is a different bug from losses spread across both.
    func testAddressQueriesAreSplitByFamily() {
        XCTAssertEqual(
            DNSQuestionAddressShape.shape(ofQuery: query(recordType: DNSRecordType.a.rawValue)),
            .ipv4Address)
        XCTAssertEqual(
            DNSQuestionAddressShape.shape(ofQuery: query(recordType: DNSRecordType.aaaa.rawValue)),
            .ipv6Address)
    }

    /// Everything that is not an address query is one bucket — including the service-binding
    /// types, which resolve addresses in practice but are not what a client retries as A/AAAA.
    func testNonAddressQueriesShareOneBucket() {
        for recordType: UInt16 in [
            DNSRecordType.txt.rawValue,
            DNSRecordType.srv.rawValue,
            DNSRecordType.svcb.rawValue,
            DNSRecordType.https.rawValue,
            255,  // ANY — no case of its own, must not crash or masquerade as an address query
        ] {
            XCTAssertEqual(
                DNSQuestionAddressShape.shape(ofQuery: query(recordType: recordType)), .other,
                "record type \(recordType) is not an address query")
        }
    }

    /// An unreadable query reports `nil`, NOT `.other`.
    ///
    /// The two are different findings and the trace logs them apart: `.other` is an expected,
    /// non-empty bucket, so folding "we could not parse the request at all" into it would hide a
    /// malformed-request bug inside normal traffic.
    func testAnUnreadableQueryIsDistinguishedFromAnUnclassifiedOne() {
        XCTAssertNil(DNSQuestionAddressShape.shape(ofQuery: Data()))
        XCTAssertNil(DNSQuestionAddressShape.shape(ofQuery: Data([0x12, 0x34])))
        // A header with no question section: long enough to be a DNS message, still unreadable.
        XCTAssertNil(DNSQuestionAddressShape.shape(
            ofQuery: Data([0x12, 0x34, 0x01, 0x00, 0, 0, 0, 0, 0, 0, 0, 0])))
    }

    /// The raw values are what reach the export, so they are part of the contract a future
    /// capture is read with — renaming one silently re-labels history.
    func testRawValuesAreStableForTheExport() {
        XCTAssertEqual(DNSQuestionAddressShape.ipv4Address.rawValue, "ipv4Address")
        XCTAssertEqual(DNSQuestionAddressShape.ipv6Address.rawValue, "ipv6Address")
        XCTAssertEqual(DNSQuestionAddressShape.other.rawValue, "other")
    }
}
