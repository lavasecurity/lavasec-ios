import XCTest
@testable import LavaSecKit

final class ChainedStatusContinuityTests: XCTestCase {
    typealias P = ChainedConnectLifecyclePolicy
    private let sampleDate = Date(timeIntervalSince1970: 10_000)
    private func sample(bytes: UInt64 = 0, ready: Bool = true, lifecycle: String? = "provider-A",
                        epoch: UInt64? = 1, transport: UInt64 = 1, baseline: UInt64 = 0,
                        condition: ChainedRuntimeCondition = .normal, healthy: Bool = true) -> ChainedRuntimeObservation {
        .chained(session: .init(generation: 1, forwardedBytes: bytes, transportGeneration: transport,
            setupReady: ready, providerLifecycleID: lifecycle, verificationEpoch: epoch,
            forwardingBaseline: baseline, runtimeCondition: condition,
            health: TunnelHealthSnapshot(startedAt: sampleDate, networkPathIsSatisfied: healthy), healthSampledAt: sampleDate))
    }
    private func begin() -> P.State {
        var state = P.State()
        P.reduce(state: &state, event: .statusChanged(.connected, onDemandConfirmed: true, userInitiated: true, now: 0))
        return state
    }
    @discardableResult private func observe(_ state: inout P.State, _ sample: ChainedRuntimeObservation?, _ now: Double) -> [P.Effect] {
        P.reduce(state: &state, event: .observed(connection: 1, observation: sample, now: now))
    }
    private func status(_ state: P.State) -> ProtectionStatus {
        let p = state.projection
        return .resolve(lifecycle: .connected, chainedEstablishing: p.claim == .establishing,
            observationUnavailable: p.claim == .checking, forwardingUnconfirmed: p.claim == .unconfirmed,
            setupReady: p.setupReady, runtimeCondition: p.runtimeCondition, connectivity: p.connectivity)
    }

    func testRetiredRunnerClearsOwnedHealthUntilFreshEvidenceArrives() {
        for missing: ChainedRuntimeObservation in [.inactive, .chained(session: nil)] {
            var state = begin()
            observe(&state, sample(bytes: 12), 1)
            XCTAssertEqual(state.projection.connectivity, .healthy)
            observe(&state, missing, 2)
            XCTAssertEqual(status(state), .unavailable)
            XCTAssertTrue(state.projection.ownsHealth)
            XCTAssertNil(state.projection.connectivity)
            XCTAssertNil(state.projection.effectiveConnectivity(fallback: .usingDeviceDNSFallback))
            observe(&state, sample(bytes: 14), 3)
            XCTAssertEqual(state.projection.connectivity, .healthy)
            XCTAssertEqual(status(state), .connected(.healthy))
        }
    }

    func testReadyBeforeAndAfterStartupDeadlineSurvivesShortControlCenter() {
        for started in [2.0, 16.0] {
            var s = begin(); observe(&s, sample(), started)
            P.reduce(state: &s, event: .successFeedbackFinished(connection: 1, retryWhenConfirmed: false))
            XCTAssertEqual(status(s), .tunnelReady)
            P.reduce(state: &s, event: .observationSuspended(now: started + 0.1))
            XCTAssertEqual(status(s), .tunnelReady)
            P.reduce(state: &s, event: .observationResumed(now: started + 0.5))
            XCTAssertEqual(status(s), .tunnelReady)
            XCTAssertEqual(observe(&s, sample(ready: false), started + 0.6), [])
            XCTAssertEqual(status(s), .tunnelReady, "Pending traffic is not invalidation")
            XCTAssertEqual(s.milestone, .setupVerified)
        }
    }
    func testConfirmedUnchangedCountersRemainStableAcrossGapAndReconfirmationIsSilent() {
        var s = begin(); observe(&s, sample(bytes: 12), 1)
        P.reduce(state: &s, event: .successFeedbackFinished(connection: 1, retryWhenConfirmed: false))
        observe(&s, nil, 2)
        XCTAssertEqual(status(s), .connected(.healthy))
        XCTAssertFalse(s.canDeliverSuccess(now: 2), "Grace cannot deliver feedback")
        XCTAssertEqual(observe(&s, sample(bytes: 12, ready: false), 3), [])
        XCTAssertEqual(status(s), .connected(.healthy))
        XCTAssertEqual(s.lastAcceptedAt, 3)
    }
    func testAbsoluteThreeSecondExpiryAndRepeatedEdgesCannotExtendIt() {
        var s = begin(); observe(&s, sample(), 1)
        observe(&s, nil, 2)
        XCTAssertEqual(s.graceDeadline, 5)
        for t in [2.1, 3, 4.999] {
            P.reduce(state: &s, event: .observationSuspended(now: t))
            P.reduce(state: &s, event: .observationResumed(now: t))
            observe(&s, nil, t)
            XCTAssertEqual(s.graceDeadline, 5)
            XCTAssertEqual(status(s), .tunnelReady)
        }
        P.reduce(state: &s, event: .observationDeadline(connection: 1, deadline: 5, now: 5))
        XCTAssertEqual(status(s), .unavailable)
        XCTAssertEqual(s.milestone, .setupVerified)
        observe(&s, sample(ready: false), 6)
        XCTAssertEqual(status(s), .tunnelReady)
    }
    func testAgeCapLimitsGraceToOneSecondAndFreshIdenticalPollRenewsAge() {
        var s = begin(); observe(&s, sample(bytes: 5), 1)
        observe(&s, nil, 10)
        XCTAssertEqual(s.graceDeadline, 11)
        P.reduce(state: &s, event: .observationDeadline(connection: 1, deadline: 11, now: 11))
        XCTAssertEqual(status(s), .unavailable)
        for t in [12.0, 17, 22] { observe(&s, sample(bytes: 5), t); XCTAssertEqual(s.lastAcceptedAt, t) }
        observe(&s, nil, 23)
        XCTAssertEqual(s.graceDeadline, 26)
    }
    func testOldDeadlineAndWrongConnectionCannotOverwriteFreshReply() {
        var s = begin(); observe(&s, sample(), 1); observe(&s, nil, 2)
        observe(&s, sample(), 3)
        let accepted = s
        P.reduce(state: &s, event: .observationDeadline(connection: 1, deadline: 5, now: 9))
        P.reduce(state: &s, event: .observed(connection: 2, observation: nil, now: 10))
        XCTAssertEqual(s, accepted)
    }
    func testLongSleepExpiresOnResumeThenRequiresAdmittedFreshEvidence() {
        var s = begin(); observe(&s, sample(bytes: 8), 1)
        P.reduce(state: &s, event: .observationSuspended(now: 2))
        P.reduce(state: &s, event: .observationResumed(now: 3600))
        XCTAssertEqual(status(s), .unavailable)
        observe(&s, sample(bytes: 8), 3601)
        XCTAssertEqual(status(s), .connected(.healthy))
    }
    func testProviderIdentityAndWakeEpochRejectOldCountersButNewTransportUsesZeroBaseline() {
        var s = begin(); observe(&s, sample(bytes: 100), 1)
        observe(&s, sample(bytes: 0, ready: false, lifecycle: "provider-B"), 2)
        XCTAssertEqual(s.milestone, .none)
        XCTAssertNotEqual(status(s), .connected(.healthy))
        observe(&s, sample(bytes: 100, epoch: 2, baseline: 100), 3)
        XCTAssertEqual(status(s), .tunnelReady)
        observe(&s, sample(bytes: 100, ready: false, epoch: 2, baseline: 100), 4)
        XCTAssertEqual(status(s), .tunnelReady)
        observe(&s, sample(bytes: 101, epoch: 2, baseline: 100), 5)
        XCTAssertEqual(status(s), .connected(.healthy))
        observe(&s, sample(bytes: 1, transport: 2), 6)
        XCTAssertEqual(status(s), .connected(.healthy), "First real byte on new transport must count")
    }
    func testCounterRegressionCannotBorrowOldMilestone() {
        var s = begin(); observe(&s, sample(bytes: 50), 1)
        observe(&s, sample(bytes: 5), 2)
        XCTAssertEqual(s.milestone, .none)
        XCTAssertFalse(s.setupReady)
        observe(&s, sample(bytes: 5), 3)
        XCTAssertNotEqual(s.claim, .confirmed)
        observe(&s, sample(bytes: 6), 4)
        XCTAssertEqual(s.claim, .confirmed)
    }
    func testCurrentRuntimeFailureOverridesImmediatelyAndSameEpochRecoveryRestoresMilestone() {
        for condition in [ChainedRuntimeCondition.recovering, .offline, .suspended, .retired] {
            var s = begin(); observe(&s, sample(), 1)
            observe(&s, sample(ready: false, condition: condition), 2)
            XCTAssertNotEqual(status(s), .tunnelReady)
            XCTAssertFalse(s.canDeliverSuccess(now: 2))
            observe(&s, sample(ready: false), 3)
            XCTAssertEqual(status(s), .tunnelReady)
        }
    }
    func testCurrentHealthOverridesReadyThenRecoversWithoutNewTraffic() {
        var s = begin(); observe(&s, sample(), 1)
        observe(&s, sample(ready: false, healthy: false), 2)
        XCTAssertEqual(status(s), .connected(.networkUnavailable))
        observe(&s, sample(ready: false), 3)
        XCTAssertEqual(status(s), .tunnelReady)
        observe(&s, nil, 4)
        P.reduce(state: &s, event: .observationDeadline(connection: 1, deadline: 7, now: 7))
        XCTAssertNil(s.projection.connectivity, "Expired health must not override unknown")
    }
    func testLegacyMissingIdentityDoesNotBorrowGrace() {
        var s = begin(); observe(&s, sample(lifecycle: nil, epoch: nil), 1)
        P.reduce(state: &s, event: .observationSuspended(now: 1.1))
        XCTAssertFalse(s.setupReady)
        XCTAssertEqual(s.claim, .checking)
    }
    func testAuthoritativeDNSOnlyReleasesChainedHealthBeforeStoppingSampler() {
        var s = begin(); observe(&s, sample(healthy: false), 1)
        XCTAssertTrue(s.projection.ownsHealth)
        XCTAssertEqual(status(s), .connected(.networkUnavailable))
        let effects = observe(&s, .dnsOnly, 2)
        XCTAssertTrue(effects.contains(.stopSampling))
        XCTAssertFalse(s.projection.ownsHealth)
        XCTAssertNil(s.projection.connectivity)
        XCTAssertEqual(s.claim, .confirmed)
        XCTAssertNil(s.graceDeadline)
        XCTAssertTrue(s.canDeliverSuccess(now: 2))
    }
    func testOffAndNewConnectionRejectPreviousTimerAndFeedback() {
        var s = begin(); observe(&s, sample(), 1); observe(&s, nil, 2)
        P.reduce(state: &s, event: .statusChanged(.disconnecting, onDemandConfirmed: true, userInitiated: false, now: 3))
        XCTAssertEqual(s.claim, .inactive)
        P.reduce(state: &s, event: .statusChanged(.connected, onDemandConfirmed: true, userInitiated: true, now: 4))
        let new = s
        P.reduce(state: &s, event: .observationDeadline(connection: 1, deadline: 5, now: 5))
        P.reduce(state: &s, event: .successFeedbackFinished(connection: 1, retryWhenConfirmed: false))
        XCTAssertEqual(s, new)
    }
    func testLegacyMissingHealthWaitsForExplicitHealthyEvidenceBeforeRetrying() {
        var s = begin()
        let missing = ChainedRuntimeObservation.chained(session: .init(
            generation: 1, forwardedBytes: 12, transportGeneration: 1))
        observe(&s, missing, 1)
        XCTAssertNil(s.projection.connectivity)
        P.reduce(state: &s, event: .successFeedbackFinished(connection: 1, retryWhenConfirmed: true))
        for time in [2.0, 3, 4, 5] { XCTAssertEqual(observe(&s, missing, time), []) }
        let healthy = ChainedRuntimeObservation.chained(session: .init(
            generation: 1, forwardedBytes: 12, transportGeneration: 1,
            health: TunnelHealthSnapshot(startedAt: sampleDate), healthSampledAt: sampleDate))
        XCTAssertTrue(observe(&s, healthy, 6).contains(
            .resolveDeferredSuccess(connection: 1, receivedByteDelta: 12)))
    }

    func testLegacyFallbackHealthCannotRetryFeedbackOnEveryConfirmedPoll() {
        var s = begin()
        var fallback = TunnelHealthSnapshot(startedAt: sampleDate)
        fallback.deviceDNSFallbackModeActive = true
        fallback.lastDeviceDNSFallbackActivatedAt = sampleDate
        func legacy(_ health: TunnelHealthSnapshot) -> ChainedRuntimeObservation {
            .chained(session: .init(generation: 1, forwardedBytes: 12, transportGeneration: 1,
                health: health, healthSampledAt: sampleDate))
        }
        observe(&s, legacy(fallback), 1)
        XCTAssertFalse(s.projection.ownsHealth)
        XCTAssertEqual(s.projection.connectivity, .usingDeviceDNSFallback)
        P.reduce(state: &s, event: .successFeedbackFinished(connection: 1, retryWhenConfirmed: true))
        for time in [2.0, 3, 4, 5] {
            XCTAssertEqual(observe(&s, legacy(fallback), time), [])
        }
        XCTAssertTrue(observe(&s, legacy(TunnelHealthSnapshot(startedAt: sampleDate)), 6).contains(
            .resolveDeferredSuccess(connection: 1, receivedByteDelta: 12)))
    }

    func testSetupOnlyPollsWaitForForwardingBeforeRetryingSuccess() {
        var s = begin()
        let first = observe(&s, sample(), 1)
        XCTAssertTrue(first.contains(.resolveSetupReady(connection: 1, userInitiated: true)))
        P.reduce(state: &s, event: .successFeedbackFinished(connection: 1, retryWhenConfirmed: true))
        for time in [2.0, 3, 4, 8, 16, 20] {
            let effects = observe(&s, sample(), time)
            XCTAssertFalse(effects.contains { effect in
                switch effect {
                case .resolveSetupReady, .resolveDeferredSuccess: true
                default: false
                }
            })
        }
        XCTAssertTrue(observe(&s, sample(bytes: 12), 21).contains(
            .resolveDeferredSuccess(connection: 1, receivedByteDelta: 12)))
        P.reduce(state: &s, event: .successFeedbackFinished(connection: 1, retryWhenConfirmed: false))
        XCTAssertEqual(observe(&s, sample(bytes: 24), 22), [])
    }

    func testDelayedSuccessCannotCrossVisibilityBoundaryOrUseGraceOrAdverseHealth() {
        var s = begin(); observe(&s, sample(), 1)
        func disposition(_ state: P.State, current: UInt64 = 4, active: Bool = true,
                         status: ProtectionStatus? = nil) -> P.SuccessFeedbackDisposition {
            P.successFeedbackDisposition(state: state, acceptedGeneration: 4, currentGeneration: current,
                isActive: active, hasError: false, status: status ?? self.status(state), now: 2)
        }
        XCTAssertEqual(disposition(s), .retryOnFreshEvidence, "Setup alone cannot celebrate success")
        observe(&s, sample(bytes: 12), 1.2)
        XCTAssertEqual(disposition(s), .deliver)
        for pending in [ProtectionStatus.tunnelReady, .vpnUnconfirmed, .establishing, .unavailable,
                        .connected(.usingEncryptedFallback), .connected(.usingDeviceDNSFallback)] {
            XCTAssertEqual(disposition(s, status: pending), .retryOnFreshEvidence)
        }
        XCTAssertEqual(disposition(s, current: 6), .consumeSilently, "Fence completion after inactive then active remains silent")
        XCTAssertEqual(disposition(s, active: false), .consumeSilently)
        XCTAssertEqual(disposition(s, status: .connected(.needsReconnect)), .retryOnFreshEvidence)
        observe(&s, nil, 1.5)
        XCTAssertEqual(disposition(s), .retryOnFreshEvidence)
    }

    func testOneShotExternalReadCannotBorrowPreWakeCounterAndDecodesLegacy() throws {
        let e = ProtectionStatusEvidence(sampledAt: sampleDate, lifecycleIsActive: true,
            health: TunnelHealthSnapshot(startedAt: sampleDate), pauseUntil: nil, isChained: true,
            sessionGeneration: 1, forwardedBytes: 100, transportGeneration: 1, setupReady: false,
            providerLifecycleID: "p", verificationEpoch: 2, forwardingBaseline: 100)
        XCTAssertNotEqual(e.status(now: sampleDate), .connected(.healthy))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as? [String: Any])
        for key in ["providerLifecycleID", "verificationEpoch", "forwardingBaseline", "runtimeCondition"] { object.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(ProtectionStatusEvidence.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.status(now: sampleDate), .connected(.healthy))
    }
}
