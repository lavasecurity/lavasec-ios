import Foundation
import XCTest
@testable import LavaSecKit

final class ProtectionLifecycleMutationFenceTests: XCTestCase {
    private enum SentinelError: Error {
        case original
    }

    @MainActor
    func testOwnedMutationPreservesOriginalOperationError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-lifecycle-mutation-error-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("protection-lifecycle-mutation.lock")
        do {
            try await ProtectionLifecycleMutationFence.withOwnedMutation(
                lockFileURL: lockURL,
                validateOwnership: { true },
                operation: { throw SentinelError.original }
            )
            XCTFail("The mutation's original error must propagate.")
        } catch SentinelError.original {
            // Expected.
        } catch {
            XCTFail("Expected the original mutation error, got \(error).")
        }
    }

    func testProcessDeathReleasesCrossProcessFence() throws {
        try withTemporaryDirectory(prefix: "protection-lifecycle-mutation-fence-tests") { directory in
            let python = "/usr/bin/python3"
            guard FileManager.default.isExecutableFile(atPath: python) else {
                try skipVisibly("python3 unavailable; process-death flock recovery needs a child process")
                return
            }

            let lockURL = directory.appendingPathComponent("protection-lifecycle-mutation.lock")
            let readyURL = directory.appendingPathComponent("ready")
            let script = """
            import fcntl, os, sys, time
            fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
            open(sys.argv[2], "w").close()
            while True:
                time.sleep(1)
            """
            let holder = Process()
            holder.executableURL = URL(fileURLWithPath: python)
            holder.arguments = ["-c", script, lockURL.path, readyURL.path]
            try holder.run()
            defer {
                if holder.isRunning {
                    holder.terminate()
                    holder.waitUntilExit()
                }
            }

            let deadline = Date().addingTimeInterval(20)
            while !FileManager.default.fileExists(atPath: readyURL.path), Date() < deadline {
                usleep(10_000)
            }
            guard FileManager.default.fileExists(atPath: readyURL.path) else {
                try skipVisibly("holder process did not acquire the lifecycle fence within 20s")
                return
            }

            XCTAssertNil(
                try ProtectionLifecycleMutationFence.acquire(lockFileURL: lockURL, wait: false),
                "A live owner in another process must exclude this process."
            )

            holder.terminate()
            holder.waitUntilExit()

            let recovered = try XCTUnwrap(
                ProtectionLifecycleMutationFence.acquire(lockFileURL: lockURL, wait: false),
                "Closing the owning process must let the kernel recover the fence immediately."
            )
            recovered.release()
        }
    }

    @MainActor
    func testDescendantMutationCompletesWhileOriginatingAutomaticLeaseRemainsLive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-lifecycle-descendant-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let clock = FakeProtectionClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let store = ProtectionLifecycleLeaseStore(
            storage: FakeProtectionKeyValueStore(),
            lock: ProtectionNSLock(),
            clock: clock,
            makeToken: { "automatic-owner" }
        )
        let snapshot = try store.captureExternalRestartGeneration()
        let automaticLease = try XCTUnwrap(
            store.claimAutomaticRestore(
                expectedExternalRestartGeneration: snapshot.value,
                leaseDuration: 30
            )
        )
        var mutationCount = 0

        try await ProtectionLifecycleMutationFence.withDescendantMutation(
            lockFileURL: directory.appendingPathComponent("protection-lifecycle-mutation.lock"),
            validateLocalOwnership: { true },
            validateExternalGeneration: { try store.matchesExternalRestartGeneration(snapshot) },
            operation: { mutationCount += 1 }
        )

        XCTAssertEqual(mutationCount, 1)
        XCTAssertTrue(try store.isOwned(automaticLease))
        XCTAssertTrue(try store.release(automaticLease))
        XCTAssertNotNil(try store.claimExplicitRestart(leaseDuration: 30))
    }

    @MainActor
    func testAcceptedRestartInvalidatesBothStaleGateTerminalBranches() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-lifecycle-descendant-generation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProtectionLifecycleLeaseStore(
            storage: FakeProtectionKeyValueStore(),
            lock: ProtectionNSLock(),
            makeToken: { "restart-owner" }
        )
        let staleSnapshot = try store.captureExternalRestartGeneration()
        XCTAssertNotNil(try store.claimExplicitRestart(leaseDuration: 30))
        var successMutationCount = 0
        var failureMutationCount = 0

        for isSuccessBranch in [true, false] {
            do {
                try await ProtectionLifecycleMutationFence.withDescendantMutation(
                    lockFileURL: directory.appendingPathComponent("protection-lifecycle-mutation.lock"),
                    validateLocalOwnership: { true },
                    validateExternalGeneration: {
                        try store.matchesExternalRestartGeneration(staleSnapshot)
                    },
                    operation: {
                        if isSuccessBranch {
                            successMutationCount += 1
                        } else {
                            failureMutationCount += 1
                        }
                    }
                )
                XCTFail("A gate captured before the accepted restart must be superseded.")
            } catch ProtectionLifecycleMutationFenceError.ownershipLost {
                // Expected.
            }
        }

        XCTAssertEqual(successMutationCount, 0)
        XCTAssertEqual(failureMutationCount, 0)
    }

    @MainActor
    func testSuspendedDescendantFenceRejectsRestartWithoutRotatingGenerationAfterLeaseExpiry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-lifecycle-descendant-suspension-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let clock = FakeProtectionClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let tokenSequence = DescendantFenceTokenSequence(["automatic-owner", "restart-owner"])
        let store = ProtectionLifecycleLeaseStore(
            storage: FakeProtectionKeyValueStore(),
            lock: ProtectionNSLock(),
            clock: clock,
            makeToken: { tokenSequence.next() }
        )
        let snapshot = try store.captureExternalRestartGeneration()
        XCTAssertNotNil(
            try store.claimAutomaticRestore(
                expectedExternalRestartGeneration: snapshot.value,
                leaseDuration: 30
            )
        )
        let callbackGate = DescendantMutationGate()
        let lockURL = directory.appendingPathComponent("protection-lifecycle-mutation.lock")

        let terminal = Task { @MainActor in
            try await ProtectionLifecycleMutationFence.withDescendantMutation(
                lockFileURL: lockURL,
                validateLocalOwnership: { true },
                validateExternalGeneration: {
                    try store.matchesExternalRestartGeneration(snapshot)
                },
                operation: { await callbackGate.suspend() }
            )
        }
        await callbackGate.waitUntilSuspended()
        clock.advance(seconds: 31)

        XCTAssertNil(
            try ProtectionLifecycleMutationFence.acquire(lockFileURL: lockURL, wait: false),
            "The kernel fence must remain owned after the logical lease expires."
        )
        XCTAssertEqual(try store.captureExternalRestartGeneration(), snapshot)

        await callbackGate.resume()
        try await terminal.value

        let restartFence = try XCTUnwrap(
            ProtectionLifecycleMutationFence.acquire(lockFileURL: lockURL, wait: false)
        )
        defer { restartFence.release() }
        XCTAssertNotNil(try store.claimExplicitRestart(leaseDuration: 30))
        XCTAssertNotEqual(try store.captureExternalRestartGeneration(), snapshot)
    }

    @MainActor
    func testAppLifecycleOwnerRejectsRestartWithoutRotatingGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-lifecycle-app-wins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProtectionLifecycleLeaseStore(
            storage: FakeProtectionKeyValueStore(),
            lock: ProtectionNSLock(),
            makeToken: { "restart-owner" }
        )
        let generationBefore = try store.captureExternalRestartGeneration()
        let callbackGate = DescendantMutationGate()
        let lockURL = directory.appendingPathComponent("protection-lifecycle-mutation.lock")
        let appLifecycle = Task { @MainActor in
            try await ProtectionLifecycleMutationFence.withExclusiveMutation(
                lockFileURL: lockURL,
                operation: { await callbackGate.suspend() }
            )
        }
        await callbackGate.waitUntilSuspended()

        XCTAssertNil(
            try ProtectionLifecycleMutationFence.acquire(lockFileURL: lockURL, wait: false),
            "Direct Restart must stop before its generation-rotating claim when the app owns the fence."
        )
        XCTAssertEqual(try store.captureExternalRestartGeneration(), generationBefore)

        await callbackGate.resume()
        try await appLifecycle.value
    }

    @MainActor
    func testRestartOwnerMakesAppLifecyclePerformZeroMutations() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-lifecycle-restart-wins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let lockURL = directory.appendingPathComponent("protection-lifecycle-mutation.lock")
        let restartFence = try XCTUnwrap(
            ProtectionLifecycleMutationFence.acquire(lockFileURL: lockURL, wait: false)
        )
        defer { restartFence.release() }
        var appMutationCount = 0

        do {
            try await ProtectionLifecycleMutationFence.withExclusiveMutation(
                lockFileURL: lockURL,
                operation: { appMutationCount += 1 }
            )
            XCTFail("The app lifecycle must fail closed while direct Restart owns the fence.")
        } catch ProtectionLifecycleMutationFenceError.busy {
            // Expected.
        }

        XCTAssertEqual(appMutationCount, 0)
    }

    @MainActor
    func testForegroundLifecycleWaitsAsynchronouslyForAcceptedRestartThenRuns() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-lifecycle-foreground-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let lockURL = directory.appendingPathComponent("protection-lifecycle-mutation.lock")
        var restartFence: ProtectionLifecycleMutationFenceHandle? = try XCTUnwrap(
            ProtectionLifecycleMutationFence.acquire(lockFileURL: lockURL, wait: false)
        )
        var waitProbeCount = 0
        var foregroundMutationCount = 0
        let foreground = Task { @MainActor in
            try await ProtectionLifecycleMutationFence.withExclusiveMutation(
                lockFileURL: lockURL,
                waitUntilAvailable: true,
                validateWaiting: {
                    waitProbeCount += 1
                    return true
                },
                operation: { foregroundMutationCount += 1 }
            )
        }

        while waitProbeCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(
            foregroundMutationCount,
            0,
            "A foreground OFF/reconnect must make no NE mutation while Restart owns the fence."
        )

        restartFence?.release()
        restartFence = nil
        try await foreground.value
        XCTAssertEqual(
            foregroundMutationCount,
            1,
            "The explicit foreground action must run after the accepted Restart releases."
        )
    }

    @MainActor
    func testFastGateTerminalWaitsForOriginatingForegroundActionInsteadOfBeingDropped() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-lifecycle-fast-terminal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProtectionLifecycleLeaseStore(
            storage: FakeProtectionKeyValueStore(),
            lock: ProtectionNSLock()
        )
        let snapshot = try store.captureExternalRestartGeneration()
        let lockURL = directory.appendingPathComponent("protection-lifecycle-mutation.lock")
        var foregroundFence: ProtectionLifecycleMutationFenceHandle? = try XCTUnwrap(
            ProtectionLifecycleMutationFence.acquire(lockFileURL: lockURL, wait: false)
        )
        var localValidationCount = 0
        var terminalMutationCount = 0
        let terminal = Task { @MainActor in
            try await ProtectionLifecycleMutationFence.withDescendantMutation(
                lockFileURL: lockURL,
                validateLocalOwnership: {
                    localValidationCount += 1
                    return true
                },
                validateExternalGeneration: {
                    try store.matchesExternalRestartGeneration(snapshot)
                },
                operation: { terminalMutationCount += 1 }
            )
        }

        while localValidationCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(
            terminalMutationCount,
            0,
            "A terminal must wait without touching NE while its originating action owns the fence."
        )

        foregroundFence?.release()
        foregroundFence = nil
        try await terminal.value
        XCTAssertEqual(terminalMutationCount, 1)
    }

    @MainActor
    func testTurnOffCancelsSuspendedArmBeforeWaitingForFenceThenRunsTeardown() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("protection-lifecycle-turnoff-arm-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProtectionLifecycleLeaseStore(
            storage: FakeProtectionKeyValueStore(),
            lock: ProtectionNSLock()
        )
        let snapshot = try store.captureExternalRestartGeneration()
        let lockURL = directory.appendingPathComponent("protection-lifecycle-mutation.lock")
        let saveGate = DescendantMutationGate()
        var intendedEnabled = true
        var intentRevision: UInt64 = 7
        let capturedIntentRevision = intentRevision
        var teardownIsActive = false
        var successPublicationCount = 0
        var teardownMutationCount = 0
        let arm = Task { @MainActor in
            do {
                try await ProtectionLifecycleMutationFence.withDescendantMutation(
                    lockFileURL: lockURL,
                    validateLocalOwnership: {
                        intendedEnabled && intentRevision == capturedIntentRevision
                    },
                    validateExternalGeneration: {
                        try store.matchesExternalRestartGeneration(snapshot)
                    },
                    operation: {
                        await saveGate.suspend()
                        guard !Task.isCancelled,
                              intendedEnabled,
                              intentRevision == capturedIntentRevision,
                              !teardownIsActive
                        else {
                            throw ProtectionLifecycleMutationFenceError.ownershipLost
                        }
                        successPublicationCount += 1
                    }
                )
            } catch {
                // Superseded arm exits without publishing success.
            }
        }
        await saveGate.waitUntilSuspended()

        // Mirrors the production OFF preflight: synchronously close producers, cancel, and drain
        // before trying to acquire the fence held by the non-cancellable preference callback.
        intendedEnabled = false
        intentRevision += 1
        teardownIsActive = true
        arm.cancel()
        let turnOff = Task { @MainActor in
            await arm.value
            try await ProtectionLifecycleMutationFence.withExclusiveMutation(
                lockFileURL: lockURL,
                waitUntilAvailable: true,
                operation: { teardownMutationCount += 1 }
            )
        }
        await saveGate.resume()
        try await turnOff.value

        XCTAssertEqual(successPublicationCount, 0)
        XCTAssertEqual(teardownMutationCount, 1)
    }

    private func skipVisibly(
        _ reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            XCTFail(
                "lifecycle process-death proof would silently stop running on CI: \(reason)",
                file: file,
                line: line
            )
            return
        }
        throw XCTSkip(reason)
    }
}

private final class DescendantFenceTokenSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]

    init(_ tokens: [String]) {
        self.tokens = tokens
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return tokens.removeFirst()
    }
}

private actor DescendantMutationGate {
    private var suspended = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        suspended = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSuspended() async {
        while !suspended {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
