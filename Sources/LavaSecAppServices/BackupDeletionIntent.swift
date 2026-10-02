import Foundation

/// App-only durable intent. A completed marker keeps Off authoritative even if
/// termination happens before ordinary preferences reach disk.
public struct BackupDeletionIntent: Codable, Equatable, Sendable {
    /// Durable checkpoints allow restart without repeating an unrelated account deletion.
    public enum Phase: String, Codable, Sendable {
        /// The original account still needs a confirmed remote deletion.
        case remotePending
        /// Remote deletion was confirmed; only local teardown remains.
        case localCleanupPending
        /// Teardown completed; this marker overrides stale ordinary preferences.
        case disabled
    }

    /// Persisted record version; unknown versions are rejected conservatively.
    public let version: Int
    /// The authenticated account captured before the first deletion suspension.
    public let accountID: String
    /// Last confirmed durable checkpoint.
    public var phase: Phase
    /// Account removal retires local unlock keys but preserves encrypted recovery
    /// material. Older Off records omit this field and still delete the envelope.
    public let retainsEnvelopeForRecovery: Bool?
    /// Binds a server-confirmation receipt to this preparation, never a later deletion.
    public let operationID: UUID?

    /// Creates an intent for a known account before any network operation.
    public init(accountID: String, phase: Phase = .remotePending, retainsEnvelopeForRecovery: Bool? = nil) {
        // Older builds must not interpret retained recovery material as an Off
        // envelope they are authorized to erase. They reject this newer record.
        // Version 3 adds preparation before remote deletion; version 2's confirmed
        // cleanup-only validation remains unchanged for existing records.
        self.version = retainsEnvelopeForRecovery == true ? (phase == .remotePending ? 3 : 2) : 1
        self.accountID = accountID
        self.phase = phase
        self.retainsEnvelopeForRecovery = retainsEnvelopeForRecovery
        self.operationID = self.version == 3 ? UUID() : nil
    }

    /// Pending teardown prevents every local and remote backup writer.
    public var blocksBackupWork: Bool { phase != .disabled }

    /// Remote retries may only use the initiating account.
    public func canDeleteRemote(currentAccountID: String?) -> Bool {
        phase == .remotePending && currentAccountID == accountID
    }

    /// A separate confirmation can advance only the exact retained-envelope preparation.
    public func confirmsLocalCleanup(of preparation: Self) -> Bool {
        version == 3 && preparation.version == 3
            && retainsEnvelopeForRecovery == true && preparation.retainsEnvelopeForRecovery == true
            && phase == .localCleanupPending && preparation.phase == .remotePending
            && accountID == preparation.accountID && operationID != nil && operationID == preparation.operationID
    }

    /// Validates stored bytes without treating corruption as an absent intent.
    public static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        let supported = (value.version == 1 && value.retainsEnvelopeForRecovery != true)
            || (value.version == 2 && value.retainsEnvelopeForRecovery == true && value.phase != .remotePending)
            || (value.version == 3 && value.retainsEnvelopeForRecovery == true)
        guard supported, !value.accountID.isEmpty,
              value.accountID.trimmingCharacters(in: .whitespacesAndNewlines) == value.accountID else {
            throw CocoaError(.coderReadCorrupt)
        }
        return value
    }
}
