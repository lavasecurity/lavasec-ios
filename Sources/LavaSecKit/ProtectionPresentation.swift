import Foundation

/// Portable, semantic tint roles for the protection surface. The view model picks a
/// role from connection state + connectivity severity; each platform resolves the role
/// to a concrete color (iOS: `ProtectionTintRole.color`). This keeps raw, non-adaptive
/// `Color.green`/`.orange` out of the view model and gives Android the same role table.
public enum ProtectionTintRole: Equatable, Sendable {
    /// Healthy / filtering with device-DNS fallback.
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

public extension ProtectionTintRole {
    /// The tint role while protection is connected, from the connectivity severity.
    /// Exhaustive over every `ProtectionConnectivitySeverity`.
    static func connected(severity: ProtectionConnectivitySeverity) -> ProtectionTintRole {
        switch severity {
        case .healthy, .usingDeviceDNSFallback, .usingEncryptedFallback: .protected
        case .recovering:                        .transitioning
        case .dnsSlow, .needsReconnect:          .attention
        case .networkUnavailable:                .inactive
        }
    }
}
