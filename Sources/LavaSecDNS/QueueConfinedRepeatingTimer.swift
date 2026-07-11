// Queue-confined repeating-timer mechanism, extracted from the provider's Focus
// config poll (Phase E2, lavasec-infra plans/2026-07-07-ios-modularization-
// scaffolding-plan.md) and migrated to a dispatch-backed ACTOR (actors slice 1 of
// the plan's long-term item): the actor's executor IS the owner's DispatchSerialQueue,
// so INV-QUEUE-1's confinement is now compiler-enforced — new code must hop (await)
// or prove it is already on the queue (`assumeIsolated`, which traps on the wrong
// executor instead of racing silently). The poll's policy — interval choice, tick
// behavior, watermark rules — stays with its owner.
import Dispatch
import Foundation

/// A restartable repeating `DispatchSourceTimer` isolated to the serial queue it
/// fires on. The actor executes on that queue itself (custom executor), so
/// already-on-queue callers use the synchronous `assumeIsolated` path with zero
/// hops — exactly the pre-actor call shape, now checked by the runtime instead of
/// a comment. `start` cancels any prior timer, so re-arming is safe; deallocating
/// the owner without `stop()` leaks nothing (the source is cancelled in `deinit`).
public actor QueueConfinedRepeatingTimer {
    /// The confinement queue, doubling as this actor's executor. Nonisolated so the
    /// executor witness can read it; immutable, so that is race-free by construction.
    private nonisolated let queue: DispatchSerialQueue
    private var timer: DispatchSourceTimer?

    /// The custom executor: this actor RUNS ON the owner's queue, which is what lets
    /// already-on-queue callers take the synchronous `assumeIsolated` path (INV-QUEUE-1).
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// - Parameter queue: the serial queue this actor executes on; ticks are
    ///   delivered on it, and `assumeIsolated` callers must already be on it.
    public init(queue: DispatchSerialQueue) {
        self.queue = queue
    }

    deinit {
        timer?.cancel()
    }

    /// Arms (or re-arms) the timer. Isolation replaces the old
    /// `dispatchPrecondition` — off-queue misuse is now a compile-time error
    /// (missing `await`) or an `assumeIsolated` trap, not a debug-only assert.
    public func start(
        interval: TimeInterval,
        leeway: DispatchTimeInterval,
        onTick: @escaping @Sendable () -> Void
    ) {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        source.setEventHandler(handler: onTick)
        timer = source
        source.resume()
    }

    /// Cancels the timer if armed. Safe to call when already stopped.
    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// True while armed — for the owner's idempotence checks and for tests.
    package var isRunning: Bool {
        timer != nil
    }
}
