import Foundation

public protocol ResolverBackoffClock: Sendable {
    var now: Date { get }
}

public struct SystemResolverBackoffClock: ResolverBackoffClock {
    public init() {}

    public var now: Date { Date() }
}

public struct ResolverBackoffPolicy: Sendable {
    public enum AttemptOutcome: String, Sendable {
        case success
        case timeout
        case httpStatusFailure = "http-status-failure"
        case backedOff = "backed-off"
        case sendFailed = "send-failed"
        case receiveFailed = "receive-failed"
        case invalidAddress = "invalid-address"
        case unsupported
        case socketUnavailable = "socket-unavailable"
        case tunnelInterfaceUnavailable = "tunnel-interface-unavailable"
        case physicalInterfaceUnavailable = "physical-interface-unavailable"
        case mismatchedResponse = "mismatched-response"
        case deviceDNSUnavailable = "device-dns-unavailable"
    }

    public struct Attempt: Equatable, Sendable {
        public let address: String
        public let outcome: AttemptOutcome

        public init(address: String, outcome: AttemptOutcome) {
            self.address = address
            self.outcome = outcome
        }
    }

    private let interval: TimeInterval
    private let clock: any ResolverBackoffClock
    private var backoffUntilByAddress: [String: Date]
    private let encryptedRecoveryInterval: TimeInterval
    private var lastEncryptedRecoveryAt: Date?

    public init(
        interval: TimeInterval = 30,
        encryptedRecoveryInterval: TimeInterval = 1,
        clock: any ResolverBackoffClock = SystemResolverBackoffClock()
    ) {
        self.interval = interval
        self.encryptedRecoveryInterval = max(0.001, encryptedRecoveryInterval)
        self.clock = clock
        backoffUntilByAddress = [:]
    }

    /// The addresses worth trying now, in the caller's order.
    ///
    /// SUPPRESSION DEFERS; IT NEVER ELIMINATES. When every candidate is backed off, this returns
    /// them all rather than nothing — because a suppression that leaves the caller with no address
    /// has stopped being a throttle and become an outage, and the throttle's entire purpose is to
    /// prefer a healthy resolver over a sick one. With none to prefer, there is nothing to
    /// express, and the honest answer is "try anyway".
    ///
    /// FIELD EVIDENCE, and it is not marginal. Device 2026-08-29T09:19–09:22Z, chained split
    /// tunnel whose profile supplies ONE resolver: ten `.socketUnavailable` failures — local,
    /// transient, the upstream never asked — each stamped a 30 s penalty on that single address.
    /// The route emptied, and 36 of 185 resolutions (25%) were answered fail-closed SERVFAIL with
    /// the user's alternative DNS never consulted (`upstreamDeclinedToServe` bars the T1 rung
    /// on `reachedTheWire`, which a suppressed address fails). `tunnelDNSUnanswered` was 0
    /// throughout: the resolver answered everything it was actually asked. Every one of those
    /// failures was self-inflicted, and to the user they were dead pages arriving in rolling
    /// 30-second bands.
    ///
    /// THE COST IS ACCEPTED, EXPLICITLY. A resolver that is genuinely dead is now re-tried on
    /// every resolution and costs its full UDP timeout each time — the head-of-line latency the
    /// ledger was added to remove (`PacketTunnelProvider.resolveTunnelledPlainDNS`'s preamble).
    /// That is the right trade: slow-but-resolving beats fast-and-blackholed, and it is bounded
    /// by the receive timeout rather than unbounded. Where a second address exists the old
    /// behaviour is untouched — the sick one drops out and the healthy one is preferred, which is
    /// what the throttle was for.
    /// pinned: ResolverBackoffPolicyTests.testSuppressionNeverEmptiesANonEmptyRoute
    public func availableAddresses(from addresses: [String], now: Date? = nil) -> [String] {
        let now = now ?? clock.now
        let available = addresses.filter { address in
            guard let backoffUntil = backoffUntilByAddress[address] else {
                return true
            }

            return backoffUntil <= now
        }
        // The caller's ORDER is preserved on the fall-back, not just the membership: `addresses`
        // arrives in failover order and returning a re-derived set would silently re-rank the
        // ladder at exactly the moment every rung is suspect.
        return available.isEmpty ? addresses : available
    }

    /// Claims one encrypted recovery launch when every permitted endpoint is suppressed.
    /// Call under the same isolation as `record`: concurrent queries share one launch per interval.
    /// The one-second default limits recovery traffic while avoiding a full 30-second blackout.
    /// Healthy alternatives keep their usual priority; the claim does not alter endpoint penalties.
    /// pinned: ResolverBackoffRecoverySourceTests.testProviderClaimsRecoveryOnTheExistingBackoffQueue
    /// pinned: ResolverBackoffPolicyTests.testEncryptedRecoveryIsSharedBoundedAndKeepsHealthyPreference
    public mutating func claimEncryptedRecovery(from addresses: [String], now: Date? = nil) -> String? {
        let now = now ?? clock.now
        guard let first = addresses.first,
              addresses.allSatisfy({ isBackedOff($0, now: now) }) else { return nil }
        if let lastEncryptedRecoveryAt {
            let elapsed = now.timeIntervalSince(lastEncryptedRecoveryAt)
            // A backward wall-clock correction rebases the cooldown instead of extending an outage.
            if elapsed >= 0 && elapsed < encryptedRecoveryInterval { return nil }
        }
        lastEncryptedRecoveryAt = now
        return first
    }

    public func isBackedOff(_ address: String, now: Date? = nil) -> Bool {
        let now = now ?? clock.now
        guard let backoffUntil = backoffUntilByAddress[address] else {
            return false
        }

        return backoffUntil > now
    }

    public func backoffExpiration(for address: String) -> Date? {
        backoffUntilByAddress[address]
    }

    public mutating func record(_ attempts: [Attempt], now: Date? = nil) {
        let now = now ?? clock.now
        for attempt in attempts {
            switch attempt.outcome {
            case .success:
                backoffUntilByAddress.removeValue(forKey: attempt.address)
            case .timeout,
                 .httpStatusFailure,
                 .sendFailed,
                 .receiveFailed,
                 .invalidAddress,
                 .socketUnavailable,
                 .mismatchedResponse:
                backoffUntilByAddress[attempt.address] = now.addingTimeInterval(interval)
            case .backedOff, .unsupported, .deviceDNSUnavailable, .tunnelInterfaceUnavailable,
                 .physicalInterfaceUnavailable:
                // `.tunnelInterfaceUnavailable` is a TRANSIENT, LOCAL condition — the tunnel interface
                // the resolver socket must pin to (`virtualInterface`) is not bound yet: iOS populates
                // it a few seconds after a chained tunnel starts, so `currentResolverSocketBinding()`
                // refuses. NOT an upstream failure. Penalising the upstream ENDPOINT for it backed the
                // resolver off for the full `interval` (30 s) after a few seconds of startup
                // interface-lag, suppressing every query as `.backedOff` long after the interface was
                // ready → a ~30-45 s DNS blackout at connect (device-confirmed 2026-08-23 via
                // `chained-dns-selftest`: interface-unavailable → 30 s backedOff → recovery, chained
                // split conf). The refusal is already fail-closed (INV-DNS-1) and sends NOTHING on the
                // wire, so not penalising cannot hammer an endpoint; retrying the instant the interface
                // is ready is correct. Same treatment as `.deviceDNSUnavailable`, its device-DNS
                // analogue. GENUINE socket failures (`.socketUnavailable`) still back off above — under
                // real local resource pressure they can persist, so throttling is right there (Codex,
                // PR #570).
                //
                // `.physicalInterfaceUnavailable` is the mirror image and takes the same treatment: the
                // tunnel IS known, but F2's live physical pin for a floor-claimed, profile-uncovered
                // destination is missing. Also a decision WE made, nothing on the wire, no upstream
                // fault — so it must not bench the endpoint either.
                // pinned: ResolverBackoffPolicyTests.testTunnelInterfaceUnavailableDoesNotBackOffTheEndpoint
                break
            }
        }
    }

    public mutating func reset() {
        backoffUntilByAddress = [:]
        lastEncryptedRecoveryAt = nil
    }
}
