import XCTest

@testable import LavaSecChainedUpstream

/// Cryptokey routing: a peer may only send packets whose SOURCE lies inside the range it was
/// assigned.
///
/// Without this, authentication proves only that a datagram came from the peer — not that the
/// peer may claim the address inside it. boringtun enforces it in its `Device` layer; we use
/// `Tunn` directly, which does not. So on our path the check exists here or nowhere, and
/// nowhere means a peer can hand us a packet claiming any source at all and every app on the
/// device treats it as genuine.
final class ChainedAllowedIPsTests: XCTestCase {
    private func octets(_ text: String) -> [UInt8] {
        // Built through the prefix parser so the tests and the code agree on byte order.
        ChainedIPPrefix(text)!.networkBytes
    }

    // MARK: - Fail closed

    func testAnEmptyListIsAConfigErrorNotAnEmptyAllowlist() {
        // Parsing "" succeeded with no prefixes, and since an empty set permits nothing every
        // packet then surfaced as `dropSpoofedSource` — a blank `AllowedIPs =` line presented
        // as the peer attacking. The fail-closed rule on the empty SET is unchanged; it just
        // cannot be reached by parsing a configuration any more.
        XCTAssertNil(ChainedAllowedIPs(list: ""))
        XCTAssertNil(ChainedAllowedIPs(list: "   "))
        XCTAssertNil(ChainedAllowedIPs(list: ",,"))
        XCTAssertNotNil(ChainedAllowedIPs(list: "10.0.0.0/8"))
    }

    func testTheVerdictForACapturedAddressMatchesTheArrayForm() {
        // The inbound path holds a WireGuardSourceAddress, whose `octets` accessor allocates
        // and says so. Calling it per packet would put an array allocation on the hot path of
        // a process bounded at ~50 MB, for a check whose whole job is to be cheap enough to
        // run on every packet.
        //
        // The two overloads must agree, or the cheap one is a second implementation that can
        // drift from the one the tests cover.
        let allowed = ChainedAllowedIPs(list: "10.8.0.0/24")!
        for text in ["10.8.0.1", "10.9.0.1", "10.8.0.255"] {
            var captured = WireGuardSourceAddress()
            let bytes = octets(text)
            captured.withMutableStorage { pointer in
                for (index, byte) in bytes.enumerated() { pointer[index] = byte }
            }
            captured.setByteCount(UInt32(bytes.count))
            XCTAssertEqual(
                allowed.verdict(source: captured, byteCount: 60),
                allowed.verdict(sourceOctets: bytes, byteCount: 60),
                text)
        }
    }

    func testAnEmptySetPermitsNothingRatherThanEverything() {
        // The classic inversion: reading "no addresses granted" as "unrestricted" turns the
        // most restrictive configuration into the most permissive one.
        let allowed = ChainedAllowedIPs([])
        XCTAssertFalse(allowed.permits(sourceOctets: octets("10.0.0.1")))
        XCTAssertFalse(allowed.permits(sourceOctets: octets("0.0.0.0")))
        XCTAssertFalse(allowed.permits(sourceOctets: octets("2001:db8::1")))
        XCTAssertEqual(
            allowed.verdict(sourceOctets: octets("10.0.0.1"), byteCount: 40),
            .dropSpoofedSource(byteCount: 40))
    }

    func testAPartiallyParseableListIsRejectedWhole() {
        // A partial parse silently NARROWS the allowlist, which fails closed and therefore
        // presents as a working tunnel that drops some traffic — the hardest kind of
        // misconfiguration to diagnose.
        XCTAssertNil(ChainedAllowedIPs(list: "10.0.0.0/8, not-an-address"))
        XCTAssertNil(ChainedAllowedIPs(list: "10.0.0.0/8, 10.0.0.0/33"))
        XCTAssertNotNil(ChainedAllowedIPs(list: "10.0.0.0/8, 2001:db8::/32"))
    }

    func testAnOutOfRangePrefixLengthIsRejectedNotClamped() {
        // Not a typo to round down. Clamping would widen or narrow what a peer may claim
        // without telling anyone.
        XCTAssertNil(ChainedIPPrefix("10.0.0.0/33"))
        XCTAssertNil(ChainedIPPrefix("10.0.0.0/-1"))
        XCTAssertNil(ChainedIPPrefix("2001:db8::/129"))
        XCTAssertNotNil(ChainedIPPrefix("10.0.0.0/32"))
        XCTAssertNotNil(ChainedIPPrefix("2001:db8::/128"))
    }

    // MARK: - The spoof this exists to stop

    func testAPeerCannotClaimAnAddressOutsideItsRange() {
        // The concrete attack. A peer assigned 10.8.0.0/24 hands us a packet sourced from the
        // in-tunnel resolver's address, or from a bank. Authentication passes — it really is
        // the peer — and without this check the packet is written into the tunnel and every
        // app treats it as having come from the address it claims.
        let allowed = ChainedAllowedIPs(list: "10.8.0.0/24")!
        XCTAssertTrue(allowed.permits(sourceOctets: octets("10.8.0.7")))

        for spoofed in ["10.255.0.1", "1.1.1.1", "127.0.0.1", "10.9.0.7", "10.7.255.255"] {
            XCTAssertFalse(
                allowed.permits(sourceOctets: octets(spoofed)),
                "\(spoofed) is outside 10.8.0.0/24 and must be refused")
            XCTAssertEqual(
                allowed.verdict(sourceOctets: octets(spoofed), byteCount: 60),
                .dropSpoofedSource(byteCount: 60))
        }
    }

    func testTheTunnelsOwnResolverAddressIsNotSpecialCasedButIsStillRefused() {
        // Worth its own assertion because it is the highest-value spoof on this device: a
        // packet claiming to come from 10.255.0.1 would look like an answer from our own
        // in-tunnel resolver. It is refused by the ordinary range rule, not by a special case
        // — a special case would be one more thing to get wrong.
        let allowed = ChainedAllowedIPs(list: "10.8.0.0/24")!
        XCTAssertFalse(allowed.permits(sourceOctets: octets("10.255.0.1")))

        // And a peer legitimately assigned that range IS allowed it. The check is about the
        // configured range, not about a blocklist of interesting addresses.
        let wide = ChainedAllowedIPs(list: "10.0.0.0/8")!
        XCTAssertTrue(wide.permits(sourceOctets: octets("10.255.0.1")))
    }

    // MARK: - Bit-level matching

    func testAPartialByteBoundaryIsRespected() {
        // Comparing whole bytes only turns every /9…/15 into a /8 and admits an eighth of the
        // internet on a rule that reads as narrow. 10.128.0.0/9 covers 10.128–10.255 and must
        // not cover 10.0–10.127.
        let allowed = ChainedAllowedIPs(list: "10.128.0.0/9")!
        XCTAssertTrue(allowed.permits(sourceOctets: octets("10.128.0.1")))
        XCTAssertTrue(allowed.permits(sourceOctets: octets("10.255.255.255")))
        XCTAssertFalse(allowed.permits(sourceOctets: octets("10.127.255.255")))
        XCTAssertFalse(allowed.permits(sourceOctets: octets("10.0.0.1")))
    }

    func testEveryIPv4PrefixLengthDividesTheSpaceCorrectly() {
        // Walks all 33 lengths against a boundary pair, so an off-by-one in the mask cannot
        // hide in the lengths a hand-picked case did not cover.
        for length in 0...32 {
            guard let prefix = ChainedIPPrefix("128.0.0.0/\(length)") else {
                return XCTFail("/\(length) should parse")
            }
            XCTAssertTrue(prefix.contains(octets("128.0.0.0")), "/\(length) must contain its own network")
            if length == 0 {
                XCTAssertTrue(prefix.contains(octets("0.0.0.0")), "/0 matches everything")
            } else {
                XCTAssertFalse(
                    prefix.contains(octets("0.0.0.0")),
                    "/\(length) must not match an address differing in the first bit")
            }
        }
    }

    func testAHostPrefixMatchesExactlyOneAddress() {
        let allowed = ChainedAllowedIPs(list: "203.0.113.9/32")!
        XCTAssertTrue(allowed.permits(sourceOctets: octets("203.0.113.9")))
        XCTAssertFalse(allowed.permits(sourceOctets: octets("203.0.113.8")))
        XCTAssertFalse(allowed.permits(sourceOctets: octets("203.0.113.10")))
    }

    func testABareAddressIsASingleHost() {
        // A `.conf` may omit the length. Reading it as a wildcard would be catastrophic; it is
        // read as /32 or /128.
        XCTAssertEqual(ChainedIPPrefix("203.0.113.9")?.prefixLength, 32)
        XCTAssertEqual(ChainedIPPrefix("2001:db8::1")?.prefixLength, 128)
        let allowed = ChainedAllowedIPs(list: "203.0.113.9")!
        XCTAssertFalse(allowed.permits(sourceOctets: octets("203.0.113.10")))
    }

    func testHostBitsAreMaskedSoTwoSpellingsOfOneRuleAgree() {
        // 10.1.2.3/8 and 10.0.0.0/8 are the same rule. Two spellings behaving differently is
        // how an allowlist quietly gains a hole.
        XCTAssertEqual(ChainedIPPrefix("10.1.2.3/8"), ChainedIPPrefix("10.0.0.0/8"))
        XCTAssertTrue(ChainedIPPrefix("10.1.2.3/8")!.contains(octets("10.99.0.1")))
    }

    // MARK: - Families never cross

    func testAnIPv4SourceIsNotMatchedByAnIPv6Rule() {
        // The engine reports v4 and v6 inner packets separately, so treating an
        // IPv4-mapped v6 prefix as authority over a v4 address would let a v6 rule silently
        // widen the v4 allowlist.
        let v6Only = ChainedAllowedIPs(list: "::/0")!
        XCTAssertFalse(v6Only.permits(sourceOctets: octets("10.0.0.1")))
        XCTAssertTrue(v6Only.permits(sourceOctets: octets("2001:db8::1")))

        let mapped = ChainedAllowedIPs(list: "::ffff:0:0/96")!
        XCTAssertFalse(
            mapped.permits(sourceOctets: octets("10.0.0.1")),
            "an IPv4-mapped v6 prefix must not authorize a bare v4 source")
    }

    func testAnIPv6SourceIsNotMatchedByAnIPv4Rule() {
        let v4Only = ChainedAllowedIPs(list: "0.0.0.0/0")!
        XCTAssertTrue(v4Only.permits(sourceOctets: octets("10.0.0.1")))
        XCTAssertFalse(v4Only.permits(sourceOctets: octets("2001:db8::1")))
    }

    func testDefaultRoutesForBothFamiliesPermitTheirOwn() {
        // The ordinary chained configuration: the peer carries everything.
        let allowed = ChainedAllowedIPs(list: "0.0.0.0/0, ::/0")!
        XCTAssertTrue(allowed.permits(sourceOctets: octets("1.1.1.1")))
        XCTAssertTrue(allowed.permits(sourceOctets: octets("2001:db8::1")))
        XCTAssertEqual(
            allowed.verdict(sourceOctets: octets("1.1.1.1"), byteCount: 1280),
            .deliver(byteCount: 1280))
    }

    // MARK: - Malformed input from below

    func testAMalformedSourceLengthIsNotReportedAsASpoof() {
        // An ABI-level impossibility, kept distinct because the two mean different things: one
        // says the peer is lying, the other says our own layers disagree about the address
        // width. Conflating them would send an investigator hunting an attacker for a bug.
        let allowed = ChainedAllowedIPs(list: "0.0.0.0/0, ::/0")!
        for bad in [[], [UInt8(1)], Array(repeating: UInt8(0), count: 5),
                    Array(repeating: UInt8(0), count: 17)] {
            XCTAssertEqual(
                allowed.verdict(sourceOctets: bad, byteCount: 40), .dropMalformedSource,
                "\(bad.count) bytes")
        }
        XCTAssertNotEqual(
            ChainedInboundVerdict.dropMalformedSource.logValue,
            ChainedInboundVerdict.dropSpoofedSource(byteCount: 40).logValue)
    }

    func testNoVerdictDeliversAnythingItShouldNot() {
        let allowed = ChainedAllowedIPs(list: "10.8.0.0/24")!
        XCTAssertTrue(allowed.verdict(sourceOctets: octets("10.8.0.1"), byteCount: 1).deliversToTunnel)
        XCTAssertFalse(allowed.verdict(sourceOctets: octets("10.9.0.1"), byteCount: 1).deliversToTunnel)
        XCTAssertFalse(allowed.verdict(sourceOctets: [], byteCount: 1).deliversToTunnel)
    }

    // MARK: - Logging

    func testTheLogValueNeverCarriesTheRejectedAddress() {
        // A rejected source is the PEER'S claim — arbitrary attacker-chosen bytes. Recording
        // it would put them into a log that travels in a bug report.
        let allowed = ChainedAllowedIPs(list: "10.8.0.0/24")!
        let verdict = allowed.verdict(sourceOctets: octets("203.0.113.9"), byteCount: 60)
        XCTAssertEqual(verdict.logValue, "inbound-drop-source-not-allowed")
        XCTAssertFalse(verdict.logValue.contains("203"))
    }
}
