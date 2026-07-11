import LavaSecFilterPipeline
import LavaSecKit
import SwiftUI

/// The outcome of one complete catalog synchronization transaction.
enum CatalogSyncTransactionResult: Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
}

/// The single hub-owned transaction that catalog synchronization coordinates.
///
/// Keeping the transaction whole prevents this controller from acquiring persistence,
/// tunnel-notification, cache-recovery, or protection-restoration responsibilities.
@MainActor
protocol CatalogSyncTransactionBridging: AnyObject {
    func performCatalogSyncTransaction(
        isBackgroundRefresh: Bool,
        operationID: LatencyOperationID
    ) async -> CatalogSyncTransactionResult
}

/// Owns catalog synchronization liveness and presentation state.
@MainActor
final class CatalogController: ObservableObject {
    @Published private(set) var syncState: CatalogPresentationState.Sync = .idle

    private weak var hub: (any CatalogSyncTransactionBridging)?
    private var syncTask: Task<CatalogSyncTransactionResult, Never>?
    private var activeOperationID: LatencyOperationID?

    init(hub: any CatalogSyncTransactionBridging) {
        self.hub = hub
    }

    deinit {
        syncTask?.cancel()
    }

    var isSyncInFlight: Bool {
        syncTask != nil
    }

    /// Starts one catalog transaction, or joins the transaction already in flight.
    ///
    /// A coalesced follower only observes the shared result. Cancellation is forwarded
    /// exclusively by the creator so cancelling a follower cannot stop another caller's work.
    func sync(isBackgroundRefresh: Bool = false) async {
        if let syncTask {
            _ = await syncTask.value
            return
        }

        let operationID = LatencyOperationID.make()
        activeOperationID = operationID
        syncState = .syncing

        let task = Task { @MainActor [weak self, weak hub = self.hub] in
            guard self != nil, let hub else {
                return CatalogSyncTransactionResult.cancelled
            }

            let result = await hub.performCatalogSyncTransaction(
                isBackgroundRefresh: isBackgroundRefresh,
                operationID: operationID
            )
            self?.complete(operationID: operationID, result: result)
            return result
        }
        syncTask = task

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        complete(operationID: operationID, result: result)
    }

    /// Joins the controller-owned transaction without changing its cancellation lifetime.
    func awaitCompletion() async {
        guard let syncTask else {
            return
        }

        _ = await syncTask.value
    }

    /// Releases the matching transaction and publishes its terminal presentation state.
    ///
    /// The hub calls this before it performs protection restoration because restoration can
    /// reenter catalog coordination. Releasing first lets that reentrant path start a new
    /// operation instead of joining the transaction that is already finishing. The task calls
    /// this again after the whole bridge operation returns as a defensive fallback; the operation
    /// ID fence makes that second completion, and any stale completion, harmless.
    func complete(
        operationID: LatencyOperationID,
        result: CatalogSyncTransactionResult
    ) {
        guard activeOperationID == operationID else {
            return
        }

        syncTask = nil
        activeOperationID = nil
        switch result {
        case .succeeded:
            syncState = .succeeded
        case .failed:
            syncState = .failed
        case .cancelled:
            syncState = .idle
        }
    }
}
