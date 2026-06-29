import Darwin
import Foundation
import SwiftUI
import UIKit
@preconcurrency import NetworkExtension
@preconcurrency import UserNotifications
import LavaSecCore

extension NETunnelProviderManager: @retroactive @unchecked Sendable {}

// FilterEditDraft, DomainDraftResult, and the pure draft-mutation editor live in
// LavaSecCore (FilterEditDraft.swift) so the mutation logic is unit-tested.

enum ProtectionPauseDuration: CaseIterable, Identifiable {
    case fiveMinutes
    case tenMinutes
    case fifteenMinutes

    var id: Self {
        self
    }

    var duration: TimeInterval {
        switch self {
        case .fiveMinutes:
            5 * 60
        case .tenMinutes:
            10 * 60
        case .fifteenMinutes:
            15 * 60
        }
    }

    var protectionCommandRequest: LavaLiveActivityActionRequest {
        switch self {
        case .fiveMinutes:
            .pauseFiveMinutes
        case .tenMinutes:
            .pauseTenMinutes
        case .fifteenMinutes:
            .pauseFifteenMinutes
        }
    }

    var label: String {
        switch self {
        case .fiveMinutes:
            "For 5 minutes"
        case .tenMinutes:
            "For 10 minutes"
        case .fifteenMinutes:
            "For 15 minutes"
        }
    }
}

enum LavaAppearancePreference: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: Self {
        self
    }

    var displayName: String {
        switch self {
        case .light:
            "Light"
        case .dark:
            "Dark"
        case .system:
            "System"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light:
            .light
        case .dark:
            .dark
        case .system:
            nil
        }
    }
}

struct LavaGuardAvailability: Equatable {
    let isSelectable: Bool
    let isRevealed: Bool
    let progress: LavaGuardGoalProgress?
    let isProgressEnabled: Bool
    let showsProgressDetail: Bool
}

@MainActor
private final class ProtectionUserNotificationController {
    private let notificationCenter: UNUserNotificationCenter
    private let defaults: UserDefaults
    private var pendingNotificationIDs = Set<String>()

    init(
        notificationCenter: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = LavaSecAppGroup.sharedDefaults
    ) {
        self.notificationCenter = notificationCenter
        self.defaults = defaults
    }

    func scheduleIfNeeded(
        assessment: ProtectionConnectivityAssessment,
        health: TunnelHealthSnapshot,
        now: Date = Date()
    ) {
        LavaSecAppGroup.migrateProtectionNotificationStateIfNeeded(defaults)
        let history = notificationHistory
        let resolvedNotificationIdentifiers = ProtectionConnectivityNotificationPolicy
            .resolvedProblemNotificationIdentifiers(
                for: assessment,
                health: health,
                history: history,
                now: now
            )
        if !resolvedNotificationIdentifiers.isEmpty {
            clearResolvedProblemNotifications(
                resolvedNotificationIdentifiers,
                cooldownAnchor: ProtectionConnectivityNotificationPolicy.deliveryCooldownAnchorAfterClear(
                    for: assessment,
                    history: history,
                    now: now
                )
            )
        } else if assessment.severity == .usingEncryptedFallback {
            // Coverage is active with NO problem banner outstanding to clear. Still lift the
            // exact-id duplicate guard so a later lapse back to a real problem with the same
            // truncated-second event id isn't suppressed by notification(for:)'s id guard
            // (the outstanding-problem case clears it via clearResolvedProblemNotifications).
            defaults.removeObject(forKey: LavaSecAppGroup.protectionLastDeliveredNotificationIDDefaultsKey)
        }

        // Use the pre-clear `history`: clearResolvedProblemNotifications wipes the
        // unresolved-problem markers, but notification(for:)'s escalation / exact-id
        // duplicate-guard logic needs to see the outstanding marker. Re-reading would
        // always miss it.
        // Customization → Notifications: the "Connection updates" toggle gates only the CREATION of new
        // connectivity/reconnect banners — placed AFTER the resolved-banner cleanup above so disabling the
        // category mid-problem still clears a stale banner when the network recovers (Codex P2).
        guard LavaNotificationPreferences.isEnabled(.connectivity, in: defaults) else { return }

        guard let notification = ProtectionConnectivityNotificationPolicy.notification(
            for: assessment,
            health: health,
            history: history,
            now: now
        ), !pendingNotificationIDs.contains(notification.identifier) else {
            return
        }

        pendingNotificationIDs.insert(notification.identifier)

        Task { [weak self] in
            guard let self else {
                return
            }

            defer {
                Task { @MainActor [weak self] in
                    self?.pendingNotificationIDs.remove(notification.identifier)
                }
            }

            guard await Self.canSendNotifications(using: notificationCenter) else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.interruptionLevel = .passive
            content.userInfo = [
                LavaSecAppGroup.protectionNotificationRouteUserInfoKey:
                    LavaSecAppGroup.protectionNotificationGuardRouteValue,
                LavaSecAppGroup.protectionNotificationKindUserInfoKey: notification.kind.rawValue,
                LavaSecAppGroup.protectionNotificationIDUserInfoKey: notification.identifier
            ]

            let request = UNNotificationRequest(
                identifier: LavaSecAppGroup.protectionNotificationRequestIdentifier(
                    for: notification.identifier
                ),
                content: content,
                trigger: nil
            )
            do {
                try await notificationCenter.add(request)
                removeSupersededNotifications(for: notification)
                recordDelivery(of: notification)
            } catch {
                return
            }
        }
    }

    func requestAuthorization() async -> Bool {
        await Self.canSendNotifications(using: notificationCenter)
    }

    private static func canSendNotifications(using notificationCenter: UNUserNotificationCenter) async -> Bool {
        let settings = await notificationCenter.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await notificationCenter.requestAuthorization(options: [.alert])) == true
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private var notificationHistory: ProtectionConnectivityNotificationHistory {
        let unresolvedProblemKind = defaults.string(
            forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationKindDefaultsKey
        ).flatMap(ProtectionConnectivityNotificationKind.init(rawValue:))

        return ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: defaults.string(
                forKey: LavaSecAppGroup.protectionLastDeliveredNotificationIDDefaultsKey
            ),
            lastDeliveredAt: defaults.object(
                forKey: LavaSecAppGroup.protectionLastDeliveredNotificationAtDefaultsKey
            ) as? Date,
            unresolvedProblemNotificationID: defaults.string(
                forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationIDDefaultsKey
            ),
            unresolvedProblemKind: unresolvedProblemKind
        )
    }

    private func recordDelivery(of notification: ProtectionConnectivityNotification) {
        defaults.set(
            notification.identifier,
            forKey: LavaSecAppGroup.protectionLastDeliveredNotificationIDDefaultsKey
        )

        // Only actionable problem banners are delivered now, and they advance the
        // throttle clock: the 600s minimum-problem-interval keys off this
        // timestamp. (A self-recovery clears the outstanding markers silently via
        // `clearResolvedProblemNotifications`, so there's no delivered
        // acknowledgement to handle here.)
        if notification.kind.isProblem {
            defaults.set(Date(), forKey: LavaSecAppGroup.protectionLastDeliveredNotificationAtDefaultsKey)
            defaults.set(
                notification.identifier,
                forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationIDDefaultsKey
            )
            defaults.set(
                notification.kind.rawValue,
                forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationKindDefaultsKey
            )
        }
    }

    private func removeSupersededNotifications(for notification: ProtectionConnectivityNotification) {
        let requestIdentifiers = notification.supersededNotificationIdentifiers.map {
            LavaSecAppGroup.protectionNotificationRequestIdentifier(for: $0)
        }
        guard !requestIdentifiers.isEmpty else {
            return
        }

        notificationCenter.removePendingNotificationRequests(withIdentifiers: requestIdentifiers)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: requestIdentifiers)
    }

    private func clearResolvedProblemNotifications(_ identifiers: [String], cooldownAnchor: Date?) {
        defaults.removeObject(forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationIDDefaultsKey)
        defaults.removeObject(forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationKindDefaultsKey)
        // Back-date the delivery cooldown ONLY for the encrypted-fallback silent supersede
        // (cooldownAnchor non-nil); a real `.healthy` recovery passes nil and keeps its
        // anti-flap cooldown intact.
        if let cooldownAnchor {
            defaults.set(cooldownAnchor, forKey: LavaSecAppGroup.protectionLastDeliveredNotificationAtDefaultsKey)
            // Also lift the exact-id duplicate guard. The silent supersede removed the
            // reconnect banner from the OS, so if coverage lapses before a new smoke probe
            // shifts the event id, the recurring `reconnect-needed:<event>` candidate must be
            // free to re-post. A stale id here would let `notification(for:)`'s duplicate
            // guard suppress the actionable banner until some later probe changes the id,
            // defeating the back-dated cooldown. The cooldown anchor stays the sole gate, so
            // a flapping wedge is still bounded to one banner per `reFlapGraceInterval`.
            defaults.removeObject(forKey: LavaSecAppGroup.protectionLastDeliveredNotificationIDDefaultsKey)
        }

        let requestIdentifiers = identifiers.map {
            LavaSecAppGroup.protectionNotificationRequestIdentifier(for: $0)
        }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: requestIdentifiers)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: requestIdentifiers)
    }
}

enum FilterPreparationState: Equatable {
    case idle
    case preparing(progress: Double, message: String)
    case failed(message: String)

    var isPreparing: Bool {
        if case .preparing = self {
            return true
        }

        return false
    }

    var progress: Double {
        if case .preparing(let progress, _) = self {
            return progress
        }

        return 0
    }

    var message: String {
        switch self {
        case .idle:
            "Ready"
        case .preparing(_, let message), .failed(let message):
            message
        }
    }
}

enum BugReportSendState: Equatable {
    case idle
    case sending
    case sent(reportID: String)
    case failed(message: String)

    var isSending: Bool {
        if case .sending = self {
            return true
        }

        return false
    }
}

private struct BugReportSubmitResponse: Decodable {
    let reportID: String

    private enum CodingKeys: String, CodingKey {
        case reportID = "report_id"
    }
}

private struct LavaSecurityPlusEntitlementSyncClient: Sendable {
    let urlSession: URLSession

    func sync(
        entitlement: LavaSecurityPlusEntitlement,
        session: BackupAccountSession
    ) async throws {
        guard let productID = entitlement.productID,
              let transactionID = entitlement.transactionID,
              let originalTransactionID = entitlement.originalTransactionID,
              let signedTransactionJWS = entitlement.signedTransactionJWS,
              !signedTransactionJWS.isEmpty
        else {
            return
        }

        let body = LavaSecurityPlusEntitlementSyncRequest(
            productID: productID,
            transactionID: transactionID,
            originalTransactionID: originalTransactionID,
            signedTransactionJWS: signedTransactionJWS,
            active: entitlement.isActive,
            expiresAt: entitlement.expiresAt,
            environment: entitlement.environment
        )
        let requestBody = try Self.makeJSONEncoder().encode(body)
        var lastError: Error?

        for endpoint in Self.syncEndpointURLs {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.httpBody = requestBody

                let (responseData, response) = try await urlSession.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw LavaSecurityPlusEntitlementSyncError.invalidResponse
                }

                guard 200..<300 ~= httpResponse.statusCode else {
                    let serverMessage = String(data: responseData, encoding: .utf8) ?? "No response body"
                    throw LavaSecurityPlusEntitlementSyncError.requestFailed(
                        statusCode: httpResponse.statusCode,
                        message: serverMessage
                    )
                }

                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? LavaSecurityPlusEntitlementSyncError.invalidResponse
    }

    private static var syncEndpointURLs: [URL] {
        [LavaSecAPI.productionBaseURL, LavaSecAPI.fallbackBaseURL].map {
            $0
                .appendingPathComponent("v1")
                .appendingPathComponent("account")
                .appendingPathComponent("entitlements")
                .appendingPathComponent("app-store-sync")
        }
    }

    private static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private struct LavaSecurityPlusEntitlementSyncRequest: Encodable {
    let productID: String
    let transactionID: String
    let originalTransactionID: String
    let signedTransactionJWS: String
    let active: Bool
    let expiresAt: Date?
    let environment: String?

    private enum CodingKeys: String, CodingKey {
        case productID = "product_id"
        case transactionID = "transaction_id"
        case originalTransactionID = "original_transaction_id"
        case signedTransactionJWS = "signed_transaction_jws"
        case active
        case expiresAt = "expires_at"
        case environment
    }
}

private enum LavaSecurityPlusEntitlementSyncError: Error, LocalizedError {
    case invalidResponse
    case requestFailed(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The subscription sync server response was not valid."
        case .requestFailed(let statusCode, let message):
            "Subscription sync returned HTTP \(statusCode): \(message)"
        }
    }
}

private struct BugReportSubmissionError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

// EncryptedBackupState moved to LavaSecCore (EncryptedBackupState.swift) so its
// signed-in/signed-out copy branching is unit-tested rather than source-pinned.

enum EncryptedBackupError: Error, LocalizedError {
    case noBackupAvailable
    case noSavedDeviceSecret
    case invalidDeviceUnlock
    case invalidRecoveryPhrase
    case noPasskeyRecovery
    case invalidPasskeyUnlock
    case passkeyRestoreRequiresSignIn
    case supersededByConcurrentConfigurationChange

    var errorDescription: String? {
        switch self {
        case .supersededByConcurrentConfigurationChange:
            "Your filter changed while the backup was restoring. Try the restore again."
        case .noBackupAvailable:
            "No encrypted backup is available on this device yet. Sign in is needed to download a server backup."
        case .noSavedDeviceSecret:
            "No saved device unlock is available on this device. Use the recovery phrase instead."
        case .invalidDeviceUnlock:
            "This device could not unlock the backup. Use the recovery phrase instead."
        case .invalidRecoveryPhrase:
            "That recovery phrase did not unlock this backup. Check the words and try again."
        case .noPasskeyRecovery:
            "This backup was not protected with Passkey. Use this device's keychain or Recovery instead."
        case .invalidPasskeyUnlock:
            "That Passkey did not unlock this backup. Use Recovery instead."
        case .passkeyRestoreRequiresSignIn:
            "Sign in to use Passkey restore."
        }
    }
}

private struct PendingBackupPasskey: Equatable {
    let credentialID: String
    /// Non-secret PRF input persisted in the envelope slot.
    let prfSalt: Data
    /// Authenticator PRF output captured at setup; transient, never persisted or uploaded.
    let prfOutput: Data
}

/// A registered (PRF-capable) passkey awaiting the explicit validation step that captures its
/// PRF output. Holds only the credential ID and the non-secret salt — no key material yet.
private struct RegisteredBackupPasskey: Equatable {
    let credentialID: String
    let prfSalt: Data
}

@MainActor
private final class FilterPreparationProgressPresenter {
    private let policy: FilterPreparationPresentationPolicy
    private var currentPhase: FilterPreparationPhase?
    private var phaseStartedAt: Date?

    init(policy: FilterPreparationPresentationPolicy = FilterPreparationPresentationPolicy()) {
        self.policy = policy
    }

    func present(
        _ update: FilterPreparationProgressUpdate,
        setState: (FilterPreparationState) -> Void
    ) async {
        let holdDuration = policy.holdDurationBeforePresenting(
            currentPhase: currentPhase,
            phaseStartedAt: phaseStartedAt,
            nextPhase: update.phase
        )

        guard await sleep(for: holdDuration) else {
            return
        }

        if currentPhase != update.phase {
            currentPhase = update.phase
            phaseStartedAt = Date()
        } else if phaseStartedAt == nil {
            phaseStartedAt = Date()
        }

        setState(.preparing(
            progress: FilterPreparationPresentationPolicy.equalThirdsProgress(phase: update.phase, rawProgress: update.progress),
            message: FilterPreparationPresentation.message(for: update.phase)
        ))
    }

    func holdCurrentPhaseIfNeeded() async {
        guard phaseStartedAt != nil
        else {
            return
        }

        let holdDuration = remainingCurrentPhaseHoldDuration()
        _ = await sleep(for: holdDuration)
    }

    private func sleep(for duration: TimeInterval) async -> Bool {
        guard duration > 0 else {
            return !Task.isCancelled
        }

        let nanoseconds = UInt64((duration * 1_000_000_000).rounded(.up))
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func remainingCurrentPhaseHoldDuration(now: Date = Date()) -> TimeInterval {
        guard let phaseStartedAt else {
            return 0
        }

        return max(0, policy.minimumPhaseDuration - now.timeIntervalSince(phaseStartedAt))
    }
}

// `ReusablePreparedFilterSnapshot` was promoted to LavaSecCore (LAV-100 Phase 4) so the foreground
// switch and the headless Focus engine share one warm-reuse value type + validation core
// (see WarmFilterSnapshotLoader). Referenced here unqualified via `import LavaSecCore`.

private final class ProtectionStopNotificationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var didResume = false

    func wait(timeout: TimeInterval) async -> Bool {
        guard timeout > 0 else {
            return false
        }

        return await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let observer = NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.finish(observedStatusChange: true)
            }

            var shouldRemoveObserver = false
            lock.lock()
            if didResume {
                shouldRemoveObserver = true
            } else {
                self.observer = observer
            }
            lock.unlock()

            if shouldRemoveObserver {
                NotificationCenter.default.removeObserver(observer)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(observedStatusChange: false)
            }
        }
    }

    private func finish(observedStatusChange: Bool) {
        let observerToRemove: NSObjectProtocol?
        let continuationToResume: CheckedContinuation<Bool, Never>?

        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }

        didResume = true
        observerToRemove = observer
        continuationToResume = continuation
        observer = nil
        continuation = nil
        lock.unlock()

        if let observerToRemove {
            NotificationCenter.default.removeObserver(observerToRemove)
        }
        continuationToResume?.resume(returning: observedStatusChange)
    }
}

enum ProtectionHapticFeedback {
    case protectionOnSucceeded
    case protectionStartFailed
    case protectionTurnedOff
    case guardianTapAcknowledged
    // Outcome haptics for the rest of the app's consequential actions. They route
    // through the same `play` choke point so the Customization toggle silences them
    // alongside the protection and guardian-tap feedback.
    case actionSucceeded
    case actionFailed
    case selectionRejected
    case selectionConfirmed

    /// Source of truth for the "Lava Haptics" Customization toggle. Lava haptics
    /// default on, so a missing key reads as enabled and preserves the prior
    /// always-on behavior. AppViewModel writes this key; `play` reads it.
    static let preferenceDefaultsKey = "lavasec.customization.lavaHaptics"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: preferenceDefaultsKey) as? Bool ?? true
    }

    @MainActor static func play(_ feedback: ProtectionHapticFeedback) {
        guard isEnabled else {
            return
        }

        switch feedback {
        case .protectionOnSucceeded:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)
        case .protectionStartFailed:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.error)
        case .protectionTurnedOff:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.warning)
        case .guardianTapAcknowledged:
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            generator.impactOccurred()
        case .actionSucceeded:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)
        case .actionFailed:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.error)
        case .selectionRejected:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.warning)
        case .selectionConfirmed:
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            generator.impactOccurred()
        }
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    private static let vpnPermissionPromptMessage = "If iOS asks to add a VPN configuration, tap Allow."
    private static let protectionStopWaitTimeout: TimeInterval = 3
    private static let protectionStartWaitTimeout: TimeInterval = 15
    private static let protectionRestartStopWaitTimeout: TimeInterval = 15
    private static let protectionStopStatusRefreshInterval: TimeInterval = 0.5
    private static let providerMessageAckTimeout: TimeInterval = 3

    static let supportsDNSOverQUICRuntime = true

    #if DEBUG || LAVA_QA_TOOLS
    static let liveDNSSmokeTestLaunchArgument = "-lava-live-dns-smoke-test"
    static let liveDNSSmokeResolverPresetIDLaunchArgument = "-lava-live-dns-smoke-resolver-preset-id"
    static let liveDNSSmokeCustomResolverLaunchArgument = "-lava-live-dns-smoke-custom-resolver"
    static let vpnLifecycleSmokeTestLaunchArgument = "-lava-vpn-lifecycle-smoke-test"

    private static var isLiveDNSSmokeTestRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(liveDNSSmokeTestLaunchArgument)
    }

    private static var isVPNLifecycleSmokeTestRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(vpnLifecycleSmokeTestLaunchArgument)
    }

    private static var liveDNSSmokeResolverPresetIDOverride: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let argumentIndex = arguments.firstIndex(of: liveDNSSmokeResolverPresetIDLaunchArgument) else {
            return nil
        }

        let valueIndex = arguments.index(after: argumentIndex)
        guard valueIndex < arguments.endIndex else {
            return nil
        }

        let resolverPresetID = arguments[valueIndex]
        guard DNSResolverPreset.allPresets.contains(where: { $0.id == resolverPresetID }) else {
            return nil
        }

        return resolverPresetID
    }

    private static var liveDNSSmokeCustomResolverOverride: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let argumentIndex = arguments.firstIndex(of: liveDNSSmokeCustomResolverLaunchArgument) else {
            return nil
        }

        let valueIndex = arguments.index(after: argumentIndex)
        guard valueIndex < arguments.endIndex else {
            return nil
        }

        let rawValue = arguments[valueIndex]
        guard DNSResolverPreset.customValidationMessage(
            rawValue: rawValue,
            supportsDNSOverQUIC: supportsDNSOverQUICRuntime
        ) == nil else {
            return nil
        }

        return rawValue
    }
    #endif

    private static func formatCatalogDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a z"
        return formatter.string(from: date)
    }

    private static func formatRelativeCatalogAge(_ age: TimeInterval, maxFreshnessAge: TimeInterval) -> String {
        let age = max(0, age)

        guard age < maxFreshnessAge else {
            return "more than a week"
        }

        if age < 60 {
            return "Now"
        }

        let minutes = Int(age / 60)
        if minutes < 60 {
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes") ago"
        }

        let hours = Int(age / (60 * 60))
        if hours < 24 {
            return "\(hours) \(hours == 1 ? "hour" : "hours") ago"
        }

        let days = Int(age / (24 * 60 * 60))
        return "\(days) \(days == 1 ? "day" : "days") ago"
    }

    @Published var configuration = AppConfiguration()
    // The hosted filters + which one is active (multi-filter library). Source of truth
    // for the SET of filters and the active selection; the active filter's four
    // filter-scoped fields are mirrored write-through into `configuration`, so the
    // ~25 existing readers of `configuration.enabledBlocklistIDs` et al. are untouched.
    // At library size 1 this is byte-for-byte today's single-filter behaviour.
    @Published private(set) var library = FilterLibrary(migratingLegacy: AppConfiguration())
    // The background catalog-refresh runs on a HEADLESS instance whose
    // loadPersistedConfiguration() must stay read-only — the migration write is gated on
    // this so a bg refresh can't overwrite a foreground-created library (read→write race).
    private let isHeadless: Bool
    // True when the most recent loadOrMigrateFilterLibrary() had to REJECT the on-disk
    // library and reseed the three defaults (pre-upgrade/old-schema library, or one that lost
    // a two-file write race). The reseed mirrors Balanced into `configuration` in memory but
    // persists it only in the foreground, so a headless background publish must NOT build from
    // this state — it would flip published artifacts to Balanced while the on-disk config (and
    // its generation) still describes the pre-upgrade filter. The background publish path
    // consults this to abort until the foreground migration lands.
    private var didReseedFilterLibraryOnLastLoad = false
    // The filter a switch is currently targeting, kept so the shared preparation screen's
    // "Try Again" can retry the SWITCH (not the edit-draft apply) after a transient failure.
    private var pendingSwitchFilterID: String?
    // Serializes EVERY wholesale config+library replacement — a filter switch, a backup restore,
    // a shared-config import, AND a My-filter draft apply — against one another. Each replacer
    // claims a token before its first await and re-checks it (1) before committing, (2) before its
    // post-persist side-effect tail, and (3) before any rollback; a newer claim supersedes an
    // older one, so the older bails instead of clobbering. persistSharedState ends in an artifact
    // actor-hop await, so re-check (2) is what stops a superseded loser's tail (applyCatalogSyncResult
    // rebuilds derived rule caches against the LIVE configuration) from desyncing caches vs the
    // newer owner's config and serializing wrong rules on the next persist. Main-actor only, so the
    // read-modify-write in begin() is not racy.
    private var configurationReplacementGate = ExclusiveReplacementGate()
    // Whether the CURRENT preparation failure can be retried. A switch whose target was deleted
    // or frozen mid-prepare is a dead end (retrying re-fails), so it surfaces a non-retryable
    // failure; ordinary transient failures stay retryable.
    @Published private(set) var filterPreparationFailureIsRetryable = true
    @Published var diagnostics = DiagnosticsStore()
    @Published private(set) var networkActivityLog = NetworkActivityLog()
    @Published var allowlistDraft = ""
    #if DEBUG || LAVA_QA_TOOLS
    @Published var qaProbeSuffixDraft = ""
    #endif
    @Published var lastAllowlistMessage: String?
    // Per-filter edit drafts, keyed by filter id. Each filter (the active one, any non-active
    // "View" target, and the Domain History edit — which keys by the active id) owns its own
    // in-progress draft, so opening/switching/staging never clobbers another filter's edit. The
    // computed `filterEditDraft` proxy below reads/writes the entry for the filter the detail page
    // is currently showing (`filterEditTargetID ?? activeFilterID`); the active-apply path keys by
    // `activeFilterID` explicitly.
    @Published private(set) var filterEditDrafts: [String: FilterEditDraft] = [:]
    // The filter the My-filter detail page is currently showing/editing. `nil` means the
    // ACTIVE filter (the common case) — every detail accessor below then reads `configuration`
    // exactly as before. A non-nil id means a NON-active filter opened via "View": the page
    // shows + edits that filter's saved fields without loading it (no prepare/recompile/tunnel
    // reload — the "edit a playlist you're not playing" model). Set via beginViewingFilterDetail
    // and cleared via endViewingFilterDetail, both scoped to the detail page's lifetime; the
    // retargeted accessors are read ONLY inside that page (verified), so a stray non-nil value
    // can't bleed into Home/Guard.
    @Published private(set) var filterEditTargetID: String?
    @Published private(set) var filterPreparationState: FilterPreparationState = .idle
    @Published var isFilterPreparationScreenPresented = false
    // Which surface owns the shared preparation cover. Multiple screens (Filters tab, Domain
    // History in Diagnostics) bind covers to `isFilterPreparationScreenPresented`; each gates on
    // this so only the originating surface presents — otherwise the always-mounted Filters cover
    // would also fire for a Domain History action (wrong origin / missing "back to review").
    @Published private(set) var filterPreparationOrigin: FilterReviewOrigin = .filters
    @Published var rageShakeDestination: RageShakeDestination?
    @Published var pendingRageShakeConfirmation: RageShakeDestination?
    @Published private(set) var bugReportDraft: BugReportBundle?
    @Published private(set) var bugReportSendState: BugReportSendState = .idle
    #if DEBUG || LAVA_QA_TOOLS
    @Published private(set) var adminQAStatusMessage: String?
    #endif
    // QA-only: the Phone QA menu is gated solely by the build flag at its call
    // sites (the account-developer runtime probe / qa_developers allowlist was
    // retired). Kept a plain constant rather than a build-flag #if so the
    // internal-only flag never lands in tracked source (contamination guard);
    // every read of it is already compile-gated, so the value is never observed
    // in a public build.
    let isAccountDeveloper = true
    @Published private(set) var vpnStatus: NEVPNStatus = .invalid
    @Published private(set) var isVPNConfigurationInstalled = false
    @Published private(set) var isConfiguringVPN = false
    @Published private(set) var tunnelHealth = TunnelHealthSnapshot()
    @Published var vpnMessage: String?
    @Published var vpnMessageIsError = false
    @Published private(set) var temporaryProtectionPauseUntil: Date?
    @Published private(set) var appearancePreference: LavaAppearancePreference = .system
    @Published private(set) var lavaGuardLook: GuardianShieldStyle = .original
    @Published private(set) var lavaGuardProgress = LavaGuardProgress()
    @Published private(set) var updatesAppIconWithLavaGuard = true
    @Published private(set) var usesLiveActivities = false
    @Published private(set) var liveActivityPauseMinutes = LiveActivityPausePreference.defaultMinutes
    @Published private(set) var usesLavaHaptics = true
    /// Customization → Notifications per-category toggles. SwiftUI-bindable mirrors of the cross-process
    /// app-group store (`LavaNotificationPreferences`) the extension + tunnel read; default ON.
    @Published private(set) var notifiesFilterChanges = true
    @Published private(set) var notifiesFilterCouldNotApply = true
    @Published private(set) var notifiesConnectivity = true
    @Published private(set) var isSyncingCatalog = false
    private var catalogSyncTask: Task<Void, Never>?
    /// Whether a catalog sync is queued or in progress. `catalogSyncTask` is assigned synchronously
    /// at the start of `syncCatalog` — BEFORE the deferred `isSyncingCatalog` flips inside
    /// `performCatalogSync` — so this also catches a sync that's been triggered but hasn't begun its
    /// work yet, and stays true for the entire sync (it's cleared only after the recompile/republish
    /// finishes). The warm-artifact switch path bails to a cold compile whenever this is true: a cold
    /// compile syncs + recompiles fresh, so an instant pointer flip can never race an in-flight
    /// refresh's recompile/republish. This makes the warm fast path mutually exclusive with catalog
    /// syncs — the whole warm-vs-sync race class — leaving only the quiescent (common) case instant.
    private var isCatalogSyncInFlight: Bool { catalogSyncTask != nil }
    @Published private(set) var catalogStatusMessage = "Filter will update from Lava Security's source catalog."
    @Published private(set) var catalogStatusIsError = false
    @Published private(set) var catalogVersion: String?
    @Published private(set) var catalogGeneratedAt: Date?
    @Published private(set) var compiledRuleCount = 0
    @Published private(set) var protectedRuleCount = 0
    @Published private(set) var compiledBlocklistRuleCount = 0
    @Published private(set) var accountAuthState: AccountAuthState = .signedOut
    @Published private(set) var accountSignInProviderInProgress: AccountAuthProvider?
    @Published private(set) var accountAuthMessage: String?
    @Published private(set) var accountAuthMessageIsError = false
    @Published private(set) var isAccountDeletionInProgress = false
    @Published private(set) var encryptedBackupState: EncryptedBackupState = .off
    @Published private(set) var isBackingUpNow = false
    @Published private(set) var isBackupMaintenanceInProgress = false
    // Tracks any in-flight server write (manual, automatic, setup, or sign-in
    // upload) so Clear/Disable never overlap an upload that could resurrect the
    // row being deleted.
    private var isUploadingEncryptedBackup = false
    @Published private(set) var isAutomaticBackupEnabled = false
    @Published private(set) var lavaSecurityPlusOffers: [LavaSecurityPlusOffer] = LavaSecurityPlusPolicy.recommendedOfferOrder.map {
        LavaSecurityPlusOffer(
            plan: $0,
            displayPrice: $0.fallbackDisplayPrice,
            product: nil
        )
    }
    @Published private(set) var isLoadingLavaSecurityPlusProducts = false
    @Published private(set) var hasCheckedLavaSecurityPlusEntitlements = false
    @Published private(set) var isRefreshingLavaSecurityPlusEntitlements = false
    /// Expiry of the active auto-renewable Lava Security Plus entitlement (nil when
    /// there is no active entitlement). Drives the subscriber "Expiration" line and
    /// gates the Manage Subscription control.
    @Published private(set) var lavaSecurityPlusExpiresAt: Date?
    @Published private(set) var isPurchasingLavaSecurityPlus = false
    @Published private(set) var lavaSecurityPlusMessage: String?
    @Published private(set) var lavaSecurityPlusMessageIsError = false

    private var blockRules = DomainRuleSet()
    private var threatGuardrail = DomainRuleSet()
    private var cachedBlockRuleSets: [String: DomainRuleSet] = [:]
    /// True while a warm (instant) switch has published the target filter but its background per-source
    /// cache rehydration (`rehydrateRuleSetCachesAfterWarmSwitch`) hasn't completed — so
    /// `cachedBlockRuleSets` still describes the PREVIOUS filter. Per-source caches are keyed by source
    /// id and filter-independent, so they never hold WRONG rules — but they OMIT the target filter's
    /// sources the previous filter didn't have, so an in-place edit that rebuilds `blockRules` from
    /// them and re-publishes would publish an UNDER-COVERING snapshot for the target filter (Codex
    /// #133). In-place edits therefore defer while this is set. Set in the warm-switch branch; cleared
    /// by `applyCatalogSyncResult` — the chokepoint every FRESH-cache load funnels through (the warm
    /// rehydration, a cold switch / import / draft-apply, or any catalog sync) — and explicitly by
    /// `restoreFiltersToDefault` (which supersedes the warm switch and drives its own coverage). A
    /// superseding path that does NOT refresh the caches (backup restore; a failed switch's rollback)
    /// correctly leaves it set — the caches really are stale for the now-active filter — and it
    /// self-heals on the next fresh-cache load (it's in-memory, so it also resets each launch). (The
    /// multi-filter UI edits via drafts today, so this guards a latent path + the deferred
    /// in-place-edit follow-up.)
    private var hasPendingWarmSwitchCacheRehydration = false
    private var catalogSourcesByID: [String: CatalogBlocklistSource] = [:]
    private var currentCatalog: BlocklistCatalog?
    private var tunnelManager: NETunnelProviderManager?
    private var vpnStatusObserver: NSObjectProtocol?
    private var tunnelHealthNudgeObserver: DarwinNotificationObserver?
    // Foreground-only: the headless Focus warm-switch posts this Darwin nudge after recording a
    // deferred switch so the foreground reconciles the pending-switch marker promptly (LAV-100 P3).
    private var focusPendingSwitchObserver: DarwinNotificationObserver?
    // Re-entrancy guard for reconcilePendingFilterSwitch — onAppear, scene .active, and the Darwin
    // nudge can all fire it, and overlapping runs would launch duplicate switchToFilter attempts.
    // These two flags are unsynchronized Bools BY DESIGN: the guard's correctness relies on every
    // access being @MainActor-confined (this class is @MainActor; the Darwin observer hops via
    // `Task { @MainActor in … }` before touching reconcile). A future off-actor read/write of either
    // flag would silently break the serialization (review P3-4).
    private var isReconcilingPendingFilterSwitch = false
    // Set when a wake trigger arrives while a reconcile is in flight, so the in-flight run loops once
    // more — a newer marker recorded during a (possibly slow cold-compile) apply isn't stranded until
    // the next scene-phase event.
    private var pendingReconcileRerun = false
    // Coalesces the non-active warm pass: it is triggered on BOTH onAppear and scene .active (and after a
    // catalog apply), which can overlap; a concurrent second pass would redundantly re-scan + double-compile
    // the same cold filters. @MainActor-confined, like the reconcile flags above.
    private var isReconcilingWarmNonActiveFilters = false
    // Set when a warm-reconcile trigger arrives while one is already in flight, so the in-flight run loops
    // once more instead of DROPPING the new trigger. The trigger that matters is a catalog apply landing
    // mid-pass: the in-flight pass may have already judged tokens against the OLD catalog (or discarded a
    // compile when its recheck saw the move), so without a rerun the non-active filters can stay cold/stale —
    // and a closed-app Focus switch to them defers-to-cold instead of landing warm, defeating the
    // warm-after-install/catalog goal this serves (Codex P2). Mirrors `pendingReconcileRerun`.
    private var pendingWarmReconcileRerun = false
    // True while a genuine USER-initiated switchToFilter (stampsForegroundSwitch == true) is in flight, from
    // entry until it commits-or-fails. The Focus reconcile reads this and DEFERS rather than applying a marker
    // via its own switchToFilter, which would begin a newer replacement epoch and make the user's in-flight
    // switch bail as superseded — letting an OLDER Focus request win over the user's newer manual choice. The
    // stamp (lastForegroundSwitch) can't cover this: it lands only AFTER the manual switch succeeds, so it is
    // still nil/old while the switch is preparing (Codex round-18). @MainActor-confined, like the reconcile flags.
    private var isForegroundManualSwitchInFlight = false
    // (The foreground-active scene flag + its 60s heartbeat were REMOVED 2026-06-29 — the headless switch is
    // state-agnostic now, so nothing reads a foreground-active hint. See HeadlessFocusFilterSwitchEngine.)
    private var automaticBackupTask: Task<Void, Never>?
    private let vpnConfigurationName = LavaTunnelConfigurationIdentity.currentDisplayName
    private let protectionStatusRefreshInterval: TimeInterval = 8
    private let catalogSyncFreshnessInterval: TimeInterval = 7 * 24 * 60 * 60
    private let automaticBackupEnabledDefaultsKey = "lavasec.encryptedBackup.automaticBackupEnabled"
    private let activeProtectionSessionIDDefaultsKey = LavaSecAppGroup.protectionActiveSessionIDDefaultsKey
    private let appearancePreferenceDefaultsKey = "lavasec.customization.appearance"
    private let lavaGuardLookDefaultsKey = LavaSecAppGroup.customizationLavaGuardLookDefaultsKey
    private let lavaGuardProgressDefaultsKey = "lavasec.customization.lavaGuardProgress"
    private let updatesAppIconWithLavaGuardDefaultsKey = "lavasec.customization.updatesAppIconWithLavaGuard"
    private let usesLiveActivitiesDefaultsKey = "lavasec.customization.liveActivities"
    private let usesLavaHapticsDefaultsKey = ProtectionHapticFeedback.preferenceDefaultsKey
    private let automaticBackupDelay: UInt64 = 30 * 60 * 1_000_000_000
    private let defaults = UserDefaults.standard
    private let appGroupDefaults = LavaSecAppGroup.sharedDefaults
    // Single source of truth for session and pause state, shared with the
    // tunnel and the intents process via the same app-group keys.
    private lazy var protectionSessionStore = ProtectionSessionStore(
        storage: ProtectionUserDefaultsStorage(defaults: appGroupDefaults),
        lock: ProtectionNSLock()
    )
    // The temporary-pause state machine (store + resume timer + legacy mirror
    // cleanup) lives in TemporaryProtectionPauseController; AppViewModel keeps the
    // @Published mirror and the pause/resume orchestration.
    private lazy var pauseController = TemporaryProtectionPauseController(appGroupDefaults: appGroupDefaults)
    // Single-flight gate for protection actions; isConfiguringVPN is the
    // published UI mirror and has no other writers.
    private lazy var protectionActionOrchestrator = ProtectionActionOrchestrator { [weak self] kind in
        self?.isConfiguringVPN = kind != nil
    }
    private lazy var filterSnapshotPreparationService: FilterSnapshotPreparationService? =
        catalogCacheURL.map { FilterSnapshotPreparationService(cacheDirectoryURL: $0) }
    private lazy var vpnLifecycleController = VPNLifecycleController(
        repository: NETunnelManagerRepository(
            providerBundleIdentifier: tunnelProviderBundleIdentifier,
            configurationName: vpnConfigurationName
        ),
        statusWaiter: ProtectionStatusChangeWaiter(),
        expectedProviderBundleIdentifier: tunnelProviderBundleIdentifier,
        waitPolicy: .init(statusPollInterval: Self.protectionStopStatusRefreshInterval),
        emitEvent: { [weak self] event, details in
            #if DEBUG || LAVA_QA_TOOLS
            self?.logVPNDebugEvent(event, details: details)
            #endif
        }
    )
    // Device-local persistence + state derivation for the encrypted backup
    // envelope (JSON + last-upload timestamp). Crypto, upload, passkey, and the
    // automatic-backup timer stay in this view model's orchestration.
    private let backupEnvelopeStore = BackupEnvelopeStore()
    private let backupKeychainStore = BackupKeychainStore()
    private let backupPasskeyCoordinator = BackupPasskeyCoordinator()
    private var pendingBackupPasskeyCredentialID: String?
    private var pendingBackupPasskey: PendingBackupPasskey?
    private var registeredBackupPasskey: RegisteredBackupPasskey?
    private let accountAuthService: AccountAuthService
    private let backupSyncService: (any BackupSyncServicing)?
    private let lavaSecurityPlusStore = LavaSecurityPlusStore()
    private let lavaSecurityPlusEntitlementSyncClient = LavaSecurityPlusEntitlementSyncClient(urlSession: .shared)
    private let protectionUserNotifications = ProtectionUserNotificationController()
    private let liveActivityController: AmbientProtectionPresenter = LavaLiveActivityController()
    private let iconPersonalizer: IconPersonalizing = UIKitIconPersonalizer()
    private var isRefreshingProtectionStatus = false
    private var needsProtectionStatusRefresh = false
    private var lastProtectionStatusRefresh: Date?
    private var awaitsProtectionOnHaptic = false
    private var diagnosticsReadGate = FileModificationReadGate()
    private var tunnelHealthReadGate = FileModificationReadGate()
    private var networkActivityLogReadGate = FileModificationReadGate()

    @Published private(set) var sourceStates: [String: SourceSyncState] = [
        DefaultCatalog.blockListProjectBasic.id: .pendingSourceUpdate,
        DefaultCatalog.blockListProjectPhishing.id: .pendingSourceUpdate,
        DefaultCatalog.blockListProjectScam.id: .pendingSourceUpdate,
        DefaultCatalog.blockListProjectRansomware.id: .pendingSourceUpdate,
        DefaultCatalog.phishingDatabaseActive.id: .pendingSourceUpdate,
        DefaultCatalog.hageziMultiLight.id: .pendingSourceUpdate,
        DefaultCatalog.hageziMultiNormal.id: .pendingSourceUpdate,
        DefaultCatalog.hageziMultiProMini.id: .pendingSourceUpdate,
        DefaultCatalog.hageziMultiPro.id: .pendingSourceUpdate,
        DefaultCatalog.oisdSmall.id: .pendingSourceUpdate
    ]

    init(loadVPNState: Bool = true, headless: Bool = false) {
        isHeadless = headless
        accountAuthService = AccountAuthService()
        accountAuthState = accountAuthService.state

        if let supabaseConfiguration = accountAuthService.supabaseConfiguration {
            backupSyncService = SupabaseBackupSyncService(configuration: supabaseConfiguration)
        } else {
            backupSyncService = nil
        }

        loadPersistedConfiguration()
        #if DEBUG || LAVA_QA_TOOLS
        applyLiveDNSSmokeTestConfigurationIfRequested()
        #endif
        // The background catalog refresh runs on a HEADLESS instance and must install no
        // side-effecting init work. Beyond loadPersistedConfiguration() above (a pure
        // read), every call here either writes shared state or schedules work that does,
        // any of which could clobber state the foreground/intents process owns:
        //   • startLavaSecurityPlusStore       — entitlement listener → persistConfigurationOnly
        //   • loadCustomizationPreferences      — persistLavaGuardLook / syncAppIcon / defaults.set (app-group)
        //   • loadTemporaryProtectionPause      — pauseController.onPauseCleared() removes the app-group
        //     pause keys, so a bg refresh seeing no pause would clear one the foreground just wrote
        //     (read→cleanup race)
        //   • scheduleTemporaryProtectionResume — resumes protection
        //   • live-activity authorization observer — reconcile churn
        // loadLavaGuardProgress / loadAutomaticBackupPreference / loadEncryptedBackupState are
        // read-only but unneeded headless. The sync/publish path depends on none of these: it
        // re-reads the live config and rebuilds rules from the sync results.
        if !headless {
            startLavaSecurityPlusStore()
            loadCustomizationPreferences()
            loadLavaGuardProgress()
            loadAutomaticBackupPreference()
            loadEncryptedBackupState()
            loadTemporaryProtectionPause()
            scheduleTemporaryProtectionResume()
            liveActivityController.startObservingAuthorizationChanges { [weak self] _ in
                self?.reconcileLiveActivity()
            }
            // A headless Focus switch that deferred (app was active) posts this nudge so the
            // foreground applies the pending-switch marker promptly, rather than waiting for the
            // next scene-phase reconcile. Delivered to the foreground app only (the headless poster
            // runs in this same app's background process), so it is the correct channel here.
            focusPendingSwitchObserver = DarwinNotificationObserver(
                name: FocusFilterSwitchSignal.darwinNotificationName
            ) { [weak self] in
                Task { @MainActor in
                    await self?.reconcilePendingFilterSwitch()
                }
            }
        }

        if loadVPNState {
            Task {
                if !hasCompletedOnboarding {
                    // Onboarding is not finished, so the user has not chosen to
                    // enable protection. Tear down any inherited VPN config (a
                    // reinstall over an existing profile, or a stale on-demand
                    // config iOS kept after a delete) FIRST — before any
                    // network-bound catalog work — so a fail-closed cold tunnel
                    // that iOS already brought up cannot linger mid-onboarding
                    // (block traffic / show filters red). (See the method.)
                    await neutralizeInheritedProtectionDuringOnboarding()
                }
                await loadCachedCatalogIfAvailable()
                await syncCatalogIfStale()
                if hasCompletedOnboarding {
                    // Connect-On-Demand may have already brought the tunnel up cold
                    // at launch; make sure it has a usable snapshot (see the method).
                    await reconcileTunnelSnapshotAfterLaunch()
                }
            }

            #if targetEnvironment(simulator)
            vpnMessage = "VPN testing requires a physical phone."
            vpnMessageIsError = false
            #else
            vpnStatusObserver = NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else {
                        return
                    }

                    // The notification already carries the change: read the
                    // cached manager's live connection instead of forcing a
                    // manager reload. loadAllFromPreferences itself re-posts
                    // NEVPNStatusDidChange, so a forced refresh here fed a
                    // self-sustaining storm (measured ~370 events/s on device,
                    // the source of the 134% CPU heat regression).
                    if self.tunnelManager != nil {
                        self.updateProtectionStatusFromCachedManager()
                    } else {
                        await self.refreshProtectionStatus(force: true)
                    }
                }
            }

            // The tunnel posts this Darwin nudge when its connectivity-relevant
            // health changes (reconnecting / network lost / needs-reconnect).
            // NEVPNStatus stays `.connected` through those, so without the nudge
            // the Dynamic Island only caught up on the next status poll. Pull the
            // fresh health over the reliable provider-message channel in response
            // (UR-6).
            tunnelHealthNudgeObserver = DarwinNotificationObserver(
                name: TunnelHealthSignal.darwinNotificationName
            ) { [weak self] in
                Task { @MainActor in
                    self?.handleTunnelHealthNudge()
                }
            }

            Task {
                await refreshProtectionStatus(force: true)
                await resumeTemporaryProtectionIfExpired()
            }
            #endif

            #if DEBUG
            logVPNDebugEvent("app-init", details: [
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
                "arguments": ProcessInfo.processInfo.arguments.joined(separator: " ")
            ])

            if Self.isVPNDebugProbeRequested {
                Task { [weak self] in
                    await self?.runVPNStartupDebugProbe()
                }
            }
            #endif
        }
    }

    deinit {
        automaticBackupTask?.cancel()
        // pauseController cancels its own resume timer in its deinit.
        Task { @MainActor [liveActivityController] in
            liveActivityController.stopObservingAuthorizationChanges()
        }
    }

    #if DEBUG || LAVA_QA_TOOLS
    private func applyLiveDNSSmokeTestConfigurationIfRequested() {
        guard Self.isLiveDNSSmokeTestRequested else {
            return
        }

        configuration.enabledBlocklistIDs = []
        configuration.allowedDomains = []
        configuration.blockedDomains = []
        configuration.customBlocklists = []
        configuration.qaProbeSet = .hosted
        if let customResolverAddress = Self.liveDNSSmokeCustomResolverOverride {
            configuration.resolverPresetID = DNSResolverPreset.customID
            configuration.customResolverAddress = customResolverAddress
        } else {
            let liveDNSSmokeResolverPresetID = Self.liveDNSSmokeResolverPresetIDOverride ?? DNSResolverPreset.google.id
            configuration.resolverPresetID = liveDNSSmokeResolverPresetID
            configuration.customResolverAddress = nil
        }

        configuration.customResolverSecondaryAddress = nil
        configuration.customResolverName = nil
        configuration.fallbackToDeviceDNS = true
        configuration.keepFilteringCounts = true
        configuration.keepDomainDiagnostics = true
        configuration.keepNetworkActivity = true
        rebuildEnabledBlockRules()
        try? persistConfigurationOnly()
        vpnMessage = "Live DNS smoke probes are active."
        vpnMessageIsError = false
        adminQAStatusMessage = "Live DNS smoke probes are active."
        logVPNDebugEvent("live-dns-smoke-configuration-persisted", details: [
            "resolverPresetID": configuration.resolverPresetID,
            "customResolverAddress": configuration.customResolverAddress ?? "nil",
            "resolverTransport": configuration.resolverPreset.transport.rawValue
        ])
    }
    #endif

    func loadLavaSecurityPlusProducts() async {
        isLoadingLavaSecurityPlusProducts = true
        await lavaSecurityPlusStore.loadProducts()
        lavaSecurityPlusOffers = lavaSecurityPlusStore.offers
        isLoadingLavaSecurityPlusProducts = false
    }

    func refreshLavaSecurityPlusEntitlements() async {
        guard !isRefreshingLavaSecurityPlusEntitlements else {
            return
        }

        isRefreshingLavaSecurityPlusEntitlements = true
        defer {
            isRefreshingLavaSecurityPlusEntitlements = false
        }

        let entitlement = await lavaSecurityPlusStore.refreshEntitlements()
        applyLavaSecurityPlusEntitlement(entitlement)
        hasCheckedLavaSecurityPlusEntitlements = true
        await syncLavaSecurityPlusEntitlementIfPossible(entitlement)
    }

    func purchaseLavaSecurityPlus(_ offer: LavaSecurityPlusOffer) async {
        guard !isPurchasingLavaSecurityPlus else {
            return
        }

        isPurchasingLavaSecurityPlus = true
        lavaSecurityPlusMessage = nil
        lavaSecurityPlusMessageIsError = false
        defer {
            isPurchasingLavaSecurityPlus = false
        }

        do {
            let appAccountToken = await currentLavaSecurityPlusAppAccountToken()
            let result = try await lavaSecurityPlusStore.purchase(
                offer,
                appAccountToken: appAccountToken
            )
            lavaSecurityPlusOffers = lavaSecurityPlusStore.offers

            switch result {
            case .purchased(let entitlement):
                applyLavaSecurityPlusEntitlement(entitlement)
                await syncLavaSecurityPlusEntitlementIfPossible(entitlement)
                if entitlement.isActive {
                    // The subscriber thank-you section already announces the
                    // active state, so skip the redundant confirmation line.
                    lavaSecurityPlusMessage = nil
                    lavaSecurityPlusMessageIsError = false
                } else {
                    lavaSecurityPlusMessage = "No active Lava Security Plus purchase was found."
                    lavaSecurityPlusMessageIsError = true
                }
            case .pending:
                lavaSecurityPlusMessage = "The App Store purchase is pending approval."
                lavaSecurityPlusMessageIsError = false
            case .cancelled:
                lavaSecurityPlusMessage = "Purchase cancelled"
                lavaSecurityPlusMessageIsError = false
            }
        } catch {
            lavaSecurityPlusMessage = "Could not complete purchase: \(error.localizedDescription)"
            lavaSecurityPlusMessageIsError = true
        }
    }

    func restoreLavaSecurityPlusPurchases() async {
        guard !isPurchasingLavaSecurityPlus else {
            return
        }

        isPurchasingLavaSecurityPlus = true
        lavaSecurityPlusMessage = "Checking the App Store for purchases."
        lavaSecurityPlusMessageIsError = false
        defer {
            isPurchasingLavaSecurityPlus = false
        }

        do {
            let entitlement = try await lavaSecurityPlusStore.restorePurchases()
            applyLavaSecurityPlusEntitlement(entitlement)
            await syncLavaSecurityPlusEntitlementIfPossible(entitlement)
            lavaSecurityPlusMessage = entitlement.isActive
                ? "Lava Security Plus is restored."
                : "No active Lava Security Plus purchase was found."
            lavaSecurityPlusMessageIsError = !entitlement.isActive
        } catch {
            lavaSecurityPlusMessage = "Could not restore purchases: \(error.localizedDescription)"
            lavaSecurityPlusMessageIsError = true
        }
    }

    func clearLavaSecurityPlusMessage() {
        lavaSecurityPlusMessage = nil
        lavaSecurityPlusMessageIsError = false
    }

    var customizationSummaryText: String {
        guard canOfferLiveActivities else {
            return appearancePreference.displayName
        }

        return usesLiveActivities
            ? "\(appearancePreference.displayName), Live Activities on"
            : "\(appearancePreference.displayName), Live Activities off"
    }

    var canOfferLiveActivities: Bool {
        liveActivityController.canOfferLiveActivities
    }

    var preferredColorScheme: ColorScheme? {
        appearancePreference.colorScheme
    }

    func setAppearancePreference(_ preference: LavaAppearancePreference) {
        guard appearancePreference != preference else {
            return
        }

        appearancePreference = preference
        defaults.set(preference.rawValue, forKey: appearancePreferenceDefaultsKey)
    }

    func setLavaGuardLook(_ look: GuardianShieldStyle) {
        guard isLavaGuardLookSelectable(look) else {
            return
        }

        guard lavaGuardLook != look else {
            persistLavaGuardLook(look)
            syncAppIcon(to: look)
            reconcileLiveActivity()
            return
        }

        lavaGuardLook = look
        persistLavaGuardLook(look)
        syncAppIcon(to: look)
        reconcileLiveActivity()
    }

    func lavaGuardAvailability(for look: GuardianShieldStyle) -> LavaGuardAvailability {
        let isSelectable = LavaGuardAvailabilityPolicy.isAvailable(
            guardID: look.lavaGuardID,
            isOriginal: look == .original,
            hasLavaSecurityPlus: configuration.hasLavaSecurityPlus,
            ledger: configuration.lavaGuardUnlocks,
            courtesyGuardID: lavaGuardLook.lavaGuardID
        )
        let showsProgressDetail = look.lavaGuardID == nextLavaGuardProgressDetailGuardID

        return LavaGuardAvailability(
            isSelectable: isSelectable,
            isRevealed: isSelectable,
            progress: lavaGuardProgress.progress(
                for: look.lavaGuardID,
                ledger: configuration.lavaGuardUnlocks
            ),
            isProgressEnabled: configuration.keepLavaGuardProgress,
            showsProgressDetail: showsProgressDetail
        )
    }

    private var nextLavaGuardProgressDetailGuardID: String? {
        guard configuration.keepLavaGuardProgress else {
            return nil
        }

        for goal in LavaGuardProgressPolicy.unlockGoals {
            let isAvailable = LavaGuardAvailabilityPolicy.isAvailable(
                guardID: goal.guardID,
                isOriginal: false,
                hasLavaSecurityPlus: configuration.hasLavaSecurityPlus,
                ledger: configuration.lavaGuardUnlocks,
                courtesyGuardID: lavaGuardLook.lavaGuardID
            )
            if !isAvailable {
                return goal.guardID
            }
        }

        return nil
    }

    private func isLavaGuardLookSelectable(_ look: GuardianShieldStyle) -> Bool {
        lavaGuardAvailability(for: look).isSelectable
    }

    func setUpdatesAppIconWithLavaGuard(_ isEnabled: Bool) {
        guard updatesAppIconWithLavaGuard != isEnabled else {
            syncAppIcon(to: lavaGuardLook)
            return
        }

        updatesAppIconWithLavaGuard = isEnabled
        defaults.set(isEnabled, forKey: updatesAppIconWithLavaGuardDefaultsKey)
        syncAppIcon(to: lavaGuardLook)
    }

    private func persistLavaGuardLook(_ look: GuardianShieldStyle) {
        defaults.set(look.rawValue, forKey: lavaGuardLookDefaultsKey)
        appGroupDefaults.set(look.rawValue, forKey: lavaGuardLookDefaultsKey)
    }

    private func syncAppIcon(to look: GuardianShieldStyle) {
        guard iconPersonalizer.supportsAppIconPersonalization else {
            return
        }

        let targetIconName = updatesAppIconWithLavaGuard ? look.alternateAppIconName : nil
        guard iconPersonalizer.currentAppIconName != targetIconName else {
            return
        }

        Task {
            do {
                try await iconPersonalizer.setAppIcon(targetIconName)
            } catch {
                #if DEBUG
                print("Failed to switch Lava app icon: \(error.localizedDescription)")
                #endif
            }
        }
    }

    func setUsesLiveActivities(_ isEnabled: Bool) {
        let canEnableLiveActivities = canOfferLiveActivities && isEnabled

        guard usesLiveActivities != canEnableLiveActivities else {
            return
        }

        usesLiveActivities = canEnableLiveActivities
        defaults.set(canEnableLiveActivities, forKey: usesLiveActivitiesDefaultsKey)
        reconcileLiveActivity()
    }

    /// User-facing label for the Live Activity pause-length stepper, e.g.
    /// "Pause length: 5 min".
    var liveActivityPauseLengthLabel: String {
        "Pause length: %d min".lavaLocalizedFormat(liveActivityPauseMinutes)
    }

    func setLiveActivityPauseMinutes(_ minutes: Int) {
        let clampedMinutes = LiveActivityPausePreference.clamp(minutes)
        guard liveActivityPauseMinutes != clampedMinutes else {
            return
        }

        liveActivityPauseMinutes = clampedMinutes
        // Persisted in the app-group defaults so the widget button label and the
        // pause intent (both out of process) resolve the same length.
        LiveActivityPausePreference.setMinutes(
            clampedMinutes,
            in: ProtectionUserDefaultsStorage(defaults: appGroupDefaults)
        )
        reconcileLiveActivity()
    }

    func setUsesLavaHaptics(_ isEnabled: Bool) {
        guard usesLavaHaptics != isEnabled else {
            return
        }

        usesLavaHaptics = isEnabled
        defaults.set(isEnabled, forKey: usesLavaHapticsDefaultsKey)

        // Play a sample tap when turning haptics on so the user feels what they just
        // enabled. Turning off stays silent — `play` is already gated by the new value.
        if isEnabled {
            ProtectionHapticFeedback.play(.selectionConfirmed)
        }
    }

    var protectionTitle: String {
        if isProtectionTemporarilyPaused {
            return "Paused"
        }

        switch vpnStatus {
        case .connected:
            return ProtectionConnectivityPresentation.title(for: protectionConnectivityAssessment.severity)
        case .connecting, .reasserting:
            return "Turning On"
        case .disconnecting:
            return "Turning Off"
        default:
            return "Protection Off"
        }
    }

    var protectionSubtitle: String {
        if isProtectionTemporarilyPaused {
            return "Lava will try to resume at \(formattedTemporaryProtectionResumeTime)"
        }

        switch vpnStatus {
        case .connected:
            return ProtectionConnectivityPresentation.subtitle(for: protectionConnectivityAssessment.severity)
        case .connecting, .reasserting:
            return "iOS is starting the local VPN"
        case .disconnecting:
            return "iOS is stopping the local VPN"
        case .invalid:
            return "Tap once to add local protection"
        default:
            return "Turn on local protection when you are ready"
        }
    }

    var protectionButtonTitle: String {
        if isProtectionTemporarilyPaused {
            return "Resume Now"
        }

        if vpnStatus == .connected,
           protectionConnectivityAssessment.primaryAction == .reconnect {
            return "Reconnect"
        }

        if isProtectionEnabledStatus(vpnStatus) {
            return "Turn Off"
        }

        return "Turn On"
    }

    var protectionPrimaryActionIsDisabled: Bool {
        ProtectionLifecyclePolicy.shouldDisablePrimaryAction(
            status: vpnStatus.protectionLifecycleStatus,
            isConfiguring: isConfiguringVPN
        )
    }

    var protectionSymbolName: String {
        if isProtectionTemporarilyPaused {
            return "pause.circle.fill"
        }

        switch vpnStatus {
        case .connected:
            switch protectionConnectivityAssessment.severity {
            case .healthy:
                return "checkmark.shield.fill"
            case .recovering:
                return "arrow.triangle.2.circlepath"
            case .usingDeviceDNSFallback, .usingEncryptedFallback:
                return "network"
            case .networkUnavailable:
                return "wifi.slash"
            case .dnsSlow, .needsReconnect:
                return "exclamationmark.shield.fill"
            }
        case .connecting, .reasserting:
            return "shield.righthalf.filled"
        default:
            return "shield"
        }
    }

    var protectionTint: Color {
        protectionTintRole.color
    }

    /// Semantic tint role for the protection surface. Portable (LavaSecCore) and
    /// resolved to a tuned, dark-mode-adaptive color via `ProtectionTintRole.color`
    /// on iOS — replaces the prior raw, non-adaptive `.green`/`.orange` returns.
    var protectionTintRole: ProtectionTintRole {
        if isProtectionTemporarilyPaused {
            return .paused
        }

        switch vpnStatus {
        case .connected:
            return .connected(severity: protectionConnectivityAssessment.severity)
        case .connecting, .reasserting, .disconnecting:
            return .transitioning
        default:
            return .inactive
        }
    }

    var protectionButtonTint: Color {
        if isProtectionTemporarilyPaused {
            return LavaStyle.safeControlGreen
        }

        switch vpnStatus {
        case .connected where protectionConnectivityAssessment.primaryAction == .reconnect:
            return LavaStyle.safeControlGreen
        case .connected, .connecting, .reasserting:
            return LavaStyle.quietControl
        default:
            return LavaStyle.safeControlGreen
        }
    }

    var protectionConnectivitySeverity: ProtectionConnectivitySeverity {
        protectionConnectivityAssessment.severity
    }

    var isProtectionTemporarilyPaused: Bool {
        vpnStatus == .connected && temporaryProtectionPauseUntil != nil
    }

    var showsTemporaryProtectionPauseControls: Bool {
        vpnStatus == .connected
            && protectionConnectivityAssessment.primaryAction != .reconnect
            // With no network path there is nothing to pause; offering it here
            // mirrors the false "On" the Dynamic Island used to show.
            && protectionConnectivityAssessment.severity != .networkUnavailable
            && !isConfiguringVPN
            && !isProtectionTemporarilyPaused
    }

    var formattedTemporaryProtectionResumeTime: String {
        guard let temporaryProtectionPauseUntil else {
            return Date().formatted(date: .omitted, time: .shortened)
        }

        return temporaryProtectionPauseUntil.formatted(date: .omitted, time: .shortened)
    }

    var guardDNSFlowStepStatus: GuardFlowStepStatus {
        GuardStepHealthPolicy.dnsStatus(
            isProtectionActive: vpnStatus == .connected,
            configuredResolver: configuration.resolverPreset,
            health: tunnelHealth,
            connectivitySeverity: protectionConnectivitySeverity
        )
    }

    var guardDNSFlowStepDetail: String {
        guardDNSFlowStepDetailComponents.displayText
    }

    var guardDNSFlowStepDetailComponents: GuardFlowDNSDetail {
        GuardStepHealthPolicy.dnsDetailComponents(
            configuredResolver: configuration.resolverPreset,
            health: tunnelHealth,
            connectivitySeverity: protectionConnectivitySeverity
        )
    }

    var guardFilterFlowStepStatus: GuardFlowStepStatus {
        GuardStepHealthPolicy.filterStatus(
            isProtectionActive: vpnStatus == .connected,
            filtersConfigured: guardFiltersConfigured,
            hasFilterIssue: guardFiltersHaveIssue,
            filterSnapshotUsable: guardFilterSnapshotUsable,
            filterSnapshotLoadComplete: guardConfiguredBlocklistRuleSetsLoaded
        )
    }

    // The Internet and Phone endpoints bookend the protected path: green while
    // the tunnel is up, grey when protection is off so the whole flow (steps and
    // connectors) reads as inactive together.
    var guardEndpointFlowStepStatus: GuardFlowStepStatus {
        vpnStatus == .connected ? .healthy : .inactive
    }

    private var protectionConnectivityAssessment: ProtectionConnectivityAssessment {
        ProtectionConnectivityPolicy.assessment(
            isConnected: vpnStatus == .connected,
            health: tunnelHealth
        )
    }

    var guardPanelMessage: String? {
        if vpnMessageIsError {
            return vpnMessage
        }

        if !isVPNConfigurationInstalled,
           vpnMessage == Self.vpnPermissionPromptMessage {
            return vpnMessage
        }

        return nil
    }

    var guardPanelMessageIsError: Bool {
        vpnMessageIsError
    }

    var enabledBlocklists: [BlocklistSource] {
        blocklists.filter { configuration.enabledBlocklistIDs.contains($0.id) }
    }

    var draftEnabledBlocklists: [BlocklistSource] {
        let enabledIDs = filterEditDraft?.enabledBlocklistIDs ?? configuration.enabledBlocklistIDs
        return blocklists.filter { enabledIDs.contains($0.id) }
    }

    var stagedBlockedDomainCount: Int {
        (filterEditDraft?.blockedDomains ?? configuration.blockedDomains).count
    }

    var stagedAllowedDomainCount: Int {
        (filterEditDraft?.allowedDomains ?? configuration.allowedDomains).count
    }

    var blocklists: [BlocklistSource] {
        DefaultCatalog.selectableCuratedSources(
            availableSourceIDs: Set(catalogSourcesByID.keys),
            enabledSourceIDs: configuration.enabledBlocklistIDs
        )
    }

    var blocklistsConfigured: Bool {
        !configuration.enabledBlocklistIDs.isEmpty
    }

    var customBlocklists: [CustomBlocklistSource] {
        configuration.customBlocklists
    }

    func stagedCustomBlocklistsForDisplay() -> [CustomBlocklistSource] {
        let enabledIDs = filterEditDraft?.enabledBlocklistIDs ?? configuration.enabledBlocklistIDs
        return displayedCustomBlocklists.filter { enabledIDs.contains($0.id) }
    }

    func stagedCustomBlocklistsForPicker() -> [CustomBlocklistSource] {
        displayedCustomBlocklists
    }

    func customBlocklistPickerTitle(for source: CustomBlocklistSource) -> String {
        if source.displayName == source.sourceURL.host {
            return source.sourceURL.absoluteString
        }

        return source.displayName
    }

    private func customBlocklistDisplayKey(for source: CustomBlocklistSource) -> String {
        customBlocklistPickerTitle(for: source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    func customBlocklistEntryCount(for source: CustomBlocklistSource) -> Int? {
        cachedBlockRuleSets[source.id]?.count
    }

    func isCustomBlocklist(_ sourceID: String) -> Bool {
        displayedCustomBlocklists.contains { $0.id == sourceID }
    }

    private var displayedCustomBlocklists: [CustomBlocklistSource] {
        // While editing, the draft is authoritative. It starts as a full copy of the
        // saved custom blocklists (`FilterEditDraft.init(configuration:)`) and records
        // both adds and deletes, so it already is the set to show. Merging it back with
        // `configuration` would resurrect a custom list the draft just deleted — making
        // a trash → Delete leave the row on screen. Order is preserved: the draft keeps
        // the saved order, with any new additions appended.
        if let filterEditDraft {
            return filterEditDraft.customBlocklists
        }
        return filterDetailBaseline.customBlocklists
    }

    var allowlistConfigured: Bool {
        !configuration.allowedDomains.isEmpty
    }

    private var guardFiltersConfigured: Bool {
        !configuration.enabledBlocklistIDs.isEmpty || !configuration.blockedDomains.isEmpty
    }

    private var guardFiltersHaveIssue: Bool {
        guard guardFiltersConfigured else {
            return false
        }

        if catalogStatusIsError {
            return true
        }

        if case .failed = filterPreparationState {
            return true
        }

        return false
    }

    private var guardConfiguredBlocklistRuleSetsLoaded: Bool {
        guard !configuration.enabledBlocklistIDs.isEmpty else {
            return true
        }

        return configuration.enabledBlocklistIDs.allSatisfy { sourceID in
            cachedBlockRuleSets[sourceID] != nil
        }
    }

    private var guardFilterSnapshotUsable: Bool {
        if !configuration.enabledBlocklistIDs.isEmpty {
            return compiledBlocklistRuleCount > 0
        }

        return !configuration.blockedDomains.isEmpty
    }

    var blockedFiltersSummaryText: String {
        let listCount = configuration.enabledBlocklistIDs.count
        let domainCount = configuration.blockedDomains.count
        let configurationStatus = listCount == 0 && domainCount == 0 ? "Not configured" : "Configured"
        let freshnessStatus = blocklistCatalogIsFresh ? "Up-to-date" : "Requires update"

        return "%@. %@".lavaLocalizedFormat(configurationStatus.lavaLocalized, freshnessStatus.lavaLocalized)
    }

    var allowedExceptionsSummaryText: String {
        configuration.allowedDomains.isEmpty ? "Not configured" : "Configured"
    }

    var blocklistSummaryText: String {
        listSummary(
            count: configuration.enabledBlocklistIDs.count,
            singular: "list",
            plural: "lists",
            values: configuration.enabledBlocklistIDs
                .map { blocklistName(for: $0) }
                .sorted()
        )
    }

    var allowlistSummaryText: String {
        listSummary(
            count: configuration.allowedDomains.count,
            singular: "domain",
            plural: "domains",
            values: Array(configuration.allowedDomains).sorted()
        )
    }

    var allowlistCountText: String {
        "\(configuration.allowedDomains.count)/\(configuration.limits.maxAllowedDomains)"
    }

    var blockedDomainCountText: String {
        "\(configuration.blockedDomains.count)/\(configuration.limits.maxBlockedDomains)"
    }

    var filterDraftDiff: FilterConfigurationDiff {
        let baseline = filterDetailBaseline
        guard let filterEditDraft else {
            return FilterConfigurationDiff(
                from: baseline.filterSelection,
                to: baseline.filterSelection
            )
        }

        return FilterConfigurationDiff(
            from: baseline.filterSelection,
            to: filterEditDraft.selection
        )
    }

    var filterDraftHasChanges: Bool {
        !filterDraftDiff.isEmpty
    }

    var filterDraftValidationMessage: String? {
        guard let draft = filterEditDraft else {
            return nil
        }

        if enabledIDsExceedSoftRuleBudget(draft.enabledBlocklistIDs) {
            return filterRuleBudgetMessage()
        }

        if draft.blockedDomains.count > configuration.limits.maxBlockedDomains {
            return "You can keep up to \(configuration.limits.maxBlockedDomains) additional blocked domains."
        }

        if draft.allowedDomains.count > configuration.limits.maxAllowedDomains {
            return "You can keep up to \(configuration.limits.maxAllowedDomains) allowed exceptions."
        }

        return nil
    }

    var filterDraftCanConfirm: Bool {
        filterDraftHasChanges && filterDraftValidationMessage == nil
    }

    var filterDraftChangeCountText: String {
        let count = filterDraftDiff.changeCount
        return count == 1
            ? "%d change".lavaLocalizedFormat(count)
            : "%d changes".lavaLocalizedFormat(count)
    }

    var blockRateText: String {
        diagnostics.summary.blockRate.formatted(.percent.precision(.fractionLength(0)))
    }

    var activityDigestTitle: String {
        let blocked = diagnostics.summary.blockedCount
        guard blocked > 0 else {
            return "Nothing blocked yet today"
        }

        let noun = blocked == 1 ? "domain" : "domains"
        return "Lava blocked \(blocked.formatted()) \(noun) today"
    }

    var activityDigestSubtitle: String {
        let allowed = diagnostics.summary.allowedCount
        guard diagnostics.summary.totalCount > 0 else {
            return "Once protection sees DNS activity, Lava will summarize it here."
        }

        return "\(allowed.formatted()) allowed locally. All local logs stay on this phone."
    }

    /// Glanceable stat under the Guard "How Lava filters" row — the number of
    /// rules currently compiled into protection. Uses `compiledRuleCount` (the
    /// same total the Filters screen headlines as "rules in effect"), so manual
    /// blocked domains count even when no curated blocklist is enabled.
    var guardFiltersRowStat: String {
        let count = compiledRuleCount
        guard count > 0 else {
            return "No filter active yet"
        }

        return count == 1
            ? "%@ rule active".lavaLocalizedFormat(count.formatted())
            : "%@ rules active".lavaLocalizedFormat(count.formatted())
    }

    /// Glanceable stat under the Guard "What Lava has caught" row — how many
    /// domains Lava has blocked on this phone today.
    var guardActivityRowStat: String {
        let blocked = diagnostics.summary.blockedCount
        guard blocked > 0 else {
            return "Nothing blocked yet today"
        }

        let percent = diagnostics.summary.blockRate.formatted(
            .percent.precision(.fractionLength(0))
        )
        return "%@ blocked today".lavaLocalizedFormat("\(blocked.formatted()) (\(percent))")
    }

    var localLogsStatusText: String {
        let enabledLogNames = [
            configuration.keepFilteringCounts ? "counts" : nil,
            configuration.keepDomainDiagnostics ? "domain history" : nil,
            configuration.keepNetworkActivity ? "network activity" : nil,
            configuration.keepLavaGuardProgress ? "Lava Guard progress" : nil
        ].compactMap { $0 }
        let totalCount = 4

        let enabledCount = enabledLogNames.count
        switch enabledCount {
        case 0:
            return "All local logs off"
        case totalCount:
            return "All local logs on"
        default:
            let enabledSummary = enabledLogNames.joined(separator: ", ")
            let displayedSummary = enabledSummary.prefix(1).uppercased() + enabledSummary.dropFirst()
            return "\(displayedSummary) on"
        }
    }


    var planStatusText: String {
        configuration.hasLavaSecurityPlus ? "Lava Security Plus" : "Free plan"
    }

    var accountStatusText: String {
        switch accountAuthState {
        case .signedIn(let connections),
             .signingIn(let connections, _):
            if connections.apple != nil && connections.google != nil {
                return "Signed in with Apple and Google"
            }
            if connections.apple != nil {
                return "Signed in with Apple"
            }
            if connections.google != nil {
                return "Signed in with Google"
            }
            return "Signing in"
        case .notConfigured:
            return "Account setup pending"
        case .signedOut:
            return "Continue without account"
        }
    }

    var accountStatusDetailText: String {
        if let accountAuthMessage {
            return accountAuthMessage
        }

        return switch accountAuthState {
        case .signedIn,
             .signingIn where isAccountSignedIn:
            if let signedInProviderName {
                "Signed in with \(signedInProviderName). Encrypted backup can upload to your account."
            } else {
                "Encrypted backup can upload to your account."
            }
        case .signingIn:
            "Opening sign-in."
        case .notConfigured:
            "Account login needs the Supabase URL and publishable key in the app configuration."
        case .signedOut:
            "Sign in only when you want encrypted backup upload or account services."
        }
    }

    var signedInProviderName: String? {
        let providers = accountAuthState.connections.all.map(\.provider.displayName)
        switch providers.count {
        case 0:
            return nil
        case 1:
            return providers[0]
        default:
            return providers.dropLast().joined(separator: ", ") + " and " + providers.last!
        }
    }

    var accountConnections: [AccountAuthConnection] {
        accountAuthState.connections.all
    }

    var isAccountSignInInProgress: Bool {
        if accountSignInProviderInProgress != nil {
            return true
        }

        return accountAuthState.signingInProvider != nil
    }

    var isAppleSignInInProgress: Bool {
        (accountSignInProviderInProgress ?? accountAuthState.signingInProvider) == .apple
    }

    var isGoogleSignInInProgress: Bool {
        (accountSignInProviderInProgress ?? accountAuthState.signingInProvider) == .google
    }

    var isAppleAccountConnected: Bool {
        accountAuthState.connections[.apple] != nil
    }

    var isGoogleAccountConnected: Bool {
        accountAuthState.connections[.google] != nil
    }

    var isAccountSignedIn: Bool {
        !accountAuthState.connections.isEmpty
    }

    var isEncryptedBackupConfigured: Bool {
        encryptedBackupState.isConfigured
    }

    var appleSignInActionTitle: String {
        if isAppleAccountConnected {
            return "Signed in with Apple"
        }

        return isAppleSignInInProgress ? "Opening Apple sign-in" : "Sign in with Apple"
    }

    var googleSignInActionTitle: String {
        if isGoogleAccountConnected {
            return "Signed in with Google"
        }

        return isGoogleSignInInProgress ? "Opening Google sign-in" : "Sign in with Google"
    }

    var encryptedBackupSummaryText: String {
        encryptedBackupState.displayText(isAccountSignedIn: isAccountSignedIn).summary
    }

    var encryptedBackupInfoTitle: String {
        encryptedBackupSummaryText
    }

    func setAutomaticBackupEnabled(_ isEnabled: Bool) {
        guard isAutomaticBackupEnabled != isEnabled else {
            return
        }

        isAutomaticBackupEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: automaticBackupEnabledDefaultsKey)

        if !isEnabled {
            automaticBackupTask?.cancel()
            automaticBackupTask = nil
        }
    }

    var dnsResolverSummaryText: String {
        guard configuration.fallbackToDeviceDNS,
              configuration.resolverPresetID != DNSResolverPreset.device.id
        else {
            return configuration.resolverPreset.shortDisplayName
        }

        return "\(configuration.resolverPreset.shortDisplayName) + Fallback"
    }

    var supportsDNSOverQUIC: Bool {
        Self.supportsDNSOverQUICRuntime
    }

    var deviceDNSFallbackDetailText: String {
        if #available(iOS 26.0, *) {
            return "When the selected resolver has repeated trouble, Lava can temporarily use Device DNS for allowed lookups and then probe more often to switch back."
        }

        return "When the selected resolver has repeated trouble, Lava can temporarily use Device DNS for allowed lookups and then probe more often to switch back. On iOS 17-25, this is best effort and might not always work depending on network conditions."
    }

    var deviceDNSResolverDetailText: String {
        if #available(iOS 26.0, *) {
            return "Uses the DNS resolver from the current Wi-Fi or cellular network while Lava still filters locally."
        }

        return "Uses the DNS resolver Lava can capture from the current Wi-Fi or cellular network. On iOS 17-25, this might not always work depending on network conditions."
    }

    var filterFreshnessText: String {
        guard catalogGeneratedAt != nil else {
            return "Filter not updated yet"
        }

        return "Filter updated: \(catalogUpdatedAtText)"
    }

    var configuredBlockedDomainCountText: String {
        let count = compiledRuleCount
        return count == 1
            ? "%@ blocked domain".lavaLocalizedFormat(count.formatted())
            : "%@ blocked domains".lavaLocalizedFormat(count.formatted())
    }

    var configuredBlockedDomainNumberText: String {
        compiledRuleCount.formatted()
    }

    var configuredProtectedDomainNumberText: String {
        protectedRuleCount.formatted()
    }

    var configuredAllowlistExceptionNumberText: String {
        configuration.allowedDomains.count.formatted()
    }

    var configuredAllowlistExceptionCountText: String {
        let count = configuration.allowedDomains.count
        return count == 1
            ? "%@ exception configured".lavaLocalizedFormat(configuredAllowlistExceptionNumberText)
            : "%@ exceptions configured".lavaLocalizedFormat(configuredAllowlistExceptionNumberText)
    }

    var catalogVersionText: String {
        catalogVersion ?? "Not updated yet"
    }

    var catalogUpdatedAtText: String {
        guard let catalogGeneratedAt else {
            return "Not updated yet"
        }

        return Self.formatCatalogDate(catalogGeneratedAt)
    }

    var catalogUpdateDetailText: String {
        guard catalogGeneratedAt != nil else {
            return "Not updated yet"
        }

        return "Updated \(catalogUpdatedAtText)"
    }

    var blocklistCatalogIsFresh: Bool {
        BlocklistCatalogFreshnessPolicy(maxAge: catalogSyncFreshnessInterval)
            .isFresh(age: blocklistCatalogAge, statusIsError: catalogStatusIsError)
    }

    var blocklistCatalogFreshnessTitle: String {
        if blocklistCatalogIsFresh {
            return "Filter up to date"
        }

        return "Update recommended"
    }

    var blocklistCatalogFreshnessDescription: String {
        guard let age = blocklistCatalogAge else {
            return "Lava will fetch the source catalog before preparing the filter."
        }

        return "Last checked: \(Self.formatRelativeCatalogAge(age, maxFreshnessAge: catalogSyncFreshnessInterval))"
    }

    var blocklistCatalogFreshnessSystemImage: String {
        blocklistCatalogIsFresh ? "checkmark.circle.fill" : "arrow.clockwise.circle.fill"
    }

    var blocklistCatalogFreshnessTint: Color {
        blocklistCatalogIsFresh ? LavaStyle.safeGreen : LavaStyle.secondaryText
    }

    var catalogRefreshButtonTitle: String {
        if isSyncingCatalog {
            return "Fetching from the server..."
        }

        if catalogStatusMessage == "Refreshed" {
            return "Refreshed"
        }

        return "Refresh now"
    }

    private var blocklistCatalogAge: TimeInterval? {
        guard let catalogCacheURL else {
            return nil
        }

        return BlocklistCatalogSynchronizer.cachedCatalogAge(in: catalogCacheURL)
    }

    var blocklistCatalogLastUpdatedText: String {
        guard let age = blocklistCatalogAge else {
            return "Not updated yet"
        }

        return Self.formatRelativeCatalogAge(age, maxFreshnessAge: catalogSyncFreshnessInterval)
    }

    var tunnelNetworkText: String {
        switch tunnelHealth.networkKind {
        case .unknown:
            "Unknown"
        case .wifi:
            "Wi-Fi"
        case .cellular:
            "Cellular"
        case .wired:
            "Wired"
        case .other:
            "Other"
        }
    }

    var tunnelNetworkChangeText: String {
        tunnelHealth.networkChangeCount.formatted()
    }

    var tunnelNetworkPathText: String {
        tunnelHealth.networkPathIsSatisfied ? "Available" : "Lost"
    }

    var tunnelResolverRuntimeResetText: String {
        tunnelHealth.resolverRuntimeResetCount.formatted()
    }

    var tunnelLastNetworkChangeText: String {
        formattedTunnelHealthDate(tunnelHealth.lastNetworkChangeAt)
    }

    var tunnelLastResolverRuntimeResetText: String {
        guard let resetAt = tunnelHealth.lastResolverRuntimeResetAt else {
            return "None yet"
        }

        let reason = tunnelHealth.lastResolverRuntimeResetReason ?? "unknown"
        return "\(resetAt.formatted(date: .omitted, time: .shortened)) · \(reason)"
    }

    var tunnelLastUpstreamSuccessText: String {
        formattedTunnelHealthDate(tunnelHealth.lastUpstreamSuccessAt)
    }

    var tunnelLastUpstreamFailureText: String {
        formattedTunnelHealthDate(tunnelHealth.lastUpstreamFailureAt)
    }

    private func formattedTunnelHealthDate(_ date: Date?) -> String {
        guard let date else {
            return "None yet"
        }

        return date.formatted(date: .omitted, time: .shortened)
    }

    func blocklistCatalogSubtitleText(for blocklist: BlocklistSource) -> String {
        blocklist.licenseName
    }

    func blocklistEntryCount(for blocklist: BlocklistSource) -> Int? {
        catalogSourcesByID[blocklist.id]?.entryCount
    }

    func blocklistRuleCountText(for blocklist: BlocklistSource) -> String {
        guard let source = catalogSourcesByID[blocklist.id] else {
            return "Waiting for source update"
        }

        return "%@ rules".lavaLocalizedFormat(source.entryCount.formatted())
    }

    func blocklistMetadataText(for sourceID: String) -> String? {
        if let blocklist = blocklists.first(where: { $0.id == sourceID }) {
            return blocklistRuleCountText(for: blocklist)
        }

        guard customBlocklistSource(for: sourceID) != nil else {
            return nil
        }

        if let rules = cachedBlockRuleSets[sourceID] {
            return "%@ rules · Custom List".lavaLocalizedFormat(rules.count.formatted())
        }

        return "Pending refresh · Custom List"
    }

    // MARK: - Filter-rules budget

    /// Snapshot of how the staged selection sits against the tier budget, for
    /// the picker meter. `knownRuleCount` sums per-list rule counts (a
    /// conservative OVER-estimate of the deduped union — the authoritative count
    /// is enforced at compile time); `pendingLists` is the number of selected
    /// lists whose rule count is not yet known (custom not fetched, or catalog
    /// not synced) and must not be silently treated as zero.
    struct FilterRuleBudgetStatus {
        let knownRuleCount: Int
        let budget: Int
        let pendingLists: Int

        /// 0...1, capped, so the bar never renders past 100%.
        var fraction: Double {
            FilterRuleBudget.fraction(knownRuleCount: knownRuleCount, budget: budget)
        }

        /// At or over the displayed budget — drives the orange/error bar.
        var isAtOrOverBudget: Bool { knownRuleCount >= budget }

        /// Rule count to render in the "X of budget" copy. Clamped to the budget
        /// while the selection is still savable (within the soft-ceiling margin)
        /// so a savable selection never reads as "506K of 500K"; shows the true
        /// count once over the ceiling, when a save is no longer possible.
        var displayedRuleCount: Int {
            FilterRuleBudget.displayedRuleCount(knownRuleCount: knownRuleCount, budget: budget)
        }

        /// Nothing is counted yet but lists are still resolving (catalog not
        /// synced / custom not fetched). The meter cannot honestly claim
        /// headroom, so the UI shows a neutral "calculating" state rather than a
        /// confident empty-green bar.
        var isIndeterminate: Bool { pendingLists > 0 && knownRuleCount == 0 }
    }

    /// The subscription-tier filter-rule budget (Free 500K / Plus 2M). The hard
    /// device guardrail (`FilterSnapshotMemoryBudget.maxFilterRuleCount` ≈ 3.26M)
    /// sits above this and is enforced at compile time, never as a paywall.
    var filterRuleBudget: Int {
        configuration.limits.maxFilterRules
    }

    private var stagedEnabledBlocklistIDs: Set<String> {
        filterEditDraft?.enabledBlocklistIDs ?? filterDetailBaseline.enabledBlocklistIDs
    }

    /// Manual blocked + allowed domains are each compiled as a filter rule, so
    /// they consume the same budget as the blocklists and are counted together.
    private var stagedManualRuleCount: Int {
        let baseline = filterDetailBaseline
        let blocked = filterEditDraft?.blockedDomains ?? baseline.blockedDomains
        let allowed = filterEditDraft?.allowedDomains ?? baseline.allowedDomains
        return blocked.count + allowed.count
    }

    /// Selection-time estimate for a set of enabled lists: the sum of per-list
    /// rule counts (known), plus a count of lists whose size is not yet known.
    /// Over-counts the deduped union, so it is a conservative upper bound.
    func projectedFilterRuleCount(forEnabledIDs enabledIDs: Set<String>) -> (known: Int, pendingLists: Int) {
        var known = 0
        var pending = 0
        for id in enabledIDs {
            // entryCount 0 is the unresolved/built-in-fallback placeholder, not a
            // genuinely empty list — treat it as not-yet-known so it counts as
            // pending instead of a misleading known 0.
            if let entryCount = catalogSourcesByID[id]?.entryCount, entryCount > 0 {
                known += entryCount
            } else if let ruleCount = cachedBlockRuleSets[id]?.count {
                known += ruleCount
            } else {
                pending += 1
            }
        }
        return (known, pending)
    }

    func filterRuleBudgetStatus(forEnabledIDs enabledIDs: Set<String>) -> FilterRuleBudgetStatus {
        let projection = projectedFilterRuleCount(forEnabledIDs: enabledIDs)
        return FilterRuleBudgetStatus(
            knownRuleCount: projection.known + stagedManualRuleCount,
            budget: filterRuleBudget,
            pendingLists: projection.pendingLists
        )
    }

    var stagedFilterRuleBudgetStatus: FilterRuleBudgetStatus {
        filterRuleBudgetStatus(forEnabledIDs: stagedEnabledBlocklistIDs)
    }

    /// True when the *known* rules for this selection already exceed the soft
    /// ceiling. Pending (unknown) lists are not counted here — they are caught
    /// at compile time, by design (smoother flow over selection-time precision).
    func enabledIDsExceedSoftRuleBudget(_ enabledIDs: Set<String>) -> Bool {
        let known = projectedFilterRuleCount(forEnabledIDs: enabledIDs).known + stagedManualRuleCount
        return FilterRuleBudget.exceedsSoftCeiling(knownRuleCount: known, budget: filterRuleBudget)
    }

    /// Tier-appropriate over-budget copy (free offers an upgrade; paid does not).
    private func filterRuleBudgetMessage() -> String {
        let budgetText = AppViewModel.abbreviatedRuleCount(filterRuleBudget)
        if configuration.hasLavaSecurityPlus {
            return "Lava Plus includes up to \(budgetText) filter rules. Remove a list to add more."
        }
        return "Free protection includes up to \(budgetText) filter rules. Remove a list or upgrade to Plus."
    }

    /// Compact filter-rule count for tight UI: 500K, 1.2M, 2M.
    static func abbreviatedRuleCount(_ count: Int) -> String {
        FilterRuleBudget.abbreviated(count)
    }

    func syncCatalogIfNeeded() async {
        guard catalogVersion == nil else {
            return
        }

        await syncCatalog()
    }

    /// The baseline filter fields the detail page displays and diffs an edit draft against:
    /// the ACTIVE filter (already mirrored in `configuration`) when no non-active target is
    /// set, otherwise the chosen non-active filter's saved fields. Only the four filter-scoped
    /// fields are substituted; device-global fields (tier limits, protection-on) stay as the
    /// live config's. When `filterEditTargetID == nil` this returns `configuration` unchanged,
    /// so the active-filter path is byte-identical to before this feature.
    /// Which filter the current edit context belongs to: the non-active "View" target if one is
    /// set, otherwise the active filter. The detail-page draft accessors operate on this filter.
    private var currentEditKey: String {
        filterEditTargetID ?? activeFilterID
    }

    /// The edit draft for the filter the detail page is currently showing — a proxy over
    /// `filterEditDrafts[currentEditKey]`. Reading/writing it transparently targets that filter's
    /// own entry, so all the staged-display / predicate / diff / mutate accessors below need no
    /// change. Setting nil removes the entry. (The active-apply path keys by `activeFilterID`
    /// directly — see `activeFilterDraft` — so Domain History never depends on `filterEditTargetID`.)
    var filterEditDraft: FilterEditDraft? {
        get { filterEditDrafts[currentEditKey] }
        set { filterEditDrafts[currentEditKey] = newValue }
    }

    /// The active filter's edit draft, addressed by `activeFilterID` regardless of which filter the
    /// detail page is showing. The full prepare+publish+reload apply (active My-filter save and
    /// Domain History) operates on this, so it's correct even if a non-active detail page is still
    /// mounted with a different `filterEditTargetID`.
    var activeFilterDraft: FilterEditDraft? {
        get { filterEditDrafts[activeFilterID] }
        set { filterEditDrafts[activeFilterID] = newValue }
    }

    private var filterDetailBaseline: AppConfiguration {
        guard let id = filterEditTargetID, let target = library.filter(id: id) else {
            return configuration
        }
        var baseline = configuration
        baseline.enabledBlocklistIDs = target.enabledBlocklistIDs
        baseline.customBlocklists = target.customBlocklists
        baseline.blockedDomains = target.blockedDomains
        baseline.allowedDomains = target.allowedDomains
        return baseline
    }

    /// The filter the detail page is currently showing: the non-active "View" target if one is
    /// set, otherwise the active filter. Drives the page title and the rules metric.
    var detailFilter: Filter {
        if let id = filterEditTargetID, let target = library.filter(id: id) {
            return target
        }
        return library.activeFilter
    }

    /// Whether the detail page is showing a NON-active filter (opened via "View"). Such a
    /// filter is edited library-only — no prepare, no tunnel reload, no auto-refresh.
    var isViewingNonActiveFilter: Bool {
        filterEditTargetID != nil
    }

    /// Whether the ACTIVE filter specifically has an unsaved draft (addressed by its own id, not
    /// the current detail target). Domain History edits the active filter, so it gates on this —
    /// a non-active filter's preserved draft lives under a different key and is irrelevant to it.
    var hasUnsavedActiveFilterDraft: Bool {
        guard let draft = activeFilterDraft else { return false }
        return !FilterConfigurationDiff(from: configuration.filterSelection, to: draft.selection).isEmpty
    }

    /// Open the My-filter detail page for `id` (`nil`/active id = the active filter). Just points
    /// the page at that filter; its own per-filter draft (in `filterEditDrafts`) resumes if present,
    /// so opening any filter never disturbs another filter's draft.
    func beginViewingFilterDetail(id: String?) {
        filterEditTargetID = (id == nil || id == library.activeFilterID) ? nil : id
        filterPreparationState = .idle
    }

    /// Called when the detail page disappears (a real pop). Drops a CLEAN draft for the filter the
    /// page was showing (no edits worth keeping); a DIRTY draft stays in its per-filter slot so
    /// re-opening that filter resumes the edit. Then stops targeting (the proxy falls back to the
    /// active filter). Unified across active/non-active — per-filter keying means there's no shared
    /// slot to leak between filters.
    func endViewingFilterDetail() {
        guard !isFilterPreparationScreenPresented, !filterPreparationState.isPreparing else {
            return
        }
        if !filterDraftHasChanges {
            filterEditDraft = nil   // removes the clean draft for the shown filter
        }
        filterEditTargetID = nil
    }

    /// Whether the filter the detail page is currently showing has an in-progress edit draft.
    /// (Per-filter storage makes "is editing" simply "this filter has a draft" — the old edit-mode
    /// flag was vestigial.)
    var isFilterEditing: Bool {
        filterEditDraft != nil
    }

    func beginFilterEditing() {
        filterEditDraft = FilterEditDraft(configuration: filterDetailBaseline)
        filterPreparationState = .idle
    }

    func cancelFilterEditing() {
        filterEditDraft = nil
        filterPreparationState = .idle
        isFilterPreparationScreenPresented = false
    }

    func keepCurrentFiltersAfterPrepareFailure() {
        filterEditDraft = nil
        pendingSwitchFilterID = nil
        filterPreparationState = .idle
        isFilterPreparationScreenPresented = false
    }

    func returnToFilterEditAfterPrepareFailure() {
        filterPreparationState = .idle
        isFilterPreparationScreenPresented = false
    }

    /// Whether the preparation-failure screen should offer "Back to Edit"/"Back to Review".
    /// A filter SWITCH has no edit draft to return to (its only recoveries are "Try Again",
    /// which re-runs the switch, and "Keep Current Filter"), so the secondary button is hidden
    /// for it. An edit apply or a Domain History apply (no pending switch) still offers it.
    var filterPreparationFailureOffersEditReturn: Bool {
        pendingSwitchFilterID == nil
    }

    /// Called from a superseded switch / draft-apply bail. The preparation cover it presented is
    /// only ever dismissed by a cover-driving owner (a switch or a draft apply). If the new owner
    /// is a non-cover-driver (a backup restore or shared-config import) it never touches the cover,
    /// so a silent return would strand the user on the full-screen spinner — dismiss it here. If the
    /// new owner IS another cover-driver, leave the cover to it (it set its own state up).
    private func dismissPreparationCoverIfStrandedBySupersession() {
        guard !configurationReplacementGate.currentOwnerOwnsPreparationCover else { return }
        filterPreparationState = .idle
        isFilterPreparationScreenPresented = false
        pendingSwitchFilterID = nil
    }

    /// Resolves a custom blocklist source by ID from the editing view *or* the saved
    /// configuration. A saved list deleted in the draft is still shown as a pending
    /// removal but is hidden from `displayedCustomBlocklists` (the picker rows); this
    /// keeps its name/metadata resolvable so the shelf and review diff show the list
    /// name instead of an opaque source ID.
    private func customBlocklistSource(for sourceID: String) -> CustomBlocklistSource? {
        displayedCustomBlocklists.first { $0.id == sourceID }
            ?? filterDetailBaseline.customBlocklists.first { $0.id == sourceID }
    }

    func blocklistName(for sourceID: String) -> String {
        if let catalogSource = catalogSourcesByID[sourceID] {
            return catalogSource.name
        }

        if let customSource = customBlocklistSource(for: sourceID) {
            return customBlocklistPickerTitle(for: customSource)
        }

        return DefaultCatalog.curatedSources.first { $0.id == sourceID }?.name ?? sourceID
    }

    func isBlocklistPendingRemoval(_ sourceID: String) -> Bool {
        guard let filterEditDraft else {
            return false
        }

        return filterDetailBaseline.enabledBlocklistIDs.contains(sourceID)
            && !filterEditDraft.enabledBlocklistIDs.contains(sourceID)
    }

    func isBlocklistNewInDraft(_ sourceID: String) -> Bool {
        guard let filterEditDraft else {
            return false
        }

        return !filterDetailBaseline.enabledBlocklistIDs.contains(sourceID)
            && filterEditDraft.enabledBlocklistIDs.contains(sourceID)
    }

    func isBlockedDomainPendingRemoval(_ domain: String) -> Bool {
        guard let filterEditDraft else {
            return false
        }

        return filterDetailBaseline.blockedDomains.contains(domain)
            && !filterEditDraft.blockedDomains.contains(domain)
    }

    func isBlockedDomainNewInDraft(_ domain: String) -> Bool {
        guard let filterEditDraft else {
            return false
        }

        return !filterDetailBaseline.blockedDomains.contains(domain)
            && filterEditDraft.blockedDomains.contains(domain)
    }

    func isAllowedDomainPendingRemoval(_ domain: String) -> Bool {
        guard let filterEditDraft else {
            return false
        }

        return filterDetailBaseline.allowedDomains.contains(domain)
            && !filterEditDraft.allowedDomains.contains(domain)
    }

    func isAllowedDomainNewInDraft(_ domain: String) -> Bool {
        guard let filterEditDraft else {
            return false
        }

        return !filterDetailBaseline.allowedDomains.contains(domain)
            && filterEditDraft.allowedDomains.contains(domain)
    }

    func stagedBlocklistIDsForDisplay() -> [String] {
        let baseline = filterDetailBaseline
        guard let filterEditDraft else {
            return baseline.enabledBlocklistIDs.sorted()
        }

        return baseline.enabledBlocklistIDs
            .union(filterEditDraft.enabledBlocklistIDs)
            .sorted { blocklistName(for: $0).localizedStandardCompare(blocklistName(for: $1)) == .orderedAscending }
    }

    func stagedBlockedDomainsForDisplay() -> [String] {
        let baseline = filterDetailBaseline
        guard let filterEditDraft else {
            return baseline.blockedDomains.sorted()
        }

        return baseline.blockedDomains
            .union(filterEditDraft.blockedDomains)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func stagedAllowedDomainsForDisplay() -> [String] {
        let baseline = filterDetailBaseline
        guard let filterEditDraft else {
            return baseline.allowedDomains.sorted()
        }

        return baseline.allowedDomains
            .union(filterEditDraft.allowedDomains)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func addBlocklistsToDraft(_ sourceIDs: Set<String>) -> String? {
        guard var draft = filterEditDraft else {
            return "Tap Edit before changing your filter."
        }

        let updatedIDs = draft.enabledBlocklistIDs.union(sourceIDs)
        guard !enabledIDsExceedSoftRuleBudget(updatedIDs) else {
            return filterRuleBudgetMessage()
        }

        draft.enabledBlocklistIDs = updatedIDs
        filterEditDraft = draft
        return nil
    }

    func setDraftBlocklists(_ sourceIDs: Set<String>) -> String? {
        guard var draft = filterEditDraft else {
            return "Tap Edit before changing your filter."
        }

        let updatedIDs = sourceIDs
        guard !enabledIDsExceedSoftRuleBudget(updatedIDs) else {
            return filterRuleBudgetMessage()
        }

        draft.enabledBlocklistIDs = updatedIDs
        filterEditDraft = draft
        return nil
    }

    func addCustomBlocklistToDraft(displayName: String, rawURL: String) -> String? {
        guard configuration.limits.allowsCustomBlocklists else {
            return "Custom blocklist URLs are included with Lava Plus."
        }

        guard var draft = filterEditDraft else {
            return "Tap Edit before changing your filter."
        }

        do {
            let source = try CustomBlocklistSource(displayName: displayName, rawURL: rawURL)
            if let catalogSourceID = KnownBlocklistURLMatcher.catalogSourceID(for: source.sourceURL) {
                if !draft.enabledBlocklistIDs.contains(catalogSourceID),
                   enabledIDsExceedSoftRuleBudget(draft.enabledBlocklistIDs.union([catalogSourceID])) {
                    return filterRuleBudgetMessage()
                }

                draft.customBlocklists.removeAll {
                    $0.sourceURL == source.sourceURL
                        || KnownBlocklistURLMatcher.catalogSourceID(for: $0.sourceURL) == catalogSourceID
                }
                draft.enabledBlocklistIDs.insert(catalogSourceID)
                filterEditDraft = draft
                return nil
            }

            guard !draft.customBlocklists.contains(where: { $0.sourceURL == source.sourceURL }) else {
                return "That custom URL is already added."
            }

            let displayKey = customBlocklistDisplayKey(for: source)
            guard !draft.customBlocklists.contains(where: { existingSource in
                existingSource.sourceURL != source.sourceURL
                    && customBlocklistDisplayKey(for: existingSource) == displayKey
            }) else {
                return "A custom list with that name already exists."
            }

            let updatedIDs = draft.enabledBlocklistIDs.union([source.id])
            guard !enabledIDsExceedSoftRuleBudget(updatedIDs) else {
                return filterRuleBudgetMessage()
            }

            draft.customBlocklists.append(source)
            draft.enabledBlocklistIDs = updatedIDs
            filterEditDraft = draft
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removeBlocklistFromDraft(_ sourceID: String) {
        guard var draft = filterEditDraft else {
            return
        }

        draft.enabledBlocklistIDs.remove(sourceID)
        filterEditDraft = draft
    }

    func deleteCustomBlocklistFromDraft(_ sourceID: String) {
        guard var draft = filterEditDraft else {
            return
        }

        draft.enabledBlocklistIDs.remove(sourceID)
        draft.customBlocklists.removeAll { $0.id == sourceID }
        filterEditDraft = draft
    }

    func undoBlocklistDraftChange(_ sourceID: String) {
        guard var draft = filterEditDraft else {
            return
        }

        let baseline = filterDetailBaseline
        if baseline.enabledBlocklistIDs.contains(sourceID) {
            draft.enabledBlocklistIDs.insert(sourceID)
            if let source = baseline.customBlocklists.first(where: { $0.id == sourceID }),
               !draft.customBlocklists.contains(where: { $0.id == sourceID }) {
                draft.customBlocklists.append(source)
            }
        } else {
            draft.enabledBlocklistIDs.remove(sourceID)
        }

        filterEditDraft = draft
    }

    func addBlockedDomainToDraft(_ rawDomain: String) -> DomainDraftResult {
        guard let draft = filterEditDraft else {
            ProtectionHapticFeedback.play(.selectionRejected)
            return .rejected(title: "Edit first", message: "Tap Edit before changing your filter.")
        }

        let outcome = FilterEditDraftEditor.addBlockedDomain(
            rawDomain,
            to: draft,
            maxBlockedDomains: configuration.limits.maxBlockedDomains
        )
        if outcome.result.isAccepted {
            filterEditDraft = outcome.draft
            ProtectionHapticFeedback.play(.selectionConfirmed)
        } else {
            ProtectionHapticFeedback.play(.selectionRejected)
        }
        return outcome.result
    }

    func removeBlockedDomainFromDraft(_ domain: String) {
        guard let draft = filterEditDraft else {
            return
        }

        filterEditDraft = FilterEditDraftEditor.removeBlockedDomain(domain, from: draft)
        ProtectionHapticFeedback.play(.selectionConfirmed)
    }

    func undoBlockedDomainDraftChange(_ domain: String) {
        guard let draft = filterEditDraft else {
            return
        }

        filterEditDraft = FilterEditDraftEditor.undoBlockedDomainChange(
            domain,
            in: draft,
            configuredBlockedDomains: filterDetailBaseline.blockedDomains
        )
    }

    func validateAllowedExceptionDraft(_ rawDomain: String) -> AllowlistValidationResult {
        AllowlistValidator(nonAllowableThreatRules: threatGuardrail).validate(rawDomain)
    }

    func addAllowedDomainToDraft(_ rawDomain: String) -> DomainDraftResult {
        guard let draft = filterEditDraft else {
            ProtectionHapticFeedback.play(.selectionRejected)
            return .rejected(title: "Edit first", message: "Tap Edit before changing your filter.")
        }

        let outcome = FilterEditDraftEditor.addAllowedDomain(
            rawDomain,
            to: draft,
            maxAllowedDomains: configuration.limits.maxAllowedDomains,
            validator: AllowlistValidator(nonAllowableThreatRules: threatGuardrail)
        )
        if outcome.result.isAccepted {
            filterEditDraft = outcome.draft
            ProtectionHapticFeedback.play(.selectionConfirmed)
        } else {
            ProtectionHapticFeedback.play(.selectionRejected)
        }
        return outcome.result
    }

    func stageDomainHistoryDomainAction(_ rawDomain: String, target: DomainHistoryDomainTarget) -> DomainDraftResult {
        // Domain History edits the ACTIVE filter's draft (keyed by activeFilterID). Per-filter
        // storage means a preserved draft for a *different* (non-active) filter is untouched — but
        // an in-progress edit of the ACTIVE filter would still be overwritten, so refuse only in
        // that case rather than losing those edits.
        if hasUnsavedActiveFilterDraft {
            ProtectionHapticFeedback.play(.selectionRejected)
            return .rejected(
                title: "Unsaved filter edits",
                message: "You have unsaved changes to your active filter. Save or discard them in Filters before changing domains here."
            )
        }
        do {
            let result = try configuration.applyingDomainHistoryDomainAction(
                rawDomain,
                target: target,
                allowlistValidator: AllowlistValidator(nonAllowableThreatRules: threatGuardrail)
            )

            // Domain History edits the ACTIVE filter, so write its keyed draft directly and force
            // the detail context to the active filter (target nil) so the review sheet diffs against
            // the active configuration. Domain History lives under the Settings tab while a Filters
            // "View" page may stay mounted on the Guard tab; resetting the target re-points the proxy
            // at the active filter (MyListCover.onAppear re-asserts its own target on return).
            filterEditTargetID = nil
            activeFilterDraft = FilterEditDraft(configuration: result.configuration)
            filterPreparationState = .idle
            isFilterPreparationScreenPresented = false
            ProtectionHapticFeedback.play(.selectionConfirmed)

            switch result.target {
            case .blocked:
                return .accepted(result.normalizedDomain, message: "This domain will be blocked after you confirm.")
            case .allowed:
                return .accepted(result.normalizedDomain, message: "This exception will take effect after you confirm.")
            }
        } catch let actionError as DomainHistoryDomainActionError {
            ProtectionHapticFeedback.play(.selectionRejected)
            return .rejected(
                title: Self.domainHistoryDomainActionRejectionTitle(for: actionError),
                message: actionError.localizedDescription
            )
        } catch {
            ProtectionHapticFeedback.play(.selectionRejected)
            return .rejected(title: "Domain cannot be added", message: error.localizedDescription)
        }
    }

    func removeAllowedDomainFromDraft(_ domain: String) {
        guard let draft = filterEditDraft else {
            return
        }

        filterEditDraft = FilterEditDraftEditor.removeAllowedDomain(domain, from: draft)
        ProtectionHapticFeedback.play(.selectionConfirmed)
    }

    func undoAllowedDomainDraftChange(_ domain: String) {
        guard let draft = filterEditDraft else {
            return
        }

        filterEditDraft = FilterEditDraftEditor.undoAllowedDomainChange(
            domain,
            in: draft,
            configuredAllowedDomains: filterDetailBaseline.allowedDomains
        )
    }

    func prepareAndApplyFilterDraft(origin: FilterReviewOrigin = .filters) async {
        // Record which surface is applying so the matching cover (and only it) presents the
        // preparation / failure UI — set at the apply point, not at staging, so it can't go stale.
        filterPreparationOrigin = origin
        // A draft apply is now the retry target (supersedes any earlier switch attempt), and every
        // fresh apply starts retryable — clearing any non-retryable state a prior dead-end switch
        // left, so a transient edit/Domain-History failure still offers "Try Again".
        pendingSwitchFilterID = nil
        filterPreparationFailureIsRetryable = true
        guard let filterEditDraft else {
            return
        }

        guard filterDraftHasChanges else {
            return
        }

        if let validationMessage = filterDraftValidationMessage {
            filterPreparationState = .failed(message: validationMessage)
            isFilterPreparationScreenPresented = true
            ProtectionHapticFeedback.play(.actionFailed)
            return
        }

        var nextConfiguration = configuration
        nextConfiguration.enabledBlocklistIDs = filterEditDraft.enabledBlocklistIDs
        nextConfiguration.customBlocklists = filterEditDraft.customBlocklists
        nextConfiguration.blockedDomains = filterEditDraft.blockedDomains
        nextConfiguration.allowedDomains = filterEditDraft.allowedDomains

        let shouldRestoreProtection = configuration.protectionEnabled || isProtectionEnabledStatus(vpnStatus)
        // A draft apply is a wholesale config replacement too: claim the replacement token before the
        // first await so a switch/restore/import that completes mid-flight supersedes it (and vice
        // versa) instead of one silently reverting the other. Claimed AFTER the early-return guards so
        // a no-op apply can't needlessly bump the epoch and supersede a legitimate in-flight replacer.
        // A draft apply drives the preparation cover, like a switch.
        let draftToken = configurationReplacementGate.begin(ownsPreparationCover: true)
        isFilterPreparationScreenPresented = true

        do {
            let progressPresenter = FilterPreparationProgressPresenter()
            let prepared = try await prepareFilterSnapshot(for: nextConfiguration) { update in
                await progressPresenter.present(update) { state in
                    self.filterPreparationState = state
                }
            }

            await progressPresenter.present(
                FilterPreparationProgressUpdate(progress: 0.86, phase: .saving)
            ) { state in
                self.filterPreparationState = state
            }
            await progressPresenter.holdCurrentPhaseIfNeeded()

            // A newer replacement took ownership while we prepared — bail without committing;
            // dismiss our cover if the new owner is a non-cover-driver that won't.
            guard configurationReplacementGate.isCurrent(draftToken) else {
                dismissPreparationCoverIfStrandedBySupersession()
                return
            }
            configuration = nextConfiguration
            updateCustomBlocklistHashes(prepared.customResult.sourceHashes)
            try await persistSharedState(preparedSnapshot: prepared.snapshot)
            // Re-check after the persist's artifact-actor await before the derived-cache tail (see
            // switchToFilter): applyCatalogSyncResult is deferred past the persist + this gate so a
            // superseded apply never desyncs the rule caches against the newer owner's config.
            guard configurationReplacementGate.isCurrent(draftToken) else {
                dismissPreparationCoverIfStrandedBySupersession()
                return
            }
            applyCatalogSyncResult(prepared.catalogResult)
            appendAppNetworkActivity(.changeFilters)

            await notifyTunnelSnapshotUpdated()
            await restoreProtectionIfNeeded(wasEnabled: shouldRestoreProtection)

            let ruleLabel = protectedRuleCount == 1 ? "rule" : "rules"
            catalogStatusMessage = "Prepared \(protectedRuleCount.formatted()) \(ruleLabel) for local protection."
            catalogStatusIsError = false
            self.activeFilterDraft = nil
            filterPreparationState = .preparing(progress: 1, message: "Success")
            ProtectionHapticFeedback.play(.actionSucceeded)

            try? await Task.sleep(nanoseconds: 650_000_000)
            filterPreparationState = .idle
            isFilterPreparationScreenPresented = false
        } catch {
            // A newer replacement took ownership while we prepared (it owns the shared cover now),
            // so a superseded apply must NOT stomp it with a spurious failure modal + haptic. Mirror
            // switchToFilter's catch: bail if no longer current (dismissing our cover if the new
            // owner won't). The apply mutates no config/library before the throw, nothing to roll back.
            guard configurationReplacementGate.isCurrent(draftToken) else {
                dismissPreparationCoverIfStrandedBySupersession()
                return
            }
            filterPreparationState = .failed(
                message: Self.filterPreparationFailureMessage(for: error)
            )
            isFilterPreparationScreenPresented = true
            ProtectionHapticFeedback.play(.actionFailed)
        }
    }

    /// Save the current draft to the NON-active filter being viewed. Library-only: writes the
    /// four filter fields into the target's library entry, invalidates its compiled token (so a
    /// later switch recompiles), and persists via the rollback-safe library-only path. No
    /// prepare, no tunnel reload, no replacement gate, and — unlike the active apply — NO
    /// full-screen preparation cover: the filter isn't loaded, so this can't touch live
    /// protection. On a validation or write failure it returns a message for the caller to show
    /// inline (so a non-active save never flips the global catalog-error/protection indicators);
    /// on success it clears the draft (the page drops to view mode) and returns nil. The target
    /// is preserved so the page keeps showing the just-saved filter.
    @discardableResult
    func saveNonActiveFilterDraft() -> String? {
        guard let targetID = filterEditTargetID,
              let draft = filterEditDraft,
              library.filter(id: targetID) != nil else {
            return nil
        }
        // The target may have become frozen since the draft was started (Plus lapsed while a draft
        // was preserved / mid-edit). A frozen filter is read-only, so report it instead of silently
        // no-op'ing — the detail page also drops the draft on appear, but this covers a lapse that
        // happens while the page stays mounted in edit mode.
        guard !isFilterFrozen(targetID) else {
            ProtectionHapticFeedback.play(.actionFailed)
            return "This filter is locked. Upgrade to Lava Plus to edit it."
        }
        if let validationMessage = filterDraftValidationMessage {
            ProtectionHapticFeedback.play(.actionFailed)
            return validationMessage
        }
        let previousLibrary = library
        library.mutateFilter(id: targetID) { filter in
            filter.enabledBlocklistIDs = draft.enabledBlocklistIDs
            filter.customBlocklists = draft.customBlocklists
            filter.blockedDomains = draft.blockedDomains
            filter.allowedDomains = draft.allowedDomains
            // Its on-disk compiled artifacts no longer match the rules — force a fresh compile
            // the next time this filter is switched to.
            filter.lastCompiledToken = nil
        }
        guard persistLibraryOnlyChange(rollingBackTo: previousLibrary) else {
            ProtectionHapticFeedback.play(.actionFailed)
            return "Couldn't save your changes. Please try again."
        }
        filterEditDraft = nil
        ProtectionHapticFeedback.play(.actionSucceeded)
        // The edit invalidated this filter's compiled artifact (token cleared above); re-warm it
        // off the hot path so a later switch stays an instant pointer flip. Fire-and-forget — the
        // inline save remains library-only and warmFilterArtifact never republishes or reloads the
        // tunnel; if the user keeps editing, the post-compile staleness recheck drops any superseded
        // compile, and a switch arriving before the token is stamped just cold-compiles (self-healing).
        Task { await warmFilterArtifact(forFilterID: targetID) }
        return nil
    }

    // MARK: - Multi-filter library

    /// Whether the user can create another filter. Free holds up to three (the seeded
    /// Core / Balanced / Extra defaults); Plus hosts up to 10. The "+ new filter" affordance
    /// gates on this — a free user at the cap trips the paywall, a Plus user at the cap sees a
    /// "maximum reached" note.
    var canCreateFilter: Bool {
        library.filters.count < configuration.limits.maxFilters
    }

    /// A filter is *frozen* when the user holds more filters than their tier allows (Plus
    /// lapsed): the excess non-active filters are kept and readable but cannot be switched to.
    /// The active filter is never frozen, and a library that fits the cap (e.g. Free with its
    /// three seeded filters) freezes nothing — all are switchable.
    func isFilterFrozen(_ id: String) -> Bool {
        let cap = configuration.limits.maxFilters
        guard library.filters.count > cap, id != library.activeFilterID else { return false }
        // The active filter takes one slot; the first (cap - 1) other filters by order stay usable.
        let nonActive = library.filters.map(\.id).filter { $0 != library.activeFilterID }
        return !nonActive.prefix(max(cap - 1, 0)).contains(id)
    }

    /// The library's filters in order, for the All-filters list.
    var filters: [Filter] {
        library.filters
    }

    var activeFilterID: String {
        library.activeFilterID
    }

    func filter(id: String) -> Filter? {
        library.filter(id: id)
    }

    /// Whether `name` is free to use for a filter — no other filter already has it (trimmed,
    /// case-insensitive). `excluding` skips one filter (the one being renamed). A blank name is
    /// never "available" (the UI requires a non-empty name). Filter names are unique so the All
    /// filters list, the share/import pickers, and the import "add as new" flow never show two
    /// indistinguishable rows.
    func isFilterNameAvailable(_ name: String, excluding excludedID: String? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !library.filters.contains { filter in
            filter.id != excludedID
                && filter.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    /// A filter name based on `base` that isn't already taken: `base`, then "base 2", "base 3"… .
    /// Used when a name is derived (duplicate / import default) rather than user-entered.
    private func uniqueFilterName(basedOn base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.isEmpty ? "Filter".lavaLocalized : trimmed
        if isFilterNameAvailable(root) { return root }
        var index = 2
        while !isFilterNameAvailable("\(root) \(index)") { index += 1 }
        return "\(root) \(index)"
    }

    /// Create a new filter, optionally duplicating an existing one's contents. Writes
    /// the library only (a new filter is never the active one, so nothing compiles or
    /// republishes). Returns the new filter's id, or `nil` if blocked (at the filter cap, a
    /// duplicate name, or a persistence failure). Callers gate on ``canCreateFilter`` first to
    /// show the paywall, and validate the name with ``isFilterNameAvailable`` so the duplicate
    /// rejection here is a backstop, not the primary UX.
    @discardableResult
    func createFilter(name: String, duplicatingFilterID: String? = nil) -> String? {
        guard canCreateFilter else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // An explicit name must be unique (UI enforces; reject as a backstop). A blank name derives
        // a unique default from the duplicated filter (or a generic base).
        let resolvedName: String
        if trimmed.isEmpty {
            let base = duplicatingFilterID
                .flatMap { library.filter(id: $0)?.name }
                .map(duplicateName(of:)) ?? "Filter".lavaLocalized
            resolvedName = uniqueFilterName(basedOn: base)
        } else {
            guard isFilterNameAvailable(trimmed) else { return nil }
            resolvedName = trimmed
        }
        let newID = "filter-\(UUID().uuidString)"
        let newFilter: Filter
        if let duplicatingFilterID, let source = library.filter(id: duplicatingFilterID) {
            newFilter = Filter(
                id: newID,
                name: resolvedName,
                enabledBlocklistIDs: source.enabledBlocklistIDs,
                customBlocklists: source.customBlocklists,
                blockedDomains: source.blockedDomains,
                allowedDomains: source.allowedDomains
            )
        } else {
            newFilter = Filter(id: newID, name: resolvedName)
        }
        let previousLibrary = library
        library.append(newFilter)
        guard persistLibraryOnlyChange(rollingBackTo: previousLibrary) else { return nil }
        // Warm the new (non-active) filter off the hot path so a later switch — manual or a
        // Focus auto-switch — is an instant pointer flip, not a cold compile. Fire-and-forget:
        // creation stays library-only/non-blocking, and warmFilterArtifact never republishes or
        // touches the live tunnel/pointer (it only stages the new filter's own artifact dir). A switch
        // arriving before the token is stamped just cold-compiles (a rare, self-healing redundant compile).
        Task { await warmFilterArtifact(forFilterID: newID) }
        return newID
    }

    /// Persist a library-only mutation (create / rename / delete) and schedule an encrypted
    /// backup, so hosted filters are captured by the backup the same way config changes are.
    /// The caller has ALREADY applied its mutation to the in-memory `library`; `previousLibrary`
    /// is the pre-mutation snapshot so a failed write can be rolled back.
    @discardableResult
    private func persistLibraryOnlyChange(rollingBackTo previousLibrary: FilterLibrary) -> Bool {
        guard (try? persistFilterLibrary()) != nil else {
            // A failed write must not leave the mutation live in the published library: the UI
            // would show a change reported as failed, and a later successful config write
            // (persistSharedState) would persist it. Roll back so the in-memory library matches
            // what actually reached disk.
            library = previousLibrary
            return false
        }
        scheduleAutomaticBackupAfterConfigurationChange()
        return true
    }

    /// Rename a filter (library-only; no recompile). No-ops on a blank name, unknown id, a
    /// duplicate name (filter names are unique), or a frozen (lapsed-Plus, read-only) filter —
    /// enforced here, below the UI, so a stale sheet or a direct caller can't mutate a frozen
    /// filter or create a name collision.
    func renameFilter(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              library.filter(id: id) != nil,
              !isFilterFrozen(id),
              isFilterNameAvailable(trimmed, excluding: id) else { return }
        let previousLibrary = library
        library.mutateFilter(id: id) { $0.name = trimmed }
        persistLibraryOnlyChange(rollingBackTo: previousLibrary)
    }

    /// Delete a filter. Refuses the in-effect filter (switch first), the last remaining
    /// filter (the ≥1 invariant), and a frozen (read-only) filter — the freeze is enforced
    /// here, below the UI. Library-only; no recompile. Returns whether a deletion happened.
    @discardableResult
    func deleteFilter(id: String) -> Bool {
        guard !isFilterFrozen(id) else { return false }
        let previousLibrary = library
        guard library.remove(id: id) else { return false }
        guard persistLibraryOnlyChange(rollingBackTo: previousLibrary) else { return false }
        // Drop the deleted filter's per-filter draft (its key is gone).
        filterEditDrafts[id] = nil
        return true
    }

    /// "Restore to default": reset the library to the three seeded default filters
    /// (Core / Balanced / Extra) with Balanced loaded. Mirrors Balanced into the live config and
    /// persists via the normal config-edit path — `persistSharedState` writes config + library
    /// together at one bumped generation and reloads the tunnel, so this never trips the
    /// library/config write-race. Replaces any custom filters the user made (a deliberate reset,
    /// gated behind a confirm dialog in the UI).
    func restoreFiltersToDefault() {
        // Restore is a wholesale config+library replacement, so it must claim the replacement
        // gate like switch/import/restore-backup/draft-apply: advancing the epoch makes any
        // in-flight replacer (e.g. a switch suspended at its prepare) bail at its commit instead
        // of silently reverting this restore.
        _ = configurationReplacementGate.begin()
        // Like every other foreground config writer, this can race a headless Focus commit. The cross-process
        // write lock + generation fence (SharedFilterStatePersistence, taken by both sides) make that safe —
        // the loser aborts cleanly — and the headless path records its pending-switch marker first, so the
        // foreground reconcile re-applies any Focus target afterward (last-writer-wins, never wrong rules or a
        // wedge). No per-writer bracketing or foreground-active gating needed.
        // This supersedes any in-flight warm switch and drives its own coverage below (rebuild from
        // cache + startOnboardingDefaultBlocklistSyncIfNeeded fills any missing source), so the
        // superseded warm switch's stale-cache deferral no longer applies — clear it (the superseded
        // rehydration will bail without clearing). Otherwise a warm switch whose target's sources were
        // all already cached would leave the flag wrongly stuck after this reseed.
        hasPendingWarmSwitchCacheRehydration = false
        // The whole library is reseeded, so every per-filter draft + the detail target are now
        // invalid — wipe them so a preserved edit can't resume over a freshly seeded filter.
        filterEditDrafts.removeAll()
        filterEditTargetID = nil
        library = .seededDefaults(active: .balanced)
        mirrorActiveFilterIntoConfiguration()
        rebuildEnabledBlockRules()
        persistFilterChanges()
        // Balanced may enable a curated source not yet cached on this device — fetch any missing
        // ones so the published snapshot covers Balanced rather than under-covering until a later
        // sync (the onboarding/switch paths do the same).
        startOnboardingDefaultBlocklistSyncIfNeeded()
    }

    /// Switch the active filter: mirror the target's four fields into the live config,
    /// prepare + publish, and reload the tunnel. A cold target shows the preparation
    /// screen ("Applying protection…"); on failure the previously-loaded filter is kept
    /// (never a half-applied state). Refuses a no-op, an unknown id, or a frozen filter.
    func switchToFilter(id: String, stampsForegroundSwitch: Bool = true) async {
        // The four-scoped-field mirroring is the shared FilterSwitchPlan transition (same source of
        // truth as the headless warm switch); it already rejects a no-op / unknown target. The library's
        // active selection is committed on the LIVE library at the commit point below (not from the
        // plan's captured copy) so a concurrent warm-token stamp during the async prepare isn't lost.
        guard !isFilterFrozen(id),
              let plan = FilterSwitchPlan.make(toFilterID: id, configuration: configuration, library: library),
              let target = library.filter(id: id)
        else {
            return
        }

        // Mark a genuine USER switch in flight so the Focus reconcile defers to it (round-18) rather than
        // superseding it mid-prepare. On exit, re-dispatch a reconcile: a Focus marker that deferred to this
        // switch had its Darwin nudge consumed while we held the flag, so without this it would strand until a
        // later scene event (same hazard as the round-17 re-dispatch). By the time the Task runs the flag is
        // cleared and lastForegroundSwitch is stamped (on success), so the reconcile drops a now-stale marker
        // or applies one genuinely newer than this switch. Gated on stampsForegroundSwitch so the reconcile's
        // OWN replay switchToFilter(false) neither sets the flag nor re-dispatches (no loop).
        if stampsForegroundSwitch {
            isForegroundManualSwitchInFlight = true
        }
        defer {
            if stampsForegroundSwitch {
                isForegroundManualSwitchInFlight = false
                Task { @MainActor [weak self] in await self?.reconcilePendingFilterSwitch() }
            }
        }

        let nextConfiguration = plan.configuration

        let shouldRestoreProtection = configuration.protectionEnabled || isProtectionEnabledStatus(vpnStatus)
        // Snapshot the loaded state so ANY failure restores the previously-loaded filter
        // exactly — a cold-compile failure (before commit) or a mid-publish error (after).
        let previousConfiguration = configuration
        let previousActiveID = library.activeFilterID
        // Capture the INITIATION instant NOW — before the (possibly slow) async prepare below — so the
        // foreground-switch supersession stamp records when the USER STARTED this switch, not when it
        // finished. A cold compile can take seconds; stamping completion time would misclassify a Focus
        // request that fired DURING the prepare (genuinely newer than this switch's initiation) as
        // "older" and silently drop it. Stamped only at the commit point on success (Codex round-15).
        let switchInitiatedAt = Date()
        // Remember the target so the shared failure screen's "Try Again" retries THIS
        // switch (there is no edit draft in the switch path).
        pendingSwitchFilterID = id
        // A fresh attempt is retryable unless it dead-ends on a deleted/frozen target below.
        filterPreparationFailureIsRetryable = true
        // Claim the configuration-replacement token. A later switch/restore/import supersedes
        // it, so this attempt bails at its commit/rollback gate instead of clobbering the
        // newer owner (the silent switch-vs-restore revert as well as overlapping switches).
        // A switch drives the preparation cover, so a superseded switch knows to dismiss it
        // when the new owner is a non-cover-driver (restore/import).
        let switchToken = configurationReplacementGate.begin(ownsPreparationCover: true)
        // A switch is a Filters-tab action, so the Filters cover (not Domain History) owns it.
        filterPreparationOrigin = .filters
        isFilterPreparationScreenPresented = true

        do {
            let progressPresenter = FilterPreparationProgressPresenter()
            // Instant switch-back: reuse the target's still-warm compiled artifacts (a pointer flip)
            // when its lastCompiledToken is valid for the current config + a FRESH cached catalog, else
            // cold-compile. Both yield a PreparedFilterSnapshot the shared tail below commits + publishes
            // identically. A switch to a filter whose proactive warm is still in flight (token not yet
            // stamped) simply cold-compiles — a rare, self-healing redundant compile, not wrong rules;
            // cross-task coalescing was removed to keep this path small (see the LAV-100 plan).
            var publication = try await prepareSwitchPublication(
                target: target,
                configuration: nextConfiguration,
                progressPresenter: progressPresenter
            )

            await progressPresenter.present(
                FilterPreparationProgressUpdate(progress: 0.86, phase: .saving)
            ) { state in
                self.filterPreparationState = state
            }
            await progressPresenter.holdCurrentPhaseIfNeeded()

            // A catalog sync that ran while we prepared (the reuse load + the holds above suspend the
            // main actor) would race a warm flip: the sync recompiles + republishes the active filter's
            // artifacts on the refreshed catalog and advances latest.json, so a warm flip to the
            // pre-refresh artifact would leave latest.json ahead of the pointer (the fail-closed
            // stale-source-hash wedge), and applyReusablePreparedSnapshot would roll currentCatalog
            // back to the stale one. Bail warm→cold on EITHER signal:
            //   • liveness — a sync is in flight RIGHT NOW (started during prepare, about to republish);
            //   • content  — the live catalog no longer matches the one the warm snapshot was validated
            //     against, i.e. a sync STARTED AND FINISHED entirely between the entry gate and here, so
            //     catalogSyncTask is already nil yet the catalog moved (Codex #133 — liveness alone
            //     can't see a completed sync). The content check is by per-source identity, not the
            //     top-level catalog_version string, so a source rotation (hagezi ~4x/day, catalog hash
            //     pinned) that keeps catalog_version constant is still caught.
            // The cold fallback compiles fresh against the now-current catalog. After this gate passes
            // the catalog is BOTH quiescent and content-matched, so persistSharedState's sub-millisecond
            // pointer flip cannot be out-raced by a freshly triggered (seconds-long) sync — no
            // post-persist drift reconciliation is needed.
            if case .warm(let reusable) = publication {
                let catalogMovedSinceValidation = currentCatalog.map {
                    !reusable.preparedSnapshot.identity.snapshotInputMismatches(
                        against: PreparedFilterSnapshotIdentity.make(configuration: nextConfiguration, catalog: $0)
                    ).isEmpty
                } ?? false
                if isCatalogSyncInFlight || catalogMovedSinceValidation {
                    publication = .compiled(try await prepareFilterSnapshot(for: nextConfiguration))
                }
            }

            // A newer replacement superseded this one while it was preparing. Don't touch
            // config/library (the newer owner has them); dismiss the preparation cover this switch
            // put up ONLY if the newer owner is a non-cover-driver (restore/import) that won't.
            guard configurationReplacementGate.isCurrent(switchToken) else {
                dismissPreparationCoverIfStrandedBySupersession()
                return
            }

            // The target may have been deleted, or Plus may have lapsed (freezing it),
            // while the async prepare ran — re-validate before committing so a lapsed
            // account can't activate a now-frozen, read-only filter.
            guard library.filter(id: id) != nil, !isFilterFrozen(id) else {
                // Surface the dead end instead of silently dropping the cover. Non-retryable
                // (retrying a gone/frozen target just re-fails), so the failure screen offers
                // only "Keep Current Filter". pendingSwitchFilterID stays set so "Back to Edit"
                // stays hidden; keepCurrentFiltersAfterPrepareFailure clears it.
                filterPreparationFailureIsRetryable = false
                filterPreparationState = .failed(message: "That filter is no longer available.")
                isFilterPreparationScreenPresented = true
                return
            }

            // Commit the switch only after a successful prepare/reuse.
            configuration = nextConfiguration
            library.setActiveFilter(id: id)
            // A compiled publish carries fresh per-source hashes; a warm reuse validated the existing
            // ones against the current catalog, so it leaves the app's hash tracking untouched.
            if case .compiled(let prepared) = publication {
                updateCustomBlocklistHashes(prepared.customResult.sourceHashes)
            }
            // The derived-cache apply below (applyCatalogSyncResult / applyReusablePreparedSnapshot)
            // mutates rule state — currentCatalog, cachedBlockRuleSets, threatGuardrail, blockRules —
            // that the failure rollback does NOT restore, so it runs only AFTER the throwing persist +
            // the ownership re-check: a failed/superseded switch never leaves those caches describing
            // the target. persistSharedState uses the explicit prepared snapshot, not these caches.
            //
            // For a WARM reuse the target's content-addressed token dir already exists, so the publish
            // is a pointer FLIP, not a recompile: persistSharedState records the (unchanged) compiled
            // token and persistArtifacts' staging step no-ops — it re-materializes the dir from the
            // in-memory snapshot only if it was GC'd between validation and the flip (fail-closed),
            // never serving stale rules (the reuse validation already matched the current catalog).
            let publishOutcome = try await persistSharedState(preparedSnapshot: publication.preparedSnapshot)
            // persistSharedState's last step awaits the artifact-publish actor, a main-actor
            // suspension. A restore/import/switch/draft-apply that completed during it now owns the
            // live configuration+library. Re-check BEFORE the side-effect tail: applyCatalogSyncResult
            // rebuilds derived rule caches (cachedBlockRuleSets/threatGuardrail/blockRules) against
            // the LIVE configuration, so running it here would leave caches describing THIS switch
            // while config is the newer owner's — a later persist would then serialize wrong rules.
            // The newer owner drives the UI/tunnel; dismiss our cover only if it's a non-cover-driver.
            guard configurationReplacementGate.isCurrent(switchToken) else {
                dismissPreparationCoverIfStrandedBySupersession()
                return
            }
            // Now that the in-process supersession guard above has confirmed THIS switch still owns the gate,
            // an `.abortedSuperseded` here is the CROSS-PROCESS case: a concurrent Focus/App Intents commit won
            // the active-filter race, so the flip degrade-ABORTED and the live pointer + disk name the newer
            // Focus target. Treat it as a deferred, non-winning switch — dismiss OUR cover WITHOUT flashing
            // "Success" for a filter that didn't take, and let the re-dispatched reconcile (the defer above)
            // adopt the genuinely-newer on-disk selection. Marker recovery already preserved correctness (the
            // kept Focus marker's requestedAt necessarily postdates this switch's initiation, so reconcile
            // adopts the Focus target); this only removes the transient wrong-"Success" toast. The NON-current
            // (in-process superseded) case is handled by the gate guard above — NOT here — so this silent
            // dismiss can never clobber a newer in-process cover-driving switch's UI (Codex review, lavasec-ios#29).
            if case .abortedSuperseded = publishOutcome {
                filterEditTargetID = nil
                pendingSwitchFilterID = nil
                filterPreparationState = .idle
                isFilterPreparationScreenPresented = false
                return
            }
            // Stamp the foreground switch time so a pending Focus marker recorded BEFORE this switch was
            // INITIATED is dropped by reconcile rather than reverting the user's newer explicit choice.
            // Stamp the captured INITIATION instant (switchInitiatedAt), NOT Date() here: a slow cold compile
            // can take seconds, and stamping completion time would misclassify a Focus request that fired
            // DURING the prepare — genuinely newer than this switch's initiation — as stale and drop it
            // (Codex round-15). Stamp ONLY HERE — after persistSharedState SUCCEEDED and the post-persist
            // re-check confirms this switch still owns the gate — so a manual switch that threw or was
            // superseded never stamps a timestamp that would clear a still-valid pending Focus request as
            // stale (Codex round-11). ONLY for genuine USER switches: reconcile's replay passes
            // stampsForegroundSwitch: false so a programmatic Focus apply never poisons the supersession
            // timestamp nor suppresses a newer Focus request.
            if stampsForegroundSwitch {
                PendingFilterSwitchStore.recordForegroundSwitch(at: switchInitiatedAt, in: LavaSecAppGroup.sharedDefaults)
            }
            switch publication {
            case .compiled(let prepared):
                applyCatalogSyncResult(prepared.catalogResult)
            case .warm(let reusable):
                // Guard the apply against a catalog sync that moved the live catalog while
                // persistSharedState was suspended on the publish lock/artifact actor. If it moved,
                // applyReusablePreparedSnapshot below would roll currentCatalog + blockRules BACK to the
                // warm snapshot's validation-time catalog, and the background rehydration's catalog
                // re-check (results.catalog == currentCatalog) would then never match — wedging the gate
                // and leaving later publishes built against the stale catalog (Codex #133). When the
                // catalog moved, that sync already applied fresh, correct state for the now-committed
                // target filter (it rebuilds against the live config) and published its own artifacts,
                // so KEEP it: skip the stale reuse apply and the rehydration (caches are already fresh).
                // This needs a sync to fetch + compile within persistSharedState's sub-millisecond flip,
                // which the pre-commit gate's liveness+content checks make unreachable in practice — but
                // the guard keeps the post-persist apply robust WITHOUT re-introducing an inline recompile.
                let catalogMovedDuringPersist = currentCatalog.map {
                    !reusable.preparedSnapshot.identity.snapshotInputMismatches(
                        against: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: $0)
                    ).isEmpty
                } ?? false
                if !catalogMovedDuringPersist {
                    // The reused snapshot already carries the target's compiled rules + the catalog it
                    // was validated against; apply them the same way the warm-startup path does.
                    applyReusablePreparedSnapshot(reusable)
                    // A warm reuse left the per-source rule-set caches (cachedBlockRuleSets) describing
                    // the PREVIOUS filter — it reused the published artifact, not the per-source sets,
                    // whereas a COLD switch leaves them fresh from its catalog sync. Mark the caches
                    // pending so in-place blocklist edits are deferred (they'd otherwise rebuild
                    // blockRules from the wrong filter's caches and publish them — Codex #133), then
                    // rehydrate in the background (the switch itself stays instant; no artifact
                    // re-publish — the pointer already names the correct directory). applyCatalogSyncResult
                    // clears the flag once the rehydration (or any fresh-cache load) lands.
                    hasPendingWarmSwitchCacheRehydration = true
                    let rehydrationToken = switchToken
                    let rehydrationFilterID = id
                    Task { [weak self] in
                        await self?.rehydrateRuleSetCachesAfterWarmSwitch(
                            switchToken: rehydrationToken,
                            filterID: rehydrationFilterID
                        )
                    }
                }
            }
            appendAppNetworkActivity(.changeFilters)

            await notifyTunnelSnapshotUpdated()
            await restoreProtectionIfNeeded(wasEnabled: shouldRestoreProtection)

            // Per-filter drafts: the previously-active filter keeps its own draft under its key
            // (no misattribution to the newly-active filter), so a switch no longer discards it.
            // Just drop any non-active detail target so the detail accessors fall back to the
            // (new) active filter.
            filterEditTargetID = nil
            pendingSwitchFilterID = nil

            filterPreparationState = .preparing(progress: 1, message: "Success")
            ProtectionHapticFeedback.play(.actionSucceeded)

            try? await Task.sleep(nanoseconds: 650_000_000)
            filterPreparationState = .idle
            isFilterPreparationScreenPresented = false
        } catch {
            // Only the current owner may roll back. A superseded attempt that failed must not
            // restore its previousActiveID over a newer switch/restore/import that committed; it
            // only dismisses its own cover if the new owner won't.
            guard configurationReplacementGate.isCurrent(switchToken) else {
                dismissPreparationCoverIfStrandedBySupersession()
                return
            }
            // Restore the previously-loaded filter exactly: a failed switch must never
            // leave config/library pointing at a target it didn't finish publishing.
            configuration = previousConfiguration
            library.setActiveFilter(id: previousActiveID)
            // Durably persist the rollback. persistSharedState writes app-configuration.json
            // and filter-library.json BEFORE the artifact publish, so a publish-stage failure
            // can leave the TARGET filter on disk; rewrite the previous config + library (no
            // artifact publish, no tunnel reload) so a restart loads the filter still in effect.
            try? persistConfigurationOnly()
            filterPreparationState = .failed(
                message: Self.filterPreparationFailureMessage(for: error)
            )
            isFilterPreparationScreenPresented = true
            ProtectionHapticFeedback.play(.actionFailed)
        }
    }

    /// How a filter switch obtains the snapshot it publishes: a warm REUSE of the target's
    /// still-on-disk compiled artifacts (an instant pointer flip), or a cold COMPILE.
    private enum SwitchPublication {
        case warm(ReusablePreparedFilterSnapshot)
        case compiled(FilterSnapshotPreparationResult)

        var preparedSnapshot: PreparedFilterSnapshot {
            switch self {
            case .warm(let reusable): return reusable.preparedSnapshot
            case .compiled(let result): return result.snapshot
            }
        }
    }

    /// Prepare the snapshot a switch will publish. Tries a warm-artifact reuse first — when the
    /// target filter's `lastCompiledToken` directory is still on disk AND valid for the target's
    /// CURRENT configuration + catalog — and only cold-compiles on a miss. The reuse validation is
    /// identical to the warm-startup path (manifest `reuseRejectionReason` + the decoded snapshot's
    /// `canReuseForProtectionStartup`), so a catalog/resolver/selection change since that compile
    /// fails the check and falls back to a recompile: a reuse can never serve rules that don't match
    /// the target's current inputs.
    ///
    /// Warm reuse is also skipped entirely while a catalog sync is in flight: that sync is about to
    /// recompile + republish on a refreshed catalog, so a warm flip would race it. Bailing to a cold
    /// compile (which coalesces with / follows the sync) keeps the warm fast path quiescent-only —
    /// instant in the common case, never racing a refresh.
    private func prepareSwitchPublication(
        target: Filter,
        configuration: AppConfiguration,
        progressPresenter: FilterPreparationProgressPresenter
    ) async throws -> SwitchPublication {
        // Reuse the target's warm artifact when one exists (shared with the headless warm switch via
        // warmReusableSnapshotForSwitch — same candidate set + validation). Skipped entirely while a
        // catalog sync is in flight: that sync is about to recompile + republish, so a warm flip would
        // race it; bailing to the cold compile keeps the warm fast path quiescent-only.
        if !isCatalogSyncInFlight,
           let reusable = await warmReusableSnapshotForSwitch(target: target, configuration: configuration) {
            return .warm(reusable)
        }

        let prepared = try await prepareFilterSnapshot(for: configuration) { update in
            await progressPresenter.present(update) { state in
                self.filterPreparationState = state
            }
        }
        return .compiled(prepared)
    }

    /// Resolve a reusable warm snapshot for switching to `target`, trying BOTH candidate tokens — the
    /// library's own `lastCompiledToken` (foreground-warmed) AND a token the BACKGROUND staged into the
    /// sidecar warm-index (Phase 2). A non-nil library token can be STALE (a catalog refresh re-warmed
    /// the filter into the sidecar before the foreground promoted it), so trying only the library token
    /// would cold-compile and never use the fresh sidecar one (Codex #138). Each candidate is validated
    /// identically (manifest per-source hashes + a FRESH cached catalog) by the per-token loader below,
    /// so an invalid candidate falls through to the next / to nil (the caller cold-compiles or defers).
    /// Shared by the foreground switch (`prepareSwitchPublication`) and the headless warm switch.
    private func warmReusableSnapshotForSwitch(
        target: Filter,
        configuration: AppConfiguration
    ) async -> ReusablePreparedFilterSnapshot? {
        var candidateTokens: [String] = []
        if let libraryToken = target.lastCompiledToken { candidateTokens.append(libraryToken) }
        if let sidecarToken = loadBackgroundWarmIndex().token(forFilterID: target.id),
           sidecarToken != target.lastCompiledToken {
            candidateTokens.append(sidecarToken)
        }
        for token in candidateTokens {
            if let reusable = await loadReusableWarmSnapshotForSwitch(token: token, configuration: configuration) {
                return reusable
            }
        }
        return nil
    }

    /// Load + validate the prepared snapshot in a SPECIFIC warm token directory (the target filter's
    /// `lastCompiledToken`) for an instant switch. `nil` ⇒ the directory is missing/undecodable, or
    /// the artifact no longer matches `configuration` + the cached catalog (coverage, source hashes,
    /// catalog version, resolver transport) — the caller then cold-compiles. Mirrors
    /// `loadReusablePreparedSnapshotForProtectionStartup`, but reads the token dir (not the live
    /// pointer) and additionally requires the decoded snapshot's content-addressed token to equal the
    /// directory name, so the subsequent `persistSharedState` flips the pointer to THIS validated dir.
    private func loadReusableWarmSnapshotForSwitch(
        token: String,
        configuration: AppConfiguration
    ) async -> ReusablePreparedFilterSnapshot? {
        // Load-bearing warm-reuse validation lives in LavaSecCore (WarmFilterSnapshotLoader) so the
        // foreground switch and the headless Focus engine share ONE validation core and can't drift on
        // reuse safety (fresh-cache + manifest/coverage/source-hash + token-match + tier-cap + full
        // guardrail). This wrapper only supplies the App Group URLs the foreground already derives.
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return nil
        }
        return await WarmFilterSnapshotLoader.loadReusable(
            token: token,
            configuration: configuration,
            containerURL: containerURL,
            cacheURL: catalogCacheURL,
            freshnessMaxAge: catalogSyncFreshnessInterval
        )
    }

    /// Background rehydration of the per-source rule-set caches after an instant (warm) switch, so
    /// they describe the now-active filter instead of the previous one. A warm switch reuses the
    /// published artifact and never loads the per-source sets, leaving `cachedBlockRuleSets` stale;
    /// a cold switch leaves them fresh. Without this, an edit path that rebuilds block rules from
    /// those caches would use the wrong filter's sources. Cache-only (no network, no artifact
    /// re-publish) and superseded-checked, so it never clobbers a newer switch/restore/edit or moves
    /// the published pointer. (Codex #133 r4.)
    private func rehydrateRuleSetCachesAfterWarmSwitch(switchToken: Int, filterID: String) async {
        guard let cacheURL = catalogCacheURL,
              configurationReplacementGate.isCurrent(switchToken),
              library.activeFilterID == filterID else {
            return
        }
        let enabledIDs = configuration.enabledBlocklistIDs
        let customSources = enabledCustomBlocklists(in: configuration)
        let loadTask = Task.detached(priority: .utility) {
            () -> (BlocklistCatalogSyncResult, CustomBlocklistSyncResult)? in
            let synchronizer = BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL)
            guard let catalogResult = try? await synchronizer.loadCached(enabledSourceIDs: enabledIDs),
                  let customResult = try? await synchronizer.loadCachedCustomBlocklists(customSources) else {
                return nil
            }
            return (catalogResult, customResult)
        }
        guard let results = await loadTask.value else {
            // The per-source caches couldn't be loaded to rehydrate (a rare disk error). The pending
            // flag is still set, so in-place edits stay deferred (fail-safe). Fall back to an
            // authoritative catalog sync — which reloads the caches, republishes, and clears the flag
            // via applyCatalogSyncResult — so the gate self-heals instead of blocking edits until the
            // next incidental sync. Only if this warm switch is still the live owner.
            if configurationReplacementGate.isCurrent(switchToken), library.activeFilterID == filterID {
                await syncCatalog()
            }
            return
        }
        // Re-check after the load that NOTHING the rule caches depend on moved while we loaded. The
        // caches are a function of: the wholesale-replacement epoch (switch/restore/import/draft),
        // the active filter, its selection (enabled IDs + custom sources incl. content hash), and the
        // catalog version. An in-place edit (toggleBlocklist / add/removeCustomBlocklist — Codex r5)
        // or a completed catalog refresh (syncCatalog — Codex r6) mutates these WITHOUT advancing the
        // replacement token, and the latter already wrote fresh caches + newer artifacts; applying our
        // stale `results` over them would rebuild later snapshots from the old catalog. If anything
        // moved, bail — that path owns the caches and drives its own rebuild. Together these conditions
        // are the COMPLETE set of inputs the rule caches derive from. The catalog check is by CONTENT
        // (the loaded result must equal the live currentCatalog, BlocklistCatalog is Equatable), not
        // the top-level catalog_version string, so a source-content rotation that left catalog_version
        // unchanged still defers to the sync that produced the live catalog rather than reverting it.
        guard configurationReplacementGate.isCurrent(switchToken),
              library.activeFilterID == filterID,
              configuration.enabledBlocklistIDs == enabledIDs,
              enabledCustomBlocklists(in: configuration) == customSources,
              results.0.catalog == currentCatalog else {
            return
        }
        applySyncResults(catalogResult: results.0, customResult: results.1)
    }

    private func duplicateName(of name: String) -> String {
        "%@ copy".lavaLocalizedFormat(name)
    }

    // MARK: - Shareable filters

    /// The security-reviewed, shareable slice of the current setup (blocklists +
    /// blocked domains only — never allowlist exceptions or resolver details).
    var shareableFilterConfiguration: ShareableFilterConfiguration {
        ShareableFilterConfiguration(configuration: configuration)
    }

    /// The tamper-evident text/QR token that encodes ``shareableFilterConfiguration``.
    var shareableFilterConfigurationCode: String {
        shareableFilterConfiguration.encodedConfigurationCode()
    }

    /// Total rules a filter contributes in effect: the active filter's live compiled
    /// count, or a saved filter's projected list count plus its manual blocked domains.
    func filterRuleCount(for filter: Filter) -> Int {
        if filter.id == activeFilterID {
            return protectedRuleCount
        }
        return projectedFilterRuleCount(forEnabledIDs: filter.enabledBlocklistIDs).known
            + filter.blockedDomains.count
    }

    /// The shareable text/QR code for a specific saved filter (for sharing a filter other
    /// than the one in effect).
    func shareableFilterCode(for filter: Filter) -> String {
        ShareableFilterConfiguration(filter: filter).encodedConfigurationCode()
    }

    /// Whether a filter can be shared at all: it has something to share AND its code fits
    /// the shareable capacity (the higher of the QR/code limits). An oversized setup is
    /// "too big to share"; an empty filter has nothing to share.
    func isFilterShareable(_ filter: Filter) -> Bool {
        let shareable = ShareableFilterConfiguration(filter: filter)
        return !shareable.isEmpty && shareable.fitsShareableCodeCapacity()
    }

    /// Reconciles a shared config against this device's catalog/plan for a PREVIEW shown BEFORE the
    /// destination is chosen. Reserves the WORST-case rule budget — the largest allowlist among the
    /// existing filters (the most any Replace target could consume; Add uses 0) — so the preview is
    /// conservative and the apply (whatever destination, whose preserved count is ≤ this) never
    /// drops a list that was shown as imported. Each apply path re-plans against its real
    /// destination (a new filter = 0 exceptions; a replaced filter = that filter's exceptions).
    func importPlan(for shared: ShareableFilterConfiguration) -> ShareableFilterImportPlan {
        let worstCasePreserved = library.filters.map { $0.allowedDomains.count }.max() ?? 0
        return importPlan(for: shared, preservedAllowedDomainCount: worstCasePreserved)
    }

    /// Reconciles a shared config against this device's catalog and tier, with `preservedAllowedDomainCount`
    /// allowlist exceptions counted against the rule budget (the destination filter keeps its own
    /// exceptions, and they share the tier ceiling at snapshot-prep time).
    func importPlan(
        for shared: ShareableFilterConfiguration,
        preservedAllowedDomainCount: Int
    ) -> ShareableFilterImportPlan {
        let curatedIDs = Set(DefaultCatalog.curatedSources.map(\.id))
        let availableCuratedIDs = curatedIDs.union(catalogSourcesByID.keys)
        // An imported custom list may not claim any built-in list ID (curated or
        // guardrail), so a crafted code can't shadow a trusted list.
        let reservedIDs = curatedIDs
            .union(catalogSourcesByID.keys)
            .union(DefaultCatalog.guardrailSources.map(\.id))
        // Known per-list rule counts so the plan can trim over-budget selections
        // (e.g. a Plus setup imported on Free) before they fail at compile time.
        var ruleCounts: [String: Int] = [:]
        for (id, source) in catalogSourcesByID where source.entryCount > 0 {
            ruleCounts[id] = source.entryCount
        }
        for (id, ruleSet) in cachedBlockRuleSets where ruleCounts[id] == nil {
            ruleCounts[id] = ruleSet.count
        }
        let capabilities = ShareableFilterImportCapabilities(
            availableCuratedBlocklistIDs: availableCuratedIDs,
            reservedBlocklistIDs: reservedIDs,
            allowsCustomBlocklists: configuration.limits.allowsCustomBlocklists,
            maxBlockedDomains: configuration.limits.maxBlockedDomains,
            maxFilterRules: configuration.limits.maxFilterRules,
            blocklistRuleCounts: ruleCounts,
            // The destination filter's allowlist exceptions also count against the tier rule
            // budget at snapshot-prep time, so reserve them here.
            preservedRuleCount: preservedAllowedDomainCount
        )
        return shared.importPlan(capabilities: capabilities)
    }

    /// Replaces the block-side filter fields with an already-planned subset and
    /// rebuilds/persists the local snapshot. Allowlist exceptions, resolver,
    /// logging, and the protection toggle are preserved.
    func applyImportedShareableConfiguration(
        _ applied: ShareableFilterConfiguration
    ) async -> ShareableFilterImportResult {
        // Never let an import that reconciled to nothing wipe the existing setup.
        guard !applied.isEmpty else {
            return .failure(message: "There's nothing this device can import from that code.")
        }

        let nextConfiguration = configuration.applyingImportedShareableConfiguration(applied)

        let shouldRestoreProtection = configuration.protectionEnabled || isProtectionEnabledStatus(vpnStatus)

        // Claim the configuration-replacement token so a switch/restore that completes while this
        // import prepares supersedes it (and vice versa) instead of one silently reverting the other.
        let importToken = configurationReplacementGate.begin()

        do {
            let prepared = try await prepareFilterSnapshot(for: nextConfiguration)
            // A newer replacement took ownership while we prepared — abort without committing.
            guard configurationReplacementGate.isCurrent(importToken) else {
                return .failure(message: "Something else updated your filter while this imported. Try again.")
            }
            configuration = nextConfiguration
            // The ACTIVE filter's content was just replaced, so its per-filter draft (built from
            // the pre-import config) is stale — drop it. Other filters' drafts are untouched.
            activeFilterDraft = nil
            updateCustomBlocklistHashes(prepared.customResult.sourceHashes)
            try await persistSharedState(preparedSnapshot: prepared.snapshot)
            // Re-check after the persist's artifact-actor await (see switchToFilter): a newer
            // replacement that took ownership during it must not have its caches/config desynced by
            // this import's tail. Derived rule state (applyCatalogSyncResult) is therefore applied
            // only AFTER the persist + this gate — persistSharedState used prepared.snapshot, not the
            // caches, so deferring it is safe.
            guard configurationReplacementGate.isCurrent(importToken) else {
                return .failure(message: "Something else updated your filter while this imported. Try again.")
            }
            applyCatalogSyncResult(prepared.catalogResult)
            appendAppNetworkActivity(.changeFilters)

            await notifyTunnelSnapshotUpdated()
            await restoreProtectionIfNeeded(wasEnabled: shouldRestoreProtection)

            let ruleLabel = protectedRuleCount == 1 ? "rule" : "rules"
            catalogStatusMessage = "Imported \(protectedRuleCount.formatted()) \(ruleLabel) for local protection."
            catalogStatusIsError = false
            return .success(ruleCount: protectedRuleCount)
        } catch {
            return .failure(message: Self.filterPreparationFailureMessage(for: error))
        }
    }

    /// Import an already-reconciled shared setup (`applied` = the previewed plan) as a NEW filter
    /// named `name` (additive — leaves every existing filter untouched). Library-only: the new
    /// filter isn't switched to, so nothing compiles or reloads the tunnel. Takes the SAME plan the
    /// preview showed (no re-plan) so what was previewed is exactly what's added. Gated on
    /// ``canCreateFilter`` + a unique, non-empty name (UI validates; backstopped here). Returns the
    /// new filter's id or nil if blocked / nothing to import.
    @discardableResult
    func addImportedShareableConfigurationAsNewFilter(
        _ applied: ShareableFilterConfiguration,
        name: String
    ) -> String? {
        guard canCreateFilter, !applied.isEmpty else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFilterNameAvailable(trimmed) else { return nil }
        let newID = "filter-\(UUID().uuidString)"
        let newFilter = Filter(
            id: newID,
            name: trimmed,
            enabledBlocklistIDs: applied.enabledBlocklistIDs,
            customBlocklists: applied.customBlocklists,
            blockedDomains: applied.blockedDomains,
            // A shared code never carries allowlist exceptions, so a new imported filter starts
            // with none (matching the active-replace path, which preserves the device's own).
            allowedDomains: []
        )
        let previousLibrary = library
        library.append(newFilter)
        guard persistLibraryOnlyChange(rollingBackTo: previousLibrary) else { return nil }
        return newID
    }

    /// Replace an existing filter's contents with a shared setup, keeping that filter's id, name,
    /// and allowlist exceptions (a shared code never carries exceptions — same as the in-effect
    /// import path). Replacing the ACTIVE filter goes through the full prepare+publish+reload (it's
    /// loaded); a NON-active filter is replaced library-only (no recompile until it's next switched
    /// to — its compiled token is invalidated). Refuses an empty import, an unknown id, or a frozen
    /// (read-only) filter.
    func replaceFilterWithImportedShareableConfiguration(
        id: String,
        _ applied: ShareableFilterConfiguration
    ) async -> ShareableFilterImportResult {
        guard !applied.isEmpty else {
            return .failure(message: "There's nothing this device can import from that code.")
        }
        guard let target = library.filter(id: id), !isFilterFrozen(id) else {
            return .failure(message: "That filter is no longer available.")
        }
        // The active filter is loaded — reuse the full apply path (prepare + publish + tunnel
        // reload), which replaces the in-effect config and preserves the device's exceptions.
        if id == library.activeFilterID {
            return await applyImportedShareableConfiguration(applied)
        }
        // Non-active: library-only replace. Keep the filter's name + allowedDomains; swap the three
        // shared fields and invalidate its compiled token so a later switch recompiles.
        let previousLibrary = library
        library.mutateFilter(id: id) { filter in
            filter.enabledBlocklistIDs = applied.enabledBlocklistIDs
            filter.customBlocklists = applied.customBlocklists
            filter.blockedDomains = applied.blockedDomains
            filter.lastCompiledToken = nil
        }
        guard persistLibraryOnlyChange(rollingBackTo: previousLibrary) else {
            return .failure(message: "Couldn't save the imported filter. Please try again.")
        }
        // The replaced filter's contents changed, so its per-filter draft (built from the old
        // contents) is stale — drop it.
        filterEditDrafts[id] = nil
        let updated = library.filter(id: id) ?? target
        return .success(ruleCount: filterRuleCount(for: updated))
    }

    /// The *reason* a preparation failed, as user copy. The failure view frames it
    /// (title = "We couldn't update your filter", plus a separate "Your previous filter
    /// is still active." reassurance) — so this returns only the reason, no prefix.
    private static func filterPreparationFailureMessage(for error: Error) -> String {
        if let syncError = error as? BlocklistCatalogSyncError {
            switch syncError {
            case .checksumMismatch, .noAcceptedSourceHashes:
                return "Lava is still preparing an update for this blocklist source. Try again shortly."
            case .noCachedCatalog:
                return "Lava could not reach the source catalog. Check your connection and try again."
            case .invalidHTTPStatus, .invalidCatalog:
                return "Lava could not refresh the source catalog. Try again shortly."
            case .invalidBlocklistEncoding, .blocklistTooLarge, .blocklistExceedsRuleLimit,
                 .noRulesAvailable, .customBlocklistUnavailable:
                return syncError.localizedDescription
            case .missingEnabledBlocklistSource:
                return "A selected blocklist is no longer available. Choose another list and try again."
            }
        }

        return error.localizedDescription
    }

    private static func domainHistoryDomainActionRejectionTitle(for error: DomainHistoryDomainActionError) -> String {
        switch error {
        case .invalidDomain:
            return "Domain cannot be added"
        case .alreadyBlocked:
            return "Already blocked"
        case .alreadyAllowed:
            return "Already allowed"
        case .blockedDomainLimitReached:
            return "Blocked domain limit reached"
        case .allowedDomainLimitReached:
            return "Allowed exception limit reached"
        case .allowedDomainRejected:
            return "Exception cannot be added"
        }
    }

    func retryFilterPreparation() {
        Task {
            // Retry whatever the failure was: a filter switch (no draft) re-runs the
            // switch; otherwise re-apply the edit draft.
            if let id = pendingSwitchFilterID {
                await switchToFilter(id: id)
            } else {
                // Retry keeps the original surface's origin (e.g. a Domain History apply).
                await prepareAndApplyFilterDraft(origin: filterPreparationOrigin)
            }
        }
    }

    var tunnelCacheHitRateText: String {
        tunnelHealth.cacheHitRate.formatted(.percent.precision(.fractionLength(0)))
    }

    var tunnelTCPFallbackText: String {
        "\(tunnelHealth.tcpFallbackSuccessCount)/\(tunnelHealth.tcpFallbackAttemptCount)"
    }

    var tunnelDeviceDNSFallbackText: String {
        "\(tunnelHealth.deviceDNSFallbackActivationCount) activations · \(tunnelHealth.deviceDNSFallbackSuccessCount)/\(tunnelHealth.deviceDNSFallbackAttemptCount) query fallbacks"
    }

    var tunnelDNSSmokeProbeText: String {
        "\(tunnelHealth.dnsSmokeProbeSuccessCount)/\(tunnelHealth.dnsSmokeProbeSuccessCount + tunnelHealth.dnsSmokeProbeFailureCount)"
    }

    var tunnelDoHProtocolText: String {
        guard let version = tunnelHealth.lastDoHHTTPVersion else {
            return "None yet"
        }

        return "\(DoHHTTPVersion.dohAnnotation(negotiatedHTTPVersion: version)) (\(version))"
    }

    var tunnelHealthUpdatedText: String {
        tunnelHealth.updatedAt.formatted(date: .omitted, time: .shortened)
    }

    #if DEBUG || LAVA_QA_TOOLS
    var qaProbeSummaryText: String {
        configuration.qaProbeSet == nil ? "Off" : "Active"
    }

    var qaProbeDomains: [String] {
        configuration.qaProbeSet?.allDomains ?? QADomainProbeSet.hosted.allDomains
    }
    #endif

    var canOpenPhoneQAFromRageShake: Bool {
        #if DEBUG || LAVA_QA_TOOLS
        return isAccountDeveloper
        #else
        return false
        #endif
    }

    func handleRageShake() {
        let destination = RageShakeRouter.destination(allowsAdminQA: canOpenPhoneQAFromRageShake)
        if RageShakeRouter.requiresFeedbackConfirmation(for: destination) {
            pendingRageShakeConfirmation = destination
        } else {
            rageShakeDestination = destination
        }
    }

    func confirmRageShakeFeedback() {
        guard let destination = pendingRageShakeConfirmation else {
            return
        }
        pendingRageShakeConfirmation = nil
        // Let the confirmation alert finish dismissing before presenting the
        // sheet; presenting in the same runloop tick can drop it. Mirrors the
        // phone-QA -> bug-report hand-off below.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.pendingRageShakeConfirmation == nil else {
                // A fresh shake re-armed the confirmation while we waited; let
                // that newer gesture win instead of stacking a sheet under it.
                return
            }
            self.rageShakeDestination = destination
        }
    }

    func cancelRageShakeFeedback() {
        pendingRageShakeConfirmation = nil
    }

    func dismissRageShakeDestination() {
        rageShakeDestination = nil
    }

    func performProtectionPrimaryAction() {
        if isProtectionTemporarilyPaused {
            resumeProtectionNow()
            return
        }

        if vpnStatus == .connected,
           protectionConnectivityAssessment.primaryAction == .reconnect {
            reconnectProtection()
            return
        }

        toggleProtection()
    }

    func pauseProtectionTemporarily(for option: ProtectionPauseDuration) {
        pauseProtectionTemporarily(request: option.protectionCommandRequest)
    }

    // Shared pause flow. `.pauseConfigured` (the Live Activity's single Pause
    // button) resolves its length inside the command service from the shared
    // preference; the app then loads the resulting pause window from the store
    // exactly like the fixed-length options.
    private func pauseProtectionTemporarily(request: LavaLiveActivityActionRequest) {
        guard showsTemporaryProtectionPauseControls else {
            return
        }

        let operationID = LatencyOperationID.make()
        Task {
            let trace = makeLatencyTrace(operationID: operationID, operationKind: "pause")
            let span = trace.beginSpan("action.pause", details: [
                "kind": request.rawValue,
                "vpnStatus": vpnStatusDebugDescription(vpnStatus)
            ])
            var actionStatus = "started"
            defer {
                span.end(details: ["status": actionStatus, "vpnStatus": vpnStatusDebugDescription(vpnStatus)])
            }

            do {
                try await LavaProtectionCommandService.perform(request, commandID: operationID.rawValue)
                loadTemporaryProtectionPause()
                if isProtectionTemporarilyPaused {
                    scheduleTemporaryProtectionResume()
                }
                await notifyTunnelProtectionPauseUpdated(operationID: operationID)
                reconcileLiveActivity()
                actionStatus = isProtectionTemporarilyPaused ? "paused" : "noop"
            } catch {
                actionStatus = "error"
                vpnMessage = Self.vpnErrorMessage(prefix: "Could not pause protection", error: error)
                vpnMessageIsError = true
            }
        }
    }

    func resumeProtectionNow() {
        guard isProtectionTemporarilyPaused else {
            return
        }

        guard protectionActionOrchestrator.claim(.resume) else {
            return
        }

        let operationID = LatencyOperationID.make()
        Task {
            await restoreFiltersAfterTemporaryProtectionPause(
                configurationAlreadyClaimed: true,
                operationID: operationID
            )
            reconcileLiveActivity()
        }
    }

    func reconcileTemporaryProtectionPause() {
        loadTemporaryProtectionPause()

        guard isProtectionTemporarilyPaused else {
            reconcileLiveActivity()
            return
        }

        scheduleTemporaryProtectionResume()
        Task {
            await resumeTemporaryProtectionIfExpired()
            reconcileLiveActivity()
        }
    }

    func reconcileLiveActivity() {
        loadTemporaryProtectionPause()
        if isProtectionTemporarilyPaused {
            scheduleTemporaryProtectionResume()
        }

        // Read the restart deadline ONCE and derive both the state and resumeDate
        // from it — a second read could expire between the two and republish
        // `.restarting` with no deadline, defeating the widget's self-clear.
        // Both transient states carry their self-resolve deadline in `resumeDate`:
        // the resume time when paused, the restart deadline when restarting.
        let restartDeadline = restartInFlightDeadline
        let protectionState = liveActivityProtectionState(restartInFlightDeadline: restartDeadline)
        let resumeDate = protectionState == .restarting ? restartDeadline : temporaryProtectionPauseUntil

        Task {
            await liveActivityController.reconcile(
                usesLiveActivities: usesLiveActivities,
                protectionState: protectionState,
                resumeDate: resumeDate,
                shieldStyle: lavaGuardLook,
                pauseMinutes: liveActivityPauseMinutes,
                pauseRequiresAuthentication: SecurityProtectedSurfaceStorage.isProtected(
                    .protectionPause,
                    defaults: appGroupDefaults
                )
            )
        }
    }

    /// Responds to the tunnel's connectivity-health Darwin nudge: pull the fresh
    /// health over the reliable provider-message channel, then let
    /// `refreshTunnelHealth` reconcile the Live Activity if the derived Dynamic
    /// Island state changed (UR-6).
    func handleTunnelHealthNudge() {
        Task { [weak self] in
            guard let self else {
                return
            }

            await self.requestTunnelHealthFlush()
            self.refreshTunnelHealth(force: true)
        }
    }

    func performLiveActivityActionRequest(_ request: LavaLiveActivityActionRequest) {
        switch request {
        case .pauseFiveMinutes:
            pauseProtectionTemporarily(for: .fiveMinutes)
        case .pauseTenMinutes:
            pauseProtectionTemporarily(for: .tenMinutes)
        case .pauseFifteenMinutes:
            pauseProtectionTemporarily(for: .fifteenMinutes)
        case .pauseConfigured:
            pauseProtectionTemporarily(request: .pauseConfigured)
        case .resume:
            resumeProtectionNow()
        case .reconnect:
            reconnectProtection()
        }
    }

    // The deadline of an in-flight Dynamic Island Restart (shared-defaults), or nil
    // when none is running / it has expired. Travels as the activity's `resumeDate`
    // so the widget self-advances `.restarting → .on` at the same instant the
    // command's own push would, keeping the two push paths consistent.
    private var restartInFlightDeadline: Date? {
        let raw = appGroupDefaults.double(
            forKey: LavaSecAppGroup.protectionRestartInFlightUntilDefaultsKey
        )
        guard raw > Date().timeIntervalSinceReferenceDate else {
            return nil
        }
        return Date(timeIntervalSinceReferenceDate: raw)
    }

    private var isRestartInFlight: Bool {
        restartInFlightDeadline != nil
    }

    // Takes the restart deadline as a parameter (rather than re-reading it) so the
    // caller can derive the state and the `resumeDate` from the SAME captured value.
    private func liveActivityProtectionState(
        restartInFlightDeadline: Date?
    ) -> LavaActivityAttributes.ProtectionState? {
        // A user-initiated Restart is in flight (the Restart command set a shared
        // deadline). Hold the Dynamic Island on the transient "restarting" feedback
        // — checked before the vpnStatus guard — so the status notifications the
        // restart itself emits (connected → disconnecting → connecting) neither end
        // the activity nor clobber it with `.on`. The command pushes the same state,
        // so the two agree; the deadline auto-expires if the restart never reports.
        if restartInFlightDeadline != nil {
            return .restarting
        }

        guard vpnStatus == .connected else {
            return nil
        }

        if isProtectionTemporarilyPaused {
            return .paused
        }

        // The Dynamic Island deliberately does not surface transient connectivity
        // status (reconnecting / needs-reconnect / no-network). Those states
        // originate in the always-running tunnel and change while the app is
        // suspended, so the app can never push a timely correction — a stale
        // alarm or stale all-clear is the result. Lava is fail-closed, so a
        // reconnect wobble blocks traffic rather than exposing it, which makes a
        // steady "On" honest. The user's recovery affordance is the always-
        // available Restart action, not a reactive alarm the surface can't keep
        // fresh. The in-app Guard tab still renders live connectivity detail.
        return .on
    }

    func turnOffProtection() {
        #if targetEnvironment(simulator)
        guard !protectionActionOrchestrator.isActionInFlight else {
            return
        }
        vpnMessage = "Use a physical phone to test VPN permission and tunneling."
        vpnMessageIsError = false
        #else
        guard protectionActionOrchestrator.claim(.turnOff) else {
            return
        }
        Task {
            await disableProtection()
            protectionActionOrchestrator.release(.turnOff)
        }
        #endif
    }

    func reconnectProtection() {
        #if targetEnvironment(simulator)
        guard !protectionActionOrchestrator.isActionInFlight else {
            return
        }
        vpnMessage = "Use a physical phone to test VPN permission and tunneling."
        vpnMessageIsError = false
        #else
        guard protectionActionOrchestrator.claim(.reconnect) else {
            return
        }
        appendAppNetworkActivity(.reconnectProtection)
        Task {
            await reconnectProtectionNow()
            protectionActionOrchestrator.release(.reconnect)
        }
        #endif
    }

    func toggleProtection() {
        #if targetEnvironment(simulator)
        guard !protectionActionOrchestrator.isActionInFlight else {
            return
        }
        vpnMessage = "Use a physical phone to test VPN permission and tunneling."
        vpnMessageIsError = false
        #else
        guard protectionActionOrchestrator.claim(.toggle) else {
            return
        }
        let shouldDisableProtection = isProtectionEnabledStatus(vpnStatus)
        Task {
            if shouldDisableProtection {
                await disableProtection()
            } else {
                await enableProtection()
            }
            protectionActionOrchestrator.release(.toggle)
        }
        #endif
    }

    func installLocalVPNProfileForOnboarding() async -> Bool {
        guard protectionActionOrchestrator.claim(.installProfile) else {
            vpnMessage = "Finish the current VPN setup first."
            vpnMessageIsError = false
            return false
        }

        defer {
            protectionActionOrchestrator.release(.installProfile)
        }

        #if targetEnvironment(simulator)
        vpnMessage = "Use a physical phone to install the VPN profile."
        vpnMessageIsError = false
        return true
        #else
        vpnMessage = "Preparing local VPN..."
        vpnMessageIsError = false

        do {
            try await persistSharedState()

            let existingManager = try await loadExistingTunnelManager()
            let manager = try await loadOrCreateTunnelManager(existingManager: existingManager)
            tunnelManager = manager
            updateProtectionStatus(from: manager)
            lastProtectionStatusRefresh = Date()

            vpnMessage = nil
            vpnMessageIsError = false
            return true
        } catch {
            vpnMessage = Self.vpnErrorMessage(prefix: "Could not install VPN profile", error: error)
            vpnMessageIsError = true
            return false
        }
        #endif
    }

    func requestProtectionNotificationAuthorizationForOnboarding() async -> Bool {
        await protectionUserNotifications.requestAuthorization()
    }

    func applyOnboardingRecommendedDefaults(protectionLevel: OnboardingProtectionLevel = .recommended) {
        let defaults = AppConfiguration.lavaRecommendedDefaults
        // The surfaced choices are owned by their steps: the protection level by the
        // protection-level step and the resolver + encrypted-fallback fields by the
        // connection-quality step (applyOnboardingConnectionPreferences). Only the non-surfaced
        // residual (local logging retention) is applied here as setup wraps up.
        configuration.keepFilteringCounts = defaults.keepFilteringCounts
        configuration.keepDomainDiagnostics = defaults.keepDomainDiagnostics
        configuration.keepNetworkActivity = defaults.keepNetworkActivity
        // Seed the three default filters (Core / Balanced / Extra) into "Your filters" with the
        // chosen level loaded; mirror its blocklist set into the live config so the active filter
        // and config agree.
        library = .seededDefaults(active: protectionLevel)
        mirrorActiveFilterIntoConfiguration()
        rebuildEnabledBlockRules()
        persistFilterChanges()
        startOnboardingDefaultBlocklistSyncIfNeeded()
    }

    /// Apply the onboarding connection-quality choice (Device DNS primary + an optional
    /// encrypted DoH fallback). Owns every resolver/fallback field so the `.done`
    /// residual apply never clobbers it.
    func applyOnboardingConnectionPreferences(useEncryptedFallback: Bool, fallbackResolverPresetID: String) {
        let defaults = AppConfiguration.lavaRecommendedDefaults
        configuration.resolverPresetID = DNSResolverPreset.device.id
        configuration.customResolverAddress = defaults.customResolverAddress
        configuration.customResolverName = defaults.customResolverName
        configuration.fallbackToDeviceDNS = defaults.fallbackToDeviceDNS
        configuration.usesEncryptedDeviceDNSFallback = useEncryptedFallback
        configuration.fallbackResolverPresetID = fallbackResolverPresetID
        configuration.fallbackCustomResolverAddress = nil
        configuration.fallbackCustomResolverSecondaryAddress = nil
        configuration.fallbackCustomResolverName = nil
        persistFilterChanges()
    }

    func selectOnboardingBlocklists(_ sourceIDs: Set<String>) {
        guard !sourceIDs.isEmpty else {
            return
        }

        guard configuration.enabledBlocklistIDs != sourceIDs else {
            return
        }

        configuration.enabledBlocklistIDs = sourceIDs
        rebuildEnabledBlockRules()
        catalogStatusMessage = "Blocklist selection updated."
        catalogStatusIsError = false
        persistFilterChanges()
        startOnboardingBlocklistSyncIfNeeded(for: sourceIDs)
    }

    private func startOnboardingDefaultBlocklistSyncIfNeeded() {
        startOnboardingBlocklistSyncIfNeeded(for: configuration.enabledBlocklistIDs)
    }

    private func startOnboardingBlocklistSyncIfNeeded(for sourceIDs: Set<String>) {
        let missingSourceIDs = sourceIDs.filter { cachedBlockRuleSets[$0] == nil }
        guard !missingSourceIDs.isEmpty, !isSyncingCatalog else {
            return
        }

        Task {
            await self.syncCatalog()
        }
    }

    func selectOnboardingBlocklist(_ blocklist: BlocklistSource) {
        guard configuration.enabledBlocklistIDs != Set([blocklist.id]) else {
            return
        }

        configuration.enabledBlocklistIDs = [blocklist.id]
        rebuildEnabledBlockRules()
        catalogStatusMessage = "\(blocklist.name) selected."
        catalogStatusIsError = false
        persistFilterChanges()

        guard cachedBlockRuleSets[blocklist.id] == nil, !isSyncingCatalog else {
            return
        }

        Task {
            await self.syncCatalog()
        }
    }

    /// Reason an in-place blocklist edit must be deferred right now, or nil if it may proceed. Today
    /// the only blocker is a pending warm-switch cache rehydration: editing while `cachedBlockRuleSets`
    /// still describes the previous filter would rebuild + publish the target filter from the wrong
    /// filter's rule sets (Codex #133). Callers surface the reason (String?-returning callers return
    /// it; void callers show it via catalogStatusMessage) so the edit is refused, not silently wrong.
    private func deferralReasonForInPlaceBlocklistEdit() -> String? {
        guard hasPendingWarmSwitchCacheRehydration else { return nil }
        return "Finishing the filter switch. Try again in a moment."
    }

    func toggleBlocklist(_ blocklist: BlocklistSource) {
        if let reason = deferralReasonForInPlaceBlocklistEdit() {
            catalogStatusMessage = reason
            catalogStatusIsError = false
            ProtectionHapticFeedback.play(.selectionRejected)
            return
        }
        if configuration.enabledBlocklistIDs.contains(blocklist.id) {
            configuration.enabledBlocklistIDs.remove(blocklist.id)
            rebuildEnabledBlockRules()
            catalogStatusMessage = "Disabled \(blocklist.name)."
            catalogStatusIsError = false
            persistFilterChanges()
            ProtectionHapticFeedback.play(.selectionConfirmed)
            return
        }

        guard catalogSourcesByID[blocklist.id] != nil else {
            catalogStatusMessage = "This source is not available yet."
            catalogStatusIsError = true
            ProtectionHapticFeedback.play(.selectionRejected)
            return
        }

        guard !isSyncingCatalog else {
            catalogStatusMessage = "Finish the current filter update first."
            catalogStatusIsError = false
            ProtectionHapticFeedback.play(.selectionRejected)
            return
        }

        guard !enabledIDsExceedSoftRuleBudget(configuration.enabledBlocklistIDs.union([blocklist.id])) else {
            catalogStatusMessage = filterRuleBudgetMessage()
            catalogStatusIsError = true
            ProtectionHapticFeedback.play(.selectionRejected)
            return
        }

        guard cachedBlockRuleSets[blocklist.id] != nil else {
            configuration.enabledBlocklistIDs.insert(blocklist.id)
            catalogStatusMessage = "Downloading \(blocklist.name)..."
            catalogStatusIsError = false
            ProtectionHapticFeedback.play(.selectionConfirmed)
            Task {
                await syncCatalog()
            }
            return
        }

        configuration.enabledBlocklistIDs.insert(blocklist.id)
        rebuildEnabledBlockRules()
        catalogStatusMessage = "Enabled \(blocklist.name)."
        catalogStatusIsError = false
        persistFilterChanges()
        ProtectionHapticFeedback.play(.selectionConfirmed)
    }

    func addCustomBlocklist(displayName: String, rawURL: String) -> String? {
        if let reason = deferralReasonForInPlaceBlocklistEdit() {
            return reason
        }
        guard configuration.limits.allowsCustomBlocklists else {
            return "Custom blocklist URLs are included with Lava Plus."
        }

        do {
            let source = try CustomBlocklistSource(displayName: displayName, rawURL: rawURL)
            if let catalogSourceID = KnownBlocklistURLMatcher.catalogSourceID(for: source.sourceURL) {
                if !configuration.enabledBlocklistIDs.contains(catalogSourceID),
                   enabledIDsExceedSoftRuleBudget(configuration.enabledBlocklistIDs.union([catalogSourceID])) {
                    return filterRuleBudgetMessage()
                }

                configuration.customBlocklists.removeAll {
                    $0.sourceURL == source.sourceURL
                        || KnownBlocklistURLMatcher.catalogSourceID(for: $0.sourceURL) == catalogSourceID
                }
                configuration.enabledBlocklistIDs.insert(catalogSourceID)
                rebuildEnabledBlockRules()
                persistFilterChanges()
                catalogStatusMessage = "Enabled \(blocklistName(for: catalogSourceID))."
                catalogStatusIsError = false

                guard !isSyncingCatalog else {
                    return nil
                }

                Task {
                    await syncCatalog()
                }

                return nil
            }

            guard !configuration.customBlocklists.contains(where: { $0.sourceURL == source.sourceURL }) else {
                return "That custom URL is already added."
            }

            let displayKey = customBlocklistDisplayKey(for: source)
            guard !configuration.customBlocklists.contains(where: { existingSource in
                existingSource.sourceURL != source.sourceURL
                    && customBlocklistDisplayKey(for: existingSource) == displayKey
            }) else {
                return "A custom list with that name already exists."
            }

            let updatedIDs = configuration.enabledBlocklistIDs.union([source.id])
            guard !enabledIDsExceedSoftRuleBudget(updatedIDs) else {
                return filterRuleBudgetMessage()
            }

            configuration.customBlocklists.append(source)
            configuration.enabledBlocklistIDs = updatedIDs
            rebuildEnabledBlockRules()
            persistFilterChanges()
            catalogStatusMessage = "Added custom blocklist."
            catalogStatusIsError = false

            guard !isSyncingCatalog else {
                return nil
            }

            Task {
                await syncCatalog()
            }

            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removeCustomBlocklist(id: String) {
        if let reason = deferralReasonForInPlaceBlocklistEdit() {
            catalogStatusMessage = reason
            catalogStatusIsError = false
            ProtectionHapticFeedback.play(.selectionRejected)
            return
        }
        configuration.customBlocklists.removeAll { $0.id == id }
        configuration.enabledBlocklistIDs.remove(id)
        cachedBlockRuleSets[id] = nil
        rebuildEnabledBlockRules()
        catalogStatusMessage = "Removed custom blocklist."
        catalogStatusIsError = false
        persistFilterChanges()
    }

    func addAllowlistDraft() {
        let validator = AllowlistValidator(nonAllowableThreatRules: threatGuardrail)
        let result = validator.validate(allowlistDraft)

        guard result.isAllowed, let domain = result.normalizedDomain else {
            lastAllowlistMessage = result.message
            return
        }

        guard configuration.allowedDomains.count < configuration.limits.maxAllowedDomains else {
            lastAllowlistMessage = "Free protection includes \(configuration.limits.maxAllowedDomains) allowed domains."
            return
        }

        configuration.allowedDomains.insert(domain)
        allowlistDraft = ""
        lastAllowlistMessage = "Added \(domain)."
        persistFilterChanges()
    }

    func removeAllowedDomain(_ domain: String) {
        if configuration.allowedDomains.remove(domain) != nil {
            lastAllowlistMessage = "Removed \(domain)."
            persistFilterChanges()
        }
    }

    func setResolver(_ preset: DNSResolverPreset) {
        guard configuration.resolverPresetID != preset.id else {
            return
        }

        configuration.resolverPresetID = preset.id
        persistResolverSettings(activity: .changeResolver)
    }

    func setCustomResolverAddresses(primary rawPrimaryValue: String, secondary rawSecondaryValue: String) {
        let trimmedPrimaryValue = rawPrimaryValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecondaryValue = rawSecondaryValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSecondaryValue = trimmedSecondaryValue.isEmpty ? nil : trimmedSecondaryValue
        if let validationMessage = DNSResolverPreset.customValidationMessage(
            primaryRawValue: trimmedPrimaryValue,
            secondaryRawValue: trimmedSecondaryValue,
            supportsDNSOverQUIC: supportsDNSOverQUIC
        ) {
            vpnMessage = validationMessage
            vpnMessageIsError = true
            return
        }

        guard configuration.resolverPresetID != DNSResolverPreset.customID
            || configuration.customResolverAddress != trimmedPrimaryValue
            || configuration.customResolverSecondaryAddress != normalizedSecondaryValue
        else {
            return
        }

        configuration.resolverPresetID = DNSResolverPreset.customID
        configuration.customResolverAddress = trimmedPrimaryValue
        configuration.customResolverSecondaryAddress = normalizedSecondaryValue
        persistResolverSettings(activity: .changeResolver)
    }

    func clearCustomResolver(fallback preset: DNSResolverPreset) {
        let fallbackPreset = preset.id == DNSResolverPreset.customID ? DNSResolverPreset.google : preset
        let hasSavedCustomResolver = configuration.customResolverAddress != nil
            || configuration.customResolverSecondaryAddress != nil
            || configuration.customResolverName != nil
        let resolverNeedsFallback = configuration.resolverPresetID == DNSResolverPreset.customID
        guard hasSavedCustomResolver || resolverNeedsFallback else {
            return
        }

        configuration.customResolverAddress = nil
        configuration.customResolverSecondaryAddress = nil
        configuration.customResolverName = nil
        if configuration.resolverPresetID == DNSResolverPreset.customID {
            configuration.resolverPresetID = fallbackPreset.id
        }
        persistResolverSettings(activity: .changeResolver)
    }

    func setCustomResolverAddress(_ rawValue: String) {
        setCustomResolverAddresses(primary: rawValue, secondary: configuration.customResolverSecondaryAddress ?? "")
    }

    func setCustomResolverName(_ rawValue: String) {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextValue = trimmedValue.isEmpty ? nil : trimmedValue
        let currentValue = configuration.customResolverName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCurrentValue = currentValue?.isEmpty == true ? nil : currentValue
        guard normalizedCurrentValue != nextValue else {
            return
        }

        configuration.customResolverName = nextValue
        do {
            try persistConfigurationOnly()
        } catch {
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
        }
    }

    private func persistResolverSettings(activity: NetworkActivityUserAction) {
        do {
            try persistConfigurationOnly()
            appendAppNetworkActivity(activity)
            Task {
                await self.sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)
            }
        } catch {
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
        }
    }

    func setFallbackToDeviceDNS(_ fallbackToDeviceDNS: Bool) {
        guard configuration.fallbackToDeviceDNS != fallbackToDeviceDNS else {
            return
        }

        configuration.fallbackToDeviceDNS = fallbackToDeviceDNS
        do {
            try persistConfigurationOnly()
            appendAppNetworkActivity(.toggleDeviceDNSFallback)
            Task {
                await self.sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)
            }
        } catch {
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
        }
    }

    func setUsesEncryptedDeviceDNSFallback(_ usesEncryptedDeviceDNSFallback: Bool) {
        guard configuration.usesEncryptedDeviceDNSFallback != usesEncryptedDeviceDNSFallback else {
            return
        }

        configuration.usesEncryptedDeviceDNSFallback = usesEncryptedDeviceDNSFallback
        do {
            try persistConfigurationOnly()
            appendAppNetworkActivity(.toggleDeviceDNSFallback)
            Task {
                await self.sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)
            }
        } catch {
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
        }
    }

    func setFallbackResolver(_ preset: DNSResolverPreset) {
        guard configuration.fallbackResolverPresetID != preset.id else {
            return
        }

        configuration.fallbackResolverPresetID = preset.id
        persistResolverSettings(activity: .changeResolver)
    }

    func setFallbackCustomResolverAddresses(primary rawPrimaryValue: String, secondary rawSecondaryValue: String) {
        let trimmedPrimaryValue = rawPrimaryValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecondaryValue = rawSecondaryValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSecondaryValue = trimmedSecondaryValue.isEmpty ? nil : trimmedSecondaryValue
        if let validationMessage = DNSResolverPreset.customValidationMessage(
            primaryRawValue: trimmedPrimaryValue,
            secondaryRawValue: trimmedSecondaryValue,
            supportsDNSOverQUIC: supportsDNSOverQUIC
        ) {
            vpnMessage = validationMessage
            vpnMessageIsError = true
            return
        }

        guard configuration.fallbackResolverPresetID != DNSResolverPreset.customID
            || configuration.fallbackCustomResolverAddress != trimmedPrimaryValue
            || configuration.fallbackCustomResolverSecondaryAddress != normalizedSecondaryValue
        else {
            return
        }

        configuration.fallbackResolverPresetID = DNSResolverPreset.customID
        configuration.fallbackCustomResolverAddress = trimmedPrimaryValue
        configuration.fallbackCustomResolverSecondaryAddress = normalizedSecondaryValue
        persistResolverSettings(activity: .changeResolver)
    }

    func clearFallbackCustomResolver(fallback preset: DNSResolverPreset) {
        let fallbackPreset = preset.id == DNSResolverPreset.customID ? DNSResolverPreset.mullvadDoH : preset
        let hasSavedCustomResolver = configuration.fallbackCustomResolverAddress != nil
            || configuration.fallbackCustomResolverSecondaryAddress != nil
            || configuration.fallbackCustomResolverName != nil
        let resolverNeedsFallback = configuration.fallbackResolverPresetID == DNSResolverPreset.customID
        guard hasSavedCustomResolver || resolverNeedsFallback else {
            return
        }

        configuration.fallbackCustomResolverAddress = nil
        configuration.fallbackCustomResolverSecondaryAddress = nil
        configuration.fallbackCustomResolverName = nil
        if configuration.fallbackResolverPresetID == DNSResolverPreset.customID {
            configuration.fallbackResolverPresetID = fallbackPreset.id
        }
        persistResolverSettings(activity: .changeResolver)
    }

    func setFallbackCustomResolverAddress(_ rawValue: String) {
        setFallbackCustomResolverAddresses(primary: rawValue, secondary: configuration.fallbackCustomResolverSecondaryAddress ?? "")
    }

    func setFallbackCustomResolverName(_ rawValue: String) {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextValue = trimmedValue.isEmpty ? nil : trimmedValue
        let currentValue = configuration.fallbackCustomResolverName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCurrentValue = currentValue?.isEmpty == true ? nil : currentValue
        guard normalizedCurrentValue != nextValue else {
            return
        }

        configuration.fallbackCustomResolverName = nextValue
        do {
            try persistConfigurationOnly()
        } catch {
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
        }
    }

    #if DEBUG || LAVA_QA_TOOLS
    func applyHostedQAProbeSet() {
        configuration.qaProbeSet = .hosted
        vpnMessage = "Hosted QA probes are active."
        vpnMessageIsError = false
        persistFilterChanges()
    }

    func applyCustomQAProbeSet() {
        do {
            configuration.qaProbeSet = try QADomainProbeSet(suffix: qaProbeSuffixDraft)
            vpnMessage = "Custom QA probes are active."
            vpnMessageIsError = false
            persistFilterChanges()
        } catch {
            vpnMessage = "Could not apply QA probes: \(error.localizedDescription)"
            vpnMessageIsError = true
        }
    }

    func clearQAProbeSet() {
        configuration.qaProbeSet = nil
        vpnMessage = "QA probes cleared."
        vpnMessageIsError = false
        persistFilterChanges()
    }

    func setQAPlanMode(isPaid: Bool) {
        configuration.isPaid = isPaid
        adminQAStatusMessage = isPaid ? "Paid state is active." : "Free state is active."
        vpnMessageIsError = false
        persistFilterChanges()
    }

    func prepareQAInternetNetworkCondition(_ condition: QAInternetNetworkCondition) {
        configuration.qaProbeSet = .hosted
        adminQAStatusMessage = "\(condition.title): \(condition.expectedOutcome)"
        vpnMessageIsError = false
        persistFilterChanges()
    }

    func applyQAInternetDNSSetup(_ setup: QAInternetDNSSetup) {
        configuration.resolverPresetID = setup.resolverPresetID
        configuration.customResolverAddress = setup.customResolverAddress
        configuration.customResolverSecondaryAddress = nil
        configuration.customResolverName = setup.customResolverName
        configuration.fallbackToDeviceDNS = setup.fallbackToDeviceDNS
        configuration.usesEncryptedDeviceDNSFallback = setup.usesEncryptedDeviceDNSFallback
        configuration.fallbackResolverPresetID = setup.fallbackResolverPresetID
        configuration.fallbackCustomResolverAddress = setup.fallbackCustomResolverAddress
        configuration.fallbackCustomResolverSecondaryAddress = nil
        configuration.fallbackCustomResolverName = setup.fallbackCustomResolverName
        configuration.isPaid = configuration.isPaid || setup.resolverPresetID == DNSResolverPreset.customID
        adminQAStatusMessage = "\(setup.title) is active."
        vpnMessageIsError = false
        persistResolverSettings(activity: .changeResolver)
    }

    func applyQAInternetBlocklistLoad(_ load: QAInternetBlocklistLoad) {
        configuration.enabledBlocklistIDs = load.enabledBlocklistIDs
        // Compile the new selection into blockRules before persisting: persistFilterChanges
        // serializes the in-memory blockRules, so without this the QA load would persist the
        // previous load's compiled rules/counts while the UI says the new load is active.
        rebuildEnabledBlockRules()
        adminQAStatusMessage = "\(load.title) blocklist load is active."
        vpnMessageIsError = false
        persistFilterChanges()
        startQAInternetBlocklistSyncIfNeeded(for: load.enabledBlocklistIDs)
    }

    func applyQAInternetScenarioSuite(_ suite: QAInternetScenarioSuite) {
        let scenario = suite.startingScenario
        configuration.qaProbeSet = .hosted
        // Set + compile the blocklist load before applying DNS so neither tunnel reload
        // (resolver-config reload from applyQAInternetDNSSetup, snapshot reload from
        // persistFilterChanges) fires against the previous blocklist set or stale blockRules.
        configuration.enabledBlocklistIDs = scenario.blocklistLoad.enabledBlocklistIDs
        rebuildEnabledBlockRules()
        applyQAInternetDNSSetup(scenario.dnsSetup)
        adminQAStatusMessage = "\(suite.title) ready: start with \(scenario.title). \(suite.totalCombinationCount) combinations total."
        vpnMessageIsError = false
        persistFilterChanges()
        startQAInternetBlocklistSyncIfNeeded(for: scenario.blocklistLoad.enabledBlocklistIDs)
    }

    // Mirrors the catalog sync the normal enable paths kick (see
    // startOnboardingBlocklistSyncIfNeeded): the QA apply* methods only assign
    // enabledBlocklistIDs, so any selected source missing from the rule cache must be
    // downloaded for the load (e.g. Recommended/Large/Stress) to actually materialize.
    private func startQAInternetBlocklistSyncIfNeeded(for sourceIDs: Set<String>) {
        guard sourceIDs.contains(where: { cachedBlockRuleSets[$0] == nil }) else {
            return
        }

        Task {
            // A refresh already in flight (e.g. the launch sync) captured the previous
            // selection, so wait for it to finish before syncing — otherwise the newly
            // selected QA sources never download and the load persists with missing rules.
            // Gate on catalogSyncTask (set synchronously at the start of syncCatalog), not
            // isSyncingCatalog (set later inside performCatalogSync), to also catch the
            // window between the two — matching the turn-on path.
            if catalogSyncTask != nil {
                await self.waitForCatalogSyncToFinish()
            }
            guard sourceIDs.contains(where: { cachedBlockRuleSets[$0] == nil }) else {
                return
            }
            await self.syncCatalog()
        }
    }

    func applyAdminQAAction(_ action: AdminQAAction) {
        switch action {
        case .showWelcome:
            adminQAStatusMessage = "Welcome screen requested."
        case .showUserBugReport:
            adminQAStatusMessage = "Normal user bug report requested."
        case .applyHostedProbes:
            applyHostedQAProbeSet()
            adminQAStatusMessage = "Hosted probes are active."
        case .testDefaultAllow:
            configuration.qaProbeSet = .hosted
            adminQAStatusMessage = "Default allow check ready: \(QADomainProbeSet.hosted.allowedDomain) should load."
            persistFilterChanges()
        case .testAllowlist:
            configuration.qaProbeSet = .hosted
            adminQAStatusMessage = "Allow list check ready: \(QADomainProbeSet.hosted.exceptionDomain) should load."
            persistFilterChanges()
        case .testDenylist:
            configuration.qaProbeSet = .hosted
            adminQAStatusMessage = "Deny list check ready: \(QADomainProbeSet.hosted.blockedDomain) should be blocked."
            persistFilterChanges()
        case .testThreatGuardrail:
            configuration.qaProbeSet = .hosted
            adminQAStatusMessage = "Threat guardrail check ready: \(QADomainProbeSet.hosted.guardrailDomain) should stay blocked even as an exception."
            persistFilterChanges()
        case .setGoogleDNS:
            setResolver(.google)
            adminQAStatusMessage = "Google DNS is active."
        case .setCloudflareDoH:
            setResolver(.cloudflareDoH)
            adminQAStatusMessage = "Cloudflare DoH is active."
        case .setCloudflareDoT:
            setResolver(.cloudflareDoT)
            adminQAStatusMessage = "Cloudflare DoT is active."
        case .enableLocalDomainHistory:
            setKeepDomainDiagnostics(true, clearHistory: false)
            adminQAStatusMessage = "Local domain history is enabled."
        case .disableLocalDomainHistory:
            setKeepDomainDiagnostics(false)
            adminQAStatusMessage = "Local domain history is disabled and cleared."
        case .clearLocalActivity:
            clearDiagnostics()
            adminQAStatusMessage = "Local activity rows cleared."
        case .setPaidPlan:
            setQAPlanMode(isPaid: true)
        case .setFreePlan:
            setQAPlanMode(isPaid: false)
        case .clearQAState:
            configuration.qaProbeSet = nil
            configuration.isPaid = false
            configuration.resolverPresetID = DNSResolverPreset.google.id
            configuration.keepDomainDiagnostics = false
            clearDiagnostics()
            adminQAStatusMessage = "QA state cleared."
            persistFilterChanges()
        }

        vpnMessageIsError = false
    }

    func applyAdminQAVPNProfileAction(_ action: AdminQAVPNProfileAction) async {
        guard protectionActionOrchestrator.claim(.adminQAProfile) else {
            adminQAStatusMessage = "Finish the current VPN profile action first."
            return
        }

        defer {
            protectionActionOrchestrator.release(.adminQAProfile)
        }

        switch action {
        case .installProfile:
            await installAdminQAVPNProfile()
        case .removeProfile:
            await removeAdminQAVPNProfile()
        case .resetProfile:
            await resetAdminQAVPNProfile()
        }
    }

    private func installAdminQAVPNProfile() async {

        #if targetEnvironment(simulator)
        adminQAStatusMessage = "VPN profile testing requires a physical phone."
        vpnMessage = "Use a physical phone to install the VPN profile."
        vpnMessageIsError = false
        #else
        adminQAStatusMessage = "Installing VPN profile..."
        vpnMessage = "Preparing VPN profile..."
        vpnMessageIsError = false

        do {
            try await persistSharedState()

            let existingManager = try await loadExistingTunnelManager()
            if existingManager == nil {
                vpnMessage = Self.vpnPermissionPromptMessage
                vpnMessageIsError = false
            }

            let manager = try await loadOrCreateTunnelManager(existingManager: existingManager)
            tunnelManager = manager
            updateProtectionStatus(from: manager)
            lastProtectionStatusRefresh = Date()

            adminQAStatusMessage = "VPN profile installed."
            vpnMessage = nil
            vpnMessageIsError = false
        } catch {
            adminQAStatusMessage = "Could not install VPN profile."
            vpnMessage = Self.vpnErrorMessage(prefix: "Could not install VPN profile", error: error)
            vpnMessageIsError = true
        }
        #endif
    }

    private func removeAdminQAVPNProfile() async {

        #if targetEnvironment(simulator)
        adminQAStatusMessage = "VPN profile testing requires a physical phone."
        vpnMessage = "Use a physical phone to remove the VPN profile."
        vpnMessageIsError = false
        #else
        adminQAStatusMessage = "Removing VPN profile..."
        vpnMessage = "Removing VPN profile..."
        vpnMessageIsError = false

        do {
            let managers = try await matchingTunnelManagers()
            guard !managers.isEmpty else {
                tunnelManager = nil
                updateProtectionStatus(from: nil)
                lastProtectionStatusRefresh = Date()
                adminQAStatusMessage = "No VPN profile to remove."
                vpnMessage = nil
                vpnMessageIsError = false
                return
            }

            for manager in managers {
                manager.connection.stopVPNTunnel()
                try await vpnLifecycleController.removeManager(manager)
            }

            tunnelManager = nil
            updateProtectionStatus(from: nil)
            lastProtectionStatusRefresh = Date()
            adminQAStatusMessage = "VPN profile removed."
            vpnMessage = nil
            vpnMessageIsError = false
        } catch {
            adminQAStatusMessage = "Could not remove VPN profile."
            vpnMessage = Self.vpnErrorMessage(prefix: "Could not remove VPN profile", error: error)
            vpnMessageIsError = true
        }
        #endif
    }

    private func resetAdminQAVPNProfile() async {

        #if targetEnvironment(simulator)
        adminQAStatusMessage = "VPN profile testing requires a physical phone."
        vpnMessage = "Use a physical phone to reset the VPN profile."
        vpnMessageIsError = false
        #else
        adminQAStatusMessage = "Resetting VPN profile..."
        vpnMessage = "Resetting VPN profile..."
        vpnMessageIsError = false

        do {
            let managers = try await matchingTunnelManagers()
            for manager in managers {
                manager.connection.stopVPNTunnel()
                try await vpnLifecycleController.removeManager(manager)
            }

            tunnelManager = nil
            updateProtectionStatus(from: nil)
            try await persistSharedState()

            let manager = try await loadOrCreateTunnelManager(existingManager: nil)
            tunnelManager = manager
            updateProtectionStatus(from: manager)
            lastProtectionStatusRefresh = Date()

            adminQAStatusMessage = "VPN profile reset."
            vpnMessage = nil
            vpnMessageIsError = false
        } catch {
            adminQAStatusMessage = "Could not reset VPN profile."
            vpnMessage = Self.vpnErrorMessage(prefix: "Could not reset VPN profile", error: error)
            vpnMessageIsError = true
        }
        #endif
    }

    #endif

    func clearDiagnostics() {
        clearAllLocalLogs()
    }

    func clearDomainHistory() {
        diagnostics.clearDomainHistory()

        do {
            try writeDiagnosticsClearControl(clearDomainHistory: true)
            try persistDiagnostics()
            diagnosticsReadGate.markRead(modifiedAt: modificationDate(for: diagnosticsURL))
            Task {
                await self.sendTunnelMessage(LavaSecAppGroup.clearDiagnosticsMessage)
            }
            ProtectionHapticFeedback.play(.actionSucceeded)
        } catch {
            vpnMessage = "Could not clear local history: \(error.localizedDescription)"
            vpnMessageIsError = true
            ProtectionHapticFeedback.play(.actionFailed)
        }
    }

    func clearLocalFilteringCounts() {
        diagnostics.clearFilteringCounts()

        do {
            try writeDiagnosticsClearControl(clearFilteringCounts: true)
            try persistDiagnostics()
            diagnosticsReadGate.markRead(modifiedAt: modificationDate(for: diagnosticsURL))
            Task {
                await self.sendTunnelMessage(LavaSecAppGroup.clearFilteringCountsMessage)
            }
            ProtectionHapticFeedback.play(.actionSucceeded)
        } catch {
            vpnMessage = "Could not clear local filtering counts: \(error.localizedDescription)"
            vpnMessageIsError = true
            ProtectionHapticFeedback.play(.actionFailed)
        }
    }

    func clearAllLocalLogs() {
        diagnostics.clearFilteringCounts()
        diagnostics.clearDomainHistory()
        clearNetworkActivityLog(notifyTunnel: false)
        clearLavaGuardProgress()

        do {
            try writeDiagnosticsClearControl(clearDomainHistory: true, clearFilteringCounts: true)
            try persistDiagnostics()
            diagnosticsReadGate.markRead(modifiedAt: modificationDate(for: diagnosticsURL))
            Task {
                await self.sendTunnelMessage(LavaSecAppGroup.clearDiagnosticsMessage)
                await self.sendTunnelMessage(LavaSecAppGroup.clearFilteringCountsMessage)
                await self.sendTunnelMessage(LavaSecAppGroup.clearNetworkActivityLogMessage)
            }
            ProtectionHapticFeedback.play(.actionSucceeded)
        } catch {
            vpnMessage = "Could not clear local logs: \(error.localizedDescription)"
            vpnMessageIsError = true
            ProtectionHapticFeedback.play(.actionFailed)
        }
    }

    func makeLocalLogExportArchive(generatedAt: Date = Date()) throws -> LocalLogExportArchive {
        refreshDiagnostics()
        refreshNetworkActivityLog(force: true)
        synchronizeLavaGuardProgress(currentStatus: vpnStatus)

        return try LocalLogExportArchive.make(
            diagnostics: diagnostics,
            networkActivityLog: networkActivityLog,
            lavaGuardProgress: lavaGuardProgress,
            lavaGuardUnlocks: configuration.lavaGuardUnlocks,
            deviceDebugLog: loadDeviceDebugLogEntriesForExport(),
            metadata: makeLocalLogExportMetadata(),
            generatedAt: generatedAt
        )
    }

    // Build/environment provenance for the export manifest, from the same
    // Info.plist / device values the bug-report bundle uses. `source_revision`
    // (Info.plist LavaSourceRevision) is the field that pins an export to an
    // exact commit — empty on local builds, the 12-char SHA on release builds.
    private func makeLocalLogExportMetadata() -> LocalLogExportMetadata {
        LocalLogExportMetadata(
            appVersion: Self.bundleInfoValue("CFBundleShortVersionString"),
            build: Self.bundleInfoValue("CFBundleVersion"),
            sourceRevision: Self.bundleInfoValue("LavaSourceRevision"),
            osVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            deviceFamily: Self.deviceFamilyDescription(UIDevice.current.userInterfaceIdiom),
            locale: Locale.current.identifier,
            catalogVersion: catalogVersion
        )
    }

    // The local export carries far more debug-log history than the Feedback
    // report (which caps at 40 to bound its upload payload): the export is a
    // local, user-controlled diagnostic file, so a deep trace is the point.
    // Same redaction (BugReportDebugLogEntry keeps only allowlisted detail keys).
    private func loadDeviceDebugLogEntriesForExport() -> [BugReportDebugLogEntry] {
        guard let url = LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.vpnDebugLogFilename),
              let data = try? Data(contentsOf: url)
        else {
            return []
        }

        return BugReportDebugLogEntry.parseJSONLines(data, limit: 5_000)
    }

    func refreshNetworkActivityLog(force: Bool = false) {
        guard configuration.keepNetworkActivity else {
            clearNetworkActivityLog(notifyTunnel: false)
            return
        }

        guard let networkActivityLogURL else {
            networkActivityLogReadGate.reset()
            return
        }

        guard let modifiedAt = modificationDate(for: networkActivityLogURL) else {
            networkActivityLogReadGate.reset()
            networkActivityLog = NetworkActivityLog()
            return
        }

        if networkActivityLogReadGate.shouldRead(modifiedAt: modifiedAt, force: force) {
            // File changed: prune on disk and reload, capturing the pruned log and
            // its post-prune mtime atomically under the lock, so a tunnel append
            // landing mid-refresh is not silently marked as already read.
            let pruned = NetworkActivityLogPersistence.loadPruned(at: networkActivityLogURL)
            networkActivityLog = pruned.log
            networkActivityLogReadGate.markRead(modifiedAt: pruned.modifiedAt)
        } else if networkActivityLog.pruneExpired() {
            // File unchanged, but the clock crossed the 7-day window while the app
            // sat idle with no new appends. Re-prune and reload atomically so the
            // trimmed file and the gate's mtime stay consistent.
            let pruned = NetworkActivityLogPersistence.loadPruned(at: networkActivityLogURL)
            networkActivityLog = pruned.log
            networkActivityLogReadGate.markRead(modifiedAt: pruned.modifiedAt)
        }
    }

    func clearNetworkActivityLog(notifyTunnel: Bool = true) {
        guard let networkActivityLogURL else {
            networkActivityLogReadGate.reset()
            networkActivityLog = NetworkActivityLog()
            return
        }

        NetworkActivityLogPersistence.clear(at: networkActivityLogURL)
        networkActivityLogReadGate.reset()
        networkActivityLog = NetworkActivityLog()
        if notifyTunnel {
            Task {
                await self.sendTunnelMessage(LavaSecAppGroup.clearNetworkActivityLogMessage)
            }
        }
    }

    func clearLavaGuardProgress() {
        lavaGuardProgress.clearUsageProgress()
        persistLavaGuardProgress()
    }

    func setKeepFilteringCounts(_ keepFilteringCounts: Bool, clearCounts: Bool = true) {
        configuration.keepFilteringCounts = keepFilteringCounts
        do {
            try persistConfigurationOnly()
            Task {
                await self.sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)
            }
        } catch {
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
        }

        if !keepFilteringCounts && clearCounts {
            clearLocalFilteringCounts()
        }
    }

    func setKeepDomainDiagnostics(_ keepDomainDiagnostics: Bool, clearHistory: Bool = true) {
        configuration.keepDomainDiagnostics = keepDomainDiagnostics
        do {
            try persistConfigurationOnly()
            Task {
                await self.sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)
            }
        } catch {
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
        }

        if !keepDomainDiagnostics && clearHistory {
            clearDomainHistory()
        }
    }

    func setKeepNetworkActivity(_ keepNetworkActivity: Bool, clearActivity: Bool = true) {
        configuration.keepNetworkActivity = keepNetworkActivity
        do {
            try persistConfigurationOnly()
            Task {
                await self.sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)
            }
        } catch {
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
        }

        if !keepNetworkActivity && clearActivity {
            clearNetworkActivityLog()
        }
    }

    func setKeepLavaGuardProgress(_ keepLavaGuardProgress: Bool, clearProgress: Bool = true) {
        configuration.keepLavaGuardProgress = keepLavaGuardProgress
        do {
            try persistConfigurationOnly()
        } catch {
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
        }

        if keepLavaGuardProgress {
            synchronizeLavaGuardProgress(currentStatus: vpnStatus)
        } else if clearProgress {
            clearLavaGuardProgress()
        }
    }

    func beginSignInWithApple() {
        Task {
            accountSignInProviderInProgress = .apple
            defer { accountSignInProviderInProgress = nil }
            accountAuthState = .signingIn(connections: accountAuthState.connections, provider: .apple)
            accountAuthMessage = "Opening Apple's sign-in sheet."
            accountAuthMessageIsError = false

            do {
                accountAuthState = try await accountAuthService.signInWithApple()
                accountSignInProviderInProgress = nil
                accountAuthMessage = "Signed in with Apple."
                accountAuthMessageIsError = false
                ProtectionHapticFeedback.play(.actionSucceeded)
                await uploadPendingEncryptedBackupIfPossible()
                await syncLavaSecurityPlusEntitlementIfPossible(lavaSecurityPlusStore.entitlement)
            } catch AccountAuthError.cancelled {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Sign in was cancelled."
                accountAuthMessageIsError = false
            } catch AccountAuthError.notConfigured {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Account login needs LavaSupabaseURL and LavaSupabaseAnonKey in the app configuration before backup upload can be enabled."
                accountAuthMessageIsError = true
                ProtectionHapticFeedback.play(.actionFailed)
            } catch {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Could not sign in: \(error.localizedDescription)"
                accountAuthMessageIsError = true
                ProtectionHapticFeedback.play(.actionFailed)
            }
        }
    }

    func beginSignInWithGoogle() {
        Task {
            accountSignInProviderInProgress = .google
            defer { accountSignInProviderInProgress = nil }
            accountAuthState = .signingIn(connections: accountAuthState.connections, provider: .google)
            accountAuthMessage = "Opening Google sign-in."
            accountAuthMessageIsError = false

            do {
                accountAuthState = try await accountAuthService.signInWithGoogle()
                accountSignInProviderInProgress = nil
                accountAuthMessage = "Signed in with Google."
                accountAuthMessageIsError = false
                ProtectionHapticFeedback.play(.actionSucceeded)
                await uploadPendingEncryptedBackupIfPossible()
                await syncLavaSecurityPlusEntitlementIfPossible(lavaSecurityPlusStore.entitlement)
            } catch AccountAuthError.cancelled {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Sign in was cancelled."
                accountAuthMessageIsError = false
            } catch AccountAuthError.notConfigured {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Account login needs LavaSupabaseURL and LavaSupabaseAnonKey in the app configuration before backup upload can be enabled."
                accountAuthMessageIsError = true
                ProtectionHapticFeedback.play(.actionFailed)
            } catch AccountAuthError.googleClientIDNotConfigured {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Google sign-in needs the Google iOS and Web client IDs in the app configuration."
                accountAuthMessageIsError = true
                ProtectionHapticFeedback.play(.actionFailed)
            } catch {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Could not sign in: \(error.localizedDescription)"
                accountAuthMessageIsError = true
                ProtectionHapticFeedback.play(.actionFailed)
            }
        }
    }

    func signOutAccount() {
        accountAuthService.signOut()
        accountAuthState = accountAuthService.state
        accountAuthMessage = "Signed out."
        accountAuthMessageIsError = false
        loadEncryptedBackupState()
    }

    func deleteAccount() async -> Bool {
        guard !isAccountDeletionInProgress else {
            return false
        }

        isAccountDeletionInProgress = true
        accountAuthMessage = "Deleting your Lava account."
        accountAuthMessageIsError = false
        defer { isAccountDeletionInProgress = false }

        do {
            try await accountAuthService.deleteAccount()
            try? backupKeychainStore.deleteRecoveryCode()
            try? backupKeychainStore.deleteDeviceSecret()
            try? backupKeychainStore.deletePasskeyCredentialID()
            accountAuthState = accountAuthService.state
            accountAuthMessage = "Deleted your Lava account."
            accountAuthMessageIsError = false
            loadEncryptedBackupState()
            ProtectionHapticFeedback.play(.actionSucceeded)
            return true
        } catch {
            accountAuthState = accountAuthService.state
            accountAuthMessage = "Could not delete account: \(error.localizedDescription)"
            accountAuthMessageIsError = true
            ProtectionHapticFeedback.play(.actionFailed)
            return false
        }
    }

    /// Step 1 of passkey setup: create the passkey (first authenticator ceremony) and confirm it
    /// supports PRF. The PRF output is captured separately in `validateBackupPasskey()` so the two
    /// biometric ceremonies are split across explicit UI steps rather than fired back-to-back.
    func registerBackupPasskey() async throws {
        guard let session = try await accountAuthService.refreshCurrentSession() else {
            accountAuthState = accountAuthService.state
            throw BackupPasskeyError.missingAccount
        }
        accountAuthState = accountAuthService.state

        // Zero-knowledge passkey backup requires the authenticator PRF extension (iOS 18+,
        // iCloud Keychain). The passkey is created locally — no server registration.
        guard #available(iOS 18.0, *) else {
            throw BackupPasskeyError.prfUnavailable
        }

        let registration = try await backupPasskeyCoordinator.registerPasskey(
            userID: session.userID,
            name: backupPasskeyAccountName,
            challenge: try BackupPasskeyCoordinator.makeChallengeString()
        )

        // Do NOT hard-gate on registration-time PRF support. ASAuthorization reports
        // `prf.isSupported` unreliably at credential *creation* for the platform authenticator —
        // iCloud Keychain frequently reports false even though PRF works at assertion — so gating
        // here regressed the iCloud Keychain happy path ("can't start passkey"). The validation
        // assertion is the reliable authority: `validateBackupPasskey()` throws `.prfUnavailable`
        // when a provider genuinely returns no PRF output (e.g. Bitwarden), surfacing a clear
        // "not supported" message on the validation step. (`registration.supportsPRF` remains
        // available as a non-blocking hint only.)

        pendingBackupPasskeyCredentialID = registration.credentialID
        pendingBackupPasskey = nil
        registeredBackupPasskey = RegisteredBackupPasskey(
            credentialID: registration.credentialID,
            prfSalt: try BackupPasskeyCoordinator.makePRFSalt()
        )
        try backupKeychainStore.savePasskeyCredentialID(registration.credentialID)
    }

    /// Step 2 of passkey setup: assert the registered passkey (second authenticator ceremony) to
    /// capture the PRF output that wraps the backup slot. This is the same operation a new-device
    /// restore performs, so it doubles as a validation that the passkey can unlock the backup.
    func validateBackupPasskey() async throws {
        guard #available(iOS 18.0, *) else {
            throw BackupPasskeyError.prfUnavailable
        }
        guard let registered = registeredBackupPasskey else {
            throw BackupPasskeyError.invalidCredentialID
        }

        let prfOutput = try await backupPasskeyCoordinator.assertPasskeyPRFOutput(
            credentialID: registered.credentialID,
            challenge: try BackupPasskeyCoordinator.makeChallengeString(),
            saltInput: registered.prfSalt
        )

        pendingBackupPasskey = PendingBackupPasskey(
            credentialID: registered.credentialID,
            prfSalt: registered.prfSalt,
            prfOutput: prfOutput
        )
    }

    func clearPendingBackupPasskey() {
        pendingBackupPasskeyCredentialID = nil
        pendingBackupPasskey = nil
        registeredBackupPasskey = nil
    }

    private var backupPasskeyAccountName: String {
        if let email = accountAuthState.connections.all.compactMap(\.email).first {
            return email
        }

        return BackupPasskeyConfiguration.displayName
    }

    func turnOnEncryptedBackup(recoveryPhrase: String) async throws {
        let payload = BackupConfigurationPayload(
            configuration: configuration,
            catalogVersionHint: catalogVersion,
            filterLibrary: library
        )
        let deviceSecret = try BackupDeviceSecret.generate()
        let serverRecoveryShare = try BackupAssistedRecoverySecret.makeServerShare()
        let normalizedRecoveryPhrase = BackupRecoveryPhrase.phrase(
            from: BackupRecoveryPhrase.words(from: recoveryPhrase)
        )

        // Zero-knowledge: when a PRF-capable passkey was prepared, wrap the backup slot with its
        // authenticator PRF output (HKDF) — no server-held secret. Otherwise create a passkey-free
        // envelope (keychain + assisted recovery only). Either way, nothing the server stores can
        // decrypt the backup.
        let envelope: ZeroKnowledgeBackupEnvelope
        if let passkey = pendingBackupPasskey {
            envelope = try ZeroKnowledgeBackupEnvelope.makeWithPRF(
                payload: payload,
                deviceSecret: deviceSecret,
                serverRecoveryShare: serverRecoveryShare,
                recoveryPhrase: normalizedRecoveryPhrase,
                passkeyPRFOutput: passkey.prfOutput,
                passkeyPRFSalt: passkey.prfSalt,
                passkeyCredentialID: passkey.credentialID
            )
            try? backupKeychainStore.savePasskeyCredentialID(passkey.credentialID)
        } else {
            envelope = try ZeroKnowledgeBackupEnvelope.makePasswordless(
                payload: payload,
                deviceSecret: deviceSecret,
                serverRecoveryShare: serverRecoveryShare,
                recoveryPhrase: normalizedRecoveryPhrase
            )
        }

        let estimatedByteSize = try ZeroKnowledgeBackupEnvelope.estimatedByteSize(
            for: payload,
            keySlotCount: envelope.keySlots.count
        )

        try backupKeychainStore.saveDeviceSecret(deviceSecret)
        try saveLocalEncryptedBackupEnvelope(envelope)
        clearPendingBackupPasskey()
        encryptedBackupState = .waitingForSignIn(estimatedByteSize: estimatedByteSize)

        if backupSyncService != nil {
            Task {
                await uploadEncryptedBackup(envelope, estimatedByteSize: estimatedByteSize)
            }
        }
    }

    func backUpNow() async {
        guard !isBackingUpNow, !isBackupMaintenanceInProgress else {
            return
        }

        guard let envelope = loadLocalEncryptedBackupEnvelope() else {
            encryptedBackupState = .off
            return
        }

        isBackingUpNow = true
        defer { isBackingUpNow = false }

        await uploadEncryptedBackup(
            envelope,
            estimatedByteSize: backupEnvelopeStore.estimatedByteSize(for: envelope)
        )
    }

    func restoreEncryptedBackup(secret: String, mode: BackupRestoreMode) async throws {
        // Claim the configuration-replacement token at entry: a filter switch suspended at its
        // async prepare is now superseded, so when it resumes its commit/rollback gate bails
        // instead of reverting this restore. Re-checked below after the unlock awaits (before any
        // disk write or app-state mutation) to cover the reverse ordering — a switch/import that
        // starts WHILE this restore awaits its envelope/passkey unlock.
        let replacementToken = configurationReplacementGate.begin()
        let envelope = try await loadAvailableEncryptedBackupEnvelope()

        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: BackupConfigurationPayload
        // A recovery-phrase / passkey restore lands on a device with NO device secret, so the
        // fetched envelope's keychain slot can't be re-sealed later (silently dropping every
        // post-restore edit). Re-key the keychain slot with a fresh device secret for THIS
        // device using the unlock material we just verified; persist it so re-seal works.
        let freshDeviceSecret = try BackupDeviceSecret.generate()
        var localEnvelope = envelope
        var didRekeyDeviceSlot = false
        switch mode {
        case .deviceKey:
            guard let deviceSecret = try backupKeychainStore.loadDeviceSecret() else {
                throw EncryptedBackupError.noSavedDeviceSecret
            }
            do {
                payload = try envelope.decryptWithKeychainSecret(deviceSecret)
            } catch {
                throw EncryptedBackupError.invalidDeviceUnlock
            }
            // Device secret already present + working — no re-key needed.
        case .recoveryCode:
            do {
                payload = try decryptWithNormalizedRecoveryPhrase(trimmedSecret, envelope: envelope)
            } catch {
                throw EncryptedBackupError.invalidRecoveryPhrase
            }
            // A recovery-phrase restore lands on a device with no working device secret, so the
            // re-key MUST succeed: without it there's no secret to re-seal with and every
            // post-restore edit silently stops backing up. Fail the restore (before any disk write
            // or app-state mutation) rather than half-restoring into that silent-drop state.
            guard let rekeyed = rekeyedEnvelopeWithNormalizedRecoveryPhrase(
                trimmedSecret, envelope: envelope, newDeviceSecret: freshDeviceSecret
            ) else {
                throw EncryptedBackupError.invalidRecoveryPhrase
            }
            localEnvelope = rekeyed
            didRekeyDeviceSlot = true
        case .passkey:
            let prfOutput = try await passkeyPRFOutputForRestore(envelope: envelope)
            do {
                payload = try envelope.decryptWithPasskeyPRFOutput(prfOutput)
            } catch {
                throw EncryptedBackupError.invalidPasskeyUnlock
            }
            // Same as recovery: a passkey restore must establish a working device secret on this
            // device, or post-restore edits silently stop backing up. Fail rather than half-restore.
            guard let rekeyed = try? envelope.rekeyingDeviceSlot(
                newDeviceSecret: freshDeviceSecret, unlockingPasskeyPRFOutput: prfOutput
            ) else {
                throw EncryptedBackupError.invalidPasskeyUnlock
            }
            localEnvelope = rekeyed
            didRekeyDeviceSlot = true
        }

        // A switch/import that started while we awaited the envelope/passkey unlock now owns the
        // configuration. Abort BEFORE writing the device secret or mutating app state, rather than
        // clobbering the newer owner (the reverse of the entry-token supersession above).
        guard configurationReplacementGate.isCurrent(replacementToken) else {
            throw EncryptedBackupError.supersededByConcurrentConfigurationChange
        }

        if didRekeyDeviceSlot {
            // A recovery-phrase / passkey restore re-keyed the envelope's .keychain slot with a
            // fresh device secret. Both the secret AND the re-keyed envelope must reach disk before
            // we mutate app state — otherwise the saved secret can't unwrap the on-disk envelope and
            // every post-restore edit silently stops backing up. Fail the restore if either write
            // fails so the user retries rather than landing in that silent-drop state.
            try backupKeychainStore.saveDeviceSecret(freshDeviceSecret)
            try saveLocalEncryptedBackupEnvelope(localEnvelope)
        } else {
            // deviceKey restore: the device secret already works, so just stage the (unchanged)
            // envelope locally — but BEFORE the persist below, not after. The persist's re-seal
            // (scheduleAutomaticBackupAfterConfigurationChange) reseals THIS local envelope to the
            // restored config/library and clears the stale upload marker; saving it AFTER the
            // persist (the prior ordering) clobbered that fresh re-seal with the pre-restore copy.
            // Best-effort: a failed local-copy write only defers the next re-seal, never corrupts.
            try? saveLocalEncryptedBackupEnvelope(localEnvelope)
        }

        configuration = payload.restoredConfiguration()
        // Restore the whole filter library (multi-filter), so every hosted filter — not
        // just the active one — survives a restore on a new device. A pre-multi-filter
        // backup carries no library, so migrate the restored config into one "Default"
        // filter. persistSharedState below writes both files; library-authoritative load
        // then regenerates the config mirror from this restored library.
        // Migrate known custom blocklists to catalog sources across EVERY hosted filter — the
        // same rewrite restoredConfiguration() applies to the active/top-level config — so a
        // backup restored onto a new device doesn't leave non-active filters pinned to raw
        // custom-URL lists that this device already ships as curated catalog sources.
        // Normalize BEFORE checking validity, exactly as the launch load path does: a backup
        // with filters but a stale activeFilterID is invalid only until normalized() repoints
        // the active id to the first filter. Checking isValid on the raw library would reject
        // it and fall through to migrating just the top-level config — discarding every other
        // hosted filter from the backup.
        if let restoredLibrary = payload.restoredFilterLibrary()?
            .migratingKnownCustomBlocklistsToCatalogSources()
            .normalized(), restoredLibrary.isValid {
            library = restoredLibrary
            // A backup may carry an OLDER-schema library (e.g. a pre-three-defaults v1 library).
            // Restoring it is a DELIBERATE recovery of the user's own data — distinct from the
            // on-upgrade reset — so stamp it to the current schema; otherwise the launch migration
            // guard (schemaVersion >= currentSchemaVersion) would reject and reseed it on the next
            // relaunch, and the restored filters would survive only until restart.
            library.schemaVersion = FilterLibrary.currentSchemaVersion
            // Library-authoritative: the restored library's active filter — not the legacy
            // top-level config fields — is the source of truth, so regenerate config's four
            // filter-scoped fields from it before persisting. This recovers the active id
            // and its contents together (the device-global config fields are untouched).
            mirrorActiveFilterIntoConfiguration()
        } else {
            library = FilterLibrary(migratingLegacy: configuration)
        }
        // Restore replaces the whole library, so every per-filter draft + the detail target are
        // stale — wipe them so a preserved edit can't overwrite the just-restored state.
        filterEditDrafts.removeAll()
        filterEditTargetID = nil
        // Config-first persist: the restored configuration carries device-global fields the
        // library can't reconstruct, so a partial write must lose the re-restorable library, not
        // the config (see persistSharedState).
        // Config-first persist (prioritizesConfigurationDurability). Its re-seal step now operates
        // on the local envelope staged above (both restore modes), so the saved envelope reflects
        // the restored state and the upload marker is correctly cleared — no post-persist save can
        // clobber it.
        try await persistSharedState(prioritizesConfigurationDurability: true)
        // An envelope + working device secret are now on disk, so backup IS configured on this
        // device. Refresh the cached state from the store (it was .off on a fresh device and the
        // restore never updates it otherwise), so Settings reflects "on" AND post-restore edits
        // pass the auto-backup gate instead of the stale .off short-circuiting the re-seal/upload.
        loadEncryptedBackupState()

        Task {
            await self.notifyTunnelSnapshotUpdated()
        }

        if let backupSyncService {
            if let session = try await accountAuthService.currentBackupSession() {
                try? await backupSyncService.markRestored(session: session)
            }
        }
    }

    /// Permanently deletes the uploaded backup copy stored for this account while
    /// keeping encrypted backup configured on this device. Only when the server copy
    /// is confirmed gone do we forget the upload marker (state returns to "not
    /// uploaded yet" and the next backup re-uploads a fresh copy). If the delete
    /// can't be confirmed, nothing local changes and the failure is surfaced — we
    /// never claim a backup was cleared when it may still exist on the server.
    func clearEncryptedBackup() async {
        guard !isBackupMaintenanceInProgress, !isBackingUpNow, !isUploadingEncryptedBackup else {
            return
        }
        isBackupMaintenanceInProgress = true
        defer { isBackupMaintenanceInProgress = false }

        switch await deleteRemoteEncryptedBackup() {
        case .deleted:
            backupEnvelopeStore.clearUploadMarker()
            loadEncryptedBackupState()
        case .unconfirmed:
            encryptedBackupState = .failed(
                message: "Couldn't delete the backup stored for your account — you may be offline or signed out. The backup was left in place; try again when you're back online."
            )
        }
    }

    /// Turns encrypted backup off on this device: permanently deletes the uploaded
    /// copy, then tears down every local unlock (device secret, passkey credential,
    /// recovery code) plus the local envelope, and stops automatic backup. The local
    /// teardown only runs once the server copy is confirmed gone, so a failed delete
    /// leaves backup intact rather than silently orphaning the server copy.
    func disableEncryptedBackup() async {
        guard !isBackupMaintenanceInProgress, !isBackingUpNow, !isUploadingEncryptedBackup else {
            return
        }
        isBackupMaintenanceInProgress = true
        defer { isBackupMaintenanceInProgress = false }

        switch await deleteRemoteEncryptedBackup() {
        case .deleted:
            try? backupKeychainStore.deleteRecoveryCode()
            try? backupKeychainStore.deleteDeviceSecret()
            try? backupKeychainStore.deletePasskeyCredentialID()
            backupEnvelopeStore.deleteEnvelope()
            setAutomaticBackupEnabled(false)
            loadEncryptedBackupState()
        case .unconfirmed:
            encryptedBackupState = .failed(
                message: "Couldn't delete the backup stored for your account — you may be offline or signed out. Backup is still on; try again when you're back online."
            )
        }
    }

    private enum RemoteBackupDeletionOutcome {
        case deleted        // confirmed gone from the server, or no server copy exists
        case unconfirmed    // couldn't reach/authorize the server — a copy may remain
    }

    // Hard-deletes the server copy and reports whether it is confirmed gone, so
    // callers never claim deletion they couldn't verify. `.deleted` when the row is
    // removed (or there is no sync service, so no server copy exists); `.unconfirmed`
    // when signed out or the request fails. Mirrors uploadEncryptedBackup's single
    // 401 refresh-retry.
    private func deleteRemoteEncryptedBackup() async -> RemoteBackupDeletionOutcome {
        guard let backupSyncService else {
            return .deleted
        }

        do {
            guard let session = try await accountAuthService.currentBackupSession() else {
                accountAuthState = accountAuthService.state
                return .unconfirmed
            }
            accountAuthState = accountAuthService.state
            try await backupSyncService.deleteRemote(session: session)
            return .deleted
        } catch BackupSyncServiceError.requestFailed(let statusCode) where statusCode == 401 {
            guard let refreshedSession = try? await accountAuthService.refreshCurrentSession() else {
                accountAuthState = accountAuthService.state
                return .unconfirmed
            }
            accountAuthState = accountAuthService.state
            do {
                try await backupSyncService.deleteRemote(session: refreshedSession)
                return .deleted
            } catch {
                return .unconfirmed
            }
        } catch {
            accountAuthState = accountAuthService.state
            return .unconfirmed
        }
    }

    /// Re-key the envelope's device slot with a fresh device secret, recovering the payload
    /// key via the recovery phrase (trying the same normalized candidates as decrypt, and
    /// both the assisted-recovery and password-style recovery slots). Returns the re-keyed
    /// envelope, or `nil` if no candidate worked.
    private func rekeyedEnvelopeWithNormalizedRecoveryPhrase(
        _ secret: String,
        envelope: ZeroKnowledgeBackupEnvelope,
        newDeviceSecret: String
    ) -> ZeroKnowledgeBackupEnvelope? {
        let normalizedPhrase = BackupRecoveryPhrase.phrase(
            from: BackupRecoveryPhrase.words(from: secret)
        )
        let candidates = [
            normalizedPhrase,
            secret.trimmingCharacters(in: .whitespacesAndNewlines),
            secret.uppercased()
        ].filter { !$0.isEmpty }

        for candidate in candidates {
            if let rekeyed = try? envelope.rekeyingDeviceSlot(
                newDeviceSecret: newDeviceSecret, unlockingAssistedRecoveryPhrase: candidate
            ) {
                return rekeyed
            }
            if let rekeyed = try? envelope.rekeyingDeviceSlot(
                newDeviceSecret: newDeviceSecret, unlockingRecoveryPhrase: candidate
            ) {
                return rekeyed
            }
        }
        return nil
    }

    private func decryptWithNormalizedRecoveryPhrase(
        _ secret: String,
        envelope: ZeroKnowledgeBackupEnvelope
    ) throws -> BackupConfigurationPayload {
        let normalizedPhrase = BackupRecoveryPhrase.phrase(
            from: BackupRecoveryPhrase.words(from: secret)
        )
        let candidates = [
            normalizedPhrase,
            secret.trimmingCharacters(in: .whitespacesAndNewlines),
            secret.uppercased()
        ].filter { !$0.isEmpty }

        var lastError: Error = ZeroKnowledgeBackupEnvelopeError.missingKeySlot
        for candidate in candidates {
            do {
                return try envelope.decryptWithAssistedRecoveryPhrase(candidate)
            } catch {
                lastError = error
            }

            do {
                return try envelope.decryptWithRecoveryPhrase(candidate)
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    /// Derive the passkey slot's unwrapping material locally: assert the passkey with the slot's
    /// stored PRF salt and return the authenticator PRF output. No server release of any secret —
    /// the server never held one. Sign-in already gated the ciphertext download upstream.
    private func passkeyPRFOutputForRestore(
        envelope: ZeroKnowledgeBackupEnvelope
    ) async throws -> Data {
        guard let passkeySlot = envelope.keySlots.first(where: { $0.kind == .passkey }),
              let credentialID = passkeySlot.credentialID,
              !credentialID.isEmpty,
              let saltInput = Data(base64Encoded: passkeySlot.salt)
        else {
            throw EncryptedBackupError.noPasskeyRecovery
        }

        guard #available(iOS 18.0, *) else {
            throw EncryptedBackupError.invalidPasskeyUnlock
        }

        return try await backupPasskeyCoordinator.assertPasskeyPRFOutput(
            credentialID: credentialID,
            challenge: try BackupPasskeyCoordinator.makeChallengeString(),
            saltInput: saltInput
        )
    }

    func refreshDiagnostics() {
        guard let diagnosticsURL else {
            diagnosticsReadGate.reset()
            return
        }

        let shouldForceHistoryClear = !configuration.keepDomainDiagnostics && !diagnostics.recentEvents.isEmpty
        let shouldForceCountsClear = !configuration.keepFilteringCounts && diagnostics.hasFilteringCountData
        let shouldForceLocalLogClear = shouldForceHistoryClear || shouldForceCountsClear
        guard let modifiedAt = modificationDate(for: diagnosticsURL) else {
            diagnosticsReadGate.reset()
            if shouldForceHistoryClear {
                clearDomainHistory()
            }
            if shouldForceCountsClear {
                clearLocalFilteringCounts()
            }
            return
        }

        guard diagnosticsReadGate.shouldRead(modifiedAt: modifiedAt, force: shouldForceLocalLogClear) else {
            // File unchanged, but the clock may have crossed the 7-day window while
            // the app sat idle with no new DNS writes. Expire the in-memory store by
            // time — independent of the file-change gate — so Top Domains and exports
            // never show stale detail, and write the trim back to disk.
            if diagnostics.pruneExpiredFineGrainedData() {
                try? persistDiagnostics()
                diagnosticsReadGate.markRead(modifiedAt: modificationDate(for: diagnosticsURL))
            }
            return
        }

        var store = DiagnosticsPersistence.load(from: diagnosticsURL)
        store.pruneExpiredFineGrainedData()
        diagnosticsReadGate.markRead(modifiedAt: modifiedAt)
        // Persist when any fine-grained prune removed events — including one
        // `load` already performed in its day-rollover reset — so aged-out domain
        // history does not linger in the file past the 7-day window.
        var shouldPersistClearedLogs = store.consumePendingFineGrainedPrunePersist()

        if !configuration.keepFilteringCounts, store.hasFilteringCountData {
            store.clearFilteringCounts()
            shouldPersistClearedLogs = true
        }

        if !configuration.keepDomainDiagnostics {
            shouldPersistClearedLogs = shouldPersistClearedLogs
                || !store.recentEvents.isEmpty
                || !diagnostics.recentEvents.isEmpty
            store.clearDomainHistory()
        }

        diagnostics = store
        refreshLavaGuardProgressFromDiagnostics()
        if shouldPersistClearedLogs {
            try? persistDiagnostics()
            diagnosticsReadGate.markRead(modifiedAt: modificationDate(for: diagnosticsURL))
        }
    }

    func refreshReports() {
        refreshDiagnostics()
        refreshTunnelHealth()
        refreshNetworkActivityLog()
    }

    func sampleReports() async {
        refreshDiagnostics()
        await sampleTunnelHealth()
        refreshNetworkActivityLog(force: true)
    }

    func prepareBugReport(context: BugReportContext) {
        refreshReports()
        let inputs = PreparedBugReportInputs(
            snapshot: currentSnapshot(),
            debugLogEntries: loadBugReportDebugLogEntries(),
            selfReconnectTimes: loadSelfReconnectAttemptTimes()
        )
        preparedBugReportInputs = inputs
        bugReportDraft = makeBugReportBundle(context: context, inputs: inputs)
        bugReportSendState = .idle
    }

    /// Cheap per-keystroke draft refresh: re-wrap the user-entered `context`
    /// around the environment snapshot captured by the last `prepareBugReport`,
    /// instead of re-reading the diagnostics/health/debug-log files and
    /// rebuilding the full blocklist union on every keystroke (UR-5: Feedback
    /// typing lag). Only the affected-site decision is recomputed, and that is a
    /// lookup against the already-built snapshot. Falls back to a full prepare
    /// when no snapshot has been captured yet.
    func refreshBugReportDraftContext(context: BugReportContext) {
        guard let inputs = preparedBugReportInputs else {
            prepareBugReport(context: context)
            return
        }

        bugReportDraft = makeBugReportBundle(context: context, inputs: inputs)
        bugReportSendState = .idle
    }

    func sendBugReport(context: BugReportContext) async {
        let bundle = BugReportSubmissionBundlePolicy.bundleToSubmit(
            draft: bugReportDraft,
            currentContext: context
        ) { [self] in
            makeBugReportBundle(context: context)
        }
        bugReportDraft = bundle
        bugReportSendState = .sending

        do {
            let reportID = try await submitBugReport(bundle)
            bugReportSendState = .sent(reportID: reportID)
        } catch {
            bugReportSendState = .failed(message: error.localizedDescription)
        }
    }

    func resetBugReportSendState() {
        bugReportSendState = .idle
    }

    func refreshFilterNumberSummaries() async {
        loadPersistedConfiguration()
        refreshCompiledBlocklistRuleCount()

        if let summary = await loadPreparedFilterSummaryForCurrentConfiguration() {
            compiledRuleCount = summary.blockRuleCount
            protectedRuleCount = summary.blockedDomainRuleCount
            if let blocklistRuleCount = summary.blocklistRuleCount {
                compiledBlocklistRuleCount = blocklistRuleCount
            } else if compiledBlocklistRuleCount == 0 {
                compiledBlocklistRuleCount = estimatedBlocklistRuleCount(fromTotalRuleCount: summary.blockRuleCount)
            }
            return
        }

        let snapshot = currentSnapshot()
        let summary = PreparedFilterSnapshotSummary(snapshot: snapshot)
        compiledRuleCount = summary.blockRuleCount
        protectedRuleCount = summary.blockedDomainRuleCount
        if compiledBlocklistRuleCount == 0 {
            compiledBlocklistRuleCount = estimatedBlocklistRuleCount(fromTotalRuleCount: snapshot.blockRules.count)
        }
    }

    func refreshTunnelHealth(force: Bool = false) {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            tunnelHealthReadGate.reset()
            return
        }

        let url = containerURL.appendingPathComponent(LavaSecAppGroup.tunnelHealthFilename)
        guard let modifiedAt = modificationDate(for: url) else {
            tunnelHealthReadGate.reset()
            return
        }

        guard tunnelHealthReadGate.shouldRead(modifiedAt: modifiedAt, force: force) else {
            return
        }

        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(TunnelHealthSnapshot.self, from: data)
        else {
            return
        }

        let previousHealth = tunnelHealth
        tunnelHealthReadGate.markRead(modifiedAt: modifiedAt)
        tunnelHealth = snapshot
        scheduleProtectionNotificationIfNeeded()

        // The Live Activity / Dynamic Island transient states (reconnecting,
        // networkUnavailable, needsReconnect) are derived from tunnel health, not
        // from NEVPNStatus — which stays `.connected` straight through a
        // reconnect. Reconcile whenever the health content actually changes so
        // the Dynamic Island reflects those states promptly instead of waiting
        // for the next status transition (UR-6: Dynamic Island lag during
        // retry/reconnect). `reconcile` dedupes by published content, so this is
        // a no-op when the derived DI state is unchanged.
        if snapshot != previousHealth {
            reconcileLiveActivity()
        }
    }

    // The tunnel already persists health on its own 30s cadence; the UI poll only
    // needs to force a flush at most that often instead of per 5s tick.
    private var lastTunnelHealthFlushRequestedAt = Date.distantPast
    private static let tunnelHealthFlushMinimumInterval: TimeInterval = 30

    func sampleTunnelHealth() async {
        let now = Date()
        guard now.timeIntervalSince(lastTunnelHealthFlushRequestedAt) >= Self.tunnelHealthFlushMinimumInterval else {
            refreshTunnelHealth()
            return
        }

        lastTunnelHealthFlushRequestedAt = now
        await requestTunnelHealthFlush()
        refreshTunnelHealth(force: true)
    }

    func syncCatalog(isBackgroundRefresh: Bool = false) async {
        if let catalogSyncTask {
            await catalogSyncTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.performCatalogSync(isBackgroundRefresh: isBackgroundRefresh)
        }
        catalogSyncTask = task
        // Forward cancellation from the awaiting context (e.g. an expired background
        // refresh's BGTask) into the unstructured sync task, which in turn forwards it
        // to the detached network/compile work in `performCatalogSync`.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func waitForCatalogSyncToFinish() async {
        guard let catalogSyncTask else {
            return
        }

        await catalogSyncTask.value
    }

    private func finishCatalogSyncTask() {
        isSyncingCatalog = false
        catalogSyncTask = nil
    }

    private func performCatalogSync(operationID: LatencyOperationID = .make(), isBackgroundRefresh: Bool = false) async {
        let trace = makeLatencyTrace(operationID: operationID, operationKind: "refreshLists")
        let span = trace.beginSpan("action.refreshLists", details: [
            "catalogVersion": catalogVersion ?? "nil",
            "compiledRuleCount": "\(compiledRuleCount)"
        ])
        var actionStatus = "started"
        defer {
            span.end(details: ["status": actionStatus, "catalogVersion": catalogVersion ?? "nil"])
        }

        guard let cacheURL = catalogCacheURL else {
            actionStatus = "app-group-unavailable"
            catalogStatusMessage = LavaSecAppError.appGroupUnavailable.localizedDescription
            catalogStatusIsError = true
            finishCatalogSyncTask()
            return
        }

        // Captured BEFORE the sync for the background rollback guard: the published pointer
        // this refresh builds forward from. If a concurrent foreground publish moves it
        // before our flip, the background aborts rather than rolling the catalog back to its
        // own older sync (see publishBackgroundRefreshArtifacts). Foreground path: unused.
        let basePublishedPointerToken = isBackgroundRefresh ? currentPublishedArtifactPointerToken() : nil
        // Captured BEFORE the sync for the background catalog-cache commit. The background sync
        // DEFERS its latest.json write (commitsLatestCatalog: false) so it can land atomically
        // with the pointer flip; this baseline lets the commit veto itself if a concurrent
        // foreground sync advanced the shared catalog meanwhile (so the background never clobbers
        // the foreground's catalog). Foreground path: unused.
        let baseLatestCatalogData: Data? = isBackgroundRefresh
            ? try? Data(contentsOf: BlocklistCatalogRepository.latestCatalogURL(in: cacheURL))
            : nil

        let shouldRestoreProtection = configuration.protectionEnabled || isProtectionEnabledStatus(vpnStatus)
        isSyncingCatalog = true
        catalogStatusMessage = "Fetching from the server..."
        catalogStatusIsError = false
        var shouldAttemptProtectionRestore = false

        do {
            let enabledIDs = configuration.enabledBlocklistIDs
            let customSources = enabledCustomBlocklists(in: configuration)
            // Free-tier (e.g. lapsed Plus) keeps its existing custom lists but their
            // contents are frozen: serve the cached payload and never refresh from
            // the network here. The curated catalog still syncs as usual.
            //
            // A background refresh is ALSO strictly cache-only for custom lists: a
            // network re-fetch would rotate custom-list hashes, diverging the artifact
            // identity from the configuration.json this path never rewrites.
            let refreshesCustomBlocklists = configuration.limits.allowsCustomBlocklists && !isBackgroundRefresh
            let syncTask = Task.detached(priority: .utility) {
                let synchronizer = BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL)
                // Background defers the latest.json commit to publish time (atomic with the
                // pointer flip); foreground commits inline as before.
                let catalogResult = try await synchronizer.sync(
                    enabledSourceIDs: enabledIDs,
                    commitsLatestCatalog: !isBackgroundRefresh
                )
                // Free tier is strictly cache-only: never network-fetch custom lists
                // here. We deliberately don't fall back to a network sync on a cache
                // miss — doing so would re-fetch (and overwrite) every enabled list,
                // not just the missing one, unfreezing the others. If a payload is
                // genuinely absent this throws and the outer handler keeps the last
                // good snapshot instead.
                let customResult = refreshesCustomBlocklists
                    ? try await synchronizer.syncCustomBlocklists(customSources)
                    : try await synchronizer.loadCachedCustomBlocklists(customSources)
                return (catalogResult, customResult)
            }
            // Detached work doesn't inherit cancellation; forward it so an expired
            // background refresh stops the network/compile work promptly instead of
            // running past the system deadline.
            let result = try await withTaskCancellationHandler {
                try await syncTask.value
            } onCancel: {
                syncTask.cancel()
            }

            guard !Task.isCancelled else {
                actionStatus = "cancelled"
                finishCatalogSyncTask()
                return
            }

            applySyncResults(catalogResult: result.0, customResult: result.1)

            if isBackgroundRefresh {
                // The system may have expired the BGTask while the detached sync ran (the
                // expiration handler calls work.cancel() + setTaskCompleted(false)). Do not
                // stage/flip artifacts or notify the tunnel past the deadline — bail like
                // the cancellation guard above. (A later expiration, mid-publish, is caught
                // before the pointer flip by the in-lock supersession closure below.)
                guard !Task.isCancelled else {
                    actionStatus = "cancelled"
                    finishCatalogSyncTask()
                    return
                }
                // Hybrid background publish: artifacts-only, never configuration.json,
                // never protection restore. Returns before the foreground persist tail.
                actionStatus = await publishBackgroundRefreshArtifacts(operationID: operationID, basePublishedPointerToken: basePublishedPointerToken, baseLatestCatalogData: baseLatestCatalogData)
                // Phase 2: with the active filter republished + latest.json committed, warm the
                // NON-active filters too (capped, most-stale-first) into the sidecar warm-index.
                // Headless-safe — it records into the sidecar, never filter-library.json, and self-guards
                // on the BGTask deadline + per-run budget. Run it ONLY on "bg-published": that is the one
                // outcome where the background COMMITTED the freshly-synced catalog to latest.json (so it
                // holds the current catalog AND its mtime is fresh). "bg-unchanged" does NOT qualify — it
                // only means the ACTIVE filter's artifact didn't need republishing; latest.json was not
                // committed and the sync may have fallen back to cache or fetched non-active-only changes,
                // so warming would compile against a non-committed catalog and the freshness gate would
                // be unreliable (Codex #138 r6 P1). Aborted outcomes never committed either. Also skip if
                // the BGTask deadline already passed (Codex r2).
                if !Task.isCancelled, actionStatus == "bg-published" {
                    await warmNonActiveFiltersInBackground()
                }
                finishCatalogSyncTask()
                return
            }

            // Smart refresh: only pay the snapshot re-encode + tunnel reload (and the
            // reconnect it triggers) when a list actually changed upstream. A refresh
            // that finds nothing new stops here — cheap, and no spurious reconnect.
            let snapshotChanged = didSnapshotIdentityChangeAfterSync()
            if snapshotChanged {
                try await persistSharedState()
                await notifyTunnelSnapshotUpdated(operationID: operationID)
            }

            catalogStatusMessage = "Refreshed"
            catalogStatusIsError = false

            // Keep the expensive snapshot reload + reconnect gated on an actual
            // upstream change, but always attempt the protection restore: a successful
            // refresh that finds nothing new must still bring a downed tunnel back
            // online (e.g. on launch after iOS dropped the VPN).
            shouldAttemptProtectionRestore = true
            actionStatus = snapshotChanged ? "refreshed" : "unchanged"
        } catch {
            if Task.isCancelled {
                // Cancelled refresh (e.g. an expired background BGTask): bail without
                // restoring from cache or touching protection.
                actionStatus = "cancelled"
                finishCatalogSyncTask()
                return
            }

            // A background refresh must NEVER write shared state, on ANY path. The
            // foreground failure recovery below restores from cache via
            // loadCachedCatalogAfterSyncFailure (which calls persistSharedState) and then
            // the tail arms restoreProtectionIfNeeded — both rewrite configuration.json /
            // protection from this headless model's launch-time config, reopening the
            // config-clobber race this mode exists to avoid. So a failed background refresh
            // bails like the cancellation case: leave the last-good artifacts and config
            // untouched and let the next foreground sync recover.
            if isBackgroundRefresh {
                actionStatus = "bg-sync-failed"
                finishCatalogSyncTask()
                return
            }

            let restoredFromCache = await loadCachedCatalogAfterSyncFailure(
                cacheURL: cacheURL,
                originalError: error,
                operationID: operationID
            )

            shouldAttemptProtectionRestore = restoredFromCache
            actionStatus = restoredFromCache ? "cache-restored" : "error"
        }

        finishCatalogSyncTask()
        if shouldAttemptProtectionRestore {
            await restoreProtectionIfNeeded(wasEnabled: shouldRestoreProtection)
        }
    }

    /// Thrown by the background publish's `commitBeforeFlip` to veto the flip when a concurrent
    /// foreground sync advanced the shared catalog (`latest.json`) since this run's baseline —
    /// declining to clobber it. Aborts the publish without changing catalog or pointer.
    private struct BackgroundCatalogCacheSupersededError: Error {}

    /// Background catalog-refresh publish tail (the BGTask path). Re-reads the LIVE
    /// on-disk configuration, builds the snapshot from it, and publishes ARTIFACTS ONLY
    /// under a degrade-ABORT publish lock with an in-lock generation supersession check —
    /// so a concurrent foreground save always wins and a stale background publish can
    /// never clobber it. NEVER rewrites configuration.json and NEVER restores protection
    /// (both would write shared state from this headless model). Returns a status string
    /// for the action span and swallows its own errors (a failed publish just leaves the
    /// last-good artifacts in place).
    private func publishBackgroundRefreshArtifacts(operationID: LatencyOperationID, basePublishedPointerToken: String?, baseLatestCatalogData: Data?) async -> String {
        // Custom lists are cache-only in the background, so cachedBlockRuleSets holds bytes
        // loaded under THIS config's custom fingerprints (applySyncResults just set the
        // hashes to match what was loaded). Capture them BEFORE reloading the live config.
        let baselineCustomIdentities = enabledCustomBlocklistIdentities(in: configuration)

        // Re-read whatever the foreground last persisted and build against THAT, not the
        // config this headless model launched with.
        loadPersistedConfiguration()

        // Abort if the reload had to reseed the filter library (the on-disk library is
        // pre-upgrade/old-schema, or lost a write race): the foreground migration has not
        // landed yet, so the reseed mirrored Balanced into `configuration` in memory WITHOUT
        // persisting it. Building here would publish Balanced artifacts while
        // app-configuration.json — and its generation — still describe the pre-upgrade filter,
        // a silent flip the generation guard cannot catch (no config was written). Publish
        // nothing until the user's next foreground launch commits the migration.
        guard !didReseedFilterLibraryOnLastLoad else {
            return "bg-premigration"
        }

        // Abort if a foreground/manual custom-list refresh changed any enabled custom
        // source's fingerprint while we synced: cachedBlockRuleSets still holds the OLD
        // bytes, but the snapshot identity is computed from this reloaded config (NEW
        // fingerprint) — publishing would stamp the new identity onto stale bytes, and the
        // tunnel would accept them until a later publish. The generation token does NOT catch
        // this when the foreground write landed before our reload (both ends then read the
        // same new generation); the coverage guard only checks presence, not fingerprint.
        // Fail-closed: a changed/added/removed entry counts as a mismatch.
        guard enabledCustomBlocklistIdentities(in: configuration) == baselineCustomIdentities else {
            return "bg-custom-changed"
        }
        let builtGeneration = configuration.configurationGeneration

        // Build the prepared snapshot OFF the main actor. The merge + filterSnapshot are
        // O(rules); for very large rule sets they would otherwise block the main actor long
        // enough that the BGTask expiration handler (queued on .main) could not preempt before
        // the system deadline. Capture the Sendable inputs here, then build on a detached task
        // (the encode/stage/flip is already off-main on the service actor).
        //
        // The builder merges for the RELOADED enabled set: currentSnapshot uses the merged
        // rules verbatim (configuration.filterSnapshot only unions manual rules, never
        // re-filters by enabled IDs) and applySyncResults built from the launch-time set, so
        // without re-merging a foreground DISABLE in the launch→reload window would over-block
        // the disabled list — over-coverage the subset-only guard can't catch. A source the
        // live config enables but this headless sync didn't fetch is omitted, so the summary
        // reports it uncovered and the coverage guard below aborts (fail-closed). Merging once
        // here also drops the redundant second merge the foreground summary path does.
        let configurationForBuild = configuration
        let ruleSetsForBuild = cachedBlockRuleSets
        let guardrailForBuild = threatGuardrail
        let catalogForBuild = currentCatalog
        let compiledRuleCountForBuild = compiledBlocklistRuleCount
        let prepared = await Task.detached(priority: .utility) {
            Self.buildBackgroundPreparedSnapshot(
                configuration: configurationForBuild,
                cachedBlockRuleSets: ruleSetsForBuild,
                threatGuardrail: guardrailForBuild,
                catalog: catalogForBuild,
                compiledBlocklistRuleCount: compiledRuleCountForBuild
            )
        }.value

        // The off-main build freed the main actor, so an expiration that fired during it has
        // already run work.cancel(); bail before the coverage/persist work (the in-lock check
        // remains the final backstop before the flip).
        guard !Task.isCancelled else {
            return "bg-cancelled"
        }

        // Fail-closed coverage backstop: never point the tunnel at a snapshot that does
        // not cover the live enabled set (e.g. a foreground enable landed for a source
        // this headless sync didn't fetch).
        guard prepared.summary.coversEnabledBlocklists(in: configuration) else {
            return "bg-uncovered"
        }

        // Smart refresh (mirror the foreground gate at performCatalogSync): if nothing
        // changed upstream, skip the publish entirely — no new versioned dir, no pointer
        // flip, no tunnel reload. The versioned token embeds generatedAt, so WITHOUT this an
        // unchanged daily run would churn a redundant dir and trigger a needless reconnect.
        guard didSnapshotIdentityChangeAfterSync() else {
            return "bg-unchanged"
        }

        // Catalog-cache commit, ATOMIC with the pointer flip. The background sync deferred its
        // latest.json write (commitsLatestCatalog: false); commit it here, under the publish
        // lock, only on success — the tunnel derives its expected identity from latest.json, so
        // committing it ahead of this abortable publish would leave the cached catalog ahead of
        // the pointer (→ the tunnel rejects the last-good artifact → in-extension recompile /
        // fail-closed on large lists). On any abort, latest.json stays consistent with the
        // pointer. If we can't reproduce the resolved catalog bytes, do not publish (a flip
        // without the matching latest.json would itself be inconsistent).
        guard let catalogCacheURL,
              let catalogForCommit = currentCatalog,
              let latestCatalogData = try? BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalogForCommit)
        else {
            return "bg-error"
        }
        let latestCatalogURL = BlocklistCatalogRepository.latestCatalogURL(in: catalogCacheURL)

        let configurationURL = self.configurationURL
        do {
            let outcome = try await persistPreparedSnapshotArtifacts(
                prepared,
                lockMode: .tryOrAbort,
                supersededWhileLocked: { @Sendable currentPointerToken in
                    // Inside the held publish lock, evaluated immediately BEFORE the pointer
                    // flip. ABORT the flip if the BGTask expired since we entered the publish
                    // (do no publish work past the system deadline)...
                    if Task.isCancelled { return true }
                    // ...or if a concurrent publish moved the live pointer since this task
                    // captured its basis. The background builds its catalog from its OWN sync,
                    // not from freshly-published artifacts, so without this it could flip the
                    // pointer back to an older catalog a foreground refresh already superseded
                    // (a rollback). The generation token misses this: the background rebuilt
                    // config from the reloaded file, so generations match. Fail-closed.
                    if currentPointerToken != basePublishedPointerToken { return true }
                    // ...or if a foreground write superseded our basis: re-read the on-disk
                    // generation and abort. If the file can't be read, treat as superseded
                    // (degrade-ABORT).
                    guard let configurationURL,
                          let data = try? Data(contentsOf: configurationURL),
                          let onDisk = try? JSONDecoder().decode(AppConfiguration.self, from: data)
                    else {
                        return true
                    }
                    return onDisk.configurationGeneration != builtGeneration
                },
                commitBeforeFlip: { @Sendable in
                    // Runs under the publish lock, after the supersession check, immediately
                    // BEFORE the pointer flip. latest.json CAS: only commit if a concurrent
                    // foreground sync hasn't advanced the shared catalog since this background
                    // run captured its baseline. The foreground commits latest.json OUTSIDE the
                    // publish lock, so this is best-effort — the residual read→write TOCTOU is
                    // sub-millisecond and the tunnel recompiles on a brief mismatch — but it
                    // closes the wide window where the background would clobber a foreground
                    // catalog. Vetoing (throw) aborts the publish before any state change: the
                    // shared catalog and the pointer both stay at the foreground's newer state.
                    let onDiskLatestCatalog = try? Data(contentsOf: latestCatalogURL)
                    guard onDiskLatestCatalog == baseLatestCatalogData else {
                        throw BackgroundCatalogCacheSupersededError()
                    }
                    try latestCatalogData.write(to: latestCatalogURL, options: [.atomic])
                }
            )

            switch outcome {
            case .published:
                await notifyTunnelSnapshotUpdated(operationID: operationID)
                return "bg-published"
            case .abortedSuperseded:
                return "bg-superseded"
            case .abortedContended:
                return "bg-contended"
            case .abortedCancelled:
                return "bg-cancelled"
            }
        } catch is BackgroundCatalogCacheSupersededError {
            // A concurrent foreground sync advanced the shared catalog; we declined to clobber
            // it. Nothing was published — latest.json and the pointer are both the foreground's.
            return "bg-catalog-superseded"
        } catch {
            return "bg-error"
        }
    }

    /// True when the just-synced configuration + catalog produces a different compiled
    /// identity than the one already persisted on disk — i.e. a list actually changed.
    /// True (rebuild) when no manifest exists yet (first prepare). Lets `performCatalogSync`
    /// skip the expensive persist + tunnel reload when nothing changed upstream.
    private func didSnapshotIdentityChangeAfterSync() -> Bool {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return true
        }

        let manifest = try? FilterArtifactStore(directoryURL: containerURL).readableStore().loadManifest()
        guard let previousIdentity = manifest?.snapshotIdentity else {
            return true
        }

        return PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: currentCatalog) != previousIdentity
    }

    func syncCatalogIfStale() async {
        guard let cacheURL = catalogCacheURL else {
            return
        }

        let migratedCache = migrateLowRiskLaunchCacheIfNeeded(cacheURL: cacheURL)
        guard migratedCache || !BlocklistCatalogSynchronizer.hasFreshCachedCatalog(
            in: cacheURL,
            maxAge: catalogSyncFreshnessInterval
        ) else {
            return
        }

        await syncCatalog()
    }

    private func loadCachedCatalogIfAvailable() async {
        guard let cacheURL = catalogCacheURL else {
            return
        }

        migrateLowRiskLaunchCacheIfNeeded(cacheURL: cacheURL)

        do {
            let enabledIDs = configuration.enabledBlocklistIDs
            let customSources = enabledCustomBlocklists(in: configuration)
            let result = try await Task.detached(priority: .utility) {
                let synchronizer = BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL)
                let catalogResult = try await synchronizer.loadCached(enabledSourceIDs: enabledIDs)
                let customResult = try await synchronizer.loadCachedCustomBlocklists(customSources)
                return (catalogResult, customResult)
            }.value

            applySyncResults(catalogResult: result.0, customResult: result.1)
            catalogStatusMessage = "Using saved downloaded filter."
            catalogStatusIsError = false
        } catch {
            catalogStatusMessage = "Filter will update from Lava Security's source catalog."
            catalogStatusIsError = false
        }
    }

    func recordDemo(domain: String) {
        let snapshot = currentSnapshot()
        let decision = snapshot.decision(for: domain)
        diagnostics.record(
            domain: domain,
            decision: decision,
            keepFilteringCounts: configuration.keepFilteringCounts,
            keepDomainHistory: configuration.keepDomainDiagnostics
        )
    }

    #if DEBUG || LAVA_QA_TOOLS
    private static var isVPNDebugProbeRequested: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--lava-debug-vpn")
            || processInfo.environment["LAVA_DEBUG_VPN"] == "1"
    }

    private func runVPNStartupDebugProbe() async {
        // The probe drives enable/reconnect itself; holding the claim keeps the
        // UI disabled and scheduled resumes out, exactly like a user action.
        let claimedProbeAction = protectionActionOrchestrator.claim(.turnOn)
        defer {
            if claimedProbeAction {
                protectionActionOrchestrator.release(.turnOn)
            }
        }

        logVPNDebugEvent("probe-begin", details: [
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
            "arguments": ProcessInfo.processInfo.arguments.joined(separator: " ")
        ])

        await refreshProtectionStatus(force: true)
        logVPNDebugEvent("probe-after-refresh", details: [
            "vpnStatus": vpnStatusDebugDescription(vpnStatus),
            "isVPNConfigurationInstalled": "\(isVPNConfigurationInstalled)"
        ])

        if Self.isLiveDNSSmokeTestRequested {
            logVPNDebugEvent("probe-live-dns-smoke-force-reconnect", details: [
                "vpnStatus": vpnStatusDebugDescription(vpnStatus)
            ])
            await reconnectProtectionNow(playsOutcomeHaptic: false)
            if Self.isVPNLifecycleSmokeTestRequested {
                await runVPNLifecycleSmokeProbe()
            }
            logVPNDebugEvent("probe-finished", details: [
                "vpnStatus": vpnStatusDebugDescription(vpnStatus),
                "isVPNConfigurationInstalled": "\(isVPNConfigurationInstalled)",
                "vpnMessage": vpnMessage ?? "nil",
                "vpnMessageIsError": "\(vpnMessageIsError)"
            ])
            return
        }

        if isProtectionEnabledStatus(vpnStatus) {
            logVPNDebugEvent("probe-reconnect-existing-tunnel", details: [
                "vpnStatus": vpnStatusDebugDescription(vpnStatus)
            ])
            await reconnectProtectionNow(playsOutcomeHaptic: false)
        } else {
            await enableProtection(logUserAction: false, playsOutcomeHaptic: false)
        }

        if Self.isVPNLifecycleSmokeTestRequested {
            await runVPNLifecycleSmokeProbe()
        }

        logVPNDebugEvent("probe-finished", details: [
            "vpnStatus": vpnStatusDebugDescription(vpnStatus),
            "isVPNConfigurationInstalled": "\(isVPNConfigurationInstalled)",
            "vpnMessage": vpnMessage ?? "nil",
            "vpnMessageIsError": "\(vpnMessageIsError)"
        ])
    }

    private func runVPNLifecycleSmokeProbe() async {
        logVPNDebugEvent("probe-lifecycle-begin", details: [
            "vpnStatus": vpnStatusDebugDescription(vpnStatus)
        ])

        await refreshProtectionStatus(force: true)
        guard await waitForProtectionToConnectForDebugProbe() else {
            logVPNDebugEvent("probe-lifecycle-skipped", details: [
                "vpnStatus": vpnStatusDebugDescription(vpnStatus)
            ])
            return
        }

        do {
            try await LavaProtectionCommandService.perform(.pauseFiveMinutes)
            // Drive the tunnel exactly the way production does. The command
            // service only writes shared defaults and posts the pause Darwin
            // signal, but the packet-tunnel's CFNotificationCenter observer is
            // not a reliable standalone trigger — on device it stays dormant
            // until a provider message wakes the extension's run loop (the app
            // never relies on the snapshot Darwin observer either, always using
            // sendProviderMessage). Without this send the tunnel never runs
            // refreshProtectionPauseStateOnly, so `pause-state-refreshed` never
            // lands and the lifecycle gate's required event is missing. Mirrors
            // pauseProtectionTemporarily.
            await notifyTunnelProtectionPauseUpdated()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            loadTemporaryProtectionPause()
            logVPNDebugEvent("probe-lifecycle-after-pause", details: [
                "isProtectionTemporarilyPaused": "\(isProtectionTemporarilyPaused)",
                "pauseUntil": temporaryProtectionPauseUntil.map { SharedDateFormatting.iso8601.string(from: $0) } ?? "nil",
                "vpnStatus": vpnStatusDebugDescription(vpnStatus)
            ])

            try await LavaProtectionCommandService.perform(.pauseTenMinutes)
            await notifyTunnelProtectionPauseUpdated()
            try await Task.sleep(nanoseconds: 300_000_000)
            try await LavaProtectionCommandService.perform(.resume)
            try await LavaProtectionCommandService.perform(.resume)
            await notifyTunnelProtectionPauseUpdated()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            loadTemporaryProtectionPause()
            await refreshProtectionStatus(force: true)
            logVPNDebugEvent("probe-lifecycle-after-resume", details: [
                "isProtectionTemporarilyPaused": "\(isProtectionTemporarilyPaused)",
                "pauseUntil": temporaryProtectionPauseUntil.map { SharedDateFormatting.iso8601.string(from: $0) } ?? "nil",
                "vpnStatus": vpnStatusDebugDescription(vpnStatus)
            ])
        } catch {
            logVPNDebugEvent("probe-lifecycle-error", details: errorDebugDetails(error))
        }
    }

    private func waitForProtectionToConnectForDebugProbe(timeout: TimeInterval = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while vpnStatus != .connected, Date() < deadline {
            updateProtectionStatusFromCachedManager()
            if vpnStatus == .connected {
                return true
            }

            await refreshProtectionStatus(force: true)
            if vpnStatus == .connected {
                return true
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        return vpnStatus == .connected
    }

    private func logVPNDebugEvent(_ event: String, details: [String: String] = [:]) {
        LavaSecDeviceDebugLog.append(component: "app", event: event, details: details)
    }

    private func tunnelManagerDebugDetails(_ manager: NETunnelProviderManager?) -> [String: String] {
        guard let manager else {
            return ["manager": "nil"]
        }

        let provider = manager.protocolConfiguration as? NETunnelProviderProtocol
        return [
            "manager": "present",
            "localizedDescription": manager.localizedDescription ?? "nil",
            "isEnabled": "\(manager.isEnabled)",
            "connectionStatus": vpnStatusDebugDescription(manager.connection.status),
            "providerBundleIdentifier": provider?.providerBundleIdentifier ?? "nil",
            "serverAddress": provider?.serverAddress ?? "nil",
            "providerConfiguration": "\(provider?.providerConfiguration ?? [:])"
        ]
    }

    private func errorDebugDetails(_ error: Error) -> [String: String] {
        let nsError = error as NSError
        return [
            "errorDescription": nsError.localizedDescription,
            "errorDomain": nsError.domain,
            "errorCode": "\(nsError.code)",
            "underlyingError": "\(nsError.userInfo[NSUnderlyingErrorKey] ?? "nil")"
        ]
    }

    #endif

    /// QA-only telemetry for the Focus-driven headless switch + its foreground reconcile. The FUNCTION must
    /// live OUTSIDE the surrounding `#if DEBUG || LAVA_QA_TOOLS` probe block — it is called unconditionally
    /// from `reconcilePendingFilterSwitch` and the headless commit paths, so a Release/TestFlight build would
    /// fail to compile if the declaration were debug-only (Codex round-11 P1). Only its BODY is gated, under
    /// the same `focus-switch-intent` component as `LavaWarmSwitchService.log` so the whole feature (intent
    /// boundary, headless commit/rollback, reconcile apply) filters as one in device dumps.
    private func logFocusSwitchEvent(_ event: String, details: [String: String] = [:]) {
        #if DEBUG || LAVA_QA_TOOLS
        LavaSecDeviceDebugLog.append(component: "focus-switch-intent", event: event, details: details)
        #endif
    }

    private func vpnStatusDebugDescription(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid:
            "invalid"
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .connected:
            "connected"
        case .reasserting:
            "reasserting"
        case .disconnecting:
            "disconnecting"
        @unknown default:
            "unknown-\(status.rawValue)"
        }
    }

    private func makeLatencyTrace(operationID: LatencyOperationID, operationKind: String) -> LatencyTrace {
        #if DEBUG || LAVA_QA_TOOLS
        return LatencyTrace(
            operationID: operationID,
            sink: LatencyDebugLogEventSink(operationKind: operationKind) { [weak self] event, details in
                self?.logVPNDebugEvent(event, details: details)
            }
        )
        #else
        return LatencyTrace(operationID: operationID)
        #endif
    }

    /// The heavy, user-input-independent inputs to a bug-report bundle: the
    /// compiled filter snapshot (the full blocklist union) and the parsed
    /// lifecycle debug-log entries. Captured once per `prepareBugReport` so the
    /// per-keystroke draft refresh can reuse them (UR-5).
    private struct PreparedBugReportInputs {
        let snapshot: FilterSnapshot
        let debugLogEntries: [BugReportDebugLogEntry]
        let selfReconnectTimes: [Date]
    }

    private var preparedBugReportInputs: PreparedBugReportInputs?

    private func makeBugReportBundle(context: BugReportContext) -> BugReportBundle {
        makeBugReportBundle(
            context: context,
            inputs: PreparedBugReportInputs(
                snapshot: currentSnapshot(),
                debugLogEntries: loadBugReportDebugLogEntries(),
                selfReconnectTimes: loadSelfReconnectAttemptTimes()
            )
        )
    }

    /// Read-only snapshot of the tunnel's persisted self-reconnect attempt timeline (shared
    /// app-group defaults). Surfaced in the bug report's incident summary (LAV-94 B); never
    /// written here — the tunnel owns the key, the app only reads it.
    private func loadSelfReconnectAttemptTimes() -> [Date] {
        let raw = LavaSecAppGroup.sharedDefaults.array(
            forKey: LavaSecAppGroup.selfReconnectAttemptTimesDefaultsKey
        ) as? [Double] ?? []
        return raw.map(Date.init(timeIntervalSince1970:))
    }

    private func makeBugReportBundle(
        context: BugReportContext,
        inputs: PreparedBugReportInputs
    ) -> BugReportBundle {
        let identity = PreparedFilterSnapshotIdentity.make(
            configuration: configuration,
            catalog: currentCatalog
        )
        let snapshotVersion = String(identity.fingerprint.prefix(12))
        let affectedSiteDecision = BugReportAffectedSiteFilterDecision.make(
            rawAffectedSite: context.normalizedAffectedSite,
            snapshot: inputs.snapshot
        )

        return BugReportBundle(
            context: context,
            app: BugReportAppSnapshot(
                version: Self.bundleInfoValue("CFBundleShortVersionString"),
                build: Self.bundleInfoValue("CFBundleVersion")
            ),
            device: BugReportDeviceSnapshot(
                iosVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
                deviceFamily: Self.deviceFamilyDescription(UIDevice.current.userInterfaceIdiom),
                locale: Locale.current.identifier
            ),
            vpn: BugReportVPNSnapshot(
                status: vpnStatusReportDescription(vpnStatus),
                resolverPreset: configuration.resolverDiagnosticDisplayName,
                health: tunnelHealth
            ),
            filters: BugReportFilterSummary(
                catalogVersion: catalogVersion,
                enabledListIDs: configuration.enabledBlocklistIDs.sorted(),
                snapshotVersion: snapshotVersion,
                compiledRuleCount: compiledRuleCount,
                blocklistRuleCount: compiledBlocklistRuleCount,
                customBlocklistCount: configuration.customBlocklists.count,
                enabledCustomBlocklistCount: configuration.customBlocklists.filter {
                    configuration.enabledBlocklistIDs.contains($0.id)
                }.count,
                affectedSiteDecision: affectedSiteDecision
            ),
            diagnostics: diagnostics,
            localHistoryEnabled: configuration.keepDomainDiagnostics,
            debugLogEntries: inputs.debugLogEntries,
            selfReconnectTimes: inputs.selfReconnectTimes,
            // Privacy-safe Focus-switch diagnostic (LAV-100 Phase 4): the extension records the last
            // attempt's outcome to the shared app group, so a closed-app failure is debuggable from the
            // (Release) bug report without a device or the QA device log.
            lastFocusSwitch: FocusSwitchDiagnostics.last(in: LavaSecAppGroup.sharedDefaults)
        )
    }

    private func submitBugReport(_ bundle: BugReportBundle) async throws -> String {
        let body = bundle.makeRequestBody()
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var lastError: Error?

        for endpoint in Self.bugReportEndpointURLs {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = data

                let (responseData, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw BugReportSubmissionError(message: "The server returned an invalid response.")
                }

                guard 200..<300 ~= httpResponse.statusCode else {
                    let serverMessage = String(data: responseData, encoding: .utf8) ?? "No response body"
                    throw BugReportSubmissionError(
                        message: "The server returned HTTP \(httpResponse.statusCode): \(serverMessage)"
                    )
                }

                let decoded = try JSONDecoder().decode(BugReportSubmitResponse.self, from: responseData)
                return decoded.reportID
            } catch {
                lastError = error
            }
        }

        throw lastError ?? BugReportSubmissionError(message: "Could not send the bug report.")
    }

    private func startLavaSecurityPlusStore() {
        lavaSecurityPlusOffers = lavaSecurityPlusStore.offers
        lavaSecurityPlusStore.entitlementChanged = { [weak self] entitlement in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.applyLavaSecurityPlusEntitlement(entitlement)
                await self.syncLavaSecurityPlusEntitlementIfPossible(entitlement)
            }
        }
        lavaSecurityPlusStore.start()

        Task { [weak self] in
            guard let self else {
                return
            }

            await self.loadLavaSecurityPlusProducts()
            await self.refreshLavaSecurityPlusEntitlements()
        }
    }

    private func applyLavaSecurityPlusEntitlement(_ entitlement: LavaSecurityPlusEntitlement) {
        // Surface the auto-renewable expiry (nil when there is no active entitlement)
        // before the early-return below, so the subscriber UI stays current even when the
        // active flag itself is unchanged (e.g. a renewal that only moves the expiry date).
        let nextExpiresAt = entitlement.isActive ? entitlement.expiresAt : nil
        if lavaSecurityPlusExpiresAt != nextExpiresAt {
            lavaSecurityPlusExpiresAt = nextExpiresAt
        }

        let hasLavaSecurityPlus = entitlement.isActive
        guard configuration.hasLavaSecurityPlus != hasLavaSecurityPlus else {
            return
        }

        configuration.isPaid = hasLavaSecurityPlus

        // The paid flag only drives app-side tier limits and UI; the tunnel
        // never reads isPaid. Persist it so the status survives launches, but do
        // NOT signal a configuration reload — that reapplies tunnel network
        // settings (a visible reconnect) and would fire spuriously on every
        // entitlement change.
        do {
            try persistConfigurationOnly()
        } catch {
            lavaSecurityPlusMessage = "Could not save plan state: \(error.localizedDescription)"
            lavaSecurityPlusMessageIsError = true
        }
    }

    private func currentLavaSecurityPlusAppAccountToken() async -> UUID? {
        guard let session = try? await accountAuthService.currentBackupSession() else {
            accountAuthState = accountAuthService.state
            return nil
        }

        accountAuthState = accountAuthService.state
        return UUID(uuidString: session.userID)
    }

    private func syncLavaSecurityPlusEntitlementIfPossible(
        _ entitlement: LavaSecurityPlusEntitlement
    ) async {
        guard entitlement.isActive,
              let signedTransactionJWS = entitlement.signedTransactionJWS,
              !signedTransactionJWS.isEmpty
        else {
            return
        }

        do {
            guard let session = try await accountAuthService.currentBackupSession() else {
                accountAuthState = accountAuthService.state
                return
            }

            accountAuthState = accountAuthService.state
            try await lavaSecurityPlusEntitlementSyncClient.sync(
                entitlement: entitlement,
                session: session
            )
        } catch LavaSecurityPlusEntitlementSyncError.requestFailed(let statusCode, _) where statusCode == 401 {
            do {
                guard let refreshedSession = try await accountAuthService.refreshCurrentSession() else {
                    accountAuthState = accountAuthService.state
                    return
                }

                accountAuthState = accountAuthService.state
                try await lavaSecurityPlusEntitlementSyncClient.sync(
                    entitlement: entitlement,
                    session: refreshedSession
                )
            } catch {
                accountAuthState = accountAuthService.state
            }
        } catch {
            accountAuthState = accountAuthService.state
        }
    }

    private func loadBugReportDebugLogEntries() -> [BugReportDebugLogEntry] {
        guard let url = LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.vpnDebugLogFilename),
              let data = try? Data(contentsOf: url)
        else {
            return []
        }

        return BugReportDebugLogEntry.parseJSONLines(data)
    }

    private func vpnStatusReportDescription(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid:
            "invalid"
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .connected:
            "connected"
        case .reasserting:
            "reasserting"
        case .disconnecting:
            "disconnecting"
        @unknown default:
            "unknown-\(status.rawValue)"
        }
    }

    private static var bugReportEndpointURLs: [URL] {
        [LavaSecAPI.productionBaseURL, LavaSecAPI.fallbackBaseURL].map {
            $0
                .appendingPathComponent("v1")
                .appendingPathComponent("bug-reports")
        }
    }

    private static func bundleInfoValue(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "Unknown"
    }

    private static func deviceFamilyDescription(_ idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .phone:
            "Phone"
        case .pad:
            "iPad"
        case .mac:
            "Mac"
        case .tv:
            "Apple TV"
        case .carPlay:
            "CarPlay"
        case .vision:
            "Apple Vision"
        case .unspecified:
            "Unspecified"
        @unknown default:
            "Unknown"
        }
    }

    func refreshProtectionStatus(force: Bool = false) async {
        #if targetEnvironment(simulator)
        vpnStatus = .invalid
        isVPNConfigurationInstalled = false
        configuration.protectionEnabled = false
        reconcileLiveActivity()
        vpnMessage = "VPN testing requires a physical phone."
        vpnMessageIsError = false
        return
        #else
        if !force, let tunnelManager {
            updateProtectionStatus(from: tunnelManager)

            if let lastProtectionStatusRefresh,
               Date().timeIntervalSince(lastProtectionStatusRefresh) < protectionStatusRefreshInterval,
               !isProtectionTransitionStatus(vpnStatus) {
                return
            }
        }

        guard !isRefreshingProtectionStatus else {
            needsProtectionStatusRefresh = true
            #if DEBUG || LAVA_QA_TOOLS
            logVPNDebugEvent("refresh-status-coalesced", details: [
                "force": "\(force)",
                "vpnStatus": vpnStatusDebugDescription(vpnStatus)
            ])
            #endif
            return
        }

        isRefreshingProtectionStatus = true
        defer {
            isRefreshingProtectionStatus = false
        }

        // Bounded: each loadExistingTunnelManager pass can re-post
        // NEVPNStatusDidChange, so an unbounded repeat-while turns coalescing
        // into a self-sustaining refresh storm. One follow-up pass is enough to
        // cover a request that arrived mid-refresh; later triggers (poll,
        // scene activation, user actions) reconcile anything newer.
        var remainingRefreshPasses = 2
        repeat {
            remainingRefreshPasses -= 1
            needsProtectionStatusRefresh = false
            do {
                let manager = try await loadExistingTunnelManager()
                tunnelManager = manager
                updateProtectionStatus(from: manager)
                lastProtectionStatusRefresh = Date()
                if vpnStatus == .connected {
                    await requestTunnelHealthFlush()
                }
                refreshTunnelHealth()
            } catch {
                vpnMessage = error.localizedDescription
                vpnMessageIsError = true

                #if DEBUG || LAVA_QA_TOOLS
                logVPNDebugEvent("refresh-status-error", details: errorDebugDetails(error))
                #endif
            }
        } while needsProtectionStatusRefresh && remainingRefreshPasses > 0
        #endif
    }

    private func currentSnapshot() -> FilterSnapshot {
        configuration.filterSnapshot(
            blockRules: blockRules,
            nonAllowableThreatRules: threatGuardrail
        )
    }

    private func preparedSummary(for snapshot: FilterSnapshot) -> PreparedFilterSnapshotSummary {
        let blocklistRuleCount = preparedBlocklistRuleCount()
        return PreparedFilterSnapshotSummary(
            snapshot: snapshot,
            blocklistRuleCount: blocklistRuleCount,
            blocklistSourceRuleCounts: preparedBlocklistSourceRuleCounts(),
            // Persist the SAME tier-budget total a cold compile would record (block-merge + FULL
            // guardrail + allowed + blocked — mirrors FilterSnapshotPreparationService.prepare), so a
            // warm switch-back to this freshly persisted token passes the tier gate instead of always
            // cold-compiling (Codex #133). threatGuardrail is the full guardrail (snapshot's
            // nonAllowableThreatRules is only the allowlist-overlap subset). nil blocklist count ⇒ nil
            // budget ⇒ the warm reuse correctly falls back to a cold compile.
            tierBudgetRuleCount: blocklistRuleCount.map {
                $0 + threatGuardrail.count + configuration.allowedDomains.count + configuration.blockedDomains.count
            }
        )
    }

    private func preparedBlocklistRuleCount() -> Int? {
        let hasAllEnabledRuleSets = configuration.enabledBlocklistIDs.allSatisfy { sourceID in
            cachedBlockRuleSets[sourceID] != nil
        }

        if configuration.enabledBlocklistIDs.isEmpty || hasAllEnabledRuleSets {
            return FilterSnapshotPreparationService.mergedBlockRules(
                enabledSourceIDs: configuration.enabledBlocklistIDs,
                sourceRuleSets: cachedBlockRuleSets
            ).count
        }

        if compiledBlocklistRuleCount > 0 {
            return compiledBlocklistRuleCount
        }

        return nil
    }

    private func preparedBlocklistSourceRuleCounts() -> [String: Int]? {
        guard !configuration.enabledBlocklistIDs.isEmpty else {
            return [:]
        }

        var sourceRuleCounts: [String: Int] = [:]
        for sourceID in configuration.enabledBlocklistIDs {
            guard let rules = cachedBlockRuleSets[sourceID] else {
                return nil
            }
            sourceRuleCounts[sourceID] = rules.count
        }

        return sourceRuleCounts
    }

    private func preparedSnapshotForCurrentConfiguration() -> PreparedFilterSnapshot {
        let snapshot = currentSnapshot()
        return PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(
                configuration: configuration,
                catalog: currentCatalog
            ),
            snapshot: snapshot,
            summary: preparedSummary(for: snapshot)
        )
    }

    /// Off-main builder for the BACKGROUND publish path. Equivalent to
    /// `preparedSnapshotForCurrentConfiguration()` for the case the background guarantees —
    /// where the block rules are exactly the merge of the enabled sources' cached rule sets —
    /// so it merges ONCE and reuses that for both the snapshot and the summary rule count,
    /// dropping the redundant second merge `preparedBlocklistRuleCount()` performs.
    ///
    /// `nonisolated static` so it runs on a detached task off the main actor: the merge +
    /// `filterSnapshot` are O(rules) and must not block the main actor past the BGTask
    /// deadline (the foreground path is unaffected and still uses
    /// `preparedSnapshotForCurrentConfiguration()`/`self.blockRules`, which can differ from a
    /// fresh merge in the reuse path). All inputs are Sendable value types the caller captures
    /// on the main actor.
    nonisolated static func buildBackgroundPreparedSnapshot(
        configuration: AppConfiguration,
        cachedBlockRuleSets: [String: DomainRuleSet],
        threatGuardrail: DomainRuleSet,
        catalog: BlocklistCatalog?,
        compiledBlocklistRuleCount: Int
    ) -> PreparedFilterSnapshot {
        let enabledIDs = configuration.enabledBlocklistIDs
        let mergedBlockRules = FilterSnapshotPreparationService.mergedBlockRules(
            enabledSourceIDs: enabledIDs,
            sourceRuleSets: cachedBlockRuleSets
        )
        let snapshot = configuration.filterSnapshot(
            blockRules: mergedBlockRules,
            nonAllowableThreatRules: threatGuardrail
        )

        // Mirror preparedBlocklistRuleCount() / preparedBlocklistSourceRuleCounts(), but reuse
        // the single merge above instead of re-merging. Fail-closed: a missing enabled source
        // yields nil source counts → coversEnabledBlocklists returns false → bg-uncovered.
        let blocklistRuleCount: Int?
        let hasAllEnabledRuleSets = enabledIDs.allSatisfy { cachedBlockRuleSets[$0] != nil }
        if enabledIDs.isEmpty || hasAllEnabledRuleSets {
            blocklistRuleCount = mergedBlockRules.count
        } else if compiledBlocklistRuleCount > 0 {
            blocklistRuleCount = compiledBlocklistRuleCount
        } else {
            blocklistRuleCount = nil
        }

        let blocklistSourceRuleCounts: [String: Int]?
        if enabledIDs.isEmpty {
            blocklistSourceRuleCounts = [:]
        } else {
            var counts: [String: Int] = [:]
            var complete = true
            for sourceID in enabledIDs {
                guard let rules = cachedBlockRuleSets[sourceID] else {
                    complete = false
                    break
                }
                counts[sourceID] = rules.count
            }
            blocklistSourceRuleCounts = complete ? counts : nil
        }

        return PreparedFilterSnapshot(
            identity: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: catalog),
            snapshot: snapshot,
            summary: PreparedFilterSnapshotSummary(
                snapshot: snapshot,
                blocklistRuleCount: blocklistRuleCount,
                blocklistSourceRuleCounts: blocklistSourceRuleCounts,
                // Same tier-budget total a cold compile records (block-merge + FULL guardrail + allowed
                // + blocked), so a warm switch-back to this background-published token passes the tier
                // gate instead of cold-compiling (Codex #133). nil blocklist count ⇒ nil budget ⇒
                // warm reuse falls back to cold.
                tierBudgetRuleCount: blocklistRuleCount.map {
                    $0 + threatGuardrail.count + configuration.allowedDomains.count + configuration.blockedDomains.count
                }
            )
        )
    }

    // reusedPersistedArtifacts means the snapshot was decoded from and validated
    // against the on-disk artifacts, so persisting it again would rewrite
    // identical bytes (and force a pointless tunnel reload).
    private struct ProtectionStartupSnapshot {
        let preparedSnapshot: PreparedFilterSnapshot
        let reusedPersistedArtifacts: Bool
    }

    private func preparedSnapshotForProtectionStartup(
        trace: LatencyTrace? = nil,
        parentSpan: LatencySpan? = nil
    ) async throws -> ProtectionStartupSnapshot {
        if let reusable = await loadReusablePreparedSnapshotForProtectionStartup() {
            applyReusablePreparedSnapshot(reusable)
            catalogStatusMessage = "Using prepared local filter."
            catalogStatusIsError = false

            #if DEBUG
            logVPNDebugEvent("enable-reuse-prepared-snapshot", details: [
                "fingerprint": reusable.preparedSnapshot.identity.fingerprint,
                "blockRuleCount": "\(reusable.preparedSnapshot.snapshot.blockRules.count)",
                "allowRuleCount": "\(reusable.preparedSnapshot.snapshot.allowRules.count)",
                "guardrailRuleCount": "\(reusable.preparedSnapshot.snapshot.nonAllowableThreatRules.count)",
                "catalogVersion": reusable.cachedCatalog?.catalogVersion ?? "nil"
            ])
            #endif

            return ProtectionStartupSnapshot(
                preparedSnapshot: reusable.preparedSnapshot,
                reusedPersistedArtifacts: true
            )
        }

        if currentCatalog != nil || configuration.enabledBlocklistIDs.isEmpty {
            let preparedSnapshot = preparedSnapshotForCurrentConfiguration()

            #if DEBUG
            logVPNDebugEvent("enable-use-current-snapshot", details: [
                "fingerprint": preparedSnapshot.identity.fingerprint,
                "compiledRuleCount": "\(compiledRuleCount)",
                "catalogVersion": currentCatalog?.catalogVersion ?? "nil"
            ])
            #endif

            return ProtectionStartupSnapshot(
                preparedSnapshot: preparedSnapshot,
                reusedPersistedArtifacts: false
            )
        }

        #if DEBUG
        logVPNDebugEvent("enable-prepare-snapshot")
        #endif

        let prepared = try await prepareFilterSnapshot(
            for: configuration,
            customListPolicy: .cacheFirst,
            trace: trace,
            parentSpan: parentSpan
        )
        updateCustomBlocklistHashes(prepared.customResult.sourceHashes)
        applyCatalogSyncResult(prepared.catalogResult)
        return ProtectionStartupSnapshot(
            preparedSnapshot: prepared.snapshot,
            reusedPersistedArtifacts: false
        )
    }

    private func loadReusablePreparedSnapshotForProtectionStartup() async -> ReusablePreparedFilterSnapshot? {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return nil
        }

        let cacheURL = catalogCacheURL
        let configuration = configuration
        if let cacheURL {
            migrateLowRiskLaunchCacheIfNeeded(cacheURL: cacheURL)
        }

        return await Task.detached(priority: .utility) {
            // Reuse misses fall through to the full (potentially multi-second)
            // preparation pipeline, so every rejection logs its reason.
            func rejectReuse(_ reason: String) -> ReusablePreparedFilterSnapshot? {
                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "app", event: "enable-reuse-rejected", details: [
                    "reason": reason
                ])
                #endif
                return nil
            }

            let cachedCatalog = cacheURL.flatMap { cacheURL in
                try? BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL).loadCachedCatalogMetadata()
            }

            // Manifest-first gate: a non-reusable artifact set is rejected from
            // the small manifest alone, without decoding the full prepared JSON.
            // The decoded snapshot below stays the authoritative reuse check.
            let artifactStore = FilterArtifactStore(directoryURL: containerURL).readableStore()
            if let manifest = try? artifactStore.loadManifest(),
               let rejection = manifest.reuseRejectionReason(configuration: configuration, cachedCatalog: cachedCatalog) {
                // Field-level reason (names only) so a redundant cold rebuild
                // after refresh is self-diagnosing on the next device repro.
                return rejectReuse("manifest-mismatch:\(rejection)")
            }

            guard let data = try? Data(contentsOf: artifactStore.preparedSnapshotURL) else {
                return rejectReuse("prepared-snapshot-unreadable")
            }
            guard let preparedSnapshot = try? JSONDecoder().decode(PreparedFilterSnapshot.self, from: data) else {
                return rejectReuse("prepared-snapshot-undecodable")
            }

            guard preparedSnapshot.canReuseForProtectionStartup(
                configuration: configuration,
                cachedCatalog: cachedCatalog
            ) else {
                return rejectReuse(cachedCatalog == nil ? "snapshot-mismatch-no-cached-catalog" : "snapshot-mismatch")
            }

            return ReusablePreparedFilterSnapshot(
                preparedSnapshot: preparedSnapshot,
                cachedCatalog: cachedCatalog,
                // Startup reuse keeps the snapshot subset (the concurrent launch catalog sync
                // repopulates the full guardrail shortly after); only the warm SWITCH hydrates it.
                fullThreatGuardrail: nil
            )
        }.value
    }

    /// Cache-first gate for turn-on: `true` when a persisted artifact set
    /// satisfies the manifest-level reuse check for the current configuration,
    /// i.e. the VPN can start from cache without waiting on a network catalog
    /// refresh. Manifest-only (no prepared-snapshot decode) so it stays cheap on
    /// the turn-on critical path; `loadReusablePreparedSnapshotForProtectionStartup`
    /// remains the authoritative reuse check that actually loads the snapshot.
    private func hasReusableArtifactForCurrentConfiguration() async -> Bool {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return false
        }

        let cacheURL = catalogCacheURL
        let configuration = configuration
        return await Task.detached(priority: .utility) {
            let cachedCatalog = cacheURL.flatMap { cacheURL in
                try? BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL).loadCachedCatalogMetadata()
            }

            let artifactStore = FilterArtifactStore(directoryURL: containerURL).readableStore()
            guard let manifest = try? artifactStore.loadManifest() else {
                return false
            }

            return manifest.reuseRejectionReason(
                configuration: configuration,
                cachedCatalog: cachedCatalog
            ) == nil
        }.value
    }

    private func loadPreparedFilterSummaryForCurrentConfiguration() async -> CompactFilterSnapshotSummary? {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return nil
        }

        // Resolve through the pointer (versioned set) with root fallback, consistent
        // with the other warm-start readers; single-file read, captured once.
        let compactSnapshotURL = FilterArtifactStore(directoryURL: containerURL).readableStore().compactSnapshotURL
        let configuration = configuration

        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: compactSnapshotURL),
                  let summary = try? CompactFilterSnapshot.readSummary(from: data),
                  summary.identity.hasSameConfiguration(as: configuration),
                  summary.coversEnabledBlocklists(in: configuration)
            else {
                return nil
            }

            return summary
        }.value
    }

    private func applyReusablePreparedSnapshot(_ reusable: ReusablePreparedFilterSnapshot) {
        if let catalog = reusable.cachedCatalog {
            currentCatalog = catalog
            catalogVersion = catalog.catalogVersion
            catalogGeneratedAt = catalog.generatedAt
            catalogSourcesByID = Dictionary(uniqueKeysWithValues: catalog.sources.map { ($0.id, $0) })

            for source in catalog.sources where configuration.enabledBlocklistIDs.contains(source.id) {
                sourceStates[source.id] = .nosync
            }
        }

        blockRules = reusable.preparedSnapshot.snapshot.blockRules
        // Prefer the FULL guardrail when the caller hydrated it (the warm switch path): the snapshot's
        // nonAllowableThreatRules is only the allowlist-overlap subset, which would let
        // AllowlistValidator allow a threat domain that isn't already allowed (Codex #133 r2).
        threatGuardrail = reusable.fullThreatGuardrail ?? reusable.preparedSnapshot.snapshot.nonAllowableThreatRules
        compiledRuleCount = reusable.preparedSnapshot.summary.blockRuleCount
        protectedRuleCount = reusable.preparedSnapshot.summary.blockedDomainRuleCount
        if let blocklistRuleCount = reusable.preparedSnapshot.summary.blocklistRuleCount {
            compiledBlocklistRuleCount = blocklistRuleCount
        } else {
            refreshCompiledBlocklistRuleCount()
        }
        if compiledBlocklistRuleCount == 0, !configuration.enabledBlocklistIDs.isEmpty {
            compiledBlocklistRuleCount = estimatedBlocklistRuleCount(fromTotalRuleCount: compiledRuleCount)
        }
    }

    // Preparation (catalog sync ladder, merge, snapshot build) and artifact
    // writes run inside FilterSnapshotPreparationService, off the main actor;
    // this wrapper bridges UI progress reporting and cache migration.
    private func prepareFilterSnapshot(
        for configuration: AppConfiguration,
        customListPolicy: CustomBlocklistSyncPolicy = .networkFirst,
        catalogCacheOnly: Bool = false,
        reportProgress: ((FilterPreparationProgressUpdate) async -> Void)? = nil,
        trace: LatencyTrace? = nil,
        parentSpan: LatencySpan? = nil
    ) async throws -> FilterSnapshotPreparationResult {
        guard let cacheURL = catalogCacheURL, let service = filterSnapshotPreparationService else {
            throw LavaSecAppError.appGroupUnavailable
        }

        migrateLowRiskLaunchCacheIfNeeded(cacheURL: cacheURL)
        let customSources = enabledCustomBlocklists(in: configuration)
        // A plan that no longer allows custom blocklists (e.g. a lapsed Plus
        // subscriber) keeps the lists it already had, but we never refresh their
        // contents from the network — the cached payload is frozen in place. This
        // is strictly cache-only (not cache-first): even a cache miss or stored-hash
        // mismatch must not fall back to a network fetch, which would re-download and
        // re-hash the frozen list. The catalog still syncs normally; only custom-list
        // fetching is held back.
        let effectiveCustomListPolicy: CustomBlocklistSyncPolicy =
            configuration.limits.allowsCustomBlocklists ? customListPolicy : .cacheOnly
        var bridgedProgress: FilterSnapshotPreparationService.ProgressHandler?
        if let reportProgress {
            bridgedProgress = { @MainActor @Sendable update in
                await reportProgress(update)
            }
        }
        return try await service.prepare(
            configuration: configuration,
            customSources: customSources,
            catalogFreshnessMaxAge: catalogSyncFreshnessInterval,
            customListPolicy: effectiveCustomListPolicy,
            catalogCacheOnly: catalogCacheOnly,
            tierRuleLimit: FilterRuleTierLimit(
                limit: configuration.limits.maxFilterRules,
                isPaid: configuration.hasLavaSecurityPlus
            ),
            reportProgress: bridgedProgress,
            trace: trace,
            parentSpan: parentSpan
        )
    }

    private func reportFilterPreparationProgress(
        _ reportProgress: ((FilterPreparationProgressUpdate) async -> Void)?,
        progress: Double,
        phase: FilterPreparationPhase
    ) async {
        guard let reportProgress else {
            return
        }

        await reportProgress(FilterPreparationProgressUpdate(progress: progress, phase: phase))
    }

    private func enableProtection(
        logUserAction: Bool = true,
        playsOutcomeHaptic: Bool = true,
        operationID: LatencyOperationID = .make()
    ) async {
        let trace = makeLatencyTrace(operationID: operationID, operationKind: "turnOn")
        let span = trace.beginSpan("action.turnOn", details: [
            "vpnStatus": vpnStatusDebugDescription(vpnStatus),
            "catalogVersion": catalogVersion ?? "nil",
            "compiledRuleCount": "\(compiledRuleCount)"
        ])
        var actionStatus = "started"
        defer {
            span.end(details: ["status": actionStatus, "vpnStatus": vpnStatusDebugDescription(vpnStatus)])
        }

        #if DEBUG
        logVPNDebugEvent("enable-begin", details: [
            "vpnStatus": vpnStatusDebugDescription(vpnStatus),
            "catalogVersion": catalogVersion ?? "nil",
            "compiledRuleCount": "\(compiledRuleCount)"
        ])
        #endif

        vpnMessage = "Preparing local protection..."
        vpnMessageIsError = false
        if playsOutcomeHaptic {
            awaitsProtectionOnHaptic = true
        } else {
            awaitsProtectionOnHaptic = false
        }

        do {
            // Cache-first turn-on: when a confirmed-reusable prepared artifact
            // exists for the *current* configuration, the VPN can come up
            // immediately from cache while any in-flight catalog sync keeps
            // refreshing in the background — performCatalogSync reconciles the
            // running tunnel on completion (notifyTunnelSnapshotUpdated +
            // restoreProtectionIfNeeded, which single-flights against this
            // turn-on). We only block on the sync when there is nothing valid
            // to start from, e.g. the user just changed the enabled-list set,
            // which invalidates the cached artifact's identity.
            if catalogSyncTask != nil {
                if await hasReusableArtifactForCurrentConfiguration() {
                    #if DEBUG
                    logVPNDebugEvent("enable-cache-first-skip-sync-wait")
                    #endif
                } else {
                    #if DEBUG
                    logVPNDebugEvent("enable-waiting-for-catalog-sync")
                    #endif

                    vpnMessage = "Finishing filter update..."
                    await waitForCatalogSyncToFinish()
                }
            }

            beginFreshProtectionVPNSession()
            let prepareSpan = trace.beginSpan("turnOn.prepareSnapshot", parent: span)
            let startup = try await preparedSnapshotForProtectionStartup(trace: trace, parentSpan: prepareSpan)
            let preparedSnapshot = startup.preparedSnapshot
            prepareSpan.end(details: [
                "reusedPersistedArtifacts": "\(startup.reusedPersistedArtifacts)"
            ])

            let persistSpan = trace.beginSpan("turnOn.persistArtifacts", parent: span)
            try await persistSharedState(
                preparedSnapshot: preparedSnapshot,
                rewritesRuleArtifacts: !startup.reusedPersistedArtifacts
            )
            persistSpan.end(details: [
                "rewroteRuleArtifacts": "\(!startup.reusedPersistedArtifacts)"
            ])
            #if DEBUG
            logVPNDebugEvent("enable-persisted-shared-state", details: [
                "compiledRuleCount": "\(compiledRuleCount)",
                "catalogVersion": catalogVersion ?? "nil",
                "fingerprint": preparedSnapshot.identity.fingerprint
            ])
            #endif

            let managerSpan = trace.beginSpan("turnOn.managerSetup", parent: span)
            let existingManager = try await loadExistingTunnelManager()
            #if DEBUG
            logVPNDebugEvent("enable-loaded-existing-manager", details: tunnelManagerDebugDetails(existingManager))
            #endif

            if existingManager == nil {
                vpnMessage = Self.vpnPermissionPromptMessage
                vpnMessageIsError = false
            }

            var manager = try await loadOrCreateTunnelManager(existingManager: existingManager)
            managerSpan.end(details: ["hadExistingManager": "\(existingManager != nil)"])
            tunnelManager = manager
            updateProtectionStatus(from: manager)

            if manager.connection.status == .disconnecting {
                vpnMessage = "Waiting for iOS to finish stopping the local VPN..."
                vpnMessageIsError = false
                guard await waitForProtectionToStop(timeout: Self.protectionRestartStopWaitTimeout) else {
                    throw LavaSecAppError.vpnStillStopping
                }
                if let refreshedManager = try await loadExistingTunnelManager() {
                    manager = refreshedManager
                } else {
                    manager = try await loadOrCreateTunnelManager()
                }
                tunnelManager = manager
                updateProtectionStatus(from: manager)
            }

            if manager.connection.status != .connected && manager.connection.status != .connecting {
                #if DEBUG
                logVPNDebugEvent("enable-start-vpn-request", details: tunnelManagerDebugDetails(manager))
                #endif

                try manager.connection.startVPNTunnel(options: [
                    LavaSecAppGroup.latencyOperationIDOptionKey: operationID.rawValue as NSString
                ])
                if logUserAction {
                    appendAppNetworkActivity(.turnProtectionOn)
                }

                #if DEBUG
                logVPNDebugEvent("enable-start-vpn-returned", details: tunnelManagerDebugDetails(manager))
                #endif
            } else if logUserAction {
                appendAppNetworkActivity(.turnProtectionOn)
            }

            updateProtectionStatus(from: manager)
            lastProtectionStatusRefresh = Date()
            if vpnStatus != .connected {
                vpnMessage = "Waiting for iOS to finish starting the local VPN..."
                vpnMessageIsError = false
                let statusWaitSpan = trace.beginSpan("turnOn.statusWait", parent: span)
                guard await waitForProtectionToConnect(timeout: Self.protectionStartWaitTimeout) else {
                    statusWaitSpan.end(details: ["status": "timeout"])
                    configuration.protectionEnabled = isProtectionEnabledStatus(vpnStatus)
                    // Rule artifacts were already persisted (or validly reused)
                    // above; only the configuration state changed here.
                    try? await persistSharedState(preparedSnapshot: preparedSnapshot, rewritesRuleArtifacts: false)
                    #if DEBUG || LAVA_QA_TOOLS
                    logVPNDebugEvent("enable-start-wait-timeout", details: [
                        "vpnStatus": vpnStatusDebugDescription(vpnStatus)
                    ])
                    #endif
                    actionStatus = "timeout"
                    return
                }
                statusWaitSpan.end(details: ["status": "connected"])

                if let refreshedManager = try await loadExistingTunnelManager() {
                    manager = refreshedManager
                    tunnelManager = manager
                    updateProtectionStatus(from: manager)
                }
            }

            // Now that protection is genuinely connected, enable Connect-On-Demand
            // so iOS keeps the tunnel up and auto-restarts it if the system tears
            // it down (e.g. NEProviderStopReason.internalError on a network change).
            // This is deliberately done here — not in applyConfiguration — so that
            // merely installing the VPN profile during onboarding does not make iOS
            // bring the tunnel up before the user has turned protection on.
            do {
                try await setManagerOnDemand(true, on: manager)
            } catch {
                #if DEBUG || LAVA_QA_TOOLS
                logVPNDebugEvent("enable-ondemand-enable-failed", details: errorDebugDetails(error))
                #endif
            }

            configuration.protectionEnabled = true
            // Notification authorization is requested only at the onboarding
            // notifications step (requestProtectionNotificationAuthorizationForOnboarding)
            // and, contextually, the first time a protection notification is
            // actually delivered. Enabling/restoring protection must NOT prompt
            // for notifications as a side effect — doing so surfaced the system
            // dialog at the wrong moment (e.g. during onboarding before the
            // notifications step, or on auto-restore at launch).
            try? await persistSharedState(preparedSnapshot: preparedSnapshot, rewritesRuleArtifacts: false)
            vpnMessage = nil
            vpnMessageIsError = false
            scheduleBackgroundCustomBlocklistRefresh()

            #if DEBUG
            logVPNDebugEvent("enable-finished", details: tunnelManagerDebugDetails(manager))
            #endif
            actionStatus = "connected"
        } catch {
            actionStatus = "error"
            endProtectionVPNSession()
            configuration.protectionEnabled = false
            vpnMessage = Self.vpnErrorMessage(prefix: "Could not start protection", error: error)
            vpnMessageIsError = true
            await refreshProtectionStatus(force: true)
            if playsOutcomeHaptic {
                playProtectionStartFailedHaptic()
            }

            #if DEBUG
            logVPNDebugEvent("enable-error", details: errorDebugDetails(error))
            #endif
        }
    }

    private func disableProtection(operationID: LatencyOperationID = .make()) async {
        let trace = makeLatencyTrace(operationID: operationID, operationKind: "turnOff")
        let span = trace.beginSpan("action.turnOff", details: [
            "vpnStatus": vpnStatusDebugDescription(vpnStatus)
        ])
        var actionStatus = "started"
        defer {
            span.end(details: ["status": actionStatus, "vpnStatus": vpnStatusDebugDescription(vpnStatus)])
        }

        vpnMessage = "Stopping local protection..."
        vpnMessageIsError = false

        // Set when the normal stop did not complete and we had to delete the VPN
        // profile to restore connectivity (see forceRemoveStuckProtectionProfile).
        var stoppedViaProfileRemoval = false

        do {
            let manager: NETunnelProviderManager?
            if let tunnelManager {
                manager = tunnelManager
            } else {
                manager = try await loadExistingTunnelManager()
            }

            if manager != nil {
                endProtectionVPNSession()
            }

            // Disable Connect-On-Demand and persist it before stopping, or iOS
            // would immediately reconnect the tunnel and the user could not turn
            // protection off. A failed disable is exactly what wedges turn-off,
            // so retry briefly (disableOnDemandWithRetry) rather than swallowing
            // the first error; a persistent failure still falls through to the
            // stop, backstopped by forceRemoveStuckProtectionProfile().
            if let manager {
                await disableOnDemandWithRetry(on: manager)
            }

            manager?.connection.stopVPNTunnel()
            updateProtectionStatus(from: manager)
            if manager == nil {
                endProtectionVPNSession()
                tunnelManager = nil
                vpnStatus = .disconnected
            } else if await waitForProtectionToStop() == false {
                // The tunnel never reached a stopped state. The usual cause is
                // that Connect-On-Demand could not be disabled above (that step
                // is best-effort), so iOS keeps reasserting the tunnel — and if
                // the provider has already exited, the device is left with a dead
                // tunnel, no working internet, and no in-app way out (UR-31/UR-32:
                // "couldn't connect to the internet and Lava wouldn't turn off
                // either, showing 'Couldn't stop protection'"). Last resort:
                // delete the VPN profile so its on-demand rules go away and
                // connectivity is restored. The profile (and the system VPN
                // permission prompt) is recreated next time protection is enabled.
                guard await forceRemoveStuckProtectionProfile() else {
                    throw LavaSecAppError.vpnStillStopping
                }
                stoppedViaProfileRemoval = true
            }
            lastProtectionStatusRefresh = Date()
            configuration.protectionEnabled = false
            appendAppNetworkActivity(.turnProtectionOff)
            vpnMessage = stoppedViaProfileRemoval ? Self.protectionForceStoppedMessage : nil
            vpnMessageIsError = false
            awaitsProtectionOnHaptic = false
            ProtectionHapticFeedback.play(.protectionTurnedOff)
            actionStatus = "stopped"
        } catch {
            actionStatus = "error"
            vpnMessage = Self.vpnErrorMessage(prefix: "Could not stop protection", error: error)
            vpnMessageIsError = true
        }
    }

    private func reconnectProtectionNow(playsOutcomeHaptic: Bool = true) async {
        #if DEBUG
        logVPNDebugEvent("reconnect-begin", details: [
            "vpnStatus": vpnStatusDebugDescription(vpnStatus),
            "networkKind": tunnelHealth.networkKind.rawValue,
            "lastFailureReason": tunnelHealth.lastFailureReason ?? "nil"
        ])
        #endif

        vpnMessage = "Reconnecting local protection..."
        vpnMessageIsError = false

        do {
            let manager: NETunnelProviderManager?
            if let tunnelManager {
                manager = tunnelManager
            } else {
                manager = try await loadExistingTunnelManager()
            }

            // Disable on-demand before the reset-stop so iOS does not reconnect
            // mid-wait (which would make waitForProtectionToStop time out);
            // enableProtection re-applies on-demand afterward.
            if let manager {
                await disableOnDemandWithRetry(on: manager)
            }
            manager?.connection.stopVPNTunnel()
            updateProtectionStatus(from: manager)
            guard await waitForProtectionToStop(timeout: Self.protectionRestartStopWaitTimeout) else {
                throw LavaSecAppError.vpnStillStopping
            }
            await enableProtection(logUserAction: false, playsOutcomeHaptic: playsOutcomeHaptic)

            #if DEBUG
            logVPNDebugEvent("reconnect-finished", details: [
                "vpnStatus": vpnStatusDebugDescription(vpnStatus)
            ])
            #endif
        } catch {
            vpnMessage = Self.vpnErrorMessage(prefix: "Could not reconnect protection", error: error)
            vpnMessageIsError = true
            if playsOutcomeHaptic {
                playProtectionStartFailedHaptic()
            }

            #if DEBUG
            logVPNDebugEvent("reconnect-error", details: errorDebugDetails(error))
            #endif
        }
    }

    @discardableResult
    // Wait behavior (deadlines, status polling, manager reloads while pending)
    // lives in VPNLifecycleController and is covered by behavior tests; these
    // wrappers keep published state current via the observation callback.
    private func waitForProtectionToConnect(timeout: TimeInterval = AppViewModel.protectionStartWaitTimeout) async -> Bool {
        await vpnLifecycleController.waitForConnect(timeout: timeout, initialManager: tunnelManager) { [weak self] manager in
            self?.tunnelManager = manager
            self?.updateProtectionStatus(from: manager)
        }
    }

    @discardableResult
    private func waitForProtectionToStop(timeout: TimeInterval = AppViewModel.protectionStopWaitTimeout) async -> Bool {
        await vpnLifecycleController.waitForStop(timeout: timeout, initialManager: tunnelManager) { [weak self] manager in
            self?.tunnelManager = manager
            self?.updateProtectionStatus(from: manager)
        }
    }

    static let protectionForceStoppedMessage =
        "Protection was force-stopped to restore your connection. You may need to allow the VPN again the next time you turn it on."

    /// Last-resort recovery for a turn-off that did not complete: deletes every
    /// matching tunnel profile so its Connect-On-Demand rules are removed and the
    /// device's internet path is restored, then resets local protection state.
    ///
    /// This exists because Connect-On-Demand is disabled best-effort before a
    /// stop; if that save fails (or the provider has already exited while the
    /// rules remain installed), iOS keeps reasserting a dead tunnel and the user
    /// is stranded offline with no way to turn protection off (UR-31/UR-32).
    /// Removing the profile is heavier than a normal stop — the system VPN
    /// permission is re-requested when protection is next enabled — but it is the
    /// only in-app action that reliably clears stuck on-demand rules.
    ///
    /// Returns `true` once no matching profile remains (including the case where
    /// the profile was already gone), `false` if removal itself failed.
    private func forceRemoveStuckProtectionProfile() async -> Bool {
        do {
            let managers = try await matchingTunnelManagers()
            for manager in managers {
                manager.connection.stopVPNTunnel()
                try await vpnLifecycleController.removeManager(manager)
            }
            // The profile (and its on-demand arming) is gone — drop the confirmed
            // signal so a later recreate can't inherit a stale `true`.
            Self.setOnDemandConfirmedEnabled(false)
            endProtectionVPNSession()
            tunnelManager = nil
            vpnStatus = .disconnected
            updateProtectionStatus(from: nil)
            return true
        } catch {
            #if DEBUG || LAVA_QA_TOOLS
            logVPNDebugEvent("turn-off-force-remove-failed", details: errorDebugDetails(error))
            #endif
            return false
        }
    }

    private func resumeTemporaryProtectionIfExpired(now: Date = Date()) async {
        guard let until = temporaryProtectionPauseUntil else {
            return
        }

        guard now >= until else {
            scheduleTemporaryProtectionResume()
            return
        }

        guard protectionActionOrchestrator.claim(.resume) else {
            return
        }

        await restoreFiltersAfterTemporaryProtectionPause(configurationAlreadyClaimed: true)
    }

    private func restoreFiltersAfterTemporaryProtectionPause(
        configurationAlreadyClaimed: Bool = false,
        operationID: LatencyOperationID = .make()
    ) async {
        if !configurationAlreadyClaimed {
            guard isProtectionTemporarilyPaused else {
                return
            }

            guard protectionActionOrchestrator.claim(.resume) else {
                return
            }
        }

        vpnMessage = "Resuming protection..."
        vpnMessageIsError = false
        defer {
            protectionActionOrchestrator.release(.resume)
        }

        let trace = makeLatencyTrace(operationID: operationID, operationKind: "resume")
        let span = trace.beginSpan("action.resume", details: [
            "vpnStatus": vpnStatusDebugDescription(vpnStatus)
        ])
        var actionStatus = "started"
        defer {
            span.end(details: ["status": actionStatus, "vpnStatus": vpnStatusDebugDescription(vpnStatus)])
        }

        do {
            try await LavaProtectionCommandService.perform(.resume, commandID: operationID.rawValue)
            loadTemporaryProtectionPause()
            await notifyTunnelProtectionPauseUpdated(operationID: operationID)
            let startup = try await preparedSnapshotForProtectionStartup()
            let preparedSnapshot = startup.preparedSnapshot
            if !startup.reusedPersistedArtifacts {
                // Only rewrite artifacts and reload the tunnel snapshot when the
                // resume actually produced different rules; the tunnel kept its
                // snapshot loaded during pause, so a reused snapshot needs no
                // reload (plan resume target: no restart, no rebuild).
                try await persistPreparedSnapshotArtifacts(preparedSnapshot)
                await notifyTunnelSnapshotUpdated(operationID: operationID)
            }
            vpnMessage = nil
            vpnMessageIsError = false
            actionStatus = "resumed"
        } catch {
            actionStatus = "error"
            vpnMessage = Self.vpnErrorMessage(prefix: "Resumed protection, but could not refresh filter", error: error)
            vpnMessageIsError = true
        }
    }

    private func clearTemporaryProtectionPause() {
        temporaryProtectionPauseUntil = nil
        pauseController.clear()
    }

    // Manager selection, save/reload, and duplicate cleanup live in
    // VPNLifecycleController (behavior-tested with fakes); these wrappers keep
    // the existing call sites stable.
    private func loadExistingTunnelManager() async throws -> NETunnelProviderManager? {
        try await vpnLifecycleController.loadExistingManager()
    }

    private func matchingTunnelManagers() async throws -> [NETunnelProviderManager] {
        try await vpnLifecycleController.matchingManagers()
    }

    private func loadOrCreateTunnelManager(existingManager: NETunnelProviderManager? = nil) async throws -> NETunnelProviderManager {
        try await vpnLifecycleController.loadOrCreateManager(existing: existingManager)
    }

    // Toggle Connect-On-Demand and persist it. Turn-off and the reconnect
    // reset-stop call this with `false` BEFORE stopVPNTunnel so iOS does not
    // immediately reconnect the tunnel; enableProtection re-applies on-demand
    // via applyConfiguration. Saving (not just setting) is required for iOS to
    // honor the change.
    private func setManagerOnDemand(_ enabled: Bool, on manager: NETunnelProviderManager) async throws {
        if enabled {
            let connectRule = NEOnDemandRuleConnect()
            connectRule.interfaceTypeMatch = .any
            manager.onDemandRules = [connectRule]
        }
        manager.isOnDemandEnabled = enabled
        // Invalidate the confirmed-armed signal up front, then re-assert it only
        // once the save is confirmed below. enableProtection swallows a
        // setManagerOnDemand(true) failure but still persists
        // protectionEnabled = true, so clearing first guarantees a swallowed save
        // failure can never leave a stale `true` from a previous profile — the
        // tunnel would otherwise self-cancel with no on-demand to recover it.
        Self.setOnDemandConfirmedEnabled(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        Self.setOnDemandConfirmedEnabled(enabled)
    }

    /// Records whether Connect-On-Demand is confirmed armed for the *current*
    /// profile, read by the tunnel to gate self-reconnect (a self-cancel only
    /// recovers if on-demand will bring the tunnel back). Cleared whenever the
    /// profile is removed or an arming save is in flight so the bit can't outlive
    /// the manager it describes.
    private static func setOnDemandConfirmedEnabled(_ enabled: Bool) {
        LavaSecAppGroup.sharedDefaults.set(
            enabled,
            forKey: LavaSecAppGroup.protectionOnDemandConfirmedEnabledDefaultsKey
        )
    }

    /// Seeds the confirmed-on-demand bit from a freshly loaded manager's actual
    /// `isOnDemandEnabled` only when it has never been written. This backfills the
    /// common upgrade/auto-start case — an existing profile whose protection is
    /// already running, where `setManagerOnDemand` never runs — so self-reconnect
    /// isn't suppressed until the user manually toggles protection. Once the bit
    /// exists, `setManagerOnDemand` owns it (seeding here would otherwise race a
    /// pre-clear during an in-flight arming save).
    private static func seedOnDemandConfirmedIfAbsent(from manager: NETunnelProviderManager) {
        guard LavaSecAppGroup.sharedDefaults.object(
            forKey: LavaSecAppGroup.protectionOnDemandConfirmedEnabledDefaultsKey
        ) == nil else {
            return
        }
        setOnDemandConfirmedEnabled(manager.isOnDemandEnabled)
    }

    private static let onDemandDisableRetryDelayNanoseconds: UInt64 = 200_000_000

    /// Disables Connect-On-Demand with a few retries before falling through.
    /// `saveToPreferences` can fail transiently (e.g. a racing configuration
    /// change), and a failed disable is precisely what wedges turn-off: iOS
    /// keeps reasserting the tunnel and, if the provider has already exited, the
    /// user is stranded offline with no way to stop protection (UR-31/UR-32).
    /// Retrying lets the common transient failure self-heal; a persistent
    /// failure still falls through to the stop, which is backstopped by
    /// forceRemoveStuckProtectionProfile(). Returns true once on-demand is
    /// confirmed disabled.
    @discardableResult
    private func disableOnDemandWithRetry(on manager: NETunnelProviderManager, attempts: Int = 3) async -> Bool {
        for attempt in 1...max(1, attempts) {
            do {
                try await setManagerOnDemand(false, on: manager)
                return true
            } catch {
                #if DEBUG || LAVA_QA_TOOLS
                logVPNDebugEvent("turn-off-ondemand-disable-failed", details: errorDebugDetails(error))
                #endif
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: Self.onDemandDisableRetryDelayNanoseconds)
                    // The common transient failure is a stale in-memory
                    // configuration: saveToPreferences rejects an out-of-date
                    // manager (NEVPNError.configurationStale). Reload it from
                    // on-disk preferences so the next attempt saves against the
                    // current configuration version — retrying the same stale
                    // object would just repeat the same failure.
                    try? await reloadManagerFromPreferences(manager)
                }
            }
        }
        return false
    }

    /// Refreshes an `NETunnelProviderManager` in place from on-disk preferences,
    /// so a subsequent save targets the current configuration version.
    private func reloadManagerFromPreferences(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func updateProtectionStatusFromCachedManager() {
        updateProtectionStatus(from: tunnelManager)
    }

    private func updateProtectionStatus(from manager: NETunnelProviderManager?) {
        let currentStatus = manager?.connection.status ?? .invalid
        let previousStatus = vpnStatus
        let isInstalled = manager != nil
        let installedStateChanged = isVPNConfigurationInstalled != isInstalled

        // Backfill the confirmed-on-demand signal for an already-installed profile
        // (upgrade / auto-start) the first time we observe its manager, so the
        // tunnel's self-reconnect isn't gated off until the user re-toggles.
        if let manager {
            Self.seedOnDemandConfirmedIfAbsent(from: manager)
        }

        // The status poll repeats with identical state; published properties only
        // change on real transitions so idle ticks stop invalidating SwiftUI.
        if installedStateChanged {
            isVPNConfigurationInstalled = isInstalled
        }
        if vpnStatus != currentStatus {
            vpnStatus = currentStatus
        }
        let protectionEnabled = isProtectionEnabledStatus(vpnStatus)
        if configuration.protectionEnabled != protectionEnabled {
            configuration.protectionEnabled = protectionEnabled
        }
        synchronizeLocalProtectionUptime(currentStatus: currentStatus)
        reconcileLiveActivity()
        playProtectionOnSucceededHapticIfNeeded(previousStatus: previousStatus, currentStatus: currentStatus)
        if previousStatus != .connected, currentStatus == .connected {
            appendNetworkActivity(.protectionConnected)
        }

        #if DEBUG
        // Idle status-updated heartbeats were half of all debug-log lines in the
        // device dumps; only transitions carry signal.
        if previousStatus != currentStatus || installedStateChanged {
            logVPNDebugEvent("status-updated", details: tunnelManagerDebugDetails(manager))
        }
        #endif
    }

    private func playProtectionOnSucceededHapticIfNeeded(previousStatus: NEVPNStatus, currentStatus: NEVPNStatus) {
        guard awaitsProtectionOnHaptic else {
            return
        }

        if currentStatus == .connected {
            awaitsProtectionOnHaptic = false
            if previousStatus != .connected {
                ProtectionHapticFeedback.play(.protectionOnSucceeded)
            }
        } else if [.invalid, .disconnected].contains(currentStatus),
                  [.connecting, .reasserting].contains(previousStatus) {
            playProtectionStartFailedHaptic()
        }
    }

    private func playProtectionStartFailedHaptic() {
        awaitsProtectionOnHaptic = false
        ProtectionHapticFeedback.play(.protectionStartFailed)
    }

    private func scheduleProtectionNotificationIfNeeded() {
        guard vpnStatus == .connected else {
            return
        }

        protectionUserNotifications.scheduleIfNeeded(
            assessment: protectionConnectivityAssessment,
            health: tunnelHealth
        )
    }

    private func appendAppNetworkActivity(_ action: NetworkActivityUserAction) {
        appendNetworkActivity(.userAction(action))
    }

    private func appendNetworkActivity(_ event: NetworkActivityEvent) {
        guard configuration.keepNetworkActivity else {
            return
        }

        guard let networkActivityLogURL else {
            return
        }

        let entry = NetworkActivityLogEntry(
            timestamp: Date(),
            event: event,
            lavaState: LavaStateSnapshot(
                protectionStatus: protectionTitle,
                connectivityStatus: protectionConnectivityAssessment.severity.diagnosticLabel,
                networkKind: tunnelHealth.networkKind,
                networkPathIsSatisfied: tunnelHealth.networkPathIsSatisfied,
                resolverDisplayName: configuration.resolverPreset.displayName,
                resolverTransport: tunnelHealth.lastResolverTransport,
                fallbackToDeviceDNS: configuration.fallbackToDeviceDNS,
                deviceDNSFallbackActive: protectionConnectivitySeverity == .usingDeviceDNSFallback
            )
        )
        NetworkActivityLogPersistence.append(entry, to: networkActivityLogURL)
        refreshNetworkActivityLog(force: true)
    }

    // Caches let the status poll skip per-tick disk decodes and defaults writes;
    // both stores reconcile on real transitions (and usage accrual is window-based,
    // so a coarser cadence credits the same uptime).
    private var lastObservedProtectionUptimeIsRunning: Bool?
    private var lastLavaGuardUsageIsRunning: Bool?
    private var lastLavaGuardUsageAccrualAt = Date.distantPast
    private static let lavaGuardUsageAccrualInterval: TimeInterval = 60

    private func synchronizeLocalProtectionUptime(currentStatus: NEVPNStatus) {
        synchronizeLavaGuardProgress(currentStatus: currentStatus)

        guard configuration.keepFilteringCounts else {
            return
        }

        guard let diagnosticsURL else {
            return
        }

        let isRunning = isLocalProtectionUptimeStatus(currentStatus)
        guard lastObservedProtectionUptimeIsRunning != isRunning else {
            return
        }

        var store = DiagnosticsPersistence.load(from: diagnosticsURL)
        lastObservedProtectionUptimeIsRunning = isRunning

        if isRunning {
            guard !store.isLocalProtectionUptimeActive else {
                diagnostics = store
                return
            }
            store.startLocalProtectionUptime()
        } else {
            guard store.isLocalProtectionUptimeActive else {
                diagnostics = store
                return
            }
            store.stopLocalProtectionUptime()
        }

        diagnostics = store
        try? DiagnosticsPersistence.save(store, to: diagnosticsURL)
    }

    private func synchronizeLavaGuardProgress(currentStatus: NEVPNStatus) {
        guard configuration.keepLavaGuardProgress else {
            return
        }

        let isRunning = isLocalProtectionUptimeStatus(currentStatus)
        let now = Date()
        let runningStateChanged = lastLavaGuardUsageIsRunning != isRunning
        guard runningStateChanged
            || now.timeIntervalSince(lastLavaGuardUsageAccrualAt) >= Self.lavaGuardUsageAccrualInterval
        else {
            return
        }
        lastLavaGuardUsageIsRunning = isRunning
        lastLavaGuardUsageAccrualAt = now

        var nextProgress = lavaGuardProgress
        var nextLedger = configuration.lavaGuardUnlocks
        nextProgress.synchronizeLocalProtectionUsage(
            isRunning: isRunning,
            ledger: &nextLedger
        )
        applyLavaGuardProgress(nextProgress, ledger: nextLedger)
    }

    private func refreshLavaGuardProgressFromDiagnostics() {
        guard configuration.keepLavaGuardProgress else {
            return
        }

        let usageDayKeys = diagnostics.localProtectionUsageDayKeys()
        guard !usageDayKeys.isEmpty else {
            return
        }

        var nextProgress = lavaGuardProgress
        var nextLedger = configuration.lavaGuardUnlocks
        nextProgress.replaceQualifiedUsageDayKeys(
            nextProgress.qualifiedUsageDayKeys.union(usageDayKeys),
            ledger: &nextLedger
        )
        applyLavaGuardProgress(nextProgress, ledger: nextLedger)
    }

    private func applyLavaGuardProgress(
        _ nextProgress: LavaGuardProgress,
        ledger nextLedger: LavaGuardAchievementLedger
    ) {
        let progressChanged = lavaGuardProgress != nextProgress
        let ledgerChanged = configuration.lavaGuardUnlocks != nextLedger

        guard progressChanged || ledgerChanged else {
            return
        }

        lavaGuardProgress = nextProgress
        if progressChanged {
            persistLavaGuardProgress()
        }

        if ledgerChanged {
            configuration.lavaGuardUnlocks = nextLedger
            do {
                try persistConfigurationOnly()
            } catch {
                vpnMessage = error.localizedDescription
                vpnMessageIsError = true
            }
        }
    }

    private func listSummary(count: Int, singular: String, plural: String, values: [String]) -> String {
        guard count > 0 else {
            return "Not configured yet"
        }

        let label = count == 1 ? singular : plural
        let visibleValues = values.prefix(2)
        let visibleText = visibleValues.joined(separator: ", ")

        if count > 2 {
            return "\(count) \(label): \(visibleText), +\(count - 2) more"
        }

        return "\(count) \(label): \(visibleText)"
    }

    private func applySyncResults(
        catalogResult: BlocklistCatalogSyncResult,
        customResult: CustomBlocklistSyncResult
    ) {
        updateCustomBlocklistHashes(customResult.sourceHashes)
        applyCatalogSyncResult(FilterSnapshotPreparationService.combinedCatalogResult(catalogResult: catalogResult, customResult: customResult))
        for sourceID in customResult.sourceRuleSets.keys {
            sourceStates[sourceID] = customResult.usedCachedSourceIDs.contains(sourceID) ? .nosync : .sync
        }
    }

    // Startup serves custom lists cache-first so protection is actionable
    // immediately; this refreshes them from the network afterwards and runs the
    // full refresh pipeline only when content actually changed.
    private func scheduleBackgroundCustomBlocklistRefresh() {
        // Free tier freezes custom-list contents: skip the post-turn-on network
        // refresh entirely, matching the cache-only prepare/sync paths. Otherwise a
        // lapsed-Plus user would re-fetch (and overwrite) their lists right after
        // protection connects.
        guard configuration.limits.allowsCustomBlocklists else {
            return
        }

        let customSources = enabledCustomBlocklists(in: configuration)
        guard !customSources.isEmpty, let service = filterSnapshotPreparationService else {
            return
        }

        Task(priority: .utility) { [weak self] in
            guard let refreshed = try? await service.refreshCustomBlocklists(customSources) else {
                return
            }

            guard let self else {
                return
            }

            let changed = customSources.contains { source in
                refreshed.sourceHashes[source.id] != source.lastAcceptedHash
            }
            guard changed else {
                return
            }

            #if DEBUG || LAVA_QA_TOOLS
            logVPNDebugEvent("custom-blocklists-changed-in-background")
            #endif
            await self.syncCatalog()
        }
    }

    private func enabledCustomBlocklists(in configuration: AppConfiguration) -> [CustomBlocklistSource] {
        configuration.customBlocklists.filter { source in
            configuration.enabledBlocklistIDs.contains(source.id)
        }
    }

    /// Per-source content fingerprint (id → cacheIdentity) for the enabled custom lists.
    /// `cacheIdentity` folds in the sourceURL, parse format, and lastAcceptedHash, so an
    /// inequality means the cached bytes a background sync loaded no longer describe the
    /// reloaded configuration. Used to fail-closed the background publish (see
    /// `publishBackgroundRefreshArtifacts`).
    private func enabledCustomBlocklistIdentities(in configuration: AppConfiguration) -> [String: String] {
        Dictionary(
            enabledCustomBlocklists(in: configuration).map { ($0.id, $0.cacheIdentity) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The content-addressed token of the currently-published filter artifact pointer, or
    /// nil if nothing is published yet. The background refresh captures this before syncing
    /// and re-checks it under the publish lock to detect a concurrent foreground publish
    /// (the catalog-rollback guard in `publishBackgroundRefreshArtifacts`).
    private func currentPublishedArtifactPointerToken() -> String? {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return nil
        }

        return FilterArtifactStore(directoryURL: containerURL).loadArtifactPointer()?.token
    }

    @discardableResult
    private func migrateLowRiskLaunchCacheIfNeeded(cacheURL: URL) -> Bool {
        // Only the launch-critical default-enabled sources gate a cache refresh.
        // Passing every curated (opt-in) source would force-purge latest.json for
        // any user whose cache predates a catalog expansion, bricking the offline
        // path when the re-fetch fails. Opt-in additions are picked up by the
        // normal catalog sync without a forced low-risk refresh.
        let changed = BlocklistCatalogSynchronizer.migrateLowRiskLaunchCacheIfNeeded(
            in: cacheURL,
            requiredSourceIDs: DefaultCatalog.recommendedDefaultSourceIDs
        )

        if changed {
            currentCatalog = nil
            catalogVersion = nil
            catalogGeneratedAt = nil
            catalogSourcesByID = [:]
        }

        return changed
    }

    private func updateCustomBlocklistHashes(_ hashes: [String: String]) {
        configuration = FilterSnapshotPreparationService.configuration(configuration, applyingCustomBlocklistHashes: hashes)
    }

    private func applyCatalogSyncResult(_ result: BlocklistCatalogSyncResult) {
        currentCatalog = result.catalog
        catalogVersion = result.catalog.catalogVersion
        catalogGeneratedAt = result.catalog.generatedAt
        catalogSourcesByID = Dictionary(uniqueKeysWithValues: result.catalog.sources.map { ($0.id, $0) })
        cachedBlockRuleSets = result.sourceRuleSets
        // Fresh per-source caches now describe the active filter, so any warm-switch rehydration this
        // would have been waiting on is satisfied (this is the chokepoint the warm rehydration, a cold
        // switch/restore/import/draft-apply, and every catalog sync all funnel through). Re-enable
        // in-place edits.
        hasPendingWarmSwitchCacheRehydration = false
        threatGuardrail = result.guardrailRuleSet

        for source in result.catalog.sources {
            sourceStates[source.id] = result.usedCachedSourceIDs.contains(source.id) ? .nosync : .sync
        }

        rebuildEnabledBlockRules()

        // The catalog just (re)applied — reconcile the non-active warm set against it: (re)warm any
        // filters now cold or stale so the instant-switch path survives catalog updates (incl. source
        // rotations under a pinned catalog_version). Fire-and-forget; the reconcile is a cheap
        // manifest-only scan that recompiles only the filters actually affected. FOREGROUND only: a
        // headless BGTask model loaded its library at launch, so warming (which writes lastCompiledToken
        // to filter-library.json) could clobber foreground create/edit/delete — the background-refresh-
        // never-writes-shared-state invariant. Headless warming is the Phase-2 BGTask's job, write-safe.
        if !isHeadless {
            Task { await reconcileWarmNonActiveFilters() }
        }
    }

    private func loadCachedCatalogAfterSyncFailure(
        cacheURL: URL,
        originalError: Error,
        operationID: LatencyOperationID
    ) async -> Bool {
        do {
            let enabledIDs = configuration.enabledBlocklistIDs
            let customSources = enabledCustomBlocklists(in: configuration)
            let result = try await Task.detached(priority: .utility) {
                let synchronizer = BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL)
                let catalogResult = try await synchronizer.loadCached(enabledSourceIDs: enabledIDs)
                let customResult = try await synchronizer.loadCachedCustomBlocklists(customSources)
                return (catalogResult, customResult)
            }.value

            applySyncResults(catalogResult: result.0, customResult: result.1)
            try await persistSharedState()
            await notifyTunnelSnapshotUpdated(operationID: operationID)

            catalogStatusMessage = "Using saved downloaded filter. Update failed: \(originalError.localizedDescription)"
            catalogStatusIsError = false
            return true
        } catch {
            catalogStatusMessage = "Could not update filter: \(originalError.localizedDescription)"
            catalogStatusIsError = true
            return false
        }
    }

    private func rebuildEnabledBlockRules() {
        let mergedBlocklistRules = FilterSnapshotPreparationService.mergedBlockRules(
            enabledSourceIDs: configuration.enabledBlocklistIDs,
            sourceRuleSets: cachedBlockRuleSets
        )
        var mergedRules = mergedBlocklistRules
        mergedRules.formUnion(configuration.manualBlockRuleSet)

        blockRules = mergedRules
        compiledBlocklistRuleCount = mergedBlocklistRules.count
        compiledRuleCount = mergedRules.count
        protectedRuleCount = mergedRules.effectiveBlockedDomainRuleCount(
            allowRules: configuration.allowRuleSet,
            nonAllowableThreatRules: configuration.nonAllowableRulesForAllowedDomains(from: threatGuardrail)
        )
    }

    private func refreshCompiledBlocklistRuleCount() {
        compiledBlocklistRuleCount = FilterSnapshotPreparationService.mergedBlockRules(
            enabledSourceIDs: configuration.enabledBlocklistIDs,
            sourceRuleSets: cachedBlockRuleSets
        ).count
    }

    private func estimatedBlocklistRuleCount(fromTotalRuleCount totalRuleCount: Int) -> Int {
        guard totalRuleCount > 0 else {
            return 0
        }

        return max(0, totalRuleCount - configuration.blockedDomains.count)
    }

    private func persistFilterChanges() {
        Task {
            do {
                try await persistSharedState()
                appendAppNetworkActivity(.changeFilters)
                await self.notifyTunnelSnapshotUpdated()
            } catch {
                vpnMessage = error.localizedDescription
                vpnMessageIsError = true
            }
        }
    }

    private func loadPersistedConfiguration() {
        if let configurationURL,
           let data = try? Data(contentsOf: configurationURL),
           let persistedConfiguration = try? JSONDecoder().decode(AppConfiguration.self, from: data) {
            configuration = persistedConfiguration
        }

        loadOrMigrateFilterLibrary()
    }

    /// Load the filter library, or (first launch on a multi-filter build, or a
    /// corrupt/empty file) migrate the legacy single-filter configuration into a
    /// one-filter "Default" library. Cheap and synchronous — an array-wrap, no parse
    /// or compile — so it is safe in the launch path next to `loadPersistedConfiguration`.
    ///
    /// The library is the source of truth: on load, the active filter's four fields are
    /// mirrored OUT of the library into `configuration` (a derived cache). This makes the
    /// persisted `activeFilterID` + active-filter contents recover together — a process
    /// kill between the library write and the config write is reconciled in the library's
    /// favour. Restore-safe because the backup payload now carries the whole library.
    private func loadOrMigrateFilterLibrary() {
        if let filterLibraryURL,
           let data = try? Data(contentsOf: filterLibraryURL),
           let persisted = try? JSONDecoder().decode(FilterLibrary.self, from: data) {
            let normalized = persisted.normalized()
            // Accept only an invariant-valid library (>=1 filter, active id resolves) that did NOT
            // lose a two-file write race: a library stamped with an OLDER config generation than the
            // config on disk is stale (e.g. a restore wrote a newer config but this library write
            // never landed), so we reject it and migrate from the durable config instead — keeping
            // the restored device-global config + active filter rather than reverting to the stale
            // library (Codex r20). A corrupt/empty/dangling file likewise falls through to migration.
            if normalized.isValid,
               normalized.schemaVersion >= FilterLibrary.currentSchemaVersion,
               !normalized.lostWriteRace(againstConfigurationGeneration: configuration.configurationGeneration) {
                library = normalized
                // The on-disk library was accepted as-is (no reseed): a headless background
                // publish may proceed against this config.
                didReseedFilterLibraryOnLastLoad = false
                // Library is authoritative — regenerate the active filter's mirror in
                // `configuration` from it (the inverse of the persist-boundary sync).
                mirrorActiveFilterIntoConfiguration()
                reconcileLoadedLibraryGenerationIfNeeded()
                return
            }
        }

        // No current (>= currentSchemaVersion), invariant-valid library that won the write race →
        // seed the three default filters (Core / Balanced / Extra) with Balanced loaded. This is
        // BOTH the first-launch seed and the on-upgrade migration: a pre-three-defaults library
        // (older schema) or a legacy single-filter config is replaced, so existing users move to
        // Balanced — a deliberate no-back-compat reset while the app is not yet public. Onboarding
        // re-seeds with the user's chosen level active when it runs on a fresh install.
        library = .seededDefaults(active: .balanced)
        // Flag the reseed so a headless background publish ABORTS: this mirrors Balanced into
        // the in-memory `configuration` below but the persist is foreground-only, so the
        // background model would otherwise build + publish Balanced artifacts while
        // app-configuration.json still describes the pre-upgrade filter — and the generation
        // guard would NOT catch it (no config was written, so the on-disk generation is
        // unchanged). The publish path checks this and bails until the foreground migration
        // lands (the user's next launch persists it, after which this stays false).
        didReseedFilterLibraryOnLastLoad = true
        mirrorActiveFilterIntoConfiguration()
        // Persist the migration only from a foreground instance. The headless
        // background-refresh model is read-only — writing here could race a foreground
        // upgrade/manage action and overwrite a just-created multi-filter library with a
        // singleton migration from this model's launch-time config. (The in-memory library
        // is still populated so the headless model can read it.)
        //
        // Persist via persistConfigurationOnly so the migration BUMPS the generation: a legacy config is
        // itself generation 0, so an un-bumped library write would stamp the freshly-migrated library
        // at generation 0 — the value lostWriteRace TRUSTS. A later config-first restore that's
        // killed before its library write would then leave this generation-0 file to win over the
        // restored config (Codex r23). persistConfigurationOnly bumps the generation first, so the
        // migrated library + config are written together at a non-zero generation that a future
        // restore can supersede. (Library-only edits now route here too — see persistFilterLibrary —
        // so every library write bumps the shared generation.) Suppress the backup hook: this runs during init before the
        // auto-backup flag is loaded, and a migration only adds the Default filter the server copy
        // already restores to (Codex r24) — the next real change re-seals + uploads.
        if !isHeadless {
            try? persistConfigurationOnly(schedulesAutomaticBackup: false)
        }
    }

    /// After accepting an on-disk library on load, bring the two files onto a single, NON-ZERO
    /// generation. Three cases need it (all one-time — the steady state is library.gen == config.gen
    /// > 0, which no-ops): the library won a write race so the config is stale (Codex r22); the
    /// library is at the generation-0 sentinel a legacy/pre-marker file decodes to (Codex r21); or
    /// both are still 0. In every case advance the in-memory generation to at least the library's so
    /// a headless background publish ABORTS against the unchanged on-disk generation, and — in the
    /// foreground — durably rewrite BOTH files at a bumped generation so a later restore can
    /// supersede this library instead of trusting a stale generation-0 stamp (Codex r23).
    private func reconcileLoadedLibraryGenerationIfNeeded() {
        guard library.configurationGeneration != configuration.configurationGeneration
            || library.configurationGeneration == 0 else {
            return
        }
        configuration.configurationGeneration = max(
            configuration.configurationGeneration,
            library.configurationGeneration
        )
        if !isHeadless {
            // Suppress the backup hook (launch-time, before the auto-backup flag is loaded). A
            // reconcile changes only the backup-stripped generation, so backed-up content is
            // unchanged anyway (Codex r24).
            try? persistConfigurationOnly(schedulesAutomaticBackup: false)
        }
    }

    private func persistDiagnostics() throws {
        guard let diagnosticsURL else {
            throw LavaSecAppError.appGroupUnavailable
        }

        try DiagnosticsPersistence.save(diagnostics, to: diagnosticsURL)
    }

    private func writeDiagnosticsClearControl(
        clearDomainHistory: Bool = false,
        clearFilteringCounts: Bool = false
    ) throws {
        guard let diagnosticsControlURL else {
            throw LavaSecAppError.appGroupUnavailable
        }

        let existingControl = DiagnosticsControlPersistence.load(from: diagnosticsControlURL)
        let now = Date()
        try DiagnosticsControlPersistence.save(
            DiagnosticsControl(
                clearDomainHistoryRequestedAt: clearDomainHistory ? now : existingControl.clearDomainHistoryRequestedAt,
                clearFilteringCountsRequestedAt: clearFilteringCounts ? now : existingControl.clearFilteringCountsRequestedAt
            ),
            to: diagnosticsControlURL
        )
    }

    // Encode and writes run inside FilterSnapshotPreparationService, off the
    // main actor (the encode + compact rebuild was measured at ~1.1s for large
    // rule sets); manifest-last ordering is owned by the service.
    @discardableResult
    private func persistPreparedSnapshotArtifacts(
        _ preparedSnapshot: PreparedFilterSnapshot,
        lockMode: FilterSnapshotPreparationService.PublishLockMode = .blocking,
        supersededWhileLocked: (@Sendable (_ currentPointerToken: String?) -> Bool)? = nil,
        commitBeforeFlip: (@Sendable () throws -> Void)? = nil
    ) async throws -> FilterSnapshotPreparationService.PublishOutcome {
        guard let containerURL = LavaSecAppGroup.containerURL,
              let service = filterSnapshotPreparationService
        else {
            throw LavaSecAppError.appGroupUnavailable
        }

        return try await service.persistArtifacts(
            preparedSnapshot,
            containerURL: containerURL,
            snapshotFilename: LavaSecAppGroup.snapshotFilename,
            compactSnapshotFilename: LavaSecAppGroup.compactSnapshotFilename,
            publishLockURL: containerURL.appendingPathComponent(LavaSecAppGroup.filterArtifactPublishLockFilename),
            lockMode: lockMode,
            supersededWhileLocked: supersededWhileLocked,
            commitBeforeFlip: commitBeforeFlip,
            // Keep every hosted filter's last-compiled directory alive so switching back
            // to a recently-used filter is an instant pointer flip, not a cold compile.
            additionalRetainedTokens: retainedFilterArtifactTokens()
        )
    }

    /// The versioned-artifact tokens to keep warm across a publish: EVERY non-frozen hosted
    /// filter's compiled token (active first, the most likely switch-back target). Keeping all
    /// of them warm makes switching to ANY filter — manually or via a Focus auto-switch — an
    /// instant pointer flip, never a cold compile. Frozen filters (lapsed Plus, not switchable)
    /// are excluded; the active filter's freshly-staged token is also retained by the publish
    /// itself. Disk is bounded by the tier filter cap (Free 3 / Plus 10); a disk-pressure
    /// escape hatch (LRU eviction) is a follow-on slice — see the LAV-100 plan.
    private func retainedFilterArtifactTokens() -> [String] {
        let activeID = library.activeFilterID
        var tokens: [String] = []
        if let activeToken = library.filter(id: activeID)?.lastCompiledToken {
            tokens.append(activeToken)
        }
        for filter in library.filters where filter.id != activeID {
            guard !isFilterFrozen(filter.id), let token = filter.lastCompiledToken else { continue }
            tokens.append(token)
        }
        // A background-warmed dir is referenced ONLY by the sidecar warm-index until the foreground
        // promotes it into the library, so retain those tokens too — otherwise the foreground GC would
        // reap a background-warmed artifact before it could be used or promoted (Phase 2). Retain ONLY
        // entries for filters that still exist and are switchable: the foreground doesn't rewrite the
        // sidecar on delete/freeze (background-only writer), so retaining every entry would pin dirs for
        // deleted/frozen filters until a later BGTask rewrites the sidecar (Codex #138 r5). The
        // background's own coherent rewrite already drops them; this keeps the foreground GC from
        // leaking them in the meantime.
        for (filterID, entry) in loadBackgroundWarmIndex().entries
        where library.filter(id: filterID) != nil && !isFilterFrozen(filterID) {
            tokens.append(entry.token)
        }
        return tokens
    }

    /// Compile and persist the on-disk artifact for a NON-active filter so it stays warm —
    /// a later switch (manual or, once wired, Focus-driven) is an instant pointer flip,
    /// never a cold compile. Builds the snapshot from THAT filter's four scoped fields over
    /// the current device-global config, stages its versioned artifact directory WITHOUT
    /// flipping the live (tunnel-facing) pointer, and records the filter's
    /// `lastCompiledToken`. Never touches the active configuration, the live pointer, the
    /// supersession generation, or the tunnel — so it is safe to run alongside the active
    /// switch/refresh paths. The active filter is excluded (it warms through
    /// `persistSharedState`). A filter is also skipped when it is frozen (not switchable),
    /// has custom blocklists (those refresh network-first on switch — a cache-only warm could
    /// stamp a token that warm-reuse later serves with stale custom bytes), or the catalog
    /// cache is STALE (warming cache-only from a stale catalog would stamp a token reused
    /// without a freshness recheck, running protection on old bytes; the filter instead takes
    /// the normal network-first refreshing cold path on its next switch). Best-effort: returns
    /// false on any of those, on failure, or if the filter was edited / removed / switched-to /
    /// frozen while compiling (the staged dir then ages out and a later warm pass retries).
    @discardableResult
    func warmFilterArtifact(forFilterID filterID: String) async -> Bool {
        // Foreground only: this writes filter-library.json (persistLibraryOnlyChange). A headless
        // BGTask model loaded its library at launch, so writing from it could clobber concurrent
        // foreground create/edit/delete changes — the "background refresh never writes shared state"
        // invariant. The background instead records into the sidecar warm-index
        // (warmNonActiveFiltersInBackground), never the library.
        guard !isHeadless,
              let result = await compileAndStageWarmArtifact(forFilterID: filterID) else {
            return false
        }

        // Stamp the token GC keeps warm and that switch-time reuse matches. compileAndStageWarmArtifact
        // already re-validated the filter (fields/active/frozen) and the catalog AFTER its compile, and
        // there is no await between its return and this stamp, so the filter is still the one we
        // compiled (mutateFilter is a no-op for a vanished id). Warmed filters are catalog-only, so
        // there are no custom-list hashes to reconcile.
        let previousLibrary = library
        library.mutateFilter(id: filterID) { $0.lastCompiledToken = result.token }
        let stamped = persistLibraryOnlyChange(rollingBackTo: previousLibrary)

        if stamped, let containerURL = LavaSecAppGroup.containerURL, let service = filterSnapshotPreparationService {
            // Reclaim the directory the PREVIOUS warm of this filter left behind. Each warm mints a
            // fresh generatedAt token and overwrites lastCompiledToken, and stageArtifacts never GCs,
            // so repeated warms (e.g. several draft saves without switching) would otherwise leak a
            // full artifact dir apiece until an unrelated publish collected them — breaking the
            // "disk bounded by the filter cap" invariant (Codex r14). Runs AFTER the stamp so the
            // retain set names the NEW token; the overwritten old token is no longer hosted and is
            // reaped. Retains every hosted filter's token + the live pointer; grace-window protected.
            await service.collectWarmArtifactGarbage(
                containerURL: containerURL,
                snapshotFilename: LavaSecAppGroup.snapshotFilename,
                compactSnapshotFilename: LavaSecAppGroup.compactSnapshotFilename,
                retaining: retainedFilterArtifactTokens()
            )
        }
        return stamped
    }

    /// Shared compile + stage + re-validate core for warming a NON-active filter, used by BOTH the
    /// foreground (`warmFilterArtifact` → stamps the library) and the background
    /// (`warmNonActiveFiltersInBackground` → records the sidecar). Compiles the filter's four scoped
    /// fields cache-only, stages the versioned artifact (no pointer flip), and re-validates AFTER the
    /// await — the filter's rules are byte-for-byte what we compiled, it is still non-active/non-frozen,
    /// and the catalog has not moved (canReuse) — so the returned token always names rules that match
    /// the filter's current config + the current cached catalog. Returns the staged token + its budget
    /// rule count, or nil on any miss. Records NOTHING and runs NO GC: gating on `isHeadless` and the
    /// write/GC belong to the caller. Never touches the live pointer, the active configuration, the
    /// supersession generation, or the tunnel, so it is safe alongside the active switch/refresh paths.
    private func compileAndStageWarmArtifact(forFilterID filterID: String) async -> (token: String, ruleCount: Int)? {
        guard let filter = library.filter(id: filterID),
              filterID != library.activeFilterID,
              !isFilterFrozen(filterID),
              // Catalog-only filters only: custom lists refresh network-first on switch, so a
              // cache-only warm of a custom-list filter could be reused with stale custom bytes.
              filter.customBlocklists.isEmpty,
              let cacheURL = catalogCacheURL,
              // Only warm from a FRESH catalog cache. A cache-only compile from a stale cache would
              // record a token reused WITHOUT a freshness recheck — running on old bytes until an
              // unrelated refresh. When stale, skip so the next switch takes the network-first cold path.
              BlocklistCatalogSynchronizer.hasFreshCachedCatalog(in: cacheURL, maxAge: catalogSyncFreshnessInterval),
              // Stay READ-ONLY w.r.t. the shared catalog cache: prepareFilterSnapshot runs
              // migrateLowRiskLaunchCacheIfNeeded, which can PURGE latest.json (legacy guardrails /
              // inactive GPL / missing required launch sources) expecting a follow-up SYNC a cache-only
              // warm never does — leaving NO cached catalog until a later sync, breaking offline
              // startup/warm reuse (Codex r15). Skip when a migration is pending; synchronous so
              // prepareFilterSnapshot's own (now no-op) migrate can't race in before it.
              !BlocklistCatalogSynchronizer.cachedCatalogRequiresLowRiskLaunchRefresh(
                  in: cacheURL,
                  requiredSourceIDs: DefaultCatalog.recommendedDefaultSourceIDs
              ),
              let containerURL = LavaSecAppGroup.containerURL,
              let service = filterSnapshotPreparationService else {
            return nil
        }

        // Capture the exact fields we compile so a concurrent edit/switch during the (awaiting)
        // compile can't make us record a token onto stale rules.
        let compiledEnabled = filter.enabledBlocklistIDs
        let compiledCustom = filter.customBlocklists
        let compiledBlocked = filter.blockedDomains
        let compiledAllowed = filter.allowedDomains

        var snapshotConfiguration = configuration
        snapshotConfiguration.enabledBlocklistIDs = compiledEnabled
        snapshotConfiguration.customBlocklists = compiledCustom
        snapshotConfiguration.blockedDomains = compiledBlocked
        snapshotConfiguration.allowedDomains = compiledAllowed

        do {
            // Compile against the CURRENT cache only — a warm must never trigger a catalog/custom sync
            // that advances latest.json under a concurrent switch's warm-reuse guard (a cache miss
            // just skips this warm). Freshness is the refresh path's job.
            let prepared = try await prepareFilterSnapshot(
                for: snapshotConfiguration,
                customListPolicy: .cacheOnly,
                catalogCacheOnly: true
            )
            // If the BGTask deadline passed during the (CPU-heavy) compile above, bail BEFORE staging —
            // stageArtifacts writes a versioned directory to the app group, which must not happen past
            // the system deadline (Codex #138 r3). Harmless in the foreground (its warm task is not
            // deadline-cancelled). The caller's per-iteration + pre-save guards cover the later steps.
            if Task.isCancelled { return nil }
            let pointer = try await service.stageArtifacts(
                prepared.snapshot,
                containerURL: containerURL,
                snapshotFilename: LavaSecAppGroup.snapshotFilename,
                compactSnapshotFilename: LavaSecAppGroup.compactSnapshotFilename
            )

            // Re-validate after the compile await: the filter may have been edited, deleted,
            // switched-to (now active), or frozen while we were off compiling. Only keep the token if
            // the filter still exists, is still non-active/non-frozen, and its rules are byte-for-byte
            // what we compiled — otherwise the staged dir is for stale rules and a later warm pass
            // (or a switch-time cold compile) supersedes it.
            guard let current = library.filter(id: filterID),
                  filterID != library.activeFilterID,
                  !isFilterFrozen(filterID),
                  current.enabledBlocklistIDs == compiledEnabled,
                  current.customBlocklists == compiledCustom,
                  current.blockedDomains == compiledBlocked,
                  current.allowedDomains == compiledAllowed else {
                return nil
            }

            // Also re-validate the CATALOG. A sync that advanced latest.json while we were suspended in
            // prepare/stage would leave this artifact built from the PREVIOUS catalog; warm reuse
            // validates against the current cached catalog by per-source hashes, so it would later
            // reject the token and the filter would look warm yet cold-compile on its next switch. Keep
            // only a token reuse will actually honor NOW, using the SAME check the switch reuse path
            // applies (canReuseForProtectionStartup against the freshly re-read cached catalog). On a
            // mismatch, return nil so the racing sync's reconcile — or a later switch — recompiles
            // against the new catalog (Codex r12). The re-read runs off the main actor (small JSON
            // decode), mirroring loadReusableWarmSnapshotForSwitch.
            let recheckCacheURL = cacheURL
            let currentCachedCatalog = await Task.detached(priority: .userInitiated) {
                try? BlocklistCatalogSynchronizer(cacheDirectoryURL: recheckCacheURL).loadCachedCatalogMetadata()
            }.value
            guard let currentCachedCatalog,
                  prepared.snapshot.canReuseForProtectionStartup(
                      configuration: snapshotConfiguration,
                      cachedCatalog: currentCachedCatalog
                  ) else {
                return nil
            }

            let ruleCount = prepared.snapshot.summary.tierBudgetRuleCount
                ?? prepared.snapshot.summary.blocklistRuleCount
                ?? 0
            return (pointer.token, ruleCount)
        } catch {
            return nil
        }
    }

    /// After a catalog (re)apply, bring the non-active warm set back in line with the catalog:
    /// (re)warm filters that are COLD (no token — e.g. created/edited while the cache was stale, when
    /// `warmFilterArtifact` skipped them) OR STALE (their artifact was built against older source
    /// bytes, so a switch's warm-reuse gate would reject it and cold-compile, losing the instant
    /// switch). Staleness is decided PER FILTER by the SAME cheap manifest check the switch path uses
    /// (`reuseRejectionReason`, off the main actor, no full compile) — which keys on the per-SOURCE
    /// content hashes, so it catches a source rotation even when the top-level `catalog_version`
    /// stays pinned (a plain version compare would miss that, so this deliberately does NOT debounce
    /// on the version). Only filters actually affected recompile; a no-op cache-hit apply just does
    /// the cheap manifest reads. The BACKGROUND BGTask refresh (priority-ordered/capped, for when the
    /// app isn't active) is the Phase-2 follow-up.
    private func reconcileWarmNonActiveFilters() async {
        // Coalesce overlapping runs (foreground fires this on onAppear AND scene .active, plus after a catalog
        // apply): a concurrent second pass would redundantly re-scan + double-compile the same cold filters.
        // But do NOT simply drop a trigger that arrives mid-pass — a catalog apply landing while a pass is in
        // flight must still re-warm against the new catalog, or the non-active filters stay stale and a
        // closed-app Focus switch to them defers-to-cold (Codex P2). Queue a single rerun instead, mirroring
        // reconcilePendingFilterSwitch.
        guard !isReconcilingWarmNonActiveFilters else {
            pendingWarmReconcileRerun = true
            return
        }
        isReconcilingWarmNonActiveFilters = true
        defer { isReconcilingWarmNonActiveFilters = false }
        // Bound the synchronous drain to the initial pass + one rerun (same storm guard as the pending-switch
        // reconcile) so a burst of triggers can't monopolize this run; a rerun still queued at the cap is
        // re-dispatched fresh on the next tick (the defer has cleared the guard by then).
        var remainingWarmPasses = 2
        repeat {
            remainingWarmPasses -= 1
            pendingWarmReconcileRerun = false
            await reconcileWarmNonActiveFiltersOnce()
        } while pendingWarmReconcileRerun && remainingWarmPasses > 0
        if pendingWarmReconcileRerun {
            Task { @MainActor [weak self] in await self?.reconcileWarmNonActiveFilters() }
        }
    }

    /// One pass of the non-active warm reconcile. The wrapper `reconcileWarmNonActiveFilters` serializes +
    /// re-runs this; the early returns here end the PASS, not the loop.
    private func reconcileWarmNonActiveFiltersOnce() async {
        guard let containerURL = LavaSecAppGroup.containerURL else { return }

        // Snapshot the candidates on the main actor (catalog-only, non-active, non-frozen), each with
        // the configuration its artifact identity is validated against.
        let activeID = library.activeFilterID
        let baseConfiguration = configuration
        let candidates: [(id: String, token: String?, configuration: AppConfiguration)] =
            library.filters.compactMap { filter in
                guard filter.id != activeID, !isFilterFrozen(filter.id), filter.customBlocklists.isEmpty else {
                    return nil
                }
                var cfg = baseConfiguration
                cfg.enabledBlocklistIDs = filter.enabledBlocklistIDs
                cfg.customBlocklists = filter.customBlocklists
                cfg.blockedDomains = filter.blockedDomains
                cfg.allowedDomains = filter.allowedDomains
                return (filter.id, filter.lastCompiledToken, cfg)
            }
        guard !candidates.isEmpty else { return }
        let cacheURL = catalogCacheURL
        // Snapshot the sidecar so a cold/stale LIBRARY filter that the BACKGROUND already warmed can be
        // PROMOTED (a cheap library token write) instead of recompiled from scratch (Phase 2).
        let warmIndex = loadBackgroundWarmIndex()

        // Decide per filter OFF the main actor (manifest + catalog-metadata reads), mirroring
        // loadReusableWarmSnapshotForSwitch — cheap (no full prepared decode, no compile). For each
        // candidate: keep (library token still valid → omit), promote (a sidecar token is valid →
        // carry it), or recompile (neither valid → promoteToken == nil).
        let actions: [(id: String, promoteToken: String?, configuration: AppConfiguration)] =
            await Task.detached(priority: .utility) {
                let cachedCatalog = cacheURL.flatMap {
                    try? BlocklistCatalogSynchronizer(cacheDirectoryURL: $0).loadCachedCatalogMetadata()
                }
                let rootStore = FilterArtifactStore(directoryURL: containerURL)
                func isValid(_ token: String, _ configuration: AppConfiguration) -> Bool {
                    let store = FilterArtifactStore(directoryURL: rootStore.versionedDirectoryURL(token: token))
                    guard let manifest = try? store.loadManifest() else { return false }
                    return manifest.reuseRejectionReason(configuration: configuration, cachedCatalog: cachedCatalog) == nil
                }
                return candidates.compactMap { candidate in
                    if let token = candidate.token, isValid(token, candidate.configuration) {
                        return nil // library token still valid ⇒ keep
                    }
                    if let sideToken = warmIndex.token(forFilterID: candidate.id), isValid(sideToken, candidate.configuration) {
                        return (candidate.id, sideToken, candidate.configuration) // promote the background's work
                    }
                    return (candidate.id, nil, candidate.configuration) // recompile
                }
            }.value

        // Apply on the main actor. Promote is a library-only token write (the artifact dir already
        // exists from the background); recompile goes through warmFilterArtifact. Both re-validate the
        // filter's current fields/active/frozen state before committing, and the switch path re-checks
        // catalog freshness at reuse time, so a catalog move mid-reconcile self-heals via the next apply.
        for action in actions {
            if let token = action.promoteToken {
                promoteWarmTokenIntoLibrary(filterID: action.id, token: token, expectedConfiguration: action.configuration)
            } else {
                await warmFilterArtifact(forFilterID: action.id)
            }
        }
    }

    /// Promote a sidecar (background-warmed) token into `filter-library.json` so the library becomes
    /// the source of truth again and the switch path reuses it directly. A foreground-only library
    /// write (the BGTask never writes the library). Re-validates on the main actor that the filter
    /// still exists, is non-active/non-frozen, and its four scoped fields are unchanged since the
    /// off-main scan — so a concurrent edit can't promote a token for stale rules. Catalog freshness
    /// is re-checked at switch time, so promotion itself needs no fresh-catalog recheck.
    @discardableResult
    private func promoteWarmTokenIntoLibrary(
        filterID: String,
        token: String,
        expectedConfiguration: AppConfiguration
    ) -> Bool {
        guard let current = library.filter(id: filterID),
              filterID != library.activeFilterID,
              !isFilterFrozen(filterID),
              current.enabledBlocklistIDs == expectedConfiguration.enabledBlocklistIDs,
              current.customBlocklists == expectedConfiguration.customBlocklists,
              current.blockedDomains == expectedConfiguration.blockedDomains,
              current.allowedDomains == expectedConfiguration.allowedDomains else {
            return false
        }
        guard current.lastCompiledToken != token else { return true } // already promoted
        let previousLibrary = library
        library.mutateFilter(id: filterID) { $0.lastCompiledToken = token }
        return persistLibraryOnlyChange(rollingBackTo: previousLibrary)
    }

    /// Background (BGTask) warm pass. With the active filter just republished and the cache fresh, warm
    /// the NON-active filters too so a later Focus-driven switch is an instant pointer-flip. Headless-
    /// safe: it records each warmed filter in the SIDECAR warm-index, NEVER in filter-library.json
    /// (which the background must not write). Capped per run at the free-tier rule ceiling and ordered
    /// most-stale-first (by the sidecar's last `syncedAt`; never-warmed sorts first) so a tight BGTask
    /// budget spends on the filters most out of date; the rest are picked up on later runs. Rewrites the
    /// sidecar coherently each run: this run's fresh entries plus carry-over of prior entries for
    /// filters still eligible that we did not re-warm, dropping entries for filters that are gone, now
    /// active/frozen, or already warm in the library (i.e. promoted). One GC after the loop.
    /// Cheap PRE-compile UPPER-BOUND estimate of a non-active filter's rule count, summed from the
    /// catalog's per-source entry counts plus the filter's own blocked/allowed domains. Used to enforce
    /// the background per-run budget before the expensive compile (Codex #138 r4). It is only an upper
    /// bound: overlapping sources are NOT deduplicated, so it can OVER-count (the actual compiled count
    /// is ≤ this and ≤ the tier cap). Callers must therefore cap it at the budget and guarantee the
    /// coldest candidate one attempt, or an over-counted filter would be starved (panel finding). An
    /// unknown source falls back to its cached rule-set size, else 0.
    private func estimatedRuleCount(forFilterID filterID: String) -> Int {
        guard let filter = library.filter(id: filterID) else { return 0 }
        var total = filter.blockedDomains.count + filter.allowedDomains.count
        for id in filter.enabledBlocklistIDs {
            total += catalogSourcesByID[id]?.entryCount ?? cachedBlockRuleSets[id]?.count ?? 0
        }
        return total
    }

    private func warmNonActiveFiltersInBackground() async {
        // Sidecar warming is the BGTask's job; the foreground warms via the library path
        // (warmFilterArtifact). This also keeps the library strictly foreground-owned.
        guard isHeadless,
              let containerURL = LavaSecAppGroup.containerURL,
              let cacheURL = catalogCacheURL,
              let store = backgroundWarmIndexStore,
              let service = filterSnapshotPreparationService else {
            return
        }
        // Honor the BGTask deadline up front: cancellation can be delivered at the caller's `await`
        // into this method, and the candidates/empty-candidates prefix below is synchronous, so without
        // this guard the empty-candidates branch could still rewrite the sidecar past the deadline
        // (panel finding). Every app-group mutation in this method stays behind a !Task.isCancelled gate.
        guard !Task.isCancelled else { return }

        // This runs only on the bg-published path, where the background just COMMITTED the fresh catalog
        // to latest.json — so its mtime is already fresh and compileAndStageWarmArtifact's
        // hasFreshCachedCatalog gate passes without any touch. (We deliberately do NOT bump the mtime
        // here: latest.json is only trustworthy-current on a commit, and a commit already refreshes it.)
        let activeID = library.activeFilterID
        let prior = store.load()

        // Snapshot eligible candidates (non-active, non-frozen, catalog-only) with the config their
        // artifact identity is validated against, on the main actor.
        let baseConfiguration = configuration
        let candidates: [(id: String, token: String?, configuration: AppConfiguration)] =
            library.filters.compactMap { filter in
                guard filter.id != activeID, !isFilterFrozen(filter.id), filter.customBlocklists.isEmpty else {
                    return nil
                }
                var cfg = baseConfiguration
                cfg.enabledBlocklistIDs = filter.enabledBlocklistIDs
                cfg.customBlocklists = filter.customBlocklists
                cfg.blockedDomains = filter.blockedDomains
                cfg.allowedDomains = filter.allowedDomains
                return (filter.id, filter.lastCompiledToken, cfg)
            }
        guard !candidates.isEmpty else {
            // No eligible filters: still rewrite the sidecar to drop any now-ineligible entries.
            try? store.save(BackgroundWarmIndex())
            return
        }

        // Classify each eligible candidate OFF the main actor by whether its LIBRARY token and/or its
        // SIDECAR token are still valid for the current catalog (the same manifest check the switch path
        // uses). A filter needs (re)warming only when NEITHER is valid — keying on the sidecar too means
        // the background doesn't recompile a filter it (a prior run) already warmed every single run,
        // and a mis-estimated oversized filter overshoots the budget at most ONCE rather than on every
        // run (Codex #138 r8).
        let scan: [(id: String, libraryValid: Bool, sidecarValid: Bool)] = await Task.detached(priority: .utility) {
            let cachedCatalog = (try? BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL).loadCachedCatalogMetadata())
            let rootStore = FilterArtifactStore(directoryURL: containerURL)
            func tokenValid(_ token: String?, _ configuration: AppConfiguration) -> Bool {
                guard let token else { return false }
                let store = FilterArtifactStore(directoryURL: rootStore.versionedDirectoryURL(token: token))
                guard let manifest = try? store.loadManifest() else { return false }
                return manifest.reuseRejectionReason(configuration: configuration, cachedCatalog: cachedCatalog) == nil
            }
            return candidates.map { candidate in
                (candidate.id,
                 tokenValid(candidate.token, candidate.configuration),
                 tokenValid(prior.token(forFilterID: candidate.id), candidate.configuration))
            }
        }.value

        // To COMPILE: neither token valid (cold or stale in both stores), most-stale-first by the
        // sidecar's last syncedAt (never-warmed ⇒ .distantPast ⇒ coldest, warmed first).
        let needsWarming: [String] = scan
            .filter { !$0.libraryValid && !$0.sidecarValid }
            .sorted { (prior.syncedAt(forFilterID: $0.id) ?? .distantPast) < (prior.syncedAt(forFilterID: $1.id) ?? .distantPast) }
            .map(\.id)
        // Carry-over base: every filter whose LIBRARY token is invalid keeps its prior sidecar entry
        // (it's still the best warm we have) unless replaced this run — including those skipped from
        // warming because their SIDECAR token is already valid. Filters with a valid library token are
        // excluded, so they're dropped (the library owns them).
        let invalidLibraryIDs = Set(scan.filter { !$0.libraryValid }.map(\.id))

        // Warm capped + most-stale-first, recording each in the new sidecar. Respect the BGTask
        // deadline (Task.isCancelled) and the per-run rule budget. The budget is enforced BEFORE the
        // expensive compile via a cheap pre-estimate — for EVERY candidate including the first — so one
        // oversized filter (a Plus filter can be up to 2M rules) can never blow the cap on a
        // deadline-bounded BGTask (Codex #138 r6). Skip (don't break) a filter that wouldn't fit the
        // remaining budget so a smaller later one can still use it. A filter whose estimate alone
        // exceeds the budget is therefore never background-warmed — the foreground reconcile (which has
        // no per-run cap) warms it instead, so it isn't starved.
        // Size the per-run budget to the user's ACTUAL tier, not the free ceiling: this warm substrate
        // exists for the Plus-only Focus auto-switch, so measuring a Plus filter (cap 2M) against the
        // free 500K ceiling would skip every legitimately-large filter on every run — it would never
        // background-warm, defeating the feature for exactly the filters it targets (panel finding P2).
        let perRunRuleBudget = configuration.limits.maxFilterRules
        var newEntries: [String: BackgroundWarmIndexEntry] = [:]
        var rulesCompiled = 0
        let warmedAt = Date()
        for id in needsWarming {
            if Task.isCancelled { break }
            // Cap the (overlap-inflated, dedup-free) estimate at the budget. A filter's ACTUAL compiled
            // count can't exceed the tier cap == budget, so min(estimate, budget) is still a valid upper
            // bound — and it guarantees the FIRST candidate of a run always fits (rulesCompiled 0 + ≤budget
            // is never > budget), so a heavy-overlap filter whose raw sum exceeds the budget isn't starved
            // forever in the background; the post-compile break still bounds the run (panel finding P2).
            if rulesCompiled + min(estimatedRuleCount(forFilterID: id), perRunRuleBudget) > perRunRuleBudget {
                continue
            }
            guard let result = await compileAndStageWarmArtifact(forFilterID: id) else { continue }
            newEntries[id] = BackgroundWarmIndexEntry(token: result.token, syncedAt: warmedAt)
            rulesCompiled += result.ruleCount
            // The pre-estimate can UNDER-estimate (a cached source's local payload rotated beyond the
            // catalog entryCount), letting an actually-over-budget filter through. Stop once the ACTUAL
            // accumulated rules reach the cap so a single underestimated filter can't drag the run into
            // compiling more past it (Codex #138 r8). The just-compiled filter is still recorded — its
            // work is done and it's a valid warm; we simply don't start another compile.
            if rulesCompiled >= perRunRuleBudget { break }
        }

        // If the BGTask deadline passed mid-pass, do NOT mutate the app-group further — skip the sidecar
        // rewrite and GC so nothing runs past the system deadline (Codex #138 r2). Any artifacts staged
        // this run are grace-window-protected and reaped by a later run's GC, so skipping leaks nothing.
        guard !Task.isCancelled else { return }

        // Coherent wholesale rewrite: this run's fresh entries + carry-over of prior entries for every
        // filter whose LIBRARY token is invalid (it still relies on the sidecar) that we did NOT replace
        // this run. Keying carry-over on `invalidLibraryIDs` (NOT `needsWarming`) is essential now that
        // `needsWarming` excludes filters with an already-valid SIDECAR token: those skipped-but-warm
        // filters must keep their prior entry, and a stale-library-token filter not reached this run
        // (cap) keeps its still-usable warm rather than being dropped and then GC'd (Codex #138). Filters
        // with a VALID library token are excluded (dropped — the library owns them); gone/active/frozen
        // filters never entered the scan. Carry-overs aren't re-validated — the read path re-checks every
        // token, so a stale carry-over is harmless and self-heals next run.
        let warmedThisRun = Set(newEntries.keys)
        var rewritten = newEntries
        for id in invalidLibraryIDs where !warmedThisRun.contains(id) {
            if let carried = prior.entries[id] { rewritten[id] = carried }
        }
        try? store.save(BackgroundWarmIndex(entries: rewritten))

        // Re-check the deadline immediately before the GC: collectWarmArtifactGarbage is an `await` into
        // the preparation actor (a suspension point), so a cancellation that lands between the post-loop
        // guard above and here would otherwise let the GC removeItem app-group directories past the
        // system deadline (panel finding — the TOCTOU the staging/save guards already close elsewhere).
        guard !Task.isCancelled else { return }

        // One GC after the loop: retain (in-memory library + just-written sidecar + live pointer) UNION
        // the CURRENT on-disk library tokens. The on-disk union is essential here: a foreground
        // create/edit/warm during this (potentially slow) headless pass writes tokens our launch-time
        // in-memory snapshot doesn't have, and once that foreground-staged dir ages out of the grace
        // window the GC would otherwise reap a dir the live library references (Codex #138 r7).
        // grace-window protected for very recent stages on top of that.
        let retain = retainedFilterArtifactTokens() + persistedLibraryArtifactTokens()
        await service.collectWarmArtifactGarbage(
            containerURL: containerURL,
            snapshotFilename: LavaSecAppGroup.snapshotFilename,
            compactSnapshotFilename: LavaSecAppGroup.compactSnapshotFilename,
            retaining: retain
        )
    }

    // MARK: - Focus auto-switch coordination (LAV-100 Phase 3)

    // `HeadlessFocusSwitchOutcome` was relocated to LavaSecCore with the headless switch engine
    // (LAV-100 Phase 4). The foreground reconcile + the non-active warm-keep helper below STAY here.

    /// Foreground-only: keep the non-active filters — including the seeded defaults (Core/Balanced/Extra) —
    /// WARM whenever the app comes to the foreground, so a closed-app Focus switch to any of them can commit
    /// instantly (warm) instead of deferring to a foreground cold-compile. `reconcileWarmNonActiveFilters` is
    /// a cheap manifest-only scan that recompiles ONLY filters that are actually cold or stale, so running it
    /// on every activation is near-free in the steady state (everything already warm ⇒ no work, no writes).
    /// This complements the existing after-catalog-apply warm pass; together they ensure the defaults are
    /// warm after install + on every open, not only right after a catalog refresh.
    func warmNonActiveFiltersOnAppForeground() {
        guard !isHeadless else { return }
        Task { await reconcileWarmNonActiveFilters() }
    }

    /// Publish a lightweight "the app is in the foreground RIGHT NOW" flag to the shared app-group defaults,
    /// read by the App Intents extension to gate the Focus-switch notification to closed/backgrounded only
    /// (a foreground app shows the switch in-UI, so a banner would be redundant). Set true on scene .active
    /// / onAppear, false on .background. NOT the removed `AppForegroundActivityState` switch-defer machinery
    /// — this has no stale window and never affects a switch; a wrong read just shows/suppresses one banner.
    func setAppForegroundActive(_ active: Bool) {
        guard !isHeadless else { return }
        LavaSecAppGroup.sharedDefaults.set(active, forKey: LavaSecAppGroup.appForegroundActiveDefaultsKey)
    }

    /// Foreground-only: apply any pending Focus switch recorded by the headless path. Run on appear, on
    /// becoming active, and on the headless wake nudge. The pending-switch marker is the feature's
    /// correctness guarantee: this is the single place that CLEARS it, and only after confirming the
    /// target is active (headless committed it) or applying the switch through the normal foreground
    /// path (which cold-compiles if no warm artifact exists). Compare-and-clear so a newer Focus request
    /// recorded meanwhile is never dropped.
    func reconcilePendingFilterSwitch() async {
        guard !isHeadless else { return }
        // Re-entrancy guard: the three wake triggers (onAppear, scene .active, Darwin nudge) could
        // otherwise both read the same marker and launch duplicate switchToFilter attempts (the
        // replacement gate makes the loser bail, but it still does redundant work). One drives a marker
        // at a time — but a trigger that arrives while a run is in flight sets pendingReconcileRerun so
        // the in-flight run loops once more, instead of stranding a newer marker (recorded during a slow
        // cold-compile apply) until the next scene-phase event (Codex P2).
        guard !isReconcilingPendingFilterSwitch else {
            pendingReconcileRerun = true
            return
        }
        isReconcilingPendingFilterSwitch = true
        defer { isReconcilingPendingFilterSwitch = false }
        // Bound each SYNCHRONOUS drain to the initial pass + one re-run (mirrors the protection-status refresh
        // loop's storm guard), so a rapid Focus-toggle burst can't monopolize this run in one unbroken
        // sequence. Cap at 2 ("loops once more", above — Codex round-16 audit).
        var remainingReconcilePasses = 2
        repeat {
            remainingReconcilePasses -= 1
            pendingReconcileRerun = false
            await applyPendingFilterSwitchOnce()
        } while pendingReconcileRerun && remainingReconcilePasses > 0
        // Hitting the cap with a re-run STILL queued means a newer marker landed during the final pass and
        // its Darwin nudge was already consumed by the re-entrancy guard above — so do NOT drop it (that would
        // strand the newest durable marker, leaving an active foreground app on the previous filter until a
        // later scene/Focus event). Re-dispatch a FRESH reconcile on the next runloop tick: the defer has reset
        // the guard by the time it runs, so it re-enters cleanly and drains the queue, while the per-run cap
        // keeps any single synchronous burst bounded (Codex round-17). Best-effort promptness only — the
        // durable marker stays the correctness guarantee, so even if the app backgrounds before this Task runs
        // the next onAppear/.active reconcile applies it.
        if pendingReconcileRerun {
            Task { @MainActor [weak self] in await self?.reconcilePendingFilterSwitch() }
        }
    }

    /// One pass of the pending-switch reconcile. The wrapper `reconcilePendingFilterSwitch` serializes +
    /// re-runs this; the early returns here end the PASS, not the loop.
    private func applyPendingFilterSwitchOnce() async {
        let defaults = LavaSecAppGroup.sharedDefaults
        guard let request = PendingFilterSwitchStore.current(in: defaults) else { return }

        // Re-check the SAME fail-closed SECURITY gate the headless record path enforces. Focus auto-switch is
        // available to all tiers (the Plus paywall was dropped), but a marker recorded while editing was
        // unprotected must NOT apply if filter editing has since become auth-protected — an unattended switch
        // would otherwise bypass the auth-to-edit boundary (the record-time gate alone does not survive a gate
        // change between record and reconcile). Gate now closed ⇒ the request is moot; drop it. Invariant: a
        // disallowed switch must not happen now or on a later reconcile.
        guard !SecurityProtectedSurfaceStorage.isProtected(.filterEditing, defaults: defaults) else {
            PendingFilterSwitchStore.clearIfMatches(request, in: defaults, lockURL: pendingFilterSwitchMarkerLockURL)
            return
        }

        // ADOPT a cross-process commit before deciding (LAV-100). The App Intents extension commits the switch
        // to DISK; a resident app that was SUSPENDED in the background couldn't receive the post-commit Darwin
        // nudge, so its in-memory (configuration, library) is STALE. Without re-reading disk here, the
        // already-active check below compares the marker against a stale `activeFilterID`, misses that the
        // extension already applied the switch WARM on disk, and falls through to `switchToFilter` — which then
        // cold-compiles (its warm-reuse reads the in-memory `lastCompiledToken`, but the extension stamped the
        // token on disk) and shows the recompile sheet on return to foreground. Reloading lets the already-active
        // branch recognize the committed switch and just re-notify+clear (a pointer the tunnel poll already
        // adopted, or adopts within its interval). GATED so it's a no-op on the common path: only when the
        // on-disk generation is NEWER than ours (another process wrote since we loaded), and NOT while a user
        // switch is in flight — that path owns the in-memory state and the reconcile defers to it below.
        if !isForegroundManualSwitchInFlight,
           let configurationURL, let filterLibraryURL, let containerURL = LavaSecAppGroup.containerURL,
           SharedFilterStatePersistence.onDiskConfigurationGeneration(at: configurationURL) > configuration.configurationGeneration {
            // A newer on-disk commit exists (the App Intents extension wrote config/library while this resident
            // app was suspended — its post-commit Darwin nudge couldn't reach a suspended run loop). Adopt it
            // ONLY if the headless commit COMPLETED: the extension flips the artifact pointer LAST, so require
            // the live pointer to name the on-disk active filter's compiled artifact. If it's mid-commit (the
            // config-leads-pointer window, which may still roll back via the in-lock catalog/failure path),
            // DEFER — `return`, do NOT fall through to the switchToFilter path below, which would race the
            // extension's in-flight commit and cold-recompile (Codex P2). The kept marker + the next reconcile
            // (the post-flip nudge) adopt it cleanly once it lands; a rollback leaves config+pointer consistent
            // and the active-change gate below no-ops it.
            guard let pointerToken = FilterArtifactStore(directoryURL: containerURL).loadArtifactPointer()?.token,
                  SharedFilterStatePersistence.onDiskActiveFilterCompiledToken(at: filterLibraryURL) == pointerToken
            else {
                return
            }
            // Re-read disk to adopt the committed switch into the stale in-memory (configuration, library).
            let previousActiveID = library.activeFilterID
            // Capture BEFORE the reload (mirrors switchToFilter): whether protection should be re-established.
            let shouldRestoreProtection = configuration.protectionEnabled || isProtectionEnabledStatus(vpnStatus)
            loadPersistedConfiguration()
            // RE-VALIDATE completeness AFTER the reload (closes the check-then-reload TOCTOU, Codex P2): a
            // back-to-back commit C can land between the pre-check above and this reload, so
            // loadPersistedConfiguration could pick up an in-flight C whose pointer hasn't flipped. If the
            // reloaded active filter's artifact is no longer the one the live pointer names, disk is mid-commit
            // — DEFER (keep the marker, return) so the tail / already-active branch never act on a switch that
            // may still roll back; a later reconcile re-evaluates once the flip lands. The kept marker + the
            // next reconcile re-read heal the (transient) in-memory state if that commit rolls back.
            guard library.filter(id: library.activeFilterID)?.lastCompiledToken
                    == FilterArtifactStore(directoryURL: containerURL).loadArtifactPointer()?.token else {
                return
            }
            // Only when the adopt ACTUALLY moved the active filter (Codex P2: a bare generation bump that left
            // the active filter unchanged — the extension's catalog-moved/failed-commit ROLLBACK — must be a
            // no-op so the rehydration flag isn't set spuriously and left stuck). Run the FULL warm-switch tail
            // (not a piecemeal patch): without it the already-active branch below would cold-recompile / the
            // app would consume stale blockRules on an immediate edit (Codex found 4 such gaps on the partial
            // version). The extension already persisted + flipped the pointer, so this is the TAIL only.
            if library.activeFilterID != previousActiveID {
                let adoptToken = configurationReplacementGate.begin()
                await applyCommittedOnDiskActiveFilter(adoptToken: adoptToken, shouldRestoreProtection: shouldRestoreProtection)
            }
        }

        // A foreground switch INITIATED after this Focus request was recorded is the user's newer explicit
        // choice and wins — drop the stale marker rather than reverting their manual switch. The stamp is
        // the switch's INITIATION instant (not its completion), so a Focus request that fired DURING a slow
        // manual switch — i.e. after the user started it — still wins over that switch (Codex round-15).
        // Exact tie (`<=`): an identical instant intentionally favors the MANUAL switch (the user's explicit
        // action outranks the automation), and is the safe direction anyway — a wrongly-dropped Focus marker
        // is re-recorded by the next Focus edge, whereas a wrongly-KEPT one would silently revert the user
        // (founder review P2-3).
        if let lastForegroundSwitchAt = PendingFilterSwitchStore.lastForegroundSwitch(in: defaults),
           request.requestedAt <= lastForegroundSwitchAt {
            PendingFilterSwitchStore.clearIfMatches(request, in: defaults, lockURL: pendingFilterSwitchMarkerLockURL)
            return
        }

        // Target gone or frozen (deleted, or Plus-cap froze it) ⇒ the request is moot; clear it.
        guard library.filter(id: request.targetFilterID) != nil, !isFilterFrozen(request.targetFilterID) else {
            PendingFilterSwitchStore.clearIfMatches(request, in: defaults, lockURL: pendingFilterSwitchMarkerLockURL)
            return
        }
        // Already active: a headless immediate commit applied this switch (or a manual switch did). A
        // headless commit could NOT schedule the encrypted-backup upload (its model never loaded the
        // backup state), so schedule it here on the foreground — which HAS the backup state loaded — so
        // an auto-backup user's Focus-driven config change is re-sealed + uploaded rather than waiting
        // for the next foreground edit (Codex P2). Safe to call even if a concurrent foreground switch to the
        // same target also schedules: scheduleAutomaticBackupAfterConfigurationChange CANCELS-AND-REPLACES the
        // single debounced automaticBackupTask and content-gates its re-seal, so overlapping calls coalesce to
        // one upload rather than double-firing (founder review P2-2). Then clear the (now-applied) marker.
        guard request.targetFilterID != library.activeFilterID else {
            scheduleAutomaticBackupAfterConfigurationChange()
            // Re-notify the tunnel BEFORE clearing: disk shows the target active, but the running tunnel may
            // still hold the OLD in-memory snapshot if the headless commit's notify was killed (App Intent
            // terminated after persistSharedState) or swallowed a send error. Clearing without this would
            // remove the only retry path until an unrelated update / VPN restart (Codex round-10). Idempotent
            // when the tunnel already has it (a lock-free pointer re-read); a no-op when protection is off.
            // This brings the already-active branch to parity with the foreground switch path, which always
            // notifies after a commit; if the notify itself fails, the same reconnect fallback applies.
            //
            // We re-notify only (no republish): a *partial* headless commit — process TERMINATED inside
            // persistSharedState after the config/library pair-write but before the latest.json pointer flip —
            // is NOT repaired here, and intentionally so. That residual is closed MARKER-INDEPENDENTLY by
            // reconcileTunnelSnapshotAfterLaunch(), which on every cold launch with protection active
            // re-prepares the on-disk active filter and re-persists with rewritesRuleArtifacts when the
            // persisted artifact doesn't match — flipping a stale pointer out of fail-closed (it exists for
            // exactly this "tunnel fail-closed at launch" class). A Swift task suspended at that await simply
            // RESUMES and completes the flip (only true termination loses it → next launch is cold → heals),
            // and the token dir is content-addressed (identical compiled rules ⇒ same dir ⇒ pointer was never
            // stale). So adding a republish here would churn the frozen warm path for an already-covered,
            // fail-closed-safe case (Codex round-15 finding B — verified not reachable as a persistent state).
            await notifyTunnelSnapshotUpdated()
            PendingFilterSwitchStore.clearIfMatches(request, in: defaults, lockURL: pendingFilterSwitchMarkerLockURL)
            return
        }
        // Do NOT supersede an IN-FLIGHT user-initiated switch (round-18): it claimed the replacement gate
        // first but hasn't stamped lastForegroundSwitch yet (the stamp lands only on success), so the stale
        // check above couldn't see it. Applying here would begin a NEWER gate epoch and make the user's
        // in-flight manual switch bail as superseded — letting this (older) Focus request wrongly win. Defer:
        // KEEP the marker; that switch's completion re-dispatches a reconcile (switchToFilter's defer), which
        // re-evaluates with lastForegroundSwitch now stamped — dropping this marker if the manual switch was
        // newer, or applying it if it is genuinely newer than the manual switch.
        guard !isForegroundManualSwitchInFlight else {
            logFocusSwitchEvent("reconcile-deferred-manual-switch-in-flight", details: ["filterID": request.targetFilterID])
            return
        }
        // Apply through the normal foreground switch (puts up the preparation cover, cold-compiles on a
        // warm miss; for a resident foreground re-syncing an already-committed headless switch it's a fast
        // warm pointer-flip). stampsForegroundSwitch: false — this is replaying a Focus automation, NOT a
        // user-initiated switch, so it must not poison the lastForegroundSwitch supersession timestamp and
        // suppress a newer Focus request recorded during this (possibly slow) apply.
        // Log every reconcile-driven apply so a transient failure that keeps re-recording (Focus re-fires,
        // each cold-compile fails) surfaces as a repeating reconcile-apply for the same filter in QA dumps.
        // switchToFilter shows its own failure screen; the marker is cleared after the attempt either way.
        logFocusSwitchEvent("reconcile-apply", details: ["filterID": request.targetFilterID])
        await switchToFilter(id: request.targetFilterID, stampsForegroundSwitch: false)
        // Clear the marker ONLY if the switch actually took effect. switchToFilter returns Void and LEAVES
        // the active filter unchanged on a preparation/publish failure (a cold-compile network blip, a
        // transient catalog miss) while showing its own failure screen. Clearing unconditionally would
        // silently DROP the user's Focus automation with no retry (Codex round-8). Keeping the marker on
        // failure lets the next foreground — or a Focus re-fire — retry until it succeeds. (A permanent
        // failure therefore re-shows the cover each foreground; a visible, actionable degradation, strictly
        // better than a silent drop, and the failure screen still offers manual retry.) The compare-and-clear
        // below still protects a NEWER marker recorded during this apply.
        guard library.activeFilterID == request.targetFilterID else {
            logFocusSwitchEvent("reconcile-apply-failed-kept-marker", details: ["filterID": request.targetFilterID])
            return
        }
        PendingFilterSwitchStore.clearIfMatches(request, in: defaults, lockURL: pendingFilterSwitchMarkerLockURL)
    }

    /// Adopt — in the RESIDENT foreground app — a Focus switch the App Intents extension already committed to
    /// disk (config + library written, artifact pointer flipped) while the app was suspended. This runs the
    /// post-commit TAIL of a warm switch ONLY: the caller has already `loadPersistedConfiguration()`'d the new
    /// (config, library) from disk and begun the replacement epoch (`adoptToken`); there is NO prepare/compile,
    /// NO `persistSharedState` (the extension already persisted + flipped — re-persisting would churn the warm
    /// path), and NO `lastForegroundSwitch` stamp (this is not a user-initiated foreground switch — stamping
    /// would wrongly out-rank a genuine later manual switch). It deliberately does NOT touch the preparation UI
    /// cover or play a haptic — the adopt is SILENT (no recompile sheet), which is the whole point.
    ///
    /// Why a shared tail (not a piecemeal patch of the already-active branch): `loadPersistedConfiguration`
    /// moved config/library, but `blockRules`/`threatGuardrail`/`cachedBlockRuleSets`/sourceStates/counts still
    /// describe the PREVIOUS filter. Applying the on-disk filter's warm snapshot SYNCHRONOUSLY here sets
    /// blockRules + the full threatGuardrail in one main-actor pass, eliminating the stale window an immediate
    /// allowlist/blocklist edit would otherwise serialize into a wrong-rules publish (Codex found 4 such gaps
    /// closing them one at a time).
    private func applyCommittedOnDiskActiveFilter(adoptToken: Int, shouldRestoreProtection: Bool) async {
        let adoptedFilterID = library.activeFilterID
        // Re-validate the adopted target exists + is switchable (a concurrent edit/delete could have landed).
        guard let target = library.filter(id: adoptedFilterID), !isFilterFrozen(adoptedFilterID) else { return }

        // Apply the adopted filter's warm snapshot from disk (the extension already published this token's
        // dir + flipped the pointer to it). Loads by the now-on-disk `lastCompiledToken`. A concurrent newer
        // switch during the async load supersedes us — bail without clobbering its state.
        if let reusable = await warmReusableSnapshotForSwitch(target: target, configuration: configuration),
           configurationReplacementGate.isCurrent(adoptToken),
           library.activeFilterID == adoptedFilterID {
            // Guard against a catalog refresh that landed DURING the async warm load: applying a snapshot
            // validated against the PRE-refresh catalog would roll currentCatalog/blockRules BACK over the
            // active filter the refresh just rebuilt + published. Mirrors switchToFilter's
            // catalogMovedDuringPersist check (Codex P2). On a move, skip the apply — the rehydration below
            // (its syncCatalog fallback) heals to the fresh catalog.
            let catalogMovedDuringLoad = currentCatalog.map {
                !reusable.preparedSnapshot.identity.snapshotInputMismatches(
                    against: PreparedFilterSnapshotIdentity.make(configuration: configuration, catalog: $0)
                ).isEmpty
            } ?? false
            if !catalogMovedDuringLoad {
                applyReusablePreparedSnapshot(reusable)
            }
        }
        guard configurationReplacementGate.isCurrent(adoptToken) else { return }

        // The per-source caches (cachedBlockRuleSets) are still the previous filter's even after the snapshot
        // apply (applyReusablePreparedSnapshot doesn't populate them) — defer in-place edits + rehydrate in the
        // background, exactly like a warm switchToFilter. applyCatalogSyncResult clears the flag once fresh
        // caches land; the rehydration's syncCatalog fallback self-heals if the warm load above failed.
        hasPendingWarmSwitchCacheRehydration = true
        Task { [weak self] in
            await self?.rehydrateRuleSetCachesAfterWarmSwitch(switchToken: adoptToken, filterID: adoptedFilterID)
        }

        // Drop any non-active detail target so the detail accessors fall back to the now-active filter (else
        // saving its draft would go through the library-only saveNonActiveFilterDraft and never publish).
        filterEditTargetID = nil
        pendingSwitchFilterID = nil

        appendAppNetworkActivity(.changeFilters)
        await notifyTunnelSnapshotUpdated()
        await restoreProtectionIfNeeded(wasEnabled: shouldRestoreProtection)
        scheduleAutomaticBackupAfterConfigurationChange()
    }

    // The headless Focus warm-switch orchestration (FocusWarmSwitchCatalogMovedError,
    // nudgeForegroundReconcile, performHeadlessFocusFilterSwitch, warmSnapshotStillReusableAgainstCachedCatalog)
    // was relocated to LavaSecCore.HeadlessFocusFilterSwitchEngine (LAV-100 Phase 4) so it can run in the
    // App Intents extension with no AppViewModel. The foreground reconcile + persist paths below STAY here.

    @discardableResult
    private func persistSharedState(
        preparedSnapshot: PreparedFilterSnapshot? = nil,
        rewritesRuleArtifacts: Bool = true,
        prioritizesConfigurationDurability: Bool = false,
        schedulesAutomaticBackup: Bool = true,
        // Optional in-lock veto, evaluated immediately BEFORE the artifact pointer flip (inside the held
        // publish lock). The foreground passes nil — its warm→cold rebind already guarantees a
        // current-basis snapshot — so its behavior is byte-identical. The headless warm switch passes a
        // catalog-basis re-check here so a background refresh that committed a newer catalog after the
        // off-lock revalidation can't be out-raced into flipping a stale-basis warm artifact (Codex round-16).
        //
        // SCOPE: commitBeforeFlip is honored ONLY when `didRewriteArtifacts` (below) is true — i.e. it is
        // co-gated with the artifact pointer FLIP it guards. There is no flip without didRewriteArtifacts, so
        // the veto's reachability is exactly the flip's: it can never be silently skipped while a flip still
        // happens. For the headless commit, didRewriteArtifacts is true because the off-lock
        // `canReuseForProtectionStartup` gate already requires the warm snapshot to COVER the target's enabled
        // blocklists (so `coversEnabledBlocklists` holds). A caller that relies on the in-lock veto must
        // therefore also rewrite artifacts (i.e. actually flip); a config-only persist neither flips nor needs
        // the veto (founder review P2-1).
        commitBeforeFlip: (@Sendable () throws -> Void)? = nil
    ) async throws -> FilterSnapshotPreparationService.PublishOutcome {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            throw LavaSecAppError.appGroupUnavailable
        }

        // rewritesRuleArtifacts is false when the snapshot was just reused from
        // the on-disk artifacts (identical bytes) or when only configuration
        // state changed: re-encoding the prepared JSON and rebuilding the
        // compact artifact were measured as the bulk of warm turn-on cost.
        let snapshotToPersist = preparedSnapshot ?? preparedSnapshotForCurrentConfiguration()
        let didRewriteArtifacts = rewritesRuleArtifacts
            && snapshotToPersist.summary.coversEnabledBlocklists(in: configuration)

        // Keep the library's active filter in lockstep with the configuration we're
        // persisting (the only two writers of app-configuration.json funnel through here
        // and persistConfigurationOnly), and record the compiled token (deterministic) so
        // GC keeps this filter's compiled directory warm. The artifact publish happens
        // AFTER the config write (below) per the config-leads-pointer ordering; a token
        // recorded for an as-yet-unpublished dir simply forces a recompile on next use.
        syncActiveFilterFromConfiguration()
        if didRewriteArtifacts {
            let token = FilterArtifactStore.versionedToken(for: snapshotToPersist)
            library.mutateFilter(id: library.activeFilterID) { $0.lastCompiledToken = token }
        }

        // Bump the supersession token + write filter-library.json and configuration.json atomically in
        // the fail-safe order, BEFORE flipping the artifact pointer below (config leads the pointer so a
        // concurrent background publish reads the already-advanced generation and degrade-aborts; the
        // brief config-leads-pointer window is fail-closed — a reader sees an under-covering artifact and
        // cold-rebuilds, never wrong rules). The ordering + generation-token + library-stamp logic lives
        // in the single shared writer (SharedFilterStatePersistence) so the foreground and the headless
        // warm switch can never drift; sync the bumped/stamped values back into the published state.
        let written = try SharedFilterStatePersistence.writeConfigurationAndLibrary(
            configuration: configuration,
            library: library,
            configurationURL: containerURL.appendingPathComponent(LavaSecAppGroup.configurationFilename),
            filterLibraryURL: containerURL.appendingPathComponent(LavaSecAppGroup.filterLibraryFilename),
            prioritizesConfigurationDurability: prioritizesConfigurationDurability,
            // Cross-process CAS: serialize against the App Intents extension's commit (LAV-100 Phase 4 P4c).
            crossProcessLockURL: containerURL.appendingPathComponent(LavaSecAppGroup.configurationWriteLockFilename)
        )
        configuration = written.configuration
        library = written.library
        // Suppressed for the headless warm switch: that model skips loadAutomaticBackupPreference /
        // loadEncryptedBackupState, so its isAutomaticBackupEnabled is the default false and touching the
        // backup envelope here would mishandle it (same hazard as the launch-time persists). The
        // foreground reconcile re-seals + schedules the upload for the committed change instead.
        if schedulesAutomaticBackup {
            scheduleAutomaticBackupAfterConfigurationChange()
        }

        // The artifact-publish outcome of the flip below. `.published` for a config-only persist (no flip,
        // so never superseded); the flip path overwrites it. Surfaced to the foreground switch caller so an
        // `.abortedSuperseded` (a concurrent cross-process Focus commit won the active-filter race) is treated
        // as a deferred, non-winning switch rather than a false success (Codex review, lavasec-ios#29).
        var publishOutcome = FilterSnapshotPreparationService.PublishOutcome.published
        if didRewriteArtifacts {
            // Reciprocal flip fence (Codex P1, state-agnostic switch). The cross-process WRITE lock above is
            // released before persistPreparedSnapshotArtifacts takes the artifact PUBLISH lock, so the App
            // Intents extension can commit + flip a NEWER switch in that gap. Before flipping our pointer,
            // confirm the on-disk selection is STILL the filter this staged artifact is for; if a newer write
            // changed the active filter (a concurrent Focus commit), ABORT the flip rather than overwriting the
            // newer pointer with our stale-basis artifact — which would leave app-configuration.json selecting
            // the Focus target while the live pointer named our snapshot. The pending-switch marker then drives
            // the foreground reconcile to apply the newer selection. The extension's commit has the symmetric
            // in-flip fence; this closes the reverse interleaving. We compare the ACTIVE FILTER (not the raw
            // generation) so a concurrent library-only bump that KEPT our filter active (a warm-token promote,
            // which has no marker to recover an aborted flip) does NOT needlessly abort us. A nil read (just
            // wrote the library atomically) is treated as not-superseded — never abort on an uncertain read.
            let flipTargetFilterID = library.activeFilterID
            let filterLibraryURL = containerURL.appendingPathComponent(LavaSecAppGroup.filterLibraryFilename)
            publishOutcome = try await persistPreparedSnapshotArtifacts(
                snapshotToPersist,
                supersededWhileLocked: { @Sendable _ in
                    guard let onDiskActive = SharedFilterStatePersistence.onDiskActiveFilterID(at: filterLibraryURL)
                    else { return false }
                    return onDiskActive != flipTargetFilterID
                },
                commitBeforeFlip: commitBeforeFlip
            )
        }
        return publishOutcome
    }

    /// Persist the live configuration + library at a freshly-bumped generation.
    ///
    /// `schedulesAutomaticBackup` is false ONLY for the launch-time generation-bump persists
    /// (migration / `reconcileLoadedLibraryGenerationIfNeeded`): those run during `init`, before
    /// `isAutomaticBackupEnabled` and the encrypted-backup state are loaded, so the re-seal would
    /// clear the upload marker but see the default `isAutomaticBackupEnabled == false` and never
    /// schedule the upload — leaving an auto-backup user's backup looking un-uploaded until a later
    /// edit (Codex r24). Suppressing the backup hook there is safe: a migration only adds the single
    /// Default filter the server's pre-multi-filter payload already restores to, and a reconcile
    /// changes only the (backup-stripped) generation, so neither alters backed-up content — the next
    /// real user change re-seals and uploads normally.
    private func persistConfigurationOnly(schedulesAutomaticBackup: Bool = true) throws {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            throw LavaSecAppError.appGroupUnavailable
        }

        syncActiveFilterFromConfiguration()

        // Bump the generation + write library (source of truth) then config, via the single shared
        // writer (see SharedFilterStatePersistence) so the ordering + generation token can't drift from
        // persistSharedState / the headless switch. Sync the bumped/stamped values back into state.
        let written = try SharedFilterStatePersistence.writeConfigurationAndLibrary(
            configuration: configuration,
            library: library,
            configurationURL: containerURL.appendingPathComponent(LavaSecAppGroup.configurationFilename),
            filterLibraryURL: containerURL.appendingPathComponent(LavaSecAppGroup.filterLibraryFilename),
            // Cross-process CAS: serialize against the App Intents extension's commit (LAV-100 Phase 4 P4c).
            crossProcessLockURL: containerURL.appendingPathComponent(LavaSecAppGroup.configurationWriteLockFilename)
        )
        configuration = written.configuration
        library = written.library
        if schedulesAutomaticBackup {
            scheduleAutomaticBackupAfterConfigurationChange()
        }
    }

    /// Write-through the active filter's four fields from the live `configuration`.
    /// Runs at the persistence boundary so the library's copy of the active filter
    /// never drifts from what's being saved to `app-configuration.json`. If the
    /// contents changed, any cached compile token is now stale, so clear it.
    private func syncActiveFilterFromConfiguration() {
        // The active id should always resolve (normalized on load + invariant-preserving
        // mutations), but repair a dangling id rather than silently skipping the sync —
        // a skipped sync would drift the config and the library apart permanently.
        if library.filter(id: library.activeFilterID) == nil {
            library = library.normalized()
        }
        guard var filter = library.filter(id: library.activeFilterID) else { return }
        // Only publish a library change when the four fields actually moved — a no-op
        // persist (the common case for device-global edits) must not churn @Published.
        guard filter.applyFilterFields(from: configuration) else { return }
        filter.lastCompiledToken = nil
        library.update(filter)
    }

    /// Regenerate the live `configuration`'s four filter-scoped fields from the active
    /// filter (the inverse of `syncActiveFilterFromConfiguration`). Used on load and after
    /// any change to which filter is active — the library is the source of truth, and the
    /// device-global fields on `configuration` are left untouched.
    private func mirrorActiveFilterIntoConfiguration() {
        let active = library.activeFilter
        configuration.enabledBlocklistIDs = active.enabledBlocklistIDs
        configuration.customBlocklists = active.customBlocklists
        configuration.blockedDomains = active.blockedDomains
        configuration.allowedDomains = active.allowedDomains
    }

    /// Persist a LIBRARY-ONLY edit (rename / delete / create / warm-token promote — no active-filter or
    /// device-global change). This ADVANCES the shared (config, library) generation via the pair writer.
    ///
    /// It MUST bump the generation, not write the library alone at the current generation: the Focus switch
    /// is now state-agnostic (LAV-100 Phase 4), so the App Intents extension can commit a (config, library)
    /// pair concurrently while the app is foreground. The extension's stale-reader fence (`rejectsAdvancedBeyond`)
    /// watches only the on-disk CONFIG generation — so a library write that left the config generation
    /// unbumped would NOT trip it, and the extension would overwrite this edit with the stale library snapshot
    /// it loaded before the lock (Codex P1: a just-created filter lost / a just-deleted filter resurrected, made
    /// permanent if the app is terminated before the resident in-memory library re-persists). Routing through
    /// `persistConfigurationOnly` bumps the generation so the extension's commit instead fences out
    /// (`deferred-superseded`); the durable pending-switch marker then re-applies the Focus switch onto THIS
    /// updated library on the next foreground reconcile. The config file content is unchanged (a library-only
    /// edit never touches the active filter), so this is purely a generation bump, not a device-global write.
    /// Backup scheduling stays with the caller (`persistLibraryOnlyChange`), so suppress it here to avoid a
    /// double schedule.
    private func persistFilterLibrary() throws {
        try persistConfigurationOnly(schedulesAutomaticBackup: false)
    }

    private func uploadEncryptedBackup(
        _ envelope: ZeroKnowledgeBackupEnvelope,
        estimatedByteSize: Int
    ) async {
        // Never write to the server while a Clear/Disable is removing it — otherwise
        // an in-flight upload could re-create the row the user just deleted.
        guard !isBackupMaintenanceInProgress else {
            return
        }
        guard let backupSyncService else {
            encryptedBackupState = .waitingForSignIn(estimatedByteSize: estimatedByteSize)
            return
        }

        isUploadingEncryptedBackup = true
        defer { isUploadingEncryptedBackup = false }

        do {
            guard let session = try await accountAuthService.currentBackupSession() else {
                accountAuthState = accountAuthService.state
                encryptedBackupState = .waitingForSignIn(estimatedByteSize: estimatedByteSize)
                return
            }

            accountAuthState = accountAuthService.state
            try await backupSyncService.upload(envelope, session: session)
            let uploadedAt = Date()
            guard recordEncryptedBackupUploadIfStillCurrent(envelope, uploadedAt: uploadedAt) else {
                // A re-seal replaced the local envelope mid-upload; the newer one still needs
                // uploading (the re-seal already cleared the marker / scheduled its own upload).
                encryptedBackupState = .waitingForSignIn(estimatedByteSize: estimatedByteSize)
                return
            }
            encryptedBackupState = .synced(estimatedByteSize: estimatedByteSize, uploadedAt: uploadedAt)
        } catch BackupSyncServiceError.requestFailed(let statusCode) where statusCode == 401 {
            do {
                guard let refreshedSession = try await accountAuthService.refreshCurrentSession() else {
                    accountAuthState = accountAuthService.state
                    encryptedBackupState = .waitingForSignIn(estimatedByteSize: estimatedByteSize)
                    return
                }

                accountAuthState = accountAuthService.state
                try await backupSyncService.upload(envelope, session: refreshedSession)
                let uploadedAt = Date()
                guard recordEncryptedBackupUploadIfStillCurrent(envelope, uploadedAt: uploadedAt) else {
                    encryptedBackupState = .waitingForSignIn(estimatedByteSize: estimatedByteSize)
                    return
                }
                encryptedBackupState = .synced(estimatedByteSize: estimatedByteSize, uploadedAt: uploadedAt)
            } catch {
                accountAuthState = accountAuthService.state
                encryptedBackupState = .failed(message: "Encrypted locally, but upload failed: \(error.localizedDescription)")
            }
        } catch {
            accountAuthState = accountAuthService.state
            encryptedBackupState = .failed(message: "Encrypted locally, but upload failed: \(error.localizedDescription)")
        }
    }

    private func uploadPendingEncryptedBackupIfPossible() async {
        guard let envelope = loadLocalEncryptedBackupEnvelope() else {
            return
        }

        await uploadEncryptedBackup(
            envelope,
            estimatedByteSize: backupEnvelopeStore.estimatedByteSize(for: envelope)
        )
    }

    private func loadAvailableEncryptedBackupEnvelope() async throws -> ZeroKnowledgeBackupEnvelope {
        if let envelope = loadLocalEncryptedBackupEnvelope() {
            return envelope
        }

        guard let backupSyncService
        else {
            accountAuthState = accountAuthService.state
            throw EncryptedBackupError.noBackupAvailable
        }

        guard let session = try await accountAuthService.currentBackupSession() else {
            accountAuthState = accountAuthService.state
            throw EncryptedBackupError.noBackupAvailable
        }

        accountAuthState = accountAuthService.state

        if let envelope = try await backupSyncService.fetchLatest(session: session) {
            return envelope
        }

        throw EncryptedBackupError.noBackupAvailable
    }

    private func loadEncryptedBackupState() {
        encryptedBackupState = backupEnvelopeStore.currentState()
    }

    private func loadAutomaticBackupPreference() {
        isAutomaticBackupEnabled = UserDefaults.standard.object(forKey: automaticBackupEnabledDefaultsKey) as? Bool ?? false
    }

    private func loadCustomizationPreferences() {
        if let rawValue = defaults.string(forKey: appearancePreferenceDefaultsKey),
           let preference = LavaAppearancePreference(rawValue: rawValue) {
            appearancePreference = preference
        } else {
            appearancePreference = .system
        }

        if let rawValue = defaults.string(forKey: lavaGuardLookDefaultsKey)
            ?? appGroupDefaults.string(forKey: lavaGuardLookDefaultsKey),
           let look = GuardianShieldStyle(rawValue: rawValue) {
            lavaGuardLook = look
            persistLavaGuardLook(look)
        } else {
            lavaGuardLook = .original
            persistLavaGuardLook(.original)
        }

        updatesAppIconWithLavaGuard = defaults.object(forKey: updatesAppIconWithLavaGuardDefaultsKey) as? Bool ?? true
        if !updatesAppIconWithLavaGuard {
            syncAppIcon(to: lavaGuardLook)
        }

        let persistedUsesLiveActivities = defaults.object(forKey: usesLiveActivitiesDefaultsKey) as? Bool ?? false
        usesLiveActivities = canOfferLiveActivities && persistedUsesLiveActivities
        if !canOfferLiveActivities {
            defaults.set(false, forKey: usesLiveActivitiesDefaultsKey)
        }

        liveActivityPauseMinutes = LiveActivityPausePreference.minutes(
            from: ProtectionUserDefaultsStorage(defaults: appGroupDefaults)
        )

        usesLavaHaptics = defaults.object(forKey: usesLavaHapticsDefaultsKey) as? Bool ?? true

        // Notification toggles live in the SHARED app-group defaults (the extension + tunnel read them);
        // mirror them into the @Published properties for the Customization → Notifications section.
        notifiesFilterChanges = LavaNotificationPreferences.isEnabled(.filterChanged, in: appGroupDefaults)
        notifiesFilterCouldNotApply = LavaNotificationPreferences.isEnabled(.filterCouldNotApply, in: appGroupDefaults)
        notifiesConnectivity = LavaNotificationPreferences.isEnabled(.connectivity, in: appGroupDefaults)
    }

    /// Set a Customization → Notifications category toggle: persist to the shared app-group store (so the
    /// extension + tunnel see it), update the @Published mirror, and — when ENABLING — request notification
    /// permission contextually (the user just asked for this kind of alert), mirroring onboarding's request.
    func setNotificationCategoryEnabled(_ category: LavaNotificationCategory, _ enabled: Bool) {
        LavaNotificationPreferences.setEnabled(enabled, for: category, in: appGroupDefaults)
        switch category {
        case .filterChanged: notifiesFilterChanges = enabled
        case .filterCouldNotApply: notifiesFilterCouldNotApply = enabled
        case .connectivity: notifiesConnectivity = enabled
        }
        if enabled {
            Task { _ = await protectionUserNotifications.requestAuthorization() }
        }
    }

    private func loadLavaGuardProgress() {
        guard let data = defaults.data(forKey: lavaGuardProgressDefaultsKey),
              let progress = try? JSONDecoder().decode(LavaGuardProgress.self, from: data)
        else {
            lavaGuardProgress = LavaGuardProgress()
            return
        }

        lavaGuardProgress = progress
    }

    private func persistLavaGuardProgress() {
        guard let data = try? JSONEncoder().encode(lavaGuardProgress) else {
            return
        }

        defaults.set(data, forKey: lavaGuardProgressDefaultsKey)
    }

    private func loadTemporaryProtectionPause() {
        // ProtectionPauseStore (owned by pauseController) applies session binding
        // and expiry; the published value mirrors the store's authoritative state.
        let pauseUntil = pauseController.currentPauseUntil()
        if temporaryProtectionPauseUntil != pauseUntil {
            temporaryProtectionPauseUntil = pauseUntil
        }

        if pauseUntil == nil {
            pauseController.onPauseCleared()
        }
    }

    private func beginFreshProtectionVPNSession() {
        _ = try? protectionSessionStore.beginFreshSession()
        clearTemporaryProtectionPause()
    }

    private func endProtectionVPNSession() {
        _ = try? protectionSessionStore.clearActiveSessionID()
        clearTemporaryProtectionPause()
    }

    private func scheduleTemporaryProtectionResume(retryDelay: TimeInterval? = nil) {
        pauseController.scheduleResume(until: temporaryProtectionPauseUntil, retryDelay: retryDelay) { [weak self] in
            await self?.resumeTemporaryProtectionIfExpired()
        }
    }

    private func recordEncryptedBackupUpload(uploadedAt: Date) {
        backupEnvelopeStore.recordUpload(at: uploadedAt)
    }

    /// Record a successful upload ONLY if the envelope we uploaded is still the current local one.
    /// A config/library change re-seals + saves a new local envelope while an upload is in flight
    /// (e.g. the turn-on upload or a manual Back Up Now); recording .synced for the older envelope
    /// would falsely claim the server holds the latest, when the freshly re-sealed envelope still
    /// needs uploading. Returns whether the marker was recorded (the envelope is comparable —
    /// ZeroKnowledgeBackupEnvelope is Equatable — and a re-seal always produces a different one).
    private func recordEncryptedBackupUploadIfStillCurrent(
        _ uploadedEnvelope: ZeroKnowledgeBackupEnvelope,
        uploadedAt: Date
    ) -> Bool {
        guard loadLocalEncryptedBackupEnvelope() == uploadedEnvelope else {
            return false
        }
        recordEncryptedBackupUpload(uploadedAt: uploadedAt)
        return true
    }

    private func scheduleAutomaticBackupAfterConfigurationChange() {
        // Re-seal the LOCAL envelope with the current config + library on every change, BEFORE
        // consulting the cached backup state. The envelope is otherwise sealed only at
        // turn-on/restore, so without this the next upload (automatic OR manual) backs up stale
        // state and a restore silently loses every post-turn-on edit (new filters, renames,
        // blocklist changes). Gate the re-seal on the LIVE store, not the in-memory
        // encryptedBackupState: that cached value is stale (.off) right after a restore until the
        // next launch re-derives it, so an early isConfigured guard here would short-circuit the
        // re-seal and drop every post-restore edit. refreshLocalEncryptedBackupEnvelope no-ops
        // safely when no local envelope / device secret is present, so calling it
        // unconditionally is correct.
        refreshLocalEncryptedBackupEnvelope()

        guard encryptedBackupState.isConfigured, isAutomaticBackupEnabled else {
            return
        }

        automaticBackupTask?.cancel()
        let automaticBackupDelay = automaticBackupDelay
        automaticBackupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: automaticBackupDelay)
            guard !Task.isCancelled else {
                return
            }

            await self?.runScheduledAutomaticBackup()
        }
    }

    private func runScheduledAutomaticBackup() async {
        automaticBackupTask = nil
        guard isAutomaticBackupEnabled else {
            return
        }

        await backUpNow()
    }

    private func saveLocalEncryptedBackupEnvelope(_ envelope: ZeroKnowledgeBackupEnvelope) throws {
        try backupEnvelopeStore.saveEnvelope(envelope)
    }

    /// Re-seal the local encrypted-backup envelope with the current config + library
    /// (keeping every key slot), so a backup reflects post-turn-on changes. Recovers the
    /// payload key via the stored device secret — no user interaction. Best-effort: if there
    /// is no local envelope or device secret, leave the existing envelope untouched.
    private func refreshLocalEncryptedBackupEnvelope() {
        guard let envelope = loadLocalEncryptedBackupEnvelope() else {
            return
        }
        let storedDeviceSecret = try? backupKeychainStore.loadDeviceSecret()
        guard let deviceSecret = storedDeviceSecret ?? nil else {
            return
        }
        let payload = BackupConfigurationPayload(
            configuration: configuration,
            catalogVersionHint: catalogVersion,
            filterLibrary: library
        )
        // Skip the re-seal entirely when the backup CONTENT is unchanged. resealingPayload mints a
        // fresh AES-GCM ciphertext every time and the marker-clear below then flips an
        // already-uploaded backup to "not uploaded"; without this gate a non-user persist (e.g.
        // reconcileTunnelSnapshotAfterLaunch on launch) would churn the backup state and schedule a
        // redundant upload with no actual change. hasSameBackupContent ignores protectionEnabledHint
        // (a frequently-toggled advisory hint) and the library's already-stripped local cache
        // tokens, so a protection pause/resume or a compile-token restamp no longer churns the
        // marker. Compare against the currently-sealed payload (recovered via the same device secret).
        if let currentPayload = try? envelope.decryptWithKeychainSecret(deviceSecret),
           currentPayload.hasSameBackupContent(as: payload) {
            return
        }
        guard let resealed = try? envelope.resealingPayload(payload, deviceSecret: deviceSecret) else {
            return
        }
        try? saveLocalEncryptedBackupEnvelope(resealed)
        // The re-sealed local envelope is newer than any uploaded copy, so the prior upload marker
        // is stale. Clear it (and refresh the cached state) — otherwise currentState() keeps
        // reporting .synced and Settings claims the latest backup is uploaded while the server
        // still holds the pre-change envelope. The automatic-upload path records a fresh marker
        // after a successful upload; with automatic backup off the state correctly stays
        // "encrypted locally, not yet uploaded" until a manual Back Up Now.
        backupEnvelopeStore.clearUploadMarker()
        loadEncryptedBackupState()
    }

    private func loadLocalEncryptedBackupEnvelope() -> ZeroKnowledgeBackupEnvelope? {
        backupEnvelopeStore.loadEnvelope()
    }

    private func notifyTunnelSnapshotUpdated(operationID: LatencyOperationID? = nil) async {
        await sendTunnelMessage(
            LavaSecAppGroup.reloadSnapshotMessage,
            fallbackMessage: "Updated filter. Restart protection if the VPN does not pick it up.",
            operationID: operationID
        )
    }

    private func notifyTunnelProtectionPauseUpdated(operationID: LatencyOperationID? = nil) async {
        await sendTunnelMessage(
            LavaSecAppGroup.reloadProtectionPauseMessage,
            fallbackMessage: "Updated protection pause. Restart protection if the VPN does not pick it up.",
            operationID: operationID
        )
    }

    private func restoreProtectionIfNeeded(wasEnabled: Bool) async {
        #if targetEnvironment(simulator)
        return
        #else
        // Never restore/enable protection while onboarding is incomplete. The
        // launch catalog sync (syncCatalogIfStale -> performCatalogSync) calls this,
        // and a concurrent startup status refresh can momentarily read an inherited
        // on-demand manager as "connected" — making the caller's
        // shouldRestoreProtection true — so without this gate a reinstall over an
        // iOS-retained VPN config could enableProtection (-> saveToPreferences ->
        // VPN permission prompt) before the user reaches the onboarding VPN step.
        // neutralizeInheritedProtectionDuringOnboarding removes the inherited
        // config; this closes the catalog-/filter-restore path too.
        guard hasCompletedOnboarding else {
            return
        }

        guard wasEnabled else {
            return
        }

        await refreshProtectionStatus(force: true)
        guard !isProtectionEnabledStatus(vpnStatus) else {
            return
        }

        // Restore is a background follow-up: when a user action already holds
        // the claim, skip rather than interleave lifecycle work.
        await protectionActionOrchestrator.run(.turnOn) {
            await enableProtection(logUserAction: false, playsOutcomeHaptic: false)
        }
        #endif
    }

    // Connect-On-Demand can bring the tunnel up on launch (or after iOS tears it
    // down on a network change) before the app has pushed a snapshot. A cold
    // tunnel with no reusable persisted snapshot loads FAIL-CLOSED — it blocks
    // all traffic — and never recovers on its own: restoreProtectionIfNeeded
    // early-returns once the tunnel already reads as "connected", and a non-stale
    // launch never re-syncs or re-pushes. So whenever protection is active at
    // launch, re-establish and push the snapshot so the tunnel reloads its real
    // rules out of fail-closed. Fail-closed stays the safe default; this just
    // supersedes it promptly. (Fixes: filters shown red / traffic blocked after
    // an app restart while Connect-On-Demand keeps the tunnel up.)
    private func reconcileTunnelSnapshotAfterLaunch() async {
        #if targetEnvironment(simulator)
        return
        #else
        await refreshProtectionStatus(force: true)
        guard isProtectionEnabledStatus(vpnStatus) else {
            return
        }

        do {
            let startup = try await preparedSnapshotForProtectionStartup()
            try await persistSharedState(
                preparedSnapshot: startup.preparedSnapshot,
                rewritesRuleArtifacts: !startup.reusedPersistedArtifacts
            )
            await notifyTunnelSnapshotUpdated()
            #if DEBUG
            logVPNDebugEvent("launch-snapshot-reconciled", details: [
                "reusedPersistedArtifacts": "\(startup.reusedPersistedArtifacts)",
                "compiledRuleCount": "\(compiledRuleCount)"
            ])
            #endif
        } catch {
            #if DEBUG || LAVA_QA_TOOLS
            logVPNDebugEvent("launch-snapshot-reconcile-failed", details: errorDebugDetails(error))
            #endif
        }
        #endif
    }

    // Mirrors the RootView @AppStorage("hasSeenLavaOnboarding") gate. The VPN
    // restore/reconcile launch chain runs from init regardless of UI state, so it
    // reads this directly to avoid acting on protection before the user has
    // finished onboarding and chosen to enable it.
    private var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: "hasSeenLavaOnboarding")
    }

    // Fundamental guard against the "fresh install shows VPN already on / filters
    // red mid-onboarding" (and the "VPN permission prompt at step 1") class of
    // bug. iOS does not reliably remove a VPN profile when the app is deleted, so
    // a reinstall can land on an *incomplete* onboarding with a pre-existing,
    // orphaned config. If that config has Connect-On-Demand enabled (or a tunnel
    // already up), iOS keeps a cold tunnel alive — it loads fail-closed and blocks
    // traffic before the user has chosen any blocklists.
    //
    // Until onboarding is complete, such inherited *active* protection must be
    // fully removed. Critically, we REMOVE the config (removeFromPreferences)
    // rather than save a modification to it: saveToPreferences (what
    // setManagerOnDemand uses) re-shows the "Add VPN Configurations" system
    // prompt on an orphaned profile this install does not own, firing the dialog
    // at app init before the onboarding sheet even renders. removeFromPreferences
    // is silent and leaves a pristine state; the user installs a fresh profile at
    // the VPN step.
    //
    // No-op on a clean install (no manager) and when the inherited config is
    // already inert (disconnected, no on-demand), so a profile freshly installed
    // at the onboarding VPN step survives a mid-onboarding relaunch (see
    // applyConfiguration / ProtectionOnDemandSourceTests).
    private func neutralizeInheritedProtectionDuringOnboarding() async {
        #if targetEnvironment(simulator)
        return
        #else
        do {
            guard let manager = try await loadExistingTunnelManager() else {
                return
            }

            let wasOnDemand = manager.isOnDemandEnabled
            let status = manager.connection.status
            let isUpOrComingUp = status == .connected || status == .connecting || status == .reasserting
            guard wasOnDemand || isUpOrComingUp else {
                return
            }

            manager.connection.stopVPNTunnel()
            try await vpnLifecycleController.removeManager(manager)
            tunnelManager = nil
            updateProtectionStatus(from: nil)
            #if DEBUG || LAVA_QA_TOOLS
            logVPNDebugEvent("onboarding-neutralized-inherited-protection", details: [
                "wasOnDemand": "\(wasOnDemand)",
                "connectionStatus": "\(status.rawValue)"
            ])
            #endif
        } catch {
            #if DEBUG || LAVA_QA_TOOLS
            logVPNDebugEvent("onboarding-neutralize-failed", details: errorDebugDetails(error))
            #endif
        }
        #endif
    }

    private func sendTunnelMessage(
        _ message: String,
        fallbackMessage: String = "Updated local settings. Restart protection if the VPN does not pick them up.",
        operationID: LatencyOperationID? = nil
    ) async {
        #if targetEnvironment(simulator)
        return
        #else
        // Runs on the HEADLESS model too: a Focus warm switch must reload the RUNNING tunnel so the new
        // filter takes effect in the background — do NOT guard this whole method on !isHeadless (that would
        // silently defeat the background switch). Only the @Published vpnMessage writes below are guarded,
        // since they would be dead state on the throwaway headless model (review #5).
        if tunnelManager == nil {
            do {
                tunnelManager = try await loadExistingTunnelManager()
            } catch {
                if !isHeadless {
                    vpnMessage = fallbackMessage
                    vpnMessageIsError = false
                }
                return
            }
        }

        guard let session = tunnelManager?.connection as? NETunnelProviderSession,
              isProtectionEnabledStatus(session.status)
        else {
            return
        }

        let operationID = operationID ?? LatencyOperationID.make()
        #if DEBUG || LAVA_QA_TOOLS
        let trace = LatencyTrace(
            operationID: operationID,
            sink: LatencyDebugLogEventSink(operationKind: "providerMessage") { [weak self] event, details in
                self?.logVPNDebugEvent(event, details: details)
            }
        )
        trace.record("provider.message.request", details: ["kind": message])
        let span = trace.beginSpan("provider.message.reply", details: ["kind": message])
        #endif
        let messageData = LavaSecProviderMessageCodec.encode(kind: message, operationID: operationID.rawValue)

        do {
            try session.sendProviderMessage(messageData) { _ in
                #if DEBUG || LAVA_QA_TOOLS
                span.end(details: ["status": "reply"])
                #endif
            }
            #if DEBUG || LAVA_QA_TOOLS
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.providerMessageAckTimeout) {
                span.end(details: ["status": "timeout"])
            }
            #endif
        } catch {
            #if DEBUG || LAVA_QA_TOOLS
            var details = errorDebugDetails(error)
            details["status"] = "send-error"
            span.end(details: details)
            #endif
            if !isHeadless {
                vpnMessage = fallbackMessage
                vpnMessageIsError = false
            }
        }
        #endif
    }

    private func requestTunnelHealthFlush() async {
        #if targetEnvironment(simulator)
        return
        #else
        if tunnelManager == nil {
            tunnelManager = try? await loadExistingTunnelManager()
        }

        guard let session = tunnelManager?.connection as? NETunnelProviderSession,
              isProtectionEnabledStatus(session.status)
        else {
            return
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    try session.sendProviderMessage(Data(LavaSecAppGroup.flushTunnelHealthMessage.utf8)) { _ in
                        continuation.resume()
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            return
        }
        #endif
    }

    private var catalogCacheURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(
            LavaSecAppGroup.catalogCacheDirectoryName,
            isDirectory: true
        )
    }

    /// Cross-process lock for the pending-Focus-switch marker (LAV-100 Phase 4): the foreground reconcile's
    /// `clearIfMatches` takes the SAME lock the App Intents extension's `record` does, so an extension record
    /// can't interleave a clear's read→remove (Codex P2).
    private var pendingFilterSwitchMarkerLockURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.pendingFilterSwitchMarkerLockFilename)
    }

    private var configurationURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.configurationFilename)
    }

    private var filterLibraryURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.filterLibraryFilename)
    }

    private var backgroundWarmIndexURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.backgroundWarmIndexFilename)
    }

    /// The sidecar warm-index store, or nil if the App Group container is unavailable. The background
    /// BGTask is the only writer; the foreground reads it for the switch read-fallback, GC retention,
    /// and reconcile promotion.
    private var backgroundWarmIndexStore: BackgroundWarmIndexStore? {
        backgroundWarmIndexURL.map(BackgroundWarmIndexStore.init(fileURL:))
    }

    /// The currently persisted sidecar warm-index (empty on a miss). Cheap JSON read; callers that
    /// need it more than once in a tight scope should snapshot the result.
    private func loadBackgroundWarmIndex() -> BackgroundWarmIndex {
        backgroundWarmIndexStore?.load() ?? BackgroundWarmIndex()
    }

    /// Every `lastCompiledToken` recorded in the CURRENT on-disk `filter-library.json` (empty on a
    /// miss/decode failure). The headless BGTask loads its in-memory library once at launch, so a
    /// foreground create/edit/warm during a long background pass writes tokens this process can't see;
    /// the background GC unions these on-disk tokens into its retain set so it never reaps a directory
    /// the live library references (Codex #138 r7). Not eligibility-filtered: anything the live library
    /// names must be retained (over-retaining is safe; under-retaining reaps a referenced dir).
    private func persistedLibraryArtifactTokens() -> [String] {
        guard let url = filterLibraryURL,
              let data = try? Data(contentsOf: url),
              let persisted = try? JSONDecoder().decode(FilterLibrary.self, from: data) else {
            return []
        }
        return persisted.filters.compactMap(\.lastCompiledToken)
    }

    private var diagnosticsURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.diagnosticsFilename)
    }

    private var networkActivityLogURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.networkActivityLogFilename)
    }

    private var diagnosticsControlURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.diagnosticsControlFilename)
    }

    private func modificationDate(for url: URL?) -> Date? {
        // Fetch only the content-modification date rather than building
        // `FileManager.attributesOfItem`'s full attribute dictionary (owner,
        // permissions, size, type, every timestamp…). Same `st_mtime` semantics,
        // less work per stat — these report-refresh paths poll several files.
        // NB: a cross-refresh cache is intentionally avoided — this date is the
        // signal used to detect the tunnel process's writes, so a TTL would mask
        // fresh data and a vnode monitor is unreliable for atomic-rename writes.
        guard let url else {
            return nil
        }

        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private var tunnelProviderBundleIdentifier: String {
        let appBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.lavasec.app"
        return "\(appBundleIdentifier).tunnel"
    }

    private func isProtectionEnabledStatus(_ status: NEVPNStatus) -> Bool {
        ProtectionLifecyclePolicy.isProtectionEnabled(status.protectionLifecycleStatus)
    }

    private func isProtectionStopPendingStatus(_ status: NEVPNStatus) -> Bool {
        ProtectionLifecyclePolicy.isStopPending(status.protectionLifecycleStatus)
    }

    private func isProtectionTransitionStatus(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connecting, .reasserting, .disconnecting:
            true
        default:
            false
        }
    }

    private func isProtectionStartPendingStatus(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connecting, .reasserting:
            true
        default:
            false
        }
    }

    private func isLocalProtectionUptimeStatus(_ status: NEVPNStatus) -> Bool {
        ProtectionLifecyclePolicy.isUptimeActive(status.protectionLifecycleStatus)
    }

    private static func vpnErrorMessage(prefix: String, error: Error) -> String {
        // User-facing, self-contained errors (e.g. the over-budget blocklist
        // message) are shown verbatim without the technical domain/code suffix.
        if let preparationError = error as? FilterSnapshotPreparationError {
            return "\(prefix): \(preparationError.localizedDescription)"
        }
        let nsError = error as NSError
        return "\(prefix): \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))."
    }

}

#if DEBUG
enum WebsiteAssetCaptureProtectionState {
    case off
    case waking
    case protected
}

extension AppViewModel {
    static func previewProtectionState(health: TunnelHealthSnapshot) -> AppViewModel {
        let viewModel = AppViewModel(loadVPNState: false)
        viewModel.vpnStatus = .connected
        viewModel.isVPNConfigurationInstalled = true
        viewModel.tunnelHealth = health
        return viewModel
    }

    static func websiteAssetCapturePreview() -> AppViewModel {
        let viewModel = AppViewModel(loadVPNState: false)
        viewModel.applyWebsiteAssetCaptureConfiguration()
        viewModel.applyWebsiteAssetCaptureProtectionState(.protected)
        return viewModel
    }

    func applyWebsiteAssetCaptureProtectionState(_ state: WebsiteAssetCaptureProtectionState) {
        applyWebsiteAssetCaptureConfiguration()

        switch state {
        case .off:
            vpnStatus = .disconnected
            isVPNConfigurationInstalled = true
            configuration.protectionEnabled = false
        case .waking:
            vpnStatus = .connecting
            isVPNConfigurationInstalled = true
            configuration.protectionEnabled = true
        case .protected:
            vpnStatus = .connected
            isVPNConfigurationInstalled = true
            configuration.protectionEnabled = true
        }
    }

    private func applyWebsiteAssetCaptureConfiguration() {
        var nextConfiguration = AppConfiguration()
        nextConfiguration.resolverPresetID = DNSResolverPreset.googleDoH.id
        nextConfiguration.fallbackToDeviceDNS = false
        nextConfiguration.blockedDomains = ["tracking.example"]
        nextConfiguration.keepFilteringCounts = true
        nextConfiguration.keepDomainDiagnostics = true
        nextConfiguration.keepNetworkActivity = true
        configuration = nextConfiguration

        let now = Date()
        tunnelHealth = TunnelHealthSnapshot(
            startedAt: now.addingTimeInterval(-180),
            updatedAt: now,
            networkKind: .cellular,
            lastResolverAddress: "https://dns.google/dns-query",
            cacheHitCount: 4,
            cacheMissCount: 12,
            upstreamSuccessCount: 12,
            lastResolverTransport: .dnsOverHTTPS,
            networkPathIsSatisfied: true,
            lastDNSSmokeProbeAt: now.addingTimeInterval(-30),
            lastDNSSmokeProbeSucceeded: true,
            dnsSmokeProbeSuccessCount: 2,
            lastUpstreamSuccessAt: now.addingTimeInterval(-8)
        )

        compiledRuleCount = 1
        protectedRuleCount = 1
        vpnMessage = nil
        vpnMessageIsError = false
    }
}
#endif

private extension GuardianShieldStyle {
    var lavaGuardID: String {
        rawValue
    }
}

private extension NEVPNStatus {
    var protectionLifecycleStatus: ProtectionLifecycleStatus {
        switch self {
        case .invalid:
            .invalid
        case .disconnected:
            .disconnected
        case .connecting:
            .connecting
        case .connected:
            .connected
        case .reasserting:
            .reasserting
        case .disconnecting:
            .disconnecting
        @unknown default:
            .invalid
        }
    }
}

private enum LavaSecAppError: LocalizedError {
    case appGroupUnavailable
    case vpnStillStopping

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "The shared App Group container is unavailable. Check the App Groups entitlement for the app and tunnel targets."
        case .vpnStillStopping:
            "iOS is still finishing turning off the local VPN. Wait a moment and try again."
        }
    }
}

// NetworkExtension-backed conformances for VPNLifecycleController. Per the
// plan's architecture decisions, NE concrete types stay in the app target and
// the controller in LavaSecCore sees only these seams.
extension NETunnelProviderManager: @retroactive VPNManagerControlling {
    public var managerDisplayName: String? {
        localizedDescription
    }

    public var managerProviderBundleIdentifier: String? {
        (protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
    }

    public var lifecycleStatus: ProtectionLifecycleStatus {
        connection.status.protectionLifecycleStatus
    }
}

@MainActor
struct NETunnelManagerRepository: VPNManagerRepositoryProtocol {
    let providerBundleIdentifier: String
    let configurationName: String

    func loadAll() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NETunnelProviderManager], Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: managers ?? [])
            }
        }
    }

    func makeManager() -> NETunnelProviderManager {
        NETunnelProviderManager()
    }

    func applyConfiguration(to manager: NETunnelProviderManager) {
        let provider = NETunnelProviderProtocol()
        provider.providerBundleIdentifier = providerBundleIdentifier
        provider.serverAddress = "Lava Security Local DNS"
        provider.providerConfiguration = [
            "appGroupIdentifier": LavaSecAppGroup.identifier,
            "snapshotFilename": LavaSecAppGroup.snapshotFilename
        ]

        manager.localizedDescription = configurationName
        manager.protocolConfiguration = provider
        manager.isEnabled = true

        // NOTE: Connect-On-Demand is deliberately NOT enabled here. This method
        // is the shared install/enable path — it also runs when onboarding
        // merely *installs* the VPN profile (installLocalVPNProfileForOnboarding),
        // before the user has ever turned protection on. Enabling on-demand at
        // that point makes iOS connect the tunnel immediately on any traffic,
        // which on a fresh install surfaces as protection already "on" (filter
        // red) with a tunnel that isn't really running — and an un-turn-off-able
        // VPN that blocks all internet. On-demand is instead enabled in
        // enableProtection() only after the tunnel is confirmed connected.
    }

    func saveAndReload(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume()
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume()
            }
        }
    }

    func remove(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.removeFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume()
            }
        }
    }
}

@MainActor
struct ProtectionStatusChangeWaiter: VPNStatusChangeWaiting {
    func waitForStatusChange(timeout: TimeInterval) async -> Bool {
        await ProtectionStopNotificationWaiter().wait(timeout: timeout)
    }
}

// The Focus-driven warm filter switch is driven by the App Intents EXTENSION (LavaSecIntents), whose
// `perform()` calls `FocusSwitchEnvironment.performSwitch` → the shared LavaSecCore
// `HeadlessFocusFilterSwitchEngine`. perform() runs in the extension even while Lava is closed (WWDC22
// §10121), so there is no app-target switch entry; the app keeps only the foreground reconcile
// (`reconcilePendingFilterSwitch`), the manual `switchToFilter`, and the non-active warm-keep helper.
