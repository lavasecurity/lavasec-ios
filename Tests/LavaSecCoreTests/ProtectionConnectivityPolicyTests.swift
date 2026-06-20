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

    func testRejectedResponseRecommendsReconnect() {
        // A resolver that answers but with rejected content (rcode != 0 / no answers
        // / question mismatch) — e.g. a stale off-network resolver — is reachable but
        // unusable. It must be restart-worthy, not mis-read as healthy (the 1941
        // "DNS smoke probe failed: success" wedge where recovery never engaged).
        let startedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let latestFailureAt = startedAt.addingTimeInterval(3_600)
        let health = TunnelHealthSnapshot(
            startedAt: startedAt,
            lastFailureReason: "rejected-response",
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

    func testSustainedRejectedResponseEscalatesEvenWhenGenericStreakWasResetByChurn() {
        // UR-37 / LAV-87: a hijacking resolver keeps rejecting, but network-change /
        // settle churn keeps `consecutiveDNSSmokeProbeFailureCount` pinned at 1 so neither
        // threshold-3 path fires. The resolver-identity-scoped rejected counter survives
        // the churn and escalates so recovery (and the encrypted fallback) can engage.
        let startedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let probeAt = startedAt.addingTimeInterval(300)
        let health = TunnelHealthSnapshot(
            startedAt: startedAt,
            lastFailureReason: "rejected-response",
            consecutiveUpstreamFailureCount: 1,
            lastDNSSmokeProbeAt: probeAt,
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 1,
            consecutiveRejectedSmokeResponseCount: 3,
            rejectedSmokeResponseResolverIdentity: "device:220.159.212.200,220.159.212.201",
            lastResolverRuntimeResetAt: startedAt
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: probeAt.addingTimeInterval(1)
        )

        XCTAssertEqual(assessment.severity, .needsReconnect)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
    }

    func testRejectedResponseBelowThresholdStaysRecovering() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let probeAt = startedAt.addingTimeInterval(300)
        let health = TunnelHealthSnapshot(
            startedAt: startedAt,
            lastFailureReason: "rejected-response",
            consecutiveUpstreamFailureCount: 1,
            lastDNSSmokeProbeAt: probeAt,
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 1,
            consecutiveRejectedSmokeResponseCount: 2,
            rejectedSmokeResponseResolverIdentity: "device:220.159.212.200,220.159.212.201",
            lastResolverRuntimeResetAt: startedAt
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: probeAt.addingTimeInterval(1)
        )

        // Honesty floor: below the threshold it must not read healthy, but it must not
        // escalate to a reconnect either.
        XCTAssertEqual(assessment.severity, .recovering)
    }

    func testSustainedRejectedResponseClearedByPrimarySuccessStaysHealthy() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let probeAt = startedAt.addingTimeInterval(300)
        let health = TunnelHealthSnapshot(
            startedAt: startedAt,
            lastFailureReason: "rejected-response",
            consecutiveUpstreamFailureCount: 1,
            lastDNSSmokeProbeAt: probeAt,
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 1,
            consecutiveRejectedSmokeResponseCount: 3,
            rejectedSmokeResponseResolverIdentity: "device:220.159.212.200,220.159.212.201",
            lastResolverRuntimeResetAt: startedAt,
            lastPrimaryUpstreamSuccessAt: probeAt.addingTimeInterval(2)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: probeAt.addingTimeInterval(3)
        )

        // A genuine PRIMARY success postdating the probe means the resolver works again —
        // even with a stale-high rejected count, do not escalate.
        XCTAssertEqual(assessment.severity, .healthy)
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
    }

    func testRecentSmokeProbeFailureWithoutFallbackRecommendsReconnect() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            upstreamFailureCount: 3,
            consecutiveUpstreamFailureCount: 3,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(2),
            lastDNSSmokeProbeSucceeded: false,
            dnsSmokeProbeFailureCount: 3,
            consecutiveDNSSmokeProbeFailureCount: 3,
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

    func testForwardingSuccessDoesNotMaskPersistentlyFailingSmokeProbe() {
        // The reported "Protected, no internet" wedge: the primary resolver's health
        // probe keeps failing, but incidental forwarding / encrypted-fallback successes
        // (and self-reconnects) keep zeroing consecutiveUpstreamFailureCount. Recovery
        // must key off the dedicated smoke-failure counter so it still escalates.
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let smokeProbeAt = networkChangedAt.addingTimeInterval(40)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "rejected-response",
            // Reset to 0 by a fallback-carried forwarding success — the masking signal.
            consecutiveUpstreamFailureCount: 0,
            lastDNSSmokeProbeAt: smokeProbeAt,
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 3,
            lastNetworkChangeAt: networkChangedAt,
            // The last forwarding success PREDATES the failing probe, so it must not clear it.
            lastUpstreamSuccessAt: networkChangedAt.addingTimeInterval(5)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: smokeProbeAt.addingTimeInterval(1)
        )

        XCTAssertEqual(assessment.severity, .needsReconnect)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
    }

    func testColdStartFailingSmokeProbeWithoutNetworkChangeStillEscalates() {
        // Cold start / post-self-reconnect: a fresh snapshot has no lastNetworkChangeAt.
        // The probe must still be evaluated against the session-start baseline, or a
        // failing primary would be skipped entirely (and fallback traffic could paint it
        // healthy). Sustained failures → needsReconnect.
        let startedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let smokeProbeAt = startedAt.addingTimeInterval(8)
        let health = TunnelHealthSnapshot(
            startedAt: startedAt,
            lastFailureReason: "rejected-response",
            consecutiveUpstreamFailureCount: 0,
            lastDNSSmokeProbeAt: smokeProbeAt,
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 3
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: smokeProbeAt.addingTimeInterval(1)
        )

        XCTAssertEqual(assessment.severity, .needsReconnect)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
    }

    func testColdStartSingleFailingSmokeProbeWithoutNetworkChangeReportsRecovering() {
        // Same cold-start context, below the threshold: never `.healthy` over a failing
        // probe — surfaces `.recovering`.
        let startedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let smokeProbeAt = startedAt.addingTimeInterval(8)
        let health = TunnelHealthSnapshot(
            startedAt: startedAt,
            lastFailureReason: "timeout",
            consecutiveUpstreamFailureCount: 0,
            lastDNSSmokeProbeAt: smokeProbeAt,
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 1
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: smokeProbeAt.addingTimeInterval(1)
        )

        XCTAssertEqual(assessment.severity, .recovering)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }

    func testSingleUncoveredSmokeProbeFailureReportsRecoveringNotHealthy() {
        // Below the reconnect threshold a failing probe must still not read as healthy
        // ("Protected"); it surfaces as recovering until a probe succeeds.
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let smokeProbeAt = networkChangedAt.addingTimeInterval(5)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "timeout",
            consecutiveUpstreamFailureCount: 0,
            lastDNSSmokeProbeAt: smokeProbeAt,
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 1,
            lastNetworkChangeAt: networkChangedAt
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: smokeProbeAt.addingTimeInterval(1)
        )

        XCTAssertEqual(assessment.severity, .recovering)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }

    func testPrimaryForwardingSuccessAfterFailedSmokeProbeStaysHealthy() {
        // The inverse guard: a genuine PRIMARY forwarding success that POSTDATES the
        // failed probe means the configured resolver is working again, so we must not
        // nag. Stays healthy.
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let smokeProbeAt = networkChangedAt.addingTimeInterval(5)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "timeout",
            lastDNSSmokeProbeAt: smokeProbeAt,
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 3,
            lastNetworkChangeAt: networkChangedAt,
            lastPrimaryUpstreamSuccessAt: smokeProbeAt.addingTimeInterval(2)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: smokeProbeAt.addingTimeInterval(3)
        )

        XCTAssertEqual(assessment.severity, .healthy)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }

    func testFallbackSuccessAfterFailedSmokeProbeStillRecommendsReconnect() {
        // A fallback-carried success (encrypted or device-DNS) does NOT prove the
        // configured primary recovered — it bumps lastUpstreamSuccessAt but not
        // lastPrimaryUpstreamSuccessAt. It must not clear a sustained failing primary
        // probe, or the "fallback masks a failing primary" wedge returns.
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let smokeProbeAt = networkChangedAt.addingTimeInterval(40)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "rejected-response",
            consecutiveUpstreamFailureCount: 0,
            lastDNSSmokeProbeAt: smokeProbeAt,
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 3,
            lastNetworkChangeAt: networkChangedAt,
            // Fallback-carried success AFTER the probe: bumps lastUpstreamSuccessAt only.
            lastUpstreamSuccessAt: smokeProbeAt.addingTimeInterval(2)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: smokeProbeAt.addingTimeInterval(3)
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
