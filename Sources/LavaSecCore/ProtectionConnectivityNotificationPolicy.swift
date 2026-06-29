import Foundation

public enum ProtectionConnectivityNotificationKind: String, Equatable, Sendable {
    case deviceDNSFallback = "device-dns-fallback"
    case networkUnavailable = "network-unavailable"
    case dnsSlow = "dns-slow"
    case reconnectNeeded = "reconnect-needed"

    /// Every notification kind is a "problem" (we only ever notify about problems
    /// now; a recovery clears the standing banner silently rather than posting an
    /// acknowledgement). Kept as a property so the escalation/clear logic reads
    /// intent-fully and to leave room for a future non-problem kind.
    public var isProblem: Bool {
        switch self {
        case .deviceDNSFallback, .networkUnavailable, .dnsSlow, .reconnectNeeded:
            return true
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
    /// After the encrypted-fallback coverage silently clears a `reconnectNeeded` banner, the
    /// delivery cooldown is back-dated so a lapse re-posts after this grace rather than the full
    /// 600s — short enough that a genuine uncovered wedge re-notifies promptly, long enough that a
    /// flapping cover<->uncover wedge is bounded to one banner per grace instead of one per lapse.
    public static let reFlapGraceInterval: TimeInterval = 60

    public static func notification(
        for assessment: ProtectionConnectivityAssessment,
        health: TunnelHealthSnapshot,
        history: ProtectionConnectivityNotificationHistory,
        now: Date = Date()
    ) -> ProtectionConnectivityNotification? {
        // We only push a NOTIFICATION when Lava needs the user to act — the two
        // "Tap to reconnect" banners (`reconnectNeeded`, `dnsSlow`). Everything
        // else is handled silently: a self-recovery clears the standing banner
        // (see `resolvedProblemNotificationIdentifiers`) WITHOUT a "reconnected"
        // ping, and the informational states (`usingDeviceDNSFallback`,
        // `networkUnavailable`) still drive the in-app Guard UI / Live Activity but
        // post no banner. This keeps Notification Center from filling with
        // self-resolving "reconnected" / "switched to Device DNS" noise on flaky
        // networks — the user is interrupted only when a tap is genuinely required.

        let candidate: (kind: ProtectionConnectivityNotificationKind, eventAt: Date?, title: String, body: String)?

        switch assessment.severity {
        case .usingDeviceDNSFallback, .networkUnavailable:
            // Informational, non-actionable — Lava keeps filtering (Device DNS) or
            // will auto-resume (no network). Surfaced in-app, not as a notification.
            candidate = nil
        case .needsReconnect:
            candidate = (
                .reconnectNeeded,
                health.lastDNSSmokeProbeAt ?? health.lastUpstreamFailureAt,
                // Localized against the package catalog (Bundle.module) — these post from the app AND the NE
                // tunnel, whose bundles lack the app's string catalog.
                String(localized: "notif.body.reconnectTitle", bundle: .module),
                String(localized: "notif.body.reconnectMessage", bundle: .module)
            )
        case .dnsSlow:
            candidate = (
                .dnsSlow,
                health.lastSlowUpstreamResponseAt,
                String(localized: "notif.body.dnsSlowTitle", bundle: .module),
                String(localized: "notif.body.dnsSlowMessage", bundle: .module)
            )
        case .healthy, .recovering, .usingEncryptedFallback:
            // No banner for the encrypted-fallback handoff: it is brief and self-recovering
            // (DNS stays up via DoH while the primary un-masks), so a notification would be
            // noise — the very disruption this state exists to avoid.
            candidate = nil
        }

        guard let candidate,
              let eventAt = candidate.eventAt,
              now.timeIntervalSince(eventAt) <= freshnessWindow
        else {
            return nil
        }

        let identifier = "\(candidate.kind.rawValue):\(Int(eventAt.timeIntervalSince1970))"

        // Never re-emit the exact notification we last delivered.
        guard identifier != history.lastDeliveredNotificationID else {
            return nil
        }

        // Escalation: a strictly more-urgent problem supersedes a lower-ranked banner
        // that's still outstanding, bypassing both the "a problem is already outstanding"
        // guard and the min-delivery throttle. Without this, a wedge that follows a
        // Device-DNS fallback leaves the user staring at a reassuring "switched to Device
        // DNS — filtering on" banner while DNS is actually down, never surfacing the
        // actionable "Reconnect" prompt for up to the full 600s cooldown.
        //
        // Only a real reconnect-needed outage (`reconnectNeeded`) outranks the rest.
        // `deviceDNSFallback`, `networkUnavailable`, and the soft `dnsSlow` degradation
        // are equal-rank peers that never supersede one another — none warrants stealing
        // a standing banner. Crucially `dnsSlow` is a distinct kind from `reconnectNeeded`
        // (the slow-DNS severity used to reuse `reconnectNeeded`), so when DNS progresses
        // from slow to a hard outage the `reconnectNeeded` candidate genuinely outranks
        // the outstanding `dnsSlow` banner and upgrades the user from "DNS is slow" to the
        // actionable "Reconnect" copy. Escalation is upward-only and the ladder has a
        // single step, so at most one supersede per problem episode — no flapping spam,
        // and the recovery path still clears whatever ends up outstanding.
        if let outstandingKind = history.unresolvedProblemKind,
           let outstandingID = history.unresolvedProblemNotificationID,
           problemRank(candidate.kind) > problemRank(outstandingKind) {
            return ProtectionConnectivityNotification(
                kind: candidate.kind,
                identifier: identifier,
                title: candidate.title,
                body: candidate.body,
                supersededNotificationIdentifiers: [outstandingID]
            )
        }

        guard history.unresolvedProblemNotificationID == nil,
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

    /// Relative urgency of a problem notification. A strictly higher rank may supersede a
    /// lower-ranked outstanding banner (see `notification(for:…)`). The informational
    /// `deviceDNSFallback`/`networkUnavailable` kinds no longer post, so a marker for one
    /// can only be a STALE leftover that survived an upgrade — rank them at 0, BELOW every
    /// actionable banner, so ANY real banner (the soft `dnsSlow` or a hard `reconnectNeeded`)
    /// supersedes the leftover instead of being suppressed by it. The two actionable banners
    /// ladder above: `dnsSlow` (1) for the soft degradation, `reconnectNeeded` (2) for a hard
    /// outage (which also supersedes an outstanding `dnsSlow`).
    private static func problemRank(_ kind: ProtectionConnectivityNotificationKind) -> Int {
        switch kind {
        case .deviceDNSFallback, .networkUnavailable:
            return 0
        case .dnsSlow:
            return 1
        case .reconnectNeeded:
            return 2
        }
    }

    public static func resolvedProblemNotificationIdentifiers(
        for assessment: ProtectionConnectivityAssessment,
        health: TunnelHealthSnapshot,
        history: ProtectionConnectivityNotificationHistory,
        now: Date = Date()
    ) -> [String] {
        if let unresolvedProblemNotificationID = resolvedProblemNotificationID(
            for: assessment,
            health: health,
            history: history,
            now: now
        ) {
            return [unresolvedProblemNotificationID]
        }

        // Silently supersede whatever single problem banner is outstanding once the encrypted
        // fallback covers the wedge. These appear in the rough-handoff edge case (a banner was
        // delivered before coverage engaged — e.g. DoH was slow enough that the smoke streak
        // crossed the reconnect threshold, or DNS was flagged slow first); leaving ANY of them
        // standing is HARMFUL, not merely cosmetic — tapping a Lava notification routes through
        // `performProtectionPrimaryAction`, which keys off the CURRENT assessment, and
        // `.usingEncryptedFallback` is `.turnOff`, so following a stale "Tap to reconnect" prompt
        // (or even an informational banner) would turn protection OFF. So clear it silently
        // (no acknowledgement is ever posted — recoveries clear the banner quietly).
        // The matching cooldown handling lives in `deliveryCooldownAnchorAfterClear`, which
        // back-dates `lastDeliveredAt` so a lapse back to a real problem re-posts promptly (no
        // 600s gap) while a sustained cover<->uncover flap is bounded to one banner per
        // `reFlapGraceInterval`.
        if let silentlyClearedID = encryptedFallbackSilentlyClearedProblemID(
            for: assessment,
            history: history
        ) {
            return [silentlyClearedID]
        }

        return []
    }

    /// The outstanding PROBLEM notification id that the encrypted-fallback coverage silently
    /// supersedes, or nil when this is not that case. NOT limited to `reconnectNeeded`: during
    /// `.usingEncryptedFallback` the covered state is silent (it posts no banner of its own), yet
    /// EVERY Lava notification tap routes through `performProtectionPrimaryAction`, whose action
    /// is now `.turnOff` — so ANY problem banner left standing turns protection OFF if tapped.
    /// That includes the actionable `reconnectNeeded`/`dnsSlow` "Tap to reconnect" prompts AND a
    /// stale informational `deviceDNSFallback`/`networkUnavailable` one. Clear whichever single
    /// problem is outstanding. Shared by `resolvedProblemNotificationIdentifiers` (what to clear)
    /// and `deliveryCooldownAnchorAfterClear` (whether to lift the cooldown) so the two can't drift.
    private static func encryptedFallbackSilentlyClearedProblemID(
        for assessment: ProtectionConnectivityAssessment,
        history: ProtectionConnectivityNotificationHistory
    ) -> String? {
        guard assessment.severity == .usingEncryptedFallback,
              history.unresolvedProblemKind?.isProblem == true,
              let outstandingProblemID = history.unresolvedProblemNotificationID
        else {
            return nil
        }
        return outstandingProblemID
    }

    /// When a clear is the encrypted-fallback silent-supersede (NOT a real `.healthy` recovery),
    /// the consumer should back-date `lastDeliveredAt` to THIS value so the 600s problem cooldown
    /// no longer blocks the next `reconnectNeeded` if coverage lapses — but only after a
    /// `reFlapGraceInterval` grace, which bounds a flapping wedge to one banner per grace. Returns
    /// nil for every other clear (a real recovery keeps its anti-flap cooldown intact).
    public static func deliveryCooldownAnchorAfterClear(
        for assessment: ProtectionConnectivityAssessment,
        history: ProtectionConnectivityNotificationHistory,
        now: Date = Date()
    ) -> Date? {
        guard encryptedFallbackSilentlyClearedProblemID(for: assessment, history: history) != nil else {
            return nil
        }
        return now.addingTimeInterval(-(minimumProblemDeliveryInterval - reFlapGraceInterval))
    }

    /// The outstanding actionable-problem notification id that a real recovery
    /// silently clears, or nil when this is not an acknowledgeable recovery. The
    /// clear is naturally once-per-episode: clearing wipes the marker, so the next
    /// pass sees `unresolvedProblemNotificationID == nil` and returns nil.
    private static func resolvedProblemNotificationID(
        for assessment: ProtectionConnectivityAssessment,
        health: TunnelHealthSnapshot,
        history: ProtectionConnectivityNotificationHistory,
        now: Date
    ) -> String? {
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
              // the banner. Must reach the threshold derived from the problem's
              // encoded event time.
              let recoveryThreshold = recoveryThresholdAfterProblem(unresolvedProblemNotificationID),
              recoveredAt >= recoveryThreshold
        else {
            return nil
        }

        return unresolvedProblemNotificationID
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
        case .recovering, .usingDeviceDNSFallback, .usingEncryptedFallback, .dnsSlow, .networkUnavailable, .needsReconnect:
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
        //     yet routing through the (e.g. just-restarted) tunnel, so clearing the
        //     "reconnect" banner on it would drop the warning while the user is still
        //     offline (the observed "said recovered but I still had to toggle" case).
        //   * Encrypted Device-DNS fallback successes — those mean the safety net
        //     caught the query while the primary resolver is still wedged. Treating
        //     them as recovery would clear the banner even though every subsequent
        //     query still depends on the fallback. The tunnel records those under
        //     `lastUpstreamSuccessAt` but NOT under `lastPrimaryUpstreamSuccessAt`, so
        //     keying off the latter holds the warning until the primary is healthy again.
        //
        // Gating the banner-clear on real primary traffic keeps the user-facing state honest.
        health.lastPrimaryUpstreamSuccessAt
    }

    private static func canDeliver(after lastDeliveredAt: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastDeliveredAt else {
            return true
        }

        return now.timeIntervalSince(lastDeliveredAt) >= interval
    }
}

/// Persistence-layer migration for the connectivity-notification policy. Lives next to
/// the policy because it exists only to keep persisted history compatible with changes
/// to the notification-kind vocabulary.
public enum ProtectionConnectivityNotificationStore {
    /// Bump when a change to the persisted notification-kind vocabulary can wedge the
    /// escalation logic against state written by an older build.
    public static let currentKindSchemaVersion = 2

    /// The defaults keys the migration touches. Injected by the app-group layer (which
    /// owns the literal key strings) so the migration stays unit-testable in the package.
    public struct DefaultsKeys: Sendable {
        public let schemaVersion: String
        public let unresolvedProblemKind: String

        public init(schemaVersion: String, unresolvedProblemKind: String) {
            self.schemaVersion = schemaVersion
            self.unresolvedProblemKind = unresolvedProblemKind
        }
    }

    /// One-time, version-gated migration of the outstanding-problem marker.
    ///
    /// Builds before schema v2 delivered the slow-DNS severity under the `.reconnectNeeded`
    /// kind. A slow-DNS banner left outstanding across an upgrade is therefore
    /// indistinguishable from a real reconnect banner, so the new escalation can't
    /// supersede it (same kind/rank) and the user stays on "DNS is slow" during a hard
    /// outage. Rather than erase the marker — which would rob recovery of the id it needs
    /// to silently clear the delivered banner on the first healthy pass
    /// — *demote* an outstanding `reconnect-needed` marker to the new `.dnsSlow` kind. The
    /// id is preserved, so recovery still works; and because `dnsSlow` now ranks below a
    /// real outage, a genuine `needsReconnect` can supersede it (bypassing the throttle).
    /// Safe regardless of the legacy marker's true origin: a mis-demoted genuine reconnect
    /// is simply re-posted once by the next hard-outage tick (same "Reconnect" copy) and
    /// then re-recorded under the correct kind. Other kinds were unaffected by the
    /// vocabulary change and are left untouched. Returns whether a migration ran.
    @discardableResult
    public static func migrateLegacyKindSchemaIfNeeded(
        in defaults: UserDefaults,
        keys: DefaultsKeys
    ) -> Bool {
        guard defaults.integer(forKey: keys.schemaVersion) < currentKindSchemaVersion else {
            return false
        }

        if defaults.string(forKey: keys.unresolvedProblemKind)
            == ProtectionConnectivityNotificationKind.reconnectNeeded.rawValue {
            defaults.set(
                ProtectionConnectivityNotificationKind.dnsSlow.rawValue,
                forKey: keys.unresolvedProblemKind
            )
        }
        defaults.set(currentKindSchemaVersion, forKey: keys.schemaVersion)
        return true
    }
}
