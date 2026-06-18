@preconcurrency import ActivityKit
import Foundation
import LavaSecCore
import UIKit

@MainActor
final class LavaLiveActivityController: AmbientProtectionPresenter {
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

        // A Live Activity the system ended — e.g. after its multi-hour lifetime cap
        // elapsed while the app was suspended overnight — stays referenced here but can
        // no longer be updated; update() becomes a silent no-op and the Dynamic Island /
        // Lock Screen stay blank. Only adopt an activity that is still updatable;
        // otherwise drop the dead reference and request a fresh one so the presentation
        // reappears on the next reconcile (app foreground or a tunnel-health change). (UR-25)
        let adoptedActivity = currentActivity.flatMap { Self.isAdoptable($0) ? $0 : nil }
            ?? Activity<LavaActivityAttributes>.activities.first(where: Self.isAdoptable)

        if let activity = adoptedActivity {
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

        // Nothing adoptable (never created, or the system ended ours) — clear the stale
        // reference and request a new activity.
        currentActivity = nil
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

    /// A Live Activity can be refreshed only while it is still `active` or `stale`. Once
    /// the system has ended or dismissed it — including when it hits its lifetime cap
    /// while the app is suspended — `update()` is a no-op, so such references must be
    /// discarded and replaced with a freshly requested activity rather than reused. (UR-25)
    private static func isAdoptable(_ activity: Activity<LavaActivityAttributes>) -> Bool {
        switch activity.activityState {
        case .active, .stale:
            return true
        default:
            return false
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
