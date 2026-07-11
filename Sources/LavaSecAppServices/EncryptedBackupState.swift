import Foundation
import LavaSecKit

/// Presentation state for the local encrypted-settings backup.
///
/// A pure value type: it derives all of its user-facing copy from the persisted
/// facts (whether an envelope exists, its estimated size, and the last upload
/// time). `BackupEnvelopeStore.currentState()` is the single producer; the app
/// mirrors the result onto an `@Published` property. Kept in LavaSecCore so the
/// signed-in/signed-out copy branching is unit-tested rather than source-pinned.
public enum EncryptedBackupState: Equatable, Sendable {
    /// No encrypted backup envelope exists on this device.
    case off
    /// A local envelope exists but has no recorded upload timestamp.
    case waitingForSignIn(estimatedByteSize: Int)
    /// The local envelope has a recorded upload timestamp.
    case synced(estimatedByteSize: Int, uploadedAt: Date)
    /// Backup setup remains configured but its latest operation failed with this message.
    case failed(message: String)

    /// Whether the state represents an existing backup configuration.
    public var isConfigured: Bool {
        switch self {
        case .off:
            false
        case .waitingForSignIn,
             .synced,
             .failed:
            true
        }
    }

    /// Short state summary using the signed-out copy variant.
    public var summaryText: String {
        displayText(isAccountSignedIn: false).summary
    }

    /// Detailed state copy using the signed-out copy variant.
    public var detailText: String {
        displayText(isAccountSignedIn: false).detail
    }

    /// Returns summary and detail copy adapted to the caller's account state.
    public func displayText(isAccountSignedIn: Bool) -> (summary: String, detail: String) {
        switch self {
        case .off:
            if isAccountSignedIn {
                return ("Pending setup", "Set up encrypted backup for this account.")
            }
            return ("Off", "Sign in to set up encrypted backup.")
        case .waitingForSignIn:
            if isAccountSignedIn {
                return ("Not uploaded yet", "Encrypted locally. Back up now to store a copy online.")
            }
            return ("Ready after sign-in", "Encrypted locally. Sign in to upload.")
        case .synced(_, let uploadedAt):
            return (LavaCoreStrings.localizedFormat("core.backup.lastUploaded", Self.formattedUploadDate(uploadedAt)), syncedDetailText)
        case .failed(let message):
            return ("Needs attention", message)
        }
    }

    private var syncedDetailText: String {
        switch self {
        case .synced(let estimatedByteSize, _):
            return "Latest encrypted settings backup size is \(Self.formattedByteSize(estimatedByteSize))."
        case .off,
             .waitingForSignIn,
             .failed:
            return ""
        }
    }

    private static func formattedByteSize(_ byteSize: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    private static func formattedUploadDate(_ uploadedAt: Date) -> String {
        LocalLogTimestampFormatter.string(from: uploadedAt)
    }
}
