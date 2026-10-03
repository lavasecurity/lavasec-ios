import Foundation
import LavaSecAppServices
import SwiftUI

// The encrypted-backup feature, peeled out of AppViewModel (Phase D1, lavasec-infra
// plans/2026-07-07-ios-modularization-scaffolding-plan.md): envelope persistence + crypto
// orchestration, passkey setup/validation, turn-on/restore/clear/disable, upload with the
// single 401 refresh-retry, and the debounced automatic backup. The hub (AppViewModel)
// remains the single owner of the filter library, the configuration-replacement gate,
// and tunnel messaging, and the single ROUTING point for the Supabase session (owned by
// AccountController since the Phase D3 account peel) — this controller reaches those
// only through the narrow `BackupHubBridging` surface below, mirroring the
// scoped-controller pattern of SecurityController / TemporaryProtectionPauseController.

// EncryptedBackupState lives in LavaSecAppServices so its
// signed-in/signed-out copy branching is unit-tested rather than source-pinned.

/// The hub identifies rejections that provably occurred before any configuration write.
enum ReviewedBackupApplyError: Error {
    case rejectedBeforeWrite(Error)
}

/// Returned only after the reviewed configuration/library pair is durable.
enum BackupRestoreCompletion: Equatable {
    case complete
    case filteringNeedsAttention
}

enum EncryptedBackupError: Error, LocalizedError {
    case noBackupAvailable
    case noSavedDeviceSecret
    case invalidDeviceUnlock
    case invalidRecoveryPhrase
    case noPasskeyRecovery
    case invalidPasskeyUnlock
    case passkeyRestoreRequiresSignIn
    case supersededByConcurrentConfigurationChange
    // The unlock secret was correct but the backup PAYLOAD is a newer schema this build can't
    // decode (PST-5, Codex #218). Distinct from the invalid-unlock errors so the user is told to
    // update the app, not that their device key / phrase / passkey is wrong.
    case unsupportedBackupSchema

    var errorDescription: String? {
        switch self {
        case .supersededByConcurrentConfigurationChange:
            "Your filter changed while the backup was restoring. Try the restore again.".lavaLocalized
        case .unsupportedBackupSchema:
            "This backup was created by a newer version of Lava. Update the app to restore it.".lavaLocalized
        case .noBackupAvailable:
            "No encrypted backup is available on this device yet. Sign in is needed to download a server backup.".lavaLocalized
        case .noSavedDeviceSecret:
            "No saved device unlock is available on this device. Use the recovery phrase instead.".lavaLocalized
        case .invalidDeviceUnlock:
            "This device could not unlock the backup. Use the recovery phrase instead.".lavaLocalized
        case .invalidRecoveryPhrase:
            "That recovery phrase did not unlock this backup. Check the words and try again.".lavaLocalized
        case .noPasskeyRecovery:
            "This backup was not protected with Passkey. Use this device's keychain or Recovery instead.".lavaLocalized
        case .invalidPasskeyUnlock:
            "That Passkey did not unlock this backup. Use Recovery instead.".lavaLocalized
        case .passkeyRestoreRequiresSignIn:
            "Sign in to use Passkey restore.".lavaLocalized
        }
    }
}

/// Public review data contains no unlock material; confirmation names this exact preparation.
struct BackupRestoreReview: Identifiable {
    let id: UUID
    let plan: BackupRestorePlan
}

private struct PendingBackupRestore {
    let review: BackupRestoreReview
    let replacementToken: Int
    let envelope: ZeroKnowledgeBackupEnvelope
    let newDeviceSecret: String?
    let lifecycleGeneration: UInt64
    let accountID: String?
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

/// An upload result belongs to one locally committed setup, never a cached sync state.
struct BackupSetupUploadProgress: Equatable {
    enum State: Equatable { case pending, uploading, uploaded, failed(String), unavailable }
    let id: UUID
    var state: State
}

private struct PendingBackupSetupUpload {
    let id: UUID
    let accountID: String?
    let generation: UInt64
    let envelope: ZeroKnowledgeBackupEnvelope
    let estimatedByteSize: Int
}

/// The narrow hub surface the backup controller depends on (Phase D1). Everything the
/// backup cluster needs from AppViewModel and nothing else, so the hub stays the owner
/// of the shared state:
///
/// - **Payload building**: the backup payload snapshots the live configuration + catalog
///   version + the WHOLE filter library — hub-owned state.
/// - **Gated restore application**: restore is one of the four serialized wholesale
///   configuration replacers, so it must claim/re-check the hub's ExclusiveReplacementGate
///   (opaque `Int` tokens here — the gate itself never leaves the hub) and apply the
///   restored payload through the hub's persistence funnel.
/// - **Session access**: `currentBackupSession`/`refreshCurrentBackupSession` are raw
///   pass-throughs to the AccountController-owned AccountAuthService (the hub delegates
///   through its `account` controller since the Phase D3 peel); `mirrorAccountAuthState`
///   re-publishes the service state onto AccountController's `accountAuthState`. They are
///   separate calls (not a combined call-then-mirror) so the controller preserves the
///   pre-peel mirror ordering exactly, including the sites that mirror without a session
///   call and the one restore site that calls without mirroring.
/// - **Tunnel notify**: restore pushes the new snapshot to the running tunnel.
@MainActor
protocol BackupHubBridging: AnyObject {
    var currentBackupAccountID: String? { get }
    var isAccountSignedIn: Bool { get }
    var accountEmailForBackupPasskey: String? { get }
    /// True while the hub's in-memory library ORIGINATED from a launch-time reseed
    /// (absent/corrupt store — recovery scaffolding, not user intent). The automatic-backup
    /// scheduler refuses to re-seal or upload while set, so a reseed can never propagate
    /// over the user's last good server backup (INV-PERSIST-1 blast-radius guard; the
    /// 2026-07-14 incident's latent-3). Cleared by the hub when the library becomes
    /// user-authoritative again (restore / restore-to-default / onboarding seed).
    var libraryOriginatesFromLaunchReseed: Bool { get }
    func makeBackupConfigurationPayload() -> BackupConfigurationPayload
    func beginConfigurationReplacement() -> Int
    func isConfigurationReplacementCurrent(_ token: Int) -> Bool
    func prepareBackupRestorePlan(_ payload: BackupConfigurationPayload) throws -> BackupRestorePlan
    func validateBackupRestorePlan(_ plan: BackupRestorePlan, resolverChangeConfirmed: Bool) throws
    func applyReviewedBackup(_ plan: BackupRestorePlan, replacementToken: Int, resolverChangeConfirmed: Bool) async throws -> BackupRestoreCompletion
    func currentBackupSession() async throws -> BackupAccountSession?
    func refreshCurrentBackupSession() async throws -> BackupAccountSession?
    func mirrorAccountAuthState()
    func notifyTunnelSnapshotUpdatedAfterRestore() async
}

/// Confirmed enablement and action availability for every backup presentation.
/// `value == nil` means deletion is unresolved or evidence is unavailable, never Off.
/// Automatic-upload scheduling is intentionally absent from this contract.
struct BackupEnablementPresentation: Equatable {
    enum State: String { case off, on, setup, busy, deletionPending, unavailable }
    let state: State
    let value: Bool?
    let canEnable: Bool
    let canDisable: Bool
    let canBackUp: Bool
    let canRestore: Bool
    let canChangeAutomatic: Bool
    let canRetryDeletion: Bool
}

@MainActor
final class BackupController: ObservableObject {
    @Published private(set) var encryptedBackupState: EncryptedBackupState = .off
    @Published private(set) var isBackingUpNow = false
    @Published private(set) var isBackupMaintenanceInProgress = false
    // Tracks any in-flight server write (manual, automatic, setup, or sign-in
    // upload) so Clear/Disable never overlap an upload that could resurrect the
    // row being deleted.
    private var isUploadingEncryptedBackup = false
    @Published private(set) var isAutomaticBackupEnabled = false
    @Published private(set) var isBackupEnabled = false
    @Published private(set) var remoteBackupStatus = "Checking for a backup…"
    @Published private(set) var remoteBackupAvailable = false
    @Published private(set) var remoteBackupStatusUnavailable = false
    @Published private(set) var setupUploadProgress: BackupSetupUploadProgress?
    private var pendingSetupUpload: PendingBackupSetupUpload?
    private var remoteBackupAccountID: String?
    private var hasConfirmedRemoteBackupStatus = false
    private var metadataTask: Task<Void, Never>?
    private var metadataTaskID: UUID?
    private var metadataGeneration: UInt64 = 0

    // Device-local persistence + state derivation for the encrypted backup
    // envelope (JSON + last-upload timestamp). Crypto, upload, passkey, and the
    // automatic-backup timer stay in this controller's orchestration.
    private let backupEnvelopeStore = BackupEnvelopeStore()
    private let backupKeychainStore = BackupKeychainStore()
    private let backupPasskeyCoordinator = BackupPasskeyCoordinator()
    private var pendingRestore: PendingBackupRestore?
    private var pendingBackupPasskeyCredentialID: String?
    private var pendingBackupPasskey: PendingBackupPasskey?
    private var registeredBackupPasskey: RegisteredBackupPasskey?
    private let backupSyncService: (any BackupSyncServicing)?
    // The Keychain record survives overlays/reinstalls; defaults and stale ciphertext
    // cannot authorize work while any deletion phase (including completed Off) exists.
    // Cached only when the existing lifecycle reads envelope state or commits setup.
    // Snapshot getters never touch storage; failures retain the last confirmed evidence.
    private var hasConfirmedLocalBackup: Bool?
    private var deletionIntent: BackupDeletionIntent?
    private var deletionFenceReadable = false
    private var hasBackupDeletionFence: Bool { !deletionFenceReadable || deletionIntent != nil }
    // Read-only presentation of the cached fence; snapshots never read Keychain.
    var requiresBackupDeletionRetry: Bool {
        !deletionFenceReadable || (deletionIntent != nil && deletionIntent?.phase != .disabled)
    }
    private var lifecycleGeneration: UInt64 = 0
    // Only an envelope created here with no remote client proves it has no server copy.
    // An inherited envelope or fence never acquires this provenance merely by loading.
    private var localOnlyEnvelope: ZeroKnowledgeBackupEnvelope?
    private var accountDeletionMaintenanceID: String?
    private var accountDeletionConfirmedID: String?
    // Survives the live maintenance lease even when both persistent stores reject
    // confirmation. A readable, matching preparation is still required for retry.
    private var confirmedAccountDeletion: BackupDeletionIntent?
    private var uploadTask: Task<Void, Never>?
    // Records only a live upload error, so a rejected/busy request cannot reuse an older failed state.
    private var uploadFailureSequence: UInt64 = 0
    private var automaticBackupGeneration: UInt64 = 0
    private var automaticBackupPreferenceNeedsReload = false
    private let backupEnabledDefaultsKeyName = "lavasec.encryptedBackup.enabled"
    private var automaticBackupTask: Task<Void, Never>?
    private let automaticBackupEnabledDefaultsKeyName = "lavasec.encryptedBackup.automaticBackupEnabled"
    private let automaticBackupDelay: UInt64 = 5 * 60 * 1_000_000_000

    // The hub outlives this controller (AppViewModel owns it strongly), so an unowned
    // back-reference avoids a retain cycle without weak-optional noise on every call.
    private unowned let hub: any BackupHubBridging

    init(hub: any BackupHubBridging, supabaseConfiguration: SupabaseAppConfiguration?) {
        self.hub = hub
        if let supabaseConfiguration {
            backupSyncService = SupabaseBackupSyncService(configuration: supabaseConfiguration)
        } else {
            backupSyncService = nil
        }
        reloadDeletionFence()
    }

    private func reloadDeletionFence() {
        do {
            deletionIntent = try backupKeychainStore.loadDeletionIntent()
            if let prepared = deletionIntent {
                if let confirmed = confirmedAccountDeletion, confirmed.confirmsLocalCleanup(of: prepared) {
                    deletionIntent = confirmed
                } else if let confirmed = backupEnvelopeStore.accountDeletionConfirmation(for: prepared) {
                    deletionIntent = confirmed
                }
            }
            deletionFenceReadable = true
        } catch {
            deletionFenceReadable = false
        }
    }

    private func showDeletionFenceStatus() {
        if deletionFenceReadable, deletionIntent?.phase == .disabled {
            hasConfirmedLocalBackup = false
            encryptedBackupState = .off
        } else if deletionFenceReadable, deletionIntent?.phase == .localCleanupPending {
            encryptedBackupState = .failed(message: "Online backup deleted. Local backup cleanup could not finish. Try turning off backup again.")
        } else {
            encryptedBackupState = .failed(message: deletionFenceReadable
                ? "Backup deletion is pending. Sign in to the original account and try turning off backup again."
                : "Backup state is unavailable. Unlock your device and try again.")
        }
    }

    /// Explicit setup/restore may replace completed Off, but never pending or unreadable intent.
    private func requireExplicitBackupSetupAllowed() throws {
        reloadDeletionFence()
        guard !isBackupMaintenanceInProgress, deletionFenceReadable,
              deletionIntent == nil || deletionIntent?.phase == .disabled else {
            if hasBackupDeletionFence { showDeletionFenceStatus() }
            throw EncryptedBackupError.supersededByConcurrentConfigurationChange
        }
    }

    /// Called only after the user's new local backup is successfully persisted.
    /// An acknowledged Keychain deletion commits explicit re-enable. Do not perform
    /// fallible work after that commit and then report the operation as unsuccessful.
    private func completeExplicitBackupEnablement() throws {
        if deletionIntent?.phase == .disabled {
            do {
                try backupKeychainStore.clearCompletedDeletionIntent()
            } catch {
                deletionFenceReadable = false
                showDeletionFenceStatus()
                throw error
            }
            // The store's synchronous delete acknowledged absence. Future passive
            // reads still fail closed if Keychain becomes unavailable afterwards.
            deletionIntent = nil
            deletionFenceReadable = true
        }
        UserDefaults.standard.set(true, forKey: backupEnabledDefaultsKeyName)
        hasConfirmedLocalBackup = true
        // Setup and restore enable backup, but recurring uploads require a fresh
        // opt-in. Clear any preference retained from an earlier configuration.
        setAutomaticBackupEnabled(false)
        isBackupEnabled = true
    }

    deinit {
        automaticBackupTask?.cancel()
        metadataTask?.cancel()
    }

    // MARK: - Derived state

    /// Reads already-observed native facts only. The existing host flow prevents
    /// duplicate entry while its setup/restore UI is presented, including review.
    func enablementPresentation(isSetupOrRestorePresented: Bool = false) -> BackupEnablementPresentation {
        let operationBusy = isBackingUpNow || isBackupMaintenanceInProgress || isUploadingEncryptedBackup || uploadTask != nil
        let interactionBusy = operationBusy || isSetupOrRestorePresented
        let state: BackupEnablementPresentation.State
        let value: Bool?
        if !deletionFenceReadable {
            state = .unavailable
            value = nil
        } else if let intent = deletionIntent, intent.phase != .disabled {
            state = .deletionPending
            value = nil
        } else if let confirmed = deletionIntent?.phase == .disabled ? false : hasConfirmedLocalBackup {
            value = confirmed
            state = isSetupOrRestorePresented ? .setup : operationBusy ? .busy : confirmed ? .on : .off
        } else {
            state = .unavailable
            value = nil
        }
        let ordinary = value != nil && state != .unavailable && state != .deletionPending
        let canAct = ordinary && hub.isAccountSignedIn && !interactionBusy
        let canRetryDeletion: Bool
        if deletionFenceReadable, let intent = deletionIntent, !interactionBusy {
            canRetryDeletion = intent.phase == .localCleanupPending
                || intent.canDeleteRemote(currentAccountID: hub.currentBackupAccountID)
        } else {
            canRetryDeletion = false
        }
        return BackupEnablementPresentation(
            state: state, value: value,
            canEnable: canAct && value == false,
            canDisable: canAct && value == true,
            canBackUp: canAct && value == true,
            canRestore: canAct,
            canChangeAutomatic: canAct && value == true,
            canRetryDeletion: canRetryDeletion
        )
    }

    var isEncryptedBackupConfigured: Bool {
        !hasBackupDeletionFence && loadLocalEncryptedBackupEnvelope() != nil && (try? backupKeychainStore.loadDeviceSecret()) != nil
    }

    var encryptedBackupFailureMessage: String? {
        guard case .failed(let message) = encryptedBackupState else { return nil }
        return message
    }

    var encryptedBackupSummaryText: String {
        if let message = encryptedBackupFailureMessage { return message }
        return encryptedBackupState.displayText(isAccountSignedIn: hub.isAccountSignedIn).summary
    }

    var encryptedBackupInfoTitle: String {
        "Back up your settings securely"
    }

    var backupStatusSubtitle: String {
        if !isBackupEnabled, !hasBackupDeletionFence { return "No backup".lavaLocalized }
        guard remoteBackupAccountID == hub.currentBackupAccountID else {
            return hub.currentBackupAccountID == nil ? "Backup status unavailable".lavaLocalized : "Checking for a backup…".lavaLocalized
        }
        return remoteBackupStatus.lavaLocalized
    }

    private func synchronizeRemoteBackupAccount() {
        guard remoteBackupAccountID != hub.currentBackupAccountID else { return }
        invalidateMetadataRequest()
        remoteBackupAccountID = hub.currentBackupAccountID
        hasConfirmedRemoteBackupStatus = false
        remoteBackupAvailable = false
        remoteBackupStatusUnavailable = hub.currentBackupAccountID == nil
        remoteBackupStatus = hub.currentBackupAccountID == nil ? "Backup status unavailable" : "Checking for a backup…"
    }

    private func invalidateMetadataRequest() {
        metadataGeneration &+= 1
        metadataTask?.cancel()
        metadataTask = nil
        metadataTaskID = nil
    }

    private func confirmRemoteBackupStatus(available: Bool, uploadedAt: Date?, accountID: String) {
        guard hub.currentBackupAccountID == accountID else { return }
        remoteBackupAccountID = accountID
        hasConfirmedRemoteBackupStatus = true
        if remoteBackupAvailable != available { remoteBackupAvailable = available }
        remoteBackupStatusUnavailable = false
        let subtitle: String
        if let uploadedAt, available {
            subtitle = "Last updated at %@, %@".lavaLocalizedFormat(
                uploadedAt.formatted(date: .omitted, time: .shortened),
                uploadedAt.formatted(date: .abbreviated, time: .omitted))
        } else {
            subtitle = available ? "Backup available".lavaLocalized : "No backup".lavaLocalized
        }
        if remoteBackupStatus != subtitle { remoteBackupStatus = subtitle }
    }

    /// Refresh server evidence for the current account without reading the local envelope.
    func refreshRemoteBackupStatus() async {
        synchronizeRemoteBackupAccount()
        guard !isBackupMaintenanceInProgress, !hasBackupDeletionFence,
              isBackupEnabled, hub.isAccountSignedIn else { return }
        if let metadataTask { await metadataTask.value; return }
        let taskID = UUID()
        metadataTaskID = taskID
        let task = Task { await fetchRemoteBackupStatus() }
        metadataTask = task
        await task.value
        if metadataTaskID == taskID { metadataTask = nil; metadataTaskID = nil }
    }

    private func fetchRemoteBackupStatus() async {
        guard !Task.isCancelled else { return }
        let lifecycle = lifecycleGeneration
        let accountID = hub.currentBackupAccountID
        metadataGeneration &+= 1
        let generation = metadataGeneration
        if !hasConfirmedRemoteBackupStatus {
            remoteBackupStatus = "Checking for a backup…"
            remoteBackupAvailable = false
        }
        do {
            guard let backupSyncService, let accountID,
                  let session = try await hub.currentBackupSession(),
                  session.userID == accountID, hub.currentBackupAccountID == accountID else {
                throw EncryptedBackupError.noBackupAvailable
            }
            let metadata = try await backupSyncService.fetchMetadata(session: session)
            let current = try await hub.currentBackupSession()
            guard !Task.isCancelled, generation == metadataGeneration, lifecycle == lifecycleGeneration,
                  !isBackupMaintenanceInProgress, hub.currentBackupAccountID == accountID,
                  current?.userID == accountID,
                  metadata == nil || metadata?.userID == session.userID else { return }
            confirmRemoteBackupStatus(available: metadata != nil, uploadedAt: metadata?.uploadedAt, accountID: accountID)
        } catch {
            guard generation == metadataGeneration, lifecycle == lifecycleGeneration,
                  !isBackupMaintenanceInProgress, hub.currentBackupAccountID == accountID else { return }
            if !hasConfirmedRemoteBackupStatus { remoteBackupStatus = "Backup status unavailable" }
            remoteBackupStatusUnavailable = true
        }
    }

    // MARK: - Automatic backup preference

    func setAutomaticBackupEnabled(_ isEnabled: Bool) {
        reloadDeletionFence()
        guard !isEnabled || (!hasBackupDeletionFence && deletionIntent?.phase != .disabled
            && !isBackupMaintenanceInProgress) else { return }
        // Persist Off even when this instance started with false but stale defaults say true.
        isAutomaticBackupEnabled = isEnabled
        automaticBackupPreferenceNeedsReload = false
        UserDefaults.standard.set(isEnabled, forKey: automaticBackupEnabledDefaultsKeyName)
        if !isEnabled {
            automaticBackupTask?.cancel()
            automaticBackupTask = nil
            automaticBackupGeneration &+= 1
        }
    }

    func loadAutomaticBackupPreference() {
        reloadDeletionFence()
        guard deletionFenceReadable else {
            // Unavailable Keychain evidence blocks work, not durable user consent.
            // Retrying after unlock restores the saved choice without scheduling work.
            isAutomaticBackupEnabled = false
            automaticBackupPreferenceNeedsReload = true
            automaticBackupTask?.cancel()
            automaticBackupTask = nil
            automaticBackupGeneration &+= 1
            showDeletionFenceStatus()
            return
        }
        automaticBackupPreferenceNeedsReload = false
        if hasBackupDeletionFence || deletionIntent?.phase == .disabled {
            setAutomaticBackupEnabled(false)
            if deletionIntent?.phase == .disabled {
                UserDefaults.standard.set(false, forKey: backupEnabledDefaultsKeyName)
                isBackupEnabled = false
            }
            showDeletionFenceStatus()
            return
        }
        isAutomaticBackupEnabled = UserDefaults.standard.object(forKey: automaticBackupEnabledDefaultsKeyName) as? Bool ?? false
        isBackupEnabled = UserDefaults.standard.bool(forKey: backupEnabledDefaultsKeyName)
            || backupEnvelopeStore.loadEnvelope() != nil || hasBackupDeletionFence
    }

    // MARK: - Encrypted backups

    /// Step 1 of passkey setup: create the passkey (first authenticator ceremony) and confirm it
    /// supports PRF. The PRF output is captured separately in `validateBackupPasskey()` so the two
    /// biometric ceremonies are split across explicit UI steps rather than fired back-to-back.
    func registerBackupPasskey() async throws {
        try requireExplicitBackupSetupAllowed()
        let generation = lifecycleGeneration
        let accountID = hub.currentBackupAccountID
        guard let session = try await hub.refreshCurrentBackupSession() else {
            hub.mirrorAccountAuthState()
            throw BackupPasskeyError.missingAccount
        }
        hub.mirrorAccountAuthState()
        guard generation == lifecycleGeneration, accountID == session.userID,
              accountID == hub.currentBackupAccountID else { throw EncryptedBackupError.supersededByConcurrentConfigurationChange }
        try requireExplicitBackupSetupAllowed()

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

        guard generation == lifecycleGeneration, accountID == hub.currentBackupAccountID else {
            throw EncryptedBackupError.supersededByConcurrentConfigurationChange
        }
        try requireExplicitBackupSetupAllowed()
        pendingBackupPasskeyCredentialID = registration.credentialID
        pendingBackupPasskey = nil
        registeredBackupPasskey = RegisteredBackupPasskey(
            credentialID: registration.credentialID,
            prfSalt: try BackupPasskeyCoordinator.makePRFSalt()
        )
    }

    /// Step 2 of passkey setup: assert the registered passkey (second authenticator ceremony) to
    /// capture the PRF output that wraps the backup slot. This is the same operation a new-device
    /// restore performs, so it doubles as a validation that the passkey can unlock the backup.
    func validateBackupPasskey() async throws {
        try requireExplicitBackupSetupAllowed()
        let generation = lifecycleGeneration
        let accountID = hub.currentBackupAccountID
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

        guard generation == lifecycleGeneration, accountID == hub.currentBackupAccountID else {
            throw EncryptedBackupError.supersededByConcurrentConfigurationChange
        }
        try requireExplicitBackupSetupAllowed()
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
        if let email = hub.accountEmailForBackupPasskey {
            return email
        }

        return BackupPasskeyConfiguration.displayName
    }

    func turnOnEncryptedBackup(recoveryPhrase: String) async throws {
        try requireExplicitBackupSetupAllowed()
        if loadLocalEncryptedBackupEnvelope() != nil {
            // Account deletion retains the envelope but removes its local unlock key.
            // Only a successful absent-key read permits explicit setup to replace it,
            // or a completed Off tombstone that already authorized replacement — a retry
            // after a partially failed explicit enablement must not dead-end here.
            // pinned: BackupSetupSourceTests.testSetupRequiresAbsentDeviceSecretToReplaceOrphanedEnvelope
            let orphaned = try backupKeychainStore.loadDeviceSecret() == nil
            guard orphaned || deletionIntent?.phase == .disabled else {
                throw EncryptedBackupError.supersededByConcurrentConfigurationChange
            }
        }
        let payload = hub.makeBackupConfigurationPayload()
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
            try backupKeychainStore.savePasskeyCredentialID(passkey.credentialID)
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
        // New setup has no upload receipt. Clear an orphan's prior evidence before
        // publishing the new envelope, including if the app stops before upload.
        // pinned: BackupSetupSourceTests.testSetupClearsOrphanUploadEvidenceBeforePublishingEnvelope
        backupEnvelopeStore.clearUploadMarker()
        try backupEnvelopeStore.saveEnvelope(envelope)
        try completeExplicitBackupEnablement()
        localOnlyEnvelope = backupSyncService == nil ? envelope : nil
        lifecycleGeneration &+= 1
        clearPendingBackupPasskey()
        encryptedBackupState = .waitingForSignIn(estimatedByteSize: estimatedByteSize)
        let attempt = PendingBackupSetupUpload(id: UUID(), accountID: hub.currentBackupAccountID,
            generation: lifecycleGeneration, envelope: envelope, estimatedByteSize: estimatedByteSize)
        pendingSetupUpload = attempt
        setupUploadProgress = BackupSetupUploadProgress(id: attempt.id, state: .pending)
        Task { await retrySetupUpload(attemptID: attempt.id) }
    }

    /// Retries only the committed setup envelope; never generates replacement keys or a phrase.
    func retrySetupUpload(attemptID: UUID) async {
        guard let attempt = pendingSetupUpload, attempt.id == attemptID else { return }
        guard setupUploadProgress?.state != .uploaded else { return }
        guard attempt.generation == lifecycleGeneration, attempt.accountID != nil,
              attempt.accountID == hub.currentBackupAccountID, isBackupEnabled,
              !isBackupMaintenanceInProgress, !hasBackupDeletionFence,
              loadLocalEncryptedBackupEnvelope() == attempt.envelope else {
            setupUploadProgress = BackupSetupUploadProgress(id: attemptID, state: .unavailable)
            return
        }
        guard uploadTask == nil else { return }
        setupUploadProgress = BackupSetupUploadProgress(id: attemptID, state: .uploading)
        let uploaded = await uploadEncryptedBackup(attempt.envelope, estimatedByteSize: attempt.estimatedByteSize)
        guard pendingSetupUpload?.id == attemptID,
              attempt.generation == lifecycleGeneration, attempt.accountID == hub.currentBackupAccountID,
              !isBackupMaintenanceInProgress, !hasBackupDeletionFence,
              loadLocalEncryptedBackupEnvelope() == attempt.envelope else {
            setupUploadProgress = BackupSetupUploadProgress(id: attemptID, state: .unavailable)
            return
        }
        setupUploadProgress = BackupSetupUploadProgress(id: attemptID, state: uploaded ? .uploaded
            : .failed(encryptedBackupFailureMessage ?? "Your online backup is pending. Try uploading again."))
    }

    func isSetupUploadConfirmed(attemptID: UUID) -> Bool {
        guard let attempt = pendingSetupUpload else { return false }
        return attempt.id == attemptID && attempt.accountID == hub.currentBackupAccountID
            && attempt.generation == lifecycleGeneration && !hasBackupDeletionFence
            && !isBackupMaintenanceInProgress && setupUploadProgress?.state == .uploaded
    }

    func backUpNow() async {
        await performBackup(feedbackLane: "backup.manual")
    }

    private func performBackup(feedbackLane: String?) async {
        reloadDeletionFence()
        guard !isBackingUpNow, !isBackupMaintenanceInProgress, !hasBackupDeletionFence, uploadTask == nil else {
            if hasBackupDeletionFence { showDeletionFenceStatus() }
            return
        }

        guard let envelope = loadLocalEncryptedBackupEnvelope() else {
            hasConfirmedLocalBackup = false
            encryptedBackupState = .off
            return
        }

        isBackingUpNow = true
        defer { isBackingUpNow = false }
        let feedbackID = feedbackLane.map { LavaFeedbackCoordinator.shared.begin($0) }
        let generation = lifecycleGeneration
        let failureSequence = uploadFailureSequence
        let uploaded = await uploadEncryptedBackup(
            envelope,
            estimatedByteSize: backupEnvelopeStore.estimatedByteSize(for: envelope)
        )
        // A false result also represents an unavailable account or superseded upload, not failure.
        let failed = uploadFailureSequence != failureSequence
        if let feedbackLane, let feedbackID {
            LavaFeedbackCoordinator.shared.finish(feedbackLane, feedbackID, uploaded ? .succeeded : .failed,
                cancelled: generation != lifecycleGeneration || (!uploaded && !failed))
        }
    }

    func prepareEncryptedBackupRestore(secret: String, mode: BackupRestoreMode) async throws -> BackupRestoreReview {
        try requireExplicitBackupSetupAllowed()
        let generation = lifecycleGeneration
        let accountID = hub.currentBackupAccountID
        pendingRestore = nil
        let replacementToken = hub.beginConfigurationReplacement()
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
            } catch BackupConfigurationPayloadError.unsupportedSchemaVersion {
                throw EncryptedBackupError.unsupportedBackupSchema
            } catch {
                throw EncryptedBackupError.invalidDeviceUnlock
            }
            // Device secret already present + working — no re-key needed.
        case .recoveryCode:
            do {
                payload = try envelope.decryptWithNormalizedRecoveryPhrase(trimmedSecret)
            } catch BackupConfigurationPayloadError.unsupportedSchemaVersion {
                throw EncryptedBackupError.unsupportedBackupSchema
            } catch {
                throw EncryptedBackupError.invalidRecoveryPhrase
            }
            // A recovery-phrase restore lands on a device with no working device secret, so the
            // re-key MUST succeed: without it there's no secret to re-seal with and every
            // post-restore edit silently stops backing up. Fail the restore (before any disk write
            // or app-state mutation) rather than half-restoring into that silent-drop state.
            guard let rekeyed = envelope.rekeyingDeviceSlotWithNormalizedRecoveryPhrase(
                trimmedSecret, newDeviceSecret: freshDeviceSecret
            ) else {
                throw EncryptedBackupError.invalidRecoveryPhrase
            }
            localEnvelope = rekeyed
            didRekeyDeviceSlot = true
        case .passkey:
            let prfOutput = try await passkeyPRFOutputForRestore(envelope: envelope)
            do {
                payload = try envelope.decryptWithPasskeyPRFOutput(prfOutput)
            } catch BackupConfigurationPayloadError.unsupportedSchemaVersion {
                throw EncryptedBackupError.unsupportedBackupSchema
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

        try Task.checkCancellation()
        try requireExplicitBackupSetupAllowed()
        guard generation == lifecycleGeneration, accountID == hub.currentBackupAccountID,
              hub.isConfigurationReplacementCurrent(replacementToken) else {
            throw EncryptedBackupError.supersededByConcurrentConfigurationChange
        }
        let plan = try hub.prepareBackupRestorePlan(payload)
        let review = BackupRestoreReview(id: UUID(), plan: plan)
        guard generation == lifecycleGeneration, !isBackupMaintenanceInProgress else {
            throw EncryptedBackupError.supersededByConcurrentConfigurationChange
        }
        pendingRestore = PendingBackupRestore(
            review: review, replacementToken: replacementToken, envelope: localEnvelope,
            newDeviceSecret: didRekeyDeviceSlot ? freshDeviceSecret : nil,
            lifecycleGeneration: generation, accountID: accountID
        )
        return review
    }

    func discardPreparedBackupRestore(id: UUID) {
        if pendingRestore?.review.id == id {
            pendingRestore = nil
        }
    }

    @discardableResult
    func confirmPreparedBackupRestore(id: UUID, resolverChangeConfirmed: Bool) async throws -> BackupRestoreCompletion {
        try requireExplicitBackupSetupAllowed()
        guard let pending = pendingRestore, pending.review.id == id,
              pending.lifecycleGeneration == lifecycleGeneration, pending.accountID == hub.currentBackupAccountID,
              hub.isConfigurationReplacementCurrent(pending.replacementToken) else {
            throw EncryptedBackupError.supersededByConcurrentConfigurationChange
        }
        try hub.validateBackupRestorePlan(pending.review.plan, resolverChangeConfirmed: resolverChangeConfirmed)
        isBackupMaintenanceInProgress = true
        defer { isBackupMaintenanceInProgress = false }
        let accountID = hub.currentBackupAccountID
        let checkpoint = backupEnvelopeStore.checkpoint()
        let previousDeviceSecret = try backupKeychainStore.loadDeviceSecret()
        // Consume before any await. The reviewed envelope and new unlock key stay
        // in memory until the configuration write and its ownership checks succeed.
        pendingRestore = nil
        try Task.checkCancellation()
        let completion: BackupRestoreCompletion
        do {
            completion = try await hub.applyReviewedBackup(
                pending.review.plan, replacementToken: pending.replacementToken,
                resolverChangeConfirmed: resolverChangeConfirmed
            )
        } catch ReviewedBackupApplyError.rejectedBeforeWrite(let underlying) {
            throw underlying
        }
        // A returned outcome proves the pair landed. Cancellation after that
        // point cannot discard its working unlock key for the same account.
        // An account change or failed configuration write cannot leave a staged
        // envelope that the next session (or launch) could mistake for enabled backup.
        reloadDeletionFence()
        guard pending.lifecycleGeneration == lifecycleGeneration,
              pending.accountID == hub.currentBackupAccountID,
              hub.isConfigurationReplacementCurrent(pending.replacementToken),
              deletionFenceReadable, deletionIntent == nil || deletionIntent?.phase == .disabled,
              backupEnvelopeStore.checkpoint() == checkpoint,
              try backupKeychainStore.loadDeviceSecret() == previousDeviceSecret else {
            loadEncryptedBackupState()
            throw EncryptedBackupError.supersededByConcurrentConfigurationChange
        }
        guard let deviceSecret = pending.newDeviceSecret ?? previousDeviceSecret else {
            throw EncryptedBackupError.noSavedDeviceSecret
        }
        let acceptedEnvelope = try reconcileRestoredBackupEnvelope(pending.envelope, deviceSecret: deviceSecret)
        // No suspension from this ownership check through the explicit enablement
        // commit. A failed write restores only this operation's synchronous changes.
        do {
            if let newDeviceSecret = pending.newDeviceSecret {
                try backupKeychainStore.saveDeviceSecret(newDeviceSecret)
            }
            try backupEnvelopeStore.saveEnvelope(acceptedEnvelope)
            backupEnvelopeStore.clearUploadMarker()
            try completeExplicitBackupEnablement()
        } catch {
            // Restore ciphertext before fallible Keychain cleanup: even a locked
            // keychain must not leave the uncommitted reviewed envelope enabled.
            backupEnvelopeStore.restoreCheckpoint(checkpoint)
            defer { loadEncryptedBackupState() }
            if let stagedSecret = pending.newDeviceSecret,
               try backupKeychainStore.loadDeviceSecret() == stagedSecret {
                if let previousDeviceSecret { try backupKeychainStore.saveDeviceSecret(previousDeviceSecret) }
                else { try backupKeychainStore.deleteDeviceSecret() }
            }
            throw error
        }
        lifecycleGeneration &+= 1
        // Publish the reconciled local state; no upload is implied by restoration.
        loadEncryptedBackupState()

        // Strong local so the fire-and-forget notify keeps the hub alive exactly as the
        // pre-peel `Task { await self.notifyTunnelSnapshotUpdated() }` (self = the hub) did.
        let hub = self.hub
        Task {
            await hub.notifyTunnelSnapshotUpdatedAfterRestore()
        }

        // Bookkeeping is best-effort after the explicit local restore commit.
        if let backupSyncService {
            if let session = try? await hub.currentBackupSession(), session.userID == accountID,
               hub.currentBackupAccountID == accountID, !hasBackupDeletionFence {
                try? await backupSyncService.markRestored(session: session)
            }
        }
        return completion
    }

    private func reconcileRestoredBackupEnvelope(
        _ reviewedEnvelope: ZeroKnowledgeBackupEnvelope, deviceSecret: String
    ) throws -> ZeroKnowledgeBackupEnvelope {
        let acceptedPayload = hub.makeBackupConfigurationPayload()
        let reviewedPayload = try reviewedEnvelope.decryptWithKeychainSecret(deviceSecret)
        return reviewedPayload.hasSameBackupContent(as: acceptedPayload)
            ? reviewedEnvelope
            : try reviewedEnvelope.resealingPayload(acceptedPayload, deviceSecret: deviceSecret)
    }

    /// Permanently deletes the uploaded backup copy stored for this account while
    /// keeping encrypted backup configured on this device. Only when the server copy
    /// is confirmed gone do we forget the upload marker (state returns to "not
    /// uploaded yet" and the next backup re-uploads a fresh copy). If the delete
    /// can't be confirmed, nothing local changes and the failure is surfaced — we
    /// never claim a backup was cleared when it may still exist on the server.
    func clearEncryptedBackup() async {
        reloadDeletionFence()
        guard !isBackupMaintenanceInProgress, !isBackingUpNow, !isUploadingEncryptedBackup, !hasBackupDeletionFence else {
            return
        }
        let initiatingAccountID = hub.currentBackupAccountID
        isBackupMaintenanceInProgress = true
        lifecycleGeneration &+= 1
        invalidateMetadataRequest()
        automaticBackupTask?.cancel()
        automaticBackupTask = nil
        automaticBackupGeneration &+= 1
        await uploadTask?.value
        defer { isBackupMaintenanceInProgress = false }

        switch await deleteRemoteEncryptedBackup(expectedAccountID: initiatingAccountID) {
        case .deleted:
            backupEnvelopeStore.clearUploadMarker()
            if let initiatingAccountID { confirmRemoteBackupStatus(available: false, uploadedAt: nil, accountID: initiatingAccountID) }
            loadEncryptedBackupState()
        case .unconfirmed:
            if !hasConfirmedRemoteBackupStatus { remoteBackupStatus = "Backup status unavailable" }
            remoteBackupStatusUnavailable = true
            encryptedBackupState = .failed(
                message: "Couldn't delete the backup stored for your account — you may be offline or signed out. The backup was left in place; try again when you're back online.".lavaLocalized
            )
        }
    }

    /// Turns encrypted backup off on this device: permanently deletes the uploaded
    /// copy, then tears down every local unlock (device secret, passkey credential,
    /// recovery code) plus the local envelope, and stops automatic backup. The local
    /// teardown only runs once the server copy is confirmed gone, so a failed delete
    /// preserves a durable, account-bound retry intent when removal cannot complete.
    func disableEncryptedBackup() async {
        guard !isBackupMaintenanceInProgress else { return }
        reloadDeletionFence()
        guard deletionFenceReadable else { showDeletionFenceStatus(); return }
        if deletionIntent?.phase == .disabled { return }
        if deletionIntent == nil {
            let isProvenLocalOnly = backupSyncService == nil && localOnlyEnvelope != nil
                && loadLocalEncryptedBackupEnvelope() == localOnlyEnvelope
            guard let accountID = hub.currentBackupAccountID ?? (isProvenLocalOnly ? "device-local-only" : nil) else {
                encryptedBackupState = .failed(message: "Couldn't delete the backup stored for your account — you may be offline or signed out. Backup is still on; try again when you're back online.".lavaLocalized)
                return
            }
            let intent = BackupDeletionIntent(accountID: accountID, phase: isProvenLocalOnly ? .localCleanupPending : .remotePending)
            do {
                // Synchronous Keychain acknowledgement precedes every suspension and
                // network request. UserDefaults alone is not a durable deletion fence.
                try backupKeychainStore.saveDeletionIntent(intent)
                deletionIntent = intent
            } catch {
                reloadDeletionFence()
                encryptedBackupState = .failed(message: "Backup deletion could not be saved safely. Try again.")
                return
            }
        }
        guard var intent = deletionIntent else { return }
        isBackupMaintenanceInProgress = true
        lifecycleGeneration &+= 1
        automaticBackupTask?.cancel()
        automaticBackupTask = nil
        automaticBackupGeneration &+= 1
        await uploadTask?.value
        defer { isBackupMaintenanceInProgress = false }

        if intent.phase == .remotePending {
            guard intent.canDeleteRemote(currentAccountID: hub.currentBackupAccountID) else {
                showDeletionFenceStatus(); return
            }
            guard case .deleted = await deleteRemoteEncryptedBackup(expectedAccountID: intent.accountID),
                  hub.currentBackupAccountID == intent.accountID else {
                showDeletionFenceStatus(); return
            }
            intent.phase = .localCleanupPending
            do {
                try backupKeychainStore.saveDeletionIntent(intent)
                deletionIntent = intent
            } catch {
                showDeletionFenceStatus(); return
            }
        }

        finishLocalBackupDeletion(intent)
    }

    private func finishLocalBackupDeletion(_ pendingIntent: BackupDeletionIntent) {
        var intent = pendingIntent
        // Remote deletion is confirmed and an acknowledged fence already prevents
        // another backup operation from replacing these local artifacts.
        do {
            // Independent artifacts must all be attempted, even when Keychain
            // rejects one deletion. The pending fence survives any partial result.
            var cleanupFailed = false
            do { try backupKeychainStore.deleteRecoveryCode() } catch { cleanupFailed = true }
            do { try backupKeychainStore.deleteDeviceSecret() } catch { cleanupFailed = true }
            do { try backupKeychainStore.deletePasskeyCredentialID() } catch { cleanupFailed = true }
            clearPendingBackupPasskey()
            pendingRestore = nil
            pendingSetupUpload = nil
            setupUploadProgress = nil
            localOnlyEnvelope = nil
            if intent.retainsEnvelopeForRecovery != true, !backupEnvelopeStore.deleteEnvelope() {
                cleanupFailed = true
            }
            setAutomaticBackupEnabled(false)
            guard !cleanupFailed else { throw EncryptedBackupError.invalidDeviceUnlock }
            UserDefaults.standard.set(false, forKey: backupEnabledDefaultsKeyName)
            isBackupEnabled = false
            intent.phase = .disabled
            try backupKeychainStore.saveDeletionIntent(intent)
            deletionIntent = intent
            loadEncryptedBackupState()
        } catch {
            encryptedBackupState = .failed(message: "Online backup deleted. Local backup cleanup could not finish. Try turning off backup again.")
        }
    }

    /// Settle an already-authorized Off before deleting its account. The caller holds
    /// this maintenance lease through the server request and releases it on every exit.
    func prepareForAccountDeletion(accountID: String) async throws {
        guard !isBackupMaintenanceInProgress, hub.currentBackupAccountID == accountID else {
            throw EncryptedBackupError.supersededByConcurrentConfigurationChange
        }
        reloadDeletionFence()
        guard deletionFenceReadable else {
            showDeletionFenceStatus()
            throw EncryptedBackupError.invalidDeviceUnlock
        }
        if deletionIntent?.accountID == accountID, deletionIntent?.blocksBackupWork == true {
            await disableEncryptedBackup()
            guard deletionIntent?.phase == .disabled else {
                throw EncryptedBackupError.invalidDeviceUnlock
            }
        }
        guard hub.currentBackupAccountID == accountID else {
            throw EncryptedBackupError.supersededByConcurrentConfigurationChange
        }
        accountDeletionMaintenanceID = accountID
        accountDeletionConfirmedID = nil
        isBackupMaintenanceInProgress = true
        lifecycleGeneration &+= 1
        automaticBackupTask?.cancel()
        automaticBackupTask = nil
        automaticBackupGeneration &+= 1
        await uploadTask?.value
        guard hub.currentBackupAccountID == accountID else {
            throw EncryptedBackupError.supersededByConcurrentConfigurationChange
        }
        if deletionIntent == nil {
            let intent = BackupDeletionIntent(accountID: accountID, retainsEnvelopeForRecovery: true)
            do {
                // A durable fence must exist before the caller can delete the
                // account remotely. A failed write aborts that irreversible step.
                try backupKeychainStore.saveDeletionIntent(intent)
                deletionIntent = intent
            } catch {
                reloadDeletionFence()
                throw error
            }
        }
    }

    /// Releases only the lease acquired by the account-deletion preflight.
    func finishAccountDeletionMaintenance() async {
        guard let accountID = accountDeletionMaintenanceID else { return }
        let confirmed = accountDeletionConfirmedID == accountID
        accountDeletionMaintenanceID = nil
        accountDeletionConfirmedID = nil
        // A failed server deletion cancelled the old debounce/upload generation.
        // Reconcile current content and consent for the same account. Successful
        // deletion/sign-out and a replacement account must never restart its work.
        if !confirmed, hub.currentBackupAccountID == accountID {
            if let intent = deletionIntent, intent.accountID == accountID,
               intent.version == 3, intent.retainsEnvelopeForRecovery == true, intent.phase == .remotePending {
                do {
                    // A lost deletion response is ambiguous. Only a fresh valid
                    // session for this account proves it is safe to resume backup.
                    guard let session = try await hub.refreshCurrentBackupSession(),
                          session.userID == accountID, hub.currentBackupAccountID == accountID else {
                        throw EncryptedBackupError.supersededByConcurrentConfigurationChange
                    }
                    try backupKeychainStore.cancelAccountDeletionPreparation(intent)
                    deletionIntent = nil
                    deletionFenceReadable = true
                } catch {
                    reloadDeletionFence()
                    showDeletionFenceStatus()
                }
            }
        }
        isBackupMaintenanceInProgress = false
        if !confirmed, hub.currentBackupAccountID == accountID {
            scheduleAutomaticBackupAfterConfigurationChange()
        }
    }

    /// Retires only the server-confirmed account’s unlock artifacts and deletion intent.
    func deleteLocalUnlockSecretsAfterAccountDeletion(deletedAccountID: String) {
        if accountDeletionMaintenanceID == deletedAccountID {
            accountDeletionConfirmedID = deletedAccountID
            if var prepared = deletionIntent, prepared.accountID == deletedAccountID,
               prepared.version == 3, prepared.phase == .remotePending {
                prepared.phase = .localCleanupPending
                confirmedAccountDeletion = prepared
            }
        }
        reloadDeletionFence()
        guard deletionFenceReadable else {
            if let confirmed = confirmedAccountDeletion, confirmed.accountID == deletedAccountID {
                backupEnvelopeStore.saveAccountDeletionConfirmation(confirmed)
            }
            showDeletionFenceStatus()
            return
        }
        if var intent = deletionIntent {
            guard intent.accountID == deletedAccountID else { return }
            if intent.phase == .disabled { return }
            intent.phase = .localCleanupPending
            if intent.version == 3, intent.retainsEnvelopeForRecovery == true {
                confirmedAccountDeletion = intent
            }
            do {
                try backupKeychainStore.saveDeletionIntent(intent)
                deletionIntent = intent
                finishLocalBackupDeletion(intent)
            } catch {
                // A failed primary promotion must not make a confirmed account
                // deletion demand sign-in to that deleted account on local retry.
                // The operation-bound receipt also recovers this evidence on launch.
                backupEnvelopeStore.saveAccountDeletionConfirmation(intent)
                reloadDeletionFence()
                if intent.version == 3, intent.retainsEnvelopeForRecovery == true {
                    // The earlier preparation remains durable even if promotion
                    // fails. Still attempt every independent local retirement.
                    finishLocalBackupDeletion(intent)
                } else {
                    encryptedBackupState = .failed(message: "Online backup deleted. Local backup cleanup could not finish. Try turning off backup again.")
                }
            }
            return
        }
        // The caller's preflight is the only place allowed to create this fence.
        // Never first attempt a fallible write after remote deletion has succeeded.
        encryptedBackupState = .failed(message: "Online backup deleted. Local backup cleanup could not finish. Try turning off backup again.")
    }

    private enum RemoteBackupDeletionOutcome {
        case deleted        // confirmed gone from the server, or no server copy exists
        case unconfirmed    // couldn't reach/authorize the server — a copy may remain
    }

    // Hard-deletes the server copy and reports whether it is confirmed gone, so
    // callers never claim deletion they couldn't verify. `.deleted` when the row is
    // removed for the initiating account; `.unconfirmed`
    // when signed out or the request fails. Mirrors uploadEncryptedBackup's single
    // 401 refresh-retry.
    private func deleteRemoteEncryptedBackup(expectedAccountID: String?) async -> RemoteBackupDeletionOutcome {
        guard let backupSyncService, let expectedAccountID,
              hub.currentBackupAccountID == expectedAccountID else {
            return .unconfirmed
        }

        do {
            guard let session = try await hub.currentBackupSession(),
                  session.userID == expectedAccountID, hub.currentBackupAccountID == expectedAccountID else {
                hub.mirrorAccountAuthState()
                return .unconfirmed
            }
            hub.mirrorAccountAuthState()
            try await backupSyncService.deleteRemote(session: session)
            guard try await hub.currentBackupSession()?.userID == expectedAccountID,
                  hub.currentBackupAccountID == expectedAccountID else { return .unconfirmed }
            return .deleted
        } catch BackupSyncServiceError.requestFailed(let statusCode) where statusCode == 401 {
            guard let refreshedSession = try? await hub.refreshCurrentBackupSession(),
                  refreshedSession.userID == expectedAccountID, hub.currentBackupAccountID == expectedAccountID else {
                hub.mirrorAccountAuthState()
                return .unconfirmed
            }
            hub.mirrorAccountAuthState()
            do {
                try await backupSyncService.deleteRemote(session: refreshedSession)
                guard try await hub.currentBackupSession()?.userID == expectedAccountID,
                      hub.currentBackupAccountID == expectedAccountID else { return .unconfirmed }
                return .deleted
            } catch {
                return .unconfirmed
            }
        } catch {
            hub.mirrorAccountAuthState()
            return .unconfirmed
        }
    }

    // The recovery-phrase candidate/slot precedence (decryptWithNormalizedRecoveryPhrase,
    // rekeyingDeviceSlotWithNormalizedRecoveryPhrase) lives on ZeroKnowledgeBackupEnvelope
    // in LavaSecAppServices (BackupRecoveryPhraseUnlock.swift) with executable tests.

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

    // MARK: - Upload & local envelope persistence

    @discardableResult
    private func uploadEncryptedBackup(
        _ envelope: ZeroKnowledgeBackupEnvelope,
        estimatedByteSize: Int
    ) async -> Bool {
        reloadDeletionFence()
        guard !isBackupMaintenanceInProgress, !hasBackupDeletionFence, uploadTask == nil else { return false }
        let generation = lifecycleGeneration
        let initiatingAccountID = hub.currentBackupAccountID
        var uploaded = false
        let task = Task {
            // A queued child must retain the request's owner, even if another account
            // signs in after enqueue but before this actor job starts.
            guard generation == lifecycleGeneration, initiatingAccountID == hub.currentBackupAccountID else { return }
            uploaded = await performEncryptedBackupUpload(envelope, estimatedByteSize: estimatedByteSize)
        }
        uploadTask = task
        await task.value
        uploadTask = nil
        return uploaded
    }

    private func performEncryptedBackupUpload(
        _ envelope: ZeroKnowledgeBackupEnvelope,
        estimatedByteSize: Int
    ) async -> Bool {
        guard !isBackupMaintenanceInProgress, !hasBackupDeletionFence else { return false }
        guard let backupSyncService else {
            encryptedBackupState = .waitingForSignIn(estimatedByteSize: estimatedByteSize)
            return false
        }
        let generation = lifecycleGeneration
        let initiatingAccountID = hub.currentBackupAccountID
        isUploadingEncryptedBackup = true
        defer { isUploadingEncryptedBackup = false }

        do {
            guard let session = try await hub.currentBackupSession(), session.userID == initiatingAccountID else {
                hub.mirrorAccountAuthState()
                return false
            }
            hub.mirrorAccountAuthState()
            guard generation == lifecycleGeneration, hub.currentBackupAccountID == initiatingAccountID,
                  !isBackupMaintenanceInProgress, !hasBackupDeletionFence else { return false }
            try await backupSyncService.upload(envelope, session: session)
            return recordConfirmedUpload(envelope, estimatedByteSize: estimatedByteSize,
                accountID: session.userID, generation: generation)
        } catch BackupSyncServiceError.requestFailed(let statusCode) where statusCode == 401 {
            do {
                guard let refreshedSession = try await hub.refreshCurrentBackupSession(),
                      refreshedSession.userID == initiatingAccountID else {
                    hub.mirrorAccountAuthState()
                    return false
                }
                hub.mirrorAccountAuthState()
                guard generation == lifecycleGeneration, hub.currentBackupAccountID == initiatingAccountID,
                      !isBackupMaintenanceInProgress, !hasBackupDeletionFence else { return false }
                try await backupSyncService.upload(envelope, session: refreshedSession)
                return recordConfirmedUpload(envelope, estimatedByteSize: estimatedByteSize,
                    accountID: refreshedSession.userID, generation: generation)
            } catch {
                hub.mirrorAccountAuthState()
                guard generation == lifecycleGeneration, hub.currentBackupAccountID == initiatingAccountID,
                      !isBackupMaintenanceInProgress, !hasBackupDeletionFence else { return false }
                encryptedBackupState = .failed(message: "Encrypted locally, but upload failed: %@".lavaLocalizedFormat(error.localizedDescription))
                if !Task.isCancelled { uploadFailureSequence &+= 1 }
                return false
            }
        } catch {
            hub.mirrorAccountAuthState()
            guard generation == lifecycleGeneration, hub.currentBackupAccountID == initiatingAccountID,
                  !isBackupMaintenanceInProgress, !hasBackupDeletionFence else { return false }
            encryptedBackupState = .failed(message: "Encrypted locally, but upload failed: %@".lavaLocalizedFormat(error.localizedDescription))
            if !Task.isCancelled { uploadFailureSequence &+= 1 }
            return false
        }
    }

    private func recordConfirmedUpload(_ envelope: ZeroKnowledgeBackupEnvelope, estimatedByteSize: Int,
                                       accountID: String, generation: UInt64) -> Bool {
        guard generation == lifecycleGeneration, hub.currentBackupAccountID == accountID,
              !isBackupMaintenanceInProgress, !hasBackupDeletionFence else { return false }
        invalidateMetadataRequest()
        synchronizeRemoteBackupAccount()
        let uploadedAt = Date()
        guard backupEnvelopeStore.recordUploadIfCurrent(envelope, at: uploadedAt) else {
            encryptedBackupState = .waitingForSignIn(estimatedByteSize: estimatedByteSize)
            return false
        }
        confirmRemoteBackupStatus(available: true, uploadedAt: uploadedAt, accountID: accountID)
        encryptedBackupState = .synced(estimatedByteSize: estimatedByteSize, uploadedAt: uploadedAt)
        return true
    }

    func uploadPendingEncryptedBackupIfPossible() async {
        reloadDeletionFence()
        guard !hasBackupDeletionFence, !isBackupMaintenanceInProgress else {
            if hasBackupDeletionFence { showDeletionFenceStatus() }
            return
        }
        guard let envelope = loadLocalEncryptedBackupEnvelope() else {
            return
        }

        await uploadEncryptedBackup(
            envelope,
            estimatedByteSize: backupEnvelopeStore.estimatedByteSize(for: envelope)
        )
    }

    private func loadAvailableEncryptedBackupEnvelope() async throws -> ZeroKnowledgeBackupEnvelope {
        try requireExplicitBackupSetupAllowed()
        let accountID = hub.currentBackupAccountID
        if deletionIntent == nil || deletionIntent?.retainsEnvelopeForRecovery == true,
           let envelope = loadLocalEncryptedBackupEnvelope() {
            return envelope
        }

        guard let backupSyncService
        else {
            hub.mirrorAccountAuthState()
            throw EncryptedBackupError.noBackupAvailable
        }

        guard let session = try await hub.currentBackupSession(), session.userID == accountID,
              hub.currentBackupAccountID == accountID else {
            hub.mirrorAccountAuthState()
            throw EncryptedBackupError.noBackupAvailable
        }

        hub.mirrorAccountAuthState()

        if let envelope = try await backupSyncService.fetchLatest(session: session) {
            try requireExplicitBackupSetupAllowed()
            guard accountID == hub.currentBackupAccountID else { throw EncryptedBackupError.supersededByConcurrentConfigurationChange }
            return envelope
        }

        throw EncryptedBackupError.noBackupAvailable
    }

    /// A missed/locked Keychain read may recover when protected data becomes
    /// available. Retry only that unavailable evidence, never normal polling or
    /// an in-flight operation's presentation. This reads local state only: no
    /// persisted preference changes, deletion, resealing or uploads.
    func refreshUnavailableBackupStateAfterUnlock() {
        guard (!deletionFenceReadable || automaticBackupPreferenceNeedsReload), !isBackupMaintenanceInProgress,
              !isBackingUpNow, !isUploadingEncryptedBackup, uploadTask == nil else { return }
        loadEncryptedBackupState()
        guard deletionFenceReadable else { return }
        automaticBackupPreferenceNeedsReload = false
        if deletionIntent != nil {
            isAutomaticBackupEnabled = false
            if deletionIntent?.phase == .disabled { isBackupEnabled = false }
        } else {
            // The launch-time preference load may have stopped at the unreadable
            // deletion fence. Rebuild its read-only projection after first unlock.
            isBackupEnabled = UserDefaults.standard.bool(forKey: backupEnabledDefaultsKeyName)
                || backupEnvelopeStore.loadEnvelope() != nil
            isAutomaticBackupEnabled = UserDefaults.standard.object(forKey: automaticBackupEnabledDefaultsKeyName) as? Bool ?? false
        }
    }

    func loadEncryptedBackupState() {
        reloadDeletionFence()
        if hasBackupDeletionFence { showDeletionFenceStatus(); return }
        let state = backupEnvelopeStore.currentState()
        // Maintenance may expose a staged restore to account-state reloads. Keep
        // prior enablement until an explicit setup/restore or deletion commit;
        // neither a staged envelope nor an interrupted review confirms On.
        if !isBackupMaintenanceInProgress { hasConfirmedLocalBackup = state.isConfigured }
        encryptedBackupState = state
    }

    func scheduleAutomaticBackupAfterConfigurationChange() {
        // INV-PERSIST-1 blast-radius guard (pinned: RebootFirstUnlockGuardSourceTests.testAutomaticBackupIsSuppressedWhileLibraryOriginatesFromLaunchReseed): a library
        // that originated from a launch reseed is recovery scaffolding, not user intent. Neither
        // re-seal the local envelope from it nor schedule the debounced upload — either would
        // stage/propagate a wipe over the user's last good backup (incident latent-3). Checked
        // BEFORE the re-seal below because the re-seal alone poisons the local envelope a later
        // manual upload would send. Manual Back Up Now stays available (explicit user action).
        reloadDeletionFence()
        guard !isBackupMaintenanceInProgress, !hasBackupDeletionFence else { return }
        guard !hub.libraryOriginatesFromLaunchReseed else {
            return
        }
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
        loadEncryptedBackupState()

        guard encryptedBackupState.isConfigured, isAutomaticBackupEnabled else {
            return
        }

        automaticBackupTask?.cancel()
        automaticBackupGeneration &+= 1
        let token = automaticBackupGeneration
        let generation = lifecycleGeneration
        let accountID = hub.currentBackupAccountID
        let automaticBackupDelay = automaticBackupDelay
        // The relative sleep is the only elapsed-time gate. A second wall-clock deadline
        // could discard this attempt permanently if the user or time sync moves time back.
        automaticBackupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: automaticBackupDelay)
            guard !Task.isCancelled else {
                return
            }

            await self?.runScheduledAutomaticBackup(token: token, generation: generation, accountID: accountID)
        }
    }

    private func runScheduledAutomaticBackup(token: UInt64, generation: UInt64, accountID: String?) async {
        guard token == automaticBackupGeneration else { return }
        automaticBackupTask = nil
        guard generation == lifecycleGeneration, accountID == hub.currentBackupAccountID else { return }
        guard isAutomaticBackupEnabled, !isBackupMaintenanceInProgress, !hasBackupDeletionFence else {
            return
        }

        // Scheduled uploads are background work; their completion must not
        // produce a foreground success/failure cue.
        await performBackup(feedbackLane: nil)
    }

    private func saveLocalEncryptedBackupEnvelope(_ envelope: ZeroKnowledgeBackupEnvelope) throws {
        guard !hasBackupDeletionFence, !isBackupMaintenanceInProgress else {
            throw EncryptedBackupError.supersededByConcurrentConfigurationChange
        }
        try backupEnvelopeStore.saveEnvelope(envelope)
    }

    /// Re-seal the local encrypted-backup envelope with the current config + library
    /// (keeping every key slot), so a backup reflects post-turn-on changes. Recovers the
    /// payload key via the stored device secret — no user interaction. Best-effort: if there
    /// is no local envelope or device secret, leave the existing envelope untouched.
    private func refreshLocalEncryptedBackupEnvelope() {
        guard !hasBackupDeletionFence, !isBackupMaintenanceInProgress else { return }
        guard let envelope = loadLocalEncryptedBackupEnvelope() else {
            return
        }
        let storedDeviceSecret = try? backupKeychainStore.loadDeviceSecret()
        guard let deviceSecret = storedDeviceSecret ?? nil else {
            return
        }
        let payload = hub.makeBackupConfigurationPayload()
        // Skip the re-seal entirely when the backup CONTENT is unchanged. resealingPayload mints a
        // fresh AES-GCM ciphertext every time and the marker-clear below then flips an
        // already-uploaded backup to "not uploaded"; without this gate a non-user persist (e.g.
        // reconcileTunnelSnapshotAfterLaunch on launch) would churn the backup state and schedule a
        // redundant upload with no actual change. hasSameBackupContent ignores protectionEnabledHint
        // (a frequently-toggled advisory hint) and the library's already-stripped local cache
        // tokens, so a protection pause/resume or a compile-token restamp no longer churns the
        // marker. Compare against the currently-sealed payload (recovered via the same device secret).
        // PST-5 (Codex #218): a NEWER app may have sealed a payload schema this build can't decode.
        // decryptWithKeychainSecret then throws `unsupportedSchemaVersion`; if we swallowed that and
        // fell through, resealingPayload would overwrite the newer local envelope with our schema-1
        // payload and clear its upload marker — the exact downgrade-clobber the schema ceiling exists
        // to prevent. Distinguish it and SKIP the reseal, leaving the newer envelope + marker intact.
        // Other decode failures fall through as before (treat as changed content → re-seal fresh).
        let currentPayload: BackupConfigurationPayload?
        do {
            currentPayload = try envelope.decryptWithKeychainSecret(deviceSecret)
        } catch BackupConfigurationPayloadError.unsupportedSchemaVersion {
            return
        } catch {
            currentPayload = nil
        }
        if let currentPayload, currentPayload.hasSameBackupContent(as: payload) {
            return
        }
        guard let resealed = try? envelope.resealingPayload(payload, deviceSecret: deviceSecret) else {
            return
        }
        do {
            try saveLocalEncryptedBackupEnvelope(resealed)
            if localOnlyEnvelope == envelope { localOnlyEnvelope = resealed }
        } catch { return }
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
}
