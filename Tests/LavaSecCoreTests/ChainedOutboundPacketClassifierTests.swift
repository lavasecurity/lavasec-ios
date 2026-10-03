import XCTest

@testable import LavaSecChainedUpstream
@testable import LavaSecKit
@testable import LavaSecDNS

/// The decision that stands between `0.0.0.0/0` and every non-DNS packet vanishing.
///
/// Today's packet loop drops anything `IPv4UDPDNSPacket` refuses. That is correct while the
/// tunnel claims `10.255.0.0/24` and a total blackhole once it claims everything, so these
/// tests are about the packets nobody currently sends through this path.
final class ChainedOutboundPacketClassifierTests: XCTestCase {

    func testDoHProfileEndpointsDoNotEscapeThroughSplitPeer() {
        let claimed = ChainedClaimedResolverDestinations(resolverAddresses: ["1.1.1.1"], httpsResolverAddresses: ["1.1.1.1"])
        for packet in [Self.tcpPacket(destination: [1,1,1,1], destinationPort: 443),
                       Self.udpPacket(destination: [1,1,1,1], destinationPort: 443, payload: [1,2])] {
            XCTAssertEqual(Self.classifyClaiming(packet, claimed), .dropUnfilterableDNS(byteCount: packet.count))
        }
        let allowed = Self.tcpPacket(destination: [93,184,216,34], destinationPort: 443)
        XCTAssertEqual(Self.classifyClaiming(allowed, claimed), .encapsulate(byteCount: allowed.count))
        let dns = Self.udpPacket(destination: [1,1,1,1], destinationPort: 53, payload: [1,2])
        XCTAssertEqual(Self.classifyClaiming(dns, claimed), .handleAsDNS(byteCount: dns.count))
        var fragment = Self.udpPacket(destination: [1,1,1,1], destinationPort: 123, payload: [1,2])
        fragment[7] = 1
        XCTAssertEqual(Self.classifyClaiming(fragment, claimed), .dropUnfilterableDNS(byteCount: fragment.count))
    }

    // MARK: - The DNS branch

    func testADNSQueryToTheTunnelResolverIsHandledLocally() {
        let packet = Self.udpPacket(destination: [10, 255, 0, 1], destinationPort: 53, payload: [0xAB, 0xCD])
        XCTAssertEqual(Self.classify(packet), .handleAsDNS(byteCount: packet.count))
    }

    func testADNSQueryToAPublicResolverIsStillIntercepted() {
        // The decision this slice makes explicit, rather than inheriting by accident.
        //
        // `IPv4UDPDNSPacket` gates on the port and parses the destination address without
        // consulting it. Under a /24 claim those are the same rule; under 0.0.0.0/0 they are
        // not, and this is the case that separates them.
        //
        // Narrowing interception to the tunnel resolver would hand every hardcoded-resolver
        // query — the 8.8.8.8 an app compiled in, the 1.1.1.1 a console insists on — to the
        // peer as ordinary encrypted traffic: unfiltered, because filtering lives on the path
        // it skipped, and legible to the upstream operator, who is the party the user chose
        // this feature to hide from. That is INV-DNS-1 failing open.
        let toTunnel = Self.udpPacket(destination: [10, 255, 0, 1], destinationPort: 53, payload: [0xAB, 0xCD])
        let toPublic = Self.udpPacket(destination: [8, 8, 8, 8], destinationPort: 53, payload: [0xAB, 0xCD])

        XCTAssertEqual(Self.classify(toPublic), .handleAsDNS(byteCount: toPublic.count))
        XCTAssertEqual(Self.classify(toPublic), Self.classify(toTunnel), "the destination changed the verdict")
    }

    func testAPortFiftyThreeDatagramWithNoPayloadIsNotTreatedAsAQuery() {
        // The DNS parser rejects it, so calling it DNS would break the differential property
        // below. It is DROPPED rather than forwarded — the earlier answer was to encapsulate,
        // on the correct-but-irrelevant grounds that an empty datagram has no query bytes to
        // leak. It left "nothing addressed to port 53 reaches the peer" with an exception, and
        // it diverged from the DNS-only path, which discards this packet too.
        let packet = Self.udpPacket(destination: [10, 255, 0, 1], destinationPort: 53, payload: [])
        XCTAssertNil(IPv4UDPDNSPacket(Data(packet)), "the DNS parser accepts it after all")
        XCTAssertEqual(Self.classify(packet), .dropUnfilterableDNS(byteCount: packet.count))
    }

    // MARK: - Traffic that would vanish today

    func testOrdinaryTrafficIsEncapsulatedRatherThanDropped() {
        // Each of these reaches `handle(packet:)` today and is silently discarded the moment
        // the route plan claims everything.
        let tcpSYN = Self.ipv4Packet(protocolNumber: UInt8(IPPROTO_TCP), payload: [UInt8](repeating: 0, count: 20))
        let icmpEcho = Self.ipv4Packet(protocolNumber: UInt8(IPPROTO_ICMP), payload: [8, 0, 0, 0, 0, 0, 0, 0])
        let quic = Self.udpPacket(destination: [93, 184, 216, 34], destinationPort: 443, payload: [1, 2, 3, 4])
        let ntp = Self.udpPacket(destination: [17, 253, 34, 125], destinationPort: 123, payload: [1, 2, 3, 4])

        for packet in [tcpSYN, icmpEcho, quic, ntp] {
            XCTAssertEqual(Self.classify(packet), .encapsulate(byteCount: packet.count))
        }
    }

    func testABareTCPAckIsEncapsulatedRatherThanCalledMalformed() {
        // 40 bytes: a legal IPv4 header plus a legal TCP header, and shorter than the
        // 20-plus-UDP-header floor the DNS parser needs. Reading "too short for UDP" as
        // "malformed" would blackhole every TCP flow's acknowledgements.
        let ack = Self.ipv4Packet(protocolNumber: UInt8(IPPROTO_TCP), payload: [UInt8](repeating: 0, count: 20))
        XCTAssertEqual(ack.count, 40)
        XCTAssertEqual(Self.classify(ack), .encapsulate(byteCount: 40))
    }

    func testDNSOverTCPIsDroppedRatherThanHandedToThePeer() {
        // My own rationale for intercepting UDP/53 condemned this: a TCP/53 query is DNS, most
        // often the retry a truncated UDP answer forces, so encapsulating it hands the peer the
        // exact query the UDP interception just protected. The DNS path reads UDP only, so it
        // cannot be handled locally — INV-DNS-1 says fail closed, not fail outward.
        for destination in [[10, 255, 0, 1] as [UInt8], [8, 8, 8, 8]] {
            let packet = Self.tcpPacket(destination: destination, destinationPort: 53)
            XCTAssertEqual(Self.classify(packet), .dropUnfilterableDNS(byteCount: packet.count))
        }
        // Ordinary TCP is untouched — this must not become "drop TCP".
        let https = Self.tcpPacket(destination: [93, 184, 216, 34], destinationPort: 443)
        XCTAssertEqual(Self.classify(https), .encapsulate(byteCount: https.count))
    }

    func testDoTIsDroppedOnlyWhenTheDataPathClaimsEveryDestination() {
        // DoT (TCP/853) and DoQ (UDP/853) are encrypted DNS the tunnel cannot read. In a FULL
        // tunnel every destination is claimed and no chained rung needs 853, so they are dropped
        // rather than handed to the peer unfiltered. In a SPLIT tunnel the user's own 853 resolver
        // may egress physically, so the drop stays off and the packet is ordinary traffic.
        let dot = Self.tcpPacket(destination: [8, 8, 8, 8], destinationPort: 853)
        XCTAssertEqual(
            Self.classifyDroppingEncryptedDNS(dot),
            .dropUnfilterableEncryptedDNS(byteCount: dot.count))
        XCTAssertEqual(Self.classify(dot), .encapsulate(byteCount: dot.count))

        let doq = Self.udpPacket(
            destination: [8, 8, 8, 8], destinationPort: 853, payload: [1, 2, 3, 4])
        XCTAssertEqual(
            Self.classifyDroppingEncryptedDNS(doq),
            .dropUnfilterableEncryptedDNS(byteCount: doq.count))
        XCTAssertEqual(Self.classify(doq), .encapsulate(byteCount: doq.count))

        // Ordinary HTTPS is untouched — this must not become "drop encrypted traffic".
        let https = Self.tcpPacket(destination: [93, 184, 216, 34], destinationPort: 443)
        XCTAssertEqual(
            Self.classifyDroppingEncryptedDNS(https), .encapsulate(byteCount: https.count))

        // A fragmented DoQ head is dropped, and remembered so its tails drop too.
        var fragmented = Self.udpPacket(
            destination: [8, 8, 8, 8], destinationPort: 853, payload: [1, 2, 3, 4])
        fragmented[6] = 0x20
        XCTAssertEqual(
            Self.classifyDroppingEncryptedDNS(fragmented),
            .dropUnfilterableEncryptedDNS(byteCount: fragmented.count))

        // A DAMAGED total-length field must not become a hole: the length-unreadable path reads
        // the port too, so a port-853 datagram with a nonsense length is still dropped under the
        // flag rather than handed to the peer with its payload intact. (Kilo, PR #739.)
        for damaged in [
            Self.udpPacket(destination: [8, 8, 8, 8], destinationPort: 853, payload: [1, 2, 3, 4]),
            Self.tcpPacket(destination: [8, 8, 8, 8], destinationPort: 853),
        ] {
            var shortTotal = damaged
            shortTotal[2] = 0
            shortTotal[3] = 20
            XCTAssertEqual(
                Self.classifyDroppingEncryptedDNS(shortTotal),
                .dropUnfilterableEncryptedDNS(byteCount: shortTotal.count),
                "a damaged length forwarded a port-853 packet")
            var longTotal = damaged
            longTotal[2] = 0xFF
            XCTAssertEqual(
                Self.classifyDroppingEncryptedDNS(longTotal),
                .dropUnfilterableEncryptedDNS(byteCount: longTotal.count),
                "an overlong length forwarded a port-853 packet")
        }
        // Anti-vacuity: damaged-length traffic to a non-853 port is still ordinary.
        var damagedHTTPS = Self.udpPacket(
            destination: [93, 184, 216, 34], destinationPort: 443, payload: [1, 2])
        damagedHTTPS[2] = 0xFF
        XCTAssertEqual(
            Self.classifyDroppingEncryptedDNS(damagedHTTPS),
            .encapsulate(byteCount: damagedHTTPS.count))
    }

    func testPort853FragmentContinuationsStayGenericWithoutATransportHeader() {
        let claimed = ChainedClaimedResolverDestinations(resolverAddresses: ["9.9.9.9"])
        for dropsEveryDestination in [false, true] {
            for packet in [
                Self.tcpPacket(destination: [9, 9, 9, 9], destinationPort: 853),
                Self.udpFragmentHead(
                    destination: [9, 9, 9, 9], destinationPort: 853,
                    reassembledPayloadByteCount: 2992),
            ] {
                var head = packet
                head[6] = 0x20
                var fragments = ChainedDroppedFragmentTable()
                XCTAssertEqual(
                    Self.classify(
                        head, fragments: &fragments,
                        claimedResolverDestinations: dropsEveryDestination ? .empty : claimed,
                        dropsUnfilterableEncryptedDNS: dropsEveryDestination),
                    .dropUnfilterableEncryptedDNS(byteCount: head.count))

                // These bytes still spell 853 at the would-be port offset, but a continuation
                // has no transport header. Its retained denial must not invent port attribution.
                let tail = Self.tail(of: head)
                XCTAssertEqual(tail[22], 3)
                XCTAssertEqual(tail[23], 85)
                XCTAssertEqual(
                    Self.classify(
                        tail, fragments: &fragments,
                        claimedResolverDestinations: dropsEveryDestination ? .empty : claimed,
                        dropsUnfilterableEncryptedDNS: dropsEveryDestination),
                    .dropUnfilterableDNS(byteCount: tail.count))

                let unrelatedTail = Self.identified(tail, 1)
                XCTAssertEqual(
                    Self.classify(
                        unrelatedTail, fragments: &fragments,
                        claimedResolverDestinations: dropsEveryDestination ? .empty : claimed,
                        dropsUnfilterableEncryptedDNS: dropsEveryDestination),
                    .encapsulate(byteCount: unrelatedTail.count),
                    "payload bytes that resemble port 853 cannot create a fragment denial")
            }
        }
    }

    func testMalformedIPv4UDPLengthKeepsMalformedAttributionOnPort853() {
        let claimed = ChainedClaimedResolverDestinations(resolverAddresses: ["9.9.9.9"])
        for udpLength in [UInt16(7), UInt16.max] {
            var packet = Self.udpPacket(
                destination: [9, 9, 9, 9], destinationPort: 853, payload: [1, 2, 3, 4])
            packet[24] = UInt8(udpLength >> 8)
            packet[25] = UInt8(udpLength & 0xFF)
            XCTAssertEqual(Self.classifyDroppingEncryptedDNS(packet), .dropMalformed)
            XCTAssertEqual(Self.classifyClaiming(packet, claimed), .dropMalformed)
        }
    }

    // MARK: - F4: encrypted DNS to a CLAIMED resolver destination is refused in split

    /// The F4 rule, IPv4 TCP/853 (DoT) plus the damaged-length shape.
    ///
    /// RED before the slice: with no full-tunnel flag the classifier encapsulated every `:853`,
    /// so a claimed resolver's DoT rode to the peer unfiltered. GREEN after: a destination the
    /// F3b capture floor claimed is refused, while an UNCLAIMED destination keeps the split
    /// behaviour the T1 rung may depend on.
    func testDotToAClaimedResolverDestinationIsDroppedInSplit() {
        let claimed = ChainedClaimedResolverDestinations(resolverAddresses: ["9.9.9.9"])
        let dot = Self.tcpPacket(destination: [9, 9, 9, 9], destinationPort: 853)
        XCTAssertEqual(
            Self.classifyClaiming(dot, claimed), .dropUnfilterableEncryptedDNS(byteCount: dot.count))

        // The same flow to an UNCLAIMED destination is untouched — the drop is destination
        // scoped, not "drop all TCP/853".
        let unclaimed = Self.tcpPacket(destination: [8, 8, 8, 8], destinationPort: 853)
        XCTAssertEqual(
            Self.classifyClaiming(unclaimed, claimed), .encapsulate(byteCount: unclaimed.count))

        // Ordinary HTTPS to the claimed resolver is not encrypted DNS and stays ordinary.
        let https = Self.tcpPacket(destination: [9, 9, 9, 9], destinationPort: 443)
        XCTAssertEqual(Self.classifyClaiming(https, claimed), .encapsulate(byteCount: https.count))

        // A DAMAGED total-length field on the claimed flow must not become a hole (PR #739's
        // rule, now destination-scoped).
        for damaged in [
            Self.tcpPacket(destination: [9, 9, 9, 9], destinationPort: 853),
            Self.udpPacket(destination: [9, 9, 9, 9], destinationPort: 853, payload: [1, 2, 3, 4]),
        ] {
            var shortTotal = damaged
            shortTotal[2] = 0
            shortTotal[3] = 20
            XCTAssertEqual(
                Self.classifyClaiming(shortTotal, claimed),
                .dropUnfilterableEncryptedDNS(byteCount: shortTotal.count),
                "a damaged length forwarded a claimed port-853 packet")
            var longTotal = damaged
            longTotal[2] = 0xFF
            XCTAssertEqual(
                Self.classifyClaiming(longTotal, claimed),
                .dropUnfilterableEncryptedDNS(byteCount: longTotal.count),
                "an overlong length forwarded a claimed port-853 packet")
        }
    }

    /// The F4 rule, IPv4 UDP/853 (DoQ), including a claimed fragmented head.
    func testDoqToAClaimedResolverDestinationIsDroppedInSplit() {
        let claimed = ChainedClaimedResolverDestinations(resolverAddresses: ["9.9.9.9"])
        let doq = Self.udpPacket(
            destination: [9, 9, 9, 9], destinationPort: 853, payload: [1, 2, 3, 4])
        XCTAssertEqual(
            Self.classifyClaiming(doq, claimed), .dropUnfilterableEncryptedDNS(byteCount: doq.count))

        // Unclaimed DoQ is the split rung's ordinary traffic.
        let unclaimed = Self.udpPacket(
            destination: [8, 8, 8, 8], destinationPort: 853, payload: [1, 2, 3, 4])
        XCTAssertEqual(
            Self.classifyClaiming(unclaimed, claimed), .encapsulate(byteCount: unclaimed.count))

        // A claimed fragmented DoQ head is dropped, so its continuations are silenced too.
        var fragmented = Self.udpPacket(
            destination: [9, 9, 9, 9], destinationPort: 853, payload: [1, 2, 3, 4])
        fragmented[6] = 0x20
        var fragments = ChainedDroppedFragmentTable()
        XCTAssertEqual(
            Self.classify(
                fragmented, fragments: &fragments, claimedResolverDestinations: claimed),
            .dropUnfilterableEncryptedDNS(byteCount: fragmented.count))
        XCTAssertTrue(
            fragments.contains(
                ChainedFragmentIdentity(
                    source: 0x0AFF0002, destination: 0x09090909,
                    identification: 0, protocolNumber: UInt8(IPPROTO_UDP))),
            "the claimed head's identity must be remembered so its tails drop")
    }

    /// The F4 rule, IPv6: a claimed DoQ destination is attributed as unfilterable rather than the
    /// blanket outbound-v6 drop; an unclaimed one keeps the existing drop.
    func testDoqToAClaimedIPv6ResolverDestinationIsDropped() {
        let claimed = ChainedClaimedResolverDestinations(
            resolverAddresses: ["2606:4700:4700::1111"])
        // 2606:4700:4700::1111
        let v6 = Self.ipv6UDPPacket(
            destinationPort: 853, payload: [1, 2, 3, 4],
            destination: [
                0x26, 0x06, 0x47, 0x00, 0x47, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11, 0x11,
            ])
        XCTAssertEqual(
            Self.classifyClaiming(v6, claimed), .dropUnfilterableEncryptedDNS(byteCount: v6.count))

        // An UNCLAIMED v6 :853 keeps the existing blanket outbound-v6 drop.
        let unclaimed = Self.ipv6UDPPacket(destinationPort: 853, payload: [1, 2, 3, 4])
        XCTAssertEqual(
            Self.classifyClaiming(unclaimed, claimed),
            .dropOutboundIPv6(byteCount: unclaimed.count))

        // A damaged length on the claimed destination is attributed the same way, not the
        // blanket drop, so the encrypted flow is named in the counters.
        var damaged = v6
        damaged[4] = 0xFF
        damaged[5] = 0xFF
        XCTAssertEqual(
            Self.classifyClaiming(damaged, claimed),
            .dropUnfilterableEncryptedDNS(byteCount: damaged.count))

        for udpLength in [UInt16(7), UInt16.max] {
            var damagedUDP = v6
            damagedUDP[44] = UInt8(udpLength >> 8)
            damagedUDP[45] = UInt8(udpLength & 0xFF)
            XCTAssertEqual(
                Self.classifyClaiming(damagedUDP, claimed),
                .dropUnfilterableEncryptedDNS(byteCount: damagedUDP.count),
                "a readable claimed port keeps its attribution when the UDP length is damaged")
        }
    }

    /// F1: the curated public-resolver floor is part of the split plan's claimed routes, so a
    /// `:853` (DoT/DoQ) flow to a curated address is refused exactly as a captured device
    /// resolver's is. The provider builds this set from the curated list plus the capture, so the
    /// classifier must drop curated destinations without any special case.
    func testDotToACuratedPublicResolverDestinationIsDroppedInSplit() {
        let claimed = ChainedClaimedResolverDestinations(
            resolverAddresses: DNSCaptureFloor.curatedPublicResolverAddresses)
        XCTAssertFalse(claimed.isEmpty)

        let dot = Self.tcpPacket(destination: [1, 1, 1, 1], destinationPort: 853)
        XCTAssertEqual(
            Self.classifyClaiming(dot, claimed), .dropUnfilterableEncryptedDNS(byteCount: dot.count))

        let doq = Self.udpPacket(
            destination: [8, 8, 8, 8], destinationPort: 853, payload: [1, 2, 3, 4])
        XCTAssertEqual(
            Self.classifyClaiming(doq, claimed), .dropUnfilterableEncryptedDNS(byteCount: doq.count))

        // Ordinary HTTPS to a curated resolver is not encrypted DNS and stays ordinary.
        let https = Self.tcpPacket(destination: [1, 1, 1, 1], destinationPort: 443)
        XCTAssertEqual(
            Self.classifyClaiming(https, claimed), .encapsulate(byteCount: https.count))

        // A destination OUTSIDE the curated set keeps the split rung's ordinary behaviour.
        let unclaimed = Self.tcpPacket(destination: [203, 0, 113, 9], destinationPort: 853)
        XCTAssertEqual(
            Self.classifyClaiming(unclaimed, claimed), .encapsulate(byteCount: unclaimed.count))
    }

    /// The claimed set is normalized once, so equivalent spellings and family separation hold.
    func testClaimedResolverDestinationsNormalizeEquivalentSpellings() {
        // Compressed and expanded spellings of one address resolve to the same set entry.
        let v6 = ChainedClaimedResolverDestinations(
            resolverAddresses: ["2606:4700:4700:0:0:0:0:1111"])
        XCTAssertTrue(v6.containsIPv6Destination(0x26064700, 0x47000000, 0x00000000, 0x00001111))
        XCTAssertFalse(v6.containsIPv6Destination(0x26064700, 0x47000000, 0x00000000, 0x00001112))

        let v4 = ChainedClaimedResolverDestinations(resolverAddresses: ["9.9.9.9"])
        XCTAssertTrue(v4.containsIPv4Destination(0x09090909))
        XCTAssertFalse(v4.containsIPv4Destination(0x08080808))

        // The tunnel's own listeners are never claims, matching the floor's exclusions.
        let listeners = ChainedClaimedResolverDestinations(
            resolverAddresses: [
                TunnelRoutePlan.dnsServerAddress,
                TunnelRoutePlan.chainedDNSServerIPv6Address,
            ])
        XCTAssertTrue(listeners.isEmpty)
        XCTAssertTrue(ChainedClaimedResolverDestinations.empty.isEmpty)
    }

    /// The claimed set applies the on-link-gateway exclusion ITSELF, so a caller handing in the
    /// raw resolver capture (the provider does) cannot make the `:853` drop disagree with the
    /// routes F3b installed: the route plan runs the same membership filter, so a gateway-class
    /// address is never claimed and its `:853` stays the split rung's ordinary traffic.
    func testClaimedResolverDestinationsExcludeTheOnLinkGatewayClass() {
        let claimed = ChainedClaimedResolverDestinations(
            resolverAddresses: ["192.168.1.53", "10.0.0.1", "8.8.8.8", "2606:4700:4700::1111"])

        XCTAssertTrue(claimed.containsIPv4Destination(0x08080808), "a public resolver is claimed")
        XCTAssertTrue(
            claimed.containsIPv6Destination(0x26064700, 0x47000000, 0x00000000, 0x00001111),
            "a public v6 resolver is claimed")
        XCTAssertFalse(
            claimed.containsIPv4Destination(0xC0A80135),
            "a private resolver in the on-link-gateway class must not be claimed")
        XCTAssertFalse(
            claimed.containsIPv4Destination(0x0A000001),
            "the LAN gateway itself must not be claimed")

        // The drop agrees with the routes: a `:853` flow to the excluded gateway is untouched.
        let gatewayDoT = Self.tcpPacket(destination: [192, 168, 1, 53], destinationPort: 853)
        XCTAssertEqual(
            Self.classifyClaiming(gatewayDoT, claimed),
            .encapsulate(byteCount: gatewayDoT.count))
    }

    func testAFragmentedDNSQueryIsDroppedNotEncapsulated() {
        // The bypass the fragment rule opened: a UDP/53 query with more-fragments set was
        // encapsulated before its port was ever inspected, so the peer could reassemble and
        // read a hardcoded-resolver query.
        var fragmented = Self.udpPacket(destination: [8, 8, 8, 8], destinationPort: 53, payload: [1, 2, 3, 4])
        fragmented[6] = 0x20  // more-fragments, offset 0 — the head, which carries the UDP header
        XCTAssertEqual(Self.classify(fragmented), .dropUnfilterableDNS(byteCount: fragmented.count))

        // Also in the shape a host really emits, where the UDP length describes the whole
        // reassembled datagram. Keeping both spellings is the point: the self-consistent one
        // above is what the corpus had, and it passed while real fragment heads were dropped.
        let realistic = Self.udpFragmentHead(
            destination: [8, 8, 8, 8], destinationPort: 53, reassembledPayloadByteCount: 2992)
        XCTAssertEqual(Self.classify(realistic), .dropUnfilterableDNS(byteCount: realistic.count))

        // A non-first fragment carries no transport header and cannot be identified. It stays
        // encapsulated, which is safe only because the head above is dropped: without fragment
        // zero the peer has no UDP header and cannot reassemble or classify what it holds.
        var tail = Self.udpPacket(destination: [8, 8, 8, 8], destinationPort: 53, payload: [1, 2, 3, 4])
        tail[6] = 0x00
        tail[7] = 0x10
        XCTAssertEqual(Self.classify(tail), .encapsulate(byteCount: tail.count))
    }

    func testTheTailsOfADroppedDNSHeadAreDroppedToo() {
        // Dropping fragment zero stops the query WORKING and does not stop it being READ. The
        // tails carry the DNS message's own bytes, so an observer concatenates the QNAME with no
        // transport header and no reassembly — and a legal head may carry only the UDP header,
        // putting the whole question in the parts that were forwarded.
        var fragments = ChainedDroppedFragmentTable()

        let head = Self.identified(
            Self.udpFragmentHead(
                destination: [8, 8, 8, 8], destinationPort: 53, reassembledPayloadByteCount: 2992),
            0x4242)
        XCTAssertEqual(
            Self.classify(head, fragments: &fragments), .dropUnfilterableDNS(byteCount: head.count))

        let ownTail = Self.tail(of: head)
        XCTAssertEqual(
            Self.classify(ownTail, fragments: &fragments),
            .dropUnfilterableDNS(byteCount: ownTail.count),
            "a tail of a dropped DNS head was forwarded with its query bytes")

        // ANTI-VACUITY: an unrelated datagram's tail must still be forwarded, or this rule has
        // become "drop all fragments", which is the blackhole the head fix exists to avoid.
        let strangerTail = Self.tail(of: Self.identified(
            Self.udpFragmentHead(
                destination: [93, 184, 216, 34], destinationPort: 443,
                reassembledPayloadByteCount: 2992),
            0x9999))
        XCTAssertEqual(
            Self.classify(strangerTail, fragments: &fragments),
            .encapsulate(byteCount: strangerTail.count),
            "an unrelated fragmented flow lost its tails")

        // TCP/53 leaks through its tails identically, so its head is remembered too.
        var tcpFragments = ChainedDroppedFragmentTable()
        var tcpHead = Self.identified(Self.tcpPacket(destination: [8, 8, 8, 8], destinationPort: 53), 0x1234)
        tcpHead[6] = 0x20
        XCTAssertEqual(
            Self.classify(tcpHead, fragments: &tcpFragments),
            .dropUnfilterableDNS(byteCount: tcpHead.count))
        let tcpTail = Self.tail(of: tcpHead)
        XCTAssertEqual(
            Self.classify(tcpTail, fragments: &tcpFragments),
            .dropUnfilterableDNS(byteCount: tcpTail.count),
            "a tail of a dropped TCP/53 head was forwarded")
    }

    func testAShortFinalFragmentOfADroppedTrainIsStillDropped() {
        // Only NON-FINAL fragments must carry an eight-byte-aligned payload, so a datagram's
        // LAST continuation is legally short — and it was reaching the length guard, which
        // encapsulated it and read its payload bytes as though they were a destination port.
        // The last bytes of a dropped DNS query going to the peer, through the guard that was
        // meant to be the conservative one.
        var fragments = ChainedDroppedFragmentTable()
        let head = Self.identified(
            Self.udpFragmentHead(
                destination: [8, 8, 8, 8], destinationPort: 53, reassembledPayloadByteCount: 2992),
            0x7070)
        XCTAssertEqual(
            Self.classify(head, fragments: &fragments), .dropUnfilterableDNS(byteCount: head.count))

        // 24 bytes: an IPv4 header plus four payload bytes. Shorter than a UDP header, which is
        // what the old guard required before it would look at anything.
        var shortTail = Array(head[0..<24])
        shortTail[2] = 0
        shortTail[3] = 24
        shortTail[6] = 0x00
        shortTail[7] = 0x10  // a continuation, and the LAST one
        // DNS message bytes, deliberately NOT anything that reads as port 53. The first version
        // of this test copied the head's UDP header, so bytes 22-23 still held 53 — and the
        // length path's "read a port there" answered `.dropUnfilterableDNS` by coincidence,
        // making the test pass against the very ordering bug it was written for.
        shortTail[20] = 0xAB
        shortTail[21] = 0xCD
        shortTail[22] = 0xEF
        shortTail[23] = 0x01
        XCTAssertLessThan(shortTail.count, 20 + 8, "the builder must model a sub-UDP-header tail")
        XCTAssertEqual(
            Self.classify(shortTail, fragments: &fragments),
            .dropUnfilterableDNS(byteCount: shortTail.count),
            "a short final fragment of a dropped DNS train was forwarded")
    }

    func testAnOutOfOrderTailIsStillDroppedAfterTheFinalOne() {
        // The previous round released the identity when a more-fragments-CLEAR continuation
        // arrived, on the reasoning that it ends the train. It does not: MF-clear identifies the
        // HIGHEST-OFFSET fragment, not the last one observed. Fragments can arrive out of order,
        // a retransmission can follow, and the key deliberately conflates identification
        // collisions — so releasing on it let a later middle fragment miss the table and carry
        // its query bytes to the peer. One leak traded for another.
        var fragments = ChainedDroppedFragmentTable()
        let head = Self.identified(
            Self.udpFragmentHead(
                destination: [8, 8, 8, 8], destinationPort: 53, reassembledPayloadByteCount: 2992),
            0x3131)
        XCTAssertEqual(
            Self.classify(head, fragments: &fragments), .dropUnfilterableDNS(byteCount: head.count))

        // The highest-offset fragment arrives FIRST, which reordering makes ordinary.
        let final = Self.tail(of: head)  // offset set, more-fragments clear
        XCTAssertEqual(
            Self.classify(final, fragments: &fragments),
            .dropUnfilterableDNS(byteCount: final.count))

        // ...and a middle fragment of the same datagram arrives after it.
        var middle = Self.tail(of: head)
        middle[6] = 0x20  // more still to come
        middle[7] = 0x08
        XCTAssertEqual(
            Self.classify(middle, fragments: &fragments),
            .dropUnfilterableDNS(byteCount: middle.count),
            "a tail arriving after the final fragment was forwarded with its query bytes")
    }

    func testADamagedFragmentHeadStillSilencesItsTails() {
        // The narrow shape the length fix opened: a port-53 first fragment whose total length is
        // damaged is dropped by the length path, which did not record its identity — so its
        // well-formed tails missed the deny-list and were forwarded. That is the case this
        // branch exists to fail closed on, failing closed for the head alone.
        for protocolNumber in [UInt8(IPPROTO_UDP), UInt8(IPPROTO_TCP)] {
            var fragments = ChainedDroppedFragmentTable()
            var head = protocolNumber == UInt8(IPPROTO_UDP)
                ? Self.udpPacket(destination: [8, 8, 8, 8], destinationPort: 53, payload: [1, 2, 3, 4])
                : Self.tcpPacket(destination: [8, 8, 8, 8], destinationPort: 53)
            head = Self.identified(head, 0x5A5A)
            head[6] = 0x20  // more fragments
            head[2] = 0xFF  // ...and a total length that does not describe it
            XCTAssertEqual(
                Self.classify(head, fragments: &fragments),
                .dropUnfilterableDNS(byteCount: head.count))

            let tail = Self.tail(of: Self.identified(head, 0x5A5A))
            XCTAssertEqual(
                Self.classify(tail, fragments: &fragments),
                .dropUnfilterableDNS(byteCount: tail.count),
                "a damaged head's tails were forwarded with their query bytes")
        }
    }

    func testAnIdentificationCollisionFailsClosed() {
        // The reassembly key cannot include ports, because a tail has none. So two datagrams to
        // the same destination sharing an identification are one identity here, and the deny-list
        // is the way round that makes the collision harmless: the permitted flow loses its tails
        // rather than the DNS query leaking. Stated as a test so the direction is not an
        // accident of implementation.
        var fragments = ChainedDroppedFragmentTable()

        let permitted = Self.identified(
            Self.udpFragmentHead(
                destination: [8, 8, 8, 8], destinationPort: 443, reassembledPayloadByteCount: 2992),
            0x0777)
        XCTAssertEqual(
            Self.classify(permitted, fragments: &fragments), .encapsulate(byteCount: permitted.count))

        let colliding = Self.identified(
            Self.udpFragmentHead(
                destination: [8, 8, 8, 8], destinationPort: 53, reassembledPayloadByteCount: 2992),
            0x0777)
        XCTAssertEqual(
            Self.classify(colliding, fragments: &fragments),
            .dropUnfilterableDNS(byteCount: colliding.count))

        // Now indistinguishable. It fails CLOSED — a rare functional blip, not a leak.
        let ambiguousTail = Self.tail(of: permitted)
        XCTAssertEqual(
            Self.classify(ambiguousTail, fragments: &fragments),
            .dropUnfilterableDNS(byteCount: ambiguousTail.count),
            "an identification collision resolved in the leaking direction")
    }

    func testAPermittedHeadReusingAnIdentificationClearsTheStaleDenial() {
        // The 16-bit identification wraps, and nothing but eviction released an entry — so a
        // permitted datagram unlucky enough to reuse a denied tuple had its head forwarded and
        // every tail dropped. Ordinary traffic never evicts (only dropped heads do), which made
        // the failure recurring: the same tuple was destroyed again on every wrap for as long
        // as the entry lived. A forwarded head is affirmative evidence the tuple now belongs to
        // a permitted datagram, and the table must not contradict the head's own disposition.
        var fragments = ChainedDroppedFragmentTable()
        let denied = Self.identified(
            Self.udpFragmentHead(
                destination: [8, 8, 8, 8], destinationPort: 53, reassembledPayloadByteCount: 2992),
            0x4242)
        XCTAssertEqual(
            Self.classify(denied, fragments: &fragments),
            .dropUnfilterableDNS(byteCount: denied.count))

        // The identification wraps; the same tuple now heads a permitted datagram...
        let permitted = Self.identified(
            Self.udpFragmentHead(
                destination: [8, 8, 8, 8], destinationPort: 443, reassembledPayloadByteCount: 2992),
            0x4242)
        XCTAssertEqual(
            Self.classify(permitted, fragments: &fragments),
            .encapsulate(byteCount: permitted.count))

        // ...whose continuations must reach the peer, or the datagram we forwarded the head of
        // can never reassemble.
        let tail = Self.tail(of: permitted)
        XCTAssertEqual(
            Self.classify(tail, fragments: &fragments), .encapsulate(byteCount: tail.count),
            "a stale denial outlived its datagram and destroyed the permitted flow that reused the tuple")
    }

    func testAHeadDoesNotReclaimWhenOlderPacketsAreStillWaiting() {
        // The reclaim reads a forwarded head as evidence about the tuple's current datagram,
        // and that is only true if everything classified before it has already left. A runner
        // under back-pressure classifies a newer arrival while an OLDER packet sits parked and
        // unclassified — so clearing the denial there means the older DNS tail is later
        // re-classified against a table that no longer denies it, and its query bytes go to the
        // peer. The caller is the only one who knows the order, so it says.
        var fragments = ChainedDroppedFragmentTable()
        let denied = Self.identified(
            Self.udpFragmentHead(
                destination: [8, 8, 8, 8], destinationPort: 53, reassembledPayloadByteCount: 2992),
            0x4747)
        XCTAssertEqual(
            Self.classify(denied, fragments: &fragments),
            .dropUnfilterableDNS(byteCount: denied.count))

        let permitted = Self.identified(
            Self.udpFragmentHead(
                destination: [8, 8, 8, 8], destinationPort: 443, reassembledPayloadByteCount: 2992),
            0x4747)
        XCTAssertEqual(
            Self.classify(permitted, fragments: &fragments, reclaimsStaleDenials: false),
            .encapsulate(byteCount: permitted.count))

        let deniedTail = Self.tail(of: denied)
        XCTAssertEqual(
            Self.classify(deniedTail, fragments: &fragments),
            .dropUnfilterableDNS(byteCount: deniedTail.count),
            "a head classified out of release order released the denial an older parked tail "
                + "was still going to be judged against")
    }

    func testADNSHeadArrivingAfterThePermittedHeadReestablishesTheDenial() {
        // Reclaiming is not a one-way door. The table always reflects the MOST RECENT head's
        // disposition for a tuple, so a DNS head arriving after the permitted one puts the
        // denial back, and the tails that follow it are dropped.
        var fragments = ChainedDroppedFragmentTable()
        let permitted = Self.identified(
            Self.udpFragmentHead(
                destination: [8, 8, 8, 8], destinationPort: 443, reassembledPayloadByteCount: 2992),
            0x4343)
        XCTAssertEqual(
            Self.classify(permitted, fragments: &fragments),
            .encapsulate(byteCount: permitted.count))

        let denied = Self.identified(
            Self.udpFragmentHead(
                destination: [8, 8, 8, 8], destinationPort: 53, reassembledPayloadByteCount: 2992),
            0x4343)
        XCTAssertEqual(
            Self.classify(denied, fragments: &fragments),
            .dropUnfilterableDNS(byteCount: denied.count))

        let tail = Self.tail(of: denied)
        XCTAssertEqual(
            Self.classify(tail, fragments: &fragments),
            .dropUnfilterableDNS(byteCount: tail.count),
            "reclaiming the tuple outlived the head that justified it")
    }

    func testAnUnfragmentedPermittedDatagramDoesNotClearTheDenial() {
        // Only a head with continuations of its own rewrites the tuple's ownership. An
        // unfragmented datagram has no tails to protect, so it is no evidence about fragments —
        // and clearing on it would release a denial whose own tails may still be in flight,
        // for nothing.
        var fragments = ChainedDroppedFragmentTable()
        let denied = Self.identified(
            Self.udpFragmentHead(
                destination: [8, 8, 8, 8], destinationPort: 53, reassembledPayloadByteCount: 2992),
            0x4444)
        XCTAssertEqual(
            Self.classify(denied, fragments: &fragments),
            .dropUnfilterableDNS(byteCount: denied.count))

        let whole = Self.identified(
            Self.udpPacket(destination: [8, 8, 8, 8], destinationPort: 443, payload: [1, 2, 3, 4]),
            0x4444)
        XCTAssertEqual(
            Self.classify(whole, fragments: &fragments), .encapsulate(byteCount: whole.count))

        let tail = Self.tail(of: denied)
        XCTAssertEqual(
            Self.classify(tail, fragments: &fragments),
            .dropUnfilterableDNS(byteCount: tail.count),
            "a datagram with no continuations released a denial that still had some in flight")
    }

    func testAForwardedHeadTooShortToReadAPortStillReclaimsItsTuple() {
        // The reclaim rule is about what the classifier DID, not about what it could read: this
        // head was forwarded, so its continuations must not be dropped by a stale entry — the
        // alternative is a flow whose head the peer holds and whose body never arrives. The
        // port being unreadable does not change the contradiction.
        var fragments = ChainedDroppedFragmentTable()
        var denied = Self.identified(Self.tcpPacket(destination: [8, 8, 8, 8], destinationPort: 53), 0x4545)
        denied[6] = 0x20  // more fragments
        XCTAssertEqual(
            Self.classify(denied, fragments: &fragments),
            .dropUnfilterableDNS(byteCount: denied.count))

        // A 22-byte first fragment: IPv4 header plus two bytes, too short for a port read.
        var short = Self.identified(
            Self.ipv4Packet(protocolNumber: UInt8(IPPROTO_TCP), payload: [0xC0, 0x00]), 0x4545)
        short[6] = 0x20
        short[16...19] = [8, 8, 8, 8]
        XCTAssertEqual(
            Self.classify(short, fragments: &fragments), .encapsulate(byteCount: short.count))

        let tail = Self.tail(of: short)
        XCTAssertEqual(
            Self.classify(tail, fragments: &fragments), .encapsulate(byteCount: tail.count),
            "a forwarded head's tails were dropped because its port could not be read")
    }

    func testADamagedLengthPermittedHeadReclaimsItsTuple() {
        // The damaged-length path forwards a non-53 head too, and the same rule follows it
        // there: forwarded head, forwardable tails.
        var fragments = ChainedDroppedFragmentTable()
        let denied = Self.identified(
            Self.udpFragmentHead(
                destination: [8, 8, 8, 8], destinationPort: 53, reassembledPayloadByteCount: 2992),
            0x4646)
        XCTAssertEqual(
            Self.classify(denied, fragments: &fragments),
            .dropUnfilterableDNS(byteCount: denied.count))

        var damaged = Self.identified(
            Self.udpPacket(destination: [8, 8, 8, 8], destinationPort: 443, payload: [1, 2, 3, 4]),
            0x4646)
        damaged[6] = 0x20  // more fragments
        damaged[2] = 0xFF  // ...and a total length that does not describe it
        XCTAssertEqual(
            Self.classify(damaged, fragments: &fragments), .encapsulate(byteCount: damaged.count))

        let tail = Self.tail(of: damaged)
        XCTAssertEqual(
            Self.classify(tail, fragments: &fragments), .encapsulate(byteCount: tail.count),
            "the damaged-length path forwards heads but abandoned their tails to a stale entry")
    }

    func testADamagedLengthFieldDoesNotForwardADNSQuery() {
        // A total-length field that does not describe the packet used to fall through to
        // "encapsulate anything with a plausible IPv4 header" — so a UDP/53 datagram with a
        // nonsense length went to the peer with its query intact. `IPv4UDPDNSPacket` rejects
        // those shapes too, so the query was neither filtered nor answered: only observed.
        for protocolNumber in [UInt8(IPPROTO_UDP), UInt8(IPPROTO_TCP)] {
            let base = protocolNumber == UInt8(IPPROTO_UDP)
                ? Self.udpPacket(destination: [8, 8, 8, 8], destinationPort: 53, payload: [1, 2, 3, 4])
                : Self.tcpPacket(destination: [8, 8, 8, 8], destinationPort: 53)

            var shortTotal = base
            shortTotal[2] = 0
            shortTotal[3] = 20  // shorter than the headers it claims to cover
            XCTAssertEqual(
                Self.classify(shortTotal), .dropUnfilterableDNS(byteCount: shortTotal.count),
                "a short total-length forwarded a DNS query")

            var longTotal = base
            longTotal[2] = 0xFF  // past the end of the buffer
            XCTAssertEqual(
                Self.classify(longTotal), .dropUnfilterableDNS(byteCount: longTotal.count),
                "an overlong total-length forwarded a DNS query")
        }

        // ANTI-VACUITY: the same damage on a non-DNS port is still ordinary traffic. Without
        // this, "drop everything with a bad length" would pass, and that is the blackhole.
        var damagedHTTPS = Self.udpPacket(destination: [93, 184, 216, 34], destinationPort: 443, payload: [1, 2])
        damagedHTTPS[2] = 0xFF
        XCTAssertEqual(Self.classify(damagedHTTPS), .encapsulate(byteCount: damagedHTTPS.count))
    }

    func testANonDNSFragmentHeadIsEncapsulatedRatherThanReadAsMalformed() {
        // The blackhole the first corpus could not see. Every "fragment" it built kept a
        // self-consistent UDP length, so the overrun guard never fired on one. A REAL head
        // carries the reassembled datagram's length, which always overruns the fragment — so
        // the guard called every legal fragment head malformed and dropped it, one line before
        // the port that would have identified it was read.
        //
        // The tail was encapsulated regardless, so the peer received continuations of a
        // datagram whose head it never got: nothing reassembles, and every fragmented UDP flow
        // dies. NFS, some VPN-in-VPN, and large DNS-over-UDP answers all live here.
        let head = Self.udpFragmentHead(
            destination: [93, 184, 216, 34], destinationPort: 443, reassembledPayloadByteCount: 2992)
        XCTAssertGreaterThan(
            8 + 2992, head.count - 20, "the builder must model a length that overruns the fragment")
        XCTAssertEqual(Self.classify(head), .encapsulate(byteCount: head.count))

        // The same shape addressed to 53 still fails closed. This is the pair that matters:
        // accepting fragment heads must not become "forward fragment heads".
        let dnsHead = Self.udpFragmentHead(
            destination: [8, 8, 8, 8], destinationPort: 53, reassembledPayloadByteCount: 2992)
        XCTAssertEqual(Self.classify(dnsHead), .dropUnfilterableDNS(byteCount: dnsHead.count))

        // And an UNFRAGMENTED overrun is still malformed — the guard moved, it did not go away.
        var overrun = Self.udpPacket(
            destination: [93, 184, 216, 34], destinationPort: 443, payload: [1, 2, 3, 4])
        overrun[24] = 0xFF
        overrun[25] = 0xFF
        XCTAssertEqual(Self.classify(overrun), .dropMalformed)
    }

    func testAFragmentedDatagramIsEncapsulatedRatherThanDropped() {
        // The DNS parser refuses fragments because it cannot reassemble a query. Copying that
        // refusal here would reintroduce the blackhole one level down, for every fragmented
        // flow.
        var packet = Self.udpPacket(destination: [93, 184, 216, 34], destinationPort: 443, payload: [1, 2, 3, 4])
        packet[6] = 0x20  // more-fragments, non-DNS
        XCTAssertEqual(Self.classify(packet), .encapsulate(byteCount: packet.count))

        var offsetFragment = Self.udpPacket(destination: [93, 184, 216, 34], destinationPort: 443, payload: [1, 2, 3, 4])
        offsetFragment[6] = 0x00
        offsetFragment[7] = 0x10  // non-zero fragment offset
        XCTAssertEqual(Self.classify(offsetFragment), .encapsulate(byteCount: offsetFragment.count))
    }

    // MARK: - IPv6

    func testIPv6PacketsAreDroppedUnlessTheyAreADNSQuery() {
        // The peer's AllowedIPs carry no IPv6 — the configuration boundary requires only the
        // IPv4 default route — so a v6 packet that is not a DNS query for the in-tunnel resolver
        // is dropped: encapsulating would spend an encryption and a round trip to be discarded at
        // the far end, unaccounted.
        var nonUDP = [UInt8](repeating: 0, count: 48)
        nonUDP[0] = 0x60
        XCTAssertEqual(Self.classify(nonUDP), .dropOutboundIPv6(byteCount: 48))

        // A plain v6/UDP datagram to port 53 is served by the in-tunnel resolver, exactly as its
        // IPv4 counterpart is (F3c).
        var v6DNS = [UInt8](repeating: 0, count: 48)
        v6DNS[0] = 0x60
        v6DNS[5] = 8        // payload length 8 (empty UDP datagram)
        v6DNS[6] = 17       // next header: UDP
        v6DNS[7] = 64
        v6DNS[40] = 0x30; v6DNS[41] = 0x39  // source port 12345
        v6DNS[42] = 0; v6DNS[43] = 53       // destination port 53
        v6DNS[44] = 0; v6DNS[45] = 8        // UDP length 8
        XCTAssertEqual(
            Self.classify(v6DNS), .dropUnfilterableDNS(byteCount: 48),
            "an empty UDP/53 datagram fails closed, matching the IPv4 rule")

        var v6DNSWithPayload = v6DNS
        v6DNSWithPayload[5] = 12            // payload length 12 (8 UDP + 4 data)
        v6DNSWithPayload[44] = 0; v6DNSWithPayload[45] = 12
        v6DNSWithPayload.append(contentsOf: [1, 2, 3, 4])
        XCTAssertEqual(Self.classify(v6DNSWithPayload), .handleAsDNS(byteCount: 52))
    }


    func testEveryPacketTheIPv6DNSParserAcceptsIsHandledAsDNS() {
        // The IPv6 analogue of the differential property (F3c): a v6 packet the DNS parser
        // accepts must be classified `.handleAsDNS`, and one it refuses must NOT be — the same
        // guarantee that keeps the two families feeding one filter.
        var corpus: [[UInt8]] = []
        for port in [UInt16(53), 54, 5353, 443, 0] {
            for payload in [[UInt8](), [0xAB], [UInt8](repeating: 0x41, count: 64)] {
                corpus.append(Self.ipv6UDPPacket(destinationPort: port, payload: payload))
            }
        }
        // Extension header (44): refused by the parser, must not be served.
        var extensionHeader = Self.ipv6UDPPacket(destinationPort: 53, payload: [1, 2, 3, 4])
        extensionHeader[6] = 44
        corpus.append(extensionHeader)
        // Payload length below the UDP header, and past the end of the buffer.
        var shortPayload = Self.ipv6UDPPacket(destinationPort: 53, payload: [1, 2, 3, 4])
        shortPayload[4] = 0; shortPayload[5] = 4
        corpus.append(shortPayload)
        var longPayload = Self.ipv6UDPPacket(destinationPort: 53, payload: [1, 2, 3, 4])
        longPayload[4] = 0xFF; longPayload[5] = 0xFF
        corpus.append(longPayload)
        // UDP length below its own header, and past the declared payload length.
        var shortUDP = Self.ipv6UDPPacket(destinationPort: 53, payload: [1, 2, 3, 4])
        shortUDP[44] = 0; shortUDP[45] = 4
        corpus.append(shortUDP)
        var longUDP = Self.ipv6UDPPacket(destinationPort: 53, payload: [1, 2, 3, 4])
        longUDP[44] = 0xFF; longUDP[45] = 0xFF
        corpus.append(longUDP)
        // Trailing padding past the declared payload length (tolerated, like IPv4).
        var padded = Self.ipv6UDPPacket(destinationPort: 53, payload: [1, 2, 3, 4])
        padded.append(contentsOf: [0, 0, 0, 0])
        corpus.append(padded)

        var agreed = 0
        for packet in corpus {
            let parsedAsDNS = IPv6UDPDNSPacket(Data(packet)) != nil
            let classifiedAsDNS: Bool
            if case .handleAsDNS = Self.classify(packet) { classifiedAsDNS = true } else { classifiedAsDNS = false }
            XCTAssertEqual(
                parsedAsDNS, classifiedAsDNS,
                "disagreement on a \(packet.count)-byte IPv6 packet — the two families must agree")
            agreed += 1
        }
        XCTAssertEqual(agreed, corpus.count)
        XCTAssertTrue(corpus.contains { IPv6UDPDNSPacket(Data($0)) != nil }, "no DNS packets in the corpus")
        XCTAssertTrue(corpus.contains { IPv6UDPDNSPacket(Data($0)) == nil }, "no non-DNS packets in the corpus")
    }

    func testALengthDamagedIPv6DatagramKeepsItsPortAttribution() {
        // The port is read BEFORE the length guards, so a damaged v6 datagram is still
        // attributed by the port it carried: port 53 fails closed as unfilterable DNS, any
        // other port drops as IPv6 rather than diluting `unfilterableDNSPacketCount`.
        var damagedToDNS = Self.ipv6UDPPacket(destinationPort: 53, payload: [1, 2, 3, 4])
        damagedToDNS[4] = 0xFF; damagedToDNS[5] = 0xFF  // payload length past the buffer
        XCTAssertEqual(Self.classify(damagedToDNS), .dropUnfilterableDNS(byteCount: damagedToDNS.count))

        var damagedToOther = Self.ipv6UDPPacket(destinationPort: 443, payload: [1, 2, 3, 4])
        damagedToOther[4] = 0xFF; damagedToOther[5] = 0xFF
        XCTAssertEqual(Self.classify(damagedToOther), .dropOutboundIPv6(byteCount: damagedToOther.count))
    }

    // MARK: - Malformed

    func testPacketsNoReaderCanActOnAreDroppedRatherThanForwarded() {
        let empty: [UInt8] = []
        var badVersion = [UInt8](repeating: 0, count: 40)
        badVersion[0] = 0x75  // version 7
        var headerPastEnd = [UInt8](repeating: 0, count: 24)
        headerPastEnd[0] = 0x4F  // IHL 15 -> 60-byte header in a 24-byte packet
        var shortIHL = [UInt8](repeating: 0, count: 40)
        shortIHL[0] = 0x44  // IHL 4 -> 16-byte header, below the 20-byte minimum

        for packet in [empty, badVersion, headerPastEnd, shortIHL] {
            XCTAssertEqual(Self.classify(packet), .dropMalformed)
        }
    }

    func testAUDPLengthPastTheEndOfItsDatagramIsDropped() {
        // "The far end will cope" is how a malformed packet becomes someone else's problem.
        var packet = Self.udpPacket(destination: [10, 255, 0, 1], destinationPort: 53, payload: [1, 2, 3, 4])
        let udpOffset = 20
        packet[udpOffset + 4] = 0xFF
        packet[udpOffset + 5] = 0xFF
        XCTAssertEqual(Self.classify(packet), .dropMalformed)
    }

    // MARK: - The property that protects DNS-only users

    func testEveryPacketTheDNSParserAcceptsIsHandledAsDNS() {
        // The differential property, and the reason this slice can land before anything is
        // wired: for every packet today's path treats as DNS, the classifier must agree. That
        // is what keeps the DNS-only path bit-identical for every user who never enables
        // chaining, which INV-DNS-1 requires.
        //
        // Asserted in BOTH directions: a packet the parser refuses must not be classified as
        // DNS either, or the chained path would divert traffic the DNS path would have
        // encapsulated.
        var corpus: [[UInt8]] = []
        for port in [UInt16(53), 54, 5353, 443, 0] {
            for payload in [[UInt8](), [0xAB], [UInt8](repeating: 0x41, count: 64)] {
                for destination in [[10, 255, 0, 1] as [UInt8], [8, 8, 8, 8], [1, 1, 1, 1]] {
                    corpus.append(Self.udpPacket(
                        destination: destination, destinationPort: port, payload: payload))
                }
            }
        }
        corpus.append(Self.ipv4Packet(protocolNumber: UInt8(IPPROTO_TCP), payload: [UInt8](repeating: 0, count: 20)))
        corpus.append(Self.ipv4Packet(protocolNumber: UInt8(IPPROTO_ICMP), payload: [8, 0, 0, 0]))

        // EVERY ACCEPTANCE BOUNDARY of the parser, not just field values on well-formed
        // packets. The earlier corpus varied ports, payloads and destinations on fixed-IHL
        // unfragmented datagrams — so deleting the classifier's fragment guard would have left
        // this test green while a fragmented UDP/53 packet became `.handleAsDNS`. A
        // differential test is only as strong as the shapes it differs over.
        for port in [UInt16(53), 443] {
            // more-fragments, and a non-zero fragment offset
            var head = Self.udpPacket(destination: [8, 8, 8, 8], destinationPort: port, payload: [1, 2, 3, 4])
            head[6] = 0x20
            corpus.append(head)
            var tail = Self.udpPacket(destination: [8, 8, 8, 8], destinationPort: port, payload: [1, 2, 3, 4])
            tail[7] = 0x10
            corpus.append(tail)
            // IP options: IHL 6 rather than 5, so the UDP header sits four bytes further in
            corpus.append(Self.udpPacketWithOptions(destinationPort: port))
            // total-length shorter than the buffer, and longer than it
            var shortTotal = Self.udpPacket(destination: [8, 8, 8, 8], destinationPort: port, payload: [1, 2, 3, 4])
            shortTotal[3] = 20
            corpus.append(shortTotal)
            var longTotal = Self.udpPacket(destination: [8, 8, 8, 8], destinationPort: port, payload: [1, 2, 3, 4])
            longTotal[2] = 0xFF
            corpus.append(longTotal)
            // UDP length below its own header, and past the end of the datagram
            var shortUDP = Self.udpPacket(destination: [8, 8, 8, 8], destinationPort: port, payload: [1, 2, 3, 4])
            shortUDP[25] = 4
            corpus.append(shortUDP)
            var longUDP = Self.udpPacket(destination: [8, 8, 8, 8], destinationPort: port, payload: [1, 2, 3, 4])
            longUDP[24] = 0xFF
            longUDP[25] = 0xFF
            corpus.append(longUDP)
            // trailing padding past the declared total length
            var padded = Self.udpPacket(destination: [8, 8, 8, 8], destinationPort: port, payload: [1, 2, 3, 4])
            padded.append(contentsOf: [0, 0, 0, 0])
            corpus.append(padded)
            // TCP on the same port
            corpus.append(Self.tcpPacket(destination: [8, 8, 8, 8], destinationPort: port))
        }

        var agreed = 0
        var failedClosed = 0
        for packet in corpus {
            let parsedAsDNS = IPv4UDPDNSPacket(Data(packet)) != nil
            let disposition = Self.classify(packet)
            let classifiedAsDNS: Bool
            if case .handleAsDNS = disposition { classifiedAsDNS = true } else { classifiedAsDNS = false }
            XCTAssertEqual(
                parsedAsDNS, classifiedAsDNS,
                "disagreement on a \(packet.count)-byte packet — the DNS-only path is not bit-identical")
            agreed += 1

            // THE SECOND HALF, and its absence hid a leak. Reducing every non-`.handleAsDNS`
            // answer to one Boolean makes `.encapsulate` and `.dropUnfilterableDNS` the same
            // result — so a port-53 datagram the parser refused could be FORWARDED and this
            // still passed. Refusing to serve a query locally and handing it to the upstream
            // operator are opposite outcomes, and only one of them is `INV-DNS-1`.
            //
            // Scoped to packets that really carry a transport header: a non-first fragment has
            // no port, and the bytes that would be one are payload.
            guard Self.carriesTransportHeader(packet), Self.destinationPort(of: packet) == 53 else { continue }
            failedClosed += 1
            if case .encapsulate = disposition {
                XCTFail("a port-53 packet the DNS parser refused was forwarded to the peer")
            }
        }
        XCTAssertGreaterThan(
            failedClosed, 0, "the corpus contains no port-53 packet — the fail-closed half is vacuous")
        XCTAssertEqual(agreed, corpus.count)
        // The corpus must actually contain both answers, or the assertion above is vacuous.
        XCTAssertTrue(corpus.contains { IPv4UDPDNSPacket(Data($0)) != nil }, "no DNS packets in the corpus")
        XCTAssertTrue(corpus.contains { IPv4UDPDNSPacket(Data($0)) == nil }, "no non-DNS packets in the corpus")
    }

    // MARK: - Support

    /// A well-formed IPv4/TCP segment.
    /// Same as ``tcpPacket(destination:destinationPort:)`` with the SOURCE port controllable —
    /// the field the carve-out is keyed on.
    private static func tcpPacket(
        destination: [UInt8], destinationPort: UInt16, sourcePort: UInt16
    ) -> [UInt8] {
        var packet = tcpPacket(destination: destination, destinationPort: destinationPort)
        packet[20] = UInt8((sourcePort >> 8) & 0xFF)
        packet[21] = UInt8(sourcePort & 0xFF)
        return packet
    }

    private static func tcpPacket(destination: [UInt8], destinationPort: UInt16) -> [UInt8] {
        var packet = ipv4Packet(
            protocolNumber: UInt8(IPPROTO_TCP), payload: [UInt8](repeating: 0, count: 20))
        packet[16...19] = ArraySlice(destination)
        packet[20] = 0xC0
        packet[21] = 0x00
        packet[22] = UInt8((destinationPort >> 8) & 0xFF)
        packet[23] = UInt8(destinationPort & 0xFF)
        return packet
    }

    /// An IPv4/UDP datagram whose header carries four bytes of options (IHL 6).
    private static func udpPacketWithOptions(destinationPort: UInt16) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 24 + 8 + 4)
        packet[0] = 0x46
        let total = packet.count
        packet[2] = UInt8((total >> 8) & 0xFF)
        packet[3] = UInt8(total & 0xFF)
        packet[9] = UInt8(IPPROTO_UDP)
        packet[12...15] = [10, 255, 0, 2]
        packet[16...19] = [8, 8, 8, 8]
        let udp = 24
        packet[udp] = 0xC0
        packet[udp + 2] = UInt8((destinationPort >> 8) & 0xFF)
        packet[udp + 3] = UInt8(destinationPort & 0xFF)
        packet[udp + 4] = 0
        packet[udp + 5] = 12
        return packet
    }

    /// A well-formed IPv6/UDP datagram from `fd00:1a7a::2` to `fd00:1a7a::1`, carrying
    /// `payload`. The payload-length and UDP-length fields are kept self-consistent; callers
    /// damage one deliberately to probe a guard.
    private static func ipv6UDPPacket(
        destinationPort: UInt16,
        payload: [UInt8],
        sourcePort: UInt16 = 49_152,
        destination: [UInt8]? = nil
    ) -> [UInt8] {
        let udpLength = 8 + payload.count
        var packet = [UInt8](repeating: 0, count: 48 + payload.count)
        packet[0] = 0x60
        packet[4] = UInt8((udpLength >> 8) & 0xFF)
        packet[5] = UInt8(udpLength & 0xFF)
        packet[6] = UInt8(IPPROTO_UDP)
        packet[7] = 64
        // source fd00:1a7a::2
        packet[8] = 0xFD; packet[9] = 0x00; packet[10] = 0x1A; packet[11] = 0x7A; packet[23] = 0x02
        if let destination {
            packet[24...39] = ArraySlice(destination)
        } else {
            // destination fd00:1a7a::1
            packet[24] = 0xFD; packet[25] = 0x00; packet[26] = 0x1A; packet[27] = 0x7A; packet[39] = 0x01
        }
        packet[40] = UInt8((sourcePort >> 8) & 0xFF)
        packet[41] = UInt8(sourcePort & 0xFF)
        packet[42] = UInt8((destinationPort >> 8) & 0xFF)
        packet[43] = UInt8(destinationPort & 0xFF)
        packet[44] = UInt8((udpLength >> 8) & 0xFF)
        packet[45] = UInt8(udpLength & 0xFF)
        if !payload.isEmpty { packet[48...] = ArraySlice(payload) }
        return packet
    }

    /// Classifies against a FRESH table, so a test that does not care about fragment history
    /// cannot be affected by one that does.
    private static func classify(_ packet: [UInt8]) -> ChainedOutboundDisposition {
        var fragments = ChainedDroppedFragmentTable()
        return classify(packet, fragments: &fragments)
    }

    /// An empty registry, so every assertion written before the carve-out existed keeps its
    /// exact meaning: nothing is claimed, so nothing is carved out.
    static func emptyPortRegistry() -> ChainedResolverPortRegistry {
        ChainedResolverPortRegistry(uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds })
    }

    private static func classify(
        _ packet: [UInt8],
        fragments: inout ChainedDroppedFragmentTable,
        ownResolverPorts: ChainedResolverPortRegistry = emptyPortRegistry(),
        claimedResolverDestinations: ChainedClaimedResolverDestinations = .empty,
        dropsUnfilterableEncryptedDNS: Bool = false,
        reclaimsStaleDenials: Bool = true
    ) -> ChainedOutboundDisposition {
        packet.withUnsafeBytes {
            ChainedOutboundPacketClassifier.disposition(
                for: $0, fragments: &fragments, ownResolverPorts: ownResolverPorts,
                claimedResolverDestinations: claimedResolverDestinations,
                dropsUnfilterableEncryptedDNS: dropsUnfilterableEncryptedDNS,
                reclaimsStaleDenials: reclaimsStaleDenials)
        }
    }

    /// Classifies against a fresh table with the full-tunnel 853 drop enabled.
    private static func classifyDroppingEncryptedDNS(_ packet: [UInt8]) -> ChainedOutboundDisposition {
        var fragments = ChainedDroppedFragmentTable()
        return classify(packet, fragments: &fragments, dropsUnfilterableEncryptedDNS: true)
    }

    /// Classifies against a fresh table with a claimed-resolver-destination set (F4, split).
    private static func classifyClaiming(
        _ packet: [UInt8], _ claimed: ChainedClaimedResolverDestinations
    ) -> ChainedOutboundDisposition {
        var fragments = ChainedDroppedFragmentTable()
        return classify(packet, fragments: &fragments, claimedResolverDestinations: claimed)
    }

    /// Whether this packet has a transport header of its own to read a port from: IPv4, first
    /// fragment, a port-bearing protocol, and four bytes present past the IPv4 header.
    private static func carriesTransportHeader(_ packet: [UInt8]) -> Bool {
        guard packet.count >= 20, packet[0] >> 4 == 4 else { return false }
        let headerLength = Int(packet[0] & 0x0F) * 4
        guard headerLength >= 20, packet.count >= headerLength + 4 else { return false }
        let fragmentOffset = (UInt16(packet[6]) << 8 | UInt16(packet[7])) & 0x1FFF
        guard fragmentOffset == 0 else { return false }
        return packet[9] == UInt8(IPPROTO_UDP) || packet[9] == UInt8(IPPROTO_TCP)
    }

    /// The destination port, for a packet ``carriesTransportHeader(_:)`` accepted.
    private static func destinationPort(of packet: [UInt8]) -> UInt16 {
        let headerLength = Int(packet[0] & 0x0F) * 4
        return UInt16(packet[headerLength + 2]) << 8 | UInt16(packet[headerLength + 3])
    }

    /// Stamps the IPv4 identification field, which is what ties a head to its tails.
    private static func identified(_ packet: [UInt8], _ identification: UInt16) -> [UInt8] {
        var copy = packet
        copy[4] = UInt8((identification >> 8) & 0xFF)
        copy[5] = UInt8(identification & 0xFF)
        return copy
    }

    /// A continuation fragment: non-zero offset, so no transport header of its own.
    private static func tail(of packet: [UInt8]) -> [UInt8] {
        var copy = packet
        copy[6] = 0x00
        copy[7] = 0x10  // fragment offset 128 bytes in
        return copy
    }

    /// A well-formed IPv4 packet carrying `payload` as protocol `protocolNumber`.
    private static func ipv4Packet(protocolNumber: UInt8, payload: [UInt8]) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 20 + payload.count)
        packet[0] = 0x45
        let total = packet.count
        packet[2] = UInt8((total >> 8) & 0xFF)
        packet[3] = UInt8(total & 0xFF)
        packet[9] = protocolNumber
        packet[12...15] = [10, 255, 0, 2]
        packet[16...19] = [10, 255, 0, 1]
        if !payload.isEmpty { packet[20...] = ArraySlice(payload) }
        return packet
    }

    /// The FIRST fragment of a UDP datagram larger than the link MTU, shaped the way the stack
    /// actually emits one.
    ///
    /// The distinction this builder exists for, and the reason the first corpus missed a
    /// blackhole: a real fragment head's UDP length field describes the REASSEMBLED datagram,
    /// not the bytes in this packet. It therefore always overruns the fragment's own IPv4 total
    /// length. Tests that set the more-fragments bit on an otherwise self-consistent datagram
    /// exercise a packet no host ever sends, and every length check passes on it.
    private static func udpFragmentHead(
        destination: [UInt8],
        destinationPort: UInt16,
        reassembledPayloadByteCount: Int
    ) -> [UInt8] {
        // This fragment carries a 1480-byte slice of the payload; the datagram continues.
        var packet = udpPacket(
            destination: destination,
            destinationPort: destinationPort,
            payload: [UInt8](repeating: 0xAB, count: 1480 - 8))
        let udpLength = 8 + reassembledPayloadByteCount
        packet[24] = UInt8((udpLength >> 8) & 0xFF)
        packet[25] = UInt8(udpLength & 0xFF)
        packet[6] = 0x20  // more-fragments, offset 0
        packet[7] = 0x00
        return packet
    }

    /// A well-formed IPv4/UDP datagram.
    private static func udpPacket(
        destination: [UInt8],
        destinationPort: UInt16,
        payload: [UInt8]
    ) -> [UInt8] {
        var packet = ipv4Packet(
            protocolNumber: UInt8(IPPROTO_UDP), payload: [UInt8](repeating: 0, count: 8 + payload.count))
        packet[16...19] = ArraySlice(destination)
        let udp = 20
        packet[udp] = 0xC0      // source port 49152
        packet[udp + 1] = 0x00
        packet[udp + 2] = UInt8((destinationPort >> 8) & 0xFF)
        packet[udp + 3] = UInt8(destinationPort & 0xFF)
        let udpLength = 8 + payload.count
        packet[udp + 4] = UInt8((udpLength >> 8) & 0xFF)
        packet[udp + 5] = UInt8(udpLength & 0xFF)
        if !payload.isEmpty { packet[(udp + 8)...] = ArraySlice(payload) }
        return packet
    }

    private static func udpPacket(
        destination: [UInt8],
        destinationPort: UInt16,
        payload: [UInt8],
        sourcePort: UInt16
    ) -> [UInt8] {
        var packet = udpPacket(
            destination: destination, destinationPort: destinationPort, payload: payload)
        packet[20] = UInt8((sourcePort >> 8) & 0xFF)
        packet[21] = UInt8(sourcePort & 0xFF)
        return packet
    }
    // MARK: - The carve-out for our own resolver flow (S8.7c)

    /// The carve-out is EXACTLY the claim — not a superset, not a subset.
    ///
    /// A full source-port sweep with one port claimed. Hand-picked negatives can only show the
    /// cases someone thought of; this shows the predicate itself, in microseconds, and it is the
    /// test that fails if the carve-out is ever widened by an off-by-one, a `>=`, or a read at
    /// the wrong header offset.
    func testTheCarveOutIsExactlyTheClaimAndNothingElse() {
        let registry = Self.emptyPortRegistry()
        let claimed: UInt16 = 51_000
        XCTAssertNotNil(registry.claim(sourcePort: claimed, protocolNumber: UInt8(IPPROTO_TCP)))

        for candidate in UInt16.min...UInt16.max {
            var fragments = ChainedDroppedFragmentTable()
            let packet = Self.tcpPacket(
                destination: [8, 8, 8, 8], destinationPort: 53, sourcePort: candidate)
            let verdict = Self.classify(packet, fragments: &fragments, ownResolverPorts: registry)
            let expected: ChainedOutboundDisposition = candidate == claimed
                ? .encapsulateOwnResolverQuery(byteCount: packet.count)
                : .dropUnfilterableDNS(byteCount: packet.count)
            if verdict != expected {
                XCTFail("source port \(candidate): expected \(expected), got \(verdict)")
                return
            }
        }
    }

    /// A claimed port carves out its own TCP/53 and NOTHING else it might be confused with.
    func testAClaimedPortCarvesOutNothingElse() {
        let registry = Self.emptyPortRegistry()
        let claimed: UInt16 = 51_000
        XCTAssertNotNil(registry.claim(sourcePort: claimed, protocolNumber: UInt8(IPPROTO_TCP)))

        // DESTINATION-BLIND, asserted in the safe direction. The mirror of
        // testADNSQueryToAPublicResolverIsStillIntercepted: a future edit narrowing the carve-out
        // to "only the upstream resolver" reopens the hardcoded-resolver leak, and fails here.
        var toPublic = ChainedDroppedFragmentTable()
        var toTunnel = ChainedDroppedFragmentTable()
        let publicVerdict = Self.classify(
            Self.tcpPacket(destination: [8, 8, 8, 8], destinationPort: 53, sourcePort: claimed),
            fragments: &toPublic, ownResolverPorts: registry)
        let tunnelVerdict = Self.classify(
            Self.tcpPacket(destination: [10, 255, 0, 1], destinationPort: 53, sourcePort: claimed),
            fragments: &toTunnel, ownResolverPorts: registry)
        XCTAssertEqual(
            publicVerdict, tunnelVerdict,
            "the carve-out must not consult the destination; keying on it would hand every "
                + "hardcoded-resolver query to the upstream operator unfiltered")

        // A different destination PORT is ordinary traffic, not a carve-out.
        var https = ChainedDroppedFragmentTable()
        let httpsPacket = Self.tcpPacket(
            destination: [8, 8, 8, 8], destinationPort: 443, sourcePort: claimed)
        XCTAssertEqual(
            Self.classify(httpsPacket, fragments: &https, ownResolverPorts: registry),
            .encapsulate(byteCount: httpsPacket.count),
            "the carve-out must stay inside the port-53 branch, or it becomes a general TCP rule")

        // THE PROTOCOL IS PART OF THE KEY. There is a UDP carve-out now (S8.8), so this is no
        // longer "the UDP arm has not arrived yet" — it is the discrimination itself: the SAME
        // port number, claimed for TCP only, must not carve out a UDP datagram. Written with a
        // different source port before, which made it a port-mismatch assertion wearing a
        // protocol-mismatch comment and left the protocol term untested in both directions.
        var udp = ChainedDroppedFragmentTable()
        let udpPacket = Self.udpPacket(
            destination: [8, 8, 8, 8], destinationPort: 53,
            payload: [UInt8](repeating: 0, count: 12), sourcePort: claimed)
        XCTAssertEqual(
            Self.classify(udpPacket, fragments: &udp, ownResolverPorts: registry),
            .handleAsDNS(byteCount: udpPacket.count),
            "a TCP claim carved out a UDP datagram on the same port, so a user app that happens "
                + "to pick our resolver's TCP port reaches the peer unfiltered")
    }

    // MARK: - The UDP carve-out (S8.8)

    /// Our own UDP query reaches the peer instead of being fed back into the resolver.
    ///
    /// The TCP arm exists so a truncated-answer retry can get out. THIS one is what makes chained
    /// mode survive at all: UDP is the ordinary resolver path, so without it every query our own
    /// resolver sends arrives back at `readPackets`, is read as a client query to a hardcoded
    /// resolver, and is resolved — by opening another socket and sending another query. Unbounded,
    /// and each turn costs a descriptor inside a process under a ~50 MB ceiling (`INV-MEM-1`).
    func testOurOwnUDPQueryIsEncapsulatedRatherThanReResolved() {
        let registry = Self.emptyPortRegistry()
        let claimed: UInt16 = 51_000
        XCTAssertNotNil(registry.claim(sourcePort: claimed, protocolNumber: UInt8(IPPROTO_UDP)))

        var fragments = ChainedDroppedFragmentTable()
        let packet = Self.udpPacket(
            destination: [10, 255, 0, 1], destinationPort: 53,
            payload: [UInt8](repeating: 0, count: 12), sourcePort: claimed)
        XCTAssertEqual(
            Self.classify(packet, fragments: &fragments, ownResolverPorts: registry),
            .encapsulateOwnResolverQuery(byteCount: packet.count),
            "our own resolver's datagram was handed back to the resolver, which answers it by "
                + "sending another one — the loop that ends in a jetsam kill")
    }

    /// The UDP carve-out is EXACTLY the claim, swept over every source port.
    ///
    /// The mirror of `testTheCarveOutIsExactlyTheClaimAndNothingElse`, and the negative half is
    /// the one that matters more here: a UDP/53 datagram from an unclaimed port is a CLIENT query,
    /// and widening this predicate by an off-by-one or a read at the wrong offset would hand real
    /// user queries to the upstream operator unfiltered rather than filtering them (`INV-DNS-1`).
    func testTheUDPCarveOutIsExactlyTheClaimAndNothingElse() {
        let registry = Self.emptyPortRegistry()
        let claimed: UInt16 = 51_000
        XCTAssertNotNil(registry.claim(sourcePort: claimed, protocolNumber: UInt8(IPPROTO_UDP)))
        let payload = [UInt8](repeating: 0, count: 12)

        for candidate in UInt16.min...UInt16.max {
            var fragments = ChainedDroppedFragmentTable()
            let packet = Self.udpPacket(
                destination: [8, 8, 8, 8], destinationPort: 53, payload: payload,
                sourcePort: candidate)
            let verdict = Self.classify(packet, fragments: &fragments, ownResolverPorts: registry)
            let expected: ChainedOutboundDisposition = candidate == claimed
                ? .encapsulateOwnResolverQuery(byteCount: packet.count)
                : .handleAsDNS(byteCount: packet.count)
            if verdict != expected {
                XCTFail("source port \(candidate): expected \(expected), got \(verdict)")
                return
            }
        }
    }

    /// A UDP claim carves out UDP only — the protocol is half the key, asserted in both directions.
    ///
    /// The TCP-claim direction lives in `testAClaimedPortCarvesOutNothingElse`. This is the other
    /// one: a TCP/53 segment from a port claimed for UDP must stay dropped, or our own UDP claim
    /// silently starts forwarding user DNS-over-TCP to the peer.
    func testAUDPClaimDoesNotCarveOutTCPOnTheSamePort() {
        let registry = Self.emptyPortRegistry()
        let claimed: UInt16 = 51_000
        XCTAssertNotNil(registry.claim(sourcePort: claimed, protocolNumber: UInt8(IPPROTO_UDP)))

        var fragments = ChainedDroppedFragmentTable()
        let packet = Self.tcpPacket(
            destination: [8, 8, 8, 8], destinationPort: 53, sourcePort: claimed)
        XCTAssertEqual(
            Self.classify(packet, fragments: &fragments, ownResolverPorts: registry),
            .dropUnfilterableDNS(byteCount: packet.count),
            "a UDP claim carved out DNS-over-TCP on the same port number")
    }

    /// A query from a port released a moment ago is DROPPED, not handed to the resolver.
    ///
    /// The window `claims` cannot see. A packet reaches the classifier through the engine queue,
    /// so an own-resolver query can be classified after its socket was torn down and the claim
    /// released — at which point it looks exactly like a client query, and serving it feeds our
    /// own query back to our own resolver (Codex, PR #495).
    ///
    /// Dropped rather than encapsulated: the port is no longer ours to send from.
    func testAQueryFromAJustReleasedPortIsDroppedNotServed() {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var value: UInt64 = 0
            func now() -> UInt64 { lock.withLock { value } }
            func advance(seconds: UInt64) { lock.withLock { value += seconds * 1_000_000_000 } }
        }
        let clock = Clock()
        let registry = ChainedResolverPortRegistry(
            uptimeNanoseconds: { clock.now() }, closeDescriptor: { _ in },
            shutdownDescriptor: { _ in })
        let port: UInt16 = 51_000
        let claim = registry.claim(sourcePort: port, protocolNumber: UInt8(IPPROTO_UDP))
        XCTAssertNotNil(claim)

        let packet = Self.udpPacket(
            destination: [10, 255, 0, 1], destinationPort: 53,
            payload: [UInt8](repeating: 0, count: 12), sourcePort: port)

        // Held: carried.
        var live = ChainedDroppedFragmentTable()
        XCTAssertEqual(
            Self.classify(packet, fragments: &live, ownResolverPorts: registry),
            .encapsulateOwnResolverQuery(byteCount: packet.count))

        registry.releaseAndClose(claim, descriptor: -1)
        XCTAssertEqual(registry.claimedCount(), 0, "the claim outlived its release")

        // Released, still inside the grace window: neither carried nor served.
        var graced = ChainedDroppedFragmentTable()
        XCTAssertEqual(
            Self.classify(packet, fragments: &graced, ownResolverPorts: registry),
            .dropUnfilterableDNS(byteCount: packet.count),
            "a query whose socket had just gone away was handed to the resolver, which answers "
                + "it by sending another")

        // Past the window the port is nobody's, and a real client query must be filtered again.
        clock.advance(seconds: UInt64(ChainedResolverPortRegistry.releaseGraceSeconds) + 1)
        var expired = ChainedDroppedFragmentTable()
        XCTAssertEqual(
            Self.classify(packet, fragments: &expired, ownResolverPorts: registry),
            .handleAsDNS(byteCount: packet.count),
            "the grace window never ends, so a client reusing the port is silently unfilterable")
    }

    /// An expired claim stops carving out, and the packet goes back to being dropped.
    func testAClaimStopsCarvingOutOnceItsDeadlineHasPassed() {
        // A box, not a captured var: the clock seam is @Sendable.
        final class Clock: @unchecked Sendable { var value: UInt64 = 0 }
        let now = Clock()
        let registry = ChainedResolverPortRegistry(uptimeNanoseconds: { now.value })
        XCTAssertNotNil(registry.claim(sourcePort: 51_000, protocolNumber: UInt8(IPPROTO_TCP)))
        let packet = Self.tcpPacket(
            destination: [8, 8, 8, 8], destinationPort: 53, sourcePort: 51_000)

        var before = ChainedDroppedFragmentTable()
        XCTAssertEqual(
            Self.classify(packet, fragments: &before, ownResolverPorts: registry),
            .encapsulateOwnResolverQuery(byteCount: packet.count))

        now.value = UInt64(ChainedResolverPortRegistry.maximumEntryLifetimeSeconds) * 1_000_000_000 + 1
        var after = ChainedDroppedFragmentTable()
        XCTAssertEqual(
            Self.classify(packet, fragments: &after, ownResolverPorts: registry),
            .dropUnfilterableDNS(byteCount: packet.count),
            "a claim that outlived its socket must stop carving out, or the carve-out widens "
                + "silently over the tunnel's lifetime")
    }

    // MARK: - Destination read

    func testTheDestinationReadIsIPv4OnlyAndBoundsChecked() {
        // The reachability accounting reads this on every packet admitted to the engine, from a
        // seam that has NOT re-run `disposition(for:)`, so it cannot inherit that function's
        // length guarantee. IPv6 returns nil by construction: chained mode drops every outbound
        // v6 packet and claims `::/0` to blackhole them (`INV-CHAIN-1`), so a v6 destination could
        // only ever record a send this process itself discarded.
        var packet = ChainedSessionHarness.ipv4Packet(byteCount: 120, source: [10, 64, 0, 5])
        packet.withUnsafeBytes {
            XCTAssertEqual(ChainedOutboundPacketClassifier.ipv4Destination(of: $0), 0x5D_B8_D8_22)
        }

        packet[0] = 0x60  // an IPv6 version nibble
        packet.withUnsafeBytes {
            XCTAssertNil(
                ChainedOutboundPacketClassifier.ipv4Destination(of: $0),
                "an IPv6 packet produced a destination the tunnel never sent anything to")
        }

        for shortCount in [0, 1, 19] {
            let truncated = [UInt8](repeating: 0x45, count: shortCount)
            truncated.withUnsafeBytes {
                XCTAssertNil(
                    ChainedOutboundPacketClassifier.ipv4Destination(of: $0),
                    "a \(shortCount)-byte packet was read past its end")
            }
        }
    }

}
