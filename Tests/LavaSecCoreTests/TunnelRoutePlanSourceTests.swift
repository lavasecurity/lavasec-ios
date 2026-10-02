import Foundation
import XCTest

@testable import LavaSecCore

/// Pins that the provider takes its routing *from* `TunnelRoutePlan` rather than alongside it.
///
/// This file previously did the opposite job: while the provider still hardcoded its
/// settings, a text pin compared the two descriptions field by field. Wiring the provider to
/// the plan retired that pin — the compiler now enforces the agreement — and replaced it
/// with a narrower question the compiler still cannot answer: has anyone put a routing
/// literal *back*?
///
/// That matters because the failure it guards is silent. A single inline
/// `NEIPv4Route(...)` or `settings.mtu = …` would keep compiling, keep passing
/// `TunnelRoutePlanTests`, and change what every user's tunnel claims on the DNS-only path
/// `INV-DNS-1` protects.
final class TunnelRoutePlanSourceTests: XCTestCase {
    func testTheProviderDerivesEverySettingFromThePlan() throws {
        let provider = try readPacketTunnelProviderSource()
        let builderBlock = try sourceBlock(
            in: provider,
            startingAt: "private static func makeTunnelNetworkSettings(",
            endingBefore: "// MARK: - App messaging (IPC)"
        )

        XCTAssertTrue(
            builderBlock.contains("let plan = TunnelRoutePlan.make("),
            "The settings builder must derive its values from the route plan for the latched mode."
        )
        XCTAssertTrue(
            builderBlock.contains("dnsCaptureResolverAddresses: dnsCaptureResolverAddresses,\n            capturesIPv6InDNSOnly: capturesIPv6InDNSOnly,\n            advertisesIPv6DNSInDNSOnly: advertisesIPv6DNSInDNSOnly,\n            declaresDefaultRoutesInDNSOnly: declaresDefaultRoutesInDNSOnly)"),
            "F3b: the capture-floor addresses must reach the plan through the builder, not be dropped."
        )
        for (label, derived) in [
            ("tunnel remote address", "NEPacketTunnelNetworkSettings(tunnelRemoteAddress: dnsServerAddress)"),
            ("MTU", "settings.mtu = NSNumber(value: Self.engineSafeMTU(for: mode, planMTU: plan.mtu))"),
            ("subnet mask", "subnetMasks: [plan.tunnelSubnetMask]"),
            ("DNS servers", "NEDNSSettings(servers: dnsServers)"),
        ] {
            XCTAssertTrue(builderBlock.contains(derived), "The \(label) must come from the plan.")
        }
    }

    func testTheProviderMapsRoutesGenericallyRatherThanEnumeratingThem() throws {
        let provider = try readPacketTunnelProviderSource()
        let builderBlock = try sourceBlock(
            in: provider,
            startingAt: "private static func makeTunnelNetworkSettings(",
            endingBefore: "// MARK: - App messaging (IPC)"
        )

        // A per-mode `switch` here would be the natural-looking regression: it compiles, it
        // is readable, and it re-splits one routing decision across two files.
        XCTAssertTrue(
            builderBlock.contains(
                "ipv4.includedRoutes = plan.includedIPv4Routes.map {\n"
                    + "            NEIPv4Route(destinationAddress: $0.destinationAddress, subnetMask: $0.subnetMask)\n"
                    + "        }"
            ),
            "Included routes must be mapped from the plan, so no mode's routes are spelled here."
        )
        XCTAssertFalse(
            builderBlock.contains("switch mode"),
            "The builder translates a plan; it must not re-decide anything per mode."
        )
    }

    func testNoRoutingLiteralSurvivesInTheProvider() throws {
        let provider = try readPacketTunnelProviderSource()

        // The plan owns these values. Any reappearance here is a second source of truth,
        // whichever mode it belongs to.
        for literal in ["\"10.255.0.2\"", "\"10.255.0.0\"", "\"255.255.255.0\"", "\"10.255.0.0/24\"", "\"0.0.0.0\""] {
            XCTAssertFalse(
                provider.contains(literal),
                "\(literal) belongs to TunnelRoutePlan; the provider must not restate it."
            )
        }
        XCTAssertFalse(
            provider.contains("settings.mtu = 1280"),
            "The MTU belongs to the plan — chained mode needs a different one, and a hardcoded "
                + "value here would silently win."
        )
        XCTAssertFalse(
            provider.contains("NEIPv4Route.default()"),
            "The default route must only ever arrive through a plan the latch chose."
        )
    }

    func testTheChainedMTUIsHeldUnderTheEnginePacketCeiling() throws {
        let provider = try readPacketTunnelProviderSource()
        let block = try sourceBlock(
            in: provider,
            startingAt: "static func engineSafeMTU(",
            endingBefore: "private static func makeTunnelNetworkSettings("
        )

        // An independent engine-ceiling check, NOT a restatement of how the plan picks its
        // MTU — that derivation has already changed once and this comment outlived it. What
        // holds regardless: LavaSecKit cannot import the engine module, so no plan value can
        // be checked against the engine's limits where it is chosen; the provider is the
        // only place the two meet.
        XCTAssertTrue(
            block.contains("min(planMTU, ceiling)") && block.contains("WireGuardSession.maximumIPPacketByteCount - 60"),
            "the chained MTU must be held under the ceiling the engine rejects packets above"
        )
        // DNS-only must NOT acquire a chained-mode dependency: its 1280 has no relationship
        // to the engine, and it is the path INV-DNS-1 protects for users who never enable
        // chaining.
        let dnsOnlyArm = try sourceBlock(in: block, startingAt: "case .dnsOnly:", endingBefore: "case .chainedUpstream(let configuration):")
        XCTAssertTrue(dnsOnlyArm.contains("return planMTU"))
        XCTAssertFalse(
            dnsOnlyArm.contains("WireGuardSession"),
            "the DNS-only MTU must not be derived from an engine constant"
        )
    }

    func testTheDNSProxyAddressIsSharedWithTheSelfListenerGuard() throws {
        let provider = try readPacketTunnelProviderSource()

        // isUsableDeviceDNSServer rejects the tunnel's own listeners — both families, since
        // F3c advertises a v6 one too — so a captured device resolver can never point back at
        // us. It has to reject the addresses the settings actually installed; binding both to
        // the plan is what keeps that true in chained mode, where the proxy does not move.
        XCTAssertTrue(
            provider.contains("static let tunnelDNSServerAddress = TunnelRoutePlan.dnsServerAddress"),
            "The self-listener guard must compare against the same address the plan installs."
        )
        XCTAssertTrue(
            provider.contains("static let tunnelDNSServerIPv6Address = TunnelRoutePlan.chainedDNSServerIPv6Address"),
            "The v6 listener must be excluded from capture too, or the tunnel reads its own proxy back."
        )
        XCTAssertTrue(
            provider.contains("guard address != tunnelDNSServerAddress, address != tunnelDNSServerIPv6Address else {"),
            "The device-DNS capture must still reject the tunnel's own listeners."
        )
    }

    func testTheProviderInstallsIPv6SettingsOnlyWhenThePlanClaimsIPv6() throws {
        let provider = try readPacketTunnelProviderSource()
        let builderBlock = try sourceBlock(
            in: provider,
            startingAt: "private static func makeTunnelNetworkSettings(",
            endingBefore: "// MARK: - App messaging (IPC)"
        )

        // Conditional on the PLAN, never on the mode: the builder translates, it does not
        // decide. A `switch mode` here would put the leak decision in two places.
        XCTAssertTrue(
            builderBlock.contains("if let ipv6Address = plan.tunnelIPv6Address,"),
            "IPv6 settings must be driven by the plan"
        )
        XCTAssertTrue(
            builderBlock.contains("ipv6.includedRoutes = plan.includedIPv6Routes.map {"),
            "IPv6 routes must be mapped from the plan, not enumerated here"
        )
        XCTAssertFalse(
            builderBlock.contains("\"::\""),
            "the IPv6 default route belongs to TunnelRoutePlan; the provider must not restate it"
        )
    }

    /// The provider claims the DNS capture floor — F1's curated public-resolver set and F3b's
    /// CAPTURED device resolvers — for a CHAINED path only.
    ///
    /// DNS-only passes `[]` for the ordinary floor; the opt-in patch adds its designated
    /// endpoints separately. Without that opt-in its route array stays the pre-chaining shape (`INV-DNS-1`): a claim
    /// there would draw a resolver's non-53 traffic into a path with no forwarding rung and
    /// silently drop it (the `https://1.1.1.1` breakage Kilo caught on PR #752). Full tunnel
    /// ignores the set by construction. A provider source pin because the package cannot observe
    /// which addresses the tunnel process actually handed the plan.
    func testTheProviderPassesCaptureFloorAddressesOnlyForAChainedPath() throws {
        let provider = try readPacketTunnelProviderSource()
        let seam = try sourceBlock(
            in: provider,
            startingAt: "func makeTunnelNetworkSettingsForLatchedDataPath(",
            endingBefore: "\n    }\n"
        )

        XCTAssertTrue(
            seam.contains("mode.isChainedUpstream"),
            "both floor sources must be claimed for a chained path only; DNS-only passes []")
        XCTAssertTrue(
            seam.contains("DNSCaptureFloor.curatedPublicResolverAddresses"),
            "F1: the curated public-resolver set is the floor's first source")
        XCTAssertTrue(
            seam.contains("DNSCaptureFloorMembership.claimableResolverAddresses("),
            "the captured set must pass through the on-link-gateway exclusion before the plan")
        XCTAssertTrue(
            seam.contains("currentDeviceDNSResolverAddresses()"),
            "the captured device resolvers are the F3b floor's source")
        XCTAssertTrue(
            seam.contains("dnsCaptureResolverAddresses: dnsCaptureResolverAddresses,"),
            "the addresses must actually reach the settings builder (F1/F3b)")
        XCTAssertTrue(
            seam.contains(": []"),
            "DNS-only must not inherit the general resolver floor")
        XCTAssertTrue(seam.contains("dnsCaptureResolverAddresses += currentDNSPatchCaptureAddresses()"))
        XCTAssertTrue(seam.contains("capturesIPv6InDNSOnly: isDNSPatchEnabled"))
        // Curated first, captured appended, the whole pair guarded by the chained ternary. The
        // concatenation literal is the pin so a later edit cannot drop one source or move the pair
        // outside the guard.
        XCTAssertTrue(
            seam.contains(
                "? DNSCaptureFloor.curatedPublicResolverAddresses\n"
                    + "                + DNSCaptureFloorMembership.claimableResolverAddresses("),
            "the curated set must be prepended to the captured resolvers under the chained guard")
    }
}
