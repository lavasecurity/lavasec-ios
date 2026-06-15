import SwiftUI
import LavaSecCore
import UIKit

enum LavaRootTab: Hashable {
    case guardPanel
    case filters
    case activity
    case settings

    var securityPolicy: SecurityAccessPolicy {
        switch self {
        case .guardPanel:
            return .readOnly
        case .filters:
            return .readOnly
        case .activity:
            return .requires(.activityViewing)
        case .settings:
            return .requires(.appSettings)
        }
    }

    var title: String {
        switch self {
        case .guardPanel:
            return "Guard"
        case .filters:
            return "Filters"
        case .activity:
            return "Activity"
        case .settings:
            return "Settings"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasSeenLavaOnboarding") private var hasSeenLavaOnboarding = false
    @State private var didHandleDebugLaunchRageShake = false
    @State private var didRequestInitialAppUnlock = false
    @State private var selectedRootTab: LavaRootTab = .guardPanel
    @State private var settingsPath = [SettingsRoute]()
    @State private var rootTabScrollToTopRequests = [LavaRootTab: Int]()

    #if DEBUG
    private static let debugRageShakeLaunchArgument = "-lava-trigger-rage-shake"
    #endif

    var body: some View {
        TabView(selection: guardedRootTabSelection) {
            GuardView(
                scrollToTopTrigger: scrollToTopTrigger(for: .guardPanel),
                openFilters: {
                    security.resetViewAuthenticationTurn()
                    selectedRootTab = .filters
                },
                openDNSResolver: {
                    openSettingsRoute(.dnsResolver)
                }
            )
                .tabItem {
                    Label("Guard", systemImage: LavaIconRole.guardShield.sfSymbolName)
                }
                .tag(LavaRootTab.guardPanel)

            FiltersView(scrollToTopTrigger: scrollToTopTrigger(for: .filters))
                .tabItem {
                    Label("Filters", systemImage: LavaIconRole.filters.sfSymbolName)
                }
                .tag(LavaRootTab.filters)

            ActivityView(scrollToTopTrigger: scrollToTopTrigger(for: .activity))
                .tabItem {
                    Label("Activity", systemImage: LavaIconRole.activity.sfSymbolName)
                }
                .tag(LavaRootTab.activity)

            SettingsView(path: $settingsPath, scrollToTopTrigger: scrollToTopTrigger(for: .settings))
                .tabItem {
                    Label("Settings", systemImage: LavaIconRole.settings.sfSymbolName)
                }
                .tag(LavaRootTab.settings)
        }
        .tint(LavaStyle.safeGreen)
        .background(LavaStyle.groupedBackground)
        .preferredColorScheme(viewModel.preferredColorScheme)
        .overlay {
            RageShakeDetector {
                viewModel.handleRageShake()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .overlay {
            if security.isAppUnlockBlockingUI && security.passcodeAuthenticationRequest == nil {
                SecurityLockOverlay {
                    Task {
                        await security.authenticateAppUnlockIfNeeded()
                    }
                }
            }
        }
        .overlay {
            if security.isAppUnlockPrivacyMaskVisible && !security.isAppUnlockBlockingUI {
                SecurityPrivacyMaskOverlay()
            }
        }
        .fullScreenCover(item: $security.passcodeAuthenticationRequest) { request in
            SecurityPasscodeAuthenticationView(request: request)
                .environmentObject(security)
        }
        .alert(
            "Send feedback?",
            isPresented: Binding(
                get: { viewModel.pendingRageShakeConfirmation != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.cancelRageShakeFeedback()
                    }
                }
            )
        ) {
            Button("Not now", role: .cancel) {
                viewModel.cancelRageShakeFeedback()
            }
            Button("Send feedback") {
                viewModel.confirmRageShakeFeedback()
            }
        } message: {
            Text("Looks like you shook your phone. Want to tell us what went wrong?")
        }
        .sheet(item: $viewModel.rageShakeDestination) { destination in
            switch destination {
#if DEBUG || LAVA_QA_TOOLS
            case .phoneQA:
                PhoneQASheetView(
                    showWelcome: {
                        viewModel.dismissRageShakeDestination()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            hasSeenLavaOnboarding = false
                        }
                    },
                    showUserBugReport: {
                        viewModel.dismissRageShakeDestination()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            viewModel.rageShakeDestination = .bugReport
                        }
                    }
                )
                    .onAppear {
                        debugLogRageShakeSheet("phoneQA")
                    }
#endif
            case .bugReport:
                BugReportSheetView()
                    .onAppear {
                        debugLogRageShakeSheet("bugReport")
                    }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { !hasSeenLavaOnboarding },
                set: { isPresented in
                    if !isPresented {
                        hasSeenLavaOnboarding = true
                    }
                }
            )
        ) {
            LavaOnboardingView(hasSeenOnboarding: $hasSeenLavaOnboarding)
        }
        .onAppear {
            handleDebugLaunchRageShakeIfNeeded()
            viewModel.reconcileLiveActivity()
            guard !didRequestInitialAppUnlock else {
                return
            }

            didRequestInitialAppUnlock = true
            Task {
                await security.authenticateAppUnlockIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                security.hideAppUnlockPrivacyMask()
                viewModel.reconcileTemporaryProtectionPause()
                viewModel.reconcileLiveActivity()
                Task {
                    await viewModel.refreshProtectionStatus(force: true)
                    await security.authenticateAppUnlockIfNeeded()
                }
            case .inactive:
                security.showAppUnlockPrivacyMaskIfNeeded()
            case .background:
                security.lockForBackgroundIfNeeded()
            @unknown default:
                security.resetForegroundSession()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lavaOpenGuardFromNotification)) { _ in
            hasSeenLavaOnboarding = true
            viewModel.dismissRageShakeDestination()
            settingsPath = []
            security.resetViewAuthenticationTurn()
            selectedRootTab = .guardPanel
        }
        .onReceive(NotificationCenter.default.publisher(for: .lavaOpenDeepLinkURL)) { notification in
            guard let url = notification.object as? URL else {
                return
            }

            if let deepLink = LavaAppDeepLink(url: url) {
                handleDeepLink(deepLink)
            }
        }
    }

    private var guardedRootTabSelection: Binding<LavaRootTab> {
        Binding {
            selectedRootTab
        } set: { nextTab in
            guard nextTab != selectedRootTab else {
                requestRootTabScrollToTop(nextTab)
                return
            }

            security.resetViewAuthenticationTurn()

            // Switch synchronously when the tab needs no auth gate (Guard/Filters
            // are .readOnly; Activity is intentionally ungated). Routing every
            // switch through an async Task makes the TabView selection lag the tap
            // by a frame — the tapped tab flashes in, snaps back to the old tab,
            // then settles — which is the Upgrade↔Guard flicker. Only auth-gated
            // tabs (Settings) need the async authentication round-trip.
            if nextTab == .activity || nextTab.securityPolicy.requiredSurface == nil {
                selectedRootTab = nextTab
                return
            }

            Task {
                await selectRootTab(nextTab)
            }
        }
    }

    private func selectRootTab(_ tab: LavaRootTab) async {
        guard await canAccess(tab.securityPolicy, reason: "Open \(tab.title)") else {
            return
        }

        selectedRootTab = tab
    }

    private func openSettingsRoute(_ route: SettingsRoute) {
        Task {
            security.resetViewAuthenticationTurn()

            guard await canAccess(SettingsRoute.settingsTabPolicy, reason: "Open Settings"),
                  await canAccess(route.securityPolicy, reason: route.securityReason)
            else {
                return
            }

            settingsPath = [route]
            selectedRootTab = .settings
        }
    }

    private func openSettingsRoot() {
        Task {
            security.resetViewAuthenticationTurn()

            guard await canAccess(SettingsRoute.settingsTabPolicy, reason: "Open Settings") else {
                return
            }

            settingsPath = []
            selectedRootTab = .settings
        }
    }

    private func handleDeepLink(_ deepLink: LavaAppDeepLink) {
        hasSeenLavaOnboarding = true
        viewModel.dismissRageShakeDestination()
        security.resetViewAuthenticationTurn()

        switch deepLink {
        case .guardPanel:
            settingsPath = []
            selectedRootTab = .guardPanel
        case .filters:
            settingsPath = []
            Task {
                await selectRootTab(.filters)
            }
        case .activity:
            settingsPath = []
            Task {
                await selectRootTab(.activity)
            }
        case .settings(let settingsRoute):
            guard let settingsRoute else {
                openSettingsRoot()
                return
            }

            guard let route = SettingsRoute(settingsRoute) else {
                return
            }

            openSettingsRoute(route)
        }
    }

    private func performLiveActivityActionRequest(_ request: LavaLiveActivityActionRequest) {
        Task {
            security.resetViewAuthenticationTurn()

            if request == .resume || request == .reconnect {
                viewModel.performLiveActivityActionRequest(request)
                viewModel.reconcileLiveActivity()
                return
            }

            guard await security.requireFreshAuthentication(
                for: .protectionPause,
                reason: request.authenticationReason
            ) else {
                return
            }

            viewModel.performLiveActivityActionRequest(request)
            viewModel.reconcileLiveActivity()
        }
    }

    private func canAccess(_ policy: SecurityAccessPolicy, reason: String) async -> Bool {
        guard let surface = policy.requiredSurface else {
            return true
        }

        return await security.requireAuthentication(for: surface, reason: reason)
    }

    private func requestRootTabScrollToTop(_ tab: LavaRootTab) {
        rootTabScrollToTopRequests[tab, default: 0] += 1
    }

    private func scrollToTopTrigger(for tab: LavaRootTab) -> Int {
        rootTabScrollToTopRequests[tab, default: 0]
    }

    private func handleDebugLaunchRageShakeIfNeeded() {
        #if DEBUG
        guard !didHandleDebugLaunchRageShake,
              ProcessInfo.processInfo.arguments.contains(Self.debugRageShakeLaunchArgument)
        else {
            return
        }

        didHandleDebugLaunchRageShake = true
        hasSeenLavaOnboarding = true
        viewModel.handleRageShake()
        // The debug launch arg should land directly on the sheet, so bypass the
        // confirmation dialog the gesture normally shows.
        if let pending = viewModel.pendingRageShakeConfirmation {
            viewModel.pendingRageShakeConfirmation = nil
            viewModel.rageShakeDestination = pending
        }
        if let destination = viewModel.rageShakeDestination {
            print("LAVA_RAGE_SHAKE_DESTINATION \(destination.id)")
        }
        #endif
    }

    private func debugLogRageShakeSheet(_ destination: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains(Self.debugRageShakeLaunchArgument) else {
            return
        }

        print("LAVA_RAGE_SHAKE_SHEET_VISIBLE \(destination)")
        #endif
    }
}

private extension SettingsRoute {
    init?(_ deepLink: LavaSettingsDeepLink) {
        switch deepLink {
        case .account:
            self = .account
        case .upgrade:
            self = .upgrade
        case .dnsResolver:
            self = .dnsResolver
        case .privacyData:
            self = .privacyData
        case .security:
            self = .security
        case .feedback:
            self = .bugReport
        case .legalNotices:
            self = .legalNotices
        case .nerdStats:
            self = .versionNerdStats
        }
    }
}

private struct BugReportSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isReportDirty = false

    var body: some View {
        NavigationStack {
            BugReportSettingsView(
                isReportDirty: $isReportDirty,
                onDismissRequested: canRequestDismiss
            )
        }
        .interactiveDismissDisabled(isReportDirty)
    }

    private func canRequestDismiss() {
        dismiss()
    }
}

#Preview {
    RootView()
        .environmentObject(AppViewModel(loadVPNState: false))
}
