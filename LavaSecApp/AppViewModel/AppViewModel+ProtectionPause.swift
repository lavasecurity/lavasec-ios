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
    // MARK: - Temporary protection pause

    func pauseProtectionTemporarily(for option: ProtectionPauseDuration) {
        pauseProtectionTemporarily(request: option.protectionCommandRequest)
    }

    // Shared pause flow. `.pauseConfigured` (the Live Activity's single Pause
    // button) resolves its length inside the command service from the shared
    // preference; the app then loads the resulting pause window from the store
    // exactly like the fixed-length options.
    func pauseProtectionTemporarily(request: LavaLiveActivityActionRequest) {
        guard showsTemporaryProtectionPauseControls else {
            return
        }

        // CLAIMED SYNCHRONOUSLY, like every other entry point in this type — this one was the
        // exception, against the orchestrator's own documented contract ("Entry points claim a
        // kind before starting (synchronously, so a second tap is rejected before any await)").
        //
        // AND THE GAP IS REACHABLE. `LavaProtectionCommandService.perform` does not populate
        // `temporaryProtectionPauseUntil` until after its await, so for the whole of that window a
        // pause is invisible to everything else: any action that ends in
        // `beginFreshProtectionVPNSession` — a turn-on, a reconnect, a staging save — sees no
        // pause to preserve AND no claim to wait behind, and `clearTemporaryProtectionPause`
        // then discards the pause this task is still persisting. The user's chosen duration is
        // cut short with nothing on screen to explain it (Codex P2, PR #599 → PR #607).
        //
        // Refusing while another action is in flight is the convention here, not a new drop:
        // every other entry point, `resumeProtectionNow` included, rejects a second tap this way.
        // pinned: ChainedUpstreamStagingWiringSourceTests.testAPauseClaimsTheLifecycleLikeEveryOtherEntryPoint
        guard protectionActionOrchestrator.claim(.pause) else {
            return
        }

        let operationID = LatencyOperationID.make()
        let feedbackID = LavaFeedbackCoordinator.shared.begin("guard.pause")
        Task {
            // RELEASED LAST, after the span ends: the claim must outlive every step another
            // action would need to observe, including `loadTemporaryProtectionPause`.
            defer { protectionActionOrchestrator.release(.pause) }
            let trace = makeLatencyTrace(operationID: operationID, operationKind: "pause")
            let span = trace.beginSpan("action.pause", details: [
                "kind": request.rawValue,
                "vpnStatus": vpnStatusDebugDescription(vpnStatus)
            ])
            var actionStatus = "started"
            defer {
                span.end(details: ["status": actionStatus, "vpnStatus": vpnStatusDebugDescription(vpnStatus)])
            }

            do {
                try await LavaProtectionCommandService.perform(request, commandID: operationID.rawValue)
                loadTemporaryProtectionPause()
                if isProtectionTemporarilyPaused {
                    scheduleTemporaryProtectionResume()
                }
                await notifyTunnelProtectionPauseUpdated(operationID: operationID)
                reconcileLiveActivity()
                actionStatus = isProtectionTemporarilyPaused ? "paused" : "noop"
                LavaFeedbackCoordinator.shared.finish("guard.pause", feedbackID, .acknowledged,
                    cancelled: !isProtectionTemporarilyPaused)
            } catch {
                actionStatus = "error"
                vpnMessage = Self.vpnErrorMessage(prefix: "Could not pause protection".lavaLocalized, error: error)
                vpnMessageIsError = true
                LavaFeedbackCoordinator.shared.finish("guard.pause", feedbackID, .failed)
            }
        }
    }

    func resumeProtectionNow() {
        guard isProtectionTemporarilyPaused else {
            return
        }

        guard protectionActionOrchestrator.claim(.resume) else {
            return
        }

        let operationID = LatencyOperationID.make()
        let feedbackID = LavaFeedbackCoordinator.shared.begin("guard.resume")
        Task {
            let resumed = await restoreFiltersAfterTemporaryProtectionPause(
                configurationAlreadyClaimed: true,
                operationID: operationID
            )
            LavaFeedbackCoordinator.shared.finish("guard.resume", feedbackID, resumed ? .succeeded : .attentionRequired)
            reconcileLiveActivity()
        }
    }

    func reconcileTemporaryProtectionPause() {
        loadTemporaryProtectionPause()

        guard isProtectionTemporarilyPaused else {
            reconcileLiveActivity()
            return
        }

        scheduleTemporaryProtectionResume()
        Task {
            await resumeTemporaryProtectionIfExpired()
            reconcileLiveActivity()
        }
    }
}
