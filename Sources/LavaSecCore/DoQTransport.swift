import Foundation
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
public final class DoQTransport: @unchecked Sendable {
    private static let maxConnectionsPerEndpoint = 4
    private let timeoutSeconds: Int
    private let debugLogger: DNSTransportDebugLogger?
    private let connectionLock = NSLock()
    private var connections: [String: [DoQConnection]] = [:]
    private var nextConnectionIndexByKey: [String: Int] = [:]
    private var activeQueryCount = 0
    private var shouldResetWhenIdle = false

    public init(timeoutSeconds: Int, debugLogger: DNSTransportDebugLogger? = nil) {
        self.timeoutSeconds = timeoutSeconds
        self.debugLogger = debugLogger
    }

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

    public func resetConnectionsWhenIdle() {
        let connectionsToCancel: [DoQConnection]?
        connectionLock.lock()
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

    public func cancel() {
        resetConnections()
    }

    public func resolve(
        _ query: Data,
        endpoint: DNSOverQUICEndpoint,
        completion: @escaping @Sendable (DNSTransportResponse) -> Void
    ) {
        beginQuery()
        let connection = connection(for: endpoint)
        connection.resolve(query) { [weak self] upstreamResponse in
            self?.finishQuery()
            completion(upstreamResponse)
        }
    }

    public func resolveIsolated(
        _ query: Data,
        endpoint: DNSOverQUICEndpoint,
        completion: @escaping @Sendable (DNSTransportResponse) -> Void
    ) {
        let connection = DoQConnection(endpoint: endpoint, timeoutSeconds: timeoutSeconds, debugLogger: debugLogger)
        connection.resolve(query) { [connection] upstreamResponse in
            connection.cancel()
            completion(upstreamResponse)
        }
    }

    private func connection(for endpoint: DNSOverQUICEndpoint) -> DoQConnection {
        connectionLock.lock()
        defer {
            connectionLock.unlock()
        }

        let key = endpoint.cacheIdentifier
        let pool = connectionPool(for: endpoint)
        let index = nextConnectionIndexByKey[key, default: 0] % pool.count
        nextConnectionIndexByKey[key] = (index + 1) % pool.count
        return pool[index]
    }

    private func connectionPool(for endpoint: DNSOverQUICEndpoint) -> [DoQConnection] {
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

    private func beginQuery() {
        connectionLock.lock()
        activeQueryCount += 1
        connectionLock.unlock()
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

            pendingQueries.append(PendingQuery(query: query, completion: completion))
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
        queue.asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeout)

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
            let responseLength = Int(Self.readUInt16(accumulated, at: 0))
            guard responseLength > 0 else {
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
                    self.finishCurrentQuery(DNSTransportResponse(response: nil, outcome: .receiveFailed))
                    return
                }

                var next = accumulated
                if let data {
                    next.append(data)
                }

                guard !next.isEmpty || !isComplete else {
                    self.finishCurrentQuery(DNSTransportResponse(response: nil, outcome: .receiveFailed))
                    return
                }

                self.receiveResponseLength(
                    connection: connection,
                    originalQuery: originalQuery,
                    zeroIDQuery: zeroIDQuery,
                    accumulated: next
                )
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
                    self.finishCurrentQuery(DNSTransportResponse(response: nil, outcome: .receiveFailed))
                    return
                }

                var next = accumulated
                if let data {
                    next.append(data)
                }

                guard !next.isEmpty || !isComplete else {
                    self.finishCurrentQuery(DNSTransportResponse(response: nil, outcome: .receiveFailed))
                    return
                }

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

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        let firstIndex = data.index(data.startIndex, offsetBy: offset)
        let secondIndex = data.index(after: firstIndex)
        return (UInt16(data[firstIndex]) << 8) | UInt16(data[secondIndex])
    }
}
