import SwiftUI
import LavaSecCore
import UIKit

enum LavaRootTab: Hashable {
    case guardPanel
    case settings

    var securityPolicy: SecurityAccessPolicy {
        switch self {
        case .guardPanel:
            return .readOnly
        case .settings:
            return .requires(.appSettings)
        }
    }

    var title: String {
        switch self {
        case .guardPanel:
            return "Guard"
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
    @State private var guardNavigationPath = [GuardDestination]()
    @State private var rootTabScrollToTopRequests = [LavaRootTab: Int]()
    @State private var importDeepLinkPresentation: ImportDeepLinkPresentation?

    #if DEBUG
    private static let debugRageShakeLaunchArgument = "-lava-trigger-rage-shake"
    #endif

    var body: some View {
        TabView(selection: guardedRootTabSelection) {
            GuardView(
                navigationPath: $guardNavigationPath,
                scrollToTopTrigger: scrollToTopTrigger(for: .guardPanel)
            )
                .tabItem {
                    // Fill on select (outline when not) so the active tab reads without relying on
                    // tint — a Differentiate Without Color cue. VoiceOver selection is already
                    // conveyed by the native tab bar.
                    Label("Guard", systemImage: LavaIconRole.guardShield.tabBarSymbolName(isSelected: selectedRootTab == .guardPanel))
                }
                .tag(LavaRootTab.guardPanel)

            SettingsView(path: $settingsPath, scrollToTopTrigger: scrollToTopTrigger(for: .settings))
                .tabItem {
                    Label("Settings", systemImage: LavaIconRole.settings.tabBarSymbolName(isSelected: selectedRootTab == .settings))
                }
                .tag(LavaRootTab.settings)
        }
        .tint(LavaStyle.safeGreen)
        .background(LavaStyle.groupedBackground)
        .preferredColorScheme(viewModel.preferredColorScheme)
        // Customization → Text Size. Nil when "Match System" is on (the default), so the system's
        // Larger Text setting flows through untouched; a fixed size otherwise. Applied app-wide here
        // so every screen — including sheets/covers presented from it — inherits it.
        .lavaTextSizeOverride(viewModel.textSizeOverride)
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
        .lavaConfirmationAlert { host in
            host.alert(
                "Send feedback?",
                isPresented: Binding(
                    get: { viewModel.pendingRageShakeConfirmation != nil && !security.isAppUnlockBlockingUI },
                    set: { isPresented in
                        // A real cancel only when the device is unlocked. While App
                        // Unlock is pending the `get` returns false to withhold the
                        // alert, and `.alert` writes that dismissal back through
                        // `set`; ignore the lock-driven dismissal so the pending
                        // confirmation re-surfaces on unlock (matching the sheet)
                        // instead of being silently discarded.
                        if !isPresented && !security.isAppUnlockBlockingUI {
                            viewModel.cancelRageShakeFeedback()
                        }
                    }
                )
            ) {
                Button("Send feedback") { viewModel.confirmRageShakeFeedback() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Looks like you shook your phone. Want to tell us what went wrong?")
            }
        }
        // The bug-report sheet stays MOUNTED across an App Unlock lock so an
        // in-progress feedback draft (BugReportSettingsView's local @State)
        // survives lock->unlock. It presents above the app-unlock overlay, so
        // `BugReportSettingsView` paints its OWN opaque, hit-blocking mask while
        // App Unlock is pending (and while the app-switcher privacy mask is up) —
        // see `isAppUnlockMaskVisible` there. Unlike the importer, withholding
        // (tearing down) here would lose an accumulating draft, so we mask in
        // place instead of withholding.
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
        .sheet(item: importDeepLinkSheetItem) { presentation in
            // The importer opened from a deeplink runs the *same* protected apply
            // gate as the in-app Filters entry point — fresh authentication on the
            // filter-editing surface — so a link can surface the importer but can
            // never apply a filter change without explicit confirm + auth. The
            // binding additionally withholds the sheet while App Unlock is
            // pending (see `importDeepLinkSheetItem`).
            ImportFiltersFlow(
                startMode: presentation.startMode,
                authorizeImport: {
                    await security.requireFreshAuthentication(for: .filterEditing, reason: "Import filter")
                }
            )
            .environmentObject(viewModel)
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
            LavaOnboardingView(
                hasSeenOnboarding: $hasSeenLavaOnboarding,
                onRequestOpenSettings: {
                    // Route through the auth-gated opener so passcode-protected
                    // Settings still require authentication.
                    openSettingsRoot()
                }
            )
        }
        .onAppear {
            handleDebugLaunchRageShakeIfNeeded()
            viewModel.reconcileLiveActivity()
            // Foreground launch starts at .active, but onChange(of:scenePhase) doesn't fire for the initial
            // value — apply any pending Focus switch + warm the non-active filters here too. Also publish the
            // lightweight foreground flag so the extension suppresses the (closed/backgrounded-only) Focus-
            // switch notification while the app is visible (a banner would be redundant with the in-UI change).
            viewModel.setAppForegroundActive(true)
            viewModel.warmNonActiveFiltersOnAppForeground()
            Task { await viewModel.reconcilePendingFilterSwitch() }
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
                viewModel.setAppForegroundActive(true)
                viewModel.warmNonActiveFiltersOnAppForeground()
                viewModel.reconcileTemporaryProtectionPause()
                viewModel.reconcileLiveActivity()
                Task {
                    await viewModel.refreshProtectionStatus(force: true)
                    await viewModel.reconcilePendingFilterSwitch()
                    await security.authenticateAppUnlockIfNeeded()
                }
            case .inactive:
                security.showAppUnlockPrivacyMaskIfNeeded()
            case .background:
                security.lockForBackgroundIfNeeded()
                // Clear the foreground flag so a Focus switch while suspended/closed posts its notification
                // (the only signal then). Cleared on .background, not transient .inactive (notification
                // center / app switcher peeks), so an in-app peek doesn't flip it.
                viewModel.setAppForegroundActive(false)
            @unknown default:
                security.resetForegroundSession()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lavaOpenGuardFromNotification)) { _ in
            hasSeenLavaOnboarding = true
            viewModel.dismissRageShakeDestination()
            settingsPath = []
            guardNavigationPath = []
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

            // Switch synchronously when the tab needs no auth gate (Guard is
            // .readOnly). Routing every switch through an async Task makes the
            // TabView selection lag the tap by a frame — the tapped tab flashes
            // in, snaps back to the old tab, then settles — which is the
            // Upgrade↔Guard flicker. Only auth-gated tabs (Settings) need the
            // async authentication round-trip.
            if nextTab.securityPolicy.requiredSurface == nil {
                selectedRootTab = nextTab
                return
            }

            Task {
                await selectRootTab(nextTab)
            }
        }
    }

    private func selectRootTab(_ tab: LavaRootTab) async {
        guard await canAccess(tab.securityPolicy, reason: "Open %@".lavaLocalizedFormat(tab.title.lavaLocalized)) else {
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
            guardNavigationPath = []
            selectedRootTab = .guardPanel
        case .filters:
            settingsPath = []
            guardNavigationPath = [.filters]
            selectedRootTab = .guardPanel
        case .activity:
            settingsPath = []
            guardNavigationPath = [.activity]
            selectedRootTab = .guardPanel
        case .settings(let settingsRoute):
            guard let settingsRoute else {
                openSettingsRoot()
                return
            }

            // Feedback presents as a bottom sheet (the same surface as the in-app
            // Settings row and the rage-shake gesture), not a pushed settings page.
            // The bug-report sheet previews diagnostic context and can submit a
            // report, so it must never reveal content above the app-unlock overlay:
            // BugReportSettingsView masks its own content (opaque, hit-blocking)
            // while App Unlock is pending, so a `lavasecurity://settings/feedback`
            // link arriving on a locked device opens the sheet masked. Kick the
            // unlock prompt here so the mask drops once the device is unlocked.
            if case .feedback = settingsRoute {
                settingsPath = []
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    viewModel.rageShakeDestination = .bugReport
                }
                Task { await security.authenticateAppUnlockIfNeeded() }
                return
            }

            guard let route = SettingsRoute(settingsRoute) else {
                return
            }

            openSettingsRoute(route)
        case .importFilters(let entry):
            // Stage the importer over a clean Guard root. This only *records* the
            // request — it never calls an apply/mutation. The filter code is
            // supplied in-app (scan/paste/type) and the apply step inside the flow
            // is sanitized, reviewed, and auth-gated. `importDeepLinkSheetItem`
            // holds the sheet back until App Unlock is satisfied, so a locked
            // device can't reach the importer above the lock overlay; kick the
            // unlock prompt here in case the link arrived while locked.
            settingsPath = []
            guardNavigationPath = []
            selectedRootTab = .guardPanel
            importDeepLinkPresentation = ImportDeepLinkPresentation(
                startMode: Self.importStartMode(for: entry)
            )
            Task { await security.authenticateAppUnlockIfNeeded() }
        }
    }

    /// Gates the deeplink importer sheet on App Unlock. The sheet presents *above*
    /// the app-unlock overlay, so without this a `lavasecurity://import` link
    /// could surface the importer on a locked device — and because importing
    /// *replaces* the block-side config (an empty import clears every list), that
    /// would be a hot-path change reachable without unlocking. While App Unlock is
    /// pending — or the app-switcher privacy mask is up (`.inactive`, before
    /// `.background` flips the lock), which keeps the importer/scanner out of the
    /// app-switcher snapshot — the binding reads `nil` (no sheet); once clear it
    /// surfaces the staged request. The apply step inside the flow still runs its
    /// own filter-editing fresh-auth gate.
    private var importDeepLinkSheetItem: Binding<ImportDeepLinkPresentation?> {
        Binding {
            (security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible) ? nil : importDeepLinkPresentation
        } set: { newValue in
            if newValue == nil {
                importDeepLinkPresentation = nil
            }
        }
    }

    private static func importStartMode(for entry: LavaImportDeepLinkEntry) -> ImportFiltersStartMode {
        switch entry {
        case .chooser:
            return .chooseMethod
        case .scan:
            return .scanCode
        case .enterCode:
            return .enterCode
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

private extension View {
    /// Forces an app-wide Dynamic Type size when the Customization → Text Size control is set to a
    /// fixed size; passes through untouched (letting the system's Larger Text setting flow) when
    /// "Match System" is on and `size` is nil.
    ///
    /// Applies `dynamicTypeSize` UNCONDITIONALLY so toggling Match System changes only the range
    /// *value*, never this view's structural identity. The earlier version branched — forcing the size
    /// in one arm and passing `self` through in the other — which built a `_ConditionalContent`:
    /// flipping Match System swapped the branch, and SwiftUI treats that as a different view, tearing
    /// down the entire tree below this modifier — including the Settings `NavigationStack` — and
    /// bouncing the user back to the Settings root mid-toggle. A fixed size clamps to the degenerate
    /// `size...size` range (forcing exactly that size); Match System clamps to the full
    /// `.xSmall ... .accessibility5` span, an inert pass-through that lets the system's Larger Text
    /// setting flow unchanged.
    func lavaTextSizeOverride(_ size: DynamicTypeSize?) -> some View {
        let range = size.map { $0 ... $0 } ?? (DynamicTypeSize.xSmall ... DynamicTypeSize.accessibility5)
        return dynamicTypeSize(range)
    }
}

/// Identifies one deeplink-driven presentation of the importer. A fresh `id`
/// per request lets the same entry re-present the sheet if tapped again.
private struct ImportDeepLinkPresentation: Identifiable {
    let id = UUID()
    let startMode: ImportFiltersStartMode
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
