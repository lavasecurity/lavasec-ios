import Foundation
import XCTest
import LavaSecDNS
@testable import LavaSecCore

/// Behavioural tests for the pure leak-canary query builder (Slice 2). The builder is data-only, so
/// it gets real tests here rather than a source pin; the QA-gated emitter that SENDS it is pinned in
/// the packet-tunnel suite.
final class DNSLeakCanaryTests: XCTestCase {
    func testDomainEmbedsTheNonceUnderTheInvalidTLD() {
        XCTAssertEqual(DNSLeakCanary.domain(nonce: "abc123"), "abc123.leak-canary.lavasec.invalid")
        // Lowercased, so the emitted QNAME matches the analyzer's lowercased nonce comparison.
        XCTAssertEqual(DNSLeakCanary.domain(nonce: "AbC123"), "abc123.leak-canary.lavasec.invalid")
        // The `.invalid` TLD (RFC 6761) can never resolve — the canary proves escape, not resolution,
        // and a leaked packet can reach no real service.
        XCTAssertTrue(DNSLeakCanary.baseDomain.hasSuffix(".invalid"))
    }

    func testQueryIsAWellFormedSingleQuestionAQueryCarryingTheNonce() {
        let nonce = "n0nceabc"
        let query = DNSLeakCanary.query(nonce: nonce, transactionID: 0x1234)
        let bytes = [UInt8](query)

        XCTAssertGreaterThan(bytes.count, 12, "must have a 12-byte header plus a question")
        XCTAssertEqual(be16(bytes, 0), 0x1234, "transaction id")
        XCTAssertEqual(be16(bytes, 2), 0x0100, "flags: standard query, recursion desired")
        XCTAssertEqual(be16(bytes, 4), 1, "QDCOUNT == 1")
        XCTAssertEqual(be16(bytes, 6), 0, "ANCOUNT == 0")

        // The nonce must appear as its own length-prefixed QNAME label, so it is greppable in a
        // capture and matches the analyzer's `--canary-nonce`.
        let nonceLabel = [UInt8(nonce.utf8.count)] + Array(nonce.utf8)
        XCTAssertNotNil(firstIndex(of: nonceLabel, in: bytes), "the nonce must be a QNAME label")

        // Trailing QTYPE=A(1), QCLASS=IN(1) after the root label.
        XCTAssertEqual(Array(bytes.suffix(4)), [0x00, 0x01, 0x00, 0x01])
    }

    func testEachNonceProducesADistinctQuery() {
        XCTAssertNotEqual(DNSLeakCanary.query(nonce: "run-a"), DNSLeakCanary.query(nonce: "run-b"))
    }

    // MARK: helpers

    private func be16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return start
        }
        return nil
    }
}
