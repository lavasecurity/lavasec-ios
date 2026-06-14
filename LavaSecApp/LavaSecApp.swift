import GoogleSignIn
import Darwin
import LavaSecCore
import SwiftUI
import UIKit
@preconcurrency import NetworkExtension
@preconcurrency import UserNotifications

extension Notification.Name {
    static let lavaOpenGuardFromNotification = Notification.Name("com.lavasec.openGuardFromNotification")
    static let lavaOpenDeepLinkURL = Notification.Name("com.lavasec.openDeepLinkURL")
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
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        privacyShield.show(in: application)
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        privacyShield.show(in: application)
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
        userInfo[LavaSecAppGroup.protectionNotificationRouteUserInfoKey] as? String
            == LavaSecAppGroup.protectionNotificationGuardRouteValue
    }
}

@main
struct LavaSecApp: App {
    @UIApplicationDelegateAdaptor(LavaNotificationDelegate.self) private var notificationDelegate
    @StateObject private var viewModel = AppViewModel()
    @StateObject private var security = SecurityController()

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
