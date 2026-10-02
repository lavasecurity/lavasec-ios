import XCTest
import LavaSecKit

final class GuardMaterialPresentationTests: XCTestCase {
    func testDeferredDeviceRepairChangesOnlyTheConnectedAction() {
        let healthy = GuardStatusPresentation(status: .connected(.healthy))
        let repair = GuardStatusPresentation(status: .connected(.healthy), offersDeviceDNSRecapture: true)
        XCTAssertEqual(repair.headline, healthy.headline)
        XCTAssertEqual(repair.materialIntent, healthy.materialIntent)
        XCTAssertEqual(repair.tintRole, healthy.tintRole)
        XCTAssertEqual(repair.mascotState, healthy.mascotState)
        XCTAssertEqual(repair.allowsPause, healthy.allowsPause)
        XCTAssertEqual(repair.primaryAction, .reconnect)
        XCTAssertEqual(repair.actionTone, .recovery)
        let fallback = GuardStatusPresentation(status: .connected(.usingEncryptedFallback), offersDeviceDNSRecapture: true)
        XCTAssertEqual(fallback.headline, .status(.connected(.usingEncryptedFallback)))
        XCTAssertEqual(fallback.primaryAction, .reconnect)
        XCTAssertEqual(fallback.materialIntent, .recovery)
    }

    func testDeferredDeviceRepairCannotReplaceANonconnectedLifecycleAction() {
        for status in [ProtectionStatus.off, .notInstalled, .turningOn, .establishing,
                       .turningOff, .paused(Date()), .reconnecting, .vpnRecovering,
                       .vpnUnconfirmed, .chainingFailed, .tunnelReady, .unavailable] {
            XCTAssertEqual(GuardStatusPresentation(status: status, offersDeviceDNSRecapture: true),
                           GuardStatusPresentation(status: status), "\(status)")
        }
    }

    func testCapturedRepairSurvivesHealthRecoveryButNotANewerProtectionIntent() {
        var intent = ProtectionRestoreIntentState(isEnabled: true)
        let request = intent.makeRestoreRequest()
        let captured = GuardStatusPresentation(status: .connected(.healthy), offersDeviceDNSRecapture: true)
        let recovered = GuardStatusPresentation(status: .connected(.healthy))
        XCTAssertEqual(captured.primaryAction, .reconnect)
        XCTAssertEqual(recovered.primaryAction, .turnOff)
        XCTAssertTrue(intent.allowsExplicitReconnect(request), "Health recovery cannot change the authorized reconnect intent.")
        intent.recordUserIntent(isEnabled: false)
        XCTAssertFalse(intent.allowsExplicitReconnect(request), "A later Turn off must cancel the suspended reconnect.")
        intent.recordUserIntent(isEnabled: true)
        XCTAssertFalse(intent.allowsExplicitReconnect(request), "A newer Turn on must also supersede the old authorization turn.")
    }

    func testExplicitReconnectCanStartFromUnchangedOffIntentButCannotOverrideANewerOff() {
        var intent = ProtectionRestoreIntentState(isEnabled: false)
        let request = intent.makeRestoreRequest()
        XCTAssertFalse(intent.allows(request), "Automatic restoration still requires ON intent.")
        XCTAssertTrue(intent.allowsExplicitReconnect(request), "An explicit unchanged OFF reconnect remains a new ON choice.")
        intent.recordUserIntent(isEnabled: false)
        XCTAssertFalse(intent.allowsExplicitReconnect(request), "A newer OFF wins even if the direction is unchanged.")
    }

    func testAllRuntimeEndpointsKeepEvidenceAndHealthDistinct() {
        let cases: [(ProtectionStatus, GuardMaterialIntent, GuardMaterialSurface)] = [
            (.off, .rest, .rest), (.notInstalled, .rest, .rest),
            (.turningOn, .unresolved, .rest), (.establishing, .unresolved, .rest),
            (.turningOff, .stopping, .neutral), (.reconnecting, .recovery, .neutral),
            (.vpnRecovering, .recovery, .neutral),
            (.vpnUnconfirmed, .unknown, .neutral), (.unavailable, .unknown, .neutral),
            (.paused(Date()), .paused, .neutral), (.tunnelReady, .unknown, .neutral),
            (.chainingFailed, .recovery, .neutral),
            (.connected(.healthy), .affirmed, .affirmed),
            (.connected(.usingDeviceDNSFallback), .recovery, .neutral),
            (.connected(.usingEncryptedFallback), .recovery, .neutral),
            (.connected(.dnsSlow), .recovery, .neutral),
            (.connected(.recovering), .recovery, .neutral),
            (.connected(.networkUnavailable), .recovery, .neutral),
            (.connected(.needsReconnect), .recovery, .neutral)
        ]
        for (status, intent, surface) in cases {
            XCTAssertEqual(GuardMaterialIntent(status: status), intent)
            XCTAssertEqual(intent.surface(), surface)
        }
    }

    func testEveryGuardStatusProjectsPanelTintButtonAndActionTogether() {
        typealias P = GuardStatusPresentation
        let cases: [(ProtectionStatus, GuardMaterialSurface, ProtectionTintRole, P.PrimaryAction, P.ActionTone, Bool)] = [
            (.off, .rest, .inactive, .turnOn, .affirmative, false),
            (.notInstalled, .rest, .inactive, .turnOn, .affirmative, false),
            (.turningOn, .rest, .transitioning, .turnOff, .quiet, false),
            (.establishing, .rest, .transitioning, .turnOff, .quiet, false),
            (.turningOff, .neutral, .transitioning, .turnOff, .quiet, false),
            (.paused(Date()), .neutral, .paused, .resume, .affirmative, false),
            (.reconnecting, .neutral, .transitioning, .turnOff, .recovery, false),
            (.vpnRecovering, .neutral, .transitioning, .turnOff, .recovery, false),
            (.vpnUnconfirmed, .neutral, .attention, .turnOff, .recovery, false),
            (.tunnelReady, .neutral, .transitioning, .turnOff, .quiet, false),
            (.chainingFailed, .neutral, .attention, .reconnect, .recovery, false),
            (.unavailable, .neutral, .transitioning, .turnOff, .recovery, false),
            (.connected(.healthy), .affirmed, .protected, .turnOff, .quiet, true),
            (.connected(.recovering), .neutral, .transitioning, .turnOff, .recovery, true),
            (.connected(.usingDeviceDNSFallback), .neutral, .attention, .turnOff, .recovery, true),
            (.connected(.usingEncryptedFallback), .neutral, .attention, .turnOff, .recovery, true),
            (.connected(.dnsSlow), .neutral, .attention, .reconnect, .recovery, false),
            (.connected(.networkUnavailable), .neutral, .inactive, .turnOff, .recovery, false),
            (.connected(.needsReconnect), .neutral, .attention, .reconnect, .recovery, false)
        ]
        for (status, surface, tint, action, tone, allowsPause) in cases {
            let presentation = P(status: status)
            XCTAssertEqual(presentation.headline, .status(status), "\(status)")
            let error = P(status: status, hasErrorNotice: true)
            XCTAssertEqual(error.headline, status == .chainingFailed ? .status(status) : .needsAttention)
            XCTAssertEqual(error.materialIntent.surface(), .neutral)
            XCTAssertEqual(error.actionTone, .recovery)
            XCTAssertEqual(error.primaryAction, presentation.primaryAction)
            XCTAssertFalse(error.allowsPause)
            XCTAssertEqual(presentation.materialIntent.surface(), surface, "\(status)")
            XCTAssertEqual(presentation.tintRole, tint, "\(status)")
            XCTAssertEqual(presentation.primaryAction, action, "\(status)")
            XCTAssertEqual(presentation.actionTone, tone, "\(status)")
            XCTAssertEqual(presentation.allowsPause, allowsPause, "\(status)")
        }
    }

    func testVerifiedSetupWaitsQuietlyUntilTrafficOrARealProblemArrives() {
        let checking = ProtectionStatus.resolve(lifecycle: .connected,
            setupReady: true, connectivity: .healthy)
        XCTAssertEqual(checking, .tunnelReady)
        let presentation = GuardStatusPresentation(status: checking)
        XCTAssertEqual(presentation.materialIntent.surface(previous: .affirmed), .neutral)
        XCTAssertEqual(presentation.actionTone, .quiet)
        XCTAssertEqual(presentation.mascotState, .waking)
        XCTAssertFalse(presentation.allowsPause)

        for severity in [ProtectionConnectivitySeverity.networkUnavailable, .needsReconnect, .dnsSlow, .recovering,
                         .usingDeviceDNSFallback, .usingEncryptedFallback] {
            let problem = ProtectionStatus.resolve(lifecycle: .connected,
                setupReady: true, connectivity: severity)
            XCTAssertEqual(problem, .connected(severity))
            XCTAssertEqual(GuardStatusPresentation(status: problem).actionTone, .recovery)
        }
        XCTAssertEqual(GuardStatusPresentation(status: checking, hasErrorNotice: true).actionTone, .recovery)
        let verified = ProtectionStatus.resolve(lifecycle: .connected, connectivity: .healthy)
        XCTAssertEqual(GuardStatusPresentation(status: verified).materialIntent.surface(), .affirmed)
    }

    func testErrorNoticeNeutralizesPanelWithoutChangingLifecycleAction() {
        let connected = GuardStatusPresentation(status: .connected(.healthy), hasErrorNotice: true)
        XCTAssertEqual(connected.materialIntent.surface(), .neutral)
        XCTAssertEqual(connected.tintRole, .attention)
        XCTAssertEqual(connected.actionTone, .recovery)
        XCTAssertEqual(connected.primaryAction, .turnOff)
        XCTAssertFalse(connected.allowsPause)
        XCTAssertEqual(connected.mascotState, .concerned)

        let off = GuardStatusPresentation(status: .off, hasErrorNotice: true)
        XCTAssertEqual(off.materialIntent.surface(), .neutral)
        XCTAssertEqual(off.actionTone, .recovery)
        XCTAssertEqual(off.primaryAction, .turnOn)
    }

    func testMascotFollowsGuardStatusAndNeverCelebratesDegradedConnectivity() {
        XCTAssertEqual(GuardStatusPresentation(status: .connected(.healthy)).mascotState, .awake)
        XCTAssertEqual(GuardStatusPresentation(status: .tunnelReady).mascotState, .waking)
        for status in [ProtectionStatus.chainingFailed, .connected(.usingDeviceDNSFallback),
                       .connected(.usingEncryptedFallback), .connected(.dnsSlow),
                       .connected(.needsReconnect)] {
            XCTAssertEqual(GuardStatusPresentation(status: status).mascotState, .concerned)
        }
        XCTAssertEqual(GuardStatusPresentation(status: .connected(.networkUnavailable)).mascotState, .retrying)
    }

    func testColdStartRecoveryAndStopUsePriorAcceptedEndpoint() {
        XCTAssertEqual(GuardMaterialIntent.unresolved.surface(previous: .rest), .rest)
        XCTAssertEqual(GuardMaterialIntent.unresolved.surface(previous: .affirmed), .neutral)
        XCTAssertEqual(GuardMaterialIntent.stopping.surface(previous: .affirmed), .affirmed)
        XCTAssertEqual(GuardMaterialIntent.stopping.surface(previous: .neutral), .neutral)
        XCTAssertEqual(GuardMaterialIntent.rest.surface(previous: .affirmed), .rest)
    }

    func testMaterialHoldNeverReplaysReadinessAndInterruptionHasDistinctCadence() {
        XCTAssertEqual(GuardMaterialIntent.affirmed.duration(from: .affirmed, to: .affirmed), 0)
        XCTAssertEqual(GuardMaterialIntent.affirmed.duration(from: .rest, to: .affirmed), 0.5)
        XCTAssertEqual(GuardMaterialIntent.affirmed.duration(from: .neutral, to: .affirmed), 0.5)
        XCTAssertEqual(GuardMaterialIntent.recovery.duration(from: .affirmed, to: .neutral), 0.24)
        XCTAssertEqual(GuardMaterialIntent.unknown.duration(from: .affirmed, to: .neutral), 0.3)
        XCTAssertEqual(GuardMaterialIntent.paused.duration(from: .affirmed, to: .neutral), 0.4)
        XCTAssertEqual(GuardMaterialIntent.rest.duration(from: .affirmed, to: .rest), 0.55)
    }
}
