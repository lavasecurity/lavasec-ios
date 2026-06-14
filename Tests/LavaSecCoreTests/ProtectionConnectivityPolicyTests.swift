import XCTest
@testable import LavaSecCore

final class ProtectionConnectivityPolicyTests: XCTestCase {
    func testConnectedHealthWithPostNetworkChangeFailureRecommendsReconnect() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "timeout",
            upstreamSuccessCount: 20,
            upstreamFailureCount: 3,
            consecutiveUpstreamFailureCount: 3,
            lastNetworkChangeAt: networkChangedAt,
            lastResolverRuntimeResetAt: networkChangedAt.addingTimeInterval(1),
            lastResolverRuntimeResetReason: "network-path-changed",
            resolverRuntimeResetCount: 1,
            lastUpstreamSuccessAt: networkChangedAt.addingTimeInterval(-30),
            lastUpstreamFailureAt: networkChangedAt.addingTimeInterval(8)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: networkChangedAt.addingTimeInterval(12)
        )

        XCTAssertEqual(assessment.severity, .needsReconnect)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
    }

    func testStableNetworkSingleTimeoutAfterLongUptimeDoesNotRecommendReconnect() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let lastSuccessAt = startedAt.addingTimeInterval(3_570)
        let latestTimeoutAt = startedAt.addingTimeInterval(3_600)
        let health = TunnelHealthSnapshot(
            startedAt: startedAt,
            lastFailureReason: "timeout",
            upstreamSuccessCount: 120,
            upstreamFailureCount: 1,
            consecutiveUpstreamFailureCount: 1,
            lastUpstreamSuccessAt: lastSuccessAt,
            lastUpstreamFailureAt: latestTimeoutAt
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: latestTimeoutAt.addingTimeInterval(1)
        )

        XCTAssertEqual(assessment.severity, .healthy)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }

    func testRepeatedStableNetworkTimeoutsRecommendReconnect() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let lastSuccessAt = startedAt.addingTimeInterval(3_540)
        let latestTimeoutAt = startedAt.addingTimeInterval(3_600)
        let health = TunnelHealthSnapshot(
            startedAt: startedAt,
            lastFailureReason: "timeout",
            upstreamSuccessCount: 120,
            upstreamFailureCount: 3,
            consecutiveUpstreamFailureCount: 3,
            lastUpstreamSuccessAt: lastSuccessAt,
            lastUpstreamFailureAt: latestTimeoutAt
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: latestTimeoutAt.addingTimeInterval(1)
        )

        XCTAssertEqual(assessment.severity, .needsReconnect)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
    }

    func testBackedOffFailureRecommendsReconnectAfterRepeatedDoHFailures() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let latestFailureAt = startedAt.addingTimeInterval(3_600)
        let health = TunnelHealthSnapshot(
            startedAt: startedAt,
            lastFailureReason: "backed-off",
            upstreamSuccessCount: 120,
            upstreamFailureCount: 3,
            consecutiveUpstreamFailureCount: 3,
            lastUpstreamSuccessAt: startedAt.addingTimeInterval(3_540),
            lastUpstreamFailureAt: latestFailureAt
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: latestFailureAt.addingTimeInterval(1)
        )

        XCTAssertEqual(assessment.severity, .needsReconnect)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
    }

    func testDoHHTTPFailureRecommendsReconnectAfterRepeatedFailures() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let latestFailureAt = startedAt.addingTimeInterval(3_600)
        let health = TunnelHealthSnapshot(
            startedAt: startedAt,
            lastFailureReason: "http-status-failure",
            upstreamSuccessCount: 120,
            upstreamFailureCount: 3,
            consecutiveUpstreamFailureCount: 3,
            lastUpstreamSuccessAt: startedAt.addingTimeInterval(3_540),
            lastUpstreamFailureAt: latestFailureAt
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: latestFailureAt.addingTimeInterval(1)
        )

        XCTAssertEqual(assessment.severity, .needsReconnect)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
    }

    func testNetworkPathLossReportsUnavailableWithoutReconnectAction() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            networkPathIsSatisfied: false,
            lastNetworkChangeAt: networkChangedAt
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: networkChangedAt.addingTimeInterval(12)
        )

        XCTAssertEqual(assessment.severity, .networkUnavailable)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
        XCTAssertEqual(assessment.title, "Network Lost")
    }

    func testRecentDeviceDNSFallbackAfterNetworkChangeReportsAutomaticFallback() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            lastResolverTransport: .deviceDNS,
            deviceDNSFallbackModeActive: true,
            lastDeviceDNSFallbackActivatedAt: networkChangedAt.addingTimeInterval(2),
            deviceDNSFallbackActivationCount: 1,
            lastNetworkChangeAt: networkChangedAt,
            lastUpstreamSuccessAt: networkChangedAt.addingTimeInterval(4)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: networkChangedAt.addingTimeInterval(30)
        )

        XCTAssertEqual(assessment.severity, .usingDeviceDNSFallback)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
        XCTAssertEqual(assessment.title, "Protected")
        XCTAssertEqual(
            assessment.subtitle,
            "Filtering is on with Device DNS fallback because the selected DNS resolver is unavailable"
        )
    }

    func testHistoricalDeviceDNSFallbackTimestampWithoutActiveModeReportsHealthy() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            lastResolverTransport: .deviceDNS,
            lastDeviceDNSFallbackActivatedAt: networkChangedAt.addingTimeInterval(2),
            deviceDNSFallbackActivationCount: 1,
            lastNetworkChangeAt: networkChangedAt,
            lastUpstreamSuccessAt: networkChangedAt.addingTimeInterval(4)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: networkChangedAt.addingTimeInterval(30)
        )

        XCTAssertEqual(assessment.severity, .healthy)
    }

    func testActiveDeviceDNSFallbackWithoutNetworkChangeReportsAutomaticFallback() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            startedAt: startedAt,
            lastResolverTransport: .deviceDNS,
            deviceDNSFallbackModeActive: true,
            lastDeviceDNSFallbackActivatedAt: startedAt.addingTimeInterval(12),
            deviceDNSFallbackActivationCount: 1,
            lastUpstreamSuccessAt: startedAt.addingTimeInterval(14)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: startedAt.addingTimeInterval(30)
        )

        XCTAssertEqual(assessment.severity, .usingDeviceDNSFallback)
    }

    func testRepeatedSlowSuccessfulDNSReportsResolverSlow() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let latestSlowResponseAt = startedAt.addingTimeInterval(60)
        let health = TunnelHealthSnapshot(
            startedAt: startedAt,
            upstreamSuccessCount: 12,
            lastUpstreamSuccessAt: latestSlowResponseAt,
            lastUpstreamDurationMilliseconds: 3_200,
            slowUpstreamResponseCount: 4,
            consecutiveSlowUpstreamResponseCount: 3,
            lastSlowUpstreamResponseAt: latestSlowResponseAt
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: latestSlowResponseAt.addingTimeInterval(1)
        )

        XCTAssertEqual(assessment.severity, .dnsSlow)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
        XCTAssertEqual(assessment.title, "DNS Slow")
    }

    func testRecentSmokeProbeSuccessAfterNetworkChangeReportsConnectedProtection() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            lastResolverTransport: .plainDNS,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(2),
            lastDNSSmokeProbeSucceeded: true,
            dnsSmokeProbeSuccessCount: 1,
            lastNetworkChangeAt: networkChangedAt,
            lastUpstreamSuccessAt: networkChangedAt.addingTimeInterval(4)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: networkChangedAt.addingTimeInterval(30)
        )

        XCTAssertEqual(assessment.severity, .healthy)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
        XCTAssertEqual(assessment.title, "Protected")
    }

    func testRecentSmokeProbeFailureWithoutFallbackRecommendsReconnect() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            upstreamFailureCount: 3,
            consecutiveUpstreamFailureCount: 3,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(2),
            lastDNSSmokeProbeSucceeded: false,
            dnsSmokeProbeFailureCount: 1,
            lastNetworkChangeAt: networkChangedAt
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: networkChangedAt.addingTimeInterval(12)
        )

        XCTAssertEqual(assessment.severity, .needsReconnect)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
    }

    func testActiveDeviceDNSFallbackSmokeProbeCoverageDoesNotRecommendReconnect() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            lastResolverTransport: .deviceDNS,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(30),
            lastDNSSmokeProbeSucceeded: false,
            dnsSmokeProbeFailureCount: 1,
            deviceDNSFallbackModeActive: true,
            lastDeviceDNSFallbackActivatedAt: networkChangedAt.addingTimeInterval(2),
            deviceDNSFallbackActivationCount: 1,
            lastNetworkChangeAt: networkChangedAt
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: networkChangedAt.addingTimeInterval(40)
        )

        XCTAssertEqual(assessment.severity, .usingDeviceDNSFallback)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }

    func testDeviceDNSUnavailableDoesNotRecommendReconnect() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "device-dns-unavailable",
            upstreamFailureCount: 1,
            consecutiveUpstreamFailureCount: 3,
            lastNetworkChangeAt: networkChangedAt,
            lastResolverRuntimeResetAt: networkChangedAt.addingTimeInterval(1),
            lastResolverRuntimeResetReason: "network-path-changed",
            resolverRuntimeResetCount: 1,
            lastUpstreamFailureAt: networkChangedAt.addingTimeInterval(8)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: networkChangedAt.addingTimeInterval(30)
        )

        XCTAssertEqual(assessment.severity, .healthy)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }

    func testFreshNetworkRuntimeResetShowsRecoveringBeforeFailuresArrive() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            lastNetworkChangeAt: networkChangedAt,
            lastResolverRuntimeResetAt: networkChangedAt.addingTimeInterval(1),
            lastResolverRuntimeResetReason: "network-path-changed",
            resolverRuntimeResetCount: 1,
            lastUpstreamSuccessAt: networkChangedAt.addingTimeInterval(-10)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: networkChangedAt.addingTimeInterval(4)
        )

        XCTAssertEqual(assessment.severity, .recovering)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }

    func testSuccessAfterNetworkChangeClearsReconnectRecommendation() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            upstreamSuccessCount: 21,
            upstreamFailureCount: 1,
            consecutiveUpstreamFailureCount: 1,
            lastNetworkChangeAt: networkChangedAt,
            lastResolverRuntimeResetAt: networkChangedAt.addingTimeInterval(1),
            lastResolverRuntimeResetReason: "network-path-changed",
            resolverRuntimeResetCount: 1,
            lastUpstreamSuccessAt: networkChangedAt.addingTimeInterval(10),
            lastUpstreamFailureAt: networkChangedAt.addingTimeInterval(6)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: networkChangedAt.addingTimeInterval(20)
        )

        XCTAssertEqual(assessment.severity, .healthy)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }

    func testDisconnectedProtectionNeverRecommendsReconnect() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "timeout",
            lastNetworkChangeAt: networkChangedAt,
            lastUpstreamFailureAt: networkChangedAt.addingTimeInterval(8)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: false,
            health: health,
            now: networkChangedAt.addingTimeInterval(12)
        )

        XCTAssertEqual(assessment.severity, .healthy)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }
}
