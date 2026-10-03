import XCTest
@testable import LavaSecKit
@testable import LavaSecChainedUpstream

final class ChainedStackRoutingTests: XCTestCase {
    func profile(full: Bool, host: String = "198.51.100.2", client: String = "10.64.0.2") throws -> ChainedUpstreamConfiguration {
        try ChainedUpstreamConfiguration(endpointHost: host, endpointPort: 51820,
            peerPublicKey: "hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo=", clientAddress: client,
            allowedIPs: full ? ["0.0.0.0/0"] : ["10.0.0.0/8"], dnsAddresses: ["10.0.0.53"])
    }
    func testDisabledFullRowDoesNotWeakenActiveSplitRouteEnforcement() throws {
        let full = try profile(full: true).enabled(false), split = try profile(full: false)
        for saved in [try full.withEntryHop(split), try split.withEntryHop(full)] {
            let active = try XCTUnwrap(saved.activeConfiguration)
            XCTAssertEqual(active.effectiveRoutingPolicy, .splitTunnel)
            XCTAssertTrue(DNSRouteEnforcementPolicy.shouldEnforce(chainedUpstreamEnabled: true, routingPolicy: active.effectiveRoutingPolicy))
        }
    }
    func testUnselectedDNSDoesNotChangeResolverFingerprint() throws {
        let full = try profile(full: true), split = try profile(full: false)
        let otherDNS = try ChainedUpstreamConfiguration(endpointHost: split.endpointHost, endpointPort: split.endpointPort,
            peerPublicKey: split.peerPublicKey, clientAddress: split.clientAddress, allowedIPs: split.allowedIPs, dnsAddresses: ["10.0.0.54"])
        XCTAssertEqual(try split.withEntryHop(full).resolverSelectionFingerprint, try otherDNS.withEntryHop(full).resolverSelectionFingerprint)
        XCTAssertEqual(try full.withEntryHop(split).resolverSelectionFingerprint, try full.withEntryHop(otherDNS).resolverSelectionFingerprint)
    }
    func testSplitThenFullDoesNotRequireSplitToReachFullEndpoint() throws {
        let stack = try profile(full: true).withEntryHop(profile(full: false, host: "198.51.100.1"))
        XCTAssertTrue(stack.containsFullTunnel)
    }
    func testFullThenSplitCapturesPublicTrafficToo() throws {
        let stack = try profile(full: false).withEntryHop(profile(full: true, host: "198.51.100.1"))
        let plan = TunnelRoutePlan.make(for: .chainedUpstream(stack))
        XCTAssertTrue(plan.includedIPv4Routes.contains { $0.destinationAddress == "0.0.0.0" && $0.subnetMask == "0.0.0.0" })
    }
    func testOrderedDestinationsAndOverlappingSplitsAreDeterministic() throws {
        let split = try profile(full: false), full = try profile(full: true)
        let firstSplit = try full.withEntryHop(split)
        XCTAssertFalse(firstSplit.usesNestedTransport)
        XCTAssertEqual(firstSplit.routeIndex(forIPv4: 0x0a010203), 0)
        XCTAssertEqual(firstSplit.routeIndex(forIPv4: 0x01010101), 1)
        let firstFull = try split.withEntryHop(full)
        XCTAssertTrue(firstFull.usesNestedTransport)
        XCTAssertEqual(firstFull.routeIndex(forIPv4: 0x0a010203), 1)
        XCTAssertEqual(firstFull.routeIndex(forIPv4: 0x01010101), 0)
        let splits = try split.withEntryHop(split)
        XCTAssertEqual(splits.routeIndex(forIPv4: 0x0a010203), 0)
        XCTAssertNil(splits.routeIndex(forIPv4: 0x01010101))
        XCTAssertEqual(try full.withEntryHop(full).routeIndex(forIPv4: 0x01010101), 1)
    }
    func testFullProfileOwnsGeneralDNSAndIndependentStackDoesNotPayNestedMTU() throws {
        let split = try profile(full: false)
        let full = try ChainedUpstreamConfiguration(endpointHost: "198.51.100.1", endpointPort: 51820,
            peerPublicKey: split.peerPublicKey, clientAddress: "10.64.0.4", allowedIPs: ["0.0.0.0/0"],
            interfaceMTU: 1280, dnsAddresses: ["1.1.1.1"])
        let independent = try full.withEntryHop(split)
        XCTAssertEqual(independent.effectiveInterfaceMTU, 1280)
        XCTAssertEqual(ChainedTunnelResolverSelection.selectedResolvers(from: independent), ["1.1.1.1"])
        let fullWithoutSmallMTU = try ChainedUpstreamConfiguration(endpointHost: full.endpointHost, endpointPort: 51820,
            peerPublicKey: full.peerPublicKey, clientAddress: full.clientAddress, allowedIPs: full.allowedIPs, dnsAddresses: full.dnsAddresses)
        let nested = try split.withEntryHop(fullWithoutSmallMTU)
        XCTAssertEqual(ChainedTunnelResolverSelection.selectedResolvers(from: nested), ["1.1.1.1"])
        XCTAssertEqual(nested.effectiveRoutingPolicy, .fullTunnel)
        let twoFull = try fullWithoutSmallMTU.withEntryHop(profile(full: true))
        XCTAssertEqual(twoFull.stackDNSProfileIndex, 1)
        XCTAssertEqual(ChainedTunnelResolverSelection.selectedResolvers(from: twoFull), ["1.1.1.1"])
    }

    func testDNSCannotUseAnotherProfilesAddressOrAnOverlappingRouteOwnedByIt() throws {
        let full = try profile(full: true, client: "10.64.0.2")
        let split = try profile(full: false, client: "10.99.0.3")
        XCTAssertFalse(ChainedTunnelResolverSelection.isUsableResolverAddress("10.64.0.2", in: try split.withEntryHop(full)))
        XCTAssertTrue(ChainedTunnelResolverSelection.selectedResolvers(from: try split.withEntryHop(full)).isEmpty,
            "The full provider's 10.0.0.53 resolver is owned by the split destination policy, so it cannot be silently sent there.")
    }

    func testSelectionFingerprintIncludesBothOrderedProfiles() throws {
        let split = try profile(full: false), full = try profile(full: true)
        let nested = try split.withEntryHop(full)
        let independent = try full.withEntryHop(split)
        XCTAssertNotEqual(nested.resolverSelectionFingerprint, independent.resolverSelectionFingerprint)
        XCTAssertNotEqual(nested.resolverSelectionFingerprint, try split.withEntryHop(split).resolverSelectionFingerprint)
        XCTAssertNotEqual(nested.resolverSelectionFingerprint,
            try split.withEntryHop(profile(full: true, client: "10.64.0.9")).resolverSelectionFingerprint)
        XCTAssertEqual(nested.resolverSelectionFingerprint,
            try split.withEntryHop(profile(full: true, host: "198.51.100.9")).resolverSelectionFingerprint)
    }

}
