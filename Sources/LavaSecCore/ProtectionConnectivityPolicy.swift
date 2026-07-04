import Foundation

public enum ProtectionConnectivitySeverity: Equatable, Sendable {
    case healthy
    case recovering
    case usingDeviceDNSFallback
    /// The configured PRIMARY resolver's health probe is failing (a transition-induced
    /// staleness) but the ENCRYPTED fallback is actively carrying DNS, so protection is
    /// up and a user-visible self-reconnect is not warranted. The held wedge marker keeps
    /// re-probing the primary so device DNS resumes in place once it un-masks.
    case usingEncryptedFallback
    case dnsSlow
    case networkUnavailable
    case needsReconnect
}

public enum ProtectionConnectivityAction: Equatable, Sendable {
    case turnOff
    case reconnect
}

public extension ProtectionConnectivitySeverity {
    /// Stable, locale-independent identifier for diagnostics/logging. This is the
    /// only string the core exposes for a severity — user-facing title/subtitle are
    /// a per-OS presentation concern (iOS: ProtectionConnectivityPresentation).
    var diagnosticLabel: String {
        switch self {
        case .healthy:                 "healthy"
        case .recovering:              "recovering"
        case .usingDeviceDNSFallback:  "device-dns-fallback"
        case .usingEncryptedFallback:  "encrypted-fallback"
        case .dnsSlow:                 "dns-slow"
        case .networkUnavailable:      "network-unavailable"
        case .needsReconnect:          "needs-reconnect"
        }
    }
}

/// The portable result of a connectivity assessment: a semantic severity and the
/// recommended primary action. User-facing title/subtitle are NOT here — they are a
/// per-OS presentation concern (iOS: ProtectionConnectivityPresentation), so the
/// platform-agnostic core stays free of English copy.
public struct ProtectionConnectivityAssessment: Equatable, Sendable {
    public let severity: ProtectionConnectivitySeverity
    public let primaryAction: ProtectionConnectivityAction

    public init(
        severity: ProtectionConnectivitySeverity,
        primaryAction: ProtectionConnectivityAction
    ) {
        self.severity = severity
        self.primaryAction = primaryAction
    }
}

public enum ProtectionConnectivityPolicy {
    // FUTURE (dns-recovery optimization D, pending rc/debug-log evidence): within
    // this window after a runtime reset the state stays `.recovering` rather than
    // escalating to `.needsReconnect`. The 1504 export hit `backed-off` ~15s after
    // a handoff — just outside this 10s window — so a normal handoff briefly showed
    // the alarming `needs-reconnect`. Widening to ~20–30s would keep an ordinary
    // handoff in `.recovering` (the light recapture/reprobe recovery still runs
    // throughout). Trade-off: a genuinely-broken-after-handoff case takes longer to
    // escalate to the heavy self-reconnect — mostly cosmetic, but confirm typical
    // handoff recovery duration from the device debug log before widening.
    private static let freshRecoveryWindow: TimeInterval = 10
    private static let reconnectFailureThreshold = 3
    private static let slowResponseThresholdMilliseconds = 2_500

    /// Read-only mirror of `reconnectFailureThreshold` for OBSERVERS (the incident
    /// ledger records the rejected-response streak reaching this bar). Exposed so the
    /// tunnel-side write can't drift from the policy's own predicate; never an input
    /// to any decision outside this type.
    public static var sustainedRejectedSmokeResponseThreshold: Int {
        reconnectFailureThreshold
    }
    private static let slowResponseThreshold = 3
    private static let restartFailureReasons: Set<String> = [
        "timeout",
        "http-status-failure",
        "backed-off",
        "receive-failed",
        "send-failed",
        "socket-unavailable",
        // Resolver reachable but its answer was rejected (rcode != 0 / no answers /
        // question mismatch) — e.g. a stale off-network resolver refusing queries.
        // Restart-worthy so recovery engages instead of mis-reading it as healthy.
        "rejected-response"
    ]
    // Transition-induced primary-resolver staleness reasons the ENCRYPTED fallback may
    // cover without a restart (the configured resolver is unreachable on the new path,
    // but DoH/DoT is carrying DNS). `rejected-response` is deliberately EXCLUDED — a
    // resolver that is reachable-but-rejecting is a hijack/captive signal that must still
    // escalate (LAV-80/LAV-87), never be masked by fallback traffic.
    private static let encryptedFallbackCoverableReasons: Set<String> =
        restartFailureReasons.subtracting(["rejected-response"])

    public static func assessment(
        isConnected: Bool,
        health: TunnelHealthSnapshot,
        now: Date = Date()
    ) -> ProtectionConnectivityAssessment {
        guard isConnected else {
            return healthyAssessment
        }

        if !health.networkPathIsSatisfied {
            return ProtectionConnectivityAssessment(severity: .networkUnavailable, primaryAction: .turnOff)
        }

        if hasCurrentRestartWorthyFailure(health, now: now) {
            return ProtectionConnectivityAssessment(severity: .needsReconnect, primaryAction: .reconnect)
        }

        if isUsingDeviceDNSFallback(health) {
            return ProtectionConnectivityAssessment(severity: .usingDeviceDNSFallback, primaryAction: .turnOff)
        }

        // The primary probe is failing (transition staleness) but the encrypted fallback
        // is carrying DNS — surface it as an active-fallback state (never `.healthy`), the
        // counterpart of `.usingDeviceDNSFallback`. The restart was already suppressed for
        // this case in `hasCurrentRestartWorthyFailure`; this only labels it honestly.
        if encryptedFallbackCoversFailedProbe(health, now: now) {
            return ProtectionConnectivityAssessment(severity: .usingEncryptedFallback, primaryAction: .turnOff)
        }

        if hasCurrentSlowDNS(health) {
            return ProtectionConnectivityAssessment(severity: .dnsSlow, primaryAction: .reconnect)
        }

        if isRecoveringFromRecentNetworkChange(health, now: now) {
            return ProtectionConnectivityAssessment(severity: .recovering, primaryAction: .turnOff)
        }

        // Honesty floor: a current, uncovered smoke-probe failure (below the reconnect
        // threshold) must never read as `.healthy`. Otherwise — when forwarding is light
        // or carried by the encrypted fallback, which resets consecutiveUpstreamFailureCount
        // — the app showed "Protected" while the primary resolver's health probe was
        // failing. Surface `.recovering` until a probe actually succeeds (it escalates to
        // `.needsReconnect` once the smoke failures reach the threshold, above).
        if hasUncoveredFailedSmokeProbe(health) {
            return ProtectionConnectivityAssessment(severity: .recovering, primaryAction: .turnOff)
        }

        return healthyAssessment
    }

    private static var healthyAssessment: ProtectionConnectivityAssessment {
        ProtectionConnectivityAssessment(severity: .healthy, primaryAction: .turnOff)
    }

    private static func hasCurrentRestartWorthyFailure(_ health: TunnelHealthSnapshot, now: Date) -> Bool {
        // A confirmed hijacking/captive resolver escalates — checked FIRST so it is never
        // covered by the encrypted fallback below. Keyed on the DURABLE,
        // resolver-identity-scoped `consecutiveRejectedSmokeResponseCount` (inside
        // `hasSustainedRejectedSmokeResponse`), NOT the volatile latest reason: a churn-pinned
        // hijacker whose generic streak is reset below the threshold and whose latest tick is a
        // transient (receive-failed / nil-after-a-fallback-query) STILL re-escalates here as long
        // as an uncovered failed probe persists. Because the encrypted-fallback coverage below
        // only grants while that SAME counter is zero (its `== 0` guard), the two are mutually
        // exclusive — this can never bypass a legitimate coverage, it only closes the prior LAV-87
        // gap where a steadily-rejecting resolver could wedge undetected once churn dropped the
        // generic streak and flipped the latest reason off `rejected-response`.
        if hasSustainedRejectedSmokeResponse(health) {
            return true
        }

        // A transition-induced primary staleness that the encrypted fallback is actively
        // carrying does NOT warrant a user-visible restart: DNS stays up via DoH, and the
        // routine periodic smoke probe (DeviceDNSFallbackPolicy.routineSmokeProbeInterval)
        // keeps re-probing the primary INDEPENDENT of any wedge marker, so device DNS is
        // recaptured in place as soon as it recovers. (An accelerated covered-state recovery
        // probe is intentionally NOT armed here: arming it would require the overloaded
        // `reconnectNeededSince` marker, whose reuse bypasses authoritative SERVFAIL/REFUSED
        // on a freshly handed-off network — so faster in-place recapture is a tracked
        // follow-up, not a gap. The covered primary is still recaptured by the routine
        // probe, just not on an accelerated cadence.) This sits BELOW the hijack check (so a
        // reachable-but-rejecting resolver still escalates) and excludes `rejected-response`
        // + any durable hijack evidence.
        if encryptedFallbackCoversFailedProbe(health, now: now) {
            return false
        }

        if hasRecentFailedSmokeProbeWithoutFallback(health) {
            return true
        }

        guard let reason = health.lastFailureReason,
              restartFailureReasons.contains(reason)
        else {
            return false
        }

        guard health.consecutiveUpstreamFailureCount >= reconnectFailureThreshold else {
            return false
        }

        if let failureAt = health.lastUpstreamFailureAt {
            if let successAt = health.lastUpstreamSuccessAt, successAt >= failureAt {
                return false
            }

            if let networkChangeAt = health.lastNetworkChangeAt {
                return failureAt >= networkChangeAt
            }

            return true
        }

        return health.upstreamFailureCount > 0 && health.upstreamSuccessCount == 0
    }

    private static func hasCurrentSlowDNS(_ health: TunnelHealthSnapshot) -> Bool {
        guard health.consecutiveSlowUpstreamResponseCount >= slowResponseThreshold,
              let lastDuration = health.lastUpstreamDurationMilliseconds,
              lastDuration >= slowResponseThresholdMilliseconds,
              let slowAt = health.lastSlowUpstreamResponseAt
        else {
            return false
        }

        if let successAt = health.lastUpstreamSuccessAt, successAt < slowAt {
            return false
        }

        if let failureAt = health.lastUpstreamFailureAt, failureAt > slowAt {
            return false
        }

        if let networkChangeAt = health.lastNetworkChangeAt {
            return slowAt >= networkChangeAt
        }

        return true
    }

    private static func hasRecentFailedSmokeProbeWithoutFallback(_ health: TunnelHealthSnapshot) -> Bool {
        // Sustained failure of the PRIMARY resolver's health probe is restart-worthy.
        // Keyed on `consecutiveDNSSmokeProbeFailureCount` (reset only by a smoke-probe
        // success) rather than `consecutiveUpstreamFailureCount`: the latter is reset by
        // forwarding / encrypted-fallback successes and self-reconnects, so a wedged
        // primary that kept failing its probe was masked "healthy" by incidental
        // fallback-carried traffic (the "Protected, no internet" reports).
        hasUncoveredFailedSmokeProbe(health)
            && health.consecutiveDNSSmokeProbeFailureCount >= reconnectFailureThreshold
    }

    /// A resolver that stays REACHABLE but keeps rejecting the known-good smoke probe
    /// (a hijacking / captive / stale resolver) is restart-worthy even when the generic
    /// smoke-failure streak above can't accumulate: on a churny roaming network that
    /// streak is repeatedly reset to 1 (network-change recovery, the device-DNS
    /// settle/recapture churn, a momentary accept) before reaching the threshold, so a
    /// steadily-bad resolver never escalated and recovery — including the encrypted
    /// fallback, which is gated on the same wedge marker — stayed dark (UR-37 / LAV-87).
    /// `consecutiveRejectedSmokeResponseCount` is resolver-identity-scoped and is kept out
    /// of those reset paths (cleared only by a genuine primary success or a resolver
    /// change), so the same resolver rejecting `reconnectFailureThreshold` times escalates.
    /// Reuses `hasUncoveredFailedSmokeProbe` so all the freshness / primary-success /
    /// fallback-coverage guards (and the honesty floor) still apply.
    private static func hasSustainedRejectedSmokeResponse(_ health: TunnelHealthSnapshot) -> Bool {
        // Keyed on the DURABLE, resolver-identity-scoped rejected counter ALONE — deliberately
        // NOT also on `lastFailureReason == "rejected-response"`. The counter is bumped only by
        // genuine `rejected-response` ticks and cleared only by an accepted primary smoke probe or
        // a resolver-identity change, so `>= reconnectFailureThreshold` already means "this
        // resolver is durably rejecting"; it can never double as a lower-threshold trigger for
        // timeout / send-failed (those never bump it). Requiring the VOLATILE latest reason to
        // ALSO be `rejected-response` was the LAV-87 escalation gap: on a churny roaming network a
        // hijacker's generic smoke/upstream streaks reset below threshold and the latest tick's
        // reason flips to a transient (receive-failed) or is nilled by a fallback-carried success,
        // so a steadily-rejecting resolver stopped re-escalating here even though the durable
        // evidence was intact. `hasUncoveredFailedSmokeProbe` still applies every freshness /
        // primary-success / reason-class guard (it de-escalates the instant a postdating
        // `lastPrimaryUpstreamSuccessAt` lands), and the encrypted-fallback coverage path declines
        // whenever this counter is nonzero — so escalating here never bypasses a live coverage.
        hasUncoveredFailedSmokeProbe(health)
            && health.consecutiveRejectedSmokeResponseCount >= reconnectFailureThreshold
    }

    /// A current smoke-probe failure that real traffic / device-DNS fallback hasn't
    /// already covered — the shared predicate behind both the `.recovering` honesty
    /// floor and the `.needsReconnect` escalation (which adds the consecutive-failure
    /// threshold on top).
    private static func hasUncoveredFailedSmokeProbe(_ health: TunnelHealthSnapshot) -> Bool {
        // The probe must belong to the current context. Baseline off the network change
        // when there is one, else the runtime reset / session start — on a cold start or
        // right after a self-reconnect `lastNetworkChangeAt` is nil (fresh snapshot), and
        // requiring it would skip both the floor and the escalation, letting fallback
        // traffic paint a failing primary `.healthy`. (Mirrors `isUsingDeviceDNSFallback`'s
        // `lastNetworkChangeAt ?? startedAt` baseline; staleness across a mid-session
        // reset is separately handled by clearing the streak in the recovery reset.)
        let contextBaseline = smokeProbeContextBaseline(health)

        guard let smokeProbeAt = health.lastDNSSmokeProbeAt,
              health.lastDNSSmokeProbeSucceeded == false,
              health.consecutiveDNSSmokeProbeFailureCount >= 1,
              smokeProbeAt >= contextBaseline
        else {
            return false
        }

        if health.deviceDNSFallbackModeActive,
           health.lastFailureReason == nil {
            return false
        }

        if let reason = health.lastFailureReason,
           !restartFailureReasons.contains(reason) {
            return false
        }

        if let fallbackAt = health.lastDeviceDNSFallbackActivatedAt,
           fallbackAt >= smokeProbeAt {
            return false
        }

        // A genuine PRIMARY forwarding success that POSTDATES the failed probe means the
        // configured resolver is working again — don't flag. Must use the primary-only
        // signal: `recordUpstreamResult` bumps `lastUpstreamSuccessAt` for ANY success,
        // including encrypted-fallback and device-DNS-fallback ones, so keying off it
        // would let a fallback-carried query re-mask the wedged primary — the very bug
        // this fixes. `lastPrimaryUpstreamSuccessAt` is set only on a real primary answer.
        if let primarySuccessAt = health.lastPrimaryUpstreamSuccessAt,
           primarySuccessAt >= smokeProbeAt {
            return false
        }

        return true
    }

    /// The instant a failed smoke probe (or a fallback success) must postdate to belong to the
    /// current context — the LATEST context boundary. Shared by the smoke-probe and
    /// encrypted-fallback-coverage checks so they can't drift.
    private static func smokeProbeContextBaseline(_ health: TunnelHealthSnapshot) -> Date {
        // A genuine resolver-IDENTITY change (a different upstream) opens a fresh DNS-health
        // context just like a network change, so take whichever is MORE RECENT — not
        // `lastNetworkChangeAt` alone. Otherwise a resolver switch that postdates the network
        // change would leave the baseline behind, letting a PRE-switch `lastEncryptedFallbackSuccessAt`
        // (or a pre-switch smoke probe) cover/escalate the new resolver's context.
        //
        // Keyed on `lastResolverIdentityChangeAt`, NOT the broad `lastResolverRuntimeResetAt`:
        // the latter is also bumped by SAME-resolver runtime resets (snapshot reloads, pause/resume,
        // recovery), which are NOT health-context changes. Using it would let a benign filter toggle
        // during a covered wedge advance the baseline past the existing failed smoke probe, making the
        // still-wedged primary read as healthy until the next probe — hiding a real outage.
        [health.lastNetworkChangeAt, health.lastResolverIdentityChangeAt]
            .compactMap { $0 }
            .max()
            ?? health.startedAt
    }

    /// True while the ENCRYPTED fallback is carrying DNS for a wedged primary: a REAL carried
    /// encrypted-fallback success that belongs to the current context and has not been
    /// invalidated by a primary recovery, a fresh context, or a sustained carried-query
    /// failure. The counterpart of `isUsingDeviceDNSFallback`, keyed on the per-query
    /// `lastEncryptedFallbackSuccessAt` signal so it reflects DoH/DoT actively serving.
    /// Deliberately has NO wall-clock freshness ceiling — see the body.
    private static func isUsingEncryptedFallback(_ health: TunnelHealthSnapshot, now: Date) -> Bool {
        guard let fallbackAt = health.lastEncryptedFallbackSuccessAt else {
            return false
        }

        // Must belong to the current context (a fallback success from a previous network
        // can't cover a fresh post-handoff staleness).
        guard fallbackAt >= smokeProbeContextBaseline(health) else {
            return false
        }

        // Not future-dated — a backward wall-clock jump must not manufacture coverage.
        guard fallbackAt <= now else {
            return false
        }

        // NO wall-clock freshness ceiling (LAV-96). Coverage holds from the last REAL carried
        // encrypted-fallback success until that success is invalidated. The tunnel nils
        // `lastEncryptedFallbackSuccessAt` on every event that actually ends coverage:
        //   * a primary recovery — a forwarding success OR an accepted primary smoke probe
        //     (recordUpstreamResult / applyResolverSmokeProbeResult),
        //   * a fresh context — any resolver-runtime reset nils it (so a smoke-only recovery,
        //     which never sets lastPrimaryUpstreamSuccessAt, is still caught), and
        //   * a genuinely dead encrypted leg — a SUSTAINED carried-query failure streak
        //     (consecutiveCarriedQueryFailureCount >= encryptedFallbackCoverageClearFailureThreshold)
        //     nils it once DoH/DoT actually stops resolving real traffic.
        // So a non-nil, in-context, not-future timestamp here always reflects the fallback
        // serving the CURRENT wedge.
        //
        // The previous 60s freshness ceiling ALSO lapsed coverage on a QUIET window with no
        // failing traffic. An idle tunnel's only activity is the synthetic primary recapture
        // probe, which never refreshes this per-query timestamp, so on a permanently-unreachable
        // primary (a stale LAN resolver, device-DNS fallback disabled) the accumulated
        // smoke-failure streak went "uncovered" after 60s and manufactured a futile, user-visible
        // self-reconnect that re-captured the SAME unreachable resolver and recovered nothing
        // (LAV-96). Idle is not failure: with no carried query failing there is no user impact,
        // and the instant traffic resumes against a dead leg the carried-failure streak nils the
        // timestamp and the restart fires (fail-closed preserved — locked by
        // testNoEncryptedFallbackSignalLeavesReconnectUnchanged).
        //
        // COUPLING (LAV-93): this trusts `lastEncryptedFallbackSuccessAt` to mean "a real client
        // query was just carried over the encrypted leg." A future warm-DoH keepalive must NEVER
        // stamp this timestamp — only a genuine carried query may — or a dead-everything tunnel
        // whose keepalive still completed a TLS handshake would stay falsely covered and never
        // fail closed.
        return true
    }

    /// `isEncryptedFallbackCoveringWedge` WITHOUT its `rejected == 0` gate: a current UNCOVERED
    /// failed smoke probe that the encrypted fallback is carrying, regardless of rejection evidence.
    /// Exposed for the tunnel's covered-recapture loop RE-ARM only. The gated covering predicate
    /// flips false on a single rejected recapture probe, and a covered wedge stamps no reconnect
    /// marker, so both re-arm gates died and the loop stalled until the 300s routine probe; this
    /// keeps it alive so the rejection streak climbs to the escalation threshold (or the primary
    /// recovers) promptly. It STILL requires a failed smoke-probe context (`hasUncoveredFailedSmokeProbe`),
    /// so a one-off fallback-carried query with no failed probe does NOT trip recovery. It does NOT
    /// suppress reconnect or change escalation — those still use the gated `isEncryptedFallbackCoveringWedge`.
    public static func isEncryptedFallbackCarryingWedge(health: TunnelHealthSnapshot, now: Date = Date()) -> Bool {
        hasUncoveredFailedSmokeProbe(health) && isUsingEncryptedFallback(health, now: now)
    }

    /// True while the encrypted (DoH/DoT) fallback is actively carrying DNS for a transition-stale
    /// primary — the exact condition `assessment(…)` surfaces as `.usingEncryptedFallback`. Exposed
    /// so the tunnel's accelerated covered-recapture probe can read the coverage BIT directly,
    /// instead of recomputing the full assessment and string-matching its severity. This forwards to
    /// the single private predicate (also used by `assessment` / `hasCurrentRestartWorthyFailure`),
    /// so the tunnel and the policy can never disagree about coverage. It is the coverage bit ONLY —
    /// it does NOT imply `primaryAction == .turnOff` or any other assessment branch.
    public static func isEncryptedFallbackCoveringWedge(health: TunnelHealthSnapshot, now: Date = Date()) -> Bool {
        encryptedFallbackCoversFailedProbe(health, now: now)
    }

    /// The encrypted fallback covers the current failed primary probe — used both to
    /// SUPPRESS the self-reconnect and to SURFACE `.usingEncryptedFallback`. Requires a
    /// current uncovered failed probe whose reason is a transition staleness (never
    /// `rejected-response`), no durable hijack evidence, and the fallback actively serving.
    private static func encryptedFallbackCoversFailedProbe(_ health: TunnelHealthSnapshot, now: Date) -> Bool {
        guard hasUncoveredFailedSmokeProbe(health) else {
            return false
        }

        // Never cover while there is ANY pending rejection evidence from the current resolver.
        // The rejected streak is DURABLE and identity-scoped (cleared only by an accepted primary
        // smoke probe or a resolver-identity change), so a NONZERO count means the resolver is
        // reachable-but-rejecting and must NOT be masked by fallback traffic — regardless of
        // whether THIS tick's reason is the rejection itself, a transient (receive-failed/timeout),
        // or nil (cleared by the fallback-carried success that stamped the timestamp). A single
        // rejection BELOW the durable hijack threshold still counts: if the transient probe that
        // crosses the smoke-reconnect threshold rode in on top of an unresolved rejection, the
        // pre-change code would have fired `.needsReconnect`, so coverage here must not suppress it.
        // This one guard subsumes the confirmed-hijack (streak ≥ threshold) and cleared-reason
        // cases — it is the single rejection gate for the coverage path. It does NOT newly ESCALATE
        // the churn-pinned-hijack case (that gap lives in `hasCurrentRestartWorthyFailure` above and
        // is independent of this path).
        guard health.consecutiveRejectedSmokeResponseCount == 0 else {
            return false
        }

        // Cover transition-staleness reasons; `rejected-response` is excluded so a reachable-but-
        // rejecting resolver is never masked. (A `rejected-response` tick always bumps the streak,
        // so it is already declined above; this stays as explicit intent.) A nil reason — the
        // fallback-carried success that stamped the timestamp cleared it — is admitted, since the
        // rejection gate above already excludes a rejecting resolver.
        if let reason = health.lastFailureReason {
            guard encryptedFallbackCoverableReasons.contains(reason) else {
                return false
            }
        }

        return isUsingEncryptedFallback(health, now: now)
    }

    private static func isUsingDeviceDNSFallback(_ health: TunnelHealthSnapshot) -> Bool {
        guard health.deviceDNSFallbackModeActive else {
            return false
        }

        guard let fallbackAt = health.lastDeviceDNSFallbackActivatedAt else {
            return false
        }

        let fallbackBaseline = health.lastNetworkChangeAt ?? health.startedAt
        guard fallbackAt >= fallbackBaseline else {
            return false
        }

        if let failureAt = health.lastUpstreamFailureAt,
           let successAt = health.lastUpstreamSuccessAt,
           failureAt > successAt {
            return false
        }

        return true
    }

    private static func isRecoveringFromRecentNetworkChange(
        _ health: TunnelHealthSnapshot,
        now: Date
    ) -> Bool {
        guard let networkChangeAt = health.lastNetworkChangeAt,
              let resetAt = health.lastResolverRuntimeResetAt,
              resetAt >= networkChangeAt,
              now.timeIntervalSince(resetAt) <= freshRecoveryWindow
        else {
            return false
        }

        if let successAt = health.lastUpstreamSuccessAt, successAt >= resetAt {
            return false
        }

        return true
    }
}
