import Foundation
import LavaSecKit

/// Where a DNS query is allowed to leave from while chained mode is latched.
///
/// The type carries no case meaning "the physical interface". That is the point — see
/// ``ChainedResolverEgressPolicy``.
public enum ChainedResolverEgress: Equatable, Sendable {
    /// Plain UDP DNS to the upstream's own resolver, framed and encapsulated through the
    /// WireGuard session. The only egress chained mode has.
    case throughTunnelToUpstreamResolver
    /// This transport cannot be used while chained. Carries the answer the tunnel gives
    /// instead — refusing the I/O is only half of `INV-DNS-1`, which requires a RESPONSE.
    case unavailableWhileChained(
        ChainedResolverEgressPolicy.Unavailable,
        answer: ChainedResolverEgressPolicy.FailClosedAnswer)

}

/// Whether a resolver socket may be opened at all while chained, and how it must be pinned.
///
/// A separate type from ``ResolverInterfaceBinding`` because the refusal outcomes are not
/// bindings. "Chained is latched but we do not know the tunnel's interface" cannot be answered
/// with `.systemChosen` — that value means "the routing table chooses", and while chained the
/// routing table chooses the leak. An `Optional<ResolverInterfaceBinding>` would have invited
/// exactly one line of code, `?? .systemChosen`, to reintroduce it.
///
/// The two refusals are DIFFERENT conditions and stay distinct so a caller (and a device log)
/// never reports one as the other:
/// ``refusedNoTunnelInterface`` is the startup `virtualInterface` lag — the TUNNEL interface is
/// unknown; ``refusedNoPhysicalInterface`` is F2's destination-scoped pin — the tunnel IS known,
/// but the live PHYSICAL interface index is missing for a floor-claimed, profile-uncovered
/// destination that must leave on the physical path.
public enum ChainedResolverSocketBinding: Equatable, Sendable {
    /// A socket may be opened, pinned this way.
    case permitted(ResolverInterfaceBinding)
    /// No socket may be opened. Chained is latched and the tunnel interface is unknown, so
    /// every socket available to us would egress around the tunnel.
    case refusedNoTunnelInterface
    /// No socket may be opened. Chained is latched and the tunnel interface IS known, but the
    /// PHYSICAL interface index is missing for a destination the capture floor claimed and the
    /// profile does not carry. An unbound socket would follow the routing table back into the
    /// tunnel's own claim, so the only safe answer is to refuse rather than re-enter it.
    case refusedNoPhysicalInterface

    /// The binding to hand the socket layer, or nil when no socket may be opened.
    public var permittedBinding: ResolverInterfaceBinding? {
        switch self {
        case .permitted(let binding):
            return binding
        case .refusedNoTunnelInterface, .refusedNoPhysicalInterface:
            return nil
        }
    }
}

/// Which DNS egress chained mode permits.
///
/// Plan: lavasec-infra `plans/2026-07-27-vpn-upstream-phase-3-data-path-plan.md` (S6),
/// implementing D5's chained-mode resolver chain.
///
/// ## The leak this exists to prevent
///
/// Every resolver transport in the app egresses on ORDINARY PROCESS SOCKETS on the physical
/// interface — `SocketResolvers`, `DoHTransport`, `DoTTransport`, `DoQTransport`. That is
/// correct today and catastrophic while chained: a user who routed their traffic through an
/// upstream so their network cannot see it would have their DNS keep going out around the
/// tunnel, to the same observer, naming every site they visit.
///
/// It is also the failure mode least likely to be noticed. Nothing breaks. The tunnel is up,
/// pages load, filtering works — and the one thing the user turned this on for is quietly not
/// happening.
///
/// So the T0 ladder's only egress while chained is plain UDP DNS to the upstream's own
/// resolver, encapsulated through the session. There is no case in ``ChainedResolverEgress``
/// meaning "the physical interface", which makes that leak unrepresentable rather than merely
/// prohibited — the same technique ``ChainedEndpointResolutionPlan`` uses for the bootstrap
/// deadlock.
///
/// ## The one exception, and why it is not this leak
///
/// THIS DOC SAID "the ONLY egress" WITHOUT QUALIFICATION, and PR #590 made that false. In a
/// SPLIT tunnel the user's chosen T1 alternative resolver may egress on the physical
/// interface — see ``permitsTierOneFallbackOnPhysicalInterface`` and ``tierOneSocketBinding(...)``,
/// and `INV-CHAIN-5` for the full set of conditions.
///
/// It is not the leak above, and the difference is the whole argument. The leak is a DNS query
/// naming a site whose traffic the observer cannot otherwise see. In a split tunnel the data
/// path to that destination ALREADY goes direct: the local network holds its address and its
/// TLS SNI regardless. Withholding the name protects nothing and costs the lookup. In a FULL
/// tunnel the observer sees none of it, so the refusal there stays absolute — which is why the
/// permission keys on the LATCHED routing policy for that session and not on a stored setting.
///
/// The reachability half is separate and is not this type's to grant. `tierOneSocketBinding(...)`
/// is `.systemChosen` — unbound, routing table decides — EXCEPT when the DNS capture floor has
/// claimed the destination's route and the profile does not already carry it, in which case F2
/// pins the socket to the live physical interface so the query does not re-enter the tunnel. A
/// profile whose own `AllowedIPs` cover the resolver still carries the rung through the peer;
/// F2 never overrides the user's routes.
///
/// ## Why the encrypted presets are unavailable rather than tunnelled
///
/// DoH, DoT and DoQ are TCP or QUIC over `URLSession`/`NWConnection`. Pushing those through a
/// userspace WireGuard session needs a TCP implementation on our side of the tunnel, which
/// this feature is not going to grow. Plain UDP DNS is bounded and request/response, so it
/// needs no stack at all.
///
/// The privacy arithmetic is also better than it looks: the query is inside the WireGuard
/// tunnel, so the local network sees encrypted UDP to the peer and nothing else. What the
/// UPSTREAM's resolver sees is a property the user chose when they chose the upstream.
///
/// ## Why the fallback ladder is suspended
///
/// `fallbackToDeviceDNS` and the `INV-DNS-4`/`INV-DNS-5` health machinery — smoke probes,
/// device-DNS capture, wedge recovery — are all physical-interface behaviours. Every one of
/// them is a path that would resume egressing around the tunnel at exactly the moment the
/// tunnelled resolver is struggling. A failure answers fail-closed per `INV-DNS-1`, which
/// still protects the user, rather than silently restoring the leak this policy exists to
/// close.
/// pinned: ChainedResolverEgressTests.testNoTransportEgressesOnThePhysicalInterfaceWhileChained
public enum ChainedResolverEgressPolicy {
    /// What the tunnel answers when a transport is unavailable.
    ///
    /// `INV-DNS-1` is about never failing OPEN, which means a query gets an answer rather than
    /// being abandoned. Refusing the I/O without specifying the response leaves the caller to
    /// invent one, and the obvious invention — let it time out — is indistinguishable to the
    /// app from a network problem and invites a retry against the same refusal.
    public enum FailClosedAnswer: String, Equatable, Sendable {
        /// SERVFAIL. The name is not resolved and the resolver says so, so the app fails fast
        /// and visibly rather than hanging.
        case servfail
    }

    /// Why a transport cannot be used while chained.
    public enum Unavailable: String, Equatable, Sendable {
        /// DoH/DoT/DoQ. Needs a TCP or QUIC stack inside the tunnel, which does not exist.
        case needsATransportTheTunnelCannotCarry
        /// The device's own resolvers, reached on the physical interface by definition.
        /// Using them while chained is the leak itself, not a fallback from it.
        case wouldEgressAroundTheTunnel
        /// A truncated (TC-bit) answer, whose retry RFC 1035 puts on TCP.
        ///
        /// The DNS-only path answers this with `TCPResolver`, an ordinary socket where the
        /// KERNEL is the TCP endpoint.
        ///
        /// THE NAME IS NOW A PRODUCT DECISION, not a technical gap, and the history matters
        /// because both halves of the original rationale are gone. A chained retry needs no
        /// userspace TCP: a socket pinned to the provider's `virtualInterface` has its
        /// segments delivered to that provider's own `packetFlow` with the tunnel's address
        /// as their source — measured, not assumed (``ResolverInterfaceBinding``;
        /// ``ChainedResolverEgressPolicy/socketBinding(chainedIsLatched:tunnelInterfaceIndex:)``
        /// is the seam). And the classifier carve-out that retry rides EXISTS — keyed on our
        /// own flow's local source port, never on destination address (which would reopen the
        /// hardcoded-resolver leak pinned by `testADNSQueryToAPublicResolverIsStillIntercepted`)
        /// — `ChainedOutboundPacketClassifier`'s TCP/53 arm, proven end-to-end against a real
        /// peer engine.
        ///
        /// That socket-carry evidence does not cover `includeAllNetworks=true`. The September 23
        /// device comparison found provider DNS on physical Wi-Fi under that flag; see
        /// `lavasec-infra/records/ios-planning/2026-09-23-connectivity-assist-validation.md`. A strict-routing transport cannot
        /// rely on the ordinary-tunnel TCP/UDP result above.
        ///
        /// What keeps this fail-closed is resolved decision 3 (phase-3 plan, founder,
        /// 2026-07-31): S6 mitigates truncation with the EDNS0 ~1232 advertisement, and the
        /// TCP retry is a follow-up whose ENABLEMENT is gated on the S9 battery's field
        /// evidence — TC-answer rate and per-domain silent-timeout rate while chained.
        ///
        /// So it fails closed, and the cost is named rather than hidden: a domain whose answer
        /// does not fit resolves in DNS-only mode and does not resolve while chained. See
        /// ``ChainedResolverEgressPolicy/truncationIsResolverLiveness`` for the rule that stops
        /// that from becoming a feature-wide outage.
        case needsATCPRetryTheTunnelCannotCarry
    }

    /// A truncated answer while chained.
    ///
    /// Separate from ``egress(for:)`` because it is not a property of the configured transport:
    /// plain DNS IS carried, the query DID go through the tunnel, and the resolver DID answer.
    /// Only this one response cannot be completed.
    /// pinned: ChainedResolverEgressTests.testATruncatedAnswerFailsClosedRatherThanRetryingOnTCP
    public static func truncatedAnswerEgress() -> ChainedResolverEgress {
        .unavailableWhileChained(.needsATCPRetryTheTunnelCannotCarry, answer: .servfail)
    }

    /// Whether a truncated answer is evidence the resolver is WORKING. It is.
    ///
    /// THE TRAP THIS EXISTS TO NAME. A TC-bit response is a resolver replying, promptly and
    /// correctly, that the answer is too large for UDP — it is proof the query reached the
    /// upstream through the tunnel and came back. Counting it as a DNS failure would be exactly
    /// backwards, and the consequence is not a slow lookup: sustained tunnel-DNS failure is a
    /// cause that feeds the shared outage supervisor, so ONE large-response domain that a
    /// browser retries a few times would spend the blackhole budget and surrender chaining for
    /// every site, for that user, until they turn it back on.
    ///
    /// The user-visible fault must stay proportional to the actual fault: one domain does not
    /// resolve. That is bad, and naming the symptom in the chained subpage copy is a C8
    /// deliverable of the Phase-4 trigger PR (no chained copy exists before then); it is
    /// not a reason to tear down a working tunnel.
    /// pinned: ChainedResolverEgressTests.testATruncatedAnswerCountsAsResolverLivenessNotFailure
    public static let truncationIsResolverLiveness = true

    /// How a resolver socket must be pinned, given the mode and what the provider knows.
    ///
    /// This is the S8.7b decision in one place. A socket bound to the provider's
    /// `virtualInterface` has its packets delivered to that provider's own `packetFlow` —
    /// measured on device 2026-07-29 for TCP and UDP, with the unbound control legs producing
    /// no packets at all — so the kernel builds the segment, the tunnel carries it, and there
    /// is no userspace TCP stack anywhere in the design.
    ///
    /// This is the ordinary-tunnel transport, not proof of containment under `includeAllNetworks`.
    /// With that flag enabled on September 23, provider DNS appeared on physical Wi-Fi and timed
    /// out. A successful interface bind is insufficient for strict routing; see the validation plan.
    ///
    /// The refusal case is the load-bearing one. If chained is latched and the interface index
    /// is unknown, there is no safe socket to open: the only thing an unpinned socket can do is
    /// the leak. Refusing produces a fail-closed answer, which `INV-DNS-1` permits; egressing
    /// on the physical interface is what it forbids.
    /// pinned: ChainedResolverEgressTests.testChainedNeverYieldsASystemChosenSocket
    public static func socketBinding(
        chainedIsLatched: Bool,
        tunnelInterfaceIndex: UInt32?
    ) -> ChainedResolverSocketBinding {
        guard chainedIsLatched else {
            // DNS-only, and every pre-latch path. The routing table has always chosen here and
            // there is no tunnel to prefer.
            return .permitted(.systemChosen)
        }

        // Index 0 is refused here as well as at the socket, and for a different reason. There it
        // is a kernel API hazard — `IP_BOUND_IF` reads 0 as "unbind" and reports success. Here it
        // means the provider handed us an interface it does not really have, which is the same
        // situation as nil and must get the same answer.
        guard let tunnelInterfaceIndex, tunnelInterfaceIndex != 0 else {
            return .refusedNoTunnelInterface
        }

        return .permitted(.boundToTunnel(interfaceIndex: tunnelInterfaceIndex))
    }

    /// The egress for a configured resolver transport while chained mode is latched.
    public static func egress(for transport: DNSResolverTransport) -> ChainedResolverEgress {
        switch transport {
        case .plainDNS:
            // The one that maps. Plain UDP DNS is bounded and request/response, so it is
            // framed and encapsulated with no stack of our own.
            return .throughTunnelToUpstreamResolver
        case .dnsOverHTTPS, .dnsOverTLS, .dnsOverQUIC:
            return .unavailableWhileChained(
                .needsATransportTheTunnelCannotCarry, answer: .servfail)
        case .deviceDNS:
            // Plain UDP too, so while chained it is redirected THROUGH THE TUNNEL to the
            // upstream's own resolver exactly as `.plainDNS` is — NOT to the device's captured
            // local resolver, which is what "would egress around the tunnel" once described and
            // what the leak actually is. The app DEFAULTS to device DNS, so refusing it here was
            // a total DNS blackhole the moment a user chained (device-verified, chimmy
            // 2026-08-14); the carry is ResolverOrchestrator's `.deviceDNS` arm.
            return .throughTunnelToUpstreamResolver
        }
    }

    /// The endpoint bootstrap's egress, which is deliberately NOT a `ChainedResolverEgress`.
    ///
    /// Its own type, because putting a physical-interface case in the resolver enum handed
    /// every future caller of that enum a value they could select — and S6 wires that enum
    /// into the resolver pipeline, where selecting it is the leak. Naming the exception made
    /// it auditable; giving it its own type keeps it unreachable from the resolver path as
    /// well.
    ///
    /// Resolving the endpoint HOSTNAME has to happen before a session exists — the tunnel
    /// that would carry the query is the tunnel being built. The privacy cost is real and
    /// belongs in the Settings copy: the endpoint hostname is disclosed to the local network.
    /// `ChainedEndpointResolutionPlan` carries the same fact as
    /// `disclosesEndpointNameToLocalNetwork`.
    /// pinned: ChainedResolverEgressTests.testTheBootstrapExceptionIsNotAResolverEgress
    public struct EndpointBootstrapEgress: Equatable, Sendable {
        /// Stable identifier for device logs. Never user copy.
        public var logValue: String { "resolver-endpoint-bootstrap" }
        public init() {}
    }

    /// The bootstrap egress. A distinct type, so it cannot be returned from `egress(for:)` or
    /// selected by a caller switching over resolver outcomes.
    public static func endpointBootstrapEgress() -> EndpointBootstrapEgress {
        EndpointBootstrapEgress()
    }

    /// Whether the device-DNS fallback ladder may run while chained.
    ///
    /// Always false, and stated as a function rather than a constant so the call site reads as
    /// a decision and a future condition has somewhere to live. Every rung of that ladder is a
    /// physical-interface behaviour, so "fall back" and "leak" are the same action here.
    ///
    /// Sourced from ``DNSHealthAuthority/deviceDNSFallbackMayRun`` rather than from
    /// ``suspendsPhysicalInterfaceBehaviour``, even though the two answer identically today. The
    /// authority names four consultations separately BECAUSE they are expected to diverge when
    /// the two health subsystems unify; a seam wired to a neighbouring question is a seam that
    /// will follow the wrong owner on the day it stops being the same bit, silently, because the
    /// question it should be asking has no reader to fail. That is the divergence class the
    /// authority exists to end, so each seam asks its own question now.
    /// pinned: ChainedResolverEgressTests.testTheFallbackLadderIsSuspendedNotMerelyDiscouraged
    /// pinned: DNSHealthAuthorityTests.testEveryOwnershipConsultationHasAProductionConsumer
    public static func permitsDeviceDNSFallback(chainedIsLatched: Bool) -> Bool {
        DNSHealthAuthority(chainedIsLatched: chainedIsLatched).deviceDNSFallbackMayRun
    }

    /// Whether the T1 rung — the user's chosen resolver, reached only for names the
    /// upstream's own `DNS =` did not serve — may leave on the PHYSICAL interface.
    ///
    /// THE ONE CONDITIONAL IN A FILE OF ABSOLUTES, and it is conditional on the latched route
    /// plan rather than on any stored preference. The suspension above rests on a specific
    /// claim: the user routed their traffic through an upstream so their network cannot see
    /// it, and DNS leaking around the tunnel would name every site while nothing visibly
    /// breaks. That claim is true in FULL tunnel and false in SPLIT, where general traffic
    /// goes direct on the physical interface and the local observer already holds the
    /// destination address and the TLS SNI for every site visited. Refusing to send the NAME
    /// over a path already carrying the CONNECTION protects nothing and costs the lookup.
    ///
    /// Field evidence for the cost (rc9, build 1787723354, 2026-08-26): a Tailscale profile
    /// whose `DNS = 100.100.100.100` serves tailnet names only. The earlier design routed the
    /// T1 resolver THROUGH the peer by widening `AllowedIPs`, but `AllowedIPs` is only our
    /// half of cryptokey routing — it says where we send and cannot make the peer forward. A
    /// Tailscale node routes tailnet addresses and advertised subnets; `1.1.1.1` is neither
    /// without an exit node, so all three T1 attempts in that capture were dropped by the
    /// peer with nothing coming back. T1 that depends on peer configuration we neither
    /// control nor can detect is T1 that does not work.
    ///
    /// FULL TUNNEL IS UNCHANGED and stays absolute: there the data path really does hide the
    /// destination, DNS would be the only observable, and every word of the suspension above
    /// applies. `nil` — no chained routing policy — is the same answer, because a latched
    /// session whose policy we cannot name is not one to spend a privacy boundary on.
    ///
    /// NOT "device DNS on the physical interface". That is whatever DHCP handed the device,
    /// which is the resolver `LAV-87` escalation exists for; ``permitsDeviceDNSFallback`` stays
    /// false in every chained shape, split included. This permits the resolver the user CHOSE,
    /// on the transport they chose.
    /// pinned: ChainedResolverEgressTests.testTierOneMayLeavePhysicallyOnlyInASplitTunnel
    public static func permitsTierOneFallbackOnPhysicalInterface(
        chainedIsLatched: Bool,
        routingPolicy: ChainedRoutingPolicy?
    ) -> Bool {
        // DNS-only is not a "no" about privacy — T1 is the same setting in both modes and runs
        // on the physical interface there by the ordinary ladder, with no T0 above it. This
        // decision is only about T1's egress WHILE CHAINED and has nothing to say outside it.
        guard chainedIsLatched else { return false }
        switch routingPolicy {
        case .splitTunnel:
            return true
        case .fullTunnel, nil:
            return false
        }
    }

    /// The socket binding for a resolver destination, scoped to whether Lava claimed its route.
    ///
    /// ## F2: why a destination can need a physical pin at all
    ///
    /// F3b merges the network's captured resolver addresses into the route plan as `/32` and
    /// `/128` host routes (``TunnelRoutePlan``, ``DNSCaptureFloor``). A destination whose route
    /// the tunnel now claims no longer follows the ordinary physical path: an unbound socket to
    /// it is drawn back into the NE, and a WireGuard peer that does not carry the address refuses
    /// the datagram. Lava would then strand its OWN upstream query while the filter it protects
    /// is the thing asking. So a floor-claimed destination must be pinned to the interface the
    /// device actually routes over.
    ///
    /// ## What this deliberately does NOT do
    ///
    /// It never overrides the user's own `AllowedIPs`. When the profile already carries the
    /// destination, the routing table sends it through the peer and that is correct — pinning it
    /// physically would disclose to the local network a lookup the user's own configuration says
    /// belongs inside the tunnel. `destinationIsProfileCovered` therefore keeps `.systemChosen`,
    /// exactly as before F2.
    ///
    /// A missing or zero physical index on a CLAIMED destination is a different case and
    /// REFUSES with ``ChainedResolverSocketBinding/refusedNoPhysicalInterface`` — NOT the
    /// tunnel-interface refusal, which names the opposite condition. `.systemChosen` there is
    /// not the shipped answer — the tunnel's floor claim draws the route into the NE, so an
    /// unbound socket follows the routing table straight back into the claim and a peer that
    /// does not carry the address refuses the datagram. Returning `.systemChosen` would undo the
    /// claim and strand Lava's own upstream query, the exact failure F2 exists to prevent, and it
    /// contradicts ``ResolverInterfaceBinding``'s rule that every pin kind must fail closed when
    /// it cannot be applied. Zero is refused as an interface for the same reason
    /// `socketBinding(chainedIsLatched:…)` refuses it: at the socket, `IP_BOUND_IF` reads 0 as
    /// "unbind" and reports success. Only an UNCLAIMED destination (or one the profile already
    /// carries) stays `.systemChosen`, where there is nothing to strand and the routing table is
    /// the answer that shipped.
    /// pinned: ChainedResolverEgressTests.testAFloorClaimedDestinationWithNoProfileCoverageBindsPhysical
    /// pinned: ChainedResolverEgressTests.testAProfileCoveredDestinationIsNeverPinnedPhysically
    /// pinned: ChainedResolverEgressTests.testADestinationOutsideTheFloorStaysSystemChosen
    /// pinned: ChainedResolverEgressTests.testAFloorClaimedDestinationWithNoPhysicalIndexIsRefused
    public static func destinationSocketBinding(
        destinationIsFloorClaimed: Bool,
        destinationIsProfileCovered: Bool,
        physicalInterfaceIndex: UInt32?
    ) -> ChainedResolverSocketBinding {
        guard destinationIsFloorClaimed, !destinationIsProfileCovered else {
            return .permitted(.systemChosen)
        }
        guard let physicalInterfaceIndex, physicalInterfaceIndex != 0 else {
            // No physical index means no safe socket to open: the destination is claimed by the
            // tunnel and the profile does not carry it, so the only unpinned answer would
            // re-enter the claim. Fail closed rather than re-enter (`INV-DNS-1`). This is
            // `refusedNoPhysicalInterface`, NOT `refusedNoTunnelInterface` — the tunnel interface
            // is exactly what IS known here.
            return .refusedNoPhysicalInterface
        }
        return .permitted(.boundToPhysical(interfaceIndex: physicalInterfaceIndex))
    }

    /// Whether any of `allowedIPs` covers `destination` — the profile-coverage term of
    /// ``destinationSocketBinding``.
    ///
    /// Parsed through the SAME ``ChainedIPPrefix`` the data path builds its inbound allowlist
    /// from (`ChainedTunnelResolverSelection.selection(from:)` builds
    /// `ChainedAllowedIPs(allowedIPs.compactMap(ChainedIPPrefix.init))`), so "covered" here can
    /// never disagree with the peer's cryptokey routing as the runner enforces it. The
    /// destination is parsed as a host prefix, and an unparseable destination is `false`.
    /// pinned: ChainedResolverEgressTests.testAllowedIPsCoverageUsesTheDataPathsOwnPrefixParser
    public static func allowedIPsCover(
        destination: String,
        allowedIPs: [String]
    ) -> Bool {
        guard let host = ChainedIPPrefix(destination) else { return false }
        return allowedIPs
            .compactMap(ChainedIPPrefix.init)
            .contains { $0.contains(host.networkBytes) }
    }

    /// The socket binding for the chained T1 rung: NEVER the tunnel.
    ///
    /// Its own function rather than a parameter on ``socketBinding(chainedIsLatched:tunnelInterfaceIndex:)``
    /// because the two answer different questions and the call sites must not be able to blur
    /// them. That one asks "is chained latched", and while it is, it pins to the tunnel — which is
    /// correct for T0 and precisely wrong for the rung. A rung permitted onto the physical
    /// interface by the allowance was still pinned to the utun by that seam, so it went to the
    /// peer and timed out exactly as before (Codex, PR #590).
    ///
    /// `.systemChosen` — unbound, routing table decides — is the default, and the tunnel does not
    /// claim the ordinary T1 resolver's route in a split tunnel, so the routing
    /// table sends it out the physical interface. F2 scopes ONE exception: a destination the DNS
    /// capture floor claimed (a device resolver, typically) is drawn back into the tunnel, so it
    /// is pinned to the live physical interface instead — see ``destinationSocketBinding`` and
    /// ``destinationIsFloorClaimed``/``destinationIsProfileCovered`` at the call site. A claimed
    /// destination with no known physical index REFUSES with
    /// ``ChainedResolverSocketBinding/refusedNoPhysicalInterface`` rather than falling back to
    /// `.systemChosen`, which would re-enter the claim.
    ///
    /// THIS DEPENDS ON THE ROUTE. An unbound socket follows the routing table, so if the tunnel's
    /// `AllowedIPs` carried the resolver's address the datagram would re-enter the tunnel
    /// regardless of this decision; and if the FLOOR carries it, the explicit physical pin is the
    /// other half. The two cases are exactly the two inputs.
    ///
    /// AN IPv6 PLAIN/DEVICE RUNG ADDRESS IS NEVER ADMITTED when the data path drops IPv6:
    /// `ChainedTunnelResolverSelection.fallbackOutcomes` names it `.unusableIPv6`, so the rung
    /// never dials one and a `::/0` claim cannot strand it.
    ///
    /// AN ENCRYPTED SELECTION IS THE EXCEPTION, and it is a real residual rather than a claim:
    /// its plan is returned whole and its connect destinations are
    /// `DNSOverTLSEndpoint`/`DNSOverQUICEndpoint.allBootstrapServers`, which are NOT in the rung's
    /// address list — so a split encrypted rung still dials v6 bootstraps that a `::/0` claim
    /// would swallow. F2's physical pin covers the plain/device leg; the encrypted transport's own
    /// connect leg remains the recorded residual, so the v4 bootstrap leg carries it and a
    /// v6-only endpoint fails closed. (Kilo, PR #738.)
    ///
    /// WHAT THIS DOES NOT DO, AND WILL NOT: override the user's OWN routes. A profile whose
    /// `AllowedIPs` already cover the T1 address — `1.1.1.1` under a broad `1.0.0.0/8` — still
    /// sends the rung through the peer, because the routing table says so and
    /// `destinationIsProfileCovered` keeps `.systemChosen`. So "never the tunnel" above is about
    /// what LAVA pins, not about what the routing table decides (Codex, PR #590).
    ///
    /// That is deliberate, and forcing a physical binding there would be wrong twice over.
    ///
    /// FIRST, IT WOULD LEAK. The whole justification for permitting T1 physically in a split
    /// tunnel is that the data path to that destination ALREADY goes direct, so the local network
    /// already sees the address and the TLS SNI and withholding the name protects nothing. That
    /// argument evaporates for a destination the profile routes INTO the tunnel: there the
    /// observer sees none of it, and sending the lookup around the tunnel would disclose a name
    /// the user's own configuration says should be hidden — the precise harm this whole type
    /// exists to prevent.
    ///
    /// SECOND, IT IS NOT A FAILURE MODE OF ITS OWN. If the peer does not forward `1.0.0.0/8`,
    /// then the user's own traffic to `1.1.1.1` is equally dead; DNS failing there is consistent
    /// with their setup rather than a defect in ours, and `ChainedFallbackStatus.notForwarded`
    /// already reports it truthfully. A resolver outside the tunnel's routes is the remedy, and
    /// it is the user's to choose.
    /// pinned: ChainedResolverEgressTests.testTheTierOneRungIsNeverBoundToTheTunnel
    /// pinned: ChainedResolverEgressTests.testTheTierOneBindingDoesNotOverrideTheProfilesOwnRoutes
    public static func tierOneSocketBinding(
        destinationIsFloorClaimed: Bool,
        destinationIsProfileCovered: Bool,
        physicalInterfaceIndex: UInt32?
    ) -> ChainedResolverSocketBinding {
        destinationSocketBinding(
            destinationIsFloorClaimed: destinationIsFloorClaimed,
            destinationIsProfileCovered: destinationIsProfileCovered,
            physicalInterfaceIndex: physicalInterfaceIndex)
    }

    /// The single decision both suspensions are — and the same decision the tunnel's
    /// health-ownership gates make.
    ///
    /// They were two byte-identical predicates kept in step by a test. That is the weaker
    /// arrangement: a half-suspended ladder still leaks, so the two must not be ABLE to
    /// diverge rather than merely observed not to. Both delegate here, and the test that
    /// compared them survives as a check that the delegation is still in place.
    ///
    /// Now sourced from ``DNSHealthAuthority`` so this does not diverge from the OTHER seams
    /// that ask "who owns the physical interface" — the reconnect actor and the organic-evidence
    /// recorder in the packet tunnel. Physical behaviour is suspended exactly when the physical
    /// path does NOT own health, i.e. the tunnel supervisor does (`INV-CHAIN-1`).
    public static func suspendsPhysicalInterfaceBehaviour(chainedIsLatched: Bool) -> Bool {
        !DNSHealthAuthority(chainedIsLatched: chainedIsLatched).physicalInterfaceHealthProbesMayRun
    }

    /// Whether the resolver-health machinery may run while chained.
    ///
    /// Same reasoning: smoke probes, device-DNS capture and wedge recovery all act on the
    /// physical interface, and they act precisely when the tunnelled resolver is struggling —
    /// which is the worst possible moment to resume egressing around the tunnel.
    public static func permitsPhysicalInterfaceHealthProbes(chainedIsLatched: Bool) -> Bool {
        !suspendsPhysicalInterfaceBehaviour(chainedIsLatched: chainedIsLatched)
    }
}

extension ChainedResolverEgress {
    /// Whether a query may be sent at all.
    public var permitsQuery: Bool {
        switch self {
        case .throughTunnelToUpstreamResolver:
            return true
        case .unavailableWhileChained:
            return false
        }
    }

    /// Stable identifier for device logs. Never user copy.
    public var logValue: String {
        switch self {
        case .throughTunnelToUpstreamResolver:
            return "resolver-through-tunnel"
        case .unavailableWhileChained(let reason, let answer):
            return "resolver-unavailable-\(reason.rawValue)-\(answer.rawValue)"

        }
    }
}
