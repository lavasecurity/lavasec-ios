import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

@MainActor
final class ProtectionActionOrchestratorTests: XCTestCase {
    func testClaimRejectsConcurrentActionsUntilReleased() {
        let orchestrator = ProtectionActionOrchestrator()

        XCTAssertTrue(orchestrator.claim(.turnOn))
        XCTAssertEqual(orchestrator.inFlightAction, .turnOn)
        XCTAssertFalse(orchestrator.claim(.turnOff), "A second action must be rejected while one is in flight.")
        XCTAssertFalse(orchestrator.claim(.turnOn), "Re-claiming the same kind is still a concurrent action.")

        orchestrator.release(.turnOn)
        XCTAssertNil(orchestrator.inFlightAction)
        XCTAssertTrue(orchestrator.claim(.turnOff))
    }

    func testMismatchedReleaseCannotEndAnotherActionsClaim() {
        let orchestrator = ProtectionActionOrchestrator()

        orchestrator.claim(.resume)
        orchestrator.release(.turnOff)

        XCTAssertEqual(
            orchestrator.inFlightAction,
            .resume,
            "A stale release from an abandoned flow must not end a newer action's claim."
        )
        orchestrator.release(.resume)
        XCTAssertNil(orchestrator.inFlightAction)
    }

    func testInFlightChangeMirrorsClaimAndRelease() {
        var observed: [ProtectionActionKind?] = []
        let orchestrator = ProtectionActionOrchestrator { observed.append($0) }

        orchestrator.claim(.reconnect)
        orchestrator.release(.reconnect)
        orchestrator.release(.reconnect)

        XCTAssertEqual(observed, [.reconnect, nil], "Idempotent releases must not re-notify.")
    }

    func testRunSkipsOperationWhileBusyAndReleasesAfterwards() async {
        let orchestrator = ProtectionActionOrchestrator()
        orchestrator.claim(.turnOn)

        var ran = false
        let started = await orchestrator.run(.resume) { ran = true }

        XCTAssertFalse(started)
        XCTAssertFalse(ran)
        XCTAssertEqual(orchestrator.inFlightAction, .turnOn)

        orchestrator.release(.turnOn)
        let secondStart = await orchestrator.run(.resume) { ran = true }
        XCTAssertTrue(secondStart)
        XCTAssertTrue(ran)
        XCTAssertNil(orchestrator.inFlightAction, "run must release its claim when the operation finishes.")
    }

    func testAutomaticRestoreRechecksLiveIntentAfterRefreshBeforeClaimingTurnOn() async {
        let orchestrator = ProtectionActionOrchestrator()
        let refreshGate = RestoreRefreshGate()
        var liveIntentAllowsRestore = true
        var restored = false

        let restore = Task { @MainActor in
            await orchestrator.runAutomaticRestoreAfterRefresh(
                refresh: { await refreshGate.wait() },
                shouldRestore: { liveIntentAllowsRestore },
                operation: { _ in
                    restored = true
                    return true
                }
            )
        }

        await refreshGate.waitUntilSuspended()
        liveIntentAllowsRestore = false
        await refreshGate.resume()

        let started = await restore.value
        XCTAssertFalse(started)
        XCTAssertFalse(restored, "A turn-off completed during refresh must win over the stale restore request.")
        XCTAssertNil(orchestrator.inFlightAction)
    }

    func testAutomaticRestoreClaimsAndRunsWhenRefreshedLiveIntentStillAllowsIt() async {
        let orchestrator = ProtectionActionOrchestrator()
        var restored = false

        let started = await orchestrator.runAutomaticRestoreAfterRefresh(
            refresh: {},
            shouldRestore: { true },
            operation: { _ in
                restored = true
                return true
            }
        )

        XCTAssertTrue(started)
        XCTAssertTrue(restored)
        XCTAssertNil(orchestrator.inFlightAction, "The automatic restore must release its turn-on claim.")
    }

    func testAutomaticRestoreDoesNotInterleaveWithActionClaimedDuringRefresh() async {
        let orchestrator = ProtectionActionOrchestrator()
        let refreshGate = RestoreRefreshGate()
        var restored = false

        let restore = Task { @MainActor in
            await orchestrator.runAutomaticRestoreAfterRefresh(
                refresh: { await refreshGate.wait() },
                shouldRestore: { true },
                operation: { _ in
                    restored = true
                    return true
                }
            )
        }

        await refreshGate.waitUntilSuspended()
        XCTAssertTrue(orchestrator.claim(.turnOff))
        await refreshGate.resume()

        let started = await restore.value
        XCTAssertFalse(started)
        XCTAssertFalse(restored)
        XCTAssertEqual(orchestrator.inFlightAction, .turnOff)
        orchestrator.release(.turnOff)
    }

    func testAutomaticRestoreDoesNotRunWhileAnExternalRestartOwnsTheLease() async throws {
        let orchestrator = ProtectionActionOrchestrator()
        let fixture = RestoreLeaseFixture(tokens: ["restart"])
        let capturedGeneration = try fixture.store.currentExternalRestartGeneration()
        _ = try XCTUnwrap(fixture.store.claimExplicitRestart(leaseDuration: 30))
        var automaticLease: ProtectionLifecycleLease?
        var restored = false

        let started = await orchestrator.runAutomaticRestoreAfterRefresh(
            refresh: {},
            shouldRestore: { true },
            claimExternalExclusion: {
                automaticLease = try? fixture.store.claimAutomaticRestore(
                    expectedExternalRestartGeneration: capturedGeneration,
                    leaseDuration: 30
                )
                return automaticLease != nil
            },
            releaseExternalExclusion: {
                if let automaticLease {
                    _ = try? fixture.store.release(automaticLease)
                }
            },
            operation: { _ in
                restored = true
                return true
            }
        )

        XCTAssertFalse(started)
        XCTAssertFalse(restored)
        XCTAssertNil(orchestrator.inFlightAction)
    }

    func testExternalRestartCannotClaimWhileAutomaticRestoreOperationIsRunning() async throws {
        let orchestrator = ProtectionActionOrchestrator()
        let fixture = RestoreLeaseFixture(tokens: ["restore", "restart"])
        let capturedGeneration = try fixture.store.currentExternalRestartGeneration()
        let operationGate = RestoreRefreshGate()
        var automaticLease: ProtectionLifecycleLease?

        let restore = Task { @MainActor in
            await orchestrator.runAutomaticRestoreAfterRefresh(
                refresh: {},
                shouldRestore: { true },
                claimExternalExclusion: {
                    automaticLease = try? fixture.store.claimAutomaticRestore(
                        expectedExternalRestartGeneration: capturedGeneration,
                        leaseDuration: 30
                    )
                    return automaticLease != nil
                },
                releaseExternalExclusion: {
                    if let automaticLease {
                        _ = try? fixture.store.release(automaticLease)
                    }
                },
                operation: { _ in
                    await operationGate.wait()
                    return true
                }
            )
        }

        await operationGate.waitUntilSuspended()
        XCTAssertNil(
            try fixture.store.claimExplicitRestart(leaseDuration: 30),
            "The restore lease must remain held for the whole enable operation."
        )

        await operationGate.resume()
        let didRestore = await restore.value
        XCTAssertTrue(didRestore)
        XCTAssertNotNil(try fixture.store.claimExplicitRestart(leaseDuration: 30))
    }

    func testAutomaticRestoreAwaitsExternalCleanupBeforeReleasingTurnOnClaim() async {
        let orchestrator = ProtectionActionOrchestrator()
        let cleanupGate = RestoreRefreshGate()
        var operationFinished = false

        let restore = Task { @MainActor in
            await orchestrator.runAutomaticRestoreAfterRefresh(
                refresh: {},
                shouldRestore: { true },
                releaseExternalExclusion: {
                    await cleanupGate.wait()
                },
                operation: { _ in
                    operationFinished = true
                    return true
                }
            )
        }

        await cleanupGate.waitUntilSuspended()
        XCTAssertTrue(operationFinished)
        XCTAssertEqual(
            orchestrator.inFlightAction,
            .turnOn,
            "The local claim must remain owned until durable external cleanup settles."
        )
        XCTAssertFalse(
            orchestrator.claim(.reconnect),
            "A foreground action must not enter while automatic-restore cleanup is still pending."
        )

        await cleanupGate.resume()
        let didRestore = await restore.value
        XCTAssertTrue(didRestore)
        XCTAssertNil(orchestrator.inFlightAction)
    }

    func testAutomaticRestoreAbortsAfterItsLeaseExpiresAndANewerRestartClaims() async throws {
        let orchestrator = ProtectionActionOrchestrator()
        let fixture = RestoreLeaseFixture(tokens: ["restore", "restart"])
        let operationGate = RestoreRefreshGate()
        var automaticLease: ProtectionLifecycleLease?
        var mutatedProtectionLifecycle = false

        let restore = Task { @MainActor in
            await orchestrator.runAutomaticRestoreAfterRefresh(
                refresh: {},
                shouldRestore: { true },
                claimExternalExclusion: {
                    automaticLease = try? fixture.store.claimAutomaticRestore(
                        expectedExternalRestartGeneration: nil,
                        leaseDuration: 10
                    )
                    return automaticLease != nil
                },
                validateExternalExclusion: {
                    guard let automaticLease else {
                        return false
                    }
                    return (try? fixture.store.renew(automaticLease, leaseDuration: 10)) == true
                },
                releaseExternalExclusion: {
                    if let automaticLease {
                        _ = try? fixture.store.release(automaticLease)
                    }
                },
                operation: { validateOwnership in
                    await operationGate.wait()
                    guard validateOwnership() else {
                        return false
                    }
                    mutatedProtectionLifecycle = true
                    return true
                }
            )
        }

        await operationGate.waitUntilSuspended()
        fixture.clock.advance(seconds: 11)
        let restart = try XCTUnwrap(fixture.store.claimExplicitRestart(leaseDuration: 10))
        await operationGate.resume()

        let didRestore = await restore.value
        XCTAssertFalse(didRestore)
        XCTAssertFalse(mutatedProtectionLifecycle)
        XCTAssertEqual(try fixture.store.currentLease(), restart)
    }

    func testRestoreIntentRevisionInvalidatesAnOlderRequestEvenWhenDirectionStaysOn() {
        var intent = ProtectionRestoreIntentState(isEnabled: true)
        let staleRequest = intent.makeRestoreRequest(wasEnabled: true)

        // Reconnect is a fresh accepted user intent in the SAME direction. Its revision must still
        // invalidate a restore request captured before the action began.
        intent.recordUserIntent(isEnabled: true)

        XCTAssertTrue(intent.isEnabled)
        XCTAssertEqual(intent.revision, staleRequest.intentRevision + 1)
        XCTAssertFalse(intent.allows(staleRequest))
        XCTAssertTrue(intent.allows(intent.makeRestoreRequest(wasEnabled: true)))
    }

    func testTurnOffDuringRefreshInvalidatesTheCapturedRestoreRequest() {
        var intent = ProtectionRestoreIntentState(isEnabled: true)
        let request = intent.makeRestoreRequest(wasEnabled: true)

        intent.recordUserIntent(isEnabled: false)

        XCTAssertFalse(intent.allows(request))
        XCTAssertFalse(intent.isEnabled)
    }

    func testDisconnectedRefreshDoesNotOverwriteExplicitOnIntent() async {
        let orchestrator = ProtectionActionOrchestrator()
        let intent = ProtectionRestoreIntentState(isEnabled: true)
        let request = intent.makeRestoreRequest(wasEnabled: true)
        var refreshedStatusSaysEnabled = true
        var restored = false

        let started = await orchestrator.runAutomaticRestoreAfterRefresh(
            refresh: { refreshedStatusSaysEnabled = false },
            shouldRestore: {
                intent.allows(request) && !refreshedStatusSaysEnabled
            },
            operation: { _ in
                restored = true
                return true
            }
        )

        XCTAssertTrue(started)
        XCTAssertTrue(restored, "An unexpected disconnected/unarmed refresh must not erase the user's on intent.")
    }

    func testRestoreCaptureUsesStickyExplicitIntentWhenObservedStatusIsAlreadyOff() {
        let intent = ProtectionRestoreIntentState(isEnabled: true)

        let request = intent.makeRestoreRequest(wasEnabled: false)

        XCTAssertTrue(
            request.wasEnabled,
            "A launch status observation must not erase the loaded or user-authored on intent before capture."
        )
        XCTAssertTrue(intent.allows(request))
    }

    func testProtectedDataRecoveryReinitializesIntentAndInvalidatesPlaceholderRequests() {
        var intent = ProtectionRestoreIntentState(isEnabled: false)
        let placeholderRequest = intent.makeRestoreRequest(wasEnabled: false)

        intent.recoverFromLoadedConfiguration(isEnabled: true)

        XCTAssertFalse(intent.allows(placeholderRequest))
        XCTAssertTrue(intent.isEnabled)
        XCTAssertTrue(intent.allows(intent.makeRestoreRequest(wasEnabled: true)))
    }
}

private final class RestoreLeaseFixture {
    let clock = FakeProtectionClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
    let store: ProtectionLifecycleLeaseStore

    init(tokens: [String]) {
        let tokenSequence = RestoreLeaseTokenSequence(tokens)
        store = ProtectionLifecycleLeaseStore(
            storage: FakeProtectionKeyValueStore(),
            lock: ProtectionNSLock(),
            clock: clock,
            makeToken: { tokenSequence.next() }
        )
    }
}

private final class RestoreLeaseTokenSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]

    init(_ tokens: [String]) {
        self.tokens = tokens
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        precondition(!tokens.isEmpty)
        return tokens.removeFirst()
    }
}

private actor RestoreRefreshGate {
    private var isSuspended = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isSuspended = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSuspended() async {
        while !isSuspended {
            await Task.yield()
        }
    }

    func resume() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
