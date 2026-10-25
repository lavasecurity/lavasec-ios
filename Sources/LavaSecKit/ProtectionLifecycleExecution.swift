import Foundation

/// Keeps app-owned lifecycle locks inside the platform's background execution window.
@MainActor
public enum ProtectionLifecycleExecution {
    /// Releases a platform assertion after the operation has relinquished its locks.
    public typealias End = @MainActor @Sendable () -> Void
    /// Starts an assertion, or returns nil when the platform refuses execution time.
    public typealias Begin = @MainActor (@escaping @MainActor @Sendable () -> Void) -> End?

    /// Installed by the app before creating its model or servicing background App Intents.
    /// Extension hosts keep their system-owned execution lifetime; Kit never imports UIKit.
    public static var beginBackgroundExecution: Begin?

    /// Failure to obtain execution time must prevent acquisition of a shared file lock.
    public enum Failure: Error, Equatable, Sendable {
        /// The app is already suspending or cannot obtain a background assertion.
        case backgroundExecutionUnavailable
    }

    /// Obtains execution time before dispatching work, cancels on expiration, and drains the
    /// operation before ending the assertion. Cancellation cannot release a fence around an
    /// outstanding, non-cancellable NetworkExtension callback (INV-PERSIST-3).
    ///
    /// `begin` is an injectable platform port. A nil port uses the app-installed default; hosts
    /// without an installed port retain their existing system-owned execution semantics.
    /// pinned: ProtectionLifecycleExecutionTests.testExpirationDrainsNonCancellableCallbacksBeforeUnlockingAndEndingExecution
    public static func run<T>(
        begin: Begin? = nil,
        operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        guard let begin = begin ?? beginBackgroundExecution else {
            return try await operation()
        }
        try Task.checkCancellation()
        let state = OperationState<T>()
        guard let end = begin({ state.expire() }) else {
            throw Failure.backgroundExecutionUnavailable
        }
        defer { end() }
        guard !state.expired else { throw CancellationError() }

        // A Void task keeps the generic result on MainActor, including non-Sendable manager
        // snapshots. The handle lets platform expiration cancel sleeps and status waits without
        // abandoning callbacks or releasing the operation's kernel fence prematurely.
        let work = Task { @MainActor in
            do {
                try Task.checkCancellation()
                let value = try await operation()
                try Task.checkCancellation()
                state.result = .success(value)
            } catch {
                state.result = .failure(error)
            }
        }
        state.cancel = { work.cancel() }
        defer { state.cancel = nil }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        // The task always publishes its result before completing, even if cancelled before entry.
        return try state.result!.get()
    }

    @MainActor
    private final class OperationState<T> {
        var result: Result<T, Error>?
        var cancel: (@MainActor () -> Void)?
        var expired = false

        func expire() {
            expired = true
            cancel?()
        }
    }
}
