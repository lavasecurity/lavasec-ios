import SwiftUI
import LavaSecKit

/// Per-OS presentation for protection connectivity states.
///
/// The portable core (`ProtectionConnectivityPolicy`) returns a semantic
/// `ProtectionConnectivitySeverity` + action only; this maps each severity to the
/// user-facing copy on iOS. The views localize via `.lavaLocalized` at render, so
/// these stay raw strings (infra #260 concise status copy). Android supplies its own map from the same severities.
///
/// Exhaustive over every `ProtectionConnectivitySeverity` case by construction.
enum ProtectionConnectivityPresentation {
    static func title(for severity: ProtectionConnectivitySeverity) -> String {
        switch severity {
        case .healthy:                return "Protected"
        case .recovering:             return "Retrying DNS"
        case .usingDeviceDNSFallback: return "DNS fallback"
        case .usingEncryptedFallback: return "DNS fallback"
        case .dnsSlow:                return "DNS is slow"
        case .networkUnavailable:     return "No connection"
        case .needsReconnect:         return "Reconnect needed"
        }
    }

    static func subtitle(for severity: ProtectionConnectivitySeverity) -> String {
        switch severity {
        case .healthy:
            return "Filtering happens locally on this device."
        case .recovering:
            // A failed primary DNS probe is present, but no reconnect action is needed yet.
            return "A DNS check failed. Lava is retrying."
        case .usingDeviceDNSFallback:
            return "Filtering is on using your device's DNS."
        case .usingEncryptedFallback:
            return "Filtering is on using encrypted backup DNS."
        case .dnsSlow:
            return "Reconnect or change your DNS provider."
        case .networkUnavailable:
            return "Lava will retry when the network returns."
        case .needsReconnect:
            return "DNS lookups are failing."
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
