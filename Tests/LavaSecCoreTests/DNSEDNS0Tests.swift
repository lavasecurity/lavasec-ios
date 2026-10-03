import XCTest

@testable import LavaSecDNS

/// The EDNS0 advertisement for tunnel-carried queries (S6, resolved decision 3).
///
/// Every declined shape returns the query UNCHANGED — the degraded answer is "forward
/// exactly what the pre-S6 path would have forwarded", never a rewritten guess.
final class DNSEDNS0Tests: XCTestCase {
    private let cap = DNSEDNS0.tunnelAdvertisedPayloadBytes

    private func plainQuery() -> Data {
        DNSResolverSmokeProbe.query(transactionID: 0x1234, domain: "example.com")
    }

    /// A minimal well-formed OPT: root name, TYPE 41, the given class (advertised size)
    /// and TTL bytes (extended RCODE / version / flags).
    private func optRecord(class klass: UInt16, ttl: [UInt8] = [0, 0, 0, 0]) -> Data {
        var record = Data([0x00, 0x00, 0x29])
        record.append(contentsOf: [UInt8(klass >> 8), UInt8(klass & 0xFF)])
        record.append(contentsOf: ttl)
        record.append(contentsOf: [0x00, 0x00])
        return record
    }

    private func withARCount(_ count: UInt16, _ query: Data) -> Data {
        var bytes = [UInt8](query)
        bytes[10] = UInt8(count >> 8)
        bytes[11] = UInt8(count & 0xFF)
        return Data(bytes)
    }

    func testAQueryWithoutOPTIsLeftAlone() {
        // Absence means the classic 512-byte limit, and that limit is the CLIENT's: the
        // answer is relayed to its stub afterwards, so introducing an advertisement would
        // promise the upstream a size the client never offered and hand a 512-byte receiver
        // up to 1232 bytes (Codex, PR #511).
        let query = plainQuery()
        XCTAssertEqual(DNSEDNS0.cappingAdvertisedPayload(in: query, to: cap), query)
    }

    func testALargerClientOPTIsLoweredToTheCapWithItsFlagsPreserved() {
        // The case this mitigation exists for, and the common one — iOS stubs advertise
        // 1232 or 4096. The DO bit (0x8000 in the TTL flags half) is the client's query
        // semantics and rides along untouched.
        let doBitTTL: [UInt8] = [0x00, 0x00, 0x80, 0x00]
        var query = withARCount(1, plainQuery())
        query.append(optRecord(class: 4096, ttl: doBitTTL))

        let advertised = DNSEDNS0.cappingAdvertisedPayload(in: query, to: cap)

        XCTAssertEqual(advertised.count, query.count, "rewrite, not append")
        XCTAssertEqual(Data(advertised.suffix(11)), optRecord(class: cap, ttl: doBitTTL))
    }

    func testASmallerClientOPTKeepsItsOwnLimit() {
        // NEVER RAISED. The client has to receive the relayed answer; promising the upstream
        // more than it offered is what breaks a stub that sized its buffer to its own
        // advertisement — where it previously got a clean TC.
        for clientSize: UInt16 in [512, 1231] {
            var query = withARCount(1, plainQuery())
            query.append(optRecord(class: clientSize))
            XCTAssertEqual(
                DNSEDNS0.cappingAdvertisedPayload(in: query, to: cap), query,
                "a client limit of \(clientSize) was raised")
        }
    }

    func testAnAuthenticatedQueryIsLeftAlone() {
        // TSIG and SIG(0) authenticate the message BYTES, and the OPT CLASS this would
        // rewrite is inside the MAC's coverage. Nothing here can re-sign, so rewriting
        // would turn a query the upstream would have honoured into one it rejects — a
        // regression against the pre-S6 path, which forwarded it intact.
        for signatureType: UInt16 in [250, 24] {
            var query = withARCount(2, plainQuery())
            query.append(optRecord(class: 4096))
            var signature = Data([0x00])                       // root name
            signature.append(contentsOf: [
                UInt8(signatureType >> 8), UInt8(signatureType & 0xFF),
            ])
            signature.append(contentsOf: [0x00, 0xFF, 0, 0, 0, 0, 0x00, 0x00])
            query.append(signature)
            XCTAssertEqual(
                DNSEDNS0.cappingAdvertisedPayload(in: query, to: cap), query,
                "an authenticated query (type \(signatureType)) had its OPT rewritten")
        }
    }

    func testAResponseIsNeverTouched() {
        var bytes = [UInt8](plainQuery())
        bytes[2] |= 0x80  // QR = 1
        let response = Data(bytes)
        XCTAssertEqual(DNSEDNS0.cappingAdvertisedPayload(in: response, to: cap), response)
    }

    func testProtocolIllegalDoubleOPTIsLeftAlone() {
        var query = withARCount(2, plainQuery())
        query.append(optRecord(class: 4096))
        query.append(optRecord(class: 4096))
        XCTAssertEqual(DNSEDNS0.cappingAdvertisedPayload(in: query, to: cap), query)
    }

    func testANonOPTAdditionalWithNoOPTIsLeftAlone() {
        // The TSIG shape: appending after it breaks its must-be-last rule, and inserting
        // before it means rewriting the message. Unchanged is the safe degraded answer.
        var query = withARCount(1, plainQuery())
        var tsigish = Data([0x01, 0x61, 0x00])  // name "a."
        tsigish.append(contentsOf: [0x00, 0xFA, 0x00, 0xFF, 0, 0, 0, 0, 0x00, 0x00])
        query.append(tsigish)
        XCTAssertEqual(DNSEDNS0.cappingAdvertisedPayload(in: query, to: cap), query)
    }

    func testAnOPTWhoseNameIsNotRootIsLeftAlone() {
        var query = withARCount(1, plainQuery())
        var odd = Data([0xC0, 0x0C])  // compression pointer instead of the root byte
        odd.append(contentsOf: [0x00, 0x29, 0x10, 0x00, 0, 0, 0, 0, 0x00, 0x00])  // class 4096
        query.append(odd)
        XCTAssertEqual(DNSEDNS0.cappingAdvertisedPayload(in: query, to: cap), query)
    }

    func testAMessageWhoseSectionsDoNotAddUpIsLeftAlone() {
        // Trailing bytes: counts and sections disagree, so nothing is rewritten.
        var trailing = plainQuery()
        trailing.append(0xFF)
        XCTAssertEqual(DNSEDNS0.cappingAdvertisedPayload(in: trailing, to: cap), trailing)

        // Truncated mid-question.
        let truncated = plainQuery().prefix(14)
        XCTAssertEqual(
            DNSEDNS0.cappingAdvertisedPayload(in: Data(truncated), to: cap), Data(truncated))

        // ARCOUNT promises a record the message does not carry.
        let lying = withARCount(1, plainQuery())
        XCTAssertEqual(DNSEDNS0.cappingAdvertisedPayload(in: lying, to: cap), lying)
    }

    func testTheCapFitsUnderEveryRepresentableChainedMTU() {
        // The arithmetic the constant's doc claims: boundary floor 1280, minus IPv4 (20)
        // and UDP (8) headers, leaves 1252 — the flag-day 1232 always fits, so no
        // MTU-derived sizing exists to get wrong.
        XCTAssertLessThanOrEqual(Int(cap), 1280 - 20 - 8)
    }

    // MARK: - The full 12-bit RCODE (RFC 6891 §6.1.3, PR #586)

    /// A response carrying one OPT whose TTL high byte holds `extensionByte`. Built from this
    /// file's own `optRecord`/`withARCount` so the OPT layout has one definition here.
    private func responseWithOPT(rcodeNibble: UInt8, extensionByte: UInt8) -> Data {
        var bytes = [UInt8](withARCount(1, plainQuery()))
        bytes[2] |= 0x80                              // QR = response
        bytes[3] = (bytes[3] & 0xF0) | (rcodeNibble & 0x0F)
        var response = Data(bytes)
        response.append(optRecord(class: cap, ttl: [extensionByte, 0, 0, 0]))
        return response
    }

    /// BADVERS is the case a header-nibble reader gets wrong: extended RCODE 16 is `0000 0001
    /// 0000`, so the nibble is ZERO and the message reads NOERROR unless the OPT is consulted.
    func testTheFullRCodeCombinesTheHeaderNibbleWithTheOPTExtension() {
        XCTAssertEqual(
            DNSEDNS0.fullRCode(of: responseWithOPT(rcodeNibble: 0, extensionByte: 1)), 16,
            "BADVERS must read 16, not the zero header nibble")
        // The nibble is the LOW four bits of the same number, so both halves have to combine.
        XCTAssertEqual(
            DNSEDNS0.fullRCode(of: responseWithOPT(rcodeNibble: 2, extensionByte: 1)), 18)
        XCTAssertEqual(
            DNSEDNS0.fullRCode(of: responseWithOPT(rcodeNibble: 3, extensionByte: 0)), 3,
            "an OPT with no extension leaves the nibble as the whole RCODE")
    }

    /// EDNS is optional: a response with no OPT is not unparseable, its RCODE is just the nibble.
    func testAResponseWithNoOPTCarriesItsHeaderRCode() {
        var bytes = [UInt8](plainQuery())
        bytes[2] |= 0x80
        bytes[3] = (bytes[3] & 0xF0) | 3
        XCTAssertEqual(DNSEDNS0.fullRCode(of: Data(bytes)), 3)

        bytes[3] = bytes[3] & 0xF0
        XCTAssertEqual(DNSEDNS0.fullRCode(of: Data(bytes)), 0)
    }

    /// `nil` is "cannot be walked", which callers read as not-resolved — the fail-safe direction.
    func testAnUnwalkableMessageHasNoRCode() {
        XCTAssertNil(DNSEDNS0.fullRCode(of: Data([0x00, 0x01])), "a runt message")

        XCTAssertNil(DNSEDNS0.fullRCode(of: plainQuery()), "a QUERY has no response RCODE")

        var trailing = responseWithOPT(rcodeNibble: 0, extensionByte: 1)
        trailing.append(0xFF)
        XCTAssertNil(
            DNSEDNS0.fullRCode(of: trailing),
            "counts that disagree with the bytes must not yield a guessed RCODE")

        var twoOPTs = withARCount(2, responseWithOPT(rcodeNibble: 0, extensionByte: 1))
        twoOPTs.append(optRecord(class: cap, ttl: [2, 0, 0, 0]))
        XCTAssertNil(DNSEDNS0.fullRCode(of: twoOPTs), "two OPTs is protocol-illegal, not a guess")
    }

}
