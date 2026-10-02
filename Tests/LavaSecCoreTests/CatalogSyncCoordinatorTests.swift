import XCTest
import LavaSecAppServices
import LavaSecFilterPipeline
import LavaSecKit

@MainActor
final class CatalogSyncCoordinatorTests: XCTestCase {
    func testFollowersShareOneTransactionAndCannotCancelItsCreator() async {
        let probe = CatalogTransactionProbe()
        var phases: [CatalogPresentationState.Sync] = []
        let coordinator = CatalogSyncCoordinator(performTransaction: probe.perform,
            onStateChange: { phases.append($0) })
        let creator = Task { await coordinator.sync(isBackgroundRefresh: true) }
        guard await probe.waitForStarts(1) else { return }
        let followerEntered = CatalogTestSignal()
        let follower = Task {
            followerEntered.signal()
            await coordinator.sync()
        }
        await followerEntered.wait()
        follower.cancel()
        XCTAssertTrue(coordinator.isSyncInFlight)
        XCTAssertEqual(coordinator.syncState, .syncing)
        XCTAssertEqual(probe.starts.map(\.background), [true])
        probe.finish(0, with: .succeeded)
        await creator.value
        await follower.value
        XCTAssertEqual(probe.starts.count, 1)
        XCTAssertEqual(probe.observedCancellation, [false])
        XCTAssertFalse(coordinator.isSyncInFlight)
        XCTAssertEqual(phases, [.syncing, .succeeded])
    }

    func testCreatorCancellationReachesTheTransactionAndAllJoinersFinish() async {
        let probe = CatalogTransactionProbe()
        let coordinator = CatalogSyncCoordinator(performTransaction: probe.perform)
        let creator = Task { await coordinator.sync() }
        guard await probe.waitForStarts(1) else { return }
        let followerEntered = CatalogTestSignal()
        let follower = Task {
            followerEntered.signal()
            await coordinator.sync()
        }
        await followerEntered.wait()
        creator.cancel()
        probe.finish(0, with: .succeeded)
        await creator.value
        await follower.value
        XCTAssertEqual(probe.observedCancellation, [true])
        XCTAssertEqual(coordinator.syncState, .idle)
        XCTAssertFalse(coordinator.isSyncInFlight)
    }

    func testAwaitCompletionWaitsForTheOwnedTransactionWithoutCancellingIt() async {
        let probe = CatalogTransactionProbe()
        let coordinator = CatalogSyncCoordinator(performTransaction: probe.perform)
        let creator = Task { await coordinator.sync() }
        guard await probe.waitForStarts(1) else { return }
        let entered = CatalogTestSignal()
        var finished = false
        let observer = Task {
            entered.signal()
            await coordinator.awaitCompletion()
            finished = true
        }
        await entered.wait()
        XCTAssertFalse(finished)
        observer.cancel()
        probe.finish(0, with: .failed)
        await creator.value
        await observer.value
        XCTAssertTrue(finished)
        XCTAssertEqual(probe.observedCancellation, [false])
        XCTAssertEqual(coordinator.syncState, .failed)
        await coordinator.awaitCompletion()
    }

    func testEarlyReleaseAllowsReentrancyAndRejectsTheOlderCompletion() async {
        let probe = CatalogTransactionProbe()
        var phases: [CatalogPresentationState.Sync] = []
        let coordinator = CatalogSyncCoordinator(performTransaction: probe.perform,
            onStateChange: { phases.append($0) })
        probe.beforeReturn = { [weak coordinator] index, operationID in
            guard index == 0, let coordinator else { return }
            // Mirrors the hub's pre-restore release and a restore that synchronizes again.
            coordinator.complete(operationID: operationID, result: .succeeded)
            await coordinator.sync(isBackgroundRefresh: true)
        }
        let creator = Task { await coordinator.sync() }
        guard await probe.waitForStarts(1) else { return }
        probe.finish(0, with: .failed)
        guard await probe.waitForStarts(2) else { return }
        XCTAssertTrue(coordinator.isSyncInFlight)
        XCTAssertEqual(coordinator.syncState, .syncing)
        XCTAssertNotEqual(probe.starts[0].operationID, probe.starts[1].operationID)
        coordinator.complete(operationID: probe.starts[0].operationID, result: .cancelled)
        XCTAssertTrue(coordinator.isSyncInFlight)
        XCTAssertEqual(coordinator.syncState, .syncing)
        probe.finish(1, with: .succeeded)
        await creator.value
        XCTAssertFalse(coordinator.isSyncInFlight)
        XCTAssertEqual(coordinator.syncState, .succeeded,
            "the older transaction returns failure after the newer one succeeds")
        XCTAssertEqual(phases, [.syncing, .succeeded, .syncing, .succeeded])
    }

    func testImmediateResultsAlwaysReleaseAndPublishTheMatchingTerminalState() async {
        for (result, expected) in [
            (CatalogSyncTransactionResult.succeeded, CatalogPresentationState.Sync.succeeded),
            (.failed, .failed), (.cancelled, .idle),
        ] {
            let coordinator = CatalogSyncCoordinator(performTransaction: { _, _ in result })
            await coordinator.sync()
            XCTAssertFalse(coordinator.isSyncInFlight)
            XCTAssertEqual(coordinator.syncState, expected)
            await coordinator.sync()
            XCTAssertEqual(coordinator.syncState, expected)
        }
    }
}

@MainActor
private final class CatalogTestSignal {
    private var signalled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        signalled = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

@MainActor
private final class CatalogTransactionProbe {
    struct Start {
        let background: Bool
        let operationID: LatencyOperationID
    }
    private(set) var starts: [Start] = []
    private(set) var observedCancellation: [Bool] = []
    var beforeReturn: (@MainActor (Int, LatencyOperationID) async -> Void)?
    private var pending: [Int: CheckedContinuation<CatalogSyncTransactionResult, Never>] = [:]
    private var startWaiters: [(Int, XCTestExpectation)] = []

    func perform(_ background: Bool, _ operationID: LatencyOperationID) async -> CatalogSyncTransactionResult {
        let index = starts.count
        starts.append(Start(background: background, operationID: operationID))
        let result = await withCheckedContinuation { continuation in
            pending[index] = continuation
            let ready = startWaiters.filter { $0.0 <= starts.count }
            startWaiters.removeAll { $0.0 <= starts.count }
            for (_, waiter) in ready { waiter.fulfill() }
        }
        observedCancellation.append(Task.isCancelled)
        if let beforeReturn { await beforeReturn(index, operationID) }
        return Task.isCancelled ? .cancelled : result
    }

    func waitForStarts(_ count: Int) async -> Bool {
        if starts.count >= count { return true }
        let entered = XCTestExpectation(description: "catalog transaction \(count) starts")
        startWaiters.append((count, entered))
        let result = await XCTWaiter.fulfillment(of: [entered], timeout: 3)
        startWaiters.removeAll { $0.1 === entered }
        XCTAssertEqual(result, .completed, "coordination must not deadlock before the next transaction")
        return result == .completed
    }

    func finish(_ index: Int, with result: CatalogSyncTransactionResult) {
        pending.removeValue(forKey: index)?.resume(returning: result)
    }
}
