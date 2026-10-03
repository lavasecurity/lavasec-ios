import Darwin

/// Reads a delivered inner IPv4 packet's transport source port, to tell an actual DNS reply
/// from ordinary traffic the resolver ADDRESS also serves.
///
/// ## The edge this closes
///
/// `ChainedSessionRunner.deliverOnQueue` excluded EVERY inbound byte whose source ADDRESS is a
/// configured resolver from `forwardedNonDNSByteCount` — the connect gate's "the chain carries
/// your traffic" evidence (`ChainedEstablishmentPolicy`, PR #558) and the egress-dead arm's
/// forwarding signal (`ChainedOutageDriver`, PR #567). A public resolver IP does not only serve
/// DNS: `1.1.1.1`, `8.8.8.8` and `9.9.9.9` all answer HTTPS on the same address. So a user whose
/// only sustained non-DNS traffic for a whole detection window is a transfer FROM that one
/// resolver IP saw the counter stay flat while the demand signal armed — the connect gate could
/// false-reject at establishment and the egress-dead arm false-surrender a healthy, forwarding
/// chain (device-confirmed 2026-08-23, QA generator aimed exclusively at the resolver IP).
///
/// The fix is to exclude only an ACTUAL DNS reply — a resolver-sourced packet whose transport
/// source port is 53 — and count everything else from that address as the general forwarding it
/// is. The address half stays with the runner's allocation-free `ChainedAllowedIPs.permits`; this
/// type supplies the port half.
///
/// ## Fail-closed asymmetry (deliberate)
///
/// ``carriesNonDNSSourcePort(_:)`` returns true ONLY for a packet whose UDP/TCP source port it
/// can positively read AND that port is not 53. Everything it cannot read that way — a port-53
/// reply, a non-first fragment carrying no transport header, a non-UDP/TCP protocol, a truncated
/// header — returns FALSE, so the caller keeps EXCLUDING it. That direction is load-bearing: the
/// connect gate must never over-count resolver traffic as forwarding or it fails OPEN
/// (`ChainedEstablishmentPolicy`'s whole invariant), so an unclassifiable resolver-sourced packet
/// — including a fragmented DNS reply's headerless tails — stays DNS-shaped and excluded. Only a
/// byte this can PROVE is non-DNS is counted. The residual under-count (a resolver IP reached
/// ONLY over ICMP, or only via fragmented non-DNS, as a user's sole traffic) is narrower than the
/// address-wide exclusion it replaces and errs toward the gate staying closed.
///
/// ## Why counting a non-53 resolver packet is NOT a fail-open
///
/// The mirror worry: could a genuine DNS reply arrive from a resolver on a non-53 port — DoT
/// (:853), DoH (:443) — so this counts real DNS as forwarding and lets a DNS-only chain confirm?
/// It cannot, because the exclusion set is the tunnel's OWN upstream resolvers, and while chained
/// the tunnel's own DNS egress is plain UDP :53 and nothing else: DoH/DoT/DoQ are unrepresentable
/// in `ChainedResolverEgress` (`ChainedResolverEgressPolicy.needsATransportTheTunnelCannotCarry`),
/// the encrypted-fallback ladder is suspended, and the only non-UDP case is a (currently disabled)
/// TCP truncation retry, still :53. So a packet FROM a resolver address on any non-53 port is by
/// construction NOT the tunnel's own DNS — it is an application flow that traversed the full
/// chained data path (e.g. an app's own DoH to that same IP), exactly the real forwarding the gate
/// must count. The port-53 exclusion is therefore complete for the tunnel's own DNS, and the
/// "cannot over-count resolver traffic" claim above holds for the deployment this runs in.
///
/// ## Allocation-free over borrowed bytes (`INV-MEM-1`)
///
/// A bounded walk of the fixed IPv4 header, no copy and no `Data`, mirroring
/// ``ChainedOutboundPacketClassifier``'s reading on the outbound side. It runs on the inbound hot
/// path inside a process bounded at ~50 MB, so it allocates nothing per packet.
/// pinned: ChainedInboundDNSReplyTests.testAPortFiftyThreeSourceIsNotCountedAsNonDNS
/// pinned: ChainedInboundDNSReplyTests.testAnHTTPSSourcePortFromTheResolverIsNonDNS
enum ChainedInboundDNSReply {
    /// The DNS transport port. A reply from a resolver leaves FROM this port, so it is the inner
    /// packet's transport SOURCE port that identifies the reply — never the destination, which is
    /// the client's ephemeral port.
    static let dnsPort: UInt16 = 53

    /// Whether a delivered inner IPv4 packet positively carries a UDP or TCP source port OTHER
    /// than 53 — the signature of ordinary traffic (a resolver IP that also serves HTTPS) rather
    /// than a DNS reply.
    ///
    /// - Parameter packet: the decapsulated inner IPv4 packet, borrowed for the call and already
    ///   restricted to its own length by the caller.
    /// - Returns: true only when a transport source port is readable and is not 53; false for a
    ///   port-53 reply and for anything whose port cannot be read (see the type's fail-closed
    ///   note).
    static func carriesNonDNSSourcePort(_ packet: UnsafeRawBufferPointer) -> Bool {
        // The fixed IPv4 header, before any field is read. Nothing shorter can carry both an IHL
        // and a transport header, and a delivered packet that is somehow shorter is left excluded
        // rather than guessed at.
        guard packet.count >= 20, packet[0] >> 4 == 4 else { return false }
        let headerLength = Int(packet[0] & 0x0F) * 4
        // The transport source port sits in the first two bytes past the IPv4 header, so the
        // header must be well-formed and the packet long enough to hold those two bytes.
        guard headerLength >= 20, packet.count >= headerLength + 2 else { return false }

        // A NON-FIRST FRAGMENT carries no transport header, so its source port is not a fact about
        // this packet at all — leave it excluded rather than read payload bytes as a port. A
        // fragmented DNS reply's tails reach here, and counting them would reopen the very
        // false-confirm the resolver exclusion exists to prevent.
        let fragmentOffset = ((UInt16(packet[6]) << 8) | UInt16(packet[7])) & 0x1FFF
        guard fragmentOffset == 0 else { return false }

        // Only UDP and TCP have transport ports, and both place the source port in the same two
        // bytes — so one read covers a UDP DNS reply and a DNS-over-TCP one alike. Any other
        // protocol (ICMP, and everything else) has no port 53 to be, so it is not a DNS reply;
        // it stays excluded here because this predicate answers "provably non-DNS", and a
        // portless protocol cannot be proven either way from its header.
        let protocolNumber = packet[9]
        guard protocolNumber == UInt8(IPPROTO_UDP) || protocolNumber == UInt8(IPPROTO_TCP) else {
            return false
        }

        let sourcePort = (UInt16(packet[headerLength]) << 8) | UInt16(packet[headerLength + 1])
        return sourcePort != dnsPort
    }
}
