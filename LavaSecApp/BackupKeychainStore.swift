import Foundation
import LavaSecCore
import Security

enum BackupKeychainStoreError: Error, LocalizedError, Sendable {
    case unexpectedItemData
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedItemData:
            "The saved backup key could not be read."
        case .unhandledStatus(let status):
            "Keychain returned status \(status)."
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
