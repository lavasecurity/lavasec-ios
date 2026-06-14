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

public struct ProtectionConnectivityAssessment: Equatable, Sendable {
    public let severity: ProtectionConnectivitySeverity
    public let primaryAction: ProtectionConnectivityAction
    public let title: String
    public let subtitle: String

    public init(
        severity: ProtectionConnectivitySeverity,
        primaryAction: ProtectionConnectivityAction,
        title: String,
        subtitle: String
    ) {
        self.severity = severity
        self.primaryAction = primaryAction
        self.title = title
        self.subtitle = subtitle
    }
}

public enum ProtectionConnectivityPolicy {
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
        "socket-unavailable"
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
            return ProtectionConnectivityAssessment(
                severity: .networkUnavailable,
                primaryAction: .turnOff,
                title: "Network Lost",
                subtitle: "No internet path is available. Lava will resume when the network returns."
            )
        }

        if hasCurrentRestartWorthyFailure(health) {
            return ProtectionConnectivityAssessment(
                severity: .needsReconnect,
                primaryAction: .reconnect,
                title: "Reconnect Needed",
                subtitle: "Lava cannot reach the DNS. Check your network condition and reconnect."
            )
        }

        if isUsingDeviceDNSFallback(health) {
            return ProtectionConnectivityAssessment(
                severity: .usingDeviceDNSFallback,
                primaryAction: .turnOff,
                title: "Protected",
                subtitle: "Filtering is on with Device DNS fallback because the selected DNS resolver is unavailable"
            )
        }

        if hasCurrentSlowDNS(health) {
            return ProtectionConnectivityAssessment(
                severity: .dnsSlow,
                primaryAction: .reconnect,
                title: "DNS Slow",
                subtitle: "The selected DNS resolver is responding slowly. Reconnect or switch resolver."
            )
        }

        if isRecoveringFromRecentNetworkChange(health, now: now) {
            return ProtectionConnectivityAssessment(
                severity: .recovering,
                primaryAction: .turnOff,
                title: "Reconnecting",
                subtitle: "Connection changed, refreshing DNS protection"
            )
        }

        return healthyAssessment
    }

    private static var healthyAssessment: ProtectionConnectivityAssessment {
        ProtectionConnectivityAssessment(
            severity: .healthy,
            primaryAction: .turnOff,
            title: "Protected",
            subtitle: "Filtering happens locally on this phone"
        )
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
