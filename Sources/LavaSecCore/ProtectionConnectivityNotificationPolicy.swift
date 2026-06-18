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
        // Positive recovery confirmation: when a problem we actually notified the
        // user about clears, acknowledge it once. Gated on a delivered problem
        // (unresolvedProblem* in history) so an auto-recovery the user never saw a
        // warning for stays silent — this only fires after a "needs reconnect"
        // (or fallback / no-network) banner, so the user who saw the warning learns
        // it's back without manually toggling.
        if let acknowledgement = reconnectedAcknowledgement(
            for: assessment,
            health: health,
            history: history,
            now: now
        ) {
            return acknowledgement
        }

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
        acknowledgeableRecovery(for: assessment, health: health, history: history, now: now)?.problemID
    }

    /// Builds the positive "reconnected" confirmation for a recovery the user was
    /// warned about. Same gating as the silent banner-clear (`resolvedProblemNotificationID`);
    /// the two run together so the problem banner is removed and the confirmation posted.
    private static func reconnectedAcknowledgement(
        for assessment: ProtectionConnectivityAssessment,
        health: TunnelHealthSnapshot,
        history: ProtectionConnectivityNotificationHistory,
        now: Date
    ) -> ProtectionConnectivityNotification? {
        guard let recovery = acknowledgeableRecovery(
            for: assessment,
            health: health,
            history: history,
            now: now
        ) else {
            return nil
        }

        return ProtectionConnectivityNotification(
            kind: .reconnected,
            identifier: recovery.identifier,
            title: "Lava reconnected",
            body: "DNS is resolving again — protection is back on.",
            supersededNotificationIdentifiers: [recovery.problemID]
        )
    }

    private static func acknowledgeableRecovery(
        for assessment: ProtectionConnectivityAssessment,
        health: TunnelHealthSnapshot,
        history: ProtectionConnectivityNotificationHistory,
        now: Date
    ) -> (problemID: String, identifier: String)? {
        guard canAcknowledgeRecovery(for: assessment.severity),
              let unresolvedProblemNotificationID = history.unresolvedProblemNotificationID,
              history.unresolvedProblemKind?.isProblem == true,
              let recoveredAt = recoveryEventAt(from: health),
              now.timeIntervalSince(recoveredAt) <= freshnessWindow,
              // The real-forwarding success must POSTDATE the problem we warned about.
              // A client query that succeeded shortly *before* the outage can still be
              // inside the freshness window, so without this a smoke-probe-only
              // recovery (which clears the tunnel's failure state without any real
              // downstream traffic) paired with that stale success would falsely clear
              // the banner and post "reconnected". Must reach the threshold derived
              // from the problem's encoded event time.
              let recoveryThreshold = recoveryThresholdAfterProblem(unresolvedProblemNotificationID),
              recoveredAt >= recoveryThreshold
        else {
            return nil
        }

        let identifier = "reconnected:\(unresolvedProblemNotificationID)"
        guard identifier != history.lastDeliveredNotificationID else {
            return nil
        }

        return (unresolvedProblemNotificationID, identifier)
    }

    /// Earliest forwarding-success time that is guaranteed to postdate the problem.
    /// The problem's id encodes `Int(eventAt.timeIntervalSince1970)`, truncated to
    /// the second, so its true time lies in `[epoch, epoch + 1)`. Requiring the
    /// recovery to land at or after the *next* whole second (`epoch + 1`) guarantees
    /// it postdates the real event regardless of the lost sub-second — otherwise a
    /// success earlier in the same second (600.2 vs a 600.8 problem) would slip past.
    private static func recoveryThresholdAfterProblem(_ problemID: String) -> Date? {
        guard let epochField = problemID.split(separator: ":").last,
              let epoch = TimeInterval(epochField)
        else {
            return nil
        }

        return Date(timeIntervalSince1970: epoch + 1)
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
        // Recovery is acknowledged ONLY on a real PRIMARY-upstream forwarding
        // success — an actual client query that resolved through the configured
        // primary resolver (`lastPrimaryUpstreamSuccessAt`).
        //
        // Two signals are deliberately excluded:
        //   * The DNS smoke probe — it validates only the provider→resolver
        //     upstream leg and can report healthy while the device's own DNS isn't
        //     yet routing through the (e.g. just-restarted) tunnel, so acknowledging
        //     on it would clear the "reconnect" banner and claim "you're back" while
        //     the user is still offline (the observed "said recovered but I still had
        //     to toggle" case).
        //   * Encrypted Device-DNS fallback successes — those mean the safety net
        //     caught the query while the primary resolver is still wedged. Treating
        //     them as recovery would clear the banner / post "reconnected" even
        //     though every subsequent query still depends on the fallback. The tunnel
        //     records those under `lastUpstreamSuccessAt` but NOT under
        //     `lastPrimaryUpstreamSuccessAt`, so keying off the latter holds the
        //     warning until the primary itself is healthy again.
        //
        // Gating both the banner-clear and the positive confirmation on real primary
        // traffic keeps the user-facing state honest.
        health.lastPrimaryUpstreamSuccessAt
    }

    private static func canDeliver(after lastDeliveredAt: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastDeliveredAt else {
            return true
        }

        return now.timeIntervalSince(lastDeliveredAt) >= interval
    }
}
