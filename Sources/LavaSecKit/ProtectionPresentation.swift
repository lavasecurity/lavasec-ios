import Foundation

/// Portable, semantic tint roles for the protection surface. The view model picks a
/// role from connection state + connectivity severity; each platform resolves the role
/// to a concrete color (iOS: `ProtectionTintRole.color`). This keeps raw, non-adaptive
/// `Color.green`/`.orange` out of the view model and gives Android the same role table.
public enum ProtectionTintRole: Equatable, Sendable {
    /// Healthy filtering.
    case protected
    /// Slow DNS or needs reconnect — warm caution.
    case attention
    /// Recovering / connecting — in-flight.
    case transitioning
    /// Temporarily paused by the user.
    case paused
    /// Off, or no usable network path.
    case inactive
}

/// Whether the chained "forwarding unconfirmed" surface may speak over a connected severity.
public extension ProtectionConnectivitySeverity {
    /// Only healthy DNS yields to VPN verification. Fallback is itself an attention state,
    /// even when it carries queries successfully, and must not disappear behind idle traffic.
    var yieldsToUnconfirmedChainedForwarding: Bool {
        switch self {
        case .healthy: true
        case .recovering, .dnsSlow, .needsReconnect, .networkUnavailable,
             .usingDeviceDNSFallback, .usingEncryptedFallback: false
        }
    }
}

/// Maps connectivity health into platform-independent protection tint roles.
public extension ProtectionTintRole {
    /// The tint role while protection is connected, from the connectivity severity.
    /// Exhaustive over every `ProtectionConnectivitySeverity`.
    static func connected(severity: ProtectionConnectivitySeverity) -> ProtectionTintRole {
        GuardStatusPresentation(status: .connected(severity)).tintRole
    }
}
