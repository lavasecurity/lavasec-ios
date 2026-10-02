import XCTest
@testable import LavaSecKit

final class DNSPatchStartupInstallPolicyTests: XCTestCase {
    private let generation: UInt64 = 7
    private let translated = "64:ff9b::909:90a"
    private let otherTranslated = "2001:db8:1234:5678:abcd:ef01:909:90a"

    private func policy(initialDiscoverySettled: Bool = true) throws -> DNSPatchStartupInstallPolicy {
        var policy = DNSPatchStartupInstallPolicy(contract: try DNSPatchContract.bundled(), lifecycleGeneration: generation)
        if initialDiscoverySettled {
            policy.initialDiscoveryDidComplete(.succeeded, lifecycleGeneration: generation)
        }
        return policy
    }

    func testColdStartWaitsForObservedNAT64BeforeCapturingTheFirstInstall() throws {
        var policy = try policy(initialDiscoverySettled: false)
        XCTAssertFalse(policy.beginInitialInstall(lifecycleGeneration: generation),
            "The first settings post must wait for physical discovery instead of paying for a second cold post.")
        policy.observeEndpoints(["9.9.9.10", translated], lifecycleGeneration: generation)
        XCTAssertTrue(policy.initialDiscoveryDidComplete(.succeeded, lifecycleGeneration: generation))
        XCTAssertTrue(policy.beginInitialInstall(lifecycleGeneration: generation))
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ready,
            "The observed NAT64 route must already be in the first install baseline.")
    }

    func testFailedDiscoveryCannotBeginTheFirstSettingsPost() throws {
        var policy = try policy(initialDiscoverySettled: false)
        policy.initialDiscoveryDidComplete(.failed(.timedOut), lifecycleGeneration: generation)
        XCTAssertFalse(policy.beginInitialInstall(lifecycleGeneration: generation))
    }

    func testPathChangeWhileCollectingIsAbsorbedByTheFirstSnapshot() throws {
        var policy = try policy(initialDiscoverySettled: false)
        XCTAssertEqual(policy.requestSettingsReapply(lifecycleGeneration: generation), .retain)
        policy.observeEndpoints([translated], lifecycleGeneration: generation)
        policy.initialDiscoveryDidComplete(.succeeded, lifecycleGeneration: generation)
        XCTAssertTrue(policy.beginInitialInstall(lifecycleGeneration: generation))
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ready,
            "The first atomic settings snapshot already sees the latest physical path and configuration.")
    }

    func testOrdinaryNudgesDuringInstallDrainOnceWithoutDNSMembershipChanges() throws {
        var policy = try policy()
        policy.beginInitialInstall(lifecycleGeneration: generation)
        XCTAssertEqual(policy.requestSettingsReapply(lifecycleGeneration: generation), .retain)
        XCTAssertEqual(policy.requestSettingsReapply(lifecycleGeneration: generation), .retain)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .installLatest,
            "A path/configuration/filter nudge cannot overlap the initial settings or disappear.")
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ready,
            "Repeated nudges before the same callback coalesce into one latest refresh.")
        XCTAssertEqual(policy.requestSettingsReapply(lifecycleGeneration: generation), .reapply)
    }

    func testOrdinaryNudgeDuringFollowUpRequiresAnotherSerializedInstall() throws {
        var policy = try policy()
        policy.beginInitialInstall(lifecycleGeneration: generation)
        policy.observeEndpoints([translated], lifecycleGeneration: generation)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .installLatest)
        XCTAssertEqual(policy.requestSettingsReapply(lifecycleGeneration: generation), .retain)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .installLatest)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ready)
    }

    func testStaleOrCancelledOrdinaryNudgeCannotPostOrExtendStartup() throws {
        var policy = try policy()
        policy.beginInitialInstall(lifecycleGeneration: generation)
        XCTAssertEqual(policy.requestSettingsReapply(lifecycleGeneration: generation - 1), .ignore)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ready)
        policy.cancel()
        XCTAssertEqual(policy.requestSettingsReapply(lifecycleGeneration: generation), .ignore)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ignore)
    }

    func testInitialPreparationWaitsBeforeFirstDiscoveryCallback() throws {
        var policy = try policy(initialDiscoverySettled: false)
        XCTAssertEqual(policy.initialSettingsAction(lifecycleGeneration: generation), .waitForDiscovery)
        XCTAssertFalse(policy.beginInitialInstall(lifecycleGeneration: generation))
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ignore)
    }

    func testNonstandardPref64DiscoveryIsIncludedInTheFirstInstall() throws {
        var policy = try policy(initialDiscoverySettled: false)
        XCTAssertEqual(policy.initialSettingsAction(lifecycleGeneration: generation), .waitForDiscovery)
        XCTAssertEqual(policy.observeEndpoints([otherTranslated], lifecycleGeneration: generation), .retain)
        XCTAssertTrue(policy.initialDiscoveryDidComplete(.succeeded, lifecycleGeneration: generation))
        XCTAssertEqual(policy.initialSettingsAction(lifecycleGeneration: generation), .ready)
        XCTAssertTrue(policy.beginInitialInstall(lifecycleGeneration: generation))
        XCTAssertEqual(policy.initialSettingsAction(lifecycleGeneration: generation), .ignore)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ready)
    }

    func testExplicitSettlementWithNoNewEndpointsAllowsTheFirstInstall() throws {
        var policy = try policy(initialDiscoverySettled: false)
        XCTAssertEqual(policy.initialSettingsAction(lifecycleGeneration: generation), .waitForDiscovery)
        XCTAssertTrue(policy.initialDiscoveryDidComplete(.succeeded, lifecycleGeneration: generation))
        XCTAssertEqual(policy.initialSettingsAction(lifecycleGeneration: generation), .ready)
        XCTAssertTrue(policy.beginInitialInstall(lifecycleGeneration: generation))
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ready)
        XCTAssertFalse(policy.initialDiscoveryDidComplete(.succeeded, lifecycleGeneration: generation))
    }

    func testDiscoveryFailureBeforePreparationCannotAuthorizeAnySettingsPost() throws {
        var policy = try policy(initialDiscoverySettled: false)
        XCTAssertTrue(policy.initialDiscoveryDidComplete(.failed(.timedOut), lifecycleGeneration: generation))
        XCTAssertEqual(policy.initialSettingsAction(lifecycleGeneration: generation), .discoveryFailed(.timedOut))
        XCTAssertFalse(policy.beginInitialInstall(lifecycleGeneration: generation))
        XCTAssertEqual(policy.initialSettingsAction(lifecycleGeneration: generation), .ignore)
    }

    func testDiscoveryFailureDuringTheInitialWaitResumesExactlyOneFailure() throws {
        var policy = try policy(initialDiscoverySettled: false)
        XCTAssertEqual(policy.initialSettingsAction(lifecycleGeneration: generation), .waitForDiscovery)
        XCTAssertTrue(policy.initialDiscoveryDidComplete(.failed(.evaluationFailed), lifecycleGeneration: generation))
        XCTAssertEqual(policy.initialSettingsAction(lifecycleGeneration: generation), .discoveryFailed(.evaluationFailed))
        XCTAssertEqual(policy.initialSettingsAction(lifecycleGeneration: generation), .ignore)
        XCTAssertFalse(policy.beginInitialInstall(lifecycleGeneration: generation))
    }

    func testStopAndStaleSettlementCannotResumeInitialPreparation() throws {
        var policy = try policy(initialDiscoverySettled: false)
        XCTAssertEqual(policy.initialSettingsAction(lifecycleGeneration: generation), .waitForDiscovery)
        XCTAssertFalse(policy.initialDiscoveryDidComplete(.succeeded, lifecycleGeneration: generation - 1))
        XCTAssertEqual(policy.initialSettingsAction(lifecycleGeneration: generation - 1), .ignore)
        policy.cancel()
        XCTAssertFalse(policy.initialDiscoveryDidComplete(.succeeded, lifecycleGeneration: generation))
        XCTAssertEqual(policy.initialSettingsAction(lifecycleGeneration: generation), .ignore)
        XCTAssertFalse(policy.beginInitialInstall(lifecycleGeneration: generation))
    }

    func testCompletedDiscoveryCannotReopenOrFailAnInstallation() throws {
        var policy = try policy(initialDiscoverySettled: false)
        XCTAssertTrue(policy.initialDiscoveryDidComplete(.succeeded, lifecycleGeneration: generation))
        XCTAssertFalse(policy.initialDiscoveryDidComplete(.failed(.timedOut), lifecycleGeneration: generation))
        XCTAssertEqual(policy.initialSettingsAction(lifecycleGeneration: generation), .ready)
        XCTAssertTrue(policy.beginInitialInstall(lifecycleGeneration: generation))
        XCTAssertEqual(policy.initialSettingsAction(lifecycleGeneration: generation), .ignore)
        XCTAssertFalse(policy.initialDiscoveryDidComplete(.failed(.evaluationFailed), lifecycleGeneration: generation))
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ready,
            "A successful discovery is immutable; installation completion never waits for it again.")
        XCTAssertFalse(policy.initialDiscoveryDidComplete(.succeeded, lifecycleGeneration: generation))
    }

    func testCancellationAfterDiscoverySettlementCannotAdmitOrCompleteSettings() throws {
        var policy = try policy()
        XCTAssertEqual(policy.initialSettingsAction(lifecycleGeneration: generation), .ready)
        policy.cancel()
        XCTAssertEqual(policy.initialSettingsAction(lifecycleGeneration: generation), .ignore)
        XCTAssertFalse(policy.beginInitialInstall(lifecycleGeneration: generation))
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ignore)
        XCTAssertFalse(policy.initialDiscoveryDidComplete(.succeeded, lifecycleGeneration: generation))
    }

    func testLiteralDiscoveryDuringInitialInstallNeedsNoFollowUp() throws {
        var policy = try policy()
        XCTAssertTrue(policy.beginInitialInstall(lifecycleGeneration: generation))
        XCTAssertEqual(policy.observeEndpoints(["9.9.9.10", "2620:fe::10"], lifecycleGeneration: generation), .retain)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ready)
    }

    func testEarlyTranslationIncludedInTheInitialBundleNeedsNoFollowUp() throws {
        var policy = try policy()
        XCTAssertEqual(policy.observeEndpoints([translated], lifecycleGeneration: generation), .retain)
        XCTAssertTrue(policy.beginInitialInstall(lifecycleGeneration: generation))
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ready)
    }

    func testTranslationDuringInitialInstallIsAwaitedBeforeReadiness() throws {
        var policy = try policy()
        policy.beginInitialInstall(lifecycleGeneration: generation)
        XCTAssertEqual(policy.observeEndpoints([translated], lifecycleGeneration: generation), .retain)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .installLatest)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ready)
    }

    func testChangesDuringFollowUpRetainOnlyTheLatestNeededCaptureSet() throws {
        var policy = try policy()
        policy.beginInitialInstall(lifecycleGeneration: generation)
        policy.observeEndpoints([translated], lifecycleGeneration: generation)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .installLatest)
        XCTAssertEqual(policy.observeEndpoints([translated, otherTranslated], lifecycleGeneration: generation), .retain)
        XCTAssertEqual(policy.observeEndpoints([otherTranslated], lifecycleGeneration: generation), .retain)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .installLatest)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ready)
    }

    func testEquivalentSpellingOrderingAndInterfaceDuplicatesDoNotCreateAnotherInstall() throws {
        var policy = try policy()
        policy.observeEndpoints([translated, otherTranslated], lifecycleGeneration: generation)
        policy.beginInitialInstall(lifecycleGeneration: generation)
        policy.observeEndpoints([otherTranslated, "0064:ff9b:0:0:0:0:0909:090a", translated], lifecycleGeneration: generation)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ready)
    }

    func testPendingTranslationThatReturnsToInstalledMembershipNeedsNoFollowUp() throws {
        var policy = try policy()
        policy.beginInitialInstall(lifecycleGeneration: generation)
        policy.observeEndpoints([translated], lifecycleGeneration: generation)
        policy.observeEndpoints(["9.9.9.10"], lifecycleGeneration: generation)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ready)
    }

    func testRejectedObservationsDoNotChangeInitialRoutes() throws {
        var policy = try policy()
        policy.beginInitialInstall(lifecycleGeneration: generation)
        policy.observeEndpoints(["not-an-ip", "1.1.1.1"], lifecycleGeneration: generation)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ready)
    }

    func testFailedInstallOrStopDiscardsThePendingDrainAndCannotReportReady() throws {
        var policy = try policy()
        policy.beginInitialInstall(lifecycleGeneration: generation)
        policy.observeEndpoints([translated], lifecycleGeneration: generation)
        policy.cancel()
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ignore)
        XCTAssertEqual(policy.observeEndpoints([otherTranslated], lifecycleGeneration: generation), .ignore)
        XCTAssertFalse(policy.beginInitialInstall(lifecycleGeneration: generation))
    }

    func testCancellationDuringFollowUpCannotSettleAStoppedLifecycle() throws {
        var policy = try policy()
        policy.beginInitialInstall(lifecycleGeneration: generation)
        policy.observeEndpoints([translated], lifecycleGeneration: generation)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .installLatest)
        policy.cancel()
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ignore)
    }

    func testStaleGenerationCannotChangeOrSettleCurrentInstall() throws {
        var policy = try policy()
        XCTAssertFalse(policy.beginInitialInstall(lifecycleGeneration: generation - 1))
        policy.beginInitialInstall(lifecycleGeneration: generation)
        XCTAssertEqual(policy.observeEndpoints([translated], lifecycleGeneration: generation - 1), .ignore)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation - 1), .ignore)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ready)
    }

    func testSecondInitialCaptureCannotOverwriteAnInFlightBaseline() throws {
        var policy = try policy()
        policy.beginInitialInstall(lifecycleGeneration: generation)
        policy.observeEndpoints([translated], lifecycleGeneration: generation)
        XCTAssertFalse(policy.beginInitialInstall(lifecycleGeneration: generation))
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .installLatest)
    }

    func testAfterReadinessRealAdditionsAndRemovalsUseOrdinaryReapply() throws {
        var policy = try policy()
        policy.beginInitialInstall(lifecycleGeneration: generation)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ready)
        XCTAssertEqual(policy.observeEndpoints([translated], lifecycleGeneration: generation), .reapply)
        XCTAssertEqual(policy.observeEndpoints(["0064:ff9b:0:0:0:0:0909:090a", translated], lifecycleGeneration: generation), .retain)
        XCTAssertEqual(policy.observeEndpoints([], lifecycleGeneration: generation), .reapply)
        XCTAssertEqual(policy.settingsInstallDidComplete(lifecycleGeneration: generation), .ignore)
    }
}
