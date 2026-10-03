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
#if DEBUG || LAVA_QA_TOOLS
    case phoneQA
    case vpnChaining
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
        case .vpnChaining:
            // Same lock as the other Protection Choices subpages: this page can change the
            // data path and holds a WireGuard private key's staging surface.
            return .requires(.appSettings)
#endif
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
        case .vpnChaining:
            return "Open VPN chaining settings"
#endif
        }
    }
}

/// Native DNS pages pushed from a native VPN sheet retain their own auth turn.
struct NativeDNSSettingsDestinationView: View {
    @EnvironmentObject private var security: SecurityController
    var body: some View {
        DNSResolverSettingsView()
            .onDisappear { security.resetViewAuthenticationTurn() }
    }
}

#if DEBUG || LAVA_QA_TOOLS
struct PhoneQASettingsView: View {
    // The rage-shake/bug-report destination lives on the diagnostics scope (Phase D4 peel).
    @EnvironmentObject private var reports: DiagnosticsController
    @AppStorage("hasSeenLavaOnboarding") private var hasSeenLavaOnboarding = false

    var body: some View {
        PhoneQAView(
            showWelcome: {
                hasSeenLavaOnboarding = false
            },
            showUserBugReport: {
                reports.rageShakeDestination = .bugReport
            }
        )
    }
}
#endif
