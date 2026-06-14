import Foundation

public struct FileModificationReadGate: Equatable, Sendable {
    private var lastReadModifiedAt: Date?

    public init(lastReadModifiedAt: Date? = nil) {
        self.lastReadModifiedAt = lastReadModifiedAt
    }

    public func shouldRead(modifiedAt: Date?, force: Bool = false) -> Bool {
        guard let modifiedAt else {
            return false
        }

        return force || modifiedAt != lastReadModifiedAt
    }

    public mutating func markRead(modifiedAt: Date?) {
        lastReadModifiedAt = modifiedAt
    }

    public mutating func reset() {
        lastReadModifiedAt = nil
    }
}
