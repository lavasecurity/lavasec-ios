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
    // MARK: - Live Activity

    func reconcileLiveActivity() {
        guard canUseProtectedPreferences else { return }
        loadTemporaryProtectionPause()
        if isProtectionTemporarilyPaused {
            scheduleTemporaryProtectionResume()
        }

        // Read the restart deadline ONCE and derive both the state and resumeDate
        // from it — a second read could expire between the two and republish
        // `.restarting` with no deadline, defeating the widget's self-clear.
        // Both transient states carry their self-resolve deadline in `resumeDate`:
        // the resume time when paused, the restart deadline when restarting.
        let restartDeadline = restartInFlightDeadline
        let protectionState = liveActivityProtectionState(restartInFlightDeadline: restartDeadline)
        let resumeDate = protectionState == .restarting ? restartDeadline : temporaryProtectionPauseUntil

        // The three preference reads live on `customization` since the Phase D5 peel
        // (hub→controller is the allowed direction — the hub owns the controller);
        // the reconcile machinery itself stays here because it reads VPN status +
        // pause state and is called from the status observation paths.
        Task {
            // Re-check before the asynchronous effect: provisional preferences must
            // not end an existing activity or publish a fallback Guard appearance.
            guard canUseProtectedPreferences else { return }
            await liveActivityController.reconcile(
                usesLiveActivities: customization.usesLiveActivities,
                protectionState: protectionState,
                resumeDate: resumeDate,
                shieldStyle: customization.lavaGuardLook,
                pauseMinutes: customization.liveActivityPauseMinutes,
                pauseRequiresAuthentication: SecurityProtectedSurfaceStorage.isProtected(
                    .protectionPause,
                    defaults: appGroupDefaults, projectionURL: LavaSecAppGroup.securityGateProjectionURL
                )
            )
        }
    }

    /// Responds to the tunnel's connectivity-health Darwin nudge: pull the fresh
    /// health over the reliable provider-message channel, then let
    /// `refreshTunnelHealth` reconcile the Live Activity if the derived Dynamic
    /// Island state changed (UR-6).
    func handleTunnelHealthNudge() {
        // A chained surrender writes its terminal marker immediately before cancelling the
        // provider. Reconcile the cached NetworkExtension state first so a foreground app can
        // disarm Connect-On-Demand without waiting for the next periodic status refresh.
        if let markerURL = LavaSecAppGroup.chainedStartupFailureMarkerURL,
            ChainedStartupFailureMarker.isMarked(
                storageURL: markerURL,
                lockURL: LavaSecAppGroup.chainedStartupFailureMarkerLockURL)
        {
            updateProtectionStatusFromCachedManager()
        }
        // The provider posts after its eligibility/terminal writes. Update both settings
        // projections even if it has already stopped and cannot answer a health flush.
        refreshDNSSettingsPresentation()
        Task { [weak self] in
            guard let self else {
                return
            }

            await self.requestTunnelHealthFlush()
            self.refreshTunnelHealth(force: true)
        }
    }

    func performLiveActivityActionRequest(_ request: LavaLiveActivityActionRequest) {
        switch request {
        case .pauseFiveMinutes:
            pauseProtectionTemporarily(for: .fiveMinutes)
        case .pauseTenMinutes:
            pauseProtectionTemporarily(for: .tenMinutes)
        case .pauseFifteenMinutes:
            pauseProtectionTemporarily(for: .fifteenMinutes)
        case .pauseConfigured:
            pauseProtectionTemporarily(request: .pauseConfigured)
        case .resume:
            resumeProtectionNow()
        case .reconnect:
            reconnectProtection()
        }
    }

    // The deadline of an in-flight Dynamic Island Restart (shared-defaults), or nil
    // when none is running / it has expired. Travels as the activity's `resumeDate`
    // so the widget self-advances `.restarting → .on` at the same instant the
    // command's own push would, keeping the two push paths consistent.
    private var restartInFlightDeadline: Date? {
        let raw = appGroupDefaults.double(
            forKey: LavaSecAppGroup.protectionRestartInFlightUntilDefaultsKeyName
        )
        guard raw > Date().timeIntervalSinceReferenceDate else {
            return nil
        }
        return Date(timeIntervalSinceReferenceDate: raw)
    }

    var isRestartInFlight: Bool {
        restartInFlightDeadline != nil
    }

    // Takes the restart deadline as a parameter (rather than re-reading it) so the
    // caller can derive the state and the `resumeDate` from the SAME captured value.
    private func liveActivityProtectionState(
        restartInFlightDeadline: Date?
    ) -> LavaActivityAttributes.ProtectionState? {
        // A user-initiated Restart is in flight (the Restart command set a shared
        // deadline). Hold the Dynamic Island on the transient "restarting" feedback
        // — checked before the vpnStatus guard — so the status notifications the
        // restart itself emits (connected → disconnecting → connecting) neither end
        // the activity nor clobber it with `.on`. The command pushes the same state,
        // so the two agree; the deadline auto-expires if the restart never reports.
        if restartInFlightDeadline != nil {
            return .restarting
        }

        guard vpnStatus == .connected else {
            return nil
        }

        if isProtectionTemporarilyPaused {
            return .paused
        }

        // The Dynamic Island deliberately does not surface transient connectivity
        // status (reconnecting / needs-reconnect / no-network). Those states
        // originate in the always-running tunnel and change while the app is
        // suspended, so the app can never push a timely correction — a stale
        // alarm or stale all-clear is the result. Lava is fail-closed, so a
        // reconnect wobble blocks traffic rather than exposing it, which makes a
        // steady "On" honest. The user's recovery affordance is the always-
        // available Restart action, not a reactive alarm the surface can't keep
        // fresh. The in-app Guard tab still renders live connectivity detail.
        return .on
    }

    func turnOffProtection() {
        #if targetEnvironment(simulator)
        guard !protectionActionOrchestrator.isActionInFlight else {
            return
        }
        vpnMessage = "Use a physical device to test VPN permission and tunneling."
        vpnMessageIsError = false
        #else
        guard protectionActionOrchestrator.claim(.turnOff) else {
            return
        }
        userProtectionIntent.recordUserIntent(isEnabled: false)
        Task {
            await disableProtection(persistsExplicitIntent: true)
            protectionActionOrchestrator.release(.turnOff)
        }
        #endif
    }

    func reconnectProtection() {
        #if targetEnvironment(simulator)
        guard !protectionActionOrchestrator.isActionInFlight else {
            return
        }
        vpnMessage = "Use a physical device to test VPN permission and tunneling."
        vpnMessageIsError = false
        #else
        guard protectionActionOrchestrator.claim(.reconnect) else {
            return
        }
        userProtectionIntent.recordUserIntent(isEnabled: true)
        appendAppNetworkActivity(.reconnectProtection)
        Task {
            await reconnectProtectionNow(persistsExplicitIntent: true)
            protectionActionOrchestrator.release(.reconnect)
        }
        #endif
    }

    func toggleProtection() {
        #if targetEnvironment(simulator)
        guard !protectionActionOrchestrator.isActionInFlight else {
            return
        }
        vpnMessage = "Use a physical device to test VPN permission and tunneling."
        vpnMessageIsError = false
        #else
        guard protectionActionOrchestrator.claim(.toggle) else {
            return
        }
        // Treat an armed-but-dropped tunnel as "on" so the "Turn Off" the reconnecting surface shows
        // routes to the disable path (which disarms on-demand), instead of re-enabling and leaving the
        // user unable to actually turn protection off while iOS keeps trying to reconnect.
        let shouldDisableProtection = isProtectionEnabledStatus(vpnStatus) || isAwaitingOnDemandReconnect
        userProtectionIntent.recordUserIntent(isEnabled: !shouldDisableProtection)
        Task {
            if shouldDisableProtection {
                await disableProtection(persistsExplicitIntent: true)
            } else {
                await enableProtection(persistsExplicitIntent: true)
            }
            protectionActionOrchestrator.release(.toggle)
        }
        #endif
    }
}
