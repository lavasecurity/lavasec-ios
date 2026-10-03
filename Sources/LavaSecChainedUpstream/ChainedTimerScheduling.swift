import Foundation

/// A timer that has been armed for a specific instant.
///
/// The type exists so that "authorized" and "armed" cannot be separated. `C1` says the object
/// which authorizes an attempt must be the object that arms its watchdog, and the enforcement is
/// that the value recording a live attempt requires one of these NON-OPTIONALLY — so an
/// authorization with no timer is not a state the driver can represent.
///
/// What is NOT enforced, stated rather than implied: this initialiser is `public`, because a
/// scheduler conformer lives outside this file and has to be able to produce one. "Only an
/// actual arming produces a timer" is therefore a property of the two conformers, not of the
/// type. The structural half is the non-optional field; this half is convention.
public final class ChainedArmedTimer: @unchecked Sendable {
    /// Identifies THIS arming, not merely that something was armed.
    ///
    /// `DispatchSourceTimer.cancel()` does not retract a handler block already delivered to the
    /// queue, so a cancelled timer can still run once. Without a serial the handler cannot tell
    /// whether it is the arming the driver currently believes in, and a late fire from a retired
    /// attempt would surrender a tunnel that had already recovered. The supervisor defends
    /// itself the same way, with `ChainedAttemptReceipt.serial`.
    public let serial: UInt64
    /// `@unchecked` and unsynchronised: every arming, cancellation and fire happens on the
    /// engine queue, so there is nothing to race.
    private let onCancel: @Sendable () -> Void
    private var isCancelled = false

    public init(serial: UInt64, onCancel: @escaping @Sendable () -> Void) {
        self.serial = serial
        self.onCancel = onCancel
    }

    /// Stops the timer. Idempotent, and safe to call from the handler it armed.
    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onCancel()
    }
}

/// Where timers come from, so the driver's schedule is executable outside a Network Extension.
///
/// The intervals and instants are the thing under test — a cadence that quietly doubles is an
/// energy regression and a watchdog armed a second late is a budget violation — and neither is
/// observable by waiting in a unit test.
public protocol ChainedTimerScheduling: AnyObject, Sendable {
    /// Arms a ONE-SHOT timer for an absolute instant.
    func arm(
        at deadline: DispatchTime,
        serial: UInt64,
        handler: @escaping @Sendable () -> Void
    ) -> ChainedArmedTimer

    /// Starts or re-schedules the repeating tick. Passing `nil` cancels it.
    ///
    /// Cancel-and-recreate, never `suspend()`: releasing a suspended `DispatchSourceTimer` traps,
    /// and a trap inside the extension is a tunnel abort.
    /// pinned: ChainedOutageDriverTests.testTheTickIsCancelledRatherThanSuspended
    func scheduleTick(every interval: DispatchTimeInterval?, leeway: DispatchTimeInterval)
}

/// The production scheduler. Every timer fires on the engine queue.
///
/// `@unchecked` because the repeating source is mutable state: it is created, re-scheduled and
/// destroyed only from `scheduleTick`, which asserts it is on the engine queue, so the mutation
/// is confined rather than synchronised.
public final class ChainedEngineQueueTimers: ChainedTimerScheduling, @unchecked Sendable {
    private let engineQueue: ChainedEngineQueue
    private let tickHandler: @Sendable () -> Void
    /// Held so the repeating source outlives the call that created it. Confined to the engine
    /// queue like everything else the driver owns.
    private var tick: DispatchSourceTimer?

    public init(engineQueue: ChainedEngineQueue, onTick: @escaping @Sendable () -> Void) {
        self.engineQueue = engineQueue
        self.tickHandler = onTick
    }

    public func arm(
        at deadline: DispatchTime,
        serial: UInt64,
        handler: @escaping @Sendable () -> Void
    ) -> ChainedArmedTimer {
        let source = DispatchSource.makeTimerSource(queue: engineQueue.queue)
        source.schedule(deadline: deadline)
        source.setEventHandler(handler: handler)
        source.resume()
        return ChainedArmedTimer(serial: serial) { source.cancel() }
    }

    public func scheduleTick(every interval: DispatchTimeInterval?, leeway: DispatchTimeInterval) {
        engineQueue.requireOnQueue()
        // DESTROYED AND REBUILT, not suspended. A suspended source that is released traps, and
        // the cadence changes often enough — every transition into and out of an outage — that
        // "remember to resume before releasing" is a rule this code would eventually break.
        tick?.cancel()
        tick = nil
        guard let interval else { return }
        let source = DispatchSource.makeTimerSource(queue: engineQueue.queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        source.setEventHandler(handler: tickHandler)
        source.resume()
        tick = source
    }

    deinit {
        // The source retains its handler, and the handler holds the driver weakly — but a live
        // repeating source on a queue that outlives this object would keep firing into nothing.
        tick?.cancel()
    }
}
