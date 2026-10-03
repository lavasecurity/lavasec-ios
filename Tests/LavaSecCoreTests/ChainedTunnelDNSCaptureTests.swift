import Foundation
import XCTest

@testable import LavaSecChainedUpstream
@testable import LavaSecKit

/// The S6 merge bar, tunnel leg: with chained latched, our own resolver's query LEAVES
/// THROUGH THE PEER and its answer comes back — asserted on real encrypted bytes, not on a
/// policy verdict (the plan: "asserted by capture, not by reading the code").
///
/// ## Why this is a capture assertion and what it does not cover
///
/// No single executable test can drive `readPackets` → classifier → `serveDNS` →
/// orchestrator → socket: this harness has no physical interface (every byte the runner
/// emits goes to `FakeChannel`), and the resolver-side fakes have no tunnel. So the merge
/// bar is assembled at two seams. THIS file owns the tunnel seam — what the peer actually
/// receives and what a peer answer does on arrival — with real `WireGuardSession`s on both
/// ends, so a query that never reached the peer, or reached it in the clear, fails here.
/// The physical-interface seam is the orchestrator's (`ResolverOrchestratorTests`, executor
/// call counts) and the socket layer's (`ChainedResolverEgressTests.testChainedNeverYields
/// ASystemChosenSocket`, plus the binding pins).
///
/// The production carry is the S8.7b pattern — a socket pinned to the provider's own
/// `virtualInterface`, whose kernel-built packets surface at our `readPackets` — so the
/// packets built here are the shape the kernel produces, and the port claim is what makes
/// the classifier carry them rather than hand them back to the resolver.
final class ChainedTunnelDNSCaptureTests: XCTestCase {
    private let clientAddress: [UInt8] = [10, 64, 0, 5]
    private let resolverAddress: [UInt8] = [10, 64, 0, 1]

    private func harness() throws -> ChainedSessionHarness {
        // AllowedIPs covers the upstream's own network, which is what a real chained config
        // carries — the peer must be entitled to source the resolver's answers or the
        // delivery below is a spoof drop rather than a carry.
        try ChainedSessionHarness(allowedIPs: "0.0.0.0/0")
    }

    func testOurResolverQueryLeavesThroughThePeerRatherThanBeingServedLocally() throws {
        let harness = try harness()
        try harness.completeHandshake()
        let port: UInt16 = 41_000
        // The claim is what tells the classifier this datagram is OURS. Without it the
        // packet is an ordinary client query to port 53 and the resolver would be asked to
        // resolve its own question — the self-resolution loop the registry exists to close.
        XCTAssertNotNil(
            harness.ownResolverPorts.claim(sourcePort: port, protocolNumber: UInt8(IPPROTO_UDP)),
            "the port claim is the precondition for the carve-out")

        let query = ChainedSessionHarness.dnsQueryPacket(
            sourcePort: port, source: clientAddress, destination: resolverAddress)
        harness.runner.handleOutboundBatch(
            [Data(query)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        XCTAssertTrue(
            harness.dnsServer.served.isEmpty,
            "our own resolver's query was handed to the DNS path — the self-resolution loop")
        // THE CAPTURE: the peer really decrypts what we emitted, and it is byte-for-byte
        // the query. A carry that never reached the peer, or reached it unencrypted, cannot
        // produce this.
        let decrypted = try harness.loopBackThroughPeer(query)
        XCTAssertEqual(decrypted, query, "the query did not arrive at the peer intact")
        XCTAssertEqual(harness.runner.snapshotCounters().ownResolverPacketCount, 1)
    }

    func testThePeersAnswerIsDeliveredBackToTheTunnel() throws {
        let harness = try harness()
        try harness.completeHandshake()
        let port: UInt16 = 41_000
        XCTAssertNotNil(
            harness.ownResolverPorts.claim(sourcePort: port, protocolNumber: UInt8(IPPROTO_UDP)))

        let answer = ChainedSessionHarness.dnsResponsePacket(
            destinationPort: port, resolver: resolverAddress, client: clientAddress)
        try harness.deliverRawInnerPacketFromPeer(answer)

        // In production the kernel demultiplexes this to the pinned socket's `recvfrom`;
        // here the observable is that it reached `packetFlow` at all, intact — an answer
        // dropped as a spoofed source, or never delivered, leaves the resolver waiting out
        // its timeout, which the outage cause would then read as a dead resolver.
        XCTAssertEqual(
            harness.writer.written.flatMap { $0 }.map { [UInt8]($0) }, [answer],
            "the resolver's answer was not delivered into the tunnel")
    }

    func testAnAnswerForgedFromOutsideAllowedIPsIsNotDelivered() throws {
        // The anti-spoof gate stays in front of the DNS path: a peer that sources an answer
        // from an address its AllowedIPs does not cover is dropped and counted, so the carry
        // cannot become a way to inject responses past the check every other inner packet
        // gets.
        let harness = try ChainedSessionHarness(allowedIPs: "10.64.0.0/24")
        try harness.completeHandshake()
        let port: UInt16 = 41_000
        XCTAssertNotNil(
            harness.ownResolverPorts.claim(sourcePort: port, protocolNumber: UInt8(IPPROTO_UDP)))

        let forged = ChainedSessionHarness.dnsResponsePacket(
            destinationPort: port, resolver: [203, 0, 113, 9], client: clientAddress)
        try harness.deliverRawInnerPacketFromPeer(forged)

        XCTAssertTrue(
            harness.writer.written.flatMap { $0 }.isEmpty, "a spoofed-source answer was delivered")
        XCTAssertEqual(harness.runner.snapshotCounters().spoofedSourceCount, 1)
    }
}
