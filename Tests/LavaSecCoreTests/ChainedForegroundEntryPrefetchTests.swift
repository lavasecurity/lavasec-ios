import XCTest
@testable import LavaSecKit

final class ChainedForegroundEntryPrefetchTests: XCTestCase {
    private typealias P = ChainedConnectLifecyclePolicy
    private typealias Entry = ChainedForegroundEntryPrefetch
    private let date = Date(timeIntervalSince1970: 10_000)

    private func sample(bytes: UInt64 = 42, ready: Bool = false, provider: String? = "provider-A",
                        runner: UInt64 = 1, transport: UInt64 = 1, epoch: UInt64? = 1,
                        baseline: UInt64 = 0, condition: ChainedRuntimeCondition = .normal,
                        healthy: Bool = true, includesHealth: Bool = true) -> ChainedRuntimeObservation {
        .chained(session: .init(generation: runner, forwardedBytes: bytes, transportGeneration: transport,
            setupReady: ready, providerLifecycleID: provider, verificationEpoch: epoch,
            forwardingBaseline: baseline, runtimeCondition: condition,
            health: includesHealth ? TunnelHealthSnapshot(startedAt: date, networkPathIsSatisfied: healthy) : nil,
            healthSampledAt: date))
    }

    private func settled(_ observation: ChainedRuntimeObservation? = nil, userInitiated: Bool = false) -> P.State {
        var state = P.State()
        P.reduce(state: &state, event: .statusChanged(.connected, onDemandConfirmed: true,
                                                    userInitiated: userInitiated, now: 0))
        P.reduce(state: &state, event: .observed(connection: 1, observation: observation ?? sample(), now: 1))
        if userInitiated {
            P.reduce(state: &state, event: .successFeedbackFinished(connection: 1, retryWhenConfirmed: false))
        }
        P.reduce(state: &state, event: .observationSuspended(now: 2))
        return state
    }

    private func status(_ state: P.State) -> ProtectionStatus {
        let p = state.projection
        return .resolve(lifecycle: .connected, chainedEstablishing: p.claim == .establishing,
            observationUnavailable: p.claim == .checking, forwardingUnconfirmed: p.claim == .unconfirmed,
            setupReady: p.setupReady, runtimeCondition: p.runtimeCondition, connectivity: p.connectivity)
    }

    /// The app's synchronous didBecomeActive ordering: consume first; a missing candidate runs
    /// the unchanged resume/expiry path. No continuation is awaited to make this decision.
    @discardableResult
    private func activate(_ entry: inout Entry, _ state: inout P.State, now: Double) -> [P.Effect] {
        if let candidate = entry.consume(connection: 1, identity: state.foregroundEntryIdentity, now: now) {
            return P.reduce(state: &state, event: .observed(connection: 1,
                observation: candidate.observation, now: candidate.receivedAt))
        }
        return P.reduce(state: &state, event: .observationResumed(now: now))
    }

    func testFreshEntryReplyPrecedesExpiredResumeWithoutPublishingUnavailableOrRepeatingFeedback() throws {
        for initial in [sample(), sample(bytes: 0, ready: true)] {
            var state = settled(initial, userInitiated: true)
            let expectedStatus = status(state)
            var entry = Entry()
            let token = entry.begin(connection: 1, identity: try XCTUnwrap(state.foregroundEntryIdentity), now: 100)
            let beforeStaging = state
            XCTAssertTrue(entry.stage(initial, for: token, now: 100.03))
            XCTAssertEqual(state, beforeStaging, "Inactive prefetch does not publish, reduce, or acknowledge")
            XCTAssertEqual(activate(&entry, &state, now: 100.10), [])
            XCTAssertEqual(status(state), expectedStatus)
            XCTAssertEqual(state.lastAcceptedAt, 100.03, "Activation must not renew the sample timestamp")
            XCTAssertNil(state.gapStartedAt, "A consumed fresh reply does not create another observation gap")
            XCTAssertNil(entry.consume(connection: 1, identity: state.foregroundEntryIdentity, now: 100.11))
        }
    }

    func testMissingOrLateReplyNeverBlocksActivationOrRestoresExpiredProof() throws {
        var state = settled()
        var entry = Entry()
        let token = entry.begin(connection: 1, identity: try XCTUnwrap(state.foregroundEntryIdentity), now: 100)
        XCTAssertEqual(activate(&entry, &state, now: 100.01), [])
        XCTAssertEqual(status(state), .unavailable)
        XCTAssertFalse(entry.stage(sample(), for: token, now: 100.03), "Activation retired the entry generation")
        XCTAssertEqual(status(state), .unavailable)
        P.reduce(state: &state, event: .observed(connection: 1, observation: sample(), now: 100.04))
        XCTAssertEqual(status(state), .connected(.healthy), "The normal active sampler remains authoritative")
    }

    func testEntryAndSampleBoundsAreAbsoluteAndDoNotExtendTenSecondEvidencePolicy() throws {
        let state = settled()
        let identity = try XCTUnwrap(state.foregroundEntryIdentity)
        for (received, activation) in [(100.1, 100.6), (101.9, 102.0), (100.1, 100.09)] {
            var entry = Entry()
            let token = entry.begin(connection: 1, identity: identity, now: 100)
            XCTAssertTrue(entry.stage(sample(), for: token, now: received))
            XCTAssertNil(entry.consume(connection: 1, identity: identity, now: activation))
        }
        for received in [99.9, 102.0, 1_000.0] {
            var entry = Entry()
            let token = entry.begin(connection: 1, identity: identity, now: 100)
            XCTAssertFalse(entry.stage(sample(), for: token, now: received))
        }
        XCTAssertLessThan(Entry.maximumEntryAge, P.maximumEvidenceAgeSeconds)
        XCTAssertEqual(P.maximumEvidenceAgeSeconds, 10)
        XCTAssertEqual(P.observationGraceSeconds, 3)
    }

    func testBackgroundAbortReplacementAndConnectionMismatchRetireStagedReplies() throws {
        let identity = try XCTUnwrap(settled().foregroundEntryIdentity)
        var entry = Entry()
        let aborted = entry.begin(connection: 1, identity: identity, now: 100)
        XCTAssertTrue(entry.stage(sample(), for: aborted, now: 100.01))
        entry.cancel()
        XCTAssertNil(entry.consume(connection: 1, identity: identity, now: 100.02))
        XCTAssertFalse(entry.stage(sample(), for: aborted, now: 100.03))
        let old = entry.begin(connection: 1, identity: identity, now: 101)
        let replacement = entry.begin(connection: 1, identity: identity, now: 101.01)
        XCTAssertFalse(entry.stage(sample(), for: old, now: 101.02))
        XCTAssertTrue(entry.stage(sample(), for: replacement, now: 101.03))
        XCTAssertNil(entry.consume(connection: 2, identity: identity, now: 101.04))
        XCTAssertFalse(entry.stage(sample(), for: replacement, now: 101.05))
    }

    func testIncompleteAndChangedIdentityCannotBorrowPreviouslyVerifiedEntry() throws {
        let identity = try XCTUnwrap(settled().foregroundEntryIdentity)
        let rejected: [ChainedRuntimeObservation?] = [nil, .inactive, .dnsOnly, .chained(session: nil),
            sample(provider: nil), sample(epoch: nil), sample(includesHealth: false),
            sample(provider: "provider-B"), sample(runner: 2), sample(transport: 2), sample(epoch: 2)]
        for observation in rejected {
            var entry = Entry()
            let token = entry.begin(connection: 1, identity: identity, now: 100)
            XCTAssertFalse(entry.stage(observation, for: token, now: 100.01))
            XCTAssertNil(entry.consume(connection: 1, identity: identity, now: 100.02))
        }
        var entry = Entry()
        let token = entry.begin(connection: 1, identity: identity, now: 100)
        XCTAssertTrue(entry.stage(sample(), for: token, now: 100.01))
        var changed = settled()
        P.reduce(state: &changed, event: .observed(connection: 1, observation: sample(provider: "provider-B"), now: 100.02))
        XCTAssertNil(entry.consume(connection: 1, identity: changed.foregroundEntryIdentity, now: 100.03))
    }

    func testCurrentAdverseEvidenceWinsAtActivationWithoutAnIntermediateHealthyClaim() throws {
        for (observation, expected) in [
            (sample(condition: .offline), ProtectionStatus.connected(.networkUnavailable)),
            (sample(condition: .recovering), .vpnRecovering),
            (sample(condition: .suspended), .unavailable),
            (sample(condition: .retired), .unavailable),
            (sample(healthy: false), .connected(.networkUnavailable))
        ] {
            var state = settled(userInitiated: true)
            var entry = Entry()
            let token = entry.begin(connection: 1, identity: try XCTUnwrap(state.foregroundEntryIdentity), now: 100)
            XCTAssertTrue(entry.stage(observation, for: token, now: 100.01))
            XCTAssertEqual(activate(&entry, &state, now: 100.02), [])
            XCTAssertEqual(status(state), expected)
        }
    }

    func testTrueWakeEpochFallsBackAndCannotConfirmUsingPreWakeCumulativeBytes() throws {
        var state = settled(sample(bytes: 100), userInitiated: true)
        var entry = Entry()
        let token = entry.begin(connection: 1, identity: try XCTUnwrap(state.foregroundEntryIdentity), now: 100)
        let wake = sample(bytes: 100, epoch: 2, baseline: 100)
        XCTAssertFalse(entry.stage(wake, for: token, now: 100.01))
        XCTAssertEqual(activate(&entry, &state, now: 100.02), [])
        XCTAssertEqual(status(state), .unavailable)
        P.reduce(state: &state, event: .observed(connection: 1, observation: wake, now: 100.03))
        XCTAssertNotEqual(state.claim, .confirmed)
        XCTAssertEqual(state.milestone, .none)
        let effects = P.reduce(state: &state, event: .observed(connection: 1,
            observation: sample(bytes: 101, epoch: 2, baseline: 100), now: 100.04))
        XCTAssertEqual(state.claim, .confirmed)
        XCTAssertEqual(effects, [], "Wake reconfirmation cannot create another success acknowledgement")
    }

    func testSameIdentityCounterRegressionIsNotHiddenByPrefetch() throws {
        var state = settled()
        var entry = Entry()
        let token = entry.begin(connection: 1, identity: try XCTUnwrap(state.foregroundEntryIdentity), now: 100)
        XCTAssertTrue(entry.stage(sample(bytes: 1), for: token, now: 100.01))
        _ = activate(&entry, &state, now: 100.02)
        XCTAssertNotEqual(state.claim, .confirmed)
        XCTAssertEqual(state.milestone, .none)
    }

    func testUnresolvedUserStartAndTeardownStayOnExistingActiveLane() {
        var state = P.State()
        P.reduce(state: &state, event: .statusChanged(.connected, onDemandConfirmed: true, userInitiated: true, now: 0))
        P.reduce(state: &state, event: .observed(connection: 1, observation: sample(), now: 1))
        XCTAssertNil(state.foregroundEntryIdentity)
        P.reduce(state: &state, event: .successFeedbackFinished(connection: 1, retryWhenConfirmed: false))
        XCTAssertNotNil(state.foregroundEntryIdentity)
        P.reduce(state: &state, event: .teardownChanged(isActive: true))
        XCTAssertNil(state.foregroundEntryIdentity)
    }
}
