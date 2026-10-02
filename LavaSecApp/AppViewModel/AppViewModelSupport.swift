import Darwin
import Foundation
import SwiftUI
import UIKit
@preconcurrency import CoreHaptics
@preconcurrency import NetworkExtension
@preconcurrency import UserNotifications
import LavaSecKit
import LavaSecFilterPipeline
import LavaSecAppServices

// MARK: - App view model support types

/// An explicit Guard start/reconnect could not advance the cross-process chained-retry marker.
///
/// The provider gates `startTunnel` on that same marker, so continuing would attempt a start that
/// is refused with certainty and leave the user looking at a recovery action that did nothing.
/// Both cases share one user-facing line — "try again" is the correct advice for either, and the
/// device debug log carries which one it was.
enum ChainedExplicitRetryPreparationFailure: LocalizedError {
    /// The App Group container could not be resolved, so the marker has no address.
    case markerUnavailable
    /// The marker file or its lock could not be replaced within the bounded wait.
    case markerAdvanceFailed

    /// Registered in `Localizable.xcstrings`; pinned by
    /// `LocalizationCatalogSourceTests.testChainedStartupFailureMessageCoversAllLocales`.
    static let message =
        "Lava could not clear the previous VPN chaining failure. Try again in a moment."

    var errorDescription: String? { Self.message.lavaLocalized }
}



// The private GuardianShieldStyle.lavaGuardID extension moved to
// CustomizationController.swift with its only callers (Phase D5 peel).

extension NEVPNStatus {
    var protectionLifecycleStatus: ProtectionLifecycleStatus {
        switch self {
        case .invalid:
            .invalid
        case .disconnected:
            .disconnected
        case .connecting:
            .connecting
        case .connected:
            .connected
        case .reasserting:
            .reasserting
        case .disconnecting:
            .disconnecting
        @unknown default:
            .invalid
        }
    }
}

// Internal (not `private`) since the Phase D4 peel: DiagnosticsController's
// persistDiagnostics / writeDiagnosticsClearControl throw the same
// `.appGroupUnavailable` their pre-peel hub bodies threw.
enum LavaSecAppError: LocalizedError {
    case appGroupUnavailable
    case vpnStillStopping
    // The launch load classified the shared config/library pair as existing-but-unreadable
    // (Data Protection before first unlock, INV-PERSIST-1); persisting the in-memory
    // placeholder would overwrite the user's intact files once they become writable.
    case sharedStateUnavailable

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "The shared App Group container is unavailable. Check the App Groups entitlement for the app and tunnel targets.".lavaLocalized
        case .vpnStillStopping:
            "iOS is still finishing turning off the local VPN. Wait a moment and try again.".lavaLocalized
        case .sharedStateUnavailable:
            "Your filters are still locked while the device finishes unlocking. Try again in a moment.".lavaLocalized
        }
    }
}

// NetworkExtension-backed conformances for VPNLifecycleController. Per the
// plan's architecture decisions, NE concrete types stay in the app target and
// the controller in LavaSecKit sees only these seams.
extension NETunnelProviderManager: @retroactive VPNManagerControlling {
    public var managerDisplayName: String? {
        localizedDescription
    }

    public var managerProviderBundleIdentifier: String? {
        (protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
    }

    public var lifecycleStatus: ProtectionLifecycleStatus {
        connection.status.protectionLifecycleStatus
    }
}

@MainActor
struct NETunnelManagerRepository: VPNManagerRepositoryProtocol {
    let providerBundleIdentifier: String
    let configurationName: String
    var dnsPatchEnabled: @MainActor () -> Bool = { false }
    var enforcesDNSRoutes: @MainActor () -> Bool = { false }
    var includesAllNetworks: @MainActor () -> Bool = { false }

    func loadAll() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NETunnelProviderManager], Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: managers ?? [])
            }
        }
    }

    func makeManager() -> NETunnelProviderManager {
        NETunnelProviderManager()
    }

    func applyConfiguration(to manager: NETunnelProviderManager) {
        let provider = NETunnelProviderProtocol()
        provider.providerBundleIdentifier = providerBundleIdentifier
        provider.serverAddress = "Lava Security Local DNS"
        provider.providerConfiguration = [
            "appGroupIdentifier": LavaSecAppGroup.identifier,
            "snapshotFilename": LavaSecAppGroup.snapshotFilename
        ]
        provider.providerConfiguration?["dnsPatchVersion"] = dnsPatchEnabled() ? 1 : 0
        provider.providerConfiguration?[DNSPatchProviderCatalog.providerConfigurationKey] =
            UserDefaults.standard.string(forKey: DNSPatchProviderCatalog.preferenceKey) ?? DNSPatchProviderCatalog.defaultID
        #if DEBUG || LAVA_QA_TOOLS
        if UserDefaults.standard.bool(forKey: "LavaQADNSOnlyDefaultRoutesEnabled") {
            provider.providerConfiguration?["qaDNSOnlyDefaultRoutes"] = true
        }
        if UserDefaults.standard.bool(forKey: "LavaQADNSOnlyIPv6Enabled") {
            provider.providerConfiguration?["qaDNSOnlyIPv6"] = true
        }
        let qaResolvers = UserDefaults.standard.stringArray(forKey: "LavaQACapturedDNSResolvers") ?? []
        if !qaResolvers.isEmpty { provider.providerConfiguration?["qaCapturedDNSResolvers"] = qaResolvers }
        if let mode = UserDefaults.standard.string(forKey: "LavaQADNSBlockAddressMode"),
           ["unspecified", "loopback", "nxdomain", "nodata", "cloudflare"].contains(mode) {
            provider.providerConfiguration?["qaDNSBlockAddressMode"] = mode
        }
        #endif
        // Resolver host routes alone do not capture connections scoped to cellular/Wi-Fi.
        // Persist enforcement on existing profiles too; the next start adopts this policy.
        provider.enforceRoutes = enforcesDNSRoutes()
        provider.includeAllNetworks = includesAllNetworks()
        // A local router can resolve public names. Do not exempt its DNS from enforced routes.
        provider.excludeLocalNetworks = false

        manager.localizedDescription = configurationName
        manager.protocolConfiguration = provider
        manager.isEnabled = true

        // NOTE: Connect-On-Demand is deliberately NOT enabled here. This method
        // is the shared install/enable path — it also runs when onboarding
        // merely *installs* the VPN profile (installLocalVPNProfileForOnboarding),
        // before the user has ever turned protection on. Enabling on-demand at
        // that point makes iOS connect the tunnel immediately on any traffic,
        // which on a fresh install surfaces as protection already "on" (filter
        // red) with a tunnel that isn't really running — and an un-turn-off-able
        // VPN that blocks all internet. The lifecycle reducer instead emits a tokened arm only after
        // the live manager reports connected, independent of the saved chained-mode preference.
    }

    func saveAndReload(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume()
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume()
            }
        }
    }

    func remove(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.removeFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume()
            }
        }
    }
}

extension AppViewModel {
    /// Reads only routing metadata; no WireGuard secret is needed to configure OS enforcement.
    var shouldEnforceDNSRoutes: Bool {
        var resolverCaptureOverride: Bool?
        #if DEBUG || LAVA_QA_TOOLS
        if !(UserDefaults.standard.stringArray(forKey: "LavaQACapturedDNSResolvers") ?? []).isEmpty
            || (UserDefaults.standard.bool(forKey: "LavaQADNSOnlyDefaultRoutesEnabled")
                && !configuration.chainedUpstreamEnabled) {
            switch UserDefaults.standard.string(forKey: "LavaQADNSRouteEnforcement") {
            case "on": resolverCaptureOverride = true
            case "off": resolverCaptureOverride = false
            default: break
            }
        }
        #endif
        if configuration.dnsPatchEnabled { resolverCaptureOverride = true }
        return DNSRouteEnforcementPolicy.shouldEnforce(
            chainedUpstreamEnabled: configuration.chainedUpstreamEnabled,
            routingPolicy: configuration.chainedUpstreamEnabled ? storedChainedRoutingPolicyForEnforcement : nil,
            resolverCaptureOverride: resolverCaptureOverride)
    }

    /// An opt-in device experiment, disabled in shipping builds. Recovery behavior remains
    /// a separate release gate; successful steady-state routing does not establish it.
    var shouldIncludeAllNetworksForQA: Bool {
        if configuration.dnsPatchEnabled { return false }
        #if DEBUG || LAVA_QA_TOOLS
        return DNSRouteEnforcementPolicy.shouldIncludeAllNetworks(
            requested: UserDefaults.standard.bool(forKey: "LavaQAFullTunnelLockdownEnabled"),
            chainedUpstreamEnabled: configuration.chainedUpstreamEnabled,
            routingPolicy: storedChainedRoutingPolicyForEnforcement)
        #else
        return false
        #endif
    }

    /// Reads only the public routing metadata, without loading the WireGuard private key.
    var storedChainedRoutingPolicyForEnforcement: ChainedRoutingPolicy? {
        guard let containerURL = LavaSecAppGroup.containerURL,
              let group = LavaSecAppGroup.chainedUpstreamKeychainAccessGroup else { return nil }
        let store = ChainedUpstreamKeychainStore(
            containerURL: containerURL,
            identity: LavaSecAppGroup.chainedUpstreamStoreIdentity,
            keyItems: ChainedUpstreamKeychainKeyItemStore(accessGroup: group))
        return (try? store.loadStoredConfigurationRecord()?.configuration.activeConfiguration)?.effectiveRoutingPolicy
    }
}

@MainActor
struct ProtectionStatusChangeWaiter: VPNStatusChangeWaiting {
    func waitForStatusChange(timeout: TimeInterval) async -> Bool {
        await ProtectionStopNotificationWaiter().wait(timeout: timeout)
    }
}

// The Focus-driven warm filter switch is driven by the App Intents EXTENSION (LavaSecIntents), whose
// `perform()` calls `FocusSwitchEnvironment.performSwitch` → the shared LavaSecFilterPipeline
// `HeadlessFocusFilterSwitchEngine`. perform() runs in the extension even while Lava is closed (WWDC22
// §10121). APP-PROCESS switch entries, exhaustively (audit this list when reasoning about who can flip
// the active filter): the foreground reconcile (`reconcilePendingFilterSwitch`), the manual
// `switchToFilter`, the Shortcuts/Siri `SwitchFilterIntent` (background-launched app, headless engine),
// the catalog-refresh BGTask's pending-switch drain (`BackgroundPendingSwitchDrain` via
// `FocusSwitchEnvironment.drainPendingFilterSwitchAfterBackgroundRefresh` — runs unattended with the
// app closed), and the non-active warm-keep helper (stages only, never flips).
