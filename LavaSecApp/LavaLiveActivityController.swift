@preconcurrency import ActivityKit
import Foundation
import LavaSecCore
import UIKit

@MainActor
final class LavaLiveActivityController {
    private let authorizationInfo = ActivityAuthorizationInfo()
    private let appGroupDefaults = UserDefaults(suiteName: LavaSecAppGroup.identifier)
    private var currentActivity: Activity<LavaActivityAttributes>?
    private var lastPublishedActivityID: String?
    private var lastPublishedContentState: LavaActivityAttributes.ContentState?
    private var authorizationObservationTask: Task<Void, Never>?

    var canOfferLiveActivities: Bool {
        Self.canOfferLiveActivities(for: UIDevice.current.userInterfaceIdiom)
    }

    static func canOfferLiveActivities(for userInterfaceIdiom: UIUserInterfaceIdiom) -> Bool {
        switch userInterfaceIdiom {
        case .phone, .pad:
            true
        default:
            false
        }
    }

    func startObservingAuthorizationChanges(onChange: @escaping @MainActor (Bool) -> Void) {
        guard authorizationObservationTask == nil else {
            return
        }

        authorizationObservationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            for await isEnabled in authorizationInfo.activityEnablementUpdates {
                onChange(isEnabled)
                if !isEnabled {
                    await endActivities()
                }
            }
        }
    }

    func stopObservingAuthorizationChanges() {
        authorizationObservationTask?.cancel()
        authorizationObservationTask = nil
    }

    func reconcile(
        usesLiveActivities: Bool,
        protectionState: LavaActivityAttributes.ProtectionState?,
        resumeDate: Date?,
        shieldStyle: GuardianShieldStyle,
        pauseRequiresAuthentication: Bool
    ) async {
        let requestedProtectionState = protectionState

        guard canOfferLiveActivities,
              usesLiveActivities,
              authorizationInfo.areActivitiesEnabled,
              let requestedProtectionState
        else {
            await endActivities()
            return
        }

        // Read pause state only after the guard: at idle with Live Activities
        // disabled this method is called on every status refresh, and the
        // pre-guard defaults read was pure churn.
        let activePauseUntil = activeTemporaryProtectionPauseUntil()
        let protectionState = effectiveProtectionState(
            requestedProtectionState,
            activePauseUntil: activePauseUntil
        )
        let resumeDate = protectionState == .paused ? (activePauseUntil ?? resumeDate) : nil
        let state = LavaActivityAttributes.ContentState(
            protectionState: protectionState,
            resumeDate: resumeDate,
            pauseRequiresAuthentication: pauseRequiresAuthentication,
            shieldStyle: shieldStyle
        )
        let content = ActivityContent(state: state, staleDate: resumeDate)

        logReconcile(
            requestedProtectionState: requestedProtectionState,
            publishedProtectionState: protectionState,
            resumeDate: resumeDate
        )

        if let activity = currentActivity ?? Activity<LavaActivityAttributes>.activities.first {
            currentActivity = activity
            // ActivityKit updates are cross-process IPC; status refreshes repeat
            // with identical state, so only publish actual changes.
            guard lastPublishedActivityID != activity.id || lastPublishedContentState != state else {
                return
            }
            await activity.update(content)
            lastPublishedActivityID = activity.id
            lastPublishedContentState = state
            await endDuplicateActivities(keeping: activity.id)
            return
        }

        do {
            currentActivity = try Activity<LavaActivityAttributes>.request(
                attributes: LavaActivityAttributes(),
                content: content,
                pushType: nil
            )
            lastPublishedActivityID = currentActivity?.id
            lastPublishedContentState = state
        } catch {
            currentActivity = nil
            lastPublishedActivityID = nil
            lastPublishedContentState = nil
        }
    }

    private func effectiveProtectionState(
        _ protectionState: LavaActivityAttributes.ProtectionState,
        activePauseUntil: Date?
    ) -> LavaActivityAttributes.ProtectionState {
        guard activePauseUntil != nil else {
            return protectionState
        }

        return .paused
    }

    private func activeTemporaryProtectionPauseUntil() -> Date? {
        guard let defaults = appGroupDefaults else {
            return nil
        }

        // ProtectionPauseStore applies session binding and expiry; the keys are
        // shared with the app, tunnel, and intents processes.
        let pauseStore = ProtectionPauseStore(
            storage: ProtectionUserDefaultsStorage(defaults: defaults),
            lock: ProtectionNoopCriticalSectionLock()
        )
        return (try? pauseStore.currentPauseState())?.pausedUntil
    }

    private func endActivities() async {
        currentActivity = nil
        lastPublishedActivityID = nil
        lastPublishedContentState = nil
        for activity in Activity<LavaActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func endDuplicateActivities(keeping activityID: String) async {
        for activity in Activity<LavaActivityAttributes>.activities where activity.id != activityID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func logReconcile(
        requestedProtectionState: LavaActivityAttributes.ProtectionState,
        publishedProtectionState: LavaActivityAttributes.ProtectionState,
        resumeDate: Date?
    ) {
        #if DEBUG || LAVA_QA_TOOLS
        var details = [
            "requested": requestedProtectionState.rawValue,
            "published": publishedProtectionState.rawValue
        ]
        if let resumeDate {
            details["resumeDate"] = SharedDateFormatting.iso8601.string(from: resumeDate)
        }
        LavaSecDeviceDebugLog.append(
            component: "live-activity-controller",
            event: "reconcile",
            details: details
        )
        #endif
    }
}
