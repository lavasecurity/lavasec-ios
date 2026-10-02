import CryptoKit
import XCTest

@testable import LavaSecChainedUpstream
@testable import LavaSecKit

/// The data path, driven end to end outside a Network Extension.
///
/// Two REAL `WireGuardSession`s — one the runner owns, one standing in as the peer — wired
/// through a fake channel that loops datagrams. Nothing here is a mock of the crypto: the
/// packets are really encrypted, really decrypted, and really checked against AllowedIPs.
final class ChainedSessionRunnerTests: XCTestCase {

    func testRefusedDirectDNSIsNotReleasedAfterTheHandshakeRecovers() throws {
        let harness = try ChainedSessionHarness()
        let packet = Data(ChainedSessionHarness.dnsQueryPacket(sourcePort: 40_001))
        XCTAssertFalse(harness.runner.sendResolverPacket(packet, deadline: MonotonicDeadline(after: 1)))
        XCTAssertEqual(harness.runner.queuedPacketCount(), 0)
        try harness.completeHandshake()
        harness.runner.tick()
        harness.settle()
        XCTAssertNil(try harness.loopBackThroughPeer(Array(packet)),
                     "A refused lookup must not remain inside the engine for a later handshake to send.")
        XCTAssertEqual(harness.runner.snapshotCounters().ownResolverPacketCount, 0)
    }

    func testSaturatedDirectDNSDoesNotSendWhenCapacityReturnsUntilCallerRetries() throws {
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        harness.channel.withholdCompletions = true
        let ordinary = Data(ChainedSessionHarness.ipv4Packet(byteCount: 120, source: [10, 64, 0, 5]))
        harness.submitPaced(ordinary, count: ChainedSessionRunner.inFlightSendBound)
        harness.settle()
        let sentBefore = harness.channel.sent.count
        XCTAssertEqual(sentBefore, ChainedSessionRunner.inFlightSendBound)
        let query = Data(ChainedSessionHarness.dnsQueryPacket(sourcePort: 40_002))
        XCTAssertFalse(harness.runner.sendResolverPacket(query, deadline: MonotonicDeadline(after: 1)))
        XCTAssertEqual(harness.runner.queuedPacketCount(), 0)

        harness.channel.releaseCompletions()
        harness.settle()
        XCTAssertEqual(harness.channel.sent.count, sentBefore,
                       "Transport recovery must not send a lookup that its caller was told was refused.")
        XCTAssertFalse(harness.runner.sendResolverPacket(query, deadline: MonotonicDeadline(after: 0)))
        XCTAssertEqual(harness.channel.sent.count, sentBefore)
        XCTAssertTrue(harness.runner.sendResolverPacket(query, deadline: MonotonicDeadline(after: 1)))
        harness.settle()
        XCTAssertEqual(harness.channel.sent.count, sentBefore + 1)
        XCTAssertEqual(harness.runner.snapshotCounters().ownResolverPacketCount, 1)
        XCTAssertTrue(harness.dnsServer.served.isEmpty)
    }

    func testDirectResolverPacketsUseWireGuardWithoutEnteringClientDNSFilter() throws {
        let harness = try ChainedSessionHarness()
        let packet = Data(ChainedSessionHarness.dnsQueryPacket(sourcePort: 40_000))
        XCTAssertFalse(harness.runner.sendResolverPacket(packet, deadline: MonotonicDeadline(after: 1)))
        try harness.completeHandshake()
        let before = harness.runner.snapshotCounters()
        XCTAssertTrue(harness.runner.sendResolverPacket(packet, deadline: MonotonicDeadline(after: 1)))
        harness.settle()
        XCTAssertEqual(try harness.loopBackThroughPeer(Array(packet)), Array(packet))
        XCTAssertEqual(harness.dnsServer.served.count, 0)
        XCTAssertEqual(harness.runner.snapshotCounters().ownResolverPacketCount - before.ownResolverPacketCount, 1)
        XCTAssertFalse(harness.runner.sendResolverPacket(packet, deadline: MonotonicDeadline(after: 0)))
        harness.runner.shutdown()
        XCTAssertFalse(harness.runner.sendResolverPacket(packet, deadline: MonotonicDeadline(after: 1)))
    }

    func testInputDiagnosticsSeparateDNSMalformedDropsAndRealEncapsulation() throws {
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        let before = harness.runner.snapshotCounters()
        let packets = [
            Data(ChainedSessionHarness.dnsQueryPacket(sourcePort: 40_000)),
            Data([0x45]),
            Data(ChainedSessionHarness.ipv4Packet(byteCount: 120, source: [10, 64, 0, 5])),
        ]
        harness.runner.handleOutboundBatch(packets, protocols: packets.map { _ in NSNumber(value: AF_INET) })
        harness.settle()
        let after = harness.runner.snapshotCounters()
        XCTAssertEqual(after.dnsHandledPacketCount - before.dnsHandledPacketCount, 1)
        XCTAssertEqual(after.malformedPacketCount - before.malformedPacketCount, 1)
        XCTAssertEqual(after.encapsulationAttemptCount - before.encapsulationAttemptCount, 1)
        XCTAssertEqual(after.unfilterableDNSPacketCount - before.unfilterableDNSPacketCount, 0)
        XCTAssertEqual(harness.dnsServer.served.count, 1)
        XCTAssertEqual(after.forwardedNonDNSByteCount, before.forwardedNonDNSByteCount,
                       "Input and engine attempts are diagnostics, not inbound forwarding proof.")
    }

    func testPort853DropsHaveDisjointCountersAndNeverReachThePeerOrDNSHandler() throws {
        let claimed = ChainedClaimedResolverDestinations(resolverAddresses: ["9.9.9.9"])
        for dropsEveryDestination in [false, true] {
            let harness = try ChainedSessionHarness(
                dropsUnfilterableEncryptedDNS: dropsEveryDestination,
                claimedResolverDestinations: ChainedClaimedResolverDestinationsStore(
                    dropsEveryDestination ? .empty : claimed))
            try harness.completeHandshake()
            let before = harness.runner.snapshotCounters()
            let sentBefore = harness.channel.sent.count

            var plainDNS = ChainedSessionHarness.ipv4Packet(byteCount: 40, source: [10, 64, 0, 5])
            plainDNS[16...19] = [9, 9, 9, 9]
            plainDNS[23] = 53
            var dot = plainDNS
            dot[22] = 3
            dot[23] = 85
            var doq = ChainedSessionHarness.dnsQueryPacket(
                sourcePort: 40_001, source: [10, 64, 0, 5], destination: [9, 9, 9, 9])
            doq[22] = 3
            doq[23] = 85
            var https = plainDNS
            https[22] = 1
            https[23] = 187
            let packets = [plainDNS, dot, doq, https].map { Data($0) }
            harness.runner.handleOutboundBatch(
                packets, protocols: packets.map { _ in NSNumber(value: AF_INET) })
            harness.settle()

            let after = harness.runner.snapshotCounters()
            XCTAssertEqual(after.unfilterableDNSPacketCount - before.unfilterableDNSPacketCount, 1)
            XCTAssertEqual(
                after.unfilterableEncryptedDNSPacketCount - before.unfilterableEncryptedDNSPacketCount, 2)
            XCTAssertEqual(after.malformedPacketCount - before.malformedPacketCount, 0)
            XCTAssertEqual(after.dnsHandledPacketCount - before.dnsHandledPacketCount, 0)
            XCTAssertEqual(after.encapsulationAttemptCount - before.encapsulationAttemptCount, 1)
            XCTAssertTrue(harness.dnsServer.served.isEmpty)
            XCTAssertEqual(harness.runner.queuedPacketCount(), 0)
            XCTAssertEqual(harness.channel.sent.count - sentBefore, 1)
            XCTAssertEqual(try harness.loopBackThroughPeer(https), https,
                           "only ordinary HTTPS may reach the peer; DNS policy drops stay local")
        }
    }

    func testAPacketMakesItThroughTheTunnelAndBackOut() throws {
        let harness = try ChainedSessionHarness()
        // The handshake first: before a session is current the engine answers `encapsulate`
        // with a handshake initiation and queues the packet, so a round trip asserted without
        // it would be asserting on the wrong datagram.
        try harness.completeHandshake()
        let packet = ChainedSessionHarness.ipv4Packet(byteCount: 200, source: [10, 64, 0, 5])

        harness.runner.handleOutboundBatch([Data(packet)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        // The peer received a real datagram and decrypted a real packet.
        XCTAssertFalse(harness.channel.sent.isEmpty, "nothing reached the channel")
        let delivered = try harness.loopBackThroughPeer(packet)
        XCTAssertEqual(delivered, packet, "the packet did not survive the round trip")
    }

    func testTheDrainLoopStopsOnAnythingThatIsNotASend() throws {
        // `.none` carries a byte count of ZERO. A loop bounded on `endsSession` rather than
        // `terminatesDrain` would keep going on it and send the stale contents of the scratch
        // buffer as a datagram — a real transmission of whatever the last packet left behind.
        let harness = try ChainedSessionHarness()
        harness.runner.handleOutboundBatch(
            [Data(ChainedSessionHarness.ipv4Packet(byteCount: 120, source: [10, 64, 0, 5]))],
            protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        XCTAssertFalse(harness.channel.sent.contains { $0.isEmpty }, "the drain sent an empty datagram")
        XCTAssertTrue(
            harness.channel.sent.allSatisfy { $0.count >= WireGuardSession.datagramOverheadByteCount },
            "the drain sent a datagram smaller than the transport overhead — stale scratch bytes")
    }

    func testTerminatesDrainMeansExactlyNotASend() {
        // The drain loop is bounded by pattern-matching on `.sendToPeer`, and the policy calls
        // the same condition `terminatesDrain`. Asserting the equivalence directly is what lets
        // the loop keep ONE bound: a policy that ever labelled a send terminal, or a non-send
        // non-terminal, would diverge from the loop and this fails.
        let actions: [ChainedDataPathAction] = [
            .sendToPeer(byteCount: 100),
            .deliverIPv4(byteCount: 100),
            .dropIPv6(byteCount: 100),
            .idle,
            .dropPacket(reason: .invalidArgument),
            .reconnect(reason: .invalidArgument),
            .callerBug(reason: .invalidArgument),
        ]
        for action in actions {
            let isSend: Bool
            if case .sendToPeer = action { isSend = true } else { isSend = false }
            XCTAssertEqual(
                action.terminatesDrain, !isSend,
                "\(action.logValue) disagrees with the loop bound")
        }
    }

    func testAnInnerSourceOutsideAllowedIPsIsNotDelivered() throws {
        // The peer is authenticated, so these bytes really came from it — and it still may not
        // claim an address it was not granted. Under 0.0.0.0/0 the tunnel would otherwise
        // deliver a packet sourced as the local resolver straight into the DNS path.
        let harness = try ChainedSessionHarness(allowedIPs: "10.64.0.0/24")
        try harness.peerSendsInnerPacket(source: [10, 255, 0, 1])

        XCTAssertTrue(harness.writer.written.isEmpty, "a spoofed inner source was delivered")
        XCTAssertEqual(harness.runner.snapshotCounters().spoofedSourceCount, 1)
    }

    func testAPermittedInnerSourceIsDelivered() throws {
        // The pair to the test above: without this, an implementation that delivers nothing at
        // all would pass the spoofing assertion.
        let harness = try ChainedSessionHarness(allowedIPs: "10.64.0.0/24")
        try harness.peerSendsInnerPacket(source: [10, 64, 0, 5])

        XCTAssertEqual(harness.writer.written.count, 1, "a permitted packet was not delivered")
        XCTAssertEqual(harness.runner.snapshotCounters().spoofedSourceCount, 0)
    }

    func testAPacketFromANonResolverSourceCountsAsForwardingEvidence() throws {
        // `forwardedNonDNSByteCount` is the connect gate's "Protected" signal — general traffic the
        // chain forwarded from the internet. A packet from a web server (not the resolver) counts.
        let harness = try ChainedSessionHarness(
            allowedIPs: "10.64.0.0/24", resolverSourceAddresses: "10.64.0.1")
        try harness.peerSendsInnerPacket(source: [10, 64, 0, 5])

        XCTAssertEqual(harness.writer.written.count, 1, "the packet was delivered")
        XCTAssertGreaterThan(
            harness.runner.snapshotCounters().forwardedNonDNSByteCount, 0,
            "a non-resolver-sourced delivery is forwarding evidence for the gate")
    }

    func testAReplyFromTheResolverIsDeliveredButNotForwardingEvidence() throws {
        // An ACTUAL DNS reply from our own upstream resolver — source ADDRESS the resolver AND
        // transport source PORT 53 — is still delivered to the device, but must NOT count as
        // general forwarding, or a chain that answers its resolver while forwarding nothing else
        // would confirm "Protected" over dead web (Codex, PR #558). The reply is real: UDP from the
        // resolver's :53, not the generic filler `peerSendsInnerPacket` builds (which carries no
        // port 53 and would now count — see the non-DNS case below).
        let harness = try ChainedSessionHarness(
            allowedIPs: "10.64.0.0/24", resolverSourceAddresses: "10.64.0.1")
        try harness.completeHandshake()
        try harness.deliverRawInnerPacketFromPeer(
            ChainedSessionHarness.dnsResponsePacket(destinationPort: 40_000))

        XCTAssertEqual(harness.writer.written.count, 1, "the DNS reply is still delivered to the device")
        XCTAssertEqual(harness.runner.snapshotCounters().spoofedSourceCount, 0)
        XCTAssertEqual(
            harness.runner.snapshotCounters().forwardedNonDNSByteCount, 0,
            "a resolver-sourced reply on port 53 is DNS, not general-traffic forwarding evidence")
    }

    func testNonDNSTrafficFromAResolverIPCountsAsForwarding() throws {
        // A resolver IP does not only serve DNS — 1.1.1.1/8.8.8.8/9.9.9.9 all answer HTTPS on the
        // same address. A delivery FROM the resolver address on a NON-53 transport port is general
        // forwarding, not a DNS reply, so it MUST count toward the connect gate's evidence and the
        // egress-dead arm's forwarding signal. The pre-tighten exclusion dropped it by address
        // alone, which is exactly the device edge PR #567 surfaced (the QA generator aimed only at
        // the resolver IP). Port-aware exclusion — `ChainedInboundDNSReply` — closes it.
        let harness = try ChainedSessionHarness(
            allowedIPs: "10.64.0.0/24", resolverSourceAddresses: "10.64.0.1")
        try harness.completeHandshake()

        // An IPv4 TCP segment FROM the resolver's :443 (HTTPS) back to the client — the SAME source
        // address a DNS reply would carry, a different source port.
        var packet = [UInt8](repeating: 0, count: 40)
        packet[0] = 0x45
        packet[2] = 0x00
        packet[3] = 40
        packet[9] = UInt8(IPPROTO_TCP)
        packet[12...15] = [10, 64, 0, 1]  // the resolver address
        packet[16...19] = [10, 64, 0, 5]  // the client
        packet[20] = UInt8(443 >> 8)  // source port 443
        packet[21] = UInt8(443 & 0xFF)
        try harness.deliverRawInnerPacketFromPeer(packet)

        XCTAssertEqual(harness.writer.written.count, 1, "the packet is delivered to the device")
        XCTAssertEqual(harness.runner.snapshotCounters().spoofedSourceCount, 0)
        XCTAssertGreaterThan(
            harness.runner.snapshotCounters().forwardedNonDNSByteCount, 0,
            "non-DNS traffic from a resolver IP is general forwarding, not a DNS reply")
    }

    // MARK: - Per-destination reachability

    /// The destination every fixture packet is addressed to (`ChainedSessionHarness.ipv4Packet`).
    private static let fixtureDestination: [UInt8] = [93, 184, 216, 34]

    /// Sustained demand on the fixture destination, at the retransmit cadence a stalled
    /// connection actually produces (~1/2/4/8 s), ending exactly on the threshold.
    private func driveSilentDestination(_ harness: ChainedSessionHarness, _ clock: SetTestClock) {
        for second in [0, 1, 3, 7, 15, ChainedDestinationReachabilityPolicy.unansweredThresholdSeconds] {
            clock.set(second)
            harness.runner.handleOutboundBatch(
                [Data(ChainedSessionHarness.taggedPacket(second))],
                protocols: [NSNumber(value: AF_INET)])
            harness.settle()
        }
    }

    func testASilentDestinationBecomesUnansweredAndAnAnswerClearsIt() throws {
        // THE SIGNAL THE 2026-08-27 FIELD CAPTURE HAD NO WAY TO PRODUCE. The chain was up, the
        // handshake was live, `forwardedNonDNSByteCount` stood at 338311 — equal to
        // `receivedByteCount` to the byte, because in split tunnel the resolver sits inside the
        // claimed range and its replies land in that counter (PR #558) — and the one host the
        // user wanted answered nothing. Every aggregate read healthy; this one does not.
        let clock = SetTestClock()
        let harness = try ChainedSessionHarness(reachabilityClock: clock)
        try harness.completeHandshake()
        driveSilentDestination(harness, clock)

        let silent = harness.runner.snapshotCounters()
        XCTAssertEqual(
            silent.unansweredDestinationCount, 1,
            "a destination under sustained demand with nothing coming back read as healthy")
        XCTAssertEqual(
            silent.longestUnansweredDestinationSeconds,
            ChainedDestinationReachabilityPolicy.unansweredThresholdSeconds)

        // One packet back is the whole answer: the window closes on evidence, not on a timer.
        clock.set(ChainedDestinationReachabilityPolicy.unansweredThresholdSeconds + 1)
        try harness.deliverInnerPacketFromPeer(source: Self.fixtureDestination)
        let answered = harness.runner.snapshotCounters()
        XCTAssertEqual(answered.unansweredDestinationCount, 0)
        XCTAssertEqual(answered.longestUnansweredDestinationSeconds, 0)
    }

    func testAResolverReplyDoesNotAnswerForTheHostTheUserWanted() throws {
        // The failure mode per-destination exists to survive, stated as a test. A resolver that
        // answers while the wanted host does not is EXACTLY the 2026-08-27 capture, and it is why
        // the receipt seam carries no DNS exclusion: the resolver is one row and the host is
        // another, so its liveness cannot stand in for anyone else's.
        let clock = SetTestClock()
        let harness = try ChainedSessionHarness(reachabilityClock: clock)
        try harness.completeHandshake()
        driveSilentDestination(harness, clock)

        try harness.deliverInnerPacketFromPeer(source: [100, 100, 100, 100])
        XCTAssertEqual(
            harness.runner.snapshotCounters().unansweredDestinationCount, 1,
            "a reply from an unrelated address closed the wanted host's window")
    }

    func testTheReachabilityLevelsAreStampedFromTheLiveTable() throws {
        // LEVELS, not tallies. Reading them must not move them — a snapshot that accumulated
        // would report a wait growing with how often the driver happened to poll.
        let clock = SetTestClock()
        let harness = try ChainedSessionHarness(reachabilityClock: clock)
        try harness.completeHandshake()
        driveSilentDestination(harness, clock)

        let first = harness.runner.snapshotCounters()
        let second = harness.runner.snapshotCounters()
        XCTAssertEqual(first.unansweredDestinationCount, second.unansweredDestinationCount)
        XCTAssertEqual(
            first.longestUnansweredDestinationSeconds, second.longestUnansweredDestinationSeconds)
    }

    func testAChannelRebindDoesNotForgetAnUnansweredDestination() throws {
        // The deliberate difference from `testAChannelRebindResetsTheForwardingEvidence` below.
        // That counter resets because the connect gate must require forwarding from the transport
        // that is live NOW. This one must NOT: a rebind keeps the WireGuard session, so the user
        // is still waiting on the same host, and zeroing their wait at a network handoff would
        // hide the failure at the moment it is most likely to be real.
        let clock = SetTestClock()
        let harness = try ChainedSessionHarness(reachabilityClock: clock)
        try harness.completeHandshake()
        try harness.peerSendsInnerPacket(source: [10, 64, 0, 5])
        driveSilentDestination(harness, clock)
        XCTAssertEqual(harness.runner.snapshotCounters().unansweredDestinationCount, 1)

        XCTAssertEqual(harness.runner.adoptChannel(RebindableFakeChannel()), .rebound)
        let afterRebind = harness.runner.snapshotCounters()
        XCTAssertEqual(
            afterRebind.forwardedNonDNSByteCount, 0,
            "the forwarding evidence must still reset — that contract is unchanged")
        XCTAssertEqual(
            afterRebind.unansweredDestinationCount, 1,
            "a network handoff forgot a wait the user is still living through")
        XCTAssertEqual(
            afterRebind.longestUnansweredDestinationSeconds,
            ChainedDestinationReachabilityPolicy.unansweredThresholdSeconds)
    }

    func testAChannelRebindResetsTheForwardingEvidence() throws {
        // The connect gate must require forwarding from the transport that is live NOW. A rebind
        // (network handoff) keeps the WG session but swaps the channel WITHOUT bumping sessionGeneration,
        // so `forwardedNonDNSByteCount` must reset — else "Protected" could certify from bytes the
        // RETIRED channel forwarded while the replacement socket has received nothing (Codex, PR #558).
        let harness = try ChainedSessionHarness(
            allowedIPs: "10.64.0.0/24", resolverSourceAddresses: "10.64.0.1")
        try harness.peerSendsInnerPacket(source: [10, 64, 0, 5])
        XCTAssertGreaterThan(
            harness.runner.snapshotCounters().forwardedNonDNSByteCount, 0,
            "the old transport forwarded — evidence accrued")

        let beforeTransport = try XCTUnwrap(harness.runner.sampleStatistics()).transportGeneration
        XCTAssertEqual(harness.runner.adoptChannel(RebindableFakeChannel()), .rebound)
        XCTAssertEqual(try XCTUnwrap(harness.runner.sampleStatistics()).transportGeneration, beforeTransport + 1)
        XCTAssertEqual(
            harness.runner.snapshotCounters().forwardedNonDNSByteCount, 0,
            "a rebind resets the forwarding evidence so the gate requires the new transport")
    }

    /// Our own carved-out resolver query must reach encapsulation AND be counted.
    ///
    /// The counter is not decoration. `.encapsulateOwnResolverQuery` is a new case, and the
    /// obvious way to get the switch compiling again is to add it to the `break` arm beside the
    /// two drops — which would silently discard our own retry and look exactly like the
    /// truncation policy working as designed.
    func testAnOwnResolverQueryIsEncapsulatedAndCounted() throws {
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()

        // An IPv4 TCP segment to port 53 from a source port this process holds.
        var packet = [UInt8](repeating: 0, count: 40)
        packet[0] = 0x45
        packet[2] = 0x00
        packet[3] = 40
        packet[9] = UInt8(IPPROTO_TCP)
        packet[12...15] = [10, 255, 0, 2]
        packet[16...19] = [8, 8, 8, 8]
        let sourcePort: UInt16 = 51_000
        packet[20] = UInt8(sourcePort >> 8)
        packet[21] = UInt8(sourcePort & 0xFF)
        packet[22] = 0
        packet[23] = 53
        XCTAssertNotNil(
            harness.ownResolverPorts.claim(sourcePort: sourcePort, protocolNumber: UInt8(IPPROTO_TCP)))

        let sentBefore = harness.channel.sent.count
        harness.runner.handleOutboundBatch([Data(packet)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        XCTAssertEqual(
            harness.runner.snapshotCounters().ownResolverPacketCount, 1,
            "the carve-out must be counted, or it is invisible in a device log")
        XCTAssertGreaterThan(
            harness.channel.sent.count, sentBefore,
            "our own retry was counted but never encapsulated — the switch arm drops it")
    }

    /// A parked own-resolver packet is counted ONCE, at the release that carries it.
    ///
    /// Under back-pressure `encapsulateOnQueue` parks the packet and `releaseStored()`
    /// RE-CLASSIFIES it, so a counter incremented at classification tallies the same packet
    /// twice — and would count a packet whose claim expired while parked despite it never being
    /// carried. `mayReclaim` cannot stand in for "this is a re-classification": the first pass
    /// also passes false whenever something is already parked (Codex, PR #491).
    func testAParkedOwnResolverQueryIsCountedOnceNotTwice() throws {
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        let sourcePort: UInt16 = 51_000
        XCTAssertNotNil(
            harness.ownResolverPorts.claim(
                sourcePort: sourcePort, protocolNumber: UInt8(IPPROTO_TCP)))

        // Withhold completions so outstanding sends accumulate and the next packet PARKS
        // rather than reaching the engine.
        harness.channel.withholdCompletions = true
        let filler = Data(ChainedSessionHarness.taggedPacket(1))
        harness.submitPaced(filler, count: ChainedSessionRunner.inFlightSendBound + 2)
        harness.settle()

        var packet = [UInt8](repeating: 0, count: 40)
        packet[0] = 0x45
        packet[3] = 40
        packet[9] = UInt8(IPPROTO_TCP)
        packet[12...15] = [10, 255, 0, 2]
        packet[16...19] = [8, 8, 8, 8]
        packet[20] = UInt8(sourcePort >> 8)
        packet[21] = UInt8(sourcePort & 0xFF)
        packet[22] = 0
        packet[23] = 53

        harness.runner.handleOutboundBatch(
            [Data(packet)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        // Now let everything drain, which re-classifies whatever parked.
        harness.channel.releaseCompletions()
        harness.settle()

        XCTAssertEqual(
            harness.runner.snapshotCounters().ownResolverPacketCount, 1,
            "the parked packet was classified twice, so the carve-out counter double-counts "
                + "under ordinary back-pressure and is neither a packet count nor a carried count")
    }

    // MARK: - Transport rebind (R2)

    /// A rebind with no current keypair must REPORT that, not claim a probe went out.
    ///
    /// `Tunn::encapsulate` takes the keepalive branch only inside
    /// `if let Some(ref session) = self.sessions[current % N_SESSIONS]`. With none it queues the
    /// packet — a zero-length one takes a slot like any other — and returns a handshake
    /// initiation, which answers `Done` when a handshake is already in flight. Zero bytes on the
    /// new socket, no counter, no event. The driver would then wait out a confirmation deadline
    /// for a probe that was never emitted.
    func testAdoptingAChannelWithNoKeypairReportsItRatherThanProbing() throws {
        let harness = try ChainedSessionHarness()
        // No handshake completed, so no keypair is current.
        let replacement = RebindableFakeChannel()

        let outcome = harness.runner.adoptChannel(replacement)

        XCTAssertEqual(
            outcome, .noCurrentSession,
            "the runner reported a successful rebind while the engine had no session to send a "
                + "keepalive with, so nothing went out and nothing can ever confirm it")
        XCTAssertEqual(
            replacement.sentCount, 0,
            "something was sent without a keypair — that is a handshake, not a keepalive")
    }

    /// A keepalive goes out on the new transport once a keypair IS current.
    func testAdoptingAChannelWithALiveKeypairSendsAKeepaliveOnIt() throws {
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        let replacement = RebindableFakeChannel()

        let outcome = harness.runner.adoptChannel(replacement)

        XCTAssertEqual(outcome, .rebound)
        XCTAssertGreaterThan(
            replacement.sentCount, 0,
            "the transport was swapped but nothing was sent on it, so the rebind cannot be "
                + "distinguished from a swap onto a dead socket")
    }

    /// A late completion from the RETIRED transport must not touch the new one's back-pressure.
    ///
    /// Nothing obliges a transport to fire the completions it holds when it is closed — the
    /// protocol contract is two words, and this repo's own fake proves the hole with a literal
    /// empty `close()`. So a retired channel's completions may arrive late, and crediting them
    /// would run `channelResumed()` → `max(0, n - 1)` → `releaseStored()` → refill to the bound,
    /// leaving twice the bound genuinely outstanding while the counter reads the bound. The
    /// `max(0,)` is exactly what hides it.
    func testARetiredChannelsLateCompletionCannotResumeTheNewOne() throws {
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()

        // Withhold completions so sends are genuinely outstanding on the OLD channel.
        harness.channel.withholdCompletions = true
        harness.submitPaced(Data(ChainedSessionHarness.taggedPacket(1)), count: 4)
        harness.settle()

        let replacement = RebindableFakeChannel()
        XCTAssertEqual(harness.runner.adoptChannel(replacement), .rebound)

        // The REPLACEMENT withholds too. An inline-completing channel never accumulates
        // outstanding sends, so nothing parks and a spurious release has nothing to release —
        // which is why two earlier versions of this test survived the mutation.
        replacement.withholdCompletions = true
        harness.submitPaced(Data(ChainedSessionHarness.taggedPacket(2)),
                            count: ChainedSessionRunner.inFlightSendBound + 8)
        harness.settle()
        let atBound = replacement.sentCount

        // The retired channel answers everything it was holding, late.
        harness.channel.releaseCompletions()
        harness.settle()

        // THE ASSERTION THIS TEST FIRST SHIPPED WITH WAS `XCTAssertFalse(a && b)`, which passes
        // whenever either half is false — it could not fail, and the mutation proved it by
        // surviving. The observable is an OVERSHOOT: each late completion credited to the new
        // transport runs `channelResumed()` → `max(0, n - 1)` → `releaseStored()`, releasing
        // another packet onto a socket that is already at its bound. The `max(0,)` is exactly
        // what stops the counter going negative and being loud about it.
        XCTAssertEqual(
            replacement.sentCount, atBound,
            "late completions from the RETIRED transport released more packets onto the new one, "
                + "so more sends are genuinely outstanding than its counter describes")
    }

    /// A datagram from the RETIRED transport is not evidence about the new one.
    ///
    /// `close()` nils the handler, but a receive already delivered is already on its way — and
    /// crediting it would let the path we just abandoned certify the path we just moved to.
    func testADatagramFromTheRetiredChannelIsNotCreditedAsLiveness() throws {
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        let replacement = RebindableFakeChannel()
        XCTAssertEqual(harness.runner.adoptChannel(replacement), .rebound)
        _ = harness.runner.takeLivenessSample()   // clear the keepalive's own bookkeeping

        // A datagram the peer GENUINELY encrypted to us, arriving on the socket we just
        // abandoned. Replaying one of our own outbound datagrams proved nothing: we cannot
        // decrypt it either way, so it was never credited and the test passed against both
        // versions.
        let inner = ChainedSessionHarness.ipv4Packet(byteCount: 120, source: [10, 0, 0, 2])
        var wire = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        guard case .writeToNetwork(let byteCount) = try harness.peerSession.encapsulate(inner, into: &wire)
        else { return XCTFail("the peer did not produce a datagram") }
        wire.withUnsafeBytes { whole in
            harness.channel.deliver(UnsafeRawBufferPointer(rebasing: whole[..<byteCount]))
        }
        harness.settle()

        XCTAssertFalse(
            harness.runner.takeLivenessSample().sawInboundData,
            "the old socket certified the new one; a rebind onto a dead transport would be "
                + "confirmed by traffic that arrived over the transport it replaced")
    }

    /// The same datagram, overtaken by a rebind DURING the queue hop.
    ///
    /// `testADatagramFromTheRetiredChannelIsNotCreditedAsLiveness` delivers on a channel that was
    /// already retired, which a check at the delivery boundary catches just as well. This is the
    /// ordering only an in-closure check catches: the datagram is delivered while its channel is
    /// still current, and the rebind lands between that delivery and the decrypt running. Both
    /// liveness flags are set inside that work item, so a boundary check certifies the new socket
    /// with traffic that arrived on the old one — cancelling the confirmation deadline, which is
    /// the one thing that would have caught a rebind onto a dead transport (Codex, PR #493).
    func testADatagramOvertakenByARebindDuringTheHopIsNotCredited() throws {
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        _ = harness.runner.takeLivenessSample()

        let inner = ChainedSessionHarness.ipv4Packet(byteCount: 120, source: [10, 0, 0, 2])
        var wire = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        guard case .writeToNetwork(let byteCount) = try harness.peerSession.encapsulate(inner, into: &wire)
        else { return XCTFail("the peer did not produce a datagram") }

        // BOTH ON THE ENGINE QUEUE, IN THIS ORDER, which is what makes the interleaving
        // deterministic rather than a race the test hopes to lose: the delivery parks its decrypt
        // behind the block we are standing in, and the rebind then completes before that decrypt
        // gets to run.
        let replacement = RebindableFakeChannel()
        harness.engineQueue.run {
            wire.withUnsafeBytes { whole in
                harness.channel.deliver(UnsafeRawBufferPointer(rebasing: whole[..<byteCount]))
            }
            XCTAssertEqual(harness.runner.adoptChannel(replacement), .rebound)
        }
        harness.settle()

        XCTAssertFalse(
            harness.runner.takeLivenessSample().sawInboundData,
            "a datagram from the socket the rebind replaced was credited to the socket that "
                + "replaced it — a rebind onto a dead transport now confirms itself")

        // THE CONTROL. The assertion above passes just as well against a harness that cannot
        // credit inbound data at all, and this is the fifth way a mutation sweep has lied on this
        // slice: a double that cannot produce the condition under test.
        var second = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        guard case .writeToNetwork(let secondCount) = try harness.peerSession.encapsulate(inner, into: &second)
        else { return XCTFail("the peer did not produce a second datagram") }
        second.withUnsafeBytes { whole in
            replacement.deliver(UnsafeRawBufferPointer(rebasing: whole[..<secondCount]))
        }
        harness.settle()

        XCTAssertTrue(
            harness.runner.takeLivenessSample().sawInboundData,
            "the same datagram on the CURRENT channel was not credited either, so the assertion "
                + "above says nothing about the generation check")
    }

    /// The same packet from an UNCLAIMED port is still dropped. The negative half, in the runner
    /// rather than the classifier, so the wiring cannot carve out more than the registry says.
    func testAnUnclaimedDNSOverTCPQueryIsStillDropped() throws {
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()

        var packet = [UInt8](repeating: 0, count: 40)
        packet[0] = 0x45
        packet[3] = 40
        packet[9] = UInt8(IPPROTO_TCP)
        packet[12...15] = [10, 255, 0, 2]
        packet[16...19] = [8, 8, 8, 8]
        packet[20] = 0xC0
        packet[21] = 0x00
        packet[22] = 0
        packet[23] = 53

        let sentBefore = harness.channel.sent.count
        harness.runner.handleOutboundBatch([Data(packet)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        XCTAssertEqual(harness.runner.snapshotCounters().ownResolverPacketCount, 0)
        XCTAssertEqual(harness.runner.snapshotCounters().unfilterableDNSPacketCount, 1)
        XCTAssertEqual(harness.runner.snapshotCounters().encapsulationAttemptCount, 0)
        XCTAssertEqual(
            harness.channel.sent.count, sentBefore,
            "an unclaimed DNS-over-TCP query reached the peer — the carve-out is wider than the "
                + "registry")
    }

    func testOutboundIPv6IsDroppedAndCounted() throws {
        let harness = try ChainedSessionHarness()
        var v6 = [UInt8](repeating: 0, count: 60)
        v6[0] = 0x60

        harness.runner.handleOutboundBatch([Data(v6)], protocols: [NSNumber(value: AF_INET6)])
        harness.settle()

        XCTAssertEqual(harness.runner.snapshotCounters().droppedIPv6Count, 1)
        XCTAssertTrue(harness.channel.sent.isEmpty, "an IPv6 packet was encapsulated")
    }

    func testIPv6DropsAreCountedPerDirection() throws {
        // ONE counter for two directions made the device log say the opposite of what happened.
        // `droppedIPv6Count` is documented as packets discarded rather than ENCAPSULATED, and
        // `perform(.dropIPv6)` — the verdict on a DECRYPTED packet from the peer — incremented
        // it too, so an upstream forwarding inner IPv6 was reported as a local client emitting
        // IPv6 it never sent. The two faults are fixed at opposite ends of the tunnel, which is
        // what makes the conflated total unactionable rather than merely imprecise.
        //
        // Both halves are asserted in ONE test because the defect is a relationship between
        // them: either counter alone still moves under the conflation, and only the direction
        // that did NOT move is evidence.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()

        // Outbound: the classifier's verdict, reached before the engine sees the packet at all.
        var outbound = [UInt8](repeating: 0, count: 60)
        outbound[0] = 0x60
        harness.runner.handleOutboundBatch(
            [Data(outbound)], protocols: [NSNumber(value: AF_INET6)])
        harness.settle()

        var counters = harness.runner.snapshotCounters()
        XCTAssertEqual(counters.droppedIPv6Count, 1, "the outbound drop missed the outbound tally")
        XCTAssertEqual(
            counters.droppedInboundIPv6Count, 0,
            "an outbound drop moved the INBOUND tally — the device log blames the peer for a "
                + "packet this client emitted")

        // Inbound: the engine's verdict, on a packet the real peer session really encrypted.
        var inner = [UInt8](repeating: 0, count: 60)
        inner[0] = 0x60
        var wire = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        guard case .writeToNetwork(let byteCount) = try harness.peerSession.encapsulate(
            inner, into: &wire)
        else { return XCTFail("the peer did not produce a datagram") }
        wire.withUnsafeBytes {
            harness.channel.deliver(UnsafeRawBufferPointer(rebasing: $0[..<byteCount]))
        }
        harness.settle()

        counters = harness.runner.snapshotCounters()
        XCTAssertEqual(
            counters.droppedInboundIPv6Count, 1, "the inbound drop missed the inbound tally")
        XCTAssertEqual(
            counters.droppedIPv6Count, 1,
            "an inbound drop moved the OUTBOUND tally — inbound peer traffic is being reported "
                + "as outbound client drops")
    }

    // MARK: - INV-MEM-1

    func testSteadyStateNeitherReallocatesNorQueues() throws {
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 1200, source: [10, 64, 0, 5]))

        harness.submitPaced(packet, count: 2_000)
        harness.settle()

        // A steady state that routes through the queue is a steady state that copies every
        // packet — the queue is for back-pressure, not for the ordinary path.
        XCTAssertEqual(harness.runner.queuedPacketCount(), 0, "steady state parked packets")
        XCTAssertEqual(harness.runner.snapshotCounters().shedPacketCount, 0, "steady state shed packets")
        XCTAssertEqual(
            harness.runner.snapshotCounters().refusedOutboundBacklogPacketCount, 0,
            "a paced producer over a keeping-up transport was refused at the boundary")
    }

    func testAStalledChannelFillsTheQueueAndReleasesItOnResume() throws {
        // The ANTI-VACUITY PAIR for the test above. Without this, an implementation that never
        // constructs the queue at all passes `queuedPacketCount() == 0` identically — the
        // assertion would be measuring absence rather than restraint.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        harness.channel.withholdCompletions = true

        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 400, source: [10, 64, 0, 5]))
        harness.submitPaced(packet, count: 80)
        harness.settle()

        let parked = harness.runner.queuedPacketCount()
        XCTAssertGreaterThan(parked, 0, "a stalled channel did not park anything — the queue is unreachable")

        let sentWhileStalled = harness.channel.sent.count
        harness.channel.releaseCompletions()
        harness.settle()

        XCTAssertEqual(harness.runner.queuedPacketCount(), 0, "parked packets were not released on resume")
        XCTAssertGreaterThan(
            harness.channel.sent.count, sentWhileStalled,
            "the released packets were dropped rather than sent")
    }

    func testThePreHandshakeWindowIsTheEnginesQueueNotOurs() throws {
        // `encapsulate` TRANSFERS ownership: while no session is current the engine heap-copies
        // the packet into its own 256-entry queue and releases it through `drain`. Queueing it
        // here as well would store the bytes twice and retransmit them on drain.
        let harness = try ChainedSessionHarness()
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 300, source: [10, 64, 0, 5]))

        harness.runner.handleOutboundBatch([packet], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        XCTAssertEqual(
            harness.runner.queuedPacketCount(), 0,
            "the runner queued a packet the engine had already taken")
        // NECESSARY, NOT SUFFICIENT — stated so this is not read as proof.
        //
        // A packet stored here as well is released by the very next completion, so depth is
        // back to zero before this runs; and the datagram count does not separate the two
        // implementations either, because the second encapsulation of a queued packet produces
        // no new send while no session is current. Both were checked by mutation and both are
        // blind to it.
        //
        // The observable consequence of double-storing is a DUPLICATE on the wire once the
        // handshake completes and both copies drain, which needs the session lifetime this
        // slice does not own. The runner's doc comment records the invariant as unenforced.
        XCTAssertFalse(harness.channel.sent.isEmpty, "no handshake initiation was emitted")
// The DUPLICATE is the observable, and it is reachable here after all.
        //
        // Two weaker candidates were tried first and both are blind. Queue depth is necessary
        // and not sufficient: a packet stored here as well is released by the very next
        // completion, so depth is back to zero before any assertion runs. The DATAGRAM COUNT is
        // blind for a reason specific to this engine — `format_handshake_initiation(dst, false)`
        // returns `Done` while a handshake is already in progress, so the second encapsulation
        // of a double-stored packet emits nothing, and `sent.count` is 1 either way. Both were
        // checked by mutation and both passed against a runner that double-stores.
        //
        // What separates them is what reaches the PEER once a session exists: two copies in the
        // engine's queue drain as two data packets. Driving the handshake through the runner's
        // own channel makes that reachable without owning session lifetime.
        try harness.completeHandshakeThroughTheChannel()
        var delivered = 0
        var inner = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        for datagram in harness.channel.sent {
            if case .writeToTunnelIPv4 = try? harness.peerSession.decapsulate(
                datagram, from: .unknown, into: &inner) { delivered += 1 }
        }
        XCTAssertEqual(
            delivered, 1,
            "one outbound packet reached the peer more than once — it was stored twice")
    }

    func testALargeBatchDoesNotManufactureItsOwnBackPressure() throws {
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        // A transport that KEEPS UP but cannot answer while the runner holds the queue — which
        // is every real transport, because `NWConnection` completions arrive on another queue
        // and hop back to this one. Completions are released only BETWEEN passes, so anything
        // copied or shed here was caused by how long the batch was, not by the transport.
        harness.channel.withholdCompletions = true
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 400, source: [10, 64, 0, 5]))
        let batch = [Data](repeating: packet, count: 400)

        harness.runner.handleOutboundBatch(batch, protocols: [NSNumber(value: AF_INET)])
        for _ in 0..<40 {
            _ = harness.runner.snapshotCounters()  // one barrier == one pass over the queue
            harness.channel.releaseCompletions(resumeWithholding: true)
        }
        harness.settle()

        // 400 is past BOTH bounds it used to collide with: the 16 outstanding sends, and the
        // 272 at which a single batch necessarily began evicting from a 256-packet queue.
        XCTAssertEqual(harness.channel.sent.count, 400, "the batch did not finish")
        XCTAssertEqual(
            harness.runner.snapshotCounters().shedPacketCount, 0,
            "batch length, not transport latency, caused packet loss")
        XCTAssertEqual(
            harness.runner.queuedPacketCount(), 0,
            "the batch was copied into the back-pressure queue rather than held by cursor")
    }

    func testABatchTooLargeToHoldTakesTheBoundedPathInstead() throws {
        // The ANTI-VACUITY PAIR for the test above, in the other direction. That one proves a
        // long batch is held by cursor rather than copied; without this one, "held by cursor"
        // has no upper limit at all — a `[Data]` retains every element it holds, so a stalled
        // transport pins the whole array for as long as the stall lasts, and `readPackets`
        // publishes no bound on what it hands over. That is the residency `INV-MEM-1` caps at
        // ~50 MB, reached by the one path that does not go through the bounded queue.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        harness.channel.withholdCompletions = true

        // Past `maximumParkedBatchBytes` on BYTES while staying at a packet size the queue
        // accepts, so what is under test is the residency ceiling and not the queue's own
        // oversize refusal.
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 1200, source: [10, 64, 0, 5]))
        let batch = [Data](repeating: packet, count: 1_000)
        XCTAssertGreaterThan(
            batch.count * 1200, ChainedSessionRunner.maximumParkedBatchBytes,
            "the batch does not actually exceed the ceiling under test")

        harness.runner.handleOutboundBatch(batch, protocols: batch.map { _ in NSNumber(value: AF_INET) })
        harness.settle()

        // The batch is NOT resident behind the cursor: what the runner still holds is in the
        // queue, which is bounded and shedding, and reports both.
        XCTAssertGreaterThan(
            harness.runner.queuedPacketCount(), 0,
            "an oversized batch was held by cursor rather than admitted to the bounded queue")
        XCTAssertLessThanOrEqual(
            harness.runner.queuedPacketCount(), ChainedPacketQueueLimits.engineQueueDepth,
            "the queue is over its own packet bound")
        XCTAssertGreaterThan(
            harness.runner.snapshotCounters().shedPacketCount, 0,
            "the excess was neither held nor shed, so it is unaccounted for")
    }

    func testTheResidencyCeilingMeasuresTheWholeBatchNotTheUnsentSuffix() throws {
        // The cursor retains the ARRAY, and a `[Data]` keeps every element alive — including the
        // ones already on the wire. So the resident cost of a cursor parked at index 900 of a
        // 1000-packet batch is all 1000 payloads, not the 100 still to send.
        //
        // Measuring the suffix is the intuitive reading of "what is still held" and it is the
        // wrong one: it reports a fraction of the residency and admits the batch the ceiling was
        // added to refuse. The test above cannot see the difference — it stalls at the sixteenth
        // packet, where suffix and whole are within 2% of each other — so this one stalls DEEP,
        // which is the only arrangement where the two measurements disagree.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        // Keeps up for 900 sends, then stops: the cursor is claimed around packet 916, with a
        // suffix under the ceiling and a whole batch far over it.
        harness.channel.withholdAfterSends = 900

        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 1200, source: [10, 64, 0, 5]))
        let batch = [Data](repeating: packet, count: 1_000)
        XCTAssertLessThan(
            84 * 1200, ChainedSessionRunner.maximumParkedBatchBytes,
            "the unsent suffix does not fit the ceiling, so the two measurements agree here")
        XCTAssertGreaterThan(
            batch.count * 1200, ChainedSessionRunner.maximumParkedBatchBytes,
            "the whole batch does not exceed the ceiling, so there is nothing to disagree about")

        harness.runner.handleOutboundBatch(batch, protocols: batch.map { _ in NSNumber(value: AF_INET) })
        harness.settle()

        // Under a suffix measurement the tail is held by cursor and the queue stays empty.
        XCTAssertGreaterThan(
            harness.runner.queuedPacketCount(), 0,
            "the batch was parked on a suffix that fits while the array over the ceiling stayed resident")
    }

    func testPacketsReachThePeerInArrivalOrderAcrossInterleavedBatches() throws {
        // Three places can hold an outbound packet — the engine's pre-handshake queue, the batch
        // cursor, and the parked-packet queue — and `releaseStored` walks them oldest first. The
        // claim that they are in age order was originally argued from "the queue only fills
        // while a batch is stopped", which is true and insufficient: a batch can FINISH while
        // the queue is still full, freeing the cursor for a NEWER batch that then jumps ahead of
        // everything parked. Under sustained traffic a new batch arrives every completion
        // window, so the parked packets are not merely reordered, they starve until the queue
        // evicts them.
        //
        // Asserted end to end, by decrypting at the peer, because ordering is a property of what
        // reaches the far end rather than of which branch ran.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        harness.channel.withholdCompletions = true

        // Sizes chosen so batches both stall mid-way and finish while others are parked; totals
        // stay under the 256-packet queue so nothing is evicted and order is the only variable.
        var tag = 0
        var arrival: [Int] = []
        for size in [40, 8, 25, 6, 33, 12, 19] {
            var batch: [Data] = []
            for _ in 0..<size {
                batch.append(Data(ChainedSessionHarness.taggedPacket(tag)))
                arrival.append(tag)
                tag += 1
            }
            harness.runner.handleOutboundBatch(batch, protocols: batch.map { _ in NSNumber(value: AF_INET) })
            _ = harness.runner.snapshotCounters()
            harness.channel.releaseCompletions(resumeWithholding: true)
        }
        for _ in 0..<80 {
            _ = harness.runner.snapshotCounters()
            harness.channel.releaseCompletions(resumeWithholding: true)
        }
        harness.settle()

        XCTAssertEqual(
            harness.runner.snapshotCounters().shedPacketCount, 0,
            "the sequence evicted packets, so ordering is not the only thing under test")
        let delivered = try harness.tagsDecryptedByPeer()
        XCTAssertEqual(delivered.count, arrival.count, "packets were lost, not merely reordered")
        XCTAssertEqual(delivered, arrival, "a newer batch was released ahead of older parked packets")
    }

    func testTheEngineDrainStopsAtTheSendBound() throws {
        // The one path that arrives with a FULL engine queue: packets accumulate while no
        // session is current, then the handshake completes and every one of them is releasable
        // at once. Draining to exhaustion handed all of them to the transport in a single go,
        // so the bound was exceeded by an order of magnitude and the bytes moved out of bounded
        // storage into a socket buffer that has none (`INV-MEM-1`).
        let harness = try ChainedSessionHarness()
        harness.channel.withholdCompletions = true
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 400, source: [10, 64, 0, 5]))
        harness.submitPaced(packet, count: 60)
        harness.settle()

        XCTAssertEqual(harness.channel.sent.count, 1, "pre-handshake, only the initiation goes out")
        XCTAssertEqual(harness.runner.queuedPacketCount(), 0, "the engine owns the pre-handshake window")

        try harness.completeHandshakeThroughTheChannel()

        // Initiation, keepalive, and drained packets up to the bound — and not one more while
        // the transport has acknowledged nothing.
        XCTAssertEqual(
            harness.channel.sent.count, ChainedSessionRunner.inFlightSendBound,
            "the drain handed a stalled transport more than the send bound")

        harness.channel.releaseCompletions()
        harness.settle()

        XCTAssertEqual(
            harness.channel.sent.count, 62,
            "pausing the drain lost packets instead of deferring them")
    }

    func testEvictionUnderSustainedPressureIsReportedAsShedding() throws {
        // `.admittedAfterEvicting` keeps the arriving packet and drops an older one, so
        // `wasQueued` is true — and a runner that counted only outright refusals reported ZERO
        // shedding through exactly the overload the counter exists to report.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        harness.channel.withholdCompletions = true
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 400, source: [10, 64, 0, 5]))
        harness.submitPaced(packet, count: 330)
        harness.settle()

        XCTAssertEqual(
            harness.runner.queuedPacketCount(), ChainedPacketQueueLimits.engineQueueDepth,
            "the queue did not fill, so nothing was evicted to report")
        XCTAssertGreaterThan(
            harness.runner.snapshotCounters().shedPacketCount, 0,
            "sustained eviction reported no shedding")
    }

    func testASynchronousTransportDrainsTheQueueIteratively() throws {
        // The inline-completion branch is deliberate — see `sendOnQueue` — and it used to cost
        // one stack frame per packet: channelResumed -> encapsulateOnQueue -> perform ->
        // sendOnQueue -> completion -> channelResumed, which Swift does not fold into tail
        // calls. Several hundred frames deep for a full queue.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        harness.channel.withholdCompletions = true
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 400, source: [10, 64, 0, 5]))
        harness.submitPaced(packet, count: 120)
        harness.settle()
        XCTAssertGreaterThan(harness.runner.queuedPacketCount(), 0, "nothing was parked to release")

        harness.channel.resetSendDepth()
        harness.channel.releaseCompletions()  // withholding off — completions now fire inline
        harness.settle()

        XCTAssertEqual(harness.runner.queuedPacketCount(), 0, "the queue did not drain")
        XCTAssertEqual(
            harness.channel.maxNestedSendDepth, 1,
            "the release recursed through the completion instead of looping")
    }

    func testADNSFragmentTailIsDroppedEvenInALaterBatch() throws {
        // The classifier's own tests prove the RULE; this proves the runner keeps the memory the
        // rule needs. `readPackets` delivers whatever the OS has ready, so a fragment head and
        // its tails routinely land in different batches — a table scoped to one batch would
        // forward every tail whose head arrived in the previous one, which is the leak intact
        // with an extra step.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()

        let head = ChainedSessionHarness.fragmentedDNSHead(identification: 0x5150)
        harness.runner.handleOutboundBatch([Data(head)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()
        let afterHead = harness.channel.sent.count
        XCTAssertEqual(afterHead, 0, "the DNS fragment head was forwarded")

        // A SEPARATE batch, which is the point.
        var tail = head
        tail[6] = 0x00
        tail[7] = 0x10
        harness.runner.handleOutboundBatch([Data(tail)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()
        XCTAssertEqual(
            harness.channel.sent.count, afterHead,
            "a tail whose head arrived in an earlier batch was forwarded to the peer")

        // ANTI-VACUITY: an unrelated fragmented flow still crosses, so this is not "the runner
        // stopped sending".
        var stranger = ChainedSessionHarness.fragmentedDNSHead(identification: 0x0001)
        stranger[6] = 0x00
        stranger[7] = 0x10
        stranger[22] = 0x01  // destination port 443, not that a tail's bytes are read as one
        stranger[23] = 0xBB
        harness.runner.handleOutboundBatch([Data(stranger)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()
        XCTAssertGreaterThan(
            harness.channel.sent.count, afterHead,
            "an unrelated fragment tail was dropped — the table is matching too broadly")
    }

    func testAHeadOvertakingAParkedTailDoesNotReleaseItsDenial() throws {
        // The mirror of the test below, and it leaks rather than over-drops. A DNS head is
        // denied and its TAIL parks behind the send bound, still to be re-classified on
        // release. Then a permitted fragmented head reusing the identification arrives and is
        // classified AT ARRIVAL — jumping ahead of the parked tail. If that head reclaims the
        // tuple, the tail's re-classification finds nothing denying it and its query bytes go
        // to the peer, which is the leak the deny-list exists to prevent, opened by the fix for
        // stale denials.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        harness.channel.withholdCompletions = true

        let filler = Data(ChainedSessionHarness.ipv4Packet(byteCount: 200, source: [10, 64, 0, 5]))
        let dnsHead = Data(ChainedSessionHarness.fragmentedDNSHead(identification: 0x5151))
        var tailBytes = ChainedSessionHarness.fragmentedDNSHead(identification: 0x5151)
        tailBytes[6] = 0x00
        tailBytes[7] = 0x10  // a continuation of the denied datagram

        // The head is classified and denied first, in release order.
        harness.runner.handleOutboundBatch([dnsHead], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        // Now fill the bound and park the TAIL behind it.
        var batch = [Data](repeating: filler, count: ChainedSessionRunner.inFlightSendBound + 4)
        batch.append(Data(tailBytes))
        harness.runner.handleOutboundBatch(batch, protocols: batch.map { _ in NSNumber(value: AF_INET) })
        harness.settle()
        XCTAssertGreaterThan(
            harness.channel.sent.count, ChainedSessionRunner.inFlightSendBound - 1,
            "the send bound was never reached, so nothing parked and the hazard is not exercised")

        // A permitted fragmented head reusing the identification, arriving while the tail waits.
        var permitted = ChainedSessionHarness.fragmentedDNSHead(identification: 0x5151)
        permitted[22] = 0x01
        permitted[23] = 0xBB  // destination port 443, so this head is forwarded
        harness.runner.handleOutboundBatch([Data(permitted)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        harness.channel.releaseCompletions()
        harness.settle()

        var inner = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        var forwardedTail = 0
        for datagram in harness.channel.sent {
            guard case .writeToTunnelIPv4(let byteCount) = try? harness.peerSession.decapsulate(
                datagram, from: .unknown, into: &inner), byteCount >= 8
            else { continue }
            let identification = UInt16(inner[4]) << 8 | UInt16(inner[5])
            let fragmentOffset = (UInt16(inner[6]) << 8 | UInt16(inner[7])) & 0x1FFF
            if identification == 0x5151 && fragmentOffset != 0 { forwardedTail += 1 }
        }
        XCTAssertEqual(
            forwardedTail, 0,
            "a head classified out of release order released the denial, and the parked DNS "
                + "tail went to the peer with its query bytes")
    }

    func testAReleasedHeadDoesNotDeleteADenialRecordedWhileItWaited() throws {
        // The case that killed "the released packet is the oldest, so it may reclaim". It is
        // the oldest among QUEUED packets and not among mutations already applied to the table:
        // a DROP happens at arrival and is never queued, so a newer DNS head can record its
        // denial while a permitted head sits in the queue. Reclaiming on release then deletes a
        // denial from the future, and the newer datagram's tails go to the peer with their
        // query bytes.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        harness.channel.withholdCompletions = true

        // Take the cursor, so what follows is copied into the queue rather than parked there.
        let filler = Data(ChainedSessionHarness.ipv4Packet(byteCount: 200, source: [10, 64, 0, 5]))
        let batchA = [Data](repeating: filler, count: ChainedSessionRunner.inFlightSendBound + 6)
        harness.runner.handleOutboundBatch(batchA, protocols: batchA.map { _ in NSNumber(value: AF_INET) })
        harness.settle()

        // A permitted head on tuple X, queued behind the stall.
        var permitted = ChainedSessionHarness.fragmentedDNSHead(identification: 0x7171)
        permitted[22] = 0x01
        permitted[23] = 0xBB  // destination port 443
        harness.runner.handleOutboundBatch(
            [Data(permitted)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        // NEWER: a DNS head on the same tuple. It is dropped at arrival and remembers X — it is
        // never queued, so nothing about it will be re-classified later.
        let dnsHead = Data(ChainedSessionHarness.fragmentedDNSHead(identification: 0x7171))
        harness.runner.handleOutboundBatch([dnsHead], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        // The queue drains, releasing the older permitted head.
        harness.channel.releaseCompletions()
        harness.settle()

        // The DNS datagram's tail, arriving after all of that.
        var tail = ChainedSessionHarness.fragmentedDNSHead(identification: 0x7171)
        tail[6] = 0x00
        tail[7] = 0x10
        harness.runner.handleOutboundBatch([Data(tail)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        var inner = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        var forwardedTail = 0
        for datagram in harness.channel.sent {
            guard case .writeToTunnelIPv4(let byteCount) = try? harness.peerSession.decapsulate(
                datagram, from: .unknown, into: &inner), byteCount >= 8
            else { continue }
            let identification = UInt16(inner[4]) << 8 | UInt16(inner[5])
            let fragmentOffset = (UInt16(inner[6]) << 8 | UInt16(inner[7])) & 0x1FFF
            if identification == 0x7171 && fragmentOffset != 0 { forwardedTail += 1 }
        }
        XCTAssertEqual(
            forwardedTail, 0,
            "a released head deleted a denial recorded after it was queued, and the DNS tail "
                + "went to the peer with its query bytes")
    }

    func testAResumedCursorHeadDoesNotDeleteADenialRecordedWhileItWaited() throws {
        // The same hazard through the CURSOR rather than the queue, and it needs its own test:
        // a cursor is older than everything parked behind it, which is what made "it may
        // reclaim" tempting — but age among parked packets is not the property that matters.
        // A newer DNS head can be dropped, and record its denial, while the cursor waits.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        harness.channel.withholdCompletions = true

        // Batch A reaches the send bound and parks a cursor BEFORE reaching the permitted head
        // at its end, so that head is classified for the first time on resumption.
        let filler = Data(ChainedSessionHarness.ipv4Packet(byteCount: 200, source: [10, 64, 0, 5]))
        var permitted = ChainedSessionHarness.fragmentedDNSHead(identification: 0x8181)
        permitted[22] = 0x01
        permitted[23] = 0xBB  // destination port 443
        var batchA = [Data](repeating: filler, count: ChainedSessionRunner.inFlightSendBound + 6)
        batchA.append(Data(permitted))
        harness.runner.handleOutboundBatch(batchA, protocols: batchA.map { _ in NSNumber(value: AF_INET) })
        harness.settle()

        // NEWER: a DNS head on the same tuple, dropped at arrival, never queued.
        let dnsHead = Data(ChainedSessionHarness.fragmentedDNSHead(identification: 0x8181))
        harness.runner.handleOutboundBatch([dnsHead], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        // The cursor resumes and classifies the permitted head for the first time.
        harness.channel.releaseCompletions()
        harness.settle()

        var tail = ChainedSessionHarness.fragmentedDNSHead(identification: 0x8181)
        tail[6] = 0x00
        tail[7] = 0x10
        harness.runner.handleOutboundBatch([Data(tail)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        var inner = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        var forwardedTail = 0
        for datagram in harness.channel.sent {
            guard case .writeToTunnelIPv4(let byteCount) = try? harness.peerSession.decapsulate(
                datagram, from: .unknown, into: &inner), byteCount >= 8
            else { continue }
            let identification = UInt16(inner[4]) << 8 | UInt16(inner[5])
            let fragmentOffset = (UInt16(inner[6]) << 8 | UInt16(inner[7])) & 0x1FFF
            if identification == 0x8181 && fragmentOffset != 0 { forwardedTail += 1 }
        }
        XCTAssertEqual(
            forwardedTail, 0,
            "a resumed cursor head deleted a denial recorded while it waited, and the DNS tail "
                + "went to the peer with its query bytes")
    }

    func testAParkedTailIsReclassifiedAgainstTheHeadThatOvertookIt() throws {
        // Back-pressure reorders CLASSIFICATION, not just transmission, and the fragment
        // deny-list is the first verdict that depends on what the classifier has already seen.
        //
        // The sequence: a batch stalls at the send bound BEFORE reaching a DNS fragment head; a
        // later batch carrying the matching TAIL cannot claim the cursor, so it runs to
        // completion and classifies the tail against a table that does not yet know about the
        // head. The tail parks as ordinary traffic. When the head is finally classified and
        // remembered, the parked tail is already past the only place that would have caught it —
        // so releasing it straight to the engine forwards the DNS bytes.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        harness.channel.withholdCompletions = true

        // Fill the send bound, then park one more so the cursor is taken and the next batch
        // cannot claim it.
        let filler = Data(ChainedSessionHarness.ipv4Packet(byteCount: 200, source: [10, 64, 0, 5]))
        let head = Data(ChainedSessionHarness.fragmentedDNSHead(identification: 0x2727))
        var tailBytes = ChainedSessionHarness.fragmentedDNSHead(identification: 0x2727)
        tailBytes[6] = 0x00
        tailBytes[7] = 0x10  // a continuation of the same datagram

        // Batch A: enough filler to reach the bound, with the HEAD last so the cursor stops
        // before it.
        var batchA = [Data](repeating: filler, count: ChainedSessionRunner.inFlightSendBound + 4)
        batchA.append(head)
        harness.runner.handleOutboundBatch(batchA, protocols: batchA.map { _ in NSNumber(value: AF_INET) })
        harness.settle()

        // Batch B: the TAIL, arriving while A is still parked.
        harness.runner.handleOutboundBatch([Data(tailBytes)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        let sentBeforeRelease = harness.channel.sent.count
        harness.channel.releaseCompletions()
        harness.settle()

        // Every datagram the peer can decrypt must be filler. If the tail was forwarded, one of
        // them carries the DNS message bytes instead.
        var inner = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        var forwardedTail = 0
        for datagram in harness.channel.sent {
            guard case .writeToTunnelIPv4(let byteCount) = try? harness.peerSession.decapsulate(
                datagram, from: .unknown, into: &inner), byteCount >= 8
            else { continue }
            let identification = UInt16(inner[4]) << 8 | UInt16(inner[5])
            if identification == 0x2727 { forwardedTail += 1 }
        }
        XCTAssertEqual(
            forwardedTail, 0,
            "a fragment tail parked before its head was released to the peer with its query bytes")
        XCTAssertGreaterThan(
            harness.channel.sent.count, sentBeforeRelease,
            "nothing was released at all — the scenario did not exercise the parked path")
    }

    func testAQueueWithoutLimitsIsRefusedRatherThanUnbounded() throws {
        // A queue with no limits is not a smaller queue; it is an unbounded one inside a ~50 MB
        // jetsam ceiling. Force-unwrapping the Optional would have been a crash in the
        // extension; refusing construction is the answer that leaves the tunnel DNS-only.
        let harness = try ChainedSessionHarness()
        XCTAssertNil(
            ChainedSessionRunner(
                session: harness.peerSession,
                peer: .unknown,
                allowedIPs: ChainedAllowedIPs([]),
                channel: FakeChannel(),
                writer: FakeWriter(),
            dnsServer: RecordingDNSServer(),
                queueLimits: nil,
                engineQueue: harness.engineQueue,
                events: RecordingSessionEvents(),
                ownResolverPorts: ChainedResolverPortRegistry(uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds })))
    }

    // MARK: - Boundary admission

    func testABatchArrivingAtASaturatedBacklogIsRefusedAndCounted() throws {
        // The backlog is saturated DIRECTLY rather than by racing the queue with a flood: the
        // gauge is the thing under test, and a race that happened to drain would make this
        // test pass against a runner with no admission at all.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        let ceiling = ChainedSessionRunner.outboundAdmissionLimits.maximumBytes
        XCTAssertTrue(harness.runner.outboundAdmission.admit(bytes: ceiling, units: 0))

        harness.runner.handleOutboundBatch(
            [Data(ChainedSessionHarness.taggedPacket(7))], protocols: [NSNumber(value: AF_INET)])
        harness.settle()
        XCTAssertEqual(
            harness.runner.snapshotCounters().refusedOutboundBacklogPacketCount, 1,
            "a refusal the counters cannot see is a silent packet loss in the field")
        XCTAssertEqual(
            try harness.tagsDecryptedByPeer(), [],
            "a batch admitted past a saturated backlog reached the engine anyway")

        // Refusal is a level, not a latch: the backlog drains and the next batch goes through.
        harness.runner.outboundAdmission.release(bytes: ceiling)
        harness.runner.handleOutboundBatch(
            [Data(ChainedSessionHarness.taggedPacket(8))], protocols: [NSNumber(value: AF_INET)])
        harness.settle()
        XCTAssertEqual(
            try harness.tagsDecryptedByPeer(), [8],
            "one saturated moment refused batches forever afterwards")
    }

    func testTheBacklogGaugeReadsZeroOnceTheQueueHasDrained() throws {
        // The admission that is never returned converts the gauge into a ratchet: after enough
        // ordinary batches the boundary refuses everything, permanently, and the tunnel goes
        // silently outbound-dead while every queue-side counter reads healthy.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        for tag in 0..<8 {
            harness.runner.handleOutboundBatch(
                [Data(ChainedSessionHarness.taggedPacket(tag))], protocols: [NSNumber(value: AF_INET)])
        }
        harness.settle()
        let resident = harness.runner.outboundAdmission.resident()
        XCTAssertEqual(resident.bytes, 0, "an admission was never returned to the gauge")
        XCTAssertEqual(resident.count, 0, "an admission was never returned to the gauge")
    }

    func testABatchLargerThanTheWholeCeilingIsStillDeliveredAlone() throws {
        // The partner of admit-then-saturate (`ChainedAdmissionGauge`): the arrival's memory is
        // already alive in the caller, so fit-checking it against the ceiling would drop — into
        // an EMPTY backlog — a batch the queue's own bounds are built to stream through. This
        // pins the delivery half of that argument.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 1000, source: [10, 64, 0, 5]))
        let batch = [Data](repeating: packet, count: 2200)  // ~2.2 MB: past the 2 MiB ceiling
        harness.runner.handleOutboundBatch(
            batch, protocols: [NSNumber](repeating: NSNumber(value: AF_INET), count: batch.count))
        harness.settle()
        XCTAssertEqual(harness.runner.snapshotCounters().refusedOutboundBacklogPacketCount, 0)
        XCTAssertGreaterThanOrEqual(
            harness.channel.sent.count, batch.count,
            "a solo batch was refused for its size, which saves no memory and loses delivery")
    }

    func testACompletionDispatchedOntoTheSharedQueueStillFreesItsSlot() throws {
        // The third case, which the two-way `isCurrent` test collapsed into "inline": a channel
        // handed the engine queue — which making it public and shared invites — answers on the
        // queue but as its OWN item, after `sendOnQueue` has read and cleared the flag. Setting
        // it there meant nobody read it: `channelResumed()` never ran, `outstandingSends` never
        // fell, and after sixteen sends everything parked forever against a transport that was
        // answering every one.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        harness.channel.completeAsynchronouslyOn = harness.engineQueue

        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 400, source: [10, 64, 0, 5]))
        harness.submitPaced(packet, count: ChainedSessionRunner.inFlightSendBound * 4)
        harness.settle()
        harness.settle()

        XCTAssertEqual(
            harness.runner.queuedPacketCount(), 0,
            "an answering transport left packets parked — the completions never freed their slots")
        XCTAssertGreaterThanOrEqual(
            harness.channel.sent.count, ChainedSessionRunner.inFlightSendBound * 4,
            "the runner stopped sending at the bound against a transport that answered everything")
    }

    func testAnOversizedBatchStaysChargedWhileItIsBeingProcessed() throws {
        // Releasing the charge on entry left the ACTIVE batch uncounted while its array was
        // still retained and scanned. A batch past the parked-cursor ceiling cannot park, so it
        // is scanned end to end — a long window during which the emptied gauge admitted the
        // next unbounded batch behind it, and a producer repeats that at every queue
        // transition. Two unbounded arrays resident against a 2 MiB ceiling.
        //
        // Observed from INSIDE a send, because the serial queue means a test's own thread can
        // only look before or after a batch, never during one.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 1000, source: [10, 64, 0, 5]))
        let oversized = [Data](repeating: packet, count: 2200)  // ~2.2 MB: cannot park
        let runner = harness.runner
        let observed = ObservedCharges()
        harness.channel.onSend = { observed.record(runner.outboundAdmission.resident().bytes) }

        harness.runner.handleOutboundBatch(
            oversized,
            protocols: [NSNumber](repeating: NSNumber(value: AF_INET), count: oversized.count))
        harness.settle()

        let charges = observed.recorded
        XCTAssertFalse(charges.isEmpty, "nothing was sent, so the batch was never observed mid-processing")
        XCTAssertTrue(
            charges.allSatisfy { $0 >= oversized.count * 1000 },
            "the active batch was uncharged while still retained — the next unbounded batch "
                + "could be admitted behind it")
    }

    func testASecondOversizedBatchIsRefusedWhileTheFirstIsStillActive() throws {
        // The consequence stated as behaviour rather than as a gauge reading: the producer's
        // next batch, submitted at the moment the first is mid-scan, must not be admitted.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 1000, source: [10, 64, 0, 5]))
        let oversized = [Data](repeating: packet, count: 2200)
        let protocols = [NSNumber](repeating: NSNumber(value: AF_INET), count: oversized.count)
        let runner = harness.runner
        let submitted = ObservedCharges()

        harness.channel.onSend = {
            // Once, from inside the first batch's processing.
            guard submitted.claimFirst() else { return }
            runner.handleOutboundBatch(oversized, protocols: protocols)
        }

        harness.runner.handleOutboundBatch(oversized, protocols: protocols)
        harness.settle()

        XCTAssertEqual(
            harness.runner.snapshotCounters().refusedOutboundBacklogPacketCount, oversized.count,
            "a second unbounded batch was admitted while the first was still resident")
    }

    func testADatagramArrivingAtASaturatedBacklogIsRefusedBeforeTheCopy() throws {
        // Inbound is the boundary the producer cannot be paced on — the network sends when it
        // sends — so refusal is the only bound. Dropping a datagram is UDP's own loss model.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        let ceiling = ChainedSessionRunner.inboundAdmissionLimits.maximumBytes
        XCTAssertTrue(harness.runner.inboundAdmission.admit(bytes: ceiling, units: 0))

        try harness.deliverInnerPacketFromPeer(source: [10, 64, 0, 9])
        XCTAssertEqual(
            harness.writer.written.count, 0,
            "a datagram refused at the boundary was still decrypted and delivered")
        XCTAssertEqual(harness.runner.snapshotCounters().refusedInboundBacklogDatagramCount, 1)

        harness.runner.inboundAdmission.release(bytes: ceiling)
        try harness.deliverInnerPacketFromPeer(source: [10, 64, 0, 9])
        XCTAssertEqual(
            harness.writer.written.count, 1,
            "one saturated moment refused inbound datagrams forever afterwards")
    }

    func testTheInboundGaugeReadsZeroOnceTheQueueHasDrained() throws {
        // Same ratchet as outbound, seen from the network side: a leak here ends with the
        // tunnel deaf to its peer while the engine's own liveness accounting reads healthy.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        for _ in 0..<5 {
            try harness.deliverInnerPacketFromPeer(source: [10, 64, 0, 9])
        }
        let resident = harness.runner.inboundAdmission.resident()
        XCTAssertEqual(resident.bytes, 0, "an admission was never returned to the gauge")
        XCTAssertEqual(resident.count, 0, "an admission was never returned to the gauge")
    }

    // MARK: - ChainedSessionHarness

    func testTheRunnerReportsASessionEndOnceAndThenStopsDrivingTheEngine() throws {
        // Session lifetime is the driver's, and this is the only way it hears about one ending.
        // Reported ONCE: the engine repeats its verdict — `handshake.is_expired()` makes every
        // later `update_timers` return the same thing — so a runner reporting each occurrence
        // would deliver the same death at the tick rate, each classified against a budget that
        // had already moved on.
        //
        // An oversized packet is the only session-ending cause a unit test can produce through a
        // REAL engine: `connectionExpired` needs 90 s of engine time and `engineInternal` needs a
        // poisoned lock.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        let oversized = Data(ChainedSessionHarness.ipv4Packet(
            byteCount: WireGuardSession.maximumIPPacketByteCount + 1, source: [10, 64, 0, 5]))

        harness.runner.handleOutboundBatch([oversized], protocols: [NSNumber(value: AF_INET)])
        harness.settle()
        XCTAssertEqual(harness.events.ends.count, 1, "a session-ending action was not reported")

        let sentAfterEnd = harness.channel.sent.count
        harness.runner.handleOutboundBatch([oversized], protocols: [NSNumber(value: AF_INET)])
        harness.runner.handleOutboundBatch(
            [Data(ChainedSessionHarness.ipv4Packet(byteCount: 200, source: [10, 64, 0, 5]))],
            protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        XCTAssertEqual(harness.events.ends.count, 1, "the same session end was reported twice")
        XCTAssertEqual(
            harness.channel.sent.count, sentAfterEnd,
            "the runner kept driving the engine after reporting its session dead")
    }

    func testABatchStopsAtThePacketThatEndsTheSession() throws {
        // `sessionEnded` is delivered synchronously, and the owner's handler retires this runner
        // and builds a replacement before it returns. So the latch cannot be tested only at the
        // hop: a packet in the MIDDLE of a batch can end the session, and everything after it
        // would be processed by a runner nobody is listening to any more — driving an engine and
        // a channel that belong to a session already replaced.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()

        // The owner does what the driver will: retire the runner from inside the callback.
        harness.events.onEnd = { [weak runner = harness.runner] _ in runner?.shutdown() }

        let oversized = Data(ChainedSessionHarness.ipv4Packet(
            byteCount: WireGuardSession.maximumIPPacketByteCount + 1, source: [10, 64, 0, 5]))
        let ordinary = Data(ChainedSessionHarness.ipv4Packet(byteCount: 200, source: [10, 64, 0, 5]))
        let sentBefore = harness.channel.sent.count

        // One batch: the session-ender first, then traffic that must never reach the engine.
        harness.runner.handleOutboundBatch(
            [oversized] + [Data](repeating: ordinary, count: 8),
            protocols: (0..<9).map { _ in NSNumber(value: AF_INET) })
        harness.settle()

        XCTAssertEqual(harness.events.ends.count, 1)
        XCTAssertEqual(
            harness.channel.sent.count, sentBefore,
            "the rest of the batch was processed by a runner that had already been retired")
    }

    func testASpoofedSourceIsNotEvidenceTheTunnelIsWorking() throws {
        // A peer claiming a source it was never granted is misbehaving. Counting its packets as
        // liveness would let exactly that peer hold the outage clock at zero while delivering
        // nothing the tunnel can use.
        let harness = try ChainedSessionHarness(allowedIPs: "10.64.0.0/24")
        try harness.peerSendsInnerPacket(source: [10, 255, 0, 1])

        XCTAssertEqual(harness.runner.snapshotCounters().spoofedSourceCount, 1)
        XCTAssertFalse(
            harness.runner.takeLivenessSample().sawInboundData,
            "a spoofed-source packet was counted as the tunnel working")
    }

    func testInboundIPv6IsNotEvidenceTheTunnelIsWorking() throws {
        // This tunnel drops every OUTBOUND IPv6 packet locally, so an inbound one cannot be a
        // response to anything this session carried. A peer emitting them periodically is no
        // better evidence than the keepalive — and counting it holds the clock at zero while the
        // IPv4 egress the peer is supposed to provide is dead.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        _ = harness.runner.takeLivenessSample()

        var inner = [UInt8](repeating: 0, count: 60)
        inner[0] = 0x60  // IPv6
        var wire = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let sent = try harness.peerSession.encapsulate(inner, into: &wire)
        guard case .writeToNetwork(let byteCount) = sent else {
            return XCTFail("the peer did not produce a datagram")
        }
        wire.withUnsafeBytes {
            harness.channel.deliver(UnsafeRawBufferPointer(rebasing: $0[..<byteCount]))
        }
        harness.settle()

        XCTAssertEqual(
            harness.runner.snapshotCounters().droppedInboundIPv6Count, 1, "the packet never arrived")
        XCTAssertFalse(
            harness.runner.takeLivenessSample().sawInboundData,
            "an unsolicited inbound IPv6 packet was counted as working egress")
    }

    func testAShutDownRunnerWritesNothingFromDatagramsAlreadyInFlight() throws {
        // The latch is what a SHARED engine queue makes necessary. `receive` copies at the
        // boundary and hops, so a datagram accepted just before teardown is already queued —
        // behind, among other things, the replacement session's work. Without the latch it
        // decapsulates on a retired session and writes the abandoned peer's packets into the
        // tunnel, including after surrender.
        let harness = try ChainedSessionHarness(allowedIPs: "10.64.0.0/24")
        try harness.completeHandshake()
        let wire = try harness.peerEncapsulated(source: [10, 64, 0, 5])

        harness.runner.shutdown()
        wire.withUnsafeBytes { harness.channel.deliver($0) }
        harness.settle()

        XCTAssertTrue(
            harness.writer.written.isEmpty,
            "a retired runner wrote a decrypted packet into the tunnel")

        // ANTI-VACUITY: the same datagram before shutdown IS delivered, so this is not asserting
        // that the fixture cannot deliver anything.
        let live = try ChainedSessionHarness(allowedIPs: "10.64.0.0/24")
        try live.peerSendsInnerPacket(source: [10, 64, 0, 5])
        XCTAssertEqual(live.writer.written.count, 1, "the fixture never delivers at all")
    }

    /// What a `send` hook saw, and a once-only claim, both across queues.
    private final class ObservedCharges: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int] = []
        private var claimed = false
        var recorded: [Int] { lock.withLock { storage } }
        func record(_ value: Int) { lock.withLock { storage.append(value) } }
        /// True exactly once, for the first caller.
        func claimFirst() -> Bool {
            lock.withLock {
                if claimed { return false }
                claimed = true
                return true
            }
        }
    }

    // MARK: - Liveness

    func testAKeepalivingPeerWithNoReturnDataIsNotFlowing() throws {
        // THE BLACKHOLE THIS PREVENTS. A peer whose WireGuard link is healthy but whose egress
        // is dead keepalives us forever — and that is precisely the failure chained mode exists
        // to survive, since the tunnel is holding `0.0.0.0/0`. Counting an authenticated
        // keepalive as liveness means the outage clock never starts, the budget never runs, and
        // the tunnel blackholes everything with nothing measuring it.
        //
        // A keepalive is a real authenticated datagram: the engine decrypts it and reports
        // `.none`, which classifies as `.idle`.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        _ = harness.runner.takeLivenessSample()

        var wire = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let keepalive = try harness.peerSession.encapsulate([], into: &wire)
        guard case .writeToNetwork(let byteCount) = keepalive else {
            return XCTFail("the peer did not produce a keepalive")
        }
        wire.withUnsafeBytes {
            harness.channel.deliver(UnsafeRawBufferPointer(rebasing: $0[..<byteCount]))
        }
        harness.settle()

        XCTAssertFalse(
            harness.runner.takeLivenessSample().sawInboundData,
            "a keepalive was counted as the peer's egress working")

        // ANTI-VACUITY: a real inner packet from the same peer DOES count, so this is not
        // asserting that inbound liveness is never recorded.
        try harness.peerSendsInnerPacket(source: [10, 64, 0, 5])
        XCTAssertTrue(
            harness.runner.takeLivenessSample().sawInboundData,
            "delivered inbound data was not counted as liveness")
    }

    func testATicksOwnOutputDoesNotCertifyLiveness() throws {
        // `perform` is reached by `tick()` and by the drain as well as by `receive`. Recording
        // liveness inside it — the obvious place, since every outcome passes through — lets the
        // tunnel certify itself: a tick emitting a handshake retransmission would read as
        // evidence the peer is answering, which is the exact condition an outage is defined by
        // the absence of. The clock would then never start on a dead path.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        _ = harness.runner.takeLivenessSample()

        for _ in 0..<5 { harness.runner.tick() }
        harness.settle()

        XCTAssertFalse(
            harness.runner.takeLivenessSample().sawInboundData,
            "the tunnel's own tick output was counted as inbound liveness")
    }

    func testTheLivenessSampleIsReadAndClearedRatherThanALevel() throws {
        // The owner asks "since I last looked". A flag that stays set credits one packet
        // forever, so a peer that answered once an hour ago reads as flowing indefinitely and
        // the outage detector never fires.
        let harness = try ChainedSessionHarness(allowedIPs: "10.64.0.0/24")
        try harness.peerSendsInnerPacket(source: [10, 64, 0, 5])

        XCTAssertTrue(harness.runner.takeLivenessSample().sawInboundData)
        XCTAssertFalse(
            harness.runner.takeLivenessSample().sawInboundData,
            "the liveness flag survived being read — it is a level, not an edge")
    }

    func testOnlyAnAuthenticatedDatagramCountsAsPeerLiveness() throws {
        // The signal the whole outage predicate rests on, and the only one no remote party can
        // manufacture: producing it requires the peer's key. A FAILED decapsulation proves
        // nothing — `protocolViolation`, `noCurrentSession` and an oversized datagram are all
        // producible by anyone who can reach our UDP port, so counting them would hand an
        // off-path attacker the ability to suppress outage detection indefinitely.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        _ = harness.runner.takeLivenessSample()

        // Garbage from anywhere. It reaches the receive path and fails to authenticate.
        let junk = [UInt8](repeating: 0xEE, count: 128)
        junk.withUnsafeBytes { harness.channel.deliver($0) }
        harness.settle()
        XCTAssertFalse(
            harness.runner.takeLivenessSample().sawAuthenticatedPeerDatagram,
            "an unauthenticated datagram was counted as the peer being alive")

        // A real keepalive from the real peer DOES count — it proves the link, which is what
        // this signal is for, even though it says nothing about the peer's egress.
        var wire = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let keepalive = try harness.peerSession.encapsulate([], into: &wire)
        guard case .writeToNetwork(let byteCount) = keepalive else {
            return XCTFail("the peer did not produce a keepalive")
        }
        wire.withUnsafeBytes {
            harness.channel.deliver(UnsafeRawBufferPointer(rebasing: $0[..<byteCount]))
        }
        harness.settle()
        XCTAssertTrue(
            harness.runner.takeLivenessSample().sawAuthenticatedPeerDatagram,
            "an authenticated keepalive was not counted as link liveness")
    }

    func testAHandshakeResponseCountsAsPeerLiveness() throws {
        // The recovery path the whole ladder exists to reach, and the previous round broke it.
        // On every retry WE initiate, so the peer's authenticated type-2 response is answered
        // by OUR keepalive — and the peer consumes that empty packet as `Done` and sends
        // nothing back. No inbound type 4 arrives until the peer has traffic of its own, so a
        // rule that credits only type 4 surrenders a working replacement session at the outage
        // deadline.
        let harness = try ChainedSessionHarness()

        // The runner initiates; the peer answers.
        harness.runner.forceHandshake()
        harness.settle()
        guard let initiation = harness.channel.sent.first else {
            return XCTFail("the runner sent no handshake initiation")
        }
        XCTAssertEqual(initiation.first, 1, "that was not a handshake initiation")
        _ = harness.runner.takeLivenessSample()

        var response = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let responded = try harness.peerSession.decapsulate(initiation, from: .unknown, into: &response)
        guard case .writeToNetwork(let byteCount) = responded else {
            return XCTFail("the peer did not answer the initiation")
        }
        XCTAssertEqual(response.first, 2, "the peer did not send a handshake response")
        response.withUnsafeBytes {
            harness.channel.deliver(UnsafeRawBufferPointer(rebasing: $0[..<byteCount]))
        }
        harness.settle()

        XCTAssertTrue(
            harness.runner.takeLivenessSample().sawAuthenticatedPeerDatagram,
            "an authenticated handshake response was not counted, so a recovered session is "
                + "surrendered at the deadline with the link working")
    }

    func testACookieReplyIsNotEvidenceThePeerIsAlive() throws {
        // The forgery the narrowing exists to exclude, pinned on the rule directly because
        // driving a real rate limiter into its under-load branch needs ten handshakes a second
        // against a live socket. `verify_packet` answers a mac2 failure under load with a
        // cookie reply, which `decapsulate` returns as an ordinary success before any Noise
        // processing — and mac1 is keyed on OUR public key, so anyone who can address us can
        // farm one crediting "success" per packet and hold the outage clock open on a dead
        // tunnel.
        //
        // The only thing separating it from genuine processing is what we send back: type 3 is
        // the cookie reply, type 2 and type 4 are answers that required the peer's key.
        XCTAssertFalse(
            ChainedSessionRunner.provesPeerKeyPossession(
                inboundMessageType: 1, operation: .writeToNetwork(byteCount: 64),
                outboundMessageType: 3),
            "a cookie reply counted as the peer being alive")
        XCTAssertFalse(
            ChainedSessionRunner.provesPeerKeyPossession(
                inboundMessageType: 2, operation: .writeToNetwork(byteCount: 64),
                outboundMessageType: 3),
            "a cookie reply counted as the peer being alive")
        XCTAssertFalse(
            ChainedSessionRunner.provesPeerKeyPossession(
                inboundMessageType: 1, operation: .writeToNetwork(byteCount: 92),
                outboundMessageType: 2),
            "an initiation counted, and it is replayable across session rebuilds")
        XCTAssertTrue(
            ChainedSessionRunner.provesPeerKeyPossession(
                inboundMessageType: 2, operation: .writeToNetwork(byteCount: 32),
                outboundMessageType: 4),
            "answering a response requires the peer's key and must count")
        XCTAssertTrue(
            ChainedSessionRunner.provesPeerKeyPossession(
                inboundMessageType: 4, operation: .writeToTunnelIPv4(byteCount: 100),
                outboundMessageType: nil),
            "transport data is carried under the session keys and must count")
        XCTAssertFalse(
            ChainedSessionRunner.provesPeerKeyPossession(
                inboundMessageType: 3, operation: .writeToNetwork(byteCount: 64),
                outboundMessageType: 4),
            "an inbound cookie reply is not evidence either")
    }

    func testAReplayedInitiationIsNotEvidenceThePeerIsAlive() throws {
        // Authenticated is not the same as CURRENT. WireGuard's replay defence for an
        // initiation is the TAI64N timestamp, and it starts at zero on every fresh `Handshake`
        // — while the driver builds a new session per retry attempt, so the window resets every
        // time. One captured initiation therefore works forever: replay it after each rebuild,
        // we answer, and crediting that answer ends the outage and refunds the budget while the
        // tunnel is still blackholed.
        //
        // Driven with a REAL initiation captured from a real peer session and replayed into a
        // SECOND runner, which is exactly the rebuild the driver performs.
        let first = try ChainedSessionHarness()
        var wire = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let initiation = try first.peerSession.forceHandshake(into: &wire)
        let captured = Array(wire[..<initiation.byteCount])
        XCTAssertEqual(captured.first, 1, "the peer did not produce an initiation")

        // The replacement session — SAME peer relationship, new engine, so a zeroed replay
        // window. Building it with fresh keys instead is what made an earlier version of this
        // test vacuous: the captured initiation could not authenticate at all, so no crediting
        // path was reached and it passed with or without the rule.
        let rebuilt = try ChainedSessionHarness(reusing: first.keys)

        // The replay really is accepted by a rebuilt engine — proved on a SEPARATE instance,
        // because consuming it here would advance the rebuilt session's own TAI64N window and
        // the runner would then see a within-session replay instead. That is precisely what
        // made the previous version of this check useless: it disproved the scenario it was
        // supposed to establish.
        let witness = try ChainedSessionHarness(reusing: first.keys)
        var probe = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let accepted = try? witness.session.decapsulate(captured, from: .unknown, into: &probe)
        guard case .writeToNetwork = accepted else {
            return XCTFail("a rebuilt engine rejected the replay — the scenario is not real")
        }
        _ = rebuilt.runner.takeLivenessSample()
        captured.withUnsafeBytes { rebuilt.channel.deliver($0) }
        rebuilt.settle()

        XCTAssertFalse(
            rebuilt.runner.takeLivenessSample().sawAuthenticatedPeerDatagram,
            "a replayed initiation was credited as the peer being alive, so an on-path party "
                + "can hold the outage clock open forever with one captured packet")
    }

    func testAReplyToAPeerInitiatedHandshakeReachesThePeerIntact() throws {
        // `decapsulate` writes into the INBOUND buffer, and `sendOnQueue` transmits the OUTBOUND
        // one — so every network-bound datagram an inbound message produces was sent as whatever
        // the last outbound call happened to leave behind, with a length taken from the other
        // buffer. `ChainedDataPathBuffers` documents this exact case ("a single inbound datagram
        // can produce a `writeToNetwork` result — a cookie or handshake reply"); the send path
        // never honoured it.
        //
        // The tunnel-breaking instance is a PEER-INITIATED rekey, which a brief uplink loss
        // produces routinely: our type-2 answer is the only thing that can complete it, there is
        // no queued-traffic rescue, and the peer retries for REKEY_ATTEMPT_TIME and then expires.
        // Asserted by handing our reply back to the real peer session — nothing weaker sees it,
        // which is why the whole suite passed either way.
        let harness = try ChainedSessionHarness()

        // The peer initiates; we answer.
        var wire = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let initiation = try harness.peerSession.forceHandshake(into: &wire)
        XCTAssertEqual(wire.first, 1, "the peer did not produce an initiation")
        let sentBefore = harness.channel.sent.count
        wire.withUnsafeBytes {
            harness.channel.deliver(UnsafeRawBufferPointer(rebasing: $0[..<initiation.byteCount]))
        }
        harness.settle()

        guard harness.channel.sent.count > sentBefore else {
            return XCTFail("we sent nothing back to a handshake initiation")
        }
        let reply = harness.channel.sent[sentBefore]
        XCTAssertEqual(
            reply.first, 2,
            "our answer to an initiation was not a handshake response — it is the stale contents "
                + "of the outbound buffer")

        // The peer must be able to consume it. This is the assertion that matters: a datagram
        // that merely looks right still fails the handshake if the bytes are from another call.
        var sink = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let consumed = try? harness.peerSession.decapsulate(reply, from: .unknown, into: &sink)
        XCTAssertNotNil(
            consumed,
            "the peer rejected our handshake response, so a peer-initiated rekey can never "
                + "complete and the session expires after REKEY_ATTEMPT_TIME")
    }

    func testOnlyAnObligingSendArmsTheSilenceClock() throws {
        // The peer owes an answer to user traffic and to a handshake initiation. It owes nothing
        // for the engine's own timer output — so arming a silence clock on a tick would be
        // waiting for an answer that was never due, and the tunnel would declare an outage on
        // itself at the tick rate.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        _ = harness.runner.takeLivenessSample()

        for _ in 0..<5 { harness.runner.tick() }
        harness.settle()
        XCTAssertFalse(
            harness.runner.takeLivenessSample().sawObligingSend,
            "the engine's own tick output was treated as a send the peer owes an answer to")

        harness.runner.handleOutboundBatch(
            [Data(ChainedSessionHarness.ipv4Packet(byteCount: 200, source: [10, 64, 0, 5]))],
            protocols: [NSNumber(value: AF_INET)])
        harness.settle()
        XCTAssertTrue(
            harness.runner.takeLivenessSample().sawObligingSend,
            "user traffic did not arm the silence clock")
    }

    func testOneQueueKeyServesEveryRunner() throws {
        // The driver builds a fresh runner per attempt on ONE queue, so "am I on the queue?" is a
        // fact about the queue. With a per-runner key, a runner handed an injected queue never
        // registers one — so `onQueue` answers "no" while standing on the queue and takes the
        // `queue.sync` branch, which from the queue itself deadlocks. This test would time out
        // rather than fail.
        let queue = ChainedEngineQueue(label: "com.lavasec.test.shared")
        let harnesses = try (0..<3).map { _ in
            try ChainedSessionHarness(engineQueue: queue)
        }
        for harness in harnesses {
            XCTAssertEqual(harness.runner.queuedPacketCount(), 0)
        }

        // The re-entrant case, which is the one that deadlocks: ask a runner about itself from
        // inside work already running on the shared queue.
        let runners = harnesses.map(\.runner)  // the runner is Sendable; the fixture is not
        let answered = expectation(description: "read counters from on-queue")
        queue.enqueue {
            for runner in runners { _ = runner.snapshotCounters() }
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
    }

    // MARK: - The DNS seam (S8.8)

    /// A client's DNS query reaches the resolver instead of vanishing into the engine.
    ///
    /// The arm this covers used to `break` alongside the two drops, which was correct only while
    /// nothing fed this runner. Once the batch arrives here first, a dropped `.handleAsDNS` is
    /// every query the tunnel exists to filter, silently unanswered (`INV-DNS-1`).
    func testAClientDNSQueryIsServedRatherThanDropped() throws {
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()

        let query = Data(ChainedSessionHarness.dnsQueryPacket(sourcePort: 40_000))
        harness.runner.handleOutboundBatch([query], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        XCTAssertEqual(
            harness.dnsServer.served, [query],
            "a client DNS query was swallowed by the chained data path, so it is never answered "
                + "and never filtered")
    }

    /// Our OWN query is carved out before the seam, so serving it can never be reached.
    ///
    /// The two halves of the loop fix meeting: the carve-out decides, and the seam only sees what
    /// the carve-out left. Asserted here rather than only in the classifier suite because this is
    /// the wiring that would send it back to the resolver.
    func testOurOwnResolverQueryIsNotHandedToTheResolver() throws {
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()

        let port: UInt16 = 41_000
        XCTAssertNotNil(
            harness.ownResolverPorts.claim(sourcePort: port, protocolNumber: UInt8(IPPROTO_UDP)))

        let query = Data(ChainedSessionHarness.dnsQueryPacket(sourcePort: port))
        harness.runner.handleOutboundBatch([query], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        XCTAssertEqual(
            harness.dnsServer.count, 0,
            "our own resolver's query was handed back to the resolver, which answers it by "
                + "sending another one")
        XCTAssertEqual(
            harness.runner.snapshotCounters().ownResolverPacketCount, 1,
            "the query was neither served nor carried, so it was simply lost")
    }

    /// A packet RE-classified as DNS on the release path is dropped, not served.
    ///
    /// `releaseStored` re-classifies a packet parked as ordinary traffic. An own-resolver query
    /// whose claim expired while it waited re-classifies as `.handleAsDNS` — and serving that is
    /// the self-resolution loop by another route: our own query, handed to our own resolver,
    /// answered by sending another. The carve-out closed the front door (PR #494); `dnsPacket`
    /// being nil on that path is what closes this one.
    func testAResumedBatchDoesNotServeAQueryWhoseClaimLapsed() throws {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var value: UInt64 = 0
            func now() -> UInt64 { lock.withLock { value } }
            func advance(seconds: UInt64) { lock.withLock { value += seconds * 1_000_000_000 } }
        }
        let clock = Clock()
        let harness = try ChainedSessionHarness(
            ownResolverPorts: ChainedResolverPortRegistry(uptimeNanoseconds: { clock.now() }))
        try harness.completeHandshake()

        let port: UInt16 = 42_000
        XCTAssertNotNil(
            harness.ownResolverPorts.claim(sourcePort: port, protocolNumber: UInt8(IPPROTO_UDP)))

        // Park it: withheld completions fill the send bound, so the query waits in the queue
        // having already been classified as ours and carried.
        harness.channel.withholdCompletions = true
        harness.submitPaced(
            Data(ChainedSessionHarness.taggedPacket(1)),
            count: ChainedSessionRunner.inFlightSendBound)
        let query = Data(ChainedSessionHarness.dnsQueryPacket(sourcePort: port))
        harness.runner.handleOutboundBatch([query], protocols: [NSNumber(value: AF_INET)])
        harness.settle()
        XCTAssertEqual(harness.dnsServer.count, 0, "it was served on the way IN, not on release")

        // The claim lapses while it waits, then the transport catches up and it is re-classified.
        clock.advance(
            seconds: UInt64(ChainedResolverPortRegistry.maximumEntryLifetimeSeconds) + 1)
        harness.channel.releaseCompletions()
        harness.settle()

        XCTAssertEqual(
            harness.dnsServer.count, 0,
            "a parked query whose claim expired was re-classified as a client query and handed "
                + "to the resolver — our own query, served by us, answered by sending another")
    }

    /// A client query sitting past the send bound is still served when the batch resumes.
    ///
    /// Everything after the 16-send cursor in a large batch is classified on RESUMPTION. An
    /// earlier version of this file refused to serve DNS on that path at all, to close the
    /// self-resolution loop — which also silently discarded legitimate client queries, and their
    /// retries under repeated large batches (Codex, PR #495). The loop is closed by the
    /// registry's grace window instead, so this path serves like any other.
    func testAClientQueryAfterTheSendBoundIsStillServed() throws {
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()

        // One batch that runs past the bound, with a never-claimed client query behind the cursor.
        harness.channel.withholdCompletions = true
        var batch = (0..<(ChainedSessionRunner.inFlightSendBound + 2)).map { index in
            Data(ChainedSessionHarness.taggedPacket(index))
        }
        let query = Data(ChainedSessionHarness.dnsQueryPacket(sourcePort: 44_000))
        batch.append(query)
        harness.runner.handleOutboundBatch(
            batch, protocols: batch.map { _ in NSNumber(value: AF_INET) })
        harness.settle()

        // The batch parked before reaching it — otherwise this test proves nothing about
        // resumption.
        XCTAssertEqual(
            harness.dnsServer.count, 0,
            "the batch never parked, so the query was served on the first pass and the resumption "
                + "path is untested")

        harness.channel.releaseCompletions()
        harness.settle()

        XCTAssertEqual(
            harness.dnsServer.served, [query],
            "a client query behind the send-bound cursor was discarded rather than served, so "
                + "under sustained traffic DNS fails for queries that happen to arrive late in a "
                + "batch — and for their retries")
    }

    /// The RELEASE path is the other way a parked packet gets re-classified, and it is a
    /// different code path from a resumed batch.
    ///
    /// `testAResumedBatchDoesNotServeAQueryWhoseClaimLapsed` parks via the batch CURSOR, which
    /// resumes through `processOutboundOnQueue` and never touches `releaseStored`. A mutation
    /// serving DNS from the release path survived it. To reach the queue the packet has to be
    /// refused the cursor, which means something must already hold it.
    func testAReleasedPacketThatReclassifiesAsDNSIsNotServed() throws {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var value: UInt64 = 0
            func now() -> UInt64 { lock.withLock { value } }
            func advance(seconds: UInt64) { lock.withLock { value += seconds * 1_000_000_000 } }
        }

        /// Runs the scenario and answers what the runner did with the query.
        func run(expiringTheClaim: Bool) throws -> (served: Int, carried: Int) {
            let clock = Clock()
            let harness = try ChainedSessionHarness(
                ownResolverPorts: ChainedResolverPortRegistry(uptimeNanoseconds: { clock.now() }))
            try harness.completeHandshake()
            let port: UInt16 = 43_000
            XCTAssertNotNil(
                harness.ownResolverPorts.claim(
                    sourcePort: port, protocolNumber: UInt8(IPPROTO_UDP)))

            // Fill the send bound AND claim the cursor, so the query behind them is refused the
            // cursor and takes the QUEUE — which is the only path through `releaseStored`.
            harness.channel.withholdCompletions = true
            harness.submitPaced(
                Data(ChainedSessionHarness.taggedPacket(1)),
                count: ChainedSessionRunner.inFlightSendBound + 1)
            harness.runner.handleOutboundBatch(
                [Data(ChainedSessionHarness.dnsQueryPacket(sourcePort: port))],
                protocols: [NSNumber(value: AF_INET)])
            harness.settle()

            if expiringTheClaim {
                clock.advance(
                    seconds: UInt64(ChainedResolverPortRegistry.maximumEntryLifetimeSeconds) + 1)
            }
            harness.channel.releaseCompletions()
            harness.settle()
            return (harness.dnsServer.count,
                    harness.runner.snapshotCounters().ownResolverPacketCount)
        }

        // THE CONTROL FIRST, because the assertion below passes just as well against a scenario
        // where the query never reached the queue at all. With the claim still live the release
        // re-classifies it as ours and CARRIES it, which is only observable if this path runs.
        let live = try run(expiringTheClaim: false)
        XCTAssertEqual(live.served, 0, "a live claim served DNS rather than carrying it")
        XCTAssertGreaterThan(
            live.carried, 0,
            "the query never reached the release path, so the expiry case below proves nothing")

        let lapsed = try run(expiringTheClaim: true)
        XCTAssertEqual(
            lapsed.served, 0,
            "a queued query whose claim expired was re-classified as a client query and handed "
                + "to the resolver — our own query, served by us, answered by sending another")
    }

    // MARK: - Engine timer freshness

    /// `REJECT_AFTER_TIME` is enforced only in `update_timers`, and neither `Tunn::encapsulate`
    /// nor `Tunn::handle_data` consults a timer. So a tick that stops while packets still flow
    /// leaves the engine encrypting on a keypair past its specified lifetime, and unlike the
    /// receive-counter ceiling this needs no attacker — only our own scheduler missing.
    ///
    /// The clock is INJECTED rather than slept through, and it is deliberately not the clock the
    /// blackhole budget runs on; see `ChainedSessionRunner.engineClockNanoseconds()`.
    func testAStalledTickCannotEncapsulateOnAnUnaskedSession() throws {
        let clock = SteppableEngineClock()
        let harness = try ChainedSessionHarness(engineClock: clock.read)
        try harness.completeHandshake()
        let packet = ChainedSessionHarness.ipv4Packet(byteCount: 200, source: [10, 64, 0, 5])

        // A packet while the timers are current must NOT drive a pass. Asserted first, because
        // without it every assertion below passes just as well against a guard that fires
        // unconditionally — which is a different bug wearing this one's test.
        harness.runner.handleOutboundBatch([Data(packet)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()
        XCTAssertEqual(
            harness.runner.snapshotCounters().engineTimerCatchUpCount, 0,
            "a fresh session drove a catch-up pass, so the bound is not being consulted")

        // Exactly the bound, which is the boundary the guard's `>=` decides.
        clock.advance(by: ChainedSessionRunner.engineTimerFreshnessBoundNanoseconds)
        harness.runner.handleOutboundBatch([Data(packet)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()
        XCTAssertEqual(
            harness.runner.snapshotCounters().engineTimerCatchUpCount, 1,
            "the engine was handed a packet without its timers being asked the time")

        // And the pass RESTAMPED the clock: a second packet at the same instant is fresh again.
        // Without this a guard that never records its pass would drive one per packet forever,
        // which the assertion above cannot tell apart from correct behaviour.
        harness.runner.handleOutboundBatch([Data(packet)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()
        XCTAssertEqual(
            harness.runner.snapshotCounters().engineTimerCatchUpCount, 1,
            "the catch-up pass did not record itself, so every packet now drives one")
    }

    /// The inbound half of the same gap. `Tunn::handle_data` looks the session up by receiver
    /// index and decrypts without consulting a timer either, so accepting on an unasked session
    /// is the same defect facing the other way — and covering only one direction would have been
    /// arbitrary rather than justified.
    func testAStalledTickCannotDecapsulateOnAnUnaskedSession() throws {
        let clock = SteppableEngineClock()
        let harness = try ChainedSessionHarness(engineClock: clock.read)

        // A datagram while the timers are current, for the same reason as above.
        try harness.peerSendsInnerPacket(source: [10, 64, 0, 5])
        XCTAssertEqual(
            harness.runner.snapshotCounters().engineTimerCatchUpCount, 0,
            "a fresh session drove a catch-up pass on the receive path")
        let deliveredWhileFresh = harness.writer.written.count
        XCTAssertGreaterThan(
            deliveredWhileFresh, 0,
            "nothing reached the writer, so the stalled case below would prove nothing")

        clock.advance(by: ChainedSessionRunner.engineTimerFreshnessBoundNanoseconds)
        try harness.deliverInnerPacketFromPeer(source: [10, 64, 0, 6])
        XCTAssertEqual(
            harness.runner.snapshotCounters().engineTimerCatchUpCount, 1,
            "a datagram was decrypted without the engine's timers being asked the time")
    }

    /// The catch-up pass is counted, because it is the guard's only observable on a device.
    ///
    /// A COUNTER rather than an observation of engine output: a pass on a healthy session
    /// produces nothing to observe, so a test that watched the channel would be asserting on
    /// `update_timers` having emitted a keepalive — which depends on where the session is in its
    /// own timer cycle and would pass or fail for reasons unrelated to this guard.
    func testACatchUpPassIsCountedSoTheGuardIsObservable() throws {
        let clock = SteppableEngineClock()
        let harness = try ChainedSessionHarness(engineClock: clock.read)
        try harness.completeHandshake()
        let packet = ChainedSessionHarness.ipv4Packet(byteCount: 200, source: [10, 64, 0, 5])

        for expected in 1...3 {
            clock.advance(by: ChainedSessionRunner.engineTimerFreshnessBoundNanoseconds)
            harness.runner.handleOutboundBatch(
                [Data(packet)], protocols: [NSNumber(value: AF_INET)])
            harness.settle()
            XCTAssertEqual(
                harness.runner.snapshotCounters().engineTimerCatchUpCount, expected,
                "the catch-up tally did not advance on stall \(expected)")
        }
    }

    /// Engine output is counted with NO session established — the dark-session discriminator.
    ///
    /// A chained session that never comes up is flat everywhere a reader would look:
    /// `channelNotReady` counts transitions INTO `waiting`/`failed`, so a socket that reached
    /// `ready` never moves it; `channelSendFailEdges` counts failure edges, so successful sends
    /// never move it; and `txBytes` is PLAINTEXT accepted for encapsulation, which a handshake
    /// initiation is not. So "the engine emitted initiations nobody answered" and "the engine
    /// emitted nothing" produced identical all-zero samples (Codex, PR #585).
    ///
    /// The pair is the assertion: a runner that was asked to handshake counts one, and a runner
    /// that was not counts zero — both with no session, which is the state the ambiguity lives in.
    func testAForcedHandshakeCountsAsEngineOutputEvenWithNoSession() throws {
        let idle = try ChainedSessionHarness()
        idle.settle()
        XCTAssertEqual(
            idle.runner.snapshotCounters().sendToPeerCount, 0,
            "a runner that produced nothing must read zero, or the counter cannot discriminate")

        let harness = try ChainedSessionHarness()
        harness.runner.forceHandshake()
        harness.settle()

        XCTAssertEqual(
            harness.channel.sent.first?.first, 1,
            "the runner did not put a handshake initiation on the wire")
        XCTAssertEqual(
            harness.runner.snapshotCounters().sendToPeerCount, 1,
            "engine output must be counted before any handshake completes")
    }

    /// One stall costs one timer pass, however many packets the batch carries.
    ///
    /// This is the observable consequence of stamping the clock BEFORE driving the tick. Stamping
    /// afterwards — or not at all — makes the pass re-entrant through `perform`, and with the
    /// bound at zero that recursion runs the stack out; it was a crash, not a failed assertion,
    /// when the bound was mutated during verification. Asserting "exactly one" rather than "at
    /// least one" is what makes this test about the ordering instead of about the guard existing.
    func testAStalledBatchDrivesOnePassNotOnePerPacket() throws {
        let clock = SteppableEngineClock()
        let harness = try ChainedSessionHarness(engineClock: clock.read)
        try harness.completeHandshake()
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 200, source: [10, 64, 0, 5]))
        let batch = Array(repeating: packet, count: 8)
        let protocols = Array(repeating: NSNumber(value: AF_INET), count: 8)

        clock.advance(by: ChainedSessionRunner.engineTimerFreshnessBoundNanoseconds)
        harness.runner.handleOutboundBatch(batch, protocols: protocols)
        harness.settle()

        XCTAssertEqual(
            harness.runner.snapshotCounters().engineTimerCatchUpCount, 1,
            "an 8-packet batch drove more than one catch-up pass, so the stamp is not being "
                + "written before the tick and the guard is re-entrant")
    }

    /// Just under the bound is fresh, and this is the assertion that stops the bound being
    /// quietly reduced to zero — under which every other test here still passes.
    func testAStallShorterThanTheBoundDoesNotDriveAPass() throws {
        let clock = SteppableEngineClock()
        let harness = try ChainedSessionHarness(engineClock: clock.read)
        try harness.completeHandshake()
        let packet = ChainedSessionHarness.ipv4Packet(byteCount: 200, source: [10, 64, 0, 5])

        clock.advance(by: ChainedSessionRunner.engineTimerFreshnessBoundNanoseconds - 1)
        harness.runner.handleOutboundBatch([Data(packet)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        XCTAssertEqual(
            harness.runner.snapshotCounters().engineTimerCatchUpCount, 0,
            "a stall one nanosecond short of the bound drove a pass")
    }

    /// The owner's own tick restamps the clock too, so a driver that is ticking normally never
    /// makes the data path pay for a catch-up pass.
    ///
    /// This is what makes the guard free in steady state rather than merely cheap: the assertion
    /// is that `tick()` and the catch-up pass share one stamp, not two.
    func testTheOwnersTickCountsAsTheTimerPass() throws {
        let clock = SteppableEngineClock()
        let harness = try ChainedSessionHarness(engineClock: clock.read)
        try harness.completeHandshake()
        let packet = ChainedSessionHarness.ipv4Packet(byteCount: 200, source: [10, 64, 0, 5])

        clock.advance(by: ChainedSessionRunner.engineTimerFreshnessBoundNanoseconds)
        // The owner ticks, exactly as ChainedOutageDriver does every 250 ms.
        harness.runner.tick()
        harness.settle()

        harness.runner.handleOutboundBatch([Data(packet)], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        XCTAssertEqual(
            harness.runner.snapshotCounters().engineTimerCatchUpCount, 0,
            "the owner's tick did not restamp the freshness clock, so a normally-ticking driver "
                + "pays for a catch-up pass on the data path")
    }

    /// The drain consults the same guard as `encapsulate` and `decapsulate`, and defers to
    /// timer output that consumed the last transport slot.
    ///
    /// The drain is boringtun's `send_queued_packet` — `encapsulate` on whatever keypair is
    /// current — and the path that reaches it stale is real: a transport completion resuming
    /// `releaseStored` is the first thing that runs after a suspension ends, before any owner
    /// tick. Leaving it unguarded was the counterexample to "the guard sits before every engine
    /// call that uses session keys" (Codex, PR #497).
    ///
    /// The local session runs a 1-second persistent keepalive, which is what makes the pass's
    /// EMISSION deterministic: the engine's timers advance on its own real clock — the
    /// 1.5-second sleep is engine time — while the runner's staleness reading stays on the
    /// steppable clock, the same separation production has. The keepalive datagram is 32 bytes
    /// (type + receiver + counter + tag), so "which send took the slot" is readable from size.
    func testAResumedDrainConsultsTheTimersBeforeUsingTheKeys() throws {
        let clock = SteppableEngineClock()
        let harness = try ChainedSessionHarness(engineClock: clock.read, keepaliveSeconds: 1)
        harness.channel.withholdCompletions = true
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 400, source: [10, 64, 0, 5]))
        harness.submitPaced(packet, count: 60)
        harness.settle()
        try harness.completeHandshakeThroughTheChannel()
        XCTAssertEqual(
            harness.channel.sent.count, ChainedSessionRunner.inFlightSendBound,
            "the setup did not reach the send bound, so nothing below measures the drain")

        // Baseline: a completion resuming the drain while the timers are current drives no
        // pass — without this, every assertion below also passes against a guard that fires
        // unconditionally.
        harness.channel.releaseOneCompletion()
        harness.settle()
        XCTAssertEqual(
            harness.runner.snapshotCounters().engineTimerCatchUpCount, 0,
            "a fresh resumption drove a catch-up pass")
        XCTAssertEqual(
            harness.channel.sent.count, ChainedSessionRunner.inFlightSendBound + 1,
            "the fresh drain did not move a packet, so the stale case below proves nothing")

        // Engine time for the keepalive to come due; steppable time for the staleness.
        Thread.sleep(forTimeInterval: 1.5)
        clock.advance(by: ChainedSessionRunner.engineTimerFreshnessBoundNanoseconds)

        harness.channel.releaseOneCompletion()
        harness.settle()
        XCTAssertEqual(
            harness.runner.snapshotCounters().engineTimerCatchUpCount, 1,
            "the resumed drain touched the engine without asking its timers the time")
        XCTAssertEqual(
            harness.channel.sent.count, ChainedSessionRunner.inFlightSendBound + 2,
            "the drain sent past the bound after the catch-up pass consumed the freed slot")
        XCTAssertEqual(
            harness.channel.sent.last?.count, 32,
            "the freed slot carried a drained data packet rather than the pass's keepalive, so "
                + "the drain outran a bound the loop tested before the pass emitted")

        // Deferred, not lost: the next freed slot moves user data again.
        harness.channel.releaseOneCompletion()
        harness.settle()
        XCTAssertEqual(harness.channel.sent.count, ChainedSessionRunner.inFlightSendBound + 3)
        XCTAssertGreaterThan(
            harness.channel.sent.last?.count ?? 0, 32,
            "the refused drain never resumed, so the engine's queue is stranded")
    }

    /// A catch-up pass that consumes the LAST transport slot parks the packet that triggered it.
    ///
    /// The back-pressure decision at the top of `encapsulateOnQueue` is made before the
    /// freshness pass runs, and the pass can send: with `outstandingSends` one short of the
    /// bound, the pass's keepalive takes the final slot, and proceeding to encapsulate would
    /// put the user packet past the hard in-flight limit exactly when the transport is nearly
    /// saturated (Codex, PR #497). Same keepalive arrangement as the drain test above.
    func testATimerPassThatConsumesTheLastSlotParksThePacket() throws {
        let clock = SteppableEngineClock()
        let harness = try ChainedSessionHarness(engineClock: clock.read, keepaliveSeconds: 1)
        try harness.completeHandshake()
        harness.channel.withholdCompletions = true
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 400, source: [10, 64, 0, 5]))
        // One slot short of the bound, so the entry check passes and only the pass's own
        // emission can close the gap.
        harness.submitPaced(packet, count: ChainedSessionRunner.inFlightSendBound - 1)
        harness.settle()
        XCTAssertEqual(
            harness.channel.sent.count, ChainedSessionRunner.inFlightSendBound - 1,
            "the transport is not one slot short, so the pass below cannot consume the last one")
        XCTAssertEqual(harness.runner.queuedPacketCount(), 0)

        Thread.sleep(forTimeInterval: 1.5)
        clock.advance(by: ChainedSessionRunner.engineTimerFreshnessBoundNanoseconds)

        harness.runner.handleOutboundBatch([packet], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        XCTAssertEqual(harness.runner.snapshotCounters().engineTimerCatchUpCount, 1)
        XCTAssertEqual(
            harness.channel.sent.count, ChainedSessionRunner.inFlightSendBound,
            "the packet was encapsulated past the bound the pass's keepalive had just filled")
        XCTAssertEqual(
            harness.channel.sent.last?.count, 32,
            "the last slot carried the user packet rather than the pass's keepalive, so the "
                + "back-pressure decision was not re-made after the pass")
        // In the CURSOR, not the queue: a declined packet re-enters the batch loop, whose park
        // logic holds it by reference with the rest of its batch. Copying it into the queue
        // here is the arrangement that either reorders (queue released after a cursor the same
        // batch can still claim) or forces the remainder onto the copying path.
        XCTAssertEqual(
            harness.runner.queuedPacketCount(), 0,
            "the declined packet was copied into the queue instead of re-parking with its batch")

        // Parked, not lost.
        harness.channel.releaseCompletions()
        harness.settle()
        XCTAssertEqual(harness.runner.queuedPacketCount(), 0)
        XCTAssertEqual(
            harness.channel.sent.count, ChainedSessionRunner.inFlightSendBound + 1,
            "the parked packet never left once the transport recovered")
    }

    /// Across repeated timer stalls whose passes emit keepalives, every packet of a stalled
    /// batch still reaches the peer exactly once, in arrival order.
    ///
    /// The composition this pins: with a batch parked, a completion always reaches the DRAIN
    /// first (every send re-arms `enginePacketsPending`), so the drain's guard is what absorbs
    /// the stall — it drives the pass, defers to the keepalive that consumed the freed slot,
    /// and the resumption then advances on fresh timers. Asserted end to end by decrypting at
    /// the peer, because ordering is a property of what arrives, not of which branch ran.
    func testArrivalOrderHoldsAcrossTimerStallsAndTheirKeepalives() throws {
        let clock = SteppableEngineClock()
        let harness = try ChainedSessionHarness(engineClock: clock.read, keepaliveSeconds: 1)
        try harness.completeHandshake()
        harness.channel.withholdCompletions = true

        var batch: [Data] = []
        var arrival: [Int] = []
        for tag in 0..<20 {
            batch.append(Data(ChainedSessionHarness.taggedPacket(tag)))
            arrival.append(tag)
        }
        harness.runner.handleOutboundBatch(batch, protocols: batch.map { _ in NSNumber(value: AF_INET) })
        harness.settle()
        XCTAssertEqual(harness.channel.sent.count, ChainedSessionRunner.inFlightSendBound)
        XCTAssertEqual(
            harness.runner.queuedPacketCount(), 0,
            "the tail of the batch was copied into the queue instead of the cursor, so nothing "
                + "below exercises the cursor path")

        // First stall: the freed slot goes to the drain's own guard — its pass emits the due
        // keepalive, and the drain defers rather than sending a seventeenth datagram.
        Thread.sleep(forTimeInterval: 1.5)
        clock.advance(by: ChainedSessionRunner.engineTimerFreshnessBoundNanoseconds)
        harness.channel.releaseOneCompletion()
        harness.settle()
        XCTAssertEqual(harness.runner.snapshotCounters().engineTimerCatchUpCount, 1)
        XCTAssertEqual(harness.channel.sent.last?.count, 32)

        // Work the batch forward on fresh timers until the engine has nothing pending, so the
        // NEXT stall reaches the resumption loop itself rather than the drain.
        harness.channel.releaseOneCompletion()
        harness.settle()

        // Second stall, now with the cursor mid-batch: the drain absorbs this one too, and the
        // batch must neither lose its place nor leak a packet into the queue.
        Thread.sleep(forTimeInterval: 1.5)
        clock.advance(by: ChainedSessionRunner.engineTimerFreshnessBoundNanoseconds)
        harness.channel.releaseOneCompletion()
        harness.settle()
        XCTAssertEqual(
            harness.runner.queuedPacketCount(), 0,
            "a stalled resumption copied a packet into the queue, which releases after the "
                + "cursor its own batch can still claim — a reorder waiting to be released")

        harness.channel.releaseCompletions()
        harness.settle()

        let delivered = try harness.tagsDecryptedByPeer()
        XCTAssertEqual(
            delivered.count, arrival.count,
            "a declined packet was skipped rather than re-parked, so it never reached the peer")
        XCTAssertEqual(
            delivered, arrival,
            "the batch was released around a packet the pass declined, so newer packets "
                + "overtook an older one")
    }

    /// A rebind whose own freshness consult fills the replacement channel skips the probe.
    ///
    /// Either consult in `adoptChannel` can emit a timer datagram, and its `perform` runs
    /// `releaseStored()` — handing the replacement a pending batch and a parked queue up to
    /// the bound before the probe line runs. The probe does not go through
    /// `encapsulateOnQueue`, so it needs its own post-consult capacity check. Skipping is
    /// honest: the sends that filled the bound are obliging user traffic on the new socket,
    /// which probes the path harder than the unobliging keepalive would have.
    func testARebindWhoseConsultFillsTheChannelSkipsTheProbe() throws {
        let clock = SteppableEngineClock()
        let harness = try ChainedSessionHarness(engineClock: clock.read, keepaliveSeconds: 1)
        try harness.completeHandshake()
        harness.channel.withholdCompletions = true
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 400, source: [10, 64, 0, 5]))
        harness.submitPaced(packet, count: ChainedSessionRunner.inFlightSendBound)
        harness.settle()
        XCTAssertEqual(harness.channel.sent.count, ChainedSessionRunner.inFlightSendBound)
        // One more claims the cursor, and the rest copy into the queue behind it — inventory
        // for the consult's release to hand the replacement.
        harness.submitPaced(packet, count: ChainedSessionRunner.inFlightSendBound)
        harness.settle()
        XCTAssertGreaterThan(
            harness.runner.queuedPacketCount(), 0,
            "nothing is parked, so the consult's release has nothing to fill the channel with")

        Thread.sleep(forTimeInterval: 1.5)
        clock.advance(by: ChainedSessionRunner.engineTimerFreshnessBoundNanoseconds)

        let replacement = FakeChannel()
        replacement.withholdCompletions = true
        let outcome = harness.runner.adoptChannel(replacement)
        harness.settle()

        XCTAssertEqual(outcome, .rebound)
        XCTAssertEqual(
            replacement.sent.first?.count, 32,
            "the consult's pass did not emit the keepalive, so nothing below distinguishes "
                + "the probe from the release")
        XCTAssertEqual(
            replacement.sent.count, ChainedSessionRunner.inFlightSendBound,
            "the probe was sent past a bound the consult's own release had just filled")
    }

    /// At the send bound, a stale inbound datagram is dropped WITHOUT driving the pass.
    ///
    /// The inbound path is the one with no capacity check ahead of its consult, so the
    /// pass's emission — here a due keepalive — would take a seventeenth slot. Not driving
    /// the pass and decapsulating anyway would accept on unasked timers, so the datagram is
    /// dropped instead: the UDP loss the path's own comment already accepts. A fresh
    /// datagram at the same saturation still delivers, which is what keeps this a staleness
    /// rule rather than a new coupling of the two directions.
    func testASaturatedInboundPathDropsStaleDatagramsWithoutDrivingThePass() throws {
        let clock = SteppableEngineClock()
        let harness = try ChainedSessionHarness(engineClock: clock.read, keepaliveSeconds: 1)
        try harness.completeHandshake()
        harness.channel.withholdCompletions = true
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 400, source: [10, 64, 0, 5]))
        harness.submitPaced(packet, count: ChainedSessionRunner.inFlightSendBound)
        harness.settle()
        XCTAssertEqual(harness.channel.sent.count, ChainedSessionRunner.inFlightSendBound)

        // Saturated but FRESH: inbound still delivers. Without this leg, every assertion
        // below also passes against a path that drops all inbound at the bound.
        try harness.deliverInnerPacketFromPeer(source: [10, 64, 0, 6])
        let deliveredWhileFresh = harness.writer.written.count
        XCTAssertGreaterThan(
            deliveredWhileFresh, 0,
            "a fresh datagram was dropped at the bound, so saturation is coupling the two "
                + "directions rather than gating the pass")

        Thread.sleep(forTimeInterval: 1.5)
        clock.advance(by: ChainedSessionRunner.engineTimerFreshnessBoundNanoseconds)

        try harness.deliverInnerPacketFromPeer(source: [10, 64, 0, 7])
        XCTAssertEqual(
            harness.writer.written.count, deliveredWhileFresh,
            "a stale datagram was decapsulated at the bound, on timers nothing had asked")
        XCTAssertEqual(
            harness.runner.snapshotCounters().engineTimerCatchUpCount, 0,
            "the saturated inbound path drove the pass, whose emission bypasses the bound")
        XCTAssertEqual(
            harness.channel.sent.count, ChainedSessionRunner.inFlightSendBound,
            "the pass's keepalive was sent past the bound from the inbound path")
    }

    /// At the send bound, a datagram that obliges a reply is dropped before decapsulation.
    ///
    /// A handshake initiation produces our response; a handshake response produces our
    /// keepalive — both through the same `perform` as everything else, taking a slot past
    /// the hard limit. The type gate is the difference between this and coupling the two
    /// directions: transport data never sends from decapsulation, so inbound user traffic
    /// still delivers at full outbound saturation (the fresh leg of the test above).
    func testAReplyObligingDatagramIsDroppedAtTheBound() throws {
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        harness.channel.withholdCompletions = true
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 400, source: [10, 64, 0, 5]))
        harness.submitPaced(packet, count: ChainedSessionRunner.inFlightSendBound)
        harness.settle()
        XCTAssertEqual(harness.channel.sent.count, ChainedSessionRunner.inFlightSendBound)

        // The peer initiates a rekey while our transport is saturated: answering would be
        // the seventeenth send.
        var initiation = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let initiationOutcome = try harness.peerSession.forceHandshake(into: &initiation)
        Array(initiation[..<initiationOutcome.byteCount]).withUnsafeBytes {
            harness.channel.deliver($0)
        }
        harness.settle()
        XCTAssertEqual(
            harness.channel.sent.count, ChainedSessionRunner.inFlightSendBound,
            "the peer's initiation was answered past the bound")

        // One freed slot, and the next initiation IS answered — the drop was the bound's,
        // not a new rule against rekeys.
        harness.channel.releaseOneCompletion()
        harness.settle()
        var retry = [UInt8](repeating: 0, count: WireGuardSession.maximumDatagramByteCount)
        let retryOutcome = try harness.peerSession.forceHandshake(into: &retry)
        Array(retry[..<retryOutcome.byteCount]).withUnsafeBytes {
            harness.channel.deliver($0)
        }
        harness.settle()
        XCTAssertEqual(
            harness.channel.sent.count, ChainedSessionRunner.inFlightSendBound + 1,
            "a rekey initiation below the bound went unanswered, so the gate is dropping "
                + "more than the bound requires")
    }

    // MARK: - Data-path observability (brief-stall investigation, 2026-08-24)

    func testAFailedSendCompletionIsCountedAndStillFreesItsSlot() throws {
        // The completion's Bool was discarded for eight slices — a transport failing every
        // send left zero trace anywhere. The counter must move, and the RESUME must not: a
        // failed send still frees its in-flight slot, or one bad spell would park the data
        // path at the bound forever.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()
        harness.channel.completeWithFailure = true

        let packetCount = ChainedSessionRunner.inFlightSendBound + 4
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 400, source: [10, 64, 0, 5]))
        harness.submitPaced(packet, count: packetCount)
        harness.settle()

        XCTAssertEqual(
            harness.channel.sent.count, packetCount,
            "failed completions stopped freeing slots — the runner parked at the bound "
                + "against a transport that was answering (with errors) every time")
        XCTAssertEqual(
            harness.runner.snapshotCounters().sendCompletionErrorCount, packetCount,
            "every erroring completion must be tallied, or the 60 s delta undercounts "
                + "exactly the failure volume it exists to name")
    }

    func testARetiredChannelsFailedCompletionIsNotCountedAgainstTheNewChannel() throws {
        // The counter's doc says "current channel only", and the tally sits inside the
        // generation guard to make that true. Untested, that is exactly the kind of claim this
        // file's history is full of retracting: a retired socket failing every held send is the
        // NORMAL shape of a rebind away from a dead path, so a tally outside the guard would
        // attribute the OLD socket's death to the replacement — the fresh socket would look
        // broken on the very liveness line meant to show it recovering.
        let harness = try ChainedSessionHarness()
        try harness.completeHandshake()

        harness.channel.withholdCompletions = true
        harness.submitPaced(Data(ChainedSessionHarness.taggedPacket(1)), count: 4)
        harness.settle()
        XCTAssertEqual(
            harness.runner.snapshotCounters().sendCompletionErrorCount, 0,
            "nothing has completed yet, so the case would be vacuous")

        let replacement = RebindableFakeChannel()
        XCTAssertEqual(harness.runner.adoptChannel(replacement), .rebound)

        // The retired channel now answers everything it was holding — as FAILURES, which is
        // what a socket whose interface went away actually reports.
        harness.channel.releaseCompletions(succeeded: false)
        harness.settle()

        XCTAssertEqual(
            harness.runner.snapshotCounters().sendCompletionErrorCount, 0,
            "a retired transport's failures were charged to the live one — the counter no "
                + "longer means what its doc says, and a healthy replacement reads as failing")
    }

    func testAnEvictingParkEmitsAPressureEventAtTheMoment() throws {
        // The shed tally says HOW MANY; a sub-60 s stall also needs WHEN. The event fires at
        // the eviction itself, with the queue-admission verdict, so a device log line carries
        // the timestamp a counter delta cannot.
        let recorded = RecordedPressureEvents()
        let harness = try ChainedSessionHarness(diagnostics: { recorded.record($0) })
        try harness.completeHandshake()
        harness.channel.withholdCompletions = true
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 400, source: [10, 64, 0, 5]))
        harness.submitPaced(packet, count: 330)
        harness.settle()

        XCTAssertGreaterThan(
            harness.runner.snapshotCounters().shedPacketCount, 0,
            "the fixture did not evict, so there was no moment to report")
        let evictions = recorded.all.filter {
            if case .outboundQueuePressure(let admission, _) = $0 {
                return admission.hasPrefix("queued-evicting")
            }
            return false
        }
        XCTAssertFalse(
            evictions.isEmpty,
            "sustained eviction emitted no pressure event — the loss happened with no "
                + "timestamp again")
    }

    func testALosslessParkEmitsNoPressureEvent() throws {
        // Ordinary back-pressure — parked and later delivered, nothing lost — is the queue
        // doing its job. An event per park would bury the losses under the routine.
        let recorded = RecordedPressureEvents()
        let harness = try ChainedSessionHarness(diagnostics: { recorded.record($0) })
        try harness.completeHandshake()
        harness.channel.withholdCompletions = true
        let packet = Data(ChainedSessionHarness.ipv4Packet(byteCount: 400, source: [10, 64, 0, 5]))
        // Past the send bound (so packets park) but far inside the queue's 256-packet depth.
        harness.submitPaced(packet, count: ChainedSessionRunner.inFlightSendBound + 8)
        harness.settle()

        XCTAssertGreaterThan(
            harness.runner.queuedPacketCount(), 0, "nothing parked, so the case is vacuous")
        XCTAssertTrue(
            recorded.all.isEmpty,
            "a lossless park was reported as pressure — the event must mean 'something was "
                + "lost NOW', not 'the queue is in use'")
    }

    func testABatchRefusedAtTheBacklogEmitsAPressureEvent() throws {
        let recorded = RecordedPressureEvents()
        let harness = try ChainedSessionHarness(diagnostics: { recorded.record($0) })
        try harness.completeHandshake()
        let ceiling = ChainedSessionRunner.outboundAdmissionLimits.maximumBytes
        XCTAssertTrue(harness.runner.outboundAdmission.admit(bytes: ceiling, units: 0))

        harness.runner.handleOutboundBatch(
            [Data(ChainedSessionHarness.taggedPacket(7))], protocols: [NSNumber(value: AF_INET)])
        harness.settle()

        XCTAssertEqual(
            recorded.all,
            [.outboundBacklogRefused(packets: 1, bytes: ChainedSessionHarness.taggedPacket(7).count)],
            "a refusal at the dispatch boundary is a whole batch lost — its moment must be "
                + "reportable, not only its count")
    }

    func testADatagramRefusedAtTheInboundBacklogEmitsAPressureEvent() throws {
        let recorded = RecordedPressureEvents()
        let harness = try ChainedSessionHarness(diagnostics: { recorded.record($0) })
        let wire = try harness.peerEncapsulated(source: [93, 184, 216, 34])
        let ceiling = ChainedSessionRunner.inboundAdmissionLimits.maximumBytes
        XCTAssertTrue(harness.runner.inboundAdmission.admit(bytes: ceiling, units: 0))

        wire.withUnsafeBytes { harness.channel.deliver($0) }
        harness.settle()

        XCTAssertEqual(
            recorded.all, [.inboundBacklogRefused(bytes: wire.count)],
            "an inbound refusal before the copy left no moment in the log")
    }
}

/// Records the runner's pressure events, from whatever thread they fire on.
private final class RecordedPressureEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ChainedDataPathPressureEvent] = []
    var all: [ChainedDataPathPressureEvent] { lock.withLock { storage } }
    func record(_ event: ChainedDataPathPressureEvent) {
        lock.withLock { storage.append(event) }
    }
}
