import XCTest

@testable import LavaSecChainedUpstream
@testable import LavaSecKit

/// Which of a chained configuration's `DNS =` entries the tunnel can actually use (S6).
///
/// The selected set is what the tunnelled transport consumes and what readiness gates the
/// latch on — the same function decides both, so an entry accepted here is an entry the
/// executor will query.
final class ChainedTunnelResolverSelectionTests: XCTestCase {
    private func configuration(
        dnsAddresses: [String],
        allowedIPs: [String] = ["0.0.0.0/0"],
        clientAddress: String = "10.64.0.5"
    ) throws -> ChainedUpstreamConfiguration {
        try ChainedUpstreamConfiguration(
            endpointHost: "203.0.113.9", endpointPort: 51820,
            peerPublicKey: Data(1...32).base64EncodedString(),
            clientAddress: clientAddress, allowedIPs: allowedIPs,
            persistentKeepaliveSeconds: 25, dnsAddresses: dnsAddresses)
    }

    /// A T1 address is ADMITTED without the tunnel routing it.
    ///
    /// The route-coverage gate is gone from the panel's derivation, because T1 is no longer
    /// carried by the tunnel: it egresses on the physical interface, so whether the peer's
    /// `AllowedIPs` happen to cover the address has stopped being a question about whether the
    /// resolver can be used (PR #590).
    ///
    /// This is the split tunnel that used to produce `notRoutedBySplitTunnel` — the disposition
    /// that drove a panel telling the user to go hand-edit their WireGuard profile.
    func testATierOneAddressIsAdmittedWithoutTheTunnelRoutingIt() throws {
        let split = try configuration(
            dnsAddresses: ["100.100.100.100"], allowedIPs: ["100.64.0.0/10"])
        let selection = ChainedTunnelResolverSelection.selection(from: split)

        let outcomes = ChainedTunnelResolverSelection.fallbackOutcomes(
            latched: ["1.1.1.1", "1.0.0.1"], resolvesOverPlainDNS: true,
            selection: selection, configuration: split)

        XCTAssertEqual(
            outcomes.map(\.disposition), [.admitted, .admitted],
            "a resolver reached on the physical interface needs no route from the tunnel")
        XCTAssertNil(outcomes.first?.refusalReason)
    }

    /// The dispositions that still MEAN something are unchanged: an address the conf already
    /// carries is not a second opinion, and an unusable one is still unusable.
    func testTheSurvivingDispositionsStillHold() throws {
        // The conf's `AllowedIPs` must COVER its own `DNS =`, or the selection admits nothing and
        // `1.1.1.1` reads as an ordinary T1 rather than the conf's own resolver.
        //
        // SPLIT, and explicitly so: the per-address dispositions are only reached in a split
        // tunnel now, because a full tunnel has no T1 rung to have a disposition about
        // (`unavailableInFullTunnel`, PR #590). This test is about the surviving per-address
        // verdicts, so it must be in the shape that produces them.
        let conf = try configuration(
            dnsAddresses: ["1.1.1.1"], allowedIPs: ["1.1.1.1/32", "10.0.0.0/8"])
        let selection = ChainedTunnelResolverSelection.selection(from: conf)

        let outcomes = ChainedTunnelResolverSelection.fallbackOutcomes(
            latched: ["1.1.1.1", "0.0.0.0"], resolvesOverPlainDNS: true,
            selection: selection, configuration: conf)

        XCTAssertEqual(outcomes.map(\.disposition), [.alreadyPrimary, .unusable])
    }

    func testAnInvalidFirstEntryYieldsTheValidSecond() throws {
        // The plan's own proof shape (S7's rule, applied to S6's field): `0.0.0.0` is
        // well-formed and unusable, so an existential "has a usable entry" check passes
        // while a first-entry consumer sources from the unusable address. The selected set
        // must contain exactly the usable entries, in order.
        let selected = ChainedTunnelResolverSelection.selectedResolvers(
            from: try configuration(dnsAddresses: ["0.0.0.0", "10.64.0.1"]))
        XCTAssertEqual(selected, ["10.64.0.1"])
    }

    func testIPv6EntriesAreNotSelected() throws {
        // Chained mode claims `::/0` in order to DROP IPv6, not carry it (INV-CHAIN-1). A
        // v6 resolver would validate, latch, and then blackhole every query — the failure
        // that reads as "chained DNS is broken" instead of naming the config.
        let selected = ChainedTunnelResolverSelection.selectedResolvers(
            from: try configuration(dnsAddresses: ["2606:4700:4700::1111", "10.64.0.1"]))
        XCTAssertEqual(selected, ["10.64.0.1"])
    }

    func testLocalDeliveryAddressesAreNotSelected() throws {
        // `10.255.0.1` is the tunnel's own DNS proxy — using it as the upstream is the
        // interception loop. The config's own clientAddress is owned by the interface, so
        // the OS delivers to it locally instead of routing into the tunnel — the same
        // collision the configuration boundary refuses for the proxy address, on a
        // different field.
        let selected = ChainedTunnelResolverSelection.selectedResolvers(
            from: try configuration(
                dnsAddresses: [TunnelRoutePlan.dnsServerAddress, "10.64.0.5", "10.64.0.1"],
                clientAddress: "10.64.0.5"))
        XCTAssertEqual(selected, ["10.64.0.1"])
    }

    func testStructurallyUnusableAddressesAreNotSelected() throws {
        // The shared judgement (`DeviceDNSFallbackPolicy.isUsableResolverAddress`): ranges
        // that can never answer real queries.
        let selected = ChainedTunnelResolverSelection.selectedResolvers(
            from: try configuration(
                dnsAddresses: ["127.0.0.1", "169.254.1.1", "224.0.0.9", "10.64.0.1"]))
        XCTAssertEqual(selected, ["10.64.0.1"])
    }

    func testOrderIsPreservedAndDuplicatesCollapseToTheFirst() throws {
        // Failover order is the user's order; a duplicate retried twice buys latency, not
        // redundancy.
        let selected = ChainedTunnelResolverSelection.selectedResolvers(
            from: try configuration(
                dnsAddresses: ["10.64.0.2", "10.64.0.1", "10.64.0.2"]))
        XCTAssertEqual(selected, ["10.64.0.2", "10.64.0.1"])
    }

    // THE `appending:` SECTION IS GONE. Seven tests stood here over a parameter that let the
    // caller append T1 addresses to the tunnelled resolver route. Nothing appends any more:
    // the rung egresses on the physical interface (PR #590), so the route is the conf's own
    // `DNS =` by construction rather than by arithmetic, and `Selection.appendedFallback` went
    // with the parameter (the plan's S3). What those tests asserted about the GATE — dedup,
    // AllowedIPs coverage, usability — is asserted below against the conf's own entries, which
    // is the only list the gate now sees.

    func testTheConfsOwnEntriesDedupe() throws {
        // A duplicate retried twice buys latency, not redundancy.
        let selected = ChainedTunnelResolverSelection.selectedResolvers(
            from: try configuration(dnsAddresses: ["1.1.1.1", "10.64.0.1", "1.1.1.1"]))
        XCTAssertEqual(selected, ["1.1.1.1", "10.64.0.1"])
    }

    func testAConfResolverOutsideAllowedIPsIsDropped() throws {
        // A conf resolver outside the conf's own AllowedIPs is a contradiction in that file: the
        // query is encapsulated, the reply arrives from outside AllowedIPs, and the runner drops
        // it as a spoof (Codex #546 P1).
        let selected = ChainedTunnelResolverSelection.selectedResolvers(
            from: try configuration(
                dnsAddresses: ["10.64.0.1", "9.9.9.9"], allowedIPs: ["10.0.0.0/8"]))
        XCTAssertEqual(selected, ["10.64.0.1"])
    }

    func testAConfigWithNoDNSLineSelectsNothing() throws {
        XCTAssertEqual(
            ChainedTunnelResolverSelection.selectedResolvers(
                from: try configuration(dnsAddresses: [])),
            [])
    }

    func testASplitResolverInsideAllowedIPsIsSelected() throws {
        // The founder's Tailscale shape: MagicDNS at 100.100.100.100 sits INSIDE the tailnet
        // AllowedIPs 100.64.0.0/10, so its reply survives the inbound check and it is selected.
        let selected = ChainedTunnelResolverSelection.selectedResolvers(
            from: try configuration(
                dnsAddresses: ["100.100.100.100"], allowedIPs: ["100.64.0.0/10"],
                clientAddress: "100.64.0.5"))
        XCTAssertEqual(selected, ["100.100.100.100"])
    }

    func testASplitResolverOutsideAllowedIPsIsNotSelected() throws {
        // A split tunnel whose DNS lives off-tunnel (AllowedIPs 10.0.0.0/8, DNS 1.1.1.1): the
        // query is encapsulated but the reply arrives FROM 1.1.1.1, outside AllowedIPs, so the
        // runner drops it as a spoof (`dropSpoofedSource`). Selecting it would latch "ready" and
        // then fail every lookup, so it is excluded — an empty selection readiness turns into a
        // `noUsableTunnelDNS` latch refusal, the honest surface. (Codex #546 P1.)
        //
        // Mutation witness: dropping the `permits` guard in `selectedResolvers` selects
        // `1.1.1.1` and turns this assertion RED.
        let selected = ChainedTunnelResolverSelection.selectedResolvers(
            from: try configuration(
                dnsAddresses: ["1.1.1.1"], allowedIPs: ["10.0.0.0/8"],
                clientAddress: "10.0.0.5"))
        XCTAssertEqual(selected, [])
    }

    func testSplitSelectsOnlyTheResolversAllowedIPsCovers() throws {
        // Mixed: keep the covered resolver, drop the off-tunnel one — the subset semantics the
        // other selection rules use, applied to reachability.
        let selected = ChainedTunnelResolverSelection.selectedResolvers(
            from: try configuration(
                dnsAddresses: ["1.1.1.1", "10.8.0.1"], allowedIPs: ["10.0.0.0/8"],
                clientAddress: "10.0.0.5"))
        XCTAssertEqual(selected, ["10.8.0.1"])
    }

    // MARK: - Per-address dispositions (the settings panel's facts)

    func testAnUnusableAddressIsNamedUnusableEvenWhenTheTunnelAlsoCannotRouteIt() throws {
        // THE MISCLASSIFICATION (Kilo, PR #575). This derivation used to live open-coded in
        // `PacketTunnelProvider` and chose between the two refusals by asking whether the tunnel
        // ROUTED the address. An address that is both unusable and unrouted — a multicast literal
        // on a split tunnel — took the unrouted branch, so the panel blamed the tunnel's routing
        // for `224.0.0.1`. That advice survives its own remedy: a full tunnel leaves 224.0.0.1
        // exactly as unusable as it was.
        let conf = try configuration(dnsAddresses: ["10.64.0.1"], allowedIPs: ["10.0.0.0/8"])
        let selection = ChainedTunnelResolverSelection.selection(from: conf)
        let outcomes = ChainedTunnelResolverSelection.fallbackOutcomes(
            latched: ["224.0.0.1"], resolvesOverPlainDNS: true,
                selection: selection, configuration: conf)
        XCTAssertEqual(
            outcomes, [ChainedFallbackAddressOutcome(address: "224.0.0.1", disposition: .unusable)],
            "a multicast address is unusable, not a routing miss — the tunnel's shape is not the remedy")
    }

    func testAnUnparseableAddressIsUnusableRatherThanARoutingMiss() throws {
        // The same defect's quieter half: the old code parsed the address to test coverage and
        // treated a parse FAILURE as "not routed", so a v6 literal or a typo was reported as the
        // tunnel's fault. Neither is a routing problem, which is what this still pins.
        //
        // THE TWO NO LONGER SHARE A DISPOSITION, and the split is deliberate rather than
        // incidental: a typo is not a resolver at all, while `2606:4700:4700::1111` is a perfectly
        // good resolver Lava declines to ask (`INV-CHAIN-1`). Reporting both as `.unusable` told
        // the v6 user their address was broken (Codex P2, PR #591) — see
        // `testAnIPv6TierOneAddressIsNamedIPv6RatherThanUnusable` for the copy that replaces it.
        // What has NOT changed is the thing this test is named for: neither is a routing miss.
        let conf = try configuration(dnsAddresses: ["10.64.0.1"], allowedIPs: ["10.0.0.0/8"])
        for (address, expected) in [
            ("2606:4700:4700::1111", ChainedFallbackDisposition.unusableIPv6),
            ("not-an-address", ChainedFallbackDisposition.unusable)
        ] {
            let selection = ChainedTunnelResolverSelection.selection(from: conf)
            let dispositions = ChainedTunnelResolverSelection.fallbackOutcomes(
                latched: [address], resolvesOverPlainDNS: true,
                selection: selection, configuration: conf
            ).map(\.disposition)
            XCTAssertEqual(
                dispositions, [expected],
                "\(address) must be reported on its own terms")
            XCTAssertNotEqual(
                dispositions, [.notRoutedBySplitTunnel],
                "\(address) is not a routing problem — blaming the tunnel misdirects the user")
        }
    }

    func testAUsableAddressOffTheSplitTunnelIsNoLongerARoutingMiss() throws {
        // THE INVERSE OF WHAT THIS ONCE PINNED. It asserted `.notRoutedBySplitTunnel` for 1.1.1.1
        // on a tunnel carrying only 10.0.0.0/8, on the reasoning that the tunnel was the remedy —
        // true while T1 was carried through the peer. It is not carried any more: the rung
        // egresses on the physical interface, so a tunnel that routes 10.0.0.0/8 and nothing else
        // is no obstacle to reaching 1.1.1.1, and reporting one would send the user to edit a
        // profile that is fine (PR #590).
        let conf = try configuration(dnsAddresses: ["10.64.0.1"], allowedIPs: ["10.0.0.0/8"])
        let selection = ChainedTunnelResolverSelection.selection(from: conf)
        XCTAssertEqual(
            ChainedTunnelResolverSelection.fallbackOutcomes(
                latched: ["1.1.1.1"], resolvesOverPlainDNS: true,
                selection: selection, configuration: conf
            ).map(\.disposition), [.admitted])
    }

    func testAMixedSelectionReportsEachAddressOnItsOwnTerms() throws {
        // The whole reason the disposition is per address: the members of one selection meet
        // different fates in the same session, and a summary claim is wrong for some arrangement.
        // Three fates survive the physical-rung move — admitted, deduped into T0, and
        // unusable — and none of them may borrow another's cause. The fourth,
        // `.notRoutedBySplitTunnel`, is unproducible now (PR #590): 1.1.1.1 below sits outside a
        // tunnel carrying only 10.0.0.0/8 and is admitted anyway, because the rung does not need
        // the tunnel to carry it.
        let conf = try configuration(
            dnsAddresses: ["10.64.0.1", "10.8.8.8"], allowedIPs: ["10.0.0.0/8"],
            clientAddress: "10.0.0.5")
        let latched = ["10.9.9.9", "10.8.8.8", "224.0.0.1", "1.1.1.1"]
        let selection = ChainedTunnelResolverSelection.selection(from: conf)
        XCTAssertEqual(
            ChainedTunnelResolverSelection.fallbackOutcomes(
                latched: latched, resolvesOverPlainDNS: true,
                selection: selection, configuration: conf
            ).map(\.disposition),
            [.admitted, .alreadyPrimary, .unusable, .admitted],
            "each address must be reported on its own terms, in the order the user chose them")
    }

    /// A FULL TUNNEL reports T1 as unavailable, never as admitted.
    ///
    /// `ChainedResolverEgressPolicy` refuses the rung outright for `.fullTunnel`, so a
    /// structurally usable address there describes a resolver that can never be attempted.
    /// Reporting `.admitted` left the counters at zero forever, which `ChainedFallbackStatus`
    /// reads as `.readyUnused` — "Ready — not needed yet", indefinitely and untruthfully
    /// (Codex, PR #590).
    ///
    /// The same address is admitted under a split tunnel, so this cannot pass by the address
    /// being unusable.
    func testAFullTunnelReportsTierOneUnavailableRatherThanAdmitted() throws {
        let full = try configuration(dnsAddresses: ["10.64.0.1"])
        let split = try configuration(
            dnsAddresses: ["10.64.0.1"], allowedIPs: ["10.0.0.0/8"])

        XCTAssertEqual(
            ChainedTunnelResolverSelection.fallbackOutcomes(
                latched: ["1.1.1.1", "1.0.0.1"], resolvesOverPlainDNS: true,
                selection: ChainedTunnelResolverSelection.selection(from: full),
                configuration: full
            ).map(\.disposition),
            [.unavailableInFullTunnel, .unavailableInFullTunnel],
            "a full tunnel has no physical-interface rung, so no address is admitted")
        XCTAssertEqual(
            ChainedTunnelResolverSelection.fallbackOutcomes(
                latched: ["1.1.1.1", "1.0.0.1"], resolvesOverPlainDNS: true,
                selection: ChainedTunnelResolverSelection.selection(from: split),
                configuration: split
            ).map(\.disposition),
            [.admitted, .admitted],
            "...and the same addresses are admitted under a split tunnel, so this is the "
                + "routing policy talking and not the addresses")
    }

    func testUsabilityIsJudgedWithoutConsultingRouteCoverage() throws {
        // The split that makes the above possible: usability is a fact about the ADDRESS, so the
        // same verdict must hold under a tunnel that routes everything and one that routes almost
        // nothing. If route coverage ever leaks back into this judgement, these disagree.
        let full = try configuration(dnsAddresses: ["10.64.0.1"])
        let split = try configuration(dnsAddresses: ["10.64.0.1"], allowedIPs: ["10.0.0.0/8"])
        for address in ["1.1.1.1", "224.0.0.1", "255.255.255.255", "2606:4700::1111", "0.0.0.0"] {
            XCTAssertEqual(
                ChainedTunnelResolverSelection.isUsableResolverAddress(address, in: full),
                ChainedTunnelResolverSelection.isUsableResolverAddress(address, in: split),
                "\(address)'s usability must not depend on what the tunnel routes")
        }
        // And it still refuses the configuration-relative collisions, which ARE its business.
        XCTAssertFalse(
            ChainedTunnelResolverSelection.isUsableResolverAddress(
                TunnelRoutePlan.dnsServerAddress, in: full),
            "the tunnel's own DNS proxy address is the interception loop")
        XCTAssertFalse(
            ChainedTunnelResolverSelection.isUsableResolverAddress("10.64.0.5", in: full),
            "the configuration's own client address is delivered locally, never routed out")
        XCTAssertTrue(ChainedTunnelResolverSelection.isUsableResolverAddress("1.1.1.1", in: full))
    }

    func testAFullTunnelSelectsAResolverAtAnyAddress() throws {
        // Regression: full tunnel covers 0.0.0.0/0, so the coverage gate excludes nothing — a
        // public resolver is still selected exactly as before the gate existed.
        let selected = ChainedTunnelResolverSelection.selectedResolvers(
            from: try configuration(dnsAddresses: ["1.1.1.1"]))
        XCTAssertEqual(selected, ["1.1.1.1"])
    }

    // MARK: - The encrypted rung has no address question

    /// An ENCRYPTED T1 endpoint is admitted whole, without an IPv4 gate it cannot pass.
    ///
    /// Both surviving gates are about IPv4 literals — "is this already the conf's own `DNS =`"
    /// and "can this literal ever answer" — and a DoH host is outside both. Running them over it
    /// yields `.unusable` (`ipv4Octets` refuses a hostname), which would report the user's
    /// working resolver as broken and drive the panel to "pick a different resolver".
    func testAnEncryptedTierOneEndpointIsAdmittedWithoutAnIPv4Gate() throws {
        let conf = try configuration(dnsAddresses: ["10.64.0.1"], allowedIPs: ["10.0.0.0/8"])
        let selection = ChainedTunnelResolverSelection.selection(from: conf)

        XCTAssertEqual(
            ChainedTunnelResolverSelection.fallbackOutcomes(
                latched: ["cloudflare-dns.com"], resolvesOverPlainDNS: false,
                selection: selection, configuration: conf
            ).map(\.disposition), [.admitted],
            "a hostname reached over TLS on the physical path is not an unusable IPv4 literal")
        XCTAssertEqual(
            ChainedTunnelResolverSelection.fallbackOutcomes(
                latched: ["cloudflare-dns.com"], resolvesOverPlainDNS: true,
                selection: selection, configuration: conf
            ).map(\.disposition), [.unusable],
            "...and judged as a plain address it is exactly the misreport this parameter prevents")
    }

    /// An IPv6 T1 address is named IPv6, never "unusable".
    ///
    /// The usability gate answers false for a v6 literal, so without a case of its own the panel
    /// would render "can't be a resolver (reserved, or already used by your tunnel)" for an address
    /// that is perfectly capable of answering — blaming the resolver for a limit that is ours
    /// (`INV-CHAIN-1`). The two sit side by side here so the test fails if either collapses into
    /// the other.
    func testAnIPv6TierOneAddressIsNamedIPv6RatherThanUnusable() throws {
        let conf = try configuration(dnsAddresses: ["10.64.0.1"], allowedIPs: ["10.0.0.0/8"])
        let outcomes = ChainedTunnelResolverSelection.fallbackOutcomes(
            latched: ["2606:4700:4700::1111", "224.0.0.1", "1.1.1.1"], resolvesOverPlainDNS: true,
            selection: ChainedTunnelResolverSelection.selection(from: conf), configuration: conf)

        XCTAssertEqual(
            outcomes.map(\.disposition), [.unusableIPv6, .unusable, .admitted],
            "v6 is a limit of ours; multicast is a property of the address; the two are not one")
        XCTAssertEqual(
            outcomes.first?.refusalReason,
            "2606:4700:4700::1111 is IPv6 — Lava's VPN chaining only uses IPv4 resolvers",
            "the copy must name Lava as the limit rather than calling the resolver broken")
    }

    /// FULL TUNNEL STILL OUTRANKS THE TRANSPORT. The routing policy is a property of the session,
    /// so an encrypted selection fares identically to a plain one there — there is no
    /// physical-interface path for either.
    func testAnEncryptedTierOneEndpointIsStillUnavailableInAFullTunnel() throws {
        let full = try configuration(dnsAddresses: ["10.64.0.1"])
        XCTAssertEqual(
            ChainedTunnelResolverSelection.fallbackOutcomes(
                latched: ["cloudflare-dns.com"], resolvesOverPlainDNS: false,
                selection: ChainedTunnelResolverSelection.selection(from: full),
                configuration: full
            ).map(\.disposition), [.unavailableInFullTunnel])
    }
}
