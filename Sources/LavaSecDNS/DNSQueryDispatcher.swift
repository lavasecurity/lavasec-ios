import Foundation
import LavaSecKit

/// The decision for an inbound DNS query in the packet tunnel.
public enum DNSQueryDecision: Equatable, Sendable {
    /// A resolver-bootstrap response is available; write it back directly.
    case bootstrap(Data)
    /// Protection is temporarily paused; forward upstream (pause TTL applies).
    case pausedForward
    /// The filter evaluated the question; an allowed query is checked again with its
    /// reachable answer aliases before the provider records the final diagnostic outcome.
    case filtered(FilterDecision)
}

/// Pure decision precedence for `PacketTunnelProvider.handle(packet:)`, extracted
/// so the safety-critical ordering is unit-testable without starting a tunnel:
///
///   resolver bootstrap  >  temporary pause  >  filter (block / allow)
///
/// The bootstrap-first rule is a hard invariant — a query that resolves the
/// encrypted resolver's own hostname must NEVER be blocked or paused, or the
/// tunnel cannot bring DNS up at all. Inputs are lazy closures so each is read
/// only when its precedence step is reached, preserving the original
/// short-circuit (no snapshot read when bootstrap/paused, no pause read when
/// bootstrap). The provider performs all I/O and diagnostics on the result.
public struct DNSQueryDispatcher: Sendable {
    /// Creates a stateless dispatcher; all policy inputs are supplied lazily to each decision.
    public init() {}

    /// The filtering outcome and TTL limit for one forwarded client response.
    public struct ForwardedDecision: Equatable, Sendable {
        /// Final domain-filter decision, including the user's current temporary pause.
        public let decision: FilterDecision
        /// Existing or pause-imposed TTL limit; nil leaves the resolver TTL unchanged.
        public let maximumAnswerTTL: UInt32?
    }

    /// Applies current pause intent to a question-and-alias decision. Normal allows keep
    /// their filter reason; would-block answers are marked as allowed by the pause and get
    /// a short TTL so client caches cannot outlive resumed protection.
    public func decideForwardedResponse(
        filterDecision: FilterDecision,
        isProtectionPaused: Bool,
        maximumAnswerTTL: UInt32?,
        pausedWouldBlockTTL: UInt32
    ) -> ForwardedDecision {
        let pauseOverridesBlock = isProtectionPaused && filterDecision.action == .block
        let pauseTTL = pauseOverridesBlock ? pausedWouldBlockTTL : nil
        return ForwardedDecision(
            decision: pauseOverridesBlock ? .pausedAllow : filterDecision,
            maximumAnswerTTL: [maximumAnswerTTL, pauseTTL].compactMap { $0 }.min()
        )
    }

    /// Evaluates bootstrap, pause, then filtering in order and invokes no lower-priority closure after a match.
    public func decide(
        bootstrapResponse: () -> Data?,
        isProtectionPaused: () -> Bool,
        filterDecision: () -> FilterDecision
    ) -> DNSQueryDecision {
        if let bootstrapResponse = bootstrapResponse() {
            return .bootstrap(bootstrapResponse)
        }

        if isProtectionPaused() {
            return .pausedForward
        }

        return .filtered(filterDecision())
    }
}
