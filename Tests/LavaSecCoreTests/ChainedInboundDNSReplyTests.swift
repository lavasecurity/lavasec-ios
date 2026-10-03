import Darwin
import XCTest

@testable import LavaSecChainedUpstream

/// The port half of the DNS-reply exclusion: reading a delivered inner IPv4 packet's transport
/// source port to tell an actual DNS reply from ordinary traffic a resolver IP also serves.
///
/// The address half lives in `ChainedSessionRunner` (`ChainedAllowedIPs.permits`); these test the
/// parser in isolation, so the SOURCE ADDRESS here is deliberately arbitrary — this predicate must
/// answer purely from the transport header, never from who sent the packet.
final class ChainedInboundDNSReplyTests: XCTestCase {

    /// An IPv4 packet with a chosen IHL, protocol, fragment offset and transport source port.
    /// The addresses are filler: the parser never reads them.
    private func packet(
        ihlWords: Int = 5,
        protocolNumber: Int32 = IPPROTO_UDP,
        fragmentOffset: UInt16 = 0,
        sourcePort: UInt16? = nil,
        byteCount: Int? = nil
    ) -> [UInt8] {
        let headerLength = ihlWords * 4
        let count = byteCount ?? (headerLength + 8)
        var p = [UInt8](repeating: 0, count: count)
        p[0] = UInt8(0x40 | (ihlWords & 0x0F))
        p[2] = UInt8((count >> 8) & 0xFF)
        p[3] = UInt8(count & 0xFF)
        let frag = fragmentOffset & 0x1FFF
        p[6] = UInt8((frag >> 8) & 0xFF)
        p[7] = UInt8(frag & 0xFF)
        p[9] = UInt8(protocolNumber)
        p[12...15] = [198, 51, 100, 7]
        p[16...19] = [10, 64, 0, 5]
        if let sourcePort, count >= headerLength + 2 {
            p[headerLength] = UInt8((sourcePort >> 8) & 0xFF)
            p[headerLength + 1] = UInt8(sourcePort & 0xFF)
        }
        return p
    }

    private func carriesNonDNS(_ p: [UInt8]) -> Bool {
        p.withUnsafeBytes { ChainedInboundDNSReply.carriesNonDNSSourcePort($0) }
    }


    func testAPortFiftyThreeSourceIsNotCountedAsNonDNS() {
        // A UDP DNS reply leaves the resolver FROM :53. It is the packet the exclusion exists for,
        // so the parser must not call it non-DNS.
        XCTAssertFalse(carriesNonDNS(packet(protocolNumber: IPPROTO_UDP, sourcePort: 53)))
    }

    func testDNSOverTCPSourcePort53IsNotCountedAsNonDNS() {
        // DNS over TCP answers from :53 too, and TCP puts the source port in the same two bytes.
        XCTAssertFalse(carriesNonDNS(packet(protocolNumber: IPPROTO_TCP, sourcePort: 53)))
    }

    func testAnHTTPSSourcePortFromTheResolverIsNonDNS() {
        // The edge this whole change closes: a resolver IP that also serves HTTPS answers from
        // :443. That is general forwarding, not DNS, so the parser reports it non-DNS and the
        // runner counts it.
        XCTAssertTrue(carriesNonDNS(packet(protocolNumber: IPPROTO_TCP, sourcePort: 443)))
    }

    func testAUDPSourcePortOtherThan53IsNonDNS() {
        // Not only TCP: a non-53 UDP source (e.g. QUIC/443) from the resolver address is ordinary
        // traffic and counts.
        XCTAssertTrue(carriesNonDNS(packet(protocolNumber: IPPROTO_UDP, sourcePort: 443)))
    }

    func testANonFirstFragmentIsNotCountedAsNonDNS() {
        // A non-first fragment carries no transport header — the bytes where a port would sit are
        // payload. Even though they read as a non-53 value here, the parser must NOT count it, or a
        // fragmented DNS reply's tails would become false forwarding evidence.
        XCTAssertFalse(
            carriesNonDNS(packet(protocolNumber: IPPROTO_UDP, fragmentOffset: 185, sourcePort: 443)))
    }

    func testANonUDPTCPProtocolIsNotCountedAsNonDNS() {
        // ICMP has no ports, so the parser cannot prove it non-DNS from the header and leaves it
        // excluded (fail-closed for the connect gate). Named as a residual in `ChainedOutageDriver`.
        XCTAssertFalse(carriesNonDNS(packet(protocolNumber: IPPROTO_ICMP, sourcePort: nil)))
    }

    func testATooShortPacketIsNotCountedAsNonDNS() {
        // Below a full IPv4 header there is nothing to read. Excluded rather than guessed.
        XCTAssertFalse(carriesNonDNS([UInt8](repeating: 0, count: 12)))
    }

    func testAPacketTooShortForItsTransportPortIsNotCountedAsNonDNS() {
        // A 20-byte header with only one byte past it cannot yield a two-byte port. The bound is
        // `headerLength + 2`, so a 21-byte packet is excluded.
        XCTAssertFalse(carriesNonDNS(packet(sourcePort: nil, byteCount: 21)))
    }

    func testHeaderOptionsShiftWhereTheSourcePortIsRead() {
        // IHL 6 means a 24-byte header, so the transport source port is at offset 24, not 20. A
        // parser that ignored IHL would read the two option bytes at 20-21 instead — set those to
        // 53 as a trap, and the true source port at 24 to 443. The parser must follow IHL and
        // report non-DNS.
        var p = packet(ihlWords: 6, protocolNumber: IPPROTO_TCP, sourcePort: 443, byteCount: 44)
        p[20] = 0x00
        p[21] = 0x35  // 53 at the wrong offset — a trap for an IHL-blind read
        XCTAssertTrue(carriesNonDNS(p))
    }

    func testAnIPv6PacketIsNotCountedAsNonDNS() {
        // Only the IPv4 delivery path reaches the runner's counter; a version nibble other than 4
        // is rejected rather than misparsed as IPv4.
        var p = packet(protocolNumber: IPPROTO_TCP, sourcePort: 443)
        p[0] = UInt8(0x60 | (5 & 0x0F))  // version 6, same IHL nibble
        XCTAssertFalse(carriesNonDNS(p))
    }
}
