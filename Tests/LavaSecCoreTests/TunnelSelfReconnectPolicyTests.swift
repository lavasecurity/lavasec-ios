import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

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
                assessment: assessment(.usingEncryptedFallback, .turnOff),
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

    func testAuthoritativeOffOrUnavailableIntentBlocksEveryRecoveryRequirement() {
        // The cached configuration may still be ON while the app is disarming.
        // Only absence preserves that compatibility value; accepted OFF and an
        // unavailable sidecar must block the typed tier grant and legacy wedge alike.
        for outcome in [
            ProtectionRestoreIntentStore.ReadOutcome.stored(isEnabled: false),
            .corrupt, .unreadable
        ] {
            let wanted = outcome.resolvedIntent(fallingBackTo: true)
            XCTAssertFalse(wanted)
            XCTAssertEqual(
                TunnelSelfReconnectPolicy.decision(
                    requirement: .deviceDNSRecapture,
                    protectionEnabled: wanted,
                    onDemandEnabled: true,
                    recentReconnectTimes: [],
                    now: now),
                .noAction
            )
            for reason in [
                TunnelSelfReconnectPolicy.RestartReason.wedge, .deviceDNSRecapture
            ] {
                XCTAssertEqual(
                    TunnelSelfReconnectPolicy.decision(
                        assessment: assessment(.needsReconnect, .reconnect),
                        protectionEnabled: wanted,
                        onDemandEnabled: true,
                        recentReconnectTimes: [],
                        reason: reason,
                        now: now),
                    .noAction
                )
            }
        }
    }

    func testAbsentIntentPreservesLegacyConfigurationWhileStoredOnOverridesIt() {
        for (outcome, configured) in [
            (ProtectionRestoreIntentStore.ReadOutcome.absent, true),
            (.stored(isEnabled: true), false)
        ] {
            let wanted = outcome.resolvedIntent(fallingBackTo: configured)
            XCTAssertTrue(wanted)
            for requirement in [
                TunnelSelfReconnectPolicy.RecoveryRequirement.deviceDNSRecapture,
                .sustainedWedge(assessment(.needsReconnect, .reconnect))
            ] {
                XCTAssertEqual(
                    TunnelSelfReconnectPolicy.decision(
                        requirement: requirement, protectionEnabled: wanted,
                        onDemandEnabled: true, recentReconnectTimes: [], now: now),
                    .reconnect
                )
            }
        }
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

    func testPrunedAttemptTimesKeepsWindowedPastAndClampsFutureToNow() {
        let inWindow = now.addingTimeInterval(-60)
        let outOfWindow = now.addingTimeInterval(-(TunnelSelfReconnectPolicy.attemptWindow + 1))
        let future = now.addingTimeInterval(60)

        let pruned = TunnelSelfReconnectPolicy.prunedAttemptTimes(
            [inWindow, outOfWindow, future],
            now: now
        )

        // The past in-window attempt is kept verbatim; the stale one is dropped; the
        // future-dated one (a backward clock jump) is clamped to `now` and retained
        // so it still counts against the cooldown/cap.
        XCTAssertEqual(pruned, [inWindow, now])
    }

    func testBackwardClockJumpDoesNotBypassCooldown() {
        // Two attempts persisted before the device clock jumped backward now look
        // future-dated. They must still throttle the next self-reconnect rather than
        // vanish and let the restart loop fire immediately.
        let futureAttempts = [
            now.addingTimeInterval(120),
            now.addingTimeInterval(240)
        ]

        let decision = TunnelSelfReconnectPolicy.decision(
            assessment: assessment(.needsReconnect, .reconnect),
            protectionEnabled: true,
            onDemandEnabled: true,
            recentReconnectTimes: futureAttempts,
            now: now
        )

        XCTAssertEqual(decision, .throttled)
    }

    // MARK: - Typed tier recovery admission

    func testDeviceDNSRecaptureGrantDoesNotDependOnAggregateConnectivity() {
        // A healthy tier can rescue a lookup while Device DNS still needs a fresh
        // capture. Its explicit tier-owned grant must survive that aggregate health.
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                assessment: assessment(.usingEncryptedFallback, .turnOff),
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: [],
                reason: .deviceDNSRecapture,
                now: now
            ),
            .noAction
        )
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                requirement: .deviceDNSRecapture,
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: [],
                now: now
            ),
            .reconnect
        )
    }

    func testDeviceDNSRecaptureGrantRequiresProtectionAndConfirmedOnDemand() {
        for (protection, onDemand) in [(false, true), (true, false), (false, false)] {
            XCTAssertEqual(
                TunnelSelfReconnectPolicy.decision(
                    requirement: .deviceDNSRecapture,
                    protectionEnabled: protection,
                    onDemandEnabled: onDemand,
                    recentReconnectTimes: [],
                    now: now
                ),
                .noAction
            )
        }
    }

    func testDeviceDNSRecaptureGrantSharesCooldownAndPersistedAttemptCeiling() {
        let attempts = [
            now.addingTimeInterval(-300),
            now.addingTimeInterval(-200)
        ]
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                requirement: .sustainedWedge(assessment(.needsReconnect, .reconnect)),
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: attempts,
                now: now
            ),
            .throttled
        )
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                requirement: .deviceDNSRecapture,
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: attempts,
                now: now
            ),
            .reconnect
        )
        for history in [
            [now.addingTimeInterval(-89)],
            attempts + [now.addingTimeInterval(-100)]
        ] {
            XCTAssertEqual(
                TunnelSelfReconnectPolicy.decision(
                    requirement: .deviceDNSRecapture,
                    protectionEnabled: true,
                    onDemandEnabled: true,
                    recentReconnectTimes: history,
                    now: now
                ),
                .throttled
            )
        }
    }

    func testDeviceDNSRecaptureGrantHonorsCooldownAndWindowBoundaries() {
        // The cooldown is inclusive at its elapsed boundary; window expiry removes
        // attempts exactly at the boundary so persisted history stays bounded.
        let attempts = [
            now.addingTimeInterval(-600),
            now.addingTimeInterval(-601),
            now.addingTimeInterval(-90)
        ]
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                requirement: .deviceDNSRecapture,
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: attempts,
                now: now
            ),
            .reconnect
        )
    }

    func testDeviceDNSRecaptureGrantCannotEvadeCooldownAfterClockRegression() {
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                requirement: .deviceDNSRecapture,
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: [now.addingTimeInterval(120)],
                now: now
            ),
            .throttled
        )
    }

    func testProductiveRestartCreditDoesNotEraseSharedCooldown() {
        // Productive credit removes the attempt from the cap store, but the
        // committed restart marker must still protect both entry points from loops.
        let committedAt = now.addingTimeInterval(-89)
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                requirement: .deviceDNSRecapture,
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: [],
                lastCommittedReconnectAt: committedAt,
                now: now
            ),
            .throttled
        )
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                assessment: assessment(.needsReconnect, .reconnect),
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: [],
                lastCommittedReconnectAt: committedAt,
                now: now
            ),
            .throttled
        )
    }

    func testProductiveRestartCreditAllowsRecoveryWhenCooldownElapses() {
        for requirement in [
            TunnelSelfReconnectPolicy.RecoveryRequirement.deviceDNSRecapture,
            .sustainedWedge(assessment(.needsReconnect, .reconnect))
        ] {
            XCTAssertEqual(
                TunnelSelfReconnectPolicy.decision(
                    requirement: requirement,
                    protectionEnabled: true,
                    onDemandEnabled: true,
                    recentReconnectTimes: [],
                    lastCommittedReconnectAt: now.addingTimeInterval(-90),
                    now: now
                ),
                .reconnect
            )
        }
    }

    func testCommittedRestartMarkerCannotEvadeCooldownAfterClockRegression() {
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                requirement: .deviceDNSRecapture,
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: [],
                lastCommittedReconnectAt: now.addingTimeInterval(120),
                now: now
            ),
            .throttled
        )
    }

    func testCooldownUsesTheNewestAttemptOrCommittedMarker() {
        for (attempt, marker) in [(-89.0, -300.0), (-300.0, -89.0)] {
            XCTAssertEqual(
                TunnelSelfReconnectPolicy.decision(
                    requirement: .deviceDNSRecapture,
                    protectionEnabled: true,
                    onDemandEnabled: true,
                    recentReconnectTimes: [now.addingTimeInterval(attempt)],
                    lastCommittedReconnectAt: now.addingTimeInterval(marker),
                    now: now
                ),
                .throttled
            )
        }
    }

    func testTypedWedgeStillRequiresSustainedReconnectAssessment() {
        let assessments = [
            assessment(.healthy, .turnOff),
            assessment(.dnsSlow, .reconnect),
            assessment(.usingEncryptedFallback, .turnOff),
            assessment(.usingDeviceDNSFallback, .turnOff),
            assessment(.needsReconnect, .turnOff)
        ]
        for candidate in assessments {
            XCTAssertEqual(
                TunnelSelfReconnectPolicy.decision(
                    requirement: .sustainedWedge(candidate),
                    protectionEnabled: true,
                    onDemandEnabled: true,
                    recentReconnectTimes: [],
                    now: now
                ),
                .noAction
            )
        }
    }

    // MARK: - Legacy device-DNS recapture restart reason

    // Two attempts past the cooldown: the wedge cap (2) is reached, but the recapture
    // cap (3) is not — so the no-fallback recapture restart still fires where the wedge
    // escalation would throttle. This is the +1 headroom that covers one in-flight,
    // not-yet-credited restart during a legitimate network-switch flurry.
    func testRecaptureReasonHasHigherCeilingThanWedge() {
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
                reason: .wedge,
                now: now
            ),
            .throttled
        )
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                assessment: assessment(.needsReconnect, .reconnect),
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: attempts,
                reason: .deviceDNSRecapture,
                now: now
            ),
            .reconnect
        )
    }

    func testRecaptureReasonThrottlesAtItsOwnCeiling() {
        // Three attempts past the cooldown — the recapture cap (3) is reached, so a
        // genuinely-dead resolver is bounded (no unbounded restart loop).
        let attempts = [
            now.addingTimeInterval(-(TunnelSelfReconnectPolicy.cooldown + 300)),
            now.addingTimeInterval(-(TunnelSelfReconnectPolicy.cooldown + 200)),
            now.addingTimeInterval(-(TunnelSelfReconnectPolicy.cooldown + 100))
        ]
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                assessment: assessment(.needsReconnect, .reconnect),
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: attempts,
                reason: .deviceDNSRecapture,
                now: now
            ),
            .throttled
        )
    }

    func testRecaptureReasonStillRespectsCooldown() {
        let lastAttempt = now.addingTimeInterval(-(TunnelSelfReconnectPolicy.cooldown - 1))
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                assessment: assessment(.needsReconnect, .reconnect),
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: [lastAttempt],
                reason: .deviceDNSRecapture,
                now: now
            ),
            .throttled
        )
    }

    func testRecaptureReasonStillRequiresProtectionAndOnDemand() {
        for (proto, onDemand) in [(false, true), (true, false)] {
            XCTAssertEqual(
                TunnelSelfReconnectPolicy.decision(
                    assessment: assessment(.needsReconnect, .reconnect),
                    protectionEnabled: proto,
                    onDemandEnabled: onDemand,
                    recentReconnectTimes: [],
                    reason: .deviceDNSRecapture,
                    now: now
                ),
                .noAction
            )
        }
    }

    func testRecaptureReasonStillRequiresNeedsReconnectSeverity() {
        // A stale resolver that still WORKS (capture merely masked, queries succeeding)
        // never reaches .needsReconnect, so the recapture restart must not fire for it.
        for severity in [ProtectionConnectivitySeverity.dnsSlow, .usingEncryptedFallback, .healthy] {
            XCTAssertEqual(
                TunnelSelfReconnectPolicy.decision(
                    assessment: assessment(severity, .reconnect),
                    protectionEnabled: true,
                    onDemandEnabled: true,
                    recentReconnectTimes: [],
                    reason: .deviceDNSRecapture,
                    now: now
                ),
                .noAction
            )
        }
    }

    func testWedgeAndRecaptureShareOneAttemptBudget() {
        // The two reasons draw from ONE persisted attempt store (a self-reconnect is one
        // scarce process restart regardless of trigger). Two wedge attempts already on
        // record => a recapture decision sees count=2 < 3 => .reconnect; a third attempt
        // of EITHER reason then throttles.
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
                reason: .deviceDNSRecapture,
                now: now
            ),
            .reconnect
        )
        let threeAttempts = attempts + [now.addingTimeInterval(-(TunnelSelfReconnectPolicy.cooldown + 50))]
        XCTAssertEqual(
            TunnelSelfReconnectPolicy.decision(
                assessment: assessment(.needsReconnect, .reconnect),
                protectionEnabled: true,
                onDemandEnabled: true,
                recentReconnectTimes: threeAttempts,
                reason: .deviceDNSRecapture,
                now: now
            ),
            .throttled
        )
    }
}
