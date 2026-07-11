import Foundation
import LavaSecKit

// DNS-over-HTTPS execution, extracted from PacketTunnelProvider as the first
// `DNSResolvingTransport` module. Owns the URLSession lifecycle plus the DoH3
// preference: every request opts into HTTP/3 (Apple's loader falls back to
// H2/H1 natively) and the negotiated protocol is reported on every response so
// tunnel health and UI surfaces can annotate "DoH3".

/// Thread-safe DNS-over-HTTPS client that owns an ephemeral URLSession and reports negotiated HTTP protocol metadata.
public final class DoHTransport: @unchecked Sendable {
    private let timeoutSeconds: Int
    private let debugLogger: DNSTransportDebugLogger?
    private let sessionLock = NSLock()
    private var session: URLSession
    private var activeTaskCount = 0
    private var shouldResetWhenIdle = false

    /// Creates an HTTP/3-capable client with request/resource timeouts measured in whole seconds.
    public init(timeoutSeconds: Int, debugLogger: DNSTransportDebugLogger? = nil) {
        self.timeoutSeconds = timeoutSeconds
        self.debugLogger = debugLogger
        self.session = Self.makeSession(timeoutSeconds: timeoutSeconds)
    }

    /// Replaces the shared session immediately and cancels every task still owned by the previous session.
    public func resetSession() {
        let oldSession: URLSession
        sessionLock.lock()
        oldSession = session
        session = Self.makeSession(timeoutSeconds: timeoutSeconds)
        shouldResetWhenIdle = false
        sessionLock.unlock()
        oldSession.invalidateAndCancel()
    }

    /// Schedules session replacement after active tasks finish, or replaces it immediately when already idle.
    public func resetSessionWhenIdle() {
        let oldSession: URLSession?
        sessionLock.lock()
        shouldResetWhenIdle = true
        if activeTaskCount == 0 {
            oldSession = session
            session = Self.makeSession(timeoutSeconds: timeoutSeconds)
            shouldResetWhenIdle = false
        } else {
            oldSession = nil
        }
        sessionLock.unlock()
        oldSession?.invalidateAndCancel()
    }

    /// Invalidates the current session and cancels its outstanding requests during tunnel shutdown.
    public func cancel() {
        let sessionToCancel = currentSession()
        sessionToCancel.invalidateAndCancel()
    }

    /// Posts one DNS wire query and asynchronously completes once with validated bytes or a classified transport failure.
    public func resolve(
        _ query: Data,
        endpoint: URL,
        completion: @escaping @Sendable (DNSTransportResponse) -> Void
    ) {
        let request = DNSOverHTTPSRequest.makePOSTRequest(
            endpoint: endpoint,
            query: query,
            timeoutSeconds: TimeInterval(timeoutSeconds)
        )

        let metricsRecorder = DoHTaskMetricsRecorder(debugLogger: debugLogger)
        let task = beginTaskSession().dataTask(with: request) { data, response, error in
            defer {
                self.finishTask()
            }

            let negotiatedHTTPProtocolName = metricsRecorder.recordedProtocolName()

            if let urlError = error as? URLError, urlError.code == .timedOut {
                completion(DNSTransportResponse(
                    response: nil,
                    outcome: .timeout,
                    negotiatedHTTPProtocolName: negotiatedHTTPProtocolName
                ))
                return
            }

            guard error == nil, let data, let response else {
                completion(DNSTransportResponse(
                    response: nil,
                    outcome: .receiveFailed,
                    negotiatedHTTPProtocolName: negotiatedHTTPProtocolName
                ))
                return
            }

            do {
                let dnsResponse = try DNSOverHTTPSRequest.validatedDNSResponse(
                    body: data,
                    response: response,
                    originalQuery: query
                )
                completion(DNSTransportResponse(
                    response: dnsResponse,
                    outcome: .success,
                    negotiatedHTTPProtocolName: negotiatedHTTPProtocolName
                ))
            } catch DNSOverHTTPSRequest.Error.httpStatus(_) {
                completion(DNSTransportResponse(
                    response: nil,
                    outcome: .httpStatusFailure,
                    negotiatedHTTPProtocolName: negotiatedHTTPProtocolName
                ))
            } catch {
                completion(DNSTransportResponse(
                    response: nil,
                    outcome: .receiveFailed,
                    negotiatedHTTPProtocolName: negotiatedHTTPProtocolName
                ))
            }
        }

        // A per-task delegate is the only way a completion-handler task can
        // observe URLSessionTaskTransactionMetrics; metrics are delivered
        // before the completion handler runs.
        task.delegate = metricsRecorder
        task.resume()
    }

    private func beginTaskSession() -> URLSession {
        sessionLock.lock()
        activeTaskCount += 1
        let currentSession = session
        sessionLock.unlock()
        return currentSession
    }

    private func finishTask() {
        let oldSession: URLSession?
        sessionLock.lock()
        activeTaskCount = max(0, activeTaskCount - 1)
        if activeTaskCount == 0 && shouldResetWhenIdle {
            oldSession = session
            session = Self.makeSession(timeoutSeconds: timeoutSeconds)
            shouldResetWhenIdle = false
        } else {
            oldSession = nil
        }
        sessionLock.unlock()
        oldSession?.invalidateAndCancel()
    }

    private func currentSession() -> URLSession {
        sessionLock.lock()
        let currentSession = session
        sessionLock.unlock()
        return currentSession
    }

    private static func makeSession(timeoutSeconds: Int) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(timeoutSeconds)
        configuration.timeoutIntervalForResource = TimeInterval(timeoutSeconds)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
}

private final class DoHTaskMetricsRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var negotiatedProtocolName: String?
    private let debugLogger: DNSTransportDebugLogger?

    init(debugLogger: DNSTransportDebugLogger?) {
        self.debugLogger = debugLogger
    }

    func recordedProtocolName() -> String? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return negotiatedProtocolName
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard let transaction = metrics.transactionMetrics.last else {
            return
        }

        if let name = transaction.networkProtocolName {
            lock.lock()
            negotiatedProtocolName = name
            lock.unlock()
        }

        logConnectionHandshakeIfNeeded(transaction)
    }

    // Handshake observation: URLSession reports connect timing only when it
    // actually established a connection for this transaction (reused
    // connections leave the dates nil), so this fires once per fresh
    // connection rather than per query. Emitted only when a logger is injected.
    private func logConnectionHandshakeIfNeeded(_ transaction: URLSessionTaskTransactionMetrics) {
        guard let debugLogger,
              !transaction.isReusedConnection,
              let connectStart = transaction.connectStartDate,
              let connectEnd = transaction.connectEndDate
        else {
            return
        }

        let handshakeMilliseconds = max(0, connectEnd.timeIntervalSince(connectStart) * 1_000)
        debugLogger("dns-doh-connection-ready", [
            "protocol": transaction.networkProtocolName ?? "nil",
            "handshakeMs": "\(Int(handshakeMilliseconds.rounded()))"
        ])
    }
}
