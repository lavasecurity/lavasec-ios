import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

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

    // A zero-evidence settle wait right after a handoff reads `.healthy`, matching cold
    // start under the same zero evidence — `.recovering` is reserved for real failure
    // evidence (the honesty floor). Previously this window showed "Reconnecting" for up
    // to 10s while merely waiting for the first post-reset success.
    func testFreshNetworkRuntimeResetStaysHealthyBeforeEvidenceArrives() {
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

        XCTAssertEqual(assessment.severity, .healthy)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }

    // The pause-resume shape of the same wait: a `.protectionPolicyRefresh` runtime reset
    // (pause flip, filter toggle) stamps `lastResolverRuntimeResetAt` hours after the last
    // handoff. The removed window branch keyed on ANY reset postdating ANY network change,
    // so resuming from pause flashed "Reconnecting" with zero failure evidence whenever a
    // handoff existed earlier in the session.
    func testPolicyRefreshResetAfterStaleNetworkChangeStaysHealthy() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let resumedAt = networkChangedAt.addingTimeInterval(7_200)
        let health = TunnelHealthSnapshot(
            upstreamSuccessCount: 40,
            lastNetworkChangeAt: networkChangedAt,
            lastResolverRuntimeResetAt: resumedAt,
            lastResolverRuntimeResetReason: "pause-updated",
            resolverRuntimeResetCount: 2,
            lastUpstreamSuccessAt: resumedAt.addingTimeInterval(-30)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: resumedAt.addingTimeInterval(2)
        )

        XCTAssertEqual(assessment.severity, .healthy)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }

    // The floor still owns the immediate post-handoff window when evidence of trouble
    // exists: one uncovered failed probe inside the old 10s window must stay `.recovering`,
    // proving the removal above dropped only the zero-evidence wait, not the floor.
    func testFailedProbeRightAfterNetworkChangeStillRecovering() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "timeout",
            consecutiveUpstreamFailureCount: 1,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(3),
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 1,
            lastNetworkChangeAt: networkChangedAt,
            lastResolverRuntimeResetAt: networkChangedAt.addingTimeInterval(1),
            lastResolverRuntimeResetReason: "network-path-changed",
            resolverRuntimeResetCount: 1,
            lastUpstreamFailureAt: networkChangedAt.addingTimeInterval(3)
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

    // MARK: - Encrypted-fallback coverage (transition self-reconnect suppression)

    /// Incident shape (WiFi→cellular handoff): the device-DNS primary went stale
    /// (`receive-failed`) and the smoke streak reached the reconnect threshold, but the
    /// encrypted DoH fallback is actively serving DNS. Must NOT escalate to a restart —
    /// surface `.usingEncryptedFallback` / `.turnOff` instead.
    func testTransitionStalenessCoveredByServingEncryptedFallbackDoesNotReconnect() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "receive-failed",
            consecutiveUpstreamFailureCount: 1, // a DoH success reset the upstream streak
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(3),
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 3, // would escalate without coverage
            consecutiveRejectedSmokeResponseCount: 0,
            lastNetworkChangeAt: networkChangedAt,
            lastEncryptedFallbackSuccessAt: networkChangedAt.addingTimeInterval(12)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: networkChangedAt.addingTimeInterval(17) // DoH success 5s ago — serving
        )

        XCTAssertEqual(assessment.severity, .usingEncryptedFallback)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }

    /// `isEncryptedFallbackCoveringWedge(health:now:)` — the public helper the tunnel's covered
    /// recapture reads — must be EXACTLY the coverage bit `assessment(…)` surfaces as
    /// `.usingEncryptedFallback`, including the two divergence traps a hand-rolled tunnel predicate
    /// would have gotten wrong: a pending rejection streak, and a primary recovery postdating the probe.
    func testIsEncryptedFallbackCoveringWedgeMatchesTheAssessmentCoverageBit() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let now = networkChangedAt.addingTimeInterval(17)
        func health(rejected: Int = 0, primarySuccessAt: Date? = nil) -> TunnelHealthSnapshot {
            TunnelHealthSnapshot(
                lastFailureReason: "receive-failed",
                consecutiveUpstreamFailureCount: 1,
                lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(3),
                lastDNSSmokeProbeSucceeded: false,
                consecutiveDNSSmokeProbeFailureCount: 3,
                consecutiveRejectedSmokeResponseCount: rejected,
                lastNetworkChangeAt: networkChangedAt,
                lastPrimaryUpstreamSuccessAt: primarySuccessAt,
                lastEncryptedFallbackSuccessAt: networkChangedAt.addingTimeInterval(12)
            )
        }
        func severity(_ h: TunnelHealthSnapshot) -> ProtectionConnectivitySeverity {
            ProtectionConnectivityPolicy.assessment(isConnected: true, health: h, now: now).severity
        }

        // Covered: helper true, and the assessment agrees.
        let covered = health()
        XCTAssertTrue(ProtectionConnectivityPolicy.isEncryptedFallbackCoveringWedge(health: covered, now: now))
        XCTAssertEqual(severity(covered), .usingEncryptedFallback)

        // Trap (a): a pending rejection vetoes coverage (round-19 gate) — helper false, assessment not covered.
        let rejecting = health(rejected: 2)
        XCTAssertFalse(ProtectionConnectivityPolicy.isEncryptedFallbackCoveringWedge(health: rejecting, now: now))
        XCTAssertNotEqual(severity(rejecting), .usingEncryptedFallback)

        // Trap (b): a primary success postdating the failed probe ends coverage — helper false.
        let recovered = health(primarySuccessAt: networkChangedAt.addingTimeInterval(15))
        XCTAssertFalse(ProtectionConnectivityPolicy.isEncryptedFallbackCoveringWedge(health: recovered, now: now))
        XCTAssertNotEqual(severity(recovered), .usingEncryptedFallback)
    }

    /// The accelerated covered-state recapture re-probes the primary every 30s instead of the
    /// 300s routine, so `consecutiveDNSSmokeProbeFailureCount` climbs ~10x faster while the
    /// primary stays wedged. That MUST NOT change the verdict: while the encrypted fallback is
    /// serving, coverage short-circuits `hasCurrentRestartWorthyFailure` BEFORE the smoke-count
    /// check, so no count — however high — escalates to `.reconnect`. This is the safety floor
    /// of the accelerated loop: an escalation here would stamp the wedge marker and flip the
    /// rejection-as-fallback trigger (the bypass of authoritative SERVFAIL/REFUSED).
    func testHighSmokeFailureCountWhileCoveredNeverEscalatesRegardlessOfCadence() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "receive-failed",
            consecutiveUpstreamFailureCount: 1,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(48),
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 12, // far past reconnectFailureThreshold via the 30s cadence
            consecutiveRejectedSmokeResponseCount: 0,
            lastNetworkChangeAt: networkChangedAt,
            lastEncryptedFallbackSuccessAt: networkChangedAt.addingTimeInterval(45)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: networkChangedAt.addingTimeInterval(50) // DoH success 5s ago — still serving
        )

        XCTAssertEqual(assessment.severity, .usingEncryptedFallback)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }

    /// LAV-80/LAV-87 must NOT regress: a hijacking resolver emits BOTH rejected-response
    /// and transient receive-failed. On a tick whose volatile `lastFailureReason` is
    /// `receive-failed`, the DURABLE resolver-identity-scoped rejected streak (≥3) must
    /// still block encrypted-fallback coverage so the restart fires.
    func testHijackEvidenceOnTransientReasonTickStillReconnectsDespiteServingFallback() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "receive-failed", // volatile transient tick, NOT rejected-response
            consecutiveUpstreamFailureCount: 1,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(3),
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 3,
            consecutiveRejectedSmokeResponseCount: 3, // durable hijack evidence
            rejectedSmokeResponseResolverIdentity: "device:198.51.100.7",
            lastNetworkChangeAt: networkChangedAt,
            lastEncryptedFallbackSuccessAt: networkChangedAt.addingTimeInterval(12)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: networkChangedAt.addingTimeInterval(17)
        )

        XCTAssertEqual(assessment.severity, .needsReconnect)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
    }

    /// LAV-87 gap closure (round 24): the hijack escalation must fire off the DURABLE rejected
    /// streak ALONE. Here the generic smoke streak is churn-reset BELOW threshold (1) and the
    /// latest reason is a transient `receive-failed` — the exact shape a roaming hijacker pins —
    /// while the resolver-identity-scoped rejected streak is durably at threshold (3). The
    /// smoke-streak path can't act (streak < 3) and coverage is declined (counter != 0), so only
    /// the durable rejected escalation prevents a silent wedge. (Pre-fix this downgraded to
    /// `.recovering` because escalation also required `lastFailureReason == "rejected-response"`.)
    func testDurableRejectedStreakReconnectsWhenSmokeStreakChurnResetBelowThreshold() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let probeAt = networkChangedAt.addingTimeInterval(3)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "receive-failed", // volatile transient tick, NOT rejected-response
            consecutiveUpstreamFailureCount: 1,  // churn-reset below threshold
            lastDNSSmokeProbeAt: probeAt,
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 1, // churn-reset below threshold(3)
            consecutiveRejectedSmokeResponseCount: 3, // durable hijack evidence at threshold
            rejectedSmokeResponseResolverIdentity: "device:198.51.100.7",
            lastNetworkChangeAt: networkChangedAt,
            lastEncryptedFallbackSuccessAt: probeAt.addingTimeInterval(2)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: probeAt.addingTimeInterval(4)
        )

        XCTAssertEqual(assessment.severity, .needsReconnect)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
    }

    /// Same gap, reason NILLED by the fallback-carried success that stamped the timestamp: the
    /// durable rejected streak must still escalate. Locks that the re-key does not depend on the
    /// reason being present at all.
    func testDurableRejectedStreakReconnectsWhenReasonNilledByFallback() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let probeAt = networkChangedAt.addingTimeInterval(3)
        let health = TunnelHealthSnapshot(
            lastFailureReason: nil, // fallback-carried success nilled the reason
            consecutiveUpstreamFailureCount: 0,
            lastDNSSmokeProbeAt: probeAt,
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 1, // churn-reset below threshold(3)
            consecutiveRejectedSmokeResponseCount: 3, // durable hijack evidence at threshold
            rejectedSmokeResponseResolverIdentity: "device:198.51.100.7",
            lastNetworkChangeAt: networkChangedAt,
            lastEncryptedFallbackSuccessAt: probeAt.addingTimeInterval(2)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: probeAt.addingTimeInterval(4)
        )

        XCTAssertEqual(assessment.severity, .needsReconnect)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
    }

    /// Over-fire guard for the re-key: with NO rejection evidence (counter 0), a churn-reset
    /// transient that the fallback is actively carrying must STAY covered. The durable-rejected
    /// escalation must not broaden to ordinary transition staleness.
    func testCoveredTransientWithoutRejectionStaysCoveredOnLoweredStreak() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let probeAt = networkChangedAt.addingTimeInterval(3)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "receive-failed",
            consecutiveUpstreamFailureCount: 1,
            lastDNSSmokeProbeAt: probeAt,
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 1,
            consecutiveRejectedSmokeResponseCount: 0, // no hijack evidence
            lastNetworkChangeAt: networkChangedAt,
            lastEncryptedFallbackSuccessAt: probeAt.addingTimeInterval(2)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: probeAt.addingTimeInterval(4)
        )

        XCTAssertEqual(assessment.severity, .usingEncryptedFallback)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }

    /// `rejected-response` is never covered by the encrypted fallback, even on its own tick.
    func testRejectedResponseReasonNeverCoveredByEncryptedFallback() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "rejected-response",
            consecutiveUpstreamFailureCount: 1,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(3),
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 1,
            consecutiveRejectedSmokeResponseCount: 3,
            rejectedSmokeResponseResolverIdentity: "device:198.51.100.7",
            lastNetworkChangeAt: networkChangedAt,
            lastEncryptedFallbackSuccessAt: networkChangedAt.addingTimeInterval(12)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: networkChangedAt.addingTimeInterval(17)
        )

        XCTAssertEqual(assessment.severity, .needsReconnect)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
    }

    /// LAV-96 incident shape: a permanently-unreachable device-DNS primary (`receive-failed`
    /// every probe) while the encrypted DoH fallback is serving, then the carried traffic goes
    /// QUIET. The recapture probe keeps the smoke-failure streak at/above the reconnect threshold,
    /// and the last real fallback success is now long in the past (here 180s, well beyond the old
    /// 60s ceiling) — but no carried query has FAILED (the tunnel did not nil the timestamp). Idle
    /// is not failure, so coverage must HOLD and the futile self-reconnect must be suppressed.
    /// (Pre-fix this escalated to `.needsReconnect` and restarted into the same dead resolver.)
    func testIdleEncryptedFallbackCoverageDoesNotLapseIntoReconnect() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let now = networkChangedAt.addingTimeInterval(220)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "receive-failed",
            consecutiveUpstreamFailureCount: 1,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(210), // synthetic recapture probe, still failing
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 7, // driven up by the 30s recapture loop
            consecutiveRejectedSmokeResponseCount: 0,
            lastNetworkChangeAt: networkChangedAt,
            // The last REAL carried success is 180s old — far past the old 60s ceiling — but the
            // tunnel never nilled it (no carried query failed), so the leg is idle, not dead.
            lastEncryptedFallbackSuccessAt: now.addingTimeInterval(-180)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: now
        )

        XCTAssertEqual(assessment.severity, .usingEncryptedFallback)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }

    /// The fail-closed counterpart of the idle case: when the encrypted leg GENUINELY dies, the
    /// tunnel's sustained carried-query failure streak nils `lastEncryptedFallbackSuccessAt`. A nil
    /// timestamp with a failing primary at/above threshold must still escalate to a real restart —
    /// removing the wall-clock ceiling (LAV-96) must not weaken this. (Mirror of the canonical nil
    /// case in `testNoEncryptedFallbackSignalLeavesReconnectUnchanged`, framed for the dead-leg path.)
    func testDeadEncryptedLegClearedByCarriedFailureStreakStillReconnects() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let now = networkChangedAt.addingTimeInterval(220)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "receive-failed",
            consecutiveUpstreamFailureCount: 3,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(210),
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 7,
            consecutiveRejectedSmokeResponseCount: 0,
            lastNetworkChangeAt: networkChangedAt,
            // Tunnel nilled it: a sustained carried-query failure streak proved DoH/DoT stopped
            // resolving real traffic (consecutiveCarriedQueryFailureCount >= clear threshold).
            lastEncryptedFallbackSuccessAt: nil
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: now
        )

        XCTAssertEqual(assessment.severity, .needsReconnect)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
    }

    /// A covered wedge re-probed on the 30s recapture cadence (so the last carried success ages
    /// between probes) must stay covered, not escalate. Coverage no longer has a wall-clock ceiling
    /// (LAV-96), so a fallback success a cadence-or-two old still reads as covered; what ends
    /// coverage is a primary recovery, a fresh context, or a sustained carried-query failure.
    func testFallbackSuccessOneProbeCadenceOldStillCovered() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let now = networkChangedAt.addingTimeInterval(100)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "receive-failed",
            consecutiveUpstreamFailureCount: 1,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(66),
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 3,
            consecutiveRejectedSmokeResponseCount: 0,
            lastNetworkChangeAt: networkChangedAt,
            // 35s old: one 30s probe cadence + ~5s RTT — the exact age a covered re-probe's
            // failure handler re-assesses at. Must remain covered, not escalate.
            lastEncryptedFallbackSuccessAt: now.addingTimeInterval(-35)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: now
        )

        XCTAssertEqual(assessment.severity, .usingEncryptedFallback)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }

    /// A resolver-IDENTITY change that POSTDATES the network change advances the coverage baseline:
    /// a fallback success from BEFORE the switch (the old resolver context) must NOT cover a smoke
    /// failure in the fresh resolver context, even inside the window — otherwise a reconfigured or
    /// just-disabled fallback keeps suppressing the reconnect. (Codex #86 round 15.)
    func testFallbackSuccessBeforeResolverIdentityChangeDoesNotCoverNewContext() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let resolverChangedAt = networkChangedAt.addingTimeInterval(20) // resolver IDENTITY switch AFTER the handoff
        let now = networkChangedAt.addingTimeInterval(25)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "receive-failed",
            consecutiveUpstreamFailureCount: 1,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(22), // postdates the switch → fresh-context failure
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 3,
            consecutiveRejectedSmokeResponseCount: 0,
            lastNetworkChangeAt: networkChangedAt,
            lastResolverIdentityChangeAt: resolverChangedAt,
            lastEncryptedFallbackSuccessAt: networkChangedAt.addingTimeInterval(12) // BEFORE the switch, still in window
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: now
        )

        // The pre-switch fallback success is stale for the new resolver context → no coverage → reconnect.
        XCTAssertEqual(assessment.severity, .needsReconnect)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
    }

    /// A SAME-resolver runtime reset (snapshot reload / pause-resume) bumps `lastResolverRuntimeResetAt`
    /// but NOT `lastResolverIdentityChangeAt`, so it must NOT advance the smoke-probe baseline: an
    /// existing failed probe on a still-wedged primary must keep surfacing (covered here by a serving
    /// fallback), never read as healthy because a benign reload looked like a fresh context. (Codex #86 round 20.)
    func testSameResolverRuntimeResetDoesNotHideAnExistingSmokeFailure() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let now = networkChangedAt.addingTimeInterval(20)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "receive-failed",
            consecutiveUpstreamFailureCount: 1,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(3), // the wedge's failed probe, pre-reload
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 3,
            consecutiveRejectedSmokeResponseCount: 0,
            lastNetworkChangeAt: networkChangedAt,
            // A snapshot reload at +15s reset the runtime but did NOT change the resolver identity.
            lastResolverRuntimeResetAt: networkChangedAt.addingTimeInterval(15),
            lastEncryptedFallbackSuccessAt: networkChangedAt.addingTimeInterval(16) // DoH still carrying
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: now
        )

        // The reload must NOT advance the baseline past the +3s probe, so the wedge still surfaces
        // (covered, since DoH is serving) rather than reading as healthy.
        XCTAssertEqual(assessment.severity, .usingEncryptedFallback)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }

    /// A cleared (nil) failure reason must NOT mask a reachable-but-rejecting resolver: when the
    /// identity-scoped rejected streak is non-empty but still BELOW the durable hijack threshold
    /// (e.g. a rejection interleaved with timeouts), the cleared reason is no longer admitted as
    /// coverable, so the smoke-failure threshold reconnects instead of being suppressed. (Codex #86 round 15.)
    func testClearedReasonWithRejectionInStreakBelowThresholdStillReconnects() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let now = networkChangedAt.addingTimeInterval(17)
        let health = TunnelHealthSnapshot(
            lastFailureReason: nil, // cleared by a fallback-carried success
            consecutiveUpstreamFailureCount: 1,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(3),
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 3,
            consecutiveRejectedSmokeResponseCount: 2, // a rejection in the streak, but < threshold(3)
            lastNetworkChangeAt: networkChangedAt,
            lastEncryptedFallbackSuccessAt: networkChangedAt.addingTimeInterval(12) // fresh, 5s ago
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: now
        )

        XCTAssertEqual(assessment.severity, .needsReconnect)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
    }

    /// Symmetry with the nil-reason case: a COVERABLE transient reason (receive-failed) must also
    /// NOT mask a pending rejection. When 1-2 rejections sit in the identity-scoped streak and the
    /// transient probe that crosses the smoke-reconnect threshold arrives while the fallback is
    /// fresh, coverage must decline so the reachable-but-rejecting resolver surfaces. (Codex #86 round 19.)
    func testCoverableReasonWithRejectionInStreakBelowThresholdStillReconnects() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let now = networkChangedAt.addingTimeInterval(17)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "receive-failed", // a COVERABLE transient — not rejected-response
            consecutiveUpstreamFailureCount: 1,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(3),
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 3,
            consecutiveRejectedSmokeResponseCount: 2, // pending rejection evidence, < threshold(3)
            lastNetworkChangeAt: networkChangedAt,
            lastEncryptedFallbackSuccessAt: networkChangedAt.addingTimeInterval(12) // fresh, 5s ago
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: now
        )

        XCTAssertEqual(assessment.severity, .needsReconnect)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
    }

    /// With no encrypted-fallback signal at all, behavior is unchanged (still reconnects).
    func testNoEncryptedFallbackSignalLeavesReconnectUnchanged() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "receive-failed",
            consecutiveUpstreamFailureCount: 1,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(3),
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 3,
            consecutiveRejectedSmokeResponseCount: 0,
            lastNetworkChangeAt: networkChangedAt,
            lastEncryptedFallbackSuccessAt: nil
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: networkChangedAt.addingTimeInterval(17)
        )

        XCTAssertEqual(assessment.severity, .needsReconnect)
    }

    /// A real PRIMARY recovery while the fallback was covering ends coverage: the primary
    /// answered after the failed probe, so the state returns to `.healthy`.
    func testPrimaryRecoveryEndsEncryptedFallbackCoverage() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let probeAt = networkChangedAt.addingTimeInterval(3)
        let health = TunnelHealthSnapshot(
            lastFailureReason: nil,
            consecutiveUpstreamFailureCount: 0,
            lastDNSSmokeProbeAt: probeAt,
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 3,
            consecutiveRejectedSmokeResponseCount: 0,
            lastNetworkChangeAt: networkChangedAt,
            lastPrimaryUpstreamSuccessAt: probeAt.addingTimeInterval(5), // primary back
            lastEncryptedFallbackSuccessAt: probeAt.addingTimeInterval(2)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: probeAt.addingTimeInterval(10)
        )

        XCTAssertEqual(assessment.severity, .healthy)
    }

    /// Below the reconnect threshold (a quick handoff), a serving fallback still surfaces
    /// the honest `.usingEncryptedFallback` state rather than the generic `.recovering`.
    func testServingEncryptedFallbackBelowThresholdSurfacesFallbackState() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "receive-failed",
            consecutiveUpstreamFailureCount: 1,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(3),
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 1, // below threshold
            consecutiveRejectedSmokeResponseCount: 0,
            lastNetworkChangeAt: networkChangedAt,
            lastEncryptedFallbackSuccessAt: networkChangedAt.addingTimeInterval(12)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: networkChangedAt.addingTimeInterval(17)
        )

        XCTAssertEqual(assessment.severity, .usingEncryptedFallback)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }

    /// A fallback-carried query clears `lastFailureReason` (recordUpstreamResult nils it on
    /// any didResolve) right after stamping the fallback success. The assessment that runs
    /// immediately after — e.g. its own notification pass — must STILL recognise the fallback
    /// is covering the failed probe and not re-escalate to `.needsReconnect`.
    func testFallbackClearedReasonStillCoveredByServingEncryptedFallback() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let probeAt = networkChangedAt.addingTimeInterval(3)
        let health = TunnelHealthSnapshot(
            lastFailureReason: nil, // a fallback didResolve just nilled it
            consecutiveUpstreamFailureCount: 0, // and reset the upstream streak
            lastDNSSmokeProbeAt: probeAt,
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 3, // would escalate without coverage
            consecutiveRejectedSmokeResponseCount: 0, // not a hijack
            lastNetworkChangeAt: networkChangedAt,
            lastEncryptedFallbackSuccessAt: probeAt.addingTimeInterval(2) // serving now
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: probeAt.addingTimeInterval(4)
        )

        XCTAssertEqual(assessment.severity, .usingEncryptedFallback)
        XCTAssertEqual(assessment.primaryAction, .turnOff)
    }

    /// But a CLEARED reason must not become a hijack escape hatch: with a durable rejected
    /// streak, coverage is still declined even when the fallback query nilled the reason.
    func testFallbackClearedReasonStillBlockedForDurableHijack() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let probeAt = networkChangedAt.addingTimeInterval(3)
        let health = TunnelHealthSnapshot(
            lastFailureReason: nil,
            consecutiveUpstreamFailureCount: 0,
            lastDNSSmokeProbeAt: probeAt,
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 3, // generic streak at threshold here
            consecutiveRejectedSmokeResponseCount: 3, // durable hijack evidence
            rejectedSmokeResponseResolverIdentity: "device:198.51.100.7",
            lastNetworkChangeAt: networkChangedAt,
            lastEncryptedFallbackSuccessAt: probeAt.addingTimeInterval(2)
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: probeAt.addingTimeInterval(4)
        )

        // Coverage is blocked (durable hijack), so the smoke-streak path still escalates.
        XCTAssertEqual(assessment.severity, .needsReconnect)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
    }

    /// A new outage after a primary recovery is reported as `.needsReconnect`, not covered —
    /// because the recovery cleared the stale fallback timestamp. With `lastEncryptedFallbackSuccessAt
    /// == nil` (the post-recovery state) a fresh failed probe escalates normally.
    func testNewOutageAfterRecoveryClearedFallbackTimestampReconnects() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_720_000)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "receive-failed",
            consecutiveUpstreamFailureCount: 1,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(3),
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 3,
            consecutiveRejectedSmokeResponseCount: 0,
            lastNetworkChangeAt: networkChangedAt,
            lastEncryptedFallbackSuccessAt: nil // cleared by the prior recovery
        )

        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: networkChangedAt.addingTimeInterval(5)
        )

        XCTAssertEqual(assessment.severity, .needsReconnect)
        XCTAssertEqual(assessment.primaryAction, .reconnect)
    }

    /// Back-compat: a persisted snapshot written before this field decodes with
    /// `lastEncryptedFallbackSuccessAt == nil`.
    func testHealthSnapshotDecodesWithoutEncryptedFallbackKey() throws {
        let json = """
        {"startedAt":0,"updatedAt":0,"networkKind":"wifi","networkPathIsSatisfied":true}
        """
        let decoded = try JSONDecoder().decode(TunnelHealthSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(decoded.lastEncryptedFallbackSuccessAt)
    }

    /// LAV-92 slice 2: a COVERED wedge (encrypted fallback carrying) whose primary RECAPTURE probe
    /// gets a single `rejected-response` (below the hijack threshold). The rejection gate drops the
    /// *covering* predicate (a rejecting resolver must escalate, not stay covered) AND no marker is
    /// stamped for a covered wedge, so both of the tunnel's recapture re-arm gates went false and
    /// the loop stalled until the 300s routine probe. The broader *carrying* signal stays true, so
    /// the recapture loop keeps re-arming (driving the rejection streak to the escalation threshold,
    /// or recovering, promptly).
    func testRejectedRecaptureKeepsFallbackCarryingSignalSoTheRecaptureLoopReArms() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_900_000)
        let health = TunnelHealthSnapshot(
            lastFailureReason: "rejected-response",
            consecutiveUpstreamFailureCount: 1,
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(3),
            lastDNSSmokeProbeSucceeded: false,
            consecutiveDNSSmokeProbeFailureCount: 1,
            consecutiveRejectedSmokeResponseCount: 1, // a single rejection — below the hijack threshold
            lastNetworkChangeAt: networkChangedAt,
            lastEncryptedFallbackSuccessAt: networkChangedAt.addingTimeInterval(12)
        )
        let now = networkChangedAt.addingTimeInterval(17)

        // The stall premise: below threshold, so no reconnect escalation / no marker.
        let assessment = ProtectionConnectivityPolicy.assessment(isConnected: true, health: health, now: now)
        XCTAssertNotEqual(assessment.primaryAction, .reconnect)

        // The rejection gate drops "covering" (so a rejecting resolver escalates, not stays covered)…
        XCTAssertFalse(ProtectionConnectivityPolicy.isEncryptedFallbackCoveringWedge(health: health, now: now))
        // …but the carrying-a-failed-probe signal (covering minus the rejection gate) stays live, so
        // the recapture loop keeps re-arming.
        XCTAssertTrue(ProtectionConnectivityPolicy.isEncryptedFallbackCarryingWedge(health: health, now: now))
    }

    /// The carrying signal must NOT fire without a failed smoke-probe context: a one-off organic
    /// query that fell back successfully (no failed probe) is not a wedge and must not trip the
    /// recovery loop (Codex #127 P2).
    func testFallbackCarryingWithoutAFailedProbeIsNotTreatedAsAWedge() {
        let networkChangedAt = Date(timeIntervalSinceReferenceDate: 800_950_000)
        let health = TunnelHealthSnapshot(
            lastDNSSmokeProbeAt: networkChangedAt.addingTimeInterval(3),
            lastDNSSmokeProbeSucceeded: true, // last probe SUCCEEDED — no failed-probe context
            consecutiveDNSSmokeProbeFailureCount: 0,
            lastNetworkChangeAt: networkChangedAt,
            lastEncryptedFallbackSuccessAt: networkChangedAt.addingTimeInterval(12) // a query fell back once
        )
        let now = networkChangedAt.addingTimeInterval(17)
        XCTAssertFalse(ProtectionConnectivityPolicy.isEncryptedFallbackCarryingWedge(health: health, now: now))
    }
}
