import Foundation

public enum ProtectionConnectivitySeverity: Equatable, Sendable {
    case healthy
    case recovering
    case usingDeviceDNSFallback
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
        case .healthy:                "healthy"
        case .recovering:             "recovering"
        case .usingDeviceDNSFallback: "device-dns-fallback"
        case .dnsSlow:                "dns-slow"
        case .networkUnavailable:     "network-unavailable"
        case .needsReconnect:         "needs-reconnect"
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

        if hasCurrentRestartWorthyFailure(health) {
            return ProtectionConnectivityAssessment(severity: .needsReconnect, primaryAction: .reconnect)
        }

        if isUsingDeviceDNSFallback(health) {
            return ProtectionConnectivityAssessment(severity: .usingDeviceDNSFallback, primaryAction: .turnOff)
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

    private static func hasCurrentRestartWorthyFailure(_ health: TunnelHealthSnapshot) -> Bool {
        if hasRecentFailedSmokeProbeWithoutFallback(health) {
            return true
        }

        if hasSustainedRejectedSmokeResponse(health) {
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
        // `hasUncoveredFailedSmokeProbe` only requires the reason to be in
        // `restartFailureReasons` (which includes several classes); tighten to
        // `rejected-response` specifically so this path is keyed to the rejected counter
        // and never doubles as a lower-threshold trigger for timeout / send-failed / etc.
        hasUncoveredFailedSmokeProbe(health)
            && health.lastFailureReason == "rejected-response"
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
        let contextBaseline = health.lastNetworkChangeAt
            ?? health.lastResolverRuntimeResetAt
            ?? health.startedAt

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
