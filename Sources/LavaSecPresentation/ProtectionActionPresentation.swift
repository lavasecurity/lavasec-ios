import LavaSecKit

/// Retains the accepted action label while its native operation owns the gate.
/// Connectivity observations still update status; they cannot rename in-flight work.
public struct ProtectionActionPresentation: Equatable, Sendable {
    /// The label captured at claim, or nil after the operation releases ownership.
    public private(set) var pendingTitle: String?

    /// Creates an idle action presentation.
    public init() {}

    /// Receives the orchestrator's ownership transition before its busy UI mirror.
    /// Repeated busy observations cannot replace the original accepted action label.
    public mutating func update(action: ProtectionActionKind?, currentTitle: String) {
        if action == nil {
            pendingTitle = nil
        } else if pendingTitle == nil {
            pendingTitle = currentTitle
        }
    }
}
