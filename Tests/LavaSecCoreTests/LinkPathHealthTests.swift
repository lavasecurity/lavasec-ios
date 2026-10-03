import XCTest

@testable import LavaSecCore
@testable import LavaSecKit

/// Slice B: `LinkPathHealth` — the second connectivity-health signal, reporting the current network
/// path state. Pure value type, so behavioral tests (never source pins).
final class LinkPathHealthTests: XCTestCase {
    private static let ref = Date(timeIntervalSinceReferenceDate: 800_720_000)

    func testIdentifiesAsLinkPath() {
        XCTAssertEqual(LinkPathHealth().id, .linkPath)
    }

    func testSatisfiedPathReadsHealthy() {
        let health = TunnelHealthSnapshot(networkPathIsSatisfied: true)
        XCTAssertEqual(
            LinkPathHealth().verdict(for: .init(isConnected: true, health: health), now: Self.ref),
            .healthy)
    }

    func testUnsatisfiedPathReadsDownWithNetworkUnavailableReason() {
        let health = TunnelHealthSnapshot(networkPathIsSatisfied: false, lastNetworkChangeAt: Self.ref)
        let verdict = LinkPathHealth().verdict(
            for: .init(isConnected: true, health: health), now: Self.ref)
        XCTAssertEqual(verdict, .down("network-unavailable"))
        // Reason is the shared label, not a parallel literal — pinned so it can't drift.
        XCTAssertEqual(verdict.reason, ProtectionConnectivitySeverity.networkUnavailable.diagnosticLabel)
    }

    func testDisconnectedReadsHealthyEvenWithUnsatisfiedPath() {
        let health = TunnelHealthSnapshot(networkPathIsSatisfied: false)
        XCTAssertEqual(
            LinkPathHealth().verdict(for: .init(isConnected: false, health: health), now: Self.ref),
            .healthy)
    }

    /// The link-down condition the DNS module surfaces (via the policy's top-precedence
    /// `.networkUnavailable`) is exactly what `LinkPathHealth` reports as `.down`, with the SAME
    /// reason label — so the supervisor (Slice D) can dedupe the two rather than double-count.
    func testAgreesWithTheDNSModuleWhenTheLinkIsDown() {
        let health = TunnelHealthSnapshot(networkPathIsSatisfied: false, lastNetworkChangeAt: Self.ref)
        let inputs = ConnectivityHealthInputs(isConnected: true, health: health)
        XCTAssertEqual(
            LinkPathHealth().verdict(for: inputs, now: Self.ref),
            DNSResolutionHealth().verdict(for: inputs, now: Self.ref))
    }

    func testPureAndDeterministic() {
        let inputs = ConnectivityHealthInputs(
            isConnected: true,
            health: TunnelHealthSnapshot(networkPathIsSatisfied: false))
        let signal = LinkPathHealth()
        XCTAssertEqual(signal.verdict(for: inputs, now: Self.ref),
                       signal.verdict(for: inputs, now: Self.ref))
    }
}
