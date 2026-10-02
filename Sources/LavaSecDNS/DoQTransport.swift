import Foundation
import LavaSecKit
import Network

// DNS-over-QUIC execution, extracted from PacketTunnelProvider. The pool keeps
// a bounded set of DoQConnection lanes per endpoint so parallel queries avoid
// head-of-line blocking; each query currently opens a fresh QUIC connection
// (reuse review is a tracked Track 4 item). Debug logging is injected so the
// transport never links a logging backend itself.
//
// DESIGN / ENERGY TRADE-OFF (NRG — deferred, no behavior change here):
// Each query pays a FULL QUIC handshake (TLS 1.3 over QUIC) plus connection
// tear-down, which is the single largest per-query transport energy cost in the
// tunnel: a radio wake for the handshake round-trips on every DoQ query, where
// DoH/DoT pool and reuse connections. The per-lane `DoQConnection` structure
// exists to bound parallelism, but it does NOT pool the underlying QUIC
// connection — `resolveCurrentQuery` builds a fresh `NWConnection` and
// `finishCurrentQuery` cancels it (see below).
//
// Why connection reuse is deferred rather than a straightforward port of the
// DoT-style pool: RFC 9250 maps each DNS query to its own QUIC stream (with
// FIN), so reuse is NOT a single reused `NWConnection` — it requires the
// multi-stream QUIC API, which is gated to iOS 26 while the app floor is iOS 17.
// An iOS-26-gated reuse path was built and device-tested against a real DoQ
// resolver and failed on every attempt (the stream send/receive errored, and the
// fallback was worse than this per-query path), matching the vendor guidance to
// hold off. It was reverted. The full rationale + the rejected-API list is
// recorded in PacketTunnelDNSRuntimeSourceTests (testDoQTransportUsesPublic-
// QUICConnectionWithoutCustomStack) — re-attempt reuse ONLY after a later iOS
// 26.x proves the QUIC stream API reliable, and update that pin deliberately
// (do not delete it to make a change pass).
//
// SCOPE / BLAST RADIUS (review 2026-07-05): real but NARROW — read this cost as
// per-DoQ-user, not an always-on population drain. DoQ ships in NO first-party
// preset and is never offered by `availableTransports` for a built-in resolver;
// it is reachable ONLY through a custom `doq://` resolver or a pasted DoQ stamp
// (an opt-in power-user path), and it sits BEHIND the response cache + in-flight
// coalescer, so the handshake lands only on non-coalesced cache MISSES. Net
// exposure ≈ (opt-in custom-resolver users) × (cache-miss queries) — a rounding
// error against the default population (Device DNS primary, DoH fallback). Even a
// working reuse path buys little at the battery-pack level, which is itself a
// reason not to re-attempt it speculatively.
//
// FRAMING OF THE DEFERRAL (review 2026-07-05): the real gate is API RELIABILITY,
// not the iOS-17 floor. The floor does not forbid an iOS-26-gated path (the app
// already ships one elsewhere), so this is "iOS-26+ gated once the platform is
// ready," NOT "blocked until we raise the floor." Re-attempt keys off the iOS-26
// QUIC stream API becoming reliable on a later 26.x (the built path was
// device-proven worse), not off the deployment target.
//
// NO CHEAPER iOS-17 MIDDLE PATH: QUIC 0-RTT / TLS 1.3 session resumption does NOT
// rescue this. It trims handshake round-trips, but the DOMINANT cost is the radio
// wake to send the query + its tail, paid regardless of handshake mode; and
// resumption needs a session ticket retained across connections, which
// `finishCurrentQuery` tears down every query (cross-connection reuse is the
// unreliable QUIC behavior the vendor guidance flagged). Treat it as not viable.
//
// What a future reuse path MUST preserve: per-query isolation, hostname-based
// connection start (SNI + certificate validation against `endpoint.hostname`),
// the timeout/cancel/failed-state handling in `handleConnectionState`, the
// idempotent `finishCurrentQuery`/`cancelLocked` completion semantics, and the
// smoke-probe timeout budgeting in PacketTunnelProvider that today sizes the
// probe window to include this per-probe connect cost.
/// Thread-safe DNS-over-QUIC client with bounded endpoint lanes; each query currently owns a fresh QUIC connection.
public final class DoQTransport: @unchecked Sendable {
    static let maxConnectionsPerEndpoint = 4
    private let timeoutSeconds: Int
    private let debugLogger: DNSTransportDebugLogger?
    /// See the test-only initialiser. Nil in every shipping construction.
    private let isolatedLaneObserver: (@Sendable (Int) -> Void)?
    private let connectionLock = NSLock()
    private var connections: [String: [DoQConnection]] = [:]
    private var nextConnectionIndexByKey: [String: Int] = [:]
    /// One-shot lanes handed out by ``resolveIsolated``, held ONLY so ``cancel`` can reach
    /// them. They are deliberately outside `connections` — an isolated lane must never be
    /// handed to a second query, which is the whole point of the isolated path — but being
    /// outside the pool previously meant being outside teardown too: `cancel` walked
    /// `connections` alone, so a smoke probe in flight at `stopTunnel` kept a live QUIC
    /// connection for up to `timeoutSeconds` past the tunnel that started it. Its handshake
    /// then completed under the NEXT session, where the QA energy counters had already been
    /// reset for a new measurement (see `EnergyCounters.activate`) — the same
    /// stale-lifecycle contamination PR #520 fixed for the chained-DNS evidence counters,
    /// arriving through the transport instead of through the recorder.
    ///
    /// Keyed by identity so the completion can retire exactly its own lane without an O(n)
    /// scan, and dropped on completion so a long-lived session cannot accumulate lanes.
    private var isolatedConnections: [ObjectIdentifier: DoQConnection] = [:]
    private var activeQueryCount = 0
    private var shouldResetWhenIdle = false
    /// Set by ``cancel`` (tunnel teardown), cleared by ``resume`` (tunnel start). While set,
    /// every entry point refuses rather than opening a connection.
    ///
    /// Cancelling alone did not close the stale-lifecycle door, because cancelling is not
    /// the same as staying down: `cancelLocked` completes each in-flight query with
    /// `.receiveFailed`, and `ResolverOrchestrator.resolveEndpoints` reads a nil response as
    /// "try the next endpoint". Stop cleanup does not drain in-flight resolver work, so that
    /// failover — and any query already inside the serving pipeline when the read loop's
    /// generation guard closed — re-entered `resolve` AFTER teardown, found `connections`
    /// empty, and built a brand-new pool. Teardown was creating the very connections it had
    /// just cancelled.
    private var isQuiesced = false

    /// Creates endpoint lanes whose connection-and-response timeout budget is measured in whole seconds.
    public init(timeoutSeconds: Int, debugLogger: DNSTransportDebugLogger? = nil) {
        self.timeoutSeconds = timeoutSeconds
        self.debugLogger = debugLogger
        self.isolatedLaneObserver = nil
    }

    /// Test-only overload carrying an observer of isolated-lane registration.
    ///
    /// A SEAM, and it exists because the property it observes cannot otherwise be observed
    /// without a race. `resolveIsolated` registers a lane and then hands the query to that
    /// lane's own queue; from outside, any read of ``laneBookkeeping`` is racing the lane's
    /// completion, which retires what is being counted. Earlier versions of the test used a
    /// well-formed query to an unroutable address on the theory that nothing could complete
    /// it — but an environment may report the route unreachable immediately, and then the
    /// assertion observes zero for a reason that has nothing to do with the code under test
    /// (Codex P2, PRs #522/#523).
    ///
    /// `internal`, defaulted absent on the public initialiser, and invoked while the
    /// registration is still current — so a test learns the count at the one instant it is
    /// unambiguous, and production carries a `nil` check on a path that already takes a lock.
    init(
        timeoutSeconds: Int,
        debugLogger: DNSTransportDebugLogger? = nil,
        isolatedLaneObserver: (@Sendable (Int) -> Void)?
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.debugLogger = debugLogger
        self.isolatedLaneObserver = isolatedLaneObserver
    }

    /// Atomically removes and cancels all shared DoQ lanes, including work currently queued on them.
    ///
    /// The MID-session reset (a resolver configuration change), so it deliberately does NOT
    /// quiesce and does NOT touch isolated lanes: the transport must keep serving, and an
    /// isolated probe already in flight belongs to the session that is still running — its
    /// counts land in that session's own window, which is the window they describe. Tunnel
    /// teardown is ``cancel``.
    public func resetConnections() {
        let connectionsToCancel: [DoQConnection]
        connectionLock.lock()
        connectionsToCancel = connections.values.flatMap { $0 }
        connections = [:]
        nextConnectionIndexByKey = [:]
        shouldResetWhenIdle = false
        connectionLock.unlock()
        connectionsToCancel.forEach { $0.cancel() }
    }

    /// Defers shared-lane cancellation until active queries finish, or resets immediately when idle.
    public func resetConnectionsWhenIdle() {
        let connectionsToCancel: [DoQConnection]?
        connectionLock.lock()
        // Nothing to arm while quiesced, and arming would OUTLIVE the teardown: this is
        // reached from the failure path of every DoQ query, including the stragglers whose
        // completions `cancel` itself fires. `shouldResetWhenIdle` is transport state, not
        // per-session state, so a straggler arming it after `cancel` cleared it would carry
        // the flag into the next tunnel session and tear down THAT session's freshly built
        // pool at its first idle moment — charging the new session an extra QUIC handshake
        // (and an extra radio wake) that the previous session caused.
        guard !isQuiesced else {
            connectionLock.unlock()
            return
        }
        shouldResetWhenIdle = true
        if activeQueryCount == 0 {
            connectionsToCancel = connections.values.flatMap { $0 }
            connections = [:]
            nextConnectionIndexByKey = [:]
            shouldResetWhenIdle = false
        } else {
            connectionsToCancel = nil
        }
        connectionLock.unlock()
        connectionsToCancel?.forEach { $0.cancel() }
    }

    /// Cancels every lane — shared and isolated — during tunnel shutdown and refuses further
    /// work until ``resume``.
    ///
    /// The pairing with ``resume`` scopes DoQ work to a tunnel LIFECYCLE rather than to a
    /// process: `cancel` is called once from the provider's stop cleanup and `resume` once
    /// from its per-lifecycle resolver reset. That is deliberately stronger than suppressing
    /// the stale handshake at the QA counter would have been: the straggler's radio wake is
    /// real energy, so a counter taught to ignore it would have read zero while the next A/B
    /// battery cell still paid for it. Removing the work removes both the wake and the
    /// miscount.
    ///
    /// WHAT THIS DOES NOT YET CLOSE, stated because the obvious reading of the above is
    /// stronger than the truth: `isQuiesced` is a WINDOW, not a generation. `cancel` only
    /// ENQUEUES each lane's cancellation, and the stop path does not await those queues — so
    /// a stop/start that completes first leaves `resume` unable to tell the previous
    /// lifecycle's late completion from the new session's own work. That completion reports
    /// `.receiveFailed`, `ResolverOrchestrator.resolveEndpoints` advances to the next
    /// endpoint, and the stale attempt opens a lane in the NEW session (Codex P1, PR #522).
    /// Narrower than the door this closes — it needs a lane queue delayed past the next
    /// resume — but the same defect. The fix is generation-tagged admission threaded from
    /// `resolveUpstream`, which also covers DoH; it is its own slice, not a rider here.
    ///
    /// Distinct from ``resetConnections``, which is the MID-session reset (a resolver
    /// configuration change) and must leave the transport serving.
    public func cancel() {
        let connectionsToCancel: [DoQConnection]
        connectionLock.lock()
        isQuiesced = true
        connectionsToCancel = connections.values.flatMap { $0 } + Array(isolatedConnections.values)
        connections = [:]
        nextConnectionIndexByKey = [:]
        isolatedConnections = [:]
        shouldResetWhenIdle = false
        connectionLock.unlock()
        connectionsToCancel.forEach { $0.cancel() }
    }

    /// Re-admits work after a ``cancel``, for the tunnel lifecycle now starting.
    public func resume() {
        connectionLock.lock()
        isQuiesced = false
        connectionLock.unlock()
    }

    /// Queues a query on a bounded endpoint lane and asynchronously returns one classified transport response.
    public func resolve(
        _ query: Data,
        endpoint: DNSOverQUICEndpoint,
        isStillAdmitted: @escaping @Sendable () -> Bool = { true },
        deadline: MonotonicDeadline? = nil,
        completion: @escaping @Sendable (DNSTransportResponse) -> Void
    ) {
        // The quiesce check, the active-query accounting and the lane hand-out share ONE
        // critical section on purpose. Split across sections — as the `beginQuery()` +
        // `connection(for:)` pair this replaces was — a `cancel` landing in the gap would be
        // followed by `connectionPoolLocked` finding `connections` empty and rebuilding the
        // pool, which is precisely the lane that must not exist after teardown.
        let connection: DoQConnection
        connectionLock.lock()
        guard !isQuiesced else {
            connectionLock.unlock()
            completion(Self.refusedResponse)
            return
        }
        activeQueryCount += 1
        connection = pooledConnectionLocked(for: endpoint)
        connectionLock.unlock()

        connection.resolve(query, isStillAdmitted: isStillAdmitted, deadline: deadline) { [weak self] upstreamResponse in
            self?.finishQuery()
            completion(upstreamResponse)
        }
    }

    /// Resolves through a one-shot lane outside the shared pool and cancels that lane after completion.
    public func resolveIsolated(
        _ query: Data,
        endpoint: DNSOverQUICEndpoint,
        isStillAdmitted: @escaping @Sendable () -> Bool = { true },
        deadline: MonotonicDeadline? = nil,
        completion: @escaping @Sendable (DNSTransportResponse) -> Void
    ) {
        let connection: DoQConnection
        connectionLock.lock()
        guard !isQuiesced else {
            connectionLock.unlock()
            completion(Self.refusedResponse)
            return
        }
        // Built and registered under the same lock the refusal is read under, so a `cancel`
        // cannot slip between the admission and the registration and leave an untracked
        // connection behind — the exact lane this registry exists to reach.
        connection = DoQConnection(endpoint: endpoint, timeoutSeconds: timeoutSeconds, debugLogger: debugLogger)
        isolatedConnections[ObjectIdentifier(connection)] = connection
        let registeredLaneCount = isolatedConnections.count
        connectionLock.unlock()
        // Reported BEFORE the query is handed to the lane's queue, which is the only instant
        // the count is unambiguous — see the test-only initialiser.
        isolatedLaneObserver?(registeredLaneCount)

        connection.resolve(query, isStillAdmitted: isStillAdmitted, deadline: deadline) { [weak self, connection] upstreamResponse in
            self?.forgetIsolatedConnection(connection)
            connection.cancel()
            completion(upstreamResponse)
        }
    }

    /// A refusal wears the same outcome an externally cancelled lane completes with, because
    /// it is the same event one moment earlier: the tunnel is gone. `resolveEndpoints` reads
    /// the nil response as a failed attempt and walks on, which while quiesced simply means
    /// every remaining endpoint is refused too — no partial resolution, and no wire contact.
    private static let refusedResponse = DNSTransportResponse(response: nil, outcome: .receiveFailed)

    /// The lane bookkeeping ``cancel`` and ``resume`` are responsible for.
    ///
    /// A read-only SNAPSHOT taken under the transport's own lock, and `internal` rather than
    /// `public`: the packet tunnel never reads this, so the storage keeps its private,
    /// lock-confined contract instead of the module gaining four mutable vars. It exists
    /// because the states that matter here — a refusal that opened no connection, a
    /// registry the teardown emptied, an idle-reset flag that must not survive a session —
    /// are otherwise indistinguishable from outside without contacting a real resolver.
    struct LaneBookkeeping: Equatable {
        var isQuiesced: Bool
        var isolatedLaneCount: Int
        var pooledEndpointCount: Int
        var idleResetIsArmed: Bool
    }

    var laneBookkeeping: LaneBookkeeping {
        connectionLock.lock()
        defer {
            connectionLock.unlock()
        }
        return LaneBookkeeping(
            isQuiesced: isQuiesced,
            isolatedLaneCount: isolatedConnections.count,
            pooledEndpointCount: connections.count,
            idleResetIsArmed: shouldResetWhenIdle
        )
    }

    private func forgetIsolatedConnection(_ connection: DoQConnection) {
        connectionLock.lock()
        isolatedConnections.removeValue(forKey: ObjectIdentifier(connection))
        connectionLock.unlock()
    }

    private func pooledConnectionLocked(for endpoint: DNSOverQUICEndpoint) -> DoQConnection {
        let key = endpoint.cacheIdentifier
        let pool = connectionPoolLocked(for: endpoint)
        let index = nextConnectionIndexByKey[key, default: 0] % pool.count
        nextConnectionIndexByKey[key] = (index + 1) % pool.count
        return pool[index]
    }

    private func connectionPoolLocked(for endpoint: DNSOverQUICEndpoint) -> [DoQConnection] {
        let key = endpoint.cacheIdentifier
        if let pool = connections[key], !pool.isEmpty {
            return pool
        }

        let pool = (0..<Self.maxConnectionsPerEndpoint).map { _ in
            DoQConnection(endpoint: endpoint, timeoutSeconds: timeoutSeconds, debugLogger: debugLogger)
        }
        connections[key] = pool
        nextConnectionIndexByKey[key] = 0
        return pool
    }

    private func finishQuery() {
        let connectionsToCancel: [DoQConnection]?
        connectionLock.lock()
        activeQueryCount = max(0, activeQueryCount - 1)
        if activeQueryCount == 0 && shouldResetWhenIdle {
            connectionsToCancel = connections.values.flatMap { $0 }
            connections = [:]
            nextConnectionIndexByKey = [:]
            shouldResetWhenIdle = false
        } else {
            connectionsToCancel = nil
        }
        connectionLock.unlock()
        connectionsToCancel?.forEach { $0.cancel() }
    }
}

final class DoQConnection: @unchecked Sendable {
    private struct PendingQuery {
        let query: Data
        let completion: @Sendable (DNSTransportResponse) -> Void
        /// Whether the work that admitted this query is still the live one, asked again at the
        /// SEND. See the identical field on `DoTConnection.PendingQuery` — this lane queues the
        /// same way, behind another query and behind a QUIC handshake (PR #611).
        let isStillAdmitted: @Sendable () -> Bool
        let deadline: MonotonicDeadline
    }

    private let endpoint: DNSOverQUICEndpoint
    private let timeoutSeconds: Int
    private let debugLogger: DNSTransportDebugLogger?
    private let queue: DispatchQueue
    private var pendingQueries: [PendingQuery] = []
    private var currentQuery: PendingQuery?
    private var currentConnection: NWConnection?
    private var currentTimeout: DispatchWorkItem?
    private var currentQueryWasSent = false
    private var currentConnectionStartedAtMonotonicTime: TimeInterval?
    private var isCancelled = false

    init(endpoint: DNSOverQUICEndpoint, timeoutSeconds: Int, debugLogger: DNSTransportDebugLogger? = nil) {
        self.endpoint = endpoint
        self.timeoutSeconds = timeoutSeconds
        self.debugLogger = debugLogger
        self.queue = DispatchQueue(
            label: "com.lavasec.tunnel.resolver.doq.\(endpoint.cacheIdentifier)",
            qos: .utility
        )
    }

    func resolve(
        _ query: Data,
        isStillAdmitted: @escaping @Sendable () -> Bool = { true },
        deadline: MonotonicDeadline? = nil,
        completion: @escaping @Sendable (DNSTransportResponse) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                completion(DNSTransportResponse(response: nil, outcome: .receiveFailed))
                return
            }

            guard !isCancelled else {
                completion(DNSTransportResponse(response: nil, outcome: .receiveFailed))
                return
            }

            pendingQueries.append(
                PendingQuery(
                    query: query, completion: completion, isStillAdmitted: isStillAdmitted,
                    deadline: deadline ?? MonotonicDeadline(after: TimeInterval(max(0, self.timeoutSeconds)))))
            startNextQueryIfNeeded()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.cancelLocked()
        }
    }

    private func startNextQueryIfNeeded() {
        guard currentQuery == nil else {
            return
        }

        guard !pendingQueries.isEmpty else {
            return
        }

        currentQuery = pendingQueries.removeFirst()
        resolveCurrentQuery()
    }

    private func resolveCurrentQuery() {
        guard let currentQuery else {
            return
        }

        // AT THE DEQUEUE, and again after the QUIC handshake reports ready. Same reasoning as the
        // DoT lane: the wait behind another query and the wait for the connection are separate
        // windows, and only the first is reachable without a connection ever existing (PR #611).
        guard !currentQuery.deadline.hasExpired() else {
            finishCurrentQuery(DNSTransportResponse(response: nil, outcome: .expiredBeforeSend))
            return
        }
        guard currentQuery.isStillAdmitted() else {
            finishCurrentQuery(
                DNSTransportResponse(response: nil, outcome: .refusedAfterLatchReplaced))
            return
        }

        guard DNSWireMessage.transactionID(in: currentQuery.query) != nil else {
            finishCurrentQuery(DNSTransportResponse(response: nil, outcome: .receiveFailed))
            return
        }

        let zeroIDQuery = DNSWireMessage.clearingTransactionID(in: currentQuery.query)
        guard let framedQuery = DNSLengthPrefixedWireMessage.framedQuery(zeroIDQuery),
              let port = NWEndpoint.Port(rawValue: endpoint.port)
        else {
            finishCurrentQuery(DNSTransportResponse(response: nil, outcome: .sendFailed))
            return
        }

        let parameters = NWParameters.quic(alpn: ["doq"])
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.hostname), port: port, using: parameters)
        currentConnection = connection
        currentQueryWasSent = false

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else {
                return
            }
            self?.handleConnectionState(
                state,
                for: connection,
                framedQuery: framedQuery,
                originalQuery: currentQuery.query,
                zeroIDQuery: zeroIDQuery
            )
        }

        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else {
                return
            }
            self.queue.async {
                guard self.currentConnection === connection else {
                    return
                }
                self.finishCurrentQuery(DNSTransportResponse(response: nil, outcome: .timeout))
            }
        }
        currentTimeout = timeout
        let remaining = min(TimeInterval(timeoutSeconds), currentQuery.deadline.remainingSeconds())
        queue.asyncAfter(deadline: .now() + remaining, execute: timeout)

        currentConnectionStartedAtMonotonicTime = debugLogger == nil ? nil : ProcessInfo.processInfo.systemUptime
        connection.start(queue: queue)
    }

    private func sendCurrentQuery(
        connection: NWConnection,
        framedQuery: Data,
        originalQuery: Data,
        zeroIDQuery: Data
    ) {
        connection.send(
            content: framedQuery,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection else {
                    return
                }
                self.queue.async {
                    guard self.currentConnection === connection else {
                        return
                    }

                    if let error {
                        self.logConnectionError(error, phase: "send")
                        self.finishCurrentQuery(DNSTransportResponse(response: nil, outcome: .sendFailed))
                        return
                    }

                    self.receiveResponseLength(
                        connection: connection,
                        originalQuery: originalQuery,
                        zeroIDQuery: zeroIDQuery,
                        accumulated: Data()
                    )
                }
            }
        )
    }

    private func handleConnectionState(
        _ state: NWConnection.State,
        for connection: NWConnection,
        framedQuery: Data,
        originalQuery: Data,
        zeroIDQuery: Data
    ) {
        guard currentConnection === connection else {
            return
        }

        switch state {
        case .ready:
            if let debugLogger {
                let metadata = connection.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
                // Fresh QUIC handshake cost: DoQ opens a connection per query
                // today, so this is paid on every query until reuse lands.
                var details: [String: String] = [
                    "endpoint": endpoint.displayAddress,
                    "negotiatedALPN": metadata?.negotiatedALPN ?? "nil"
                ]
                if let startedAt = currentConnectionStartedAtMonotonicTime {
                    let handshakeMilliseconds = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
                    details["handshakeMs"] = "\(Int(handshakeMilliseconds.rounded()))"
                }
                debugLogger("dns-doq-connection-ready", details)
            }
            currentConnectionStartedAtMonotonicTime = nil
            guard !currentQueryWasSent else {
                return
            }
            // THE SEND SEAM. Same reasoning as the DoT lane: the wait behind another query and the
            // QUIC handshake above can take seconds, and every gate before them has already
            // passed, so this is the last point a data path replaced in that window can stop the
            // query reaching a resolver the user has stopped choosing (PR #611).
            if currentQuery?.deadline.hasExpired() == true {
                finishCurrentQuery(DNSTransportResponse(response: nil, outcome: .expiredBeforeSend))
                return
            }
            guard currentQuery?.isStillAdmitted() ?? true else {
                finishCurrentQuery(
                    DNSTransportResponse(response: nil, outcome: .refusedAfterLatchReplaced))
                return
            }
            currentQueryWasSent = true
            sendCurrentQuery(
                connection: connection,
                framedQuery: framedQuery,
                originalQuery: originalQuery,
                zeroIDQuery: zeroIDQuery
            )

        case .waiting(let error):
            logConnectionError(error, phase: "waiting")

        case .failed(let error):
            logConnectionError(error, phase: "failed")
            finishCurrentQuery(DNSTransportResponse(response: nil, outcome: .receiveFailed))

        case .cancelled:
            // An externally cancelled live connection (resetConnections, sleep) must
            // fail the in-flight query immediately rather than wait out the query
            // timeout, mirroring DoT. finishCurrentQuery is idempotent and the guard
            // above drops the self-cancel it triggers, so this can't double-complete.
            finishCurrentQuery(DNSTransportResponse(response: nil, outcome: .receiveFailed))

        default:
            break
        }
    }

    private func receiveResponseLength(
        connection: NWConnection,
        originalQuery: Data,
        zeroIDQuery: Data,
        accumulated: Data
    ) {
        let remainingByteCount = 2 - accumulated.count
        guard remainingByteCount > 0 else {
            guard let responseLength = DNSLengthPrefixedWireMessage.responseBodyLength(fromPrefix: accumulated) else {
                finishCurrentQuery(DNSTransportResponse(response: nil, outcome: .receiveFailed))
                return
            }

            receiveResponseBody(
                connection: connection,
                originalQuery: originalQuery,
                zeroIDQuery: zeroIDQuery,
                expectedLength: responseLength,
                accumulated: Data()
            )
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: remainingByteCount) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else {
                return
            }
            self.queue.async {
                guard self.currentConnection === connection else {
                    return
                }

                if let error {
                    self.logConnectionError(error, phase: "receive-length")
                }

                switch DNSLengthPrefixedWireMessage.receiveStep(
                    accumulated: accumulated,
                    incoming: data,
                    hadReceiveError: error != nil,
                    isComplete: isComplete,
                    targetByteCount: 2,
                    failsOnEmptyChunk: false
                ) {
                case .failed:
                    // Includes a stream that FINishes short of the prefix: re-receiving
                    // on a finished stream spins until the query timeout, so fail fast
                    // (mirrors DoT's truncation handling).
                    self.finishCurrentQuery(DNSTransportResponse(response: nil, outcome: .receiveFailed))
                case .frameComplete(let next), .continueReceiving(accumulated: let next):
                    // Both re-enter through the entry guard, which parses the prefix
                    // once the 2 bytes are accumulated.
                    self.receiveResponseLength(
                        connection: connection,
                        originalQuery: originalQuery,
                        zeroIDQuery: zeroIDQuery,
                        accumulated: next
                    )
                }
            }
        }
    }

    private func receiveResponseBody(
        connection: NWConnection,
        originalQuery: Data,
        zeroIDQuery: Data,
        expectedLength: Int,
        accumulated: Data
    ) {
        let remainingByteCount = expectedLength - accumulated.count
        guard remainingByteCount > 0 else {
            guard DNSWireMessage.isValidResponse(accumulated, matching: zeroIDQuery) else {
                finishCurrentQuery(DNSTransportResponse(response: nil, outcome: .mismatchedResponse))
                return
            }

            finishCurrentQuery(DNSTransportResponse(
                response: DNSWireMessage.replacingTransactionID(in: accumulated, from: originalQuery),
                outcome: .success
            ))
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: remainingByteCount) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else {
                return
            }
            self.queue.async {
                guard self.currentConnection === connection else {
                    return
                }

                if let error {
                    self.logConnectionError(error, phase: "receive-body")
                }

                switch DNSLengthPrefixedWireMessage.receiveStep(
                    accumulated: accumulated,
                    incoming: data,
                    hadReceiveError: error != nil,
                    isComplete: isComplete,
                    targetByteCount: expectedLength,
                    failsOnEmptyChunk: false
                ) {
                case .failed:
                    // Includes a truncated body (stream FIN before expectedLength):
                    // fail fast instead of re-receiving until the query timeout.
                    self.finishCurrentQuery(DNSTransportResponse(response: nil, outcome: .receiveFailed))
                case .frameComplete(let next), .continueReceiving(accumulated: let next):
                    // Both re-enter through the entry guard, which validates the body
                    // once expectedLength is accumulated.
                    self.receiveResponseBody(
                        connection: connection,
                        originalQuery: originalQuery,
                        zeroIDQuery: zeroIDQuery,
                        expectedLength: expectedLength,
                        accumulated: next
                    )
                }
            }
        }
    }

    private func finishCurrentQuery(_ response: DNSTransportResponse) {
        currentTimeout?.cancel()
        currentTimeout = nil
        currentConnection?.cancel()
        currentConnection = nil
        currentQueryWasSent = false
        let completion = currentQuery?.completion
        currentQuery = nil
        completion?(response)
        startNextQueryIfNeeded()
    }

    private func cancelLocked() {
        isCancelled = true
        currentTimeout?.cancel()
        currentTimeout = nil
        currentConnection?.cancel()
        currentConnection = nil
        currentQueryWasSent = false
        let activeCompletion = currentQuery?.completion
        let queuedCompletions = pendingQueries.map(\.completion)
        currentQuery = nil
        pendingQueries = []

        let failure = DNSTransportResponse(response: nil, outcome: .receiveFailed)
        activeCompletion?(failure)
        queuedCompletions.forEach { $0(failure) }
    }

    private func logConnectionError(_ error: NWError, phase: String) {
        debugLogger?("dns-doq-connection-error", [
            "endpoint": endpoint.displayAddress,
            "phase": phase,
            "error": String(describing: error)
        ])
    }
}
