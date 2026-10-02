import Foundation

public enum ProtectionConnectivityNotificationKind: String, Equatable, Codable, Sendable {
    case deviceDNSFallback = "device-dns-fallback"
    case networkUnavailable = "network-unavailable"
    case dnsSlow = "dns-slow"
    case reconnectNeeded = "reconnect-needed"
    /// Artifact triage identified a necessary user action while client DNS remains blocked.
    case filteringUnavailable = "filtering-unavailable"

    /// Every notification kind is a "problem" (we only ever notify about problems
    /// now; a recovery clears the standing banner silently rather than posting an
    /// acknowledgement). Kept as a property so the escalation/clear logic reads
    /// intent-fully and to leave room for a future non-problem kind.
    public var isProblem: Bool {
        switch self {
        case .deviceDNSFallback, .networkUnavailable, .dnsSlow, .reconnectNeeded, .filteringUnavailable:
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

public struct ProtectionConnectivityNotificationHistory: Equatable, Codable, Sendable {
    public static let empty = ProtectionConnectivityNotificationHistory()

    public let lastDeliveredNotificationID: String?
    public let lastDeliveredAt: Date?
    public let unresolvedProblemNotificationID: String?
    /// Logical incident identity used for recovery timing, separate from the owned OS request.
    public let unresolvedProblemIncidentID: String?
    public let unresolvedProblemKind: ProtectionConnectivityNotificationKind?

    public init(
        lastDeliveredNotificationID: String? = nil,
        lastDeliveredAt: Date? = nil,
        unresolvedProblemNotificationID: String? = nil,
        unresolvedProblemIncidentID: String? = nil,
        unresolvedProblemKind: ProtectionConnectivityNotificationKind? = nil
    ) {
        self.lastDeliveredNotificationID = lastDeliveredNotificationID
        self.lastDeliveredAt = lastDeliveredAt
        self.unresolvedProblemNotificationID = unresolvedProblemNotificationID
        self.unresolvedProblemIncidentID = unresolvedProblemIncidentID
        self.unresolvedProblemKind = unresolvedProblemKind
    }
}

public enum ProtectionConnectivityNotificationPolicy {
    public static let freshnessWindow: TimeInterval = 120
    public static let minimumProblemDeliveryInterval: TimeInterval = 600
    /// Debounces client impact after triage establishes a necessary user action.
    public static let filteringUnavailableGraceInterval: TimeInterval = 30
    /// After the encrypted-fallback coverage silently clears a `reconnectNeeded` banner, the
    /// delivery cooldown is back-dated so a lapse re-posts after this grace rather than the full
    /// 600s — short enough that a genuine uncovered wedge re-notifies promptly, long enough that a
    /// flapping cover<->uncover wedge is bounded to one banner per grace instead of one per lapse.
    public static let reFlapGraceInterval: TimeInterval = 60

    /// Proposes a fresh, deduplicated problem notice. Only the tunnel confirms failed filter recovery; nil is unknown.
    /// `filteringUnavailableSince` is the first blocked client query in that continuous failure window.
    public static func notification(
        for assessment: ProtectionConnectivityAssessment,
        health: TunnelHealthSnapshot,
        history: ProtectionConnectivityNotificationHistory,
        filteringUnavailable: Bool? = nil,
        filteringUnavailableSince: Date? = nil,
        filteringIntervention: FilterArtifactIntervention? = nil,
        now: Date = Date(),
        languageCode: String? = nil
    ) -> ProtectionConnectivityNotification? {
        // Resolver problems and an observed block-all failure share one cooldown and banner.
        // Only the tunnel can assert current filtering posture; historical health is not enough.
        let candidate: (kind: ProtectionConnectivityNotificationKind, eventAt: Date?, title: String, body: String)?

        if filteringUnavailable == true {
            guard let filteringIntervention, let filteringUnavailableSince,
                  now.timeIntervalSince(filteringUnavailableSince) >= filteringUnavailableGraceInterval,
                  health.lastFailClosedReason == "snapshot-unavailable",
                  let lastBlockedAt = health.lastFailClosedAt,
                  lastBlockedAt >= filteringUnavailableSince else { return nil }
            candidate = (
                .filteringUnavailable,
                health.failClosedServedQueryCount > 0 ? health.lastFailClosedAt : nil,
                LavaNotificationLocalizer.string("notif.body.filteringUnavailableTitle", languageCode: languageCode),
                LavaNotificationLocalizer.string(filteringIntervention == .refreshCustomSources
                    ? "notif.body.customFilterRefreshMessage" : "notif.body.filteringUnavailableMessage", languageCode: languageCode)
            )
        } else {
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
                    // tunnel, whose bundles lack the app's string catalog. `languageCode` pins the pinned app
                    // language so the tunnel matches the app UI, not the (possibly different) system language.
                    LavaNotificationLocalizer.string("notif.body.reconnectTitle", languageCode: languageCode),
                    LavaNotificationLocalizer.string("notif.body.reconnectMessage", languageCode: languageCode)
                )
            case .dnsSlow:
                candidate = (
                    .dnsSlow,
                    health.lastSlowUpstreamResponseAt,
                    LavaNotificationLocalizer.string("notif.body.dnsSlowTitle", languageCode: languageCode),
                    LavaNotificationLocalizer.string("notif.body.dnsSlowMessage", languageCode: languageCode)
                )
            case .healthy, .recovering, .usingEncryptedFallback:
                // No banner for the encrypted-fallback handoff: it is brief and self-recovering
                // (DNS stays up via DoH while the primary un-masks), so a notification would be
                // noise — the very disruption this state exists to avoid.
                candidate = nil
            }
        }

        guard let candidate,
              let eventAt = candidate.eventAt,
              now.timeIntervalSince(eventAt) <= freshnessWindow
        else {
            return nil
        }

        let identifier: String
        if candidate.kind == .filteringUnavailable, let filteringUnavailableSince, let filteringIntervention {
            // Client activity proves freshness; the outage start and remedy own pending delivery.
            identifier = "\(candidate.kind.rawValue):\(filteringIntervention.rawValue):\(Int(filteringUnavailableSince.timeIntervalSince1970))"
        } else {
            identifier = "\(candidate.kind.rawValue):\(Int(eventAt.timeIntervalSince1970))"
        }

        // Never re-emit the exact notification we last delivered.
        guard identifier != history.lastDeliveredNotificationID else {
            return nil
        }

        // A harder failure may replace a softer outstanding banner once. Equal-rank
        // repeats remain suppressed; recovery retains the shared anti-flap cooldown.
        if let outstandingKind = history.unresolvedProblemKind,
           let outstandingID = history.unresolvedProblemNotificationID,
           canEscalate(from: outstandingKind, to: candidate.kind) {
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

    /// Whether a more serious incident may replace an outstanding notice or failed retry.
    public static func canEscalate(from outstanding: ProtectionConnectivityNotificationKind,
                                   to candidate: ProtectionConnectivityNotificationKind) -> Bool {
        problemRank(candidate) > problemRank(outstanding)
    }

    /// Escalation order: retired informational kinds, slow DNS, resolver outage, unavailable filter.
    private static func problemRank(_ kind: ProtectionConnectivityNotificationKind) -> Int {
        switch kind {
        case .deviceDNSFallback, .networkUnavailable:
            return 0
        case .dnsSlow:
            return 1
        case .reconnectNeeded:
            return 2
        case .filteringUnavailable:
            return 3
        }
    }

    /// Clears resolver incidents from health evidence, and filter incidents only from explicit current tunnel posture.
    public static func resolvedProblemNotificationIdentifiers(
        for assessment: ProtectionConnectivityAssessment,
        health: TunnelHealthSnapshot,
        history: ProtectionConnectivityNotificationHistory,
        filteringUnavailable: Bool? = nil,
        now: Date = Date()
    ) -> [String] {
        // A healthy resolver cannot prove that filtering recovered. The app leaves this
        // banner alone; the tunnel clears it only after observing usable filtering or a pause.
        if history.unresolvedProblemKind == .filteringUnavailable {
            return filteringUnavailable == false ? history.unresolvedProblemNotificationID.map { [$0] } ?? [] : []
        }
        // Filtering still blocks DNS. Preserve the lower-priority incident so an actionable
        // filter notice can escalate after its grace period instead of inheriting cooldown.
        guard filteringUnavailable != true else { return [] }

        if let unresolvedProblemNotificationID = resolvedProblemNotificationID(
            for: assessment,
            health: health,
            history: history,
            now: now
        ) {
            return [unresolvedProblemNotificationID]
        }

        // Encrypted fallback makes a resolver-problem banner stale. Clear it quietly;
        // notification taps only navigate to Guard and never mutate protection.
        // The shared cooldown helper bounds a subsequent coverage lapse.
        if let silentlyClearedID = encryptedFallbackSilentlyClearedProblemID(
            for: assessment,
            history: history
        ) {
            return [silentlyClearedID]
        }

        return []
    }

    /// Shares resolver-banner cleanup with its cooldown adjustment. Filter failures need
    /// their own current-posture proof and cannot be cleared by resolver fallback coverage.
    private static func encryptedFallbackSilentlyClearedProblemID(
        for assessment: ProtectionConnectivityAssessment,
        history: ProtectionConnectivityNotificationHistory
    ) -> String? {
        guard history.unresolvedProblemKind != .filteringUnavailable,
              assessment.severity == .usingEncryptedFallback,
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
              let recoveryThreshold = recoveryThresholdAfterProblem(history.unresolvedProblemIncidentID ?? unresolvedProblemNotificationID),
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

/// Shared notification history, atomic delivery claims, and migration from legacy defaults.
public enum ProtectionConnectivityNotificationStore {
    /// A scheduling snapshot after atomic recovery cleanup.
    public struct Reconciliation: Sendable {
        /// History used to evaluate this scheduling pass.
        public let history: ProtectionConnectivityNotificationHistory
        /// System request IDs whose problem has recovered.
        public let resolvedIdentifiers: [String]
        /// A candidate that still needs successful submission and a delivery claim.
        public let notification: ProtectionConnectivityNotification?
    }

    /// Outcome of claiming a successfully submitted notification.
    public enum DeliveryClaim: Equatable, Sendable {
        /// This submission owns the banner; these older IDs can be removed.
        case recorded(supersededIdentifiers: [String])
        /// Another producer already recorded this same system request.
        case alreadyOwned
        /// Current history or posture no longer permits this submission.
        case refused
    }

    /// Reads the atomic file, using legacy defaults only before the first file write.
    public static func load(at url: URL?, legacyHistory: ProtectionConnectivityNotificationHistory) -> ProtectionConnectivityNotificationHistory? {
        guard let url else { return nil }
        return try? read(at: url, legacyHistory: legacyHistory)
    }

    /// Clears recovered ownership and proposes a notice under the shared nonblocking lock.
    public static func reconcile(
        at url: URL?, legacyHistory: ProtectionConnectivityNotificationHistory,
        assessment: ProtectionConnectivityAssessment, health: TunnelHealthSnapshot,
        filteringUnavailable: Bool? = nil, filteringUnavailableSince: Date? = nil,
        filteringIntervention: FilterArtifactIntervention? = nil,
        now: Date = Date(), languageCode: String? = nil
    ) -> Reconciliation? {
        transact(at: url, legacyHistory: legacyHistory) { history in
            let previous = history
            let resolved = ProtectionConnectivityNotificationPolicy.resolvedProblemNotificationIdentifiers(
                for: assessment, health: health, history: previous, filteringUnavailable: filteringUnavailable, now: now)
            if !resolved.isEmpty {
                let anchor = ProtectionConnectivityNotificationPolicy.deliveryCooldownAnchorAfterClear(
                    for: assessment, history: previous, now: now)
                history = ProtectionConnectivityNotificationHistory(
                    lastDeliveredNotificationID: anchor == nil ? previous.lastDeliveredNotificationID : nil,
                    lastDeliveredAt: anchor ?? previous.lastDeliveredAt)
            } else if assessment.severity == .usingEncryptedFallback, previous.unresolvedProblemKind != .filteringUnavailable {
                history = ProtectionConnectivityNotificationHistory(
                    lastDeliveredAt: previous.lastDeliveredAt,
                    unresolvedProblemNotificationID: previous.unresolvedProblemNotificationID,
                    unresolvedProblemIncidentID: previous.unresolvedProblemIncidentID,
                    unresolvedProblemKind: previous.unresolvedProblemKind)
            }
            return Reconciliation(history: previous, resolvedIdentifiers: resolved,
                notification: ProtectionConnectivityNotificationPolicy.notification(
                    for: assessment, health: health, history: previous, filteringUnavailable: filteringUnavailable,
                    filteringUnavailableSince: filteringUnavailableSince, filteringIntervention: filteringIntervention,
                    now: now, languageCode: languageCode))
        }
    }

    /// Rechecks and records successful delivery in one cross-process transaction.
    public static func claimDelivery(
        _ notification: ProtectionConnectivityNotification,
        requestIdentifier: String? = nil,
        at url: URL?, legacyHistory: ProtectionConnectivityNotificationHistory,
        assessment: ProtectionConnectivityAssessment, health: TunnelHealthSnapshot,
        filteringUnavailable: Bool? = nil, filteringUnavailableSince: Date? = nil,
        filteringIntervention: FilterArtifactIntervention? = nil, now: Date = Date()
    ) -> DeliveryClaim? {
        transact(at: url, legacyHistory: legacyHistory) { history in
            let requestID = requestIdentifier ?? notification.identifier
            if history.unresolvedProblemNotificationID == requestID { return .alreadyOwned }
            guard let current = ProtectionConnectivityNotificationPolicy.notification(
                for: assessment, health: health, history: history, filteringUnavailable: filteringUnavailable,
                filteringUnavailableSince: filteringUnavailableSince, filteringIntervention: filteringIntervention,
                now: now), current.identifier == notification.identifier else { return .refused }
            history = ProtectionConnectivityNotificationHistory(lastDeliveredNotificationID: notification.identifier,
                lastDeliveredAt: now, unresolvedProblemNotificationID: requestID,
                unresolvedProblemIncidentID: notification.identifier, unresolvedProblemKind: notification.kind)
            return .recorded(supersededIdentifiers: current.supersededNotificationIdentifiers)
        }
    }

    // A single atomically replaced file avoids UserDefaults' per-process caches and partial
    // multi-key writes. OS submission and cleanup run outside this lock. Each attempt owns a
    // unique request ID, so late cleanup cannot remove another producer's request.
    // pinned: ProtectionConnectivityNotificationPolicyTests.testAtomicHistoryClaimCannotOverwriteAHigherPriorityProducer
    private static func transact<Result>(at url: URL?, legacyHistory: ProtectionConnectivityNotificationHistory,
                                        _ mutation: (inout ProtectionConnectivityNotificationHistory) -> Result) -> Result? {
        guard let url else { return nil }
        return try? FilterPublishLock.withTryExclusiveLock(at: url.appendingPathExtension("lock")) {
            var history = try read(at: url, legacyHistory: legacyHistory)
            let previous = history
            let result = mutation(&history)
            if history != previous || !FileManager.default.fileExists(atPath: url.path) {
                try JSONEncoder().encode(history).write(to: url, options: SharedStateFileProtection.atomicControlPlaneWritingOptions)
            }
            return result
        }
    }

    private static func read(at url: URL, legacyHistory: ProtectionConnectivityNotificationHistory) throws -> ProtectionConnectivityNotificationHistory {
        guard FileManager.default.fileExists(atPath: url.path) else { return legacyHistory }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= 4_096 else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(ProtectionConnectivityNotificationHistory.self, from: data)
    }

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
