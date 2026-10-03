import Foundation
import LavaSecKit

// Shared result vocabulary for the extracted DNS transports (DoH/DoT/DoQ).
// Resolver-level outcomes (backed-off, device-DNS-unavailable, ...) stay with
// the tunnel's attempt bookkeeping; transports only report what happened to
// the wire exchange itself.
/// Wire-exchange result shared by DoH, DoT, and DoQ and persisted through its diagnostic raw string.
// `CaseIterable` so the classification test can enumerate rather than restate: the whole point of
// `isTransportFailureEvidence` being a category is that a fourth refusal added later is caught,
// and a hand-written test list cannot deliver that (Kilo/sweep, PR #623).
public enum DNSTransportOutcome: String, CaseIterable, Sendable {
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
    /// A datagram arrived from an address or port other than the queried resolver's.
    ///
    /// Split from ``mismatchedResponse`` because the two prove opposite things. A datagram from
    /// the RESOLVER whose transaction or question does not match is proof the query reached the
    /// resolver and a reply came back; a datagram from somewhere else proves nothing about either
    /// (PR #577). UDP-only: the connection-oriented transports cannot receive off-source frames.
    case unexpectedSourceResponse = "unexpected-source-response"
    /// The DATA PATH this query was admitted under was replaced before it reached the wire.
    ///
    /// The connection-oriented transports queue: a query waits behind another query and behind a
    /// handshake, so seconds can pass between the orchestrator handing it over and the bytes
    /// leaving. A relatch inside that window leaves the query addressed to the resolver the user
    /// has just stopped choosing. Refusing at the send is the only place that can still stop it —
    /// every earlier gate has already passed (PR #611).
    ///
    /// NOTHING WAS SENT, which is what separates this from ``sendFailed``: that one is a write
    /// that failed, this one is a write that was never attempted.
    case refusedAfterLatchReplaced = "refused-after-latch-replaced"
    /// The lookup deadline elapsed before its DNS query was sent; the connection is not at fault.
    case expiredBeforeSend = "expired-before-send"

    /// Whether a nil response is evidence that the connection failed.
    /// Local admission refusals sent no DNS query and must not discard healthy pooled lanes.
    /// pinned: DNSTransportOutcomeTests.testOnlyADeclinedSendIsNotTransportFailureEvidence
    /// pinned: PacketTunnelDNSRuntimeSourceTests.testARefusedEncryptedQueryDoesNotDiscardThePool
    public var isTransportFailureEvidence: Bool {
        switch self {
        case .refusedAfterLatchReplaced, .expiredBeforeSend:
            return false
        case .success, .timeout, .httpStatusFailure, .sendFailed, .receiveFailed,
            .mismatchedResponse, .unexpectedSourceResponse:
            return true
        }
    }
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
