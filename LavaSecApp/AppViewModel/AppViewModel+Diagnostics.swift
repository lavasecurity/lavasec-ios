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

// One concern of `AppViewModel`, split out of the former single-file view model.
// Stored state (`@Published` and otherwise) lives in LavaSecApp/AppViewModel.swift (extensions
// cannot declare stored properties); every file under AppViewModel/ is one `// MARK:` section.

extension AppViewModel {
    // MARK: - Diagnostic context & event logging

    #if DEBUG || LAVA_QA_TOOLS
    func tunnelManagerDebugDetails(_ manager: NETunnelProviderManager?) -> [String: String] {
        guard let manager else {
            return ["manager": "nil"]
        }

        let provider = manager.protocolConfiguration as? NETunnelProviderProtocol
        return [
            "manager": "present",
            "localizedDescription": manager.localizedDescription ?? "nil",
            "isEnabled": "\(manager.isEnabled)",
            "connectionStatus": vpnStatusDebugDescription(manager.connection.status),
            "providerBundleIdentifier": provider?.providerBundleIdentifier ?? "nil",
            "serverAddress": provider?.serverAddress ?? "nil",
            "providerConfiguration": "\(provider?.providerConfiguration ?? [:])"
        ]
    }

    func errorDebugDetails(_ error: Error) -> [String: String] {
        let nsError = error as NSError
        return [
            "errorDescription": nsError.localizedDescription,
            "errorDomain": nsError.domain,
            "errorCode": "\(nsError.code)",
            "underlyingError": "\(nsError.userInfo[NSUnderlyingErrorKey] ?? "nil")"
        ]
    }

    #endif

    /// Error IDENTITY only — domain and code, never the message.
    ///
    /// Two reasons this exists rather than reusing `errorDebugDetails`, and both bit:
    ///
    /// 1. 🔴 BUILD. `errorDebugDetails` lives inside `#if DEBUG || LAVA_QA_TOOLS` (above). The
    ///    unconditional `launch-snapshot-reconcile-failed` breadcrumb calls it from an UN-gated
    ///    arm, so a Release DEVICE build does not compile — the trap this file already documents
    ///    a few lines up. Invisible to Debug and to the QA simulator lane; the Release
    ///    `generic/platform=iOS` lane is the one that goes red.
    /// 2. 🔴 PRIVACY. `localizedDescription` is not a fixed string.
    ///    `BlocklistCatalogSyncError.customBlocklistUnavailable` interpolates the source's
    ///    display name, and `CustomBlocklistSource` falls back to the HOST when unnamed — and
    ///    `errorDescription` is allowlisted into the bug-report bundle. A user's self-hosted
    ///    blocklist hostname would ship in every report. Domain+code carry the diagnosis this
    ///    breadcrumb needs without carrying a name the user did not agree to send.
    func errorIdentityDetails(_ error: Error) -> [String: String] {
        let nsError = error as NSError
        return [
            "errorDomain": nsError.domain,
            "errorCode": "\(nsError.code)",
        ]
    }

    /// Ship-safe app-side breadcrumb writer.
    ///
    /// DELIBERATELY OUTSIDE the debug-probe region above. It lived inside it until 2026-07-29,
    /// which broke the Release device compile the moment a caller outside that region used it —
    /// `chained-upstream-disabled` (pinned by
    /// `ChainedUpstreamReconcileSourceTests`) is exactly such a caller, and main's app-compile
    /// lane had been red since 2026-07-28 because of it. The other 44 call sites all sit inside
    /// build-flag regions, so nothing else exposed the gap.
    ///
    /// It belongs out here on its own merits, not merely to fix the build: it is a thin wrapper
    /// over `LavaSecDeviceDebugLog`, which is itself required to stay un-gated so Release builds
    /// emit the device log at all (pinned in `PacketTunnelDNSRuntimeSourceTests`). A logger that
    /// ships wrapped in a helper that does not is a contradiction waiting for a caller.
    /// pinned: AppViewModelSourceTests.testTheDebugEventWriterIsAvailableInEveryConfiguration
    func logVPNDebugEvent(_ event: String, details: [String: String] = [:]) {
        LavaSecDeviceDebugLog.append(component: "app", event: event, details: details)
    }

    /// QA-only telemetry for the Focus-driven headless switch + its foreground reconcile. The FUNCTION must
    /// live OUTSIDE the surrounding `#if DEBUG || LAVA_QA_TOOLS` probe block — it is called unconditionally
    /// from `reconcilePendingFilterSwitch` and the headless commit paths, so a Release/TestFlight build would
    /// fail to compile if the declaration were debug-only (Codex round-11 P1). Only its BODY is gated, under
    /// the same `focus-switch-intent` component as `LavaWarmSwitchService.log` so the whole feature (intent
    /// boundary, headless commit/rollback, reconcile apply) filters as one in device dumps.
    func logFocusSwitchEvent(_ event: String, details: [String: String] = [:]) {
        #if DEBUG || LAVA_QA_TOOLS
        LavaSecDeviceDebugLog.append(component: "focus-switch-intent", event: event, details: details)
        #endif
    }

    func vpnStatusDebugDescription(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid:
            "invalid"
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .connected:
            "connected"
        case .reasserting:
            "reasserting"
        case .disconnecting:
            "disconnecting"
        @unknown default:
            "unknown-\(status.rawValue)"
        }
    }

    func makeLatencyTrace(operationID: LatencyOperationID, operationKind: String) -> LatencyTrace {
        #if DEBUG || LAVA_QA_TOOLS
        return LatencyTrace(
            operationID: operationID,
            sink: LatencyDebugLogEventSink(operationKind: operationKind) { [weak self] event, details in
                self?.logVPNDebugEvent(event, details: details)
            }
        )
        #else
        return LatencyTrace(operationID: operationID)
        #endif
    }

    // The bug-report draft/send machinery (the prepared-inputs cache, submitBugReport
    // + its App Attest helpers, the debug-log reads, and the incident-ledger /
    // self-reconnect-gap observability reads with their clear-all wipes) moved to
    // DiagnosticsController.swift (Phase D4 diagnostics/bug-report peel). The hub keeps
    // only the wide-hub-state bundle ASSEMBLY — the DiagnosticsHubBridging conformance
    // in AppViewModel+HubBridges.swift.

    // startLavaSecurityPlusStore / applyLavaSecurityPlusEntitlement /
    // currentLavaSecurityPlusAppAccountToken / syncLavaSecurityPlusEntitlementIfPossible
    // moved to LavaSecurityPlusController.swift (Phase D2 billing peel).

    func vpnStatusReportDescription(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid:
            "invalid"
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .connected:
            "connected"
        case .reasserting:
            "reasserting"
        case .disconnecting:
            "disconnecting"
        @unknown default:
            "unknown-\(status.rawValue)"
        }
    }

    static func bundleInfoValue(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "Unknown"
    }

    static func deviceFamilyDescription(_ idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .phone:
            "Phone"
        case .pad:
            "iPad"
        case .mac:
            "Mac"
        case .tv:
            "Apple TV"
        case .carPlay:
            "CarPlay"
        case .vision:
            "Apple Vision"
        case .unspecified:
            "Unspecified"
        @unknown default:
            "Unknown"
        }
    }
}
