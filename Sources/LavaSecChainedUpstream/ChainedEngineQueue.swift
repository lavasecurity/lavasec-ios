import Foundation

/// The one serial queue every engine object in a chained tunnel runs on, and the single
/// authority on whether you are standing on it.
///
/// ## Why the key belongs to the QUEUE and not to its users
///
/// `ChainedSessionRunner` used to create its own queue and its own `DispatchSpecificKey`, which
/// was right while a runner was the only thing on it. A tunnel lifecycle outlives its sessions:
/// the outage driver holds the budget across attempts and builds a fresh runner per attempt, so
/// several runners share one queue over time and the driver's own timers fire on it too.
///
/// "Am I on the queue?" is then a fact about the QUEUE, and a per-object key answers it about
/// whichever object you happened to ask. Both ways of keeping per-object keys are wrong. If each
/// runner sets its own key on the shared queue, every runner adds an entry that outlives it —
/// the queue's specific table grows for the life of the tunnel, and a key allocated at a
/// deallocated key's address inherits its entry. If the runner stops setting one because the
/// queue is injected, its key is never registered at all, so `getSpecific` answers "no" while
/// the code is standing on the queue — and the callers that ask are exactly the ones that then
/// take a `queue.sync` branch, which from the queue itself is a deadlock.
/// pinned: ChainedSessionRunnerTests.testOneQueueKeyServesEveryRunner
///
/// Never `dnsStateQueue` (`INV-QUEUE-1`). The DNS state machine and the engine are two
/// independent confinements, and hanging the engine off the DNS queue would couple a
/// crypto-bound loop to the queue that answers queries.
public final class ChainedEngineQueue: @unchecked Sendable {
    /// The queue itself, for scheduling timers and hops.
    public let queue: DispatchQueue

    /// `@unchecked` because `DispatchSpecificKey` is a class and not `Sendable`. It is written
    /// once in `init` and thereafter only ever read for identity, so there is nothing to race.
    private let key = DispatchSpecificKey<Void>()

    public init(label: String = "com.lavasec.chained.engine") {
        queue = DispatchQueue(label: label)
        queue.setSpecific(key: key, value: ())
    }

    /// Whether the caller is already executing on this queue.
    public var isCurrent: Bool { DispatchQueue.getSpecific(key: key) != nil }

    /// Runs `work` here, inline when already on the queue.
    ///
    /// The re-entrancy pattern the tunnel uses elsewhere (`INV-QUEUE-1`): a `sync` from the
    /// queue itself deadlocks, so the specific key is what makes a single entry point usable
    /// from both sides of the boundary.
    public func run<T>(_ work: () -> T) -> T {
        if isCurrent { return work() }
        return queue.sync(execute: work)
    }

    /// Schedules `work` here, always asynchronously.
    public func enqueue(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// Traps if the caller is not on this queue.
    ///
    /// For entry points that have no business hopping — the ones whose contract is "you are
    /// already here". `ChainedSessionRunner` is `@unchecked Sendable`, so Swift 6 will not
    /// diagnose an off-queue call from the provider or a test.
    public func requireOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    /// Traps if the caller IS on this queue.
    ///
    /// The mirror of ``requireOnQueue()``, for the handful of operations that are allowed to
    /// block — priming the path cache is the only one — and would otherwise block the queue every
    /// engine timer fires on. `ChainedSessionSource` states that obligation in prose and cannot
    /// enforce it; this is where it is enforced, at the entry point that does the waiting.
    /// `dispatchPrecondition` is built on `precondition`, so the trap survives a Release build.
    public func requireOffQueue() {
        dispatchPrecondition(condition: .notOnQueue(queue))
    }
}
