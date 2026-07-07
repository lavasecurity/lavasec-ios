import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class RageShakeQATests: XCTestCase {
    func testNormalUserRageShakeRoutesToBugReport() {
        XCTAssertEqual(RageShakeRouter.destination(for: .normalUser), .bugReport)
    }

    func testAdminRageShakeRoutesToPhoneQA() {
        XCTAssertEqual(RageShakeRouter.destination(for: .admin), .phoneQA)
    }

    func testLegacyQAToolsRouteMatchesExplicitModes() {
        XCTAssertEqual(RageShakeRouter.destination(allowsAdminQA: true), .phoneQA)
        XCTAssertEqual(RageShakeRouter.destination(allowsAdminQA: false), .bugReport)
    }

    func testBugReportRequiresFeedbackConfirmation() {
        XCTAssertTrue(RageShakeRouter.requiresFeedbackConfirmation(for: .bugReport))
    }

    func testPhoneQADoesNotRequireFeedbackConfirmation() {
        XCTAssertFalse(RageShakeRouter.requiresFeedbackConfirmation(for: .phoneQA))
    }

    func testSingleShakeDoesNotTriggerRageShake() {
        var tracker = RageShakeIntentTracker(requiredShakes: 2, window: 1.5)
        XCTAssertFalse(tracker.registerShake(at: 0))
    }

    func testTwoShakesWithinWindowTriggerOnceThenReset() {
        var tracker = RageShakeIntentTracker(requiredShakes: 2, window: 1.5)
        XCTAssertFalse(tracker.registerShake(at: 0))
        XCTAssertTrue(tracker.registerShake(at: 1.0))
        // Resets after firing, so a lone follow-up shake must not re-trigger.
        XCTAssertFalse(tracker.registerShake(at: 1.2))
    }

    func testShakesOutsideWindowDoNotTrigger() {
        var tracker = RageShakeIntentTracker(requiredShakes: 2, window: 1.5)
        XCTAssertFalse(tracker.registerShake(at: 0))
        // The first shake is evicted before the second one is counted.
        XCTAssertFalse(tracker.registerShake(at: 2.0))
    }

    func testRequiringSingleShakeTriggersImmediately() {
        var tracker = RageShakeIntentTracker(requiredShakes: 1, window: 1.5)
        XCTAssertTrue(tracker.registerShake(at: 0))
    }

    func testDefaultTrackerTriggersOnASingleShake() {
        // UIKit reports `.motionShake` once per gesture, so the default fires on
        // the first shake and relies on the confirmation dialog as the guard.
        var tracker = RageShakeIntentTracker()
        XCTAssertEqual(tracker.requiredShakes, 1)
        XCTAssertTrue(tracker.registerShake(at: 0))
    }

    func testShakeExactlyAtWindowBoundaryStillCounts() {
        // Eviction uses `time - t > window`, so a shake exactly `window` apart
        // is kept (the boundary is inclusive).
        var tracker = RageShakeIntentTracker(requiredShakes: 2, window: 1.5)
        XCTAssertFalse(tracker.registerShake(at: 0))
        XCTAssertTrue(tracker.registerShake(at: 1.5))
    }

    func testRequiredShakesIsClampedToAtLeastOne() {
        var tracker = RageShakeIntentTracker(requiredShakes: 0, window: 1.5)
        XCTAssertEqual(tracker.requiredShakes, 1)
        XCTAssertTrue(tracker.registerShake(at: 0))
    }

    func testTrackerReArmsForASecondGesture() {
        var tracker = RageShakeIntentTracker(requiredShakes: 2, window: 1.5)
        XCTAssertFalse(tracker.registerShake(at: 0))
        XCTAssertTrue(tracker.registerShake(at: 0.5))   // fires, then resets
        XCTAssertFalse(tracker.registerShake(at: 0.7))  // first of next gesture
        XCTAssertTrue(tracker.registerShake(at: 1.0))   // second -> fires again
    }

    func testStaleShakeIsEvictedThenAFreshPairTriggers() {
        var tracker = RageShakeIntentTracker(requiredShakes: 2, window: 1.5)
        XCTAssertFalse(tracker.registerShake(at: 0))    // stale
        XCTAssertFalse(tracker.registerShake(at: 2.0))  // evicts 0, count back to 1
        XCTAssertTrue(tracker.registerShake(at: 2.5))   // pairs with 2.0 -> fires
    }

    func testRageShakeActivationDoesNotStealFocusFromTextInput() {
        XCTAssertFalse(
            RageShakeActivationPolicy.shouldActivate(
                isViewInWindow: true,
                isDetectorFirstResponder: false,
                isTextInputActive: true
            )
        )
    }

    func testRageShakeActivationRequiresVisibleIdleDetector() {
        XCTAssertTrue(
            RageShakeActivationPolicy.shouldActivate(
                isViewInWindow: true,
                isDetectorFirstResponder: false,
                isTextInputActive: false
            )
        )
        XCTAssertFalse(
            RageShakeActivationPolicy.shouldActivate(
                isViewInWindow: false,
                isDetectorFirstResponder: false,
                isTextInputActive: false
            )
        )
        XCTAssertFalse(
            RageShakeActivationPolicy.shouldActivate(
                isViewInWindow: true,
                isDetectorFirstResponder: true,
                isTextInputActive: false
            )
        )
    }

    func testPhoneQAActionsStayDetailedAtomicAndOrdered() {
        XCTAssertEqual(AdminQAAction.allCases, [
            .showWelcome,
            .showUserBugReport,
            .applyHostedProbes,
            .testDefaultAllow,
            .testAllowlist,
            .testDenylist,
            .testThreatGuardrail,
            .setGoogleDNS,
            .setCloudflareDoH,
            .setCloudflareDoT,
            .enableLocalDomainHistory,
            .disableLocalDomainHistory,
            .clearLocalActivity,
            .setPaidPlan,
            .setFreePlan,
            .clearQAState
        ])

        XCTAssertEqual(AdminQAAction.showWelcome.title, "Welcome Screen")
        XCTAssertEqual(AdminQAAction.showUserBugReport.title, "Normal User Feedback")
        XCTAssertEqual(AdminQAAction.testDefaultAllow.title, "Test Default Allow")
        XCTAssertEqual(AdminQAAction.testAllowlist.title, "Test Allow List")
        XCTAssertEqual(AdminQAAction.testDenylist.title, "Test Deny List")
        XCTAssertEqual(AdminQAAction.testThreatGuardrail.title, "Test Threat Guardrail")
        XCTAssertEqual(AdminQAAction.setGoogleDNS.title, "Use Google DNS")
        XCTAssertEqual(AdminQAAction.setCloudflareDoH.title, "Use Cloudflare DoH")
        XCTAssertEqual(AdminQAAction.setCloudflareDoT.title, "Use Cloudflare DoT")
        XCTAssertEqual(AdminQAAction.enableLocalDomainHistory.title, "Enable Local History")
        XCTAssertEqual(AdminQAAction.disableLocalDomainHistory.title, "Disable Local History")
        XCTAssertEqual(AdminQAAction.clearLocalActivity.title, "Clear Local Activity")
        XCTAssertEqual(AdminQAAction.setPaidPlan.title, "Test Paid")
        XCTAssertEqual(AdminQAAction.setFreePlan.title, "Test Free")
    }

    func testPhoneQAActionsCoverFeatureSections() {
        let sections = AdminQAAction.allCases.map(\.section)
        XCTAssertEqual(Set(sections), Set(AdminQAActionSection.allCases))
        XCTAssertEqual(AdminQAAction.showWelcome.section, .appFlows)
        XCTAssertEqual(AdminQAAction.testThreatGuardrail.section, .filtering)
        XCTAssertEqual(AdminQAAction.setCloudflareDoH.section, .resolverAndPrivacy)
        XCTAssertEqual(AdminQAAction.setCloudflareDoT.section, .resolverAndPrivacy)
        XCTAssertEqual(AdminQAAction.setPaidPlan.section, .planAndLimits)
        XCTAssertEqual(AdminQAAction.clearQAState.section, .cleanup)
    }

    func testAdminQAVPNProfileActionsStayFocusedAndOrdered() {
        XCTAssertEqual(AdminQAVPNProfileAction.allCases, [
            .installProfile,
            .removeProfile,
            .resetProfile
        ])

        XCTAssertEqual(AdminQAVPNProfileAction.installProfile.title, "Install VPN Profile")
        XCTAssertEqual(AdminQAVPNProfileAction.removeProfile.title, "Remove VPN Profile")
        XCTAssertEqual(AdminQAVPNProfileAction.resetProfile.title, "Reset VPN Profile")
    }
}
