import Foundation
import LavaSecKit

// Shared result vocabulary for the extracted DNS transports (DoH/DoT/DoQ).
// Resolver-level outcomes (backed-off, device-DNS-unavailable, ...) stay with
// the tunnel's attempt bookkeeping; transports only report what happened to
// the wire exchange itself.
/// Wire-exchange result shared by DoH, DoT, and DoQ and persisted through its diagnostic raw string.
public enum DNSTransportOutcome: String, Sendable {
    /// A response was received and passed the transport's query-identity validation.
    case success
    /// The exchange exceeded its configured timeout budget.
    case timeout
    /// A DoH server returned a non-success HTTP status.
    case httpStatusFailure = "http-status-failure"
    /// The query could not be written to the transport connection.
    case sendFailed = "send-failed"
    /// No usable response could be read or decoded from the transport.
    case receiveFailed = "receive-failed"
    /// A reply arrived but did not match the request transaction or question.
    case mismatchedResponse = "mismatched-response"
}

/// Transport completion payload containing optional DNS wire bytes and their failure classification.
public struct DNSTransportResponse: Sendable {
    /// Validated DNS response bytes; `nil` whenever no reply can be forwarded.
    public let response: Data?
    /// Stable outcome consumed by resolver attempt logging, retry policy, and health scoring.
    public let outcome: DNSTransportOutcome
    /// Negotiated ALPN protocol for the transaction that produced this
    /// response (DoH only), when observed.
    public let negotiatedHTTPProtocolName: String?

    package init(
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
