// Queue-confined repeating-timer mechanism, extracted from the provider's Focus
// config poll (Phase E2, lavasec-infra plans/2026-07-07-ios-modularization-
// scaffolding-plan.md): the timer LIFECYCLE lives here where it gets executable
// tests (QueueConfinedRepeatingTimerTests); the poll's policy — interval choice,
// tick behavior, watermark rules — stays with its owner. INV-QUEUE-1: this type
// does not replicate the provider's specific-key re-entrancy hop; it *asserts*
// confinement and leaves the dual-entry contract at the owner's entry points.
import Foundation

/// A restartable repeating `DispatchSourceTimer` whose start/stop must run on the
/// queue it fires on. `start` cancels any prior timer first, so re-arming is safe;
/// deallocating the owner without `stop()` leaks nothing (the source is cancelled
/// in `deinit`).
public final class QueueConfinedRepeatingTimer {
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?

    /// - Parameter queue: the confinement queue; every `start`/`stop` call must
    ///   already be running on it, and ticks are delivered on it.
    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit {
        timer?.cancel()
    }

    /// Arms (or re-arms) the timer. Confinement is asserted, not hopped — the
    /// owner's entry points keep the specific-key re-entrancy pattern (INV-QUEUE-1).
    public func start(
        interval: TimeInterval,
        leeway: DispatchTimeInterval,
        onTick: @escaping () -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        source.setEventHandler(handler: onTick)
        timer = source
        source.resume()
    }

    /// Cancels the timer if armed. Safe to call when already stopped.
    public func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        timer?.cancel()
        timer = nil
    }

    /// True while armed — for the owner's idempotence checks and for tests.
    public var isRunning: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return timer != nil
    }
}
