import Foundation

/// The one time source the blackhole budget is measured on.
///
/// Two operations, deliberately, and from ONE origin. `ChainedOutageSupervisor` issues deadlines
/// as absolute instants on the caller's clock, and something has to arm a timer for that instant
/// — so a clock that can only be read leaves the caller converting between two denominations,
/// which is where a "same instant" claim quietly becomes an approximation.
public protocol ChainedMonotonicClock: Sendable {
    /// Seconds since this clock's origin. Never decreases.
    func nowSeconds() -> Int
    /// The dispatch deadline for an instant expressed in this clock's seconds.
    func deadline(atSeconds seconds: Int) -> DispatchTime
}

/// The production clock: the device's UPTIME base, which does not advance while the system is
/// asleep.
///
/// ## Why uptime and not continuous time
///
/// The forceful reason is mechanical. `DispatchSourceTimer.schedule(deadline:)` takes a
/// `DispatchTime`, which is the uptime base; the alternative parameter, `wallDeadline:`, is the
/// settable wall clock — precisely the "moves both ways" input `ChainedOutageSupervisor` refuses
/// (it surrenders with `.clockUnusable` on any backward reading). There is no continuous-time
/// dispatch source. `C1` requires that the object which authorizes an attempt is the object that
/// arms its watchdog, so a clock that cannot be armed cannot discharge C1 at all.
///
/// The second reason is what the budget promises: that the user will not stare at a dead
/// connection for fifteen seconds. A suspended process is not staring at anything, and no packet
/// enters the tunnel while the device is asleep.
///
/// ## The engine is NOT on this base, and that is stated rather than glossed
///
/// It would be tidy to say this matches the engine. It does not. `boringtun`'s timers use
/// `sleepyinstant::Instant`, whose module documentation says it "accounts for time when the
/// system is asleep", and which selects `CLOCK_MONOTONIC` on Darwin — where, unlike Linux, that
/// clock keeps incrementing across sleep. The cfg split in that file exists for exactly this
/// difference. So the engine's deadlines advance during sleep and ours do not.
///
/// Across a LONG sleep that resolves safely: on the first post-wake tick the engine trips its
/// own expiry and reports a session end, on a fresh budget, on the network the device actually
/// woke up on.
///
/// THAT SENTENCE USED TO BE AN ASSUMPTION ABOUT ORDERING, and it is now enforced. It is only
/// true if a tick beats the first post-wake packet: `Tunn::encapsulate` and `Tunn::handle_data`
/// consult no timer, so a packet arriving before that tick is encrypted or accepted on a keypair
/// the engine would have retired — and `ChainedOutageDriver.tick()` declines to decide anything
/// while quiesced, while `handleOutboundBatch` has no such guard. Nothing ordered the two.
/// `ChainedSessionRunner.engineTimersAreFreshOnQueue()` now does, by driving a catch-up pass
/// before any engine call that uses session keys — which is also why that guard reads the
/// ENGINE's clock and not this one.
///
/// Across a SHORT sleep spanning an authorized attempt it does not: the attempt's
/// window contains no engine retransmits, because the engine's timers only advance when it is
/// ticked. Neither clock choice fixes that, because the deadlines are in the engine's
/// denomination — so the driver handles sleep at the boundary instead, by ending the outage.
///
/// ## Arithmetic
///
/// `&+` and `&*` throughout: a trap inside a Network Extension is a tunnel abort, and a wrapped
/// value that produces a wrong deadline is recoverable where a crash is not. Flooring a
/// non-decreasing `UInt64` is non-decreasing, so this conversion can never manufacture the
/// backward reading that would make the supervisor surrender.
/// pinned: ChainedUptimeClockTests.testTheClockNeverGoesBackwardsAcrossManyReads
public final class ChainedUptimeClock: ChainedMonotonicClock {
    private let origin: UInt64

    public init() {
        origin = DispatchTime.now().uptimeNanoseconds
    }

    public func nowSeconds() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- origin) / 1_000_000_000)
    }

    public func deadline(atSeconds seconds: Int) -> DispatchTime {
        DispatchTime(
            uptimeNanoseconds: origin &+ UInt64(max(0, seconds)) &* 1_000_000_000)
    }
}
