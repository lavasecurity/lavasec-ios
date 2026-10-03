import XCTest

@testable import LavaSecKit

final class TunnelRoutePlanTests: XCTestCase {
    /// A validated upstream, since the chained mode now carries one (C7). `allowedIPs`
    /// defaults to a full tunnel; pass a non-covering set to derive a split tunnel.
    private static func configuration(
        clientAddress: String = "10.64.0.5",
        allowedIPs: [String] = ["0.0.0.0/0"],
        interfaceMTU: UInt16? = nil
    ) -> ChainedUpstreamConfiguration {
        try! ChainedUpstreamConfiguration(
            endpointHost: "vpn.example.com",
            endpointPort: 51_820,
            peerPublicKey: Data(1...32).base64EncodedString(),
            clientAddress: clientAddress,
            allowedIPs: allowedIPs,
            interfaceMTU: interfaceMTU)
    }

    /// The chained mode most tests here need; address distinct from every hardcoded
    /// tunnel constant, so an assertion against it cannot pass by coincidence.
    private static let chainedMode = TunnelDataPathMode.chainedUpstream(configuration())

    func testDNSOnlyClaimsOnlyTheTunnelSubnet() {
        let plan = TunnelRoutePlan.make(for: .dnsOnly)

        XCTAssertEqual(plan.tunnelAddress, "10.255.0.2")
        XCTAssertEqual(plan.tunnelSubnetMask, "255.255.255.0")
        XCTAssertEqual(plan.dnsServerAddress, "10.255.0.1")
        XCTAssertEqual(plan.routeDescription, "10.255.0.0/24")
        XCTAssertEqual(plan.mtu, 1280)
        XCTAssertEqual(
            plan.includedIPv4Routes,
            [TunnelRoutePlan.IPv4Route(destinationAddress: "10.255.0.0", subnetMask: "255.255.255.0")]
        )
        XCTAssertFalse(
            plan.claimsDefaultRoute,
            "DNS-only must never claim traffic it does not forward"
        )
    }

    func testChainedClaimsTheDefaultRoute() {
        let plan = TunnelRoutePlan.make(for: Self.chainedMode)

        XCTAssertTrue(plan.claimsDefaultRoute)
        XCTAssertEqual(
            plan.includedIPv4Routes,
            [TunnelRoutePlan.IPv4Route(destinationAddress: "0.0.0.0", subnetMask: "0.0.0.0")]
        )
        // The description is what the device log emits as the claimed route, so it must
        // name every family actually claimed — otherwise a field log cannot tell whether
        // IPv6 was captured and dropped.
        XCTAssertEqual(plan.routeDescription, "0.0.0.0/0, ::/0")
        XCTAssertTrue(plan.routeDescription.contains("::/0"), "IPv6 capture is invisible in diagnostics")
    }

    func testQADNSOnlyIPv6AdvertisesOnlyItsLocalResolverWithoutDefaultRoutes() {
        let plan = TunnelRoutePlan.make(
            for: .dnsOnly, dnsCaptureResolverAddresses: [], advertisesIPv6DNSInDNSOnly: true)
        XCTAssertEqual(plan.dnsServerIPv6Address, "fd00:1a7a::1")
        XCTAssertEqual(plan.tunnelIPv6Address, "fd00:1a7a::2")
        XCTAssertEqual(plan.includedIPv6Routes, [
            .init(destinationAddress: "fd00:1a7a::", prefixLength: 64)
        ])
        XCTAssertEqual(plan.includedIPv4Routes, TunnelRoutePlan.make(for: .dnsOnly).includedIPv4Routes)
        XCTAssertFalse(plan.claimsDefaultRoute)
        XCTAssertFalse(plan.claimsIPv6DefaultRoute)
        XCTAssertNil(TunnelRoutePlan.make(for: .dnsOnly).dnsServerIPv6Address)
        XCTAssertTrue(TunnelRoutePlan.make(for: .dnsOnly).includedIPv6Routes.isEmpty)
    }

    func testQADNSOnlyIPv6OptionCannotAlterChainedRoutes() {
        for mode in [Self.chainedMode, .chainedUpstream(Self.configuration(allowedIPs: ["10.0.0.0/8"]))] {
            let ordinary = TunnelRoutePlan.make(for: mode)
            let comparison = TunnelRoutePlan.make(
                for: mode, dnsCaptureResolverAddresses: [], advertisesIPv6DNSInDNSOnly: true)
            XCTAssertEqual(comparison.includedIPv4Routes, ordinary.includedIPv4Routes)
            XCTAssertEqual(comparison.includedIPv6Routes, ordinary.includedIPv6Routes)
            XCTAssertEqual(comparison.dnsServerIPv6Address, ordinary.dnsServerIPv6Address)
        }
    }

    func testChainedTakesTheConfiguredAddressAndKeepsTheResolver() {
        // This test used to pin the OPPOSITE: `chained.tunnelAddress == dnsOnly.tunnelAddress`,
        // the exact hardcoding C7 removes. An interface numbered 10.255.0.2 has every
        // encapsulated packet dropped by the peer, whose AllowedIPs permit only the address
        // it assigned — after the tunnel reports established, with 0.0.0.0/0 claimed.
        let dnsOnly = TunnelRoutePlan.make(for: .dnsOnly)
        let chained = TunnelRoutePlan.make(
            for: .chainedUpstream(Self.configuration(clientAddress: "10.64.0.5")))

        XCTAssertEqual(
            chained.tunnelAddress, "10.64.0.5",
            "the chained interface must be numbered with the configured [Interface] Address")
        XCTAssertNotEqual(chained.tunnelAddress, dnsOnly.tunnelAddress)
        // A host mask: the config carries a bare address, and with 0.0.0.0/0 claimed the
        // interface subnet decides nothing — a wider mask would only claim an on-link
        // subnet the peer never assigned.
        XCTAssertEqual(chained.tunnelSubnetMask, "255.255.255.255")

        // What genuinely does not change: the DNS proxy answers on the same address in both
        // modes, so nothing keyed on it breaks when the mode changes — and it deliberately
        // does NOT move into the configured subnet, because queries reach it through the
        // claimed default route rather than on-link.
        XCTAssertEqual(chained.dnsServerAddress, dnsOnly.dnsServerAddress)
    }

    func testDNSOnlyDefaultRouteExperimentCannotChangeChainedRoutes() {
        for allowedIPs in [["0.0.0.0/0"], ["100.64.0.0/10"]] {
            let mode = TunnelDataPathMode.chainedUpstream(Self.configuration(allowedIPs: allowedIPs))
            XCTAssertEqual(TunnelRoutePlan.make(for: mode), TunnelRoutePlan.make(
                for: mode, dnsCaptureResolverAddresses: [], declaresDefaultRoutesInDNSOnly: true))
        }
    }

    func testTheChainedAddressFollowsTheConfigurationRatherThanAnyConstant() {
        // Two configs, two plans. If the factory read a constant — old or new — the two
        // plans would agree and this fails.
        let first = TunnelRoutePlan.make(
            for: .chainedUpstream(Self.configuration(clientAddress: "10.64.0.5")))
        let second = TunnelRoutePlan.make(
            for: .chainedUpstream(Self.configuration(clientAddress: "192.168.7.2")))

        XCTAssertEqual(first.tunnelAddress, "10.64.0.5")
        XCTAssertEqual(second.tunnelAddress, "192.168.7.2")
    }

    func testTheConfiguredMTUReachesThePlanAndItsAbsenceYieldsTheFloor() {
        // D5: `[Interface] MTU` when present, else 1280. The sub-floor case cannot reach
        // here at all — the configuration boundary refuses it at construction
        // (ChainedUpstreamConfigurationTests.testASubFloorInterfaceMTUIsRefusedNotClamped),
        // so a chained plan with an illegal MTU is unrepresentable rather than clamped.
        let configured = TunnelRoutePlan.make(
            for: .chainedUpstream(Self.configuration(interfaceMTU: 1420)))
        XCTAssertEqual(configured.mtu, 1420, "the configured MTU must reach the plan")

        let absent = TunnelRoutePlan.make(for: .chainedUpstream(Self.configuration()))
        XCTAssertEqual(absent.mtu, 1280, "no configured MTU means the IPv6 minimum")
    }

    func testEveryModeRunsALegalMTUForWhatItClaims() {
        // An interface carrying IPv6 below 1280 is out of spec (RFC 8200 §5) and iOS may
        // refuse the settings rather than degrade. Stated over all modes so a future one
        // cannot claim ::/0 at a smaller MTU.
        for mode in [TunnelDataPathMode.dnsOnly, Self.chainedMode] {
            XCTAssertTrue(
                TunnelRoutePlan.make(for: mode).mtuIsLegalForClaimedFamilies,
                "\(mode) claims IPv6 at an MTU below the v6 floor"
            )
        }
    }

    func testThePartialIPv6PlanIsHeldToTheFloorToo() {
        // The floor applies to a link that carries IPv6, not to one that carries ALL of it.
        // A plan with an IPv6 address and a /64 — no default route — is equally out of spec
        // below 1280, and a predicate keyed on the default route alone waves it through.
        let partial = TunnelRoutePlan(
            tunnelAddress: "10.255.0.2", tunnelSubnetMask: "255.255.255.0",
            dnsServerAddress: "10.255.0.1", routeDescription: "partial",
            includedIPv4Routes: [],
            tunnelIPv6Address: "fd00:1a7a::2", tunnelIPv6PrefixLength: 64,
            includedIPv6Routes: [TunnelRoutePlan.IPv6Route(destinationAddress: "fd00:1a7a::", prefixLength: 64)],
            mtu: 1200
        )
        XCTAssertTrue(partial.carriesIPv6)
        XCTAssertFalse(partial.claimsIPv6DefaultRoute, "not a default route — the old predicate missed this")
        XCTAssertFalse(partial.mtuIsLegalForClaimedFamilies)
    }

    func testAnAddressWithoutRoutesStillCarriesIPv6() {
        // An address alone puts IPv6 on the interface, so the floor applies.
        let addressOnly = TunnelRoutePlan(
            tunnelAddress: "10.255.0.2", tunnelSubnetMask: "255.255.255.0",
            dnsServerAddress: "10.255.0.1", routeDescription: "v4 only",
            includedIPv4Routes: [],
            tunnelIPv6Address: "fd00:1a7a::2", tunnelIPv6PrefixLength: 64,
            includedIPv6Routes: [], mtu: 1200
        )
        XCTAssertTrue(addressOnly.carriesIPv6)
        XCTAssertFalse(addressOnly.mtuIsLegalForClaimedFamilies)
    }

    func testAPlanWithNoIPv6HasNoFloorToMeet() {
        // DNS-only carries no IPv6, so a lower MTU would be legal there — the guard must
        // not become a blanket 1280 minimum it was never meant to be.
        let v4Only = TunnelRoutePlan(
            tunnelAddress: "10.255.0.2", tunnelSubnetMask: "255.255.255.0",
            dnsServerAddress: "10.255.0.1", routeDescription: "10.255.0.0/24",
            includedIPv4Routes: [
                TunnelRoutePlan.IPv4Route(destinationAddress: "10.255.0.0", subnetMask: "255.255.255.0")
            ],
            mtu: 1000
        )
        XCTAssertFalse(v4Only.carriesIPv6)
        XCTAssertTrue(v4Only.mtuIsLegalForClaimedFamilies)
    }

    func testTheLegalityPredicateActuallyCatchesAnIllegalPlan() {
        // The earlier chained value, 1280 - 80. Legal while no IPv6 was claimed, illegal
        // the moment it was — which is exactly how the bug arrived.
        let illegal = TunnelRoutePlan(
            tunnelAddress: "10.255.0.2",
            tunnelSubnetMask: "255.255.255.0",
            dnsServerAddress: "10.255.0.1",
            routeDescription: "0.0.0.0/0",
            includedIPv4Routes: [
                TunnelRoutePlan.IPv4Route(destinationAddress: "0.0.0.0", subnetMask: "0.0.0.0")
            ],
            tunnelIPv6Address: "fd00:1a7a::2",
            tunnelIPv6PrefixLength: 64,
            includedIPv6Routes: [TunnelRoutePlan.IPv6Route(destinationAddress: "::", prefixLength: 0)],
            mtu: 1200
        )
        XCTAssertFalse(illegal.mtuIsLegalForClaimedFamilies)
    }

    func testTheEncapsulatedPacketStillFitsTheEngineDatagramCeiling() {
        // The budget the old derivation was actually about: inner + overhead must fit one
        // outer datagram. 1280 + 80 = 1360, inside the engine's 1532 ceiling.
        let chained = TunnelRoutePlan.make(for: Self.chainedMode)
        XCTAssertLessThanOrEqual(chained.mtu + TunnelRoutePlan.encapsulationOverhead, 1532)
    }

    func testTheTwoModesAreDistinguishable() {
        XCTAssertNotEqual(TunnelDataPathMode.dnsOnly, Self.chainedMode)
        XCTAssertNotEqual(
            TunnelRoutePlan.make(for: .dnsOnly),
            TunnelRoutePlan.make(for: Self.chainedMode)
        )
    }

    func testClaimsDefaultRouteIsDerivedNotAsserted() {
        // A hand-built plan that lists the default route reports it, even though nothing
        // set a flag — the property cannot drift from the routes it describes.
        let plan = TunnelRoutePlan(
            tunnelAddress: "10.255.0.2",
            tunnelSubnetMask: "255.255.255.0",
            dnsServerAddress: "10.255.0.1",
            routeDescription: "custom",
            includedIPv4Routes: [
                TunnelRoutePlan.IPv4Route(destinationAddress: "0.0.0.0", subnetMask: "0.0.0.0")
            ],
            mtu: 1200
        )
        XCTAssertTrue(plan.claimsDefaultRoute)
    }

    // MARK: - IPv6

    func testChainedClaimsIPv6SoItCannotEscapeTheTunnel() {
        let plan = TunnelRoutePlan.make(for: Self.chainedMode)

        // The leak this guards: claiming only 0.0.0.0/0 on a dual-stack network leaves
        // IPv6 application traffic on the physical interface, outside the VPN entirely.
        XCTAssertTrue(plan.claimsIPv6DefaultRoute)
        XCTAssertEqual(
            plan.includedIPv6Routes,
            [TunnelRoutePlan.IPv6Route(destinationAddress: "::", prefixLength: 0)]
        )
        XCTAssertNotNil(plan.tunnelIPv6Address, "iOS installs no IPv6 route without an address")
        XCTAssertNotNil(plan.tunnelIPv6PrefixLength)
    }

    func testEveryEquivalentSpellingOfTheDefaultRouteIsRecognized() {
        // A literal compare against "::" recognizes one spelling of an address that has
        // many. A plan claiming ::/0 as "0:0:0:0:0:0:0:0" would then be read as leaking —
        // the predicate would report the opposite of the truth.
        for spelling in ["::", "::0", "0::0", "0:0:0:0:0:0:0:0", "0000:0000:0000:0000:0000:0000:0000:0000"] {
            let plan = TunnelRoutePlan(
                tunnelAddress: "10.255.0.2", tunnelSubnetMask: "255.255.255.0",
                dnsServerAddress: "10.255.0.1", routeDescription: "0.0.0.0/0",
                includedIPv4Routes: [
                    TunnelRoutePlan.IPv4Route(destinationAddress: "0.0.0.0", subnetMask: "0.0.0.0")
                ],
                tunnelIPv6Address: "fd00:1a7a::2", tunnelIPv6PrefixLength: 64,
                includedIPv6Routes: [TunnelRoutePlan.IPv6Route(destinationAddress: spelling, prefixLength: 0)],
                mtu: 1280
            )
            XCTAssertTrue(plan.claimsIPv6DefaultRoute, "\(spelling) is ::/0")
            XCTAssertFalse(plan.leaksIPv6AroundTheTunnel, "\(spelling) was misread as a leak")
        }
    }

    func testANonDefaultIPv6RouteIsNotMistakenForTheDefault() {
        // The predicate must not become so permissive that a real prefix reads as ::/0.
        XCTAssertFalse(TunnelRoutePlan.isUnspecifiedIPv6Address("fd00:1a7a::2"))
        XCTAssertFalse(TunnelRoutePlan.isUnspecifiedIPv6Address("::1"))
        XCTAssertFalse(TunnelRoutePlan.isUnspecifiedIPv6Address("not-an-address"))
        XCTAssertFalse(TunnelRoutePlan.isUnspecifiedIPv6Address(""))
    }

    func testNoModeCarriesIPv4WhileLeakingIPv6() {
        // Stated as a property over every mode rather than a fact about one, so a future
        // mode cannot reintroduce the asymmetry.
        for mode in [TunnelDataPathMode.dnsOnly, Self.chainedMode] {
            XCTAssertFalse(
                TunnelRoutePlan.make(for: mode).leaksIPv6AroundTheTunnel,
                "\(mode) claims all IPv4 but no IPv6 — that is traffic escaping the tunnel"
            )
        }
    }

    func testDNSOnlyStillClaimsNoIPv6AtAll() {
        let plan = TunnelRoutePlan.make(for: .dnsOnly)

        // Unchanged from the pre-chaining tunnel, and correct: DNS-only carries no traffic,
        // so it has nothing to leak. NEDNSSettings captures DNS regardless of transport.
        XCTAssertNil(plan.tunnelIPv6Address)
        XCTAssertNil(plan.tunnelIPv6PrefixLength)
        XCTAssertEqual(plan.includedIPv6Routes, [])
        XCTAssertFalse(plan.claimsIPv6DefaultRoute)
    }

    func testTheChainedIPv6AddressIsALocallyAssignedULA() {
        // Never a routable address: the interface needs one before iOS installs an IPv6
        // route, but chained mode claims IPv6 to DROP it, not to source traffic from it.
        XCTAssertTrue(
            TunnelRoutePlan.chainedTunnelIPv6Address.hasPrefix("fd"),
            "must sit in the fd00::/8 locally-assigned range (RFC 4193)"
        )
    }

    func testTheLeakPredicateActuallyDetectsALeak() {
        // The guard above is only worth having if it can fail. A hand-built plan that
        // claims all IPv4 and no IPv6 is exactly the shape it exists to catch.
        let leaky = TunnelRoutePlan(
            tunnelAddress: "10.255.0.2",
            tunnelSubnetMask: "255.255.255.0",
            dnsServerAddress: "10.255.0.1",
            routeDescription: "0.0.0.0/0",
            includedIPv4Routes: [
                TunnelRoutePlan.IPv4Route(destinationAddress: "0.0.0.0", subnetMask: "0.0.0.0")
            ],
            mtu: 1200
        )
        XCTAssertTrue(leaky.leaksIPv6AroundTheTunnel)
    }

    // MARK: - Split tunnel (infra #198 §3, Option A)

    func testDropsOutboundIPv6IsTrueForFullTunnelOnly() {
        // The exact gate for the AAAA→NODATA suppression (`ChainedIPv6DNSPolicy`). Only the FULL
        // chained tunnel claims `::/0` and drops v6; split claims only the in-tunnel DNS server's
        // on-link ULA and captured resolver host routes, so general v6 egresses direct — it must
        // NOT suppress AAAA (F3b+F3c, 2026-09-19). DNS-only claims no v6 at all.
        XCTAssertFalse(TunnelDataPathMode.dnsOnly.dropsOutboundIPv6, "DNS-only leaves v6 direct")

        let fullTunnel = Self.configuration(allowedIPs: ["0.0.0.0/0"])
        XCTAssertEqual(fullTunnel.routingPolicy, .fullTunnel)
        XCTAssertTrue(
            TunnelDataPathMode.chainedUpstream(fullTunnel).dropsOutboundIPv6,
            "full-tunnel chained claims ::/0 and drops v6")

        let splitTunnel = Self.configuration(clientAddress: "10.77.0.2", allowedIPs: ["100.64.0.0/10", "10.1.2.3/8"])
        XCTAssertEqual(splitTunnel.routingPolicy, .splitTunnel)
        XCTAssertFalse(
            TunnelDataPathMode.chainedUpstream(splitTunnel).dropsOutboundIPv6,
            "split serves filtered v6 DNS and leaves general v6 direct, so AAAA stays answerable")
    }

    func testSplitTunnelClaimsOnlyAllowedIPsPlusTheDNSRoute() {
        // A split config (AllowedIPs that do not cover the default route). The plan claims
        // exactly those prefixes (masked to their network) plus the DNS-capture route for IPv4,
        // and `::/0` to blackhole IPv6 — so non-AllowedIPs IPv4 is left direct but no v6 escapes.
        let config = Self.configuration(
            clientAddress: "10.77.0.2",
            // Second entry carries host bits, to prove the plan masks to the network like the
            // inbound `ChainedAllowedIPs` does.
            allowedIPs: ["100.64.0.0/10", "10.1.2.3/8"])
        XCTAssertEqual(config.routingPolicy, .splitTunnel)
        let plan = TunnelRoutePlan.make(for: .chainedUpstream(config))

        XCTAssertEqual(
            plan.includedIPv4Routes,
            [
                TunnelRoutePlan.IPv4Route(destinationAddress: "100.64.0.0", subnetMask: "255.192.0.0"),
                TunnelRoutePlan.IPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
                TunnelRoutePlan.dnsCaptureIPv4Route,
            ],
            "split claims the AllowedIPs prefixes (masked) then the DNS-capture route")
        // The DNS-capture route is byte-identical to the one dns-only uses, so system-resolver
        // DNS reaches the NE and is filtered exactly as in dns-only.
        XCTAssertEqual(
            TunnelRoutePlan.dnsCaptureIPv4Route,
            TunnelRoutePlan.make(for: .dnsOnly).includedIPv4Routes[0])

        // IPv4 stays selective, and split no longer claims `::/0` (F3b+F3c, 2026-09-19): it
        // claims only the in-tunnel DNS server's on-link ULA /64, so the v6 resolver is
        // reachable and all other IPv6 egresses direct instead of being blackholed.
        XCTAssertFalse(plan.claimsDefaultRoute, "split must not claim the whole IPv4 space")
        XCTAssertFalse(plan.claimsIPv6DefaultRoute, "split no longer blackholes all v6")
        XCTAssertEqual(plan.tunnelIPv6Address, TunnelRoutePlan.chainedTunnelIPv6Address)
        XCTAssertEqual(plan.tunnelIPv6PrefixLength, TunnelRoutePlan.chainedTunnelIPv6PrefixLength)
        XCTAssertEqual(
            plan.includedIPv6Routes,
            [TunnelRoutePlan.IPv6Route(
                destinationAddress: TunnelRoutePlan.chainedTunnelIPv6Network,
                prefixLength: TunnelRoutePlan.chainedTunnelIPv6PrefixLength)])
        XCTAssertEqual(plan.dnsServerIPv6Address, TunnelRoutePlan.chainedDNSServerIPv6Address)

        // The interface is the configured [Interface] Address at /32 (C7); the DNS proxy is
        // unchanged.
        XCTAssertEqual(plan.tunnelAddress, "10.77.0.2")
        XCTAssertEqual(plan.tunnelSubnetMask, "255.255.255.255")
        XCTAssertEqual(plan.dnsServerAddress, "10.255.0.1")
    }

    func testTheFullTunnelPlanIsUnchangedByTheSplitBranch() {
        // The split branch must not perturb the full-tunnel plan: a covering config still
        // claims 0.0.0.0/0 + ::/0 with the configured address at /32.
        let full = TunnelRoutePlan.make(for: Self.chainedMode)
        XCTAssertEqual(
            full.includedIPv4Routes,
            [TunnelRoutePlan.IPv4Route(destinationAddress: "0.0.0.0", subnetMask: "0.0.0.0")])
        XCTAssertEqual(
            full.includedIPv6Routes,
            [TunnelRoutePlan.IPv6Route(destinationAddress: "::", prefixLength: 0)])
        XCTAssertEqual(full.routeDescription, "0.0.0.0/0, ::/0")
        XCTAssertTrue(full.claimsDefaultRoute)
        XCTAssertTrue(full.claimsIPv6DefaultRoute)
    }

    func testSplitLeavesGeneralIPv6DirectWhileStillCarryingItsDNSBlock() {
        // Split carries IPv6 (the DNS server's on-link ULA /64) but not the default route, so
        // all other v6 egresses direct (F3b+F3c). `carriesIPv6` is true and the RFC 8200 floor
        // binds the MTU; the leak predicate stays scoped to the IPv4 default shape.
        let split = TunnelRoutePlan.make(
            for: .chainedUpstream(Self.configuration(
                clientAddress: "10.77.0.2", allowedIPs: ["100.64.0.0/10"])))
        XCTAssertTrue(split.carriesIPv6, "split carries its DNS server's ULA /64")
        XCTAssertFalse(split.claimsIPv6DefaultRoute, "general v6 is direct, not claimed")
        XCTAssertFalse(split.leaksIPv6AroundTheTunnel, "the predicate is about the IPv4 default shape")
        XCTAssertTrue(split.mtuIsLegalForClaimedFamilies, "the v6 floor binds and 1280 satisfies it")

        // A full-tunnel-shaped plan that claims all IPv4 but forgot ::/0 IS a leak — the same
        // predicate must still catch that, or scoping it would have disarmed it.
        let fullMissingV6 = TunnelRoutePlan(
            tunnelAddress: "10.64.0.5", tunnelSubnetMask: "255.255.255.255",
            dnsServerAddress: "10.255.0.1", routeDescription: "0.0.0.0/0",
            includedIPv4Routes: [
                TunnelRoutePlan.IPv4Route(destinationAddress: "0.0.0.0", subnetMask: "0.0.0.0")
            ],
            mtu: 1280)
        XCTAssertTrue(fullMissingV6.leaksIPv6AroundTheTunnel)
    }
    // MARK: - DNS capture floor (F1/F3b)

    func testTheCaptureFloorAddsHostRoutesInSplitAndV4OnlyInDNSOnly() {
        // The floor's membership is `DNSCaptureFloor`'s; this pins that the PLAN merges it where
        // it can be reached. A v6 /128 needs installed v6 settings, so DNS-only drops it.
        let resolvers = ["9.9.9.9", "2606:4700:4700::1111"]

        let split = TunnelRoutePlan.make(
            for: .chainedUpstream(Self.configuration(
                clientAddress: "10.77.0.2", allowedIPs: ["100.64.0.0/10"])),
            dnsCaptureResolverAddresses: resolvers)
        XCTAssertTrue(split.includedIPv4Routes.contains(
            TunnelRoutePlan.IPv4Route(destinationAddress: "9.9.9.9", subnetMask: "255.255.255.255")))
        XCTAssertTrue(split.includedIPv6Routes.contains(
            TunnelRoutePlan.IPv6Route(destinationAddress: "2606:4700:4700::1111", prefixLength: 128)))
        // The on-link DNS block stays first, so a capture route cannot displace it.
        XCTAssertEqual(split.includedIPv6Routes.first, TunnelRoutePlan.IPv6Route(
            destinationAddress: TunnelRoutePlan.chainedTunnelIPv6Network,
            prefixLength: TunnelRoutePlan.chainedTunnelIPv6PrefixLength))
        // The description must name every route the plan claims, or a field log cannot confirm
        // the floor installed (`testChainedClaimsTheDefaultRoute` states the same contract).
        XCTAssertEqual(
            split.routeDescription,
            "100.64.0.0/10, 10.255.0.0/24 (DNS), fd00:1a7a::/64 (DNS v6), "
                + "9.9.9.9/32, 2606:4700:4700::1111/128 (DNS capture), rest IPv4/v6 direct")

        let dnsOnly = TunnelRoutePlan.make(for: .dnsOnly, dnsCaptureResolverAddresses: resolvers)
        XCTAssertTrue(dnsOnly.includedIPv4Routes.contains(
            TunnelRoutePlan.IPv4Route(destinationAddress: "9.9.9.9", subnetMask: "255.255.255.255")))
        XCTAssertEqual(dnsOnly.includedIPv6Routes, [], "DNS-only has no v6 settings to reach a v6 /128")
        XCTAssertEqual(
            dnsOnly.routeDescription, "10.255.0.0/24, 9.9.9.9/32 (DNS capture)",
            "the description must name the v4 capture-floor route the plan claims")
        XCTAssertFalse(
            dnsOnly.routeDescription.contains("2606:4700:4700::1111"),
            "a route the plan drops must not appear in the description")

        let full = TunnelRoutePlan.make(
            for: .chainedUpstream(Self.configuration(allowedIPs: ["0.0.0.0/0"])),
            dnsCaptureResolverAddresses: resolvers)
        XCTAssertEqual(full.includedIPv4Routes, [
            TunnelRoutePlan.IPv4Route(destinationAddress: "0.0.0.0", subnetMask: "0.0.0.0")
        ], "full tunnel already claims every destination")
        XCTAssertEqual(full.includedIPv6Routes, [
            TunnelRoutePlan.IPv6Route(destinationAddress: "::", prefixLength: 0)
        ])
    }

    /// F1: the curated public-resolver set is claimed by the CHAINED SPLIT plan (both families),
    /// the only path the provider hands it to. Full tunnel ignores the floor by construction.
    /// DNS-only is deliberately NOT wired (Kilo, PR #752): a claim there would silently drop the
    /// resolver's non-53 traffic, because the DNS-only packet loop has no forwarding rung.
    func testTheCuratedPublicResolverFloorIsClaimedInChainedSplitOnly() {
        let curated = DNSCaptureFloor.curatedPublicResolverAddresses

        let split = TunnelRoutePlan.make(
            for: .chainedUpstream(Self.configuration(
                clientAddress: "10.77.0.2", allowedIPs: ["100.64.0.0/10"])),
            dnsCaptureResolverAddresses: curated)
        XCTAssertTrue(split.includedIPv4Routes.contains(
            TunnelRoutePlan.IPv4Route(destinationAddress: "1.1.1.1", subnetMask: "255.255.255.255")))
        XCTAssertTrue(split.includedIPv6Routes.contains(
            TunnelRoutePlan.IPv6Route(
                destinationAddress: "2606:4700:4700::1111", prefixLength: 128)))
        // The on-link DNS block stays first, so a curated /128 cannot displace it.
        XCTAssertEqual(split.includedIPv6Routes.first, TunnelRoutePlan.IPv6Route(
            destinationAddress: TunnelRoutePlan.chainedTunnelIPv6Network,
            prefixLength: TunnelRoutePlan.chainedTunnelIPv6PrefixLength))

        // Full tunnel ignores the floor by construction.
        let full = TunnelRoutePlan.make(
            for: .chainedUpstream(Self.configuration(allowedIPs: ["0.0.0.0/0"])),
            dnsCaptureResolverAddresses: curated)
        XCTAssertEqual(full.includedIPv4Routes, [
            TunnelRoutePlan.IPv4Route(destinationAddress: "0.0.0.0", subnetMask: "0.0.0.0")
        ])
        XCTAssertEqual(full.includedIPv6Routes, [
            TunnelRoutePlan.IPv6Route(destinationAddress: "::", prefixLength: 0)
        ])
    }

    func testTheCaptureFloorNeverAdmitsTheTunnelsOwnListeners() {
        let plan = TunnelRoutePlan.make(
            for: .chainedUpstream(Self.configuration(
                clientAddress: "10.77.0.2", allowedIPs: ["100.64.0.0/10"])),
            dnsCaptureResolverAddresses: [
                TunnelRoutePlan.dnsServerAddress,
                TunnelRoutePlan.chainedDNSServerIPv6Address,
            ])
        XCTAssertFalse(plan.includedIPv4Routes.contains { $0.destinationAddress == "10.255.0.1" })
        // Only the on-link block; the v6 listener is not re-claimed as a /128.
        XCTAssertEqual(plan.includedIPv6Routes, [TunnelRoutePlan.IPv6Route(
            destinationAddress: TunnelRoutePlan.chainedTunnelIPv6Network,
            prefixLength: TunnelRoutePlan.chainedTunnelIPv6PrefixLength)])
    }
}
