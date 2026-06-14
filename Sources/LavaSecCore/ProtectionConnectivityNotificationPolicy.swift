import Foundation

public enum ProtectionConnectivityNotificationKind: String, Equatable, Sendable {
    case deviceDNSFallback = "device-dns-fallback"
    case networkUnavailable = "network-unavailable"
    case reconnectNeeded = "reconnect-needed"
    case reconnected

    public var isProblem: Bool {
        switch self {
        case .deviceDNSFallback, .networkUnavailable, .reconnectNeeded:
            return true
        case .reconnected:
            return false
        }
    }
}

public struct ProtectionConnectivityNotification: Equatable, Sendable {
    public let kind: ProtectionConnectivityNotificationKind
    public let identifier: String
    public let title: String
    public let body: String
    public let supersededNotificationIdentifiers: [String]

    public init(
        kind: ProtectionConnectivityNotificationKind,
        identifier: String,
        title: String,
        body: String,
        supersededNotificationIdentifiers: [String] = []
    ) {
        self.kind = kind
        self.identifier = identifier
        self.title = title
        self.body = body
        self.supersededNotificationIdentifiers = supersededNotificationIdentifiers
    }
}

public struct ProtectionConnectivityNotificationHistory: Equatable, Sendable {
    public static let empty = ProtectionConnectivityNotificationHistory()

    public let lastDeliveredNotificationID: String?
    public let lastDeliveredAt: Date?
    public let unresolvedProblemNotificationID: String?
    public let unresolvedProblemKind: ProtectionConnectivityNotificationKind?

    public init(
        lastDeliveredNotificationID: String? = nil,
        lastDeliveredAt: Date? = nil,
        unresolvedProblemNotificationID: String? = nil,
        unresolvedProblemKind: ProtectionConnectivityNotificationKind? = nil
    ) {
        self.lastDeliveredNotificationID = lastDeliveredNotificationID
        self.lastDeliveredAt = lastDeliveredAt
        self.unresolvedProblemNotificationID = unresolvedProblemNotificationID
        self.unresolvedProblemKind = unresolvedProblemKind
    }
}

public enum ProtectionConnectivityNotificationPolicy {
    public static let freshnessWindow: TimeInterval = 120
    public static let minimumProblemDeliveryInterval: TimeInterval = 600

    public static func notification(
        for assessment: ProtectionConnectivityAssessment,
        health: TunnelHealthSnapshot,
        history: ProtectionConnectivityNotificationHistory,
        now: Date = Date()
    ) -> ProtectionConnectivityNotification? {
        let candidate: (kind: ProtectionConnectivityNotificationKind, eventAt: Date?, title: String, body: String)?

        switch assessment.severity {
        case .usingDeviceDNSFallback:
            candidate = (
                .deviceDNSFallback,
                health.lastDeviceDNSFallbackActivatedAt,
                "Lava switched to Device DNS",
                "Network DNS rules changed. Filtering is still on."
            )
        case .networkUnavailable:
            candidate = (
                .networkUnavailable,
                health.lastNetworkChangeAt ?? health.updatedAt,
                "Lava needs a network",
                "No internet path is available. Lava will resume when the network returns."
            )
        case .needsReconnect:
            candidate = (
                .reconnectNeeded,
                health.lastDNSSmokeProbeAt ?? health.lastUpstreamFailureAt,
                "Reconnect Lava",
                "DNS is not resolving on this network. Tap to reconnect protection."
            )
        case .dnsSlow:
            candidate = (
                .reconnectNeeded,
                health.lastSlowUpstreamResponseAt,
                "Lava DNS is slow",
                "The selected DNS resolver is responding slowly. Tap to reconnect protection."
            )
        case .healthy, .recovering:
            candidate = nil
        }

        guard let candidate,
              let eventAt = candidate.eventAt,
              now.timeIntervalSince(eventAt) <= freshnessWindow
        else {
            return nil
        }

        let identifier = "\(candidate.kind.rawValue):\(Int(eventAt.timeIntervalSince1970))"
        guard identifier != history.lastDeliveredNotificationID,
              history.unresolvedProblemNotificationID == nil,
              canDeliver(after: history.lastDeliveredAt, now: now, interval: minimumProblemDeliveryInterval)
        else {
            return nil
        }

        return ProtectionConnectivityNotification(
            kind: candidate.kind,
            identifier: identifier,
            title: candidate.title,
            body: candidate.body
        )
    }

    public static func resolvedProblemNotificationIdentifiers(
        for assessment: ProtectionConnectivityAssessment,
        health: TunnelHealthSnapshot,
        history: ProtectionConnectivityNotificationHistory,
        now: Date = Date()
    ) -> [String] {
        guard let unresolvedProblemNotificationID = resolvedProblemNotificationID(
            for: assessment,
            health: health,
            history: history,
            now: now
        ) else {
            return []
        }

        return [unresolvedProblemNotificationID]
    }

    private static func resolvedProblemNotificationID(
        for assessment: ProtectionConnectivityAssessment,
        health: TunnelHealthSnapshot,
        history: ProtectionConnectivityNotificationHistory,
        now: Date
    ) -> String? {
        guard canAcknowledgeRecovery(for: assessment.severity),
              let unresolvedProblemNotificationID = history.unresolvedProblemNotificationID,
              history.unresolvedProblemKind?.isProblem == true,
              let eventAt = recoveryEventAt(from: health),
              now.timeIntervalSince(eventAt) <= freshnessWindow
        else {
            return nil
        }

        let identifier = "reconnected:\(unresolvedProblemNotificationID)"
        guard identifier != history.lastDeliveredNotificationID else {
            return nil
        }

        return unresolvedProblemNotificationID
    }

    private static func canAcknowledgeRecovery(for severity: ProtectionConnectivitySeverity) -> Bool {
        switch severity {
        case .healthy:
            return true
        case .recovering, .usingDeviceDNSFallback, .dnsSlow, .networkUnavailable, .needsReconnect:
            return false
        }
    }

    private static func recoveryEventAt(from health: TunnelHealthSnapshot) -> Date? {
        var candidates = [Date]()
        if health.lastDNSSmokeProbeSucceeded == true,
           let lastDNSSmokeProbeAt = health.lastDNSSmokeProbeAt {
            candidates.append(lastDNSSmokeProbeAt)
        }

        if let lastUpstreamSuccessAt = health.lastUpstreamSuccessAt {
            candidates.append(lastUpstreamSuccessAt)
        }

        return candidates.max()
    }

    private static func canDeliver(after lastDeliveredAt: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastDeliveredAt else {
            return true
        }

        return now.timeIntervalSince(lastDeliveredAt) >= interval
    }
}
