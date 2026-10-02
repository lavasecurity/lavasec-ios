import AppIntents
import Foundation
import LavaSecKit
import UIKit
@preconcurrency import NetworkExtension

struct ConnectLavaIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Connect"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = try? await LavaProtectionStatusReader.loadManager()
        let needsSetup = manager == nil || manager?.connection.status == .invalid
        if (LavaProtectionShortcutRuntime.requiresForeground || needsSetup),
           UIApplication.shared.applicationState != .active {
            try await requestToContinueInForeground()
        }
        let message = try await LavaProtectionShortcutRuntime.shared.perform(enabled: true)
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct DisconnectLavaIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Disconnect"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if LavaProtectionShortcutRuntime.requiresForeground,
           UIApplication.shared.applicationState != .active {
            try await requestToContinueInForeground()
        }
        let message = try await LavaProtectionShortcutRuntime.shared.perform(enabled: false)
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct GetLavaStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Status"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        // No runtime/view-model access: their initialization and status refresh own
        // lifecycle reconciliation. This reader only queries the installed provider.
        let status = await LavaProtectionStatusReader.read()
        let title = status.title.lavaLocalized
        var message = title
        if case .paused(let until) = status {
            message = "%@. %@".lavaLocalizedFormat(message, "Lava will try to resume at %@".lavaLocalizedFormat(
                until.formatted(date: .omitted, time: .shortened)))
        } else if case .connected(let severity) = status,
                  severity.yieldsToUnconfirmedChainedForwarding,
                  let name = LavaProtectionStatusReader.activeFilterName() {
            message = "%@. %@".lavaLocalizedFormat(message, "Filter: %@".lavaLocalizedFormat(name))
        }
        return .result(value: title, dialog: IntentDialog(stringLiteral: message))
    }
}

/// The app and mutating shortcuts share one model/action gate. Merely constructing the
/// runtime does not construct either model; Get Status never accesses this runtime.
@MainActor
final class LavaProtectionShortcutRuntime {
    static let shared = LavaProtectionShortcutRuntime()
    lazy var viewModel = AppViewModel(platformServices: .live())
    lazy var security = SecurityController()

    static var requiresForeground: Bool {
        !UserDefaults.standard.bool(forKey: "hasSeenLavaOnboarding") ||
            [SecurityProtectedSurface.appUnlock, .protectionControl].contains { surface in
                SecurityProtectedSurfaceStorage.isProtected(surface,
                    defaults: LavaSecAppGroup.sharedDefaults,
                    projectionURL: LavaSecAppGroup.securityGateProjectionURL)
            }
    }

    func perform(enabled: Bool) async throws -> String {
        guard UIApplication.shared.isProtectedDataAvailable else {
            throw LavaShortcutFailure("Open Lava to authenticate.")
        }
        guard UserDefaults.standard.bool(forKey: "hasSeenLavaOnboarding") else {
            throw LavaShortcutFailure("Open Lava to complete setup.")
        }
        // Authenticate before model initialization can schedule ordinary app lifecycle work.
        if Self.requiresForeground {
            guard UIApplication.shared.applicationState == .active,
                  await security.requireAuthentication(for: .appUnlock, reason: "Change Lava protection"),
                  await security.requireFreshAuthentication(for: .protectionControl, reason: "Change Lava protection")
            else { throw LavaShortcutFailure("Open Lava to authenticate.") }
        }
        try Task.checkCancellation()
        return try await viewModel.performProtectionShortcut(enabled: enabled)
    }
}

struct LavaShortcutFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    init(_ message: String) { self.message = message.lavaLocalized }
    var localizedStringResource: LocalizedStringResource { .init(stringLiteral: message) }
}

/// Reads current observations without creating a profile, flushing diagnostics, or
/// calling the app's side-effecting status-refresh/recovery machinery.
@MainActor
enum LavaProtectionStatusReader {
    static func read() async -> ProtectionStatus {
        guard UIApplication.shared.isProtectedDataAvailable else { return .unavailable }
        do {
            guard let manager = try await loadManager() else { return .notInstalled }
            let lifecycle = manager.connection.status.protectionLifecycleStatus
            guard lifecycle == .connected else {
                let armed = ProtectionLifecyclePolicy.isAwaitingOnDemandReconnect(
                    status: lifecycle, onDemandConfirmedEnabled: manager.isOnDemandEnabled)
                let terminalRefusal = armed && LavaSecAppGroup.chainedStartupFailureMarkerURL.map {
                    ChainedStartupFailureMarker.observation(from: $0,
                        lockURL: LavaSecAppGroup.chainedStartupFailureMarkerLockURL).terminalReason != nil
                } == true
                return .resolve(lifecycle: lifecycle, awaitingOnDemandReconnect: armed && !terminalRefusal)
            }
            guard let session = manager.connection as? NETunnelProviderSession,
                  let data = await query(session),
                  let evidence = try? JSONDecoder().decode(ProtectionStatusEvidence.self, from: data),
                  manager.connection.status == .connected
            else { return .unavailable }
            // The provider's fail-closed DNS-only fallback is no longer a chained tunnel.
            // Read the same durable failure marker as Guard before labeling it Protected.
            guard let markerURL = LavaSecAppGroup.chainedStartupFailureMarkerURL else {
                return .unavailable
            }
            let marker = ChainedStartupFailureMarker.observation(
                from: markerURL, lockURL: LavaSecAppGroup.chainedStartupFailureMarkerLockURL)
            guard marker != .unavailable, manager.connection.status == .connected else {
                return .unavailable
            }
            let chainedFailure: Bool
            if case .marked = marker {
                // A marker can outlive the user's chaining preference. The app's Guard
                // projection discloses it only while chaining is still requested.
                guard let configurationURL = LavaSecAppGroup.containerURL?.appendingPathComponent(
                    LavaSecAppGroup.configurationFilename),
                    case .loaded(let configuration) = SharedStateFileReader.read(
                        AppConfiguration.self, from: configurationURL)
                else { return .unavailable }
                chainedFailure = configuration.chainedUpstreamEnabled
            } else {
                chainedFailure = false
            }
            return evidence.status(now: Date(), chainedFailure: chainedFailure)
        } catch { return .unavailable }
    }

    static func loadManager() async throws -> NETunnelProviderManager? {
        let providerID = (Bundle.main.bundleIdentifier ?? "com.lavasec.app") + ".tunnel"
        let repository = NETunnelManagerRepository(providerBundleIdentifier: providerID,
            configurationName: "Lava Security")
        let controller = VPNLifecycleController(repository: repository,
            statusWaiter: ProtectionStatusChangeWaiter(), expectedProviderBundleIdentifier: providerID)
        return try await controller.loadExistingManager()
    }

    static func activeFilterName() -> String? {
        // App-unlock is also a privacy boundary for user-chosen filter names.
        guard !SecurityProtectedSurfaceStorage.isProtected(.appUnlock,
            defaults: LavaSecAppGroup.sharedDefaults,
            projectionURL: LavaSecAppGroup.securityGateProjectionURL),
              let url = LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.filterLibraryFilename),
              let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(FilterLibrary.self, from: data)
        else { return nil }
        return library.filters.first { $0.id == library.activeFilterID }?.name
    }

    static func query(_ session: NETunnelProviderSession, message: String = LavaSecAppGroup.readProtectionStatusMessage) async -> Data? {
        await withCheckedContinuation { continuation in
            let reply = Reply(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { reply.finish(nil) }
            do {
                try session.sendProviderMessage(Data(message.utf8)) {
                    reply.finish($0)
                }
            } catch { reply.finish(nil) }
        }
    }

    /// The provider callback, error, and deadline may race; only the first completes.
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data?, Never>?
        init(_ continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }
        func finish(_ data: Data?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: data)
        }
    }
}

extension ProtectionStatus {
    var title: String {
        switch self {
        case .off, .notInstalled: "Protection off"
        case .paused: "Paused"
        case .turningOn: "Turning On"
        case .establishing: "Checking VPN"
        case .turningOff: "Turning Off"
        case .reconnecting: "Waiting to reconnect"
        case .vpnRecovering: "Reconnecting VPN"
        case .vpnUnconfirmed: "VPN traffic unconfirmed"
        case .chainingFailed: "VPN forwarding stopped"
        case .tunnelReady: "Checking VPN"
        case .connected(let severity): ProtectionConnectivityPresentation.title(for: severity)
        case .unavailable: "Status unavailable"
        }
    }
}

// Resolve localized copy from the same semantic projection as the panel and control.
extension GuardStatusPresentation {
    var title: String {
        switch headline {
        case .status(let status): status.title
        case .needsAttention: "Needs attention"
        }
    }
}
