import XCTest
@testable import LavaSecKit

final class DNSRouteEnforcementPolicyTests: XCTestCase {
    func testSplitTunnelEnforcesItsResolverAndPeerRoutes() {
        XCTAssertTrue(DNSRouteEnforcementPolicy.shouldEnforce(
            chainedUpstreamEnabled: true, routingPolicy: .splitTunnel))
    }

    func testDNSOnlyEnforcesItsRoutesRegardlessOfAnUnusedStoredPeer() {
        for policy: ChainedRoutingPolicy? in [nil, .splitTunnel, .fullTunnel] {
            XCTAssertTrue(DNSRouteEnforcementPolicy.shouldEnforce(
                chainedUpstreamEnabled: false, routingPolicy: policy))
        }
    }

    func testFullTunnelDoesNotUseEnforceRoutesForDefaultRoutes() {
        XCTAssertFalse(DNSRouteEnforcementPolicy.shouldEnforce(
            chainedUpstreamEnabled: true, routingPolicy: .fullTunnel))
    }

    func testUnreadableChainedConfigurationDoesNotGuessSplitRouting() {
        XCTAssertFalse(DNSRouteEnforcementPolicy.shouldEnforce(
            chainedUpstreamEnabled: true, routingPolicy: nil))
    }

    func testResolverComparisonCannotFollowTheUserIntoFullTunnel() {
        for override in [true, false] {
            for policy: ChainedRoutingPolicy? in [.fullTunnel, nil] {
                XCTAssertFalse(DNSRouteEnforcementPolicy.shouldEnforce(
                    chainedUpstreamEnabled: true, routingPolicy: policy,
                    resolverCaptureOverride: override))
            }
        }
    }

    func testResolverComparisonStillControlsDNSOnlyWithSavedFullTunnelCredentials() {
        for override in [true, false] {
            XCTAssertEqual(DNSRouteEnforcementPolicy.shouldEnforce(
                chainedUpstreamEnabled: false, routingPolicy: .fullTunnel,
                resolverCaptureOverride: override), override)
            XCTAssertEqual(DNSRouteEnforcementPolicy.shouldEnforce(
                chainedUpstreamEnabled: true, routingPolicy: .splitTunnel,
                resolverCaptureOverride: override), override)
        }
    }

    func testUnusedFullTunnelCredentialsCannotLockDownDNSOnly() {
        XCTAssertFalse(DNSRouteEnforcementPolicy.shouldIncludeAllNetworks(
            requested: true, chainedUpstreamEnabled: false, routingPolicy: .fullTunnel))
    }

    func testSplitAndUnreadablePeersCannotActivateLockdown() {
        for policy: ChainedRoutingPolicy? in [nil, .splitTunnel] {
            XCTAssertFalse(DNSRouteEnforcementPolicy.shouldIncludeAllNetworks(
                requested: true, chainedUpstreamEnabled: true, routingPolicy: policy))
        }
    }

    func testFullTunnelComparisonCanExplicitlyEnableAndDisableLockdown() {
        XCTAssertTrue(DNSRouteEnforcementPolicy.shouldIncludeAllNetworks(
            requested: true, chainedUpstreamEnabled: true, routingPolicy: .fullTunnel))
        XCTAssertFalse(DNSRouteEnforcementPolicy.shouldIncludeAllNetworks(
            requested: false, chainedUpstreamEnabled: true, routingPolicy: .fullTunnel))
    }
}
