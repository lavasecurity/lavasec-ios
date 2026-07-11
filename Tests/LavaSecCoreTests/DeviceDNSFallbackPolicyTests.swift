import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class DeviceDNSFallbackPolicyTests: XCTestCase {
    func testStickyFallbackRequiresMultipleConsecutiveQueryFallbackSuccesses() {
        XCTAssertFalse(
            DeviceDNSFallbackPolicy.shouldActivateFallbackMode(consecutiveQueryFallbackSuccesses: 1)
        )
        XCTAssertFalse(
            DeviceDNSFallbackPolicy.shouldActivateFallbackMode(consecutiveQueryFallbackSuccesses: 2)
        )
        XCTAssertTrue(
            DeviceDNSFallbackPolicy.shouldActivateFallbackMode(consecutiveQueryFallbackSuccesses: 3)
        )
    }

    func testFallbackEvidenceOnlyAdvancesForActualPrimaryAttempts() {
        let firstFailure = DeviceDNSFallbackPolicy.nextConsecutiveFallbackEvidenceCount(
            currentCount: 0,
            primaryResolverWasAttempted: true
        )
        let backedOffFailure = DeviceDNSFallbackPolicy.nextConsecutiveFallbackEvidenceCount(
            currentCount: firstFailure,
            primaryResolverWasAttempted: false
        )

        XCTAssertEqual(firstFailure, 1)
        XCTAssertEqual(backedOffFailure, 1)
        XCTAssertFalse(
            DeviceDNSFallbackPolicy.shouldActivateFallbackMode(
                consecutiveQueryFallbackSuccesses: backedOffFailure
            )
        )
    }

    func testSmokeProbeFallbackDoesNotActivateStickyModeOnFirstFailure() {
        let count = DeviceDNSFallbackPolicy.nextConsecutiveFallbackEvidenceCount(
            currentCount: 0,
            primaryResolverWasAttempted: true
        )

        XCTAssertEqual(count, 1)
        XCTAssertFalse(
            DeviceDNSFallbackPolicy.shouldActivateFallbackMode(
                consecutiveQueryFallbackSuccesses: count
            )
        )
    }

    func testFallbackFollowUpProbeRunsForCandidateOrActiveFallback() {
        XCTAssertFalse(
            DeviceDNSFallbackPolicy.shouldScheduleFallbackFollowUpProbe(
                deviceDNSFallbackModeActive: false,
                consecutiveFallbackEvidenceCount: 0
            )
        )
        XCTAssertTrue(
            DeviceDNSFallbackPolicy.shouldScheduleFallbackFollowUpProbe(
                deviceDNSFallbackModeActive: false,
                consecutiveFallbackEvidenceCount: 1
            )
        )
        XCTAssertTrue(
            DeviceDNSFallbackPolicy.shouldScheduleFallbackFollowUpProbe(
                deviceDNSFallbackModeActive: true,
                consecutiveFallbackEvidenceCount: 0
            )
        )
    }

    func testFallbackRecoveryProbeRunsMoreFrequentlyThanRoutineProbe() {
        XCTAssertLessThan(
            DeviceDNSFallbackPolicy.fallbackRecoverySmokeProbeInterval,
            DeviceDNSFallbackPolicy.routineSmokeProbeInterval
        )
    }

    func testDeviceDNSRefreshPreservesLastUsableResolversWhenCaptureIsEmpty() {
        XCTAssertEqual(
            DeviceDNSFallbackPolicy.refreshedResolverAddresses(
                current: ["192.168.1.1", "2001:4860:4860::8888"],
                captured: [],
                preserveOnEmptyCapture: true
            ),
            ["192.168.1.1", "2001:4860:4860::8888"]
        )
    }

    func testDeviceDNSRefreshClearsEmptyCaptureAcrossNetworkChange() {
        XCTAssertEqual(
            DeviceDNSFallbackPolicy.refreshedResolverAddresses(
                current: ["192.168.1.1"],
                captured: [],
                preserveOnEmptyCapture: false
            ),
            []
        )
    }

    func testDeviceDNSRefreshUsesFreshNonEmptyCapture() {
        XCTAssertEqual(
            DeviceDNSFallbackPolicy.refreshedResolverAddresses(
                current: ["192.168.1.1"],
                captured: ["10.0.0.1"],
                preserveOnEmptyCapture: false
            ),
            ["10.0.0.1"]
        )
    }

    func testCaptureRetryContinuesWhileMaskedUnderAttemptCap() {
        XCTAssertTrue(
            DeviceDNSFallbackPolicy.shouldRetryDeviceDNSCapture(
                attemptsMade: 1,
                capturedNonEmpty: false
            )
        )
        XCTAssertTrue(
            DeviceDNSFallbackPolicy.shouldRetryDeviceDNSCapture(
                attemptsMade: DeviceDNSFallbackPolicy.deviceDNSCaptureMaxRetryAttempts - 1,
                capturedNonEmpty: false
            )
        )
    }

    func testCaptureRetryStopsAtAttemptCap() {
        XCTAssertFalse(
            DeviceDNSFallbackPolicy.shouldRetryDeviceDNSCapture(
                attemptsMade: DeviceDNSFallbackPolicy.deviceDNSCaptureMaxRetryAttempts,
                capturedNonEmpty: false
            )
        )
        XCTAssertFalse(
            DeviceDNSFallbackPolicy.shouldRetryDeviceDNSCapture(
                attemptsMade: DeviceDNSFallbackPolicy.deviceDNSCaptureMaxRetryAttempts + 1,
                capturedNonEmpty: false
            )
        )
    }

    func testCaptureRetryStopsImmediatelyOnceCaptureSucceeds() {
        // A non-empty capture means the mask lifted — adopt it and stop, even with
        // attempts still left in the window.
        XCTAssertFalse(
            DeviceDNSFallbackPolicy.shouldRetryDeviceDNSCapture(
                attemptsMade: 1,
                capturedNonEmpty: true
            )
        )
    }

    func testWakeRestartAllowedWithNoPriorMaskedExhaustion() {
        // nil stamp = no cycle has exhausted while masked since the last real
        // change signal — a wake may always start the retry cycle.
        XCTAssertTrue(
            DeviceDNSFallbackPolicy.shouldRestartCaptureRetryCycleAfterWake(
                lastExhaustedMaskedCaptureAt: nil,
                now: Date(timeIntervalSince1970: 1_000)
            )
        )
    }

    func testWakeRestartSuppressedInsideExhaustionCooldown() {
        // The UR-48 follow-up log's failure shape: wakes every ~5 s each restarting
        // the full masked retry cycle. Inside the cooldown of an exhausted-still-
        // masked cycle the wake restart must be suppressed.
        let exhaustedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(
            DeviceDNSFallbackPolicy.shouldRestartCaptureRetryCycleAfterWake(
                lastExhaustedMaskedCaptureAt: exhaustedAt,
                now: exhaustedAt.addingTimeInterval(5)
            )
        )
        XCTAssertFalse(
            DeviceDNSFallbackPolicy.shouldRestartCaptureRetryCycleAfterWake(
                lastExhaustedMaskedCaptureAt: exhaustedAt,
                now: exhaustedAt.addingTimeInterval(
                    DeviceDNSFallbackPolicy.deviceDNSCaptureRetryExhaustionCooldown - 1
                )
            )
        )
    }

    func testWakeRestartResumesOnceCooldownElapses() {
        let exhaustedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(
            DeviceDNSFallbackPolicy.shouldRestartCaptureRetryCycleAfterWake(
                lastExhaustedMaskedCaptureAt: exhaustedAt,
                now: exhaustedAt.addingTimeInterval(
                    DeviceDNSFallbackPolicy.deviceDNSCaptureRetryExhaustionCooldown
                )
            )
        )
    }

    func testWakeRestartFailsOpenOnBackwardsClockJump() {
        // A stamp in the future (clock set backwards) must not suppress retries
        // indefinitely — fail open to retrying.
        let exhaustedAt = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(
            DeviceDNSFallbackPolicy.shouldRestartCaptureRetryCycleAfterWake(
                lastExhaustedMaskedCaptureAt: exhaustedAt,
                now: exhaustedAt.addingTimeInterval(-30)
            )
        )
    }

    func testWakeRestartCooldownOutlastsRetryCycleButNotRoutineProbe() {
        // The cooldown must be longer than one full retry cycle (else it never
        // actually suppresses a repeat) and shorter than the 300 s routine probe
        // cadence so a genuinely-recoverable mask is still retried well before the
        // routine backstop.
        let cycleWindow = DeviceDNSFallbackPolicy.deviceDNSCaptureRetryInterval
            * Double(DeviceDNSFallbackPolicy.deviceDNSCaptureMaxRetryAttempts)
        XCTAssertGreaterThan(
            DeviceDNSFallbackPolicy.deviceDNSCaptureRetryExhaustionCooldown,
            cycleWindow
        )
        XCTAssertLessThan(
            DeviceDNSFallbackPolicy.deviceDNSCaptureRetryExhaustionCooldown,
            DeviceDNSFallbackPolicy.routineSmokeProbeInterval
        )
    }

    func testCaptureRetryWindowIsBoundedAndShorterThanRoutineProbe() {
        XCTAssertGreaterThan(DeviceDNSFallbackPolicy.deviceDNSCaptureMaxRetryAttempts, 0)
        XCTAssertGreaterThan(DeviceDNSFallbackPolicy.deviceDNSCaptureRetryInterval, 0)
        // The whole retry window must resolve well inside the 300s routine cadence
        // so a masked handoff recovers promptly, not on the next routine probe.
        let totalWindow = DeviceDNSFallbackPolicy.deviceDNSCaptureRetryInterval
            * Double(DeviceDNSFallbackPolicy.deviceDNSCaptureMaxRetryAttempts)
        XCTAssertLessThan(totalWindow, DeviceDNSFallbackPolicy.routineSmokeProbeInterval)
    }

    func testUsableResolverAddressAcceptsRealResolvers() {
        // Ordinary public/private resolvers a real network hands out, plus addresses
        // adjacent to (but outside) the rejected blocks.
        for address in [
            "1.1.1.1", "8.8.8.8", "9.9.9.9",
            "192.168.11.2", "10.0.0.1", "172.16.0.1",
            "169.253.0.1", "169.255.0.1", // adjacent to 169.254/16, must stay usable
            "2001:4860:4860::8888", "240a:40:0:1008::9", "fd00::1", "2606:4700:4700::1111"
        ] {
            XCTAssertTrue(
                DeviceDNSFallbackPolicy.isUsableResolverAddress(address),
                "\(address) should be accepted as a usable resolver"
            )
        }
    }

    func testUsableResolverAddressRejectsReservedAndUnroutableRanges() {
        for address in [
            // unspecified / "this network"
            "0.0.0.0", "0.1.2.3", "::",
            // loopback
            "127.0.0.1", "127.1.2.3", "::1",
            // IPv4 link-local 169.254/16
            "169.254.0.1", "169.254.255.255",
            // IPv6 link-local fe80::/10 (covers fe80–febf)
            "fe80::1", "fe80::abcd:1234", "febf::1",
            // NAT64 64:ff9b::/96 wrapping a RESERVED IPv4 (still cannot answer) — rejected by
            // the embedded-IPv4 check: unspecified 0.0.0.0, loopback 127/8, link-local 169.254/16.
            "64:ff9b::", "64:ff9b::127.0.0.1", "64:ff9b::169.254.1.1",
            // garbage / non-addresses
            "not-an-ip", "", "999.999.999.999"
        ] {
            XCTAssertFalse(
                DeviceDNSFallbackPolicy.isUsableResolverAddress(address),
                "\(address) should be rejected as unusable"
            )
        }
    }

    func testUsableResolverAddressKeepsAddressesJustOutsideTheRejectedBlocks() {
        // fc00::/7 ULA and fec0:: are NOT in fe80::/10 — must remain usable.
        XCTAssertTrue(DeviceDNSFallbackPolicy.isUsableResolverAddress("fec0::1"))
        XCTAssertTrue(DeviceDNSFallbackPolicy.isUsableResolverAddress("fc00::1"))
        // 64:ff9b:1:: is outside the /96 well-known NAT64 prefix — keep it.
        XCTAssertTrue(DeviceDNSFallbackPolicy.isUsableResolverAddress("64:ff9b:1::1"))
        // 64:ff9b::/96 wrapping a routable PUBLIC IPv4 is a real NAT64-reached resolver on an
        // IPv6-only path (CLAT translates) — keep it (Codex P2).
        XCTAssertTrue(DeviceDNSFallbackPolicy.isUsableResolverAddress("64:ff9b::8.8.8.8"))
        XCTAssertTrue(DeviceDNSFallbackPolicy.isUsableResolverAddress("64:ff9b::1.2.3.4"))
        // Both dotted-quad and hextet spellings of the embedded v4 are accepted.
        XCTAssertTrue(DeviceDNSFallbackPolicy.isUsableResolverAddress("64:ff9b::808:808"))
    }

    // MARK: - Brief-wake resolver preservation (UR-48 Phase 2a)

    func testPreserveResolverRuntimeRequiresAnObservedSleepStart() {
        // No paired sleep() observed (fresh process, or an OS wake with no sleep callback) —
        // the suspension length is unknown, so the conservative teardown must run.
        XCTAssertFalse(DeviceDNSFallbackPolicy.shouldPreserveResolverRuntimeAcrossWake(
            sleepBeganAt: nil,
            now: Date(timeIntervalSinceReferenceDate: 1_000)
        ))
    }

    func testPreserveResolverRuntimeAcrossBriefSleepOnly() {
        let sleepBeganAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let threshold = DeviceDNSFallbackPolicy.briefWakeResolverPreserveThreshold

        // Micro-sleep (the UR-48 thrash shape): keep the live sessions.
        XCTAssertTrue(DeviceDNSFallbackPolicy.shouldPreserveResolverRuntimeAcrossWake(
            sleepBeganAt: sleepBeganAt,
            now: sleepBeganAt.addingTimeInterval(5)
        ))
        // Exactly at the threshold still preserves (inclusive bound).
        XCTAssertTrue(DeviceDNSFallbackPolicy.shouldPreserveResolverRuntimeAcrossWake(
            sleepBeganAt: sleepBeganAt,
            now: sleepBeganAt.addingTimeInterval(threshold)
        ))
        // Past the threshold the stale-socket/DHCP-rebind risk wins: tear down.
        XCTAssertFalse(DeviceDNSFallbackPolicy.shouldPreserveResolverRuntimeAcrossWake(
            sleepBeganAt: sleepBeganAt,
            now: sleepBeganAt.addingTimeInterval(threshold + 1)
        ))
    }

    func testPreserveResolverRuntimeRejectsClockJumpBackwards() {
        // A sleep stamp in the future (clock set backwards while suspended) is bogus —
        // fail toward the conservative teardown, never toward trusting stale sessions.
        let sleepBeganAt = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertFalse(DeviceDNSFallbackPolicy.shouldPreserveResolverRuntimeAcrossWake(
            sleepBeganAt: sleepBeganAt,
            now: sleepBeganAt.addingTimeInterval(-1)
        ))
    }

    // MARK: - Chronic-failure smoke-probe backoff (UR-48 Phase 2a)

    func testRoutineProbeIntervalKeepsBaseCadenceBelowActivation() {
        // Transient blips (streaks under the activation count) keep today's cadence exactly.
        let base = DeviceDNSFallbackPolicy.routineSmokeProbeInterval
        for failures in 0..<DeviceDNSFallbackPolicy.smokeProbeBackoffActivationFailureCount {
            XCTAssertEqual(
                DeviceDNSFallbackPolicy.routineSmokeProbeInterval(afterConsecutiveFailures: failures),
                base,
                "streak of \(failures) must not back off"
            )
        }
    }

    func testRoutineProbeIntervalDoublesFromActivationAndHitsTheCeiling() {
        let activation = DeviceDNSFallbackPolicy.smokeProbeBackoffActivationFailureCount
        let base = DeviceDNSFallbackPolicy.routineSmokeProbeInterval
        let ceiling = DeviceDNSFallbackPolicy.maxRoutineSmokeProbeInterval

        XCTAssertEqual(
            DeviceDNSFallbackPolicy.routineSmokeProbeInterval(afterConsecutiveFailures: activation),
            min(base * 2, ceiling)
        )
        // Chronic streak (the rc9 log's 500+): pinned to the ceiling, never beyond.
        XCTAssertEqual(
            DeviceDNSFallbackPolicy.routineSmokeProbeInterval(afterConsecutiveFailures: 500),
            ceiling
        )
        // Ceiling stays modest so a silent recovery is noticed within minutes, not hours.
        XCTAssertLessThanOrEqual(ceiling, 1_800)
    }

    func testConsecutiveSmokeFailureStreakSaturates() {
        XCTAssertEqual(DeviceDNSFallbackPolicy.nextConsecutiveSmokeProbeFailureCount(current: 0), 1)
        let cap = DeviceDNSFallbackPolicy.maxTrackedConsecutiveSmokeProbeFailures
        XCTAssertEqual(DeviceDNSFallbackPolicy.nextConsecutiveSmokeProbeFailureCount(current: cap - 1), cap)
        // Saturates instead of growing without bound (rc9 log: 500+ with no consumer).
        XCTAssertEqual(DeviceDNSFallbackPolicy.nextConsecutiveSmokeProbeFailureCount(current: cap), cap)
        // Every behavioral threshold sits far below the saturation point.
        XCTAssertLessThan(DeviceDNSFallbackPolicy.smokeProbeBackoffActivationFailureCount, cap)
        XCTAssertLessThan(DeviceDNSFallbackPolicy.queryFallbackActivationThreshold, cap)
    }

    func testDeviceDNSCaptureLoggingCollapsesMaskedEpisodes() {
        // First read of a masked episode logs; SAME-reason repeats within it do not.
        XCTAssertTrue(DeviceDNSFallbackPolicy.shouldLogDeviceDNSCapture(
            capturedCount: 0, reason: "wake", lastLoggedCount: nil, lastLoggedReason: nil))
        XCTAssertFalse(DeviceDNSFallbackPolicy.shouldLogDeviceDNSCapture(
            capturedCount: 0, reason: "wake", lastLoggedCount: 0, lastLoggedReason: "wake"))
        // Any non-empty capture always logs (it can change the adopted resolvers)...
        XCTAssertTrue(DeviceDNSFallbackPolicy.shouldLogDeviceDNSCapture(
            capturedCount: 2, reason: "wake", lastLoggedCount: 2, lastLoggedReason: "wake"))
        XCTAssertTrue(DeviceDNSFallbackPolicy.shouldLogDeviceDNSCapture(
            capturedCount: 1, reason: "wake", lastLoggedCount: 0, lastLoggedReason: "wake"))
        // ...and the next masked read after a recovery logs the new episode's start.
        XCTAssertTrue(DeviceDNSFallbackPolicy.shouldLogDeviceDNSCapture(
            capturedCount: 0, reason: "wake", lastLoggedCount: 2, lastLoggedReason: "wake"))
        // A masked→masked handoff under a NEW reason logs — it's a distinct recapture the
        // diagnostic log exists to surface, not a same-reason repeat within one episode.
        XCTAssertTrue(DeviceDNSFallbackPolicy.shouldLogDeviceDNSCapture(
            capturedCount: 0, reason: "network-path-changed", lastLoggedCount: 0, lastLoggedReason: "wake"))
        // But once that new context has logged, its own same-reason repeats collapse again.
        XCTAssertFalse(DeviceDNSFallbackPolicy.shouldLogDeviceDNSCapture(
            capturedCount: 0, reason: "network-path-changed", lastLoggedCount: 0, lastLoggedReason: "network-path-changed"))
    }

    func testRoutineProbeIntervalIsMonotonicInFailureStreak() {
        // More failures may never SHORTEN the cadence — the streak resets (on success,
        // recovery, or a path change) are what restore the base interval.
        var previous: TimeInterval = 0
        for failures in 0...600 {
            let interval = DeviceDNSFallbackPolicy.routineSmokeProbeInterval(afterConsecutiveFailures: failures)
            XCTAssertGreaterThanOrEqual(interval, previous, "interval shrank at streak \(failures)")
            previous = interval
        }
    }
}
