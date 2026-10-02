import Darwin
import Foundation
import LavaSecKit

/// What the tunnel must do with one packet the OS handed it, while chained.
///
/// Plan: lavasec-infra `plans/2026-07-22-vpn-upstream-chaining-implementation-plan.md` (D5).
public enum ChainedOutboundDisposition: Equatable, Sendable {
    /// A DNS query for the local resolver path. Filtering owns it; the peer never sees it.
    case handleAsDNS(byteCount: Int)
    /// Ordinary traffic. Encrypt it for the peer.
    case encapsulate(byteCount: Int)
    /// An outbound IPv6 packet, discarded. See ``ChainedOutboundPacketClassifier`` for why
    /// this is deliberate rather than unimplemented.
    case dropOutboundIPv6(byteCount: Int)
    /// A DNS query this path cannot filter, dropped rather than handed to the peer.
    ///
    /// `INV-DNS-1` is never failing OPEN. Encapsulating a query the filter cannot read sends
    /// it to the upstream operator unfiltered and legible — the precise failure that
    /// intercepting port 53 exists to prevent, arriving by a shape the interception missed.
    /// Dropping fails closed: the resolver retries, or falls back to a form this path does
    /// read.
    case dropUnfilterableDNS(byteCount: Int)
    /// A packet identified as destination port 853 and refused by the encrypted-DNS policy.
    ///
    /// This names an existing drop decision, not a verified DoT/DoQ query or a successful
    /// bypass. It covers IPv4 full-tunnel and claimed split destinations, plus claimed IPv6
    /// UDP destinations. Other IPv6 drops retain their existing classification.
    /// Continuations have no port header and remain generic ``dropUnfilterableDNS`` drops;
    /// the bounded fragment deny-list deliberately stores no protocol attribution.
    /// pinned: ChainedOutboundPacketClassifierTests.testDoTIsDroppedOnlyWhenTheDataPathClaimsEveryDestination
    case dropUnfilterableEncryptedDNS(byteCount: Int)
    /// OUR OWN tunnel-pinned resolver query, encapsulated.
    ///
    /// A distinct case rather than reusing ``encapsulate``, for three reasons that are all
    /// about being able to SEE this later: the carve-out becomes visible in the type rather
    /// than hidden in a branch, it earns its own counter, and a spike in that counter with no
    /// resolver activity behind it is a detectable signal rather than noise inside the general
    /// encapsulation count.
    case encapsulateOwnResolverQuery(byteCount: Int)
    /// Not a packet this tunnel can reason about. Discarded without being forwarded.
    case dropMalformed

    /// Stable identifier for counters and the device log. Never user copy.
    public var logValue: String {
        switch self {
        case .handleAsDNS: return "handle-as-dns"
        case .dropUnfilterableDNS: return "drop-unfilterable-dns"
        case .dropUnfilterableEncryptedDNS: return "drop-unfilterable-encrypted-dns"
        case .encapsulate: return "encapsulate"
        case .encapsulateOwnResolverQuery: return "encapsulate-own-resolver-query"
        case .dropOutboundIPv6: return "drop-outbound-ipv6"
        case .dropMalformed: return "drop-malformed"
        }
    }
}

/// Decides what happens to each packet leaving the device while the tunnel is chained.
///
/// ## The blackhole this exists to prevent
///
/// `PacketTunnelProvider.handle(packet:protocolNumber:)` opens with
/// `guard let request = IPv4UDPDNSPacket(packet) else { return }`. Under the DNS-only route
/// plan that is correct: the tunnel claims `10.255.0.0/24`, so the only packets that arrive
/// are DNS queries for the local resolver, and anything else genuinely is unexpected.
///
/// Under `INV-CHAIN-1` the tunnel claims `0.0.0.0/0`. Every TCP connection, every IPv6
/// packet and every non-port-53 datagram on the device now arrives at that `guard` — and is
/// silently discarded, with no error, no counter and no log. Not a degraded tunnel: a total
/// blackhole that looks like a working one.
///
/// ## Why the DNS branch keys on the PORT and not the destination
///
/// `IPv4UDPDNSPacket` gates on `destinationPort == 53` while parsing `destinationAddress`
/// and never consulting it. Under a `/24` claim those are the same rule. Under `0.0.0.0/0`
/// they are not: a query to `8.8.8.8:53` now reaches the tunnel too, and this classifier has
/// to say what happens to it.
///
/// It is intercepted, exactly as a query to the tunnel resolver is. Narrowing interception to
/// the tunnel's own resolver address would hand every hardcoded-resolver query — the
/// `8.8.8.8` an app compiled in, the `1.1.1.1` a game console insists on — straight to the
/// peer as ordinary encrypted traffic. Unfiltered, because filtering happens on the DNS path
/// this would have skipped; and visible to the upstream operator, who is the one party the
/// user chose this feature to hide from. That is `INV-DNS-1` failing open, and it is the
/// reason today's port-only predicate is preserved rather than tightened.
/// pinned: ChainedOutboundPacketClassifierTests.testADNSQueryToAPublicResolverIsStillIntercepted
///
/// The reach of that interception is NOT this file's to claim, and the difference is
/// `INV-DNS-7`. Port-only capture makes every hardcoded-resolver query filterable *among the
/// packets that arrive here* — and what arrives is whatever the route plan claimed. Under a
/// SPLIT tunnel this same classifier runs while a hardcoded resolver outside the peer's
/// `AllowedIPs` never enters the NE at all, so "every clear-text query on the device is
/// filtered" is a full-tunnel statement, not a classifier statement. `DNSCaptureScope` is
/// where that distinction is derived and pinned.
///
/// ## Why IPv6 is dropped here
///
/// `ChainedDataPathPolicy` already answers this for the INBOUND direction
/// (`ChainedDataPathAction.dropIPv6`). Nothing answered it outbound, because until the tunnel
/// claims `::/0` nothing outbound arrives. The peer's AllowedIPs carry no IPv6 — the
/// configuration boundary requires only the IPv4 default route — so an encapsulated v6 packet
/// would be discarded at the far end instead of here, spending an encryption and a round trip
/// to reach the same outcome unaccounted.
///
/// ## One function over borrowed bytes
///
/// No I/O and no allocation, so every decision above is executable in a unit test rather than
/// reachable only inside a Network Extension.
///
/// It is not stateless, and the one piece of state is deliberately the caller's. A non-first
/// fragment carries no transport header, so whether it belongs to a DNS query is not a fact
/// about the fragment — it is a fact about the head that came before it. That history lives in
/// ``ChainedDroppedFragmentTable``, passed in, so the classifier stays a pure function of its
/// two arguments and the table can be constructed directly by a test.
public enum ChainedOutboundPacketClassifier {
    /// Classifies one outbound packet.
    ///
    /// - Parameters:
    ///   - packet: the bytes as `NEPacketTunnelFlow` delivered them, borrowed for the duration
    ///     of the call.
    ///   - fragments: the identities whose first fragment this classifier already dropped as
    ///     unfilterable DNS. Carried by the caller rather than held here because the decision
    ///     for a non-first fragment cannot be made from the fragment alone — see
    ///     ``ChainedDroppedFragmentTable``. The classifier stays a pure function of its two
    ///     inputs; only the table is state, and only fragments touch it.
    ///   - reclaimsStaleDenials: whether a forwarded fragment head may RELEASE its tuple from
    ///     the deny-list. True when this classification is happening in the order the packets
    ///     will leave, which is the only order the reclaim is sound in — see
    ///     ``encapsulateHead(_:moreFragments:reclaims:fragments:)``. A caller that classifies
    ///     out of release order (the runner does, under back-pressure) passes false and gets
    ///     the fail-closed behaviour instead.
    /// - Parameter ownResolverPorts: the source ports this process holds for its own
    ///   tunnel-pinned resolver queries. NO DEFAULT, deliberately: a defaulted empty registry
    ///   would make every future call site silently drop our own retries, and the failure would
    ///   look exactly like the truncation policy working as designed.
    /// - Parameter claimedResolverDestinations: the resolver destinations the route plan claimed
    ///   as DNS capture-floor host routes (``ChainedClaimedResolverDestinations``). Port 853
    ///   (DoT/DoQ) to one of them is dropped as unfilterable even in a SPLIT tunnel: the claim is
    ///   what brings the flow into the NE, where the filter cannot read it and the IPv4-only peer
    ///   will not carry it, so failing closed is the same rule the full-tunnel flag applies. A
    ///   destination NOT in the set stays ordinary traffic, preserving the split behaviour the
    ///   T1 rung may need. Defaults to empty — the pre-F4 behaviour — and a full tunnel passes
    ///   empty too, because `dropsUnfilterableEncryptedDNS` already covers its every destination.
    /// - Parameter dropsUnfilterableEncryptedDNS: whether port 853 (DoT over TCP, DoQ over UDP)
    ///   to ANY destination is dropped as unfilterable. True only for a FULL tunnel: there every
    ///   destination is claimed, so 853 can only be a resolver the filter cannot read, and the
    ///   session has no physical-egress resolver rung to strand. In a SPLIT tunnel the user's own
    ///   DoT resolver may egress on the physical interface, so dropping its port would break
    ///   resolution rather than protect it — the plan (`plans/2026-09-17-path-independent-dns-capture-floor.md`,
    ///   F4) scopes the split case to claimed destinations via `claimedResolverDestinations`.
    ///   Defaults to `false`, which is the pre-F4 behaviour, so a caller that forgets the flag
    ///   suppresses nothing.
    public static func disposition(
        for packet: UnsafeRawBufferPointer,
        fragments: inout ChainedDroppedFragmentTable,
        ownResolverPorts: ChainedResolverPortRegistry,
        claimedResolverDestinations: ChainedClaimedResolverDestinations = .empty,
        dropsUnfilterableEncryptedDNS: Bool = false,
        reclaimsStaleDenials: Bool = true
    ) -> ChainedOutboundDisposition {
        // An empty or sub-header packet cannot be classified at all. Reported as malformed
        // rather than encapsulated: handing the engine something we could not read is how a
        // caller-contract violation becomes a tunnel abort.
        guard packet.count >= 1 else { return .dropMalformed }

        let version = packet[0] >> 4
        if version == 6 {
            return ipv6Disposition(
                for: packet, ownResolverPorts: ownResolverPorts,
                claimedResolverDestinations: claimedResolverDestinations)
        }
        guard version == 4 else { return .dropMalformed }

        // From here the checks mirror `IPv4UDPDNSPacket.init?` exactly, in the same order, so
        // that every packet it accepts is classified `.handleAsDNS` and no packet it rejects
        // is. That equivalence is what keeps the DNS-only path bit-identical for users who
        // never enable chaining, and it is asserted differentially rather than by inspection.
        // pinned: ChainedOutboundPacketClassifierTests.testEveryPacketTheDNSParserAcceptsIsHandledAsDNS
        // THE WHOLE FIXED IPv4 HEADER, before anything else is read. Every field this
        // classifier needs to identify a fragment — identification, flags, addresses, protocol
        // — lives in the first 20 bytes, and reading them first is what lets a fragment be
        // judged before any length rule can discard it.
        guard packet.count >= 20 else { return .dropMalformed }
        let headerLength = Int(packet[0] & 0x0F) * 4

        // Fragments are inspected BEFORE being waved through. Encapsulating any fragment on
        // sight — which is what this did first — made fragmentation a DNS-filter bypass: a
        // UDP/53 query with more-fragments set went to the peer before its port was ever read,
        // to be reassembled and observed. The blackhole this rule avoids is real, but avoiding
        // it must not reopen the leak the port-53 interception exists to close.
        let flagsAndFragmentOffset = readUInt16(packet, at: 6)
        let moreFragments = flagsAndFragmentOffset & 0x2000 != 0
        let fragmentOffset = flagsAndFragmentOffset & 0x1FFF

        // A DoH profile's exact route must suppress Assist here too, not forward
        // encrypted lookups to a split peer. IPv6 already refuses non-DNS traffic.
        // Refuse continuation fragments to these dedicated endpoints before reading
        // a nonexistent transport header. Ordinary HTTPS destinations stay untouched.
        if claimedResolverDestinations.containsHTTPSIPv4Destination(readUInt32(packet, at: 16)),
           fragmentOffset != 0 || (headerLength >= 20 && packet.count >= headerLength + 4
                && (packet[9] == UInt8(IPPROTO_TCP) || packet[9] == UInt8(IPPROTO_UDP))
                && readUInt16(packet, at: headerLength + 2) == 443) {
            return .dropUnfilterableDNS(byteCount: packet.count)
        }

        // A NON-FIRST FRAGMENT IS DECIDED HERE, ahead of every length guard, because the guards
        // below are about a UDP header this packet does not have. Only NON-FINAL fragments must
        // carry an eight-byte-aligned payload, so the LAST continuation of a datagram is legally
        // short — and it was reaching `unreadableLengthDisposition`, which encapsulated it and,
        // worse, read its payload bytes as though they were a destination port. That is the tail
        // of a dropped DNS query going to the peer, which is the leak this table exists to stop,
        // arriving through the guard meant to be conservative.
        if fragmentOffset != 0 {
            let identity = identity(of: packet)
            guard fragments.contains(identity) else { return .encapsulate(byteCount: packet.count) }
            // NOT FORGOTTEN HERE, and the previous round's fix to do so was wrong.
            //
            // An unset more-fragments bit identifies the HIGHEST-OFFSET fragment, not the last
            // one that will be observed. Fragments can arrive out of offset order, a
            // retransmission can follow the tail, and the key deliberately conflates
            // identification collisions — so a colliding datagram's MF-clear tail releases an
            // identity whose own continuations have not all passed. The next middle fragment
            // then misses the table and is encapsulated with its query bytes.
            //
            // So NO TAIL releases an entry. An entry is released by eviction, or by a later
            // HEAD this classifier forwards, in release order — see
            // ``encapsulateHead(_:moreFragments:reclaims:fragments:)`` for why a forwarded head
            // is different in kind from an MF-clear tail, and when it is not trusted at all. A reused
            // identification between those two events drops an unrelated permitted flow's
            // tails: fail-CLOSED — traffic lost, not query bytes leaked — and the direction to
            // be wrong in. Bounding the lifetime properly needs fragment-coverage tracking or a
            // clock, and this type has neither.
            // pinned: ChainedOutboundPacketClassifierTests.testAnOutOfOrderTailIsStillDroppedAfterTheFinalOne
            return .dropUnfilterableDNS(byteCount: packet.count)
        }

        guard headerLength >= 20, packet.count >= headerLength + 8 else {
            // Too short to carry an IPv4 header plus a UDP header. It may still be a legal
            // packet of another protocol — a 20-byte TCP ACK arrives here — so this is not
            // malformed on its own; fall through to the protocol check below.
            return unreadableLengthDisposition(
                packet, headerLength: headerLength, moreFragments: moreFragments,
                claimedResolverDestinations: claimedResolverDestinations,
                dropsUnfilterableEncryptedDNS: dropsUnfilterableEncryptedDNS,
                reclaims: reclaimsStaleDenials, fragments: &fragments)
        }

        let totalLength = Int(readUInt16(packet, at: 2))
        guard totalLength >= headerLength + 8, totalLength <= packet.count else {
            return unreadableLengthDisposition(
                packet, headerLength: headerLength, moreFragments: moreFragments,
                claimedResolverDestinations: claimedResolverDestinations,
                dropsUnfilterableEncryptedDNS: dropsUnfilterableEncryptedDNS,
                reclaims: reclaimsStaleDenials, fragments: &fragments)
        }

        // TCP/53 IS DNS, and most often it is the retry a truncated UDP answer forces. Treating
        // it as ordinary traffic hands the peer the very query the UDP interception just
        // protected — unfiltered, and legible to the one party the user is hiding from. The
        // resolver path reads UDP only, so this cannot be served locally; INV-DNS-1 says fail
        // closed, not fail outward.
        // pinned: ChainedOutboundPacketClassifierTests.testDNSOverTCPIsDroppedRatherThanHandedToThePeer
        if packet[9] == UInt8(IPPROTO_TCP) {
            let tcpOffset = headerLength
            guard packet.count >= tcpOffset + 4 else {
                return encapsulateHead(packet, moreFragments: moreFragments, reclaims: reclaimsStaleDenials, fragments: &fragments)
            }
            if readUInt16(packet, at: tcpOffset + 2) == 53 {
                // OUR OWN retry, and nothing else. Keyed on the LOCAL SOURCE PORT — a port this
                // process currently holds — NEVER on the destination, which would hand every
                // hardcoded-resolver query to the operator unfiltered (see
                // `testADNSQueryToAPublicResolverIsStillIntercepted`).
                //
                // `!moreFragments` is exactness rather than caution: our own segments are
                // kernel-built and MSS-clamped, so a FRAGMENTED TCP/53 packet is never ours.
                // Gating here also keeps the carve-out entirely outside
                // `ChainedDroppedFragmentTable`'s reclaim semantics, which took PRs #478 and
                // #480 to get right.
                //
                // The source port is at `tcpOffset + 0..1`; the `packet.count >= tcpOffset + 4`
                // guard above already covers reading it, so this adds no bounds check.
                // pinned: ChainedOutboundPacketClassifierTests.testTheCarveOutIsExactlyTheClaimAndNothingElse
                if !moreFragments,
                   ownResolverPorts.claims(
                    sourcePort: readUInt16(packet, at: tcpOffset), protocolNumber: packet[9]) {
                    return .encapsulateOwnResolverQuery(byteCount: packet.count)
                }
                // The TCP arm reaches the same drop by a different road — a TCP/53 segment is
                // dropped as unfilterable anyway — so the grace window changes nothing here and
                // is not consulted. Stated so the asymmetry with the UDP arm reads as deliberate
                // rather than forgotten.

                // A fragmented TCP/53 query leaks through its tails exactly as a UDP one does,
                // so its identity is remembered here too. Only when there ARE tails: an
                // unfragmented datagram has none, and remembering it would spend an entry that
                // a datagram with continuations in flight needs.
                if moreFragments {
                    fragments.remember(identity(of: packet))
                }
                return .dropUnfilterableDNS(byteCount: packet.count)
            }
            // DoT (TCP/853). A transport the tunnel cannot terminate or read, so it is dropped
            // rather than handed to the peer — same fail-closed rule as TCP/53, and the same
            // source-port carve-out does NOT apply (our own resolver has no TCP/853 leg while
            // chained; the encrypted rung is unavailable).
            //
            // FULL tunnel: every destination is claimed, so the flag drops all of it. SPLIT:
            // only a destination the F3b capture floor CLAIMED is dropped, because the claim is
            // what drew the flow into the NE — an unclaimed `:853` is the user's own DoT rung
            // egressing physically, and dropping it would strand resolution rather than protect
            // it (`INV-DNS-7`).
            // pinned: ChainedOutboundPacketClassifierTests.testDoTIsDroppedOnlyWhenTheDataPathClaimsEveryDestination
            // pinned: ChainedOutboundPacketClassifierTests.testDotToAClaimedResolverDestinationIsDroppedInSplit
            if readUInt16(packet, at: tcpOffset + 2) == 853,
               (dropsUnfilterableEncryptedDNS
                   || (!claimedResolverDestinations.isEmpty
                       && claimedResolverDestinations.containsIPv4Destination(
                           readUInt32(packet, at: 16)))) {
                if moreFragments {
                    fragments.remember(identity(of: packet))
                }
                return .dropUnfilterableEncryptedDNS(byteCount: packet.count)
            }
            return encapsulateHead(packet, moreFragments: moreFragments, reclaims: reclaimsStaleDenials, fragments: &fragments)
        }

        guard packet[9] == UInt8(IPPROTO_UDP) else {
            return encapsulateHead(packet, moreFragments: moreFragments, reclaims: reclaimsStaleDenials, fragments: &fragments)
        }

        let udpOffset = headerLength
        let destinationPort = readUInt16(packet, at: udpOffset + 2)

        // A FIRST FRAGMENT is decided HERE, before the UDP length is consulted, because for a
        // first fragment that field does not describe this packet. It describes the whole
        // reassembled datagram, so on any real fragment head `udpOffset + udpLength` exceeds
        // this fragment's `totalLength` — and the overrun check below therefore called every
        // legal fragment head malformed and dropped it, while `fragmentOffset != 0` waved its
        // continuations through to the peer. Tails no receiver can reassemble: chained mode
        // blackholing every fragmented UDP flow, by the same "cannot read it, drop it" reflex
        // that is right one line later and wrong here.
        //
        // The destination port IS readable — a first fragment carries the UDP header — and it
        // is the only thing this decision needs. A FRAGMENTED DNS query cannot be filtered,
        // because the resolver path needs a whole datagram and this one continues in packets
        // carrying no header, so it fails closed (`INV-DNS-1`); encapsulating it would let the
        // peer reassemble and read the hardcoded-resolver query the interception exists to
        // stop. Everything else is ordinary traffic and is encapsulated intact.
        // pinned: ChainedOutboundPacketClassifierTests.testAFragmentedDNSQueryIsDroppedNotEncapsulated
        // pinned: ChainedOutboundPacketClassifierTests.testANonDNSFragmentHeadIsEncapsulatedRatherThanReadAsMalformed
        if moreFragments {
            // 53 is DNS; 853 (DoQ) joins it when the data path claims every destination (full
            // tunnel) OR claims this destination specifically (the F3b capture floor), so the
            // split-tunnel case that may need its own DoT rung is untouched for unclaimed
            // destinations.
            guard destinationPort == 53
                || (destinationPort == 853
                    && (dropsUnfilterableEncryptedDNS
                        || (!claimedResolverDestinations.isEmpty
                            && claimedResolverDestinations.containsIPv4Destination(
                                readUInt32(packet, at: 16)))))
            else {
                return encapsulateHead(packet, moreFragments: true, reclaims: reclaimsStaleDenials, fragments: &fragments)
            }
            // Remembered so the continuations are dropped too. Dropping only the head stops the
            // query without stopping it being read — see ``ChainedDroppedFragmentTable``.
            fragments.remember(identity(of: packet))
            return destinationPort == 853
                ? .dropUnfilterableEncryptedDNS(byteCount: packet.count)
                : .dropUnfilterableDNS(byteCount: packet.count)
        }

        let udpLength = Int(readUInt16(packet, at: udpOffset + 4))
        guard udpLength >= 8, udpOffset + udpLength <= totalLength else {
            // An UNFRAGMENTED UDP length that overruns its own datagram is not something to
            // forward. The engine would encapsulate it happily and the far end would decide —
            // but "the far end will cope" is how a malformed packet becomes someone else's
            // problem. Only reachable for unfragmented datagrams, where the length field
            // genuinely does describe these bytes.
            return .dropMalformed
        }

        // DoQ (UDP/853). Same fail-closed rule as TCP/853: there is no local resolver path on
        // 853, so an unfilterable one is refused rather than handed to the peer. FULL tunnel
        // drops every destination; SPLIT drops only a destination the F3b capture floor claimed,
        // leaving the session's own DoQ rung reachable everywhere else (`INV-DNS-7`).
        // pinned: ChainedOutboundPacketClassifierTests.testDoqToAClaimedResolverDestinationIsDroppedInSplit
        if destinationPort == 853,
           (dropsUnfilterableEncryptedDNS
               || (!claimedResolverDestinations.isEmpty
                   && claimedResolverDestinations.containsIPv4Destination(
                       readUInt32(packet, at: 16)))) {
            return .dropUnfilterableEncryptedDNS(byteCount: packet.count)
        }

        guard destinationPort == 53 else {
            return encapsulateHead(packet, moreFragments: moreFragments, reclaims: reclaimsStaleDenials, fragments: &fragments)
        }

        // OUR OWN QUERY, and without this arm chained mode does not merely leak — it does not
        // survive. The TCP carve-out below the same rule exists so a truncated-answer retry can
        // reach the upstream; this one exists because the UDP query is the ORDINARY path, and
        // classifying it `.handleAsDNS` feeds our own resolver's datagram back into the resolver.
        // Each turn opens a socket and sends a query that returns here, unbounded, under a ~50 MB
        // ceiling (`INV-MEM-1`).
        //
        // Keyed on the LOCAL SOURCE PORT — a port this process currently holds — never on the
        // destination, which would hand every hardcoded-resolver query to the operator unfiltered
        // (`testADNSQueryToAPublicResolverIsStillIntercepted`). No `!moreFragments` guard is
        // needed here where the TCP arm has one: a fragmented UDP/53 datagram was already
        // dispatched above, so everything reaching this line is unfragmented.
        // pinned: ChainedOutboundPacketClassifierTests.testOurOwnUDPQueryIsEncapsulatedRatherThanReResolved
        // pinned: ChainedOutboundPacketClassifierTests.testTheUDPCarveOutIsExactlyTheClaimAndNothingElse
        // pinned: ChainedOutboundPacketClassifierTests.testAUDPClaimDoesNotCarveOutTCPOnTheSamePort
        let udpSourcePort = readUInt16(packet, at: udpOffset)
        if ownResolverPorts.claims(sourcePort: udpSourcePort, protocolNumber: packet[9]) {
            return .encapsulateOwnResolverQuery(byteCount: packet.count)
        }

        // OURS A MOMENT AGO, AND STILL IN FLIGHT. A packet reaches this function through the
        // engine queue, so an own-resolver query can be classified after its socket was torn
        // down and its claim released. `claims` is false by then and the query would read as a
        // CLIENT query — served by our own resolver, which answers it by sending another
        // (Codex, PR #495). Dropped rather than encapsulated: the port is no longer ours to send
        // from, and this query's socket is gone, so there is nothing left to carry.
        // pinned: ChainedOutboundPacketClassifierTests.testAQueryFromAJustReleasedPortIsDroppedNotServed
        if ownResolverPorts.wasRecentlyClaimed(sourcePort: udpSourcePort, protocolNumber: packet[9]) {
            return .dropUnfilterableDNS(byteCount: packet.count)
        }

        // A port-53 datagram with no payload is not a query, and the DNS parser rejects it — so
        // classifying it as DNS would break the differential property. It is DROPPED rather than
        // forwarded, which was the earlier answer on the grounds that an empty datagram has no
        // query bytes to leak.
        //
        // That was true and it was the wrong question. Forwarding it made the rule "nothing
        // addressed to port 53 reaches the peer" have an exception, and an invariant with an
        // exception is one a reader has to re-derive every time. Dropping also matches what the
        // DNS-only path already does with this packet: the parser refuses it and the provider
        // discards it, so chained mode now agrees rather than diverging on a shape neither can
        // use.
        // pinned: ChainedOutboundPacketClassifierTests.testEveryPacketTheDNSParserAcceptsIsHandledAsDNS
        let payloadStart = udpOffset + 8
        let payloadEnd = udpOffset + udpLength
        guard payloadEnd > payloadStart else {
            return .dropUnfilterableDNS(byteCount: packet.count)
        }

        return .handleAsDNS(byteCount: packet.count)
    }

    /// The IPv6 branch of ``disposition(for:fragments:ownResolverPorts:claimedResolverDestinations:dropsUnfilterableEncryptedDNS:reclaimsStaleDenials:)``.
    ///
    /// Since F3c the tunnel serves filtered client DNS over IPv6 as well as IPv4, so a plain
    /// IPv6/UDP datagram to port 53 is handed to the in-tunnel resolver (`.handleAsDNS`) exactly
    /// as its IPv4 counterpart is. Everything else over IPv6 is dropped: the chained upstream is
    /// IPv4-only, and the plan's F3b/F3c end state claims only the DNS destinations it must
    /// capture, so non-DNS v6 that still reaches here is not ours to carry.
    ///
    /// A DoQ (UDP/853) destination the F3b floor CLAIMED is attributed as unfilterable encrypted
    /// DNS rather than the blanket outbound-v6 drop — same refusal, but named, and symmetric with
    /// the IPv4 arm. A claimed v6 resolver reaches the NE only because the plan routed it here;
    /// an unclaimed one stays on the physical interface and never arrives. The full-tunnel flag is
    /// deliberately NOT read here: a full tunnel passes `.empty`, and every non-DNS v6 packet is
    /// already dropped, so this arm changes only the attribution of what is dropped regardless.
    ///
    /// Extension headers are refused rather than walked. A fragment header (44) or any other
    /// extension header means this is not a plain UDP DNS query, and failing closed is the only
    /// answer consistent with `INV-DNS-1`. The header shape mirrors ``IPv6UDPDNSPacket/init?``
    /// so every packet the DNS parser accepts is classified `.handleAsDNS` and no packet it
    /// rejects is — the same differential property the IPv4 branch carries.
    private static func ipv6Disposition(
        for packet: UnsafeRawBufferPointer,
        ownResolverPorts: ChainedResolverPortRegistry,
        claimedResolverDestinations: ChainedClaimedResolverDestinations
    ) -> ChainedOutboundDisposition {
        // Fixed IPv6 header (40) + UDP header (8): anything shorter is not a UDP datagram, and
        // a non-UDP next header is not a DNS query we can read.
        guard packet.count >= 48, packet[6] == UInt8(IPPROTO_UDP) else {
            return .dropOutboundIPv6(byteCount: packet.count)
        }

        // The port survives a damaged length field whenever the transport header is present,
        // so it is read FIRST: a length-damaged datagram is only attributed to unfilterable DNS
        // when it is actually addressed to 53, never for an unrelated v6 flow (the IPv4
        // `unreadableLengthDisposition` rule, for the same accounting reason).
        let sourcePort = readUInt16(packet, at: 40)
        let destinationPort = readUInt16(packet, at: 42)

        // A claimed DoQ destination, computed only for :853 and only when the set is non-empty,
        // so the common path pays no extra destination reads. The bytes live in the fixed header.
        // pinned: ChainedOutboundPacketClassifierTests.testDoqToAClaimedIPv6ResolverDestinationIsDropped
        let isClaimedEncryptedDNSDestination = destinationPort == 853
            && !claimedResolverDestinations.isEmpty
            && claimedResolverDestinations.containsIPv6Destination(
                readUInt32(packet, at: 24), readUInt32(packet, at: 28),
                readUInt32(packet, at: 32), readUInt32(packet, at: 36))

        let payloadLength = Int(readUInt16(packet, at: 4))
        let totalLength = 40 + payloadLength
        guard payloadLength >= 8, totalLength <= packet.count else {
            if isClaimedEncryptedDNSDestination {
                return .dropUnfilterableEncryptedDNS(byteCount: packet.count)
            }
            return destinationPort == 53
                ? .dropUnfilterableDNS(byteCount: packet.count)
                : .dropOutboundIPv6(byteCount: packet.count)
        }

        let udpLength = Int(readUInt16(packet, at: 44))
        guard udpLength >= 8, 40 + udpLength <= totalLength else {
            if isClaimedEncryptedDNSDestination {
                return .dropUnfilterableEncryptedDNS(byteCount: packet.count)
            }
            return destinationPort == 53
                ? .dropUnfilterableDNS(byteCount: packet.count)
                : .dropOutboundIPv6(byteCount: packet.count)
        }

        guard destinationPort == 53 else {
            return isClaimedEncryptedDNSDestination
                ? .dropUnfilterableEncryptedDNS(byteCount: packet.count)
                : .dropOutboundIPv6(byteCount: packet.count)
        }

        // The same own-resolver carve-out IPv4 gets: our own v6 query must reach the peer, not
        // be fed back into the resolver that sent it.
        if ownResolverPorts.claims(sourcePort: sourcePort, protocolNumber: UInt8(IPPROTO_UDP)) {
            return .encapsulateOwnResolverQuery(byteCount: packet.count)
        }
        if ownResolverPorts.wasRecentlyClaimed(sourcePort: sourcePort, protocolNumber: UInt8(IPPROTO_UDP)) {
            return .dropUnfilterableDNS(byteCount: packet.count)
        }

        // A port-53 datagram with no payload is not a query; it fails closed rather than being
        // served (the IPv4 branch's rule, for the same differential reason).
        guard 40 + udpLength > 48 else {
            return .dropUnfilterableDNS(byteCount: packet.count)
        }

        return .handleAsDNS(byteCount: packet.count)
    }

    /// A packet whose lengths do not describe it, classified by what it is rather than by what
    /// it is not.
    ///
    /// Separated so the two length guards above read as one decision. A short IPv4 packet is
    /// ordinary traffic — a bare TCP ACK is 40 bytes and legal — so it is encapsulated. Only a
    /// packet whose own header length field points past its end is malformed, because that is
    /// a packet no reader can act on.
    ///
    /// THE PORT IS STILL READ, and that is the correction. This returned `.encapsulate` for
    /// anything with a plausible IPv4 header, so a UDP/53 datagram whose total-length field was
    /// nonsense — shorter than its own headers, or longer than the buffer — was forwarded to the
    /// peer with the query bytes intact. `IPv4UDPDNSPacket` rejects those shapes, so they are
    /// not served locally either: the query was neither filtered nor answered, only handed to
    /// the observer. A packet too damaged to classify is exactly the one that must fail closed
    /// (`INV-DNS-1`), and the destination port survives the damage whenever four transport bytes
    /// are present.
    /// pinned: ChainedOutboundPacketClassifierTests.testADamagedLengthFieldDoesNotForwardADNSQuery
    private static func unreadableLengthDisposition(
        _ packet: UnsafeRawBufferPointer,
        headerLength: Int,
        moreFragments: Bool,
        claimedResolverDestinations: ChainedClaimedResolverDestinations,
        dropsUnfilterableEncryptedDNS: Bool,
        reclaims: Bool,
        fragments: inout ChainedDroppedFragmentTable
    ) -> ChainedOutboundDisposition {
        guard headerLength >= 20, packet.count >= headerLength else { return .dropMalformed }
        // UDP and TCP put the destination port in the same place, so one read covers both. Only
        // reachable for FIRST fragments and unfragmented datagrams, which do carry a transport
        // header — a continuation is decided by the deny-list before this is called.
        guard packet.count >= headerLength + 4 else {
            return encapsulateHead(packet, moreFragments: moreFragments, reclaims: reclaims, fragments: &fragments)
        }
        let isTransportWithPorts = packet[9] == UInt8(IPPROTO_UDP) || packet[9] == UInt8(IPPROTO_TCP)
        if isTransportWithPorts, readUInt16(packet, at: headerLength + 2) == 53 {
            // REMEMBERED HERE TOO, and forgetting to was a leak with a narrow shape: a port-53
            // first fragment whose total length was damaged got dropped by this path without
            // its identity being recorded, so its well-formed tails missed the deny-list and
            // were forwarded. The damaged-length case is exactly the one this branch exists to
            // fail closed on, and it was failing closed for the head alone.
            // pinned: ChainedOutboundPacketClassifierTests.testADamagedFragmentHeadStillSilencesItsTails
            if moreFragments { fragments.remember(identity(of: packet)) }
            return .dropUnfilterableDNS(byteCount: packet.count)
        }
        // DoT/DoQ under a damaged length: the same fail-closed rule as port 53 above, so a
        // port-853 packet whose total-length field is nonsense is not handed to the peer with
        // its encrypted payload intact just because the length could not be read. The identity
        // is remembered for the same reason — a damaged head's well-formed tails must be silenced
        // too, or the datagram is dropped only in part. (Kilo, PR #739.) The full-tunnel flag and
        // the F3b claimed destination set are the same two terms the readable-length arms use,
        // so a claimed resolver's damaged DoT/DoQ cannot become a hole.
        // pinned: ChainedOutboundPacketClassifierTests.testDotToAClaimedResolverDestinationIsDroppedInSplit
        if isTransportWithPorts,
           readUInt16(packet, at: headerLength + 2) == 853,
           (dropsUnfilterableEncryptedDNS
               || (!claimedResolverDestinations.isEmpty
                   && claimedResolverDestinations.containsIPv4Destination(
                       readUInt32(packet, at: 16)))) {
            if moreFragments { fragments.remember(identity(of: packet)) }
            return .dropUnfilterableEncryptedDNS(byteCount: packet.count)
        }
        return encapsulateHead(packet, moreFragments: moreFragments, reclaims: reclaims, fragments: &fragments)
    }

    /// Forwards a first fragment, RECLAIMING its tuple from the deny-list on the way out.
    ///
    /// Every `.encapsulate` the classifier returns for an offset-zero packet passes through
    /// here, so the rule is structural rather than per-site: the table never contradicts the
    /// disposition of the most recent head it has seen for a tuple. A forwarded head whose
    /// tails a stale entry then drops is a datagram the peer can never reassemble — and because
    /// only dropped heads evict, ordinary traffic never cleared the entry, so a reused
    /// identification was destroyed again on every wrap for as long as the entry lived (PR
    /// #478). The reclaim happens only when the head has continuations to protect
    /// (more-fragments set): an unfragmented datagram is no evidence about fragments, and
    /// clearing on it would release a denial whose own tails may still be in flight, for
    /// nothing.
    /// pinned: ChainedOutboundPacketClassifierTests.testAnUnfragmentedPermittedDatagramDoesNotClearTheDenial
    ///
    /// ## Only in release order, which the caller is the authority on
    ///
    /// The reclaim reads the head as evidence about a tuple's CURRENT datagram, and that
    /// inference is only valid if every packet classified before this one has already left. Out
    /// of release order it is false and the failure is a leak: a runner holding a stalled batch
    /// classifies a newer permitted head at arrival, clears the denial, and then re-classifies
    /// the OLDER parked DNS tail against a table that no longer denies it — forwarding the query
    /// bytes the deny-list exists to suppress (Codex, PR #480). So `reclaims` is the caller's
    /// statement that nothing older is still waiting to be classified; when it cannot say that,
    /// the stale denial simply stands, which is the fail-CLOSED direction this whole type
    /// prefers.
    /// pinned: ChainedOutboundPacketClassifierTests.testAHeadDoesNotReclaimWhenOlderPacketsAreStillWaiting
    ///
    /// ## The direction this trades, stated rather than dismissed
    ///
    /// A straggler tail of the DROPPED datagram arriving after its tuple is reclaimed now
    /// misses the table and is forwarded — partial query bytes, the fail-OPEN direction. That
    /// shape already exists: eviction releases entries the same way, and the reclaim requires
    /// the same coincidence eviction does (another datagram claiming the identical tuple).
    /// What bounds it is who can construct it: outbound packets come from the OS stack, which
    /// assigns identifications itself — an app cannot emit raw IP or hand-built fragments — so
    /// the interleaving is a wraparound accident, not a crafted clearing. The recurring
    /// destruction of permitted flows was certain and unbounded in time; the straggler is
    /// probabilistic and one datagram wide.
    /// pinned: ChainedOutboundPacketClassifierTests.testAPermittedHeadReusingAnIdentificationClearsTheStaleDenial
    private static func encapsulateHead(
        _ packet: UnsafeRawBufferPointer,
        moreFragments: Bool,
        reclaims: Bool,
        fragments: inout ChainedDroppedFragmentTable
    ) -> ChainedOutboundDisposition {
        if moreFragments, reclaims { fragments.forget(identity(of: packet)) }
        return .encapsulate(byteCount: packet.count)
    }

    /// This packet's IPv4 destination, or `nil` when it is not a readable IPv4 header.
    ///
    /// Public because the reachability accounting (`ChainedDestinationTable`) needs the same
    /// field the reassembly key reads, and IP-header offsets belong in ONE file. It re-validates
    /// rather than trusting the caller: `identity(of:)` can rely on `disposition(for:)` having
    /// established the length, and a second caller reached from another seam cannot.
    ///
    /// Returns `nil` for IPv6 by construction rather than by omission — while chained every
    /// outbound v6 packet is dropped here and chained mode claims `::/0` deliberately to
    /// blackhole them (`INV-CHAIN-1`), so a v6 destination could only ever record a send this
    /// process itself discarded.
    /// pinned: ChainedOutboundPacketClassifierTests.testTheDestinationReadIsIPv4OnlyAndBoundsChecked
    public static func ipv4Destination(of packet: UnsafeRawBufferPointer) -> UInt32? {
        guard packet.count >= 20, packet[0] >> 4 == 4 else { return nil }
        return readUInt32(packet, at: 16)
    }

    /// The reassembly key: source, destination, protocol and identification.
    ///
    /// Every field read here lives in the first 20 bytes, and the caller has already
    /// established `headerLength >= 20` with the packet at least that long — so the bound holds
    /// regardless of options, and this needs no length argument to stay in range.
    private static func identity(of packet: UnsafeRawBufferPointer) -> ChainedFragmentIdentity {
        ChainedFragmentIdentity(
            source: readUInt32(packet, at: 12),
            destination: readUInt32(packet, at: 16),
            identification: readUInt16(packet, at: 4),
            protocolNumber: packet[9])
    }

    private static func readUInt32(_ packet: UnsafeRawBufferPointer, at index: Int) -> UInt32 {
        (UInt32(packet[index]) << 24) | (UInt32(packet[index + 1]) << 16)
            | (UInt32(packet[index + 2]) << 8) | UInt32(packet[index + 3])
    }

    private static func readUInt16(_ packet: UnsafeRawBufferPointer, at index: Int) -> UInt16 {
        (UInt16(packet[index]) << 8) | UInt16(packet[index + 1])
    }
}
