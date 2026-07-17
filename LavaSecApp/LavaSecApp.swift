import BackgroundTasks
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
final class LavaPrivacyShield {
    private let overlayTag = 0x4C415650

    func show(in application: UIApplication) {
        application.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        for window in windows(in: application) {
            addShield(to: window)
        }
    }

    func hide(from application: UIApplication) {
        for window in windows(in: application) {
            window.viewWithTag(overlayTag)?.removeFromSuperview()
        }
    }

    private func addShield(to window: UIWindow) {
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

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BackgroundCatalogRefresh.registerHandler()
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        privacyShield.show(in: application)
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        privacyShield.show(in: application)
        BackgroundCatalogRefresh.scheduleNext()
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
        privacyShield.hide(from: application)
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

@main
struct LavaSecApp: App {
    @UIApplicationDelegateAdaptor(LavaNotificationDelegate.self) private var notificationDelegate
    @StateObject private var viewModel = AppViewModel()
    @StateObject private var security = SecurityController()

    init() {
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
        // Register / refresh the "Switch Filter" App Shortcut at launch so a fresh install surfaces
        // it in Shortcuts & Siri and its filter parameter reflects the current library (Codex #325).
        // updateAppShortcutParameters re-reads the entity query, which loads the on-disk filter
        // library directly (no AppViewModel), so this is correct here in App.init before the model
        // finishes loading. The library-change refresh lives in AppViewModel.persistLibraryOnlyChange.
        LavaShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            appRoot
                .onOpenURL { url in
                    guard !GIDSignIn.sharedInstance.handle(url) else {
                        return
                    }

                    NotificationCenter.default.post(name: .lavaOpenDeepLinkURL, object: url)
                }
        }
    }

    @ViewBuilder
    private var appRoot: some View {
        #if DEBUG
        if WebsiteAssetCaptureConfiguration.isRequested {
            WebsiteAssetCaptureRootView(configuration: .current)
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
