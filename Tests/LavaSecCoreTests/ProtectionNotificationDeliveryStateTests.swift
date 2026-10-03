import XCTest
import LavaSecCore

final class ProtectionNotificationDeliveryStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 900)

    private func posture(_ severity: ProtectionConnectivitySeverity = .needsReconnect,
                         filteringUnavailable: Bool? = nil) -> ProtectionNotificationDeliveryState.Posture {
        .init(assessment: .init(severity: severity, primaryAction: .reconnect),
              health: TunnelHealthSnapshot(lastUpstreamFailureAt: now, lastSlowUpstreamResponseAt: now,
                  failClosedServedQueryCount: 1, lastFailClosedAt: now, lastFailClosedReason: "snapshot-unavailable"),
              filteringUnavailable: filteringUnavailable, filteringUnavailableSince: now.addingTimeInterval(-30),
              filteringIntervention: filteringUnavailable == true ? .reviewFilterSelection : nil)
    }

    private func beginSubmission(_ state: inout ProtectionNotificationDeliveryState) throws -> ProtectionNotificationDeliveryState.Attempt {
        let attempt = try XCTUnwrap(state.prepare(history: .empty, now: now))
        return try XCTUnwrap(state.authorized(attempt, permitted: true, history: .empty, now: now))
    }

    func testRecoveryDuringAuthorizationPreventsSubmission() throws {
        var state = ProtectionNotificationDeliveryState()
        state.update(posture())
        let attempt = try XCTUnwrap(state.prepare(history: .empty, now: now))
        state.update(posture(.healthy))
        XCTAssertNil(state.authorized(attempt, permitted: true, history: .empty, now: now))
        XCTAssertNil(state.prepare(history: .empty, now: now))
    }

    func testAutomaticRepairInvalidatesAPendingFilterIntervention() throws {
        var state = ProtectionNotificationDeliveryState()
        state.update(posture(.healthy, filteringUnavailable: true))
        let submission = try beginSubmission(&state)
        let previous = try XCTUnwrap(state.posture)
        state.update(.init(assessment: previous.assessment, health: previous.health,
                           filteringUnavailable: true, filteringUnavailableSince: previous.filteringUnavailableSince))
        guard case .discard = state.submitted(submission, succeeded: true, permitted: true, now: now) else {
            return XCTFail("A pending intervention must be discarded while automatic repair can proceed")
        }
    }

    func testRecoveryDuringSubmissionDiscardsTheAcceptedRequest() throws {
        var state = ProtectionNotificationDeliveryState()
        state.update(posture())
        let submission = try beginSubmission(&state)
        state.update(posture(.healthy))
        guard case .discard = state.submitted(submission, succeeded: true, permitted: true, now: now) else {
            return XCTFail("Recovered health cannot claim an outage notice")
        }
        XCTAssertNil(state.retryDeadline)
    }

    func testAllEntryPointsRespectBackoffUntilItsDeadline() throws {
        var state = ProtectionNotificationDeliveryState()
        state.update(posture())
        let submission = try beginSubmission(&state)
        guard case .retry(let deadline) = state.submitted(submission, succeeded: false, permitted: true, now: now) else {
            return XCTFail("Failed submission must reserve a retry")
        }
        XCTAssertEqual(deadline, now.addingTimeInterval(60))
        for elapsed in [0.0, 1, 30, 59] {
            XCTAssertNil(state.prepare(history: .empty, now: now.addingTimeInterval(elapsed)))
        }
        XCTAssertNotNil(state.prepare(history: .empty, now: deadline))
        XCTAssertNil(state.retryDeadline)
    }

    func testFilterFailurePreemptsAResolverRetryButNotAnInflightSubmission() throws {
        var state = ProtectionNotificationDeliveryState()
        state.update(posture())
        let submission = try beginSubmission(&state)
        XCTAssertNil(state.prepare(history: .empty, now: now))
        _ = state.submitted(submission, succeeded: false, permitted: true, now: now)
        state.update(posture(.healthy, filteringUnavailable: true))
        let repair = try XCTUnwrap(state.prepare(history: .empty, now: now.addingTimeInterval(1)))
        XCTAssertEqual(repair.notification.kind, .filteringUnavailable)
        XCTAssertNil(state.retryDeadline)
        XCTAssertNil(state.prepare(history: .empty, now: now.addingTimeInterval(2)))
    }

    func testShutdownInvalidatesAuthorizationAndCannotConsumeTheNextLifecycleAttempt() throws {
        var state = ProtectionNotificationDeliveryState()
        state.update(posture())
        let old = try XCTUnwrap(state.prepare(history: .empty, now: now))
        XCTAssertTrue(state.invalidate().isEmpty)
        state.update(posture())
        let current = try XCTUnwrap(state.prepare(history: .empty, now: now))
        XCTAssertNotEqual(old.token, current.token)
        XCTAssertNil(state.authorized(old, permitted: true, history: .empty, now: now))
        XCTAssertNotNil(state.authorized(current, permitted: true, history: .empty, now: now))
    }

    func testShutdownReturnsSubmittedRequestAndRejectsItsLateCompletion() throws {
        var state = ProtectionNotificationDeliveryState()
        state.update(posture())
        let old = try beginSubmission(&state)
        XCTAssertEqual(state.invalidate(), [old.requestIdentifier])
        state.update(posture())
        let current = try beginSubmission(&state)
        guard case .discard(let removeRequest) = state.submitted(old, succeeded: true, permitted: true, now: now) else {
            return XCTFail("The ended lifecycle cannot claim delivery")
        }
        XCTAssertTrue(removeRequest)
        XCTAssertNotEqual(old.requestIdentifier, current.requestIdentifier,
                          "Late cleanup owns a different OS request even for the same incident")
        guard case .claim = state.submitted(current, succeeded: true, permitted: true, now: now) else {
            return XCTFail("The stale callback must not consume the current attempt")
        }
        XCTAssertNil(state.claimed(current, result: .recorded(supersededIdentifiers: []), permitted: true, now: now))
        guard case .discard = state.submitted(current, succeeded: true, permitted: true, now: now) else {
            return XCTFail("Completion must be consumed exactly once")
        }
    }

    func testPreferencesOrPermissionLossCannotClaimOrRetry() throws {
        var state = ProtectionNotificationDeliveryState()
        state.update(posture())
        let denied = try XCTUnwrap(state.prepare(history: .empty, now: now))
        XCTAssertNil(state.authorized(denied, permitted: false, history: .empty, now: now))
        let submission = try beginSubmission(&state)
        guard case .discard = state.submitted(submission, succeeded: false, permitted: false, now: now) else {
            return XCTFail("Disabled notifications cannot create retries")
        }
        XCTAssertNil(state.retryDeadline)
    }

    func testIncidentChangeDuringSubmissionAllowsFreshScheduling() throws {
        var state = ProtectionNotificationDeliveryState()
        state.update(posture(.dnsSlow))
        let old = try beginSubmission(&state)
        state.update(posture(.healthy, filteringUnavailable: true))
        guard case .discard = state.submitted(old, succeeded: true, permitted: true, now: now) else {
            return XCTFail("A changed incident must be reevaluated")
        }
        XCTAssertEqual(state.prepare(history: .empty, now: now)?.notification.kind, .filteringUnavailable)
    }

    func testNewFailureOfTheSameKindInvalidatesAnOlderSubmission() throws {
        var state = ProtectionNotificationDeliveryState()
        state.update(.init(assessment: .init(severity: .needsReconnect, primaryAction: .reconnect),
                           health: TunnelHealthSnapshot(lastDNSSmokeProbeAt: now)))
        let old = try beginSubmission(&state)
        let latest = now.addingTimeInterval(10)
        state.update(.init(assessment: .init(severity: .needsReconnect, primaryAction: .reconnect),
                           health: TunnelHealthSnapshot(lastDNSSmokeProbeAt: latest)))
        guard case .discard = state.submitted(old, succeeded: true, permitted: true, now: latest) else {
            return XCTFail("An older failure cannot own the current incident's recovery threshold")
        }
        XCTAssertNotEqual(state.prepare(history: .empty, now: latest)?.notification.identifier, old.notification.identifier)
    }

    func testBlockedTrafficPreservesTheFilterIncidentButAChangedRemedyInvalidatesIt() throws {
        for remedy: FilterArtifactIntervention in [.reviewFilterSelection, .refreshCustomSources] {
            var state = ProtectionNotificationDeliveryState()
            state.update(posture(.healthy, filteringUnavailable: true))
            let old = try beginSubmission(&state)
            let previous = try XCTUnwrap(state.posture)
            let latest = now.addingTimeInterval(10)
            state.update(.init(assessment: previous.assessment,
                health: TunnelHealthSnapshot(failClosedServedQueryCount: 100, lastFailClosedAt: latest,
                                             lastFailClosedReason: "snapshot-unavailable"),
                filteringUnavailable: true, filteringUnavailableSince: previous.filteringUnavailableSince,
                filteringIntervention: remedy))
            let result = state.submitted(old, succeeded: true, permitted: true, now: latest)
            if remedy == .reviewFilterSelection {
                guard case .claim = result else { return XCTFail("Ongoing client traffic must not starve delivery") }
            } else {
                guard case .discard = result else { return XCTFail("The pending message must still describe the current remedy") }
            }
        }
    }

    func testShutdownClearsRetryReservation() throws {
        var state = ProtectionNotificationDeliveryState()
        state.update(posture())
        let submission = try beginSubmission(&state)
        _ = state.submitted(submission, succeeded: false, permitted: true, now: now)
        XCTAssertNotNil(state.retryDeadline)
        XCTAssertTrue(state.invalidate().isEmpty)
        XCTAssertNil(state.retryDeadline)
        XCTAssertNil(state.posture)
    }

    func testLateSubmissionAfterShutdownIsRemovedWhenNoCurrentAttemptOwnsItsID() throws {
        var state = ProtectionNotificationDeliveryState()
        state.update(posture())
        let submission = try beginSubmission(&state)
        _ = state.invalidate()
        guard case .discard(let removeRequest) = state.submitted(submission, succeeded: true, permitted: true, now: now) else {
            return XCTFail("A stopped lifecycle cannot claim delivery")
        }
        XCTAssertTrue(removeRequest)
    }

    func testSeparateProducersNeverShareSystemRequestOwnershipForTheSameIncident() throws {
        var app = ProtectionNotificationDeliveryState()
        var tunnel = ProtectionNotificationDeliveryState()
        app.update(posture())
        tunnel.update(posture())
        let first = try beginSubmission(&app)
        let second = try beginSubmission(&tunnel)
        XCTAssertEqual(first.notification.identifier, second.notification.identifier)
        XCTAssertNotEqual(first.requestIdentifier, second.requestIdentifier)
        XCTAssertEqual(app.invalidate(), [first.requestIdentifier])
        XCTAssertEqual(tunnel.invalidate(), [second.requestIdentifier])
    }

    func testContendedDeliveryClaimKeepsABoundedRetry() throws {
        var state = ProtectionNotificationDeliveryState()
        state.update(posture(.healthy, filteringUnavailable: true))
        let submission = try beginSubmission(&state)
        guard case .claim = state.submitted(submission, succeeded: true, permitted: true, now: now) else {
            return XCTFail("Successful submission must attempt an atomic claim")
        }
        let deadline = try XCTUnwrap(state.claimed(submission, result: nil, permitted: true, now: now))
        XCTAssertEqual(deadline, now.addingTimeInterval(60))
        XCTAssertNil(state.prepare(history: .empty, now: now.addingTimeInterval(59)))
        XCTAssertNotNil(state.prepare(history: .empty, now: deadline))
    }

    func testUnavailableHistoryReservesOnlyOneRetryUntilDeadline() throws {
        var state = ProtectionNotificationDeliveryState()
        state.update(posture())
        let deadline = try XCTUnwrap(state.deferEvaluation(now: now))
        XCTAssertEqual(deadline, now.addingTimeInterval(60))
        for elapsed in [0.0, 1, 30, 59] {
            XCTAssertNil(state.deferEvaluation(now: now.addingTimeInterval(elapsed)))
            XCTAssertNil(state.prepare(history: .empty, now: now.addingTimeInterval(elapsed)))
        }
        XCTAssertEqual(state.deferEvaluation(now: deadline), deadline.addingTimeInterval(60))
        state.update(posture(.healthy, filteringUnavailable: true))
        XCTAssertEqual(state.prepare(history: .empty, now: deadline)?.notification.kind, .filteringUnavailable)
    }

    func testUnavailableHistoryRetriesRecoveryCleanupEvenDuringAnOlderAttempt() throws {
        var state = ProtectionNotificationDeliveryState()
        state.update(posture())
        let attempt = try XCTUnwrap(state.prepare(history: .empty, now: now))
        XCTAssertNil(state.deferEvaluation(now: now))
        state.update(posture(.healthy))
        XCTAssertEqual(state.deferEvaluation(now: now), now.addingTimeInterval(60))
        XCTAssertNil(state.authorized(attempt, permitted: false, history: .empty, now: now))
        XCTAssertNil(state.deferEvaluation(now: now.addingTimeInterval(1)))
        state.reconciledHistory()
        XCTAssertNil(state.retryDeadline)
        _ = state.invalidate()
        XCTAssertNil(state.deferEvaluation(now: now))
    }

    func testReconciledHistoryDoesNotShortenFailedDeliveryBackoff() throws {
        var state = ProtectionNotificationDeliveryState()
        state.update(posture())
        let submission = try beginSubmission(&state)
        _ = state.submitted(submission, succeeded: false, permitted: true, now: now)
        state.reconciledHistory()
        XCTAssertEqual(state.retryDeadline, now.addingTimeInterval(60))
        XCTAssertNil(state.prepare(history: .empty, now: now.addingTimeInterval(1)))
    }

    func testCompletedOrRefusedClaimsConsumeTheAttemptWithoutRetry() throws {
        let results: [ProtectionConnectivityNotificationStore.DeliveryClaim] = [
            .recorded(supersededIdentifiers: []), .alreadyOwned, .refused
        ]
        for result in results {
            var state = ProtectionNotificationDeliveryState()
            state.update(posture())
            let submission = try beginSubmission(&state)
            _ = state.submitted(submission, succeeded: true, permitted: true, now: now)
            XCTAssertNil(state.claimed(submission, result: result, permitted: true, now: now))
            XCTAssertNil(state.retryDeadline)
            XCTAssertTrue(state.invalidate().isEmpty)
        }
    }
}
