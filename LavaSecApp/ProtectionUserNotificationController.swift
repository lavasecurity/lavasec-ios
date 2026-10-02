import Foundation
@preconcurrency import UserNotifications
import LavaSecKit

@MainActor
final class ProtectionUserNotificationController: ProtectionNotificationPresenting {
    private let notificationCenter: UNUserNotificationCenter
    private let defaults: UserDefaults
    private var delivery = ProtectionNotificationDeliveryState()

    init(notificationCenter: UNUserNotificationCenter = .current(),
         defaults: UserDefaults = LavaSecAppGroup.sharedDefaults) {
        self.notificationCenter = notificationCenter
        self.defaults = defaults
    }

    func scheduleIfNeeded(assessment: ProtectionConnectivityAssessment, health: TunnelHealthSnapshot, now: Date = Date()) {
        delivery.update(.init(assessment: assessment, health: health))
        LavaSecAppGroup.migrateProtectionNotificationStateIfNeeded(defaults)
        guard let reconciliation = ProtectionConnectivityNotificationStore.reconcile(
            at: LavaSecAppGroup.protectionNotificationHistoryURL,
            legacyHistory: LavaSecAppGroup.legacyProtectionNotificationHistory(in: defaults),
            assessment: assessment, health: health, now: now) else {
            if let deadline = delivery.deferEvaluation(now: now) { scheduleRetry(at: deadline) }
            return
        }
        delivery.reconciledHistory()
        removeProblemNotifications(reconciliation.resolvedIdentifiers)
        guard LavaNotificationPreferences.isEnabled(.connectivity, in: defaults),
              let attempt = delivery.prepare(history: reconciliation.history, now: now,
                  languageCode: LavaNotificationLanguage.pinnedCode(in: defaults)) else { return }

        Task { [weak self] in
            guard let self else { return }
            let authorized = await Self.canSendNotifications(using: notificationCenter)
            let history = notificationHistory
            let permitted = authorized && LavaNotificationPreferences.isEnabled(.connectivity, in: defaults)
            guard let submission = delivery.authorized(attempt, permitted: permitted && history != nil,
                history: history ?? .empty, languageCode: LavaNotificationLanguage.pinnedCode(in: defaults)) else {
                if permitted {
                    if history != nil { reevaluateLatestPosture() }
                    else if let deadline = delivery.deferEvaluation() { scheduleRetry(at: deadline) }
                }
                return
            }
            let notification = submission.notification
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.interruptionLevel = .passive
            content.userInfo = [
                LavaSecAppGroup.protectionNotificationRouteUserInfoKeyName: LavaSecAppGroup.protectionNotificationGuardRouteValue,
                LavaSecAppGroup.protectionNotificationKindUserInfoKeyName: notification.kind.rawValue,
                LavaSecAppGroup.protectionNotificationIDUserInfoKeyName: notification.identifier
            ]
            let request = UNNotificationRequest(
                identifier: LavaSecAppGroup.protectionNotificationRequestIdentifier(for: submission.requestIdentifier),
                content: content, trigger: nil)
            let succeeded: Bool
            do { try await notificationCenter.add(request); succeeded = true }
            catch { succeeded = false }
            switch delivery.submitted(submission, succeeded: succeeded,
                permitted: LavaNotificationPreferences.isEnabled(.connectivity, in: defaults)) {
            case .discard(let removeRequest):
                if removeRequest { removeProblemNotifications([submission.requestIdentifier]) }
                reevaluateLatestPosture()
            case .retry(let deadline):
                scheduleRetry(at: deadline)
            case .claim(let posture):
                let claim = ProtectionConnectivityNotificationStore.claimDelivery(
                    notification, requestIdentifier: submission.requestIdentifier, at: LavaSecAppGroup.protectionNotificationHistoryURL,
                    legacyHistory: LavaSecAppGroup.legacyProtectionNotificationHistory(in: defaults),
                    assessment: posture.assessment, health: posture.health)
                let retry = delivery.claimed(submission, result: claim,
                    permitted: LavaNotificationPreferences.isEnabled(.connectivity, in: defaults))
                switch claim {
                case .recorded(let identifiers): removeProblemNotifications(identifiers)
                case .alreadyOwned: break
                case .refused, nil: removeProblemNotifications([submission.requestIdentifier])
                }
                if let retry { scheduleRetry(at: retry) }
            }
        }
    }

    private func reevaluateLatestPosture() {
        guard let posture = delivery.posture else { return }
        scheduleIfNeeded(assessment: posture.assessment, health: posture.health)
    }

    private func scheduleRetry(at deadline: Date) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, delivery.retryDeadline == deadline,
                  let posture = delivery.posture else { return }
            scheduleIfNeeded(assessment: posture.assessment, health: posture.health)
        }
    }

    func requestAuthorization() async -> Bool {
        await Self.canSendNotifications(using: notificationCenter)
    }

    private static func canSendNotifications(using notificationCenter: UNUserNotificationCenter) async -> Bool {
        let settings = await notificationCenter.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return (try? await notificationCenter.requestAuthorization(options: [.alert])) == true
        case .denied: return false
        @unknown default: return false
        }
    }

    private var notificationHistory: ProtectionConnectivityNotificationHistory? {
        ProtectionConnectivityNotificationStore.load(at: LavaSecAppGroup.protectionNotificationHistoryURL,
            legacyHistory: LavaSecAppGroup.legacyProtectionNotificationHistory(in: defaults))
    }

    private func removeProblemNotifications(_ identifiers: [String]) {
        let requestIdentifiers = identifiers.map { LavaSecAppGroup.protectionNotificationRequestIdentifier(for: $0) }
        guard !requestIdentifiers.isEmpty else { return }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: requestIdentifiers)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: requestIdentifiers)
    }
}

