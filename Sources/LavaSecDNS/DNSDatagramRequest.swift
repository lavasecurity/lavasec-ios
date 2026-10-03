import Foundation

/// A parsed UDP DNS datagram captured from the tunnel's virtual interface, whatever its
/// address family.
///
/// The DNS filter's decision path (bootstrap > pause > filter) and the upstream relay are
/// family-agnostic — they read the DNS payload and address the reply back. This protocol is
/// the one seam that lets both the IPv4 and IPv6 admission gates feed that single path, so a
/// query captured over IPv6 is answered with the same bytes as one captured over IPv4
/// (F3c, lavasec-infra `plans/2026-09-17-path-independent-dns-capture-floor.md`).
///
/// Deliberately narrow: the plumbing only ever needs the payload and the write-back. The
/// address and port fields stay `package` on each concrete type, so widening this protocol
/// cannot widen their access.
public protocol DNSDatagramRequest: Sendable {
    /// The raw DNS message carried by the datagram.
    var dnsPayload: Data { get }
    /// Builds a complete response datagram for this request carrying `dnsPayload`.
    ///
    /// Returns `nil` when the payload would overflow the family's length field.
    func response(dnsPayload: Data) -> Data?
}

/// Parses `packet` as a UDP DNS datagram of either family, whichever it is.
///
/// The one admission entry point for the family-agnostic DNS path: both the DNS-only read
/// loop and the chained serving seam call this, so an IPv6 query is parsed and filtered
/// exactly as an IPv4 one is (F3c).
public func parseDNSDatagram(_ packet: Data) -> (any DNSDatagramRequest)? {
    if let ipv4 = IPv4UDPDNSPacket(packet) {
        return ipv4
    }
    if let ipv6 = IPv6UDPDNSPacket(packet) {
        return ipv6
    }
    return nil
}
