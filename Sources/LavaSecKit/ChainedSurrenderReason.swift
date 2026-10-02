import Foundation

/// A chained lifecycle's surrender reason, shared by the engine, provider, and app.
public enum ChainedSurrenderReason: String, Equatable, Sendable {
    /// The peer remained unreachable until the outage budget expired.
    case budgetExhausted
    /// Retrying cannot clear the engine fault.
    case engineUnusable
    /// The packet loop violated the engine contract.
    case callerContractViolation
    /// The clock could not measure the outage budget safely.
    case clockUnusable

    /// Only a reachability failure can recover on another network. Other faults remain terminal.
    public var isResolvableByNetworkChange: Bool {
        switch self {
        case .budgetExhausted: true
        case .engineUnusable, .callerContractViolation, .clockUnusable: false
        }
    }

    /// The persisted marker namespace; writers and readers must use the same spelling.
    public static let markerReasonPrefix = "chained-surrendered:"

    /// The marker representation of this surrender; its existing wire spelling is preserved.
    public var markerReason: String { Self.markerReasonPrefix + rawValue }

    /// Marks recovery ready only after suppression was persisted for the next lifecycle.
    /// Legacy/unconfirmed markers stay terminal because they carry no durable-recovery evidence.
    public func markerReason(suppressionPersisted: Bool) -> String {
        suppressionPersisted && isResolvableByNetworkChange
            ? "chained-recovery-ready:" + rawValue : markerReason
    }

    /// Only a confirmed recoverable surrender may authorize degraded DNS-only recovery.
    /// pinned: ChainedStartupFailureMarkerTests.testOnlyNetworkRecoverableSurrenderKeepsTheArmedReconnectSurface
    public static func markerReasonIsRecoverableSurrender(_ reason: String) -> Bool {
        reason == Self.budgetExhausted.markerReason(suppressionPersisted: true)
    }
}
