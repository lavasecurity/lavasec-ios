import Foundation

/// Presentation state for the local encrypted-settings backup.
///
/// A pure value type: it derives all of its user-facing copy from the persisted
/// facts (whether an envelope exists, its estimated size, and the last upload
/// time). `BackupEnvelopeStore.currentState()` is the single producer; the app
/// mirrors the result onto an `@Published` property. Kept in LavaSecCore so the
/// signed-in/signed-out copy branching is unit-tested rather than source-pinned.
public enum EncryptedBackupState: Equatable, Sendable {
    case off
    case waitingForSignIn(estimatedByteSize: Int)
    case synced(estimatedByteSize: Int, uploadedAt: Date)
    case failed(message: String)

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

    public var summaryText: String {
        displayText(isAccountSignedIn: false).summary
    }

    public var detailText: String {
        displayText(isAccountSignedIn: false).detail
    }

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
            return ("Last uploaded \(Self.formattedUploadDate(uploadedAt))", syncedDetailText)
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
