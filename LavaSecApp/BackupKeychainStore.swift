import Foundation
import LavaSecKit
import LavaSecAppServices
import Security

enum BackupKeychainStoreError: Error, LocalizedError, Sendable {
    case unexpectedItemData
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedItemData:
            "The saved backup key could not be read.".lavaLocalized
        case .unhandledStatus(let status):
            "Keychain returned status %@.".lavaLocalizedFormat(String(status))
        }
    }
}

struct BackupKeychainStore {
    private let deviceSecretAccount = "device-secret"
    private let passkeyCredentialIDAccount = "passkey-credential-id"
    private let recoveryCodeAccount = "recovery-code"
    private let keychain = GenericKeychainStore(
        service: "com.lavasec.zero-knowledge-backup",
        unexpectedItemData: BackupKeychainStoreError.unexpectedItemData,
        unhandledStatus: BackupKeychainStoreError.unhandledStatus
    )

    func saveDeviceSecret(_ deviceSecret: String) throws {
        try save(deviceSecret, account: deviceSecretAccount)
    }

    func loadDeviceSecret() throws -> String? {
        try load(account: deviceSecretAccount)
    }

    func deleteDeviceSecret() throws {
        try delete(account: deviceSecretAccount)
    }

    func savePasskeyCredentialID(_ credentialID: String) throws {
        try save(credentialID, account: passkeyCredentialIDAccount)
    }

    func loadPasskeyCredentialID() throws -> String? {
        try load(account: passkeyCredentialIDAccount)
    }

    func deletePasskeyCredentialID() throws {
        try delete(account: passkeyCredentialIDAccount)
    }

    func saveRecoveryCode(_ recoveryCode: String) throws {
        try save(recoveryCode, account: recoveryCodeAccount)
    }

    func loadRecoveryCode() throws -> String? {
        try load(account: recoveryCodeAccount)
    }

    func deleteRecoveryCode() throws {
        try delete(account: recoveryCodeAccount)
    }

    // Separate from unlock secrets: cleanup must retain the fence until every
    // artifact is gone and the durable Off marker has been committed.
    private var deletionIntentAccount: String { "deletion-intent-v1" }

    func loadDeletionIntent() throws -> BackupDeletionIntent? {
        guard let data = try keychain.loadData(account: deletionIntentAccount) else { return nil }
        return try BackupDeletionIntent.decode(data)
    }

    func saveDeletionIntent(_ intent: BackupDeletionIntent) throws {
        try keychain.saveData(JSONEncoder().encode(intent), account: deletionIntentAccount)
        guard try loadDeletionIntent() == intent else {
            throw BackupKeychainStoreError.unexpectedItemData
        }
    }

    func clearCompletedDeletionIntent() throws {
        guard try loadDeletionIntent()?.phase == .disabled else {
            throw BackupKeychainStoreError.unexpectedItemData
        }
        // SecItemDelete acknowledges absence synchronously. This is the explicit
        // enablement commit: a later read failure cannot turn that success into a
        // failed setup with an already-removed fence. Strict validation stays before it.
        try keychain.delete(account: deletionIntentAccount)
    }

    /// Roll back only this live account-deletion preflight. A confirmed cleanup,
    /// ordinary Off request or another account's intent cannot be cancelled here.
    func cancelAccountDeletionPreparation(_ expected: BackupDeletionIntent) throws {
        guard expected.version == 3, expected.retainsEnvelopeForRecovery == true,
              expected.phase == .remotePending, try loadDeletionIntent() == expected else {
            throw BackupKeychainStoreError.unexpectedItemData
        }
        try keychain.delete(account: deletionIntentAccount)
    }

    private func save(_ value: String, account: String) throws {
        try keychain.saveData(Data(value.utf8), account: account)
    }

    private func load(account: String) throws -> String? {
        guard let data = try keychain.loadData(account: account) else {
            return nil
        }

        guard let value = String(data: data, encoding: .utf8) else {
            throw BackupKeychainStoreError.unexpectedItemData
        }

        return value
    }

    private func delete(account: String) throws {
        try keychain.delete(account: account)
    }
}
