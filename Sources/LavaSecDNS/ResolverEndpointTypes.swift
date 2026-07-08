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
    public let request: IPv4UDPDNSPacket
    /// The packet-flow protocol number (address family) the response packet is
    /// written back with.
    public let protocolNumber: Int
    /// Cap applied to the response's answer TTLs before write-back (e.g. the
    /// 1-second cap on would-block domains forwarded during a temporary
    /// protection pause, so they cannot outlive the pause in caches);
    /// `nil` means no cap.
    public let maximumAnswerTTL: UInt32?
    /// Set when the query was forwarded during a temporary protection pause for
    /// a domain that would otherwise have been blocked; drives pause bookkeeping
    /// when the response completes.
    public let temporaryPauseNormalizedDomain: String?

    /// Explicit because the memberwise initializer is internal-at-most and the
    /// packet-tunnel provider constructs these cross-module (Phase E1).
    public init(
        request: IPv4UDPDNSPacket,
        protocolNumber: Int,
        maximumAnswerTTL: UInt32?,
        temporaryPauseNormalizedDomain: String?
    ) {
        self.request = request
        self.protocolNumber = protocolNumber
        self.maximumAnswerTTL = maximumAnswerTTL
        self.temporaryPauseNormalizedDomain = temporaryPauseNormalizedDomain
    }
}

/// A validated upstream resolver IP endpoint. Construction accepts numeric
/// IPv4/IPv6 literals only (`inet_pton`) — hostnames are rejected, so dialing
/// a resolver can never itself require DNS resolution.
public struct ResolverEndpoint: Hashable, Sendable {
    /// The numeric address literal, exactly as validated.
    public let address: String
    /// The validated address family: `AF_INET` or `AF_INET6`.
    public let family: Int32

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
    public var socketAddressLength: socklen_t {
        if family == AF_INET6 {
            return socklen_t(MemoryLayout<sockaddr_in6>.size)
        }

        return socklen_t(MemoryLayout<sockaddr_in>.size)
    }
}

private extension ResolverBackoffPolicy.AttemptOutcome {
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
        case .mismatchedResponse:
            self = .mismatchedResponse
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
