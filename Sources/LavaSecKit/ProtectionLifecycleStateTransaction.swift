import Darwin
import Foundation

/// Fail-closed errors from the short shared-state transaction that backs protection lifecycle
/// ownership. `.busy` is intentionally distinct: an already-owned lifecycle mutation fence may
/// retry that transient state-lock conflict without mistaking it for a lost lease token.
public enum ProtectionLifecycleStateTransactionError: Error, Equatable, Sendable {
    /// The caller could not derive the shared App Group container needed for the transaction.
    case missingContainer
    /// The state-lock file could not be opened; the associated value is `errno`.
    case openFailed(Int32)
    /// The state-lock file could not be verified as readable before first unlock.
    case protectionClassFailed
    /// The kernel lock operation failed for a reason other than ordinary contention.
    case lockFailed(Int32)
    /// A nonblocking state-lock acquisition found another short transaction in progress.
    case busy
    /// A caller-owned retry budget was exhausted while the state lock remained busy.
    case busyRetryExhausted
}

/// The result of revalidating and extending a lifecycle lease under the shared state lock.
public enum ProtectionLifecycleLeaseRenewalResult: Equatable, Sendable {
    /// The exact owner/token pair was still current and received a fresh expiry.
    case renewed
    /// The stored owner/token no longer matches, so this suspended caller must stop mutating.
    case ownershipLost
}

/// Coordinates cancellation across a task suspension and a later callback that can mutate the
/// protection lifecycle.
///
/// Callback APIs such as NetworkExtension invoke their completion outside the suspended Swift
/// task, so querying `Task.isCancelled` inside that completion does not reliably observe the
/// original task. ``withCancellationHandler(operation:)`` records cancellation in this gate;
/// ``executeUnlessCancelled(_:)`` then atomically checks that record immediately before a
/// synchronous callback mutation. The gate holds its lock through `operation`, so cancellation
/// cannot win between the check and the mutation.
public final class ProtectionLifecycleCallbackCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    /// Creates a gate for one callback-backed lifecycle operation.
    public init() {}

    /// Runs an async operation with a gate that is synchronously tripped if its task is cancelled.
    ///
    /// The operation must pass the gate to its eventual callback and call
    /// ``executeUnlessCancelled(_:)`` immediately around every synchronous lifecycle mutation.
    /// The callback remains responsible for resuming any continuation after a cancelled gate is
    /// observed, which avoids a late callback mutating the tunnel after task cancellation.
    public static func withCancellationHandler<T: Sendable>(
        operation: @escaping @Sendable (ProtectionLifecycleCallbackCancellationGate) async throws -> T
    ) async throws -> T {
        let gate = ProtectionLifecycleCallbackCancellationGate()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await operation(gate)
        }, onCancel: {
            gate.cancel()
        })
    }

    /// Runs a synchronous callback mutation only when cancellation has not already won the race.
    ///
    /// A `nil` result means cancellation happened before `operation` entered and the caller must
    /// resume its callback-backed operation with `CancellationError` instead of mutating.
    public func executeUnlessCancelled<T>(
        _ operation: () throws -> T
    ) rethrows -> T? {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard !cancelled else {
            return nil
        }
        return try operation()
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Owns nonblocking exclusion and retry semantics for the durable protection lifecycle state.
///
/// The state lock protects only a fresh-read/mutate/atomic-write transaction. Long-running
/// tunnel work is excluded separately by ``ProtectionLifecycleMutationFence``; callers that own
/// that fence can use ``retryingBusy(maximumBusyAttempts:retryDelayNanoseconds:operation:)`` to
/// wait asynchronously for a short state-lock holder without treating transient contention as a
/// token mismatch. That retry is explicitly bounded, because a peer can be suspended while holding
/// the short state lock and must not indefinitely retain the long mutation fence.
public enum ProtectionLifecycleStateTransaction {
    /// Runs `body` while holding the required, nonblocking shared-state lock.
    ///
    /// Failure to open, stamp, or acquire the lock never runs `body`. Ordinary contention throws
    /// ``ProtectionLifecycleStateTransactionError/busy`` so a caller that already owns the long
    /// mutation fence can retry asynchronously; callers that do not own that fence must fail
    /// closed instead of waiting behind unknown lifecycle work.
    public static func withRequiredExclusiveLock<T>(
        at lockFileURL: URL,
        _ body: () throws -> T
    ) throws -> T {
        let descriptor = open(
            lockFileURL.path,
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw ProtectionLifecycleStateTransactionError.openFailed(errno)
        }
        defer {
            _ = close(descriptor)
        }

        guard SharedStateFileProtection.applyControlPlaneProtection(at: lockFileURL) else {
            throw ProtectionLifecycleStateTransactionError.protectionClassFailed
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let errorCode = errno
            if errorCode == EWOULDBLOCK || errorCode == EAGAIN {
                throw ProtectionLifecycleStateTransactionError.busy
            }
            throw ProtectionLifecycleStateTransactionError.lockFailed(errorCode)
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
        }

        return try body()
    }

    /// Retries only transient state-lock contention with a bounded, cancellable asynchronous delay.
    ///
    /// A returned value is never retried: in particular, a `false` lease renewal remains the
    /// caller's proof that its owner/token pair is no longer current. Cancellation is checked
    /// before every attempt and the delay propagates `CancellationError`, so cancellation cannot
    /// collapse the backoff into a hot polling loop or allow a later tunnel mutation to run.
    /// If `maximumBusyAttempts` lock probes all report ordinary contention, this throws
    /// ``ProtectionLifecycleStateTransactionError/busyRetryExhausted``. Callers must then fail
    /// closed and release any long-running mutation fence; durable claims are left to expire rather
    /// than being modified without the state lock.
    public static func retryingBusy<T: Sendable>(
        maximumBusyAttempts: Int = 10,
        retryDelayNanoseconds: UInt64 = 100_000_000,
        operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        precondition(maximumBusyAttempts > 0)
        precondition(retryDelayNanoseconds > 0)

        var busyAttempts = 0
        while true {
            try Task.checkCancellation()
            do {
                return try operation()
            } catch ProtectionLifecycleStateTransactionError.busy {
                busyAttempts += 1
                guard busyAttempts < maximumBusyAttempts else {
                    throw ProtectionLifecycleStateTransactionError.busyRetryExhausted
                }
                try await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }
    }

    /// Retries a lease renewal only for transient state-lock contention.
    ///
    /// A `false` from `operation` is converted to ``ProtectionLifecycleLeaseRenewalResult/ownershipLost``
    /// immediately. It is never retried, because it proves the stored owner/token changed or expired;
    /// retrying it would let a stale lifecycle action keep the mutation fence after its authority ended.
    public static func retryingBusyRenewal(
        maximumBusyAttempts: Int = 10,
        retryDelayNanoseconds: UInt64 = 100_000_000,
        operation: @escaping @Sendable () throws -> Bool
    ) async throws -> ProtectionLifecycleLeaseRenewalResult {
        let didRenew = try await retryingBusy(
            maximumBusyAttempts: maximumBusyAttempts,
            retryDelayNanoseconds: retryDelayNanoseconds,
            operation: operation
        )
        return didRenew ? .renewed : .ownershipLost
    }
}
