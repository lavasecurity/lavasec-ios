import XCTest

final class ProtectionLifecycleRestartSourceTests: XCTestCase {
    func testRestartRetriesOnlyBusyStateTransactionsAndStopsOnTokenLoss() throws {
        let commandService = try readSource(.lavaProtectionCommandService)
        let renewal = try sourceBlock(
            in: commandService,
            startingAt: "private static func renewProtectionLifecycleLeaseWithRetry(",
            endingBefore: "@discardableResult\n    static func releaseProtectionLifecycleLease("
        )

        XCTAssertTrue(renewal.contains("ProtectionLifecycleStateTransaction.retryingBusyRenewal"))
        XCTAssertTrue(renewal.contains("maximumBusyAttempts: protectionLifecycleStateLockMaximumBusyAttempts"))
        XCTAssertTrue(renewal.contains("retryDelayNanoseconds: protectionLifecycleStateLockRetryDelayNanoseconds"))
        XCTAssertTrue(renewal.contains("case .renewed:"))
        XCTAssertTrue(renewal.contains("case .ownershipLost:"))
        XCTAssertTrue(renewal.contains("throw RestartError.lifecycleLeaseLost"))
        XCTAssertFalse(
            renewal.contains("try?"),
            "Restart must distinguish typed busy contention from a genuine false/token mismatch."
        )

        let automaticRestoreCleanup = try sourceBlock(
            in: commandService,
            startingAt: "static func releaseProtectionLifecycleLease(",
            endingBefore: "static func startProtectionLifecycleLeaseRenewal("
        )
        XCTAssertTrue(automaticRestoreCleanup.contains(") async -> Bool"))
        XCTAssertTrue(automaticRestoreCleanup.contains("Task.detached"))
        XCTAssertTrue(automaticRestoreCleanup.contains("ProtectionLifecycleStateTransaction.retryingBusy"))
        XCTAssertTrue(automaticRestoreCleanup.contains("maximumBusyAttempts: protectionLifecycleStateLockMaximumBusyAttempts"))
        XCTAssertTrue(automaticRestoreCleanup.contains("retryDelayNanoseconds: protectionLifecycleStateLockRetryDelayNanoseconds"))
        XCTAssertFalse(
            automaticRestoreCleanup.contains("(try? withProtectionLifecycleTransaction"),
            "Automatic-restore cleanup must not collapse the first transient busy result to false."
        )

        let stateTransaction = try sourceBlock(
            in: commandService,
            startingAt: "private static func withProtectionLifecycleTransaction",
            endingBefore: "// commandID threads"
        )
        XCTAssertTrue(stateTransaction.contains("ProtectionLifecycleStateTransaction.withRequiredExclusiveLock"))
        let lockIndex = try XCTUnwrap(
            stateTransaction.range(of: "ProtectionLifecycleStateTransaction.withRequiredExclusiveLock")?.lowerBound
        )
        let clockIndex = try XCTUnwrap(
            stateTransaction.range(of: "let transactionNow = now ?? Date()")?.lowerBound
        )
        XCTAssertLessThan(
            lockIndex,
            clockIndex,
            "The retryable state-lock probe must still acquire before sampling the transaction clock."
        )

        let cleanup = try sourceBlock(
            in: commandService,
            startingAt: "private static func finishRestartInFlight",
            endingBefore: "private static func runTunnelRestart"
        )
        XCTAssertTrue(cleanup.contains("ProtectionLifecycleStateTransaction.retryingBusy"))
        XCTAssertTrue(cleanup.contains("maximumBusyAttempts: protectionLifecycleStateLockMaximumBusyAttempts"))
        XCTAssertTrue(cleanup.contains("retryDelayNanoseconds: protectionLifecycleStateLockRetryDelayNanoseconds"))

        let claim = try sourceBlock(
            in: commandService,
            startingAt: "private static func claimRestartInFlight(",
            endingBefore: "/// Clears this Restart's exact UI deadline"
        )
        XCTAssertTrue(claim.contains("async throws -> RestartInFlightClaim?"))
        XCTAssertTrue(claim.contains("ProtectionLifecycleStateTransaction.retryingBusy"))
        XCTAssertTrue(claim.contains("maximumBusyAttempts: protectionLifecycleStateLockMaximumBusyAttempts"))
        XCTAssertTrue(claim.contains("retryDelayNanoseconds: protectionLifecycleStateLockRetryDelayNanoseconds"))
        XCTAssertFalse(
            claim.contains("try?"),
            "An initial Restart claim must propagate non-busy state errors rather than disguising them as contention."
        )
        let claimFenceIndex = try XCTUnwrap(
            claim.range(of: "acquireProtectionLifecycleMutationFence(wait: false)")?.lowerBound
        )
        let claimRetryIndex = try XCTUnwrap(
            claim.range(of: "ProtectionLifecycleStateTransaction.retryingBusy")?.lowerBound
        )
        let claimTransactionIndex = try XCTUnwrap(
            claim.range(of: "withProtectionLifecycleTransaction(now: now)")?.lowerBound
        )
        XCTAssertLessThan(claimFenceIndex, claimRetryIndex)
        XCTAssertLessThan(
            claimRetryIndex,
            claimTransactionIndex,
            "Initial Restart must retry its short state transaction only after it owns the long mutation fence."
        )
    }

    func testRestartCancellationCannotHotPollOrDispatchLateStartAndAlwaysUnwindsFence() throws {
        let commandService = try readSource(.lavaProtectionCommandService)
        let restart = try sourceBlock(
            in: commandService,
            startingAt: "private static func runTunnelRestart(",
            endingBefore: "private static let reconnectStopWaitTimeout"
        )
        let startIndex = try XCTUnwrap(restart.range(of: "connection.startVPNTunnel()")?.lowerBound)
        let stopWaitIndex = try XCTUnwrap(
            restart.range(of: "try await waitForTunnelToStop(timeout: Self.reconnectStopWaitTimeout)")?.lowerBound
        )
        let postStopCancellationIndex = try XCTUnwrap(
            restart.range(
                of: "try Task.checkCancellation()",
                range: stopWaitIndex..<restart.endIndex
            )?.lowerBound
        )
        XCTAssertLessThan(stopWaitIndex, postStopCancellationIndex)
        XCTAssertLessThan(
            postStopCancellationIndex,
            startIndex,
            "Cancellation must be rechecked after the stop wait and immediately before a new tunnel start."
        )
        XCTAssertTrue(restart.contains("try await waitForTunnelToStop"))
        XCTAssertTrue(restart.contains("try await waitForTunnelToReconnect"))

        let stopWait = try sourceBlock(
            in: commandService,
            startingAt: "private static func waitForTunnelToStop",
            endingBefore: "/// Polls the tunnel status until it has settled back"
        )
        let reconnectWait = try sourceBlock(
            in: commandService,
            startingAt: "private static func waitForTunnelToReconnect",
            endingBefore: "/// Sends the `reloadProtectionPause`"
        )
        XCTAssertTrue(stopWait.contains("async throws -> Bool"))
        XCTAssertTrue(reconnectWait.contains("async throws"))
        XCTAssertTrue(stopWait.contains("try await Task.sleep"))
        XCTAssertTrue(reconnectWait.contains("try await Task.sleep"))
        XCTAssertFalse(stopWait.contains("try? await Task.sleep"))
        XCTAssertFalse(reconnectWait.contains("try? await Task.sleep"))

        let tunnelConnection = try sourceBlock(
            in: commandService,
            startingAt: "private static func withTunnelConnection(",
            endingBefore: "/// Reads Lava's tunnel status"
        )
        XCTAssertTrue(tunnelConnection.contains("ProtectionLifecycleCallbackCancellationGate.withCancellationHandler"))
        XCTAssertTrue(tunnelConnection.contains("cancellationGate.executeUnlessCancelled"))
        XCTAssertFalse(
            tunnelConnection.contains("Task.checkCancellation"),
            "The callback has no reliable parent task context; only the explicit latch may gate its mutation."
        )
        let gateIndex = try XCTUnwrap(
            tunnelConnection.range(of: "cancellationGate.executeUnlessCancelled")?.lowerBound
        )
        let mutationIndex = try XCTUnwrap(
            tunnelConnection.range(of: "try body(manager.connection)")?.lowerBound
        )
        XCTAssertLessThan(
            gateIndex,
            mutationIndex,
            "The callback must consult the task-cancellation latch before mutating the tunnel."
        )

        let reconnect = try sourceBlock(
            in: commandService,
            startingAt: "private static func performReconnect()",
            endingBefore: "private static func restoreLiveActivityAfterRestart()"
        )
        let cancelRenewal = try XCTUnwrap(reconnect.range(of: "leaseRenewal.cancel()")?.lowerBound)
        let cleanup = try XCTUnwrap(reconnect.range(of: "await finishRestartInFlight(claimedRestart)")?.lowerBound)
        let releaseFence = try XCTUnwrap(reconnect.range(of: "claimedRestart.mutationFence.release()")?.lowerBound)
        XCTAssertLessThan(cancelRenewal, cleanup)
        XCTAssertLessThan(cleanup, releaseFence)
        XCTAssertTrue(
            reconnect.contains(
                "if didOwnRestart {\n                await restoreLiveActivityAfterRestart()\n            }\n            claimedRestart.mutationFence.release()\n            throw error"
            ),
            "An ordinary error must keep the mutation fence through its guarded restore tail."
        )
        XCTAssertTrue(
            reconnect.contains(
                "let didOwnRestart = await finishRestartInFlight(claimedRestart)\n        // Keep the same complete-operation exclusion through the final async status/UI tail.\n        if didOwnRestart {\n            await restoreLiveActivityAfterRestart()\n        }\n        claimedRestart.mutationFence.release()"
            ),
            "A successful Restart must keep the mutation fence through its guarded restore tail."
        )
    }

    func testAcceptedRestartPersistsExplicitOnUnderFenceBeforePublishingItsDeadline() throws {
        let commandService = try readSource(.lavaProtectionCommandService)
        let claim = try sourceBlock(
            in: commandService,
            startingAt: "private static func claimRestartInFlight(",
            endingBefore: "/// Clears this Restart's exact UI deadline"
        )

        let fenceIndex = try XCTUnwrap(
            claim.range(of: "acquireProtectionLifecycleMutationFence(wait: false)")?.lowerBound
        )
        let transactionIndex = try XCTUnwrap(
            claim.range(of: "withProtectionLifecycleTransaction(now: now)")?.lowerBound
        )
        let leaseIndex = try XCTUnwrap(
            claim.range(of: "store.claimExplicitRestart(")?.lowerBound
        )
        let intentIndex = try XCTUnwrap(
            claim.range(of: "ProtectionRestoreIntentStore.persist(")?.lowerBound
        )
        let deadlineIndex = try XCTUnwrap(
            claim.range(of: "defaults.set(")?.lowerBound
        )

        XCTAssertLessThan(fenceIndex, transactionIndex)
        XCTAssertLessThan(transactionIndex, leaseIndex)
        XCTAssertLessThan(
            leaseIndex,
            intentIndex,
            "A rejected duplicate Restart must not rewrite the user's durable explicit intent."
        )
        XCTAssertLessThan(
            intentIndex,
            deadlineIndex,
            "If durable explicit-on persistence fails, Restart must not publish an in-flight deadline."
        )
        XCTAssertTrue(claim.contains("isEnabled: true"))
        XCTAssertTrue(claim.contains("containerURL: containerURL"))
    }
}
