import BackgroundTasks
import Combine
import GoogleSignIn
import Darwin
import LavaSecKit
import SwiftUI
import UIKit
@preconcurrency import NetworkExtension
@preconcurrency import UserNotifications

extension Notification.Name {
    static let lavaOpenGuardFromNotification = Notification.Name("com.lavasec.openGuardFromNotification")
    static let lavaOpenDeepLinkURL = Notification.Name("com.lavasec.openDeepLinkURL")
}

/// Daily background refresh of the filter lists (LAV-90 Phase 2). Registered at launch
/// and re-submitted whenever the app backgrounds. The handler runs the same catalog sync
/// as a manual refresh, but in `isBackgroundRefresh` mode: it re-reads the live on-disk
/// configuration, publishes ARTIFACTS ONLY through the pointer-swap substrate under a
/// degrade-ABORT publish lock + generation supersession check (so a concurrent foreground
/// save always wins); the CATALOG REFRESH itself never rewrites `configuration.json` and
/// never restores protection. Thanks to the snapshot-identity gate, a run that finds
/// nothing new is cheap and never reloads the tunnel. After the sync, the run drains a
/// pending Focus/Automation filter switch
/// (`FocusSwitchEnvironment.drainPendingFilterSwitchAfterBackgroundRefresh`) — and THAT
/// arm, unlike the refresh, MAY commit a filter switch: a warm commit through the shared
/// `HeadlessFocusFilterSwitchEngine` writes config+library (generation-fenced CAS, the
/// same cross-process writer every switch uses) and flips the artifact pointer, so a
/// `.deferred` automation switch applies without the user opening Lava.
///
/// Requires `Info.plist`: `UIBackgroundModes = [processing]` and
/// `BGTaskSchedulerPermittedIdentifiers = [com.lavasec.catalog-refresh]`.
/// Background *execution* — and the lock-free `mmap` read surviving a concurrent publish
/// + GC — can only be validated on a real device.
enum BackgroundCatalogRefresh {
    /// Fixed (not bundle-derived) so it matches the Info.plist literal exactly in both
    /// the App Store and dev/QA builds — no `$(PRODUCT_BUNDLE_IDENTIFIER)` substitution risk.
    static let taskIdentifier = "com.lavasec.catalog-refresh"

    /// App-group kill switch. The refresh is ON by default (founder 2026-07-16 — closed-app list
    /// freshness plus the pending-switch drain; previously an off-by-default opt-in): the publish
    /// path is fail-closed end to end (artifacts-only, degrade-ABORT lock, in-lock generation +
    /// pointer CAS, and the reader degrades to a cold rebuild or fail-closed — never wrong bytes),
    /// which bounds the risk of enabling ahead of the LAV-90 Phase-1 on-device gate. That
    /// rapid-publish-burst mmap validation REMAINS a release gate — run it before shipping a build
    /// with this on (lavasec-infra `plans/reviews/2026-07-16-background-catalog-refresh-
    /// reintroduction-review.md` §4/§7). The kill switch preserves the no-new-build off-switch QA
    /// relied on while this was an opt-in; setting it true disables scheduling and pending runs.
    /// NOTE for QA devices: the OLD key `backgroundCatalogRefreshEnabled` is dead — a device profile
    /// still setting it (either value) now silently gets the new default-ON behavior.
    /// pinned: BackgroundCatalogRefreshSourceTests.testKillSwitchCommentPairsReleaseGateWithDefaultOn
    static let killSwitchDefaultsKeyName = "backgroundCatalogRefreshDisabled"

    /// Must run before the app finishes launching (called from the app delegate). Always
    /// registers (iOS requires a handler for every permitted identifier); scheduling is
    /// gated separately by `scheduleNext()`.
    static func registerHandler() {
        // Run the launch handler on the main queue and box the non-Sendable BGTask so it
        // can cross into the main-actor `handle` (only ever touched on the main actor).
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
            let box = BGTaskBox(task)
            MainActor.assumeIsolated {
                handle(box.task)
            }
        }
    }

    /// Best-effort submit of the next run (~daily). Safe to call repeatedly. No-op when the
    /// kill switch is set (see `killSwitchDefaultsKeyName`).
    static func scheduleNext() {
        guard !LavaSecAppGroup.sharedDefaults.bool(forKey: killSwitchDefaultsKeyName) else { return }
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    private static func handle(_ task: BGTask) {
        scheduleNext() // always queue the next run, even if this one expires

        // Complete the BGTask exactly once — when the sync finishes, or up front when
        // the system expires the task — so iOS never records it as timed out (which
        // would throttle future catalog refreshes).
        let completion = BGTaskCompletion(task)

        let work = Task { @MainActor in
            // The kill switch is the safety off-switch for this background publisher.
            // `scheduleNext()` stops resubmitting once it is set, but iOS can still
            // deliver a request that was already pending when the flag flipped — so re-read
            // it here and do NO work (complete cleanly) if it was disabled after scheduling.
            guard !LavaSecAppGroup.sharedDefaults.bool(forKey: killSwitchDefaultsKeyName) else {
                completion.complete(success: true)
                return
            }

            // A headless view model is enough to run the catalog sync against the shared
            // container; the identity gate keeps it cheap. `headless: true` installs NO
            // side-effecting init work (Plus-store entitlement listener, temporary-protection
            // resume, live-activity observer) — all of which could write this model's stale
            // launch-time config — and `isBackgroundRefresh` makes the publish artifacts-only
            // + degrade-ABORT, so it never persists launch-time state over newer on-disk state.
            let viewModel = AppViewModel(loadVPNState: false, headless: true)
            await viewModel.syncCatalog(isBackgroundRefresh: true)
            // Drain a pending Focus/Automation switch AFTER the sync: the sync re-stamped the
            // catalog freshness (verified-unchanged) or committed + sidecar-warmed (published),
            // so warm reuse commits for the main pocket — an ALREADY-COMPILED target whose
            // catalog basis is unchanged — and the tunnel adopts it via its generation poll: a
            // deferred automation switch no longer waits for the next app open. HONEST COVERAGE
            // LIMIT: a never-compiled or disk-pressure-evicted target still re-defers here every
            // cycle (the sidecar warm pass runs only on published cycles, and this pass never
            // cold-compiles in the BGTask's budgeted window) and waits for the next foreground —
            // the drain plan's optional Phase 2 is that remainder's fix. Skipped when the BGTask
            // already expired — the marker is the correctness guarantee, not this best-effort pass.
            if !Task.isCancelled {
                await FocusSwitchEnvironment.drainPendingFilterSwitchAfterBackgroundRefresh()
            }
            completion.complete(success: !Task.isCancelled)
        }

        task.expirationHandler = {
            // Called on the registration queue (.main). Cancelling `work` propagates
            // through `syncCatalog` into the detached sync, and we finish the task
            // immediately so it never overruns the system deadline.
            MainActor.assumeIsolated {
                work.cancel()
                completion.complete(success: false)
            }
        }
    }
}

/// A cheap, frequent top-up that re-warms non-active filters from the catalog cache ALREADY HELD.
///
/// ## Why a second background task
///
/// A headless Focus or Shortcut switch is a pointer flip to a warm artifact, or it defers — the
/// engine never cold-compiles, because an App Intent gets seconds. So the switch is only as
/// reliable as the warm index is WHOLE, and ONE catalog refresh invalidates every entry at once
/// (each artifact is valid only against the basis it was compiled from).
///
/// Refilling the index afterwards is opportunistic, and the audit in `lavasec-infra`
/// `plans/2026-09-03-warm-index-coverage-plan.md` found why that is thin: the only background
/// window declared today is `BackgroundCatalogRefresh`, a `BGProcessingTask` asking for
/// `+12h` AND network connectivity, and its warm pass runs only on the `bg-published` outcome.
/// Field capture 2026-09-02: the catalog moved at 12:17, a switch fired at 20:30 with nothing warm
/// to flip to, and deferred correctly to a foreground the user reached hours later.
///
/// ## Why this one can be cheap
///
/// It does NO sync and needs NO network. Re-warming compiles from the cached catalog the device
/// already has, which is what makes a `BGAppRefreshTask` — short, frequent, opportunistic — the
/// right shape, where the refresh needs a long window because it fetches.
///
/// **The safety that makes a sync-free warm sound is already in `compileAndStageWarmArtifact`, not
/// in the caller.** It self-gates on a FRESH cached catalog, on catalog-only filters, on
/// non-active and non-frozen, and on no pending low-risk cache migration — staying read-only with
/// respect to the shared cache. That is why this task can skip the `bg-published` condition the
/// refresh's own warm pass carries: that condition exists because after a SYNC you cannot trust
/// `latest.json` unless the sync committed it. With no sync at all, `latest.json` is simply the
/// last committed catalog, and the freshness gate decides. A stale cache means no warming, which
/// is correct — the next switch takes the network-first cold path.
///
/// Requires `Info.plist`: `UIBackgroundModes` includes `fetch`, and
/// `BGTaskSchedulerPermittedIdentifiers` includes this identifier.
/// Background *execution* can only be validated on a real device.
enum BackgroundWarmTopUp {
    /// Fixed (not bundle-derived) so it matches the Info.plist literal exactly in both the App
    /// Store and dev/QA builds — no `$(PRODUCT_BUNDLE_IDENTIFIER)` substitution risk.
    static let taskIdentifier = "com.lavasec.warm-topup"

    /// App-group kill switch, mirroring `BackgroundCatalogRefresh`'s. ON by default: this task
    /// only ever COMPILES artifacts into the sidecar warm-index — it never syncs, never touches
    /// the catalog cache, and never writes the filter library or the artifact pointer — so the
    /// worst case of a bad run is wasted work, not wrong bytes. Setting it true disables
    /// scheduling and any run already pending.
    static let killSwitchDefaultsKeyName = "backgroundWarmTopUpDisabled"

    /// Must run before the app finishes launching; iOS requires a handler for every permitted
    /// identifier. Scheduling is gated separately by `scheduleNext()`.
    static func registerHandler() {
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
            let box = BGTaskBox(task)
            MainActor.assumeIsolated {
                handle(box.task)
            }
        }
    }

    /// Best-effort submit of the next run. Safe to call repeatedly.
    ///
    /// `earliestBeginDate` is a floor, not a schedule — iOS decides when an app-refresh task
    /// actually runs, from usage patterns and budget. Two hours asks for "materially more often
    /// than the 12-hour refresh" without pretending to a cadence the system does not offer.
    ///
    /// NO `requiresNetworkConnectivity`: this task compiles from the cache already on disk, and
    /// asking for connectivity would make it wait for a condition it does not need — which is the
    /// whole reason it can run when the refresh cannot.
    static func scheduleNext() {
        guard !LavaSecAppGroup.sharedDefaults.bool(forKey: killSwitchDefaultsKeyName) else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    private static func handle(_ task: BGTask) {
        scheduleNext() // always queue the next run, even if this one expires

        let completion = BGTaskCompletion(task)

        let work = Task { @MainActor in
            // Re-read the kill switch: iOS can deliver a request that was already pending when the
            // flag flipped, and `scheduleNext()` only stops future submissions.
            guard !LavaSecAppGroup.sharedDefaults.bool(forKey: killSwitchDefaultsKeyName) else {
                completion.complete(success: true)
                return
            }
            // `headless: true` for the same reason the catalog refresh uses it: no entitlement
            // listener, no temporary-protection resume, no live-activity observer — none of which
            // may write this short-lived model's launch-time state over newer on-disk state.
            let viewModel = AppViewModel(loadVPNState: false, headless: true)
            await viewModel.topUpWarmIndexFromCachedCatalog()
            // WARMING WITHOUT DRAINING LEAVES THE SWITCH STILL WAITING. A Focus or Shortcut switch
            // that deferred for a missing artifact leaves its marker in `PendingFilterSwitchStore`;
            // topping up makes the artifact exist but applies nothing, so the switch would keep
            // waiting for a foreground or the next processing task — while every diagnostic reports
            // health. The catalog refresh warms then drains for exactly this reason, and
            // `lavasec-infra`
            // `plans/2026-07-16-deferred-automation-switch-background-warm-and-apply-plan.md`
            // requires rerunning the shared switch engine after a warm pass (Codex review, PR #646).
            //
            // AFTER the top-up, not before: the drain is warm-only by design, so a target this run
            // just warmed is one it can now commit. Skipped when the BGTask already expired — the
            // marker survives to the next window, which is the designed fallback.
            if !Task.isCancelled {
                await FocusSwitchEnvironment.drainPendingFilterSwitchAfterBackgroundRefresh()
            }
            completion.complete(success: !Task.isCancelled)
        }

        task.expirationHandler = {
            // Delivered on the registration queue (.main). Cancelling propagates into the warm
            // pass, whose every app-group mutation sits behind a `!Task.isCancelled` gate, and we
            // finish immediately so iOS never records an overrun (which would throttle us).
            MainActor.assumeIsolated {
                work.cancel()
                completion.complete(success: false)
            }
        }
    }
}

private final class BGTaskBox: @unchecked Sendable {
    let task: BGTask
    init(_ task: BGTask) { self.task = task }
}

/// Boxes a `BGTask` (non-Sendable) and guarantees `setTaskCompleted` runs exactly
/// once across the work task and the expiration handler. `@unchecked Sendable`: the
/// task is only ever touched on the main actor.
private final class BGTaskCompletion: @unchecked Sendable {
    private let task: BGTask
    private var hasCompleted = false

    init(_ task: BGTask) { self.task = task }

    @MainActor
    func complete(success: Bool) {
        guard !hasCompleted else { return }
        hasCompleted = true
        task.setTaskCompleted(success: success)
    }
}

@MainActor
final class LavaPrivacyShield: NSObject {
    private let overlayTag = 0x4C415650
    private var overlays = [UIView]()
    private var coveredWindows = [(window: UIWindow, accessibilityWasHidden: Bool)]()

    override init() {
        super.init()
        // SwiftUI owns scenes. Application delegate activation alone is not the
        // lifetime of a scene's windows, especially around presented RN sheets.
        for name in [UIScene.didActivateNotification, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(activated), name: name, object: nil)
        }
    }

    @objc private func activated() { reconcileActive(in: UIApplication.shared) }

    func reconcileActive(in application: UIApplication) {
        guard application.applicationState == .active else { return }
        let security = LavaProtectionShortcutRuntime.shared.security
        #if LAVA_REACT_NATIVE
        let authenticating = security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible
        #else
        let authenticating = false // The non-RN lock is an overlay in the ordinary window.
        #endif
        if authenticating || !security.protectedDataIsAvailableForPresentation && security.backgroundPrivacyCoverRequired {
            // Keep the ordinary app windows covered while the dedicated lock
            // window owns authentication. Do not resign its passcode responder.
            show(in: application, resignFirstResponder: false)
        } else { hide(from: application) }
    }

    func show(in application: UIApplication, resignFirstResponder: Bool = true) {
        if resignFirstResponder {
            application.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        // RN modal controllers live in the normal app window. System keyboard
        // and authentication windows must remain interactive above this shield.
        for window in windows(in: application) where window.windowLevel == .normal
            && window.accessibilityIdentifier != "lava-security-window" {
            addShield(to: window)
        }
    }

    func hide(from application: UIApplication) {
        // Remove the exact views we installed, including windows no longer in
        // connectedScenes after a sheet/key-window transition.
        for overlay in overlays { overlay.removeFromSuperview() }
        overlays.removeAll()
        for covered in coveredWindows {
            covered.window.accessibilityElementsHidden = covered.accessibilityWasHidden
        }
        coveredWindows.removeAll()
        for window in windows(in: application) {
            window.viewWithTag(overlayTag)?.removeFromSuperview()
        }
    }

    private func addShield(to window: UIWindow) {
        if !coveredWindows.contains(where: { $0.window === window }) {
            coveredWindows.append((window, window.accessibilityElementsHidden))
        }
        // The dedicated security window owns accessibility while locked. A
        // second modal AX cover here can make its visible Retry unreachable.
        window.accessibilityElementsHidden = true
        if let existingOverlay = window.viewWithTag(overlayTag) {
            window.bringSubviewToFront(existingOverlay)
            return
        }

        let overlay = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        overlay.tag = overlayTag
        overlay.accessibilityIdentifier = "lavaPrivacyShield"
        overlay.frame = window.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isUserInteractionEnabled = true
        overlay.accessibilityElementsHidden = true
        overlays.append(overlay)

        let dimmingView = UIView(frame: overlay.bounds)
        dimmingView.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.64)
        dimmingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.contentView.addSubview(dimmingView)

        UIView.performWithoutAnimation {
            window.addSubview(overlay)
            window.bringSubviewToFront(overlay)
            window.layoutIfNeeded()
        }
    }

    private func windows(in application: UIApplication) -> [UIWindow] {
        application.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
    }
}

@MainActor
final class LavaNotificationDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private let privacyShield = LavaPrivacyShield()
    private var securityPresentationSubscription: AnyCancellable?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        #if LAVA_QA_TOOLS
        QAMetricKitCollector.start()
        #endif
        securityPresentationSubscription = LavaProtectionShortcutRuntime.shared.security.objectWillChange.sink { [weak self] _ in
            // Observe the completed controller transaction, not @Published's old value.
            Task { @MainActor [weak self] in self?.privacyShield.reconcileActive(in: application) }
        }
        UNUserNotificationCenter.current().delegate = self
        BackgroundCatalogRefresh.registerHandler()
        BackgroundWarmTopUp.registerHandler()
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Our own credential prompt is an interruption, not a background lock.
        // The real background/protected-data callbacks still cover immediately.
        guard !LavaProtectionShortcutRuntime.shared.security.isBiometricAuthenticationInProgress else { return }
        updatePrivacyShield(in: application)
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        updatePrivacyShield(in: application)
        BackgroundCatalogRefresh.scheduleNext()
        BackgroundWarmTopUp.scheduleNext()
    }

    private func updatePrivacyShield(in application: UIApplication) {
        // Read the live controller synchronously before iOS takes its snapshot.
        // Credential-only setup does not opt into covering the entire window.
        if LavaProtectionShortcutRuntime.shared.security.backgroundPrivacyCoverRequired {
            privacyShield.show(in: application)
        } else {
            privacyShield.hide(from: application)
        }
    }

    func applicationProtectedDataWillBecomeUnavailable(_ application: UIApplication) {
        // Revoke access before UIKit changes its bit. Selected or unknown security
        // conceals immediately; confirmed all-off keeps only its accepted display.
        LavaProtectionShortcutRuntime.shared.security.protectedDataWillBecomeUnavailable()
        updatePrivacyShield(in: application)
    }

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        LavaProtectionShortcutRuntime.shared.security.protectedDataDidBecomeAvailable()
        if application.applicationState == .active {
            updateActivePrivacyShield(in: application)
        } else {
            updatePrivacyShield(in: application)
        }
    }

    private func updateActivePrivacyShield(in application: UIApplication) {
        privacyShield.reconcileActive(in: application)
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // A force-quit from the app switcher of a still-running (just-visible) app can skip the scene
        // .background transition (the switcher peek is .inactive) but does deliver willTerminate —
        // clear the shared foreground flag here so closed-app switch banners aren't suppressed until
        // the next launch clear (LavaSecApp.init) or the poster's maxTrustedAge age-out. Best-effort:
        // a hard crash/jetsam delivers nothing, which is exactly what the age-out covers (Codex
        // review #361).
        // GUARDED on protected data (INV-PERSIST-2, Codex P2 on #385): the flag lives in the Class-C
        // shared-defaults suite, unwritable while locked — a termination that skips this write is
        // exactly what the poster's maxTrustedAge age-out already covers, and a still-visible app
        // being force-quit is unlocked anyway. Completes the "no Class-C suite write while locked"
        // discipline the scene-phase publish adopts.
        if UIApplication.shared.isProtectedDataAvailable {
            LavaAppForegroundPublication.publish(false, to: LavaSecAppGroup.sharedDefaults)
        }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        LavaProtectionShortcutRuntime.shared.security.sceneDidBecomeActive()
        updateActivePrivacyShield(in: application)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        guard Self.isLavaGuardNotification(notification.request.content.userInfo) else {
            completionHandler([])
            return
        }

        completionHandler([.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard Self.isLavaGuardNotification(response.notification.request.content.userInfo) else {
            completionHandler()
            return
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .lavaOpenGuardFromNotification, object: nil)
            completionHandler()
        }
    }

    private static func isLavaGuardNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[LavaSecAppGroup.protectionNotificationRouteUserInfoKeyName] as? String
            == LavaSecAppGroup.protectionNotificationGuardRouteValue
    }
}

#if DEBUG
/// Exercises a real passcode keyboard inset without changing the production Sudoku input path.
private struct SudokuKeyboardUITestControls: View {
    @State private var code = ""
    @State private var isFocused = false

    var body: some View {
        HStack {
            Button { isFocused = true } label: { Text(verbatim: "Show keyboard") }
                .accessibilityIdentifier("sudoku-test-show-keyboard")
            Button { isFocused = false } label: { Text(verbatim: "Hide keyboard") }
                .accessibilityIdentifier("sudoku-test-hide-keyboard")
        }
        .background {
            SecurityHiddenPasscodeField(code: $code, isFocused: $isFocused)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
    }
}
#endif

@main
struct LavaSecApp: App {
    @UIApplicationDelegateAdaptor(LavaNotificationDelegate.self) private var notificationDelegate

    init() {
        #if DEBUG && targetEnvironment(simulator)
        // Seed the real preference once for the isolated onboarding journey.
        // A -hasSeenLavaOnboarding NO launch argument would outrank subsequent
        // AppStorage writes and prevent the actual completion from dismissing.
        if ProcessInfo.processInfo.environment["LAVA_UI_TEST_REPLAY_ONBOARDING"] == "1" {
            UserDefaults.standard.set(false, forKey: "hasSeenLavaOnboarding")
        }
        #endif
        // Clear the shared "app is foregrounded" flag at process start. A previous app process that
        // died while VISIBLE — a crash, a watchdog/jetsam kill, or a force-quit from the app switcher
        // (killed from .inactive, so RootView's .background clear never ran) — leaves the flag stuck
        // TRUE, which suppresses every closed-app filter-switch banner. Process start is by definition
        // not scene-active (this also runs for a background App-Intent launch), so false is always
        // correct here; RootView re-asserts true when UI actually appears. Two companions close the
        // no-relaunch gap (Codex review #361): applicationWillTerminate clears on a force-quit that
        // skips .background, and the poster ages out an assert older than
        // LavaAppForegroundPublication.maxTrustedAge — a crashed app can't clear anything, and the
        // Focus EXTENSION (possibly the next process to run) must never clear the flag itself.
        // GUARDED on protected data (INV-PERSIST-2, Codex P2 on #385): the flag's Class-C shared
        // suite is unwritable while locked, and a pre-first-unlock prewarm / background App-Intent
        // launch cannot land this write anyway — the maxTrustedAge age-out clears a genuinely stuck
        // flag, so skipping the locked-suite write here loses nothing and completes the discipline.
        if UIApplication.shared.isProtectedDataAvailable {
            LavaAppForegroundPublication.publish(false, to: LavaSecAppGroup.sharedDefaults)
        }
        // Register the protection and filter App Shortcuts at launch. Refreshing also keeps
        // the Switch Filter parameter aligned with the current library (Codex #325).
        // updateAppShortcutParameters re-reads the entity query, which loads the on-disk filter
        // library directly (no AppViewModel), so this is correct here in App.init before the model
        // finishes loading. The library-change refresh lives in AppViewModel.persistLibraryOnlyChange.
        LavaShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            LavaAppWindowRoot()
                .onOpenURL { url in
                    guard !GIDSignIn.sharedInstance.handle(url) else {
                        return
                    }

                    NotificationCenter.default.post(name: .lavaOpenDeepLinkURL, object: url)
                }
        }
    }
}

// The App graph is installed for background App Intent launches too. Keep the
// side-effecting model in the window's view graph so Get Status can run without it.
// Mutating shortcuts access the same lazy runtime only after existing authentication.
// pinned: ProtectionShortcutWiringSourceTests.testBackgroundAppGraphDoesNotOwnTheProtectionModel
private struct LavaAppWindowRoot: View {
    @StateObject private var viewModel = LavaProtectionShortcutRuntime.shared.viewModel
    @StateObject private var security = LavaProtectionShortcutRuntime.shared.security

    var body: some View { appRoot }

    @ViewBuilder
    private var appRoot: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-lava-sudoku-ui-test") {
            SudokuEasterEggView(initialPuzzleSeed: 648)
                .environmentObject(viewModel)
                // Explicit presentation preference makes dark-mode screenshot tests independent
                // of Simulator defaults; this launch route is compiled only in DEBUG builds.
                .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-lava-sudoku-dark-ui-test") ? .dark : .light)
                .overlay(alignment: .top) {
                    if ProcessInfo.processInfo.arguments.contains("-lava-sudoku-keyboard-ui-test") {
                        SudokuKeyboardUITestControls()
                    }
                }
        } else if ProcessInfo.processInfo.arguments.contains("-lava-mascot-demo") {
            MascotAnimationDemoView()
        } else {
            productionRoot
        }
        #else
        productionRoot
        #endif
    }

    private var productionRoot: some View {
        RootView()
            .environmentObject(viewModel)
            // Catalog sync single-flight/presentation is observed separately from the hub's
            // authoritative metadata and transaction state.
            .environmentObject(viewModel.catalog)
            .environmentObject(viewModel.filterDrafts)
            // The backup scope peeled from the hub (Phase D1): views observe it as its own
            // environment object; the hub creates it so the bridge is wired to live state.
            .environmentObject(viewModel.backup)
            // The LavaSecurity+ billing scope, peeled the same way (Phase D2).
            .environmentObject(viewModel.plus)
            // The account/sign-in scope, peeled the same way (Phase D3).
            .environmentObject(viewModel.account)
            // The diagnostics + bug-report/rage-shake scope, peeled the same way (Phase D4).
            .environmentObject(viewModel.reports)
            // The customization-preferences scope, peeled the same way (Phase D5).
            .environmentObject(viewModel.customization)
            .environmentObject(security)
            .overlay(alignment: .bottom) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains(AppViewModel.liveDNSSmokeTestLaunchArgument) {
                    LavaLiveDNSSmokeTestPanel()
                        .environmentObject(viewModel)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 18)
                }
                #else
                EmptyView()
                #endif
            }
    }
}

#if DEBUG
private enum LavaLiveDNSSmokeState: Equatable {
    case idle
    case running
    case passed(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            "Ready to run live DNS smoke."
        case .running:
            "Running live DNS smoke..."
        case .passed(let details):
            "Live DNS smoke passed: \(details)"
        case .failed(let details):
            "Live DNS smoke failed: \(details)"
        }
    }

    var markerIdentifier: String {
        switch self {
        case .idle:
            "lavaLiveDNSSmokeIdle"
        case .running:
            "lavaLiveDNSSmokeRunning"
        case .passed:
            "lavaLiveDNSSmokePassed"
        case .failed:
            "lavaLiveDNSSmokeFailed"
        }
    }
}

private struct LavaLiveDNSSmokeTestPanel: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var state: LavaLiveDNSSmokeState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(vpnStatusText)
                .font(.caption.weight(.semibold))
                .accessibilityIdentifier(isVPNConnected ? "lavaLiveDNSSmokeVPNConnected" : "lavaLiveDNSSmokeVPNStatus")

            Text(state.label)
                .font(.caption2.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("lavaLiveDNSSmokeStatus")

            Text(state.markerIdentifier)
                .font(.caption2)
                .accessibilityIdentifier(state.markerIdentifier)

            Button {
                runSmoke()
            } label: {
                Text("Run Live DNS Smoke")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isVPNConnected || state == .running)
            .accessibilityIdentifier("lavaLiveDNSSmokeRunButton")

            Button {
                viewModel.turnOffProtection()
            } label: {
                Text("Stop Live DNS Smoke Protection")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!isVPNConnected)
            .accessibilityIdentifier("lavaLiveDNSSmokeStopButton")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.orange.opacity(0.45), lineWidth: 1)
        )
    }

    private var isVPNConnected: Bool {
        viewModel.vpnStatus == .connected
    }

    private var vpnStatusText: String {
        switch viewModel.vpnStatus {
        case .connected:
            "Live DNS smoke VPN connected"
        case .connecting:
            "Live DNS smoke VPN connecting"
        case .reasserting:
            "Live DNS smoke VPN reconnecting"
        case .disconnecting:
            "Live DNS smoke VPN disconnecting"
        case .disconnected:
            "Live DNS smoke VPN disconnected"
        case .invalid:
            "Live DNS smoke VPN invalid"
        @unknown default:
            "Live DNS smoke VPN unknown"
        }
    }

    private func runSmoke() {
        guard state != .running else {
            return
        }

        state = .running
        Task {
            state = await LavaLiveDNSSmokeRunner.run()
        }
    }
}

private struct LavaLiveDNSLookupResult: Sendable {
    let domain: String
    let addresses: [String]
    let errorMessage: String?

    var displayText: String {
        if let errorMessage {
            return "\(domain) error=\(errorMessage)"
        }

        return "\(domain) addresses=\(addresses.joined(separator: ","))"
    }
}

private enum LavaLiveDNSSmokeRunner {
    static func run(probeSet: QADomainProbeSet = .hosted) async -> LavaLiveDNSSmokeState {
        let allowed = await resolveIPv4Addresses(for: probeSet.allowedDomain)
        guard allowed.errorMessage == nil,
              allowed.addresses.contains(where: { $0 != "0.0.0.0" })
        else {
            return .failed("allowed lookup did not return a usable address; \(allowed.displayText)")
        }

        let blocked = await resolveIPv4Addresses(for: probeSet.blockedDomain)
        guard blocked.errorMessage == nil,
              !blocked.addresses.isEmpty,
              blocked.addresses.allSatisfy({ $0 == "0.0.0.0" })
        else {
            return .failed("blocked lookup was not sinkholed; \(blocked.displayText)")
        }

        return .passed("allowed=\(allowed.addresses.joined(separator: ",")); blocked=\(blocked.addresses.joined(separator: ","))")
    }

    private static func resolveIPv4Addresses(for domain: String) async -> LavaLiveDNSLookupResult {
        await Task.detached(priority: .utility) {
            resolveIPv4AddressesSynchronously(for: domain)
        }.value
    }

    private static func resolveIPv4AddressesSynchronously(for domain: String) -> LavaLiveDNSLookupResult {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var info: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(domain, nil, &hints, &info)
        guard status == 0 else {
            return LavaLiveDNSLookupResult(
                domain: domain,
                addresses: [],
                errorMessage: String(cString: gai_strerror(status))
            )
        }

        defer {
            if let info {
                freeaddrinfo(info)
            }
        }

        var addresses = [String]()
        var cursor = info
        while let current = cursor {
            if current.pointee.ai_family == AF_INET,
               let socketAddress = current.pointee.ai_addr {
                let address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee
                }
                var ipv4Address = address.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let converted = withUnsafePointer(to: &ipv4Address) { pointer in
                    inet_ntop(AF_INET, UnsafeRawPointer(pointer), &buffer, socklen_t(INET_ADDRSTRLEN))
                }

                if converted != nil {
                    let addressBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    if let address = String(bytes: addressBytes, encoding: .utf8) {
                        addresses.append(address)
                    }
                }
            }

            cursor = current.pointee.ai_next
        }

        return LavaLiveDNSLookupResult(
            domain: domain,
            addresses: Array(Set(addresses)).sorted(),
            errorMessage: nil
        )
    }
}
#endif
