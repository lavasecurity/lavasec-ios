import LavaSecFilterPipeline
import LavaSecKit

/// The outcome of one complete catalog synchronization transaction.
public enum CatalogSyncTransactionResult: Equatable, Sendable {
    /// The complete transaction succeeded.
    case succeeded
    /// The transaction failed.
    case failed
    /// The creator cancelled or its owner was unavailable.
    case cancelled
}

/// Coordinates one whole catalog transaction and publishes its synchronization phase.
@MainActor
public final class CatalogSyncCoordinator {
    /// Latest synchronization phase, independent of platform presentation.
    public private(set) var syncState: CatalogPresentationState.Sync = .idle

    private let performTransaction: @MainActor (Bool, LatencyOperationID) async -> CatalogSyncTransactionResult
    private let onStateChange: @MainActor (CatalogPresentationState.Sync) -> Void
    private var syncTask: Task<CatalogSyncTransactionResult, Never>?
    private var activeOperationID: LatencyOperationID?

    /// Injects one whole transaction and an optional phase observer.
    public init(
        performTransaction: @escaping @MainActor (Bool, LatencyOperationID) async -> CatalogSyncTransactionResult,
        onStateChange: @escaping @MainActor (CatalogPresentationState.Sync) -> Void = { _ in }
    ) {
        self.performTransaction = performTransaction
        self.onStateChange = onStateChange
    }

    deinit {
        syncTask?.cancel()
    }

    /// Whether a transaction is currently owned.
    public var isSyncInFlight: Bool {
        syncTask != nil
    }

    /// Starts one catalog transaction, or joins the transaction already in flight.
    ///
    /// A coalesced follower only observes the shared result. Cancellation is forwarded
    /// exclusively by the creator so cancelling a follower cannot stop another caller's work.
    public func sync(isBackgroundRefresh: Bool = false) async {
        if let syncTask {
            _ = await syncTask.value
            return
        }

        let operationID = LatencyOperationID.make()
        activeOperationID = operationID
        syncState = .syncing
        onStateChange(syncState)

        let task = Task { @MainActor [weak self] in
            guard let performTransaction = self?.performTransaction else {
                return CatalogSyncTransactionResult.cancelled
            }

            let result = await performTransaction(isBackgroundRefresh, operationID)
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

    /// Joins the coordinator-owned transaction without changing its cancellation lifetime.
    public func awaitCompletion() async {
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
    public func complete(
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
        onStateChange(syncState)
    }
}
