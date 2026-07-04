import SwiftUI
import LavaSecCore
import StoreKit
import UIKit
import UniformTypeIdentifiers

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

private enum LavaWebLinks {
    static let support = URL(string: "https://lavasecurity.app/support/")!
    static let privacy = URL(string: "https://lavasecurity.app/privacy/")!
    // No custom EULA is hosted; Apple's standard EULA is the compliant default
    // for the Guideline 3.1.2 "Terms of Use" link.
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}

private struct SettingsRouteDestinationView: View {
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

private enum SettingsSubpageLayout {
    static let spacing: CGFloat = 18
    static let feedbackSpacing: CGFloat = 18
}

/// The shared layout for a Settings sub-screen — the single place the "Lava Settings Page"
/// anatomy is enforced, so a non-technical user (think a parent with no security background)
/// meets the same shape on every screen instead of a different layout each time:
///
///   1. Large navigation `title`, always run through `.lavaLocalized`.
///   2. Exactly one `intro` panel (`LavaInfoPanel`) above all sections — one plain sentence
///      saying what the screen does plus the single reassurance that matters. On a
///      `.technical` (Workshop) screen this panel is the plain-language on-ramp. Typed as a
///      concrete `LavaInfoPanel?` rather than a generic slot so the "one panel" rule is
///      structural, not a convention each screen has to remember.
///   3. The body is titled `LavaSectionGroup`s; per-option helper text lives in the group's
///      `footer:`, not scattered `lavaQuietNoteText`.
///   4. `tier` declares the screen's depth (`LavaTier`): `.calm` for everyday screens,
///      `.celebratory` for delight, `.technical` for power-user surfaces. The tier governs
///      the reading level — how much jargon is allowed — see `LavaTier` in LavaTokens.swift.
///
/// Sales surfaces (Upgrade) are intentionally exempt from the strict body anatomy but still
/// declare a `tier` and reuse the shared components/tokens.
private struct SettingsSubpageContent<Content: View>: View {
    let title: String?
    let tier: LavaTier
    let intro: LavaInfoPanel?
    let spacing: CGFloat
    let scrolls: Bool
    let refreshAction: (() async -> Void)?
    let content: Content

    init(
        title: String? = nil,
        tier: LavaTier = .calm,
        intro: LavaInfoPanel? = nil,
        spacing: CGFloat = SettingsSubpageLayout.spacing,
        scrolls: Bool = true,
        refreshAction: (() async -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.tier = tier
        self.intro = intro
        self.spacing = spacing
        self.scrolls = scrolls
        self.refreshAction = refreshAction
        self.content = content()
    }

    var body: some View {
        LavaScreenContent(
            spacing: spacing,
            scrolls: scrolls,
            refreshAction: refreshAction
        ) {
            if let intro {
                intro
            }
            content
        }
        .lavaTier(tier)
        .modifier(SettingsSubpageNavigationTitle(title: title))
    }
}

/// Applies the localized large navigation title when a subpage declares one, leaving the
/// chrome untouched otherwise. Keeps the `.lavaLocalized` call in one place so no screen can
/// ship an unlocalized title.
private struct SettingsSubpageNavigationTitle: ViewModifier {
    let title: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let title {
            content.navigationTitle(title.lavaLocalized)
        } else {
            content
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
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
                        path: $path,
                        route: .account,
                        systemImage: "person.crop.circle",
                        title: "Account & Backup",
                        summary: viewModel.accountStatusText
                    )

                    SettingsNavigationRow(
                        path: $path,
                        route: .upgrade,
                        badge: LavaSecurityPlusGlyph(),
                        title: "Upgrade",
                        summary: viewModel.planStatusText
                    )

                    SettingsNavigationRow(
                        path: $path,
                        route: .customization,
                        systemImage: "slider.horizontal.3",
                        title: "Customization",
                        summary: "Make Lava Security yours"
                    )
                }

                LavaSectionGroup("Protection Choices") {
                    SettingsNavigationRow(
                        path: $path,
                        route: .dnsResolver,
                        systemImage: "network",
                        title: "DNS Resolver",
                        summary: viewModel.dnsResolverSummaryText
                    )

                    SettingsNavigationRow(
                        path: $path,
                        route: .privacyData,
                        systemImage: "eyeglasses",
                        title: "Privacy & Data",
                        summary: viewModel.localLogsStatusText
                    )

                    SettingsNavigationRow(
                        path: $path,
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
                        action: { viewModel.rageShakeDestination = .bugReport }
                    )

                    SettingsNavigationRow(
                        path: $path,
                        route: .legalNotices,
                        systemImage: "doc.text",
                        title: "Legal Notices",
                        summary: "Credits and licenses"
                    )
                }

                    LavaSectionGroup("Advanced") {
                        SettingsNavigationRow(
                            path: $path,
                            route: .versionNerdStats,
                            systemImage: "info.circle",
                            title: "Nerd Stats",
                            summary: "Version and tunnel health"
                        )

                        SettingsNavigationRow(
                            path: $path,
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
                            path: $path,
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

    init(
        path: Binding<[SettingsRoute]>,
        route: SettingsRoute,
        systemImage: String? = nil,
        title: String,
        summary: String
    ) {
        self.init(
            route: route,
            systemImage: systemImage,
            title: title,
            summary: summary
        )
    }

    /// For a custom composed badge glyph (e.g. the Security+ shield+plus, which
    /// has no stock SF Symbol).
    init(
        path: Binding<[SettingsRoute]>,
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
            HStack(spacing: 12) {
                if let badgeGlyph {
                    badgeGlyph
                        .frame(width: 34, height: 34)
                        .background(LavaStyle.softGreen, in: RoundedRectangle(cornerRadius: 10))
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.headline)
                        .foregroundStyle(LavaStyle.safeGreen)
                        .frame(width: 34, height: 34)
                        .background(LavaStyle.softGreen, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title.lavaLocalized)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(summary.lavaLocalized)
                        .lavaRowSubtitleText()
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lavaSurface(.card)
            .contentShape(RoundedRectangle(cornerRadius: LavaSurface.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .navigationDestination(isPresented: $isShowingDestination) {
            SettingsRouteDestinationView(route: route)
        }
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
            HStack(spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.headline)
                        .foregroundStyle(LavaStyle.safeGreen)
                        .frame(width: 34, height: 34)
                        .background(LavaStyle.softGreen, in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title.lavaLocalized)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(summary.lavaLocalized)
                        .lavaRowSubtitleText()
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lavaSurface(.card)
            .contentShape(RoundedRectangle(cornerRadius: LavaSurface.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

private struct SettingsSystemSettingsRow: View {
    let title: String

    var body: some View {
        Button {
            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
                return
            }

            UIApplication.shared.open(settingsURL)
        } label: {
            HStack(spacing: 12) {
                Text(title.lavaLocalized)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .lavaControlRowCard()
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

private struct AccountSettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    @State private var isShowingAccountSheet = false
    @State private var isSettingUpBackup = false
    @State private var isRestoringBackup = false
    @State private var backupMaintenanceTarget: BackupMaintenanceAction?

    var body: some View {
        SettingsSubpageContent(
            title: "Account & Backup",
            tier: .calm,
            intro: LavaInfoPanel(
                title: viewModel.encryptedBackupInfoTitle,
                description: "Lava works without an account. Sign in only to back up your settings online — encrypted, so only you can restore them on a new phone.",
                systemImage: "person.crop.circle"
            )
        ) {
            LavaSectionGroup(
                "Account",
                footer: "Account login is only needed for encrypted backup upload, support history, or paid account management."
            ) {
                LavaCondensedList {
                    Button {
                        performAppSettingsMutation(reason: "Edit Account settings") {
                            if viewModel.isAppleAccountConnected {
                                isShowingAccountSheet = true
                            } else {
                                viewModel.beginSignInWithApple()
                            }
                        }
                    } label: {
                        SettingsActionRow(
                            title: viewModel.appleSignInActionTitle,
                            iconTint: LavaStyle.primaryText
                        ) {
                            AppleSignInStatusIcon(
                                isSigningIn: viewModel.isAppleSignInInProgress
                            )
                        }
                        .lavaRow()
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isAccountSignInInProgress)

                    LavaCondensedDivider()

                    Button {
                        performAppSettingsMutation(reason: "Edit Account settings") {
                            if viewModel.isGoogleAccountConnected {
                                isShowingAccountSheet = true
                            } else {
                                viewModel.beginSignInWithGoogle()
                            }
                        }
                    } label: {
                        SettingsActionRow(title: viewModel.googleSignInActionTitle) {
                            if viewModel.isGoogleSignInInProgress {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                GoogleSignInIcon()
                            }
                        }
                        .lavaRow()
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isAccountSignInInProgress)
                }
            }
            .sheet(isPresented: $isShowingAccountSheet) {
                AccountSheet()
                    .environmentObject(viewModel)
            }
            // The backup setup/restore flows present as full bottom sheets (like
            // Import filters) so they cover the tab bar and put their actions on the
            // sheet's footer bar.
            .sheet(isPresented: $isSettingUpBackup) {
                BackupSetupView()
                    .environmentObject(viewModel)
            }
            .sheet(isPresented: $isRestoringBackup) {
                BackupRestoreView()
                    .environmentObject(viewModel)
            }

            LavaSectionGroup("Encrypted Backup") {
                VStack(alignment: .leading, spacing: 10) {
                    LavaCondensedList {
                        if viewModel.isEncryptedBackupConfigured {
                            Button {
                                Task {
                                    guard await security.requireAuthentication(
                                        for: .appSettings,
                                        reason: "Back up settings"
                                    ) else {
                                        return
                                    }

                                    await viewModel.backUpNow()
                                }
                            } label: {
                                SettingsActionRow(title: viewModel.isBackingUpNow ? "Backing Up" : "Back Up Now") {
                                    if viewModel.isBackingUpNow {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "icloud.and.arrow.up.fill")
                                            .font(.title3.weight(.semibold))
                                    }
                                }
                                .lavaRow()
                            }
                            .buttonStyle(.plain)
                            .disabled(!viewModel.isAccountSignedIn || viewModel.isBackingUpNow || viewModel.isBackupMaintenanceInProgress)
                            .opacity(viewModel.isAccountSignedIn ? 1 : 0.45)
                        } else {
                            Button {
                                isSettingUpBackup = true
                            } label: {
                                SettingsActionRow(title: "Set Up Encrypted Backup") {
                                    Image(systemName: "key.fill")
                                        .font(.title3.weight(.semibold))
                                }
                                .lavaRow()
                            }
                            .buttonStyle(.plain)
                            .disabled(!viewModel.isAccountSignedIn)
                            .opacity(viewModel.isAccountSignedIn ? 1 : 0.45)
                        }

                        LavaCondensedDivider()

                        Button {
                            isRestoringBackup = true
                        } label: {
                            SettingsActionRow(title: "Restore Backup") {
                                Image(systemName: "icloud.and.arrow.down.fill")
                                    .font(.title3.weight(.semibold))
                            }
                            .lavaRow()
                        }
                        .buttonStyle(.plain)
                        .disabled(!viewModel.isAccountSignedIn)
                        .opacity(viewModel.isAccountSignedIn ? 1 : 0.45)
                    }

                    BackupOptionControl(
                        title: "Automatic Backup",
                        detail: "Lava waits 30 minutes after your last settings change before it tries an automatic upload.",
                        isOn: automaticBackupBinding
                    )
                    .disabled(!viewModel.isEncryptedBackupConfigured)
                    .opacity(viewModel.isEncryptedBackupConfigured ? 1 : 0.45)

                    if viewModel.isEncryptedBackupConfigured {
                        VStack(alignment: .leading, spacing: 8) {
                            LavaCondensedList {
                                backupMaintenanceButton(.clear)

                                LavaCondensedDivider()

                                backupMaintenanceButton(.disable)
                            }

                            Text("Delete online backup copy removes the server copy but keeps backups on. Turn off & delete backup stops them too. Either way, it's gone for good.".lavaLocalized)
                                .lavaQuietNoteText()
                        }
                    }
                }
            }
        }
        .lavaConfirmationAlert { host in
            host.alert(
                backupMaintenanceTarget?.title.lavaLocalized ?? "",
                isPresented: backupMaintenanceConfirmationBinding,
                presenting: backupMaintenanceTarget
            ) { target in
                Button("Cancel", role: .cancel) {}
                Button(target.actionTitle.lavaLocalized, role: .destructive) {
                    performBackupMaintenance(target)
                }
            } message: { target in
                Text(target.message.lavaLocalized)
            }
        }
    }

    private func backupMaintenanceButton(_ target: BackupMaintenanceAction) -> some View {
        Button(role: .destructive) {
            backupMaintenanceTarget = target
        } label: {
            SettingsActionRow(title: target.buttonTitle, iconTint: .red, titleTint: .red) {
                Image(systemName: "trash")
                    .font(.title3.weight(.semibold))
            }
            .lavaRow()
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBackupMaintenanceInProgress || viewModel.isBackingUpNow)
    }

    private var backupMaintenanceConfirmationBinding: Binding<Bool> {
        Binding {
            backupMaintenanceTarget != nil
        } set: { isPresented in
            if !isPresented {
                backupMaintenanceTarget = nil
            }
        }
    }

    private func performBackupMaintenance(_ target: BackupMaintenanceAction) {
        Task {
            guard await security.requireAuthentication(for: .appSettings, reason: target.authReason) else {
                return
            }

            switch target {
            case .clear:
                await viewModel.clearEncryptedBackup()
            case .disable:
                await viewModel.disableEncryptedBackup()
            }
        }
    }

    private var automaticBackupBinding: Binding<Bool> {
        Binding {
            viewModel.isAutomaticBackupEnabled
        } set: { isEnabled in
            performAppSettingsMutation(reason: "Edit backup settings") {
                viewModel.setAutomaticBackupEnabled(isEnabled)
            }
        }
    }

    private func performAppSettingsMutation(reason: String, action: @escaping @MainActor () -> Void) {
        Task {
            guard await security.requireAuthentication(for: .appSettings, reason: reason) else {
                return
            }

            action()
        }
    }
}

private enum BackupMaintenanceAction: Identifiable {
    case clear
    case disable

    var id: String {
        switch self {
        case .clear:
            return "clear"
        case .disable:
            return "disable"
        }
    }

    var buttonTitle: String {
        switch self {
        case .clear:
            return "Delete online backup copy"
        case .disable:
            return "Turn off & delete backup"
        }
    }

    var title: String {
        switch self {
        case .clear:
            return "Delete online backup copy?"
        case .disable:
            return "Turn off & delete backup?"
        }
    }

    var actionTitle: String {
        switch self {
        case .clear:
            return "Delete online backup copy"
        case .disable:
            return "Turn off & delete backup"
        }
    }

    var message: String {
        switch self {
        case .clear:
            return "Permanently deletes your account's encrypted backup — this can't be undone. Backup stays on, and a fresh copy uploads next time."
        case .disable:
            return "Turns off backup on this device and permanently deletes your account's copy. This can't be undone — you can set up a new backup later."
        }
    }

    var authReason: String {
        switch self {
        case .clear:
            return "Clear encrypted backup"
        case .disable:
            return "Disable encrypted backup"
        }
    }
}

private struct BackupOptionControl: View {
    let title: String
    let detail: String
    let isOn: Binding<Bool>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(title.lavaLocalized, isOn: isOn)
                .font(.headline)
                .tint(LavaStyle.safeGreen)
                .lavaControlRowCard()

            Text(detail.lavaLocalized)
                .lavaQuietNoteText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AppleSignInStatusIcon: View {
    let isSigningIn: Bool

    var body: some View {
        if isSigningIn {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: "apple.logo")
                .font(.title3.weight(.semibold))
        }
    }
}

private struct LocalLogExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.zip]
    }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    @State private var isConfirmingAccountDeletion = false

    var body: some View {
        let accountConnections = viewModel.accountConnections

        NavigationStack {
            LavaSheetScaffold(spacing: 14, scrolls: false) {
                LavaCondensedList {
                    ForEach(Array(accountConnections.enumerated()), id: \.element.provider) { index, connection in
                        AccountConnectionRow(connection: connection)
                            .lavaRow()

                        if index < accountConnections.count - 1 {
                            LavaCondensedDivider()
                        }
                    }

                    LavaCondensedDivider()

                    Button {
                        performAppSettingsMutation(reason: "Edit Account settings") {
                            viewModel.signOutAccount()
                            dismiss()
                        }
                    } label: {
                        SettingsActionRow(title: "Sign out of all accounts", iconTint: LavaStyle.secondaryText) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.title3.weight(.semibold))
                        }
                        .lavaRow()
                    }
                    .buttonStyle(.plain)

                    LavaCondensedDivider()

                    Button(role: .destructive) {
                        performAppSettingsMutation(reason: "Edit Account settings") {
                            isConfirmingAccountDeletion = true
                        }
                    } label: {
                        SettingsActionRow(
                            title: viewModel.isAccountDeletionInProgress ? "Deleting account" : "Delete my Lava account",
                            iconTint: .red,
                            titleTint: .red
                        ) {
                            if viewModel.isAccountDeletionInProgress {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "trash")
                                    .font(.title3.weight(.semibold))
                            }
                        }
                        .lavaRow()
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isAccountDeletionInProgress)
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close", role: .close, action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.height(accountSheetHeight)])
        .presentationDragIndicator(.visible)
        .lavaConfirmationAlert { host in
            host.alert(
                "Delete your Lava account?",
                isPresented: $isConfirmingAccountDeletion
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task {
                        if await viewModel.deleteAccount() {
                            dismiss()
                        }
                    }
                }
            } message: {
                Text("This deletes the signed-in Lava account and its encrypted backup from Lava's servers. Local protection settings stay on this device.")
            }
        }
    }

    private var accountSheetHeight: CGFloat {
        viewModel.accountConnections.count > 1 ? 332 : 288
    }

    private func performAppSettingsMutation(reason: String, action: @escaping @MainActor () -> Void) {
        Task {
            guard await security.requireAuthentication(for: .appSettings, reason: reason) else {
                return
            }

            action()
        }
    }
}

private struct AccountConnectionRow: View {
    let connection: AccountAuthConnection

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 28, height: 28)

            Text(connection.email ?? "\(connection.provider.displayName) account")
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        switch connection.provider {
        case .apple:
            Image(systemName: "apple.logo")
                .font(.title3.weight(.semibold))
                .foregroundStyle(LavaStyle.primaryText)
        case .google:
            GoogleSignInIcon()
        }
    }
}

private struct SettingsActionRow<Icon: View>: View {
    let title: String
    let iconTint: Color
    let titleTint: Color
    let icon: Icon

    init(
        title: String,
        iconTint: Color = LavaStyle.safeGreen,
        titleTint: Color = .primary,
        @ViewBuilder icon: () -> Icon
    ) {
        self.title = title
        self.iconTint = iconTint
        self.titleTint = titleTint
        self.icon = icon()
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
                .foregroundStyle(iconTint)
                .frame(width: 28, height: 28)

            Text(title.lavaLocalized)
                .font(.headline)
                .foregroundStyle(titleTint)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

private struct GoogleSignInIcon: View {
    var body: some View {
        Image("GoogleSignInG")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: 23, height: 23)
            .accessibilityHidden(true)
    }
}

/// Upgrade is a **sales surface**, intentionally exempt from the strict Settings-page anatomy
/// (it keeps its marketing layout) but still declaring its depth `tier`. The eyebrow +
/// `LavaInfoCard { UpgradePlanComparisonView() }` free-vs-paid table already plays the
/// orientation-panel role, so no separate `LavaInfoPanel` intro is added.
///
/// Documented divergences / improvement opportunities (deferred — keep the current sales
/// layout for now, per product):
///   - The nav title stays a raw `.navigationTitle("Lava Security Plus")` literal (NOT
///     `.lavaLocalized`). It is the one Settings title left untranslated; localize it when the
///     sales copy is finalized.
///   - The plan-pitch strings + the "…and a pitch for your parent" subtitle are jokey
///     marketing copy, now localized (pitch via .lavaLocalized; subtitle via a literal Text).
///     Swap in finalized marketing copy when ready.
///   - The Restore Purchase / Manage Subscription rows are hand-rolled with
///     `.padding(16).lavaSurface(.card)` instead of the shared `lavaControlRowCard()`; they
///     could adopt the shared row card pending visual QA that it preserves the sales look.
private struct UpgradeSettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController

    var body: some View {
        SettingsSubpageContent(tier: .celebratory) {
            VStack(alignment: .leading, spacing: 10) {
                Text("More room for your rules")
                    .foregroundStyle(LavaStyle.lavaOrange)
                    .font(.title3.bold())

                LavaInfoCard {
                    UpgradePlanComparisonView()
                }
            }

            if viewModel.configuration.hasLavaSecurityPlus {
                UpgradeThankYouView()
                subscriberManagementSection
            } else if !viewModel.hasCheckedLavaSecurityPlusEntitlements
                || viewModel.isRefreshingLavaSecurityPlusEntitlements {
                UpgradeEntitlementCheckingView()
            } else {
                purchaseOptions
            }

            if let message = viewModel.lavaSecurityPlusMessage {
                Text(message)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(viewModel.lavaSecurityPlusMessageIsError ? LavaStyle.errorText : LavaStyle.safeGreen)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("Lava Security Plus")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            viewModel.clearLavaSecurityPlusMessage()
        }
        .onDisappear {
            viewModel.clearLavaSecurityPlusMessage()
        }
        .task {
            // Check entitlements once per session — re-checking on every appear
            // flips the loading flag (flicker) and re-applies the entitlement,
            // which can churn the paid status. The displayed status is driven by
            // the persisted configuration, which stays truthful between checks.
            if !viewModel.hasCheckedLavaSecurityPlusEntitlements {
                await viewModel.refreshLavaSecurityPlusEntitlements()
            }
            if !viewModel.configuration.hasLavaSecurityPlus, viewModel.lavaSecurityPlusOffers.isEmpty {
                await viewModel.loadLavaSecurityPlusProducts()
            }
        }
    }

    private var purchaseOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose a plan")
                    .font(.title3.bold())
                    .foregroundStyle(LavaStyle.ink)

                Text("... and a pitch for your parent")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LavaStyle.secondaryText)
            }

            VStack(spacing: 10) {
                ForEach(displayedOffers) { offer in
                    Button {
                        purchase(offer)
                    } label: {
                        UpgradePlanOfferRow(
                            offer: offer,
                            pitch: planPitch(for: offer.plan.kind)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isPurchasingLavaSecurityPlus)
                }

                Text("or if you have already made a purchase")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LavaStyle.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                    .padding(.bottom, 2)

                Button {
                    restorePurchases()
                } label: {
                    SettingsActionRow(title: "Restore Purchase") {
                        if viewModel.isPurchasingLavaSecurityPlus {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise.circle")
                                .font(.title3.weight(.semibold))
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isPurchasingLavaSecurityPlus)
                .padding(16)
                .lavaSurface(.card, cornerRadius: LavaSurface.compactCornerRadius)
            }

            UpgradeLegalFooter()
        }
    }

    private var displayedOffers: [LavaSecurityPlusOffer] {
        if !viewModel.lavaSecurityPlusOffers.isEmpty {
            return viewModel.lavaSecurityPlusOffers
        }

        return LavaSecurityPlusPolicy.fallbackOfferOrder.map {
            LavaSecurityPlusOffer(
                plan: $0,
                displayPrice: $0.fallbackDisplayPrice,
                commitmentDisplayPrice: nil,
                product: nil
            )
        }
    }

    private func planPitch(for kind: LavaSecurityPlusPlanKind) -> String {
        switch kind {
        case .yearly:
            "\"We are saving 37%! This has the best value.\""
        case .yearlyPaidMonthly:
            "\"If we commit for 12 months, each month is cheaper.\""
        case .monthly:
            "\"We already saved this by unplugging appliances.\""
        }
    }

    private func performAppSettingsMutation(reason: String, action: @escaping @MainActor () async -> Void) {
        Task {
            guard await security.requireAuthentication(for: .appSettings, reason: reason) else {
                return
            }

            await action()
        }
    }

    private func purchase(_ offer: LavaSecurityPlusOffer) {
        performAppSettingsMutation(reason: "Upgrade to Lava Security Plus") {
            await viewModel.purchaseLavaSecurityPlus(offer)
        }
    }

    private func restorePurchases() {
        performAppSettingsMutation(reason: "Restore Lava Security Plus") {
            await viewModel.restoreLavaSecurityPlusPurchases()
        }
    }

    @ViewBuilder
    private var subscriberManagementSection: some View {
        VStack(spacing: 10) {
            // Manage / cancel is shown only with an active auto-renewable subscription
            // (non-nil expiry); hidden when there is no entitlement.
            if viewModel.lavaSecurityPlusExpiresAt != nil {
                Button {
                    manageSubscription()
                } label: {
                    SettingsActionRow(title: "Manage Subscription") {
                        Image(systemName: "creditcard.circle")
                            .font(.title3.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isPurchasingLavaSecurityPlus)
                .padding(16)
                .lavaSurface(.card, cornerRadius: LavaSurface.compactCornerRadius)
            }

            // Restore — relevant for any plan after a reinstall or device switch.
            Button {
                restorePurchases()
            } label: {
                SettingsActionRow(title: "Restore Purchase") {
                    if viewModel.isPurchasingLavaSecurityPlus {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.title3.weight(.semibold))
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isPurchasingLavaSecurityPlus)
            .padding(16)
            .lavaSurface(.card, cornerRadius: LavaSurface.compactCornerRadius)
        }
    }

    private func manageSubscription() {
        performAppSettingsMutation(reason: "Manage Lava Security Plus") {
            await presentManageSubscriptions()
        }
    }

    @MainActor
    private func presentManageSubscriptions() async {
        // Prefer Apple's in-app manage sheet; fall back to the App Store subscriptions
        // page when no foreground scene is available or the sheet can't present (e.g. the
        // Simulator, where showManageSubscriptions often no-ops).
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            do {
                try await AppStore.showManageSubscriptions(in: scene)
                await viewModel.refreshLavaSecurityPlusEntitlements()
                return
            } catch {
                // Fall through to the deep link below.
            }
        }

        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            _ = await UIApplication.shared.open(url)
        }
    }
}

/// Guideline 3.1.2 disclosure: auto-renew terms + functional Terms (EULA) and
/// Privacy Policy links, shown on the paywall wherever subscriptions are offered.
private struct UpgradeLegalFooter: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Monthly and yearly plans auto-renew. Yearly paid monthly is billed monthly on a 12-month commitment; after that, cancelling affects the next renewal per App Store terms. Payment is charged to your Apple Account at purchase and renews unless turned off at least 24 hours before the period ends. Manage or cancel in Apple Account settings.")
                .lavaQuietNoteText()
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Link("Terms of Use", destination: LavaWebLinks.terms)
                Text("•")
                    .foregroundStyle(LavaStyle.secondaryText)
                Link("Privacy Policy", destination: LavaWebLinks.privacy)
            }
            .font(.footnote.weight(.semibold))
            .tint(LavaStyle.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}

private struct UpgradeThankYouView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        LavaPlainCard {
            VStack(spacing: 14) {
                UpgradeThankYouMascot()

                VStack(spacing: 6) {
                    Text("Thank you for your support")
                        .font(.title3.bold())
                        .foregroundStyle(LavaStyle.ink)
                        .multilineTextAlignment(.center)

                    Text("Lava Security Plus is active")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LavaStyle.secondaryText)
                        .multilineTextAlignment(.center)

                    if let expiresAt = viewModel.lavaSecurityPlusExpiresAt {
                        Text("Expiration: %@".lavaLocalizedFormat(expiresAt.formatted(date: .abbreviated, time: .omitted)))
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(LavaStyle.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

private struct UpgradeThankYouMascot: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var mascotState: GuardianMascotState = .awake

    var body: some View {
        SoftShieldGuardian(size: 96, state: mascotState, shieldStyle: viewModel.lavaGuardLook)
            .task {
                mascotState = .awake
                try? await Task.sleep(nanoseconds: 650_000_000)
                guard !Task.isCancelled else {
                    return
                }
                mascotState = .grateful
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled else {
                    return
                }
                mascotState = .awake
            }
    }
}

private struct UpgradeEntitlementCheckingView: View {
    var body: some View {
        LavaPlainCard {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(LavaStyle.safeGreen)

                Text("Checking Lava Security Plus")
                    .font(.headline)
                    .foregroundStyle(LavaStyle.ink)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }
}

struct LavaPlusUpgradeDestination: View {
    var body: some View {
        UpgradeSettingsView()
    }
}

private enum UpgradePlanComparisonValue: Equatable {
    case text(String)
    case unlocked
}

private struct UpgradePlanComparisonView: View {
    private let differences: [(title: String, free: String?, paid: UpgradePlanComparisonValue)] = [
        ("Filters", "\(FeatureLimits.free.maxFilters)", .text("\(FeatureLimits.paid.maxFilters)")),
        ("All filter rules", AppViewModel.abbreviatedRuleCount(FeatureLimits.free.maxFilterRules), .text(AppViewModel.abbreviatedRuleCount(FeatureLimits.paid.maxFilterRules))),
        ("Allowed domains", "\(FeatureLimits.free.maxAllowedDomains)", .text("\(FeatureLimits.paid.maxAllowedDomains)")),
        ("Blocked domains", "\(FeatureLimits.free.maxBlockedDomains)", .text("\(FeatureLimits.paid.maxBlockedDomains)")),
        ("All Lava Guards", nil, .unlocked),
        ("Family Sharing", nil, .unlocked),
        ("Custom blocklists", nil, .unlocked),
        ("Custom DNS", nil, .unlocked)
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(differences.indices, id: \.self) { index in
                let row = differences[index]
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        comparisonTitle(row.title)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        comparisonValues(free: row.free, paid: row.paid)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        comparisonTitle(row.title)

                        comparisonValues(free: row.free, paid: row.paid)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .font(.body.weight(.bold))
                .monospacedDigit()
                .padding(.vertical, 12)

                if index + 1 < differences.count {
                    Divider()
                }
            }
        }
        // First/last rows otherwise pick up the card inset (16) + row padding (12) = 28 at the
        // top/bottom edges vs 24 between rows; pull the stack 4pt into the card inset so every
        // vertical gap reads as 24 — consistent with the inter-row rhythm.
        .padding(.vertical, -4)
    }

    private func comparisonTitle(_ title: String) -> some View {
        Text(title.lavaLocalized)
            .foregroundStyle(LavaStyle.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
    }

    private func comparisonValues(free: String?, paid: UpgradePlanComparisonValue) -> some View {
        HStack(spacing: 6) {
            if let free {
                Text(free)
                    .foregroundStyle(LavaStyle.secondaryText)
                Text("→")
                    .foregroundStyle(LavaStyle.secondaryText)
            }
            paidValue(paid)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    @ViewBuilder
    private func paidValue(_ value: UpgradePlanComparisonValue) -> some View {
        switch value {
        case .text(let text):
            Text(text)
                .foregroundStyle(LavaStyle.safeGreen)
        case .unlocked:
            Text("Unlocked")
                .foregroundStyle(LavaStyle.safeGreen)
        }
    }
}

private struct UpgradePlanOfferRow: View {
    let offer: LavaSecurityPlusOffer
    let pitch: String

    var body: some View {
        LavaPlainCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(offer.title.lavaLocalized)
                        .font(.headline)
                        .foregroundStyle(LavaStyle.ink)

                    Text(pitch.lavaLocalized)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LavaStyle.secondaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.88)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(offer.displayPrice)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(LavaStyle.safeGreen)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    if offer.plan.kind == .yearlyPaidMonthly,
                       let commitmentDisplayPrice = offer.commitmentDisplayPrice {
                        Text("%@ total".lavaLocalizedFormat(commitmentDisplayPrice))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LavaStyle.secondaryText)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                }
                .layoutPriority(1)
            }
        }
    }
}

private struct CustomizationSettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController

    var body: some View {
        SettingsSubpageContent(
            title: "Customization",
            tier: .calm,
            intro: LavaInfoPanel(
                title: "Make Lava yours",
                description: "Pick how Lava looks and feels. None of these change how it protects you, so try anything.",
                systemImage: "slider.horizontal.3"
            )
        ) {
            LavaSectionGroup("Lava Guard") {
                LavaGuardLookPickerRow(
                    look: viewModel.lavaGuardLook,
                    availability: viewModel.lavaGuardAvailability(for: viewModel.lavaGuardLook),
                    onSelect: selectLavaGuardLook
                )
                .lavaTier(.celebratory)

                Toggle("Match App Icon to Lava Guard", isOn: updatesAppIconBinding)
                    .font(.headline)
                    .tint(LavaStyle.safeGreen)
                    .lavaControlRowCard()
            }

            if viewModel.canOfferLiveActivities {
                LavaSectionGroup("Live Activities") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Use Live Activities", isOn: usesLiveActivitiesBinding)
                            .font(.headline)
                            .tint(LavaStyle.safeGreen)
                            .lavaControlRowCard()

                        Text("Shows Lava status on the Lock Screen and Dynamic Island when available.".lavaLocalized)
                            .lavaQuietNoteText()

                        if viewModel.usesLiveActivities {
                            Stepper(
                                value: liveActivityPauseMinutesBinding,
                                in: LiveActivityPausePreference.minutesRange
                            ) {
                                Text(viewModel.liveActivityPauseLengthLabel)
                                    .font(.headline)
                            }
                            .tint(LavaStyle.safeGreen)
                            .lavaControlRowCard()

                            Text("How long the Pause button turns Lava off before protection resumes on its own.".lavaLocalized)
                                .lavaQuietNoteText()
                        }
                    }
                }
            }

            LavaSectionGroup("Haptics") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("App Haptics", isOn: lavaHapticsBinding)
                        .font(.headline)
                        .tint(LavaStyle.safeGreen)
                        .lavaControlRowCard()

                    Text("Lava's own taps. System haptics stay with iOS.".lavaLocalized)
                        .lavaQuietNoteText()
                }
            }

            LavaSectionGroup("Notifications") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Filter changes", isOn: notificationBinding(for: .filterChanged))
                        .font(.headline)
                        .tint(LavaStyle.safeGreen)
                        .lavaControlRowCard()
                    Text("Tells you when a Focus switches your filter while Lava is closed or in the background.".lavaLocalized)
                        .lavaQuietNoteText()

                    Toggle("Filter couldn't switch", isOn: notificationBinding(for: .filterCouldNotApply))
                        .font(.headline)
                        .tint(LavaStyle.safeGreen)
                        .lavaControlRowCard()
                    Text("Tells you when a Focus couldn't switch your filter, for example while editing is locked.".lavaLocalized)
                        .lavaQuietNoteText()

                    Toggle("Connection updates", isOn: notificationBinding(for: .connectivity))
                        .font(.headline)
                        .tint(LavaStyle.safeGreen)
                        .lavaControlRowCard()
                    Text("Alerts when protection needs your help to reconnect on a network.".lavaLocalized)
                        .lavaQuietNoteText()
                }
            }

            LavaSectionGroup("Appearance") {
                Picker("Appearance", selection: appearanceBinding) {
                    ForEach(LavaAppearancePreference.allCases) { preference in
                        Text(preference.displayName.lavaLocalized)
                            .tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                .tint(LavaStyle.safeGreen)
                .lavaControlRowCard()
            }

            LavaSectionGroup("Language") {
                SettingsSystemSettingsRow(title: "Change in iOS Settings")
            }
        }
    }

    private var appearanceBinding: Binding<LavaAppearancePreference> {
        Binding {
            viewModel.appearancePreference
        } set: { preference in
            performAppSettingsMutation(reason: "Edit Customization settings") {
                viewModel.setAppearancePreference(preference)
            }
        }
    }

    private var usesLiveActivitiesBinding: Binding<Bool> {
        Binding {
            viewModel.usesLiveActivities
        } set: { isEnabled in
            performAppSettingsMutation(reason: "Edit Customization settings") {
                viewModel.setUsesLiveActivities(isEnabled)
            }
        }
    }

    private var liveActivityPauseMinutesBinding: Binding<Int> {
        Binding {
            viewModel.liveActivityPauseMinutes
        } set: { minutes in
            performAppSettingsMutation(reason: "Edit Customization settings") {
                viewModel.setLiveActivityPauseMinutes(minutes)
            }
        }
    }

    private var updatesAppIconBinding: Binding<Bool> {
        Binding {
            viewModel.updatesAppIconWithLavaGuard
        } set: { isEnabled in
            performAppSettingsMutation(reason: "Edit Customization settings") {
                viewModel.setUpdatesAppIconWithLavaGuard(isEnabled)
            }
        }
    }

    private var lavaHapticsBinding: Binding<Bool> {
        Binding {
            viewModel.usesLavaHaptics
        } set: { isEnabled in
            performAppSettingsMutation(reason: "Edit Customization settings") {
                viewModel.setUsesLavaHaptics(isEnabled)
            }
        }
    }

    private func notificationBinding(for category: LavaNotificationCategory) -> Binding<Bool> {
        Binding {
            switch category {
            case .filterChanged: return viewModel.notifiesFilterChanges
            case .filterCouldNotApply: return viewModel.notifiesFilterCouldNotApply
            case .connectivity: return viewModel.notifiesConnectivity
            }
        } set: { isEnabled in
            performAppSettingsMutation(reason: "Edit Customization settings") {
                viewModel.setNotificationCategoryEnabled(category, isEnabled)
            }
        }
    }

    private func performAppSettingsMutation(reason: String, action: @escaping @MainActor () -> Void) {
        Task {
            guard await security.requireAuthentication(for: .appSettings, reason: reason) else {
                return
            }

            action()
        }
    }

    private func selectLavaGuardLook(_ look: GuardianShieldStyle) {
        performAppSettingsMutation(reason: "Edit Customization settings") {
            viewModel.setLavaGuardLook(look)
        }
    }
}

/// The current Guard is a single tappable row that opens the catalog as a bottom
/// sheet (radio-style single select, mirroring the Select Blocklists scaffold)
/// rather than an inline disclosure that pushed the rest of the screen around.
private struct LavaGuardLookPickerRow: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    @State private var isPresentingPicker = false

    let look: GuardianShieldStyle
    let availability: LavaGuardAvailability
    let onSelect: (GuardianShieldStyle) -> Void

    var body: some View {
        LavaPlainCard {
            Button {
                isPresentingPicker = true
            } label: {
                HStack(spacing: 12) {
                    LavaGuardLookContent(look: look, availability: availability)
                        .layoutPriority(1)

                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LavaStyle.secondaryText)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Lava Guard look".lavaLocalized)
            .accessibilityValue(availability.title(for: look).lavaLocalized)
            .accessibilityHint("Opens the Lava Guard picker".lavaLocalized)
        }
        .sheet(isPresented: $isPresentingPicker) {
            LavaGuardLookPickerSheet(selectedLook: look, onSelect: onSelect)
                .environmentObject(viewModel)
                .environmentObject(security)
        }
    }
}

/// The Lava Guard catalog as a bottom sheet: an info panel up top (when more
/// Guards are still locked) followed by the radio-style single-select list.
private struct LavaGuardLookPickerSheet: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showUpgradePage = false
    @State private var showPrivacyDataPage = false

    let selectedLook: GuardianShieldStyle
    let onSelect: (GuardianShieldStyle) -> Void

    var body: some View {
        NavigationStack {
            LavaSheetScaffold(spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    if !viewModel.configuration.hasLavaSecurityPlus {
                        LavaGuardUnlockInfoPanel(
                            openUpgrade: { showUpgradePage = true },
                            openPrivacyData: { showPrivacyDataPage = true }
                        )
                    }

                    LavaSectionGroup("Choose your Guard") {
                        LavaPlainCard {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(GuardianShieldStyle.allCases.enumerated()), id: \.element.id) { index, look in
                                    let availability = viewModel.lavaGuardAvailability(for: look)
                                    Button {
                                        guard availability.isSelectable else {
                                            return
                                        }
                                        onSelect(look)
                                        dismiss()
                                    } label: {
                                        LavaGuardLookOptionRow(
                                            look: look,
                                            availability: availability,
                                            isSelected: look == selectedLook
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!availability.isSelectable)

                                    if index + 1 < GuardianShieldStyle.allCases.count {
                                        Divider()
                                            .padding(.leading, LavaGuardLookRowMetrics.mascotFrameSize + 12)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Lava Guard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(
                        systemName: "xmark",
                        accessibilityLabel: "Close",
                        role: .cancel,
                        action: dismiss.callAsFunction
                    )
                }
            }
            .navigationDestination(isPresented: $showUpgradePage) {
                SettingsRouteDestinationView(route: .upgrade)
            }
            .navigationDestination(isPresented: $showPrivacyDataPage) {
                SettingsRouteDestinationView(route: .privacyData)
            }
        }
    }
}

/// Moved out of the Customization screen into the picker sheet: the same unlock
/// and privacy copy, now presented as an info panel above the catalog.
private struct LavaGuardUnlockInfoPanel: View {
    let openUpgrade: () -> Void
    let openPrivacyData: () -> Void

    var body: some View {
        LavaInfoCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(.init("Keep Lava protecting you to unlock more Guards, or [**Upgrade**](lavasecurity://settings/upgrade) to unlock them all.".lavaLocalized))
                    .lavaSupportingText()

                Text(.init("Lava Guard progress requires local logs. [**Review Privacy & Data**](lavasecurity://settings/privacy-data)".lavaLocalized))
                    .lavaSupportingText()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tint(LavaStyle.safeGreen)
            .environment(\.openURL, OpenURLAction { url in
                if url == URL(string: "lavasecurity://settings/upgrade") {
                    openUpgrade()
                    return .handled
                }

                if url == URL(string: "lavasecurity://settings/privacy-data") {
                    openPrivacyData()
                    return .handled
                }

                return .systemAction
            })
        }
    }
}

private enum LavaGuardLookRowMetrics {
    static let mascotSize: CGFloat = 48
    static let mascotFrameSize: CGFloat = 52
    static let minRowHeight: CGFloat = 64
    /// Proportion of the masked-icon frame used by the "?" placeholder glyph
    /// (the unknown/locked Guard look). Proportional, so it scales with the frame.
    static let unknownGlyphRatio: CGFloat = 0.44
}

private struct LavaGuardLookContent: View {
    let look: GuardianShieldStyle
    let availability: LavaGuardAvailability
    let showsDescription: Bool

    init(
        look: GuardianShieldStyle,
        availability: LavaGuardAvailability,
        showsDescription: Bool = true
    ) {
        self.look = look
        self.availability = availability
        self.showsDescription = showsDescription
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: LavaGuardLookRowMetrics.mascotFrameSize, height: LavaGuardLookRowMetrics.mascotFrameSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(availability.title(for: look).lavaLocalized)
                    .font(.headline)
                    .foregroundStyle(availability.titleColor(for: look))
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showsDescription, let subtitle = availability.subtitle(for: look) {
                    Text(subtitle.lavaLocalized)
                        .font(.subheadline)
                        .foregroundStyle(LavaStyle.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .minimumScaleFactor(0.82)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .frame(minHeight: LavaGuardLookRowMetrics.minRowHeight)
    }

    @ViewBuilder
    private var icon: some View {
        if availability.isRevealed {
            SoftShieldGuardian(
                size: LavaGuardLookRowMetrics.mascotSize,
                state: .awake,
                animates: false,
                shieldStyle: look
            )
        } else {
            MaskedLavaGuardIcon(size: LavaGuardLookRowMetrics.mascotSize)
        }
    }
}

private struct MaskedLavaGuardIcon: View {
    let size: CGFloat

    var body: some View {
        let contourSize = size * 1.12

        ZStack {
            LavaGuardianShieldShape()
                .stroke(
                    LavaStyle.secondaryText,
                    style: StrokeStyle(
                        lineWidth: max(1.8, size * 0.045),
                        lineCap: .round,
                        lineJoin: .round,
                        dash: [2, 4]
                    )
                )
                .frame(width: contourSize, height: contourSize)

            Text("?")
                .font(.system(size: size * LavaGuardLookRowMetrics.unknownGlyphRatio, weight: .bold, design: .rounded))
                .foregroundStyle(LavaStyle.secondaryText)
        }
        .frame(width: LavaGuardLookRowMetrics.mascotFrameSize, height: LavaGuardLookRowMetrics.mascotFrameSize)
    }
}

private struct LavaGuardLookOptionRow: View {
    let look: GuardianShieldStyle
    let availability: LavaGuardAvailability
    let isSelected: Bool

    var body: some View {
        // The card already insets its content by 16, so the row carries no padding
        // of its own — it just swaps the bespoke trailing radio for the shared
        // trailing checkmark (a lock for gated Guards) via LavaSelectableRow.
        LavaSelectableRow(
            state: selectionState,
            isEnabled: availability.isSelectable,
            horizontalPadding: 0,
            verticalPadding: 0,
            minHeight: LavaGuardLookRowMetrics.minRowHeight
        ) {
            LavaGuardLookContent(
                look: look,
                availability: availability,
                showsDescription: !availability.isRevealed
            )
        }
    }

    private var selectionState: LavaRowSelectionState {
        guard availability.isSelectable else {
            return .locked
        }

        return isSelected ? .selected : .unselected
    }
}

private extension LavaGuardAvailability {
    func title(for look: GuardianShieldStyle) -> String {
        guard !isRevealed else {
            return look.displayName
        }

        if let progress {
            return "Use Lava %d days".lavaLocalizedFormat(progress.requiredUsageDays)
        }

        return "Keep using Lava"
    }

    func subtitle(for look: GuardianShieldStyle) -> String? {
        guard !isRevealed else {
            return look.settingsDescription
        }

        guard isProgressEnabled else {
            return "Progress is off in Privacy & Data"
        }

        guard let progress else {
            return "Keep Lava protecting you to unlock this Guard."
        }

        guard showsProgressDetail else {
            return nil
        }

        let currentDays = min(progress.currentUsageDays, progress.requiredUsageDays)
        return "Currently at: %d days".lavaLocalizedFormat(currentDays)
    }

    func titleColor(for look: GuardianShieldStyle) -> Color {
        isRevealed ? look.dynamicIslandStatusGlyphColor : LavaStyle.ink
    }
}

private extension GuardianShieldStyle {
    var settingsDescription: String {
        switch self {
        case .original:
            "A Lava a day keeps bad domains away."
        case .fireOpal:
            "Always check the link first."
        case .purpleObsidian:
            "Block it once. Browse in peace."
        case .obsidian:
            "Sign in where you meant to sign in."
        case .cherryQuartz:
            "Giveaways should not ask for secrets."
        case .emerald:
            "Make me your web-surfing buddy!"
        case .kiwiCreme:
            "Hey I'm no rock but I take security paw-sonally. U know what I mean?"
        }
    }
}

struct DNSResolverSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    @State private var customResolverDraft = ""
    @State private var customResolverSecondaryDraft = ""
    @State private var customResolverNameDraft = ""
    @State private var hasPendingCustomResolverAddressChange = false
    @State private var hasPendingCustomResolverSecondaryAddressChange = false
    @State private var hasPendingCustomResolverNameChange = false
    @State private var isEditingCustomResolver = false
    @State private var showingCustomResolverDiscardConfirmation = false
    @State private var pendingCustomResolverDiscardAction: CustomResolverDiscardAction?
    @State private var customResolverValidationMessage: String?
    @State private var showUpgradePage = false
    @FocusState private var focusedCustomResolverField: CustomResolverFocusField?

    var body: some View {
        SettingsSubpageContent(
            title: "DNS Resolver",
            tier: .technical,
            intro: LavaInfoPanel(
                title: "How websites get found",
                description: "DNS is how your phone finds a website's address. Our default is safe for almost everyone, so we recommend keeping it.",
                systemImage: "network"
            )
        ) {
            LavaSectionGroup("Device DNS") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Use Device DNS Setting", isOn: useDeviceDNSBinding)
                        .font(.headline)
                        .tint(LavaStyle.safeGreen)
                        .lavaControlRowCard()

                    Text(viewModel.deviceDNSResolverDetailText.lavaLocalized)
                        .lavaQuietNoteText()

                    // The fallback toggle sits directly under the Device DNS detail in
                    // both states. When an encrypted primary is selected it offers the
                    // Device-DNS safety net; when Device DNS is the primary it offers an
                    // encrypted alternative resolver instead. The toggle + its detail now
                    // carry the disclosure that previously lived in static copy.
                    if usesDeviceDNSSetting {
                        ResolverOptionControl(
                            title: "Fallback to alternative DNS",
                            detail: "If your device's DNS stops responding, Lava sends allowed requests to a backup DNS provider, then switches back automatically.",
                            isOn: usesEncryptedDeviceDNSFallbackBinding
                        )
                    } else {
                        ResolverOptionControl(
                            title: "Fallback to Device DNS",
                            detail: viewModel.deviceDNSFallbackDetailText,
                            isOn: fallbackToDeviceDNSBinding
                        )
                    }
                }
            }

            if usesDeviceDNSSetting && viewModel.configuration.usesEncryptedDeviceDNSFallback {
                ResolverPickerSections(
                    selectedPreset: viewModel.configuration.fallbackResolverPreset,
                    configuredCustomAddress: viewModel.configuration.fallbackCustomResolverAddress,
                    configuredCustomSecondaryAddress: viewModel.configuration.fallbackCustomResolverSecondaryAddress,
                    configuredCustomName: viewModel.configuration.fallbackCustomResolverName,
                    allowsCustomDNS: viewModel.configuration.limits.allowsCustomDNS,
                    supportsDNSOverQUIC: viewModel.supportsDNSOverQUIC,
                    selectPreset: { preset in
                        performAppSettingsMutation(reason: "Edit DNS settings") {
                            viewModel.setFallbackResolver(preset)
                        }
                    },
                    saveCustom: { name, primary, secondary in
                        performAppSettingsMutation(reason: "Edit DNS settings") {
                            viewModel.setFallbackCustomResolverName(name)
                            viewModel.setFallbackCustomResolverAddresses(primary: primary, secondary: secondary)
                        }
                    },
                    clearCustom: { fallback in
                        performAppSettingsMutation(reason: "Edit DNS settings") {
                            viewModel.clearFallbackCustomResolver(fallback: fallback)
                        }
                    },
                    requestUpgrade: {
                        showUpgradePage = true
                    }
                )
            }

            if !usesDeviceDNSSetting {
                LavaSectionGroup("DNS Providers", footer: "A provider answers your phone's \"where is this website?\" questions. Any of these are trustworthy.") {
                    LavaCondensedList {
                        ForEach(Array(DNSResolverPreset.settingsPresets.filter { $0.id != DNSResolverPreset.device.id }.enumerated()), id: \.element.id) { _, preset in
                            Button {
                                selectResolver(preset)
                            } label: {
                                LavaSelectableRow(
                                    state: (!isCustomResolverSelected && selectedBaseResolver.id == preset.id) ? .selected : .unselected
                                ) {
                                    ResolverPresetRowContent(
                                        title: preset.displayName,
                                        metadata: metadata(for: preset)
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            .tint(LavaStyle.safeGreen)
                            // Provider-selection VoiceOver semantics (WS-S): lead with the
                            // provider name as the accessibility label and carry the
                            // transport-address summary as the value, so VoiceOver announces
                            // the provider identity first instead of a name+address run-on.
                            // Selection itself stays on LavaSelectableRow's .isSelected trait.
                            .accessibilityLabel(preset.displayName.lavaLocalized)
                            .accessibilityValue(metadata(for: preset).lavaLocalized)

                            LavaCondensedDivider(leadingInset: 16)
                        }

                        Button {
                            selectCustomResolver()
                        } label: {
                            CustomDNSResolverRow(
                                isSelected: isCustomResolverSelected,
                                isEnabled: viewModel.configuration.limits.allowsCustomDNS,
                                metadata: customResolverMetadata
                            )
                        }
                        .buttonStyle(.plain)
                        .tint(LavaStyle.safeGreen)
                        .accessibilityLabel("Custom DNS".lavaLocalized)
                        .accessibilityValue(customResolverMetadata.lavaLocalized)
                    }
                }

                if showsCustomResolverOptions {
                    LavaSectionGroup("Custom Resolver", footer: "For advanced users: enter the address of a DNS service you trust. Not sure? Leave it and pick a provider above.") {
                        VStack(spacing: 12) {
                            LavaTextInputPanel {
                                CustomResolverTextField(
                                    title: "Name (optional)",
                                    placeholder: "Custom DNS",
                                    text: $customResolverNameDraft,
                                    focus: $focusedCustomResolverField,
                                    focusField: .name,
                                    onChange: updateCustomResolverNameDraft
                                )

                                Divider()

                                CustomResolverTextField(
                                    title: "Primary DNS",
                                    placeholder: "IPv4/6, https://, tls://, doq://, quic://, or sdns://",
                                    text: $customResolverDraft,
                                    keyboardType: .URL,
                                    axis: .vertical,
                                    focus: $focusedCustomResolverField,
                                    focusField: .primaryAddress,
                                    onChange: updateCustomResolverDraft
                                )

                                Divider()

                                CustomResolverTextField(
                                    title: "Secondary DNS (optional)",
                                    placeholder: "Same transport as Primary",
                                    text: $customResolverSecondaryDraft,
                                    keyboardType: .URL,
                                    axis: .vertical,
                                    focus: $focusedCustomResolverField,
                                    focusField: .secondaryAddress,
                                    onChange: updateCustomResolverSecondaryDraft
                                )
                            }

                            HStack(spacing: 12) {
                                Button(action: clearCustomResolverDrafts) {
                                    Text("Clear".lavaLocalized)
                                }
                                .buttonStyle(FeedbackSecondaryActionButtonStyle())
                                .disabled(!canClearCustomResolver)

                                Button(action: saveCustomResolver) {
                                    Text(customResolverSaveButtonTitle.lavaLocalized)
                                }
                                .buttonStyle(CustomResolverSaveButtonStyle(isSaved: customResolverSaveButtonTitle == "Saved"))
                                .disabled(!canSaveCustomResolver)
                            }

                            if let customResolverValidationMessage {
                                DomainRejectPanel(title: "Custom DNS cannot be saved", message: customResolverValidationMessage)
                            }
                        }
                    }
                }

                if showsResolverOptions {
                    LavaSectionGroup("DNS Transport", footer: "\"Transport\" is how the lookup travels. IP is unencrypted; DoH, DoT, and DoQ scramble it so others on your network can't see the sites you visit.") {
                        ResolverTransportControl(
                            detail: transportDetailText,
                            selectedBaseResolver: selectedBaseResolver,
                            selection: resolverTransportBinding
                        )
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(customResolverBackButtonIsVisible)
        .toolbar {
            if customResolverBackButtonIsVisible {
                ToolbarItem(placement: .topBarLeading) {
                    NativeToolbarIconButton(systemName: "chevron.left", accessibilityLabel: "Back", action: requestCustomResolverDismiss)
                }
            }
        }
        .lavaConfirmationAlert { host in
            host.alert("Discard custom DNS changes?", isPresented: $showingCustomResolverDiscardConfirmation) {
                Button("Cancel", role: .cancel) {
                    pendingCustomResolverDiscardAction = nil
                }
                Button("Discard", role: .destructive) {
                    discardPendingCustomResolverDraft()
                }
            } message: {
                Text("Your custom DNS draft will be removed.")
            }
        }
        .navigationDestination(isPresented: $showUpgradePage) {
            LavaPlusUpgradeDestination()
        }
        .onAppear(perform: resetCustomResolverDrafts)
        .onDisappear(perform: resetCustomResolverDrafts)
    }

    private var selectedResolver: DNSResolverPreset {
        viewModel.configuration.resolverPreset
    }

    private var selectedBaseResolver: DNSResolverPreset {
        selectedResolver.settingsBasePreset
    }

    private var selectedTransport: DNSResolverTransport {
        selectedResolver.transport
    }

    private var usesDeviceDNSSetting: Bool {
        viewModel.configuration.resolverPresetID == DNSResolverPreset.device.id
    }

    private var isCustomResolverSelected: Bool {
        isEditingCustomResolver || viewModel.configuration.resolverPresetID == DNSResolverPreset.customID
    }

    private var showsResolverOptions: Bool {
        !showsCustomResolverOptions
            && selectedBaseResolver.id != DNSResolverPreset.device.id
            && selectedBaseResolver.id != DNSResolverPreset.customID
    }

    private var showsCustomResolverOptions: Bool {
        (isEditingCustomResolver || isCustomResolverSelected) && viewModel.configuration.limits.allowsCustomDNS
    }

    private var customResolverBackButtonIsVisible: Bool {
        showsCustomResolverOptions
    }

    private var useDeviceDNSBinding: Binding<Bool> {
        Binding {
            usesDeviceDNSSetting
        } set: { newValue in
            guard newValue != usesDeviceDNSSetting else {
                return
            }

            if customResolverHasUnsavedDraft {
                requestCustomResolverDiscard(for: .useDeviceDNS(newValue))
                return
            }

            applyUseDeviceDNSSetting(newValue)
        }
    }

    private func applyUseDeviceDNSSetting(_ newValue: Bool) {
        performAppSettingsMutation(reason: "Edit DNS settings") {
            isEditingCustomResolver = false
            hasPendingCustomResolverAddressChange = false
            hasPendingCustomResolverSecondaryAddressChange = false
            hasPendingCustomResolverNameChange = false

            if newValue {
                viewModel.setResolver(.device)
                resetCustomResolverDrafts()
            } else {
                // Leaving Device DNS: there is no prior non-device transport to restore
                // (`selectedMenuTransport` is forced to `.plainDNS` while Device DNS is
                // selected), so adopt the app's default/top resolver — Mullvad DoH — to
                // match onboarding and the AppConfiguration default, rather than dropping
                // the user onto Google plain IP.
                viewModel.setResolver(.mullvadDoH)
            }
        }
    }

    private var resolverTransportBinding: Binding<DNSResolverTransport> {
        Binding {
            selectedTransport
        } set: { newValue in
            let nextPreset = selectedBaseResolver.resolverVariant(for: newValue)
            performAppSettingsMutation(reason: "Edit DNS settings") {
                viewModel.setResolver(nextPreset)
            }
        }
    }

    private var fallbackToDeviceDNSBinding: Binding<Bool> {
        Binding {
            viewModel.configuration.fallbackToDeviceDNS
        } set: { newValue in
            performAppSettingsMutation(reason: "Edit DNS settings") {
                viewModel.setFallbackToDeviceDNS(newValue)
            }
        }
    }

    private var usesEncryptedDeviceDNSFallbackBinding: Binding<Bool> {
        Binding {
            viewModel.configuration.usesEncryptedDeviceDNSFallback
        } set: { newValue in
            performAppSettingsMutation(reason: "Edit DNS settings") {
                viewModel.setUsesEncryptedDeviceDNSFallback(newValue)
            }
        }
    }

    private var transportDetailText: String {
        "IP uses standard DNS. DNS over HTTPS (DoH), TLS (DoT), and QUIC (DoQ) encrypt allowed lookups to the resolver."
    }

    private var selectedMenuTransport: DNSResolverTransport {
        selectedTransport == .deviceDNS ? .plainDNS : selectedTransport
    }

    private var customResolverMetadata: String {
        guard viewModel.configuration.limits.allowsCustomDNS else {
            return "Upgrade to use DNS over HTTPS, TLS and QUIC"
        }

        let configuredValue = viewModel.configuration.customResolverAddress ?? ""
        let configuredSecondaryValue = viewModel.configuration.customResolverSecondaryAddress ?? ""
        guard let preset = DNSResolverPreset.custom(
            primaryRawValue: configuredValue,
            secondaryRawValue: configuredSecondaryValue
        ) else {
            return "Supports DNS over IP, HTTPS, TLS and QUIC"
        }

        return resolverAddressSummary(for: preset)
    }

    private var trimmedCustomResolverDraft: String {
        customResolverDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCustomResolverSecondaryDraft: String {
        customResolverSecondaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedCustomResolverNameDraft: String? {
        let trimmedValue = customResolverNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private var normalizedConfiguredCustomResolverName: String? {
        let trimmedValue = viewModel.configuration.customResolverName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue?.isEmpty == true ? nil : trimmedValue
    }

    private var normalizedConfiguredCustomResolverAddress: String {
        viewModel.configuration.customResolverAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var normalizedConfiguredCustomResolverSecondaryAddress: String {
        viewModel.configuration.customResolverSecondaryAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var customResolverDraftIsValid: Bool {
        DNSResolverPreset.customValidationMessage(
            primaryRawValue: trimmedCustomResolverDraft,
            secondaryRawValue: trimmedCustomResolverSecondaryDraft,
            supportsDNSOverQUIC: viewModel.supportsDNSOverQUIC
        ) == nil
    }

    private var customResolverDraftMatchesSavedEntry: Bool {
        normalizedConfiguredCustomResolverAddress == trimmedCustomResolverDraft
            && normalizedConfiguredCustomResolverSecondaryAddress == trimmedCustomResolverSecondaryDraft
            && normalizedConfiguredCustomResolverName == normalizedCustomResolverNameDraft
    }

    private var customResolverDraftIsCleared: Bool {
        trimmedCustomResolverDraft.isEmpty
            && trimmedCustomResolverSecondaryDraft.isEmpty
            && normalizedCustomResolverNameDraft == nil
    }

    private var customResolverClearFallbackPreset: DNSResolverPreset {
        let fallbackBasePreset = selectedBaseResolver.id == DNSResolverPreset.customID ? DNSResolverPreset.google : selectedBaseResolver
        return fallbackBasePreset.resolverVariant(for: selectedMenuTransport)
    }

    private var customResolverHasChanges: Bool {
        !customResolverDraftMatchesSavedEntry
    }

    private var customResolverHasUnsavedDraft: Bool {
        customResolverHasChanges
    }

    private var canSaveCustomResolver: Bool {
        customResolverHasChanges
            && (!trimmedCustomResolverDraft.isEmpty || customResolverDraftIsCleared)
    }

    private var canClearCustomResolver: Bool {
        !customResolverDraft.isEmpty || !customResolverSecondaryDraft.isEmpty || !customResolverNameDraft.isEmpty
    }

    private var customResolverSaveButtonTitle: String {
        if !customResolverHasChanges && customResolverDraftIsValid {
            return "Saved"
        }

        return "Save"
    }

    private func selectResolver(_ preset: DNSResolverPreset) {
        if customResolverHasUnsavedDraft {
            requestCustomResolverDiscard(for: .selectResolver(preset))
            return
        }

        applyResolverSelection(preset)
    }

    private func applyResolverSelection(_ preset: DNSResolverPreset) {
        performAppSettingsMutation(reason: "Edit DNS settings") {
            isEditingCustomResolver = false
            hasPendingCustomResolverAddressChange = false
            hasPendingCustomResolverSecondaryAddressChange = false
            hasPendingCustomResolverNameChange = false
            viewModel.setResolver(preset.resolverVariant(for: selectedMenuTransport))
            resetCustomResolverDrafts()
        }
    }

    private func selectCustomResolver() {
        guard viewModel.configuration.limits.allowsCustomDNS else {
            showUpgradePage = true
            return
        }

        isEditingCustomResolver = true
        if !customResolverHasUnsavedDraft {
            customResolverDraft = viewModel.configuration.customResolverAddress ?? ""
            customResolverSecondaryDraft = viewModel.configuration.customResolverSecondaryAddress ?? ""
            customResolverNameDraft = viewModel.configuration.customResolverName ?? ""
            hasPendingCustomResolverAddressChange = false
            hasPendingCustomResolverSecondaryAddressChange = false
            hasPendingCustomResolverNameChange = false
            customResolverValidationMessage = nil
        }
    }

    private func updateCustomResolverDraft() {
        hasPendingCustomResolverAddressChange = true
        customResolverValidationMessage = nil
    }

    private func updateCustomResolverSecondaryDraft() {
        hasPendingCustomResolverSecondaryAddressChange = true
        customResolverValidationMessage = nil
    }

    private func updateCustomResolverNameDraft() {
        hasPendingCustomResolverNameChange = true
        customResolverValidationMessage = nil
    }

    private func resetCustomResolverDrafts() {
        customResolverDraft = viewModel.configuration.customResolverAddress ?? ""
        customResolverSecondaryDraft = viewModel.configuration.customResolverSecondaryAddress ?? ""
        customResolverNameDraft = viewModel.configuration.customResolverName ?? ""
        hasPendingCustomResolverAddressChange = false
        hasPendingCustomResolverSecondaryAddressChange = false
        hasPendingCustomResolverNameChange = false
        customResolverValidationMessage = nil
        isEditingCustomResolver = viewModel.configuration.resolverPresetID == DNSResolverPreset.customID
    }

    private func saveCustomResolver() {
        guard canSaveCustomResolver else {
            return
        }

        if customResolverDraftIsCleared {
            focusedCustomResolverField = nil
            performAppSettingsMutation(reason: "Edit DNS settings") {
                viewModel.clearCustomResolver(fallback: customResolverClearFallbackPreset)
                customResolverDraft = ""
                customResolverSecondaryDraft = ""
                customResolverNameDraft = ""
                hasPendingCustomResolverNameChange = false
                hasPendingCustomResolverAddressChange = false
                hasPendingCustomResolverSecondaryAddressChange = false
                customResolverValidationMessage = nil
                isEditingCustomResolver = false
            }
            return
        }

        if let validationMessage = DNSResolverPreset.customValidationMessage(
            primaryRawValue: trimmedCustomResolverDraft,
            secondaryRawValue: trimmedCustomResolverSecondaryDraft,
            supportsDNSOverQUIC: viewModel.supportsDNSOverQUIC
        ) {
            customResolverValidationMessage = validationMessage
            return
        }

        let trimmedValue = trimmedCustomResolverDraft
        let trimmedSecondaryValue = trimmedCustomResolverSecondaryDraft
        focusedCustomResolverField = nil
        performAppSettingsMutation(reason: "Edit DNS settings") {
            viewModel.setCustomResolverName(customResolverNameDraft)
            viewModel.setCustomResolverAddresses(primary: trimmedValue, secondary: trimmedSecondaryValue)
            customResolverDraft = trimmedValue
            customResolverSecondaryDraft = viewModel.configuration.customResolverSecondaryAddress ?? ""
            customResolverNameDraft = viewModel.configuration.customResolverName ?? ""
            hasPendingCustomResolverNameChange = false
            hasPendingCustomResolverAddressChange = false
            hasPendingCustomResolverSecondaryAddressChange = false
            customResolverValidationMessage = nil
            isEditingCustomResolver = true
        }
    }

    private func clearCustomResolverDrafts() {
        customResolverDraft = ""
        customResolverSecondaryDraft = ""
        customResolverNameDraft = ""
        hasPendingCustomResolverAddressChange = true
        hasPendingCustomResolverSecondaryAddressChange = true
        hasPendingCustomResolverNameChange = true
        customResolverValidationMessage = nil
    }

    private func requestCustomResolverDismiss() {
        if customResolverHasUnsavedDraft {
            requestCustomResolverDiscard(for: .dismiss)
        } else {
            dismiss()
        }
    }

    private func requestCustomResolverDiscard(for action: CustomResolverDiscardAction) {
        pendingCustomResolverDiscardAction = action
        showingCustomResolverDiscardConfirmation = true
    }

    private func discardPendingCustomResolverDraft() {
        let action = pendingCustomResolverDiscardAction
        pendingCustomResolverDiscardAction = nil
        showingCustomResolverDiscardConfirmation = false
        focusedCustomResolverField = nil
        resetCustomResolverDrafts()

        switch action {
        case .selectResolver(let preset):
            applyResolverSelection(preset)
        case .useDeviceDNS(let newValue):
            applyUseDeviceDNSSetting(newValue)
        case .dismiss:
            dismiss()
        case nil:
            break
        }
    }

    private func performAppSettingsMutation(reason: String, action: @escaping @MainActor () -> Void) {
        Task {
            guard await security.requireAuthentication(for: .appSettings, reason: reason) else {
                return
            }

            action()
        }
    }

    private func metadata(for preset: DNSResolverPreset) -> String {
        resolverAddressSummary(for: displayPreset(for: preset))
    }

    private func displayPreset(for preset: DNSResolverPreset) -> DNSResolverPreset {
        preset.resolverVariant(for: selectedMenuTransport)
    }

    private func resolverAddressSummary(for preset: DNSResolverPreset) -> String {
        let dohEndpointAddresses = preset.dohEndpoints.map { $0.url.absoluteString }
        if !dohEndpointAddresses.isEmpty {
            return dohEndpointAddresses.joined(separator: ", ")
        }

        let dotEndpointAddresses = preset.dotEndpoints.map(\.displayAddress)
        if !dotEndpointAddresses.isEmpty {
            return dotEndpointAddresses.joined(separator: ", ")
        }

        let doqEndpointAddresses = preset.doqEndpoints.map(\.displayAddress)
        if !doqEndpointAddresses.isEmpty {
            return doqEndpointAddresses.joined(separator: ", ")
        }

        let servers = preset.allServers
        if !servers.isEmpty {
            return servers.joined(separator: ", ")
        }

        return "Supports DNS over IP, HTTPS, TLS and QUIC"
    }
}

private enum CustomResolverDiscardAction {
    case selectResolver(DNSResolverPreset)
    case useDeviceDNS(Bool)
    case dismiss
}

// Reusable DNS provider list + Custom-resolver editor + transport selector. The
// primary resolver picker is rendered inline in DNSResolverSettingsView (it owns a
// page-level discard-confirmation flow that also guards the Device-DNS toggle and
// page dismissal). This component is used for the encrypted Device-DNS *fallback*
// selection: it owns its own draft state and applies edits immediately through the
// supplied closures, mirroring the primary's provider/transport/custom layout.
private struct ResolverPickerSections: View {
    let selectedPreset: DNSResolverPreset
    let configuredCustomAddress: String?
    let configuredCustomSecondaryAddress: String?
    let configuredCustomName: String?
    let allowsCustomDNS: Bool
    let supportsDNSOverQUIC: Bool
    let selectPreset: (DNSResolverPreset) -> Void
    let saveCustom: (_ name: String, _ primary: String, _ secondary: String) -> Void
    let clearCustom: (_ fallback: DNSResolverPreset) -> Void
    let requestUpgrade: () -> Void

    @State private var customResolverDraft = ""
    @State private var customResolverSecondaryDraft = ""
    @State private var customResolverNameDraft = ""
    @State private var isEditingCustomResolver = false
    @State private var customResolverValidationMessage: String?
    @FocusState private var focusedCustomResolverField: CustomResolverFocusField?

    var body: some View {
        Group {
            LavaSectionGroup("DNS Providers") {
                LavaCondensedList {
                    ForEach(Array(DNSResolverPreset.settingsPresets.filter { $0.id != DNSResolverPreset.device.id }.enumerated()), id: \.element.id) { _, preset in
                        Button {
                            selectBaseResolver(preset)
                        } label: {
                            LavaSelectableRow(
                                state: (!isCustomResolverSelected && selectedBaseResolver.id == preset.id) ? .selected : .unselected
                            ) {
                                ResolverPresetRowContent(
                                    title: preset.displayName,
                                    metadata: metadata(for: preset)
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        .tint(LavaStyle.safeGreen)

                        LavaCondensedDivider(leadingInset: 16)
                    }

                    Button {
                        selectCustomResolver()
                    } label: {
                        CustomDNSResolverRow(
                            isSelected: isCustomResolverSelected,
                            isEnabled: allowsCustomDNS,
                            metadata: customResolverMetadata
                        )
                    }
                    .buttonStyle(.plain)
                    .tint(LavaStyle.safeGreen)
                }
            }

            if showsCustomResolverOptions {
                LavaSectionGroup("Custom Resolver") {
                    VStack(spacing: 12) {
                        LavaTextInputPanel {
                            CustomResolverTextField(
                                title: "Name (optional)",
                                placeholder: "Custom DNS",
                                text: $customResolverNameDraft,
                                focus: $focusedCustomResolverField,
                                focusField: .name,
                                onChange: { customResolverValidationMessage = nil }
                            )

                            Divider()

                            CustomResolverTextField(
                                title: "Primary DNS",
                                placeholder: "IPv4/6, https://, tls://, doq://, quic://, or sdns://",
                                text: $customResolverDraft,
                                keyboardType: .URL,
                                axis: .vertical,
                                focus: $focusedCustomResolverField,
                                focusField: .primaryAddress,
                                onChange: { customResolverValidationMessage = nil }
                            )

                            Divider()

                            CustomResolverTextField(
                                title: "Secondary DNS (optional)",
                                placeholder: "Same transport as Primary",
                                text: $customResolverSecondaryDraft,
                                keyboardType: .URL,
                                axis: .vertical,
                                focus: $focusedCustomResolverField,
                                focusField: .secondaryAddress,
                                onChange: { customResolverValidationMessage = nil }
                            )
                        }

                        HStack(spacing: 12) {
                            Button(action: clearCustomResolverDrafts) {
                                Text("Clear".lavaLocalized)
                            }
                            .buttonStyle(FeedbackSecondaryActionButtonStyle())
                            .disabled(!canClearCustomResolver)

                            Button(action: saveCustomResolver) {
                                Text(customResolverSaveButtonTitle.lavaLocalized)
                            }
                            .buttonStyle(CustomResolverSaveButtonStyle(isSaved: customResolverSaveButtonTitle == "Saved"))
                            .disabled(!canSaveCustomResolver)
                        }

                        if let customResolverValidationMessage {
                            DomainRejectPanel(title: "Custom DNS cannot be saved", message: customResolverValidationMessage)
                        }
                    }
                }
            }

            if showsResolverOptions {
                LavaSectionGroup("DNS Transport") {
                    ResolverTransportControl(
                        detail: transportDetailText,
                        selectedBaseResolver: selectedBaseResolver,
                        selection: transportBinding
                    )
                }
            }
        }
        .onAppear(perform: resetCustomResolverDrafts)
        .onDisappear(perform: resetCustomResolverDrafts)
    }

    private var selectedBaseResolver: DNSResolverPreset {
        selectedPreset.settingsBasePreset
    }

    private var selectedTransport: DNSResolverTransport {
        selectedPreset.transport
    }

    private var selectedMenuTransport: DNSResolverTransport {
        selectedTransport == .deviceDNS ? .plainDNS : selectedTransport
    }

    private var isCustomResolverSelected: Bool {
        isEditingCustomResolver || selectedPreset.id == DNSResolverPreset.customID
    }

    private var showsResolverOptions: Bool {
        !showsCustomResolverOptions
            && selectedBaseResolver.id != DNSResolverPreset.device.id
            && selectedBaseResolver.id != DNSResolverPreset.customID
    }

    private var showsCustomResolverOptions: Bool {
        (isEditingCustomResolver || isCustomResolverSelected) && allowsCustomDNS
    }

    private var transportBinding: Binding<DNSResolverTransport> {
        Binding {
            selectedTransport
        } set: { newValue in
            selectPreset(selectedBaseResolver.resolverVariant(for: newValue))
        }
    }

    private var transportDetailText: String {
        "IP uses standard DNS. DNS over HTTPS (DoH), TLS (DoT), and QUIC (DoQ) encrypt allowed lookups to the resolver."
    }

    private var customResolverMetadata: String {
        guard allowsCustomDNS else {
            return "Upgrade to use DNS over HTTPS, TLS and QUIC"
        }

        let configuredValue = configuredCustomAddress ?? ""
        let configuredSecondaryValue = configuredCustomSecondaryAddress ?? ""
        guard let preset = DNSResolverPreset.custom(
            primaryRawValue: configuredValue,
            secondaryRawValue: configuredSecondaryValue
        ) else {
            return "Supports DNS over IP, HTTPS, TLS and QUIC"
        }

        return resolverAddressSummary(for: preset)
    }

    private var trimmedCustomResolverDraft: String {
        customResolverDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCustomResolverSecondaryDraft: String {
        customResolverSecondaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedCustomResolverNameDraft: String? {
        let trimmedValue = customResolverNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private var normalizedConfiguredCustomResolverName: String? {
        let trimmedValue = configuredCustomName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue?.isEmpty == true ? nil : trimmedValue
    }

    private var normalizedConfiguredCustomResolverAddress: String {
        configuredCustomAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var normalizedConfiguredCustomResolverSecondaryAddress: String {
        configuredCustomSecondaryAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var customResolverDraftIsValid: Bool {
        DNSResolverPreset.customValidationMessage(
            primaryRawValue: trimmedCustomResolverDraft,
            secondaryRawValue: trimmedCustomResolverSecondaryDraft,
            supportsDNSOverQUIC: supportsDNSOverQUIC
        ) == nil
    }

    private var customResolverDraftMatchesSavedEntry: Bool {
        normalizedConfiguredCustomResolverAddress == trimmedCustomResolverDraft
            && normalizedConfiguredCustomResolverSecondaryAddress == trimmedCustomResolverSecondaryDraft
            && normalizedConfiguredCustomResolverName == normalizedCustomResolverNameDraft
    }

    private var customResolverDraftIsCleared: Bool {
        trimmedCustomResolverDraft.isEmpty
            && trimmedCustomResolverSecondaryDraft.isEmpty
            && normalizedCustomResolverNameDraft == nil
    }

    private var customResolverClearFallbackPreset: DNSResolverPreset {
        let fallbackBasePreset = selectedBaseResolver.id == DNSResolverPreset.customID ? DNSResolverPreset.mullvad : selectedBaseResolver
        let variant = fallbackBasePreset.resolverVariant(for: selectedMenuTransport)
        // The encrypted fallback must stay encrypted. A custom DoQ alternative has no
        // built-in QUIC variant, so resolverVariant degrades to plain Mullvad IP —
        // clearing it would silently drop the safety net from encrypted to unencrypted.
        // Coerce that unsupported-QUIC case to the encrypted default/top resolver.
        if selectedMenuTransport == .dnsOverQUIC, variant.transport != .dnsOverQUIC {
            return .mullvadDoH
        }
        return variant
    }

    private var customResolverHasChanges: Bool {
        !customResolverDraftMatchesSavedEntry
    }

    private var canSaveCustomResolver: Bool {
        customResolverHasChanges
            && (!trimmedCustomResolverDraft.isEmpty || customResolverDraftIsCleared)
    }

    private var canClearCustomResolver: Bool {
        !customResolverDraft.isEmpty || !customResolverSecondaryDraft.isEmpty || !customResolverNameDraft.isEmpty
    }

    private var customResolverSaveButtonTitle: String {
        if !customResolverHasChanges && customResolverDraftIsValid {
            return "Saved"
        }

        return "Save"
    }

    private func selectBaseResolver(_ preset: DNSResolverPreset) {
        // Selecting a built-in provider always leaves custom-editing. Set that
        // explicitly and reset the draft text inline — do NOT call
        // resetCustomResolverDrafts() here: the config change via selectPreset is
        // deferred (the parent wraps it in an authenticated mutation), so
        // `selectedPreset` is still the old Custom value at this point, and
        // re-deriving isEditingCustomResolver from it would flip the editor back on
        // and keep the Custom row selected until the page is recreated.
        isEditingCustomResolver = false
        customResolverDraft = configuredCustomAddress ?? ""
        customResolverSecondaryDraft = configuredCustomSecondaryAddress ?? ""
        customResolverNameDraft = configuredCustomName ?? ""
        customResolverValidationMessage = nil
        selectPreset(preset.resolverVariant(for: selectedMenuTransport))
    }

    private func selectCustomResolver() {
        guard allowsCustomDNS else {
            requestUpgrade()
            return
        }

        isEditingCustomResolver = true
        customResolverDraft = configuredCustomAddress ?? ""
        customResolverSecondaryDraft = configuredCustomSecondaryAddress ?? ""
        customResolverNameDraft = configuredCustomName ?? ""
        customResolverValidationMessage = nil
    }

    private func resetCustomResolverDrafts() {
        customResolverDraft = configuredCustomAddress ?? ""
        customResolverSecondaryDraft = configuredCustomSecondaryAddress ?? ""
        customResolverNameDraft = configuredCustomName ?? ""
        customResolverValidationMessage = nil
        isEditingCustomResolver = selectedPreset.id == DNSResolverPreset.customID
    }

    private func saveCustomResolver() {
        guard canSaveCustomResolver else {
            return
        }

        if customResolverDraftIsCleared {
            focusedCustomResolverField = nil
            clearCustom(customResolverClearFallbackPreset)
            customResolverDraft = ""
            customResolverSecondaryDraft = ""
            customResolverNameDraft = ""
            customResolverValidationMessage = nil
            isEditingCustomResolver = false
            return
        }

        if let validationMessage = DNSResolverPreset.customValidationMessage(
            primaryRawValue: trimmedCustomResolverDraft,
            secondaryRawValue: trimmedCustomResolverSecondaryDraft,
            supportsDNSOverQUIC: supportsDNSOverQUIC
        ) {
            customResolverValidationMessage = validationMessage
            return
        }

        let trimmedValue = trimmedCustomResolverDraft
        let trimmedSecondaryValue = trimmedCustomResolverSecondaryDraft
        focusedCustomResolverField = nil
        saveCustom(customResolverNameDraft, trimmedValue, trimmedSecondaryValue)
        customResolverDraft = trimmedValue
        customResolverSecondaryDraft = trimmedSecondaryValue.isEmpty ? "" : trimmedSecondaryValue
        customResolverNameDraft = normalizedCustomResolverNameDraft ?? ""
        customResolverValidationMessage = nil
        isEditingCustomResolver = true
    }

    private func clearCustomResolverDrafts() {
        customResolverDraft = ""
        customResolverSecondaryDraft = ""
        customResolverNameDraft = ""
        customResolverValidationMessage = nil
    }

    private func metadata(for preset: DNSResolverPreset) -> String {
        resolverAddressSummary(for: preset.resolverVariant(for: selectedMenuTransport))
    }

    private func resolverAddressSummary(for preset: DNSResolverPreset) -> String {
        let dohEndpointAddresses = preset.dohEndpoints.map { $0.url.absoluteString }
        if !dohEndpointAddresses.isEmpty {
            return dohEndpointAddresses.joined(separator: ", ")
        }

        let dotEndpointAddresses = preset.dotEndpoints.map(\.displayAddress)
        if !dotEndpointAddresses.isEmpty {
            return dotEndpointAddresses.joined(separator: ", ")
        }

        let doqEndpointAddresses = preset.doqEndpoints.map(\.displayAddress)
        if !doqEndpointAddresses.isEmpty {
            return doqEndpointAddresses.joined(separator: ", ")
        }

        let servers = preset.allServers
        if !servers.isEmpty {
            return servers.joined(separator: ", ")
        }

        return "Supports DNS over IP, HTTPS, TLS and QUIC"
    }
}

private enum CustomResolverFocusField {
    case name
    case primaryAddress
    case secondaryAddress
}

private struct CustomResolverSaveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let isSaved: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isSaved ? LavaStyle.secondaryText : .white)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity)
            .frame(height: LavaSurface.actionButtonHeight)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSaved ? LavaStyle.quietControl : LavaStyle.safeControlGreen)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(configuration.isPressed ? 0.10 : 0))
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .opacity(isEnabled || isSaved ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct CustomResolverTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    var axis: Axis = .horizontal
    let focus: FocusState<CustomResolverFocusField?>.Binding
    let focusField: CustomResolverFocusField
    let onChange: () -> Void

    var body: some View {
        LavaTextInputRow(title: title) {
            TextField(placeholder.lavaLocalized, text: $text, axis: axis)
                .lavaTextInputBody(keyboardType: keyboardType, axis: axis)
                .lineLimit(1...3)
                .focused(focus, equals: focusField)
                .onSubmit {
                    focus.wrappedValue = nil
                }
                .onChange(of: text) { _, _ in
                    onChange()
                }
        }
    }
}

/// Title + transport-address metadata for a preset DNS provider row. The selection
/// checkmark is supplied by the enclosing ``LavaSelectableRow``.
private struct ResolverPresetRowContent: View {
    let title: String
    let metadata: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.lavaLocalized)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)

            if let metadata {
                Text(metadata.lavaLocalized)
                    .lavaMetadataText()
            }
        }
    }
}

private struct CustomDNSResolverRow: View {
    let isSelected: Bool
    let isEnabled: Bool
    let metadata: String

    var body: some View {
        LavaSelectableRow(
            state: isSelected ? .selected : .unselected,
            verticalPadding: 9,
            minHeight: 52
        ) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Custom DNS".lavaLocalized)
                    .font(.subheadline.weight(.medium))
                    .lavaInactiveText(!isEnabled)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)

                metadataView
            }
        }
    }

    @ViewBuilder
    private var metadataView: some View {
        if isEnabled {
            Text(metadata.lavaLocalized)
                .lavaMetadataText()
        } else {
            // One concatenated Text so the copy flows and wraps as a single
            // paragraph instead of "Upgrade" sitting in its own column beside a
            // separately-wrapping remainder.
            (Text("Upgrade".lavaLocalized)
                .font(.caption.weight(.bold))
                .foregroundStyle(LavaStyle.safeGreen)
             + Text(" to use DNS over HTTPS, TLS and QUIC".lavaLocalized)
                .font(.caption)
                .foregroundStyle(LavaStyle.secondaryText))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
        }
    }
}

private struct ResolverTransportControl: View {
    let detail: String
    let selectedBaseResolver: DNSResolverPreset
    @Binding var selection: DNSResolverTransport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("DNS Transport", selection: $selection) {
                ForEach(selectedBaseResolver.availableTransports, id: \.self) { transport in
                    Text(transport.menuTitle.lavaLocalized)
                        .tag(transport)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lavaControlRowCard()

            Text(detail.lavaLocalized)
                .lavaQuietNoteText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ResolverToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title.lavaLocalized, isOn: $isOn)
            .font(.headline)
            .tint(LavaStyle.safeGreen)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ResolverOptionControl: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ResolverToggleRow(title: title, isOn: $isOn)
                .lavaControlRowCard()

            Text(detail.lavaLocalized)
                .lavaQuietNoteText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PrivacyDataSettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    @State private var disableTarget: LocalLogSetting?
    @State private var clearTarget: LocalLogClearTarget?
    @State private var showsClearOptions = false
    @State private var localLogExportDocument: LocalLogExportDocument?
    @State private var localLogExportFilename = "lava-local-logs.zip"
    @State private var isPresentingLocalLogExporter = false
    @State private var localLogExportErrorMessage: String?

    var body: some View {
        SettingsSubpageContent(
            title: "Privacy & Data",
            tier: .calm,
            intro: LavaInfoPanel(
                title: "All local logs stay on this iPhone",
                description: "Domain history and network activity are kept for 7 days; counts and Lava Guard progress last longer. Keep or clear each below.",
                systemImage: "eyeglasses"
            )
        ) {
            LavaSectionGroup("Local Logs", footer: "Detailed activity is kept for 7 days — export to keep a copy.") {
                VStack(spacing: 10) {
                    LavaCondensedList {
                        localLogToggle("Filtering Counts", isOn: keepFilteringCountsBinding)

                        LavaCondensedDivider()

                        localLogToggle("Domain Logs", isOn: keepDomainHistoryBinding)

                        LavaCondensedDivider()

                        localLogToggle("Network Activity", isOn: keepNetworkActivityBinding)

                        LavaCondensedDivider()

                        localLogToggle("Lava Guard Progress", isOn: keepLavaGuardProgressBinding)
                    }
                    .font(.headline)
                    .tint(LavaStyle.safeGreen)

                    Button {
                        exportLocalLogs()
                    } label: {
                        ExportLocalLogsRow()
                            .lavaControlRowCard()
                    }
                    .buttonStyle(.plain)

                    if let localLogExportErrorMessage {
                        Text(localLogExportErrorMessage)
                            .lavaQuietNoteText()
                            .foregroundStyle(.red)
                    }
                }
            }

            LavaSectionGroup("Delete Local Logs") {
                VStack(spacing: 10) {
                    Toggle("Show Delete Options", isOn: $showsClearOptions)
                        .font(.headline)
                        .tint(LavaStyle.safeGreen)
                        .lavaControlRowCard()

                    if showsClearOptions {
                        VStack(spacing: 10) {
                            LavaCondensedList {
                                localLogClearButton(.filteringCounts)
                                LavaCondensedDivider()
                                localLogClearButton(.domainHistory)
                                LavaCondensedDivider()
                                localLogClearButton(.networkActivity)
                                LavaCondensedDivider()
                                localLogClearButton(.lavaGuardProgress)
                            }

                            LavaCondensedList {
                                localLogClearButton(.all)
                            }
                        }
                    }
                }
            }
        }
        .fileExporter(
            isPresented: $isPresentingLocalLogExporter,
            document: localLogExportDocument,
            contentType: .zip,
            defaultFilename: localLogExportFilename
        ) { result in
            handleLocalLogExportCompletion(result)
        }
        .lavaConfirmationAlert { host in
            host.alert(
                disableTarget?.disableTitle.lavaLocalized ?? "",
                isPresented: disableConfirmationBinding,
                presenting: disableTarget
            ) { target in
                Button("Cancel", role: .cancel) {}
                Button(target.disableActionTitle.lavaLocalized, role: .destructive) {
                    disable(target)
                }
            } message: { target in
                Text(target.disableMessage.lavaLocalized)
            }
        }
        .lavaConfirmationAlert { host in
            host.alert(
                clearTarget?.clearTitle.lavaLocalized ?? "",
                isPresented: clearConfirmationBinding,
                presenting: clearTarget
            ) { target in
                Button("Cancel", role: .cancel) {}
                Button(target.clearActionTitle.lavaLocalized, role: .destructive) {
                    clear(target)
                }
            } message: { target in
                Text(target.clearMessage.lavaLocalized)
            }
        }
    }

    private var keepFilteringCountsBinding: Binding<Bool> {
        Binding {
            viewModel.configuration.keepFilteringCounts
        } set: { newValue in
            if newValue {
                performAppSettingsMutation(reason: "Edit Privacy & Data settings") {
                    viewModel.setKeepFilteringCounts(true)
                }
            } else {
                disableTarget = .filteringCounts
            }
        }
    }

    private var keepDomainHistoryBinding: Binding<Bool> {
        Binding {
            viewModel.configuration.keepDomainDiagnostics
        } set: { newValue in
            if newValue {
                performAppSettingsMutation(reason: "Edit Privacy & Data settings") {
                    viewModel.setKeepDomainDiagnostics(true)
                }
            } else {
                disableTarget = .domainHistory
            }
        }
    }

    private var keepNetworkActivityBinding: Binding<Bool> {
        Binding {
            viewModel.configuration.keepNetworkActivity
        } set: { newValue in
            if newValue {
                performAppSettingsMutation(reason: "Edit Privacy & Data settings") {
                    viewModel.setKeepNetworkActivity(true)
                }
            } else {
                disableTarget = .networkActivity
            }
        }
    }

    private var keepLavaGuardProgressBinding: Binding<Bool> {
        Binding {
            viewModel.configuration.keepLavaGuardProgress
        } set: { newValue in
            if newValue {
                performAppSettingsMutation(reason: "Edit Privacy & Data settings") {
                    viewModel.setKeepLavaGuardProgress(true)
                }
            } else {
                disableTarget = .lavaGuardProgress
            }
        }
    }

    private var disableConfirmationBinding: Binding<Bool> {
        Binding {
            disableTarget != nil
        } set: { isPresented in
            if !isPresented {
                disableTarget = nil
            }
        }
    }

    private var clearConfirmationBinding: Binding<Bool> {
        Binding {
            clearTarget != nil
        } set: { isPresented in
            if !isPresented {
                clearTarget = nil
            }
        }
    }

    private func disable(_ target: LocalLogSetting) {
        performAppSettingsMutation(reason: "Edit Privacy & Data settings") {
            switch target {
            case .filteringCounts:
                viewModel.setKeepFilteringCounts(false)
            case .domainHistory:
                viewModel.setKeepDomainDiagnostics(false)
            case .networkActivity:
                viewModel.setKeepNetworkActivity(false)
            case .lavaGuardProgress:
                viewModel.setKeepLavaGuardProgress(false)
            }
        }
    }

    private func localLogToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title.lavaLocalized, isOn: isOn)
            .lavaRow()
    }

    private func localLogClearButton(_ target: LocalLogClearTarget) -> some View {
        Button(role: .destructive) {
            clearTarget = target
        } label: {
            SettingsActionRow(
                title: target.buttonTitle,
                iconTint: .red,
                titleTint: .red
            ) {
                Image(systemName: target.systemImage)
                    .font(.title3.weight(.semibold))
            }
            .lavaRow()
        }
        .buttonStyle(.plain)
    }

    private func clear(_ target: LocalLogClearTarget) {
        performAppSettingsMutation(reason: "Delete Local Logs") {
            switch target {
            case .filteringCounts:
                viewModel.clearLocalFilteringCounts()
            case .domainHistory:
                viewModel.clearDomainHistory()
            case .networkActivity:
                viewModel.clearNetworkActivityLog()
            case .lavaGuardProgress:
                viewModel.clearLavaGuardProgress()
            case .all:
                viewModel.clearAllLocalLogs()
            }
        }
    }

    private func exportLocalLogs() {
        performAppSettingsMutation(reason: "Export local logs") {
            do {
                let archive = try viewModel.makeLocalLogExportArchive()
                localLogExportFilename = archive.filename
                localLogExportDocument = LocalLogExportDocument(data: archive.data)
                localLogExportErrorMessage = nil
                isPresentingLocalLogExporter = true
            } catch {
                localLogExportErrorMessage = "Could not export local logs: \(error.localizedDescription)"
            }
        }
    }

    private func handleLocalLogExportCompletion(_ result: Result<URL, Error>) {
        localLogExportDocument = nil

        if case .failure(let error) = result {
            let nsError = error as NSError
            guard !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) else {
                return
            }

            localLogExportErrorMessage = "Could not save local logs: \(error.localizedDescription)"
        }
    }

    private func performAppSettingsMutation(reason: String, action: @escaping @MainActor () -> Void) {
        Task {
            guard await security.requireAuthentication(for: .appSettings, reason: reason) else {
                return
            }

            action()
        }
    }
}

private struct SecuritySettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    @State private var isShowingPasscodeSetup = false

    var body: some View {
        SettingsSubpageContent(
            title: "Security",
            tier: .calm,
            intro: LavaInfoPanel(
                title: "Lock Lava with a passcode",
                description: "Add a passcode or Face ID so only you can change Lava. Pick which screens ask for it below.",
                systemImage: "lock.fill"
            )
        ) {
            LavaSectionGroup("Authentication method") {
                LavaCondensedList {
                    Toggle("Passcode", isOn: passcodeBinding)
                        .lavaRow()

                    if security.shouldShowBiometricToggle {
                        LavaCondensedDivider()

                        Toggle(security.biometricToggleTitle.lavaLocalized, isOn: biometricBinding)
                            .lavaRow()
                            .disabled(!security.canEnableBiometrics)
                    }
                }
                .font(.headline)
                .tint(LavaStyle.safeGreen)
            }

            LavaSectionGroup(
                "Use authentication for",
                footer: "These switches turn on after you set a passcode or Face ID above. Each one decides which screen asks before it lets you in."
            ) {
                LavaCondensedList {
                    ForEach(Array(authenticationSurfaces.enumerated()), id: \.offset) { index, item in
                        securitySurfaceToggle(item.title, surface: item.surface)

                        if index < authenticationSurfaces.count - 1 {
                            LavaCondensedDivider()
                        }
                    }
                }
                .disabled(!security.hasAuthenticationMethod)
                .opacity(security.hasAuthenticationMethod ? 1 : 0.45)
            }

            if let statusMessage = security.statusMessage {
                Text(statusMessage.lavaLocalized)
                    .lavaQuietNoteText()
            }
        }
        .fullScreenCover(isPresented: $isShowingPasscodeSetup) {
            SecurityPasscodeSetupView()
                .environmentObject(security)
        }
    }

    private var passcodeBinding: Binding<Bool> {
        Binding {
            security.isPasscodeEnabled
        } set: { isEnabled in
            if isEnabled {
                isShowingPasscodeSetup = true
            } else {
                Task {
                    guard await security.requirePasscodeAuthentication(reason: "Turn off Security passcode") else {
                        return
                    }

                    security.disablePasscode()
                }
            }
        }
    }

    private var biometricBinding: Binding<Bool> {
        Binding {
            security.isBiometricEnabled
        } set: { isEnabled in
            Task {
                if isEnabled {
                    await security.setBiometricEnabled(true)
                    return
                }

                guard await security.requireBiometricAuthentication(reason: "Turn off %@".lavaLocalizedFormat(security.biometricToggleTitle)) else {
                    return
                }

                await security.setBiometricEnabled(false)
            }
        }
    }

    private var authenticationSurfaces: [(title: String, surface: SecurityProtectedSurface)] {
        [
            ("App Unlock", .appUnlock),
            ("Turn on/off Lava", .protectionControl),
            ("Pause Lava", .protectionPause),
            ("Update domains and lists", .filterEditing),
            ("View Activities", .activityViewing),
            ("Update App Settings", .appSettings),
        ]
    }

    private func securitySurfaceToggle(_ title: String, surface: SecurityProtectedSurface) -> some View {
        Toggle(title.lavaLocalized, isOn: Binding {
            security.hasAuthenticationMethod && security.isProtected(surface)
        } set: { isEnabled in
            guard security.hasAuthenticationMethod else {
                return
            }

            security.setProtection(isEnabled, for: surface)
            if surface == .protectionPause {
                viewModel.reconcileLiveActivity()
            }
        })
        .font(.headline)
        .tint(LavaStyle.safeGreen)
        .lavaRow()
    }
}

private enum SecurityPasscodeSetupPhase {
    case enter
    case confirm

    var title: String {
        switch self {
        case .enter:
            return "Set Passcode"
        case .confirm:
            return "Confirm Passcode"
        }
    }

    var subtitle: String {
        switch self {
        case .enter:
            return "Enter a 4-digit code for Lava"
        case .confirm:
            return "Enter it again to confirm"
        }
    }
}

private struct SecurityPasscodeSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var security: SecurityController
    @State private var phase: SecurityPasscodeSetupPhase = .enter
    @State private var firstCode = ""
    @State private var code = ""
    @State private var message: String?
    @State private var isPasscodeFieldFocused = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: LavaIconSize.hero, weight: .semibold))
                    .foregroundStyle(LavaStyle.safeGreen)

                VStack(spacing: 8) {
                    Text(phase.title.lavaLocalized)
                        .font(.title.bold())
                    Text(phase.subtitle.lavaLocalized)
                        .lavaSupportingText()
                        .multilineTextAlignment(.center)
                }

                SecurityPasscodeDigitsView(code: code)

                if let message {
                    Text(message.lavaLocalized)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                }

                SecurityHiddenPasscodeField(code: $code, isFocused: $isPasscodeFieldFocused)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .onChange(of: code) { _, newValue in
                        handleCodeChange(newValue)
                    }

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LavaStyle.groupedBackground.ignoresSafeArea())
            .navigationTitle("Passcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Cancel", role: .cancel, action: dismiss.callAsFunction)
                }
            }
            .task {
                await focusPasscodeField()
            }
            .onTapGesture {
                isPasscodeFieldFocused = true
            }
        }
    }

    @MainActor
    private func focusPasscodeField() async {
        isPasscodeFieldFocused = false
        try? await Task.sleep(nanoseconds: 200_000_000)
        isPasscodeFieldFocused = true
    }

    private func handleCodeChange(_ value: String) {
        let filtered = String(value.filter(\.isNumber).prefix(4))
        if filtered != value {
            code = filtered
            return
        }

        guard filtered.count == 4 else {
            return
        }

        switch phase {
        case .enter:
            firstCode = filtered
            code = ""
            message = nil
            phase = .confirm
        case .confirm:
            guard filtered == firstCode else {
                message = "Passcodes did not match"
                phase = .enter
                firstCode = ""
                code = ""
                return
            }

            do {
                try security.setPasscode(filtered)
                dismiss()
            } catch {
                message = error.localizedDescription
                phase = .enter
                firstCode = ""
                code = ""
            }
        }
    }
}

private struct ExportLocalLogsRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Export Local Logs".lavaLocalized)
                .font(.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Image(systemName: "square.and.arrow.up")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private enum LocalLogSetting: Identifiable {
    case filteringCounts
    case domainHistory
    case networkActivity
    case lavaGuardProgress

    var id: String {
        switch self {
        case .filteringCounts:
            return "filtering-counts"
        case .domainHistory:
            return "domain-history"
        case .networkActivity:
            return "network-activity"
        case .lavaGuardProgress:
            return "lava-guard-progress"
        }
    }

    var disableTitle: String {
        switch self {
        case .filteringCounts:
            return "Turn off local filtering counts?"
        case .domainHistory:
            return "Turn off local domain history?"
        case .networkActivity:
            return "Turn off local network activity?"
        case .lavaGuardProgress:
            return "Turn off Lava Guard progress?"
        }
    }

    var disableActionTitle: String {
        switch self {
        case .filteringCounts:
            return "Turn Off and Clear Counts"
        case .domainHistory:
            return "Turn Off and Clear History"
        case .networkActivity:
            return "Turn Off and Clear Activity"
        case .lavaGuardProgress:
            return "Turn Off and Clear Progress"
        }
    }

    var disableMessage: String {
        switch self {
        case .filteringCounts:
            return "Saved filtering counts will be cleared and new allowed, blocked, and local protection uptime counts will not be saved."
        case .domainHistory:
            return "Saved domain names will be cleared and new domain names will not be saved."
        case .networkActivity:
            return "Saved network activity entries will be cleared and new network activity entries will not be saved."
        case .lavaGuardProgress:
            return "Saved Lava Guard progress will be cleared and new Lava Guard progress will not be saved."
        }
    }
}

private enum LocalLogClearTarget: Identifiable {
    case filteringCounts
    case domainHistory
    case networkActivity
    case lavaGuardProgress
    case all

    var id: String {
        switch self {
        case .filteringCounts:
            return "filtering-counts"
        case .domainHistory:
            return "domain-history"
        case .networkActivity:
            return "network-activity"
        case .lavaGuardProgress:
            return "lava-guard-progress"
        case .all:
            return "all"
        }
    }

    var systemImage: String {
        "trash"
    }

    var buttonTitle: String {
        switch self {
        case .filteringCounts:
            return "Clear filtering counts"
        case .domainHistory:
            return "Clear domain history"
        case .networkActivity:
            return "Clear network activity"
        case .lavaGuardProgress:
            return "Clear Lava Guard progress"
        case .all:
            return "Clear all logs"
        }
    }

    var clearTitle: String {
        switch self {
        case .filteringCounts:
            return "Clear filtering counts?"
        case .domainHistory:
            return "Clear domain history?"
        case .networkActivity:
            return "Clear network activity?"
        case .lavaGuardProgress:
            return "Clear Lava Guard progress?"
        case .all:
            return "Clear all logs?"
        }
    }

    var clearActionTitle: String {
        switch self {
        case .filteringCounts:
            return "Clear Counts"
        case .domainHistory:
            return "Clear History"
        case .networkActivity:
            return "Clear Activity"
        case .lavaGuardProgress:
            return "Clear Progress"
        case .all:
            return "Clear All Logs"
        }
    }

    var clearMessage: String {
        switch self {
        case .filteringCounts:
            return "This removes saved allowed, blocked, and local protection uptime counts from this phone."
        case .domainHistory:
            return "This removes saved domain rows from this phone. Filtering counts and network activity are unchanged."
        case .networkActivity:
            return "This removes saved network activity entries from this phone. Filtering counts and domain history are unchanged."
        case .lavaGuardProgress:
            return "This removes unearned Lava Guard progress from this phone. Earned Lava Guards stay unlocked."
        case .all:
            return "This removes saved filtering counts, domain history, network activity, and unearned Lava Guard progress from this phone."
        }
    }
}

private enum BugReportStep: Int, CaseIterable, Identifiable {
    case topic
    case context
    case review

    var id: Int { rawValue }
    var stepNumber: Int { rawValue + 1 }
    var displayNumber: String {
        switch self {
        case .topic:
            "1."
        case .context:
            "2."
        case .review:
            "3."
        }
    }

    var title: String {
        switch self {
        case .topic:
            "Topic"
        case .context:
            "Details"
        case .review:
            "Review"
        }
    }
}

struct BugReportSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    @Binding private var externalIsReportDirty: Bool
    private let onDismissRequested: (() -> Void)?
    @State private var selectedIssueType: BugReportIssueType?
    @State private var affectedSite = ""
    @State private var details = ""
    @State private var contactEmail = ""
    @State private var includeDiagnostics = false
    @State private var currentStep: BugReportStep = .topic
    @State private var furthestVisitedStep: BugReportStep = .topic
    @State private var isShowingDiscardConfirmation = false
    @State private var isShowingThankYou = false
    @State private var didCopySubmittedReportID = false

    init(
        isReportDirty: Binding<Bool> = .constant(false),
        onDismissRequested: (() -> Void)? = nil
    ) {
        self._externalIsReportDirty = isReportDirty
        self.onDismissRequested = onDismissRequested
    }

    var body: some View {
        SettingsSubpageContent(title: "Feedback", tier: .calm, spacing: SettingsSubpageLayout.feedbackSpacing, scrolls: !isShowingThankYou) {
            if isShowingThankYou {
                thankYouPage
            } else {
                BugReportStepProgressView(
                    currentStep: currentStep,
                    furthestVisitedStep: furthestVisitedStep,
                    selectStep: goToStep
                )
                currentPage
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isShowingThankYou {
                thankYouBottomActionBar
            } else {
                feedbackBottomActionBar
            }
        }
        .navigationBarBackButtonHidden(isReportDirty && onDismissRequested == nil)
        .toolbar {
            if isReportDirty && onDismissRequested == nil {
                ToolbarItem(placement: .topBarLeading) {
                    NativeToolbarIconButton(systemName: "chevron.left", accessibilityLabel: "Back", action: requestDismiss)
                }
            }

            if onDismissRequested != nil && !isShowingThankYou {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Cancel", role: .cancel, action: requestDismiss)
                }
            }
        }
        .lavaConfirmationAlert { host in
            host.alert("Discard feedback?", isPresented: $isShowingDiscardConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Discard", role: .destructive) {
                    discardAndDismiss()
                }
            } message: {
                Text("Your feedback draft will be removed.")
            }
        }
        .task(id: isAppUnlockMaskVisible) {
            // Don't sample device diagnostics (connectivity/health/network log)
            // while the content is masked for App Unlock; re-sample once the mask
            // drops on unlock so the draft carries fresh, post-unlock diagnostics.
            guard !isAppUnlockMaskVisible else { return }
            await viewModel.sampleReports()
            // `sampleReports()` isn't cancellation-aware, so the app may have
            // locked during the await (this task is cancelled, but execution
            // resumes). Re-check before refreshing the draft so we never rebuild
            // it above the lock — the unlock transition starts a fresh task.
            guard !Task.isCancelled, !isAppUnlockMaskVisible else { return }
            refreshDraft()
            syncReportDirtyState()
        }
        .onDisappear {
            externalIsReportDirty = false
        }
        .onChange(of: selectedIssueType) { _, newValue in
            if newValue != .websiteAccess && !affectedSite.isEmpty {
                affectedSite = ""
            }
            refreshDraft()
            syncReportDirtyState()
        }
        .onChange(of: affectedSite) { _, _ in reportInputChanged() }
        .onChange(of: details) { _, _ in reportInputChanged() }
        .onChange(of: contactEmail) { _, _ in reportInputChanged() }
        .onChange(of: includeDiagnostics) { _, _ in reportInputChanged() }
        .onChange(of: isShowingThankYou) { _, _ in syncReportDirtyState() }
        // Opaque, hit-blocking mask over the WHOLE sheet (form + bottom action
        // bar) while App Unlock is pending or the privacy mask is up. Placed as
        // the last modifier so it composes over `.safeAreaInset` (the Submit /
        // Continue bar) — content stays unreadable and unsubmittable above the
        // lock overlay. The toolbar Cancel/Back buttons live in nav chrome above
        // this overlay and are intentionally left reachable: they only dismiss
        // (never reveal or submit content).
        .overlay {
            if isAppUnlockMaskVisible {
                BugReportSheetLockMask(
                    unlock: { Task { await security.authenticateAppUnlockIfNeeded() } }
                )
            }
        }
    }

    @ViewBuilder
    private var currentPage: some View {
        switch currentStep {
        case .topic:
            topicPage
        case .context:
            contextPage
        case .review:
            reviewPage
        }
    }

    private var topicPage: some View {
        VStack(spacing: 18) {
            LavaInfoPanel(
                title: "No silent telemetry",
                description: "Lava only sends feedback after you review it and tap Submit",
                systemImage: "ladybug"
            )

            LavaSectionGroup("Choose a topic") {
                LavaCondensedList {
                    ForEach(Array(BugReportIssueType.allCases.enumerated()), id: \.element.id) { index, type in
                        Button {
                            selectIssueType(type)
                        } label: {
                            BugReportTopicOptionRow(
                                title: type.title,
                                isSelected: selectedIssueType == type
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedIssueType == type ? [.isSelected] : [])

                        if index < BugReportIssueType.allCases.count - 1 {
                            LavaCondensedDivider()
                        }
                    }
                }
            }
        }
    }

    private var contextPage: some View {
        VStack(spacing: 18) {
            LavaSectionGroup("Tell us more") {
                VStack(spacing: 10) {
                    LavaTextInputPanel {
                        if selectedIssueType == .websiteAccess {
                            LavaTextInputRow(title: "Site or domain") {
                                TextField("Site or domain".lavaLocalized, text: $affectedSite)
                                    .lavaTextInputBody(keyboardType: .URL)
                                    // Implicit cap for the URL field — enforced silently, no counter (UR-29).
                                    .onChange(of: affectedSite) { _, newValue in
                                        if newValue.count > BugReportInputLimits.affectedSite {
                                            affectedSite = String(newValue.prefix(BugReportInputLimits.affectedSite))
                                        }
                                    }
                            }

                            Divider()
                        }

                        // Details carries an explicit live counter; the others stay implicit (UR-29).
                        LavaTextEditorInputRow(
                            title: "Details",
                            text: $details,
                            placeholder: "What were you trying to do? What did Lava do instead?",
                            characterLimit: BugReportInputLimits.details
                        )

                        Divider()

                        LavaTextInputRow(title: "Email for follow-up (optional)") {
                            TextField("Email for follow-up (optional)".lavaLocalized, text: $contactEmail)
                                .lavaTextInputBody(keyboardType: .emailAddress)
                                // Implicit cap for the email field — enforced silently, no counter (UR-29).
                                .onChange(of: contactEmail) { _, newValue in
                                    if newValue.count > BugReportInputLimits.contactEmail {
                                        contactEmail = String(newValue.prefix(BugReportInputLimits.contactEmail))
                                    }
                                }
                        }
                    }

                    Toggle("Include optional diagnostic", isOn: $includeDiagnostics)
                        .font(.headline)
                        .tint(LavaStyle.safeGreen)
                        .lavaControlRowCard()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Optional diagnostics include anonymized Lava Data like VPN status, network logs, and filter snapshot. They help the Lava team better investigate what went wrong.")
                    .lavaQuietNoteText()

                NavigationLink {
                    BugReportDiagnosticsInfoView(sections: diagnosticPreviewSections)
                } label: {
                    Text("See what information is sent".lavaLocalized)
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LavaStyle.safeGreen)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var reviewPage: some View {
        VStack(spacing: 18) {
            LavaSectionGroup("Review and submit") {
                VStack(spacing: 10) {
                    // Mirror the "Tell us more" panel layout (stacked label-above-value rows in
                    // a single card) so the review reads as a read-only echo of what was typed,
                    // instead of every field claiming its own fixed-width header column (UR-26).
                    LavaTextInputPanel {
                        BugReportReviewRow(label: "Topic", value: selectedIssueType.map { $0.title.lavaLocalized } ?? "Not selected".lavaLocalized)

                        if selectedIssueType == .websiteAccess {
                            Divider()

                            BugReportReviewRow(label: "Site or domain", value: normalizedAffectedSite)
                        }

                        Divider()

                        BugReportReviewRow(label: "Details", value: normalizedDetails.isEmpty ? "Not provided" : normalizedDetails)

                        Divider()

                        BugReportReviewRow(label: "Email", value: normalizedContactEmail.isEmpty ? "Not provided" : normalizedContactEmail)

                        Divider()

                        BugReportReviewRow(label: "Diagnostics", value: includeDiagnostics ? "Sent" : "Not sent")
                    }
                }
            }

            bugReportStatusView
        }
    }

    private var thankYouPage: some View {
        VStack(spacing: 20) {
            FeedbackThankYouMascot()

            VStack(spacing: 12) {
                Text(thankYouTitle.lavaLocalized)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 6) {
                    Text("Report ID:".lavaLocalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LavaStyle.secondaryText)

                    Text(submittedReportID)
                        .font(.footnote.monospaced())
                        .foregroundStyle(LavaStyle.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var thankYouBottomActionBar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                Button {
                    copySubmittedReportID()
                } label: {
                    Text((didCopySubmittedReportID ? "Copied!" : "Copy ID").lavaLocalized)
                        .contentTransition(.identity)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LavaPanelActionButtonStyle())
                .disabled(submittedReportID.isEmpty)

                Button {
                    dismissAfterSubmit()
                } label: {
                    Text("Done".lavaLocalized)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LavaStandaloneActionButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(LavaStyle.groupedBackground)
    }

    @ViewBuilder
    private var feedbackBottomActionBar: some View {
        VStack(spacing: 0) {
            Divider()

            feedbackBottomActionButtons
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .background(LavaStyle.groupedBackground)
    }

    @ViewBuilder
    private var feedbackBottomActionButtons: some View {
        switch currentStep {
        case .topic:
            Button {
                refreshDraft()
                markStepVisited(.context)
                currentStep = .context
            } label: {
                Text("Continue".lavaLocalized)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(LavaStandaloneActionButtonStyle())
            .disabled(selectedIssueType == nil)
        case .context:
            HStack(spacing: 12) {
                Button {
                    moveBack()
                } label: {
                    Text("Back".lavaLocalized)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FeedbackSecondaryActionButtonStyle())

                Button {
                    refreshDraft()
                    markStepVisited(.review)
                    currentStep = .review
                } label: {
                    Text("Review".lavaLocalized)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LavaStandaloneActionButtonStyle())
                .disabled(!canContinueFromContext)
            }
        case .review:
            HStack(spacing: 12) {
                Button {
                    moveBack()
                } label: {
                    Text("Back".lavaLocalized)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(FeedbackSecondaryActionButtonStyle())
                .disabled(viewModel.bugReportSendState.isSending)

                Button {
                    submitReport()
                } label: {
                    Text(submitButtonTitle.lavaLocalized)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LavaStandaloneActionButtonStyle())
                .disabled(!canContinueFromContext || viewModel.bugReportSendState.isSending || viewModel.bugReportDraft == nil)
            }
        }
    }

    private func goToStep(_ step: BugReportStep) {
        guard step.rawValue <= furthestVisitedStep.rawValue else {
            return
        }

        currentStep = step
    }

    private func markStepVisited(_ step: BugReportStep) {
        if step.rawValue > furthestVisitedStep.rawValue {
            furthestVisitedStep = step
        }
    }

    private func moveBack() {
        switch currentStep {
        case .topic:
            break
        case .context:
            currentStep = .topic
        case .review:
            currentStep = .context
        }
    }

    @ViewBuilder
    private var bugReportStatusView: some View {
        switch viewModel.bugReportSendState {
        case .idle, .sent, .sending:
            EmptyView()
        case .failed(let message):
            LavaInfoPanel(
                title: "Could not send feedback",
                description: message,
                systemImage: "exclamationmark.triangle.fill",
                tint: LavaStyle.lavaOrange
            )
        }
    }

    private func selectIssueType(_ type: BugReportIssueType) {
        selectedIssueType = type
        if type != .websiteAccess {
            affectedSite = ""
        }
        viewModel.resetBugReportSendState()
    }

    private func requestDismiss() {
        if isReportDirty {
            isShowingDiscardConfirmation = true
        } else {
            dismissAfterSubmit()
        }
    }

    private func discardAndDismiss() {
        resetReport()
        dismissAfterSubmit()
    }

    private func dismissAfterSubmit() {
        externalIsReportDirty = false
        if let onDismissRequested {
            onDismissRequested()
        } else {
            dismiss()
        }
    }

    private func resetReport() {
        selectedIssueType = nil
        affectedSite = ""
        details = ""
        contactEmail = ""
        includeDiagnostics = false
        currentStep = .topic
        furthestVisitedStep = .topic
        isShowingThankYou = false
        didCopySubmittedReportID = false
        viewModel.resetBugReportSendState()
        refreshDraft()
        syncReportDirtyState()
    }

    private func reportInputChanged() {
        viewModel.resetBugReportSendState()
        // Typing only changes the user-entered context; reuse the environment
        // snapshot captured on appear/step-change instead of rebuilding the
        // whole diagnostics bundle on every keystroke (UR-5: Feedback typing lag).
        refreshDraftContext()
        syncReportDirtyState()
    }

    private func submitReport() {
        refreshDraft()
        didCopySubmittedReportID = false
        Task {
            await viewModel.sendBugReport(context: currentContext)
            if case .sent = viewModel.bugReportSendState {
                isShowingThankYou = true
            }
        }
    }

    private var currentContext: BugReportContext {
        BugReportContext(
            issueType: selectedIssueType ?? .other,
            affectedSite: selectedIssueType == .websiteAccess ? affectedSite : "",
            details: details,
            contactEmail: contactEmail,
            includeDiagnostics: includeDiagnostics
        )
    }

    private func copySubmittedReportID() {
        guard !submittedReportID.isEmpty else {
            return
        }

        UIPasteboard.general.string = submittedReportID
        ProtectionHapticFeedback.play(.selectionConfirmed)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            didCopySubmittedReportID = UIPasteboard.general.string == submittedReportID
        }
    }

    /// True while the sheet's content must be hidden behind the in-sheet lock
    /// mask: when App Unlock is pending (locked device) OR the app-switcher
    /// privacy mask is up (`.inactive`, before `.background` flips the lock).
    /// Keying on the privacy-mask flag too closes the app-switcher-snapshot gap —
    /// the bug-report sheet presents above RootView's privacy/lock overlays, so
    /// those don't cover it and this view must mask itself.
    private var isAppUnlockMaskVisible: Bool {
        security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible
    }

    private var isReportDirty: Bool {
        guard !isShowingThankYou else {
            return false
        }

        return selectedIssueType != nil
            || !affectedSite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !contactEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || includeDiagnostics
    }

    private var canContinueFromContext: Bool {
        selectedIssueType != nil
            && !normalizedDetails.isEmpty
            && (selectedIssueType != .websiteAccess || !normalizedAffectedSite.isEmpty)
    }

    // Route through the same BugReportContext normalization used by makeRequestBody so the
    // review screen and the continue/submit validation reflect exactly what will be sent —
    // including the sanitization that strips zero-width / control / bidi characters. Trimming
    // alone would let an all-zero-width "Details" look non-empty here yet submit empty (UR-29).
    private var normalizedAffectedSite: String {
        currentContext.normalizedAffectedSite
    }

    private var normalizedDetails: String {
        currentContext.normalizedDetails
    }

    private var normalizedContactEmail: String {
        currentContext.normalizedContactEmail ?? ""
    }

    private var diagnosticPreviewSections: [BugReportPreviewSection] {
        viewModel.bugReportDraft?.previewSections.filter { $0.id != "context" } ?? []
    }

    private var thankYouTitle: String {
        if normalizedContactEmail.isEmpty {
            return "Thank you, Lava will look into this"
        }

        return "Thank you, Lava will look into this and reach out if needed"
    }

    private var submittedReportID: String {
        if case .sent(let reportID) = viewModel.bugReportSendState {
            return reportID
        }

        return ""
    }

    private var submitButtonTitle: String {
        switch viewModel.bugReportSendState {
        case .failed:
            "Retry"
        case .sending:
            "Submitting"
        case .idle, .sent:
            "Submit"
        }
    }

    private func refreshDraft() {
        viewModel.prepareBugReport(context: currentContext)
    }

    private func refreshDraftContext() {
        viewModel.refreshBugReportDraftContext(context: currentContext)
    }

    private func syncReportDirtyState() {
        externalIsReportDirty = isReportDirty
    }
}

private struct FeedbackThankYouMascot: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var mascotState: GuardianMascotState = .awake

    var body: some View {
        SoftShieldGuardian(size: 96, state: mascotState, shieldStyle: viewModel.lavaGuardLook)
            .task {
                mascotState = .awake
                try? await Task.sleep(nanoseconds: 550_000_000)
                guard !Task.isCancelled else { return }
                mascotState = .grateful
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                mascotState = .awake
            }
    }
}

/// Opaque, hit-blocking cover for the bug-report sheet while App Unlock is
/// pending. The sheet stays mounted (so an in-progress draft survives), and this
/// mask hides its content above the lock overlay. It uses an OPAQUE fill (never
/// translucent `.regularMaterial`) so the draft can't bleed through, swallows all
/// taps/scroll/keyboard hits via `contentShape`, and is an `.isModal`
/// accessibility container so VoiceOver can't reach the masked fields underneath.
///
/// It mirrors `SecurityLockOverlay` and carries its OWN "Unlock Lava" button:
/// the root lock overlay renders *behind* this window-level sheet and the sheet
/// can't be swiped away while the draft is dirty, so without an in-mask unlock
/// affordance a user who cancels the passcode prompt would be stuck (forced to
/// discard the draft). Tapping it re-surfaces the App Unlock prompt.
private struct BugReportSheetLockMask: View {
    let unlock: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(LavaStyle.groupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: LavaIconSize.hero, weight: .semibold))
                    .foregroundStyle(LavaStyle.safeGreen)

                Text("Lava Locked")
                    .font(.title.bold())

                Button("Unlock Lava", action: unlock)
                    .buttonStyle(.borderedProminent)
                    .tint(LavaStyle.safeControlGreen)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("bugReportSheetLockMask")
    }
}

private struct FeedbackSecondaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color(uiColor: .secondaryLabel))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity)
            .frame(height: LavaSurface.actionButtonHeight)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemFill))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemFill).opacity(configuration.isPressed ? 1 : 0))
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .opacity(isEnabled ? 1 : 0.55)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct BugReportTopicOptionRow: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(isSelected ? LavaStyle.safeGreen : LavaStyle.secondaryText)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            Text(title.lavaLocalized)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct BugReportReviewRow: View {
    let label: String
    let value: String

    var body: some View {
        // Reuse the editable screen's row scaffold (label stacked above the value) so the
        // review echo lines up pixel-for-pixel with "Tell us more", just read-only (UR-26).
        LavaTextInputRow(title: label) {
            Text(value)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct BugReportDiagnosticsInfoView: View {
    let sections: [BugReportPreviewSection]

    var body: some View {
        SettingsSubpageContent(
            title: "Information Sent",
            tier: .technical,
            intro: LavaInfoPanel(
                title: "Diagnostics",
                description: "These examples show the technical summary Lava can send when you turn on optional diagnostics",
                systemImage: "doc.text.magnifyingglass"
            )
        ) {
            LavaSectionGroup("Information sent") {
                if sections.isEmpty {
                    LavaPlainCard {
                        Text("Lava will show App & Device, VPN Status, Tunnel Lifecycle, Network & Resolver Health, Filter Snapshot, and Local Activity Summary when a local summary is ready.")
                            .lavaRowSubtitleText()
                    }
                } else {
                    VStack(spacing: 10) {
                        ForEach(sections) { section in
                            BugReportPreviewSectionCard(section: section)
                        }
                    }
                }
            }

            LavaSectionGroup(
                "Lifecycle log examples",
                footer: "Lifecycle entries use safe event names and counters. Recent DNS and domain events are not included."
            ) {
                LavaPlainCard {
                    VStack(alignment: .leading, spacing: 10) {
                        BugReportReviewRow(label: "App", value: "enable-begin, enable-finished, reconnect-requested")
                        Divider()
                        BugReportReviewRow(label: "Tunnel", value: "startTunnel-ready, network-path-changed, resolver-reset")
                        Divider()
                        BugReportReviewRow(label: "Details", value: "VPN status, network kind, resolver status, failure counters")
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BugReportStepProgressView: View {
    let currentStep: BugReportStep
    let furthestVisitedStep: BugReportStep
    let selectStep: (BugReportStep) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(BugReportStep.allCases) { step in
                if isUnavailableStep(step) {
                    stepLabel(for: step)
                } else {
                    Button {
                        selectStep(step)
                    } label: {
                        stepLabel(for: step)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func stepLabel(for step: BugReportStep) -> some View {
        Text("\(step.displayNumber) \(step.title.lavaLocalized)")
            // Current step also carries a heavier weight — a non-color cue so the active step
            // survives grayscale, not just the selection tint swap.
            .font(.caption.weight(step == currentStep ? .heavy : .semibold))
            .foregroundStyle(isUnavailableStep(step) ? LavaStyle.tertiaryText : Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .lavaSurface(.selection(isSelected: step == currentStep))
            .opacity(isUnavailableStep(step) ? 0.55 : 1)
            .contentShape(Rectangle())
            .accessibilityAddTraits(step == currentStep ? [.isSelected] : [])
    }

    private func isUnavailableStep(_ step: BugReportStep) -> Bool {
        step.rawValue > furthestVisitedStep.rawValue
    }
}

private struct BugReportPreviewSectionCard: View {
    let section: BugReportPreviewSection

    var body: some View {
        LavaPlainCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.title.lavaLocalized)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(section.purpose.lavaLocalized)
                        .lavaRowSubtitleText()
                }

                Divider()

                VStack(spacing: 8) {
                    ForEach(section.items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Text(item.label.lavaLocalized)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(LavaStyle.secondaryText)
                                .frame(width: 110, alignment: .leading)

                            Text(item.value)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

private struct LegalNoticesView: View {
    var body: some View {
        SettingsSubpageContent(
            title: "Legal Notices",
            tier: .calm,
            intro: LavaInfoPanel(
                title: "Third-party notices",
                description: ThirdPartyLegalNotices.affiliationDisclaimer,
                systemImage: "doc.text"
            )
        ) {
            LegalNoticeSection(
                title: "DNS Resolvers",
                notices: ThirdPartyLegalNotices.dnsResolverNotices
            )

            LegalNoticeSection(
                title: "Sign-in Providers",
                notices: ThirdPartyLegalNotices.signInProviderNotices
            )

            LegalNoticeSection(
                title: "Blocklist Licenses",
                notices: ThirdPartyLegalNotices.blocklistNotices
            )

            LavaSectionGroup("Other Marks") {
                LavaPlainCard {
                    Text("All other trademarks and service marks are property of their respective owners.")
                        .lavaRowSubtitleText()
                }
            }
        }
    }
}

private struct LegalNoticeSection: View {
    let title: String
    let notices: [ThirdPartyLegalNotice]

    var body: some View {
        LavaSectionGroup(title) {
            LavaCondensedList {
                ForEach(Array(notices.enumerated()), id: \.element.id) { index, notice in
                    LegalNoticeCard(notice: notice)

                    if index < notices.count - 1 {
                        LavaCondensedDivider()
                    }
                }
            }
        }
    }
}

private struct LegalNoticeCard: View {
    let notice: ThirdPartyLegalNotice

    var body: some View {
        LavaCondensedListItem(
            title: notice.displayName,
            subtitle: notice.noticeText,
            metadata: metadataText,
            titleLineLimit: 2
        )
    }

    private var metadataText: String {
        var lines = [notice.plannedUse]

        if let sourceURL = notice.sourceURL {
            lines.append("Source: \(sourceURL.absoluteString)")
        }

        if let distributionModeDescription = notice.distributionModeDescription {
            lines.append("Use: \(distributionModeDescription)")
        }

        if let licenseTextURL = notice.licenseTextURL {
            lines.append("License: \(licenseTextURL.absoluteString)")
        }

        if let noticeURL = notice.noticeURL {
            lines.append("Notice: \(noticeURL.absoluteString)")
        }

        return lines.joined(separator: "\n")
    }
}

@MainActor
private enum VersionInfo {
    static let appVersion = infoValue("CFBundleShortVersionString")
    static let platformVersion = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    static let sourceRevision = infoValue("LavaSourceRevision", default: "")

    private static func infoValue(_ key: String, default fallback: String = "Unknown") -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? fallback
    }
}

#if DEBUG || LAVA_QA_TOOLS
private struct PhoneQASettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @AppStorage("hasSeenLavaOnboarding") private var hasSeenLavaOnboarding = false

    var body: some View {
        PhoneQAView(
            showWelcome: {
                hasSeenLavaOnboarding = false
            },
            showUserBugReport: {
                viewModel.rageShakeDestination = .bugReport
            }
        )
    }
}
#endif

private struct VersionNerdStatsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var isSamplingTunnelHealth = false

    var body: some View {
        SettingsSubpageContent(
            title: "Nerd Stats",
            tier: .technical,
            intro: LavaInfoPanel(
                title: "Lava's behind-the-scenes counters",
                description: "Local counts of how Lava handles your traffic. Nothing here shows the sites you visited, so look around freely.",
                systemImage: "info.circle"
            )
        ) {
            LavaSectionGroup("App") {
                LavaPlainCard {
                    VStack(spacing: 10) {
                        LabeledContent("Version", value: VersionInfo.appVersion)
                        Divider()
                        LabeledContent("Platform", value: VersionInfo.platformVersion)
                        if !VersionInfo.sourceRevision.isEmpty {
                            Divider()
                            LabeledContent("Source", value: VersionInfo.sourceRevision)
                        }
                    }
                }
            }

            LavaSectionGroup(
                "Tunnel Health",
                footer: "Local counts of how Lava reaches the internet — no site names. Tracks when requests worked, failed, retried, or briefly used your phone's settings."
            ) {
                LavaPlainCard {
                    VStack(spacing: 10) {
                        Button {
                            Task {
                                await refreshTunnelHealthSample()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if isSamplingTunnelHealth {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.subheadline.weight(.semibold))
                                }

                                Text((isSamplingTunnelHealth ? "Sampling" : "Refresh sample").lavaLocalized)
                                    .font(.subheadline.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderless)
                        .tint(LavaStyle.safeGreen)
                        .disabled(isSamplingTunnelHealth)

                        Divider()
                        LabeledContent("Network", value: viewModel.tunnelNetworkText)
                        Divider()
                        LabeledContent("Network path", value: viewModel.tunnelNetworkPathText)
                        Divider()
                        LabeledContent("Network changes", value: viewModel.tunnelNetworkChangeText)
                        Divider()
                        LabeledContent("Last network change", value: viewModel.tunnelLastNetworkChangeText)
                        Divider()
                        LabeledContent("Runtime resets", value: viewModel.tunnelResolverRuntimeResetText)
                        Divider()
                        LabeledContent("Last runtime reset", value: viewModel.tunnelLastResolverRuntimeResetText)
                        Divider()
                        LabeledContent("Last resolver", value: viewModel.tunnelHealth.lastResolverAddress ?? "None yet")
                        Divider()
                        LabeledContent("DoH protocol", value: viewModel.tunnelDoHProtocolText)
                        Divider()
                        LabeledContent("Upstream success", value: "\(viewModel.tunnelHealth.upstreamSuccessCount)")
                        Divider()
                        LabeledContent("Last success", value: viewModel.tunnelLastUpstreamSuccessText)
                        Divider()
                        LabeledContent("Upstream failures", value: "\(viewModel.tunnelHealth.upstreamFailureCount)")
                        Divider()
                        LabeledContent("Last failure time", value: viewModel.tunnelLastUpstreamFailureText)
                        Divider()
                        LabeledContent("Timeouts", value: "\(viewModel.tunnelHealth.upstreamTimeoutCount)")
                        Divider()
                        LabeledContent("TCP fallback", value: viewModel.tunnelTCPFallbackText)
                        Divider()
                        LabeledContent("DNS smoke probes", value: viewModel.tunnelDNSSmokeProbeText)
                        Divider()
                        LabeledContent("Device DNS fallback", value: viewModel.tunnelDeviceDNSFallbackText)
                        Divider()
                        LabeledContent("Cache hit rate", value: viewModel.tunnelCacheHitRateText)

                        if let lastFailure = viewModel.tunnelHealth.lastFailureReason {
                            Divider()
                            LabeledContent("Last failure", value: lastFailure)
                        }

                        Divider()
                        LabeledContent("Sampled", value: viewModel.tunnelHealthUpdatedText)
                    }
                    .lavaTierMetadata()
                }
            }
        }
        .task {
            await refreshTunnelHealthSample()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else {
                    return
                }

                await refreshTunnelHealthSample()
            }
        }
    }

    private func refreshTunnelHealthSample() async {
        guard !isSamplingTunnelHealth else {
            return
        }

        isSamplingTunnelHealth = true
        await viewModel.sampleTunnelHealth()
        isSamplingTunnelHealth = false
    }
}
