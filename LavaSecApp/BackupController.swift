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
            "Your filter changed while the backup was restoring. Try the restore again."
        case .unsupportedBackupSchema:
            "This backup was created by a newer version of Lava. Update the app to restore it."
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
    var isAccountSignedIn: Bool { get }
    var accountEmailForBackupPasskey: String? { get }
    func makeBackupConfigurationPayload() -> BackupConfigurationPayload
    func beginConfigurationReplacement() -> Int
    func isConfigurationReplacementCurrent(_ token: Int) -> Bool
    func applyRestoredBackupPayload(_ payload: BackupConfigurationPayload) async throws
    func currentBackupSession() async throws -> BackupAccountSession?
    func refreshCurrentBackupSession() async throws -> BackupAccountSession?
    func mirrorAccountAuthState()
    func notifyTunnelSnapshotUpdatedAfterRestore() async
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

    // Device-local persistence + state derivation for the encrypted backup
    // envelope (JSON + last-upload timestamp). Crypto, upload, passkey, and the
    // automatic-backup timer stay in this controller's orchestration.
    private let backupEnvelopeStore = BackupEnvelopeStore()
    private let backupKeychainStore = BackupKeychainStore()
    private let backupPasskeyCoordinator = BackupPasskeyCoordinator()
    private var pendingBackupPasskeyCredentialID: String?
    private var pendingBackupPasskey: PendingBackupPasskey?
    private var registeredBackupPasskey: RegisteredBackupPasskey?
    private let backupSyncService: (any BackupSyncServicing)?
    private var automaticBackupTask: Task<Void, Never>?
    private let automaticBackupEnabledDefaultsKeyName = "lavasec.encryptedBackup.automaticBackupEnabled"
    private let automaticBackupDelay: UInt64 = 30 * 60 * 1_000_000_000

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
    }

    deinit {
        automaticBackupTask?.cancel()
    }

    // MARK: - Derived state

    var isEncryptedBackupConfigured: Bool {
        encryptedBackupState.isConfigured
    }

    var encryptedBackupSummaryText: String {
        encryptedBackupState.displayText(isAccountSignedIn: hub.isAccountSignedIn).summary
    }

    var encryptedBackupInfoTitle: String {
        encryptedBackupSummaryText
    }

    // MARK: - Automatic backup preference

    func setAutomaticBackupEnabled(_ isEnabled: Bool) {
        guard isAutomaticBackupEnabled != isEnabled else {
            return
        }

        isAutomaticBackupEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: automaticBackupEnabledDefaultsKeyName)

        if !isEnabled {
            automaticBackupTask?.cancel()
            automaticBackupTask = nil
        }
    }

    func loadAutomaticBackupPreference() {
        isAutomaticBackupEnabled = UserDefaults.standard.object(forKey: automaticBackupEnabledDefaultsKeyName) as? Bool ?? false
    }

    // MARK: - Encrypted backups

    /// Step 1 of passkey setup: create the passkey (first authenticator ceremony) and confirm it
    /// supports PRF. The PRF output is captured separately in `validateBackupPasskey()` so the two
    /// biometric ceremonies are split across explicit UI steps rather than fired back-to-back.
    func registerBackupPasskey() async throws {
        guard let session = try await hub.refreshCurrentBackupSession() else {
            hub.mirrorAccountAuthState()
            throw BackupPasskeyError.missingAccount
        }
        hub.mirrorAccountAuthState()

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
        if let email = hub.accountEmailForBackupPasskey {
            return email
        }

        return BackupPasskeyConfiguration.displayName
    }

    func turnOnEncryptedBackup(recoveryPhrase: String) async throws {
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
        // Claim the configuration-replacement token at entry (via the hub — the gate itself
        // stays hub-owned): a filter switch suspended at its async prepare is now superseded,
        // so when it resumes its commit/rollback gate bails instead of reverting this restore.
        // Re-checked below after the unlock awaits (before any disk write or app-state
        // mutation) to cover the reverse ordering — a switch/import that starts WHILE this
        // restore awaits its envelope/passkey unlock.
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

        // A switch/import that started while we awaited the envelope/passkey unlock now owns the
        // configuration. Abort BEFORE writing the device secret or mutating app state, rather than
        // clobbering the newer owner (the reverse of the entry-token supersession above).
        guard hub.isConfigurationReplacementCurrent(replacementToken) else {
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
            // envelope locally — but BEFORE the hub persist below, not after. The persist's re-seal
            // (scheduleAutomaticBackupAfterConfigurationChange) reseals THIS local envelope to the
            // restored config/library and clears the stale upload marker; saving it AFTER the
            // persist (the prior ordering) clobbered that fresh re-seal with the pre-restore copy.
            // Best-effort: a failed local-copy write only defers the next re-seal, never corrupts.
            try? saveLocalEncryptedBackupEnvelope(localEnvelope)
        }

        // Apply the restored configuration + library through the hub (it owns both, plus the
        // config-first persist ordering that protects the unreconstructable device-global fields).
        try await hub.applyRestoredBackupPayload(payload)
        // An envelope + working device secret are now on disk, so backup IS configured on this
        // device. Refresh the cached state from the store (it was .off on a fresh device and the
        // restore never updates it otherwise), so Settings reflects "on" AND post-restore edits
        // pass the auto-backup gate instead of the stale .off short-circuiting the re-seal/upload.
        loadEncryptedBackupState()

        // Strong local so the fire-and-forget notify keeps the hub alive exactly as the
        // pre-peel `Task { await self.notifyTunnelSnapshotUpdated() }` (self = the hub) did.
        let hub = self.hub
        Task {
            await hub.notifyTunnelSnapshotUpdatedAfterRestore()
        }

        if let backupSyncService {
            if let session = try await hub.currentBackupSession() {
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

    /// Local-unlock teardown for the hub's account-deletion path: the server row is gone
    /// with the account, so drop the device-local unlock material (the local envelope is
    /// kept, matching the pre-peel behavior). The hub refreshes the published state after.
    func deleteLocalUnlockSecretsAfterAccountDeletion() {
        try? backupKeychainStore.deleteRecoveryCode()
        try? backupKeychainStore.deleteDeviceSecret()
        try? backupKeychainStore.deletePasskeyCredentialID()
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
            guard let session = try await hub.currentBackupSession() else {
                hub.mirrorAccountAuthState()
                return .unconfirmed
            }
            hub.mirrorAccountAuthState()
            try await backupSyncService.deleteRemote(session: session)
            return .deleted
        } catch BackupSyncServiceError.requestFailed(let statusCode) where statusCode == 401 {
            guard let refreshedSession = try? await hub.refreshCurrentBackupSession() else {
                hub.mirrorAccountAuthState()
                return .unconfirmed
            }
            hub.mirrorAccountAuthState()
            do {
                try await backupSyncService.deleteRemote(session: refreshedSession)
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
            guard let session = try await hub.currentBackupSession() else {
                hub.mirrorAccountAuthState()
                encryptedBackupState = .waitingForSignIn(estimatedByteSize: estimatedByteSize)
                return
            }

            hub.mirrorAccountAuthState()
            try await backupSyncService.upload(envelope, session: session)
            let uploadedAt = Date()
            guard backupEnvelopeStore.recordUploadIfCurrent(envelope, at: uploadedAt) else {
                // A re-seal replaced the local envelope mid-upload; the newer one still needs
                // uploading (the re-seal already cleared the marker / scheduled its own upload).
                encryptedBackupState = .waitingForSignIn(estimatedByteSize: estimatedByteSize)
                return
            }
            encryptedBackupState = .synced(estimatedByteSize: estimatedByteSize, uploadedAt: uploadedAt)
        } catch BackupSyncServiceError.requestFailed(let statusCode) where statusCode == 401 {
            do {
                guard let refreshedSession = try await hub.refreshCurrentBackupSession() else {
                    hub.mirrorAccountAuthState()
                    encryptedBackupState = .waitingForSignIn(estimatedByteSize: estimatedByteSize)
                    return
                }

                hub.mirrorAccountAuthState()
                try await backupSyncService.upload(envelope, session: refreshedSession)
                let uploadedAt = Date()
                guard backupEnvelopeStore.recordUploadIfCurrent(envelope, at: uploadedAt) else {
                    encryptedBackupState = .waitingForSignIn(estimatedByteSize: estimatedByteSize)
                    return
                }
                encryptedBackupState = .synced(estimatedByteSize: estimatedByteSize, uploadedAt: uploadedAt)
            } catch {
                hub.mirrorAccountAuthState()
                encryptedBackupState = .failed(message: "Encrypted locally, but upload failed: \(error.localizedDescription)")
            }
        } catch {
            hub.mirrorAccountAuthState()
            encryptedBackupState = .failed(message: "Encrypted locally, but upload failed: \(error.localizedDescription)")
        }
    }

    func uploadPendingEncryptedBackupIfPossible() async {
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
            hub.mirrorAccountAuthState()
            throw EncryptedBackupError.noBackupAvailable
        }

        guard let session = try await hub.currentBackupSession() else {
            hub.mirrorAccountAuthState()
            throw EncryptedBackupError.noBackupAvailable
        }

        hub.mirrorAccountAuthState()

        if let envelope = try await backupSyncService.fetchLatest(session: session) {
            return envelope
        }

        throw EncryptedBackupError.noBackupAvailable
    }

    func loadEncryptedBackupState() {
        encryptedBackupState = backupEnvelopeStore.currentState()
    }

    func scheduleAutomaticBackupAfterConfigurationChange() {
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
}
