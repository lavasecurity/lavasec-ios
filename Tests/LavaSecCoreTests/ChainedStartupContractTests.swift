import XCTest

@testable import LavaSecKit

final class ChainedStartupContractTests: XCTestCase {
    func testStrictProfileCannotStartDNSOnlyEvenWhenChainingWasDisabled() {
        for enabled in [false, true] {
            XCTAssertEqual(ChainedStartupContract.decide(
                chainedUpstreamEnabled: enabled, latchedMode: .dnsOnly,
                refusal: .upstreamUnavailable, includeAllNetworks: true),
                .rejectStrictProfile(refusal: .upstreamUnavailable))
        }
    }
    /// 🔴 FAIL CLOSED. Every refusal starts the latched DNS-only path. Refusing the start left
    /// the device unfiltered: on 2026-09-17 a locked-device eligibility read became a terminal
    /// marker, the app disarmed Connect-On-Demand and persisted OFF, and nothing restarted
    /// (plans/2026-09-18-fail-closed-protection-startup-failures-plan.md). The saved chaining
    /// intent still governs which mode runs; a failed chain is disclosed and recovered, never a
    /// reason to stop filtering.
    func testARequestedChainNeverStartsUnfiltered() {
        for refusal: TunnelDataPathLatch.Refusal in [
            .configurationUnreadable, .unsupportedByBuild, .deviceStateUnavailable,
            .upstreamUnavailable, .deviceIneligible(.startupCrashLoop),
            .deviceIneligible(.insufficientMemory), .chainedSurrendered,
        ] {
            XCTAssertEqual(
                ChainedStartupContract.decide(
                    chainedUpstreamEnabled: true,
                    latchedMode: .dnsOnly,
                    refusal: refusal),
                .startDegraded(refusal: refusal),
                "\(refusal) must keep the DNS-only path filtering")
        }
    }

    /// An absent refusal on a requested-but-unlatched chain is still a degraded start. The
    /// latch's biconditional says it cannot happen, and if it ever does the provider must still
    /// install the DNS-only path rather than leave the device unfiltered.
    func testAnAbsentRefusalStillStartsDegraded() {
        XCTAssertEqual(
            ChainedStartupContract.decide(
                chainedUpstreamEnabled: true,
                latchedMode: .dnsOnly,
                refusal: nil),
            .startDegraded(refusal: nil))
    }

    func testARequestedAndLatchedChainMayStart() throws {
        let upstream = try ChainedUpstreamConfiguration(
            endpointHost: "203.0.113.10",
            endpointPort: 51820,
            peerPublicKey: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=",
            clientAddress: "10.10.0.2",
            allowedIPs: ["0.0.0.0/0"])

        XCTAssertEqual(
            ChainedStartupContract.decide(
                chainedUpstreamEnabled: true,
                latchedMode: .chainedUpstream(upstream),
                refusal: nil),
            .start)
        XCTAssertEqual(ChainedStartupContract.decide(
            chainedUpstreamEnabled: true, latchedMode: .chainedUpstream(upstream),
            refusal: nil, includeAllNetworks: true), .start)
        let split = try ChainedUpstreamConfiguration(
            endpointHost: "203.0.113.10", endpointPort: 51820,
            peerPublicKey: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=",
            clientAddress: "10.10.0.2", allowedIPs: ["10.0.0.0/8"])
        XCTAssertEqual(ChainedStartupContract.decide(
            chainedUpstreamEnabled: true, latchedMode: .chainedUpstream(split),
            refusal: nil, includeAllNetworks: true), .rejectStrictProfile(refusal: nil))
    }

    func testDNSOnlyMayStartWhenChainingIsNotRequested() {
        XCTAssertEqual(
            ChainedStartupContract.decide(
                chainedUpstreamEnabled: false,
                latchedMode: .dnsOnly,
                refusal: .chainingDisabled),
            .start)
    }
}
