import Foundation

/// The DNS destinations Lava claims **for interception only**, so a client that dials a
/// resolver address itself still reaches the filter instead of egressing around it.
///
/// ## Why this exists
///
/// A route the tunnel does not claim never enters the NE, so no interception the classifier
/// performs can apply to it (`INV-DNS-7`, ``DNSCaptureScope``). In a split tunnel that is the
/// documented `dnsOnly`-grade scope reduction for the *direct* portion of traffic — but it is
/// also a real filter escape when the destination is a name resolver: an app, or iOS itself,
/// querying a resolver the network advertised off-tunnel gets an unfiltered answer. Field
/// evidence (lavasec-infra `plans/2026-09-17-path-independent-dns-capture-floor.md`, 2026-09-17
/// and 2026-09-19) reproduces it on a dual-stack Wi-Fi whose resolvers are IPv6 and outside the
/// claimed prefixes; cellular, which advertised none of them, filtered normally.
///
/// A route claimed purely for interception costs the data path nothing: a query that enters the
/// NE on port 53 is answered by the in-tunnel proxy and never reaches the peer. The membership
/// rule is therefore narrow — and its premise is HONEST, not assumed: a destination qualifies
/// only if non-DNS traffic to it is nonexistent, droppable, or already carried. The curated
/// anycast resolvers below are the exception that proves the rule — several also serve HTTPS/DoH
/// on `:443` — so they are claimed by a CHAINED SPLIT plan only, where the packet enters the
/// classifier and non-DNS to a claimed resolver is a knowing, counted drop. They are NOT claimed
/// in DNS-only, whose packet loop has no forwarding rung and would silently drop that traffic
/// (the `https://1.1.1.1` breakage Kilo caught on PR #752). This type computes only the ROUTES,
/// leaving membership (which curated resolvers, whether to include the LAN gateway) to its
/// caller, per the plan's open decisions. Open decision 1 is resolved to EXCLUDE the on-link
/// gateway, and ``DNSCaptureFloorMembership`` is the pure helper that decides it; the caller
/// passes its output here.
///
/// F1 (`plans/2026-09-17-path-independent-dns-capture-floor.md`) supplies one membership source
/// itself: ``curatedPublicResolverAddresses``, the well-known anycast resolvers that qualify by
/// construction. The provider merges that set into a CHAINED SPLIT plan only (not DNS-only), so
/// an app hardcoded to `1.1.1.1` reaches the filter in a chained session even on a network that
/// advertised no such resolver — the escape the floor's captured-device-resolver half (F3b)
/// could not close. DNS-only's residual is stated with the caller: a hardcoded clear-text resolver
/// still escapes there, disclosed by F5, because a claim cannot be served on a path with no
/// forwarding rung.
///
/// ## Why `/32` and `/128`
///
/// A resolver is claimed as a host route, never a prefix: the claim is about one address that
/// answers DNS, and widening it would draw unrelated traffic into a tunnel that may not carry
/// it. IPv6 resolvers get `/128` for the same reason, and because the family is exactly what a
/// v4-only plan left escaping.
///
/// Pure policy, no provider state: the plan builder merges the result into
/// ``TunnelRoutePlan/includedIPv4Routes`` / ``TunnelRoutePlan/includedIPv6Routes``.
public enum DNSCaptureFloor {
    /// One resolver address to claim, tagged with the family that decides its prefix length.
    public struct HostRoute: Equatable, Sendable {
        /// The address family, which is also the prefix length the claim uses.
        public enum Family: Equatable, Sendable {
            /// A 4-byte address, claimed as a `/32`.
            case ipv4
            /// A 16-byte address, claimed as a `/128`.
            case ipv6
        }

        /// The resolver address, canonical (`inet_ntop` shape) — the caller's input, verbatim.
        public let address: String
        /// The address family, and therefore the prefix length.
        public let family: Family

        /// The host prefix for the family: `/32` for IPv4, `/128` for IPv6.
        public var prefixLength: Int {
            switch family {
            case .ipv4: return 32
            case .ipv6: return 128
            }
        }

        /// Creates a host route from a resolver address and its family.
        public init(address: String, family: Family) {
            self.address = address
            self.family = family
        }
    }

    /// The host routes for `resolverAddresses`, dropping unusable and duplicate entries.
    ///
    /// Unusable is the shared structural predicate (``DeviceDNSFallbackPolicy/isUsableResolverAddress``):
    /// unspecified, loopback, link-local and NAT64-mapped-unusable addresses can never answer a
    /// real query, so claiming one would only wedge the link. Order is preserved; the first
    /// occurrence of a duplicate wins.
    ///
    /// The tunnel's own DNS listener (``TunnelRoutePlan/dnsServerAddress``) is excluded: it is
    /// already reachable through the capture route, and re-claiming it would be noise.
    ///
    /// The caller owns membership and the upstream-collision question. This returns the routes;
    /// it does **not** decide whether Lava can still query these addresses on the physical
    /// interface once they are claimed (the plan's F2 prerequisite), so it must not be wired into
    /// ``TunnelRoutePlan`` without that half.
    public static func hostRoutes(forResolverAddresses resolverAddresses: [String]) -> [HostRoute] {
        var seen = Set<String>()
        var routes: [HostRoute] = []

        for address in resolverAddresses {
            // The tunnel's own listeners, in both families: already reachable through the
            // capture routes, and re-claiming one would draw our own proxy back in.
            guard address != TunnelRoutePlan.dnsServerAddress,
                  address != TunnelRoutePlan.chainedDNSServerIPv6Address else { continue }
            guard DeviceDNSFallbackPolicy.isUsableResolverAddress(address) else { continue }
            guard seen.insert(address).inserted else { continue }
            guard let family = family(of: address) else { continue }

            routes.append(HostRoute(address: address, family: family))
        }

        return routes
    }

    /// The well-known anycast public resolvers Lava claims as host routes in a CHAINED SPLIT
    /// plan (F3b's captured device resolvers ride beside them).
    ///
    /// ## Why a versioned in-tree constant
    ///
    /// F1 (`plans/2026-09-17-path-independent-dns-capture-floor.md`) closes the escape an app
    /// hardcoded to a public resolver opens: it dials `8.8.8.8` or `1.1.1.1` directly, and on a
    /// network that advertised no such resolver the floor had nothing to claim (F3b claims only
    /// the network's own captured resolvers), so the query egressed unfiltered. These addresses
    /// qualify by construction — the well-known anycast resolvers — so the provider merges them
    /// into the chained split plan whatever the network advertised.
    ///
    /// ## The stated cost: claimed in chained split, NOT in DNS-only
    ///
    /// The narrow-membership premise is weaker for this set than for the captured resolvers: a
    /// public resolver also serves HTTPS (and often DoH) on `:443`, and answers ICMP. Claiming one
    /// turns every such packet into a packet the NE must decide about. A CHAINED SPLIT plan is
    /// safe to claim it because the packet reaches ``ChainedOutboundPacketClassifier``, which
    /// knowingly drops and counts non-DNS to a claimed resolver (the plan's "droppable" membership
    /// arm) rather than pretending it is not there. A DNS-only plan is NOT safe: its packet loop
    /// handles only port-53 datagrams and has no forwarding rung, so a claim there silently drops
    /// `https://1.1.1.1`, QUIC, and ICMP. F1 was therefore scoped to the chained path (Kilo,
    /// PR #752): DNS-only's route array is unchanged, and a hardcoded clear-text resolver that is
    /// neither curated nor captured still escapes there — a disclosed residual (F5), not a claim.
    ///
    /// ## Why a constant, not a fetch
    ///
    /// Open decision 3 is resolved to a CONSTANT rather than a network fetch. The NE process lives
    /// under a ~50 MB jetsam ceiling (`INV-MEM-1`) and a boot start occurs before first unlock
    /// (`INV-PERSIST-1`); a fetched list would need both a resident copy and a reachable network,
    /// and would let a remote party re-shape the routes Lava claims. The cost, stated rather than
    /// hidden: a public resolver NOT listed here is not captured until a reviewed change widens
    /// this list and re-ships the app.
    ///
    /// ## Governance
    ///
    /// Entries are canonical `inet_ntop` form, lowercase. Widening is a deliberate, reviewed,
    /// VERSIONED change: add the provider's documented anycast addresses (both families together
    /// where it publishes a v6 pair) and re-run the floor tests. This set is never
    /// user-configurable and never fetched.
    public static let curatedPublicResolverAddresses: [String] = [
        // Google Public DNS
        "8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844",
        // Cloudflare
        "1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001",
        // Quad9
        "9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9",
        // OpenDNS (Cisco)
        "208.67.222.222", "208.67.220.220", "2620:119:35::35", "2620:119:53::53",
        // AdGuard DNS
        "94.140.14.14", "94.140.15.15", "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff",
        // Mullvad DNS
        "194.242.2.2", "194.242.2.3", "2a07:e340::2", "2a07:e340::3",
    ]

    /// Whether `address` is one of ``curatedPublicResolverAddresses``, compared over parsed bytes
    /// so equivalent IPv6 spellings match.
    ///
    /// The provider's floor-claim check (`PacketTunnelProvider.deviceResolverIsFloorClaimed`) asks
    /// this to decide whether Lava's own egress to a curated resolver must bind physically in a
    /// chained split (the only path that claims the curated set). A string compare would miss
    /// `2606:4700:4700:0:0:0:0:1111`, and a missed match leaves Lava's own query following the
    /// claimed route back into the tunnel — the strand F2 exists to prevent
    /// (``ResolverAddressIdentity``).
    public static func isCuratedPublicResolverAddress(_ address: String) -> Bool {
        curatedPublicResolverAddresses.contains {
            ResolverAddressIdentity.denotesSameAddress($0, address)
        }
    }

    /// The family `inet_pton` resolves `address` to, or `nil` when it parses as neither — or parses
    /// as an IPv4-mapped / IPv4-compatible literal, which the floor refuses.
    ///
    /// `DeviceDNSFallbackPolicy.isUsableResolverAddress` judges those literals by their IPv6 shape,
    /// which is routable, so a mapped LOOPBACK such as `::ffff:127.0.0.1` would otherwise be claimed
    /// as a `/128` — the shared predicate's reserved-range checks do not see the embedded IPv4. The
    /// floor claims a resolver as a client dials it, and a mapped or compatible form is not a
    /// resolver identity, so it is refused rather than claimed. (Kilo, PR #738.)
    private static func family(of address: String) -> HostRoute.Family? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return .ipv4
        }

        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }  // 16 bytes, network order
            return isMappedOrCompatibleIPv4Literal(bytes) ? nil : .ipv6
        }

        return nil
    }

    /// Whether a 16-byte IPv6 address is an IPv4-mapped (`::ffff:a.b.c.d`) or IPv4-compatible
    /// (`::a.b.c.d`, excluding `::` and `::1`) literal.
    ///
    /// Parsed from the bytes rather than string-matched, so every equivalent spelling is caught.
    private static func isMappedOrCompatibleIPv4Literal(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }

        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return true  // ::ffff:a.b.c.d
        }

        let compatible = bytes[0..<12].allSatisfy { $0 == 0 }
            && !bytes[12..<16].allSatisfy { $0 == 0 }  // not ::
            && !(bytes[12] == 0 && bytes[13] == 0 && bytes[14] == 0 && bytes[15] == 1)  // not ::1
        return compatible
    }
}

/// Which captured resolver addresses Lava may CLAIM on the DNS capture floor.
///
/// ## Why the on-link gateway is excluded
///
/// ``DNSCaptureFloor/hostRoutes(forResolverAddresses:)`` computes routes for whatever it is
/// handed; membership is the caller's. The plan's Open decision 1 resolved that membership to
/// EXCLUDE the on-link gateway. A device resolver capture routinely contains the LAN's gateway
/// address (the router that also answers DNS), and claiming the gateway as a `/32` or `/128`
/// host route would draw the user's general traffic to that router into the tunnel — with no
/// matching `AllowedIPs` the peer refuses it, so every other host behind the gateway becomes
/// unreachable. The gateway is also the address most likely to be shared with non-DNS traffic,
/// which the floor's own narrow-membership rule (non-DNS traffic to the address must be
/// nonexistent, droppable, or already carried) forbids.
///
/// ## Why the exclusion is range-based rather than by identity
///
/// `Network.NWPath` exposes no gateway address — it names the interfaces a path uses, not the
/// L2 next hop — so the path observer cannot hand the gateway's identity to the floor. The
/// conservative substitute excludes the ranges a private on-link gateway (and private resolvers
/// generally) occupy: RFC 1918 (`10/8`, `172.16/12`, `192.168/16`), IPv4 link-local
/// (`169.254/16`), IPv6 link-local (`fe80::/10`) and ULA (`fc00::/7`). The floor's own
/// structural predicate already drops the link-local ranges; they are named here too so the
/// exclusion reads as one complete rule. The accepted cost, stated rather
/// than hidden: a private resolver that is NOT the gateway (a Pi-hole at `192.168.1.53`) is
/// also excluded, so such a network loses that resolver's filtered capture — the plan's
/// documented acceptable coverage loss. Public resolvers are unaffected.
public enum DNSCaptureFloorMembership {
    /// `resolverAddresses` with the on-link-gateway-class ranges removed; order preserved.
    public static func claimableResolverAddresses(_ resolverAddresses: [String]) -> [String] {
        resolverAddresses.filter { !excludesAsOnLinkGatewayClass($0) }
    }

    /// Whether `address` sits in a range the on-link gateway (and private resolvers) occupy,
    /// and is therefore excluded from the floor. An unparseable address is NOT excluded here —
    /// the floor's structural predicate already drops it, and this helper must not become a
    /// second, silently-divergent validator.
    public static func excludesAsOnLinkGatewayClass(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let octets = withUnsafeBytes(of: v4) { Array($0) }  // network byte order == octet order
            if octets[0] == 10 { return true }                                  // 10/8
            if octets[0] == 172, (16...31).contains(Int(octets[1])) { return true }  // 172.16/12
            if octets[0] == 192, octets[1] == 168 { return true }               // 192.168/16
            if octets[0] == 169, octets[1] == 254 { return true }               // 169.254/16
            return false
        }

        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }  // 16 bytes, network order
            if bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0x80 { return true }  // fe80::/10 link-local
            if (bytes[0] & 0xfe) == 0xfc { return true }                    // fc00::/7 ULA
            return false
        }

        return false
    }
}
