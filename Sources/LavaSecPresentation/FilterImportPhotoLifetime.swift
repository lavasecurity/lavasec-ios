import Foundation

/// One photo selection belongs to one import stage. A stage change cancels its
/// admission even when the system provider or image decoder is still running.
public struct FilterImportPhotoLifetime: Equatable, Sendable {
    /// The pending selection, independently of the system picker's visibility.
    public private(set) var requestID: UUID?

    /// Creates a visit with no pending photo selection.
    public init() {}

    /// Claims the photo row once until selection completes or its stage retires.
    public mutating func begin() -> UUID? {
        guard requestID == nil else { return nil }
        let id = UUID()
        requestID = id
        return id
    }

    /// Consumes only the current selection; a late decoder cannot clear a newer one.
    public mutating func finish(_ id: UUID) -> Bool {
        guard requestID == id else { return false }
        requestID = nil
        return true
    }

    /// Releases the photo row and revokes delivery from its retired stage.
    public mutating func cancel() { requestID = nil }
}
