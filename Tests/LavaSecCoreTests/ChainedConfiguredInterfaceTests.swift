import XCTest

@testable import LavaSecChainedUpstream
@testable import LavaSecDNS
@testable import LavaSecKit

/// The C7 proofs: the configured `[Interface]` values govern the data path, asserted on
/// PACKETS rather than on the settings object or the plan value.
///
/// The distinction is the constraint's own wording. A wiring bug — the plan carrying the
/// configured address while something downstream still assumes `10.255.0.2` — leaves every
/// value object looking correct and every packet dead. So the address proof reads the inner
/// source of a datagram the peer actually decrypted, and the DNS proofs drive the runner the
/// provider will drive, with the interface numbered off the `10.255.0.0/24` subnet the code
/// grew up on.
final class ChainedConfiguredInterfaceTests: XCTestCase {
    /// An upstream whose client address shares no octet pattern with the DNS-only tunnel
    /// constants, so nothing here can pass by coincidence.
    private static func configuration(clientAddress: String = "10.64.0.5") throws
        -> ChainedUpstreamConfiguration
    {
        try ChainedUpstreamConfiguration(
            endpointHost: "vpn.example.com",
            endpointPort: 51_820,
            peerPublicKey: Data(1...32).base64EncodedString(),
            clientAddress: clientAddress,
            allowedIPs: ["0.0.0.0/0"])
    }

    private static func octets(of address: String) throws -> [UInt8] {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        XCTAssertEqual(parts.count, 4, "not an IPv4 literal: \(address)")
        return parts
    }

    func testTheConfiguredAddressIsTheInnerSourceOfAnEmittedPacket() throws {
        // The full coupling, end to end: the configuration numbers the interface (through
        // the route plan), the interface numbers every outbound packet's source, and the
        // peer's decryption is where a wrong source becomes a silent drop. So the inner
        // packet is built with its source taken from the PLAN — as iOS stamps packets with
        // the installed interface address — and the emitted result is asserted against the
        // CONFIGURATION. If `make(for:)` reverts to the hardcoded 10.255.0.2, the two
        // disagree and this fails; no assertion on the plan value alone can say that.
        let configuration = try Self.configuration(clientAddress: "10.64.0.5")
        let plan = TunnelRoutePlan.make(for: .chainedUpstream(configuration))
        let planSource = try Self.octets(of: plan.tunnelAddress)

        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        let inner = ChainedSessionHarness.ipv4Packet(byteCount: 120, source: planSource)
        harness.runner.handleOutboundBatch([Data(inner)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        let emitted = try XCTUnwrap(
            harness.loopBackThroughPeer(inner),
            "no transport datagram reached the peer — the outbound path dropped the packet")
        XCTAssertEqual(
            Array(emitted[12..<16]),
            try Self.octets(of: configuration.clientAddress),
            "the peer decrypted an inner source that is not the configured [Interface] "
                + "Address — its AllowedIPs would drop this packet, after the tunnel "
                + "reported established"
        )
        XCTAssertEqual(emitted, inner, "the data path must not rewrite the packet")
    }

    func testDNSToTheTunnelResolverIsStillInterceptedFromAnOffSubnetAddress() throws {
        // The plan names this exact regression: "the resolver is no longer on-link" is the
        // plausible-looking reason someone re-couples interception to the tunnel subnet.
        // Interception keys on the destination PORT, so a query sourced from the configured
        // 10.64.0.5 — outside 10.255.0.0/24 entirely — must still reach the DNS server and
        // must never reach the peer.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        let sentBeforeQuery = harness.channel.sent.count

        let query = ChainedSessionHarness.dnsQueryPacket(
            sourcePort: 40_000, source: [10, 64, 0, 5])
        harness.runner.handleOutboundBatch([Data(query)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        XCTAssertEqual(
            harness.dnsServer.served, [Data(query)],
            "a DNS query from the configured off-subnet address was not handed to the "
                + "local resolver path")
        XCTAssertEqual(
            harness.channel.sent.count, sentBeforeQuery,
            "the query leaked toward the peer instead of being intercepted")
    }

    func testTheDNSReplyIsAddressedBackToTheOffSubnetSource() throws {
        // Interception is only half the property — the answer has to make it back to an
        // interface that no longer sits in 10.255.0.0/24. The reply is built from the
        // request's OWN addresses, so no tunnel constant appears anywhere in the exchange.
        let query = ChainedSessionHarness.dnsQueryPacket(
            sourcePort: 40_000, source: [10, 64, 0, 5])
        let request = try XCTUnwrap(IPv4UDPDNSPacket(Data(query)))

        let reply = try XCTUnwrap(
            IPv4UDPDNSPacket.response(to: request, dnsPayload: Data([0xAB, 0xCD])))
        XCTAssertEqual(
            Array(reply[16..<20]), [10, 64, 0, 5],
            "the reply must go back to the querying source, wherever the config numbered it")
        XCTAssertEqual(
            Array(reply[12..<16]), [10, 255, 0, 1],
            "the reply must come FROM the resolver the query was addressed to")
    }
}
