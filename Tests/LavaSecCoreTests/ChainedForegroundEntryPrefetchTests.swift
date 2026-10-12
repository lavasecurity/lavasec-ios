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

    private func providerReply(_ publication: ProtectionStatusPublication, bytes: UInt64 = 101,
                               baseline: UInt64 = 100, condition: ChainedRuntimeCondition = .normal) -> ChainedHandshakeStatus {
        .init(isChained: true, hasHandshake: true, everHandshaked: true,
            receivedByteCount: bytes, sessionGeneration: publication.sessionGeneration ?? 1,
            transportGeneration: publication.transportGeneration ?? 1,
            providerLifecycleID: publication.providerLifecycleID, verificationEpoch: publication.verificationEpoch,
            forwardingBaseline: baseline, runtimeCondition: condition,
            health: .init(startedAt: date, networkPathIsSatisfied: condition != .offline),
            statusPublication: publication)
    }

    private func publication(_ publisher: inout ProtectionStatusPublisher, at seconds: Double,
                             bytes: UInt64, epoch: UInt64, baseline: UInt64,
                             condition: ChainedRuntimeCondition = .normal) throws -> ProtectionStatusPublication {
        let time = date.addingTimeInterval(seconds)
        let evidence = ProtectionStatusEvidence(sampledAt: time, lifecycleIsActive: true,
            health: .init(startedAt: date, networkPathIsSatisfied: condition != .offline),
            pauseUntil: nil, isChained: true, sessionGeneration: 1, forwardedBytes: bytes,
            transportGeneration: 1, setupReady: false, providerLifecycleID: "provider-A",
            verificationEpoch: epoch, forwardingBaseline: baseline, runtimeCondition: condition)
        return try XCTUnwrap(publisher.observe(evidence, clock: .init(date: time, bootSessionID: "boot-A",
            continuousNanoseconds: UInt64(seconds * 1_000_000_000))))
    }

    func testFreshCanonicalWakeReplyReplacesExpiredFileBeforeForegroundPresentation() throws {
        var publisher = ProtectionStatusPublisher()
        let old = try publication(&publisher, at: 1, bytes: 100, epoch: 1, baseline: 0)
        _ = try publication(&publisher, at: 2, bytes: 100, epoch: 1, baseline: 0, condition: .suspended)
        let current = try publication(&publisher, at: 3600, bytes: 101, epoch: 2, baseline: 100)
        var state = settled(sample(bytes: 100), userInitiated: true)
        var entry = Entry()
        let token = entry.begin(connection: 1, identity: try XCTUnwrap(state.foregroundEntryIdentity), now: 3600)
        XCTAssertTrue(entry.stageProviderReply(providerReply(current), for: token, now: 3600.01))
        let candidate = try XCTUnwrap(entry.consume(connection: 1, identity: state.foregroundEntryIdentity, now: 3600.02))
        let reply = try XCTUnwrap(candidate.providerReply)
        var reader = ProtectionStatusPublicationReader()
        let clock = ProtectionStatusPublicationClock.Sample(date: date.addingTimeInterval(3600.02),
            bootSessionID: "boot-A", continuousNanoseconds: 3_600_020_000_000)
        XCTAssertTrue(reader.admit(reply.statusPublication, clock: clock, providerLifecycleID: "provider-A", connectedAt: date))
        XCTAssertFalse(reader.admit(old, clock: clock, providerLifecycleID: "provider-A", connectedAt: date))
        XCTAssertEqual(reader.status(clock: clock, providerLifecycleID: "provider-A", connectedAt: date), .connected(.healthy))
        XCTAssertEqual(P.reduce(state: &state, event: .observed(connection: 1,
            observation: candidate.observation, now: candidate.receivedAt)), [])
        XCTAssertEqual(state.claim, .confirmed)
        XCTAssertEqual(state.lastAcceptedAt, 3600.01, "Activation preserves the real sample age")
    }

    func testCurrentWakeEpochWithoutNewForwardingNeverRestoresOldProtectedClaim() throws {
        for condition in [ChainedRuntimeCondition.normal, .offline, .recovering, .suspended, .retired] {
            var publisher = ProtectionStatusPublisher()
            _ = try publication(&publisher, at: 1, bytes: 100, epoch: 1, baseline: 0)
            let current = try publication(&publisher, at: 3600, bytes: 100, epoch: 2, baseline: 100, condition: condition)
            var state = settled(sample(bytes: 100), userInitiated: true)
            var entry = Entry()
            let token = entry.begin(connection: 1, identity: try XCTUnwrap(state.foregroundEntryIdentity), now: 3600)
            XCTAssertTrue(entry.stageProviderReply(providerReply(current, bytes: 100, condition: condition),
                for: token, now: 3600.01))
            let candidate = try XCTUnwrap(entry.consume(connection: 1, identity: state.foregroundEntryIdentity, now: 3600.02))
            XCTAssertNotEqual(candidate.providerReply?.statusPublication?.status, .connected(.healthy))
            P.reduce(state: &state, event: .observed(connection: 1, observation: candidate.observation, now: candidate.receivedAt))
            XCTAssertNotEqual(state.claim, .confirmed)
            XCTAssertEqual(state.milestone, .none)
        }
    }

    func testCanonicalPrefetchKeepsAbsoluteBoundsAndRejectsMismatchedWriter() throws {
        var publisher = ProtectionStatusPublisher()
        let current = try publication(&publisher, at: 3600, bytes: 101, epoch: 2, baseline: 100)
        let identity = try XCTUnwrap(settled().foregroundEntryIdentity)
        var entry = Entry()
        let token = entry.begin(connection: 1, identity: identity, now: 3600)
        XCTAssertTrue(entry.isPending(now: 3600.01), "An in-flight unlock read can be reused")
        XCTAssertTrue(entry.stageProviderReply(providerReply(current), for: token, now: 3600.01))
        XCTAssertTrue(entry.isPending(now: 3600.1))
        XCTAssertTrue(entry.isPending(now: 3601), "Canonical evidence retains its original publication lease")
        XCTAssertFalse(entry.isPending(now: 3610.01))
        XCTAssertNil(entry.consume(connection: 1, identity: identity, now: 3610.01))
        XCTAssertFalse(entry.stageProviderReply(providerReply(current), for: token, now: 3610.02))
        let fresh = entry.begin(connection: 1, identity: identity, now: 3602)
        let mismatch = ChainedHandshakeStatus(isChained: true, hasHandshake: true, everHandshaked: true,
            providerLifecycleID: "provider-B", statusPublication: current)
        XCTAssertFalse(entry.stageProviderReply(mismatch, for: fresh, now: 3602.01))
        XCTAssertFalse(entry.stageProviderReply(providerReply(current), for: fresh, now: 3604))
    }

    func testCanonicalPrefetchStagesCurrentDNSOnlyAndInactiveReplies() throws {
        let identity = try XCTUnwrap(settled().foregroundEntryIdentity)
        for active in [true, false] {
            var entry = Entry()
            let token = entry.begin(connection: 1, identity: identity, now: 100)
            let reply = ChainedHandshakeStatus(isChained: false, hasHandshake: false, everHandshaked: false,
                lifecycleIsActive: active)
            XCTAssertTrue(entry.stageProviderReply(reply, for: token, now: 100.01))
            let candidate = try XCTUnwrap(entry.consume(connection: 1, identity: identity, now: 100.02))
            XCTAssertEqual(candidate.observation, active ? .dnsOnly : .inactive)
            XCTAssertNotNil(candidate.providerReply)
        }
    }

    func testCompletedMissingUnlockReplyAllowsForegroundRetryAndLateCompletionCannotRetireIt() throws {
        let identity = try XCTUnwrap(settled().foregroundEntryIdentity)
        var entry = Entry()
        let unlock = entry.begin(connection: 1, identity: identity, now: 100)
        XCTAssertTrue(entry.isPending(now: 100.01))
        XCTAssertFalse(entry.stageProviderReply(nil, for: unlock, now: 100.02))
        XCTAssertFalse(entry.isPending(now: 100.03), "A completed failed read must not suppress the foreground retry")
        let foreground = entry.begin(connection: 1, identity: identity, now: 100.04)
        XCTAssertFalse(entry.stageProviderReply(nil, for: unlock, now: 100.05))
        XCTAssertTrue(entry.isPending(now: 100.06), "A retired completion cannot finish the newer physical read")
        var publisher = ProtectionStatusPublisher()
        let current = try publication(&publisher, at: 100, bytes: 101, epoch: 2, baseline: 100)
        XCTAssertTrue(entry.stageProviderReply(providerReply(current), for: foreground, now: 100.07))
        XCTAssertNotNil(entry.consume(connection: 1, identity: identity, now: 100.08))
    }

    func testInactiveReplyWithRetainedTerminalPublicationFencesOutPreviousHealthyFile() throws {
        var publisher = ProtectionStatusPublisher()
        let healthy = try publication(&publisher, at: 1, bytes: 100, epoch: 1, baseline: 0)
        let clock = ProtectionStatusPublicationClock.Sample(date: date.addingTimeInterval(2),
            bootSessionID: "boot-A", continuousNanoseconds: 2_000_000_000)
        let terminal = try XCTUnwrap(publisher.observe(.init(sampledAt: clock.date, lifecycleIsActive: false,
            health: .init(startedAt: date), pauseUntil: nil, isChained: false,
            sessionGeneration: nil, forwardedBytes: nil, providerLifecycleID: "provider-A"), clock: clock))
        XCTAssertEqual(terminal.status, .unavailable)
        let reply = ChainedHandshakeStatus(isChained: false, hasHandshake: false, everHandshaked: false,
            lifecycleIsActive: false, providerLifecycleID: nil, statusPublication: terminal)
        let identity = try XCTUnwrap(settled().foregroundEntryIdentity)
        var entry = Entry()
        let token = entry.begin(connection: 1, identity: identity, now: 2)
        XCTAssertTrue(entry.stageProviderReply(reply, for: token, now: 2.01))
        let candidate = try XCTUnwrap(entry.consume(connection: 1, identity: identity, now: 2.02))
        XCTAssertEqual(candidate.observation, .inactive)
        // Production terminal envelope supplies the retained ID only for an unavailable status.
        let retainedID = candidate.providerReply?.statusPublication?.providerLifecycleID
        var reader = ProtectionStatusPublicationReader()
        XCTAssertTrue(reader.admit(candidate.providerReply?.statusPublication, clock: clock,
            providerLifecycleID: retainedID, connectedAt: date))
        XCTAssertFalse(reader.admit(healthy, clock: clock, providerLifecycleID: retainedID, connectedAt: date))
        XCTAssertEqual(reader.status(clock: clock, providerLifecycleID: retainedID, connectedAt: date), .unavailable)
    }

    func testForegroundRefreshRetainsCanonicalBackupAcrossTheShortLegacyWindow() throws {
        let identity = try XCTUnwrap(settled().foregroundEntryIdentity)
        var publisher = ProtectionStatusPublisher()
        let current = try publication(&publisher, at: 100, bytes: 101, epoch: 2, baseline: 100)
        var entry = Entry()
        let unlock = entry.begin(connection: 1, identity: identity, now: 100)
        XCTAssertTrue(entry.stageProviderReply(providerReply(current), for: unlock, now: 100.01))
        let foreground = entry.begin(connection: 1, identity: identity, now: 100.49, retainingCandidate: true)
        XCTAssertFalse(entry.stageProviderReply(nil, for: foreground, now: 100.5))
        let candidate = try XCTUnwrap(entry.consume(connection: 1, identity: identity, now: 100.65))
        XCTAssertEqual(candidate.providerReply?.statusPublication, current)
        XCTAssertEqual(candidate.receivedAt, 100.01, "Foreground refresh cannot renew the backup's sample")

        let old = entry.begin(connection: 1, identity: identity, now: 101)
        let restarted = entry.begin(connection: 1, identity: identity, now: 102.9, retainingCandidate: true)
        XCTAssertFalse(entry.stageProviderReply(providerReply(current), for: old, now: 102.95))
        XCTAssertTrue(entry.stageProviderReply(providerReply(current), for: restarted, now: 103.01))
        XCTAssertNotNil(entry.consume(connection: 1, identity: identity, now: 103.05))
    }

    func testForegroundRefreshReplacesBackupWithCurrentFailureAndCannotCarryAcrossConnections() throws {
        let identity = try XCTUnwrap(settled().foregroundEntryIdentity)
        var publisher = ProtectionStatusPublisher()
        let healthy = try publication(&publisher, at: 100, bytes: 101, epoch: 2, baseline: 100)
        let failure = try publication(&publisher, at: 101, bytes: 101, epoch: 2, baseline: 100, condition: .offline)
        var entry = Entry()
        let unlock = entry.begin(connection: 1, identity: identity, now: 100)
        XCTAssertTrue(entry.stageProviderReply(providerReply(healthy), for: unlock, now: 100.01))
        let foreground = entry.begin(connection: 1, identity: identity, now: 100.49, retainingCandidate: true)
        XCTAssertTrue(entry.stageProviderReply(providerReply(failure, condition: .offline), for: foreground, now: 101.01))
        let candidate = try XCTUnwrap(entry.consume(connection: 1, identity: identity, now: 101.02))
        XCTAssertEqual(candidate.providerReply?.statusPublication?.status, .connected(.networkUnavailable))
        let next = entry.begin(connection: 1, identity: identity, now: 102)
        XCTAssertTrue(entry.stageProviderReply(providerReply(healthy), for: next, now: 102.01))
        _ = entry.begin(connection: 2, identity: identity, now: 102.02, retainingCandidate: true)
        XCTAssertNil(entry.consume(connection: 2, identity: identity, now: 102.03))
    }

    func testRetainedCanonicalBackupCannotRenewTheProvidersAbsoluteLease() throws {
        let identity = try XCTUnwrap(settled().foregroundEntryIdentity)
        var publisher = ProtectionStatusPublisher()
        let current = try publication(&publisher, at: 100, bytes: 101, epoch: 2, baseline: 100)
        var entry = Entry()
        let unlock = entry.begin(connection: 1, identity: identity, now: 100)
        XCTAssertTrue(entry.stageProviderReply(providerReply(current), for: unlock, now: 100.49))
        _ = entry.begin(connection: 1, identity: identity, now: 109.98, retainingCandidate: true)
        let candidate = try XCTUnwrap(entry.consume(connection: 1, identity: identity, now: 110.01))
        let clock = ProtectionStatusPublicationClock.Sample(date: date.addingTimeInterval(110.01),
            bootSessionID: "boot-A", continuousNanoseconds: 110_010_000_000)
        var reader = ProtectionStatusPublicationReader()
        XCTAssertFalse(reader.admit(candidate.providerReply?.statusPublication, clock: clock,
            providerLifecycleID: "provider-A", connectedAt: date))
        XCTAssertEqual(reader.status(clock: clock, providerLifecycleID: "provider-A", connectedAt: date), .unavailable)
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
