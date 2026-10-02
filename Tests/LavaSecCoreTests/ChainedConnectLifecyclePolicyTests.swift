import XCTest

@testable import LavaSecKit

final class ChainedConnectLifecyclePolicyTests: XCTestCase {
    private typealias Policy = ChainedConnectLifecyclePolicy
    private typealias Observation = ChainedRuntimeObservation

    func testForegroundRepairRetriesAStableConfirmedConnectionOnce() {
        var state = Policy.State()
        _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0))
        _ = reduce(&state, .observed(connection: 1, observation: session(7, 1), now: 1))
        _ = reduce(&state, .onDemandArmFinished(id: 1, confirmed: false))
        XCTAssertEqual(state.claim, .confirmed)
        XCTAssertEqual(reduce(&state, .observed(connection: 1, observation: session(7, 2), now: 2)), [])
        XCTAssertEqual(reduce(&state, .onDemandRepairRequested(connection: 1, startsNewObservation: false, now: 3)),
            [.ensureOnDemand(id: 2, connection: 1)])
        XCTAssertEqual(reduce(&state, .onDemandRepairRequested(connection: 1, startsNewObservation: false, now: 3)), [])
        _ = reduce(&state, .onDemandArmFinished(id: 2, confirmed: true))
        XCTAssertEqual(reduce(&state, .onDemandRepairRequested(connection: 1, startsNewObservation: false, now: 4)), [])
        XCTAssertEqual(state.claim, .confirmed, "repair does not discard a valid observation identity")
    }

    func testForegroundRepairWorksAfterDNSOnlyStoppedSampling() {
        var state = Policy.State()
        _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0))
        _ = reduce(&state, .observed(connection: 1, observation: .dnsOnly, now: 1))
        _ = reduce(&state, .onDemandArmFinished(id: 1, confirmed: false))
        XCTAssertEqual(state.onDemandRepairConnection, 1)
        XCTAssertEqual(reduce(&state, .onDemandRepairRequested(connection: 1, startsNewObservation: false, now: 2)),
            [.ensureOnDemand(id: 2, connection: 1)])
    }

    func testMissingGenerationRepairCreatesANewEpochAndRejectsTheOldCompletion() {
        var state = Policy.State()
        _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0))
        _ = reduce(&state, .onDemandArmFinished(id: 1, confirmed: false))
        XCTAssertEqual(reduce(&state, .onDemandRepairRequested(connection: 1, startsNewObservation: true, now: 1)),
            [.startSampling(connection: 2), .ensureOnDemand(id: 2, connection: 2)])
        XCTAssertEqual(state.onDemandRepairConnection, 2)
        XCTAssertEqual(reduce(&state, .onDemandArmFinished(id: 1, confirmed: true)), [.reconcileProtectionStatus])
        XCTAssertEqual(reduce(&state, .onDemandRepairRequested(connection: 1, startsNewObservation: true, now: 2)), [])
        _ = reduce(&state, .onDemandArmFinished(id: 2, confirmed: false))
        XCTAssertEqual(reduce(&state, .onDemandRepairRequested(connection: 2, startsNewObservation: false, now: 3)),
            [.ensureOnDemand(id: 3, connection: 2)], "the stale completion did not confirm the new epoch")
    }

    func testMissingGenerationRepairSupersedesAPendingArmWithoutConfirmingTheNewEpoch() {
        var state = Policy.State()
        XCTAssertEqual(reduce(&state, .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0)),
            [.startSampling(connection: 1), .ensureOnDemand(id: 1, connection: 1)])
        XCTAssertEqual(reduce(&state, .onDemandRepairRequested(connection: 1, startsNewObservation: false, now: 1)), [],
            "an ordinary retry must not duplicate the pending current-epoch arm")
        XCTAssertEqual(reduce(&state, .onDemandRepairRequested(connection: 1, startsNewObservation: true, now: 1)),
            [.startSampling(connection: 2), .ensureOnDemand(id: 2, connection: 2)],
            "fresh saved-manager and durable-intent admission must replace the unusable pending epoch")
        XCTAssertEqual(state.onDemandRepairConnection, 2)
        XCTAssertEqual(reduce(&state, .onDemandArmFinished(id: 1, confirmed: true)), [.reconcileProtectionStatus])
        XCTAssertEqual(reduce(&state, .onDemandRepairRequested(connection: 1, startsNewObservation: true, now: 2)), [])
        XCTAssertEqual(reduce(&state, .onDemandRepairRequested(connection: 2, startsNewObservation: false, now: 2)), [])
        _ = reduce(&state, .onDemandArmFinished(id: 2, confirmed: false))
        XCTAssertEqual(reduce(&state, .onDemandRepairRequested(connection: 2, startsNewObservation: false, now: 3)),
            [.ensureOnDemand(id: 3, connection: 2)], "the replaced arm's success cannot confirm or consume the new token")
    }

    func testPendingArmEpochReplacementPreservesOffAndSuccessorRejection() {
        var state = Policy.State()
        _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0))
        _ = reduce(&state, .onDemandRepairRequested(connection: 1, startsNewObservation: true, now: 1))
        _ = reduce(&state, .teardownChanged(isActive: true))
        XCTAssertEqual(reduce(&state, .onDemandRepairRequested(connection: 2, startsNewObservation: true, now: 2)), [])
        XCTAssertEqual(reduce(&state, .onDemandArmFinished(id: 1, confirmed: true)), [.reconcileProtectionStatus])
        _ = reduce(&state, .statusChanged(.disconnected, onDemandConfirmed: false, userInitiated: false, now: 3))
        _ = reduce(&state, .teardownChanged(isActive: false))
        XCTAssertNil(state.onDemandRepairConnection)
        XCTAssertEqual(reduce(&state, .onDemandRepairRequested(connection: 2, startsNewObservation: true, now: 4)), [])
        XCTAssertEqual(reduce(&state, .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 5)),
            [.startSampling(connection: 3), .ensureOnDemand(id: 3, connection: 3)])
        XCTAssertEqual(reduce(&state, .onDemandArmFinished(id: 2, confirmed: true)), [.reconcileProtectionStatus])
        XCTAssertEqual(reduce(&state, .onDemandRepairRequested(connection: 2, startsNewObservation: true, now: 6)), [])
        _ = reduce(&state, .onDemandArmFinished(id: 3, confirmed: false))
        XCTAssertEqual(reduce(&state, .onDemandRepairRequested(connection: 3, startsNewObservation: false, now: 7)),
            [.ensureOnDemand(id: 4, connection: 3)], "an arm from before OFF/restart cannot confirm the successor")
    }

    func testForegroundRepairCannotArmDuringOffTeardownOrAfterDisconnect() {
        var state = Policy.State()
        _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0))
        _ = reduce(&state, .onDemandArmFinished(id: 1, confirmed: false))
        _ = reduce(&state, .teardownChanged(isActive: true))
        XCTAssertNil(state.onDemandRepairConnection)
        XCTAssertEqual(reduce(&state, .onDemandRepairRequested(connection: 1, startsNewObservation: true, now: 1)), [])
        _ = reduce(&state, .statusChanged(.disconnected, onDemandConfirmed: false, userInitiated: false, now: 2))
        _ = reduce(&state, .teardownChanged(isActive: false))
        XCTAssertNil(state.onDemandRepairConnection)
        XCTAssertEqual(reduce(&state, .onDemandRepairRequested(connection: 1, startsNewObservation: true, now: 3)), [])
    }


    func testVerifiedSetupResolvesOneStartWithoutClaimingForwarding() {
        var state = Policy.State()
        _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: true, userInitiated: true, now: 0))
        let ready = Observation.chained(session: .init(generation: 1, forwardedBytes: 0,
            transportGeneration: 1, setupReady: true))
        XCTAssertEqual(reduce(&state, .observed(connection: 1, observation: ready, now: 2)),
            [.resolveSetupReady(connection: 1, userInitiated: true)])
        XCTAssertTrue(state.setupReady)
        XCTAssertEqual(state.claim, .establishing, "Handshake is not forwarded traffic")
        XCTAssertEqual(reduce(&state, .observed(connection: 1, observation: ready, now: 30)), [])
        _ = reduce(&state, .successFeedbackFinished(connection: 1, retryWhenConfirmed: true))
        XCTAssertEqual(reduce(&state, .observed(connection: 1, observation: .chained(session: .init(
            generation: 1, forwardedBytes: 429, transportGeneration: 1,
            health: TunnelHealthSnapshot())), now: 31)),
            [.resolveDeferredSuccess(connection: 1, receivedByteDelta: 429)])
        XCTAssertEqual(state.claim, .confirmed)
        XCTAssertFalse(state.setupReady)
    }

    func testReadyPresentationPreservesTimeoutAndRecoveryArmRetry() {
        var state = Policy.State()
        _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0))
        let ready = Observation.chained(session: .init(generation: 1, forwardedBytes: 0,
            transportGeneration: 1, setupReady: true))
        _ = reduce(&state, .observed(connection: 1, observation: ready, now: 2))
        _ = reduce(&state, .onDemandArmFinished(id: 1, confirmed: false))
        XCTAssertEqual(reduce(&state, .observed(connection: 1, observation: ready, now: 16)),
            [.ensureOnDemand(id: 2, connection: 1)])
        XCTAssertEqual(state.claim, .unconfirmed)
        XCTAssertTrue(state.setupReady)
    }

    func testReadinessRevalidatesAfterObservationLossWithoutRetryingSuccess() {
        var state = Policy.State()
        _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: true, userInitiated: true, now: 0))
        let ready = Observation.chained(session: .init(generation: 1, forwardedBytes: 0,
            transportGeneration: 1, setupReady: true))
        _ = reduce(&state, .observed(connection: 1, observation: ready, now: 1))
        _ = reduce(&state, .observationSuspended(now: 1.5))
        XCTAssertFalse(state.setupReady)
        _ = reduce(&state, .observed(connection: 2, observation: ready, now: 2))
        XCTAssertFalse(state.setupReady, "Wrong connection cannot restore setup")
        _ = reduce(&state, .successFeedbackFinished(connection: 1, retryWhenConfirmed: true))
        XCTAssertEqual(reduce(&state, .observed(connection: 1, observation: ready, now: 3)), [])
        _ = reduce(&state, .observed(connection: 1, observation: nil, now: 4))
        XCTAssertFalse(state.setupReady)
        XCTAssertEqual(reduce(&state, .observed(connection: 1, observation: ready, now: 5)), [])
        XCTAssertTrue(state.setupReady)
    }

    func testLegacyReboundMissingAndRegressedEvidenceNeverAnnouncesSetupReady() {
        for transport: UInt64 in [0, 2] {
            var state = Policy.State()
            _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: true, userInitiated: true, now: 0))
            _ = reduce(&state, .observed(connection: 1, observation: .chained(session: .init(
                generation: 1, forwardedBytes: 0, transportGeneration: transport, setupReady: true)), now: 1))
            XCTAssertFalse(state.setupReady)
        }
        for lost in [false, true] {
            var state = Policy.State()
            _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: true, userInitiated: false, now: 0))
            _ = reduce(&state, .observed(connection: 1, observation: .chained(session: .init(
                generation: 1, forwardedBytes: 42, transportGeneration: 1)), now: 1))
            if lost { _ = reduce(&state, .observed(connection: 1, observation: .chained(session: nil), now: 2)) }
            _ = reduce(&state, .observed(connection: 1, observation: .chained(session: .init(
                generation: 1, forwardedBytes: 0, transportGeneration: 1, setupReady: true)), now: 3))
            XCTAssertFalse(state.setupReady)
            XCTAssertNotEqual(state.claim, .confirmed)
        }
    }

    func testReadinessAfterTimeoutSharesSuccessAndOrdinaryStartsStaySilent() {
        for userInitiated in [false, true] {
            var state = Policy.State()
            _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: true, userInitiated: userInitiated, now: 0))
            _ = reduce(&state, .observed(connection: 1, observation: session(1, 0), now: 16))
            let effects = reduce(&state, .observed(connection: 1, observation: .chained(session: .init(
                generation: 1, forwardedBytes: 0, transportGeneration: 1, setupReady: true)), now: 17))
            XCTAssertTrue(state.setupReady)
            XCTAssertEqual(effects, [])
            let forwarded = reduce(&state, .observed(connection: 1, observation: .chained(session: .init(
                generation: 1, forwardedBytes: 42, transportGeneration: 1,
                health: TunnelHealthSnapshot())), now: 18))
            XCTAssertEqual(forwarded, userInitiated ? [.resolveDeferredSuccess(connection: 1, receivedByteDelta: 42)] : [])
            _ = reduce(&state, .teardownChanged(isActive: true))
            XCTAssertFalse(state.setupReady)
        }
    }

    func testIPCGapDoesNotEraseSameRunnerProof() {
        var state = Policy.State()
        _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: true, userInitiated: true, now: 0))
        _ = reduce(&state, .observed(connection: 1, observation: session(7, 42), now: 1))
        XCTAssertEqual(state.claim, .confirmed)
        _ = reduce(&state, .observed(connection: 1, observation: nil, now: 3600))
        XCTAssertEqual(state.claim, .checking, "missing replies cannot claim Protected or a new start")
        _ = reduce(&state, .observed(connection: 1, observation: nil, now: 3700))
        XCTAssertEqual(state.claim, .checking)
        let effects = reduce(&state, .observed(connection: 1, observation: session(7, 42), now: 3701))
        XCTAssertEqual(state.claim, .confirmed, "fresh current-runner reply retains its real cumulative proof")
        XCTAssertEqual(effects, [], "recovery must not repeat success haptics or initial resolution")
    }

    func testRunnerLossAfterIPCGapStillInvalidatesOldProof() {
        var state = Policy.State()
        _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: true, userInitiated: false, now: 0))
        _ = reduce(&state, .observed(connection: 1, observation: session(7, 42), now: 1))
        _ = reduce(&state, .observed(connection: 1, observation: nil, now: 2))
        _ = reduce(&state, .observed(connection: 1, observation: .chained(session: nil), now: 3))
        _ = reduce(&state, .observed(connection: 1, observation: session(7, 42), now: 4))
        XCTAssertEqual(state.claim, .establishing)
        _ = reduce(&state, .observed(connection: 1, observation: session(7, 43), now: 5))
        XCTAssertEqual(state.claim, .confirmed)
    }

    func testReplacementAndCounterRegressionAfterIPCGapCannotReuseProof() {
        for observation in [session(8, 0), session(7, 20)] {
            var state = Policy.State()
            _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: true, userInitiated: false, now: 0))
            _ = reduce(&state, .observed(connection: 1, observation: session(7, 42), now: 1))
            _ = reduce(&state, .observed(connection: 1, observation: nil, now: 2))
            _ = reduce(&state, .observed(connection: 1, observation: observation, now: 3))
            XCTAssertEqual(state.claim, .establishing)
            _ = reduce(&state, .observed(connection: 1, observation: observation, now: 18))
            XCTAssertEqual(state.claim, .unconfirmed)
        }
    }

    func testEveryConnectedEpochSamplesRuntimeModeAndDNSOnlyConfirmsImmediately() {
        var state = Policy.State()

        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(.connected, onDemandConfirmed: false, userInitiated: true, now: 10)),
            [
                .startSampling(connection: 1),
                .ensureOnDemand(id: 1, connection: 1),
            ])
        XCTAssertEqual(state.claim, .establishing)

        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: .dnsOnly, now: 10.1)),
            [
                .stopSampling,
                .resolveInitialClaim(
                    connection: 1, confirmed: true, userInitiated: true,
                    receivedByteDelta: nil),
            ])
        XCTAssertEqual(state.claim, .confirmed)

        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(.disconnected, onDemandConfirmed: true, userInitiated: false, now: 11)),
            [])
        XCTAssertEqual(state.claim, .inactive)

        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(.connected, onDemandConfirmed: true, userInitiated: false, now: 12)),
            [.startSampling(connection: 2)])
        XCTAssertEqual(
            reduce(
                &state,
                .observed(connection: 2, observation: .chained(session: nil), now: 12.1)),
            [])
        XCTAssertEqual(
            state.claim, .establishing,
            "the actual runtime reply, not a mutable future preference, decides the live mode")
    }

    func testRunnerlessChainedAndMissingIPCRemainConservativeThroughTheDeadline() {
        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 100))

        XCTAssertEqual(
            reduce(
                &state,
                .observed(connection: 1, observation: .chained(session: nil), now: 114.999)),
            [])
        XCTAssertEqual(state.claim, .establishing)
        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: nil, now: 115)),
            [
                .resolveInitialClaim(
                    connection: 1, confirmed: false, userInitiated: false,
                    receivedByteDelta: nil)
            ])
        XCTAssertEqual(state.claim, .unconfirmed)

        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: .inactive, now: 130)), [])
        XCTAssertEqual(
            state.claim, .unconfirmed,
            "missing IPC and an inactive runtime are never evidence of DNS-only protection")
    }

    func testInitialResolutionCarriesTheExactCurrentForwardingDeltaForDiagnostics() {
        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: true, userInitiated: false, now: 0))

        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(5, 0), now: 15)),
            [
                .resolveInitialClaim(
                    connection: 1, confirmed: false, userInitiated: false,
                    receivedByteDelta: 0)
            ])
    }

    func testMissingDeadlineSampleDoesNotReplayAnEarlierForwardingDeltaForDiagnostics() {
        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: true, userInitiated: false, now: 0))

        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(5, 0), now: 14)),
            [])
        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: nil, now: 15)),
            [
                .resolveInitialClaim(
                    connection: 1, confirmed: false, userInitiated: false,
                    receivedByteDelta: nil)
            ],
            "an IPC miss at the deadline must describe that poll, not replay prior evidence")
    }

    func testConfirmedChainKeepsSamplingAndRunnerLossRevokesUntilFreshEvidence() {
        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: true, userInitiated: true, now: 0))

        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(7, 1), now: 1)),
            [
                .resolveInitialClaim(
                    connection: 1, confirmed: true, userInitiated: true,
                    receivedByteDelta: 1)
            ])
        XCTAssertEqual(state.claim, .confirmed)
        XCTAssertEqual(state.samplingConnection, 1, "confirmed chained sessions stay monitored")

        XCTAssertEqual(
            reduce(
                &state,
                .observed(connection: 1, observation: .chained(session: nil), now: 2)),
            [])
        XCTAssertEqual(state.claim, .establishing)

        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(7, 1), now: 3)), [])
        XCTAssertEqual(
            state.claim, .establishing,
            "the same old watermark returning after runner loss is not fresh forwarding")

        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(8, 4), now: 4)), [])
        XCTAssertEqual(
            state.claim, .confirmed,
            "a new generation with positive bytes may prove itself in its first observation")
    }

    func testSameGenerationCounterRegressionRequiresANewIncreaseBeforeReconfirming() {
        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: true, userInitiated: false, now: 0))
        _ = reduce(&state, .observed(connection: 1, observation: session(7, 10), now: 1))
        XCTAssertEqual(state.claim, .confirmed)

        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(7, 5), now: 2)), [])
        XCTAssertEqual(state.claim, .establishing)
        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(7, 5), now: 3)), [])
        XCTAssertEqual(state.claim, .establishing)

        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(7, 6), now: 4)), [])
        XCTAssertEqual(state.claim, .confirmed)
    }

    func testZeroByteNewGenerationImmediatelyRevokesConfirmedClaim() {
        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: true, userInitiated: false, now: 0))
        _ = reduce(&state, .observed(connection: 1, observation: session(7, 10), now: 1))
        XCTAssertEqual(state.claim, .confirmed)

        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(8, 0), now: 2)), [])
        XCTAssertEqual(state.claim, .establishing)
        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(8, 0), now: 17)), [])
        XCTAssertEqual(
            state.claim, .unconfirmed,
            "a replacement generation with no forwarding must re-gate without replaying initial effects")

        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(8, 1), now: 18)), [])
        XCTAssertEqual(state.claim, .confirmed)
    }

    func testFailedTeardownResumesTheSameConservativeConnectionWithoutErasingEvidence() {
        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0))
        _ = reduce(
            &state,
            .observed(connection: 1, observation: .chained(session: nil), now: 15))
        XCTAssertEqual(state.claim, .unconfirmed)

        XCTAssertEqual(reduce(&state, .teardownChanged(isActive: true)), [.stopSampling])
        XCTAssertEqual(state.claim, .unconfirmed)
        XCTAssertNil(state.samplingConnection)

        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: .dnsOnly, now: 16)), [])
        XCTAssertEqual(
            state.claim, .unconfirmed,
            "a callback already in flight cannot green the UI while teardown owns the lifecycle")

        XCTAssertEqual(
            reduce(&state, .teardownChanged(isActive: false)), [.startSampling(connection: 1)])
        XCTAssertEqual(state.claim, .unconfirmed)
        XCTAssertEqual(state.connection, 1)
    }

    func testTeardownPreservesTheRevokedSessionWatermarkUntilFreshBytesArrive() {
        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: true, userInitiated: false, now: 0))
        _ = reduce(&state, .observed(connection: 1, observation: session(7, 10), now: 1))
        XCTAssertEqual(state.claim, .confirmed)
        _ = reduce(
            &state,
            .observed(connection: 1, observation: .chained(session: nil), now: 2))
        XCTAssertEqual(state.claim, .establishing)

        XCTAssertEqual(reduce(&state, .teardownChanged(isActive: true)), [.stopSampling])
        XCTAssertEqual(
            reduce(&state, .teardownChanged(isActive: false)),
            [.startSampling(connection: 1)])

        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(7, 10), now: 3)), [])
        XCTAssertEqual(
            state.claim, .establishing,
            "resuming cannot treat the pre-suspension watermark as fresh forwarding")
        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(7, 11), now: 4)), [])
        XCTAssertEqual(state.claim, .confirmed)
    }

    func testUnconfirmedTerminalDropWaitsForTheExactOnDemandArmResult() {
        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0))
        let resolution = reduce(
            &state,
            .observed(connection: 1, observation: .chained(session: nil), now: 15))
        XCTAssertEqual(
            resolution,
            [
                .resolveInitialClaim(
                    connection: 1, confirmed: false, userInitiated: false,
                    receivedByteDelta: nil)
            ])

        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(.disconnecting, onDemandConfirmed: false, userInitiated: false, now: 16)),
            [.stopSampling])
        XCTAssertEqual(state.notice, .none)
        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(.disconnected, onDemandConfirmed: false, userInitiated: false, now: 17)),
            [])
        XCTAssertEqual(state.notice, .pending(connection: 1))

        XCTAssertEqual(
            reduce(&state, .onDemandArmFinished(id: 999, confirmed: false)),
            [.reconcileProtectionStatus])
        XCTAssertEqual(
            state.notice, .pending(connection: 1),
            "a stale completion cannot publish or clear another connection's owned notice")

        XCTAssertEqual(
            reduce(&state, .onDemandArmFinished(id: 1, confirmed: false)),
            [.reconcileProtectionStatus])
        XCTAssertEqual(state.notice, .visible(connection: 1))
    }

    func testConfirmedOnDemandClearsOnlyTheReducerOwnedVanishNotice() {
        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0))
        _ = reduce(
            &state,
            .observed(connection: 1, observation: .chained(session: nil), now: 15))
        _ = reduce(
            &state,
            .statusChanged(.disconnected, onDemandConfirmed: false, userInitiated: false, now: 16))
        XCTAssertEqual(state.notice, .pending(connection: 1))

        XCTAssertEqual(
            reduce(&state, .onDemandArmFinished(id: 1, confirmed: true)),
            [.reconcileProtectionStatus])
        XCTAssertEqual(state.notice, .none)

        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(.disconnected, onDemandConfirmed: true, userInitiated: false, now: 17)),
            [])
        XCTAssertEqual(state.notice, .none)
    }

    func testInvalidTerminalStatusCannotHideAVanishNoticeBehindStaleOnDemandState() {
        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0))
        _ = reduce(
            &state,
            .observed(connection: 1, observation: .chained(session: nil), now: 15))
        XCTAssertEqual(state.claim, .unconfirmed)
        _ = reduce(&state, .onDemandArmFinished(id: 1, confirmed: true))

        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(.invalid, onDemandConfirmed: true, userInitiated: false, now: 16)),
            [.stopSampling])
        XCTAssertEqual(
            state.notice, .visible(connection: 1),
            "invalid means no loaded profile can recover even when the persisted arm bit is stale")

        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(.invalid, onDemandConfirmed: true, userInitiated: false, now: 17)),
            [])
        XCTAssertEqual(
            state.notice, .visible(connection: 1),
            "repeated invalid reconciliation cannot clear the failure notice with a stale arm bit")
    }

    func testArmSuccessCannotHideAVanishNoticeAfterTheProfileBecomesInvalid() {
        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0))
        _ = reduce(
            &state,
            .observed(connection: 1, observation: .chained(session: nil), now: 15))
        XCTAssertEqual(state.claim, .unconfirmed)

        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(.invalid, onDemandConfirmed: false, userInitiated: false, now: 16)),
            [.stopSampling])
        XCTAssertEqual(state.notice, .pending(connection: 1))

        XCTAssertEqual(
            reduce(&state, .onDemandArmFinished(id: 1, confirmed: true)),
            [.reconcileProtectionStatus])
        XCTAssertEqual(
            state.notice, .visible(connection: 1),
            "a completed save cannot recover an invalid profile, so the failure stays visible")

        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(
                    .disconnected, onDemandConfirmed: true, userInitiated: false, now: 17)),
            [])
        XCTAssertEqual(
            state.notice, .none,
            "a later disconnected-and-confirmed reconciliation establishes real recovery")
    }

    func testExplicitTeardownClearsAnOwnedVanishNoticeWhileAlreadyTerminal() {
        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0))
        _ = reduce(
            &state,
            .observed(connection: 1, observation: .chained(session: nil), now: 15))
        _ = reduce(
            &state,
            .statusChanged(.invalid, onDemandConfirmed: false, userInitiated: false, now: 16))
        _ = reduce(&state, .onDemandArmFinished(id: 1, confirmed: false))
        XCTAssertEqual(state.notice, .visible(connection: 1))

        XCTAssertEqual(reduce(&state, .teardownChanged(isActive: true)), [])
        XCTAssertEqual(
            state.notice, .none,
            "an intentional turn-off owns its own non-error surface and dismisses the stale failure")
        XCTAssertEqual(reduce(&state, .teardownChanged(isActive: false)), [])
        XCTAssertEqual(state.notice, .none)
    }

    func testIntentionalRestartPulseSuppressesPendingAndFailedArmNoticeAndReplacementStarts() {
        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0))
        _ = reduce(
            &state,
            .observed(connection: 1, observation: .chained(session: nil), now: 15))
        XCTAssertEqual(state.claim, .unconfirmed)

        XCTAssertEqual(reduce(&state, .teardownChanged(isActive: true)), [.stopSampling])
        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(
                    .disconnecting, onDemandConfirmed: false, userInitiated: false, now: 16)),
            [])
        XCTAssertEqual(reduce(&state, .teardownChanged(isActive: false)), [])
        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(
                    .disconnected, onDemandConfirmed: false, userInitiated: false, now: 17)),
            [])
        XCTAssertEqual(state.notice, .none)

        XCTAssertEqual(
            reduce(&state, .onDemandArmFinished(id: 1, confirmed: false)),
            [.reconcileProtectionStatus])
        XCTAssertEqual(
            state.notice, .none,
            "a failed arm from the intentionally replaced connection cannot publish a vanish notice")

        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 20)),
            [
                .startSampling(connection: 2),
                .ensureOnDemand(id: 2, connection: 2),
            ],
            "the teardown pulse ends with the outbound reduction, so the replacement still starts")
        XCTAssertEqual(state.notice, .none)
        XCTAssertEqual(state.claim, .establishing)
    }

    func testConfirmedOnDemandSuppressesTheNoticeForARecoverableDisconnectedStatus() {
        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: true, userInitiated: false, now: 0))
        _ = reduce(
            &state,
            .observed(connection: 1, observation: .chained(session: nil), now: 15))
        XCTAssertEqual(state.claim, .unconfirmed)

        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(
                    .disconnected,
                    onDemandConfirmed: true,
                    userInitiated: false,
                    now: 16)),
            [.stopSampling])
        XCTAssertEqual(state.notice, .none)
    }

    func testLateForwardingCompletesTheExplicitStartOnce() {
        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: false, userInitiated: true, now: 0))
        _ = reduce(
            &state,
            .observed(connection: 1, observation: session(4, 0), now: 15))
        XCTAssertEqual(state.claim, .unconfirmed)

        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(4, 1), now: 40)),
            [.resolveDeferredSuccess(connection: 1, receivedByteDelta: 1)])
        XCTAssertEqual(state.claim, .confirmed)
        XCTAssertEqual(reduce(&state, .observed(connection: 1, observation: session(4, 2), now: 45)), [])
        _ = reduce(&state, .successFeedbackFinished(connection: 1, retryWhenConfirmed: false))
        _ = reduce(&state, .observed(connection: 1, observation: nil, now: 50))
        XCTAssertEqual(reduce(&state, .observed(connection: 1, observation: session(4, 2), now: 51)), [])
    }

    func testLateProofForAnObservedConnectionHasNoUserSuccess() {
        var state = Policy.State()
        _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: true, userInitiated: false, now: 0))
        _ = reduce(&state, .observed(connection: 1, observation: session(4, 0), now: 15))
        XCTAssertEqual(reduce(&state, .observed(connection: 1, observation: session(4, 20), now: 40)), [])
        XCTAssertEqual(state.claim, .confirmed)
    }

    func testSuccessDeliveryWaitsForAcknowledgementAndRetriesAfterTemporaryClaimLoss() {
        var state = Policy.State()
        _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: true, userInitiated: true, now: 0))
        _ = reduce(&state, .observed(connection: 1, observation: session(4, 1), now: 1))
        // The asynchronous fence is still waiting. A poll cannot dispatch a second delivery.
        XCTAssertEqual(reduce(&state, .observed(connection: 1, observation: session(4, 2), now: 2)), [])
        _ = reduce(&state, .observed(connection: 1, observation: nil, now: 3))
        _ = reduce(&state, .successFeedbackFinished(connection: 1, retryWhenConfirmed: true))
        XCTAssertEqual(reduce(&state, .observed(connection: 1, observation: session(4, 2), now: 4)),
                       [.resolveDeferredSuccess(connection: 1, receivedByteDelta: 2)])
        _ = reduce(&state, .successFeedbackFinished(connection: 1, retryWhenConfirmed: false))
        _ = reduce(&state, .observed(connection: 1, observation: nil, now: 5))
        XCTAssertEqual(reduce(&state, .observed(connection: 1, observation: session(4, 2), now: 6)), [])
    }

    func testSupersededSuccessCannotRetryAcrossOffOrReplaceTheNextConnectionsAttempt() {
        var state = Policy.State()
        _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: true, userInitiated: true, now: 0))
        _ = reduce(&state, .observed(connection: 1, observation: session(4, 1), now: 1))
        _ = reduce(&state, .statusChanged(.disconnected, onDemandConfirmed: false, userInitiated: false, now: 2))
        _ = reduce(&state, .successFeedbackFinished(connection: 1, retryWhenConfirmed: true))
        XCTAssertEqual(reduce(&state, .observed(connection: 1, observation: session(4, 2), now: 3)), [])
        _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: true, userInitiated: true, now: 4))
        _ = reduce(&state, .observed(connection: 2, observation: session(5, 1), now: 5))
        _ = reduce(&state, .successFeedbackFinished(connection: 1, retryWhenConfirmed: true))
        XCTAssertEqual(reduce(&state, .observed(connection: 2, observation: session(5, 2), now: 6)), [])
        _ = reduce(&state, .successFeedbackFinished(connection: 2, retryWhenConfirmed: false))
        XCTAssertEqual(reduce(&state, .observed(connection: 2, observation: session(5, 3), now: 7)), [])
    }

    func testReboundTransportAcceptsItsFirstAlreadyForwardedSample() {
        var state = Policy.State()
        _ = reduce(&state, .statusChanged(.connected, onDemandConfirmed: true, userInitiated: true, now: 0))
        _ = reduce(&state, .observed(connection: 1,
            observation: .chained(session: .init(generation: 7, forwardedBytes: 10_000, transportGeneration: 1)), now: 1))
        // Phone wake/handoff may finish forwarding on the new channel before the app polls.
        // Its smaller positive tally is fresh proof, not a baseline that requires another packet.
        XCTAssertEqual(reduce(&state, .observed(connection: 1,
            observation: .chained(session: .init(generation: 7, forwardedBytes: 42, transportGeneration: 2)), now: 60)), [])
        XCTAssertEqual(state.claim, .confirmed)
        _ = reduce(&state, .observed(connection: 1,
            observation: .chained(session: .init(generation: 7, forwardedBytes: 0, transportGeneration: 3)), now: 61))
        XCTAssertEqual(state.claim, .establishing, "a new empty transport cannot borrow the old proof")
    }

    func testOnDemandFailureBeforeEvidenceRetriesOnceAtInitialResolution() {
        var state = Policy.State()
        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0)),
            [
                .startSampling(connection: 1),
                .ensureOnDemand(id: 1, connection: 1),
            ])

        XCTAssertEqual(
            reduce(&state, .onDemandArmFinished(id: 1, confirmed: false)),
            [.reconcileProtectionStatus])
        XCTAssertEqual(
            reduce(
                &state,
                .observed(connection: 1, observation: .chained(session: nil), now: 15)),
            [
                .resolveInitialClaim(
                    connection: 1, confirmed: false, userInitiated: false,
                    receivedByteDelta: nil),
                .ensureOnDemand(id: 2, connection: 1),
            ])
        XCTAssertEqual(state.claim, .unconfirmed)

        XCTAssertEqual(
            reduce(&state, .onDemandArmFinished(id: 2, confirmed: false)),
            [.reconcileProtectionStatus])
        XCTAssertEqual(
            reduce(
                &state,
                .observed(connection: 1, observation: .chained(session: nil), now: 16)),
            [],
            "an unchanged unconfirmed poll is not a meaningful retry transition")
    }

    func testStaleArmFailureCannotReopenOrDuplicateTheLiveAttempt() {
        var state = Policy.State()
        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0)),
            [
                .startSampling(connection: 1),
                .ensureOnDemand(id: 1, connection: 1),
            ])

        XCTAssertEqual(
            reduce(&state, .onDemandArmFinished(id: 999, confirmed: false)),
            [.reconcileProtectionStatus])
        XCTAssertEqual(
            reduce(
                &state,
                .observed(connection: 1, observation: .chained(session: nil), now: 15)),
            [
                .resolveInitialClaim(
                    connection: 1, confirmed: false, userInitiated: false,
                    receivedByteDelta: nil)
            ],
            "a stale failure cannot reopen eligibility while the exact arm is still pending")
        XCTAssertEqual(state.claim, .unconfirmed)
    }

    func testFailedArmAfterUnconfirmedRetriesOnlyOnLatePromotion() {
        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0))
        _ = reduce(&state, .observed(connection: 1, observation: session(9, 0), now: 15))
        XCTAssertEqual(state.claim, .unconfirmed)

        XCTAssertEqual(
            reduce(&state, .onDemandArmFinished(id: 1, confirmed: false)),
            [.reconcileProtectionStatus])
        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(9, 0), now: 20)), [])
        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(9, 1), now: 40)),
            [.ensureOnDemand(id: 2, connection: 1)])
        XCTAssertEqual(state.claim, .confirmed)

        XCTAssertEqual(
            reduce(&state, .onDemandArmFinished(id: 2, confirmed: false)),
            [.reconcileProtectionStatus])
        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(9, 1), now: 45)), [],
            "a failed promotion retry does not become one retry per sampling tick")
    }

    func testFailedArmRetriesWhenAReplacementGenerationImmediatelyReconfirms() {
        var state = Policy.State()
        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0)),
            [
                .startSampling(connection: 1),
                .ensureOnDemand(id: 1, connection: 1),
            ])
        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(7, 1), now: 1)),
            [
                .resolveInitialClaim(
                    connection: 1, confirmed: true, userInitiated: false,
                    receivedByteDelta: 1)
            ])
        XCTAssertEqual(state.claim, .confirmed)

        XCTAssertEqual(
            reduce(&state, .onDemandArmFinished(id: 1, confirmed: false)),
            [.reconcileProtectionStatus])
        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(7, 2), now: 2)),
            [],
            "an unchanged confirmed session cannot turn a reopened arm into a polling loop")

        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(8, 1), now: 3)),
            [.ensureOnDemand(id: 2, connection: 1)],
            "a replacement identity is a meaningful re-gate even when its first sample has bytes")
        XCTAssertEqual(state.claim, .confirmed)
    }

    func testDropInsideEvidenceWindowStillHasAPendingRecoveryArmToReconcile() {
        var state = Policy.State()
        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0)),
            [
                .startSampling(connection: 1),
                .ensureOnDemand(id: 1, connection: 1),
            ])

        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(.disconnected, onDemandConfirmed: false, userInitiated: false, now: 1)),
            [.stopSampling])
        XCTAssertEqual(state.notice, .none, "only a resolved-unconfirmed drop owns a vanish notice")
        XCTAssertEqual(
            reduce(&state, .onDemandArmFinished(id: 1, confirmed: true)),
            [.reconcileProtectionStatus])
        XCTAssertEqual(state.notice, .none)
    }

    func testRepeatedAndStaleEventsAreIdempotent() {
        var state = Policy.State()
        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(.connected, onDemandConfirmed: true, userInitiated: false, now: 0)),
            [.startSampling(connection: 1)])
        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(.connected, onDemandConfirmed: true, userInitiated: true, now: 1)),
            [])
        XCTAssertEqual(state.connection, 1)

        XCTAssertEqual(
            reduce(&state, .observed(connection: 99, observation: .dnsOnly, now: 2)), [])
        XCTAssertEqual(state.claim, .establishing)
        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(3, 1), now: 3)),
            [
                .resolveInitialClaim(
                    connection: 1, confirmed: true, userInitiated: false,
                    receivedByteDelta: 1)
            ])
        XCTAssertEqual(
            reduce(&state, .observed(connection: 1, observation: session(3, 1), now: 4)), [])
        XCTAssertEqual(state.claim, .confirmed)
    }

    func testNewConnectionClearsAnOwnedNoticeAndGetsANewIdentity() {
        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0))
        _ = reduce(
            &state,
            .observed(connection: 1, observation: .chained(session: nil), now: 15))
        _ = reduce(&state, .onDemandArmFinished(id: 1, confirmed: false))
        _ = reduce(
            &state,
            .statusChanged(.disconnected, onDemandConfirmed: false, userInitiated: false, now: 16))
        XCTAssertEqual(state.notice, .visible(connection: 1))

        XCTAssertEqual(
            reduce(
                &state,
                .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 20)),
            [
                .startSampling(connection: 2),
                .ensureOnDemand(id: 2, connection: 2),
            ])
        XCTAssertEqual(state.notice, .none)
        XCTAssertEqual(state.connection, 2)
    }

    func testReducerUsesTheSharedEstablishmentPolicyLimits() {
        let timeout = ChainedEstablishmentPolicy.defaultTimeoutSeconds
        let threshold = ChainedEstablishmentPolicy.forwardingConfirmedByteThreshold
        XCTAssertGreaterThan(threshold, 0)
        XCTAssertEqual(Policy.establishmentTimeoutSeconds, timeout)

        var state = Policy.State()
        _ = reduce(
            &state,
            .statusChanged(.connected, onDemandConfirmed: true, userInitiated: false, now: 0))

        XCTAssertEqual(
            reduce(
                &state,
                .observed(
                    connection: 1,
                    observation: session(1, threshold - 1),
                    now: timeout - 0.001)),
            [])
        XCTAssertEqual(state.claim, .establishing)
        XCTAssertEqual(
            reduce(
                &state,
                .observed(
                    connection: 1,
                    observation: session(1, threshold - 1),
                    now: timeout)),
            [
                .resolveInitialClaim(
                    connection: 1, confirmed: false, userInitiated: false,
                    receivedByteDelta: threshold - 1)
            ])
        XCTAssertEqual(state.claim, .unconfirmed)

        XCTAssertEqual(
            reduce(
                &state,
                .observed(
                    connection: 1,
                    observation: session(1, threshold),
                    now: timeout + 1)),
            [])
        XCTAssertEqual(state.claim, .confirmed)
    }

    private func session(_ generation: UInt64, _ forwardedBytes: UInt64) -> Observation {
        .chained(session: .init(generation: generation, forwardedBytes: forwardedBytes,
            health: TunnelHealthSnapshot()))
    }

    @discardableResult
    private func reduce(_ state: inout Policy.State, _ event: Policy.Event) -> [Policy.Effect] {
        Policy.reduce(state: &state, event: event)
    }
}
