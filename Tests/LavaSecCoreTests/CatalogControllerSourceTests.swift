import XCTest

/// App-target source contracts for the catalog single-flight peel. The SPM test target cannot
/// instantiate `CatalogController`, so these pins stay narrow: task ownership and wiring that the
/// compiler cannot observe, while catalog presentation behavior remains in executable value tests.
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
        XCTAssertTrue(controller.contains("private var syncTask: Task<CatalogSyncTransactionResult, Never>?"))
        XCTAssertTrue(controller.contains("private var activeOperationID: LatencyOperationID?"))
        XCTAssertTrue(
            controller.contains("@Published private(set) var syncState: CatalogPresentationState.Sync"))
        XCTAssertTrue(controller.contains("var isSyncInFlight: Bool"))
        XCTAssertTrue(controller.contains("syncTask != nil"))
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
            "didSnapshotIdentityChangeAfterSync",
        ]
        for helper in hubTransactionHelpers {
            XCTAssertFalse(
                controller.contains(helper),
                "CatalogController must not acquire the hub transaction helper \(helper)."
            )
        }
    }

    func testSyncCoalescesFollowersButOnlyCreatorForwardsCancellation() throws {
        let source = try readSource(.catalogController)
        let sync = try sourceBlock(
            in: source,
            startingAt: "func sync(",
            endingBefore: "func awaitCompletion() async"
        )
        let follower = try sourceBlock(
            in: sync,
            startingAt: "if let syncTask {",
            endingBefore: "let operationID = LatencyOperationID.make()"
        )
        let creator = try sourceBlock(
            in: sync,
            startingAt: "let operationID = LatencyOperationID.make()"
        )

        XCTAssertTrue(follower.contains("_ = await syncTask.value"))
        XCTAssertTrue(follower.contains("return"), "A follower must not start a second transaction.")
        XCTAssertFalse(
            follower.contains("withTaskCancellationHandler"),
            "Cancelling a coalesced follower must not cancel another caller's shared sync."
        )

        XCTAssertTrue(creator.contains("let task = Task { @MainActor"))
        XCTAssertTrue(creator.contains("[weak self, weak hub = self.hub]"))
        XCTAssertTrue(creator.contains("guard self != nil, let hub else"))
        XCTAssertTrue(creator.contains("hub.performCatalogSyncTransaction("))
        XCTAssertTrue(creator.contains("await withTaskCancellationHandler"))
        XCTAssertTrue(creator.contains("task.cancel()"))
        XCTAssertTrue(creator.contains("complete(operationID: operationID, result: result)"))

        let taskInstall = try XCTUnwrap(creator.range(of: "syncTask = task")?.lowerBound)
        let operationInstall = try XCTUnwrap(creator.range(of: "activeOperationID = operationID")?.lowerBound)
        let stateInstall = try XCTUnwrap(creator.range(of: "syncState = .syncing")?.lowerBound)
        let firstAwait = try XCTUnwrap(creator.range(of: "await withTaskCancellationHandler")?.lowerBound)
        XCTAssertLessThan(
            taskInstall, firstAwait, "The task must be visible synchronously before suspension.")
        XCTAssertLessThan(
            operationInstall, firstAwait, "The operation fence must be installed before suspension.")
        XCTAssertLessThan(stateInstall, firstAwait, "In-flight presentation must publish before suspension.")
    }

    func testAwaitCompletionJoinsTheOwnedTaskWithoutPolling() throws {
        let source = try readSource(.catalogController)
        let awaitCompletion = try sourceBlock(
            in: source,
            startingAt: "func awaitCompletion() async",
            endingBefore: "func complete("
        )

        XCTAssertTrue(awaitCompletion.contains("guard let syncTask else"))
        XCTAssertTrue(awaitCompletion.contains("await syncTask.value"))
        for pollingAnchor in ["Task.sleep", "Task.yield", "while ", "repeat {", "Timer", "DispatchQueue"] {
            XCTAssertFalse(
                awaitCompletion.contains(pollingAnchor),
                "awaitCompletion must join the owned task directly, not poll with \(pollingAnchor)."
            )
        }
    }

    func testCompletionIsOperationIDFencedBeforeItClearsTaskAndPresentationState() throws {
        let source = try readSource(.catalogController)
        let completion = try sourceBlock(in: source, startingAt: "func complete(")

        XCTAssertTrue(completion.contains("operationID: LatencyOperationID"))
        XCTAssertTrue(completion.contains("result: CatalogSyncTransactionResult"))
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "guard activeOperationID == operationID else",
                    "syncTask = nil",
                    "activeOperationID = nil",
                    "syncState",
                ], in: completion))
    }

    func testHubOwnsTheWholeTransactionAndReleasesBeforeProtectionRestore() throws {
        let source = try readSource(.appViewModel)
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
            "didSnapshotIdentityChangeAfterSync",
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
        let source = try readSource(.appViewModel)
        let readerBlocks: [(String, String, Int, Int)] = [
            ("func switchToFilter(id:", "private enum SwitchPublication", 1, 0),
            ("private func prepareSwitchPublication(", "private func warmReusableSnapshotForSwitch(", 1, 0),
            ("private func startOnboardingBlocklistSyncIfNeeded(", "func selectOnboardingBlocklist(", 1, 0),
            ("func selectOnboardingBlocklist(", "private func deferralReasonForInPlaceBlocklistEdit(", 1, 0),
            ("func toggleBlocklist(", "func addCustomBlocklist(displayName:", 1, 0),
            ("func addCustomBlocklist(displayName:", "func removeCustomBlocklist(", 2, 0),
            ("private func startQAInternetBlocklistSyncIfNeeded(", "func applyAdminQAAction(", 1, 1),
            ("private func enableProtection(", "private func disableProtection(", 1, 1),
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
        let source = try readSource(.appViewModel)
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
        let filters = try [
            readSource(.filtersView),
            readSource(.filterMyListView),
        ].joined(separator: "\n")
        let app = try readSource(.lavaSecApp)
        let previews = try readSource(.developerPreviewViews)
        let myList = try sourceBlock(
            in: filters,
            startingAt: "struct MyListCover: View",
            endingBefore: "private enum BlockedDomainSheet"
        )
        let productionRoot = try sourceBlock(
            in: app,
            startingAt: "private var productionRoot: some View",
            endingBefore: "#if DEBUG\nprivate enum LavaLiveDNSSmokeState"
        )
        let previewRoot = try sourceBlock(
            in: previews,
            startingAt: "struct WebsiteAssetCaptureRootView: View",
            endingBefore: "struct GentleProtectionDiagram: View"
        )

        XCTAssertTrue(myList.contains("@EnvironmentObject private var catalog: CatalogController"))
        XCTAssertTrue(myList.contains(".disabled(catalog.isSyncInFlight)"))
        XCTAssertEqual(
            sourceOccurrenceCount(
                of: "@EnvironmentObject private var catalog: CatalogController",
                in: filters
            ),
            2
        )
        XCTAssertEqual(sourceOccurrenceCount(of: "await catalog.sync()", in: filters), 4)
        XCTAssertEqual(sourceOccurrenceCount(of: "catalog.isSyncInFlight", in: filters), 1)

        XCTAssertEqual(
            sourceOccurrenceCount(of: ".environmentObject(viewModel.catalog)", in: productionRoot), 1)
        XCTAssertEqual(sourceOccurrenceCount(of: ".environmentObject(viewModel.catalog)", in: app), 1)
        XCTAssertTrue(app.contains("await viewModel.syncCatalog(isBackgroundRefresh: true)"))
        XCTAssertFalse(app.contains("CatalogController(hub:"))

        XCTAssertEqual(sourceOccurrenceCount(of: ".environmentObject(viewModel.catalog)", in: previewRoot), 1)
        XCTAssertEqual(sourceOccurrenceCount(of: ".environmentObject(viewModel.catalog)", in: previews), 1)
        XCTAssertFalse(previews.contains("CatalogController(hub:"))

        for unrelated in [SourceFile.guardView, .settingsView] {
            XCTAssertFalse(try readSource(unrelated).contains("CatalogController"))
        }
        XCTAssertFalse(try readDiagnosticsSourceAggregate().contains("CatalogController"))
    }
}
