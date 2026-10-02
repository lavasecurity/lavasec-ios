import Foundation

/// One observation of the upstream UDP transport's own health signals — TELEMETRY ONLY.
///
/// `ChainedUpstreamChannel` documents that transport failure deliberately has no separate
/// REMEDY signal: the outage driver learns "the socket is broken" and "the peer is gone" as
/// one fact, through silence, and a second remedy path would give it two sources of truth.
/// That design survives this type. What the field showed (brief-stall investigation,
/// 2026-08-24) is that it left the tunnel unable to even NAME a stall: a socket that spends
/// two seconds in `.waiting` under Wi-Fi power-save recovers before the silence detector's
/// threshold, and nothing anywhere records that it happened. These events feed a device-log
/// line and a counter the 60 s liveness sample can difference — never a decision.
public enum ChainedChannelTransportEvent: Equatable, Sendable {
    /// The `NWConnection` changed state. `previousMilliseconds` is how long it spent in
    /// `previousState`, so a `waiting → ready` line carries the stall's duration by itself.
    case stateChanged(state: String, previousState: String, previousMilliseconds: Int)
    /// The connection's viability flipped. `false` is the closest thing Network.framework
    /// has to "frames are currently not deliverable" — exactly the signal the send path
    /// cannot see (a send into a non-viable connection still completes without error).
    case viabilityChanged(isViable: Bool, previousMilliseconds: Int)
    /// The framework advertises a better path (or stops). Pure context for reading the log.
    case betterPathChanged(hasBetterPath: Bool)
    /// A send completion carried an error — EDGE-TRIGGERED on the first failure after a
    /// success, because a dead socket fails every send at line rate and the tally of the
    /// volume is `ChainedRunnerCounters.sendCompletionErrorCount`'s job.
    case sendFailed(error: String)
    /// The receive loop stopped re-arming because `receiveMessage` completed with an error
    /// on a channel that was NOT closed. After this the socket delivers nothing even if the
    /// connection recovers — inbound-blackhole evidence a byte counter cannot distinguish
    /// from an idle peer.
    case receiveLoopEnded(error: String)
}

/// Derives ``ChainedChannelTransportEvent``s from raw `NWConnection` callbacks, carrying the
/// per-state timing and the send-failure edge so the untestable glue in
/// `ChainedUpstreamChannel` stays decision-free.
///
/// ## Confinement
///
/// NOT locked, and that is a contract rather than an oversight: every input arrives on the
/// connection's dispatch queue — `NWConnection` delivers state, viability, better-path and
/// send-completion callbacks on the queue passed to `start(queue:)`, and the receive loop's
/// error branch runs there too — so the mutable state is queue-confined the same way the
/// runner's is. `@unchecked Sendable` because the CHANNEL is; a test drives it from one
/// thread, which satisfies the same contract.
///
/// The `emit` sink runs inline on that queue and must not block — it is the same obligation
/// every channel callback already carries (`ChainedSessionSource`'s no-blocking contract).
public final class ChainedChannelTransportObserver: @unchecked Sendable {
    /// Which socket an event belongs to. Rebinds and rebuilds create fresh channels, so a
    /// log line's sequence is what separates "the live socket went `.waiting`" from a
    /// retired socket's teardown `.cancelled` — and a NEW sequence appearing in the log IS
    /// the timestamped marker that a rebind/rebuild built a socket.
    public let channelSequence: Int
    private let emit: @Sendable (Int, ChainedChannelTransportEvent) -> Void
    private let nowNanoseconds: @Sendable () -> UInt64

    private var stateDescription = "init"
    private var stateSinceNanoseconds: UInt64
    private var isViable = true
    private var viableSinceNanoseconds: UInt64
    private var lastSendFailed = false

    private static let sequenceLock = NSLock()
    /// Guarded by `sequenceLock`; `nonisolated(unsafe)` is the annotation for exactly a
    /// lock-protected global under strict concurrency.
    nonisolated(unsafe) private static var nextSequence = 0
    private static func claimSequence() -> Int {
        sequenceLock.withLock {
            nextSequence += 1
            return nextSequence
        }
    }

    /// - Parameters:
    ///   - channelSequence: injectable for tests; nil (production) claims the process-wide
    ///     counter's next value.
    ///   - nowNanoseconds: `CLOCK_MONOTONIC`, the base that keeps counting through a
    ///     suspension — a `.waiting` interval spanning one should read as the wall time the
    ///     user actually stared at it, not the awake sliver.
    public init(
        channelSequence: Int? = nil,
        emit: @escaping @Sendable (Int, ChainedChannelTransportEvent) -> Void,
        nowNanoseconds: @escaping @Sendable () -> UInt64 = {
            clock_gettime_nsec_np(CLOCK_MONOTONIC)
        }
    ) {
        self.channelSequence = channelSequence ?? Self.claimSequence()
        self.emit = emit
        self.nowNanoseconds = nowNanoseconds
        let now = nowNanoseconds()
        stateSinceNanoseconds = now
        viableSinceNanoseconds = now
    }

    public func noteState(_ description: String) {
        // Repeats are not transitions. The framework does not promise to de-duplicate, and
        // a repeated `.waiting` would otherwise read as a fresh stall with a reset clock.
        guard description != stateDescription else { return }
        let now = nowNanoseconds()
        emit(
            channelSequence,
            .stateChanged(
                state: description,
                previousState: stateDescription,
                previousMilliseconds: Self.elapsedMilliseconds(
                    from: stateSinceNanoseconds, to: now)))
        stateDescription = description
        stateSinceNanoseconds = now
    }

    public func noteViability(_ viable: Bool) {
        guard viable != isViable else { return }
        let now = nowNanoseconds()
        emit(
            channelSequence,
            .viabilityChanged(
                isViable: viable,
                previousMilliseconds: Self.elapsedMilliseconds(
                    from: viableSinceNanoseconds, to: now)))
        isViable = viable
        viableSinceNanoseconds = now
    }

    public func noteBetterPath(_ hasBetterPath: Bool) {
        emit(channelSequence, .betterPathChanged(hasBetterPath: hasBetterPath))
    }

    /// `error` is nil for a completion that succeeded. The edge — not every failure — is
    /// emitted; the volume is the runner's counter.
    public func noteSendOutcome(error: String?) {
        guard let error else {
            lastSendFailed = false
            return
        }
        if !lastSendFailed { emit(channelSequence, .sendFailed(error: error)) }
        lastSendFailed = true
    }

    public func noteReceiveLoopEnded(error: String) {
        emit(channelSequence, .receiveLoopEnded(error: error))
    }

    /// `&-` because a trap inside a Network Extension is a tunnel abort; a wrapped reading
    /// produces one absurd duration in a log line, which is recoverable where a crash is not.
    private static func elapsedMilliseconds(from start: UInt64, to now: UInt64) -> Int {
        Int((now &- start) / 1_000_000)
    }
}
