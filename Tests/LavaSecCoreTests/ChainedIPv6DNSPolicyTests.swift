import XCTest
@testable import LavaSecDNS

/// The resolver must decline AAAA (answer NODATA) exactly when the data path DROPS outbound IPv6 —
/// and never otherwise. Whether the data path drops v6 is `TunnelDataPathMode.dropsOutboundIPv6`
/// (full-tunnel chained only; split-tunnel and DNS-only leave v6 direct). See `ChainedIPv6DNSPolicy`.
final class ChainedIPv6DNSPolicyTests: XCTestCase {
    private func question(_ recordType: DNSRecordType, raw: UInt16) throws -> DNSQuestion {
        try DNSQuestion(
            transactionID: 0x1234,
            domain: "mullvad.net",
            recordType: recordType,
            rawRecordType: raw,
            questionRange: 0..<0
        )
    }

    func testAAAAIsSuppressedOnlyWhenTheDataPathDropsIPv6() throws {
        let aaaa = try question(.aaaa, raw: 28)
        XCTAssertTrue(
            ChainedIPv6DNSPolicy.answersWithNoData(dropsOutboundIPv6: true, question: aaaa),
            "the data path drops v6 → AAAA must be answered NODATA so the client uses A"
        )
        XCTAssertFalse(
            ChainedIPv6DNSPolicy.answersWithNoData(dropsOutboundIPv6: false, question: aaaa),
            "v6 is carried/direct (split-tunnel or DNS-only) → AAAA forwards normally"
        )
    }

    func testOnlyAAAAIsSuppressed() throws {
        // Every other record type must forward even when v6 is dropped: A is the path we want the
        // client on; TXT/SRV/SVCB/HTTPS/unknown carry no bare v6 address to answer NODATA here. An
        // HTTPS/SVCB `ipv6hint` is handled on a SEPARATE path (`stripsIPv6Hint` +
        // `DNSServiceBinding.strippingIPv6Hints` rewrite the answer), so it must NOT be NODATA'd.
        let others: [(DNSRecordType, UInt16)] = [(.a, 1), (.txt, 16), (.srv, 33), (.svcb, 64), (.https, 65), (.unknown, 0)]
        for (recordType, raw) in others {
            XCTAssertFalse(
                ChainedIPv6DNSPolicy.answersWithNoData(dropsOutboundIPv6: true, question: try question(recordType, raw: raw)),
                "\(recordType) must still forward even when v6 is dropped"
            )
        }
        XCTAssertTrue(ChainedIPv6DNSPolicy.answersWithNoData(dropsOutboundIPv6: true, question: try question(.aaaa, raw: 28)))
    }

    func testIsIPv6AddressQueryClassifiesOnlyAAAA() throws {
        XCTAssertTrue(ChainedIPv6DNSPolicy.isIPv6AddressQuery(try question(.aaaa, raw: 28)))
        for (recordType, raw) in [(DNSRecordType.a, UInt16(1)), (.https, 65), (.unknown, 0)] {
            XCTAssertFalse(ChainedIPv6DNSPolicy.isIPv6AddressQuery(try question(recordType, raw: raw)))
        }
    }

    func testStripsIPv6HintOnlyForServiceBindingQueriesWhileDroppingIPv6() throws {
        // The strip applies to exactly the two service binding record types, and only when the data
        // path drops v6 — mirroring `answersWithNoData` for AAAA.
        for (recordType, raw) in [(DNSRecordType.https, UInt16(65)), (.svcb, 64)] {
            let query = try question(recordType, raw: raw)
            XCTAssertTrue(
                ChainedIPv6DNSPolicy.stripsIPv6Hint(dropsOutboundIPv6: true, question: query),
                "\(recordType): drops v6 → the ipv6hint must be stripped from the answer"
            )
            XCTAssertFalse(
                ChainedIPv6DNSPolicy.stripsIPv6Hint(dropsOutboundIPv6: false, question: query),
                "\(recordType): v6 direct (split/DNS-only) → the hint is valid, leave it"
            )
        }
        // A/AAAA/TXT are never service binding records, so they are never stripped.
        for (recordType, raw) in [(DNSRecordType.a, UInt16(1)), (.aaaa, 28), (.txt, 16), (.unknown, 0)] {
            XCTAssertFalse(
                ChainedIPv6DNSPolicy.stripsIPv6Hint(dropsOutboundIPv6: true, question: try question(recordType, raw: raw))
            )
        }
    }

    func testIsServiceBindingQueryClassifiesOnlyHTTPSAndSVCB() throws {
        XCTAssertTrue(ChainedIPv6DNSPolicy.isServiceBindingQuery(try question(.https, raw: 65)))
        XCTAssertTrue(ChainedIPv6DNSPolicy.isServiceBindingQuery(try question(.svcb, raw: 64)))
        for (recordType, raw) in [(DNSRecordType.a, UInt16(1)), (.aaaa, 28), (.txt, 16), (.srv, 33), (.unknown, 0)] {
            XCTAssertFalse(ChainedIPv6DNSPolicy.isServiceBindingQuery(try question(recordType, raw: raw)))
        }
    }
}
