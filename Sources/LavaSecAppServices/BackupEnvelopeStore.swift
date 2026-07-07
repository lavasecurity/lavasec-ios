import Foundation
import LavaSecKit

/// Narrow key/value seam the backup envelope store persists through. Mirrors the
/// `ProtectionKeyValueStorage` pattern but for `Data` + `Date` (the envelope is
/// stored as JSON, with a separate last-upload timestamp). A test double can
/// implement this in memory; production wraps `UserDefaults`.
public protocol BackupEnvelopeStorage: Sendable {
    func data(forKey key: String) -> Data?
    func date(forKey key: String) -> Date?
    func set(_ value: Data, forKey key: String)
    func set(_ value: Date, forKey key: String)
    func removeObject(forKey key: String)
}

public struct BackupEnvelopeUserDefaultsStorage: BackupEnvelopeStorage, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    public func date(forKey key: String) -> Date? {
        defaults.object(forKey: key) as? Date
    }

    public func set(_ value: Data, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func set(_ value: Date, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

/// Owns the device-local encrypted backup envelope and its last-upload
/// timestamp: JSON persistence, the reserved size overhead, and deriving the
/// `EncryptedBackupState` shown in the UI. Pure persistence + derivation — no
/// account, crypto, upload, or scheduling concerns, which stay in the app's
/// orchestration. The envelope persists in `UserDefaults.standard` (device
/// local until uploaded) exactly as before.
public struct BackupEnvelopeStore: Sendable {
    public enum Keys {
        public static let envelope = "lavasec.encryptedBackupEnvelope.pending"
        public static let lastUploadedAt = "lavasec.encryptedBackup.lastUploadedAt"
    }

    /// Headroom added to the ciphertext size for the surrounding envelope JSON
    /// when estimating the stored backup size. Centralizes the literal that was
    /// duplicated across the save/load/upload paths.
    public static let reservedOverheadBytes = 1_024

    private let storage: any BackupEnvelopeStorage

    public init(storage: any BackupEnvelopeStorage = BackupEnvelopeUserDefaultsStorage()) {
        self.storage = storage
    }

    public func saveEnvelope(_ envelope: ZeroKnowledgeBackupEnvelope) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        storage.set(data, forKey: Keys.envelope)
    }

    public func loadEnvelope() -> ZeroKnowledgeBackupEnvelope? {
        guard let data = storage.data(forKey: Keys.envelope) else {
            return nil
        }

        return try? JSONDecoder().decode(ZeroKnowledgeBackupEnvelope.self, from: data)
    }

    public func recordUpload(at uploadedAt: Date) {
        storage.set(uploadedAt, forKey: Keys.lastUploadedAt)
    }

    /// Forgets the recorded upload timestamp while keeping the local envelope.
    /// After this, `currentState()` reports `.waitingForSignIn` for a still-present
    /// envelope — used when the uploaded server copy is cleared but encrypted
    /// backup stays configured on this device and can re-upload.
    public func clearUploadMarker() {
        storage.removeObject(forKey: Keys.lastUploadedAt)
    }

    /// Removes the local envelope and its upload timestamp, so `currentState()`
    /// reports `.off`. Used when encrypted backup is fully disabled on this device.
    public func deleteEnvelope() {
        storage.removeObject(forKey: Keys.envelope)
        storage.removeObject(forKey: Keys.lastUploadedAt)
    }

    public func lastUploadedAt() -> Date? {
        storage.date(forKey: Keys.lastUploadedAt)
    }

    /// Estimated stored size of a backed-up envelope (ciphertext + envelope JSON
    /// headroom).
    public func estimatedByteSize(for envelope: ZeroKnowledgeBackupEnvelope) -> Int {
        envelope.ciphertextByteSize + Self.reservedOverheadBytes
    }

    /// Derives the presentation state from the persisted facts:
    /// no envelope → `.off`; envelope with a recorded upload → `.synced`;
    /// envelope not yet uploaded → `.waitingForSignIn`.
    public func currentState() -> EncryptedBackupState {
        guard let envelope = loadEnvelope() else {
            return .off
        }

        let estimatedByteSize = estimatedByteSize(for: envelope)
        if let uploadedAt = lastUploadedAt() {
            return .synced(estimatedByteSize: estimatedByteSize, uploadedAt: uploadedAt)
        }

        return .waitingForSignIn(estimatedByteSize: estimatedByteSize)
    }
}
