import XCTest
@testable import LavaSecCore

final class TunnelSelfReconnectPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100_000)

    private func assessment(
        _ severity: ProtectionConnectivitySeverity,
        _ action: ProtectionConnectivityAction
    ) -> ProtectionConnectivityAssessment {
        ProtectionConnectivityAssessment(severity: severity, primaryAction: action)
    }

    func testReconnectsOnSustainedNeedsReconnectWhenProtectionEnabled() {
        let decision = TunnelSelfReconnectPolicy.decision(
            assessment: assessment(.needsReconnect, .reconnect),
            protectionEnabled: true,
            onDemandEnabled: true,
            recentReconnectTimes: [],
            now: now
        )
        XCTAssertEqual(decision, .reconnect)
    }

    func testNoActionWhenNotNeedsReconnect() {
        // dnsSlow also recommends .reconnect, but DNS is still working — a restart
        // would be disruptive, so we must not self-restart for it.
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                assessment: assessment(.dnsSlow, .reconnect),
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: [],
                now: now
            ),
            .noAction
        )
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                assessment: assessment(.usingDeviceDNSFallback, .turnOff),
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: [],
                now: now
            ),
            .noAction
        )
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                assessment: assessment(.healthy, .turnOff),
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: [],
                now: now
            ),
            .noAction
        )
    }

    func testNoActionWhenProtectionDisabled() {
        // With protection off the user isn't asking to be protected, so never
        // self-restart.
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                assessment: assessment(.needsReconnect, .reconnect),
                protectionEnabled: false,
                onDemandEnabled: true,
                recentReconnectTimes: [],
                now: now
            ),
            .noAction
        )
    }

    func testNoActionWhenOnDemandNotArmed() {
        // protectionEnabled can be persisted even when arming Connect-On-Demand
        // failed; without confirmed on-demand a self-cancel would strand the user
        // offline with no automatic recovery, so never restart.
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                assessment: assessment(.needsReconnect, .reconnect),
                protectionEnabled: true,
                onDemandEnabled: false,
                recentReconnectTimes: [],
                now: now
            ),
            .noAction
        )
    }

    func testThrottledWithinCooldown() {
        let lastAttempt = now.addingTimeInterval(-(TunnelSelfReconnectPolicy.cooldown - 1))
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                assessment: assessment(.needsReconnect, .reconnect),
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: [lastAttempt],
                now: now
            ),
            .throttled
        )
    }

    func testReconnectsAgainOnceCooldownElapses() {
        let lastAttempt = now.addingTimeInterval(-(TunnelSelfReconnectPolicy.cooldown + 1))
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                assessment: assessment(.needsReconnect, .reconnect),
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: [lastAttempt],
                now: now
            ),
            .reconnect
        )
    }

    func testThrottledOncePerWindowCapReached() {
        // Two attempts inside the window, both past the cooldown — the cap (2) is
        // reached, so further restarts are suppressed (notify only) to avoid loops.
        let attempts = [
            now.addingTimeInterval(-(TunnelSelfReconnectPolicy.cooldown + 200)),
            now.addingTimeInterval(-(TunnelSelfReconnectPolicy.cooldown + 100))
        ]
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                assessment: assessment(.needsReconnect, .reconnect),
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: attempts,
                now: now
            ),
            .throttled
        )
    }

    func testAttemptsOutsideWindowDoNotCountTowardCap() {
        // Both attempts are older than the window, so they're ignored and a fresh
        // restart is allowed.
        let attempts = [
            now.addingTimeInterval(-(TunnelSelfReconnectPolicy.attemptWindow + 100)),
            now.addingTimeInterval(-(TunnelSelfReconnectPolicy.attemptWindow + 50))
        ]
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                assessment: assessment(.needsReconnect, .reconnect),
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: attempts,
                now: now
            ),
            .reconnect
        )
    }

    func testPrunedAttemptTimesKeepsOnlyWindowedPastTimestamps() {
        let inWindow = now.addingTimeInterval(-60)
        let outOfWindow = now.addingTimeInterval(-(TunnelSelfReconnectPolicy.attemptWindow + 1))
        let future = now.addingTimeInterval(60)

        let pruned = TunnelSelfReconnectPolicy.prunedAttemptTimes(
            [inWindow, outOfWindow, future],
            now: now
        )

        XCTAssertEqual(pruned, [inWindow])
    }
}
