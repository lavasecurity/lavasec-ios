import Foundation
import LavaSecKit

/// Narrow key/value seam the backup envelope store persists through. Mirrors the
/// `ProtectionKeyValueStorage` pattern but for `Data` + `Date` (the envelope is
/// stored as JSON, with a separate last-upload timestamp). A test double can
/// implement this in memory; production wraps `UserDefaults`.
public protocol BackupEnvelopeStorage: Sendable {
    /// Returns persisted data for a key, or `nil` when no data is stored.
    func data(forKey key: String) -> Data?
    /// Returns a persisted date for a key, or `nil` when no date is stored.
    func date(forKey key: String) -> Date?
    /// Stores data under the supplied key.
    func set(_ value: Data, forKey key: String)
    /// Stores a date under the supplied key.
    func set(_ value: Date, forKey key: String)
    /// Removes any value stored under the supplied key.
    func removeObject(forKey key: String)
}

/// `UserDefaults`-backed implementation of backup-envelope key/value storage.
public struct BackupEnvelopeUserDefaultsStorage: BackupEnvelopeStorage, @unchecked Sendable {
    private let defaults: UserDefaults

    /// Creates storage backed by the supplied defaults database.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Reads a data value from the defaults database.
    public func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    /// Reads a date value from the defaults database.
    public func date(forKey key: String) -> Date? {
        defaults.object(forKey: key) as? Date
    }

    /// Writes a data value to the defaults database.
    public func set(_ value: Data, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    /// Writes a date value to the defaults database.
    public func set(_ value: Date, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    /// Removes a value from the defaults database.
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
    package enum Keys {
        package static let envelope = "lavasec.encryptedBackupEnvelope.pending"
        package static let lastUploadedAt = "lavasec.encryptedBackup.lastUploadedAt"
    }

    /// Headroom added to the ciphertext size for the surrounding envelope JSON
    /// when estimating the stored backup size. Centralizes the literal that was
    /// duplicated across the save/load/upload paths.
    package static let reservedOverheadBytes = 1_024

    private let storage: any BackupEnvelopeStorage

    /// Creates a store using the supplied persistence implementation.
    public init(storage: any BackupEnvelopeStorage = BackupEnvelopeUserDefaultsStorage()) {
        self.storage = storage
    }

    /// Encodes an envelope as sorted-key JSON and persists it as the current local envelope.
    public func saveEnvelope(_ envelope: ZeroKnowledgeBackupEnvelope) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        storage.set(data, forKey: Keys.envelope)
    }

    /// Loads the current envelope, returning `nil` when storage is absent or malformed.
    public func loadEnvelope() -> ZeroKnowledgeBackupEnvelope? {
        guard let data = storage.data(forKey: Keys.envelope) else {
            return nil
        }

        return try? JSONDecoder().decode(ZeroKnowledgeBackupEnvelope.self, from: data)
    }

    package func recordUpload(at uploadedAt: Date) {
        storage.set(uploadedAt, forKey: Keys.lastUploadedAt)
    }

    /// Records the upload timestamp ONLY if `uploadedEnvelope` is still the current local
    /// envelope, returning whether the marker was recorded. A config/library change
    /// re-seals + saves a new local envelope while an upload is in flight (e.g. the
    /// turn-on upload or a manual Back Up Now); recording an upload for the older
    /// envelope would falsely claim the server holds the latest, when the freshly
    /// re-sealed envelope still needs uploading. The comparison is exact — the envelope
    /// is `Equatable` and a re-seal always produces a different one (fresh AES-GCM
    /// ciphertext). Extracted from the app's upload path (Phase D1) so the mid-upload
    /// re-seal race is executable: BackupEnvelopeStoreTests.
    public func recordUploadIfCurrent(
        _ uploadedEnvelope: ZeroKnowledgeBackupEnvelope,
        at uploadedAt: Date
    ) -> Bool {
        guard loadEnvelope() == uploadedEnvelope else {
            return false
        }
        recordUpload(at: uploadedAt)
        return true
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

    package func lastUploadedAt() -> Date? {
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
