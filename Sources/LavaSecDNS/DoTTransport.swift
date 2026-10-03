import Foundation
import LavaSecKit
import Network

// DNS-over-TLS execution, extracted from PacketTunnelProvider. Pools
// connections per endpoint (round-robin, bounded) so parallel queries avoid
// head-of-line blocking, and carries the idle-staleness handling: providers
// like Cloudflare close idle DoT connections server-side without surfacing a
// state change on the pooled NWConnection, so reused connections are refreshed
// after an idle window and a timeout on a reused connection earns exactly one
// fresh-connection retry.
/// Thread-safe DNS-over-TLS client with bounded per-endpoint connection pools and stale-connection recovery.
public final class DoTTransport: @unchecked Sendable {
    static let maxConnectionsPerEndpoint = 4
    private let timeoutSeconds: Int
    private let debugLogger: DNSTransportDebugLogger?
    /// See the test-only initialiser. Nil in every shipping construction.
    private let isolatedLaneObserver: (@Sendable (Int) -> Void)?
    private let connectionLock = NSLock()
    private var connections: [String: [DoTConnection]] = [:]
    private var nextConnectionIndexByKey: [String: Int] = [:]
    /// One-shot lanes handed out by ``resolveIsolated``, held ONLY so ``cancel`` can reach
    /// them. Outside `connections` deliberately — an isolated lane must never be handed to a
    /// second query — but being outside the pool also meant being outside teardown: `cancel`
    /// walked `connections` alone, so a smoke probe in flight at `stopTunnel` kept a live TLS
    /// connection and its socket for up to `timeoutSeconds` past the tunnel that started it.
    ///
    /// Identical in shape to `DoQTransport`'s registry and fixed for the same reason, with one
    /// difference in what it costs: no energy counter reads the DoT callback, so this is a
    /// resource straggler rather than a corrupted measurement. What it shares is the teardown
    /// bug in ``cancel`` — see ``isQuiesced``.
    private var isolatedConnections: [ObjectIdentifier: DoTConnection] = [:]
    private var activeQueryCount = 0
    private var shouldResetWhenIdle = false
    /// Set by ``cancel`` (tunnel teardown), cleared by ``resume`` (tunnel start). While set,
    /// every entry point refuses rather than opening a connection.
    ///
    /// Cancelling alone did not keep the transport down: `cancelLocked` completes each
    /// in-flight query with `.receiveFailed`, `ResolverOrchestrator.resolveEndpoints` reads a
    /// nil response as "try the next endpoint", and stop cleanup does not drain in-flight
    /// resolver work — so that failover, and any query still inside the serving pipeline,
    /// re-entered `resolve` after teardown, found `connections` empty and built a fresh pool.
    /// Teardown was creating the connections it had just cancelled.
    ///
    /// The pooled case matters more here than it does for DoQ: DoT lanes are REUSED across
    /// queries rather than opened per query, so a pool rebuilt by a straggler outlives the
    /// rebuild — `startTunnel`'s own `resetConnections` runs early enough that a straggler can
    /// re-create the pool after it, leaving the next session serving from connections the
    /// previous session's dying work opened.
    private var isQuiesced = false

    /// Creates connection pools whose per-query timeout budget is measured in whole seconds.
    public init(timeoutSeconds: Int, debugLogger: DNSTransportDebugLogger? = nil) {
        self.timeoutSeconds = timeoutSeconds
        self.debugLogger = debugLogger
        self.isolatedLaneObserver = nil
    }

    /// Test-only overload carrying an observer of isolated-lane registration.
    ///
    /// The DoQ sibling's seam, for the same reason: `resolveIsolated` registers a lane and
    /// then hands the query to that lane's own queue, so any read of ``laneBookkeeping`` from
    /// outside races the completion that retires what is being counted. A well-formed query
    /// to an unroutable address only *usually* stays in flight — an environment can report
    /// the route unreachable immediately (Codex P2, PR #523). Invoked while the registration
    /// is still current, so a test learns the count at the one unambiguous instant.
    init(
        timeoutSeconds: Int,
        debugLogger: DNSTransportDebugLogger? = nil,
        isolatedLaneObserver: (@Sendable (Int) -> Void)?
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.debugLogger = debugLogger
        self.isolatedLaneObserver = isolatedLaneObserver
    }

    /// Atomically removes and cancels every pooled TLS connection, including lanes serving active queries.
    ///
    /// The MID-session reset (a resolver configuration change), so it deliberately does NOT
    /// quiesce and does NOT touch isolated lanes: the transport must keep serving, and an
    /// isolated probe already in flight belongs to the session that is still running. Tunnel
    /// teardown is ``cancel``.
    public func resetConnections() {
        let connectionsToCancel: [DoTConnection]
        connectionLock.lock()
        connectionsToCancel = connections.values.flatMap { $0 }
        connections = [:]
        nextConnectionIndexByKey = [:]
        shouldResetWhenIdle = false
        connectionLock.unlock()
        connectionsToCancel.forEach { $0.cancel() }
    }

    /// Defers pool cancellation until active queries finish, while resetting immediately when no query is active.
    public func resetConnectionsWhenIdle() {
        let connectionsToCancel: [DoTConnection]?
        connectionLock.lock()
        // Nothing to arm while quiesced, and arming would OUTLIVE the teardown: this is
        // reached from the failure path of every DoT query, including the stragglers whose
        // completions `cancel` itself fires. `shouldResetWhenIdle` is transport state, not
        // per-session state, so a straggler arming it after `cancel` cleared it would carry
        // the flag into the next tunnel session and tear down THAT session's pool at its
        // first idle moment — costing it a TLS handshake the previous session caused.
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

    /// Cancels every lane — pooled and isolated — during tunnel shutdown and refuses further
    /// work until ``resume``.
    ///
    /// The pairing with ``resume`` scopes DoT work to a tunnel LIFECYCLE rather than to a
    /// process: `cancel` is called once from the provider's stop cleanup and `resume` once
    /// from its per-lifecycle resolver reset.
    ///
    /// WHAT THIS DOES NOT YET CLOSE, the same residual as the DoQ sibling and stated for the
    /// same reason: `isQuiesced` is a WINDOW, not a generation. `cancel` only ENQUEUES each
    /// lane's cancellation and the stop path does not await those queues, so a stop/start
    /// completing first leaves `resume` unable to tell the previous lifecycle's late
    /// completion from the new session's own work — that completion reports `.receiveFailed`,
    /// `ResolverOrchestrator.resolveEndpoints` advances to the next endpoint, and the stale
    /// attempt builds a pool in the NEW session (Codex P1, PRs #522/#523). Generation-tagged
    /// admission threaded from `resolveUpstream` is the fix, and covers DoH too; its own slice.
    ///
    /// Distinct from ``resetConnections``, the MID-session reset, which must leave the
    /// transport serving.
    public func cancel() {
        let connectionsToCancel: [DoTConnection]
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

    /// Resolves through a pooled endpoint lane and asynchronously returns one classified transport response.
    public func resolve(
        _ query: Data,
        endpoint: DNSOverTLSEndpoint,
        isStillAdmitted: @escaping @Sendable () -> Bool = { true },
        deadline: MonotonicDeadline? = nil,
        completion: @escaping @Sendable (DNSTransportResponse) -> Void
    ) {
        // The quiesce check, the active-query accounting and the lane hand-out share ONE
        // critical section on purpose. Split across sections — as the `beginQuery()` +
        // `connection(for:)` pair this replaces was — a `cancel` landing in the gap would be
        // followed by `connectionPoolLocked` rebuilding the pool teardown had just emptied.
        let connection: DoTConnection
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

    /// Resolves on a fresh one-shot connection that is cancelled after completion and never enters the shared pool.
    public func resolveIsolated(
        _ query: Data,
        endpoint: DNSOverTLSEndpoint,
        isStillAdmitted: @escaping @Sendable () -> Bool = { true },
        deadline: MonotonicDeadline? = nil,
        completion: @escaping @Sendable (DNSTransportResponse) -> Void
    ) {
        let connection: DoTConnection
        connectionLock.lock()
        guard !isQuiesced else {
            connectionLock.unlock()
            completion(Self.refusedResponse)
            return
        }
        // Built and registered under the same lock the refusal is read under, so a `cancel`
        // cannot slip between the admission and the registration and leave an untracked
        // connection behind — the exact lane this registry exists to reach.
        connection = DoTConnection(endpoint: endpoint, timeoutSeconds: timeoutSeconds, debugLogger: debugLogger)
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
    /// the nil response as a failed attempt and walks on, which while quiesced means every
    /// remaining endpoint is refused too — no partial resolution, and no wire contact.
    private static let refusedResponse = DNSTransportResponse(response: nil, outcome: .receiveFailed)

    /// The lane bookkeeping ``cancel`` and ``resume`` are responsible for — a read-only
    /// snapshot under the transport's own lock, `internal` so the storage keeps its private,
    /// lock-confined contract. See `DoQTransport.LaneBookkeeping` for why the states it
    /// exposes cannot otherwise be observed without contacting a real resolver.
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

    private func forgetIsolatedConnection(_ connection: DoTConnection) {
        connectionLock.lock()
        isolatedConnections.removeValue(forKey: ObjectIdentifier(connection))
        connectionLock.unlock()
    }

    private func pooledConnectionLocked(for endpoint: DNSOverTLSEndpoint) -> DoTConnection {
        let key = endpoint.cacheIdentifier
        let pool = connectionPoolLocked(for: endpoint)
        let index = nextConnectionIndexByKey[key, default: 0] % pool.count
        nextConnectionIndexByKey[key] = (index + 1) % pool.count
        return pool[index]
    }

    private func connectionPoolLocked(for endpoint: DNSOverTLSEndpoint) -> [DoTConnection] {
        let key = endpoint.cacheIdentifier
        if let pool = connections[key], !pool.isEmpty {
            return pool
        }

        let pool = (0..<Self.maxConnectionsPerEndpoint).map { _ in
            DoTConnection(endpoint: endpoint, timeoutSeconds: timeoutSeconds, debugLogger: debugLogger)
        }
        connections[key] = pool
        nextConnectionIndexByKey[key] = 0
        return pool
    }

    private func finishQuery() {
        let connectionsToCancel: [DoTConnection]?
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

final class DoTConnection: @unchecked Sendable {
    private struct PendingQuery {
        let query: Data
        let completion: @Sendable (DNSTransportResponse) -> Void
        /// Whether the work that admitted this query is still the live one, asked again at the
        /// SEND rather than trusted from when it was enqueued.
        ///
        /// This lane queues: a query waits behind another query and behind a handshake, so
        /// seconds separate the caller handing it over from the bytes leaving. Every gate above
        /// has already passed by then, so this is the last place a data path replaced in that
        /// window can still stop the query (PR #611). Defaults to always-admitted, which is every
        /// caller that carries no such token.
        let isStillAdmitted: @Sendable () -> Bool
        let deadline: MonotonicDeadline
        var connectionAttemptCount = 0
    }

    private let hostname: String
    private let port: UInt16
    private let bootstrapAddresses: [String]
    private let timeoutSeconds: Int
    private let debugLogger: DNSTransportDebugLogger?
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var connectionIsReady = false
    private var isConnecting = false
    private var connectionGeneration = 0
    private var nextBootstrapAddressIndex = 0
    private var readyCompletions: [@Sendable (Bool) -> Void] = []
    private var pendingQueries: [PendingQuery] = []
    private var currentQuery: PendingQuery?
    private var currentTimeout: DispatchWorkItem?
    private var lastConnectionActivityAt = Date.distantPast
    private var currentAttemptReusedConnection = false
    private var connectionStartedAtMonotonicTime: TimeInterval?
    /// Refuses work that arrives after this lane was cancelled, rather than reconnecting.
    ///
    /// The transport's quiesce closes the front door but not this one: `resolve` releases the
    /// transport lock before calling into the lane, so a `cancel` landing in that gap enqueues
    /// `cancelLocked` AHEAD of the query's own append — and without this flag the append then
    /// ran `startNextQueryIfNeeded` and opened a FRESH TLS connection, after teardown, on a
    /// lane teardown had just cancelled. `DoQConnection` has always had this guard; DoT did
    /// not, which is the one place the two transports' teardown genuinely differed.
    ///
    /// Scoped to `cancelLocked` alone. The idle-staleness refresh and the retry ladder go
    /// through `resetConnectionLocked`, which does not set this — a lane that reconnects
    /// because its server closed it idle is not a lane anyone cancelled.
    private var isCancelled = false

    // Cloudflare closes idle DoT connections after ~10s without surfacing a
    // state change on the pooled NWConnection; a query sent on such a zombie
    // rides into a full timeout. Refresh reused connections idle longer than
    // this instead of trusting them.
    private static let reusedConnectionMaxIdleInterval: TimeInterval = 8

    init(endpoint: DNSOverTLSEndpoint, timeoutSeconds: Int, debugLogger: DNSTransportDebugLogger? = nil) {
        self.hostname = endpoint.hostname
        self.port = endpoint.port
        self.bootstrapAddresses = endpoint.allBootstrapServers.isEmpty
            ? [endpoint.hostname]
            : endpoint.allBootstrapServers
        self.timeoutSeconds = timeoutSeconds
        self.debugLogger = debugLogger
        self.queue = DispatchQueue(
            label: "com.lavasec.tunnel.resolver.dot.\(endpoint.cacheIdentifier)",
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
        connectThenSendCurrentQuery()
    }

    private func connectThenSendCurrentQuery() {
        guard let currentQuery else {
            return
        }

        // AT THE DEQUEUE, and again after the handshake below. This lane serialises, so a query
        // can sit behind another one for that query's whole timeout before reaching here — and
        // then wait again for the connection. Both waits are windows in which the data path that
        // admitted it can be replaced, and they are separate: the first is survivable without a
        // connection ever existing, which is also what makes it testable (PR #611).
        guard !currentQuery.deadline.hasExpired() else {
            finishCurrentQuery(DNSTransportResponse(response: nil, outcome: .expiredBeforeSend), resetsConnection: false)
            return
        }
        guard currentQuery.isStillAdmitted() else {
            finishCurrentQuery(
                DNSTransportResponse(response: nil, outcome: .refusedAfterLatchReplaced),
                resetsConnection: false)
            return
        }

        guard DNSWireMessage.transactionID(in: currentQuery.query) != nil else {
            finishCurrentQuery(
                DNSTransportResponse(response: nil, outcome: .receiveFailed),
                resetsConnection: false
            )
            return
        }

        if connectionIsReady, connection != nil,
           Date().timeIntervalSince(lastConnectionActivityAt) > Self.reusedConnectionMaxIdleInterval {
            // Likely closed server-side while idle: reconnect (~tens of ms)
            // instead of riding it into a multi-second timeout.
            resetConnectionLocked(advanceBootstrapAddress: false)
        }
        currentAttemptReusedConnection = connectionIsReady && connection != nil

        ensureConnectionReady { [weak self] isReady in
            guard let self else {
                return
            }

            guard isReady else {
                failOrRetryCurrentQuery(outcome: .receiveFailed, resetsConnection: true)
                return
            }

            // THE SEND SEAM, and the reason the predicate is asked here rather than trusted from
            // when the query was enqueued: everything above this line can take seconds — the wait
            // behind another query on this lane, and the TLS handshake itself. A data path
            // replaced in that window leaves this query addressed to a resolver the user has
            // stopped choosing, and every earlier gate has already passed (PR #611).
            //
            // NOT `resetsConnection`: the connection is fine and other queries on this lane may
            // be perfectly current. Only this query is stale.
            //
            // `self.currentQuery`, QUALIFIED. The enclosing function opens with
            // `guard let currentQuery else { return }`, so the bare name here is that shadowed
            // NON-optional local — captured before the handshake. The property is what
            // `sendCurrentQuery` will actually read, and it can have been finished and cleared
            // while the handshake ran, so the property is the one to ask. (The DoQ lane writes
            // the same check unqualified because `handleConnectionState` shadows nothing; the two
            // differ for that reason, not by accident.)
            if self.currentQuery?.deadline.hasExpired() == true {
                finishCurrentQuery(DNSTransportResponse(response: nil, outcome: .expiredBeforeSend), resetsConnection: false)
                return
            }
            guard self.currentQuery?.isStillAdmitted() ?? true else {
                finishCurrentQuery(
                    DNSTransportResponse(response: nil, outcome: .refusedAfterLatchReplaced),
                    resetsConnection: false)
                return
            }

            sendCurrentQuery()
        }
    }

    private func ensureConnectionReady(completion: @escaping @Sendable (Bool) -> Void) {
        if connectionIsReady, connection != nil {
            completion(true)
            return
        }

        readyCompletions.append(completion)
        guard !isConnecting else {
            return
        }

        startConnectionLocked()
    }

    private func startConnectionLocked() {
        guard !bootstrapAddresses.isEmpty,
              let networkPort = NWEndpoint.Port(rawValue: port)
        else {
            completeReadyCompletions(isReady: false)
            return
        }

        resetConnectionLocked(advanceBootstrapAddress: false)
        isConnecting = true
        connectionGeneration += 1
        let generation = connectionGeneration
        let address = bootstrapAddresses[nextBootstrapAddressIndex % bootstrapAddresses.count]
        let tlsOptions = NWProtocolTLS.Options()
        hostname.withCString { serverName in
            sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, serverName)
        }
        let tcpOptions = NWProtocolTCP.Options()
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        let networkConnection = NWConnection(
            host: NWEndpoint.Host(address),
            port: networkPort,
            using: parameters
        )
        connection = networkConnection
        networkConnection.stateUpdateHandler = { [weak self] state in
            self?.queue.async { [weak self] in
                self?.handleConnectionState(state, generation: generation)
            }
        }
        connectionStartedAtMonotonicTime = debugLogger == nil ? nil : ProcessInfo.processInfo.systemUptime
        scheduleTimeout(generation: generation)
        networkConnection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State, generation: Int) {
        guard generation == connectionGeneration else {
            return
        }

        switch state {
        case .ready:
            isConnecting = false
            connectionIsReady = true
            lastConnectionActivityAt = Date()
            logConnectionReady()
            completeReadyCompletions(isReady: true)
        case .failed, .cancelled:
            let hadReadyCompletions = !readyCompletions.isEmpty
            resetConnectionLocked(advanceBootstrapAddress: !hadReadyCompletions)
            completeReadyCompletions(isReady: false)
            if !hadReadyCompletions {
                failOrRetryCurrentQuery(outcome: .receiveFailed, resetsConnection: false)
            }
        default:
            break
        }
    }

    private func sendCurrentQuery() {
        guard let currentQuery,
              let framedQuery = DNSLengthPrefixedWireMessage.framedQuery(currentQuery.query),
              let connection
        else {
            failOrRetryCurrentQuery(outcome: .sendFailed, resetsConnection: true)
            return
        }

        let generation = connectionGeneration
        scheduleTimeout(generation: generation)
        connection.send(content: framedQuery, completion: .contentProcessed { [weak self] error in
            self?.queue.async { [weak self] in
                guard let self, generation == self.connectionGeneration else {
                    return
                }

                guard error == nil else {
                    self.failOrRetryCurrentQuery(outcome: .sendFailed, resetsConnection: true)
                    return
                }

                self.receiveResponseLength(generation: generation)
            }
        })
    }

    private func receiveResponseLength(generation: Int) {
        receiveExact(byteCount: 2, generation: generation) { [weak self] lengthData in
            guard let self, generation == self.connectionGeneration else {
                return
            }

            guard let responseLength = DNSLengthPrefixedWireMessage.responseBodyLength(fromPrefix: lengthData) else {
                self.failOrRetryCurrentQuery(outcome: .receiveFailed, resetsConnection: true)
                return
            }

            self.receiveExact(byteCount: responseLength, generation: generation) { [weak self] response in
                guard let self, generation == self.connectionGeneration else {
                    return
                }

                guard let currentQuery = self.currentQuery,
                      let response,
                      DNSWireMessage.isValidResponse(response, matching: currentQuery.query)
                else {
                    self.failOrRetryCurrentQuery(outcome: .mismatchedResponse, resetsConnection: true)
                    return
                }

                self.finishCurrentQuery(
                    DNSTransportResponse(response: response, outcome: .success),
                    resetsConnection: false
                )
            }
        }
    }

    private func receiveExact(
        byteCount: Int,
        generation: Int,
        accumulated: Data = Data(),
        completion: @escaping @Sendable (Data?) -> Void
    ) {
        guard generation == connectionGeneration,
              let connection
        else {
            completion(nil)
            return
        }

        let remainingByteCount = byteCount - accumulated.count
        guard remainingByteCount > 0 else {
            completion(accumulated)
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: remainingByteCount) { [weak self] data, _, isComplete, error in
            self?.queue.async { [weak self] in
                guard let self, generation == self.connectionGeneration else {
                    return
                }

                switch DNSLengthPrefixedWireMessage.receiveStep(
                    accumulated: accumulated,
                    incoming: data,
                    hadReceiveError: error != nil,
                    isComplete: isComplete,
                    targetByteCount: byteCount,
                    failsOnEmptyChunk: true
                ) {
                case .frameComplete(let frame):
                    completion(frame)
                case .failed:
                    completion(nil)
                case .continueReceiving(let nextData):
                    self.receiveExact(
                        byteCount: byteCount,
                        generation: generation,
                        accumulated: nextData,
                        completion: completion
                    )
                }
            }
        }
    }

    private func scheduleTimeout(generation: Int) {
        currentTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, generation == self.connectionGeneration else {
                return
            }

            self.readyCompletions = []
            self.resetConnectionLocked(advanceBootstrapAddress: !self.currentAttemptReusedConnection)
            self.failOrRetryCurrentQuery(outcome: .timeout, resetsConnection: false)
        }
        currentTimeout = timeout
        let remaining = min(TimeInterval(timeoutSeconds), currentQuery?.deadline.remainingSeconds() ?? TimeInterval(timeoutSeconds))
        queue.asyncAfter(deadline: .now() + remaining, execute: timeout)
    }

    private func failOrRetryCurrentQuery(outcome: DNSTransportOutcome, resetsConnection: Bool) {
        currentTimeout?.cancel()
        currentTimeout = nil

        if resetsConnection {
            resetConnectionLocked(advanceBootstrapAddress: true)
        }

        guard var currentQuery else {
            return
        }

        if DoTQueryRetryPolicy.shouldRetry(
            outcome: outcome,
            priorAttemptCount: currentQuery.connectionAttemptCount,
            attemptRodeReusedConnection: currentAttemptReusedConnection,
            bootstrapAddressCount: bootstrapAddresses.count
        ) {
            currentQuery.connectionAttemptCount += 1
            self.currentQuery = currentQuery
            connectThenSendCurrentQuery()
            return
        }

        finishCurrentQuery(
            DNSTransportResponse(response: nil, outcome: outcome),
            resetsConnection: false
        )
    }

    private func finishCurrentQuery(_ response: DNSTransportResponse, resetsConnection: Bool) {
        currentTimeout?.cancel()
        currentTimeout = nil
        let completion = currentQuery?.completion
        currentQuery = nil

        if response.response != nil {
            lastConnectionActivityAt = Date()
        }
        if resetsConnection {
            resetConnectionLocked(advanceBootstrapAddress: response.response == nil)
        }

        completion?(response)
        startNextQueryIfNeeded()
    }

    private func resetConnectionLocked(advanceBootstrapAddress: Bool) {
        connectionGeneration += 1
        connectionIsReady = false
        isConnecting = false
        if advanceBootstrapAddress, !bootstrapAddresses.isEmpty {
            nextBootstrapAddressIndex = (nextBootstrapAddressIndex + 1) % bootstrapAddresses.count
        }
        let oldConnection = connection
        connection = nil
        oldConnection?.stateUpdateHandler = nil
        oldConnection?.cancel()
    }

    private func completeReadyCompletions(isReady: Bool) {
        let completions = readyCompletions
        readyCompletions = []
        completions.forEach { $0(isReady) }
    }

    // Handshake observation: the TLS handshake cost paid for a freshly
    // established connection (reused connections never reach this path), so
    // the resolver-transport latency can be attributed between connect and
    // first byte. Emitted only when a debug logger is injected.
    private func logConnectionReady() {
        guard let debugLogger, let startedAt = connectionStartedAtMonotonicTime else {
            return
        }

        connectionStartedAtMonotonicTime = nil
        let handshakeMilliseconds = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        debugLogger("dns-dot-connection-ready", [
            "endpoint": hostname,
            "handshakeMs": "\(Int(handshakeMilliseconds.rounded()))"
        ])
    }

    private func cancelLocked() {
        isCancelled = true
        currentTimeout?.cancel()
        currentTimeout = nil
        let activeCompletion = currentQuery?.completion
        let queuedCompletions = pendingQueries.map(\.completion)
        currentQuery = nil
        pendingQueries = []
        readyCompletions = []
        resetConnectionLocked(advanceBootstrapAddress: false)

        let failure = DNSTransportResponse(response: nil, outcome: .receiveFailed)
        activeCompletion?(failure)
        queuedCompletions.forEach { $0(failure) }
    }
}

enum DNSLengthPrefixedWireMessage {
    static func framedQuery(_ query: Data) -> Data? {
        guard query.count <= Int(UInt16.max) else {
            return nil
        }

        var frame = Data()
        appendUInt16(UInt16(query.count), to: &frame)
        frame.append(query)
        return frame
    }

    // One accumulation step of the receive-side reassembly shared by the DoT and DoQ
    // connections. Pure so the truncation/partial-frame/error branches get executable
    // tests (DNSLengthPrefixedFramingTests) — the NWConnection callbacks stay thin glue.
    enum ReceiveStep: Equatable {
        /// The target byte count is fully accumulated; the frame is ready to consume.
        case frameComplete(Data)
        /// The stream cannot yield a complete frame (receive error, empty chunk where
        /// one is required, or the peer finished the stream short). Fail the query.
        case failed
        /// More bytes are required; issue another receive with this accumulation.
        case continueReceiving(accumulated: Data)
    }

    // `failsOnEmptyChunk` preserves the transports' historical difference: DoT treats a
    // nil/empty chunk without an error as a dead read and fails immediately; DoQ
    // tolerates it and keeps receiving (QUIC delivery can surface empty callbacks).
    // Both agree that a stream FINishing short of the target is terminal — replaying a
    // receive on a finished stream can spin until the query timeout instead of failing
    // fast (the pre-extraction DoQ loop did exactly that on truncated responses).
    static func receiveStep(
        accumulated: Data,
        incoming: Data?,
        hadReceiveError: Bool,
        isComplete: Bool,
        targetByteCount: Int,
        failsOnEmptyChunk: Bool
    ) -> ReceiveStep {
        guard !hadReceiveError else {
            return .failed
        }

        let chunk = incoming ?? Data()
        if failsOnEmptyChunk, chunk.isEmpty {
            return .failed
        }

        var nextData = accumulated
        nextData.append(chunk)

        if nextData.count >= targetByteCount {
            return .frameComplete(nextData)
        }

        guard !isComplete else {
            return .failed
        }

        return .continueReceiving(accumulated: nextData)
    }

    // Decodes the RFC 7858 §3.3 / RFC 9250 §4.2 big-endian response-length prefix.
    // nil for a missing/short prefix and for a zero length: a zero-length "response"
    // carries no DNS header, so treating it as a frame would hand an empty message to
    // response validation. Slice-safe (never assumes index 0).
    static func responseBodyLength(fromPrefix lengthData: Data?) -> Int? {
        guard let lengthData, lengthData.count == 2 else {
            return nil
        }

        let firstIndex = lengthData.startIndex
        let secondIndex = lengthData.index(after: firstIndex)
        let responseLength = Int((UInt16(lengthData[firstIndex]) << 8) | UInt16(lengthData[secondIndex]))
        guard responseLength > 0 else {
            return nil
        }

        return responseLength
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

// Decides whether a failed DoT attempt earns another connection attempt. Pure so the
// retry matrix gets executable tests (DoTQueryRetryPolicyTests); DoTConnection owns the
// side effects (bootstrap-address advance, reconnect) once the decision says retry.
// pinned: DoTQueryRetryPolicyTests.testTimeoutOnReusedConnectionRetriesExactlyOnce
enum DoTQueryRetryPolicy {
    static func shouldRetry(
        outcome: DNSTransportOutcome,
        priorAttemptCount: Int,
        attemptRodeReusedConnection: Bool,
        bootstrapAddressCount: Int
    ) -> Bool {
        let maximumAttempts = max(1, bootstrapAddressCount)
        // Timeouts retry exactly once, and only when the attempt rode a REUSED
        // connection: a query that timed out on a zombie pooled connection
        // deserves one fresh connection before failing (and before the failure
        // counts toward device-DNS fallback). Fresh-connection timeouts still
        // fail immediately so worst-case latency stays bounded.
        let allowsStaleConnectionRetry = outcome == .timeout
            && attemptRodeReusedConnection
            && priorAttemptCount == 0
        if outcome != .timeout || allowsStaleConnectionRetry,
           priorAttemptCount + 1 < maximumAttempts || allowsStaleConnectionRetry {
            return true
        }

        return false
    }
}
