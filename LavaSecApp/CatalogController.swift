import LavaSecAppServices
import LavaSecFilterPipeline
import LavaSecKit
import SwiftUI

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

/// Bridges catalog coordination to app presentation and the hub's complete transaction.
@MainActor
final class CatalogController: ObservableObject {
    @Published private(set) var syncState: CatalogPresentationState.Sync = .idle
    private weak var hub: (any CatalogSyncTransactionBridging)?
    private lazy var coordinator = CatalogSyncCoordinator(
        performTransaction: { [weak self] isBackgroundRefresh, operationID in
            guard let hub = self?.hub else { return .cancelled }
            return await hub.performCatalogSyncTransaction(
                isBackgroundRefresh: isBackgroundRefresh, operationID: operationID)
        },
        onStateChange: { [weak self] in self?.syncState = $0 }
    )

    init(hub: any CatalogSyncTransactionBridging) {
        self.hub = hub
    }

    var isSyncInFlight: Bool { coordinator.isSyncInFlight }

    func sync(isBackgroundRefresh: Bool = false) async {
        await coordinator.sync(isBackgroundRefresh: isBackgroundRefresh)
    }

    func awaitCompletion() async {
        await coordinator.awaitCompletion()
    }

    func complete(operationID: LatencyOperationID, result: CatalogSyncTransactionResult) {
        coordinator.complete(operationID: operationID, result: result)
    }
}
