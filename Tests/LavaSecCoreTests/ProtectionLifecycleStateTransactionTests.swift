import Foundation
import XCTest
@testable import LavaSecKit

final class ProtectionLifecycleStateTransactionTests: XCTestCase {
    func testRetryingBusyRenewsFileBackedLeaseAfterRealCrossProcessContentionClears() async throws {
        try await withTemporaryDirectory(prefix: "protection-lifecycle-state-transaction") { directory in
            let lockURL = directory.appendingPathComponent("protection-command.lock")
            let stateURL = directory.appendingPathComponent("lifecycle-state.json")
            let lease = try Self.claimFileBackedRestartLease(stateURL: stateURL, lockURL: lockURL)
            let holder = try startLockHolder(lockURL: lockURL, directory: directory)
            defer {
                releaseLockHolder(holder)
            }

            let sawBusy = LockedFlag()
            let renewal = Task<ProtectionLifecycleLeaseRenewalResult, Error> {
                try await ProtectionLifecycleStateTransaction.retryingBusyRenewal(
                    retryDelayNanoseconds: 100_000_000
                ) {
                    do {
                        return try Self.renewFileBackedLease(
                            lease,
                            stateURL: stateURL,
                            lockURL: lockURL
                        )
                    } catch ProtectionLifecycleStateTransactionError.busy {
                        sawBusy.set()
                        throw ProtectionLifecycleStateTransactionError.busy
                    }
                }
            }

            try await waitUntilSet(sawBusy)
            releaseLockHolder(holder)

            let renewed = try await renewal.value
            XCTAssertEqual(
                renewed,
                .renewed,
                "A transient state-lock conflict must retry the same lease renewal instead of reporting a lost token."
            )
            XCTAssertTrue(
                try Self.fileBackedStore(stateURL: stateURL).isOwned(lease),
                "The successful retry must preserve the original token's ownership."
            )
        }
    }

    func testInitialRestartClaimRetriesRealStateContentionAndRetainsFenceOnSuccess() async throws {
        try await withTemporaryDirectory(prefix: "protection-lifecycle-initial-claim") { directory in
            let stateLockURL = directory.appendingPathComponent("protection-command.lock")
            let mutationFenceURL = directory.appendingPathComponent("protection-lifecycle-mutation.lock")
            let stateURL = directory.appendingPathComponent("lifecycle-state.json")
            let holder = try startLockHolder(lockURL: stateLockURL, directory: directory)
            defer {
                releaseLockHolder(holder)
            }

            let sawBusy = LockedFlag()
            let claimTask = Task<ClaimedRestartFixture?, Error> {
                try await Self.claimInitialRestartFixture(
                    stateURL: stateURL,
                    stateLockURL: stateLockURL,
                    mutationFenceURL: mutationFenceURL,
                    retryDelayNanoseconds: 100_000_000,
                    onBusy: { sawBusy.set() }
                )
            }

            try await waitUntilSet(sawBusy)
            releaseLockHolder(holder)

            let optionalClaim = try await claimTask.value
            let claim = try XCTUnwrap(optionalClaim)
            defer {
                claim.mutationFence.release()
            }
            XCTAssertTrue(
                try Self.fileBackedStore(stateURL: stateURL).isOwned(claim.lifecycleLease),
                "Once state contention clears, the initial Restart claim must install its exact lease."
            )
            let competingFence = try ProtectionLifecycleMutationFence.acquire(
                lockFileURL: mutationFenceURL,
                wait: false
            )
            XCTAssertNil(
                competingFence,
                "The accepted claim must retain the long mutation fence for the following restart work."
            )
            competingFence?.release()
        }
    }

    func testInitialRestartClaimExhaustionReleasesFenceWithoutPersistingAClaim() async throws {
        try await withTemporaryDirectory(prefix: "protection-lifecycle-initial-claim") { directory in
            let stateLockURL = directory.appendingPathComponent("protection-command.lock")
            let mutationFenceURL = directory.appendingPathComponent("protection-lifecycle-mutation.lock")
            let stateURL = directory.appendingPathComponent("lifecycle-state.json")
            let holder = try startLockHolder(lockURL: stateLockURL, directory: directory)
            defer {
                releaseLockHolder(holder)
            }

            let sawBusy = LockedFlag()
            let attemptCount = LockedCounter()
            do {
                _ = try await Self.claimInitialRestartFixture(
                    stateURL: stateURL,
                    stateLockURL: stateLockURL,
                    mutationFenceURL: mutationFenceURL,
                    maximumBusyAttempts: 2,
                    retryDelayNanoseconds: 10_000_000,
                    onBusy: {
                        attemptCount.increment()
                        sawBusy.set()
                    }
                )
                XCTFail("Initial Restart must fail closed when its state lock remains busy.")
            } catch ProtectionLifecycleStateTransactionError.busyRetryExhausted {
                // Expected.
            } catch {
                XCTFail("Expected busyRetryExhausted, got \(error).")
            }

            XCTAssertTrue(sawBusy.isSet)
            XCTAssertEqual(attemptCount.value, 2)
            let state = try Self.fileBackedStore(stateURL: stateURL)
            XCTAssertNil(try state.currentLease())
            XCTAssertNil(try state.currentExternalRestartGeneration())
            let successor = try XCTUnwrap(
                ProtectionLifecycleMutationFence.acquire(lockFileURL: mutationFenceURL, wait: false),
                "A failed initial claim must release its mutation fence for foreground lifecycle work."
            )
            successor.release()
        }
    }

    func testCancellationDuringInitialRestartClaimReleasesFenceWithoutPersistingAClaim() async throws {
        try await withTemporaryDirectory(prefix: "protection-lifecycle-initial-claim") { directory in
            let stateLockURL = directory.appendingPathComponent("protection-command.lock")
            let mutationFenceURL = directory.appendingPathComponent("protection-lifecycle-mutation.lock")
            let stateURL = directory.appendingPathComponent("lifecycle-state.json")
            let holder = try startLockHolder(lockURL: stateLockURL, directory: directory)
            defer {
                releaseLockHolder(holder)
            }

            let sawBusy = LockedFlag()
            let attemptCount = LockedCounter()
            let claimTask = Task<ClaimedRestartFixture?, Error> {
                try await Self.claimInitialRestartFixture(
                    stateURL: stateURL,
                    stateLockURL: stateLockURL,
                    mutationFenceURL: mutationFenceURL,
                    retryDelayNanoseconds: 1_000_000_000,
                    onBusy: {
                        attemptCount.increment()
                        sawBusy.set()
                    }
                )
            }

            try await waitUntilSet(sawBusy)
            claimTask.cancel()
            try await Task.sleep(nanoseconds: 100_000_000)
            releaseLockHolder(holder)

            do {
                _ = try await claimTask.value
                XCTFail("Cancellation must unwind an initial Restart claim before it can publish a lease.")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("Expected CancellationError, got \(error).")
            }

            XCTAssertEqual(
                attemptCount.value,
                1,
                "Cancellation must interrupt the initial-claim backoff instead of hot-polling into a late claim."
            )
            let state = try Self.fileBackedStore(stateURL: stateURL)
            XCTAssertNil(try state.currentLease())
            XCTAssertNil(try state.currentExternalRestartGeneration())
            let successor = try XCTUnwrap(
                ProtectionLifecycleMutationFence.acquire(lockFileURL: mutationFenceURL, wait: false),
                "Cancellation must release the initial-claim fence for foreground lifecycle work."
            )
            successor.release()
        }
    }

    func testRetryingBusyDoesNotRetryGenuineLeaseTokenMismatch() async throws {
        let storage = FakeProtectionKeyValueStore()
        let clock = FakeProtectionClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let tokens = LockedStringSequence(["stale", "successor"])
        let store = ProtectionLifecycleLeaseStore(
            storage: storage,
            lock: ProtectionNSLock(),
            clock: clock,
            makeToken: { tokens.next() }
        )
        let staleLease = try XCTUnwrap(store.claimExplicitRestart(leaseDuration: 30))
        XCTAssertTrue(try store.release(staleLease))
        XCTAssertNotNil(try store.claimExplicitRestart(leaseDuration: 30))
        let attempts = LockedCounter()

        let renewed = try await ProtectionLifecycleStateTransaction.retryingBusyRenewal {
            attempts.increment()
            return try store.renew(staleLease, leaseDuration: 30)
        }

        XCTAssertEqual(renewed, .ownershipLost)
        XCTAssertEqual(
            attempts.value,
            1,
            "A false renewal is an actual token/owner mismatch, not transient lock contention."
        )
    }

    func testCancellationDuringBusyRetryMakesNoStartAndReleasesMutationFence() async throws {
        try await withTemporaryDirectory(prefix: "protection-lifecycle-state-transaction") { directory in
            let stateLockURL = directory.appendingPathComponent("protection-command.lock")
            let mutationFenceURL = directory.appendingPathComponent("protection-lifecycle-mutation.lock")
            let holder = try startLockHolder(lockURL: stateLockURL, directory: directory)
            defer {
                releaseLockHolder(holder)
            }

            let sawBusy = LockedFlag()
            let attemptCount = LockedCounter()
            let startCount = LockedCounter()
            let restart = Task<Void, Error> {
                guard let fence = try ProtectionLifecycleMutationFence.acquire(
                    lockFileURL: mutationFenceURL,
                    wait: false
                ) else {
                    throw RestartFixtureError.mutationFenceBusy
                }
                defer {
                    fence.release()
                }

                try await ProtectionLifecycleStateTransaction.retryingBusy(
                    retryDelayNanoseconds: 1_000_000_000
                ) {
                    attemptCount.increment()
                    do {
                        return try ProtectionLifecycleStateTransaction.withRequiredExclusiveLock(
                            at: stateLockURL
                        ) {}
                    } catch ProtectionLifecycleStateTransactionError.busy {
                        sawBusy.set()
                        throw ProtectionLifecycleStateTransactionError.busy
                    }
                }

                try Task.checkCancellation()
                startCount.increment()
            }

            try await waitUntilSet(sawBusy)
            restart.cancel()
            // Keep the real state lock busy briefly after cancellation. Regressions that both
            // bypass the pre-attempt cancellation check and swallow the backoff error would
            // otherwise hot-poll until the lock clears, then reach the start.
            try await Task.sleep(nanoseconds: 100_000_000)
            releaseLockHolder(holder)

            do {
                try await restart.value
                XCTFail("A cancelled Restart must unwind before dispatching a new tunnel start.")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("Expected CancellationError, got \(error).")
            }

            XCTAssertEqual(startCount.value, 0)
            XCTAssertEqual(
                attemptCount.value,
                1,
                "Cancellation must interrupt the backoff rather than collapse it into hot polling."
            )
            let successor = try XCTUnwrap(
                ProtectionLifecycleMutationFence.acquire(lockFileURL: mutationFenceURL, wait: false),
                "Cancellation must release the Restart fence so foreground lifecycle work can proceed."
            )
            successor.release()
        }
    }

    func testExhaustedBusyRetryMakesNoStartAndReleasesMutationFence() async throws {
        try await withTemporaryDirectory(prefix: "protection-lifecycle-state-transaction") { directory in
            let stateLockURL = directory.appendingPathComponent("protection-command.lock")
            let mutationFenceURL = directory.appendingPathComponent("protection-lifecycle-mutation.lock")
            let holder = try startLockHolder(lockURL: stateLockURL, directory: directory)
            defer {
                releaseLockHolder(holder)
            }

            let sawBusy = LockedFlag()
            let attemptCount = LockedCounter()
            let startCount = LockedCounter()
            let restart = Task<Void, Error> {
                guard let fence = try ProtectionLifecycleMutationFence.acquire(
                    lockFileURL: mutationFenceURL,
                    wait: false
                ) else {
                    throw RestartFixtureError.mutationFenceBusy
                }
                defer {
                    fence.release()
                }

                try await ProtectionLifecycleStateTransaction.retryingBusy(
                    maximumBusyAttempts: 2,
                    retryDelayNanoseconds: 10_000_000
                ) {
                    attemptCount.increment()
                    do {
                        return try ProtectionLifecycleStateTransaction.withRequiredExclusiveLock(
                            at: stateLockURL
                        ) {}
                    } catch ProtectionLifecycleStateTransactionError.busy {
                        sawBusy.set()
                        throw ProtectionLifecycleStateTransactionError.busy
                    }
                }

                startCount.increment()
            }

            try await waitUntilSet(sawBusy)
            do {
                try await restart.value
                XCTFail("A Restart must fail closed when a peer keeps the state lock busy.")
            } catch ProtectionLifecycleStateTransactionError.busyRetryExhausted {
                // Expected. The peer remains locked until this test's defer runs.
            } catch {
                XCTFail("Expected busyRetryExhausted, got \(error).")
            }

            XCTAssertEqual(startCount.value, 0)
            XCTAssertEqual(
                attemptCount.value,
                2,
                "Retry exhaustion must use its finite contention budget rather than retaining the fence indefinitely."
            )
            let successor = try XCTUnwrap(
                ProtectionLifecycleMutationFence.acquire(lockFileURL: mutationFenceURL, wait: false),
                "A failed-closed Restart must release its mutation fence for foreground lifecycle work."
            )
            successor.release()
        }
    }

    func testCancellationWhileCallbackIsHeldPreventsLateTunnelMutation() async throws {
        let callbackHolder = HeldCallback()
        let callbackRegistered = LockedFlag()
        let mutationCount = LockedCounter()
        let operation = Task<Void, Error> {
            try await ProtectionLifecycleCallbackCancellationGate.withCancellationHandler { gate in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    callbackHolder.register {
                        let didMutate: Void? = gate.executeUnlessCancelled {
                            mutationCount.increment()
                        }
                        guard didMutate != nil else {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        continuation.resume()
                    }
                    callbackRegistered.set()
                }
            }
        }

        try await waitUntilSet(callbackRegistered)
        operation.cancel()
        callbackHolder.fire()

        do {
            try await operation.value
            XCTFail("Cancellation before the manager callback runs must suppress the tunnel mutation.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error).")
        }
        XCTAssertEqual(
            mutationCount.value,
            0,
            "A callback released after cancellation must not invoke stopVPNTunnel or startVPNTunnel."
        )
    }

    private static func claimFileBackedRestartLease(
        stateURL: URL,
        lockURL: URL
    ) throws -> ProtectionLifecycleLease {
        try ProtectionLifecycleStateTransaction.withRequiredExclusiveLock(at: lockURL) {
            let storage = try ProtectionFileKeyValueStorage(fileURL: stateURL)
            let store = ProtectionLifecycleLeaseStore(
                storage: storage,
                lock: ProtectionNoopCriticalSectionLock()
            )
            let lease = try XCTUnwrap(store.claimExplicitRestart(leaseDuration: 30))
            try storage.persistIfNeeded()
            return lease
        }
    }

    private static func renewFileBackedLease(
        _ lease: ProtectionLifecycleLease,
        stateURL: URL,
        lockURL: URL
    ) throws -> Bool {
        try ProtectionLifecycleStateTransaction.withRequiredExclusiveLock(at: lockURL) {
            let storage = try ProtectionFileKeyValueStorage(fileURL: stateURL)
            let store = ProtectionLifecycleLeaseStore(
                storage: storage,
                lock: ProtectionNoopCriticalSectionLock()
            )
            let renewed = try store.renew(lease, leaseDuration: 30)
            try storage.persistIfNeeded()
            return renewed
        }
    }

    private static func claimInitialRestartFixture(
        stateURL: URL,
        stateLockURL: URL,
        mutationFenceURL: URL,
        maximumBusyAttempts: Int = 10,
        retryDelayNanoseconds: UInt64 = 100_000_000,
        onBusy: @escaping @Sendable () -> Void = {}
    ) async throws -> ClaimedRestartFixture? {
        guard let mutationFence = try ProtectionLifecycleMutationFence.acquire(
            lockFileURL: mutationFenceURL,
            wait: false
        ) else {
            throw RestartFixtureError.mutationFenceBusy
        }
        var transferredFence = false
        defer {
            if !transferredFence {
                mutationFence.release()
            }
        }

        let lifecycleLease = try await ProtectionLifecycleStateTransaction.retryingBusy(
            maximumBusyAttempts: maximumBusyAttempts,
            retryDelayNanoseconds: retryDelayNanoseconds
        ) {
            do {
                return try Self.claimFileBackedRestartLease(
                    stateURL: stateURL,
                    lockURL: stateLockURL
                )
            } catch ProtectionLifecycleStateTransactionError.busy {
                onBusy()
                throw ProtectionLifecycleStateTransactionError.busy
            }
        }
        transferredFence = true
        return ClaimedRestartFixture(
            lifecycleLease: lifecycleLease,
            mutationFence: mutationFence
        )
    }

    private static func fileBackedStore(stateURL: URL) throws -> ProtectionLifecycleLeaseStore {
        ProtectionLifecycleLeaseStore(
            storage: try ProtectionFileKeyValueStorage(fileURL: stateURL),
            lock: ProtectionNoopCriticalSectionLock()
        )
    }

    private func startLockHolder(lockURL: URL, directory: URL) throws -> LockHolder {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw XCTSkip("python3 unavailable; real cross-process lifecycle state-lock proof cannot run")
        }

        let readyURL = directory.appendingPathComponent("holder-ready-\(UUID().uuidString)")
        let releaseURL = directory.appendingPathComponent("holder-release-\(UUID().uuidString)")
        let script = """
        import fcntl, os, sys, time
        fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        open(sys.argv[2], "w").close()
        deadline = time.monotonic() + 60
        while not os.path.exists(sys.argv[3]) and time.monotonic() < deadline:
            time.sleep(0.01)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", script, lockURL.path, readyURL.path, releaseURL.path]
        try process.run()

        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: readyURL.path), Date() < deadline {
            usleep(10_000)
        }
        guard FileManager.default.fileExists(atPath: readyURL.path) else {
            terminateLockHolder(process)
            throw XCTSkip("lock holder did not acquire the lifecycle state lock within 20s")
        }
        return LockHolder(process: process, releaseURL: releaseURL)
    }

    private func releaseLockHolder(
        _ holder: LockHolder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard holder.process.isRunning else {
            return
        }
        guard FileManager.default.createFile(atPath: holder.releaseURL.path, contents: nil) else {
            XCTFail("Could not signal the lifecycle state-lock holder to exit.", file: file, line: line)
            terminateLockHolder(holder.process, file: file, line: line)
            return
        }
        guard waitForLockHolderExit(holder.process, timeout: 5) else {
            holder.process.terminate()
            guard waitForLockHolderExit(holder.process, timeout: 5) else {
                XCTFail("Lifecycle state-lock holder did not terminate within 10s.", file: file, line: line)
                return
            }
            XCTFail("Lifecycle state-lock holder ignored its release signal.", file: file, line: line)
            return
        }
    }

    private func terminateLockHolder(
        _ process: Process,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard process.isRunning else {
            return
        }
        process.terminate()
        XCTAssertTrue(
            waitForLockHolderExit(process, timeout: 5),
            "Lifecycle state-lock holder did not terminate within 5s.",
            file: file,
            line: line
        )
    }

    private func waitForLockHolderExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            usleep(10_000)
        }
        return !process.isRunning
    }

    private func waitUntilSet(
        _ flag: LockedFlag,
        timeout: TimeInterval = 20
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !flag.isSet, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(flag.isSet, "The test operation did not observe the held state lock in time.")
    }
}

private struct LockHolder {
    let process: Process
    let releaseURL: URL
}

private struct ClaimedRestartFixture: Sendable {
    let lifecycleLease: ProtectionLifecycleLease
    let mutationFence: ProtectionLifecycleMutationFenceHandle
}

private enum RestartFixtureError: Error {
    case mutationFenceBusy
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var didSet = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didSet
    }

    func set() {
        lock.lock()
        didSet = true
        lock.unlock()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class LockedStringSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return values.removeFirst()
    }
}

private final class HeldCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?

    func register(_ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let callback = self.callback
        self.callback = nil
        lock.unlock()
        callback?()
    }
}
