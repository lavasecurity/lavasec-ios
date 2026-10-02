import CryptoKit
import Foundation

/// Whether a chained upstream carries all of a device's traffic or only part of it.
///
/// DERIVED from the validated IPv4 `AllowedIPs` shape, never chosen by a caller and never
/// parsed from a `.conf` directive (there is none):
///
/// - ``fullTunnel`` when the IPv4 `AllowedIPs` COVER the default route `0.0.0.0/0` — the
///   upstream carries every destination, and the route plan claims `0.0.0.0/0` + `::/0`.
/// - ``splitTunnel`` when the IPv4 `AllowedIPs` are a non-empty set of well-formed IPv4
///   prefixes that do NOT cover the default route — the upstream carries only those
///   prefixes, non-`AllowedIPs` IPv4 leaves DIRECT on the physical interface, and DNS is
///   filtered on everything the plan captures. The plan also claims `::/0` to DROP IPv6, so
///   a network's v6 resolvers cannot answer outside the filter.
///
/// The two modes are disjoint by route set: a "split" config that happens to cover the
/// default route IS a full tunnel and derives ``fullTunnel``. A config that leaves the data
/// path no usable IPv4 inner route (empty, or IPv6-only) is refused, not assigned a policy.
///
/// Plan: lavasec-infra `#198` (§3 — Slice 2 added the type; Slice 3 makes split routable).
public enum ChainedRoutingPolicy: String, Codable, Sendable {
    /// The upstream carries every destination — the IPv4 `AllowedIPs` cover the default route.
    case fullTunnel
    /// The upstream carries only the `AllowedIPs` prefixes; the rest egresses direct.
    case splitTunnel
}

/// The user's WireGuard peer, validated.
///
/// Plan: lavasec-infra `plans/2026-07-22-vpn-upstream-chaining-implementation-plan.md`
/// (D5). This is the non-secret half of a chained upstream — where to send encapsulated
/// traffic and which peer key authenticates it. The private key and any preshared key are
/// Keychain-held and referenced, never carried here: a value type gets copied, logged,
/// encoded and diffed, and every one of those is a way for key material to escape.
///
/// ## Where this may be stored, and where it may not
///
/// It does **not** belong in `AppConfiguration`. That file is control-plane and carries
/// `NSFileProtectionNone` (`INV-PERSIST-2`) so DNS filtering can boot before first unlock
/// — a deliberate at-rest trade for filter selections and rules, which the invariant
/// describes as holding "no browsing history".
///
/// An upstream endpoint is a different kind of fact: it names the server a user routes all
/// of their traffic through. It belongs with the privacy stores, at the iOS default Class C.
/// Nothing is lost by that, because chained mode cannot start pre-unlock anyway — the
/// private key is Keychain `AfterFirstUnlockThisDeviceOnly`, so the latch resolves DNS-only
/// until first unlock regardless. There is no boot benefit to trade for.
///
/// Only the `chainedUpstreamEnabled` flag lives in the control plane, because the latch
/// reads it at start and a boolean preference reveals nothing about where traffic goes.
public struct ChainedUpstreamConfiguration: Equatable, Sendable, Codable {
    /// Hostname or IP literal of the peer. Resolved at session start, not here.
    public let endpointHost: String
    /// User-facing identity. Never contains imported configuration content.
    public let displayName: String
    /// Saved participation in the VPN stack; disabled rows keep their credentials.
    public let isEnabled: Bool
    // Immutable packet-dispatch ranges; rebuilt only when a profile is created/decoded.
    private let ipv4RouteRanges: [ClosedRange<UInt64>]
    /// At most one preceding profile. This value retains row 2 metadata; the stack derives capture and DNS separately.
    public let precedingHops: [ChainedUpstreamConfiguration]
    /// Selected rows, preserving saved order; an empty selection leaves routing OFF.
    // pinned: ChainedUpstreamKeychainStoreTests.testRowActivationSelectsMatchingRuntimeCredentialsAndPreservesDisabledSecrets
    public var activeConfiguration: Self? {
        get throws {
            let rows = try orderedHops.filter(\.isEnabled).map { try $0.withoutEntryHop() }
            guard let last = rows.last else { return nil }
            return rows.count == 2 ? try last.withEntryHop(rows[0]) : last
        }
    }
    /// Changes participation without exposing or replacing stored secrets.
    public func enabled(_ value: Bool) throws -> Self {
        try copying(displayName: displayName, precedingHops: precedingHops, isEnabled: value)
    }
    /// Shared interface MTU fits both profiles and reserves nested overhead only for a full first row.
    public var effectiveInterfaceMTU: Int {
        let requested = interfaceMTU.map(Int.init) ?? 1280
        guard let entry = precedingHops.first else { return requested }
        if entry.routingPolicy == .splitTunnel { return min(requested, Int(entry.interfaceMTU ?? 1280)) }
        return min(requested, ((Int(entry.interfaceMTU ?? 1420) - 60) / 16) * 16)
    }
    /// Saved order, from the device outward.
    public var orderedHops: [ChainedUpstreamConfiguration] { precedingHops + [self] }
    /// Physical DNS fallback is forbidden if either hop requires full-tunnel privacy.
    public var containsFullTunnel: Bool {
        routingPolicy == .fullTunnel || precedingHops.contains { $0.routingPolicy == .fullTunnel }
    }
    /// The installed capture policy covers every profile, independently of row order.
    public var effectiveRoutingPolicy: ChainedRoutingPolicy { containsFullTunnel ? .fullTunnel : .splitTunnel }
    /// Only a full first profile carries the second profile's encrypted connection.
    public var usesNestedTransport: Bool { precedingHops.first?.routingPolicy == .fullTunnel }
    /// User destinations captured by the whole stack; authored per-peer lists stay intact.
    public var capturedAllowedIPs: [String] { orderedHops.flatMap(\.allowedIPs) }
    /// A stable destination decision, never a health/failure fallback.
    // pinned: ChainedStackRoutingTests.testOrderedDestinationsAndOverlappingSplitsAreDeterministic
    public func routeIndex(forIPv4 address: UInt32) -> Int? {
        func contains(_ profile: Self) -> Bool {
            profile.ipv4RouteRanges.contains { $0.contains(UInt64(address)) }
        }
        guard let first = precedingHops.first else { return contains(self) ? 0 : nil }
        if first.routingPolicy == .fullTunnel { return contains(self) ? 1 : 0 }
        if contains(first) { return 0 }
        return contains(self) ? 1 : nil
    }
    /// General DNS follows the full profile, or the exit for two full profiles.
    /// Two split profiles use the first row. This is not domain-specific DNS routing.
    public var stackDNSProfileIndex: Int {
        guard !precedingHops.isEmpty else { return 0 }
        if routingPolicy == .fullTunnel { return 1 }
        return 0
    }
    /// Provider-authored resolver addresses selected for the stack's general DNS.
    public var stackDNSAddresses: [String] { orderedHops[stackDNSProfileIndex].dnsAddresses }
    /// Builds a two-hop chain without changing either provider's AllowedIPs.
    public func withEntryHop(_ entry: ChainedUpstreamConfiguration) throws -> Self {
        try copying(displayName: displayName, precedingHops: [entry])
    }
    /// A saved row can be renamed without making its secret available to an editor.
    public func named(_ name: String) throws -> Self {
        try copying(displayName: name, precedingHops: precedingHops)
    }
    /// The exit as an independent profile, used when explicitly removing the entry row.
    public func withoutEntryHop() throws -> Self {
        try copying(displayName: displayName, precedingHops: [])
    }
    private func copying(displayName: String, precedingHops: [Self], isEnabled: Bool? = nil) throws -> Self {
        try Self(endpointHost: endpointHost, endpointPort: endpointPort, peerPublicKey: peerPublicKey,
            clientAddress: clientAddress, allowedIPs: allowedIPs, persistentKeepaliveSeconds: persistentKeepaliveSeconds,
            interfaceMTU: interfaceMTU, dnsAddresses: dnsAddresses, displayName: displayName, precedingHops: precedingHops, isEnabled: isEnabled ?? self.isEnabled)
    }
    /// UDP port of the peer.
    public let endpointPort: UInt16
    /// The peer's public key, base64 as WireGuard writes it. Public by design — it
    /// authenticates the peer, it does not authorize anyone.
    public let peerPublicKey: String
    /// Seconds between keepalives, or `0` for off.
    public let persistentKeepaliveSeconds: UInt16

    /// The client's own address inside the tunnel, from the config's `[Interface] Address`.
    ///
    /// Carried rather than reused from `TunnelRoutePlan.dnsOnlyTunnelAddress`, and that is
    /// forced by the protocol rather than chosen. A WireGuard peer accepts a client's inner
    /// packets only from the source its own AllowedIPs for that client permits; sending from
    /// this app's DNS-only tunnel address (`10.255.0.2`) would have the peer drop everything,
    /// and there would be no local symptom — the tunnel is up, the handshake completed, and
    /// packets simply never come back. The chained route plan claims exactly this address as
    /// the interface's own (C7).
    ///
    /// The alternative — keeping `10.255.0.2` on the interface and NAT-rewriting the inner
    /// source on every packet — was rejected on `INV-MEM-1`: it is a per-packet rewrite plus a
    /// checksum recomputation on the hot path, to avoid carrying one string.
    ///
    /// IPv4 only. The inner data path forwards IPv4 and claims `::/0` in order to DROP IPv6
    /// in both modes, so in neither mode is a v6 client address a source this data path
    /// forwards from.
    public let clientAddress: String

    /// The prefixes the peer routes to this client, from the config's `[Peer] AllowedIPs`.
    ///
    /// Stored as written so a device log can be compared against the file the user pasted.
    /// Their SHAPE also decides the routing mode: whether the IPv4 prefixes cover the default
    /// route selects full vs split tunnel (``routingPolicy``), and in split mode these same
    /// prefixes are the exact set the route plan claims — see ``routingPolicy`` and
    /// `TunnelRoutePlan.make(for:)`.
    public let allowedIPs: [String]

    // THE TUNNEL NEVER WIDENS `allowedIPs`, and there is no longer a field recording that it
    // might. `fallbackResolverRoutes` held the `/32` routes this app added at latch time so the
    // tunnel would CARRY the user's chosen alternative DNS, and `openingRoutes(forFallbackResolvers:)`
    // was its only writer.
    //
    // Both are gone (the plan's S3). Routing a public resolver through the peer made T1 depend
    // on that peer being an exit node — configuration we neither control nor can detect, and which
    // rc9 (build 1787723354) measured as three attempts dropped with nothing coming back. The
    // T1 rung egresses on the PHYSICAL interface in a split tunnel since PR #590, so it needs
    // no route from the tunnel at all, and the user's intent the widening served is better met:
    // load a profile, pick a resolver, and both work with no profile edit.
    //
    // What goes with them is worth naming, because it was the sharpest hazard in this type: the
    // widening had to compare the derived `routingPolicy` before and after, since `AllowedIPs`
    // exclusion decompositions are an ordinary WireGuard idiom and a host route filling the
    // excluded hole promotes a split tunnel to a full one — all of the user's traffic captured
    // and their IPv6 blackholed because they chose an alternative DNS (Codex, PR #584). No
    // widening, no promotion to guard against.
    //
    // `asAuthored` went with the field it stripped, and `resolverSelectionFingerprint` now
    // fingerprints `allowedIPs` directly. Both were no-ops over a permanently empty set.


    /// The interface MTU from the config's `[Interface] MTU`, or `nil` when the file
    /// carries none — in which case the route plan runs the IPv6 minimum, 1280 (D5).
    ///
    /// A sub-1280 value is refused at this boundary rather than clamped downstream, in BOTH
    /// modes: both claim `::/0`, so RFC 8200 §5's floor applies to each; and
    /// `ChainedPacketQueueLimits.forChainedTunnel` independently rejects a lower MTU, which
    /// would otherwise downgrade the profile to DNS-only. It refuses rather than
    /// clamps: clamping would install an interface whose advertised MTU disagrees with
    /// the file the user is debugging against. There is no upper validation bound: the provider already
    /// holds the installed value under the engine's own per-packet ceiling
    /// (`engineSafeMTU`), which is the one limit this module cannot see.
    public let interfaceMTU: UInt16?

    /// The resolvers from the config's `[Interface] DNS`, stored as written (S6).
    ///
    /// While chained is latched these are the SOLE DNS egress — plain UDP through the
    /// session — so a config that carries none cannot serve DNS at all and readiness
    /// refuses to latch it (`ChainedUpstreamReadiness`). Empty means the file carried no
    /// `DNS =` line, which is the ordinary shape for configs written before this field
    /// existed and for peers that expect the client to bring its own resolver — chained
    /// mode has none to bring, which is why absence is a readiness refusal rather than a
    /// validation failure here.
    ///
    /// Validation is well-formedness only: every entry must be an IP literal (either
    /// family, stored as the file spells it). USABILITY — the IPv4-only rule the data path
    /// imposes, the addresses that mean local delivery instead of egress — is selection,
    /// not validation, and lives with readiness so its rules sit next to the consumer that
    /// depends on them.
    public let dnsAddresses: [String]

    /// How this configuration routes traffic: full tunnel or split tunnel.
    ///
    /// DERIVED from the validated IPv4 `AllowedIPs`, not parsed and not chosen by a caller.
    /// There is no `routingPolicy` `.conf` directive and the staging parser never sets it.
    /// The initializer computes it from the prefix set: covering the default route yields
    /// ``ChainedRoutingPolicy/fullTunnel``, a non-empty non-covering set of IPv4 prefixes
    /// yields ``ChainedRoutingPolicy/splitTunnel``, and a set with no usable IPv4 inner route
    /// is refused (see ``ValidationFailure``). It is a PURE FUNCTION of `allowedIPs`, so a
    /// persisted value cannot contradict the routes — ``init(from:)`` re-derives it on decode
    /// rather than trusting the stored key. Stored (and encoded) as a diagnostic: a device
    /// log names the mode without recomputing coverage.
    public let routingPolicy: ChainedRoutingPolicy

    /// Why a supplied upstream is not usable. Log/health identifiers, never user copy.
    public enum ValidationFailure: String, Error, Equatable, Sendable {
        /// The host was empty, over-long, or carried a scheme, path, or whitespace.
        case malformedEndpointHost
        /// Port 0 is not a destination.
        case invalidEndpointPort
        /// The client address was absent, not an IPv4 literal, or not a usable host address.
        case malformedClientAddress
        /// An AllowedIPs entry was not a prefix this parser recognises.
        case malformedAllowedIPs
        /// The `AllowedIPs` carried no prefix at all — a peer that routes nothing.
        ///
        /// Distinct from ``ipv6OnlyUpstreamUnsupported`` (which carries prefixes, just no
        /// usable IPv4 one) so a device log names the actual shape. Not
        /// ``malformedAllowedIPs``: an empty set is well-formed, it is just non-functional.
        case allowedIPsEmpty
        /// The `AllowedIPs` carry IPv6 prefixes (e.g. `::/0`) but no IPv4 prefix.
        ///
        /// The inner data path is IPv4-only, so there is no IPv4 prefix to install as an
        /// inner route and nothing this upstream could actually carry. A truthful surface for
        /// an IPv6-only upstream — the earlier coverage check reported the misdirecting
        /// "AllowedIPs omit the default route" for this (infra `#198` §2 gap #11 / P12), when
        /// the file DOES carry a default, just the v6 one. Full tunnel keeps accepting a v6
        /// prefix ALONGSIDE a covering v4 set (`0.0.0.0/0, ::/0`): there the v6 half is stored
        /// but inert, blackholed by the `::/0` claim. This refuses only the case with no v4 at all.
        case ipv6OnlyUpstreamUnsupported
        /// A split-tunnel `AllowedIPs` set that also carries an IPv6 prefix.
        ///
        /// Split tunnel's IPv6 is the plan's OWN `::/0` blackhole (see ``TunnelRoutePlan``), not
        /// the profile's: the data path carries no IPv6, so a v6 `AllowedIPs` entry could never
        /// be honored and the inner route it names would be unreachable. Refused rather than
        /// dropped or silently ignored (infra `#198` §3.4 open-Q #3). Full tunnel keeps
        /// accepting a v6 prefix beside a covering v4 set, where the same `::/0` claim owns it.
        case splitTunnelCarriesIPv6AllowedIPs
        /// The client address is the tunnel's own DNS proxy address, `10.255.0.1`.
        ///
        /// Refused because it kills DNS rather than chaining: if the interface OWNS the
        /// address the DNS settings point at, the OS treats every query to it as local
        /// delivery instead of routing it into the tunnel, so interception never sees it.
        /// Unrepresentable while the tunnel address was hardcoded; carrying the configured
        /// address (C7) is what makes the collision possible, so the boundary that admits
        /// the address is the boundary that refuses this one value of it.
        case clientAddressCollidesWithTunnelDNS
        /// A configured `[Interface] MTU` below 1280. Refused in BOTH modes on the same
        /// constant: both claim `::/0`, so 1280 is the smallest legal IPv6 link (RFC 8200 §5);
        /// and `ChainedPacketQueueLimits.forChainedTunnel` independently rejects any MTU below
        /// `minimumIPv6LinkMTU`, so a sub-1280 config could never run in either mode.
        case mtuBelowIPv6Floor
        /// A `DNS =` entry that is not an IP literal.
        ///
        /// Hostnames are refused deliberately, not merely unimplemented: resolving a
        /// resolver's name needs a resolver, and while chained the only one is the thing
        /// being configured — the bootstrap deadlock `ChainedEndpointResolutionPlan`
        /// documents for the endpoint, without the endpoint's excuse.
        case malformedDNSAddress
        /// The key was not base64, or did not decode to exactly 32 bytes.
        case malformedPeerPublicKey
        /// The key decoded to the right length but cannot authenticate a peer — currently
        /// only the all-zero key, which is what an unfilled config template contains.
        case unusablePeerPublicKey
        /// A keepalive short enough to hold the radio awake.
        case keepaliveTooFrequent
    }

    /// The WireGuard public-key length. The engine reads 32 bytes unconditionally, so a
    /// short key is an over-read at the FFI boundary rather than a rejected argument.
    public static let publicKeyByteCount = 32

    /// The WireGuard private-key length. X25519 keys are 32 bytes, secret and public alike.
    ///
    /// Lives beside the public one so the WRITE boundary in this module
    /// (`ChainedUpstreamRotation.init`) and the READINESS gate in `LavaSecChainedUpstream`
    /// share one constant; the latter derives from this rather than carrying its own copy.
    public static let privateKeyByteCount = 32

    /// The WireGuard pre-shared-key length. A PSK is a symmetric 32-byte secret mixed into the
    /// handshake, so it is the same width as the X25519 keys — but a SEPARATE constant, because
    /// the two are conceptually distinct and a future protocol change to one must not silently
    /// move the other. Mirrors ``privateKeyByteCount``: the write boundary
    /// (`ChainedUpstreamRotation.init`) and the staging parser both size the PSK against this,
    /// and the engine (`WireGuardSession.init`) enforces the same 32 at the FFI boundary.
    public static let presharedKeyByteCount = 32

    /// Shortest accepted non-zero keepalive, in seconds.
    ///
    /// Not a protocol limit — WireGuard permits any interval. It is a battery one. Each
    /// keepalive wakes the cellular radio, and wake churn is the mechanism behind this
    /// app's one confirmed thermal report (UR-53), where sustained warmth traced to wake
    /// frequency rather than to work done. A misconfigured 1-second keepalive would be
    /// indistinguishable to the user from "chaining makes my phone hot".
    public static let minimumKeepaliveSeconds: UInt16 = 5

    /// Validates and stores an upstream.
    ///
    /// Rejecting here is what lets the rest of the data path assume its inputs. The engine
    /// is a C ABI over Rust that panics on some malformed arguments — in release, inside a
    /// Network Extension, that is a tunnel abort rather than an exception — so the boundary
    /// where bad input stops has to be before the engine, not inside it.
    public init(
        endpointHost: String,
        endpointPort: UInt16,
        peerPublicKey: String,
        clientAddress: String,
        allowedIPs: [String],
        persistentKeepaliveSeconds: UInt16 = 0,
        interfaceMTU: UInt16? = nil,
        dnsAddresses: [String] = [],
        displayName: String = "",
        precedingHops: [ChainedUpstreamConfiguration] = [],
        isEnabled: Bool = true
        // No `routingPolicy` parameter: the policy is DERIVED from the `AllowedIPs` shape
        // below, never chosen by a caller. A parameter would let a caller assert a policy the
        // routes contradict, which is exactly the silent mis-route these validations exist to
        // prevent. `init(from:)` re-derives on decode rather than trusting the persisted key.
    ) throws {
        guard precedingHops.count <= 1, precedingHops.allSatisfy({ $0.precedingHops.isEmpty }) else {
            throw WireGuardChainFailure.tooManyHops
        }
        if isEnabled, let entry = precedingHops.first, entry.isEnabled {
            guard Self.isIPLiteral(entry.endpointHost) else { throw WireGuardChainFailure.entryRequiresLiteralEndpoint }
            if entry.routingPolicy == .fullTunnel {
                guard Self.ipv4Octets(endpointHost) != nil else { throw WireGuardChainFailure.exitRequiresIPv4Endpoint }
                if let mtu = entry.interfaceMTU, mtu < 1340 { throw WireGuardChainFailure.entryMTUTooSmall }
            }
        }
        self.displayName = String(displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.precedingHops = precedingHops
        self.isEnabled = isEnabled
        let host = endpointHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPlausibleEndpointHost(host) else {
            throw ValidationFailure.malformedEndpointHost
        }
        guard endpointPort != 0 else {
            throw ValidationFailure.invalidEndpointPort
        }
        guard let decodedKey = Self.decodedPublicKey(peerPublicKey),
              decodedKey.count == Self.publicKeyByteCount else {
            throw ValidationFailure.malformedPeerPublicKey
        }
        guard !Self.isSmallOrderPoint(decodedKey) else {
            throw ValidationFailure.unusablePeerPublicKey
        }
        guard persistentKeepaliveSeconds == 0 || persistentKeepaliveSeconds >= Self.minimumKeepaliveSeconds else {
            throw ValidationFailure.keepaliveTooFrequent
        }

        let address = clientAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isUsableClientAddress(address) else {
            throw ValidationFailure.malformedClientAddress
        }
        guard address != TunnelRoutePlan.dnsServerAddress else {
            throw ValidationFailure.clientAddressCollidesWithTunnelDNS
        }
        let prefixes = allowedIPs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard prefixes.allSatisfy(Self.isPlausiblePrefix) else {
            throw ValidationFailure.malformedAllowedIPs
        }

        // Derive the routing mode from the (well-formed) prefix set. The order is
        // deliberate — coverage first, then the reasons a non-covering set is unroutable —
        // and each branch is mutually exclusive, so the derived policy is a pure function of
        // `AllowedIPs`. Plan: lavasec-infra `#198` §3.2/§3.3 (founder-signed §3.3 decisions).
        let ipv4Prefixes = prefixes.filter { Self.ipv4Block($0) != nil }
        let policy: ChainedRoutingPolicy
        if Self.coversIPv4DefaultRoute(prefixes) {
            // Full tunnel: the IPv4 prefixes span the whole space (a literal `0.0.0.0/0` or
            // the two-halves idiom). A v6 prefix may ride alongside; the `::/0` claim
            // blackholes it, so it is stored inert.
            policy = .fullTunnel
        } else if ipv4Prefixes.isEmpty {
            // Nothing the IPv4-inner data path can carry. Empty is a peer that routes
            // nothing; a non-empty v6-only set (e.g. `::/0`) is an IPv6-only upstream. Both
            // get a truthful surface rather than the misdirecting "omits the default route".
            throw prefixes.isEmpty
                ? ValidationFailure.allowedIPsEmpty
                : ValidationFailure.ipv6OnlyUpstreamUnsupported
        } else if ipv4Prefixes.count != prefixes.count {
            // A routable IPv4 split set that ALSO carries a v6 prefix. Split's IPv6 is the
            // route plan's own `::/0` blackhole, not the profile's, so that v6 entry could
            // never be honored. Refuse it (open-Q #3), rather than silently dropping the v6 half.
            throw ValidationFailure.splitTunnelCarriesIPv6AllowedIPs
        } else {
            // A non-empty set of IPv4 prefixes that leaves a gap in the 32-bit space: a
            // genuine split tunnel. The route plan claims exactly these IPv4 prefixes, plus
            // the DNS-capture /24 and `::/0` to drop IPv6; everything else egresses direct.
            policy = .splitTunnel
        }

        // The 1280 floor binds BOTH modes, for two reasons that happen to share the constant.
        // Both modes claim `::/0`, so RFC 8200 §5 makes 1280 the smallest legal IPv6 link for
        // each. `ChainedPacketQueueLimits.forChainedTunnel` independently rejects any MTU below
        // `minimumIPv6LinkMTU`, and the session factory then DOWNGRADES the profile to DNS-only,
        // so a sub-1280 config would latch and never run. Refusing here keeps this boundary
        // aligned with what the session factory can actually build, rather than accepting a
        // value that silently degrades. (Codex #546 P2.)
        if let mtu = interfaceMTU, Int(mtu) < TunnelRoutePlan.minimumIPv6LinkMTU {
            throw ValidationFailure.mtuBelowIPv6Floor
        }
        let resolvers = dnsAddresses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard resolvers.allSatisfy(Self.isIPLiteral) else {
            throw ValidationFailure.malformedDNSAddress
        }

        self.endpointHost = host
        self.endpointPort = endpointPort
        self.peerPublicKey = peerPublicKey
        self.clientAddress = address
        self.allowedIPs = prefixes
        self.ipv4RouteRanges = prefixes.compactMap(Self.ipv4Block).map { $0.start...$0.end }
        self.persistentKeepaliveSeconds = persistentKeepaliveSeconds
        self.interfaceMTU = interfaceMTU
        self.dnsAddresses = resolvers
        // Derived above from `allowedIPs`, never taken from a caller: a policy that could
        // disagree with the routes is the silent mis-route this type exists to preclude.
        // Stored (and encoded) purely as a diagnostic; `init(from:)` re-derives it.
        self.routingPolicy = policy
    }

    /// Decodes through the validating initializer.
    ///
    /// Without this, synthesized `Decodable` assigns the stored properties directly and the
    /// throwing initializer above is never called — so the type's whole claim, that it
    /// cannot exist in an invalid state, holds only for values built in memory and not for
    /// any value that has been round-tripped through disk. Persisted configuration is
    /// exactly where a stale or hand-edited value comes from, so that is the path that most
    /// needs checking, and it was the one path skipping the check.
    ///
    /// `ValidationFailure` propagates rather than being wrapped in `DecodingError`: a
    /// caller loading a saved upstream wants to know the key is unusable, not that byte 42
    /// was unexpected.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            endpointHost: container.decode(String.self, forKey: .endpointHost),
            endpointPort: container.decode(UInt16.self, forKey: .endpointPort),
            peerPublicKey: container.decode(String.self, forKey: .peerPublicKey),
            // Required, not `decodeIfPresent` with a default. A default would be a client
            // address nobody chose and a peer will not accept, reintroducing the silent
            // failure these fields exist to prevent.
            //
            // There IS persisted configuration now — `ChainedUpstreamKeychainStore` commits
            // this type inside its envelope — so the compatibility argument that used to
            // finish this comment ("no production conformer exists yet") no longer holds and
            // a future field must be added compatibly. What the revalidation on this path
            // means in practice is worth stating: a validator that TIGHTENS can turn a
            // configuration that was valid when written into one that no longer decodes, and
            // the store reports that as `configurationUnusable` (re-enter it) rather than as
            // an unreadable store (retry later).
            clientAddress: container.decode(String.self, forKey: .clientAddress),
            allowedIPs: container.decode([String].self, forKey: .allowedIPs),
            persistentKeepaliveSeconds: container.decode(
                UInt16.self, forKey: .persistentKeepaliveSeconds),
            // `decodeIfPresent`, unlike the client address above, because absence MEANS
            // something here: a config file with no `[Interface] MTU` line is the ordinary
            // case and the route plan's 1280 default is the documented answer to it (D5).
            // This is also what keeps a configuration committed before this field existed
            // decodable — the compatibility obligation the comment above records.
            interfaceMTU: container.decodeIfPresent(UInt16.self, forKey: .interfaceMTU),
            // `decodeIfPresent` for the same compatibility obligation the MTU records: a
            // configuration committed before this field existed must keep decoding, and its
            // absence MEANS "no DNS = line" — readiness turns that into a latch refusal
            // (S6), which is the correct failure surface for a config that cannot serve
            // chained DNS; `configurationUnusable` ("re-enter it") is not.
            dnsAddresses: container.decodeIfPresent([String].self, forKey: .dnsAddresses) ?? [],
            displayName: container.decodeIfPresent(String.self, forKey: .displayName) ?? "",
            precedingHops: container.decodeIfPresent([Self].self, forKey: .precedingHops) ?? [],
            isEnabled: container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
            // `routingPolicy` is deliberately NOT decoded: it is a pure function of
            // `allowedIPs`, and the throwing initializer re-derives it. This is stronger than
            // `decodeIfPresent ?? .fullTunnel` — a persisted (or tampered) policy that
            // disagreed with the routes could not survive, and a configuration committed
            // before the key existed decodes with no special case because the key is ignored.
        )
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, precedingHops, isEnabled
        case endpointHost
        case endpointPort
        case peerPublicKey
        case clientAddress
        case allowedIPs
        case persistentKeepaliveSeconds
        case interfaceMTU
        case dnsAddresses
        case routingPolicy
    }

    /// Whether `address` is an IPv4 literal usable as this client's own tunnel address.
    ///
    /// ROUTABLE UNICAST only. The first version of this rule excluded just `0.0.0.0` and
    /// `255.255.255.255` and justified itself with "what a half-filled config template
    /// produces" — which was the right reasoning applied to two values out of four ranges.
    /// Loopback, link-local and multicast are equally what a hand-edited or
    /// copied-from-a-tutorial config produces, and none of them is a source a peer will
    /// accept for forwarded traffic. A config carrying one can be stored, can report ready,
    /// and then carries nothing.
    ///
    /// Private ranges (10/8, 172.16/12, 192.168/16) are deliberately NOT excluded: a
    /// WireGuard peer assigning its clients addresses out of one is the ordinary case, not a
    /// mistake.
    private static func isUsableClientAddress(_ address: String) -> Bool {
        guard let octets = ipv4Octets(address) else { return false }
        // 0.0.0.0/8 — "this network", including the unspecified address.
        if octets[0] == 0 { return false }
        // 127.0.0.0/8 — loopback.
        if octets[0] == 127 { return false }
        // 169.254.0.0/16 — link-local, what a host assigns itself when configuration failed.
        if octets[0] == 169 && octets[1] == 254 { return false }
        // 224.0.0.0/4 multicast, 240.0.0.0/4 reserved, and 255.255.255.255 broadcast, which
        // is the top of that range rather than a separate case.
        if octets[0] >= 224 { return false }
        return true
    }

    /// Whether `prefix` parses as a prefix the data path can actually represent.
    ///
    /// PARSED, not pattern-matched. Two earlier versions checked punctuation — first for a
    /// colon, then for a colon and a slash — and both were the same mistake at different
    /// resolutions: `foo:/bar`, `::/129` and `::/` all carry the right characters and none is
    /// a prefix. That matters more than it looks, because `ChainedIPPrefix`
    /// (`Sources/LavaSecChainedUpstream/ChainedAllowedIPs.swift`) DOES reject them, so this
    /// boundary was able to store a configuration and report it ready for data the
    /// representation downstream cannot parse. A validator that is looser than the thing it
    /// guards is not a validator.
    ///
    /// IPv6 is validated exactly as the data path validates it: `inet_pton` for the address,
    /// `0...128` for the length. IPv6 traffic is still never forwarded — chained mode claims
    /// `::/0` in order to drop it — but "we do not carry this" is not a reason to accept
    /// nonsense describing it.
    ///
    /// IPv4 stays on this file's own octet parser rather than `inet_pton`, deliberately: the
    /// platform's `inet_pton` accepts leading zeros on Darwin, and rejecting `010.0.0.0/8` is
    /// the single-spelling rule this type committed to a few lines up. Stricter than the data
    /// path is safe in a way that looser is not.
    ///
    /// A LENGTH IS REQUIRED for both families, which is stricter than `ChainedIPPrefix`
    /// (where a bare address means the full-width prefix). Every AllowedIPs entry a WireGuard
    /// config writes carries one, and requiring it removes the "is `10.0.0.0` a host or a
    /// /32?" reading from a field a device log is compared against.
    private static func isPlausiblePrefix(_ prefix: String) -> Bool {
        let parts = prefix.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let addressText = String(parts[0])
        let lengthText = String(parts[1])
        // Canonical decimal length, for the same reason the octets are: `/08` and `/8` must
        // not be two spellings of one prefix.
        guard !lengthText.isEmpty, lengthText.allSatisfy(\.isNumber),
              lengthText.count == 1 || lengthText.first != "0",
              let length = Int(lengthText) else {
            return false
        }
        if addressText.contains(":") {
            var parsed = in6_addr()
            guard inet_pton(AF_INET6, addressText, &parsed) == 1 else { return false }
            return (0...128).contains(length)
        }
        guard ipv4Octets(addressText) != nil else { return false }
        return (0...32).contains(length)
    }

    /// Whether `text` is an IP literal of either family, in the spellings this boundary
    /// accepts: the canonical dotted quad for IPv4 (same parser, same leading-zero rule as
    /// every other IPv4 field here) or anything Darwin's `inet_pton` takes for IPv6 —
    /// matching `isPlausiblePrefix`'s family split exactly, minus the length.
    private static func isIPLiteral(_ text: String) -> Bool {
        if text.contains(":") {
            var parsed = in6_addr()
            return inet_pton(AF_INET6, text, &parsed) == 1
        }
        return ipv4Octets(text) != nil
    }

    /// Whether the IPv4 prefixes in `prefixes` collectively COVER the default route
    /// `0.0.0.0/0` — whether their union spans the whole 32-bit IPv4 space.
    ///
    /// Coverage, not a literal `0.0.0.0/0` match. WireGuard front-ends routinely write a full
    /// tunnel as the two-halves idiom `0.0.0.0/1, 128.0.0.0/1` — the standard way to override
    /// the system default route without deleting it — and that pair claims exactly the same
    /// space as `0.0.0.0/0`. Refusing it treated a full tunnel as a split one.
    ///
    /// This is the FULL-vs-SPLIT discriminator: a covering set is a full tunnel; a set that
    /// leaves any gap (`10.0.0.0/8, 192.168.0.0/16`, a lone `100.64.0.0/10`) is a split
    /// tunnel the route plan now claims exactly (Slice 3). The initializer's derivation calls
    /// this first, then classifies the non-covering shapes it cannot route (empty, v6-only,
    /// v6-in-split) — see ``ValidationFailure``.
    ///
    /// IPv6 prefixes are ignored: they cannot contribute to covering the IPv4 default route,
    /// and full tunnel claims `::/0` to DROP v6 rather than carry it. `prefixes` is assumed
    /// already well-formed — `isPlausiblePrefix` runs first — so a malformed entry (including
    /// the leading-zero `00.00.00.00/0`) is refused upstream and never reaches here.
    private static func coversIPv4DefaultRoute(_ prefixes: [String]) -> Bool {
        // Each IPv4 prefix is a contiguous [start, end] block of the 32-bit space. Collect the
        // blocks in UInt64 — so the top of the range, 0xFFFFFFFF, has room to be incremented
        // past without overflow — sort by start, then sweep for a gap-free span of the whole
        // space. A gap before or between blocks means the default route is not covered.
        let blocks = prefixes.compactMap(Self.ipv4Block).sorted { $0.start < $1.start }
        var nextNeeded: UInt64 = 0
        for block in blocks {
            // A block starting past the first address still uncovered is a hole: nothing in
            // this sorted-by-start list can fill it, because every later block starts no earlier.
            if block.start > nextNeeded { return false }
            if block.end >= nextNeeded { nextNeeded = block.end + 1 }
            if nextNeeded > 0xFFFF_FFFF { return true }
        }
        return nextNeeded > 0xFFFF_FFFF
    }

    /// The inclusive `[start, end]` 32-bit range an IPv4 `address/length` prefix covers, as
    /// `UInt64` so the top of the range can be incremented past 0xFFFFFFFF. `nil` for anything
    /// that is not an IPv4 prefix — an IPv6 entry, or a malformed one the caller already refused.
    private static func ipv4Block(_ prefix: String) -> (start: UInt64, end: UInt64)? {
        let parts = prefix.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let length = Int(parts[1]), (0...32).contains(length),
              let octets = ipv4Octets(String(parts[0])) else { return nil }
        let address = octets.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        // A /0 covers 2^32 addresses; a /32 covers one. Masking host bits off the start makes
        // `10.1.2.3/8` and `10.0.0.0/8` claim the same block — a prefix is a network, not the
        // host that happened to be written in it.
        let blockSize = UInt64(1) << (32 - length)
        let network = address & ~(blockSize - 1) & 0xFFFF_FFFF
        return (network, network + blockSize - 1)
    }

    /// The four octets of a dotted-quad IPv4 literal, or `nil`.
    ///
    /// Deliberately strict: exactly four parts, each a decimal 0-255 with no leading `+`,
    /// sign, or whitespace. `inet_aton` would accept `10.1` and `0x0a000001` as the same
    /// address, which is not a generosity a security boundary wants — two configs that look
    /// different would be one address, and a log would name a form the user never wrote.
    private static func ipv4Octets(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = UInt16(part), value <= 255
            else { return nil }
            // CANONICAL decimal: `0` is fine, `00` and `010` are not. Leading zeros were the
            // hole in the "one spelling" claim this function's own comment makes — `UInt16`
            // parses them happily, so `010.064.000.005` was a second spelling of `10.64.0.5`
            // and `00.00.00.00/0` was recognised as the default route.
            //
            // Note this is NOT about matching the data path: on Darwin's libc — which is what
            // iOS uses — `inet_pton` ACCEPTS leading zeros, so `ChainedIPPrefix` would take
            // these too. There is no divergence to fix. The reason to reject them is the one
            // stated above: two spellings of one address is not a generosity a security
            // boundary wants, and a log naming a form the user never wrote is worse than an
            // error at the boundary.
            guard part.count == 1 || part.first != "0" else { return nil }
            octets.append(UInt8(value))
        }
        return octets
    }

    /// Whether a 32-byte X25519 public key is one of Curve25519's small-order points.
    ///
    /// Lives here because this type's contract is that a value of it is ALREADY VALIDATED —
    /// so a check performed only by a later consumer leaves every other construction path
    /// accepting a key that cannot be used. The all-zero test this replaces was one of the
    /// seven canonical points; the other six passed.
    ///
    /// A small-order peer key drives the Diffie-Hellman to an all-zero shared secret whatever
    /// our key is, making the session's key material predictable. Nothing below us checks:
    /// `check_base64_encoded_x25519_key` exists in boringtun's FFI and nothing on our ABI path
    /// calls it, `Tunn::new` is infallible, and `was_contributory` is never invoked.
    ///
    /// Seven canonical u-coordinates of order dividing 8, plus each with the high bit set —
    /// that bit is ignored during scalar multiplication, so the twin is an equivalent key and
    /// refusing only the canonical spelling is a check that looks complete and is not.
    /// pinned: ChainedUpstreamConfigurationTests.testASmallOrderPeerKeyIsRefusedAtConstruction
    public static func isSmallOrderPoint(_ key: Data) -> Bool {
        guard key.count == publicKeyByteCount else { return false }
        return smallOrderPoints.contains(Array(key))
    }

    private static let smallOrderPoints: Set<[UInt8]> = {
        let canonical: [[UInt8]] = [
            Array(repeating: 0x00, count: 32),
            [0x01] + Array(repeating: 0x00, count: 31),
            [0xe0, 0xeb, 0x7a, 0x7c, 0x3b, 0x41, 0xb8, 0xae, 0x16, 0x56, 0xe3, 0xfa, 0xf1, 0x9f,
             0xc4, 0x6a, 0xda, 0x09, 0x8d, 0xeb, 0x9c, 0x32, 0xb1, 0xfd, 0x86, 0x62, 0x05, 0x16,
             0x5f, 0x49, 0xb8, 0x00],
            [0x5f, 0x9c, 0x95, 0xbc, 0xa3, 0x50, 0x8c, 0x24, 0xb1, 0xd0, 0xb1, 0x55, 0x9c, 0x83,
             0xef, 0x5b, 0x04, 0x44, 0x5c, 0xc4, 0x58, 0x1c, 0x8e, 0x86, 0xd8, 0x22, 0x4e, 0xdd,
             0xd0, 0x9f, 0x11, 0x57],
            [0xec] + Array(repeating: 0xff, count: 30) + [0x7f],
            [0xed] + Array(repeating: 0xff, count: 30) + [0x7f],
            [0xee] + Array(repeating: 0xff, count: 30) + [0x7f],
        ]
        var all = Set(canonical)
        for point in canonical {
            var twin = point
            twin[31] |= 0x80
            all.insert(twin)
        }
        return all
    }()

    /// The table's size, for the test that asserts nothing was added to it.
    ///
    /// Only the count is exposed. The table itself stays private so a test cannot take its
    /// expected values from it — an oracle derived from the thing under test agrees with a
    /// dropped or corrupted entry, which is the failure the pinned test exists to catch.
    static var smallOrderPointCount: Int { smallOrderPoints.count }

    /// Rejects the shapes that mean the user pasted a URL, a `host:port` pair, or a line of
    /// a config file rather than a host.
    ///
    /// Deliberately permissive about what a hostname may contain — this is not a resolver,
    /// and rejecting a valid but unusual name would lock a user out of their own server.
    /// It only refuses input that cannot be a host at all.
    private static func isPlausibleEndpointHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }

        // A trailing dot is legal FQDN syntax, so strip one before checking labels —
        // otherwise "vpn.example.com." fails on an empty final label.
        var candidate = Substring(host)
        if candidate.hasSuffix(".") { candidate = candidate.dropLast() }
        guard !candidate.isEmpty else { return false }

        for scalar in candidate.unicodeScalars {
            // Control and format characters are never part of a host and are invisible in
            // the field the user pasted into, so they have to be rejected by class rather
            // than by listing them.
            guard !CharacterSet.whitespacesAndNewlines.contains(scalar),
                  !CharacterSet.controlCharacters.contains(scalar) else { return false }
            // The URI delimiters. A colon means either a pasted "host:port" or a bare IPv6
            // literal; "?" and "#" mean a pasted URL kept its query or fragment. Each of
            // these means the caller has to say what it intended, so none is a host.
            guard !uriDelimiters.contains(scalar) else { return false }
        }

        // Both length rules are measured on the name that is actually QUERIED — the A-label
        // form — not on its Unicode spelling. Neither substitute works:
        //
        //   `host.count` counts grapheme clusters, so 253 CJK characters (~700 octets) sailed
        //   past a gate documented as capping at 253.
        //
        //   `host.utf8.count` looks like the fix and is not. Punycode COMPRESSES long
        //   non-ASCII labels, so a 304-octet CJK name can encode to a 134-octet A-label that
        //   is entirely legal — rejecting it is the "locked a user out of their own server"
        //   failure this validator exists to avoid. It also fails the other way: punycode
        //   carries basic code points literally and appends delta digits, so `"a" * 59 + "ü"`
        //   is 61 octets spelled and 67 on the wire.
        //
        // Foundation performs IDNA when a host is parsed as part of a URL, and returns nil
        // when the result is not encodable at all. `DomainName.normalizedIDNAHostname` in
        // this module already uses the technique, so it adds no machinery to the tunnel's
        // budget. ASCII skips the conversion because Foundation passes ASCII hosts through
        // WITHOUT validating them, so it would admit an over-long ASCII label.
        //
        // Interpolating into a URL is safe only because the delimiter loop above has already
        // run; otherwise a crafted host could change how this string parses.
        let wireForm: String
        if candidate.unicodeScalars.allSatisfy({ $0.isASCII }) {
            wireForm = String(candidate)
        } else {
            guard let encoded = URLComponents(string: "https://\(candidate)/")?.encodedHost,
                  !encoded.isEmpty
            else { return false }
            wireForm = encoded
        }

        guard wireForm.utf8.count <= 253 else { return false }
        for label in wireForm.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty, label.utf8.count <= 63 else { return false }
        }
        return true
    }

    /// Characters that cannot appear in a hostname or IP literal.
    ///
    /// Deliberately a denylist of the URI delimiters rather than an allowlist of permitted
    /// characters. An allowlist would have to enumerate every script a valid
    /// internationalized domain may use, and getting that wrong locks a user out of their
    /// own server — the failure this validator's documentation says to avoid. A denylist
    /// errs the other way, toward admitting an odd name, which the resolver then rejects
    /// harmlessly.
    private static let uriDelimiters = CharacterSet(charactersIn: ":/@?#[]%\\|^`\"'<>{} ,")

    private static func decodedPublicKey(_ base64: String) -> Data? {
        // Reject the lenient parse: `Data(base64Encoded:)` accepts trailing junk under
        // `.ignoreUnknownCharacters`, and the default still tolerates some inputs a user
        // would not recognize as their key. A wrong-length decode is the failure that
        // reaches the engine as an over-read.
        guard let data = Data(base64Encoded: base64), !base64.isEmpty else { return nil }
        return data
    }

    /// The peer key as the engine consumes it: the decoded bytes, exactly 32 of them.
    ///
    /// `nil` only for a value this type's own validator would refuse — and `init(from:)`
    /// revalidates on every decode, so a held instance answering `nil` means the validator
    /// tightened since the value was constructed in-process. Exposed so the session-build
    /// path decodes with the SAME strict parse the validator used, rather than growing a
    /// second decoder that can drift from it.
    public var decodedPeerPublicKey: Data? {
        guard let data = Self.decodedPublicKey(peerPublicKey),
            data.count == Self.publicKeyByteCount
        else { return nil }
        return data
    }

    /// Fingerprint of the peer key, for correlating log lines across a session.
    ///
    /// Taken over the DECODED key, not the base64 string. Base64 of 32 bytes has slack in
    /// its final character, so several spellings decode identically — and hashing the text
    /// gave a user who re-pasted a differently-encoded copy of the same key a different
    /// "stable" fingerprint.
    ///
    /// NOT anonymous, despite what this comment used to claim. A peer public key is public
    /// and enumerable: providers publish one per server, so anyone holding a candidate list
    /// — including us, on receipt of a debug bundle — can match a 32-bit prefix back to the
    /// exact server offline. It is also globally stable, so two users of the same server
    /// share a fingerprint. Treat it as "which peer, consistently" for support triage, not
    /// as redaction. Making it genuinely non-identifying needs a per-install salt held in
    /// the Keychain, which belongs with the code that first stores a peer key —
    /// `ChainedUpstreamKeychainStore.commit`. That producer now exists, so this is a shippable
    /// change rather than a blocked one; it is deliberately NOT taken in the same slice,
    /// because a salt is a third stored item and the commit protocol's whole guarantee is that
    /// exactly one thing is written per rotation. Salting it is a rotation of the fingerprint
    /// scheme, not of the upstream, and belongs in its own slice.
    /// pinned: ChainedUpstreamConfigurationTests.testTheFingerprintIsStableAcrossEncodings
    public var peerKeyFingerprint: String {
        let key = Self.decodedPublicKey(peerPublicKey) ?? Data(peerPublicKey.utf8)
        return SHA256.hash(data: key).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// A change detector for the fields that decide RESOLVER SELECTION.
    ///
    /// Exactly the inputs `ChainedTunnelResolverSelection` reads: `allowedIPs`, `dnsAddresses` and
    /// `clientAddress`. Endpoint, peer key and keepalive are deliberately EXCLUDED — none of them
    /// can change which resolvers are admitted, and a freshness check that tripped on them would
    /// send the user to restart protection for nothing.
    ///
    /// Exists because the settings panel compares the live session against the current settings,
    /// and the fallback ADDRESSES are only half of that comparison. Replacing a full-tunnel
    /// configuration with a split one leaves the chosen resolver unchanged while reversing the
    /// admission verdict, so the panel kept reporting the old session's `working` for a fallback
    /// the newly staged configuration will refuse on restart — and the reverse replacement left a
    /// stale refusal standing over a configuration that would now admit it (Codex, PR #575).
    ///
    /// Same construction and same caveat as ``peerKeyFingerprint``: SHA-256 truncated to 4 bytes,
    /// unsalted, so it is a comparison token rather than a secret. It may travel in a health
    /// snapshot; the fields it covers may not — `allowedIPs` and the conf's `DNS =` name the
    /// operator's infrastructure the way the endpoint does.
    ///
    /// pinned: ChainedUpstreamConfigurationTests.testTheSelectionFingerprintTracksOnlySelectionInputs
    public var resolverSelectionFingerprint: String {
        // `allowedIPs` DIRECTLY. This used to strip the routes the app opened for a fallback
        // resolver, because the comparison this token exists for is "does the running session
        // match what is saved" and the saved configuration never carried them. Nothing opens
        // routes any more, so the filter excluded an empty set on every call.
        // A separator that cannot occur inside an address or a prefix, so a field boundary can
        // never be forged by the contents: `allowedIPs: ["a", "b"]` and `allowedIPs: ["a,b"]`
        // must not collide, nor may a value shifting between two adjacent fields.
        // Both ordered rows affect route ownership and address translation; only the
        // selected provider contributes DNS addresses to the effective resolver list.
        // pinned: ChainedStackRoutingTests.testSelectionFingerprintIncludesBothOrderedProfiles
        let canonical = orderedHops.enumerated().map { index, profile in
            profile.allowedIPs.joined(separator: ",") + "\u{1F}"
                + (index == stackDNSProfileIndex ? profile.dnsAddresses.joined(separator: ",") : "") + "\u{1F}"
                + profile.clientAddress
        }.joined(separator: "\u{1E}")
        return SHA256.hash(data: Data(canonical.utf8))
            .prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The only representation that may reach a log.
    ///
    /// The host is withheld, not truncated: a domain suffix alone often identifies a VPN
    /// provider, and a debug bundle is something users send to us.
    public var redactedSummary: String {
        // The resolver addresses are withheld like the host: they name the operator's
        // infrastructure the same way the endpoint does. The count alone supports triage
        // ("no DNS line" vs "resolvers present") without identifying anything.
        "ChainedUpstreamConfiguration(endpoint: <redacted>:\(endpointPort), "
            + "peer: \(peerKeyFingerprint), keepalive: \(persistentKeepaliveSeconds)s, "
            + "dns: \(dnsAddresses.count))"
    }
}

// Interpolating a value is the easiest way to leak it, and it happens by accident — a
// `"\(configuration)"` in a log line reads as harmless. Routing both conversions through
// the redacted form means the careless path is also the safe one. The spike branch shipped
// exactly this bug in reverse: its config type had no custom description, so reflection
// rendered the raw key bytes as a decimal array into the debug log.
// pinned: ChainedUpstreamConfigurationTests.testInterpolationCannotLeakTheEndpointOrKey
extension ChainedUpstreamConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { redactedSummary }
    public var debugDescription: String { redactedSummary }
}

/// Invalid composition of otherwise valid WireGuard profiles.
public enum WireGuardChainFailure: Error, LocalizedError, Equatable {
    /// The chain would exceed two profiles.
    case tooManyHops
    /// Nested UDP currently supports only an IPv4 exit endpoint.
    case exitRequiresIPv4Endpoint
    /// Hostname bootstrap is unsupported for the entry transport.
    case entryRequiresLiteralEndpoint
    /// The entry's authored routes do not reach the exit endpoint.
    case exitNotReachableThroughEntry
    /// The entry cannot carry the minimum inner interface MTU plus encapsulation.
    case entryMTUTooSmall
    /// An editor or mutation holds an outdated storage generation.
    case changed
    /// Preserving a saved row requires unavailable key material.
    case missingSecret
    /// Localizable description for the app's validation surface.
    public var errorDescription: String? {
        switch self {
        case .tooManyHops: LavaCoreStrings.localized("You can add up to two WireGuard configurations.")
        case .entryRequiresLiteralEndpoint: LavaCoreStrings.localized("The first configuration needs an IP endpoint address.")
        case .exitRequiresIPv4Endpoint: LavaCoreStrings.localized("The second configuration needs an IPv4 endpoint address.")
        case .exitNotReachableThroughEntry: LavaCoreStrings.localized("The first configuration's AllowedIPs must include the second VPN's endpoint.")
        case .entryMTUTooSmall: LavaCoreStrings.localized("The first configuration's MTU must be at least 1340 for two VPN hops.")
        case .changed: LavaCoreStrings.localized("The saved configurations changed. Reopen the editor and try again.")
        case .missingSecret: LavaCoreStrings.localized("A saved configuration's key is unavailable. Import it again.")
        }
    }
}
