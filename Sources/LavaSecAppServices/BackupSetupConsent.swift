import Foundation

/// Explicit acknowledgments belong to one generated recovery phrase/setup attempt.
/// A copy action never asserts that the user saved the phrase or accepted recovery risk.
public struct BackupSetupConsent: Equatable, Sendable {
    /// A new attempt invalidates every previous copy and acknowledgment event.
    public private(set) var attemptID = UUID()
    /// Whether the current phrase was copied through the local, expiring pasteboard action.
    public private(set) var copiedRecoveryPhrase = false
    /// The user's explicit confirmation that the current phrase is stored safely.
    public var savedRecoveryPhrase = false
    /// The user's explicit acceptance of losing access if all recovery methods are lost.
    public var understandsNoRecovery = false

    /// Starts a new attempt with no accepted acknowledgments.
    public init() {}

    /// Both acknowledgments are required; copying the phrase is optional.
    public var canFinish: Bool {
        savedRecoveryPhrase && understandsNoRecovery
    }

    /// Copying is optional and never changes explicit acknowledgments.
    public mutating func recordCopy() {
        copiedRecoveryPhrase = true
    }

    /// Invalidates consent when the phrase or setup method changes.
    public mutating func reset() { self = Self() }
}
