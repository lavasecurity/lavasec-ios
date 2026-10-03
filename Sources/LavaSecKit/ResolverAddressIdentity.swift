import Darwin
import Foundation

/// Whether two textual IP literals name the same address, across equivalent spellings.
///
/// ## Why this exists, and why a string compare is not enough
///
/// F2/F3b make a socket's binding depend on whether a resolver destination is on the DNS capture
/// floor (``DNSCaptureFloor``). The two sides of that question come from different producers: the
/// endpoint was validated by `inet_pton` at `ResolverEndpoint` construction, while the captured
/// resolver address arrives from the system's resolver list. Both are canonical for the family
/// the producing API emits, but equivalent IPv6 spellings exist — `2606:4700:4700::1111` and
/// `2606:4700:4700:0:0:0:0:1111` are the same address — so a string equality can MISS a real
/// match. The consequence is a stranded query: the route IS claimed, so the socket left
/// `.systemChosen` would follow the routing table back into the tunnel and be refused by a peer
/// that does not carry the destination.
///
/// So the comparison is over PARSED BYTES, never strings, and families never cross: a 4-byte
/// literal is never equal to a 16-byte one, including an IPv4-mapped form. Either side failing to
/// parse is `false` — an unparseable literal is not evidence of a match, and treating it as one
/// would pin a socket for a destination we cannot even identify.
public enum ResolverAddressIdentity {
    /// Whether `lhs` and `rhs` parse to the same IPv4 or IPv6 address.
    public static func denotesSameAddress(_ lhs: String, _ rhs: String) -> Bool {
        var lhsV4 = in_addr()
        var rhsV4 = in_addr()
        let lhsIsV4 = inet_pton(AF_INET, lhs, &lhsV4) == 1
        let rhsIsV4 = inet_pton(AF_INET, rhs, &rhsV4) == 1
        if lhsIsV4 || rhsIsV4 {
            guard lhsIsV4, rhsIsV4 else { return false }
            return equalBytes(lhsV4, rhsV4)
        }

        var lhsV6 = in6_addr()
        var rhsV6 = in6_addr()
        guard inet_pton(AF_INET6, lhs, &lhsV6) == 1,
              inet_pton(AF_INET6, rhs, &rhsV6) == 1 else { return false }
        return equalBytes(lhsV6, rhsV6)
    }

    /// Byte-for-byte equality of two fixed-layout address values.
    private static func equalBytes<T>(_ lhs: T, _ rhs: T) -> Bool {
        withUnsafeBytes(of: lhs) { left in
            withUnsafeBytes(of: rhs) { right in
                left.elementsEqual(right)
            }
        }
    }
}
