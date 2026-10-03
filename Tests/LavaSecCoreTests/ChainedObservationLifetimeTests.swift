import XCTest
@testable import LavaSecCore

final class ChainedObservationLifetimeTests: XCTestCase {
    private typealias Policy = ChainedConnectLifecyclePolicy

    func testWakeDiscardsExpiredTimeoutBeforeOrAfterTheFreshReplyWithoutClaimOrFeedbackChanges() throws {
        for timeoutArrivesFirst in [true, false] {
            var lifetime = ChainedObservationLifetime()
            lifetime.setActive(true)
            let suspendedQuery = try XCTUnwrap(lifetime.beginSampling())
            var state = Policy.State()
            Policy.reduce(state: &state, event:
                .statusChanged(.connected, onDemandConfirmed: true, userInitiated: true, now: 0))
            Policy.reduce(state: &state, event:
                .observed(connection: 1, observation: .chained(session:
                    .init(generation: 4, forwardedBytes: 9106, transportGeneration: 1)), now: 1))
            Policy.reduce(state: &state, event:
                .successFeedbackFinished(connection: 1, retryWhenConfirmed: false))
            let confirmedState = state

            lifetime.setActive(false)
            lifetime.setActive(true)
            let freshQuery = try XCTUnwrap(lifetime.beginSampling())
            XCTAssertFalse(lifetime.accepts(suspendedQuery))
            XCTAssertTrue(lifetime.accepts(freshQuery))
            let currentReply = ChainedHandshakeStatus(
                isChained: true, hasHandshake: true, everHandshaked: true,
                receivedByteCount: 9106, sessionGeneration: 4, transportGeneration: 1)
            let replies: [(UInt64, ChainedHandshakeStatus?)] = timeoutArrivesFirst
                ? [(suspendedQuery, nil), (freshQuery, currentReply)]
                : [(freshQuery, currentReply), (suspendedQuery, nil)]
            for (token, reply) in replies {
                guard lifetime.accepts(token) else { continue }
                let effects = Policy.reduce(state: &state, event:
                    .observed(connection: 1, observation: roundTripObservation(reply), now: 3600))
                XCTAssertEqual(effects, [], "Ordinary wake cannot replay explicit-start success.")
                XCTAssertEqual(state.projection, confirmedState.projection,
                               "A fresh unchanged runner retains its proof; the expired timeout is not an observation.")
            }
            XCTAssertEqual(state.projection, confirmedState.projection)
            XCTAssertEqual(state.lastAcceptedAt, 3600, "A newly admitted identical sample refreshes freshness")
        }
    }

    func testWakeRejectsStalePositiveProofButAdmitsFreshTransportLossAndLaterForwarding() throws {
        var lifetime = ChainedObservationLifetime()
        lifetime.setActive(true)
        let suspendedQuery = try XCTUnwrap(lifetime.beginSampling())
        var state = Policy.State()
        Policy.reduce(state: &state, event:
            .statusChanged(.connected, onDemandConfirmed: true, userInitiated: false, now: 0))
        Policy.reduce(state: &state, event:
            .observed(connection: 1, observation: .chained(session:
                .init(generation: 4, forwardedBytes: 9106, transportGeneration: 1)), now: 1))
        XCTAssertEqual(state.claim, .confirmed)

        lifetime.setActive(false)
        lifetime.setActive(true)
        let freshQuery = try XCTUnwrap(lifetime.beginSampling())
        let replacement = ChainedHandshakeStatus(
            isChained: true, hasHandshake: true, everHandshaked: true,
            receivedByteCount: 0, sessionGeneration: 4, transportGeneration: 2)
        XCTAssertTrue(lifetime.accepts(freshQuery))
        Policy.reduce(state: &state, event:
            .observed(connection: 1, observation: roundTripObservation(replacement), now: 3600))
        XCTAssertEqual(state.claim, .establishing,
                       "Visibility admission cannot carry old forwarding proof into a fresh empty transport.")

        let staleProof = ChainedHandshakeStatus(
            isChained: true, hasHandshake: true, everHandshaked: true,
            receivedByteCount: 9106, sessionGeneration: 4, transportGeneration: 1)
        XCTAssertFalse(lifetime.accepts(suspendedQuery))
        if lifetime.accepts(suspendedQuery) {
            Policy.reduce(state: &state, event:
                .observed(connection: 1, observation: roundTripObservation(staleProof), now: 3601))
        }
        XCTAssertEqual(state.claim, .establishing)
        Policy.reduce(state: &state, event:
            .observed(connection: 1, observation: roundTripObservation(replacement), now: 3615))
        XCTAssertEqual(state.claim, .unconfirmed)

        let forwarded = ChainedHandshakeStatus(
            isChained: true, hasHandshake: true, everHandshaked: true,
            receivedByteCount: 360, sessionGeneration: 4, transportGeneration: 2)
        let effects = Policy.reduce(state: &state, event:
            .observed(connection: 1, observation: roundTripObservation(forwarded), now: 3620))
        XCTAssertEqual(state.claim, .confirmed)
        XCTAssertEqual(effects, [], "A wake recovery is not an explicit start success.")
    }

    func testRecordedRestartHandshakeDoesNotProveForwardingOrCelebrateWithoutHealth() {
        // Aggregate boundaries from the sanitized r15 restart receipt. This replay
        // pins observed inputs; it does not explain whether routed traffic was attempted.
        var state = Policy.State()
        Policy.reduce(state: &state, event:
            .statusChanged(.connected, onDemandConfirmed: true, userInitiated: true, now: 0))
        let handshakeOnly = ChainedHandshakeStatus(
            isChained: true, hasHandshake: true, everHandshaked: true,
            receivedByteCount: 0, sessionGeneration: 5, transportGeneration: 1)
        Policy.reduce(state: &state, event:
            .observed(connection: 1, observation: roundTripObservation(handshakeOnly), now: 2.719))
        XCTAssertEqual(state.claim, .establishing)
        XCTAssertEqual(Policy.reduce(state: &state, event:
            .observed(connection: 1, observation: roundTripObservation(handshakeOnly), now: 15.446)), [
                .resolveInitialClaim(connection: 1, confirmed: false,
                                     userInitiated: true, receivedByteDelta: 0),
            ])
        XCTAssertEqual(state.claim, .unconfirmed)
        Policy.reduce(state: &state, event:
            .successFeedbackFinished(connection: 1, retryWhenConfirmed: false))

        let forwarded = ChainedHandshakeStatus(
            isChained: true, hasHandshake: true, everHandshaked: true,
            receivedByteCount: 360, sessionGeneration: 5, transportGeneration: 1)
        XCTAssertEqual(Policy.reduce(state: &state, event:
            .observed(connection: 1, observation: roundTripObservation(forwarded), now: 36.085)), [], "Legacy traffic without health cannot retry success feedback")
        XCTAssertEqual(state.claim, .confirmed)
        Policy.reduce(state: &state, event:
            .successFeedbackFinished(connection: 1, retryWhenConfirmed: false))
        XCTAssertEqual(Policy.reduce(state: &state, event:
            .observed(connection: 1, observation: roundTripObservation(forwarded), now: 41.085)), [])
    }

    private func roundTripObservation(_ reply: ChainedHandshakeStatus?) -> ChainedRuntimeObservation? {
        ChainedRuntimeObservation.fromTunnelReply(ChainedHandshakeStatus.decode(reply?.encoded()))
    }

    func testInactiveLaunchCannotStartAnObservation() {
        var lifetime = ChainedObservationLifetime()
        XCTAssertNil(lifetime.beginSampling())
        XCTAssertFalse(lifetime.accepts(lifetime.generation))
    }

    func testQueuedPreBackgroundTimeoutCannotReachReducerAfterWake() throws {
        var lifetime = ChainedObservationLifetime()
        lifetime.setActive(true)
        let suspendedQuery = try XCTUnwrap(lifetime.beginSampling())
        lifetime.setActive(false)
        XCTAssertFalse(lifetime.accepts(suspendedQuery))
        lifetime.setActive(true)
        let freshQuery = try XCTUnwrap(lifetime.beginSampling())
        // Main-actor scheduling can deliver the expired continuation after the
        // new foreground sampler. Neither order makes the old timeout admissible.
        XCTAssertFalse(lifetime.accepts(suspendedQuery))
        XCTAssertTrue(lifetime.accepts(freshQuery))
        XCTAssertFalse(lifetime.accepts(suspendedQuery))
    }

    func testDuplicateActivationDoesNotDiscardAValidCurrentReply() throws {
        var lifetime = ChainedObservationLifetime()
        XCTAssertTrue(lifetime.setActive(true))
        let query = try XCTUnwrap(lifetime.beginSampling())
        XCTAssertFalse(lifetime.setActive(true))
        XCTAssertTrue(lifetime.accepts(query))
    }

    func testReplacementSamplerInvalidatesOldReplyForSameActiveConnection() throws {
        var lifetime = ChainedObservationLifetime()
        lifetime.setActive(true)
        let replaced = try XCTUnwrap(lifetime.beginSampling())
        let current = try XCTUnwrap(lifetime.beginSampling())
        XCTAssertFalse(lifetime.accepts(replaced))
        XCTAssertTrue(lifetime.accepts(current))
    }

    func testTeardownInvalidatesPendingReplyWithoutChangingVisibility() throws {
        var lifetime = ChainedObservationLifetime()
        lifetime.setActive(true)
        let pending = try XCTUnwrap(lifetime.beginSampling())
        lifetime.invalidateSampling()
        XCTAssertTrue(lifetime.isActive)
        XCTAssertFalse(lifetime.accepts(pending))
    }

    func testDNSOnlySamplerStopAndReplacementPreserveTheActivityGeneration() throws {
        var lifetime = ChainedObservationLifetime()
        lifetime.setActive(true)
        let activity = lifetime.activityGeneration
        let pending = try XCTUnwrap(lifetime.beginSampling())
        var state = Policy.State()
        _ = Policy.reduce(state: &state, event:
            .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0))
        let effects = Policy.reduce(state: &state, event:
            .observed(connection: 1, observation: .dnsOnly, now: 1))
        XCTAssertTrue(effects.contains(.stopSampling))
        lifetime.invalidateSampling()
        XCTAssertTrue(lifetime.isActive)
        XCTAssertFalse(lifetime.accepts(pending))
        XCTAssertEqual(lifetime.activityGeneration, activity,
            "Stopping DNS-only sampling cannot retire a foreground recovery request.")
        _ = lifetime.beginSampling()
        XCTAssertEqual(lifetime.activityGeneration, activity,
            "Replacing the sampler for an active connection is not a new activity interval.")
    }

    func testActivityGenerationChangesOnlyOnActualActivityEdges() {
        var lifetime = ChainedObservationLifetime()
        XCTAssertEqual(lifetime.activityGeneration, 0)
        XCTAssertFalse(lifetime.setActive(false))
        XCTAssertEqual(lifetime.activityGeneration, 0)
        XCTAssertTrue(lifetime.setActive(true))
        let foreground = lifetime.activityGeneration
        XCTAssertEqual(foreground, 1)
        XCTAssertFalse(lifetime.setActive(true))
        XCTAssertEqual(lifetime.activityGeneration, foreground)
        XCTAssertTrue(lifetime.setActive(false))
        XCTAssertEqual(lifetime.activityGeneration, foreground + 1)
        XCTAssertFalse(lifetime.setActive(false))
        XCTAssertEqual(lifetime.activityGeneration, foreground + 1)
        XCTAssertTrue(lifetime.setActive(true))
        XCTAssertEqual(lifetime.activityGeneration, foreground + 2,
            "A request from before backgrounding cannot be admitted merely because the app is active again.")
    }

    func testCurrentActiveIPCFailureStillReachesTheExistingCheckingPolicy() throws {
        var lifetime = ChainedObservationLifetime()
        lifetime.setActive(true)
        let query = try XCTUnwrap(lifetime.beginSampling())
        var state = ChainedConnectLifecyclePolicy.State()
        ChainedConnectLifecyclePolicy.reduce(state: &state, event:
            .statusChanged(.connected, onDemandConfirmed: true, userInitiated: false, now: 0))
        ChainedConnectLifecyclePolicy.reduce(state: &state, event:
            .observed(connection: 1, observation: .chained(session:
                .init(generation: 4, forwardedBytes: 9106, transportGeneration: 1)), now: 1))
        XCTAssertEqual(state.claim, .confirmed)
        if lifetime.accepts(query) {
            ChainedConnectLifecyclePolicy.reduce(state: &state, event:
                .observed(connection: 1, observation: nil, now: 3))
        }
        XCTAssertEqual(state.claim, .checking, "A genuine active IPC failure still revokes current confirmation immediately.")
    }
}
