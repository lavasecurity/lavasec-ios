import AppIntents
import ActivityKit
import Foundation
import LavaSecKit

public struct PauseLavaProtectionIntent: AppIntent, LiveActivityIntent {
    nonisolated(unsafe) public static var title: LocalizedStringResource = "Pause Lava Protection"
    nonisolated(unsafe) public static var description = IntentDescription("Ask to confirm pausing Lava protection for your chosen length.")
    nonisolated(unsafe) public static var isDiscoverable = false

    @Parameter(title: "Activity") public var activityID: String

    public init() {}

    /// Binds confirmation to the Live Activity whose Pause control was tapped.
    public init(activityID: String) { self.activityID = activityID }

    public func perform() async throws -> some IntentResult {
        await LavaLiveActivityPauseConfirmationCoordinator.shared.arm(activityID: activityID)
        return .result()
    }
}

public struct PauseLavaProtectionFiveMinutesIntent: AppIntent, LiveActivityIntent {
    nonisolated(unsafe) public static var title: LocalizedStringResource = "Pause Lava Protection for 5 Minutes"
    nonisolated(unsafe) public static var description = IntentDescription("Pause Lava protection for five minutes.")
    nonisolated(unsafe) public static var isDiscoverable = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await LavaProtectionCommandService.perform(.pauseFiveMinutes)
        return .result()
    }
}

public struct PauseLavaProtectionTenMinutesIntent: AppIntent, LiveActivityIntent {
    nonisolated(unsafe) public static var title: LocalizedStringResource = "Pause Lava Protection for 10 Minutes"
    nonisolated(unsafe) public static var description = IntentDescription("Pause Lava protection for ten minutes.")
    nonisolated(unsafe) public static var isDiscoverable = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await LavaProtectionCommandService.perform(.pauseTenMinutes)
        return .result()
    }
}

public struct AuthenticatedPauseLavaProtectionFiveMinutesIntent: AppIntent, LiveActivityIntent {
    nonisolated(unsafe) public static var title: LocalizedStringResource = "Pause Lava Protection for 5 Minutes"
    nonisolated(unsafe) public static var description = IntentDescription("Pause Lava protection for five minutes.")
    nonisolated(unsafe) public static var isDiscoverable = false
    nonisolated(unsafe) public static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await LavaProtectionCommandService.perform(.pauseFiveMinutes)
        return .result()
    }
}

public struct AuthenticatedPauseLavaProtectionTenMinutesIntent: AppIntent, LiveActivityIntent {
    nonisolated(unsafe) public static var title: LocalizedStringResource = "Pause Lava Protection for 10 Minutes"
    nonisolated(unsafe) public static var description = IntentDescription("Pause Lava protection for ten minutes.")
    nonisolated(unsafe) public static var isDiscoverable = false
    nonisolated(unsafe) public static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await LavaProtectionCommandService.perform(.pauseTenMinutes)
        return .result()
    }
}

public struct ResumeLavaProtectionIntent: AppIntent, LiveActivityIntent {
    nonisolated(unsafe) public static var title: LocalizedStringResource = "Resume Lava Protection"
    nonisolated(unsafe) public static var description = IntentDescription("Resume Lava protection now.")
    nonisolated(unsafe) public static var isDiscoverable = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await LavaProtectionCommandService.perform(.resume)
        return .result()
    }
}

// Restart control surfaced on the Live Activity. The type name and the
// underlying `.reconnect` command are unchanged (a full tunnel stop→start);
// only the user-facing wording is "Restart", which reads as a neutral always-
// available control rather than implying a disconnected status the UI no
// longer surfaces.
public struct ReconnectLavaProtectionIntent: AppIntent, LiveActivityIntent {
    nonisolated(unsafe) public static var title: LocalizedStringResource = "Restart Lava Protection"
    nonisolated(unsafe) public static var description = IntentDescription("Restart Lava protection now.")
    nonisolated(unsafe) public static var isDiscoverable = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await LavaProtectionCommandService.perform(.reconnect)
        return .result()
    }
}

struct ConfirmLavaProtectionPauseIntent: AppIntent, LiveActivityIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Confirm Pause"
    nonisolated(unsafe) static var isDiscoverable = false

    @Parameter(title: "Confirmation") var token: String
    @Parameter(title: "Activity") var activityID: String

    init() {}

    init(token: String, activityID: String) {
        self.token = token
        self.activityID = activityID
    }

    func perform() async throws -> some IntentResult {
        try await LavaLiveActivityPauseConfirmationCoordinator.shared.confirm(token: token, activityID: activityID)
        return .result()
    }
}

// LiveActivityIntent executes in the app process. Pending permission is deliberately
// memory-only: process death revokes it, rather than reviving a stale Confirm button.
//
// A Live Activity re-renders when the system decides to, when new content is pushed, and
// at the content's `staleDate`. The widget does re-evaluate deadlines from `timeline.date`
// on every render it is given — that is how `paused`/`restarting` resolve themselves, and
// it still holds (`LavaActivityAttributes.effectiveProtectionState`). Those two states work
// unattended because the app sets `staleDate: resumeDate` when it publishes them
// (`LavaProtectionCommandService`), so a render is guaranteed at the exact instant their
// deadline passes.
//
// The pause confirmation is the one transient state published with `staleDate: nil`, so
// nothing guarantees a render when ITS deadline passes and the Confirm button could sit
// there indefinitely — the owner's report (PR #731). `staleDate` is still not used here:
// it marks the WHOLE activity stale, stranding an otherwise current On activity after a
// dismissed confirmation, and that trade-off is pinned by
// `LiveActivityPauseConfirmationTests.testIntentArmsWithoutPausingAndConsumesBeforeCommand`.
//
// So this process publishes the cleared confirmation itself. That revert is BEST EFFORT
// and not a guarantee: `Task.sleep` only advances while the app runs, and iOS may suspend
// it once `perform()` returns, in which case the scheduled revert does not fire at the
// five-second mark. What actually bounds the stale button is the late-tap repair below,
// which runs whenever the user taps and is the one moment this process is certainly awake,
// plus any later render the system performs. None of this is device-verified.
private actor LavaLiveActivityPauseConfirmationCoordinator {
    static let shared = LavaLiveActivityPauseConfirmationCoordinator()
    private var confirmationGate = LiveActivityPauseConfirmationGate()
    /// One pending revert per activity, tagged with the window that scheduled it. The
    /// actor suspends across `activity.update`, so a re-arm can land between a superseded
    /// window's wake and its cleanup; the tag is what stops it retiring the newer handle.
    private var expiry: [String: (token: String, task: Task<Void, Never>)] = [:]

    func arm(activityID: String) async {
        guard let activity = Activity<LavaActivityAttributes>.activities.first(where: {
            $0.id == activityID && ($0.activityState == .active || $0.activityState == .stale)
        }) else { return }
        var state = activity.content.state
        guard state.effectiveProtectionState(now: Date()) == .on, !state.pauseRequiresAuthentication else { return }
        let confirmation = confirmationGate.arm(activityID: activity.id, now: Date())
        state.pauseConfirmation = confirmation
        // Only the confirmation expires. Marking the whole activity stale would strand
        // an otherwise current On activity after a dismissed confirmation.
        await activity.update(ActivityContent(state: state, staleDate: nil))
        scheduleExpiry(activityID: activity.id, token: confirmation.token)
    }


    func confirm(token: String, activityID: String) async throws {
        guard let activity = Activity<LavaActivityAttributes>.activities.first(where: { $0.id == activityID }),
              activity.activityState == .active,
              activity.content.state.effectiveProtectionState(now: Date()) == .on,
              !activity.content.state.pauseRequiresAuthentication,
              activity.content.state.pauseConfirmation?.token == token
        else { return }
        // Consume before the first suspension: duplicate taps cannot submit two pauses.
        guard confirmationGate.consume(activityID: activityID, token: token, now: Date()) else {
            // An expired or already-spent tap is the one moment this process is awake and
            // knows the rendered button outlived its permission. Repair the control instead
            // of returning silently, so a late tap restores Pause rather than doing nothing.
            // pinned: LiveActivityPauseConfirmationTests.testALateTapRepairsTheRenderedControlWithoutPausing
            await clearRenderedConfirmation(activityID: activityID, token: token)
            return
        }
        // The window is spent; retire its scheduled revert and the rendered button with it.
        await clearRenderedConfirmation(activityID: activityID, token: token)
        // Existing command service remains the authority for current authentication/session
        // gating and pause duration. Never mutate the tunnel or pause store here.
        try await LavaProtectionCommandService.perform(.pauseConfigured)
    }

    /// Publishes the cleared confirmation when the window closes, which is the render the
    /// expiring confirmation would otherwise never be given. Best effort: see the rationale
    /// above — a suspended app does not reach this, and the late-tap repair is the backstop.
    /// pinned: LiveActivityPauseConfirmationTests.testArmingSchedulesTheRevertThatClearsTheRenderedConfirmation
    private func scheduleExpiry(activityID: String, token: String) {
        expiry[activityID]?.task.cancel()
        expiry[activityID] = (token: token, task: Task { [weak self] in
            // Relative sleep is the only elapsed-time gate, so moving the wall clock
            // cannot strand a pending confirmation on screen.
            try? await Task.sleep(nanoseconds: UInt64(LiveActivityPauseConfirmation.window * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.clearRenderedConfirmation(activityID: activityID, token: token)
        })
    }

    /// Drops this window's scheduled revert, and only this window's.
    private func retireExpiry(activityID: String, token: String) {
        guard expiry[activityID]?.token == token else { return }
        expiry[activityID]?.task.cancel()
        expiry[activityID] = nil
    }

    /// Clears only the confirmation this call owns: matching the token keeps a later
    /// arming's button alive, and the activity's own staleness is left untouched.
    private func clearRenderedConfirmation(activityID: String, token: String) async {
        retireExpiry(activityID: activityID, token: token)
        guard let activity = Activity<LavaActivityAttributes>.activities.first(where: { $0.id == activityID }),
              activity.content.state.pauseConfirmation?.token == token
        else { return }
        var state = activity.content.state
        state.pauseConfirmation = nil
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }
}
