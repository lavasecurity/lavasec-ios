import Foundation

/// Tracks the last observed file-modification date so unchanged files can be skipped.
public struct FileModificationReadGate: Equatable, Sendable {
    private var lastReadModifiedAt: Date?

    /// Creates a gate with an optional modification date that has already been read.
    public init(lastReadModifiedAt: Date? = nil) {
        self.lastReadModifiedAt = lastReadModifiedAt
    }

    /// Returns false without a modification date; otherwise reports whether it changed or the read is forced.
    public func shouldRead(modifiedAt: Date?, force: Bool = false) -> Bool {
        guard let modifiedAt else {
            return false
        }

        return force || modifiedAt != lastReadModifiedAt
    }

    /// Records the modification date associated with the most recent read.
    public mutating func markRead(modifiedAt: Date?) {
        lastReadModifiedAt = modifiedAt
    }

    /// Forgets the previously read date so the next dated file is treated as changed.
    public mutating func reset() {
        lastReadModifiedAt = nil
    }
}
