// The app runs through the RN workspace; the base project is a target manifest.
#if !LAVA_REACT_NATIVE
#error("Build ReactNative/native-app/LavaSecRN.xcworkspace after running prepare-full-app.sh.")
#endif

import SwiftUI
import LavaSecKit
import StoreKit
import UIKit

enum LavaRootTab: Hashable {
    case guardPanel
    case settings
}

enum GuardDestination: Hashable {
    case explore
    case filters
    case activity
}

struct RootView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    // The diagnostics + bug-report/rage-shake scope (Phase D4 peel).
    @EnvironmentObject private var reports: DiagnosticsController
    // The customization-preferences scope (Phase D5 peel): the app-wide appearance +
    // text-size overrides below read it, so only customization changes re-render here.
    @EnvironmentObject private var customization: CustomizationController
    @Environment(\.scenePhase) private var scenePhase
    // Native App Store review prompt. iOS decides whether to actually display it (throttled to
    // ~3/user/365 days) and gives no callback — so all eligibility lives upstream in ReviewPromptPolicy.
    @Environment(\.requestReview) private var requestReview
    @AppStorage("hasSeenLavaOnboarding") private var hasSeenLavaOnboarding = false
    @State private var didHandleDebugLaunchRageShake = false
    @State private var didRequestInitialAppUnlock = false
    @State private var selectedRootTab: LavaRootTab = .guardPanel
    @State private var settingsPath = [SettingsRoute]()
    @State private var guardNavigationPath = [GuardDestination]()
    @State private var importDeepLinkPresentation: ImportDeepLinkPresentation?
    /// Deliberately a bare Bool, not the payload. The configuration that triggered
    /// this notice is discarded at the guard, so there is nothing here to replay.
    @State private var isShowingFinishSetupBeforeImportNotice = false

    #if DEBUG
    private static let debugRageShakeLaunchArgument = "-lava-trigger-rage-shake"
    #endif

    var body: some View {
        rootPresentation
        .tint(LavaStyle.safeGreen)
        .background(LavaStyle.groupedBackground)
        .preferredColorScheme(customization.preferredColorScheme)
        // Customization → Text Size. Nil when "Match System" is on (the default), so the system's
        // Larger Text setting flows through untouched; a fixed size otherwise. Applied app-wide here
        // so every screen — including sheets/covers presented from it — inherits it.
        .lavaTextSizeOverride(customization.textSizeOverride)
        // A review anchor was earned: present the native prompt, but ONLY while the scene is active.
        // StoreKit needs a foreground-active scene to present from, and an eligible moment can be armed
        // from an async path (a filter apply or VPN connect finishing) after the user has left the app —
        // firing then silently drops the sheet yet would still spend the budget. So keep the flag armed
        // and let `presentReviewRequestIfActive` gate on scene phase; the scene-becomes-active case is
        // handled in the scenePhase onChange below. (Codex review #406.)
        // pinned: ReviewPromptWiringSourceTests.testRootViewForwardsTheSignalToNativeRequestReview
        .onChange(of: viewModel.pendingReviewRequest) { _, _ in
            presentReviewRequestIfActive()
        }
        .accessibilityHidden(!hasSeenLavaOnboarding)
        .allowsHitTesting(hasSeenLavaOnboarding)
        .overlay {
            if !hasSeenLavaOnboarding {
                LavaOnboardingView(hasSeenOnboarding: $hasSeenLavaOnboarding,
                    installDNSProfile: { try await LavaAppBridge.shared.updateManagedDNSPatch(create: true) },
                    supportsDNSProfile: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27)
            }
        }
        .overlay {
            RageShakeDetector {
                reports.handleRageShake()
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

        .lavaConfirmationAlert { host in
            host.alert(
                "Send feedback?",
                isPresented: Binding(
                    get: { reports.pendingRageShakeConfirmation != nil && !security.isAppUnlockBlockingUI },
                    set: { isPresented in
                        // A real cancel only when the device is unlocked. While App
                        // Unlock is pending the `get` returns false to withhold the
                        // alert, and `.alert` writes that dismissal back through
                        // `set`; ignore the lock-driven dismissal so the pending
                        // confirmation re-surfaces on unlock (matching the sheet)
                        // instead of being silently discarded.
                        if !isPresented && !security.isAppUnlockBlockingUI {
                            reports.cancelRageShakeFeedback()
                        }
                    }
                )
            ) {
                Button("Send feedback") { reports.confirmRageShakeFeedback() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Looks like you shook your device. Want to tell us what went wrong?")
            }
        }
        .alert(
            "Finish setup, then scan again".lavaLocalized,
            isPresented: $isShowingFinishSetupBeforeImportNotice
        ) {
            Button("OK".lavaLocalized, role: .cancel) {}
        } message: {
            Text("Lava protects this device first. Once setup is done, scan the same QR code again to review the shared filter.".lavaLocalized)
        }
        .onAppear {
            handleDebugLaunchRageShakeIfNeeded()
            viewModel.reconcileLiveActivity()
            // Foreground launch starts at .active, but onChange(of:scenePhase) doesn't fire for the initial
            // value — apply any pending Focus switch + warm the non-active filters here too. Also publish the
            // lightweight foreground flag so the headless posters (Focus extension + automation intent)
            // suppress their (closed/backgrounded-only) switch notifications while the app is visible
            // (a banner would be redundant with the in-UI change).
            viewModel.setAppForegroundActive(true)
            viewModel.warmNonActiveFiltersOnAppForeground()
            Task { await viewModel.reconcilePendingFilterSwitch() }
            // Same initial-.active gap for the review prompt: a request armed BEFORE this view installed
            // its observers (`onChange` fires on CHANGE, not the initial value; the scene-phase onChange
            // likewise skips the launch's initial .active) would otherwise wait for a background→foreground
            // round-trip. The guard inside no-ops unless a request is armed and the scene is active, so a
            // foreground launch that has one presents it immediately. (Codex review on lavasec-ios#69.)
            // pinned: ReviewPromptWiringSourceTests.testRootViewForwardsTheSignalToNativeRequestReview
            presentReviewRequestIfActive()
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
                // Present a review request that was armed while the app was not active (see the
                // pendingReviewRequest onChange above). pinned: ReviewPromptWiringSourceTests.testRootViewForwardsTheSignalToNativeRequestReview
                presentReviewRequestIfActive()
                Task {
                    await viewModel.refreshProtectionStatus(force: true)
                    await viewModel.reconcilePendingFilterSwitch()
                    await security.authenticateAppUnlockIfNeeded()
                }
            case .inactive:
                security.showAppUnlockPrivacyMaskIfNeeded()
            case .background:
                security.lockForBackgroundIfNeeded()
                // Clear the foreground flag so a Focus or automation switch while suspended/closed posts
                // its notification (the only signal then). Cleared on .background, not transient .inactive
                // (notification center / app switcher peeks), so an in-app peek doesn't flip it. The
                // crash/force-quit-while-visible path that never reaches .background is covered by the
                // process-start + willTerminate clears (LavaSecApp) and the poster's
                // LavaAppForegroundPublication.maxTrustedAge age-out (Codex review #361).
                viewModel.setAppForegroundActive(false)
            @unknown default:
                security.resetForegroundSession()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lavaOpenGuardFromNotification)) { _ in
            // Navigates only. Tapping a notification must not complete setup, for the
            // same reason a deeplink must not: setup is what gets protection running,
            // and nothing outside it may mark it done as a side effect. If onboarding
            // is still up, the overlay stays up and this navigation lands behind it.
            // pinned: SharedFilterImportSourceTests.testNoExternalEntryPointCompletesOnboarding
            dismissFeedbackForNavigation()
            settingsPath = []
            guardNavigationPath = []
            security.resetViewAuthenticationTurn()
            selectedRootTab = .guardPanel
            forwardReactNavigation()
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

    @ViewBuilder
    private var rootPresentation: some View {
        // UIKit owns keyboard avoidance inside the embedded app. SwiftUI must
        // not shrink the React Native tab controller when a descendant field focuses.
        LavaAppHost().ignoresSafeArea(.all, edges: .bottom)
            .statusBarHidden(false)
            .onAppear { forwardReactExternalFlows() }
            .onReceive(LavaAppBridge.shared.$flow) { flow in
                guard flow == nil else { return }
                // @Published emits before assignment. Defer until the current
                // dismissal also clears its original native request binding.
                Task { @MainActor in forwardReactExternalFlows() }
            }
            .onChange(of: importDeepLinkPresentation?.id) { _, _ in forwardReactImport() }
            .onChange(of: security.isAppUnlockBlockingUI) { _, _ in forwardReactImport() }
            .onChange(of: security.isAppUnlockPrivacyMaskVisible) { _, _ in forwardReactImport() }
            .onChange(of: reports.rageShakeDestination?.id) { _, _ in forwardReactRageShake() }
    }

    private func forwardReactExternalFlows() {
        forwardReactImport()
        forwardReactRageShake()
    }
    private func forwardReactImport() {
        guard let presentation = importDeepLinkSheetItem.wrappedValue else { return }
        guard LavaAppBridge.shared.flow == nil else { return }
        LavaAppBridge.shared.flow = LavaAppNativeFlow(name: "deepLinkImport", externalRequestID: presentation.id, importStartMode: presentation.startMode, importCompletion: presentation.completion, onDismiss: {
            if importDeepLinkPresentation?.id == presentation.id { importDeepLinkPresentation = nil }
        })
    }
    private func forwardReactRageShake() {
        guard let destination = reports.rageShakeDestination else { return }
        guard LavaAppBridge.shared.flow == nil else { return }
        let dismiss = { if reports.rageShakeDestination?.id == destination.id { reports.dismissRageShakeDestination() } }
        switch destination {
        case .bugReport: LavaAppBridge.shared.flow = LavaAppNativeFlow(name: "feedback", onDismiss: dismiss)
        #if DEBUG || LAVA_QA_TOOLS
        case .phoneQA: LavaAppBridge.shared.flow = LavaAppNativeFlow(name: "phoneQASheet", onDismiss: dismiss, showWelcome: {
            LavaAppBridge.shared.flow = nil
            reports.dismissRageShakeDestination()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { hasSeenLavaOnboarding = false }
        })
        #endif
        }
    }

    private func forwardReactNavigation() {
        if selectedRootTab == .guardPanel {
            let screen: String
            switch guardNavigationPath.last { case .explore: screen = "Explore"; case .filters: screen = "Filters"; case .activity: screen = "Activity"; case nil: screen = "Guard" }
            LavaAppBridge.shared.requestNavigation(tab: "GuardTab", screen: screen)
        } else {
            let screen: String
            switch settingsPath.last {
            case .account: screen = "Account"
            case .upgrade: screen = "Upgrade"
            case .customization: screen = "Customization"
            case .dnsResolver: screen = "DNS"
            case .privacyData: screen = "Privacy"
            case .security: screen = "Security"
            case .bugReport: screen = "Feedback"
            case .legalNotices: screen = "Legal"
            case .versionNerdStats: screen = "Stats"
            case .networkActivity: screen = "Network"
            #if DEBUG || LAVA_QA_TOOLS
            case .phoneQA: screen = "phoneQA"
            #endif
            case .vpnChaining: screen = "vpnChaining"
            case nil: screen = "Settings"
            }
            LavaAppBridge.shared.requestNavigation(tab: "SettingsTab", screen: screen)
        }
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
            forwardReactNavigation()
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
            forwardReactNavigation()
        }
    }

    private func dismissFeedbackForNavigation() {
        reports.dismissRageShakeDestination()
        // Native Feedback/QA sheets may also originate outside the rage-shake binding.
        // Pushed Settings pages are reset by their navigation stack, not this sheet path.
        if let name = LavaAppBridge.shared.flow?.name, name == "feedback" || name == "phoneQASheet" {
            LavaAppBridge.shared.flow = nil
        }
    }

    private func handleDeepLink(_ deepLink: LavaAppDeepLink) {
        // No deeplink may complete onboarding. Setup is what gets protection running
        // on the device in the first place, and it is the one flow a link must never
        // be able to skip, choose for the user, or mark done as a side effect —
        // including the non-import routes, which used to do exactly that from here.
        // pinned: SharedFilterImportSourceTests.testNoDeepLinkCanCompleteOnboarding
        dismissFeedbackForNavigation()
        security.resetViewAuthenticationTurn()

        switch deepLink {
        case .guardPanel:
            settingsPath = []
            guardNavigationPath = []
            selectedRootTab = .guardPanel
            forwardReactNavigation()
        case .explore:
            settingsPath = []
            guardNavigationPath = [.explore]
            selectedRootTab = .guardPanel
            forwardReactNavigation()
        case .filters:
            settingsPath = []
            guardNavigationPath = [.filters]
            selectedRootTab = .guardPanel
            forwardReactNavigation()
        case .activity:
            settingsPath = []
            guardNavigationPath = [.activity]
            selectedRootTab = .guardPanel
            forwardReactNavigation()
        case .settings(let settingsRoute):
            guard let settingsRoute else {
                openSettingsRoot()
                return
            }

            // Settings links use the same page routes as Settings rows. Feedback keeps
            // its own App Unlock mask and guarded Back; rage shake remains a separate sheet.
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
            // A payload-bearing link that arrives before setup is finished is
            // explained and DISCARDED — never stashed to replay afterwards. Holding
            // it would mean an untrusted configuration surviving across onboarding
            // and surfacing at a moment the user didn't ask for it. The same card
            // can simply be scanned again once setup is done.
            if case .sharedConfiguration = entry, !hasSeenLavaOnboarding {
                isShowingFinishSetupBeforeImportNotice = true
                return
            }
            settingsPath = []
            guardNavigationPath = []
            selectedRootTab = .guardPanel
            forwardReactNavigation()
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
            guard !(security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible) else { return }
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
        case .sharedConfiguration(let configuration):
            return .review(configuration)
        }
    }

    private func canAccess(_ policy: SecurityAccessPolicy, reason: String) async -> Bool {
        guard let surface = policy.requiredSurface else {
            return true
        }

        return await security.requireAuthentication(for: surface, reason: reason)
    }

    /// Issues the native review prompt when one is armed AND the scene is active, then records the
    /// budget spend and disarms. A no-op otherwise, leaving the flag armed for the next activation so a
    /// request armed off-screen is never dropped-yet-charged. (Codex review #406.)
    private func presentReviewRequestIfActive() {
        guard viewModel.pendingReviewRequest, scenePhase == .active else {
            return
        }
        requestReview()
        viewModel.markReviewRequestPresented()
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
        reports.handleRageShake()
        // The debug launch arg should land directly on the sheet, so bypass the
        // confirmation dialog the gesture normally shows.
        if let pending = reports.pendingRageShakeConfirmation {
            reports.pendingRageShakeConfirmation = nil
            reports.rageShakeDestination = pending
        }
        if let destination = reports.rageShakeDestination {
            print("LAVA_RAGE_SHAKE_DESTINATION \(destination.id)")
        }
        #endif
    }


}

extension View {
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
@MainActor
private struct ImportDeepLinkPresentation: Identifiable {
    let id = UUID()
    let startMode: ImportFiltersStartMode
    let completion = ImportFiltersCompletion()
}

private extension SettingsRoute {
    init?(_ deepLink: LavaSettingsDeepLink) {
        switch deepLink {
        case .account:
            self = .account
        case .upgrade:
            self = .upgrade
        case .customization:
            self = .customization
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
        case .networkActivity:
            self = .networkActivity
        }
    }
}

struct BugReportSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding private var isReportDirty: Bool

    init(isReportDirty: Binding<Bool> = .constant(false)) {
        self._isReportDirty = isReportDirty
    }

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
    let viewModel = AppViewModel(loadVPNState: false)
    RootView()
        .environmentObject(viewModel)
        .environmentObject(viewModel.catalog)
        .environmentObject(viewModel.filterDrafts)
}
