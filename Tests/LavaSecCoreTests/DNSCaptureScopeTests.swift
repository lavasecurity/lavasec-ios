import XCTest

@testable import LavaSecKit

/// `INV-DNS-7` — the DNS capture set is the ROUTE set.
///
/// The contract these assert is a coverage claim, so the failure they exist to catch is an
/// over-claim rather than a crash: a future route shape that stops capturing hardcoded-resolver
/// queries while some sentence still says every lookup is filtered. Each case derives its scope
/// from a real `TunnelRoutePlan`, so the claim cannot drift from the routes the tunnel installs.
final class DNSCaptureScopeTests: XCTestCase {
    /// A validated upstream. `allowedIPs` defaults to a full tunnel; a non-covering set derives
    /// a split tunnel, exactly as `TunnelRoutePlanTests` builds them.
    private static func configuration(
        clientAddress: String = "10.64.0.5",
        allowedIPs: [String] = ["0.0.0.0/0"]
    ) -> ChainedUpstreamConfiguration {
        try! ChainedUpstreamConfiguration(
            endpointHost: "vpn.example.com",
            endpointPort: 51_820,
            peerPublicKey: Data(1...32).base64EncodedString(),
            clientAddress: clientAddress,
            allowedIPs: allowedIPs,
            interfaceMTU: nil)
    }

    func testTheScopeIsDerivedFromTheRoutesEachDataPathClaims() {
        let fullTunnel = Self.configuration()
        XCTAssertEqual(fullTunnel.routingPolicy, .fullTunnel)
        XCTAssertEqual(
            TunnelRoutePlan.make(for: .chainedUpstream(fullTunnel)).dnsCaptureScope,
            .everyDestination,
            "a tunnel claiming 0.0.0.0/0 sees every clear-text DNS datagram on the device"
        )

        // The case a two-mode reading of this feature gets wrong. Split claims its AllowedIPs
        // plus the DNS-capture /24 (and, since 2026-09-19, `::/0` to blackhole v6), but not the
        // IPv4 default route, so a hardcoded IPv4 resolver at a DIRECT destination still egresses
        // unfiltered — the signed-off INV-DNS-1 scope of infra #198 §3.3, stated in
        // TunnelRoutePlan's own split branch.
        //
        // `100.64.0.0/10` is not an arbitrary fixture: it is the Tailscale profile this feature
        // is repeatedly tested against, whose `DNS = 100.100.100.100` (MagicDNS) sits INSIDE the
        // claimed /10 while `8.8.8.8` sits outside it. One profile, both answers — which is why
        // the scope-level Boolean asks about EVERY destination and not about "hardcoded
        // resolvers".
        let splitTunnel = Self.configuration(
            clientAddress: "10.77.0.2", allowedIPs: ["100.64.0.0/10", "10.1.2.3/8"])
        XCTAssertEqual(splitTunnel.routingPolicy, .splitTunnel)
        XCTAssertEqual(
            TunnelRoutePlan.make(for: .chainedUpstream(splitTunnel)).dnsCaptureScope,
            .systemResolverAndClaimedRoutes,
            "split leaves the IPv4 default unclaimed, so it cannot claim every destination"
        )

        XCTAssertEqual(
            TunnelRoutePlan.make(for: .dnsOnly).dnsCaptureScope,
            .systemResolverAndClaimedRoutes,
            "DNS-only claims the capture /24 alone — the system resolver, and nothing beyond it"
        )
    }

    func testOnlyTheFullTunnelCapturesEveryHardcodedResolverDestination() {
        // The product question the scope exists to answer, asserted separately from the mapping
        // so a future third case cannot quietly inherit the strongest claim.
        //
        // EVERY is the load-bearing word, not a flourish. A split profile whose AllowedIPs cover
        // the resolver DOES capture it: the query is drawn into the tunnel, where port-53
        // interception catches it as usual. So the claimed-routes scope captures SOME hardcoded
        // destinations, and only the full tunnel captures them all (Codex, PR #728).
        XCTAssertTrue(DNSCaptureScope.everyDestination.capturesEveryHardcodedResolverDestination)
        XCTAssertFalse(
            DNSCaptureScope.systemResolverAndClaimedRoutes.capturesEveryHardcodedResolverDestination
        )

        XCTAssertNotEqual(
            DNSCaptureScope.everyDestination.logValue,
            DNSCaptureScope.systemResolverAndClaimedRoutes.logValue,
            "a field log that cannot tell the two scopes apart cannot answer a coverage question"
        )
    }

    func testASurrenderToDNSOnlyNarrowsTheCaptureSet() {
        // The fallback this invariant exists to make explicit: INV-CHAIN-1 surrenders a chained
        // session to DNS-only, and that is a COVERAGE change as well as a routing one. Asserted
        // as a comparison rather than two constants so the direction is what fails if it flips.
        let chained = TunnelRoutePlan.make(for: .chainedUpstream(Self.configuration())).dnsCaptureScope
        let surrendered = TunnelRoutePlan.make(for: .dnsOnly).dnsCaptureScope

        XCTAssertTrue(chained.capturesEveryHardcodedResolverDestination)
        XCTAssertFalse(
            surrendered.capturesEveryHardcodedResolverDestination,
            "a surrender narrows capture back to the system resolver — a disclosure must not imply otherwise"
        )
    }

    func testASplitConfigurationThatCoversTheDefaultRouteIsNotAThirdShape() {
        // `ChainedRoutingPolicy` makes the two policies disjoint by route set: AllowedIPs that
        // happen to cover everything ARE a full tunnel. So the scope follows the claim, and no
        // separate "split that covers everything" case can exist to be forgotten.
        let covering = Self.configuration(allowedIPs: ["0.0.0.0/0"])
        XCTAssertEqual(covering.routingPolicy, .fullTunnel)
        XCTAssertEqual(
            TunnelRoutePlan.make(for: .chainedUpstream(covering)).dnsCaptureScope,
            .everyDestination
        )

        // The two-halves idiom is the case a literal `0.0.0.0/0` check would miss:
        // `coversIPv4DefaultRoute` sweeps for a gap-free span, so this derives .fullTunnel, and
        // the full-tunnel branch emits the literal default route whatever the prefixes spelled.
        // The scope therefore follows the CLAIM rather than the profile's spelling.
        let twoHalves = Self.configuration(allowedIPs: ["0.0.0.0/1", "128.0.0.0/1"])
        XCTAssertEqual(twoHalves.routingPolicy, .fullTunnel)
        XCTAssertEqual(
            TunnelRoutePlan.make(for: .chainedUpstream(twoHalves)).dnsCaptureScope,
            .everyDestination,
            "a gap-free prefix set claims 0.0.0.0/0, so its scope must be the full-tunnel one"
        )
    }

    func testAPlanThatClaimsAllIPv4ButNoIPv6DoesNotEarnTheStrongestScope() {
        // The over-claim Codex caught (PR #728). `TunnelRoutePlan.make` always pairs `0.0.0.0/0`
        // with `::/0`, but the public initializer does not, and the repo builds exactly this
        // shape in `TunnelRoutePlanTests.testTheLeakPredicateActuallyDetectsALeak`. On such a
        // plan IPv6 stays on the physical interface, so a hardcoded IPv6 resolver is neither
        // intercepted nor dropped — it simply leaves, and `.everyDestination` would be false.
        let leaky = TunnelRoutePlan(
            tunnelAddress: "10.255.0.2",
            tunnelSubnetMask: "255.255.255.0",
            dnsServerAddress: "10.255.0.1",
            routeDescription: "0.0.0.0/0",
            includedIPv4Routes: [
                TunnelRoutePlan.IPv4Route(destinationAddress: "0.0.0.0", subnetMask: "0.0.0.0")
            ],
            mtu: 1280
        )

        XCTAssertTrue(leaky.claimsDefaultRoute, "the IPv4 half of the strongest scope is satisfied")
        XCTAssertTrue(leaky.leaksIPv6AroundTheTunnel, "and the IPv6 half is not — this is the leak shape")
        XCTAssertEqual(
            leaky.dnsCaptureScope,
            .systemResolverAndClaimedRoutes,
            "IPv6 escaping the tunnel disqualifies the every-destination claim"
        )
        XCTAssertFalse(leaky.dnsCaptureScope.capturesEveryHardcodedResolverDestination)

        // The contrast that makes the term load-bearing rather than defensive: the real
        // full-tunnel plan claims both families, so it keeps the strongest scope.
        let full = TunnelRoutePlan.make(for: .chainedUpstream(Self.configuration()))
        XCTAssertTrue(full.claimsDefaultRoute)
        XCTAssertFalse(full.leaksIPv6AroundTheTunnel, "make() pairs 0.0.0.0/0 with ::/0")
        XCTAssertEqual(full.dnsCaptureScope, .everyDestination)
    }

    func testAHandBuiltTwoHalvesPlanUnderClaimsRatherThanOverClaims() {
        // Codex raised the mirror of the IPv6 case (PR #728): `claimsDefaultRoute` is a literal
        // /0 match, so a hand-built plan spelling the default route as two halves reports the
        // weaker scope though every IPv4 destination is claimed.
        //
        // Pinned as-is rather than fixed, and the direction is the reason. This UNDER-claims,
        // which cannot produce a false safety claim; re-deriving coverage here would add a
        // second definition of "claims everything" beside `claimsDefaultRoute` AND desync this
        // from `leaksIPv6AroundTheTunnel`, which keys on the same literal — the two-halves plan
        // would read `.everyDestination` while the leak predicate saw no default route to check
        // IPv6 against. The aggregate sweep belongs where it already is: on the user's
        // `AllowedIPs`, one layer up, where `coversIPv4DefaultRoute` normalises this to a
        // literal /0 before any plan is built — pinned by
        // `testASplitConfigurationThatCoversTheDefaultRouteIsNotAThirdShape` above.
        let twoHalvesByHand = TunnelRoutePlan(
            tunnelAddress: "10.255.0.2",
            tunnelSubnetMask: "255.255.255.0",
            dnsServerAddress: "10.255.0.1",
            routeDescription: "0.0.0.0/1, 128.0.0.0/1",
            includedIPv4Routes: [
                TunnelRoutePlan.IPv4Route(destinationAddress: "0.0.0.0", subnetMask: "128.0.0.0"),
                TunnelRoutePlan.IPv4Route(destinationAddress: "128.0.0.0", subnetMask: "128.0.0.0")
            ],
            mtu: 1280
        )

        XCTAssertFalse(twoHalvesByHand.claimsDefaultRoute, "a literal /0 match, by design")
        XCTAssertEqual(
            twoHalvesByHand.dnsCaptureScope,
            .systemResolverAndClaimedRoutes,
            "under-claiming is the safe direction; the aggregate sweep lives on AllowedIPs, not here"
        )
    }

    func testAClaimedIPv6RouteWithNoInstallableSettingsDoesNotEarnTheStrongestScope() {
        // Codex's fourth finding (PR #728), and the subtlest of them: a route array is a CLAIM,
        // not an installation. `makeTunnelNetworkSettings` hands iOS `NEIPv6Settings` only when
        // the address, the prefix length AND a route are all present, so this plan — which does
        // claim ::/0 — gets no IPv6 settings at all and leaves v6 on the physical interface.
        // `leaksIPv6AroundTheTunnel` reports no leak here because it asks only about the route
        // claim, which is why installability is a separate term rather than folded into it.
        let claimedButNotInstalled = TunnelRoutePlan(
            tunnelAddress: "10.64.0.5",
            tunnelSubnetMask: "255.255.255.255",
            dnsServerAddress: "10.255.0.1",
            routeDescription: "0.0.0.0/0, ::/0",
            includedIPv4Routes: [
                TunnelRoutePlan.IPv4Route(destinationAddress: "0.0.0.0", subnetMask: "0.0.0.0")
            ],
            tunnelIPv6Address: nil,
            tunnelIPv6PrefixLength: nil,
            includedIPv6Routes: [TunnelRoutePlan.IPv6Route(destinationAddress: "::", prefixLength: 0)],
            mtu: 1280
        )

        XCTAssertTrue(claimedButNotInstalled.claimsDefaultRoute)
        XCTAssertTrue(claimedButNotInstalled.claimsIPv6DefaultRoute, "the route IS claimed")
        XCTAssertFalse(
            claimedButNotInstalled.leaksIPv6AroundTheTunnel,
            "the leak predicate asks about the route claim alone, and by that question there is none"
        )
        XCTAssertFalse(
            claimedButNotInstalled.installsIPv6Settings,
            "but with no address or prefix length iOS is handed no NEIPv6Settings"
        )
        XCTAssertEqual(
            claimedButNotInstalled.dnsCaptureScope,
            .systemResolverAndClaimedRoutes,
            "a claim iOS was never asked to install cannot support an every-destination claim"
        )

        // The term must not make `.everyDestination` unreachable. `make` never emits the mixed
        // shape — a full tunnel and (since 2026-09-19) a split tunnel both set all three, while
        // DNS-only sets none and is false here by design — so a real full-tunnel plan still earns
        // the strongest scope.
        let real = TunnelRoutePlan.make(for: .chainedUpstream(Self.configuration()))
        XCTAssertTrue(real.installsIPv6Settings)
        XCTAssertEqual(real.dnsCaptureScope, .everyDestination)
    }

    func testTheIPv6InstallabilityTermMirrorsTheProviderCondition() throws {
        // `installsIPv6Settings` is only worth anything if it says what the provider does. The
        // provider is out of the package, so this pins the three conjuncts it branches on — a
        // fourth condition appearing there without one here would make the coverage claim lie.
        let lifecycle = try readSource(.packetTunnelProviderLifecycle)

        XCTAssertTrue(
            sourceContainsInOrder([
                "if let ipv6Address = plan.tunnelIPv6Address,",
                "let ipv6PrefixLength = plan.tunnelIPv6PrefixLength,",
                "!plan.includedIPv6Routes.isEmpty {",
                "settings.ipv6Settings = ipv6",
            ], in: lifecycle),
            "the provider installs IPv6 on exactly address + prefix + routes; installsIPv6Settings mirrors it"
        )
    }

    func testTheInvariantRegistryCarriesTheCaptureContract() throws {
        let invariants = try readSource(.invariants)

        XCTAssertTrue(
            invariants.contains("### INV-DNS-7 — The DNS capture set is the route set"),
            "the registry is where a cited ID is resolved; an uncited invariant is a stale comment waiting to happen"
        )
        XCTAssertTrue(invariants.contains("DNSCaptureScope.everyDestination"))
        XCTAssertTrue(invariants.contains("DNSCaptureScope.systemResolverAndClaimedRoutes"))
        XCTAssertTrue(
            invariants.contains("split tunnel"),
            "the split shape is the one a two-mode reading omits, so the registry must name it"
        )
    }

    func testTheProviderLogsTheCaptureScopeBesideTheClaimedRoute() throws {
        // Provider wiring: out of the package, so no executable test can observe it. The pin is
        // that the scope reaches the settings log DERIVED from the plan — a hand-spelled string
        // here would be the second description of one routing the plan type exists to prevent.
        let core = try readSource(.packetTunnelProviderCore)
        let lifecycle = try readSource(.packetTunnelProviderLifecycle)

        XCTAssertTrue(
            core.contains("let dnsCaptureScope: DNSCaptureScope"),
            "the settings bundle carries the scope the session actually claimed"
        )
        XCTAssertTrue(
            sourceContainsInOrder([
                "let plan = TunnelRoutePlan.make(",
                "dnsCaptureScope: plan.dnsCaptureScope",
            ], in: lifecycle),
            "the scope must be derived from the plan, never spelled per mode"
        )
        XCTAssertTrue(
            sourceContainsInOrder([
                "\"route\": settingsBundle.routeDescription",
                "\"dnsCapture\": settingsBundle.dnsCaptureScope.logValue",
            ], in: lifecycle),
            "a capture-coverage question is answered from the same log line as the claimed route"
        )

        // EVERY settings-apply site, not just startup. The device log is bounded, so on a
        // long-lived session the startup event rotates out and the reapply record is all a field
        // capture has left — instrumenting one site would answer the coverage question for a
        // session that flapped recently and not for one that did not (Codex, PR #728).
        let networkPath = try readSource(.packetTunnelProviderNetworkPath)
        XCTAssertTrue(
            sourceContainsInOrder([
                "event: \"network-settings-reapply-begin\"",
                "\"route\": settingsBundle.routeDescription",
                "\"dnsCapture\": settingsBundle.dnsCaptureScope.logValue",
            ], in: networkPath),
            "the reapply path must carry the scope too, or a rotated log loses it"
        )
        XCTAssertTrue(
            sourceContainsInOrder([
                "event: \"dns-patch-startup-settings-begin\"",
                "\"route\": settingsBundle.routeDescription",
                "\"dnsCapture\": settingsBundle.dnsCaptureScope.logValue",
                "\"dataPath\": settingsBundle.mode.logValue",
            ], in: lifecycle),
            "a translated-route startup install must report its actual capture scope too"
        )
    }
}
