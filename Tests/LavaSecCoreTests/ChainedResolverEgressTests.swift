import XCTest

@testable import LavaSecChainedUpstream
@testable import LavaSecKit

/// DNS egress while chained.
///
/// The plan calls this the slice where a leak would ship, and the reason is that nothing
/// breaks when it does: the tunnel is up, pages load, filtering works, and the user's DNS is
/// quietly still going out to the network they routed everything away from.
final class ChainedResolverEgressTests: XCTestCase {
    private typealias Policy = ChainedResolverEgressPolicy

    // MARK: - The leak is unrepresentable

    func testATruncatedAnswerFailsClosedRatherThanRetryingOnTCP() {
        // RFC 1035 puts the retry for a truncated answer on TCP, and DNS-only mode does exactly
        // that with an ordinary socket where the KERNEL is the TCP endpoint. While chained
        // there is no such endpoint: an OS socket egresses on the physical interface, which is
        // the leak this policy exists to close, and our own retry would not even survive the
        // classifier, which drops TCP/53 rather than hand it to the peer unfiltered.
        //
        // So it fails CLOSED with an answer, not a timeout — INV-DNS-1 is about the query
        // getting a reply the app can act on rather than hanging against a silent refusal.
        guard case .unavailableWhileChained(let reason, let answer) =
            Policy.truncatedAnswerEgress()
        else {
            return XCTFail("a truncated answer was treated as tunnellable")
        }
        XCTAssertEqual(reason, .needsATCPRetryTheTunnelCannotCarry)
        XCTAssertEqual(answer, .servfail, "the app must fail fast and visibly, not hang")
    }

    func testATruncatedAnswerCountsAsResolverLivenessNotFailure() {
        // The trap, stated as a test so it cannot be quietly reversed. A TC-bit response is a
        // resolver replying promptly and correctly that the answer is too big for UDP — proof
        // the query reached the upstream through the tunnel and came back.
        //
        // Counting it as a DNS failure is backwards, and the cost is not a slow lookup:
        // sustained tunnel-DNS failure feeds the shared outage supervisor, so ONE
        // large-response domain retried by a browser would spend the blackhole budget and
        // surrender chaining for EVERY site until the user turns it back on. The user-visible
        // fault has to stay proportional to the real one: a single domain does not resolve.
        XCTAssertTrue(
            Policy.truncationIsResolverLiveness,
            "a truncated answer was treated as resolver failure — one oversized domain can now "
                + "surrender chaining feature-wide")
    }

    func testNoTransportEgressesOnThePhysicalInterfaceWhileChained() {
        // Exhaustive over the transport enum, so a new one cannot be admitted by omission —
        // and the structural claim underneath it: there is no case of ChainedResolverEgress
        // meaning "the physical interface", so a caller cannot select one.
        for transport in [
            DNSResolverTransport.deviceDNS, .plainDNS, .dnsOverHTTPS, .dnsOverTLS, .dnsOverQUIC,
        ] {
            switch Policy.egress(for: transport) {
            case .throughTunnelToUpstreamResolver:
                // Plain UDP DNS is carried — whether the user CONFIGURED plain resolvers or is on
                // device DNS, since while chained both are redirected to the upstream's resolver
                // through the tunnel rather than to their own addresses on the physical interface.
                XCTAssertTrue(
                    transport == .plainDNS || transport == .deviceDNS,
                    "only plain UDP DNS (configured or device) can be tunnelled, not \(transport)")
            case .unavailableWhileChained(_, let answer):
                // The encrypted presets alone — TCP/QUIC the tunnel cannot carry.
                XCTAssertTrue(transport != .plainDNS && transport != .deviceDNS, "\(transport)")
                // INV-DNS-1 is about never failing OPEN, which means the query gets an ANSWER.
                XCTAssertEqual(answer, .servfail)
            }
        }
    }

    func testOnlyPlainUDPIsCarried() {
        XCTAssertEqual(Policy.egress(for: .plainDNS), .throughTunnelToUpstreamResolver)
        XCTAssertTrue(Policy.egress(for: .plainDNS).permitsQuery)
    }

    func testTheEncryptedPresetsAreUnavailableForTheReasonTheyAre() {
        // DoH/DoT/DoQ are TCP or QUIC. Pushing them through a userspace WireGuard session needs
        // a TCP implementation on our side, which this feature is not going to grow.
        for transport in [
            DNSResolverTransport.dnsOverHTTPS, .dnsOverTLS, .dnsOverQUIC,
        ] {
            XCTAssertEqual(
                Policy.egress(for: transport),
                .unavailableWhileChained(.needsATransportTheTunnelCannotCarry, answer: .servfail),
                "\(transport)")
            XCTAssertFalse(Policy.egress(for: transport).permitsQuery)
        }
    }

    func testDeviceDNSIsCarriedThroughTheTunnelLikePlainDNS() {
        // Device DNS is plain UDP, so while chained it is redirected to the upstream's own
        // resolver THROUGH THE TUNNEL — the same egress as a configured `.plainDNS` preset, not
        // the physical-interface leak the old "would egress around the tunnel" verdict described.
        // The app DEFAULTS to device DNS, so the prior refusal was a total blackhole the moment a
        // user chained (device-verified, chimmy 2026-08-14). The carry is
        // ResolverOrchestrator's `.deviceDNS` arm; this pins the declarative seam to agree with it.
        XCTAssertEqual(Policy.egress(for: .deviceDNS), .throughTunnelToUpstreamResolver)
        XCTAssertTrue(Policy.egress(for: .deviceDNS).permitsQuery)
        // Still distinct from the encrypted presets, which remain unavailable.
        XCTAssertNotEqual(
            Policy.egress(for: .deviceDNS).logValue,
            Policy.egress(for: .dnsOverHTTPS).logValue)
    }

    func testTheBootstrapExceptionIsNotAResolverEgress() {
        // The one physical-interface egress chained mode has, and it is not a resolver query:
        // the endpoint HOSTNAME must resolve before a session exists, because the tunnel that
        // would carry the query is the tunnel being built.
        //
        // Modelled as its own case rather than left as a bypass — an exception nobody can see
        // is an exception nobody audits, and a reader would otherwise conclude no
        // physical-interface egress is possible and treat S1's bootstrap as a violation.
        //
        // It is reachable ONLY through its own entry point, so no configured resolver can
        // arrive there however the transport enum grows.
        // It is not a `ChainedResolverEgress` at all now. Naming the exception made it
        // auditable; giving it its own TYPE keeps it unreachable from the resolver path, which
        // matters because S6 wires that enum into the resolver pipeline — where a
        // physical-interface case any caller could select is the leak itself.
        //
        // The compiler proves the negative: no `egress(for:)` result can be this value,
        // because they are different types.
        XCTAssertEqual(
            Policy.endpointBootstrapEgress().logValue, "resolver-endpoint-bootstrap")
        for transport in [
            DNSResolverTransport.deviceDNS, .plainDNS, .dnsOverHTTPS, .dnsOverTLS, .dnsOverQUIC,
        ] {
            XCTAssertNotEqual(
                Policy.egress(for: transport).logValue,
                Policy.endpointBootstrapEgress().logValue,
                "\(transport) reported the bootstrap egress")
        }
    }

    func testEveryRefusalCarriesTheAnswerItGives() {
        // Refusing the I/O is only half of INV-DNS-1. Leaving the response unspecified lets
        // the caller invent one, and the obvious invention — let it time out — is
        // indistinguishable from a network problem and invites a retry against the same
        // refusal.
        // The encrypted presets only — device DNS is carried through the tunnel, not refused.
        for transport in [
            DNSResolverTransport.dnsOverHTTPS, .dnsOverTLS, .dnsOverQUIC,
        ] {
            guard case .unavailableWhileChained(_, let answer) = Policy.egress(for: transport)
            else { return XCTFail("\(transport) should be unavailable") }
            XCTAssertEqual(answer, .servfail, "\(transport)")
        }
    }

    // MARK: - The fallback ladder

    func testTheFallbackLadderIsSuspendedNotMerelyDiscouraged() {
        // Every rung is a physical-interface behaviour, so "fall back" and "leak" are the same
        // action here — and the ladder runs precisely when the tunnelled resolver is
        // struggling, which is the worst possible moment to resume egressing around the
        // tunnel.
        XCTAssertFalse(Policy.permitsDeviceDNSFallback(chainedIsLatched: true))
        XCTAssertFalse(Policy.permitsPhysicalInterfaceHealthProbes(chainedIsLatched: true))
    }

    func testNothingIsSuspendedWhenChainedIsNotLatched() {
        // The DNS-only path is untouched. A policy that suppressed the ladder unconditionally
        // would break today's shipping behaviour for a mode nobody is in.
        XCTAssertTrue(Policy.permitsDeviceDNSFallback(chainedIsLatched: false))
        XCTAssertTrue(Policy.permitsPhysicalInterfaceHealthProbes(chainedIsLatched: false))
    }

    func testSuspensionIsDrivenByTheLatchAndNothingElse() {
        // Both predicates are total over the one input, so there is no third state where a
        // caller could find them disagreeing.
        for latched in [true, false] {
            XCTAssertEqual(
                Policy.permitsDeviceDNSFallback(chainedIsLatched: latched),
                Policy.permitsPhysicalInterfaceHealthProbes(chainedIsLatched: latched),
                "the two must not diverge — a half-suspended ladder still leaks")
        }
    }

    // MARK: - The T1 rung (split tunnel only)

    /// The one conditional in a file of absolutes, and it turns on the LATCHED ROUTE PLAN.
    ///
    /// Full tunnel keeps the suspension whole: there the data path really does hide the
    /// destination, so DNS would be the only thing the local network could still see. Split
    /// tunnel already sends the connection itself out the physical interface, so the observer
    /// holds the destination address and the TLS SNI before any of this — refusing to send the
    /// name protects nothing and costs the lookup.
    func testTierOneMayLeavePhysicallyOnlyInASplitTunnel() {
        XCTAssertTrue(
            Policy.permitsTierOneFallbackOnPhysicalInterface(
                chainedIsLatched: true, routingPolicy: .splitTunnel),
            "split tunnel already discloses the destination on the same path")
        XCTAssertFalse(
            Policy.permitsTierOneFallbackOnPhysicalInterface(
                chainedIsLatched: true, routingPolicy: .fullTunnel),
            "full tunnel hides the destination, so the name would be the only leak")
    }

    /// A latched session whose routing policy cannot be named gets the FULL-tunnel answer.
    /// Spending a privacy boundary requires knowing which shape you are in.
    func testAnUnknownRoutingPolicyIsTreatedAsFullTunnel() {
        XCTAssertFalse(
            Policy.permitsTierOneFallbackOnPhysicalInterface(
                chainedIsLatched: true, routingPolicy: nil))
    }

    /// Outside chained mode this decision has nothing to say. The user's chosen resolver is
    /// T0 there and runs on the physical interface by the ordinary ladder, which
    /// ``permitsDeviceDNSFallback`` and the allowance already govern — a `true` here would be a
    /// second mechanism for a permission that is not this one's to grant.
    func testTheTierOneDecisionIsSilentOutsideChainedMode() {
        for policy: ChainedRoutingPolicy? in [.splitTunnel, .fullTunnel, nil] {
            XCTAssertFalse(
                Policy.permitsTierOneFallbackOnPhysicalInterface(
                    chainedIsLatched: false, routingPolicy: policy))
        }
    }

    /// The T1 permission does NOT relax the T0 suspension. A split tunnel changes nothing
    /// about where the PRIMARY resolves: the device-DNS LADDER stays suspended in every chained
    /// shape, because that ladder is reached by the primary's health and not by anything the user
    /// picked.
    ///
    /// The rung this permits is the resolver the user CHOSE. Since PR #592 that may BE device DNS
    /// — a user whose one selection is the network's resolver has asked for it — and none of the
    /// assertions below move, because they are about the ladder rather than the selection. Device
    /// DNS may be SELECTED as the rung; it may never be IMPOSED on one.
    func testASplitTunnelStillSuspendsTheTierZeroLadder() {
        XCTAssertFalse(Policy.permitsDeviceDNSFallback(chainedIsLatched: true))
        XCTAssertFalse(Policy.permitsPhysicalInterfaceHealthProbes(chainedIsLatched: true))
        XCTAssertEqual(
            Policy.egress(for: .plainDNS), .throughTunnelToUpstreamResolver,
            "T0 plain DNS is still carried, not released to the physical interface")
        XCTAssertFalse(Policy.egress(for: .dnsOverHTTPS).permitsQuery)
    }

    /// The T1 rung is NEVER bound to the tunnel, whatever the latch says.
    ///
    /// The allowance and the socket binding are separate decisions, and this is the one the
    /// socket asks. `socketBinding(chainedIsLatched: true, …)` pins to the utun — correct for
    /// T0, and precisely wrong for a rung whose whole purpose is to leave it. A rung the
    /// allowance had permitted onto the physical interface was still pinned to the tunnel and
    /// timed out exactly as before (Codex, PR #590).
    func testTheTierOneRungIsNeverBoundToTheTunnel() {
        // The ordinary split rung: the destination is not on the capture floor, so the routing
        // table decides, and a physical index being available does not change that.
        XCTAssertEqual(
            Policy.tierOneSocketBinding(
                destinationIsFloorClaimed: false,
                destinationIsProfileCovered: false,
                physicalInterfaceIndex: 9),
            .permitted(.systemChosen))

        // The F2 pin, when the floor claims the destination and the profile does not carry it,
        // is PHYSICAL — never the tunnel.
        let floorClaimed = Policy.tierOneSocketBinding(
            destinationIsFloorClaimed: true,
            destinationIsProfileCovered: false,
            physicalInterfaceIndex: 9)
        XCTAssertEqual(floorClaimed, .permitted(.boundToPhysical(interfaceIndex: 9)))
        XCTAssertNotEqual(floorClaimed, .permitted(.boundToTunnel(interfaceIndex: 9)))

        // And it differs from the T0 answer under the same latch — the property that was
        // missing, since nothing else proves the two seams disagree on purpose.
        XCTAssertEqual(
            Policy.socketBinding(chainedIsLatched: true, tunnelInterfaceIndex: 9),
            .permitted(.boundToTunnel(interfaceIndex: 9)))
        XCTAssertNotEqual(
            floorClaimed,
            Policy.socketBinding(chainedIsLatched: true, tunnelInterfaceIndex: 9))
    }

    /// The T1 binding does NOT try to out-route the user's own profile.
    ///
    /// `.systemChosen` follows the routing table, so a profile whose `AllowedIPs` already cover
    /// the T1 address carries the rung through the peer. F2's physical pin is scoped to
    /// destinations the profile does NOT carry; a profile-covered destination keeps
    /// `.systemChosen`, so the override the old Codex round (PR #590) proposed still cannot
    /// happen. Pinning it would disclose, on the local network, a name the user's own routes say
    /// belongs inside the tunnel — the split-tunnel justification for physical T1 rests on the
    /// destination ALREADY going direct, and it does not hold for one the profile routes in.
    func testTheTierOneBindingDoesNotOverrideTheProfilesOwnRoutes() {
        let profileCovered = Policy.tierOneSocketBinding(
            destinationIsFloorClaimed: true,
            destinationIsProfileCovered: true,
            physicalInterfaceIndex: 9)
        XCTAssertEqual(profileCovered, .permitted(.systemChosen))
        XCTAssertEqual(
            profileCovered.permittedBinding, .systemChosen,
            "an explicit physical pin here would route around the user's own AllowedIPs")
        // The tunnel pin is still not a value this seam produces, so the override cannot even
        // express itself as the other pin.
        XCTAssertNotEqual(
            Policy.tierOneSocketBinding(
                destinationIsFloorClaimed: true,
                destinationIsProfileCovered: false,
                physicalInterfaceIndex: 9),
            Policy.socketBinding(chainedIsLatched: true, tunnelInterfaceIndex: 9))
    }

    // MARK: - F2 destination-scoped binding

    /// The whole point of F2: a floor-claimed destination the profile does not carry must be
    /// pinned physically, or the claimed route draws the query back into the tunnel.
    func testAFloorClaimedDestinationWithNoProfileCoverageBindsPhysical() {
        XCTAssertEqual(
            Policy.destinationSocketBinding(
                destinationIsFloorClaimed: true,
                destinationIsProfileCovered: false,
                physicalInterfaceIndex: 7),
            .permitted(.boundToPhysical(interfaceIndex: 7)))
    }

    /// Profile coverage still wins — Lava never overrides the user's own `AllowedIPs`.
    func testAProfileCoveredDestinationIsNeverPinnedPhysically() {
        XCTAssertEqual(
            Policy.destinationSocketBinding(
                destinationIsFloorClaimed: true,
                destinationIsProfileCovered: true,
                physicalInterfaceIndex: 7),
            .permitted(.systemChosen))
    }

    /// Nothing is claimed, so there is nothing to strand; the routing table is the shipped
    /// answer and F2 must not change it.
    func testADestinationOutsideTheFloorStaysSystemChosen() {
        XCTAssertEqual(
            Policy.destinationSocketBinding(
                destinationIsFloorClaimed: false,
                destinationIsProfileCovered: false,
                physicalInterfaceIndex: 7),
            .permitted(.systemChosen))
    }

    /// A claimed, profile-uncovered destination with no usable physical index REFUSES.
    ///
    /// `.systemChosen` here would be the strand F2 exists to prevent: the tunnel's floor claim
    /// draws the destination's route into the NE, so an unbound socket follows the routing table
    /// straight back into the tunnel and a peer that does not carry the address refuses it. `nil`
    /// is "before the first path update" and `0` is the kernel's unbind value; neither can pin, so
    /// the decision fails closed (`INV-DNS-1`) rather than re-entering the claim.
    ///
    /// The refusal is ``ChainedResolverSocketBinding/refusedNoPhysicalInterface``, NOT
    /// ``ChainedResolverSocketBinding/refusedNoTunnelInterface``: the tunnel interface is exactly
    /// what IS known here, and reporting the missing PHYSICAL pin as a missing TUNNEL interface
    /// sent a reader hunting a `virtualInterface` lag that was not happening (Kilo, PR #747).
    func testAFloorClaimedDestinationWithNoPhysicalIndexIsRefused() {
        for index in [UInt32?.none, UInt32(0)] {
            let decision = Policy.destinationSocketBinding(
                destinationIsFloorClaimed: true,
                destinationIsProfileCovered: false,
                physicalInterfaceIndex: index)
            XCTAssertEqual(
                decision, .refusedNoPhysicalInterface,
                "index \(String(describing: index)) cannot pin a claimed destination; it must refuse")
            XCTAssertNotEqual(
                decision, .refusedNoTunnelInterface,
                "the tunnel interface is known; the missing pin is the PHYSICAL one")
            XCTAssertNil(
                decision.permittedBinding,
                "a refusal must not be convertible into a usable binding")
        }
    }

    /// The T1 rung inherits the same fail-closed answer: a floor-claimed, profile-uncovered
    /// destination with no known physical index refuses rather than re-enter the claim.
    func testTheTierOneRungRefusesAClaimedDestinationWithNoPhysicalIndex() {
        XCTAssertEqual(
            Policy.tierOneSocketBinding(
                destinationIsFloorClaimed: true,
                destinationIsProfileCovered: false,
                physicalInterfaceIndex: nil),
            .refusedNoPhysicalInterface)
    }

    /// Profile coverage is judged through the SAME prefix parser the data path builds its
    /// inbound allowlist from, so "covered" cannot disagree with the peer's cryptokey routing.
    func testAllowedIPsCoverageUsesTheDataPathsOwnPrefixParser() {
        XCTAssertTrue(Policy.allowedIPsCover(destination: "1.1.1.1", allowedIPs: ["1.0.0.0/8"]))
        XCTAssertTrue(
            Policy.allowedIPsCover(
                destination: "2606:4700:4700::1111", allowedIPs: ["2606:4700:4700::/48"]))
        XCTAssertFalse(Policy.allowedIPsCover(destination: "9.9.9.9", allowedIPs: ["1.0.0.0/8"]))
        XCTAssertFalse(
            Policy.allowedIPsCover(
                destination: "1.1.1.1", allowedIPs: ["2606:4700:4700::/48"]),
            "families never cross")
        XCTAssertFalse(
            Policy.allowedIPsCover(destination: "not-an-address", allowedIPs: ["0.0.0.0/0"]),
            "an unparseable destination is not evidence of coverage")
    }

    // MARK: - Failing closed

    func testAnUnavailableTransportDoesNotFallBackToAnAvailableOne() {
        // The shape of the bug this prevents: "DoH is unavailable, so use device DNS". Both
        // are refusals, and neither is a suggestion to try the other — INV-DNS-1 says a
        // failure answers fail-closed, which still filters and still protects.
        // The encrypted presets — device DNS is carried, not a refusal, so it is not part of the
        // "unavailable transport must not fall back" set.
        for transport in [
            DNSResolverTransport.dnsOverHTTPS, .dnsOverTLS, .dnsOverQUIC,
        ] {
            let egress = Policy.egress(for: transport)
            XCTAssertFalse(egress.permitsQuery, "\(transport)")
            XCTAssertNotEqual(egress, .throughTunnelToUpstreamResolver, "\(transport)")
        }
    }

    func testEveryTransportResolvesToExactlyOneEgress() {
        // Totality, asserted against expected values rather than by switching and continuing —
        // a switch over every case cannot fail and proves nothing about the mapping.
        let expected: [(DNSResolverTransport, ChainedResolverEgress)] = [
            (.plainDNS, .throughTunnelToUpstreamResolver),
            (.dnsOverHTTPS, .unavailableWhileChained(
                 .needsATransportTheTunnelCannotCarry, answer: .servfail)),
            (.dnsOverTLS, .unavailableWhileChained(
                 .needsATransportTheTunnelCannotCarry, answer: .servfail)),
            (.dnsOverQUIC, .unavailableWhileChained(
                 .needsATransportTheTunnelCannotCarry, answer: .servfail)),
            (.deviceDNS, .throughTunnelToUpstreamResolver),
        ]
        for (transport, egress) in expected {
            XCTAssertEqual(Policy.egress(for: transport), egress, "\(transport)")
        }
        XCTAssertEqual(expected.count, 5, "a transport was added without a chained decision")
    }

    // MARK: - Logging

    func testLogValuesDistinguishCarriedFromUnavailable() {
        // Two outcomes now reach the resolver egress: plain and device DNS are both carried
        // through the tunnel (same log value), and the encrypted presets are unavailable. The
        // `.wouldEgressAroundTheTunnel` reason is no longer produced here — device DNS is carried,
        // not refused — so the distinct log values a reader sees for a configured transport are
        // these two.
        XCTAssertEqual(Policy.egress(for: .plainDNS).logValue, "resolver-through-tunnel")
        XCTAssertEqual(Policy.egress(for: .deviceDNS).logValue, "resolver-through-tunnel")
        XCTAssertNotEqual(
            Policy.egress(for: .dnsOverHTTPS).logValue,
            Policy.egress(for: .plainDNS).logValue)
    }
    // MARK: - Socket binding (S8.7b)

    /// The load-bearing property of `socketBinding`: while chained there is no answer that lets
    /// the routing table choose. `.systemChosen` means "the physical interface", and that is the
    /// leak this whole policy exists to close — so the chained branch must produce either a pin
    /// or a refusal, never a permission to egress unpinned.
    func testChainedNeverYieldsASystemChosenSocket() {
        for index in [UInt32(1), 95, .max] {
            XCTAssertEqual(
                Policy.socketBinding(chainedIsLatched: true, tunnelInterfaceIndex: index),
                .permitted(.boundToTunnel(interfaceIndex: index)))
        }

        // Zero is refused alongside nil, and for a reason the policy layer cannot see: at the
        // socket, `IP_BOUND_IF` reads 0 as "unbind" and REPORTS SUCCESS. Here it simply means the
        // provider handed us an interface it does not really have.
        XCTAssertEqual(
            Policy.socketBinding(chainedIsLatched: true, tunnelInterfaceIndex: 0),
            .refusedNoTunnelInterface,
            "index 0 is not an interface; permitting it would produce a socket the kernel silently "
                + "leaves unpinned")

        XCTAssertEqual(
            Policy.socketBinding(chainedIsLatched: true, tunnelInterfaceIndex: nil),
            .refusedNoTunnelInterface,
            "chained with no known tunnel interface has no safe socket to open; the only thing an "
                + "unpinned socket can do here is the leak")

        XCTAssertNil(
            Policy.socketBinding(chainedIsLatched: true, tunnelInterfaceIndex: nil).permittedBinding,
            "a refusal must not be convertible into a usable binding")
    }

    /// DNS-only is unchanged, including when an interface index happens to be available. The
    /// tunnel exists in DNS-only mode too and has an index; pinning to it there would route plain
    /// DNS into a tunnel that is not carrying traffic, which is a wedge, not a privacy win.
    func testDNSOnlyLetsTheRoutingTableChooseEvenWhenATunnelInterfaceIsKnown() {
        XCTAssertEqual(
            Policy.socketBinding(chainedIsLatched: false, tunnelInterfaceIndex: nil),
            .permitted(.systemChosen))
        XCTAssertEqual(
            Policy.socketBinding(chainedIsLatched: false, tunnelInterfaceIndex: 95),
            .permitted(.systemChosen))
    }

}
