import Foundation

/// Durable explicit protection direction used to decide whether a cold app launch may
/// automatically restore the local VPN.
///
/// The shared configuration/library pair is owned by the foreground app and the headless Focus
/// switch, so an accepted user OFF must never rewrite that generation-owned pair merely to make
/// the user intent survive a relaunch. This app-owned sidecar has one writer and is atomically
/// replaced as a small control-plane file instead. Its absence preserves the pre-sidecar
/// configuration fallback for existing installs; a valid stored value is authoritative. A corrupt
/// or unreadable sidecar is restore-ineligible rather than falling back to a possibly stale
/// `configuration.protectionEnabled == true`.
///
/// The app writes this file only while it owns the protection lifecycle mutation fence, before
/// the associated stop/disarm or start/reconnect lifecycle mutations. It deliberately carries no
/// configuration generation and never reads or writes the filter-library pair (INV-PERSIST-3).
/// - pinned: ProtectionRestoreIntentStoreTests.testPersistingOffCannotClobberNewerFocusConfigurationOrLibraryPair
public enum ProtectionRestoreIntentStore {
    /// Sidecar filename under the shared App Group container.
    public static let filename = "protection-restore-intent.json"

    /// Classification of the durable explicit-intent sidecar.
    public enum ReadOutcome: Equatable, Sendable {
        /// A complete, valid explicit user direction was read from disk.
        case stored(isEnabled: Bool)
        /// The sidecar has never been written, so callers retain the legacy configuration fallback.
        case absent
        /// The sidecar was readable but was not a valid payload.
        case corrupt
        /// The sidecar exists but its contents cannot currently be read.
        case unreadable

        /// Resolves the effective cold-launch intent.
        ///
        /// Only an absent sidecar retains the compatibility fallback. A corrupt or unreadable
        /// record is deliberately restore-ineligible: treating either as absence could resurrect
        /// a stale configuration true after an explicit OFF whose sidecar is unavailable.
        public func resolvedIntent(fallingBackTo configurationEnabled: Bool) -> Bool {
            switch self {
            case let .stored(isEnabled):
                isEnabled
            case .absent:
                configurationEnabled
            case .corrupt, .unreadable:
                false
            }
        }
    }

    /// Thrown when an existing durable intent cannot be read and therefore must not be replaced.
    ///
    /// This is the sidecar equivalent of the shared-pair writer fence in `INV-PERSIST-1`: a
    /// replacement cannot claim success over a file whose existing value the app could not inspect.
    public struct ExistingIntentUnreadableError: Error, Sendable {}

    private struct PersistedIntent: Codable, Sendable {
        let isEnabled: Bool
    }

    /// Kept visible to the executable contract so a future refactor cannot silently change the
    /// crash barrier from atomic replacement to an in-place write.
    static var atomicWritingOptions: Data.WritingOptions {
        SharedStateFileProtection.atomicControlPlaneWritingOptions
    }

    /// Returns the sidecar URL beneath an App Group container.
    public static func fileURL(containerURL: URL) -> URL {
        containerURL.appendingPathComponent(filename)
    }

    /// Reads and classifies the durable explicit direction without collapsing unavailable data
    /// into an absent record.
    public static func read(
        containerURL: URL,
        fileManager: FileManager = .default
    ) -> ReadOutcome {
        switch SharedStateFileReader.read(
            PersistedIntent.self,
            from: fileURL(containerURL: containerURL),
            fileManager: fileManager
        ) {
        case let .loaded(intent):
            .stored(isEnabled: intent.isEnabled)
        case .absent:
            .absent
        case .corrupt:
            .corrupt
        case .unreadable:
            .unreadable
        }
    }

    /// Atomically persists an accepted explicit user direction.
    ///
    /// The sole writer is the app's lifecycle action path. Before replacement, refuse an existing
    /// but unreadable file so a failed/locked read cannot be treated as permission to overwrite a
    /// prior user choice. Readable corruption is intentionally replaceable: the newly accepted
    /// explicit choice is authoritative and the atomic write repairs the damaged sidecar.
    public static func persist(
        isEnabled: Bool,
        containerURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let url = fileURL(containerURL: containerURL)
        guard !SharedStateFileReader.fileExistsButIsUnreadable(at: url, fileManager: fileManager) else {
            throw ExistingIntentUnreadableError()
        }
        let data = try JSONEncoder().encode(PersistedIntent(isEnabled: isEnabled))
        try data.write(to: url, options: atomicWritingOptions)
    }
}
