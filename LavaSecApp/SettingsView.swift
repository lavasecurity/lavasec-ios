import SwiftUI
import LavaSecKit

enum SettingsRoute: Hashable {
    case account
    case upgrade
    case customization
    case dnsResolver
    case privacyData
    case security
    case bugReport
    case legalNotices
    case versionNerdStats
    case networkActivity
    case vpnChaining
#if DEBUG || LAVA_QA_TOOLS
    case phoneQA
#endif

    static let settingsTabPolicy = SecurityAccessPolicy.requires(.appSettings)

    var securityPolicy: SecurityAccessPolicy {
        switch self {
        case .account:
            return .requires(.appSettings)
        case .upgrade:
            return .requires(.appSettings)
        case .customization:
            return .requires(.appSettings)
        case .dnsResolver:
            return .requires(.appSettings)
        case .privacyData:
            return .requires(.appSettings)
        case .security:
            return .readOnly
        case .bugReport:
            return .readOnly
        case .legalNotices:
            return .readOnly
        case .versionNerdStats:
            // Nerd Stats exposes tunnel health and version diagnostics — the same
            // "view my on-device diagnostics" family as Activity and Network
            // Activity, so it shares their `.activityViewing` lock.
            return .requires(.activityViewing)
        case .networkActivity:
            // Network Activity used to live behind the Activity tab's
            // `.activityViewing` gate; keep that protection now that it is reached
            // from Settings, so moving it does not bypass the user's passcode.
            return .requires(.activityViewing)
#if DEBUG || LAVA_QA_TOOLS
        case .phoneQA:
            return .requires(.appSettings)
#endif
        case .vpnChaining:
            // Same lock as the other Protection Choices subpages: this page can change the
            // data path and holds a WireGuard private key's staging surface.
            return .requires(.appSettings)
        }
    }

    var securityReason: String {
        switch self {
        case .account:
            return "Open Account & Backup settings"
        case .upgrade:
            return "Open plan settings"
        case .customization:
            return "Edit Customization settings"
        case .dnsResolver:
            return "Edit DNS settings"
        case .privacyData:
            return "Edit Privacy & Data settings"
        case .security:
            return "Open Security settings"
        case .bugReport:
            return "Open Feedback"
        case .legalNotices:
            return "Open Legal Notices"
        case .versionNerdStats:
            return "Open Nerd Stats"
        case .networkActivity:
            return "Open Network Activity"
#if DEBUG || LAVA_QA_TOOLS
        case .phoneQA:
            return "Open Device QA settings"
#endif
        case .vpnChaining:
            return "Open VPN chaining settings"
        }
    }
}
