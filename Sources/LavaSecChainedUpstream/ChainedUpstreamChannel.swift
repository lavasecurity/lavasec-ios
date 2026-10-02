import Foundation
import Network

/// The UDP socket to the WireGuard peer, bound to one physical interface.
///
/// ## Deliberately thin
///
/// Everything decidable is decided elsewhere — which interface to bind (`ChainedUpstreamEgress`),
/// what parameters express that binding (`ChainedUpstreamChannelParameters`), when a rebuild is
/// warranted (`ChainedUpstreamEgressPolicy`), and what a stalled transport means
/// (`ChainedSessionRunner`'s send bound). What is left here is plumbing that cannot be unit
/// tested without a network, so the design goal is that there is as little of it as possible and
/// none of it makes a decision.
///
/// ## Why binding is not optional
///
/// The tunnel claims `0.0.0.0/0` while chained (`INV-CHAIN-1`). A socket that resolved its route
/// the ordinary way would therefore be routed INTO the tunnel it is carrying — the packets it
/// sends are the tunnel's own outer datagrams, so that is an immediate loop, not a slow
/// degradation. `ChainedUpstreamChannelParameters` binds to the physical interface and prohibits
/// `.other`, which is the interface type a virtual interface reports; the parameters are refused
/// outright rather than defaulted when the interface kind cannot be expressed, so a channel that
/// could ride the wrong interface is not constructible.
///
/// The binding is by IDENTITY, not merely by kind, and reading the live interface list that
/// makes the identity available is the one job this opener has which the value types could not
/// do for it. It is still not a decision: no match means no channel.
///
/// ## Failure has no separate REMEDY signal, and that is the design
///
/// There is no error callback into the driver here. A connection that fails produces sends that
/// never complete and datagrams that never arrive, which the outage driver already reads as an
/// outage — and from the tunnel's point of view "the socket is broken" and "the peer is gone"
/// are the same fact with the same remedy. A second failure path would give the driver two ways
/// to learn one thing, and the earlier slices' review history is largely about what happens when
/// two sources of truth disagree.
///
/// The TELEMETRY observer below is not that second path, and must never become it. A socket
/// that spends two seconds in `.waiting` under Wi-Fi power-save recovers before the silence
/// detector's threshold, and until this observer existed nothing anywhere recorded that it
/// happened — the brief-stall investigation (2026-08-24) found every 60 s counter flat across a
/// user-visible stall. The observer NAMES such intervals in the device log; it decides nothing,
/// feeds no driver input, and remedies nothing.
public final class ChainedUpstreamChannel: ChainedUpstreamDatagramChannel, @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var handler: (@Sendable (UnsafeRawBufferPointer) -> Void)?
    private var isClosed = false
    /// Telemetry only — see the type doc. Held for the send/receive paths; the state,
    /// viability and better-path handlers capture it directly. The observer holds no
    /// reference back to this channel or its connection, so the handlers' strong captures
    /// cannot cycle, and `deinit`'s close still runs.
    private let observer: ChainedChannelTransportObserver?

    /// - Parameter liveInterfaces: the interfaces to match `binding` against, or `nil` to read
    ///   the shared path cache now. `ChainedUpstreamSessionFactory` passes the reading it already
    ///   took, so the production build consults the system exactly once; a test passes the empty
    ///   list, which is the only value it can pass because `NWInterface` cannot be constructed.
    /// - Parameter telemetry: where transport observations go — `(channelSequence, event)`,
    ///   called inline on `queue` and must not block. Nil (the default) installs no handlers
    ///   at all, so the pre-observability behaviour is the absence of the parameter.
    /// - Returns: `nil` when the binding cannot be expressed as interface-bound parameters —
    ///   the kind is unconstrainable, or no live interface carries the selected identity. Both
    ///   are refusals the parameters type makes rather than defaulting, and the caller turns
    ///   them into `ChainedSessionBuildFailure.unbindableInterface`.
    public init?(
        endpoint: ChainedEndpointAddress,
        binding: ChainedBindableInterface,
        queue: DispatchQueue,
        liveInterfaces: [NWInterface]? = nil,
        telemetry: (@Sendable (Int, ChainedChannelTransportEvent) -> Void)? = nil
    ) {
        let candidates = liveInterfaces ?? ChainedUpstreamLivePath.shared.availableInterfaces()
        guard let parameters = ChainedUpstreamChannelParameters.make(for: binding, among: candidates),
              let port = NWEndpoint.Port(rawValue: endpoint.port)
        else { return nil }
        connection = NWConnection(
            host: NWEndpoint.Host(endpoint.literal), port: port, using: parameters)
        if let telemetry {
            let observer = ChainedChannelTransportObserver(emit: telemetry)
            self.observer = observer
            // Installed BEFORE start, so the birth transitions (`.preparing`, `.ready`) are
            // observed — a fresh sequence's first line in the log is the timestamped marker
            // that a rebind or rebuild built this socket.
            connection.stateUpdateHandler = { state in
                observer.noteState(Self.describe(state))
            }
            connection.viabilityUpdateHandler = { viable in
                observer.noteViability(viable)
            }
            connection.betterPathUpdateHandler = { hasBetterPath in
                observer.noteBetterPath(hasBetterPath)
            }
        } else {
            observer = nil
        }
        connection.start(queue: queue)
        receiveNext()
    }

    public func send(_ datagram: UnsafeRawBufferPointer, completion: @escaping @Sendable (Bool) -> Void) {
        // COPIED HERE, and that is the protocol's contract rather than an accident: the pointer
        // is borrowed for this call only, and the runner sends from one reused scratch buffer
        // with up to `inFlightSendBound` sends outstanding. `Data(bytes:count:)` copies eagerly,
        // so the bytes are ours before this returns.
        let payload = Data(bytes: datagram.baseAddress!, count: datagram.count)
        let observer = observer
        connection.send(
            content: payload,
            completion: .contentProcessed { error in
                // The NWError's shape is only visible here, so the edge-triggered telemetry
                // line is this channel's to emit; the runner counts the Bool it already gets.
                observer?.noteSendOutcome(error: error.map(Self.describe))
                completion(error == nil)
            })
    }

    public func setReceiveHandler(_ handler: @escaping @Sendable (UnsafeRawBufferPointer) -> Void) {
        lock.withLock { self.handler = handler }
    }

    /// Closes on the last release, so a channel that is merely DROPPED does not leak.
    ///
    /// `connection.cancel()` appears exactly once in this module, inside `close()`. Without this
    /// a dropped channel leaves a bound UDP port with its `receiveMessage` loop still armed and
    /// re-arming itself — invisible, and one port per drop in the process with the tightest
    /// memory ceiling. It became reachable when the transport stopped being owned for the
    /// lifetime of its session (R2); it is fixed here rather than at the one call site, so a
    /// future caller cannot reintroduce it.
    deinit { close() }

    public func close() {
        let shouldCancel: Bool = lock.withLock {
            guard !isClosed else { return false }
            isClosed = true
            handler = nil
            return true
        }
        guard shouldCancel else { return }
        connection.cancel()
    }

    /// One receive at a time, re-armed after each datagram.
    ///
    /// `receiveMessage` delivers exactly one datagram per call, so the loop is the re-arm. It is
    /// re-armed BEFORE the handler runs: the handler hops to the engine queue and can take
    /// arbitrarily long, and a receive armed only afterwards would leave the socket unread for
    /// that whole window — losing datagrams to the socket buffer under exactly the load where
    /// they matter.
    private func receiveNext() {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            let live = self.lock.withLock { !self.isClosed }
            guard live else { return }
            if let error {
                // The loop is about to stop re-arming on a channel nobody closed — after
                // this, a connection that recovers still delivers nothing, and the only
                // downstream symptom is inbound silence. Telemetry only: the remedy stays
                // the outage driver's, through that silence, exactly as the type doc says.
                self.observer?.noteReceiveLoopEnded(error: Self.describe(error))
            } else {
                self.receiveNext()
            }
            guard let content, !content.isEmpty else { return }
            let handler = self.lock.withLock { self.handler }
            content.withUnsafeBytes { handler?($0) }
        }
    }

    /// Stable, PII-free log forms. An `NWError`'s description can be verbose; the code and
    /// family are what a device log needs to name a mechanism (`posix-50` is `ENETDOWN`,
    /// `posix-65` `EHOSTUNREACH`), and neither carries an address or a name.
    private static func describe(_ state: NWConnection.State) -> String {
        switch state {
        case .setup: return "setup"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .waiting(let error): return "waiting:\(describe(error))"
        case .failed(let error): return "failed:\(describe(error))"
        case .cancelled: return "cancelled"
        @unknown default: return "unknown"
        }
    }

    private static func describe(_ error: NWError) -> String {
        // A plain `default`, not `@unknown default`: the SDK grows named cases (`.wifi` on
        // newer platforms) and this build compiles for more than one of them — an exhaustive
        // list here is a per-SDK compile break for a log string.
        switch error {
        case .posix(let code): return "posix-\(code.rawValue)"
        case .dns(let code): return "dns-\(code)"
        case .tls(let code): return "tls-\(code)"
        default: return "nw-other"
        }
    }
}

/// The interfaces the system currently reports, for the one caller that needs identities.
///
/// ## Why this is not a one-line property read
///
/// `NWPathMonitor().currentPath` on a monitor that has never been started reports `.unsatisfied`
/// with an EMPTY interface list — measured on macOS 26, and still empty on a second fresh
/// monitor in a process where another monitor has already run, so it is not warm-up state that
/// some earlier start fixes. A bare `currentPath.availableInterfaces` read would therefore match
/// nothing, every time, and with `ChainedUpstreamChannelParameters`' refusal that is not a subtle
/// bug: it is chaining that never starts. A monitor has to be started and its first report
/// awaited. The only thing this type decides is WHERE that wait is paid.
///
/// That first report is the monitor stating whatever the path IS, including an unsatisfied one —
/// it is not a wait for connectivity, which is why a short cap is honest rather than optimistic.
/// Measured at 0.1–1.6 ms.
///
/// ## Not on the engine queue, and that is a contract rather than a preference
///
/// ``ChainedSessionSource`` states that a source must not block the engine queue.
/// `ChainedOutageDriver.startAuthorizedAttempt` calls `makeSession` INLINE on that queue with no
/// hop, and `ChainedEngineQueueTimers` fires every driver timer there, so a source that blocks
/// defers whichever handler is queued behind it by however long it blocks. The handler that
/// matters is the attempt watchdog: its deadline is the same absolute instant as the outage
/// deadline (`ChainedOutageDriver.beginOutage` derives why), so it is the fire that surrenders at
/// budget exhaustion, and deferring it is blackhole time past the bound the budget exists to be —
/// on the one path where the queue has no session to serve and nothing to notice with.
///
/// The first version of this type started a fresh monitor per socket and blocked on its first
/// report from exactly there, for up to 250 ms (PR #484). So the monitor is started ONCE and
/// kept, its reports are cached as they arrive on its own queue, and the per-attempt read is a
/// copy of that cache which never waits.
/// pinned: ChainedUpstreamSessionFactoryTests.testBuildingASessionNeverWaitsOnAPathMonitorThatHasNotReported
///
/// ## The wait still exists, and where it is paid is now a compiler question
///
/// A cache is empty until the first report arrives, and a cold read refuses the socket. Dropping
/// the wait entirely was considered and rejected. The original reason was that a refusal was not
/// a spent ladder rung at all: the driver turned every build failure into
/// `ChainedSessionEndCause.sessionCreationFailed` and `ChainedReconnectPolicy` answered it with
/// `.fallBackToDNSOnly(.engineUnusable)`, so ONE cold read surrendered chained mode for the whole
/// tunnel lifecycle. That was a defect in the driver rather than an argument for this wait, and it
/// is fixed: a cold read now refuses with `ChainedSessionBuildFailure.unbindableInterface`, which
/// the factory classifies as transient, so it costs one rung.
///
/// The wait stays because the rest of the reason survives, and it is the worse half. Before the
/// driver exists there is no ladder to spend: the FIRST session is built by the wiring, and a cold
/// read there means chaining simply never starts. A rung is also not free — it is one of about
/// three the 15-second budget buys, spent on a cache that fills in 0.1–1.6 ms.
/// pinned: ChainedOutageDriverTests.testATransientBuildFailureSpendsARungRatherThanSurrendering
///
/// So the wait is paid once, off the engine queue, by ``primed(offEngineQueue:timeoutMilliseconds:)``
/// — and its result is a ``ChainedPrimedLivePath``, which is what
/// ``ChainedUpstreamSessionFactory`` requires. "Somebody primed this first" stopped being a
/// sentence in a comment and became a value the initialiser cannot be called without.
///
/// A kept monitor is also FRESHER than the per-socket one it replaces rather than staler: it
/// carries whatever the path last became, where a fresh monitor's first report was a round trip
/// the attempt had to stand still for. The cost is one monitor for the life of the process,
/// which against `INV-MEM-1` is nothing.
public final class ChainedUpstreamLivePath: @unchecked Sendable {
    /// The process's one monitor. Everything in production reads this; only a test builds another.
    public static let shared = ChainedUpstreamLivePath()

    /// Begins delivering path reports to `sink` and returns whatever must be retained for them to
    /// keep arriving.
    ///
    /// Injected because the property that matters is what happens when NOTHING reports, and no
    /// real monitor produces that on demand — it was also the case the old bounded wait swallowed,
    /// since a silent monitor cost the full timeout and still returned a plausible empty list.
    public typealias Observation = @Sendable (@escaping @Sendable ([NWInterface]) -> Void) -> AnyObject?

    private let observe: Observation
    /// One condition rather than a lock beside a semaphore: the priming wait is a bounded wait
    /// for a state change that more than one caller may be sitting on, and a semaphore hands its
    /// single signal to exactly one of them.
    ///
    /// Module-internal rather than private, for the same reason ``Observation`` is injected: the
    /// property that matters is what a wake that is NOT a report does, and nothing can produce one
    /// on demand from outside — a spurious wake-up is by definition not something a caller
    /// arranges. A test broadcasts on this directly, which is exactly a wake with `hasReported`
    /// still false.
    /// pinned: ChainedUpstreamChannelTests.testAWakeWithoutAReportDoesNotEndThePrimingWait
    let state = NSCondition()
    private var latest: [NWInterface] = []
    private var hasReported = false
    private var isObserving = false
    private var observation: AnyObject?

    public init(observe: @escaping Observation = ChainedUpstreamLivePath.systemPathMonitor) {
        self.observe = observe
    }

    /// The per-attempt read. Starts the monitor if nothing has yet, and NEVER waits.
    ///
    /// Starting from here as well as from the prime is deliberate: ``ChainedUpstreamChannel``'s
    /// initialiser is public and constructible without a factory, and a channel built that way
    /// should leave the monitor running for the next attempt rather than read an empty cache
    /// forever.
    public func availableInterfaces() -> [NWInterface] {
        startObserving()
        state.lock()
        defer { state.unlock() }
        return latest
    }

    /// Starts the monitor, waits — bounded — for its first report, and hands back the proof.
    ///
    /// THE ONE PLACE IN THE CHAINED TRANSPORT THAT WAITS ON SOMETHING THAT MAY NEVER ARRIVE —
    /// `ChainedEngineQueue.run`'s `sync` is a hop and completes when the queue drains; this stands
    /// still for a report only the system can produce. The precondition is what makes that
    /// tolerable. `ChainedEngineQueueTimers` fires every outage-driver timer on the engine
    /// queue and `ChainedOutageDriver.startAuthorizedAttempt` runs inline on it, so blocking there
    /// defers the attempt watchdog — whose deadline is the outage deadline itself — and a late
    /// surrender is blackhole time past the bound the budget exists to be. That obligation used to
    /// be a paragraph asking the caller not to; it is now a trap.
    ///
    /// A timeout leaves the cache empty, which refuses the socket exactly as an unmatched
    /// interface does — a refusal, never a type-only binding.
    ///
    /// - Parameters:
    ///   - engineQueue: the queue this must NOT be standing on. Call it from tunnel setup, before
    ///     any outage clock exists.
    ///   - timeoutMilliseconds: the cap on the wait. The first report is the monitor stating
    ///     whatever the path IS, measured at 0.1–1.6 ms; the cap is for a monitor that never
    ///     answers at all.
    public func primed(
        offEngineQueue engineQueue: ChainedEngineQueue,
        timeoutMilliseconds: Int = 250
    ) -> ChainedPrimedLivePath {
        engineQueue.requireOffQueue()
        _ = startedAndWaitingForFirstReport(timeoutMilliseconds: timeoutMilliseconds)
        return ChainedPrimedLivePath(self)
    }

    /// The wait itself, without the queue check — module-internal so the only PUBLIC door to it
    /// is the enforced one above.
    ///
    /// A PREDICATE LOOP against ONE fixed deadline, and both halves are load-bearing:
    ///
    /// It was `if !hasReported { wait(until:) }` — a single wait, whose return was treated as
    /// proof that a report had arrived. `NSCondition.wait` may return SPURIOUSLY, before any
    /// broadcast, which is why every condition-variable API in every language documents the
    /// predicate as the thing to re-check rather than the wake. On a spurious wake this returned
    /// the still-empty cache; the caller took that as a primed path, the next build matched no
    /// interface identity and refused the socket, and the driver answered the refusal by ending
    /// chained mode for the tunnel lifecycle. Waiting on a state change and then not re-reading
    /// the state is the whole defect.
    ///
    /// The deadline is computed ONCE, before the loop. Recomputing it per wake turns a bounded
    /// wait into an unbounded one — each wake would restore the full cap — and this runs where
    /// tunnel setup is standing still for it.
    /// pinned: ChainedUpstreamChannelTests.testAWakeWithoutAReportDoesNotEndThePrimingWait
    /// pinned: ChainedUpstreamChannelTests.testWakesCannotStretchThePrimingWaitPastItsTimeout
    @discardableResult
    func startedAndWaitingForFirstReport(timeoutMilliseconds: Int = 250) -> [NWInterface] {
        startObserving()
        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1000)
        state.lock()
        defer { state.unlock() }
        while !hasReported {
            // `false` means the deadline passed. Only a real report or the cap itself can leave
            // this loop.
            guard state.wait(until: deadline) else { break }
        }
        return latest
    }

    private func startObserving() {
        state.lock()
        let shouldStart = !isObserving
        isObserving = true
        state.unlock()
        guard shouldStart else { return }
        // STARTED OUTSIDE THE LOCK. The report handler takes it, so a monitor that ever delivered
        // its first report inline on the starting thread would deadlock against the caller that
        // started it.
        let token = observe { [weak self] interfaces in self?.record(interfaces) }
        state.lock()
        observation = token
        state.unlock()
    }

    private func record(_ interfaces: [NWInterface]) {
        state.lock()
        latest = interfaces
        hasReported = true
        state.broadcast()
        state.unlock()
    }

    /// The real monitor, reporting on its OWN queue and never a caller's.
    ///
    /// The monitor is returned to be RETAINED. `start(queue:)` does not promise that the framework
    /// keeps it alive, and a released monitor stops reporting — which here would not error, it
    /// would freeze the cache at whatever the path was when the last strong reference went away.
    public static let systemPathMonitor: Observation = { sink in
        let monitor = NWPathMonitor()
        // USED-FIRST ordering, deliberately not the system's: `availableInterfaces` is not
        // ordered by the route the path selected, and a consumer taking the head as "the
        // used interface" can bind cellular while the system routes Wi-Fi — the exact
        // field case `ChainedUpstreamSocketLifecycle`'s doc records (Codex, PR #508).
        // Partitioning by `usesInterfaceType` puts route truth at the head while keeping
        // the full list: the channel's identity match consults membership, not order.
        monitor.pathUpdateHandler = { path in
            let interfaces = path.availableInterfaces
            let used = interfaces.filter { path.usesInterfaceType($0.type) }
            sink(used + interfaces.filter { !path.usesInterfaceType($0.type) })
        }
        monitor.start(queue: DispatchQueue(label: "com.lavasec.chained.livepath"))
        return monitor
    }
}

/// A ``ChainedUpstreamLivePath`` whose monitor has been started and whose first report has been
/// awaited — the only thing ``ChainedUpstreamSessionFactory`` will build sessions over.
///
/// A type rather than a comment because the obligation is one nobody notices being dropped. An
/// unprimed cache reports no interfaces, an empty list matches no binding, and a build that
/// matches no binding is refused — so an unprimed path is a tunnel whose every attempt refuses,
/// silently, for a reason no log names, and the first refusal happens before any retry ladder
/// exists to absorb it. One forgotten call away, so it is worth a value the initialiser cannot be
/// called without.
///
/// It carries no interface list of its own. The reading is taken per attempt from the same cache
/// (``availableInterfaces()``), because a list captured here would be the network as it was at
/// tunnel setup — and an attempt exists precisely because the network changed.
public struct ChainedPrimedLivePath: Sendable {
    private let path: ChainedUpstreamLivePath

    init(_ path: ChainedUpstreamLivePath) {
        self.path = path
    }

    /// The per-attempt read: a copy of the cache, and never a wait. See
    /// ``ChainedUpstreamLivePath/availableInterfaces()``.
    public func availableInterfaces() -> [NWInterface] { path.availableInterfaces() }
}
