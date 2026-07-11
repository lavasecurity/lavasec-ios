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
            return "Open Phone QA settings"
#endif
        }
    }
}

struct SettingsRouteDestinationView: View {
    @EnvironmentObject private var security: SecurityController
    let route: SettingsRoute

    @ViewBuilder
    var body: some View {
        Group {
            switch route {
            case .account:
                AccountSettingsView()
            case .upgrade:
                UpgradeSettingsView()
            case .customization:
                CustomizationSettingsView()
            case .dnsResolver:
                DNSResolverSettingsView()
            case .privacyData:
                PrivacyDataSettingsView()
            case .security:
                SecuritySettingsView()
            case .bugReport:
                BugReportSettingsView()
            case .legalNotices:
                LegalNoticesView()
            case .versionNerdStats:
                VersionNerdStatsView()
            case .networkActivity:
                NetworkActivityLogView()
#if DEBUG || LAVA_QA_TOOLS
            case .phoneQA:
                PhoneQASettingsView()
#endif
            }
        }
        .onDisappear {
            security.resetViewAuthenticationTurn()
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var account: AccountController
    // The diagnostics + bug-report/rage-shake scope (Phase D4 peel).
    @EnvironmentObject private var reports: DiagnosticsController
    @EnvironmentObject private var security: SecurityController
    @Binding private var path: [SettingsRoute]
    private let scrollToTopTrigger: Int

    init(path: Binding<[SettingsRoute]> = .constant([]), scrollToTopTrigger: Int = 0) {
        self._path = path
        self.scrollToTopTrigger = scrollToTopTrigger
    }

    var body: some View {
        NavigationStack(path: $path) {
            LavaPrimaryTabScreenContent(
                title: "Settings",
                scrolls: true,
                scrollToTopTrigger: scrollToTopTrigger,
            ) {
                LavaSectionGroup("Your Lava") {
                    SettingsNavigationRow(
                        route: .account,
                        systemImage: "person.crop.circle",
                        title: "Account & Backup",
                        summary: account.accountStatusText
                    )

                    SettingsNavigationRow(
                        route: .upgrade,
                        badge: LavaSecurityPlusGlyph(),
                        title: "Upgrade",
                        summary: viewModel.planStatusText
                    )

                    SettingsNavigationRow(
                        route: .customization,
                        systemImage: "slider.horizontal.3",
                        title: "Customization",
                        summary: "Make Lava Security yours"
                    )
                }

                LavaSectionGroup("Protection Choices") {
                    SettingsNavigationRow(
                        route: .dnsResolver,
                        systemImage: "network",
                        title: "DNS Resolver",
                        summary: viewModel.dnsResolverSummaryText
                    )

                    SettingsNavigationRow(
                        route: .privacyData,
                        systemImage: "eyeglasses",
                        title: "Privacy & Data",
                        summary: viewModel.localLogsStatusText
                    )

                    SettingsNavigationRow(
                        route: .security,
                        systemImage: "lock.fill",
                        title: "Security",
                        summary: security.securityStatusSummary
                    )
                }

                LavaSectionGroup("Support") {
                    SettingsExternalLinkRow(
                        destination: LavaWebLinks.support,
                        systemImage: "questionmark.circle",
                        title: "Help",
                        summary: "Learn how Lava works"
                    )

                    SettingsNavigationRow(
                        route: .bugReport,
                        systemImage: "ladybug",
                        title: "Feedback",
                        summary: "Voluntary and anonymized",
                        action: { reports.rageShakeDestination = .bugReport }
                    )

                    SettingsNavigationRow(
                        route: .legalNotices,
                        systemImage: "doc.text",
                        title: "Legal Notices",
                        summary: "Credits and licenses"
                    )
                }

                    LavaSectionGroup("Advanced") {
                        SettingsNavigationRow(
                            route: .versionNerdStats,
                            systemImage: "info.circle",
                            title: "Nerd Stats",
                            summary: "Version and tunnel health"
                        )

                        SettingsNavigationRow(
                            route: .networkActivity,
                            systemImage: "waveform.path.ecg.rectangle",
                            title: "Network Activity",
                            summary: viewModel.configuration.keepNetworkActivity ? "Local network activity on" : "Local network activity off"
                    )
                }

                #if DEBUG || LAVA_QA_TOOLS
                if viewModel.isAccountDeveloper {
                    LavaSectionGroup("Developer") {
                        SettingsNavigationRow(
                            route: .phoneQA,
                            systemImage: "iphone.gen3.radiowaves.left.and.right",
                            title: "Phone QA",
                            summary: viewModel.qaProbeSummaryText
                        )
                    }
                }
                #endif

                Text(appVersionString)
                    .lavaRowSubtitleText()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                SettingsRouteDestinationView(route: route)
            }
        }
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let revision = Bundle.main.infoDictionary?["LavaSourceRevision"] as? String ?? ""
        let base = "Lava \(version) (build \(build))"
        return revision.isEmpty ? base : "\(base) · \(revision)"
    }
}

/// The Lava Security+ mark: a shield with a centered plus, reading as "Security+".
/// No stock SF Symbol composes shield + plus, so it's built from `shield.fill` +
/// `plus`. (Natural home for a `LavaIconRole.securityPlus` once the Phase 2 icon
/// layer lands.)
private struct LavaSecurityPlusGlyph: View {
    var body: some View {
        Image(systemName: "shield.fill")
            .font(.headline)
            .foregroundStyle(LavaStyle.safeGreen)
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: LavaIconSize.badge, weight: .heavy))
                    .foregroundStyle(LavaStyle.softGreen)
                    .offset(y: -1)
            }
            .accessibilityHidden(true)
    }
}

private struct SettingsNavigationRow: View {
    @EnvironmentObject private var security: SecurityController
    @State private var isShowingDestination = false
    let route: SettingsRoute
    let systemImage: String?
    let badgeGlyph: AnyView?
    let title: String
    let summary: String
    /// When set, tapping the row runs this instead of pushing the route's
    /// destination — used for entries that present a sheet (e.g. Feedback).
    let action: (() -> Void)?

    init(
        route: SettingsRoute,
        systemImage: String? = nil,
        badgeGlyph: AnyView? = nil,
        title: String,
        summary: String,
        action: (() -> Void)? = nil
    ) {
        self.route = route
        self.systemImage = systemImage
        self.badgeGlyph = badgeGlyph
        self.title = title
        self.summary = summary
        self.action = action
    }

    /// For a custom composed badge glyph (e.g. the Security+ shield+plus, which
    /// has no stock SF Symbol).
    init(
        route: SettingsRoute,
        badge: some View,
        title: String,
        summary: String
    ) {
        self.init(
            route: route,
            systemImage: nil,
            badgeGlyph: AnyView(badge),
            title: title,
            summary: summary
        )
    }

    var body: some View {
        Button {
            Task {
                guard await canOpenRoute() else {
                    return
                }

                if let action {
                    action()
                } else {
                    isShowingDestination = true
                }
            }
        } label: {
            LavaNavigationCardLabel(
                badge: navigationBadge,
                badgeSize: 34,
                rowSpacing: LavaSpacing.md,
                title: title,
                summary: .standardLocalized(summary),
                accessory: .chevron
            )
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .navigationDestination(isPresented: $isShowingDestination) {
            SettingsRouteDestinationView(route: route)
        }
    }

    private var navigationBadge: LavaNavigationCardBadge? {
        if let badgeGlyph {
            return .custom(badgeGlyph, cornerRadius: 10)
        }
        if let systemImage {
            return .systemImage(systemImage, cornerRadius: 10)
        }
        return nil
    }

    private func canOpenRoute() async -> Bool {
        if route == .security {
            guard await security.requireCredentialAuthentication(reason: route.securityReason) else {
                return false
            }
        }

        guard let surface = route.securityPolicy.requiredSurface else {
            return true
        }

        return await security.requireAuthentication(for: surface, reason: route.securityReason)
    }
}

private struct SettingsExternalLinkRow: View {
    let destination: URL
    let systemImage: String?
    let title: String
    let summary: String

    var body: some View {
        Link(destination: destination) {
            LavaNavigationCardLabel(
                badge: systemImage.map { .systemImage($0, cornerRadius: 10) },
                badgeSize: 34,
                rowSpacing: LavaSpacing.md,
                title: title,
                summary: .standardLocalized(summary),
                accessory: .externalLink
            )
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

#if DEBUG || LAVA_QA_TOOLS
private struct PhoneQASettingsView: View {
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
