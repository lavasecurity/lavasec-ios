import Darwin
import Foundation

/// Errors emitted by the fail-closed, cross-process fence around NetworkExtension mutations.
public enum ProtectionLifecycleMutationFenceError: Error, Equatable, Sendable {
    /// The shared lock file could not be opened; the associated value is `errno`.
    case openFailed(Int32)
    /// The required pre-unlock-readable protection class could not be applied.
    case protectionClassFailed
    /// The kernel lock operation failed for a reason other than contention; the value is `errno`.
    case lockFailed(Int32)
    /// A try-once acquisition found the fence already owned.
    case busy
    /// Local identity or external generation changed before the protected mutation completed.
    case ownershipLost
}

/// An owned kernel lock. The file descriptor keeps the lock alive across task suspension and
/// cancellation; the kernel closes it automatically if the process exits.
public final class ProtectionLifecycleMutationFenceHandle: @unchecked Sendable {
    private let stateLock = NSLock()
    private var fileDescriptor: Int32?

    fileprivate init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    /// Releases this exact owned descriptor once. Repeated calls are harmless, and process death
    /// remains the fail-safe release when normal cleanup cannot run.
    public func release() {
        let descriptor: Int32?
        stateLock.lock()
        descriptor = fileDescriptor
        fileDescriptor = nil
        stateLock.unlock()

        guard let descriptor else {
            return
        }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    deinit {
        release()
    }
}

/// Serializes the protection lifecycle mutations that can overlap across the app and App Intent
/// processes: foreground ON/OFF/reconnect, automatic restore callbacks, chained terminal work,
/// direct Live Activity Restart, and internal admin-QA lifecycle controls. Onboarding profile setup
/// is outside this fence because Restart is not exposed before onboarding completes.
public enum ProtectionLifecycleMutationFence {
    /// Acquires the single shared inode without replacing it.
    ///
    /// With `wait == false`, this is a try-once probe that returns `nil` on contention. With
    /// `wait == true`, it blocks the calling thread until the kernel lock becomes available; callers
    /// running on the main actor must use the async wrappers instead. Open, protection-class, and
    /// non-contention lock failures throw in either mode.
    public static func acquire(
        lockFileURL: URL,
        wait: Bool
    ) throws -> ProtectionLifecycleMutationFenceHandle? {
        let descriptor = open(
            lockFileURL.path,
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw ProtectionLifecycleMutationFenceError.openFailed(errno)
        }

        guard SharedStateFileProtection.applyControlPlaneProtection(at: lockFileURL) else {
            let error = ProtectionLifecycleMutationFenceError.protectionClassFailed
            _ = close(descriptor)
            throw error
        }

        let operation = wait ? LOCK_EX : (LOCK_EX | LOCK_NB)
        guard flock(descriptor, operation) == 0 else {
            let errorCode = errno
            _ = close(descriptor)
            if !wait, errorCode == EWOULDBLOCK || errorCode == EAGAIN {
                return nil
            }
            throw ProtectionLifecycleMutationFenceError.lockFailed(errorCode)
        }

        return ProtectionLifecycleMutationFenceHandle(fileDescriptor: descriptor)
    }

    /// Runs one complete app lifecycle action while excluding direct App Intent restart. Every lock
    /// probe is nonblocking because callers are MainActor-bound. A try-once caller
    /// (`waitUntilAvailable == false`) fails closed on contention; an async-waiting caller retries
    /// nonblockingly while `validateWaiting` remains true.
    @MainActor
    public static func withExclusiveMutation<T>(
        lockFileURL: URL,
        waitUntilAvailable: Bool = false,
        validateWaiting: @escaping @MainActor () -> Bool = { true },
        operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let fence = try await acquireWithoutBlockingMainActor(
            lockFileURL: lockFileURL,
            waitUntilAvailable: waitUntilAvailable,
            validateWaiting: validateWaiting
        )
        defer {
            fence.release()
        }
        return try await operation()
    }

    /// Runs one non-cancellable platform mutation while a try-once kernel fence is held.
    ///
    /// Contention throws `busy` immediately; this method never retries while main-actor-bound.
    /// Ownership is revalidated after acquiring the fence, immediately before dispatch, then checked
    /// again when the callback returns. The original platform error is preserved.
    @MainActor
    public static func withOwnedMutation<T>(
        lockFileURL: URL,
        validateOwnership: @escaping @MainActor () -> Bool,
        operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        guard let fence = try acquire(lockFileURL: lockFileURL, wait: false) else {
            // Never block the MainActor behind a callback owned by a suspended process. The
            // current automatic attempt aborts safely; the explicit restart already holding the
            // fence remains responsible for convergence.
            throw ProtectionLifecycleMutationFenceError.busy
        }
        defer {
            fence.release()
        }

        guard validateOwnership() else {
            throw ProtectionLifecycleMutationFenceError.ownershipLost
        }
        let result = try await operation()
        guard validateOwnership() else {
            throw ProtectionLifecycleMutationFenceError.ownershipLost
        }
        return result
    }

    /// Runs a lifecycle mutation descended from an earlier asynchronous decision (for example a
    /// chained-establishment gate) only when both its local identity and captured direct-restart
    /// generation remain current.
    ///
    /// The kernel fence is acquired through nonblocking probes with asynchronous backoff while local
    /// ownership remains valid, then the generation is checked. Direct restart uses the same lock
    /// order before rotating its generation, so exactly one side wins: a winning restart invalidates
    /// the stale descendant, while a winning descendant makes restart return busy without rotating.
    /// The descriptor spans the complete callback and therefore remains exclusive across suspension,
    /// task cancellation, and logical-lease expiry. The original operation error is preserved.
    @MainActor
    public static func withDescendantMutation<T>(
        lockFileURL: URL,
        validateLocalOwnership: @escaping @MainActor () -> Bool,
        validateExternalGeneration: @escaping @MainActor () throws -> Bool,
        operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        // A foreground app action can own this same process-wide flock when a very fast chained
        // terminal arrives. Retry asynchronously rather than dropping the terminal or blocking the
        // MainActor. If direct Restart owns it, the later strict generation check invalidates this
        // stale descendant after Restart releases.
        let fence = try await acquireWithoutBlockingMainActor(
            lockFileURL: lockFileURL,
            waitUntilAvailable: true,
            validateWaiting: validateLocalOwnership
        )
        defer {
            fence.release()
        }

        guard validateLocalOwnership(), try validateExternalGeneration() else {
            throw ProtectionLifecycleMutationFenceError.ownershipLost
        }
        let result = try await operation()
        guard validateLocalOwnership(), try validateExternalGeneration() else {
            throw ProtectionLifecycleMutationFenceError.ownershipLost
        }
        return result
    }

    @MainActor
    private static func acquireWithoutBlockingMainActor(
        lockFileURL: URL,
        waitUntilAvailable: Bool,
        validateWaiting: @escaping @MainActor () -> Bool
    ) async throws -> ProtectionLifecycleMutationFenceHandle {
        while true {
            guard validateWaiting() else {
                throw ProtectionLifecycleMutationFenceError.ownershipLost
            }
            if let fence = try acquire(lockFileURL: lockFileURL, wait: false) {
                return fence
            }
            guard waitUntilAvailable else {
                throw ProtectionLifecycleMutationFenceError.busy
            }
            // Nonblocking flock + async backoff: process/task suspension is safe because no lock is
            // held yet, and the MainActor remains available to cancellation/status callbacks.
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
