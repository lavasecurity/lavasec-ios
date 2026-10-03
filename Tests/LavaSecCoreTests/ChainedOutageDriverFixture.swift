import Foundation
import XCTest

@testable import LavaSecChainedUpstream

/// A clock the test SETS. Reading it never moves it.
///
/// The separation from ``AdvancingTestClock`` is deliberate and one fake cannot serve both: a
/// clock that advances per read makes elapsed time a function of how often the test happens to
/// poke the driver, which is exactly what a budget test must not depend on.
final class SetTestClock: ChainedMonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 0
    private var reads = 0
    /// How many times the driver asked. Used to assert the single-read property of the C1 step.
    var readCount: Int { lock.withLock { reads } }
    /// The current value WITHOUT counting the read, so a test can look without perturbing the
    /// very property it is asserting.
    var currentSeconds: Int { lock.withLock { seconds } }

    func set(_ value: Int) { lock.withLock { seconds = value } }
    func advance(_ delta: Int) { lock.withLock { seconds += delta } }
    func resetReadCount() { lock.withLock { reads = 0 } }

    /// Stalls the NEXT read until `releaseGate()`, so a test can hold a producer inside the
    /// clock read and interleave a second one deterministically.
    ///
    /// The only way to exercise a preemption between stamping an observation and submitting
    /// it: the window is one instruction wide in practice, and a stress test that hammered
    /// it would prove nothing on the run where it happened not to interleave.
    private var gate: DispatchSemaphore?
    private var gateEntered: DispatchSemaphore?
    private var gateArmed = false

    /// Returns `(entered, release)`: `entered` is signalled once the stalled read has
    /// CAPTURED its value, and the read then waits on `release`.
    ///
    /// Arming alone is not enough for a caller that wants to advance the clock behind the
    /// stalled producer: a fixed sleep does not establish that the producer ever reached
    /// the read, so on a loaded runner the clock could move first and both producers stamp
    /// the same instant — the test would fail nondeterministically (Codex, PR #513). The
    /// caller waits for `entered` instead.
    func stallNextRead() -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        lock.withLock {
            gateEntered = entered
            gate = release
            gateArmed = true
        }
        return (entered, release)
    }

    func nowSeconds() -> Int {
        // The VALUE IS CAPTURED FIRST, then the reader stalls. Stalling before the read
        // would hand the stalled producer whatever the clock reached while it waited —
        // which is the opposite of the interleaving under test, and made the first version
        // of this gate report both producers at the same instant.
        let (value, stall, entered): (Int, DispatchSemaphore?, DispatchSemaphore?) =
            lock.withLock {
                reads += 1
                let armed = gateArmed
                gateArmed = false
                return (seconds, armed ? gate : nil, armed ? gateEntered : nil)
            }
        // Announced AFTER the value is captured and OUTSIDE the lock: the caller may now
        // advance the clock knowing this read already has its own answer, and the stalled
        // reader does not block the test thread meanwhile.
        entered?.signal()
        stall?.wait()
        return value
    }

    func deadline(atSeconds seconds: Int) -> DispatchTime {
        // The fake scheduler never really waits, so this only has to be an injective, monotone
        // mapping from the driver's seconds — the tests read the SECONDS back, not the instant.
        DispatchTime(uptimeNanoseconds: UInt64(max(0, seconds)) &* 1_000_000_000 &+ 1)
    }
}

/// A clock that moves one second per read, for the one property that is about reading it twice.
final class AdvancingTestClock: ChainedMonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 0

    func nowSeconds() -> Int {
        lock.withLock {
            seconds += 1
            return seconds
        }
    }

    func deadline(atSeconds seconds: Int) -> DispatchTime {
        DispatchTime(uptimeNanoseconds: UInt64(max(0, seconds)) &* 1_000_000_000 &+ 1)
    }
}

/// Records what was armed and lets the test fire it, so instants and intervals are assertable
/// without waiting.
final class RecordingTimerScheduler: ChainedTimerScheduling, @unchecked Sendable {
    struct Armed {
        let serial: UInt64
        let deadline: DispatchTime
        let handler: @Sendable () -> Void
        var isCancelled = false
    }

    private let lock = NSLock()
    private var armedStorage: [Armed] = []
    private var tickIntervals: [DispatchTimeInterval?] = []
    /// Trips if anything ever suspends the tick, which would be a latent crash on release.
    private(set) var suspendWasCalled = false

    var armed: [Armed] { lock.withLock { armedStorage } }
    var liveArmed: [Armed] { lock.withLock { armedStorage.filter { !$0.isCancelled } } }
    var recordedTickIntervals: [DispatchTimeInterval?] { lock.withLock { tickIntervals } }
    var currentTickInterval: DispatchTimeInterval? { lock.withLock { tickIntervals.last ?? nil } }

    func arm(
        at deadline: DispatchTime,
        serial: UInt64,
        handler: @escaping @Sendable () -> Void
    ) -> ChainedArmedTimer {
        lock.withLock { armedStorage.append(Armed(serial: serial, deadline: deadline, handler: handler)) }
        return ChainedArmedTimer(serial: serial) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                if let index = self.armedStorage.firstIndex(where: { $0.serial == serial }) {
                    self.armedStorage[index].isCancelled = true
                }
            }
        }
    }

    func scheduleTick(every interval: DispatchTimeInterval?, leeway: DispatchTimeInterval) {
        lock.withLock { tickIntervals.append(interval) }
    }

    /// Fires the newest live timer whose deadline is at or before `seconds`, if any.
    @discardableResult
    func fireDue(atSeconds seconds: Int, on queue: ChainedEngineQueue) -> Bool {
        let limit = DispatchTime(uptimeNanoseconds: UInt64(max(0, seconds)) &* 1_000_000_000 &+ 1)
        let due: Armed? = lock.withLock {
            armedStorage.last { !$0.isCancelled && $0.deadline.uptimeNanoseconds <= limit.uptimeNanoseconds }
        }
        guard let due else { return false }
        lock.withLock {
            if let index = armedStorage.firstIndex(where: { $0.serial == due.serial }) {
                armedStorage[index].isCancelled = true
            }
        }
        queue.run { due.handler() }
        return true
    }

    /// Fires a handler the queue had ALREADY been handed when it was cancelled.
    ///
    /// `fireDue` deliberately skips cancelled timers, which models a timer that never got to
    /// run — and therefore cannot see the race that matters at the sleep boundary, where
    /// `cancel()` does not retract a handler already delivered to the queue
    /// (``ChainedArmedTimer`` documents exactly that). This fires by serial regardless of
    /// cancellation, which is what the real dispatch source does to a handler in flight.
    func fireAlreadyDelivered(serial: UInt64, on queue: ChainedEngineQueue) -> Bool {
        let armed: Armed? = lock.withLock { armedStorage.first { $0.serial == serial } }
        guard let armed else { return false }
        queue.run { armed.handler() }
        return true
    }

    /// The serials of every timer armed so far, cancelled or not.
    func allArmedSerials() -> [UInt64] { armed.map { $0.serial } }

    /// The seconds every LIVE armed timer is set for, read back from the deadline.
    func liveArmedSeconds() -> [Int] {
        liveArmed.map { Int(($0.deadline.uptimeNanoseconds &- 1) / 1_000_000_000) }
    }
}

/// A session that records what it was asked to do and reports whatever liveness the test sets.
///
/// The crypto is exercised for real in `ChainedSessionRunnerTests`; what the DRIVER is about is
/// the budget, and standing up an engine to answer a question about elapsed seconds would make
/// every test here slower and none of them sharper.
final class StubSession: ChainedSessionDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var sample = ChainedLivenessSample()
    private(set) var tickCount = 0
    private(set) var forcedHandshakeCount = 0
    private(set) var isShutDown = false
    /// COUNTED, not just latched. A rebuild is "this runner was torn down and another built",
    /// and a boolean cannot distinguish that from a runner that was already down.
    private(set) var shutdownCount = 0

    func pretendAuthenticatedPeerDatagram() {
        lock.withLock { sample.sawAuthenticatedPeerDatagram = true }
    }
    func pretendInboundData() { lock.withLock { sample.sawInboundData = true } }
    func pretendObligingSend() { lock.withLock { sample.sawObligingSend = true } }
    /// General user (non-DNS) traffic sets BOTH the obliging-send flag (it arms the link-silence
    /// clock) and the non-DNS flag (the egress-dead demand), exactly as the runner's
    /// `.obligingNonDNS` origin does. So a test that models the egress-dead world — link answered,
    /// nothing forwarded — must also keep the link alive to hold the silence clock off, the way a
    /// real chain with a dead upstream does.
    func pretendObligingNonDNSSend() {
        lock.withLock {
            sample.sawObligingSend = true
            sample.sawObligingNonDNSSend = true
        }
    }
    func pretendChannelSaturated() { lock.withLock { sample.sendChannelSaturated = true } }

    func handleOutboundBatch(_ packets: [Data], protocols: [NSNumber]) {}
    func tick() { lock.withLock { tickCount += 1 } }
    /// Records the call AND the obliging send it produces, because the real runner's
    /// `forceHandshake` reaches `perform` with `origin: .obliging` — the handshake initiation
    /// is a datagram the peer owes an answer to. A stub that only counted the call made the
    /// driver's re-arm-on-wake untestable: nothing armed, so the test could not tell a fixed
    /// driver from a broken one.
    func forceHandshake() {
        lock.withLock {
            forcedHandshakeCount += 1
            sample.sawObligingSend = true
        }
    }
    /// Invoked when the driver shuts this session down, OUTSIDE the stub's lock.
    ///
    /// THE ONLY RE-ENTRANCY HOOK THE DRIVER HARNESS HAS, and it exists because one invariant
    /// cannot be reached without it: `sessionEnded` queues a re-entrant end in a FIFO, and the
    /// re-entrant frame is only reachable from a callback the driver makes while it is INSIDE
    /// `finishAttempt` — of which `runner?.shutdown()` is the one the fixtures can reach. Without
    /// it every test delivers ends sequentially, `isProcessingEnd` is false on entry to each, and
    /// the queue is never exercised as a queue (sweep, PR #623).
    ///
    /// Called outside the lock deliberately: the closure re-enters the DRIVER, and holding a stub
    /// lock across a callback into the object that owns this one is how a fixture deadlocks.
    var onShutdown: (@Sendable () -> Void)?

    func shutdown() {
        lock.withLock { isShutDown = true; shutdownCount += 1 }
        onShutdown?()
    }

    /// Scripted, because what a rebind achieves is exactly what the driver has to triage: a
    /// swap with a live keypair, a swap with none, or a refusal. A stub that always succeeded
    /// could not tell the fast path from its fallbacks.
    var rebindOutcome: ChainedRebindOutcome = .rebound
    private(set) var adoptedChannelCount = 0

    func adoptChannel(_ channel: ChainedUpstreamDatagramChannel) -> ChainedRebindOutcome {
        lock.withLock {
            adoptedChannelCount += 1
            // The real runner closes the replacement on every non-`.rebound` outcome, and the
            // driver relies on that to not leak a bound port. Mirrored here so a test cannot
            // pass against a fake that is more forgiving than production.
            if rebindOutcome != .rebound { channel.close() }
            return rebindOutcome
        }
    }

    func takeLivenessSample() -> ChainedLivenessSample {
        lock.withLock {
            let taken = sample
            sample = ChainedLivenessSample()
            return taken
        }
    }

    /// Scripted like the liveness sample: a test sets what the engine's byte totals should read.
    var stubStatistics: ChainedRunnerStatistics?
    func sampleStatistics() -> ChainedRunnerStatistics? { lock.withLock { stubStatistics } }

    /// The rotation this stub claims to be running. Immutable in production; a plain var here so
    /// a test can stage one.
    var acceptedUpstreamGeneration: UInt64 = 0

    /// Scripted so a test can hand the driver pressure tallies to fold in on retirement.
    var stubCounters = ChainedRunnerCounters()
    func snapshotCounters() -> ChainedRunnerCounters { lock.withLock { stubCounters } }
}

/// Hands out one prepared outcome per call, then fails — which is how a real source behaves when
/// the endpoint is unreachable.
///
/// A FAILURE IS SCRIPTABLE TOO, and with its error, because what a build failure costs now depends
/// on which error it is: `ChainedSessionBuildFailure.warrantsAnotherAttempt` decides whether the
/// driver spends a ladder rung or surrenders chained mode. A source that could only fail one way
/// could not tell the two apart.
final class ScriptedSessionSource: ChainedSessionSource, @unchecked Sendable {
    struct Unavailable: Error {}

    private let lock = NSLock()
    private var outcomes: [Result<StubSession, Error>] = []
    private var handedOutStorage: [StubSession] = []
    private var calls = 0
    /// Every session this source actually returned, in order. The driver builds a FRESH one per
    /// attempt, so a test that keeps poking the adopted session is talking to a retired object.
    var handedOut: [StubSession] { lock.withLock { handedOutStorage } }
    /// How many times the driver asked for a session, and what was armed when it did.
    var callCount: Int { lock.withLock { calls } }
    var armedWhenAsked: [Int] { lock.withLock { armedSnapshots } }
    private var armedSnapshots: [Int] = []
    /// Set by the harness so the source can record what was armed at the moment it was called.
    var liveArmedCount: (@Sendable () -> Int)?

    func push(_ session: StubSession) { lock.withLock { outcomes.append(.success(session)) } }

    /// Scripts a build that FAILS with this error, so a test can choose what the driver has to
    /// triage. An empty script still throws ``Unavailable``, which is an error nothing can
    /// classify — the conservative case.
    func pushFailure(_ error: Error) { lock.withLock { outcomes.append(.failure(error)) } }

    /// Scripted independently of `makeSession`: a rebind can fail where a build would succeed
    /// (the interface went away between them) and the driver must fall back rather than assume.
    var channelOutcome: Result<ChainedUpstreamDatagramChannel, Error> = .success(RebindableFakeChannel())
    private(set) var madeChannelCount = 0

    func makeChannel(engineQueue: ChainedEngineQueue) throws -> ChainedUpstreamDatagramChannel {
        try lock.withLock {
            madeChannelCount += 1
            return try channelOutcome.get()
        }
    }

    func makeSession(
        engineQueue: ChainedEngineQueue,
        events: ChainedSessionEvents
    ) throws -> ChainedSessionDriving {
        let armed = liveArmedCount?() ?? -1
        let next: Result<StubSession, Error>? = lock.withLock {
            calls += 1
            armedSnapshots.append(armed)
            return outcomes.isEmpty ? nil : outcomes.removeFirst()
        }
        guard let next else { throw Unavailable() }
        let session = try next.get()
        lock.withLock { handedOutStorage.append(session) }
        return session
    }
}


/// A channel a rebind can be handed. Records its own close, because "the replacement was closed
/// on a declined rebind" is the property that keeps a refused fast path from leaking a bound UDP
/// port — and nothing in the protocol obliges a conformer to do it.
final class RebindableFakeChannel: ChainedUpstreamDatagramChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (UnsafeRawBufferPointer) -> Void)?
    private(set) var closeCount = 0
    private(set) var sentCount = 0
    var isClosed: Bool { lock.withLock { closeCount > 0 } }

    /// Withholding is not a detail — a channel that completes inline never ACCUMULATES
    /// outstanding sends, so nothing ever parks, so a test about spurious releases has nothing
    /// to release. Two mutation rounds survived against the inline-only version.
    var withholdCompletions = false
    private var pending: [@Sendable (Bool) -> Void] = []

    func send(_ datagram: UnsafeRawBufferPointer, completion: @escaping @Sendable (Bool) -> Void) {
        let withhold: Bool = lock.withLock {
            sentCount += 1
            return withholdCompletions
        }
        if withhold {
            lock.withLock { pending.append(completion) }
        } else {
            completion(true)
        }
    }

    func releaseCompletions() {
        let waiting: [@Sendable (Bool) -> Void] = lock.withLock {
            let all = pending
            pending.removeAll()
            return all
        }
        for completion in waiting { completion(true) }
    }
    func setReceiveHandler(_ handler: @escaping @Sendable (UnsafeRawBufferPointer) -> Void) {
        lock.withLock { self.handler = handler }
    }
    func close() { lock.withLock { closeCount += 1; handler = nil } }
    func deliver(_ datagram: UnsafeRawBufferPointer) { lock.withLock { handler }?(datagram) }
}
