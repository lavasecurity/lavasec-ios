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
        let history = notificationHistory
        let resolvedNotificationIdentifiers = ProtectionConnectivityNotificationPolicy
            .resolvedProblemNotificationIdentifiers(
                for: assessment,
                health: health,
                history: history,
                now: now
            )
        if !resolvedNotificationIdentifiers.isEmpty {
            clearResolvedProblemNotifications(resolvedNotificationIdentifiers)
        }

        // Use the pre-clear `history`: clearResolvedProblemNotifications wipes the
        // unresolved-problem markers, but the recovery acknowledgement (.reconnected)
        // needs to see the outstanding problem to fire. Re-reading would always miss it.
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

        if notification.kind.isProblem {
            // Only problem deliveries advance the throttle clock; the 600s
            // minimum-problem-interval keys off this timestamp, so a recovery
            // acknowledgement must not extend it (a fresh problem after a flappy
            // recovery would otherwise be suppressed for another full window).
            defaults.set(Date(), forKey: LavaSecAppGroup.protectionLastDeliveredNotificationAtDefaultsKey)
            defaults.set(
                notification.identifier,
                forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationIDDefaultsKey
            )
            defaults.set(
                notification.kind.rawValue,
                forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationKindDefaultsKey
            )
        } else if notification.kind == .reconnected {
            defaults.removeObject(forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationIDDefaultsKey)
            defaults.removeObject(forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationKindDefaultsKey)
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

    private func clearResolvedProblemNotifications(_ identifiers: [String]) {
        defaults.removeObject(forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationIDDefaultsKey)
        defaults.removeObject(forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationKindDefaultsKey)

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

enum FilterEditScope: Equatable {
    case blockedDomains
    case allowedExceptions
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

private struct AccountQADecisionResponse: Decodable {
    let isDeveloper: Bool

    private enum CodingKeys: String, CodingKey {
        case isDeveloper = "is_developer"
    }
}

private struct AccountQAAccessClient: Sendable {
    let urlSession: URLSession

    func isAccountDeveloper(accessToken: String) async throws -> Bool {
        var lastError: Error?
        for endpoint in Self.qaAccessEndpointURLs {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "GET"
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")

                let (responseData, response) = try await urlSession.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AccountQAAccessError(message: "The QA access server response was not valid.")
                }

                guard 200..<300 ~= httpResponse.statusCode else {
                    let serverMessage = String(data: responseData, encoding: .utf8) ?? "No response body"
                    throw AccountQAAccessError(
                        message: "QA access returned HTTP \(httpResponse.statusCode): \(serverMessage)"
                    )
                }

                let decoded = try JSONDecoder().decode(AccountQADecisionResponse.self, from: responseData)
                return decoded.isDeveloper
            } catch {
                lastError = error
            }
        }

        throw lastError ?? AccountQAAccessError(message: "Could not load QA access.")
    }

    private static var qaAccessEndpointURLs: [URL] {
        [LavaSecAPI.productionBaseURL, LavaSecAPI.fallbackBaseURL].map {
            $0
                .appending(path: "v1")
                .appending(path: "account")
                .appending(path: "qa-access")
        }
    }
}

private struct AccountQAAccessError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
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

    var errorDescription: String? {
        switch self {
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

        setState(.preparing(progress: update.progress, message: FilterPreparationPresentation.message(for: update.phase)))
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

private struct ReusablePreparedFilterSnapshot: Sendable {
    let preparedSnapshot: PreparedFilterSnapshot
    let cachedCatalog: BlocklistCatalog?
}

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

    @MainActor static func play(_ feedback: ProtectionHapticFeedback) {
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
    @Published var diagnostics = DiagnosticsStore()
    @Published private(set) var networkActivityLog = NetworkActivityLog()
    @Published var allowlistDraft = ""
    #if DEBUG || LAVA_QA_TOOLS
    @Published var qaProbeSuffixDraft = ""
    #endif
    @Published var lastAllowlistMessage: String?
    @Published var filterEditDraft: FilterEditDraft?
    @Published private(set) var filterEditScope: FilterEditScope?
    @Published private(set) var filterPreparationState: FilterPreparationState = .idle
    @Published var isFilterPreparationScreenPresented = false
    @Published var rageShakeDestination: RageShakeDestination?
    @Published var pendingRageShakeConfirmation: RageShakeDestination?
    @Published private(set) var bugReportDraft: BugReportBundle?
    @Published private(set) var bugReportSendState: BugReportSendState = .idle
    #if DEBUG || LAVA_QA_TOOLS
    @Published private(set) var adminQAStatusMessage: String?
    #endif
    @Published private(set) var isAccountDeveloper = false
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
    @Published private(set) var isSyncingCatalog = false
    private var catalogSyncTask: Task<Void, Never>?
    @Published private(set) var catalogStatusMessage = "Filters will update from Lava Security's source catalog."
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
    @Published private(set) var isPurchasingLavaSecurityPlus = false
    @Published private(set) var lavaSecurityPlusMessage: String?
    @Published private(set) var lavaSecurityPlusMessageIsError = false

    private var blockRules = DomainRuleSet()
    private var threatGuardrail = DomainRuleSet()
    private var cachedBlockRuleSets: [String: DomainRuleSet] = [:]
    private var catalogSourcesByID: [String: CatalogBlocklistSource] = [:]
    private var currentCatalog: BlocklistCatalog?
    private var tunnelManager: NETunnelProviderManager?
    private var vpnStatusObserver: NSObjectProtocol?
    private var tunnelHealthNudgeObserver: DarwinNotificationObserver?
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

    init(loadVPNState: Bool = true) {
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
        Task {
            await refreshAccountDeveloperAccess()
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
                lavaSecurityPlusMessage = entitlement.isActive
                    ? "Lava Security Plus is active."
                    : "No active Lava Security Plus purchase was found."
                lavaSecurityPlusMessageIsError = !entitlement.isActive
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
            case .usingDeviceDNSFallback:
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
        guard let filterEditDraft else {
            return configuration.customBlocklists
        }

        var mergedByID = Dictionary(
            uniqueKeysWithValues: configuration.customBlocklists.map { ($0.id, $0) }
        )
        for source in filterEditDraft.customBlocklists {
            mergedByID[source.id] = source
        }

        let configuredIDs = Set(configuration.customBlocklists.map(\.id))
        let displayOrder = configuration.customBlocklists.map(\.id)
            + filterEditDraft.customBlocklists.map(\.id).filter { !configuredIDs.contains($0) }
        return displayOrder.compactMap { mergedByID[$0] }
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
        guard let filterEditDraft else {
            return FilterConfigurationDiff(
                from: configuration.filterSelection,
                to: configuration.filterSelection
            )
        }

        return FilterConfigurationDiff(
            from: configuration.filterSelection,
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
            return "No filters active yet"
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

    var localHistoryStatusText: String {
        configuration.keepDomainDiagnostics ? "Local history on" : "Local history off"
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
            return "Filters not updated yet"
        }

        return "Filters updated: \(catalogUpdatedAtText)"
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
            return "Catalog checked"
        }

        return "Catalog needs a refresh"
    }

    var blocklistCatalogFreshnessDescription: String {
        guard let age = blocklistCatalogAge else {
            return "Lava will fetch the source catalog before preparing filters."
        }

        return "Last checked: \(Self.formatRelativeCatalogAge(age, maxFreshnessAge: catalogSyncFreshnessInterval))"
    }

    var blocklistCatalogFreshnessSystemImage: String {
        blocklistCatalogIsFresh ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    var blocklistCatalogFreshnessTint: Color {
        blocklistCatalogIsFresh ? LavaStyle.safeGreen : LavaStyle.lavaOrange
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

        guard displayedCustomBlocklists.contains(where: { $0.id == sourceID }) else {
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
        filterEditDraft?.enabledBlocklistIDs ?? configuration.enabledBlocklistIDs
    }

    /// Manual blocked + allowed domains are each compiled as a filter rule, so
    /// they consume the same budget as the blocklists and are counted together.
    private var stagedManualRuleCount: Int {
        let blocked = filterEditDraft?.blockedDomains ?? configuration.blockedDomains
        let allowed = filterEditDraft?.allowedDomains ?? configuration.allowedDomains
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

    func isFilterEditing(_ scope: FilterEditScope) -> Bool {
        filterEditScope == scope && filterEditDraft != nil
    }

    func beginFilterEditing(_ scope: FilterEditScope) {
        filterEditDraft = FilterEditDraft(configuration: configuration)
        filterEditScope = scope
        filterPreparationState = .idle
    }

    func cancelFilterEditing() {
        filterEditDraft = nil
        filterEditScope = nil
        filterPreparationState = .idle
        isFilterPreparationScreenPresented = false
    }

    func cancelFilterEditingOnPageDisappear(_ scope: FilterEditScope) {
        guard isFilterEditing(scope),
              !isFilterPreparationScreenPresented,
              !filterPreparationState.isPreparing
        else {
            return
        }

        cancelFilterEditing()
    }

    func keepCurrentFiltersAfterPrepareFailure() {
        filterEditDraft = nil
        filterEditScope = nil
        filterPreparationState = .idle
        isFilterPreparationScreenPresented = false
    }

    func returnToFilterEditAfterPrepareFailure() {
        filterPreparationState = .idle
        isFilterPreparationScreenPresented = false
    }

    func blocklistName(for sourceID: String) -> String {
        if let catalogSource = catalogSourcesByID[sourceID] {
            return catalogSource.name
        }

        if let customSource = displayedCustomBlocklists.first(where: { $0.id == sourceID }) {
            return customBlocklistPickerTitle(for: customSource)
        }

        return DefaultCatalog.curatedSources.first { $0.id == sourceID }?.name ?? sourceID
    }

    func isBlocklistPendingRemoval(_ sourceID: String) -> Bool {
        guard let filterEditDraft else {
            return false
        }

        return configuration.enabledBlocklistIDs.contains(sourceID)
            && !filterEditDraft.enabledBlocklistIDs.contains(sourceID)
    }

    func isBlocklistNewInDraft(_ sourceID: String) -> Bool {
        guard let filterEditDraft else {
            return false
        }

        return !configuration.enabledBlocklistIDs.contains(sourceID)
            && filterEditDraft.enabledBlocklistIDs.contains(sourceID)
    }

    func isBlockedDomainPendingRemoval(_ domain: String) -> Bool {
        guard let filterEditDraft else {
            return false
        }

        return configuration.blockedDomains.contains(domain)
            && !filterEditDraft.blockedDomains.contains(domain)
    }

    func isBlockedDomainNewInDraft(_ domain: String) -> Bool {
        guard let filterEditDraft else {
            return false
        }

        return !configuration.blockedDomains.contains(domain)
            && filterEditDraft.blockedDomains.contains(domain)
    }

    func isAllowedDomainPendingRemoval(_ domain: String) -> Bool {
        guard let filterEditDraft else {
            return false
        }

        return configuration.allowedDomains.contains(domain)
            && !filterEditDraft.allowedDomains.contains(domain)
    }

    func isAllowedDomainNewInDraft(_ domain: String) -> Bool {
        guard let filterEditDraft else {
            return false
        }

        return !configuration.allowedDomains.contains(domain)
            && filterEditDraft.allowedDomains.contains(domain)
    }

    func stagedBlocklistIDsForDisplay() -> [String] {
        guard let filterEditDraft else {
            return configuration.enabledBlocklistIDs.sorted()
        }

        return configuration.enabledBlocklistIDs
            .union(filterEditDraft.enabledBlocklistIDs)
            .sorted { blocklistName(for: $0).localizedStandardCompare(blocklistName(for: $1)) == .orderedAscending }
    }

    func stagedBlockedDomainsForDisplay() -> [String] {
        guard let filterEditDraft else {
            return configuration.blockedDomains.sorted()
        }

        return configuration.blockedDomains
            .union(filterEditDraft.blockedDomains)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func stagedAllowedDomainsForDisplay() -> [String] {
        guard let filterEditDraft else {
            return configuration.allowedDomains.sorted()
        }

        return configuration.allowedDomains
            .union(filterEditDraft.allowedDomains)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func addBlocklistsToDraft(_ sourceIDs: Set<String>) -> String? {
        guard var draft = filterEditDraft else {
            return "Tap Edit before changing filters."
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
            return "Tap Edit before changing filters."
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
            return "Tap Edit before changing filters."
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

        if configuration.enabledBlocklistIDs.contains(sourceID) {
            draft.enabledBlocklistIDs.insert(sourceID)
            if let source = configuration.customBlocklists.first(where: { $0.id == sourceID }),
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
            return .rejected(title: "Edit first", message: "Tap Edit before changing filters.")
        }

        let outcome = FilterEditDraftEditor.addBlockedDomain(
            rawDomain,
            to: draft,
            maxBlockedDomains: configuration.limits.maxBlockedDomains
        )
        if outcome.result.isAccepted {
            filterEditDraft = outcome.draft
        }
        return outcome.result
    }

    func removeBlockedDomainFromDraft(_ domain: String) {
        guard let draft = filterEditDraft else {
            return
        }

        filterEditDraft = FilterEditDraftEditor.removeBlockedDomain(domain, from: draft)
    }

    func undoBlockedDomainDraftChange(_ domain: String) {
        guard let draft = filterEditDraft else {
            return
        }

        filterEditDraft = FilterEditDraftEditor.undoBlockedDomainChange(
            domain,
            in: draft,
            configuredBlockedDomains: configuration.blockedDomains
        )
    }

    func validateAllowedExceptionDraft(_ rawDomain: String) -> AllowlistValidationResult {
        AllowlistValidator(nonAllowableThreatRules: threatGuardrail).validate(rawDomain)
    }

    func addAllowedDomainToDraft(_ rawDomain: String) -> DomainDraftResult {
        guard let draft = filterEditDraft else {
            return .rejected(title: "Edit first", message: "Tap Edit before changing filters.")
        }

        let outcome = FilterEditDraftEditor.addAllowedDomain(
            rawDomain,
            to: draft,
            maxAllowedDomains: configuration.limits.maxAllowedDomains,
            validator: AllowlistValidator(nonAllowableThreatRules: threatGuardrail)
        )
        if outcome.result.isAccepted {
            filterEditDraft = outcome.draft
        }
        return outcome.result
    }

    func stageDomainHistoryDomainAction(_ rawDomain: String, target: DomainHistoryDomainTarget) -> DomainDraftResult {
        do {
            let result = try configuration.applyingDomainHistoryDomainAction(
                rawDomain,
                target: target,
                allowlistValidator: AllowlistValidator(nonAllowableThreatRules: threatGuardrail)
            )

            filterEditDraft = FilterEditDraft(configuration: result.configuration)
            filterEditScope = nil
            filterPreparationState = .idle
            isFilterPreparationScreenPresented = false

            switch result.target {
            case .blocked:
                return .accepted(result.normalizedDomain, message: "This domain will be blocked after you confirm.")
            case .allowed:
                return .accepted(result.normalizedDomain, message: "This exception will take effect after you confirm.")
            }
        } catch let actionError as DomainHistoryDomainActionError {
            return .rejected(
                title: Self.domainHistoryDomainActionRejectionTitle(for: actionError),
                message: actionError.localizedDescription
            )
        } catch {
            return .rejected(title: "Domain cannot be added", message: error.localizedDescription)
        }
    }

    func removeAllowedDomainFromDraft(_ domain: String) {
        guard let draft = filterEditDraft else {
            return
        }

        filterEditDraft = FilterEditDraftEditor.removeAllowedDomain(domain, from: draft)
    }

    func undoAllowedDomainDraftChange(_ domain: String) {
        guard let draft = filterEditDraft else {
            return
        }

        filterEditDraft = FilterEditDraftEditor.undoAllowedDomainChange(
            domain,
            in: draft,
            configuredAllowedDomains: configuration.allowedDomains
        )
    }

    func prepareAndApplyFilterDraft() async {
        guard let filterEditDraft else {
            return
        }

        guard filterDraftHasChanges else {
            return
        }

        if let validationMessage = filterDraftValidationMessage {
            filterPreparationState = .failed(message: validationMessage)
            isFilterPreparationScreenPresented = true
            return
        }

        var nextConfiguration = configuration
        nextConfiguration.enabledBlocklistIDs = filterEditDraft.enabledBlocklistIDs
        nextConfiguration.customBlocklists = filterEditDraft.customBlocklists
        nextConfiguration.blockedDomains = filterEditDraft.blockedDomains
        nextConfiguration.allowedDomains = filterEditDraft.allowedDomains

        let shouldRestoreProtection = configuration.protectionEnabled || isProtectionEnabledStatus(vpnStatus)
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

            configuration = nextConfiguration
            updateCustomBlocklistHashes(prepared.customResult.sourceHashes)
            applyCatalogSyncResult(prepared.catalogResult)
            try await persistSharedState(preparedSnapshot: prepared.snapshot)
            appendAppNetworkActivity(.changeFilters)

            await notifyTunnelSnapshotUpdated()
            await restoreProtectionIfNeeded(wasEnabled: shouldRestoreProtection)

            let ruleLabel = protectedRuleCount == 1 ? "rule" : "rules"
            catalogStatusMessage = "Prepared \(protectedRuleCount.formatted()) \(ruleLabel) for local protection."
            catalogStatusIsError = false
            self.filterEditDraft = nil
            filterEditScope = nil
            filterPreparationState = .preparing(progress: 1, message: "Success")

            try? await Task.sleep(nanoseconds: 650_000_000)
            filterPreparationState = .idle
            isFilterPreparationScreenPresented = false
        } catch {
            filterPreparationState = .failed(
                message: Self.filterPreparationFailureMessage(for: error)
            )
            isFilterPreparationScreenPresented = true
        }
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

    /// Reconciles a shared config against this device's catalog and plan so the
    /// import sheet can preview exactly what will apply and what can't.
    func importPlan(for shared: ShareableFilterConfiguration) -> ShareableFilterImportPlan {
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
            // Import preserves the recipient's allowlist, which also counts
            // against the tier rule budget at snapshot-prep time.
            preservedRuleCount: configuration.allowedDomains.count
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

        do {
            let prepared = try await prepareFilterSnapshot(for: nextConfiguration)
            configuration = nextConfiguration
            updateCustomBlocklistHashes(prepared.customResult.sourceHashes)
            applyCatalogSyncResult(prepared.catalogResult)
            try await persistSharedState(preparedSnapshot: prepared.snapshot)
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

    private static func filterPreparationFailureMessage(for error: Error) -> String {
        let prefix = "Previous filters are still active. "

        if let syncError = error as? BlocklistCatalogSyncError {
            switch syncError {
            case .checksumMismatch, .noAcceptedSourceHashes:
                return prefix + "Lava is still preparing an update for this blocklist source. Try again shortly."
            case .noCachedCatalog:
                return prefix + "Lava could not reach the source catalog. Check your connection and try again."
            case .invalidHTTPStatus, .invalidCatalog:
                return prefix + "Lava could not refresh the source catalog. Try again shortly."
            case .invalidBlocklistEncoding, .blocklistTooLarge, .noRulesAvailable:
                return prefix + syncError.localizedDescription
            case .missingEnabledBlocklistSource:
                return prefix + "A selected blocklist is no longer available. Choose another list and try again."
            }
        }

        return prefix + error.localizedDescription
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
            await prepareAndApplyFilterDraft()
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
        guard showsTemporaryProtectionPauseControls else {
            return
        }

        let request = option.protectionCommandRequest
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

        Task {
            await liveActivityController.reconcile(
                usesLiveActivities: usesLiveActivities,
                protectionState: liveActivityProtectionState,
                resumeDate: temporaryProtectionPauseUntil,
                shieldStyle: lavaGuardLook,
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
        case .resume:
            resumeProtectionNow()
        case .reconnect:
            reconnectProtection()
        }
    }

    private var liveActivityProtectionState: LavaActivityAttributes.ProtectionState? {
        guard vpnStatus == .connected else {
            return nil
        }

        if isProtectionTemporarilyPaused {
            return .paused
        }

        // No network path: there is nothing to reconnect to and Lava resumes on
        // its own when the path returns, so this gets its own informational DI
        // state instead of falsely reporting "On".
        if protectionConnectivityAssessment.severity == .networkUnavailable {
            return .networkUnavailable
        }

        // DNS is being re-established after a network change (transient). Show
        // the reconnecting glyph rather than the all-clear checkmark.
        if protectionConnectivityAssessment.severity == .recovering {
            return .reconnecting
        }

        // Surface the reconnect-needed state (same assessment that drives the
        // Guard tab) so the Dynamic Island shows the triangle + Reconnect button.
        if protectionConnectivityAssessment.primaryAction == .reconnect {
            return .needsReconnect
        }

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

    func applyOnboardingRecommendedDefaults() {
        let defaults = AppConfiguration.lavaRecommendedDefaults
        configuration.enabledBlocklistIDs = defaults.enabledBlocklistIDs
        configuration.resolverPresetID = defaults.resolverPresetID
        configuration.customResolverAddress = defaults.customResolverAddress
        configuration.customResolverName = defaults.customResolverName
        configuration.fallbackToDeviceDNS = defaults.fallbackToDeviceDNS
        configuration.keepFilteringCounts = defaults.keepFilteringCounts
        configuration.keepDomainDiagnostics = defaults.keepDomainDiagnostics
        configuration.keepNetworkActivity = defaults.keepNetworkActivity
        rebuildEnabledBlockRules()
        persistFilterChanges()
        startOnboardingDefaultBlocklistSyncIfNeeded()
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

    func toggleBlocklist(_ blocklist: BlocklistSource) {
        if configuration.enabledBlocklistIDs.contains(blocklist.id) {
            configuration.enabledBlocklistIDs.remove(blocklist.id)
            rebuildEnabledBlockRules()
            catalogStatusMessage = "Disabled \(blocklist.name)."
            catalogStatusIsError = false
            persistFilterChanges()
            return
        }

        guard catalogSourcesByID[blocklist.id] != nil else {
            catalogStatusMessage = "This source is not available yet."
            catalogStatusIsError = true
            return
        }

        guard !isSyncingCatalog else {
            catalogStatusMessage = "Finish the current filter update first."
            catalogStatusIsError = false
            return
        }

        guard !enabledIDsExceedSoftRuleBudget(configuration.enabledBlocklistIDs.union([blocklist.id])) else {
            catalogStatusMessage = filterRuleBudgetMessage()
            catalogStatusIsError = true
            return
        }

        guard cachedBlockRuleSets[blocklist.id] != nil else {
            configuration.enabledBlocklistIDs.insert(blocklist.id)
            catalogStatusMessage = "Downloading \(blocklist.name)..."
            catalogStatusIsError = false
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
    }

    func addCustomBlocklist(displayName: String, rawURL: String) -> String? {
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
        } catch {
            vpnMessage = "Could not clear local history: \(error.localizedDescription)"
            vpnMessageIsError = true
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
        } catch {
            vpnMessage = "Could not clear local filtering counts: \(error.localizedDescription)"
            vpnMessageIsError = true
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
        } catch {
            vpnMessage = "Could not clear local logs: \(error.localizedDescription)"
            vpnMessageIsError = true
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
            generatedAt: generatedAt
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

        guard networkActivityLogReadGate.shouldRead(modifiedAt: modifiedAt, force: force) else {
            return
        }

        networkActivityLog = NetworkActivityLogPersistence.load(from: networkActivityLogURL)
        networkActivityLogReadGate.markRead(modifiedAt: modifiedAt)
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
                await uploadPendingEncryptedBackupIfPossible()
                await refreshAccountDeveloperAccess()
                await syncLavaSecurityPlusEntitlementIfPossible(lavaSecurityPlusStore.entitlement)
            } catch AccountAuthError.cancelled {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Sign in was cancelled."
                accountAuthMessageIsError = false
            } catch AccountAuthError.notConfigured {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Account login needs LavaSupabaseURL and LavaSupabaseAnonKey in the app configuration before backup upload can be enabled."
                accountAuthMessageIsError = true
            } catch {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Could not sign in: \(error.localizedDescription)"
                accountAuthMessageIsError = true
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
                await uploadPendingEncryptedBackupIfPossible()
                await refreshAccountDeveloperAccess()
                await syncLavaSecurityPlusEntitlementIfPossible(lavaSecurityPlusStore.entitlement)
            } catch AccountAuthError.cancelled {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Sign in was cancelled."
                accountAuthMessageIsError = false
            } catch AccountAuthError.notConfigured {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Account login needs LavaSupabaseURL and LavaSupabaseAnonKey in the app configuration before backup upload can be enabled."
                accountAuthMessageIsError = true
            } catch AccountAuthError.googleClientIDNotConfigured {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Google sign-in needs the Google iOS and Web client IDs in the app configuration."
                accountAuthMessageIsError = true
            } catch {
                accountAuthState = accountAuthService.state
                accountAuthMessage = "Could not sign in: \(error.localizedDescription)"
                accountAuthMessageIsError = true
            }
        }
    }

    func signOutAccount() {
        accountAuthService.signOut()
        accountAuthState = accountAuthService.state
        isAccountDeveloper = false
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
            isAccountDeveloper = false
            loadEncryptedBackupState()
            return true
        } catch {
            accountAuthState = accountAuthService.state
            accountAuthMessage = "Could not delete account: \(error.localizedDescription)"
            accountAuthMessageIsError = true
            return false
        }
    }

    func refreshAccountDeveloperAccess() async {
        do {
            guard let session = try await accountAuthService.currentBackupSession() else {
                accountAuthState = accountAuthService.state
                isAccountDeveloper = false
                return
            }

            accountAuthState = accountAuthService.state
            isAccountDeveloper = await accountQAStatusResponseIsDeveloper(accessToken: session.accessToken)
        } catch {
            accountAuthState = accountAuthService.state
            isAccountDeveloper = false
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
            catalogVersionHint: catalogVersion
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
        let envelope = try await loadAvailableEncryptedBackupEnvelope()

        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: BackupConfigurationPayload
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
        case .recoveryCode:
            do {
                payload = try decryptWithNormalizedRecoveryPhrase(trimmedSecret, envelope: envelope)
            } catch {
                throw EncryptedBackupError.invalidRecoveryPhrase
            }
        case .passkey:
            let prfOutput = try await passkeyPRFOutputForRestore(envelope: envelope)
            do {
                payload = try envelope.decryptWithPasskeyPRFOutput(prfOutput)
            } catch {
                throw EncryptedBackupError.invalidPasskeyUnlock
            }
        }

        configuration = payload.restoredConfiguration()
        try await persistSharedState()
        try? saveLocalEncryptedBackupEnvelope(envelope)

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
            return
        }

        var store = DiagnosticsPersistence.load(from: diagnosticsURL)
        diagnosticsReadGate.markRead(modifiedAt: modifiedAt)
        var shouldPersistClearedLogs = false

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
            debugLogEntries: loadBugReportDebugLogEntries()
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

    func syncCatalog() async {
        if let catalogSyncTask {
            await catalogSyncTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.performCatalogSync()
        }
        catalogSyncTask = task
        await task.value
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

    private func performCatalogSync(operationID: LatencyOperationID = .make()) async {
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

        let shouldRestoreProtection = configuration.protectionEnabled || isProtectionEnabledStatus(vpnStatus)
        isSyncingCatalog = true
        catalogStatusMessage = "Fetching from the server..."
        catalogStatusIsError = false
        var shouldAttemptProtectionRestore = false

        do {
            let enabledIDs = configuration.enabledBlocklistIDs
            let customSources = enabledCustomBlocklists(in: configuration)
            let result = try await Task.detached(priority: .utility) {
                let synchronizer = BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL)
                let catalogResult = try await synchronizer.sync(enabledSourceIDs: enabledIDs)
                let customResult = try await synchronizer.syncCustomBlocklists(customSources)
                return (catalogResult, customResult)
            }.value

            applySyncResults(catalogResult: result.0, customResult: result.1)
            try await persistSharedState()
            await notifyTunnelSnapshotUpdated(operationID: operationID)

            catalogStatusMessage = "Refreshed"
            catalogStatusIsError = false

            shouldAttemptProtectionRestore = true
            actionStatus = "refreshed"
        } catch {
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
            catalogStatusMessage = "Using saved downloaded filters."
            catalogStatusIsError = false
        } catch {
            catalogStatusMessage = "Filters will update from Lava Security's source catalog."
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
    }

    private var preparedBugReportInputs: PreparedBugReportInputs?

    private func makeBugReportBundle(context: BugReportContext) -> BugReportBundle {
        makeBugReportBundle(
            context: context,
            inputs: PreparedBugReportInputs(
                snapshot: currentSnapshot(),
                debugLogEntries: loadBugReportDebugLogEntries()
            )
        )
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
            debugLogEntries: inputs.debugLogEntries
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

    private func accountQAStatusResponseIsDeveloper(accessToken: String) async -> Bool {
        do {
            return try await AccountQAAccessClient(urlSession: .shared).isAccountDeveloper(
                accessToken: accessToken
            )
        } catch {
            return false
        }
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
        PreparedFilterSnapshotSummary(
            snapshot: snapshot,
            blocklistRuleCount: preparedBlocklistRuleCount(),
            blocklistSourceRuleCounts: preparedBlocklistSourceRuleCounts()
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
            catalogStatusMessage = "Using prepared local filters."
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
            let artifactStore = FilterArtifactStore(directoryURL: containerURL)
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
                cachedCatalog: cachedCatalog
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

            let artifactStore = FilterArtifactStore(directoryURL: containerURL)
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

        let compactSnapshotURL = containerURL.appendingPathComponent(LavaSecAppGroup.compactSnapshotFilename)
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
        threatGuardrail = reusable.preparedSnapshot.snapshot.nonAllowableThreatRules
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
        reportProgress: ((FilterPreparationProgressUpdate) async -> Void)? = nil,
        trace: LatencyTrace? = nil,
        parentSpan: LatencySpan? = nil
    ) async throws -> FilterSnapshotPreparationResult {
        guard let cacheURL = catalogCacheURL, let service = filterSnapshotPreparationService else {
            throw LavaSecAppError.appGroupUnavailable
        }

        migrateLowRiskLaunchCacheIfNeeded(cacheURL: cacheURL)
        let customSources = enabledCustomBlocklists(in: configuration)
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
            customListPolicy: customListPolicy,
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
            vpnMessage = Self.vpnErrorMessage(prefix: "Resumed protection, but could not refresh filters", error: error)
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

    @discardableResult
    private func migrateLowRiskLaunchCacheIfNeeded(cacheURL: URL) -> Bool {
        let changed = BlocklistCatalogSynchronizer.migrateLowRiskLaunchCacheIfNeeded(
            in: cacheURL,
            requiredSourceIDs: Set(DefaultCatalog.curatedSources.map(\.id))
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
        threatGuardrail = result.guardrailRuleSet

        for source in result.catalog.sources {
            sourceStates[source.id] = result.usedCachedSourceIDs.contains(source.id) ? .nosync : .sync
        }

        rebuildEnabledBlockRules()
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

            catalogStatusMessage = "Using saved downloaded filters. Update failed: \(originalError.localizedDescription)"
            catalogStatusIsError = false
            return true
        } catch {
            catalogStatusMessage = "Could not update filters: \(originalError.localizedDescription)"
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
        guard let configurationURL,
              let data = try? Data(contentsOf: configurationURL),
              let persistedConfiguration = try? JSONDecoder().decode(AppConfiguration.self, from: data)
        else {
            return
        }

        configuration = persistedConfiguration
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
    private func persistPreparedSnapshotArtifacts(_ preparedSnapshot: PreparedFilterSnapshot) async throws {
        guard let containerURL = LavaSecAppGroup.containerURL,
              let service = filterSnapshotPreparationService
        else {
            throw LavaSecAppError.appGroupUnavailable
        }

        try await service.persistArtifacts(
            preparedSnapshot,
            containerURL: containerURL,
            snapshotFilename: LavaSecAppGroup.snapshotFilename,
            compactSnapshotFilename: LavaSecAppGroup.compactSnapshotFilename
        )
    }

    private func persistSharedState(
        preparedSnapshot: PreparedFilterSnapshot? = nil,
        rewritesRuleArtifacts: Bool = true
    ) async throws {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            throw LavaSecAppError.appGroupUnavailable
        }

        // rewritesRuleArtifacts is false when the snapshot was just reused from
        // the on-disk artifacts (identical bytes) or when only configuration
        // state changed: re-encoding the prepared JSON and rebuilding the
        // compact artifact were measured as the bulk of warm turn-on cost.
        let snapshotToPersist = preparedSnapshot ?? preparedSnapshotForCurrentConfiguration()
        if rewritesRuleArtifacts, snapshotToPersist.summary.coversEnabledBlocklists(in: configuration) {
            try await persistPreparedSnapshotArtifacts(snapshotToPersist)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let configurationURL = containerURL.appendingPathComponent(LavaSecAppGroup.configurationFilename)
        let configurationData = try encoder.encode(configuration)
        try configurationData.write(to: configurationURL, options: [.atomic])
        scheduleAutomaticBackupAfterConfigurationChange()
    }

    private func persistConfigurationOnly() throws {
        guard let configurationURL else {
            throw LavaSecAppError.appGroupUnavailable
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let configurationData = try encoder.encode(configuration)
        try configurationData.write(to: configurationURL, options: [.atomic])
        scheduleAutomaticBackupAfterConfigurationChange()
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
            recordEncryptedBackupUpload(uploadedAt: uploadedAt)
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
                recordEncryptedBackupUpload(uploadedAt: uploadedAt)
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

    private func scheduleAutomaticBackupAfterConfigurationChange() {
        guard isAutomaticBackupEnabled, encryptedBackupState.isConfigured else {
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

    private func loadLocalEncryptedBackupEnvelope() -> ZeroKnowledgeBackupEnvelope? {
        backupEnvelopeStore.loadEnvelope()
    }

    private func notifyTunnelSnapshotUpdated(operationID: LatencyOperationID? = nil) async {
        await sendTunnelMessage(
            LavaSecAppGroup.reloadSnapshotMessage,
            fallbackMessage: "Updated filters. Restart protection if the VPN does not pick them up.",
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
        if tunnelManager == nil {
            do {
                tunnelManager = try await loadExistingTunnelManager()
            } catch {
                vpnMessage = fallbackMessage
                vpnMessageIsError = false
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
            vpnMessage = fallbackMessage
            vpnMessageIsError = false
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

    private var configurationURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.configurationFilename)
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
