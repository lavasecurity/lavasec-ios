import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class DNSCaptureFloorTests: XCTestCase {
    func testDNSOnlyIPv6ComparisonClaimsOnlyTheExplicitResolverAndRequiresOptIn() {
        let addresses = ["2606:4700:4700::1111"]
        let baseline = TunnelRoutePlan.make(for: .dnsOnly, dnsCaptureResolverAddresses: addresses)
        XCTAssertNil(baseline.tunnelIPv6Address)
        XCTAssertTrue(baseline.includedIPv6Routes.isEmpty)
        let comparison = TunnelRoutePlan.make(
            for: .dnsOnly, dnsCaptureResolverAddresses: addresses, capturesIPv6InDNSOnly: true)
        XCTAssertNotNil(comparison.tunnelIPv6Address)
        XCTAssertEqual(comparison.includedIPv6Routes, [
            .init(destinationAddress: addresses[0], prefixLength: 128)
        ])
        XCTAssertEqual(comparison.includedIPv4Routes, baseline.includedIPv4Routes)
        let empty = TunnelRoutePlan.make(
            for: .dnsOnly, dnsCaptureResolverAddresses: [], capturesIPv6InDNSOnly: true)
        XCTAssertNil(empty.tunnelIPv6Address)
    }
    func testIPv4ResolverBecomesA32HostRoute() {
        XCTAssertEqual(
            DNSCaptureFloor.hostRoutes(forResolverAddresses: ["8.8.8.8"]),
            [.init(address: "8.8.8.8", family: .ipv4)]
        )
        XCTAssertEqual(
            DNSCaptureFloor.hostRoutes(forResolverAddresses: ["8.8.8.8"]).first?.prefixLength,
            32
        )
    }

    func testIPv6ResolverBecomesA128HostRoute() {
        XCTAssertEqual(
            DNSCaptureFloor.hostRoutes(forResolverAddresses: ["2606:4700:4700::1111"]),
            [.init(address: "2606:4700:4700::1111", family: .ipv6)]
        )
        XCTAssertEqual(
            DNSCaptureFloor.hostRoutes(forResolverAddresses: ["2606:4700:4700::1111"])
                .first?.prefixLength,
            128
        )
    }

    func testMixedFamiliesKeepInputOrder() {
        XCTAssertEqual(
            DNSCaptureFloor.hostRoutes(forResolverAddresses: [
                "8.8.8.8", "2606:4700:4700::1111", "1.1.1.1",
            ]),
            [
                .init(address: "8.8.8.8", family: .ipv4),
                .init(address: "2606:4700:4700::1111", family: .ipv6),
                .init(address: "1.1.1.1", family: .ipv4),
            ]
        )
    }

    func testDuplicatesAreDroppedAndTheFirstOccurrenceWins() {
        XCTAssertEqual(
            DNSCaptureFloor.hostRoutes(forResolverAddresses: [
                "9.9.9.9", "9.9.9.9", "2620:fe::fe", "2620:fe::fe",
            ]),
            [
                .init(address: "9.9.9.9", family: .ipv4),
                .init(address: "2620:fe::fe", family: .ipv6),
            ]
        )
    }

    func testStructurallyUnusableResolversAreDropped() {
        XCTAssertEqual(
            DNSCaptureFloor.hostRoutes(forResolverAddresses: [
                "0.0.0.0",          // unspecified
                "127.0.0.1",        // loopback
                "169.254.1.1",      // link-local
                "::",               // unspecified v6
                "::1",              // loopback v6
                "fe80::1",          // link-local v6
                "::ffff:127.0.0.1", // IPv4-mapped loopback
                "::ffff:8.8.8.8",   // IPv4-mapped form is not a resolver identity
                "::8.8.8.8",        // IPv4-compatible form
                "not-an-address",   // unparseable
                "1.1.1.1",
            ]),
            [.init(address: "1.1.1.1", family: .ipv4)]
        )
    }

    func testNAT64MappedPublicResolverIsKeptAsIPv6() {
        // The NAT64 prefix itself is not dropped: a v6-only/NAT64 link reaches an IPv4 resolver
        // through it, and the claim must follow the address as the client dials it.
        XCTAssertEqual(
            DNSCaptureFloor.hostRoutes(forResolverAddresses: ["64:ff9b::8.8.8.8"]),
            [.init(address: "64:ff9b::8.8.8.8", family: .ipv6)]
        )
    }

    func testTunnelListenerIsNeverClaimedAsAResolver() {
        XCTAssertEqual(
            DNSCaptureFloor.hostRoutes(forResolverAddresses: [
                TunnelRoutePlan.dnsServerAddress,
                TunnelRoutePlan.chainedDNSServerIPv6Address,
                "8.8.8.8",
            ]),
            [.init(address: "8.8.8.8", family: .ipv4)]
        )
    }

    func testEmptyInputProducesNoRoutes() {
        XCTAssertTrue(DNSCaptureFloor.hostRoutes(forResolverAddresses: []).isEmpty)
    }

    // MARK: - On-link gateway exclusion (plan Open decision 1)

    /// The gateway-class ranges are excluded before anything reaches the floor. A private
    /// on-link gateway claimed as a host route would draw the router's non-DNS traffic into a
    /// tunnel whose peer does not carry it, and `NWPath` exposes no gateway identity to exclude
    /// by, so the membership rule is range-based. Public resolvers are unaffected.
    func testOnLinkGatewayClassAddressesAreExcludedFromTheFloor() {
        let captured = [
            "10.0.0.1",              // RFC1918 10/8 — a typical LAN gateway
            "172.16.5.1",            // RFC1918 172.16/12 lower bound
            "172.31.255.254",        // RFC1918 172.16/12 upper bound
            "192.168.1.1",           // RFC1918 192.168/16
            "169.254.1.1",           // IPv4 link-local
            "fe80::1",               // IPv6 link-local
            "fc00::1",               // ULA lower bound
            "fd00:1a7a::1",          // ULA
            "8.8.8.8",               // public — kept
            "1.1.1.1",               // public — kept
            "2606:4700:4700::1111",  // public v6 — kept
        ]
        XCTAssertEqual(
            DNSCaptureFloorMembership.claimableResolverAddresses(captured),
            ["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111"])
    }

    /// The masks must not over-reach: the address just outside each private range is kept, and
    /// the boundary just outside `fc00::/7` is not ULA.
    func testPrivateRangeExclusionDoesNotOverReach() {
        XCTAssertFalse(DNSCaptureFloorMembership.excludesAsOnLinkGatewayClass("172.15.0.1"))
        XCTAssertFalse(DNSCaptureFloorMembership.excludesAsOnLinkGatewayClass("172.32.0.1"))
        XCTAssertFalse(DNSCaptureFloorMembership.excludesAsOnLinkGatewayClass("11.0.0.1"))
        XCTAssertFalse(DNSCaptureFloorMembership.excludesAsOnLinkGatewayClass("192.169.0.1"))
        XCTAssertFalse(DNSCaptureFloorMembership.excludesAsOnLinkGatewayClass("169.255.0.1"))
        XCTAssertFalse(DNSCaptureFloorMembership.excludesAsOnLinkGatewayClass("fb00::1"))
        XCTAssertFalse(DNSCaptureFloorMembership.excludesAsOnLinkGatewayClass("not-an-address"))
        XCTAssertTrue(DNSCaptureFloorMembership.excludesAsOnLinkGatewayClass("fdff::1"))
    }

    /// Membership composes with the floor: the survivors of the exclusion are exactly the
    /// addresses the floor would otherwise claim, so a public resolver is unaffected and an
    /// excluded gateway is absent.
    func testClaimableAddressesComposeWithHostRoutes() {
        let claimable = DNSCaptureFloorMembership.claimableResolverAddresses(
            ["192.168.1.1", "8.8.8.8"])
        XCTAssertEqual(
            DNSCaptureFloor.hostRoutes(forResolverAddresses: claimable),
            [.init(address: "8.8.8.8", family: .ipv4)])
    }

    // MARK: - F1 curated public-resolver set

    /// Every curated entry is a usable literal that parses to a family, and both families are
    /// present — a v4-only list would leave the v6 resolver escape F3c closed half-open.
    func testCuratedPublicResolverSetIsNonEmptyAndEveryEntryParses() {
        XCTAssertFalse(
            DNSCaptureFloor.curatedPublicResolverAddresses.isEmpty,
            "F1's curated set may not be empty")
        for address in DNSCaptureFloor.curatedPublicResolverAddresses {
            XCTAssertNotNil(
                DNSCaptureFloor.hostRoutes(forResolverAddresses: [address]).first,
                "curated entry \(address) did not parse to a claimable family")
        }
        let routes = DNSCaptureFloor.hostRoutes(
            forResolverAddresses: DNSCaptureFloor.curatedPublicResolverAddresses)
        XCTAssertTrue(routes.contains { $0.family == .ipv4 }, "no curated v4 resolver")
        XCTAssertTrue(routes.contains { $0.family == .ipv6 }, "no curated v6 resolver")
    }

    /// The curated set yields exactly one route per entry — no duplicate or unusable entries —
    /// and each is a host route (`/32` v4, `/128` v6).
    func testCuratedHostRoutesAreA32Or128ForEveryEntry() {
        let routes = DNSCaptureFloor.hostRoutes(
            forResolverAddresses: DNSCaptureFloor.curatedPublicResolverAddresses)
        XCTAssertEqual(
            routes.count, DNSCaptureFloor.curatedPublicResolverAddresses.count,
            "a duplicate or unusable curated entry would collapse a route")
        for route in routes {
            switch route.family {
            case .ipv4:
                XCTAssertEqual(route.prefixLength, 32, "\(route.address) is not a /32")
            case .ipv6:
                XCTAssertEqual(route.prefixLength, 128, "\(route.address) is not a /128")
            }
        }
    }

    /// The membership helper compares over parsed bytes, so an equivalent v6 spelling is
    /// recognized; a string compare would miss it and strand Lava's own egress in the claim.
    func testCuratedMembershipMatchesEquivalentSpellings() {
        XCTAssertTrue(DNSCaptureFloor.isCuratedPublicResolverAddress("1.1.1.1"))
        XCTAssertTrue(
            DNSCaptureFloor.isCuratedPublicResolverAddress("2606:4700:4700:0:0:0:0:1111"))
        XCTAssertTrue(DNSCaptureFloor.isCuratedPublicResolverAddress("8.8.8.8"))
        XCTAssertFalse(DNSCaptureFloor.isCuratedPublicResolverAddress("8.8.8.9"))
        XCTAssertFalse(DNSCaptureFloor.isCuratedPublicResolverAddress("10.0.0.1"))
        XCTAssertFalse(DNSCaptureFloor.isCuratedPublicResolverAddress("not-an-address"))
    }
}
