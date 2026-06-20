import XCTest
@testable import LavaSecCore

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

    func testCaptureRetryWindowIsBoundedAndShorterThanRoutineProbe() {
        XCTAssertGreaterThan(DeviceDNSFallbackPolicy.deviceDNSCaptureMaxRetryAttempts, 0)
        XCTAssertGreaterThan(DeviceDNSFallbackPolicy.deviceDNSCaptureRetryInterval, 0)
        // The whole retry window must resolve well inside the 300s routine cadence
        // so a masked handoff recovers promptly, not on the next routine probe.
        let totalWindow = DeviceDNSFallbackPolicy.deviceDNSCaptureRetryInterval
            * Double(DeviceDNSFallbackPolicy.deviceDNSCaptureMaxRetryAttempts)
        XCTAssertLessThan(totalWindow, DeviceDNSFallbackPolicy.routineSmokeProbeInterval)
    }
}
