import Foundation

/// The composed connectivity-health picture: one overall level, the per-signal verdicts behind it,
/// and the recovery action to surface. Produced by ``ConnectivityHealthSupervisor``.
///
/// SURFACE-ONLY. This value is a read: it names what the operator should see and, in
/// ``recommendedAction``, the action a surface (banner button, diagnostics) may OFFER. It executes
/// nothing. Actual recovery stays where it already lives — the physical reconnect coordinator in
/// DNS-only mode and `ChainedOutageDriver`'s surrender → dns-only ladder while chained — selected by
/// the same ``DNSHealthAuthority`` this assessment is gated by.
public struct ConnectivityHealthAssessment: Equatable, Sendable {
    /// The worst level across the composed signals — the currency the three-level ``HealthVerdict``
    /// exists to make combinable. `.healthy` iff every signal is healthy.
    public let overallLevel: HealthVerdict.Level

    /// Each signal's verdict, keyed by id. A consumer surfaces the non-healthy ones (with their
    /// `reason` diagnostic label) to say WHICH dimension is degraded/down, not merely that one is.
    public let verdicts: [ConnectivityHealthSignalID: HealthVerdict]

    /// The recovery action to OFFER on a surface — never one this type performs. Only the
    /// DNS/link policy, gated by ownership, can make this `.reconnect`; see the supervisor for why
    /// the data-path signal can never raise it.
    public let recommendedAction: ProtectionConnectivityAction

    public init(
        overallLevel: HealthVerdict.Level,
        verdicts: [ConnectivityHealthSignalID: HealthVerdict],
        recommendedAction: ProtectionConnectivityAction
    ) {
        self.overallLevel = overallLevel
        self.verdicts = verdicts
        self.recommendedAction = recommendedAction
    }

    /// The verdict for one signal, or `.healthy` if that signal was not evaluated (an empty/partial
    /// supervisor). Lets a consumer read a dimension without unwrapping the dictionary.
    public func verdict(for id: ConnectivityHealthSignalID) -> HealthVerdict {
        verdicts[id] ?? .healthy
    }

    /// The non-healthy signals in a STABLE order (``ConnectivityHealthSignalID/allCases``), so a
    /// surface lists degraded/down dimensions deterministically instead of in dictionary order.
    public var unhealthySignals: [(id: ConnectivityHealthSignalID, verdict: HealthVerdict)] {
        ConnectivityHealthSignalID.allCases.compactMap { id in
            guard let verdict = verdicts[id], verdict.level != .healthy else { return nil }
            return (id, verdict)
        }
    }
}

/// Composes the connectivity-health signals — DNS resolution, link/path, data path — into one
/// ``ConnectivityHealthAssessment``, gated by ``DNSHealthAuthority`` ownership.
///
/// ## The action gate (the founder-agreed rule, enforced here)
///
/// `recommendedAction` has exactly one source of `.reconnect`: the authoritative
/// ``ProtectionConnectivityPolicy`` (the single owner of DNS/link severity → action), and only when
/// the authority says a physical reconnect may act. Two consequences fall out, both PINNED:
///
///  * **The data-path signal never drives a reconnect.** `DataPathHealth`'s `.down("upstream-quiet")`
///    names a peer that stays reachable but stops FORWARDING — a flaky/misconfigured upstream a
///    tunnel restart cannot fix, and restarting on it reintroduces the false-reconnect churn #548
///    closed. So the data-path verdict is not consulted for the action AT ALL; it contributes only to
///    ``ConnectivityHealthAssessment/overallLevel`` and the surfaced reason. Structural exclusion, not
///    a downstream "please don't" — there is no code path from an `upstream-quiet` verdict to
///    `.reconnect`.
///  * **A chained reconnect is clamped to `.turnOff`.** While the tunnel supervisor owns health
///    (`authority.physicalReconnectMayAct == false`), a physical VPN restart is exactly the
///    INV-CHAIN-1 leak / #548 loop; recovery there is the outage driver's internal surrender ladder,
///    not a user-visible reconnect. So even a genuine DNS `.needsReconnect` is surfaced as `.turnOff`.
///
/// Ownership is CONSULTED (`DNSHealthAuthority`), never re-derived inline from
/// `currentTunnelDataPathMode().isChainedUpstream` — the seam-divergence that produced #548. The
/// supervisor is a pure function of its inputs + the authority + `now`; sampling and the authority
/// bit are the provider's job (`INV-QUEUE-1`, `INV-MEM-1`), handed in here.
///
/// ## What each signal reflects, per owner
///
/// `DNSResolutionHealth` delegates to the physical-DNS policy. In DNS-only mode (physicalPath owns)
/// that is the authoritative DNS reading. While chained, the provider mirrors only the CHAINED
/// counters and FREEZES the physical failure fields, so this signal's physical reading goes stale —
/// a pre-latch `needs-reconnect` streak / device-DNS-fallback marker / uncovered failed smoke probe
/// would otherwise produce a permanent stale `.down`/`.degraded` that never reflects the chained
/// path. The supervisor therefore SHORT-CIRCUITS the DNS-resolution signal to `.healthy` while the
/// tunnel supervisor owns health (`verdict(from:for:authority:now:)`), which is what actually makes
/// link + data-path load-bearing there. Chained DNS health is surfaced by the Slice-3 chained
/// counters + the data-path signal, not re-homed into this signal (a later integration owns that).
/// The link and data-path signals read live current-state, so they are NOT gated by owner.
public struct ConnectivityHealthSupervisor: Sendable {
    private let signals: [any ConnectivityHealthSignal]

    /// The shipping supervisor: the three connectivity-health signals in id order.
    public init() {
        self.init(signals: [DNSResolutionHealth(), LinkPathHealth(), DataPathHealth()])
    }

    /// Inject a specific signal set — for tests that need a subset/order. Production uses `init()`.
    init(signals: [any ConnectivityHealthSignal]) {
        self.signals = signals
    }

    public func assess(
        for inputs: ConnectivityHealthInputs,
        authority: DNSHealthAuthority,
        now: Date = Date()
    ) -> ConnectivityHealthAssessment {
        let verdicts = Dictionary(
            signals.map { ($0.id, verdict(from: $0, for: inputs, authority: authority, now: now)) },
            uniquingKeysWith: { first, _ in first })

        let overallLevel = verdicts.values
            .max(by: { Self.severityRank($0.level) < Self.severityRank($1.level) })?
            .level ?? .healthy

        // The ONLY source of a reconnect recommendation: the authoritative DNS/link policy, gated by
        // ownership. The data-path verdict is deliberately absent from this derivation — that is the
        // founder-agreed gate (see the type doc). `primaryAction` already composes DNS + link
        // (network-unavailable is the policy's top precedence), so we do not re-map severities here
        // and cannot drift from the policy.
        let policyAction = ProtectionConnectivityPolicy.assessment(
            isConnected: inputs.isConnected,
            health: inputs.health,
            now: now
        ).primaryAction
        let recommendedAction: ProtectionConnectivityAction =
            (policyAction == .reconnect && !authority.physicalReconnectMayAct) ? .turnOff : policyAction

        return ConnectivityHealthAssessment(
            overallLevel: overallLevel,
            verdicts: verdicts,
            recommendedAction: recommendedAction)
    }

    /// One signal's verdict, gated by ownership. While the tunnel supervisor owns health the
    /// DNS-resolution signal is short-circuited to `.healthy` (quiescent): it reads the physical-DNS
    /// policy over `inputs.health`, but the provider freezes the physical failure fields while chained
    /// (it mirrors only the CHAINED counters — see `mirrorChainedHealthCountersIfChanged`), so a
    /// pre-latch failure streak / device-DNS-fallback marker / uncovered failed smoke probe would
    /// otherwise produce a permanent STALE `.down`/`.degraded` that never reflects the chained path.
    /// Enforcing the short-circuit here (not merely documenting the intent) is what makes link +
    /// data-path load-bearing while chained. Link and data-path are live current-state, so they are
    /// evaluated under both owners. (Kilo, #555)
    /// pinned: ConnectivityHealthSupervisorTests.testDNSResolutionSignalIsQuiescentWhileTunnelSupervisorOwnsHealth
    private func verdict(
        from signal: any ConnectivityHealthSignal,
        for inputs: ConnectivityHealthInputs,
        authority: DNSHealthAuthority,
        now: Date
    ) -> HealthVerdict {
        if signal.id == .dnsResolution, authority.owner == .tunnelSupervisor {
            return .healthy
        }
        return signal.verdict(for: inputs, now: now)
    }

    /// Severity ordering for the overall level — `down` (2) worst, then `degraded` (1), `healthy`
    /// (0). Not the enum's `String` rawValue order (which is alphabetical and would rank `down`
    /// below `healthy`). Private: the composed `overallLevel` is what tests assert, not the rank.
    private static func severityRank(_ level: HealthVerdict.Level) -> Int {
        switch level {
        case .healthy: 0
        case .degraded: 1
        case .down: 2
        }
    }
}
