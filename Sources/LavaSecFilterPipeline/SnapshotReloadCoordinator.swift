import Dispatch

/// Owns snapshot-reload generation fencing and in-flight ownership on a caller-supplied
/// serial queue. The queue is also the actor's executor, allowing callers already on that
/// queue to use `assumeIsolated` without changing their synchronous ordering.
public actor SnapshotReloadCoordinator {
    private nonisolated let queue: DispatchSerialQueue
    private var generation: UInt64 = 0
    private var reloadInFlight = false

    /// The serial queue that executes all actor-isolated state transitions.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Creates a coordinator whose state transitions execute on `queue`.
    ///
    /// - Parameter queue: The serial queue callers must occupy before using
    ///   `assumeIsolated` for synchronous access.
    public init(queue: DispatchSerialQueue) {
        self.queue = queue
    }

    /// Starts a reload, superseding any prior owner and returning the new generation token.
    public func begin() -> UInt64 {
        generation += 1
        reloadInFlight = true
        return generation
    }

    /// Returns whether `candidate` identifies the current coordinator generation.
    ///
    /// - Parameter candidate: The generation token to compare with the current generation.
    public func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation
    }

    /// Finishes the reload identified by `candidate` without disturbing a newer owner.
    ///
    /// - Parameter candidate: The generation token returned by `begin()`.
    public func finish(_ candidate: UInt64) {
        guard isCurrent(candidate) else { return }
        reloadInFlight = false
    }

    /// Supersedes all prior work, clears in-flight ownership, and returns the new generation.
    @discardableResult
    public func invalidate() -> UInt64 {
        generation += 1
        reloadInFlight = false
        return generation
    }

    /// Whether the current coordinator generation owns an unfinished reload.
    public var isReloadInFlight: Bool {
        reloadInFlight
    }
}
