import Foundation
import Security
import XCTest

@testable import LavaSecKit

/// Behaviour against an injected backend, plus the production item attributes.
///
/// The classification is the point: unavailability must never flatten into values, because
/// the one place these values are consumed — the start latch, via the app's reconcile — is
/// where a guessed `false` deletes a user preference (`ChainedAvailabilityPolicy.
/// revokesStoredPreference(.insufficientMemory)` is `true`).
final class ChainedDeviceEligibilityStoreTests: XCTestCase {

    /// In-memory backend, scriptable to refuse like a pre-first-unlock Keychain.
    private final class FakeItems: ChainedDeviceStateItemStore, @unchecked Sendable {
        private let lock = NSLock()
        private let lifecycleEvidenceLock = NSLock()
        private var storage: [String: Data] = [:]
        var refusesReads = false
        var refusesSaves = false
        var afterLoad: ((String) -> Void)?
        var beforeLifecycleEvidenceAccess: (() -> Void)?
        private(set) var saveCount = 0

        func save(_ data: Data, account: String) throws {
            if refusesSaves { throw ChainedDeviceStateStoreFailure.keychainRefused(errSecInteractionNotAllowed) }
            lock.withLock {
                saveCount += 1
                storage[account] = data
            }
        }

        func load(account: String) throws -> Data? {
            if refusesReads { throw ChainedDeviceStateStoreFailure.keychainRefused(errSecInteractionNotAllowed) }
            let data = lock.withLock { storage[account] }
            afterLoad?(account)
            return data
        }

        func delete(account: String) throws {
            lock.withLock { storage[account] = nil }
        }

        func withExclusiveLifecycleEvidenceAccess<T>(
            _ operation: () throws -> T
        ) throws -> T {
            beforeLifecycleEvidenceAccess?()
            return try lifecycleEvidenceLock.withLock(operation)
        }

        func peek(_ account: String) -> Data? { lock.withLock { storage[account] } }
        func plant(_ data: Data, account: String) { lock.withLock { storage[account] = data } }
    }

    private final class LifecycleRaceResults: @unchecked Sendable {
        private let lock = NSLock()
        private var consumedState: ChainedStartupCrashLoopPolicy.State?
        private var proofResult: Bool?
        private var operationError: Error?

        func record(state: ChainedStartupCrashLoopPolicy.State) {
            lock.withLock { consumedState = state }
        }

        func record(proof: Bool) {
            lock.withLock { proofResult = proof }
        }

        func record(error: Error) {
            lock.withLock { operationError = error }
        }

        var state: ChainedStartupCrashLoopPolicy.State? { lock.withLock { consumedState } }
        var proof: Bool? { lock.withLock { proofResult } }
        var error: Error? { lock.withLock { operationError } }
    }

    private func makeStore() -> (ChainedDeviceEligibilityStore, FakeItems) {
        let items = FakeItems()
        return (ChainedDeviceEligibilityStore(items: items), items)
    }

    @discardableResult
    private func settleTermination(
        in store: ChainedDeviceEligibilityStore,
        from snapshot: ChainedDeviceEligibilityStore.Snapshot,
        sessionRanAndStoppedCleanly: Bool,
        isStillWanted: () -> Bool = { true }
    ) throws -> Bool {
        try store.settleTermination(
            owningLifecycleID: snapshot.activeSessionLifecycleID,
            sessionRanAndStoppedCleanly: sessionRanAndStoppedCleanly,
            isStillWanted: isStillWanted)
    }

    @discardableResult
    private func recordChainedSurrender(
        in store: ChainedDeviceEligibilityStore,
        from snapshot: ChainedDeviceEligibilityStore.Snapshot,
        reasonLogValue: String,
        isStillWanted: () -> Bool = { true }
    ) throws -> Bool {
        try store.recordChainedSurrender(
            owningLifecycleID: snapshot.activeSessionLifecycleID,
            reasonLogValue: reasonLogValue,
            isStillWanted: isStillWanted)
    }

    // MARK: - Read classification

    /// Absent items are genuine defaults: never opted in, never a strike, no dead session.
    func testAnEmptyStoreReadsAsTheDefaults() {
        let (store, _) = makeStore()
        XCTAssertEqual(
            store.read(),
            .snapshot(
                ChainedDeviceEligibilityStore.Snapshot(
                    experimentalOverrideEnabled: false,
                    backoffState: .clean,
                    uncleanTerminationMarkerIsSet: false,
                    surrenderReasonLogValue: nil
                )))
    }

    func testValuesRoundTripThroughTheStore() throws {
        let (store, _) = makeStore()
        try store.setExperimentalOverrideEnabled(true)
        var state = ChainedStartupCrashLoopPolicy.State.clean
        state = ChainedStartupCrashLoopPolicy.unprovenExitDetected(in: state)
        try store.saveBackoffState(state)
        guard case .snapshot(let beforeMark) = store.read() else {
            return XCTFail("setup read failed")
        }
        try store.markChainedSessionStarted(
            from: beforeMark, buildIdentity: "test-build", lifecycleID: "round-trip")

        XCTAssertEqual(
            store.read(),
            .snapshot(
                ChainedDeviceEligibilityStore.Snapshot(
                    experimentalOverrideEnabled: true,
                    backoffState: state,
                    uncleanTerminationMarkerIsSet: true,
                    surrenderReasonLogValue: nil,
                    activeSessionBuildIdentity: "test-build",
                    activeSessionLifecycleID: "round-trip"
                )))
    }

    func testAStaleEligibleSnapshotCannotInstallAMarkerAfterTheLiveBreakerTrips() throws {
        let (store, _) = makeStore()
        let staleEligible = try snapshot(of: store)
        let tripped = ChainedStartupCrashLoopPolicy.State(
            consecutiveUnprovenExits:
                ChainedStartupCrashLoopPolicy.consecutiveUnprovenExitsBeforeTrip,
            hasTripped: true)
        try store.saveBackoffState(tripped)

        XCTAssertFalse(
            try store.markChainedSessionStarted(
                from: staleEligible, buildIdentity: "build-a", lifecycleID: "stale-start"))
        let current = try snapshot(of: store)
        XCTAssertEqual(current.backoffState, tripped)
        XCTAssertFalse(current.uncleanTerminationMarkerIsSet)
    }

    func testAStaleEligibleSnapshotCannotInstallAMarkerAfterALiveSurrender() throws {
        let (store, _) = makeStore()
        let staleEligible = try snapshot(of: store)
        try recordChainedSurrender(
            in: store, from: staleEligible, reasonLogValue: "budget-exhausted")

        XCTAssertFalse(
            try store.markChainedSessionStarted(
                from: staleEligible, buildIdentity: "build-a", lifecycleID: "stale-start"))
        let current = try snapshot(of: store)
        XCTAssertTrue(current.isSurrenderSuppressed)
        XCTAssertFalse(current.uncleanTerminationMarkerIsSet)
    }

    func testABuildReplacementDoesNotTurnAStaleMarkerIntoACrashLoopStrike() throws {
        let (store, _) = makeStore()
        let beforeStart = try snapshot(of: store)
        try store.markChainedSessionStarted(
            from: beforeStart, buildIdentity: "build-a", lifecycleID: "lifecycle-a")

        let state = try store.consumeUncleanTerminationEvidence(
            from: try snapshot(of: store), currentBuildIdentity: "build-b")

        XCTAssertEqual(state.backoffState, .clean)
        XCTAssertFalse(try snapshot(of: store).uncleanTerminationMarkerIsSet)
    }

    func testAProvenHealthySessionDoesNotTurnLifecycleChurnIntoACrashLoopStrike() throws {
        let (store, items) = makeStore()
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-a")
        let markerBeforeProof = items.peek(ChainedDeviceEligibilityStore.terminationRecordAccount)
        XCTAssertTrue(
            try store.markChainedSessionProvenHealthy(
                buildIdentity: "build-a", lifecycleID: "lifecycle-a"))
        XCTAssertEqual(
            items.peek(ChainedDeviceEligibilityStore.terminationRecordAccount),
            markerBeforeProof,
            "forwarding proof rewrote the shared lifecycle marker, so a retired callback can "
                + "clobber a replacement provider between its read and write")

        let state = try store.consumeUncleanTerminationEvidence(
            from: try snapshot(of: store), currentBuildIdentity: "build-a")

        XCTAssertEqual(state.backoffState, .clean)
        XCTAssertFalse(try snapshot(of: store).uncleanTerminationMarkerIsSet)
    }

    func testAnAbandonedForwardingProofStandsDownBeforeWriting() throws {
        let (store, items) = makeStore()
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-a")
        var isStillWanted = true
        items.afterLoad = { account in
            guard account
                == ChainedDeviceEligibilityStore.forwardingProofAccount(
                    lifecycleID: "lifecycle-a")
            else { return }
            isStillWanted = false
        }

        XCTAssertFalse(
            try store.markChainedSessionProvenHealthy(
                buildIdentity: "build-a", lifecycleID: "lifecycle-a",
                isStillWanted: { isStillWanted }))
        XCTAssertNil(
            items.peek(
                ChainedDeviceEligibilityStore.forwardingProofAccount(
                    lifecycleID: "lifecycle-a")),
            "a proof whose bounded caller timed out still mutated Keychain")
        XCTAssertFalse(try snapshot(of: store).activeSessionWasProvenHealthy)
    }

    func testAStaleForwardingCallbackCannotProveANewerLifecycleHealthy() throws {
        let (store, _) = makeStore()
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-a")
        _ = try store.consumeUncleanTerminationEvidence(
            from: try snapshot(of: store), currentBuildIdentity: "build-a")
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-b")

        XCTAssertFalse(
            try store.markChainedSessionProvenHealthy(
                buildIdentity: "build-a", lifecycleID: "lifecycle-a"))
        XCTAssertFalse(try snapshot(of: store).activeSessionWasProvenHealthy)
    }

    func testConsumptionRechecksProofAfterItsSnapshotWasCaptured() throws {
        let (store, _) = makeStore()
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-a")
        let replacementSnapshot = try snapshot(of: store)

        XCTAssertTrue(
            try store.markChainedSessionProvenHealthy(
                buildIdentity: "build-a", lifecycleID: "lifecycle-a"))
        let state = try store.consumeUncleanTerminationEvidence(
            from: replacementSnapshot, currentBuildIdentity: "build-a")

        XCTAssertEqual(
            state.backoffState, .clean,
            "consumption classified its stale snapshot after forwarding proof had already landed")
    }

    func testAStaleConsumerCannotClearANewerLifecycleMarker() throws {
        let (store, _) = makeStore()
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-a")
        let staleSnapshot = try snapshot(of: store)
        _ = try store.consumeUncleanTerminationEvidence(
            from: staleSnapshot, currentBuildIdentity: "build-a")
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-b")

        _ = try store.consumeUncleanTerminationEvidence(
            from: staleSnapshot, currentBuildIdentity: "build-a")

        let current = try snapshot(of: store)
        XCTAssertTrue(current.uncleanTerminationMarkerIsSet)
        XCTAssertEqual(current.activeSessionLifecycleID, "lifecycle-b")
    }

    func testAStaleTeardownCannotClearANewerLifecycleMarker() throws {
        let (store, _) = makeStore()
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-a")
        let retiredLifecycle = try snapshot(of: store)
        _ = try store.consumeUncleanTerminationEvidence(
            from: retiredLifecycle, currentBuildIdentity: "build-a")
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-b")
        let replacementReadByRetiredProvider = try snapshot(of: store)

        try store.settleTermination(
            owningLifecycleID: retiredLifecycle.activeSessionLifecycleID,
            sessionRanAndStoppedCleanly: true)

        let current = try snapshot(of: store)
        XCTAssertEqual(replacementReadByRetiredProvider.activeSessionLifecycleID, "lifecycle-b")
        XCTAssertTrue(current.uncleanTerminationMarkerIsSet)
        XCTAssertEqual(current.activeSessionLifecycleID, "lifecycle-b")
    }

    func testAStaleSurrenderCannotClearANewerLifecycleMarker() throws {
        let (store, _) = makeStore()
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-a")
        let retiredLifecycle = try snapshot(of: store)
        _ = try store.consumeUncleanTerminationEvidence(
            from: retiredLifecycle, currentBuildIdentity: "build-a")
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-b")
        let replacementReadByRetiredProvider = try snapshot(of: store)

        try store.recordChainedSurrender(
            owningLifecycleID: retiredLifecycle.activeSessionLifecycleID,
            reasonLogValue: "budget-exhausted")

        let current = try snapshot(of: store)
        XCTAssertEqual(replacementReadByRetiredProvider.activeSessionLifecycleID, "lifecycle-b")
        XCTAssertTrue(current.uncleanTerminationMarkerIsSet)
        XCTAssertEqual(current.activeSessionLifecycleID, "lifecycle-b")
        XCTAssertFalse(current.isSurrenderSuppressed)
    }

    func testAStaleStartupContinuationCannotOverwriteANewerLifecycleMarker() throws {
        let (store, _) = makeStore()
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-a")
        let staleSnapshot = try snapshot(of: store)

        _ = try store.consumeUncleanTerminationEvidence(
            from: staleSnapshot, currentBuildIdentity: "build-a")
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-b")

        let staleConsumedState = try store.consumeUncleanTerminationEvidence(
            from: staleSnapshot, currentBuildIdentity: "build-a")
        let staleContinuation = ChainedDeviceEligibilityStore.Snapshot(
            experimentalOverrideEnabled: staleSnapshot.experimentalOverrideEnabled,
            backoffState: staleConsumedState.backoffState,
            uncleanTerminationMarkerIsSet: false,
            surrenderReasonLogValue: staleSnapshot.surrenderReasonLogValue)
        try store.markChainedSessionStarted(
            from: staleContinuation, buildIdentity: "build-a", lifecycleID: "lifecycle-stale")

        let current = try snapshot(of: store)
        XCTAssertTrue(current.uncleanTerminationMarkerIsSet)
        XCTAssertEqual(current.activeSessionLifecycleID, "lifecycle-b")
    }

    func testProofCannotValidateBetweenConsumptionProofReadAndWrite() throws {
        let (store, items) = makeStore()
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-a")
        let replacementSnapshot = try snapshot(of: store)
        let consumerReadProof = DispatchSemaphore(value: 0)
        let allowConsumerWrite = DispatchSemaphore(value: 0)
        let consumeFinished = DispatchSemaphore(value: 0)
        let proofAttemptedTransition = DispatchSemaphore(value: 0)
        let proofFinished = DispatchSemaphore(value: 0)
        let results = LifecycleRaceResults()

        items.afterLoad = { account in
            guard account == ChainedDeviceEligibilityStore.forwardingProofAccount(
                lifecycleID: "lifecycle-a")
            else { return }
            items.afterLoad = nil
            consumerReadProof.signal()
            allowConsumerWrite.wait()
        }

        DispatchQueue.global().async {
            do {
                let state = try store.consumeUncleanTerminationEvidence(
                    from: replacementSnapshot, currentBuildIdentity: "build-a")
                results.record(state: state.backoffState)
            } catch {
                results.record(error: error)
            }
            consumeFinished.signal()
        }
        XCTAssertEqual(consumerReadProof.wait(timeout: .now() + 1), .success)

        items.beforeLifecycleEvidenceAccess = {
            items.beforeLifecycleEvidenceAccess = nil
            proofAttemptedTransition.signal()
        }

        DispatchQueue.global().async {
            do {
                let didProve = try store.markChainedSessionProvenHealthy(
                    buildIdentity: "build-a", lifecycleID: "lifecycle-a")
                results.record(proof: didProve)
            } catch {
                results.record(error: error)
            }
            proofFinished.signal()
        }

        XCTAssertEqual(proofAttemptedTransition.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            proofFinished.wait(timeout: .now() + 0.1), .timedOut,
            "proof validated after consumption's final read but before its marker-clearing write")
        allowConsumerWrite.signal()
        XCTAssertEqual(consumeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(proofFinished.wait(timeout: .now() + 1), .success)
        XCTAssertNil(results.error)
        XCTAssertEqual(results.state?.consecutiveUnprovenExits, 1)
        XCTAssertEqual(results.proof, false)
    }

    func testRepeatedSameBuildExitsBeforeForwardingStillTripTheCrashLoopBreaker() throws {
        let (store, _) = makeStore()
        var state = ChainedStartupCrashLoopPolicy.State.clean

        for _ in 0..<ChainedStartupCrashLoopPolicy.consecutiveUnprovenExitsBeforeTrip {
            try store.markChainedSessionStarted(
                from: try snapshot(of: store), buildIdentity: "build-a",
                lifecycleID: "lifecycle-\(state.consecutiveUnprovenExits)")
            state = try store.consumeUncleanTerminationEvidence(
                from: try snapshot(of: store), currentBuildIdentity: "build-a"
            ).backoffState
        }

        XCTAssertTrue(state.hasTripped)
    }

    func testAnExplicitGuardStartResetsSuppressionsWithoutErasingTunnelEvidence() throws {
        let (store, _) = makeStore()
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-a")
        var excluded = ChainedStartupCrashLoopPolicy.State.clean
        for _ in 0..<ChainedStartupCrashLoopPolicy.consecutiveUnprovenExitsBeforeTrip {
            excluded = ChainedStartupCrashLoopPolicy.unprovenExitDetected(in: excluded)
        }
        try store.saveBackoffState(excluded)

        try store.prepareForExplicitGuardStart()

        let state = try snapshot(of: store)
        XCTAssertEqual(state.backoffState, .clean)
        XCTAssertFalse(state.isSurrenderSuppressed)
        XCTAssertTrue(state.uncleanTerminationMarkerIsSet)
        XCTAssertEqual(state.activeSessionLifecycleID, "lifecycle-a")

        _ = try store.settleTermination(
            owningLifecycleID: "lifecycle-a", sessionRanAndStoppedCleanly: false)
        try recordChainedSurrender(
            in: store, from: try snapshot(of: store), reasonLogValue: "budget-exhausted")
        try store.prepareForExplicitGuardStart()
        XCTAssertFalse(try snapshot(of: store).isSurrenderSuppressed)
    }

    func testExplicitGuardStartCannotClearAReplacementLifecycleMarker() throws {
        let (store, items) = makeStore()
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-a")
        let replacementSnapshot = try snapshot(of: store)
        let explicitStartReadRecord = DispatchSemaphore(value: 0)
        let allowExplicitStartWrite = DispatchSemaphore(value: 0)
        let explicitStartFinished = DispatchSemaphore(value: 0)
        let replacementStartAttemptedTransition = DispatchSemaphore(value: 0)
        let replacementStartFinished = DispatchSemaphore(value: 0)
        let results = LifecycleRaceResults()

        items.afterLoad = { account in
            guard account == ChainedDeviceEligibilityStore.terminationRecordAccount else { return }
            items.afterLoad = nil
            explicitStartReadRecord.signal()
            allowExplicitStartWrite.wait()
        }

        DispatchQueue.global().async {
            do {
                try store.prepareForExplicitGuardStart()
            } catch {
                results.record(error: error)
            }
            explicitStartFinished.signal()
        }
        XCTAssertEqual(explicitStartReadRecord.wait(timeout: .now() + 1), .success)

        items.beforeLifecycleEvidenceAccess = {
            items.beforeLifecycleEvidenceAccess = nil
            replacementStartAttemptedTransition.signal()
        }

        DispatchQueue.global().async {
            do {
                let consumed = try store.consumeUncleanTerminationEvidence(
                    from: replacementSnapshot, currentBuildIdentity: "build-a")
                try store.markChainedSessionStarted(
                    from: consumed, buildIdentity: "build-a",
                    lifecycleID: "lifecycle-b")
            } catch {
                results.record(error: error)
            }
            replacementStartFinished.signal()
        }

        XCTAssertEqual(replacementStartAttemptedTransition.wait(timeout: .now() + 1), .success)
        let replacementFinishedBeforeReset = replacementStartFinished.wait(timeout: .now() + 0.1)
        allowExplicitStartWrite.signal()
        XCTAssertEqual(explicitStartFinished.wait(timeout: .now() + 1), .success)
        if replacementFinishedBeforeReset == .timedOut {
            XCTAssertEqual(replacementStartFinished.wait(timeout: .now() + 1), .success)
        }
        XCTAssertNil(results.error)

        let current = try snapshot(of: store)
        XCTAssertTrue(current.uncleanTerminationMarkerIsSet)
        XCTAssertEqual(current.activeSessionLifecycleID, "lifecycle-b")
    }

    func testExplicitGuardStartPreservesAProviderMarkerInstalledAfterTheUserAction() throws {
        let (store, _) = makeStore()
        let struck = ChainedStartupCrashLoopPolicy.unprovenExitDetected(in: .clean)
        try store.saveBackoffState(struck)
        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "budget-exhausted")
        let userActionBaseline = try snapshot(of: store)

        try store.prepareForExplicitGuardStart()
        try store.markChainedSessionStarted(
            from: userActionBaseline, buildIdentity: "build-a", lifecycleID: "lifecycle-live")

        let current = try snapshot(of: store)
        XCTAssertEqual(current.backoffState, .clean)
        XCTAssertFalse(current.isSurrenderSuppressed)
        XCTAssertTrue(current.uncleanTerminationMarkerIsSet)
        XCTAssertEqual(current.activeSessionLifecycleID, "lifecycle-live")
    }

    func testProviderConsumesTheLiveRecoveryStateInsteadOfItsStaleSuppression() throws {
        let (store, _) = makeStore()
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-a")
        let liveMarker = try snapshot(of: store)
        let providerSnapshot = ChainedDeviceEligibilityStore.Snapshot(
            experimentalOverrideEnabled: liveMarker.experimentalOverrideEnabled,
            backoffState: liveMarker.backoffState,
            uncleanTerminationMarkerIsSet: liveMarker.uncleanTerminationMarkerIsSet,
            surrenderReasonLogValue: "budget-exhausted",
            activeSessionBuildIdentity: liveMarker.activeSessionBuildIdentity,
            activeSessionLifecycleID: liveMarker.activeSessionLifecycleID,
            activeSessionWasProvenHealthy: liveMarker.activeSessionWasProvenHealthy)

        try store.prepareForExplicitGuardStart()
        let consumed = try store.consumeUncleanTerminationEvidence(
            from: providerSnapshot, currentBuildIdentity: "build-a")

        XCTAssertFalse(consumed.isSurrenderSuppressed)
        XCTAssertFalse(consumed.uncleanTerminationMarkerIsSet)
        XCTAssertEqual(consumed.backoffState.consecutiveUnprovenExits, 1)
    }

    func testExplicitGuardRecoveryCannotResurrectAMarkerSettledDuringItsRead() throws {
        let (store, items) = makeStore()
        try store.saveBackoffState(
            ChainedStartupCrashLoopPolicy.unprovenExitDetected(in: .clean))
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-a")
        let liveSession = try snapshot(of: store)
        let recoveryReadRecord = DispatchSemaphore(value: 0)
        let allowRecoveryWrite = DispatchSemaphore(value: 0)
        let recoveryFinished = DispatchSemaphore(value: 0)
        let settlementAttemptedTransition = DispatchSemaphore(value: 0)
        let settlementFinished = DispatchSemaphore(value: 0)
        let results = LifecycleRaceResults()

        items.afterLoad = { account in
            guard account == ChainedDeviceEligibilityStore.terminationRecordAccount else { return }
            items.afterLoad = nil
            recoveryReadRecord.signal()
            allowRecoveryWrite.wait()
        }
        DispatchQueue.global().async {
            do {
                try store.prepareForExplicitGuardStart()
            } catch {
                results.record(error: error)
            }
            recoveryFinished.signal()
        }
        XCTAssertEqual(recoveryReadRecord.wait(timeout: .now() + 1), .success)

        items.beforeLifecycleEvidenceAccess = {
            items.beforeLifecycleEvidenceAccess = nil
            settlementAttemptedTransition.signal()
        }

        DispatchQueue.global().async {
            do {
                try store.settleTermination(
                    owningLifecycleID: liveSession.activeSessionLifecycleID,
                    sessionRanAndStoppedCleanly: true)
            } catch {
                results.record(error: error)
            }
            settlementFinished.signal()
        }

        XCTAssertEqual(settlementAttemptedTransition.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            settlementFinished.wait(timeout: .now() + 0.1), .timedOut,
            "settlement interleaved with recovery instead of waiting for its record write")
        allowRecoveryWrite.signal()
        XCTAssertEqual(recoveryFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(settlementFinished.wait(timeout: .now() + 1), .success)
        XCTAssertNil(results.error)
        XCTAssertFalse(try snapshot(of: store).uncleanTerminationMarkerIsSet)
    }

    func testExplicitGuardRecoveryCannotEraseASurrenderThatFinishesAfterIt() throws {
        let (store, items) = makeStore()
        try store.saveBackoffState(
            ChainedStartupCrashLoopPolicy.unprovenExitDetected(in: .clean))
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "build-a", lifecycleID: "lifecycle-a")
        let liveSession = try snapshot(of: store)
        let recoveryReadRecord = DispatchSemaphore(value: 0)
        let allowRecoveryWrite = DispatchSemaphore(value: 0)
        let recoveryFinished = DispatchSemaphore(value: 0)
        let surrenderAttemptedTransition = DispatchSemaphore(value: 0)
        let surrenderFinished = DispatchSemaphore(value: 0)
        let results = LifecycleRaceResults()

        items.afterLoad = { account in
            guard account == ChainedDeviceEligibilityStore.terminationRecordAccount else { return }
            items.afterLoad = nil
            recoveryReadRecord.signal()
            allowRecoveryWrite.wait()
        }
        DispatchQueue.global().async {
            do {
                try store.prepareForExplicitGuardStart()
            } catch {
                results.record(error: error)
            }
            recoveryFinished.signal()
        }
        XCTAssertEqual(recoveryReadRecord.wait(timeout: .now() + 1), .success)

        items.beforeLifecycleEvidenceAccess = {
            items.beforeLifecycleEvidenceAccess = nil
            surrenderAttemptedTransition.signal()
        }

        DispatchQueue.global().async {
            do {
                try store.recordChainedSurrender(
                    owningLifecycleID: liveSession.activeSessionLifecycleID,
                    reasonLogValue: "budget-exhausted")
            } catch {
                results.record(error: error)
            }
            surrenderFinished.signal()
        }

        XCTAssertEqual(surrenderAttemptedTransition.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            surrenderFinished.wait(timeout: .now() + 0.1), .timedOut,
            "surrender interleaved with recovery instead of waiting for its record write")
        allowRecoveryWrite.signal()
        XCTAssertEqual(recoveryFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(surrenderFinished.wait(timeout: .now() + 1), .success)
        XCTAssertNil(results.error)
        let current = try snapshot(of: store)
        XCTAssertFalse(current.uncleanTerminationMarkerIsSet)
        XCTAssertEqual(current.surrenderReasonLogValue, "budget-exhausted")
    }

    func testALegacyMemoryExclusionMigratesToAUsableState() throws {
        let (store, items) = makeStore()
        let legacy = Data(
            """
            {"backoffState":{"consecutiveUncleanTerminations":3,"isExcluded":true},"uncleanTerminationMarkerIsSet":true,"surrenderReasonLogValue":"budget-exhausted","autoRecoveryEpochs":[]}
            """.utf8)
        items.plant(legacy, account: ChainedDeviceEligibilityStore.terminationRecordAccount)

        let migrated = try snapshot(of: store)

        XCTAssertEqual(migrated.backoffState, .clean)
        XCTAssertTrue(migrated.uncleanTerminationMarkerIsSet)
        XCTAssertEqual(migrated.surrenderReasonLogValue, "budget-exhausted")
    }

    func testStartingFromALegacyExclusionPersistsTheMigratedCleanState() throws {
        let (store, items) = makeStore()
        let legacy = Data(
            """
            {"backoffState":{"consecutiveUncleanTerminations":3,"isExcluded":true},"uncleanTerminationMarkerIsSet":false,"surrenderReasonLogValue":null,"autoRecoveryEpochs":[]}
            """.utf8)
        items.plant(legacy, account: ChainedDeviceEligibilityStore.terminationRecordAccount)

        let migrated = try snapshot(of: store)
        XCTAssertEqual(migrated.backoffState, .clean)
        XCTAssertTrue(
            try store.markChainedSessionStarted(
                from: migrated, buildIdentity: "current-build", lifecycleID: "current-session"))

        let started = try snapshot(of: store)
        XCTAssertEqual(
            started.backoffState, .clean,
            "installing the current marker resurrected the schema-0 sticky exclusion")
        XCTAssertTrue(
            try settleTermination(
                in: store, from: started, sessionRanAndStoppedCleanly: true))
        XCTAssertEqual(try snapshot(of: store).backoffState, .clean)
    }

    /// A refusing Keychain is UNAVAILABILITY, never a snapshot of defaults.
    ///
    /// The pre-first-unlock boot: reporting defaults here reads a sub-floor opted-in
    /// device's override as "off", which the latch refuses as `.insufficientMemory`, which
    /// the app's reconcile treats as durable and CLEARS the stored preference over.
    func testARefusingKeychainReadsAsUnavailableNeverAsDefaults() {
        let (store, items) = makeStore()
        items.refusesReads = true
        XCTAssertEqual(store.read(), .unavailable("keychain-unavailable"))
    }

    /// A malformed override byte is unavailability too: `false` deletes a preference and
    /// `true` claims an opt-in the user never made, so neither guess is offered.
    func testAMalformedOverrideIsUnavailabilityNotAPreference() {
        let (store, items) = makeStore()
        items.plant(Data([7]), account: ChainedDeviceEligibilityStore.overrideAccount)
        XCTAssertEqual(store.read(), .unavailable("override-malformed"))

        items.plant(Data([0, 1]), account: ChainedDeviceEligibilityStore.overrideAccount)
        XCTAssertEqual(store.read(), .unavailable("override-malformed"))
    }

    /// A structurally corrupt termination record resets to `.clean` — DELIBERATELY the
    /// opposite of the override's treatment. Garbage-as-a-value for the override destroys
    /// a user preference irreversibly; garbage-as-clean here re-opens a safety net that
    /// re-closes by itself (a genuinely thrashing device re-excludes in three strikes),
    /// while unavailability would wedge chained mode behind a permanently unreadable blob
    /// wearing a transient refusal.
    func testACorruptTerminationRecordResetsToCleanRatherThanWedging() {
        let (store, items) = makeStore()
        items.plant(
            Data("not json".utf8),
            account: ChainedDeviceEligibilityStore.terminationRecordAccount)

        XCTAssertEqual(
            store.read(),
            .snapshot(
                ChainedDeviceEligibilityStore.Snapshot(
                    experimentalOverrideEnabled: false,
                    backoffState: .clean,
                    uncleanTerminationMarkerIsSet: false,
                    surrenderReasonLogValue: nil
                )))
    }

    // MARK: - The surrender suppression (C4)

    private func snapshot(
        of store: ChainedDeviceEligibilityStore, _ label: String = "read"
    ) throws -> ChainedDeviceEligibilityStore.Snapshot {
        guard case .snapshot(let snapshot) = store.read() else {
            XCTFail("\(label) failed")
            throw ChainedDeviceStateStoreFailure.keychainRefused(errSecDecode)
        }
        return snapshot
    }

    func testASurrenderPersistsAcrossLifecyclesUntilTheUserClearsIt() throws {
        // P2 and P4's store halves in one walk: record → a fresh read (a second lifecycle)
        // still reads suppressed → clear → a fresh read may select chained again.
        let (store, _) = makeStore()
        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "budget-exhausted")

        let afterSurrender = try snapshot(of: store, "after surrender")
        XCTAssertTrue(
            afterSurrender.isSurrenderSuppressed,
            "the suppression did not survive to the next lifecycle — the surrender ends "
                + "nothing and the blackhole budget runs again on the same fault")
        XCTAssertEqual(afterSurrender.surrenderReasonLogValue, "budget-exhausted")

        try store.userResetChainedSuppressions()
        XCTAssertFalse(
            try snapshot(of: store, "after reset").isSurrenderSuppressed,
            "Reset did not clear the suppression — a dead control")
    }

    func testAUserReEnableClearsTheSurrenderButKeepsTheBackoff() throws {
        // The user's own turn-on is a fresh "try chained now": it clears a standing surrender so
        // a transient roam/sleep fallback does not persist until a manual Reset — but it must
        // NOT touch the jetsam backoff, or a casual toggle would reset the memory safety net for
        // every user (`INV-MEM-1`), an override reserved for the explicit Reset.
        let (store, _) = makeStore()
        let backoff = ChainedStartupCrashLoopPolicy.unprovenExitDetected(in: .clean)
        try store.saveBackoffState(backoff)
        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "budgetExhausted")
        XCTAssertTrue(
            try snapshot(of: store, "precondition").isSurrenderSuppressed,
            "precondition: a surrender stands")

        try store.clearStandingSurrenderOnUserReEnable()

        let after = try snapshot(of: store, "after user re-enable")
        XCTAssertFalse(
            after.isSurrenderSuppressed,
            "a user turn-on did not clear the standing surrender — the chain stays Paused until "
                + "a manual Reset, the exact device complaint")
        XCTAssertEqual(
            after.backoffState, backoff,
            "the surrender-only clear also reset the jetsam backoff — a casual toggle must not "
                + "bypass the memory safety net")
    }

    func testAUserReEnableWithNoSurrenderStandingIsANoOpWrite() throws {
        // Nothing to clear must mean no write — the same guard the Reset carries — so a turn-on
        // cannot churn the record (or race a concurrent tunnel write) when nothing is suppressed.
        let (store, items) = makeStore()
        let backoff = ChainedStartupCrashLoopPolicy.unprovenExitDetected(in: .clean)
        try store.saveBackoffState(backoff)
        let savesBefore = items.saveCount

        try store.clearStandingSurrenderOnUserReEnable()

        XCTAssertEqual(
            items.saveCount, savesBefore,
            "a re-enable with no surrender standing still wrote the record")
        XCTAssertEqual(
            try snapshot(of: store, "unchanged").backoffState, backoff,
            "the idle re-enable disturbed the backoff")
    }

    // MARK: - Hands-free auto-recovery window (Slice 2)

    func testAnAutoRecoveryClearsTheSurrenderAndRecordsTheAttempt() throws {
        // The hands-free recovery clears the standing surrender (so the restart re-latches
        // chained) AND records the attempt into the rolling window, in one write; backoff kept.
        let (store, _) = makeStore()
        let backoff = ChainedStartupCrashLoopPolicy.unprovenExitDetected(in: .clean)
        try store.saveBackoffState(backoff)
        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "budgetExhausted")

        let outcome = try store.recordSurrenderAutoRecovery(nowEpoch: 111.0)

        XCTAssertEqual(
            outcome, .restart,
            "a committed recovery against a standing surrender must proceed to restart")
        XCTAssertFalse(
            try snapshot(of: store, "after auto-recovery").isSurrenderSuppressed,
            "the auto-recovery did not clear the surrender — the restart would re-latch DNS-only")
        XCTAssertEqual(
            try store.readAutoRecoveryEpochs(), [111.0],
            "the recovery attempt (nowEpoch) was not recorded into the window")
        XCTAssertEqual(
            try snapshot(of: store, "after auto-recovery").backoffState, backoff,
            "the auto-recovery disturbed the jetsam backoff")
    }

    func testAutoRecoveryWithNoStoreRecordDoesNotRestart() throws {
        // No record at all → never surrendered → the store declines (unavailable), so a stray
        // satisfied-path signal cannot manufacture a restart against a healthy chain.
        let (store, items) = makeStore()
        let savesBefore = items.saveCount
        let outcome = try store.recordSurrenderAutoRecovery(nowEpoch: 111.0)
        XCTAssertEqual(
            outcome, .declinedUnavailable,
            "a recovery with no stored record must decline — the caller must not then cancel a "
                + "healthy (non-surrendered) session")
        XCTAssertEqual(
            items.saveCount, savesBefore, "an auto-recovery with no record still wrote")
    }

    func testAnAlreadyClearedRecordProceedsToRestartEvenWhenTheWindowIsSpent() throws {
        // The already-cleared case is handled BEFORE the cap: an aborted FINAL recovery (surrender
        // cleared, window full) still completes with a plain restart, so it cannot get stuck
        // DNS-only until an epoch ages out (Codex, PR #569 round 11).
        let (store, items) = makeStore()
        var now = 1000.0
        // Recover the cap number of times (re-surrendering between): each clears + records one
        // epoch, so after the last the surrender is cleared AND the window is full.
        for _ in 0..<ChainedSurrenderAutoRecoveryPolicy.maxRecoveriesPerWindow {
            try recordChainedSurrender(in: store,
                from: try snapshot(of: store), reasonLogValue: "budgetExhausted")
            XCTAssertEqual(try store.recordSurrenderAutoRecovery(nowEpoch: now), .restart)
            now += 1
        }
        XCTAssertFalse(
            try snapshot(of: store, "cleared").isSurrenderSuppressed, "precondition: cleared")
        XCTAssertEqual(
            try store.readAutoRecoveryEpochs().count,
            ChainedSurrenderAutoRecoveryPolicy.maxRecoveriesPerWindow, "precondition: full window")

        // Surrender still cleared + window full = the aborted-final-recovery state. It must restart.
        let savesBefore = items.saveCount
        XCTAssertEqual(
            try store.recordSurrenderAutoRecovery(nowEpoch: now), .restart,
            "an aborted final recovery must still restart despite a spent window (no new budget)")
        XCTAssertEqual(items.saveCount, savesBefore, "the already-cleared restart must not write")
    }

    func testCompleteOnlyDeclinesAStandingSurrenderButFinishesAClearedOne() throws {
        // The complete-only mode (a new lifecycle's initial update finishing an aborted handoff)
        // must DECLINE a standing surrender — a fresh startup surrender stays DNS-only until a real
        // network change — but RESTART an already-cleared one (Codex, PR #569 round 12).
        let (store, items) = makeStore()
        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "budgetExhausted")
        let savesBefore = items.saveCount

        XCTAssertEqual(
            try store.recordSurrenderAutoRecovery(nowEpoch: 1000, onlyIfAlreadyCleared: true),
            .declinedUnavailable,
            "complete-only must NOT clear a standing surrender (a fresh startup surrender stays "
                + "DNS-only)")
        XCTAssertEqual(items.saveCount, savesBefore, "complete-only cleared a standing surrender")
        XCTAssertTrue(try snapshot(of: store, "still surrendered").isSurrenderSuppressed)

        // Clear it (an aborted handoff) → complete-only now finishes it with a restart.
        try store.clearStandingSurrenderOnUserReEnable()
        XCTAssertEqual(
            try store.recordSurrenderAutoRecovery(nowEpoch: 1000, onlyIfAlreadyCleared: true),
            .restart,
            "complete-only must restart an already-cleared surrender (finish the aborted handoff)")
    }

    func testAutoRecoveryDeclinesANonTransientSurrenderReason() throws {
        // A surrender a network change cannot clear (engineUnusable etc.) must NOT be auto-recovered
        // — re-entering the broken chain just drops the working DNS-only tunnel (Codex, PR #569).
        let (store, items) = makeStore()
        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "engineUnusable")
        let savesBefore = items.saveCount

        let outcome = try store.recordSurrenderAutoRecovery(
            nowEpoch: 111.0, isRecoverableReason: { $0 == "budgetExhausted" })

        XCTAssertEqual(
            outcome, .declinedNonTransient, "a non-transient surrender reason must not be recovered")
        XCTAssertEqual(items.saveCount, savesBefore, "it cleared a non-recoverable surrender")
        XCTAssertTrue(
            try snapshot(of: store, "after decline").isSurrenderSuppressed,
            "the non-transient surrender must remain standing")
        XCTAssertEqual(
            try store.readAutoRecoveryEpochs(), [], "a declined recovery must not spend budget")
    }

    func testACapExhaustedWindowDeclinesAStandingSurrender() throws {
        // With a standing surrender and the rolling window full, the store declines (cap) and leaves
        // the surrender — the flap bound that converges a dead chain to DNS-only (Codex, PR #569).
        let (store, _) = makeStore()
        var now = 1000.0
        for _ in 0..<ChainedSurrenderAutoRecoveryPolicy.maxRecoveriesPerWindow {
            try recordChainedSurrender(in: store,
                from: try snapshot(of: store), reasonLogValue: "budgetExhausted")
            XCTAssertEqual(try store.recordSurrenderAutoRecovery(nowEpoch: now), .restart)
            now += 1
        }
        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "budgetExhausted")
        XCTAssertEqual(
            try store.recordSurrenderAutoRecovery(nowEpoch: now), .declinedCapExhausted,
            "a spent window must decline the recovery")
        XCTAssertTrue(
            try snapshot(of: store, "at cap").isSurrenderSuppressed,
            "a cap-declined surrender must remain standing")
    }

    func testANewSurrenderPreservesTheAutoRecoveryWindow() throws {
        // A surrender that FOLLOWS a recovery must keep the spent recoveries on the clock, or the
        // recover→surrender→recover loop resets its own bound and never converges.
        let (store, _) = makeStore()
        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "budgetExhausted")
        _ = try store.recordSurrenderAutoRecovery(nowEpoch: 111.0)
        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "budgetExhausted")
        XCTAssertEqual(
            try store.readAutoRecoveryEpochs(), [111.0],
            "the new surrender wiped the recovery window — the bound would never converge")
    }

    func testAPreservingWriteKeepsTheAutoRecoveryWindow() throws {
        // Every non-owning writer (here a session-start marker) preserves the window, like it
        // preserves the surrender — a preserving write that reset it hands a flap its budget back.
        let (store, _) = makeStore()
        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "budgetExhausted")
        _ = try store.recordSurrenderAutoRecovery(nowEpoch: 111.0)
        try markStarted(store)
        XCTAssertEqual(
            try store.readAutoRecoveryEpochs(), [111.0],
            "a preserving write reset the recovery window")
    }

    func testARecordWrittenBeforeTheAutoRecoveryFieldDecodesToAnEmptyWindow() throws {
        // Decode-tolerance: a record written before autoRecoveryEpochs existed has no such key,
        // and a synthesized Decodable would throw keyNotFound — losing the surrender with it.
        let (store, items) = makeStore()
        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "budgetExhausted")
        let raw = try XCTUnwrap(
            items.peek(ChainedDeviceEligibilityStore.terminationRecordAccount))
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        obj.removeValue(forKey: "autoRecoveryEpochs")
        items.plant(
            try JSONSerialization.data(withJSONObject: obj),
            account: ChainedDeviceEligibilityStore.terminationRecordAccount)
        XCTAssertEqual(
            try store.readAutoRecoveryEpochs(), [], "an older record must read an empty window")
        XCTAssertTrue(
            try snapshot(of: store, "old record").isSurrenderSuppressed,
            "the missing key threw and lost the whole record — the surrender vanished with it")
    }

    func testAnAutoRecoveryAbandonedByAStaleLifecycleDoesNotClearTheSurrender() throws {
        // The recovery WRITE is gated on the originating lifecycle: if `isStillWanted` turns false
        // (a newer lifecycle started) after the store reads the surrender fresh, it must NOT clear
        // it — a stale task wiping a newer lifecycle's surrender would let the next restart
        // re-enter the dead chained path (Codex, PR #569).
        let (store, items) = makeStore()
        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "budgetExhausted")
        let savesBefore = items.saveCount

        let outcome = try store.recordSurrenderAutoRecovery(
            nowEpoch: 111.0, isStillWanted: { false })

        XCTAssertEqual(
            outcome, .declinedUnavailable, "an abandoned recovery must decline, so no cancel")
        XCTAssertEqual(
            items.saveCount, savesBefore, "an abandoned recovery still wrote — it cleared a "
                + "surrender it no longer owns")
        XCTAssertTrue(
            try snapshot(of: store, "after abandoned recovery").isSurrenderSuppressed,
            "the abandoned recovery cleared the surrender anyway")
    }

    func testASurrenderAbandonedAfterItsWindowReadDoesNotLand() throws {
        // recordChainedSurrender now reads the recovery window (a Keychain round-trip); a bounded
        // caller's timeout landing inside it must NOT let the surrender write proceed, or it
        // overwrites a Reset/newer lifecycle that landed meanwhile (Codex, PR #569 / PR #508).
        let (store, items) = makeStore()
        let snap = try snapshot(of: store)
        let savesBefore = items.saveCount
        try recordChainedSurrender(in: store,
            from: snap, reasonLogValue: "budgetExhausted", isStillWanted: { false })
        XCTAssertEqual(items.saveCount, savesBefore, "an abandoned surrender still wrote")
        XCTAssertFalse(
            try snapshot(of: store, "after abandoned surrender").isSurrenderSuppressed,
            "the abandoned surrender landed despite the caller moving on")
    }

    func testAUserResetAfterARecoveryClearsTheSpentWindow() throws {
        // After a committed recovery the record is surrender=nil + epochs=[spent]. A user Reset
        // that lands (e.g. during a flap) must reset that spent window to [] — both to give a manual
        // retry a fresh budget and so nothing can silently re-pause the user (Codex, PR #569).
        let (store, _) = makeStore()
        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "budgetExhausted")
        _ = try store.recordSurrenderAutoRecovery(nowEpoch: 111.0)
        XCTAssertEqual(try store.readAutoRecoveryEpochs(), [111.0], "precondition: a spent window")

        try store.userResetChainedSuppressions()

        XCTAssertFalse(
            try snapshot(of: store, "after reset").isSurrenderSuppressed, "surrender must stay clear")
        XCTAssertEqual(
            try store.readAutoRecoveryEpochs(), [],
            "the Reset did not clear the spent recovery window")
    }

    func testAUserReEnableResetsASpentWindowEvenWithNoSurrender() throws {
        // After a SUCCESSFUL recovery the record is surrender=nil + epochs=[spent]. A user turn-on
        // must still reset that spent budget, or a fresh manual retry inherits fewer auto attempts.
        let (store, _) = makeStore()
        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "budgetExhausted")
        _ = try store.recordSurrenderAutoRecovery(nowEpoch: 111.0)
        XCTAssertFalse(try snapshot(of: store, "post-recovery").isSurrenderSuppressed)
        XCTAssertEqual(
            try store.readAutoRecoveryEpochs(), [111.0], "precondition: a spent budget")

        try store.clearStandingSurrenderOnUserReEnable()

        XCTAssertEqual(
            try store.readAutoRecoveryEpochs(), [],
            "a user turn-on did not reset the spent recovery window — the manual retry inherits a "
                + "depleted budget")
    }

    /// A bounded caller that gave up mid-transition must not have its write land.
    ///
    /// The fence lives INSIDE the transition, between its own Keychain read and its write,
    /// because an outer check cannot cover that read: a timeout landing inside it would
    /// still let the settle proceed, clearing a marker the NEXT lifecycle wrote and
    /// overwriting its backoff (Codex, PR #508).
    func testASettleAbandonedMidTransitionDoesNotLand() throws {
        let (store, items) = makeStore()
        try markStarted(store)
        let marked = try snapshot(of: store, "setup read")
        let savesBefore = items.saveCount

        try settleTermination(in: store,
            from: marked, sessionRanAndStoppedCleanly: true, isStillWanted: { false })

        XCTAssertEqual(
            items.saveCount, savesBefore,
            "an abandoned settle still wrote — a late write can clear the next "
                + "lifecycle's marker and overwrite its backoff")
        XCTAssertTrue(
            try snapshot(of: store, "after abandoned settle").uncleanTerminationMarkerIsSet,
            "the marker this settle would have cleared must survive an abandoned write")
    }

    func testTheResetRevivesTheJetsamToleranceAlongsideTheSurrender() throws {
        // ONE working reset for BOTH suppressions. An excluded device with no surrender is
        // the case a surrender-only Reset leaves dead: the control reports success while the
        // latch keeps refusing on `startupCrashLoop`. The backoff goes through
        // `explicitRetryRequested`, so count and exclusion clear together — a re-enable that kept the
        // counter at its threshold would re-exclude on the very next unclean termination.
        let (store, _) = makeStore()
        var state = ChainedStartupCrashLoopPolicy.State.clean
        for _ in 0..<ChainedStartupCrashLoopPolicy.consecutiveUnprovenExitsBeforeTrip {
            state = ChainedStartupCrashLoopPolicy.unprovenExitDetected(in: state)
        }
        XCTAssertTrue(state.hasTripped, "precondition: the device is excluded")
        try store.saveBackoffState(state)

        try store.userResetChainedSuppressions()

        let after = try snapshot(of: store, "after reset")
        XCTAssertEqual(
            after.backoffState, .clean,
            "the Reset left the exclusion (or its counter) standing — a dead control for "
                + "the jetsam half")

        // The MARKER survives a Reset: it is evidence of a death, not a suppression, and a
        // Reset racing a live chained session must not erase the crash the safety net is
        // mid-way through witnessing. It costs one strike against the restored tolerance.
        try store.markChainedSessionStarted(
            from: after, buildIdentity: "test-build", lifecycleID: "reset-a")
        try store.userResetChainedSuppressions()
        // The reset above is a no-op (nothing suppressed); set the breaker while the marker is
        // live so the reset write path itself is the thing proven to preserve tunnel evidence.
        try store.saveBackoffState(
            ChainedStartupCrashLoopPolicy.unprovenExitDetected(in: .clean))
        try store.userResetChainedSuppressions()
        XCTAssertTrue(
            try snapshot(of: store, "marker after reset").uncleanTerminationMarkerIsSet,
            "the Reset erased a pending death marker — that death no longer counts")
    }

    func testTheSurrenderSettlesTheMarkerInTheSameWrite() throws {
        // The crash-window class, closed by representation: the two-item shape needed a
        // second write to settle the marker, and a kill between the writes left marker +
        // suppression together — counted by the next launch as a jetsam death, so repeated
        // surrender/Reset cycles could exclude a device that never jetsammed (Codex,
        // PR #505). One write carries both facts; no interruption can separate them. The
        // streak is untouched — a surrender is evidence of neither coping nor thrashing.
        let (store, items) = makeStore()
        var state = ChainedStartupCrashLoopPolicy.State.clean
        state = ChainedStartupCrashLoopPolicy.unprovenExitDetected(in: state)
        try store.saveBackoffState(state)
        try markStarted(store)
        let savesBefore = items.saveCount

        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "budget-exhausted")

        XCTAssertEqual(items.saveCount, savesBefore + 1, "the surrender took more than one write")
        let after = try snapshot(of: store, "after surrender")
        XCTAssertTrue(after.isSurrenderSuppressed)
        XCTAssertFalse(
            after.uncleanTerminationMarkerIsSet,
            "the marker survived the surrender write — the crash window is back")
        XCTAssertEqual(after.backoffState, state, "the surrender moved the strike count")

        // And the launch after it consumes nothing: no residue state can exist.
        let consumed = try store.consumeUncleanTerminationEvidence(
            from: after, currentBuildIdentity: "test-build")
        XCTAssertEqual(
            consumed.backoffState, state,
            "a controlled surrender was counted as a jetsam death")
    }

    func testEveryRecordRewriteCarriesTheSuppression() throws {
        // The single-record shape makes every rewrite a place the suppression could be
        // silently dropped — so every writer carries it from the live transactional record.
        // Dropping it re-enters the mode the notice said turned itself off.
        let (store, _) = makeStore()
        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "budget-exhausted")

        // The teardown funnel of the surrendered session (settle, unclean shape).
        try settleTermination(in: store,
            from: try snapshot(of: store), sessionRanAndStoppedCleanly: false)
        XCTAssertTrue(
            try snapshot(of: store).isSurrenderSuppressed,
            "the teardown settle dropped the suppression")

        // A Settings-side backoff save while suppressed.
        try store.saveBackoffState(.clean)
        XCTAssertTrue(
            try snapshot(of: store).isSurrenderSuppressed,
            "the backoff save dropped the suppression")
    }

    func testAnUnreadableStoreIsNeverReadAsNotSuppressed() {
        // The suppression rides the same snapshot as the other terms, so a refusing
        // Keychain answers `unavailable` — and the latch's `deviceStateUnavailable` guard
        // shadows the placeholder. What must never happen is a bare `false` synthesized
        // from unreadability: that is the fail-open direction, and it re-enters the mode
        // the notice said turned itself off.
        let (store, items) = makeStore()
        items.refusesReads = true
        XCTAssertEqual(store.read(), .unavailable("keychain-unavailable"))
    }

    func testATeardownSettleCannotResurrectAClearedSuppression() throws {
        // The tunnel's teardown reads its snapshot, the user Resets mid-teardown, and the
        // settle then writes the stale reason back — the Reset appears to succeed and the
        // next lifecycle is still DNS-only (Codex, PR #505). Only the two owning
        // transitions write the suppression; every other writer preserves what the STORE
        // holds, re-read at write time.
        let (store, _) = makeStore()
        try markStarted(store)
        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "budget-exhausted")

        // The teardown's snapshot, taken while still suppressed.
        let teardownSnapshot = try snapshot(of: store, "teardown read")
        XCTAssertTrue(teardownSnapshot.isSurrenderSuppressed)

        // The user Resets before the teardown's settle lands.
        try store.userResetChainedSuppressions()

        try settleTermination(in: store,
            from: teardownSnapshot, sessionRanAndStoppedCleanly: true)

        XCTAssertFalse(
            try snapshot(of: store, "after settle").isSurrenderSuppressed,
            "the teardown settle wrote a stale suppression back over the user's Reset — the "
                + "Reset reports success and the next lifecycle is still DNS-only")
    }

    func testEveryPreservingWriterReReadsTheSuppressionRatherThanCarryingIt() throws {
        // The same hazard through the other three preserving writers, each with a stale
        // snapshot taken before the Reset.
        let (store, _) = makeStore()
        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "budget-exhausted")
        let stale = try snapshot(of: store, "stale read")
        try store.userResetChainedSuppressions()

        try store.markChainedSessionStarted(
            from: stale, buildIdentity: "test-build", lifecycleID: "preserve-a")
        XCTAssertFalse(
            try snapshot(of: store).isSurrenderSuppressed,
            "marking a session resurrected a cleared suppression")

        try store.saveBackoffState(.clean)
        XCTAssertFalse(
            try snapshot(of: store).isSurrenderSuppressed,
            "a backoff save resurrected a cleared suppression")

        // Consume needs a marker to act on; take a fresh snapshot for the marker but keep
        // the stale suppression by rebuilding it.
        try store.markChainedSessionStarted(
            from: try snapshot(of: store), buildIdentity: "test-build", lifecycleID: "preserve-b")
        let staleWithMarker = ChainedDeviceEligibilityStore.Snapshot(
            experimentalOverrideEnabled: false,
            backoffState: .clean,
            uncleanTerminationMarkerIsSet: true,
            surrenderReasonLogValue: "budget-exhausted")
        _ = try store.consumeUncleanTerminationEvidence(
            from: staleWithMarker, currentBuildIdentity: "test-build")
        XCTAssertFalse(
            try snapshot(of: store).isSurrenderSuppressed,
            "consuming evidence resurrected a cleared suppression")
    }

    func testAResetRacingTheTunnelCannotInventAResidueState() throws {
        // The two-item shape let a Connect-On-Demand launch read the OLD record beside the
        // NEW suppression item — marker set, suppression absent, a state that never
        // existed — and record a false strike (Codex, PR #505 round 2). With one record,
        // every read observes some record that was actually written: this walk pins the
        // Reset to ONE load and ONE save with no delete, which is the whole window.
        let (store, items) = makeStore()
        var state = ChainedStartupCrashLoopPolicy.State.clean
        state = ChainedStartupCrashLoopPolicy.unprovenExitDetected(in: state)
        try store.saveBackoffState(state)
        try markStarted(store)
        try recordChainedSurrender(in: store,
            from: try snapshot(of: store), reasonLogValue: "budget-exhausted")
        let savesBefore = items.saveCount

        try store.userResetChainedSuppressions()

        XCTAssertEqual(items.saveCount, savesBefore + 1, "the Reset took more than one write")
        let after = try snapshot(of: store, "after reset")
        XCTAssertFalse(after.isSurrenderSuppressed)
        XCTAssertFalse(
            after.uncleanTerminationMarkerIsSet,
            "the surrender had settled the marker; the Reset resurrected it")
        XCTAssertEqual(
            after.backoffState, .clean,
            "the Reset must restore the full jetsam tolerance in the SAME write that clears "
                + "the surrender — one working reset, not two half-built ones")

        // A Reset with nothing to clear writes nothing — it must not clobber a concurrent
        // tunnel-side settle with a stale record.
        let savesAfterFirst = items.saveCount
        try store.userResetChainedSuppressions()
        XCTAssertEqual(items.saveCount, savesAfterFirst, "an idle Reset rewrote the record")
    }

    func testTheStoreAndTheLatchComposeAcrossASurrenderedLifecycle() throws {
        // The end-to-end P2/P4 walk at the substrate level: what the provider's latch reads
        // is what the store persisted, with every other term favourable — so the only thing
        // deciding chained-vs-DNS-only across these three lifecycles is the suppression.
        let (store, _) = makeStore()
        let upstream = try ChainedUpstreamConfiguration(
            endpointHost: "vpn.example.com",
            endpointPort: 51_820,
            peerPublicKey: Data(1...32).base64EncodedString(),
            clientAddress: "10.64.0.5",
            allowedIPs: ["0.0.0.0/0"])

        func resolveLifecycle() -> TunnelDataPathLatch.Resolution {
            guard case .snapshot(let snapshot) = store.read() else {
                XCTFail("store unreadable mid-walk")
                return TunnelDataPathLatch.Resolution(mode: .dnsOnly, refusal: .deviceStateUnavailable)
            }
            return TunnelDataPathLatch.resolve(
                configurationIsUnreadable: false,
                chainedUpstreamEnabled: true,
                buildSupportsChainedDataPath: true,
                hasLavaSecurityPlus: true,
                physicalMemoryBytes: ChainedAvailability.minimumPhysicalMemoryBytes,
                deviceLocalStateIsUnavailable: false,
                experimentalOverrideEnabled: snapshot.experimentalOverrideEnabled,
                hasStartupCrashLoopTripped: snapshot.backoffState.hasTripped,
                isSurrenderSuppressed: snapshot.isSurrenderSuppressed,
                readyUpstream: upstream
            )
        }

        XCTAssertEqual(resolveLifecycle().mode, .chainedUpstream(upstream), "pre-surrender")

        guard case .snapshot(let preSurrender) = store.read() else { return XCTFail("read failed") }
        try recordChainedSurrender(in: store, from: preSurrender, reasonLogValue: "budget-exhausted")
        XCTAssertEqual(resolveLifecycle().refusal, .chainedSurrendered, "post-surrender restart")
        XCTAssertEqual(resolveLifecycle().refusal, .chainedSurrendered, "a further lifecycle")

        try store.userResetChainedSuppressions()
        XCTAssertEqual(resolveLifecycle().mode, .chainedUpstream(upstream), "post-Reset")
    }

    // MARK: - Consuming evidence

    private func markStarted(_ store: ChainedDeviceEligibilityStore) throws {
        guard case .snapshot(let snapshot) = store.read() else {
            return XCTFail("read failed before marking")
        }
        try store.markChainedSessionStarted(
            from: snapshot, buildIdentity: "test-build", lifecycleID: UUID().uuidString)
    }

    func testConsumingEvidenceAdvancesAndClearsTheMarkerInOneWrite() throws {
        let (store, _) = makeStore()
        try markStarted(store)
        guard case .snapshot(let snapshot) = store.read() else {
            return XCTFail("setup read failed")
        }

        let advanced = try store.consumeUncleanTerminationEvidence(
            from: snapshot, currentBuildIdentity: "test-build")

        XCTAssertEqual(advanced.backoffState.consecutiveUnprovenExits, 1)
        guard case .snapshot(let after) = store.read() else { return XCTFail("reread failed") }
        XCTAssertFalse(
            after.uncleanTerminationMarkerIsSet,
            "the marker survived its own consumption, so the same death counts again")
        XCTAssertEqual(
            after.backoffState, advanced.backoffState, "the advanced state was not persisted")
    }

    func testConsumingWithoutAMarkerIsANoOp() throws {
        let (store, items) = makeStore()
        var state = ChainedStartupCrashLoopPolicy.State.clean
        state = ChainedStartupCrashLoopPolicy.unprovenExitDetected(in: state)
        try store.saveBackoffState(state)
        let savesBefore = items.saveCount
        guard case .snapshot(let snapshot) = store.read() else {
            return XCTFail("setup read failed")
        }

        let result = try store.consumeUncleanTerminationEvidence(
            from: snapshot, currentBuildIdentity: "test-build")

        XCTAssertEqual(result.backoffState, state, "a markerless start changed the state")
        XCTAssertEqual(items.saveCount, savesBefore, "a markerless start wrote to the Keychain")
    }

    /// An interrupted transition changes NOTHING — atomic by representation, not by
    /// ordering. The two-item shape had to choose which half a kill between writes would
    /// corrupt (a lost strike versus a double count), and review found a third corruption
    /// on the clean-stop path; with both halves in one record, a failed write leaves the
    /// marker AND the count exactly as they were, and the same death is counted exactly
    /// once whenever the write finally lands.
    func testAnInterruptedConsumeChangesNothing() throws {
        let (store, items) = makeStore()
        try markStarted(store)
        guard case .snapshot(let snapshot) = store.read() else {
            return XCTFail("setup read failed")
        }

        items.refusesSaves = true
        XCTAssertThrowsError(
            try store.consumeUncleanTerminationEvidence(
                from: snapshot, currentBuildIdentity: "test-build"))
        items.refusesSaves = false

        guard case .snapshot(let after) = store.read() else { return XCTFail("reread failed") }
        XCTAssertTrue(
            after.uncleanTerminationMarkerIsSet,
            "the marker vanished across a failed write, so the death it recorded is lost")
        XCTAssertEqual(
            after.backoffState.consecutiveUnprovenExits, 0,
            "the count advanced across a failed write, so a retried consume double-counts")
    }

    /// The same one-write guarantee on the settlement side: a failed clean-stop settle
    /// leaves the marker set WITH its strikes, never a cleared marker whose streak reset
    /// vanished — the split that compounds non-consecutive crashes into a premature
    /// exclusion.
    func testAnInterruptedCleanStopSettleChangesNothing() throws {
        let (store, items) = makeStore()
        var state = ChainedStartupCrashLoopPolicy.State.clean
        state = ChainedStartupCrashLoopPolicy.unprovenExitDetected(in: state)
        state = ChainedStartupCrashLoopPolicy.unprovenExitDetected(in: state)
        try store.saveBackoffState(state)
        try markStarted(store)
        guard case .snapshot(let snapshot) = store.read() else {
            return XCTFail("setup read failed")
        }

        items.refusesSaves = true
        XCTAssertThrowsError(
            try settleTermination(in: store, from: snapshot, sessionRanAndStoppedCleanly: true))
        items.refusesSaves = false

        guard case .snapshot(let after) = store.read() else { return XCTFail("reread failed") }
        XCTAssertTrue(after.uncleanTerminationMarkerIsSet)
        XCTAssertEqual(after.backoffState.consecutiveUnprovenExits, 2)
    }

    /// The settlement's two shapes: a clean stop clears the marker AND resets the streak;
    /// a failed or cancelled start clears only the marker, so its strikes survive.
    func testSettlementResetsTheStreakOnlyForASessionThatRan() throws {
        let (store, _) = makeStore()
        var state = ChainedStartupCrashLoopPolicy.State.clean
        state = ChainedStartupCrashLoopPolicy.unprovenExitDetected(in: state)
        try store.saveBackoffState(state)
        try markStarted(store)
        guard case .snapshot(let cancelled) = store.read() else {
            return XCTFail("setup read failed")
        }
        try settleTermination(in: store, from: cancelled, sessionRanAndStoppedCleanly: false)
        guard case .snapshot(let afterCancel) = store.read() else {
            return XCTFail("reread failed")
        }
        XCTAssertFalse(afterCancel.uncleanTerminationMarkerIsSet)
        XCTAssertEqual(
            afterCancel.backoffState.consecutiveUnprovenExits, 1,
            "a cancelled start reset the streak, erasing evidence of a crashing device")

        try markStarted(store)
        guard case .snapshot(let clean) = store.read() else { return XCTFail("read failed") }
        try settleTermination(in: store, from: clean, sessionRanAndStoppedCleanly: true)
        guard case .snapshot(let afterClean) = store.read() else {
            return XCTFail("reread failed")
        }
        XCTAssertFalse(afterClean.uncleanTerminationMarkerIsSet)
        XCTAssertEqual(
            afterClean.backoffState.consecutiveUnprovenExits, 0,
            "a clean stop did not reset the streak")
    }

    /// Three consumed markers exclude, end to end through the store.
    func testThreeConsumedMarkersExcludeTheDevice() throws {
        let (store, _) = makeStore()
        for _ in 0..<ChainedStartupCrashLoopPolicy.consecutiveUnprovenExitsBeforeTrip {
            try markStarted(store)
            guard case .snapshot(let snapshot) = store.read() else {
                return XCTFail("read failed mid-walk")
            }
            _ = try store.consumeUncleanTerminationEvidence(
                from: snapshot, currentBuildIdentity: "test-build")
        }
        guard case .snapshot(let final) = store.read() else { return XCTFail("final read failed") }
        XCTAssertTrue(final.backoffState.hasTripped)
    }

    // MARK: - Production item attributes

    private let group = "ABCDE12345.com.lavasec.app.chained-upstream"
    private let lifecycleEvidenceLockURL = URL(
        fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
    ).appendingPathComponent("chained-device-state-test.lock")

    func testTheItemsAreAfterFirstUnlockThisDeviceOnly() {
        let store = ChainedDeviceStateKeychainItemStore(
            accessGroup: group, lifecycleEvidenceLockURL: lifecycleEvidenceLockURL)
        let query = store.addQuery(
            account: ChainedDeviceEligibilityStore.overrideAccount, data: Data([1]))

        XCTAssertEqual(
            query[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            "the class is the founder decision of 2026-07-30: restore-safety enforced by the "
                + "OS, readable on a locked-screen Connect-On-Demand start, unreadable only "
                + "pre-first-unlock where chained mode cannot start anyway")
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testEveryQueryCarriesTheSharedAccessGroupAndItsOwnService() {
        let store = ChainedDeviceStateKeychainItemStore(
            accessGroup: group, lifecycleEvidenceLockURL: lifecycleEvidenceLockURL)
        let query = store.addQuery(
            account: ChainedDeviceEligibilityStore.terminationRecordAccount, data: Data([1]))

        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, group)
        XCTAssertEqual(
            query[kSecAttrService as String] as? String,
            ChainedDeviceStateKeychainItemStore.keychainService)
        // A SEPARATE service from the rotation store, whose orphan sweep enumerates its
        // service's accounts in order to DELETE them. Mutable eligibility state stays out
        // of that enumeration by construction, not by prefix discipline.
        XCTAssertNotEqual(
            ChainedDeviceStateKeychainItemStore.keychainService,
            ChainedUpstreamSecretNaming.keychainService)
    }
}
