import Foundation

/// Which data path the tunnel is running for this lifecycle.
///
/// Plan: lavasec-infra `plans/2026-07-22-vpn-upstream-chaining-implementation-plan.md` (D1).
///
/// The provider **latches** this once, in `loadInitialSharedState`, before network settings
/// are ever applied — and all settings installs (initial, startup DNS patch drain and
/// ordinary reapply) read the latch rather than live configuration. That is the whole point: a
/// running tunnel adopts `AppConfiguration` changes within ≤30–60 s through several
/// independent paths, so a chaining flag read live would let a mid-session write or a
/// network flap silently change what routes the tunnel claims.
public enum TunnelDataPathMode: Equatable, Sendable {
    /// Today's behaviour: claim only the tunnel's own /24 and filter DNS.
    case dnsOnly
    /// Filter DNS *and* forward traffic through a user-supplied WireGuard upstream.
    ///
    /// Full vs split is not a separate mode: it is the configuration's derived
    /// `routingPolicy`, and `TunnelRoutePlan.make` reads it to claim either the whole space
    /// (`0.0.0.0/0` + `::/0`) or only the `AllowedIPs` prefixes (the rest egressing direct).
    /// Both filter DNS on everything.
    ///
    /// Carries the resolved configuration, and that is the C7 coupling rather than a
    /// convenience: the route plan must claim the `[Interface]` Address the peer assigned
    /// (and, in split, the `AllowedIPs`), and a payload is what makes "chained mode with no
    /// configuration to claim from" unrepresentable. A parallel `latchedChainedConfiguration`
    /// property would be exactly that state, one missed assignment away.
    ///
    /// The payload is the NON-SECRET half only. The private key stays behind
    /// `ChainedUpstreamReadiness`, read again when a session is built — a latched mode is
    /// stored for the whole session and read from logs-adjacent code, which is no place for
    /// key material.
    case chainedUpstream(ChainedUpstreamConfiguration)

    /// Stable identifier for device logs. Never user copy.
    public var logValue: String {
        switch self {
        case .dnsOnly:
            return "dns-only"
        case .chainedUpstream:
            return "chained-upstream"
        }
    }

    /// Whether this session runs the chained data path, whatever it was configured with.
    ///
    /// The comparison most call sites actually mean. `==` now compares the payload too, so
    /// `mode == .chainedUpstream(someConfig)` would be a different — and almost always
    /// wrong — question: a session is chained by virtue of what it latched, not by whether
    /// its configuration matches the one the caller happens to hold.
    public var isChainedUpstream: Bool {
        if case .chainedUpstream = self { return true }
        return false
    }

    /// Whether this data path DROPS outbound IPv6 rather than carrying or forwarding it.
    ///
    /// True only for the FULL chained tunnel, which claims `::/0` and has no IPv6 upstream, so
    /// v6 entered the tunnel is dropped and clients must fall to IPv4. FALSE for split, since
    /// 2026-09-19 (F3b+F3c): split no longer claims `::/0`. It claims only the in-tunnel DNS
    /// server's on-link ULA plus any captured resolver host routes, so all other IPv6 egresses
    /// direct and is usable — the resolver is still filtered because the system resolver is
    /// served in-tunnel over both families, and the network's own resolvers are captured as
    /// host routes. FALSE for DNS-only, which claims no v6 and carries no traffic.
    ///
    /// This is the precise condition under which the resolver must answer AAAA with NODATA and
    /// strip `ipv6hint` — see `ChainedIPv6DNSPolicy`. It is deliberately not a property of the
    /// routing policy alone: it is the `::/0` claim, and only full tunnel makes that claim now.
    public var dropsOutboundIPv6: Bool {
        switch self {
        case .dnsOnly:
            return false
        case .chainedUpstream(let configuration):
            return configuration.effectiveRoutingPolicy == .fullTunnel
        }
    }
}

/// The routing shape the tunnel claims for a given data-path mode.
///
/// A pure description, deliberately free of `NetworkExtension` types so the decision is
/// testable without a tunnel process; the provider maps it onto
/// `NEPacketTunnelNetworkSettings` and decides nothing of its own. Keeping the *decision*
/// here and the *translation* there is what makes the DNS-only branch the single
/// description of the routing that shipped before chaining existed:
/// `TunnelRoutePlanSourceTests` pins that no routing literal has reappeared in the
/// provider, and the type system covers the rest.
public struct TunnelRoutePlan: Equatable, Sendable {
    /// One included route, expressed as address + mask exactly as `NEIPv4Route` wants it.
    public struct IPv4Route: Equatable, Sendable {
        public let destinationAddress: String
        public let subnetMask: String

        public init(destinationAddress: String, subnetMask: String) {
            self.destinationAddress = destinationAddress
            self.subnetMask = subnetMask
        }
    }

    /// One included IPv6 route, expressed as address + prefix length for `NEIPv6Route`.
    public struct IPv6Route: Equatable, Sendable {
        public let destinationAddress: String
        public let prefixLength: Int

        public init(destinationAddress: String, prefixLength: Int) {
            self.destinationAddress = destinationAddress
            self.prefixLength = prefixLength
        }
    }

    /// The address assigned to the tunnel interface.
    public let tunnelAddress: String
    /// The mask paired with `tunnelAddress`.
    public let tunnelSubnetMask: String
    /// The address the DNS proxy answers on, and the settings' remote address.
    public let dnsServerAddress: String
    /// The IPv6 address the DNS proxy answers on, advertised in `NEDNSSettings` beside
    /// ``dnsServerAddress`` so the system resolver is filtered over IPv6 as well as IPv4 —
    /// `nil` when the plan carries no IPv6 (DNS-only), in which case there is no route by which
    /// a v6 DNS server could be reached. See ``TunnelRoutePlan/chainedDNSServerIPv6Address``.
    public let dnsServerIPv6Address: String?
    /// Human-readable summary of the claimed routes, used in logs and health state.
    public let routeDescription: String
    /// Routes the tunnel claims. DNS-only claims its /24 plus any capture-floor v4 host routes a
    /// caller merges in (production passes none — the floor is chained-only); split claims the
    /// `AllowedIPs` plus the DNS routes and the floor; full tunnel claims the whole space and
    /// ignores the floor.
    public let includedIPv4Routes: [IPv4Route]
    /// Destinations kept on the physical network; empty in ordinary production plans.
    public let excludedIPv4Routes: [IPv4Route]
    /// The IPv6 address assigned to the tunnel interface, or `nil` when the mode claims
    /// no IPv6 at all.
    public let tunnelIPv6Address: String?
    /// Prefix length paired with `tunnelIPv6Address`.
    public let tunnelIPv6PrefixLength: Int?
    /// IPv6 routes the tunnel claims. Empty means iOS leaves IPv6 on the physical
    /// interface: a leak in FULL tunnel (which claims all IPv4 and must not leave IPv6
    /// outside), and closed in split tunnel since 2026-09-19, which claims `::/0` to
    /// blackhole v6 rather than leave a network's v6 resolvers answerable outside the
    /// filter. DNS-only claims no IPv6 and leaves it on the ordinary physical path. See
    /// ``leaksIPv6AroundTheTunnel``.
    public let includedIPv6Routes: [IPv6Route]
    /// IPv6 destinations kept on the physical network, including in the QA DNS-only comparison.
    public let excludedIPv6Routes: [IPv6Route]
    /// Interface MTU.
    public let mtu: Int
    /// Whether this plan takes the whole IPv4 space. An included default route with
    /// exclusions does not establish full coverage; conservatively reject that claim.
    public var claimsDefaultRoute: Bool {
        excludedIPv4Routes.isEmpty
            && includedIPv4Routes.contains { $0.destinationAddress == "0.0.0.0" && $0.subnetMask == "0.0.0.0" }
    }

    /// Which clear-text DNS this plan's routes let the tunnel see (`INV-DNS-7`).
    ///
    /// Derived from ``claimsDefaultRoute`` rather than from the mode, because the capture set
    /// IS the route set: a destination this plan does not claim never reaches the NE, so no
    /// interception the classifier performs can apply to it. See ``DNSCaptureScope`` for why
    /// split tunnel and DNS-only share one scope and full tunnel does not.
    /// pinned: DNSCaptureScopeTests.testTheScopeIsDerivedFromTheRoutesEachDataPathClaims
    public var dnsCaptureScope: DNSCaptureScope {
        DNSCaptureScope.forRoutePlan(self)
    }

    /// Whether this plan takes the whole IPv6 space, without excluded destinations.
    /// Derived for the same reason as ``claimsDefaultRoute``.
    public var claimsIPv6DefaultRoute: Bool {
        excludedIPv6Routes.isEmpty
            && includedIPv6Routes.contains { $0.prefixLength == 0 && Self.isUnspecifiedIPv6Address($0.destinationAddress) }
    }

    /// Whether a textual IPv6 address is the unspecified address, however it is spelled.
    ///
    /// `::` has many equivalent forms — `::0`, `0::0`, `0:0:0:0:0:0:0:0` — and a literal
    /// string compare recognizes exactly one. That matters here because the comparison
    /// decides whether the plan claims the IPv6 default route, and a plan that DOES claim
    /// it but spells it differently would be read as leaking. Parsed rather than
    /// pattern-matched, so every spelling the OS accepts is recognized.
    static func isUnspecifiedIPv6Address(_ address: String) -> Bool {
        var bytes = in6_addr()
        guard inet_pton(AF_INET6, address, &bytes) == 1 else { return false }
        return withUnsafeBytes(of: &bytes) { raw in raw.allSatisfy { $0 == 0 } }
    }

    /// The `NEIPv4Route` (network address + dotted mask) for an `address/length` IPv4 prefix,
    /// masked to its network so `10.1.2.3/8` and `10.0.0.0/8` claim the same block — the same
    /// masking `ChainedAllowedIPs` applies inbound. `nil` for anything that is not an IPv4
    /// prefix (an IPv6 entry, or a malformed one), so the split builder can `compactMap` a
    /// mixed list; in practice the configuration boundary has already refused a split config
    /// carrying a v6 or malformed `AllowedIPs`, so the filter is a defensive no-op there.
    static func ipv4Route(fromPrefix prefix: String) -> IPv4Route? {
        let parts = prefix.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let length = Int(parts[1]), (0...32).contains(length),
              let value = ipv4Value(String(parts[0])) else { return nil }
        // `length == 0` is guarded away from a shift by the full 32-bit width (undefined in
        // Swift). Split never reaches it — a /0 covers the default route, so that config is a
        // full tunnel — but the guard keeps this helper total.
        let maskBits: UInt32 = length == 0 ? 0 : (~UInt32(0) << (32 - length))
        let network = value & maskBits
        return IPv4Route(
            destinationAddress: Self.dottedQuad(network),
            subnetMask: Self.dottedQuad(maskBits))
    }

    /// The 32-bit value of a canonical dotted-quad IPv4 literal, or `nil`. The prefixes that
    /// reach here are already validated by the configuration boundary, so this is a parse,
    /// not a validator — `nil` only defends the `compactMap` above.
    private static func ipv4Value(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = (value << 8) | UInt32(octet)
        }
        return value
    }

    /// A 32-bit value as a dotted quad.
    private static func dottedQuad(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    /// The `(DNS capture)` fragment `routeDescription` appends for the capture-floor host
    /// routes the plan claims — `9.9.9.9/32`, `2606:4700:4700::1111/128` — so a device log can
    /// confirm the floor is installed beside the capture subnet. Empty when the floor added
    /// nothing, so the default-empty `make(for:)` description is byte-for-byte unchanged.
    private static func captureFloorDescription(_ hostRoutes: [DNSCaptureFloor.HostRoute]) -> [String] {
        guard !hostRoutes.isEmpty else { return [] }
        let addresses = hostRoutes
            .map { "\($0.address)/\($0.prefixLength)" }
            .joined(separator: ", ")
        return ["\(addresses) (DNS capture)"]
    }

    /// True when the plan carries the whole IPv4 space but leaves IPv6 on the physical
    /// interface — the shape of an IPv6 leak in FULL tunnel.
    ///
    /// Named so a test can assert its absence rather than enumerating routes. Scoped to full
    /// tunnel by the `claimsDefaultRoute` term, and that scoping is the point: a full tunnel
    /// promises to carry everything, so claiming all IPv4 while leaving IPv6 direct is traffic
    /// escaping the tunnel the user turned on. A SPLIT tunnel does not claim the whole IPv4
    /// space (its `AllowedIPs` leave a gap, so `claimsDefaultRoute` is false), so this returns
    /// false for it — and since 2026-09-19 split no longer claims `::/0` either: it claims only
    /// its in-tunnel DNS server's on-link ULA `/64`, so the `false` is about the IPv4 term alone
    /// and general v6 is direct by design. (INV-CHAIN-1 split clause, amended by the owner on
    /// 2026-09-19 and again by F3b+F3c; lavasec-infra
    /// `plans/2026-09-17-path-independent-dns-capture-floor.md`.)
    /// pinned: TunnelRoutePlanTests.testSplitLeavesGeneralIPv6DirectWhileStillCarryingItsDNSBlock
    ///
    /// Keyed on the ROUTE CLAIM alone, which is the question it is named for and not the whole
    /// of "IPv6 cannot escape". A plan can claim `::/0` and still have no IPv6 installed, because
    /// the provider needs an address and prefix length too — see ``installsIPv6Settings``. That
    /// combination is unreachable from ``make``, so this predicate is never wrong about a plan
    /// the tunnel actually runs; a caller reasoning about an ARBITRARY plan needs both terms
    /// (`DNSCaptureScope.forRoutePlan`, Codex PR #728).
    public var leaksIPv6AroundTheTunnel: Bool {
        claimsDefaultRoute && !claimsIPv6DefaultRoute
    }

    /// Whether the provider will actually install IPv6 settings for this plan.
    ///
    /// Mirrors the exact `if let` in `PacketTunnelProvider.makeTunnelNetworkSettings`: iOS gets
    /// `NEIPv6Settings` only when the plan carries an address, a prefix length AND at least one
    /// route. Miss any one and `ipv6Settings` stays nil, which the provider's own comment calls
    /// what it is — "IPv6 stays on the physical interface and leaves the device outside the
    /// tunnel the user turned on".
    ///
    /// So a route array is a claim, not an installation, and a coverage statement has to read
    /// both.
    ///
    /// This is NOT `true` for every plan the tunnel runs, and the precise claim matters: `make`
    /// leaves all three absent for DNS-only, which claims no IPv6 and is `false` here by design;
    /// full tunnel and (since 2026-09-19) split both set all three. What `make` never produces
    /// is the MIXED shape — some of the three present and some missing — so this term never
    /// narrows a `make`-built plan that already claims both default routes. Only the public
    /// initializer reaches the inconsistent shape, which is what this exists to catch
    /// (Kilo, PR #728).
    /// pinned: DNSCaptureScopeTests.testTheIPv6InstallabilityTermMirrorsTheProviderCondition
    public var installsIPv6Settings: Bool {
        tunnelIPv6Address != nil && tunnelIPv6PrefixLength != nil && !includedIPv6Routes.isEmpty
    }

    /// Whether this plan's MTU is legal for the address families it claims.
    ///
    /// Only meaningful once IPv6 is claimed — a plan carrying no IPv6 has no floor to meet at
    /// the PLAN level, which is why DNS-only at 1280 passes. Split now claims `::/0` (2026-09-19)
    /// so `carriesIPv6` is true and the floor binds there too; the configuration boundary already
    /// refuses a sub-1280 split MTU, so a split plan reaching the floor is always legal.
    public var mtuIsLegalForClaimedFamilies: Bool {
        carriesIPv6 ? mtu >= Self.minimumIPv6LinkMTU : true
    }

    /// Whether the interface carries IPv6 at all — an address, any route, or both.
    ///
    /// Keyed on PRESENCE, not on the default route. RFC 8200's floor applies to a link
    /// that carries IPv6, not to one that carries all of it, so a partial-route mode with
    /// an IPv6 address and a /64 would be equally out of spec at 1200 while a
    /// default-route-only test waved it through. Checking the specific shape the current
    /// factory happens to emit is how a guard passes while the invariant it names is
    /// violated.
    public var carriesIPv6: Bool {
        tunnelIPv6Address != nil || !includedIPv6Routes.isEmpty
    }

    /// Address of the tunnel interface in DNS-only mode.
    ///
    /// This used to claim "in every mode — chaining does not renumber the tunnel", and C7
    /// falsified it: chained mode's interface address is the `[Interface]` Address the
    /// peer assigned, carried in `ChainedUpstreamConfiguration.clientAddress`, because the
    /// peer accepts inner packets only from the source its AllowedIPs for this client
    /// permit. What still holds in every mode is the DNS proxy's address below.
    public static let dnsOnlyTunnelAddress = "10.255.0.2"
    /// Address the local DNS proxy answers on, in every mode.
    public static let dnsServerAddress = "10.255.0.1"
    /// MTU for the DNS-only path — unchanged from the pre-chaining tunnel.
    public static let dnsOnlyMTU = 1280

    /// The `/24` containing the DNS proxy (``dnsServerAddress``), as a device log spells it.
    ///
    /// This is the DNS-CAPTURE route: `NEDNSSettings` points the system resolver at
    /// 10.255.0.1, and claiming a route that covers it is what draws those queries into the
    /// NE to be filtered. In dns-only it doubles as the tunnel's own on-link subnet; in split
    /// tunnel it is purely the capture route, claimed BESIDE the `AllowedIPs` prefixes so DNS
    /// stays filtered on everything while the rest egresses direct. Full tunnel needs no
    /// separate entry — its `0.0.0.0/0` already covers 10.255.0.1.
    public static let dnsCaptureRouteDescription = "10.255.0.0/24"
    /// The DNS-capture route as address + mask. Shared by dns-only and split so the two
    /// cannot spell the same capture subnet differently. See ``dnsCaptureRouteDescription``.
    static let dnsCaptureIPv4Route = IPv4Route(
        destinationAddress: "10.255.0.0", subnetMask: "255.255.255.0")

    /// The smallest link MTU IPv6 permits (RFC 8200 §5).
    ///
    /// A hard floor, not a tuning knob: an interface carrying IPv6 below this is out of
    /// spec, and iOS may refuse the settings outright rather than degrade.
    public static let minimumIPv6LinkMTU = 1280

    /// Worst-case bytes WireGuard adds around an inner packet: outer IPv6 header (40) +
    /// UDP (8) + the engine's transport overhead (32).
    public static let encapsulationOverhead = 80

    /// The tunnel's IPv6 address in chained mode, and its prefix length.
    ///
    /// A locally-assigned ULA (`fd00::/8`, RFC 4193) rather than anything routable: the
    /// interface needs *an* IPv6 address before iOS will install an IPv6 route, but this
    /// address is never a source for traffic that leaves the device — chained mode claims
    /// IPv6 in order to DROP it, not to carry it.
    public static let chainedTunnelIPv6Address = "fd00:1a7a::2"
    /// The on-link network the chained tunnel's ULA addresses live in. Claimed as a route in
    /// split so the in-tunnel IPv6 DNS server (``chainedDNSServerIPv6Address``) is reachable
    /// without a default route, while all other IPv6 egresses direct (F3c).
    public static let chainedTunnelIPv6Network = "fd00:1a7a::"
    /// Prefix length paired with ``chainedTunnelIPv6Address``.
    public static let chainedTunnelIPv6PrefixLength = 64

    /// The IPv6 address the in-tunnel DNS proxy answers on, in the same on-link ULA block as
    /// ``chainedTunnelIPv6Address`` so it is reachable without a default route.
    ///
    /// Advertised in `NEDNSSettings` beside ``dnsServerAddress`` in every chained shape. It is
    /// what lets the system resolver stay filtered over IPv6 without claiming `::/0`: the
    /// client's v6 queries reach this address through the tunnel's on-link `/64`, are parsed by
    /// ``IPv6UDPDNSPacket`` and answered by the same filter as IPv4 (F3c).
    public static let chainedDNSServerIPv6Address = "fd00:1a7a::1"

    /// Builds the plan for `mode`.
    ///
    /// The chained case fans out on the configuration's derived `routingPolicy`: full tunnel
    /// (claim `0.0.0.0/0` + `::/0`) or split tunnel (claim only the `AllowedIPs` prefixes plus
    /// the DNS-capture route; the rest, IPv6 included, egresses direct). Plan: lavasec-infra
    /// `#198` §3.
    ///
    /// - Important: this default-empty call must keep producing exactly the settings the
    ///   tunnel claimed before chaining existed. `INV-DNS-1` (filtering never fails open)
    ///   is enforced on that path, and every field here feeds the routes the system
    ///   installs — a drift would change production behaviour for every user who never
    ///   enables chaining, including the ones who never see a chaining toggle at all.
    ///   F1's curated floor is merged by the PROVIDER (which calls the other overload), not
    ///   here, so the empty call stays the pre-chaining plan byte-for-byte.
    public static func make(for mode: TunnelDataPathMode) -> TunnelRoutePlan {
        make(for: mode, dnsCaptureResolverAddresses: [])
    }

    /// Builds the plan with the DNS capture floor merged in (F1/F3b).
    ///
    /// - Parameter dnsCaptureResolverAddresses: the resolver addresses to claim as `/32` and
    ///   `/128` host routes so a client that dials one itself still reaches the filter
    ///   (``DNSCaptureFloor``). Full tunnel ignores them — it already claims every destination.
    ///   The default-empty `make(for:)` is byte-for-byte the plan that shipped before the floor
    ///   existed, which is what keeps the DNS-only pins honest.
    /// - Parameter capturesIPv6InDNSOnly: enables IPv6 settings for explicit DNS-only host routes
    ///   in the bounded QA comparison. Normal DNS-only callers leave it false; no default IPv6
    ///   route or IPv6 DNS server is added by this option.
    /// - Parameter advertisesIPv6DNSInDNSOnly: QA comparison advertising the local IPv6
    ///   DNS proxy and its ULA route. It adds no internet default route or carrier resolver.
    /// - Parameter declaresDefaultRoutesInDNSOnly: QA comparison declaring default routes
    ///   while excluding every destination except the two local DNS hosts. Ignores carrier
    ///   overrides and never changes a chained plan or claims full traffic coverage.
    ///
    /// - Important: production (`PacketTunnelProvider.makeTunnelNetworkSettingsForLatchedDataPath`)
    ///   passes F1's curated public-resolver set AND F3b's CAPTURED device resolvers for a CHAINED
    ///   path only, and `[]` for DNS-only. DNS-only is deliberately kept unwired (Kilo, PR #752):
    ///   a claim there would draw a resolver's non-53 traffic (HTTPS/QUIC `:443`, ICMP) into a path
    ///   with no forwarding rung and silently drop it. F2's
    ///   `ChainedResolverEgressPolicy.destinationSocketBinding` keeps Lava's own egress to a
    ///   claimed address on the physical interface — which is what makes the chained claim safe
    ///   rather than stranding.
    public static func make(
        for mode: TunnelDataPathMode,
        dnsCaptureResolverAddresses: [String],
        capturesIPv6InDNSOnly: Bool = false,
        advertisesIPv6DNSInDNSOnly: Bool = false,
        declaresDefaultRoutesInDNSOnly: Bool = false
    ) -> TunnelRoutePlan {
        if declaresDefaultRoutesInDNSOnly, !mode.isChainedUpstream {
            return dnsOnlyDefaultRouteExperiment()
        }
        let captureFloor = DNSCaptureFloor.hostRoutes(forResolverAddresses: dnsCaptureResolverAddresses)
        let captureIPv4HostRoutes = captureFloor.filter { $0.family == .ipv4 }
        let captureIPv6HostRoutes = captureFloor.filter { $0.family == .ipv6 }
        let captureIPv4Routes = captureIPv4HostRoutes
            .map { IPv4Route(destinationAddress: $0.address, subnetMask: "255.255.255.255") }
        let captureIPv6Routes = captureIPv6HostRoutes
            .map { IPv6Route(destinationAddress: $0.address, prefixLength: $0.prefixLength) }

        switch mode {
        case .dnsOnly:
            let dnsIPv6Routes = advertisesIPv6DNSInDNSOnly ? [IPv6Route(
                destinationAddress: chainedTunnelIPv6Network,
                prefixLength: chainedTunnelIPv6PrefixLength)] : []
            let ipv6Routes = dnsIPv6Routes + (capturesIPv6InDNSOnly ? captureIPv6Routes : [])
            return TunnelRoutePlan(
                tunnelAddress: dnsOnlyTunnelAddress,
                tunnelSubnetMask: "255.255.255.0",
                dnsServerAddress: dnsServerAddress,
                dnsServerIPv6Address: advertisesIPv6DNSInDNSOnly ? chainedDNSServerIPv6Address : nil,
                // The tunnel's own /24 — which is also the DNS-capture route (it contains the
                // proxy at 10.255.0.1). Split reuses the same constant for capture beside its
                // AllowedIPs, so the two paths cannot describe the subnet differently. A caller
                // that DOES merge capture-floor v4 host routes (production passes none here) has
                // them named too, since the description must reflect every route the plan claims
                // (the v6 ones are dropped here).
                routeDescription: ([dnsCaptureRouteDescription]
                    + (advertisesIPv6DNSInDNSOnly
                        ? ["\(chainedTunnelIPv6Network)/\(chainedTunnelIPv6PrefixLength) (DNS v6)"] : [])
                    + Self.captureFloorDescription(captureIPv4HostRoutes
                        + (capturesIPv6InDNSOnly ? captureIPv6HostRoutes : [])))
                    .joined(separator: ", "),
                // Any capture-floor v4 resolvers ride here, before the DNS-only v6 question is
                // answered: claiming a v6 /128 needs installed v6 settings, which DNS-only has
                // none of by design (INV-DNS-1), so a v6 floor entry is deliberately dropped here.
                // Production passes `[]` (the floor is chained-only, Kilo PR #752); this arm
                // remains the plan's capability, not its live wiring.
                includedIPv4Routes: [dnsCaptureIPv4Route] + captureIPv4Routes,
                // Production DNS-only keeps its existing shape. The opt-in comparison adds
                // only the explicit resolver /128s; it cannot forward general IPv6 traffic.
                tunnelIPv6Address: ipv6Routes.isEmpty ? nil : chainedTunnelIPv6Address,
                tunnelIPv6PrefixLength: ipv6Routes.isEmpty ? nil : chainedTunnelIPv6PrefixLength,
                includedIPv6Routes: ipv6Routes,
                mtu: dnsOnlyMTU
            )
        case .chainedUpstream(let configuration):
            // Full vs split is DERIVED into the configuration's `routingPolicy` from its
            // `AllowedIPs` shape (`ChainedUpstreamConfiguration`); the plan reads it here.
            // The config is the immutable latched payload, so selecting on it means no live
            // re-read can change what the tunnel claims mid-session (INV-CHAIN-1). Plan:
            // lavasec-infra `#198` §3 (§3.1 Option A; §3.3 founder-signed decisions).
            switch configuration.effectiveRoutingPolicy {
            case .fullTunnel:
                // Claiming the default route is what makes chained mode a VPN rather than a
                // DNS proxy. It is also why the latch refuses this mode unless the upstream
                // config parses and the secret is readable *now*: a tunnel that claims
                // 0.0.0.0/0 and cannot forward is a blackhole, not a degraded state.
                //
                // The TUNNEL ADDRESS is the configured `[Interface]` Address, not the DNS-only
                // 10.255.0.2 (C7). A WireGuard peer accepts a client's inner packets only from
                // the source its AllowedIPs for that client permit, so an interface numbered
                // 10.255.0.2 has every encapsulated packet silently dropped at the far end —
                // after the tunnel reports established, with 0.0.0.0/0 claimed.
                // pinned: ChainedConfiguredInterfaceTests.testTheConfiguredAddressIsTheInnerSourceOfAnEmittedPacket
                //
                // The mask is /32, and that is a decision rather than a default. The config
                // carries a bare host address — chained staging NORMALISES any `/0`…`/32` prefix
                // to the bare host before this plan ever sees it — and with 0.0.0.0/0 claimed the
                // interface subnet decides nothing about routing — every destination enters the
                // tunnel regardless. A wider mask would only ADD a claim: that the surrounding
                // subnet is on-link, which the peer never said. That the plan reinstalls /32 here
                // is exactly why staging can subsume a file's `/24` down to the bare host.
                //
                // The DNS proxy stays at 10.255.0.1 and deliberately does NOT move into the
                // configured subnet. It does not need to be on-link: queries reach it through
                // the default route the plan claims. "The resolver is no longer on-link" is
                // the plausible-looking reason someone re-couples these — the plan names it so
                // it is not re-invented.
                //
                // MTU is the configured `[Interface] MTU` when present, else the IPv6 minimum
                // (D5). The configuration boundary refuses a sub-1280 value outright — this
                // plan always claims ::/0, and RFC 8200 §5 makes 1280 the smallest legal value
                // for a link carrying IPv6 — so the floor cannot be undercut from here. (The
                // earlier hardcoded derivation `dnsOnlyMTU - encapsulationOverhead` = 1200
                // confused the inner and outer budgets; see testTheEncapsulatedPacketStill-
                // FitsTheEngineDatagramCeiling for the arithmetic that actually binds.)
                //
                // The FLOOR is enforced: a plan carrying IPv6 must run at least 1280.
                // pinned: TunnelRoutePlanTests.testEveryModeRunsALegalMTUForWhatItClaims
                //
                // The rest of the MTU contract is NOT enforced, and the pin above must not be
                // read as covering it. Phase 3 may lower the MTU from a negotiated path MTU only
                // while the plan claims no IPv6, and must never raise it — neither clause is
                // exercised by any test, because negotiation does not exist yet and every MTU
                // above the floor satisfies the predicate the pin runs. It is a requirement on
                // the slice that adds negotiation, not a property of the current factory.
                return TunnelRoutePlan(
                    tunnelAddress: configuration.clientAddress,
                    tunnelSubnetMask: "255.255.255.255",
                    dnsServerAddress: dnsServerAddress,
                    dnsServerIPv6Address: chainedDNSServerIPv6Address,
                    // Both families, because this string is what the device log reports as the
                    // claimed route. Saying only "0.0.0.0/0" while ::/0 is also installed would
                    // hide the single fact a field log needs to confirm the IPv6 fail-closed
                    // behaviour is actually engaged.
                    routeDescription: "0.0.0.0/0, ::/0",
                    includedIPv4Routes: [
                        IPv4Route(destinationAddress: "0.0.0.0", subnetMask: "0.0.0.0")
                    ],
                    // Claim IPv6 in order to DROP it. Claiming only 0.0.0.0/0 on a dual-stack
                    // network leaves IPv6 application traffic on the physical interface, so it
                    // would leave the device outside the VPN entirely — in a privacy feature
                    // that is a leak, not a missing feature.
                    //
                    // Claiming ::/0 with no IPv6 upstream is what makes it fail CLOSED: the
                    // packets enter the tunnel and are dropped, and Happy Eyeballs moves the
                    // connection to IPv4, which the tunnel does carry. That is standard
                    // WireGuard-client behaviour for a peer with no IPv6 AllowedIPs.
                    //
                    // Until the data path forwards IPv6, dropping is the whole implementation.
                    // The engine already reports decrypted v6 separately
                    // (LAVA_WG_OP_WRITE_TO_TUNNEL_V6), so the forwarding half is a later
                    // slice — but the CLAIM cannot wait for it, because without it the leak
                    // exists the moment chained mode becomes reachable.
                    tunnelIPv6Address: chainedTunnelIPv6Address,
                    tunnelIPv6PrefixLength: chainedTunnelIPv6PrefixLength,
                    includedIPv6Routes: [IPv6Route(destinationAddress: "::", prefixLength: 0)],
                    mtu: configuration.effectiveInterfaceMTU
                )
            case .splitTunnel:
                // Split tunnel (infra #198 §3, Option A, founder-signed §3.3). Claim ONLY the
                // configured `AllowedIPs` prefixes plus the DNS-capture route: everything
                // outside them never enters the NE, so iOS routes it DIRECT on the physical
                // interface. The classifier/runner/data-path policy need no change — direct
                // traffic is invisible to them (Option B's userspace re-injection was rejected
                // on INV-MEM-1). The `AllowedIPs` are guaranteed a non-empty set of IPv4-only
                // prefixes here: the configuration boundary derives `.splitTunnel` only for
                // that shape and refuses a v6 `AllowedIPs` entry (which would egress direct).
                //
                // The tunnel address and /32 mask are the full-tunnel decision unchanged (C7):
                // the peer accepts inner packets only from the source its AllowedIPs permit,
                // and `clientAddressCollidesWithTunnelDNS` already keeps it off the proxy.
                //
                // DNS is still filtered on EVERYTHING THIS PLAN CLAIMS — which is the whole
                // of `INV-DNS-7`, and why the scope is DERIVED from the routes (`dnsCaptureScope`,
                // `DNSCaptureScope`) rather than asserted per mode. `NEDNSSettings` points the
                // system resolver at 10.255.0.1 (`matchDomains=[""]`, applied in the provider), and
                // the DNS-capture route below draws those queries into the NE exactly as
                // dns-only does — so system-resolver DNS is captured and filtered identically.
                // (A raw socket to a hardcoded resolver at a DIRECT destination egresses
                // unfiltered: dns-only-grade for the direct portion, the signed-off INV-DNS-1
                // scope of §3.3, not a regression.)
                //
                // IPv6 IS SERVED, NOT BLACKHOLED (F3b+F3c, 2026-09-19). A plan that claims no
                // IPv6 route leaves a dual-stack network's IPv6 DNS on the physical interface,
                // where a client, or the OS itself, can resolve a name outside the filter (field
                // evidence, plans/2026-09-17-path-independent-dns-capture-floor.md). The earlier
                // answer was to claim `::/0` and drop all of it — but on a v6-preferring network
                // that is a visible connectivity regression: cached AAAA, QUIC/HTTP3-over-v6
                // sockets and v6-only resources stall before Happy Eyeballs falls back (field
                // data, rc5, 2026-09-19).
                //
                // So split claims only what it must: the in-tunnel DNS server's on-link ULA
                // `/64`. The system resolver is advertised over both families in `NEDNSSettings`
                // and served by the in-tunnel filter, so a client DNS query over v6 is parsed
                // (`IPv6UDPDNSPacket`) and filtered rather than dropped, while all other IPv6
                // egresses direct and stays usable. F3b — capturing the network's own resolvers
                // as `/128` host routes — is WIRED for a chained path: the addresses are merged
                // below, so an app hardcoded to the network's v6 resolver reaches the filter, and
                // F2 pins Lava's own egress to a claimed address on the physical interface. An
                // app hardcoded to a resolver the network did NOT advertise still escapes, the
                // same ceiling split already has for hardcoded IPv4 resolvers. The interface
                // still carries the ULA, so `carriesIPv6` is true and the RFC 8200 floor binds
                // the MTU.
                let allowedIPv4Routes = configuration.capturedAllowedIPs.compactMap(Self.ipv4Route(fromPrefix:))
                return TunnelRoutePlan(
                    tunnelAddress: configuration.clientAddress,
                    tunnelSubnetMask: "255.255.255.255",
                    dnsServerAddress: dnsServerAddress,
                    dnsServerIPv6Address: chainedDNSServerIPv6Address,
                    // What a device log reports as claimed: the tunneled prefixes, the DNS-capture
                    // routes for both families, the capture floor's host routes, then an explicit
                    // note that the rest of either family is direct — so a field log can confirm
                    // the split shape installed.
                    routeDescription: (configuration.capturedAllowedIPs
                        + [
                            "\(dnsCaptureRouteDescription) (DNS)",
                            "\(chainedTunnelIPv6Network)/\(chainedTunnelIPv6PrefixLength) (DNS v6)",
                        ]
                        + Self.captureFloorDescription(captureIPv4HostRoutes + captureIPv6HostRoutes)
                        + ["rest IPv4/v6 direct"])
                        .joined(separator: ", "),
                    includedIPv4Routes: allowedIPv4Routes + [dnsCaptureIPv4Route] + captureIPv4Routes,
                    tunnelIPv6Address: chainedTunnelIPv6Address,
                    tunnelIPv6PrefixLength: chainedTunnelIPv6PrefixLength,
                    includedIPv6Routes: [
                        IPv6Route(
                            destinationAddress: chainedTunnelIPv6Network,
                            prefixLength: chainedTunnelIPv6PrefixLength)
                    ] + captureIPv6Routes,
                    // The configuration boundary already refuses a sub-1280 MTU in both modes,
                    // so any configured value here is >= 1280; absent MTU defaults to 1280.
                    mtu: configuration.effectiveInterfaceMTU
                )
            }
        }
    }

    public init(
        tunnelAddress: String,
        tunnelSubnetMask: String,
        dnsServerAddress: String,
        dnsServerIPv6Address: String? = nil,
        routeDescription: String,
        includedIPv4Routes: [IPv4Route],
        tunnelIPv6Address: String? = nil,
        tunnelIPv6PrefixLength: Int? = nil,
        includedIPv6Routes: [IPv6Route] = [],
        mtu: Int,
        excludedIPv4Routes: [IPv4Route] = [],
        excludedIPv6Routes: [IPv6Route] = []
    ) {
        self.tunnelAddress = tunnelAddress
        self.tunnelSubnetMask = tunnelSubnetMask
        self.dnsServerAddress = dnsServerAddress
        self.dnsServerIPv6Address = dnsServerIPv6Address
        self.routeDescription = routeDescription
        self.includedIPv4Routes = includedIPv4Routes
        self.excludedIPv4Routes = excludedIPv4Routes
        self.tunnelIPv6Address = tunnelIPv6Address
        self.tunnelIPv6PrefixLength = tunnelIPv6PrefixLength
        self.includedIPv6Routes = includedIPv6Routes
        self.excludedIPv6Routes = excludedIPv6Routes
        self.mtu = mtu
    }
}
