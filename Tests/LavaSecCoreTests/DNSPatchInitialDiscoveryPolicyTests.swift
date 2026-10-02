import XCTest
@testable import LavaSecKit

final class DNSPatchInitialDiscoveryPolicyTests: XCTestCase {
    private func token(_ action: DNSPatchInitialDiscoveryPolicy.Action) -> UInt64 {
        guard case .evaluate(let token) = action else {
            XCTFail("An active initial path requires a new evaluation token.")
            return 0
        }
        return token
    }

    func testBothInactivePathsSettleWithoutAnEndpoint() {
        var policy = DNSPatchInitialDiscoveryPolicy()
        XCTAssertEqual(policy.pathObserved(.wifi, isSatisfied: false), .none)
        XCTAssertEqual(policy.pathObserved(.cellular, isSatisfied: false), .complete(.succeeded))
    }

    func testAnActivePathMustProduceAnAdmittedEndpointBeforeSettlement() {
        var policy = DNSPatchInitialDiscoveryPolicy()
        let wifi = token(policy.pathObserved(.wifi, isSatisfied: true))
        XCTAssertEqual(policy.pathObserved(.cellular, isSatisfied: false), .none)
        XCTAssertEqual(policy.evaluationCompleted(.wifi, token: wifi, endpointIsAdmitted: true), .complete(.succeeded))
    }

    func testBothActiveInterfacesMustFinishInitialEvaluation() {
        var policy = DNSPatchInitialDiscoveryPolicy()
        let wifi = token(policy.pathObserved(.wifi, isSatisfied: true))
        let cellular = token(policy.pathObserved(.cellular, isSatisfied: true))
        XCTAssertEqual(policy.evaluationCompleted(.wifi, token: wifi, endpointIsAdmitted: true), .none)
        XCTAssertEqual(policy.evaluationCompleted(.cellular, token: cellular, endpointIsAdmitted: true), .complete(.succeeded))
    }

    func testMonitorSilenceConsumesTheOverallDeadlineAndFailsOnce() {
        var policy = DNSPatchInitialDiscoveryPolicy()
        XCTAssertEqual(policy.deadlineDidExpire(), .complete(.failed(.timedOut)))
        XCTAssertEqual(policy.deadlineDidExpire(), .none)
        XCTAssertEqual(policy.pathObserved(.wifi, isSatisfied: true), .none)
    }

    func testPendingConnectionCannotTurnDeadlineExpiryIntoReadiness() {
        var policy = DNSPatchInitialDiscoveryPolicy()
        let wifi = token(policy.pathObserved(.wifi, isSatisfied: true))
        policy.pathObserved(.cellular, isSatisfied: false)
        XCTAssertEqual(policy.deadlineDidExpire(), .complete(.failed(.timedOut)))
        XCTAssertEqual(policy.evaluationCompleted(.wifi, token: wifi, endpointIsAdmitted: true), .none)
    }

    func testFailedOrUnusableReadyEndpointFailsInitialEvaluation() {
        var policy = DNSPatchInitialDiscoveryPolicy()
        let wifi = token(policy.pathObserved(.wifi, isSatisfied: true))
        XCTAssertEqual(policy.evaluationCompleted(.wifi, token: wifi, endpointIsAdmitted: false),
            .complete(.failed(.evaluationFailed)))
        XCTAssertEqual(policy.cancel(), .none)
    }

    func testReplacementPathFencesTheEarlierConnection() {
        var policy = DNSPatchInitialDiscoveryPolicy()
        let old = token(policy.pathObserved(.wifi, isSatisfied: true))
        let replacement = token(policy.pathObserved(.wifi, isSatisfied: true))
        XCTAssertNotEqual(old, replacement)
        policy.pathObserved(.cellular, isSatisfied: false)
        XCTAssertEqual(policy.evaluationCompleted(.wifi, token: old, endpointIsAdmitted: true), .none)
        XCTAssertEqual(policy.evaluationCompleted(.wifi, token: old, endpointIsAdmitted: false), .none)
        XCTAssertEqual(policy.evaluationCompleted(.wifi, token: replacement, endpointIsAdmitted: true), .complete(.succeeded))
    }

    func testAnInactiveTransitionSettlesAndOldConnectionCannotUndoIt() {
        var policy = DNSPatchInitialDiscoveryPolicy()
        let wifi = token(policy.pathObserved(.wifi, isSatisfied: true))
        XCTAssertEqual(policy.pathObserved(.wifi, isSatisfied: false), .none)
        XCTAssertEqual(policy.pathObserved(.cellular, isSatisfied: false), .complete(.succeeded))
        XCTAssertEqual(policy.evaluationCompleted(.wifi, token: wifi, endpointIsAdmitted: false), .none)
    }

    func testASettledInterfaceThatChangesWhileTheOtherWaitsNeedsFreshEvaluation() {
        var policy = DNSPatchInitialDiscoveryPolicy()
        policy.pathObserved(.wifi, isSatisfied: false)
        let wifi = token(policy.pathObserved(.wifi, isSatisfied: true))
        XCTAssertEqual(policy.pathObserved(.cellular, isSatisfied: false), .none)
        XCTAssertEqual(policy.evaluationCompleted(.wifi, token: wifi, endpointIsAdmitted: true), .complete(.succeeded))
    }

    func testCancelBeforeOrDuringEvaluationCompletesOnlyOnce() {
        for didBeginEvaluation in [false, true] {
            var policy = DNSPatchInitialDiscoveryPolicy()
            let wifi = didBeginEvaluation ? token(policy.pathObserved(.wifi, isSatisfied: true)) : 0
            XCTAssertEqual(policy.cancel(), .complete(.failed(.cancelled)))
            XCTAssertEqual(policy.cancel(), .none)
            XCTAssertEqual(policy.deadlineDidExpire(), .none)
            XCTAssertEqual(policy.evaluationCompleted(.wifi, token: wifi, endpointIsAdmitted: true), .none)
        }
    }

    func testSuccessCannotBeDeliveredAgainByDeadlineOrCancellation() {
        var policy = DNSPatchInitialDiscoveryPolicy()
        policy.pathObserved(.wifi, isSatisfied: false)
        XCTAssertEqual(policy.pathObserved(.cellular, isSatisfied: false), .complete(.succeeded))
        XCTAssertEqual(policy.deadlineDidExpire(), .none)
        XCTAssertEqual(policy.cancel(), .none)
    }
}
