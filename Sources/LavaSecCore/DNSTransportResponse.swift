import Foundation

// Shared result vocabulary for the extracted DNS transports (DoH/DoT/DoQ).
// Resolver-level outcomes (backed-off, device-DNS-unavailable, ...) stay with
// the tunnel's attempt bookkeeping; transports only report what happened to
// the wire exchange itself.
public enum DNSTransportOutcome: String, Sendable {
    case success
    case timeout
    case httpStatusFailure = "http-status-failure"
    case sendFailed = "send-failed"
    case receiveFailed = "receive-failed"
    case mismatchedResponse = "mismatched-response"
}

public struct DNSTransportResponse: Sendable {
    public let response: Data?
    public let outcome: DNSTransportOutcome
    /// Negotiated ALPN protocol for the transaction that produced this
    /// response (DoH only), when observed.
    public let negotiatedHTTPProtocolName: String?

    public init(
        response: Data?,
        outcome: DNSTransportOutcome,
        negotiatedHTTPProtocolName: String? = nil
    ) {
        self.response = response
        self.outcome = outcome
        self.negotiatedHTTPProtocolName = negotiatedHTTPProtocolName
    }
}

/// Sink for transport-level debug events. Callers inject their build-gated
/// logger; transports never link a logging backend themselves.
public typealias DNSTransportDebugLogger = @Sendable (_ event: String, _ details: [String: String]) -> Void
