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
    private static let maxConnectionsPerEndpoint = 4
    private let timeoutSeconds: Int
    private let debugLogger: DNSTransportDebugLogger?
    private let connectionLock = NSLock()
    private var connections: [String: [DoTConnection]] = [:]
    private var nextConnectionIndexByKey: [String: Int] = [:]
    private var activeQueryCount = 0
    private var shouldResetWhenIdle = false

    /// Creates connection pools whose per-query timeout budget is measured in whole seconds.
    public init(timeoutSeconds: Int, debugLogger: DNSTransportDebugLogger? = nil) {
        self.timeoutSeconds = timeoutSeconds
        self.debugLogger = debugLogger
    }

    /// Atomically removes and cancels every pooled TLS connection, including lanes serving active queries.
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

    /// Cancels all pooled work during tunnel shutdown using the immediate reset semantics.
    public func cancel() {
        resetConnections()
    }

    /// Resolves through a pooled endpoint lane and asynchronously returns one classified transport response.
    public func resolve(
        _ query: Data,
        endpoint: DNSOverTLSEndpoint,
        completion: @escaping @Sendable (DNSTransportResponse) -> Void
    ) {
        beginQuery()
        let connection = connection(for: endpoint)
        connection.resolve(query) { [weak self] upstreamResponse in
            self?.finishQuery()
            completion(upstreamResponse)
        }
    }

    /// Resolves on a fresh one-shot connection that is cancelled after completion and never enters the shared pool.
    public func resolveIsolated(
        _ query: Data,
        endpoint: DNSOverTLSEndpoint,
        completion: @escaping @Sendable (DNSTransportResponse) -> Void
    ) {
        let connection = DoTConnection(endpoint: endpoint, timeoutSeconds: timeoutSeconds, debugLogger: debugLogger)
        connection.resolve(query) { [connection] upstreamResponse in
            connection.cancel()
            completion(upstreamResponse)
        }
    }

    private func connection(for endpoint: DNSOverTLSEndpoint) -> DoTConnection {
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

    private func connectionPool(for endpoint: DNSOverTLSEndpoint) -> [DoTConnection] {
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

    private func beginQuery() {
        connectionLock.lock()
        activeQueryCount += 1
        connectionLock.unlock()
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
        completion: @escaping @Sendable (DNSTransportResponse) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
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
        connectThenSendCurrentQuery()
    }

    private func connectThenSendCurrentQuery() {
        guard let currentQuery else {
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

            guard let lengthData, lengthData.count == 2 else {
                self.failOrRetryCurrentQuery(outcome: .receiveFailed, resetsConnection: true)
                return
            }

            let responseLength = Int((UInt16(lengthData[0]) << 8) | UInt16(lengthData[1]))
            guard responseLength > 0 else {
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

                guard error == nil, let data, !data.isEmpty else {
                    completion(nil)
                    return
                }

                var nextData = accumulated
                nextData.append(data)

                if nextData.count >= byteCount {
                    completion(nextData)
                    return
                }

                guard !isComplete else {
                    completion(nil)
                    return
                }

                self.receiveExact(
                    byteCount: byteCount,
                    generation: generation,
                    accumulated: nextData,
                    completion: completion
                )
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
        queue.asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeout)
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

        let maximumAttempts = max(1, bootstrapAddresses.count)
        // Timeouts retry exactly once, and only when the attempt rode a REUSED
        // connection: a query that timed out on a zombie pooled connection
        // deserves one fresh connection before failing (and before the failure
        // counts toward device-DNS fallback). Fresh-connection timeouts still
        // fail immediately so worst-case latency stays bounded.
        let allowsStaleConnectionRetry = outcome == .timeout
            && currentAttemptReusedConnection
            && currentQuery.connectionAttemptCount == 0
        if outcome != .timeout || allowsStaleConnectionRetry,
           currentQuery.connectionAttemptCount + 1 < maximumAttempts || allowsStaleConnectionRetry {
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

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
