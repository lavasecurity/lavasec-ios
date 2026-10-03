import SwiftUI
import LavaSecKit

/// Network Activity now lives under Settings → Advanced (it left the Activity
/// tab), so it carries its own privacy explainer and the Review Privacy & Data
/// link that the Activity-screen footer used to provide alongside it.
enum NetworkActivityTheme {
    case networkChange
    case protectionLifecycle
    case userAction
    case smokeTest(isWarning: Bool)
    case deviceDNS
    case reconnect

    var title: String {
        switch self {
        case .networkChange:
            return "Network Change"
        case .protectionLifecycle:
            return "Protection"
        case .userAction:
            return "User Action"
        case .smokeTest:
            return "Smoke Test"
        case .deviceDNS:
            return "Device DNS"
        case .reconnect:
            return "Reconnect"
        }
    }

    var systemImage: String {
        switch self {
        case .networkChange:
            return "antenna.radiowaves.left.and.right"
        case .protectionLifecycle:
            return "checkmark.shield"
        case .userAction:
            return "person.crop.circle"
        case .smokeTest(let isWarning):
            return isWarning ? "xmark.circle" : "checkmark.circle"
        case .deviceDNS:
            return "arrow.triangle.branch"
        case .reconnect:
            return "arrow.clockwise"
        }
    }

    var tint: Color {
        switch self {
        case .networkChange, .protectionLifecycle, .userAction:
            return LavaStyle.safeGreen
        case .smokeTest(let isWarning):
            return isWarning ? LavaStyle.lavaOrangeText : LavaStyle.safeGreen
        case .deviceDNS, .reconnect:
            return LavaStyle.secondaryText
        }
    }

    var tone: String {
        switch self {
        case .networkChange, .protectionLifecycle, .userAction: return "green"
        case .smokeTest(let isWarning): return isWarning ? "orange" : "green"
        case .deviceDNS, .reconnect: return "secondary"
        }
    }

    var background: Color {
        switch self {
        case .networkChange, .protectionLifecycle, .userAction:
            return LavaStyle.softGreen
        case .smokeTest(let isWarning):
            return isWarning ? LavaStyle.lavaOrangeSoft : LavaStyle.softGreen
        case .deviceDNS, .reconnect:
            return LavaStyle.secondaryText.opacity(0.12)
        }
    }
}

extension NetworkActivityEvent {
    var activityTheme: NetworkActivityTheme {
        switch self {
        case .networkChanged:
            return .networkChange
        case .protectionConnected:
            return .protectionLifecycle
        case .userAction:
            return .userAction
        case .dnsSmokeProbeSucceeded:
            return .smokeTest(isWarning: false)
        case .dnsSmokeProbeFailed:
            return .smokeTest(isWarning: true)
        case .deviceDNSFallbackActivated, .deviceDNSFallbackRecovered:
            return .deviceDNS
        case .reconnectNeeded:
            return .reconnect
        case .connectivityRecovered:
            // The positive counterpart to .reconnectNeeded — protection is healthy
            // again (green checkmark), closing the wedge→recovery pair in the feed.
            return .protectionLifecycle
        case .networkSettingsReapplyFailed:
            return .smokeTest(isWarning: true)
        }
    }
}
