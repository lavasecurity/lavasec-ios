import LavaSecKit

/// Retains the accepted action label while its native operation owns the gate.
/// Connectivity observations still update status; they cannot rename in-flight work.
public struct ProtectionActionPresentation: Equatable, Sendable {
    /// The label captured at claim, or nil after the operation releases ownership.
    public private(set) var pendingTitle: String?
    private var startsProtection = false

    /// Creates an idle action presentation.
    public init() {}

    /// Receives the orchestrator's ownership transition before its busy UI mirror.
    /// Repeated busy observations cannot replace the original accepted action label.
    public mutating func update(action: ProtectionActionKind?, currentTitle: String,
                               currentStatus: ProtectionStatus? = nil) {
        if action == nil {
            pendingTitle = nil
            startsProtection = false
        } else if pendingTitle == nil {
            pendingTitle = currentTitle
            startsProtection = (action == .turnOn || action == .toggle)
                && (currentStatus == .off || currentStatus == .notInstalled)
        }
    }

    /// Accepted preparation is part of starting, even before NetworkExtension changes status.
    /// This cannot override a provider observation, an error, or a released action.
    public func status(whileObserving status: ProtectionStatus) -> ProtectionStatus {
        startsProtection && (status == .off || status == .notInstalled) ? .turningOn : status
    }

    /// Once iOS starts changing the tunnel, a later disconnect is a real outcome.
    /// Keep the accepted button label, but never revive preparation over that outcome.
    public mutating func observe(lifecycle: ProtectionLifecycleStatus) {
        switch lifecycle {
        case .connecting, .connected, .reasserting, .disconnecting: startsProtection = false
        case .invalid, .disconnected: break
        }
    }
}
