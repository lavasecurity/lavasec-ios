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

        return healthyAssessment
    }

    private static var healthyAssessment: ProtectionConnectivityAssessment {
        ProtectionConnectivityAssessment(severity: .healthy, primaryAction: .turnOff)
    }

    private static func hasCurrentRestartWorthyFailure(_ health: TunnelHealthSnapshot) -> Bool {
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
        guard let smokeProbeAt = health.lastDNSSmokeProbeAt,
              health.lastDNSSmokeProbeSucceeded == false,
              health.consecutiveUpstreamFailureCount >= reconnectFailureThreshold,
              let networkChangeAt = health.lastNetworkChangeAt,
              smokeProbeAt >= networkChangeAt
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

        if let successAt = health.lastUpstreamSuccessAt,
           successAt >= smokeProbeAt {
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
