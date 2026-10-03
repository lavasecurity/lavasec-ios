// Resolver endpoint + in-flight response value types, extracted verbatim from
// PacketTunnelProvider.swift (Phase E1). Zero provider state.
import Foundation
import LavaSecKit
import Darwin

/// Everything the tunnel needs to answer one in-flight DNS query once the
/// upstream result arrives: the original request datagram to respond to, the
/// packet-flow protocol number for the write-back, and per-query answer-TTL
/// policy captured at forward time.
public struct PendingDNSResponse: Sendable {
    /// The parsed request datagram the response must be addressed back to.
    public let request: any DNSDatagramRequest
    /// The packet-flow protocol number (address family) the response packet is
    /// written back with.
    public let protocolNumber: Int
    /// Cap applied to the response's answer TTLs before write-back (e.g. the
    /// 1-second cap on would-block domains forwarded during a temporary
    /// protection pause, so they cannot outlive the pause in caches);
    /// `nil` means no cap.
    public let maximumAnswerTTL: UInt32?
    /// Original name when admitted during a pause, including normally allowed questions.
    /// Retains the protection-policy snapshot for the final check after that pause expires.
    public let temporaryPauseNormalizedDomain: String?
    /// Set when this query's filter decision has ALREADY been recorded once, so a
    /// re-handling of it must not count it again.
    ///
    /// It travels with the request because the two queues that hold one of these —
    /// the in-flight coalescer and the transient-bootstrap wait — both hand their
    /// contents back to the request handler, and a handler that cannot tell a
    /// re-handling from a first handling records the same client query twice
    /// (Codex P2, PR #617). A request can also cross BOTH queues: a wake replay
    /// re-decided as transiently fail-closed is parked in the wait and re-handled a
    /// second time when the snapshot lands.
    public let isReplayOfARecordedDecision: Bool

    /// Explicit because the memberwise initializer is internal-at-most and the
    /// packet-tunnel provider constructs these cross-module (Phase E1).
    public init(
        request: any DNSDatagramRequest,
        protocolNumber: Int,
        maximumAnswerTTL: UInt32?,
        temporaryPauseNormalizedDomain: String?,
        isReplayOfARecordedDecision: Bool = false
    ) {
        self.request = request
        self.protocolNumber = protocolNumber
        self.maximumAnswerTTL = maximumAnswerTTL
        self.temporaryPauseNormalizedDomain = temporaryPauseNormalizedDomain
        self.isReplayOfARecordedDecision = isReplayOfARecordedDecision
    }
}

/// A validated upstream resolver IP endpoint. Construction accepts numeric
/// IPv4/IPv6 literals only (`inet_pton`) — hostnames are rejected, so dialing
/// a resolver can never itself require DNS resolution.
public struct ResolverEndpoint: Hashable, Sendable {
    /// The numeric address literal, exactly as validated.
    internal let address: String
    /// The validated address family: `AF_INET` or `AF_INET6`.
    internal let family: Int32

    /// Parses and validates `address`; fails for anything that is not a
    /// numeric IPv4 or IPv6 literal.
    public init?(address: String) {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            self.address = address
            self.family = AF_INET
            return
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, address, &ipv6) == 1 {
            self.address = address
            self.family = AF_INET6
            return
        }

        return nil
    }

    /// The `sockaddr` byte length matching `family`, for socket-call plumbing.
    internal var socketAddressLength: socklen_t {
        if family == AF_INET6 {
            return socklen_t(MemoryLayout<sockaddr_in6>.size)
        }

        return socklen_t(MemoryLayout<sockaddr_in>.size)
    }
}

extension ResolverBackoffPolicy.AttemptOutcome {
    /// Bridges a wire-level resolver attempt outcome into the backoff policy's
    /// own outcome domain (the policy lives in LavaSecKit and must not depend
    /// on the DNS layer's types). Case-for-case; new outcomes must be mapped
    /// here deliberately. `public` overrides the extension's default so the
    /// provider's backoff bookkeeping can call it cross-module.
    public init(_ outcome: ResolverAttemptOutcome) {
        switch outcome {
        case .success:
            self = .success
        case .timeout:
            self = .timeout
        case .httpStatusFailure:
            self = .httpStatusFailure
        case .backedOff:
            self = .backedOff
        case .sendFailed:
            self = .sendFailed
        case .receiveFailed:
            self = .receiveFailed
        case .invalidAddress:
            self = .invalidAddress
        case .unsupported:
            self = .unsupported
        case .socketUnavailable:
            self = .socketUnavailable
        case .tunnelInterfaceUnavailable:
            self = .tunnelInterfaceUnavailable
        case .physicalInterfaceUnavailable:
            // The mirror of the tunnel-interface refusal: the tunnel IS known, but F2's physical
            // pin for a floor-claimed destination is not available. Its own no-penalty case, not
            // folded into the tunnel one, so the ledger records the accurate condition.
            self = .physicalInterfaceUnavailable
        case .mismatchedResponse, .unexpectedSourceResponse:
            // Same backoff weight. Neither yielded a usable answer, and the distinction between
            // them is about EVIDENCE (did the resolver reply at all), which health scoring does
            // not ask — it only asks whether this attempt produced one (PR #577).
            self = .mismatchedResponse
        case .refusedByEgressPolicy, .refusedAfterLifecycleEnded, .refusedAfterLatchReplaced, .expiredBeforeSend,
            .resolverPortUnavailable:
            // Mapped to `backedOff`, which is the policy's "suppressed without a wire attempt"
            // outcome — the same shape as this one. It must NOT map to a failure: nothing is
            // wrong with the endpoint, and scoring a deliberate policy refusal against its
            // health would back off a resolver that is working, so that when the tunnel later
            // leaves chained mode the user's own resolver is suppressed for a while.
            self = .backedOff
        case .truncatedAnswer:
            // The endpoint ANSWERED (S6, resolved decision 3: TC is resolver liveness).
            // Benching a resolver for answering that a response is too large would suppress
            // a working upstream over a property of one domain's answer, not the resolver.
            self = .success
        case .deviceDNSUnavailable:
            self = .deviceDNSUnavailable
        }
    }
}

/// The result of one upstream resolution attempt: the raw response bytes (when
/// any arrived and validated) plus the classified outcome consumed by health
/// scoring and backoff bookkeeping.
public struct DNSUpstreamResponse: Sendable {
    /// Raw DNS response bytes; `nil` for every non-`.success` outcome.
    public let response: Data?
    /// Classification of the attempt (success/timeout/spoof-mismatch/…).
    public let outcome: ResolverAttemptOutcome

    /// Explicit for the same cross-module construction reason as `PendingDNSResponse`.
    public init(response: Data?, outcome: ResolverAttemptOutcome) {
        self.response = response
        self.outcome = outcome
    }
}

extension ResolverEndpoint {
    /// The numeric address literal, exactly as validated by `init?(address:)`.
    ///
    /// Public because the packet tunnel's F2 egress policy scopes a socket binding by
    /// DESTINATION: it must ask whether this endpoint is one the DNS capture floor claims
    /// (``DNSCaptureFloor``) and whether the user's own `AllowedIPs` already route it. Both
    /// questions need the literal, and `address` stays internal so the type's invariant —
    /// "constructed only through the validating initializer" — is unchanged by the accessor.
    public var addressLiteral: String { address }
}
