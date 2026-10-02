import Foundation

/// Queue-confined delivery lifecycle shared by the app and tunnel notification adapters.
public struct ProtectionNotificationDeliveryState: Sendable {
    /// Current evidence supplied by the owning process before each asynchronous completion.
    public struct Posture: Sendable {
        /// Current resolver assessment.
        public let assessment: ProtectionConnectivityAssessment
        /// Current resolver and client-impact evidence.
        public let health: TunnelHealthSnapshot
        /// Only the tunnel can establish current filtering availability.
        public let filteringUnavailable: Bool?
        /// First client impact in the continuous failed-recovery window.
        public let filteringUnavailableSince: Date?
        /// A concrete remedy established by artifact recovery triage.
        public let filteringIntervention: FilterArtifactIntervention?

        /// Captures the evidence used by the shared notification policy.
        public init(assessment: ProtectionConnectivityAssessment, health: TunnelHealthSnapshot,
                    filteringUnavailable: Bool? = nil, filteringUnavailableSince: Date? = nil,
                    filteringIntervention: FilterArtifactIntervention? = nil) {
            self.assessment = assessment
            self.health = health
            self.filteringUnavailable = filteringUnavailable
            self.filteringUnavailableSince = filteringUnavailableSince
            self.filteringIntervention = filteringIntervention
        }
    }

    /// Identifies one authorization/submission attempt independently of the incident ID.
    public struct Attempt: Equatable, Sendable {
        /// Rejects completions from an invalidated lifecycle or an older attempt.
        public let token: UUID
        /// The incident and localized content proposed for delivery.
        public let notification: ProtectionConnectivityNotification
        /// Unique OS request ownership; incident identity remains in `notification.identifier`.
        public var requestIdentifier: String { "\(token.uuidString):\(notification.identifier)" }
    }

    /// The adapter's next action after the system submission completes.
    public enum Completion: Sendable {
        /// Discard this completion, removing its request unless a current submission shares the ID.
        case discard(removeRequest: Bool)
        /// Schedule one callback at this deadline; other entry points share the same backoff.
        case retry(Date)
        /// Recheck and claim delivery through the shared atomic history store.
        case claim(Posture)
    }

    private enum Phase: Sendable { case authorizing, submitting, claiming }
    private var pending: (attempt: Attempt, phase: Phase)?
    private var retry: (kind: ProtectionConnectivityNotificationKind?, deadline: Date)?
    /// Latest evidence, including recovery that arrived during authorization or submission.
    public private(set) var posture: Posture?
    /// The active retry deadline, or nil after success, preemption or shutdown.
    public var retryDeadline: Date? { retry?.deadline }

    /// Starts an empty delivery lifecycle.
    public init() {}

    /// Updates evidence without replacing an in-flight attempt's identity.
    public mutating func update(_ posture: Posture) { self.posture = posture }

    /// Begins at most one attempt; only a harder incident can preempt failed-delivery backoff.
    public mutating func prepare(history: ProtectionConnectivityNotificationHistory,
                                 now: Date = Date(), languageCode: String? = nil) -> Attempt? {
        guard pending == nil, let notification = candidate(history: history, now: now, languageCode: languageCode) else { return nil }
        if let retry, let kind = retry.kind, now < retry.deadline,
           !ProtectionConnectivityNotificationPolicy.canEscalate(from: kind, to: notification.kind) { return nil }
        retry = nil
        let attempt = Attempt(token: UUID(), notification: notification)
        pending = (attempt, .authorizing)
        return attempt
    }

    /// Rechecks current evidence after permission lookup, before any OS submission.
    public mutating func authorized(_ attempt: Attempt, permitted: Bool,
                                    history: ProtectionConnectivityNotificationHistory,
                                    now: Date = Date(), languageCode: String? = nil) -> Attempt? {
        guard pending?.attempt.token == attempt.token, pending?.phase == .authorizing else { return nil }
        guard permitted, let current = candidate(history: history, now: now, languageCode: languageCode),
              current.kind == attempt.notification.kind else {
            pending = nil
            return nil
        }
        let submission = Attempt(token: attempt.token, notification: current)
        pending = (submission, .submitting)
        return submission
    }

    /// Consumes a completion exactly once, retaining backoff only while its incident remains current.
    public mutating func submitted(_ attempt: Attempt, succeeded: Bool, permitted: Bool,
                                   now: Date = Date()) -> Completion {
        guard pending?.attempt.token == attempt.token, pending?.phase == .submitting else {
            let currentSubmissionSharesID = pending?.phase != .authorizing
                && pending?.attempt.requestIdentifier == attempt.requestIdentifier
            return .discard(removeRequest: !currentSubmissionSharesID)
        }
        pending = nil
        guard permitted, let posture,
              candidate(history: .empty, now: now)?.identifier == attempt.notification.identifier else { return .discard(removeRequest: true) }
        if succeeded {
            pending = (attempt, .claiming)
            return .claim(posture)
        }
        return .retry(reserveRetry(for: attempt.notification.kind, now: now))
    }

    /// Completes the atomic history claim; transient storage/lock failure keeps a bounded retry.
    public mutating func claimed(_ attempt: Attempt, result: ProtectionConnectivityNotificationStore.DeliveryClaim?,
                                 permitted: Bool, now: Date = Date()) -> Date? {
        guard pending?.attempt.token == attempt.token, pending?.phase == .claiming else { return nil }
        pending = nil
        guard result == nil, permitted,
              candidate(history: .empty, now: now)?.kind == attempt.notification.kind else { return nil }
        return reserveRetry(for: attempt.notification.kind, now: now)
    }

    /// Retries unavailable history, including recovery cleanup with no new notification candidate.
    public mutating func deferEvaluation(now: Date = Date()) -> Date? {
        guard posture != nil,
              retry.map({ now >= $0.deadline }) ?? true else { return nil }
        let notification = candidate(history: .empty, now: now)
        guard pending == nil || notification == nil else { return nil }
        return reserveRetry(for: notification?.kind, now: now)
    }

    /// Successful history access clears cleanup backoff without shortening failed-delivery backoff.
    public mutating func reconciledHistory() {
        if let retry, retry.kind == nil { self.retry = nil }
    }

    private mutating func reserveRetry(for kind: ProtectionConnectivityNotificationKind?, now: Date) -> Date {
        let deadline = now.addingTimeInterval(ProtectionConnectivityNotificationPolicy.reFlapGraceInterval)
        retry = (kind, deadline)
        return deadline
    }

    /// Ends a lifecycle and returns any request already submitted to the OS for cleanup.
    public mutating func invalidate() -> [String] {
        let identifiers = pending?.phase != .authorizing ? pending.map { [$0.attempt.requestIdentifier] } ?? [] : []
        pending = nil
        retry = nil
        posture = nil
        return identifiers
    }

    private func candidate(history: ProtectionConnectivityNotificationHistory, now: Date,
                           languageCode: String? = nil) -> ProtectionConnectivityNotification? {
        guard let posture else { return nil }
        return ProtectionConnectivityNotificationPolicy.notification(
            for: posture.assessment, health: posture.health, history: history,
            filteringUnavailable: posture.filteringUnavailable, filteringUnavailableSince: posture.filteringUnavailableSince,
            filteringIntervention: posture.filteringIntervention,
            now: now, languageCode: languageCode)
    }
}
