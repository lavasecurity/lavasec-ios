import XCTest

/// Pins only the app/package bridge; executable coordinator tests cover task lifetime and reentrancy.
final class CatalogControllerSourceTests: XCTestCase {
    func testBridgeExposesOneWholeTransactionAndControllerOwnsOnlySyncCoordination() throws {
        let source = try readSource(.catalogController)
        let bridge = try sourceBlock(
            in: source,
            startingAt: "protocol CatalogSyncTransactionBridging: AnyObject",
            endingBefore: "final class CatalogController: ObservableObject"
        )
        let controller = try sourceBlock(
            in: source,
            startingAt: "final class CatalogController: ObservableObject"
        )

        XCTAssertEqual(
            sourceOccurrenceCount(of: "func ", in: bridge),
            1,
            "The controller bridge must expose one auditable catalog transaction, not hub mutation fragments."
        )
        XCTAssertTrue(bridge.contains("func performCatalogSyncTransaction("))
        XCTAssertTrue(bridge.contains("isBackgroundRefresh: Bool"))
        XCTAssertTrue(bridge.contains("operationID: LatencyOperationID"))
        XCTAssertTrue(bridge.contains("async -> CatalogSyncTransactionResult"))

        XCTAssertTrue(controller.contains("private weak var hub: (any CatalogSyncTransactionBridging)?"))
        XCTAssertFalse(
            controller.contains("unowned"),
            "A controller retained independently by SwiftUI must not trap after its hub deallocates."
        )
        XCTAssertTrue(controller.contains("private lazy var coordinator = CatalogSyncCoordinator("))
        XCTAssertFalse(controller.contains("private var syncTask:"))
        XCTAssertFalse(controller.contains("private var activeOperationID:"))
        XCTAssertTrue(
            controller.contains("@Published private(set) var syncState: CatalogPresentationState.Sync"))
        XCTAssertTrue(controller.contains("var isSyncInFlight: Bool"))
        XCTAssertTrue(controller.contains("coordinator.isSyncInFlight"))
        XCTAssertFalse(controller.contains("AppViewModel"))

        let hubTransactionHelpers = [
            "applySyncResults",
            "applyCatalogSyncResult",
            "publishBackgroundRefreshArtifacts",
            "warmNonActiveFiltersInBackground",
            "persistSharedState",
            "notifyTunnelSnapshotUpdated",
            "loadCachedCatalogAfterSyncFailure",
            "restoreProtectionIfNeeded",
            "snapshotNeedsPublicationAfterSync",
        ]
        for helper in hubTransactionHelpers {
            XCTAssertFalse(
                controller.contains(helper),
                "CatalogController must not acquire the hub transaction helper \(helper)."
            )
        }
    }

    func testControllerDelegatesCoordinationAndMirrorsPublishedState() throws {
        let source = sourceCodeOnly(try readSource(.catalogController))
        XCTAssertTrue(source.contains("await coordinator.sync(isBackgroundRefresh: isBackgroundRefresh)"))
        XCTAssertTrue(source.contains("await coordinator.awaitCompletion()"))
        XCTAssertTrue(source.contains("coordinator.complete(operationID: operationID, result: result)"))
        XCTAssertTrue(source.contains("onStateChange: { [weak self] in self?.syncState = $0 }"))
        XCTAssertTrue(source.contains("guard let hub = self?.hub else { return .cancelled }"))
        XCTAssertTrue(source.contains("return await hub.performCatalogSyncTransaction("))
    }

    func testHubOwnsTheWholeTransactionAndReleasesBeforeProtectionRestore() throws {
        let source = try readAppViewModelSource()
        let transaction = try sourceBlock(
            in: source,
            startingAt: "func performCatalogSyncTransaction(",
            endingBefore: "private struct BackgroundCatalogCacheSupersededError"
        )

        XCTAssertTrue(source.contains("extension AppViewModel: CatalogSyncTransactionBridging"))
        XCTAssertTrue(source.contains("private(set) lazy var catalog = CatalogController(hub: self)"))
        for retainedHelper in [
            "applySyncResults",
            "publishBackgroundRefreshArtifacts",
            "warmNonActiveFiltersInBackground",
            "persistSharedState",
            "notifyTunnelSnapshotUpdated",
            "loadCachedCatalogAfterSyncFailure",
            "restoreProtectionIfNeeded",
            "snapshotNeedsPublicationAfterSync",
        ] {
            XCTAssertTrue(
                transaction.contains(retainedHelper),
                "AppViewModel must retain the complete transaction helper \(retainedHelper)."
            )
        }

        let deferredCompletion = try sourceBlock(
            in: transaction,
            startingAt: "defer {",
            endingBefore: "guard let cacheURL = catalogCacheURL else {"
        )
        XCTAssertTrue(
            deferredCompletion.contains(
                "catalog.complete(operationID: operationID, result: transactionResult)"
            ),
            "Every early return must release the matching controller operation through defer."
        )
        XCTAssertEqual(
            sourceOccurrenceCount(
                of: "catalog.complete(operationID: operationID, result: transactionResult)",
                in: transaction
            ),
            2,
            "The transaction needs one deferred fallback and one explicit pre-restore release."
        )

        let completion = try XCTUnwrap(
            transaction.range(
                of: "catalog.complete(operationID: operationID, result:",
                options: .backwards
            )?.lowerBound
        )
        let restore = try XCTUnwrap(
            transaction.range(of: "restoreProtectionIfNeeded", options: .backwards)?.lowerBound
        )
        XCTAssertLessThan(
            completion,
            restore,
            "The controller must synchronously release the operation before reentrant protection restoration."
        )
    }

    func testEveryHubLivenessReaderUsesTheControllerAPI() throws {
        let source = try readAppViewModelSource()
        let readerBlocks: [(String, String, Int, Int)] = [
            ("func switchToFilter(id:", "enum SwitchPublication", 1, 0),
            ("private func prepareSwitchPublication(", "func warmReusableSnapshotForSwitch(", 1, 0),
            ("func startOnboardingBlocklistSyncIfNeeded(", "func selectOnboardingBlocklist(", 1, 1),
            ("func selectOnboardingBlocklist(", "private func deferralReasonForInPlaceBlocklistEdit(", 1, 0),
            ("func toggleBlocklist(", "func addCustomBlocklist(displayName:", 1, 0),
            ("func addCustomBlocklist(displayName:", "func removeCustomBlocklist(", 2, 0),
            ("private func startQAInternetBlocklistSyncIfNeeded(", "func applyAdminQAAction(", 1, 1),
            ("func enableProtection(", "func disableProtection(", 1, 1),
        ]

        for (start, end, expectedReads, expectedAwaits) in readerBlocks {
            let block = try sourceBlock(in: source, startingAt: start, endingBefore: end)
            XCTAssertEqual(
                sourceOccurrenceCount(of: "catalog.isSyncInFlight", in: block),
                expectedReads,
                "The liveness reader in \(start) must use the controller's synchronous truth."
            )
            XCTAssertEqual(
                sourceOccurrenceCount(of: "await catalog.awaitCompletion()", in: block),
                expectedAwaits,
                "The wait in \(start) must join through CatalogController."
            )
        }
    }

    func testAppViewModelHasNoRawCatalogTaskOrSyncStateMirror() throws {
        let source = try readAppViewModelSource()
        let syncWrapper = try sourceBlock(
            in: source,
            startingAt: "func syncCatalog(isBackgroundRefresh: Bool = false) async",
            endingBefore: "func performCatalogSyncTransaction("
        )

        XCTAssertTrue(syncWrapper.contains("await catalog.sync(isBackgroundRefresh: isBackgroundRefresh)"))
        for retiredAnchor in [
            "catalogSyncTask",
            "isCatalogSyncInFlight",
            "isSyncingCatalog",
            "waitForCatalogSyncToFinish",
            "finishCatalogSyncTask",
        ] {
            XCTAssertFalse(
                source.contains(retiredAnchor),
                "AppViewModel must not retain the raw catalog coordination mirror \(retiredAnchor)."
            )
        }
    }

    func testOnlyCatalogConsumersObserveControllerAndRootsInjectHubOwnedInstance() throws {
        let app = try readSource(.lavaSecApp)
        XCTAssertEqual(sourceOccurrenceCount(of: ".environmentObject(viewModel.catalog)", in: app), 1)
        XCTAssertTrue(app.contains("await viewModel.syncCatalog(isBackgroundRefresh: true)"))
        XCTAssertFalse(app.contains("CatalogController(hub:"))
        let bridge = try readSource(.reactNativeAppFilters)
        XCTAssertTrue(bridge.contains("await model.syncCatalog()"))
        XCTAssertFalse(bridge.contains("CatalogController(hub:"))
    }
}
