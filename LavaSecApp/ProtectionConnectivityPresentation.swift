import SwiftUI
import LavaSecCore

/// Per-OS presentation for protection connectivity states.
///
/// The portable core (`ProtectionConnectivityPolicy`) returns a semantic
/// `ProtectionConnectivitySeverity` + action only; this maps each severity to the
/// user-facing copy on iOS. The views localize via `.lavaLocalized` at render, so
/// these stay raw strings (identical to the copy that used to live in the core —
/// this is a no-op on screen). Android supplies its own map from the same severities.
///
/// Exhaustive over every `ProtectionConnectivitySeverity` case by construction.
enum ProtectionConnectivityPresentation {
    static func title(for severity: ProtectionConnectivitySeverity) -> String {
        switch severity {
        case .healthy:                return "Protected"
        case .recovering:             return "Reconnecting"
        case .usingDeviceDNSFallback: return "Protected"
        case .dnsSlow:                return "DNS Slow"
        case .networkUnavailable:     return "Network Lost"
        case .needsReconnect:         return "Reconnect Needed"
        }
    }

    static func subtitle(for severity: ProtectionConnectivitySeverity) -> String {
        switch severity {
        case .healthy:
            return "Filtering happens locally on this phone"
        case .recovering:
            return "Connection changed, refreshing DNS protection"
        case .usingDeviceDNSFallback:
            return "Filtering is on with Device DNS fallback because the selected DNS resolver is unavailable"
        case .dnsSlow:
            return "The selected DNS resolver is responding slowly. Reconnect or switch resolver."
        case .networkUnavailable:
            return "No internet path is available. Lava will resume when the network returns."
        case .needsReconnect:
            return "Lava cannot reach the DNS. Check your network condition and reconnect."
        }
    }
}

extension ProtectionTintRole {
    /// iOS color for this tint role — tuned `LavaStyle` tokens that adapt in dark mode
    /// (the view model used to return raw, non-adaptive `.green`/`.orange`).
    var color: Color {
        switch self {
        case .protected:     LavaStyle.safeGreen
        case .attention:     LavaStyle.lavaOrange
        case .transitioning: LavaStyle.lavaOrange
        case .paused:        LavaStyle.lavaOrange
        case .inactive:      LavaStyle.secondaryText
        }
    }
}
