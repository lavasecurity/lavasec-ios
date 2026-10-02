import Foundation

/// Turns transport and pressure observations into rate-bounded device-log emissions and
/// cumulative tallies — the decision half of the observability, so the provider's sink stays a
/// one-line append.
///
/// ## Why the rate bound lives here and not at the emitters
///
/// The runner emits pressure events unthrottled because its failure paths are the wrong place
/// for a clock, and the channel observer emits every state transition because de-duplication is
/// the only judgement it can make locally. Neither knows what the LOG can absorb. This type
/// does: at most one line per event kind per ``minimumSecondsBetweenLogs``, everything counted
/// in the tallies whether logged or not, and a suppressed-line count so a throttled storm is
/// itself visible. The 8 MB on-device log rotates (`LavaSecDeviceDebugLog`), so the bound is
/// about signal, not survival — a hundred identical `shed` lines say less than one line plus a
/// counter that moved by a hundred.
///
/// ## Confinement
///
/// One lock, because the inputs genuinely race: channel events arrive on the engine queue,
/// pressure refusals on the producer's thread before the hop, and the tally snapshot on the
/// provider's 60 s tick. Everything behind the lock is integer arithmetic; the log append never
/// happens under it.
public final class ChainedTransportDiagnosticsRecorder: @unchecked Sendable {
    /// One prepared device-log line: `event` and flattened string details, ready for the
    /// provider to append verbatim. A struct rather than the append itself so this type never
    /// needs a logger — and stays executable-testable.
    public struct Emission: Equatable, Sendable {
        public let event: String
        public let details: [String: String]
    }

    /// Cumulative counts of every observation, logged or throttled — the 60 s liveness line
    /// differences these, so a blip window names its mechanism even when the per-event lines
    /// were suppressed.
    public struct Tallies: Equatable, Sendable {
        /// Transitions INTO a non-ready connection state (`waiting`/`failed`), which is the
        /// socket-went-dark signal the send path cannot see.
        public var stateNotReadyTransitionCount = 0
        /// Transitions to `isViable == false`.
        public var unviableTransitionCount = 0
        /// Send-failure edges (first failure after a success), per channel.
        public var sendFailedEdgeCount = 0
        /// Receive loops that ended on an error — after which that socket delivers nothing.
        public var receiveLoopEndedCount = 0
        /// Pressure events (queue evictions/refusals at either dispatch boundary).
        public var pressureEventCount = 0
        /// Log lines the rate bound suppressed on the CHANNEL path — connection state,
        /// viability, better-path, send-failure edges, receive-loop ends.
        public var suppressedTransportLogCount = 0
        /// Log lines the rate bound suppressed on the PRESSURE path — queue evictions and
        /// refusals at either dispatch boundary.
        ///
        /// SEPARATE from the channel tally because the two name different mechanisms, and a
        /// surface reporting one total under a channel-shaped name attributed a queue-pressure
        /// storm to the NWConnection — the opposite fault, and the wrong thing to go and look at
        /// (Codex P2, PR #582).
        public var suppressedPressureLogCount = 0
        /// All kinds. Derived, so it can never disagree with its parts.
        public var suppressedLogCount: Int {
            suppressedTransportLogCount + suppressedPressureLogCount
        }
        public init() {}
    }

    /// Per event kind. One second: fast enough that consecutive distinct moments in a 1–2 s
    /// blip each get a line, slow enough that a per-arrival storm costs one line per second.
    public static let minimumSecondsBetweenLogs = 1

    private let lock = NSLock()
    private var tallies = Tallies()
    /// Last emission instant per event name, on `nowNanoseconds`'s clock.
    private var lastEmissionNanoseconds: [String: UInt64] = [:]
    private let nowNanoseconds: @Sendable () -> UInt64

    public init(
        nowNanoseconds: @escaping @Sendable () -> UInt64 = {
            clock_gettime_nsec_np(CLOCK_MONOTONIC)
        }
    ) {
        self.nowNanoseconds = nowNanoseconds
    }

    /// Records one channel observation; returns the log line to append now, or nil when the
    /// rate bound already spent this observation's slot.
    ///
    /// The rate key includes the channel AND the observed value, never the bare event name: a
    /// rebind's marker is three distinct transitions inside one second (old socket `cancelled`,
    /// new socket `preparing` then `ready`), and a name-wide bound would log the first and eat
    /// the birth. What the bound is FOR is a pathological flap repeating the SAME transition —
    /// `waiting ↔ ready` on one socket costs at most two lines per second, while every distinct
    /// moment of an ordinary lifecycle logs.
    /// pinned: ChainedTransportDiagnosticsRecorderTests.testARebindsDistinctTransitionsAllLogInsideOneSecond
    /// pinned: ChainedTransportDiagnosticsRecorderTests.testARepeatedTransitionIsRateBounded
    public func recordTransport(
        channelSequence: Int, event: ChainedChannelTransportEvent
    ) -> Emission? {
        let name: String
        let valueKey: String
        var details: [String: String] = ["channel": "\(channelSequence)"]
        switch event {
        case .stateChanged(let state, let previousState, let previousMilliseconds):
            name = "chained-transport-state"
            valueKey = state
            details["state"] = state
            details["previousState"] = previousState
            details["previousMs"] = "\(previousMilliseconds)"
        case .viabilityChanged(let isViable, let previousMilliseconds):
            name = "chained-transport-viability"
            valueKey = "\(isViable)"
            details["isViable"] = "\(isViable)"
            details["previousMs"] = "\(previousMilliseconds)"
        case .betterPathChanged(let hasBetterPath):
            name = "chained-transport-better-path"
            valueKey = "\(hasBetterPath)"
            details["hasBetterPath"] = "\(hasBetterPath)"
        case .sendFailed(let error):
            name = "chained-transport-send-failed"
            valueKey = ""
            details["error"] = error
        case .receiveLoopEnded(let error):
            name = "chained-transport-receive-ended"
            valueKey = ""
            details["error"] = error
        }
        return lock.withLock {
            switch event {
            case .stateChanged(let state, _, _):
                if state.hasPrefix("waiting") || state.hasPrefix("failed") {
                    tallies.stateNotReadyTransitionCount += 1
                }
            case .viabilityChanged(let isViable, _):
                if !isViable { tallies.unviableTransitionCount += 1 }
            case .sendFailed:
                tallies.sendFailedEdgeCount += 1
            case .receiveLoopEnded:
                tallies.receiveLoopEndedCount += 1
            case .betterPathChanged:
                break
            }
            return emissionRespectingRateBound(
                name: name, details: details,
                rateKey: "\(name):\(channelSequence):\(valueKey)", kind: .transport)
        }
    }

    /// Records one data-path pressure event; same rate-bound contract as `recordTransport`.
    public func recordPressure(_ event: ChainedDataPathPressureEvent) -> Emission? {
        let name = "chained-data-path-pressure"
        var details: [String: String] = [:]
        switch event {
        case .outboundQueuePressure(let admission, let queueDepth):
            details["kind"] = "outbound-queue"
            details["admission"] = admission
            details["queueDepth"] = "\(queueDepth)"
        case .outboundBacklogRefused(let packets, let bytes):
            details["kind"] = "outbound-backlog-refused"
            details["packets"] = "\(packets)"
            details["bytes"] = "\(bytes)"
        case .inboundBacklogRefused(let bytes):
            details["kind"] = "inbound-backlog-refused"
            details["bytes"] = "\(bytes)"
        }
        return lock.withLock {
            tallies.pressureEventCount += 1
            // Rate-keyed by name AND kind, so an outbound storm cannot silence the first
            // inbound refusal — they are different mechanisms sharing one event name.
            return emissionRespectingRateBound(
                name: name, details: details, rateKey: "\(name):\(details["kind"] ?? "")", kind: .pressure)
        }
    }

    /// The tallies so far. Read by the 60 s liveness line, and by the QA recovery-window
    /// sampler — which is the reader that matters for a session that dies before 60 s and
    /// therefore never reaches the liveness line at all.
    public func snapshotTallies() -> Tallies {
        lock.withLock { tallies }
    }

    /// Caller holds `lock`.
    /// Which mechanism an emission belongs to, so a suppression is tallied against the thing
    /// that actually storm-ed rather than against whichever name the caller happened to use.
    enum SuppressionKind { case transport, pressure }

    /// Caller holds `lock`.
    private func emissionRespectingRateBound(
        name: String, details: [String: String], rateKey: String? = nil,
        kind: SuppressionKind
    ) -> Emission? {
        let key = rateKey ?? name
        let now = nowNanoseconds()
        if let last = lastEmissionNanoseconds[key],
            now &- last < UInt64(Self.minimumSecondsBetweenLogs) &* 1_000_000_000 {
            switch kind {
            case .transport: tallies.suppressedTransportLogCount += 1
            case .pressure: tallies.suppressedPressureLogCount += 1
            }
            return nil
        }
        // BOUNDED. Keys carry channel sequences, which grow by one per rebind for the life of
        // the tunnel — unpruned, a week of periodic rebinds is an unbounded dictionary inside
        // the ~50 MB ceiling (`INV-MEM-1`). An entry older than the rate window can never
        // suppress anything again, so once the map is past a nominal size, expired entries are
        // dropped before the new one is stored. O(entries), on an at-most-once-per-second path.
        if lastEmissionNanoseconds.count >= 64 {
            let horizon = UInt64(Self.minimumSecondsBetweenLogs) &* 1_000_000_000
            lastEmissionNanoseconds = lastEmissionNanoseconds.filter {
                now &- $0.value < horizon
            }
        }
        lastEmissionNanoseconds[key] = now
        return Emission(event: name, details: details)
    }
}
