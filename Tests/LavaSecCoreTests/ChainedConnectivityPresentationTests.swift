import XCTest
import LavaSecKit
import LavaSecPresentation

final class ChainedConnectivityPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private var connected: ChainedHandshakeStatus {
        ChainedHandshakeStatus(isChained: true, hasHandshake: true, everHandshaked: true)
    }
    private var sample: TunnelHealthSnapshot {
        TunnelHealthSnapshot(updatedAt: now, isChainedUpstreamActive: true)
    }
    func testOneSilentDestinationDoesNotClaimTheWholeVPNIsDown() {
        var health = sample
        health.chainedLongestUnansweredDestinationSeconds = 120
        health.chainedUnansweredDestinationCount = 1
        health.chainedDataPathTransmitWindowBytes = 50_000
        health.chainedDataPathReceiveWindowBytes = 500_000
        XCTAssertEqual(ChainedConnectivityPresentation.summary(health, handshake: connected,
            isConnected: true, now: now), "Some destinations unanswered")
    }
    func testUploadAsymmetryIsAnObservationNotProofOfAnOutage() {
        var health = sample
        health.chainedDataPathTransmitWindowBytes = 500_000
        health.chainedDataPathReceiveWindowBytes = 20_000
        XCTAssertEqual(ChainedConnectivityPresentation.summary(health, handshake: connected,
            isConnected: true, now: now), "Few replies observed")
    }
    func testNoObservedFailureDoesNotClaimAnEndToEndInternetTest() {
        XCTAssertEqual(ChainedConnectivityPresentation.summary(sample, handshake: connected,
            isConnected: true, now: now), "No issues observed")
    }
    func testUnknownReplyNeverClaimsConnectingHealthyOrDown() {
        XCTAssertEqual(ChainedConnectivityPresentation.summary(sample, handshake: nil,
            isConnected: true, now: now), "Status unavailable")
    }
    func testDisconnectedAndRetiredLifecyclesIgnoreOldConnectedSamples() {
        XCTAssertEqual(ChainedConnectivityPresentation.summary(sample, handshake: connected,
            isConnected: false, now: now), "Not connected")
        let inactive = ChainedHandshakeStatus(isChained: false, hasHandshake: false,
            everHandshaked: false, lifecycleIsActive: false)
        XCTAssertEqual(ChainedConnectivityPresentation.summary(sample, handshake: inactive,
            isConnected: true, now: now), "Not connected")
    }
    func testLiveDNSOnlyModeDoesNotReuseTheOldChainedSnapshot() {
        let dns = ChainedHandshakeStatus(isChained: false, hasHandshake: false, everHandshaked: false)
        XCTAssertEqual(ChainedConnectivityPresentation.summary(sample, handshake: dns,
            isConnected: true, now: now), "DNS-only")
    }
    func testKnownHandshakeStatesStayDistinct() {
        let starting = ChainedHandshakeStatus(isChained: true, hasHandshake: false, everHandshaked: false)
        let expired = ChainedHandshakeStatus(isChained: true, hasHandshake: false, everHandshaked: true)
        XCTAssertEqual(ChainedConnectivityPresentation.summary(sample, handshake: starting,
            isConnected: true, now: now), "Connecting…")
        XCTAssertEqual(ChainedConnectivityPresentation.summary(sample, handshake: expired,
            isConnected: true, now: now), "Handshake expired")
    }
    func testOfflinePathTakesPrecedenceOverAnUnansweredDestination() {
        var health = sample
        health.networkPathIsSatisfied = false
        health.chainedLongestUnansweredDestinationSeconds = 100
        XCTAssertEqual(ChainedConnectivityPresentation.summary(health, handshake: connected,
            isConnected: true, now: now), "Network unavailable")
    }
    func testOldOrFutureDatedSamplesCannotDeclareCurrentHealth() {
        for offset in [-91.0, 1.0] {
            var health = sample
            health.updatedAt = now.addingTimeInterval(offset)
            XCTAssertEqual(ChainedConnectivityPresentation.summary(health, handshake: connected,
                isConnected: true, now: now), "Sample out of date")
        }
    }
    func testCumulativeOutageCountersDoNotDescribeCurrentConnectivity() {
        var health = sample
        health.chainedTunnelDNSOutageCount = 42
        health.chainedLinkOutageCount = 17
        XCTAssertEqual(ChainedConnectivityPresentation.summary(health, handshake: connected,
            isConnected: true, now: now), "No issues observed")
    }
    func testNewChainedSessionWaitsForItsOwnSample() {
        var health = sample
        health.isChainedUpstreamActive = false
        XCTAssertEqual(ChainedConnectivityPresentation.summary(health, handshake: connected,
            isConnected: true, now: now), "Sample out of date")
    }
}
