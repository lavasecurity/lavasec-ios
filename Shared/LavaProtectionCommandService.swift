import ActivityKit
import CoreFoundation
import Darwin
import Foundation
import LavaSecCore
import NetworkExtension

enum LavaProtectionCommandService {
    private static let commandCoordinator = LavaProtectionCommandCoordinator()
    private static let liveActivityUpdateCoordinator = LavaProtectionLiveActivityUpdateCoordinator()

    // commandID threads the caller's operation id into the pause store's
    // duplicate-command dedup, so a re-delivered command (stale intent retry,
    // double-dispatched action) cannot mint a second revision.
    static func perform(
        _ request: LavaLiveActivityActionRequest,
        now: Date = Date(),
        commandID: String? = nil
    ) async throws {
        log("perform-begin", details: ["request": request.rawValue])

        // Reconnect is not a pause-store command — it restarts the tunnel. Handle
        // it directly (the LiveActivityIntent runs in the app process, which holds
        // the NetworkExtension entitlement) and skip the pause/revision pipeline.
        if request == .reconnect {
            do {
                try await performReconnect()
                log("perform-finished", details: ["request": request.rawValue])
            } catch {
                log("perform-error", details: [
                    "request": request.rawValue,
                    "error": String(describing: error)
                ])
                throw error
            }
            return
        }

        do {
            let outcome = try await commandCoordinator.perform(request, now: now, commandID: commandID)
            await liveActivityUpdateCoordinator.schedule(outcome.activityUpdate)

            log("perform-finished", details: [
                "request": request.rawValue,
                "revision": String(outcome.activityUpdate.revision)
            ])
        } catch {
            log("perform-error", details: [
                "request": request.rawValue,
                "error": String(describing: error)
            ])
            throw error
        }
    }

    private static func applyCommand(
        _ request: LavaLiveActivityActionRequest,
        now: Date,
        commandID: String?
    ) throws -> LavaProtectionCommandOutcome {
        try LavaProtectionCommandFileLock.withExclusiveLock {
            let defaults = LavaSecAppGroup.sharedDefaults
            // The cross-process file lock is already held, so the stores run with
            // a no-op critical section. The LavaSecCore stores are the single
            // owners of key layout, revisions, dedup, and session binding; this
            // service keeps the lock, auth denial, signaling, and Live Activity
            // outcomes.
            let storage = ProtectionUserDefaultsStorage(defaults: defaults)
            let sessionStore = ProtectionSessionStore(
                storage: storage,
                lock: ProtectionNoopCriticalSectionLock()
            )
            let pauseStore = ProtectionPauseStore(
                storage: storage,
                lock: ProtectionNoopCriticalSectionLock(),
                clock: LavaProtectionCommandClock(now: now)
            )

            switch request {
            case .pauseFiveMinutes, .pauseTenMinutes, .pauseFifteenMinutes, .pauseConfigured:
                guard let duration = resolvedPauseDuration(for: request, defaults: defaults) else {
                    log("perform-missing-duration", details: ["request": request.rawValue])
                    return try currentActivityOutcome(pauseStore: pauseStore, reason: "missing-duration")
                }

                return try pauseProtection(
                    for: duration,
                    defaults: defaults,
                    sessionStore: sessionStore,
                    pauseStore: pauseStore,
                    commandID: commandID
                )
            case .resume:
                return try resumeProtection(
                    sessionStore: sessionStore,
                    pauseStore: pauseStore,
                    commandID: commandID
                )
            case .reconnect:
                // Handled earlier in perform(); unreachable here. Return the
                // current state defensively rather than mutating pause state.
                return try currentActivityOutcome(pauseStore: pauseStore, reason: "reconnect-unexpected")
            }
        }
    }

    // Restart the tunnel for an explicit Dynamic Island "Restart" tap.
    //
    // The Restart control is always offered in the `.on` state, so the tunnel is
    // usually already connected — a bare `startVPNTunnel()` would be a no-op there
    // and never actually restart anything. So this performs a real stop → wait →
    // start, tearing the provider down and bringing it back (fresh resolvers,
    // cleared wedges). Connect-On-Demand is deliberately left untouched: disabling
    // it would risk leaving protection un-armed if this background-woken intent's
    // execution window expires before it could be re-enabled.
    //
    // loadAllFromPreferences is scoped to this app's NE configurations, so the
    // first manager is Lava's. The non-Sendable manager never crosses a
    // continuation boundary (Swift 6): each step runs a synchronous closure on a
    // freshly loaded manager and returns only Sendable values.
    enum RestartError: Error {
        /// The tunnel never confirmed a full stop within the wait window, so an
        /// explicit start could not be issued safely.
        case stopTimedOut
    }

    private static func performReconnect() async throws {
        // Claim the in-flight slot. This rejects a second concurrent / re-delivered
        // Restart, and (load-bearing) lets the app's status reconcile report
        // `.restarting` for the duration: the restart's own stop→start emits
        // NEVPNStatusDidChange, and without this the in-process reconcile would
        // recompute `.on`/end and clobber the transient. Stored as a deadline so a
        // killed background window auto-clears it.
        let now = Date()
        guard let claimedDeadline = claimRestartInFlight(window: Self.restartingStaleWindow, now: now) else {
            log("reconnect-already-in-flight")
            return
        }

        // Show transient "Restarting…" feedback for the multi-second restart. Safe
        // to push (unlike ambient status) because the Restart tap woke this app
        // process. The deadline travels in `resumeDate`: the widget advances
        // `.restarting → .on` on its own 1s clock once it passes, so even if this
        // process is killed before the restore below runs, the Dynamic Island can't
        // get stranded on "Restarting…".
        await updateLiveActivities(
            protectionState: .restarting,
            resumeDate: now.addingTimeInterval(Self.restartingStaleWindow)
        )

        do {
            try await runTunnelRestart()
        } catch {
            // Clear the transient before propagating so a failure never leaves the
            // Dynamic Island stuck on "Restarting…" — but only when we still own the
            // lease. If a newer Restart took over after ours expired mid-unwind, it
            // owns the transient and its own restore; clearing/restoring here would
            // clobber it.
            if clearRestartInFlight(claimedDeadline: claimedDeadline) {
                await restoreLiveActivityAfterRestart()
            }
            throw error
        }

        if clearRestartInFlight(claimedDeadline: claimedDeadline) {
            await restoreLiveActivityAfterRestart()
        }
    }

    /// Re-derives the honest post-restart state rather than assuming `.on`:
    ///  - a pause that landed during the restart (rapid taps) is preserved, not
    ///    overwritten with On (which would hide Resume until a later reconcile);
    ///  - otherwise the state comes from the ACTUAL tunnel status, so a failed
    ///    restart (tunnel down) ends the activity instead of claiming protection is
    ///    On — the next reconcile recreates it with the true state.
    private static func restoreLiveActivityAfterRestart() async {
        let pauseStore = ProtectionPauseStore(
            storage: ProtectionUserDefaultsStorage(defaults: LavaSecAppGroup.sharedDefaults),
            lock: ProtectionNoopCriticalSectionLock()
        )
        if let pauseState = try? pauseStore.currentPauseState() {
            await updateLiveActivities(protectionState: .paused, resumeDate: pauseState.pausedUntil)
            return
        }

        switch await currentTunnelStatus() {
        case .connected:
            // Confirmed up — fail-closed, so a permanent On is honest.
            await updateLiveActivities(protectionState: .on, resumeDate: nil)
        default:
            // Not confirmed connected — still connecting/reasserting after the settle
            // wait, or down. Never assert a permanent On the suspended app might not
            // get to correct; end the activity and let the next reconcile recreate it
            // with the true state once the status settles.
            await endLiveActivities()
        }
    }

    private static func endLiveActivities() async {
        for activity in Activity<LavaActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Atomically claims the restart-in-flight slot (App Group, file-locked). Returns
    /// the claimed deadline, or `nil` when a restart is already in flight (its
    /// deadline is still in the future), so the caller no-ops instead of running a
    /// second parallel restart. The returned deadline is the exact value stored, so
    /// the caller can release it by compare-and-set in `clearRestartInFlight`.
    private static func claimRestartInFlight(window: TimeInterval, now: Date) -> Date? {
        (try? LavaProtectionCommandFileLock.withExclusiveLock { () -> Date? in
            let defaults = LavaSecAppGroup.sharedDefaults
            let existing = defaults.double(forKey: LavaSecAppGroup.protectionRestartInFlightUntilDefaultsKey)
            guard existing <= now.timeIntervalSinceReferenceDate else {
                return nil
            }
            let deadline = now.addingTimeInterval(window)
            defaults.set(
                deadline.timeIntervalSinceReferenceDate,
                forKey: LavaSecAppGroup.protectionRestartInFlightUntilDefaultsKey
            )
            return deadline
        }) ?? nil
    }

    /// Releases the restart-in-flight slot, but only if the stored deadline is still
    /// the one THIS restart claimed. A newer Restart may have taken over the slot
    /// after ours expired mid-unwind; deleting its deadline would drop the app-side
    /// `.restarting` guard and let status reconciles clobber its feedback. Returns
    /// whether we actually released our own lease.
    @discardableResult
    private static func clearRestartInFlight(claimedDeadline: Date) -> Bool {
        (try? LavaProtectionCommandFileLock.withExclusiveLock { () -> Bool in
            let defaults = LavaSecAppGroup.sharedDefaults
            let stored = defaults.double(forKey: LavaSecAppGroup.protectionRestartInFlightUntilDefaultsKey)
            guard stored == claimedDeadline.timeIntervalSinceReferenceDate else {
                return false
            }
            defaults.removeObject(
                forKey: LavaSecAppGroup.protectionRestartInFlightUntilDefaultsKey
            )
            return true
        }) ?? false
    }

    private static func runTunnelRestart() async throws {
        let didStop = try await withTunnelConnection { connection in
            connection.stopVPNTunnel()
        }
        guard didStop else {
            // No configured manager — nothing to restart.
            log("reconnect-no-manager")
            return
        }

        // Start only once the provider has fully gone down — a start issued while
        // it is still `.disconnecting` is silently ignored, which would log a
        // phantom restart.
        if await waitForTunnelToStop(timeout: Self.reconnectStopWaitTimeout) {
            try await withTunnelConnection { connection in
                try connection.startVPNTunnel()
            }
            // Wait (bounded) for the tunnel to actually come back before returning.
            // Right after a start iOS briefly still reports .disconnected/.connecting
            // (the documented start-grace beat); returning then would clear the
            // in-flight guard and let the restore/reconcile sample that pending status
            // and END the activity on a successful restart. Holding the guard until
            // it settles keeps the grace window masked as "restarting".
            await waitForTunnelToReconnect(timeout: Self.reconnectStartWaitTimeout)
            log("reconnect-restarted")
            return
        }

        // The stop did not confirm in time. If Connect-On-Demand already brought
        // the tunnel back up while we waited, the provider was still torn down and
        // relaunched — a successful restart, no explicit start needed. Otherwise it
        // is a slow/wedged tear-down where a start would be ignored, so surface the
        // timeout instead of logging a restart that did not happen.
        switch await currentTunnelStatus() {
        case .connected:
            log("reconnect-restarted-by-ondemand")
        case .connecting, .reasserting:
            // On-demand has relaunched the provider but it is mid-handshake. Settle
            // to .connected the same way the explicit-start path does, so the
            // restore samples a connected status instead of ending the activity on
            // a successful restart.
            await waitForTunnelToReconnect(timeout: Self.reconnectStartWaitTimeout)
            log("reconnect-restarted-by-ondemand")
        default:
            log("reconnect-stop-timeout")
            throw RestartError.stopTimedOut
        }
    }

    private static let reconnectStopWaitTimeout: TimeInterval = 8
    // Bounded wait for the tunnel to come back up after the start, covering the
    // post-start grace window so a successful restart reports a settled status.
    private static let reconnectStartWaitTimeout: TimeInterval = 4
    // The in-flight deadline / widget self-clear must cover the whole restart (stop
    // wait + start-settle wait) plus a small buffer, so the guard never drops
    // mid-restart and a killed window can't strand the transient much past it.
    // Derived so the pieces can't drift apart.
    private static let restartingStaleWindow: TimeInterval =
        reconnectStopWaitTimeout + reconnectStartWaitTimeout + 2

    /// Runs a synchronous op on Lava's tunnel connection. Returns `false` when no
    /// manager is configured so the caller can no-op. The non-Sendable manager
    /// never escapes the completion handler.
    @discardableResult
    private static func withTunnelConnection(
        _ body: @escaping @Sendable (NEVPNConnection) throws -> Void
    ) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let manager = (managers ?? []).first else {
                    continuation.resume(returning: false)
                    return
                }
                do {
                    try body(manager.connection)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Reads Lava's tunnel status without the non-Sendable manager crossing an
    /// `await` (`NEVPNStatus` is a plain enum). `nil` means no manager / load error.
    private static func currentTunnelStatus() async -> NEVPNStatus? {
        let status = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NEVPNStatus?, Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (managers ?? []).first?.connection.status)
            }
        }
        return status ?? nil
    }

    /// Polls the tunnel status until it is fully down. Returns `true` on a
    /// confirmed stop (or no manager), `false` if the timeout elapsed while the
    /// tunnel was still tearing down or had come back up.
    private static func waitForTunnelToStop(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch await currentTunnelStatus() {
            case .disconnected, .invalid, nil:
                return true
            default:
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        return false
    }

    /// Polls the tunnel status until it has settled back to `.connected` after a
    /// start, or the timeout elapses. Lets the post-start grace window (where iOS
    /// still reports `.disconnected`/`.connecting`) pass while the in-flight guard
    /// still masks it as "restarting", so the restore samples a settled status.
    private static func waitForTunnelToReconnect(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await currentTunnelStatus() == .connected {
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    // Fixed pause cases carry their own duration; `.pauseConfigured` (the Live
    // Activity's single Pause button) resolves the user-chosen length from the
    // shared app-group defaults, clamped to the valid range by the policy.
    private static func resolvedPauseDuration(
        for request: LavaLiveActivityActionRequest,
        defaults: UserDefaults
    ) -> TimeInterval? {
        if let fixedDuration = request.pauseDuration {
            return fixedDuration
        }

        guard request == .pauseConfigured else {
            return nil
        }

        return LiveActivityPausePreference.duration(forMinutes: persistedPauseMinutes(defaults: defaults))
    }

    private static func persistedPauseMinutes(defaults: UserDefaults) -> Int {
        LiveActivityPausePreference.minutes(from: ProtectionUserDefaultsStorage(defaults: defaults))
    }

    private static func pauseProtection(
        for duration: TimeInterval,
        defaults: UserDefaults,
        sessionStore: ProtectionSessionStore,
        pauseStore: ProtectionPauseStore,
        commandID: String?
    ) throws -> LavaProtectionCommandOutcome {
        guard let sessionID = try sessionStore.activeSessionID() else {
            log("pause-denied-no-active-session")
            return try currentActivityOutcome(pauseStore: pauseStore, reason: "pause-denied-no-active-session")
        }

        guard !SecurityProtectedSurfaceStorage.isProtected(.protectionPause, defaults: defaults) else {
            log("pause-denied-auth-required")
            return try currentActivityOutcome(pauseStore: pauseStore, reason: "pause-denied-auth-required")
        }

        let result = try pauseStore.pause(for: duration, requestedSessionID: sessionID, commandID: commandID)
        guard case .changed(let changedState) = result.status, let state = changedState else {
            log("pause-unchanged", details: ["revision": String(result.revision)])
            return try currentActivityOutcome(pauseStore: pauseStore, reason: "pause-unchanged")
        }

        log("pause-defaults-updated", details: [
            "duration": String(Int(duration)),
            "revision": String(result.revision),
            "sessionID": state.sessionID,
            "until": ISO8601DateFormatter().string(from: state.pausedUntil)
        ])

        return LavaProtectionCommandOutcome(
            activityUpdate: LavaProtectionLiveActivityUpdate(
                revision: result.revision,
                protectionState: .paused,
                resumeDate: state.pausedUntil,
                reason: "pause"
            )
        )
    }

    private static func resumeProtection(
        sessionStore: ProtectionSessionStore,
        pauseStore: ProtectionPauseStore,
        commandID: String?
    ) throws -> LavaProtectionCommandOutcome {
        let sessionID = try sessionStore.activeSessionID() ?? ""
        let result = try pauseStore.resume(requestedSessionID: sessionID, commandID: commandID)

        switch result.status {
        case .changed:
            log("resume-defaults-cleared", details: ["revision": String(result.revision)])
            return LavaProtectionCommandOutcome(
                activityUpdate: LavaProtectionLiveActivityUpdate(
                    revision: result.revision,
                    protectionState: .on,
                    resumeDate: nil,
                    reason: "resume"
                )
            )
        case .unchanged(.noActivePause):
            log("resume-noop-no-active-pause")
            return try currentActivityOutcome(pauseStore: pauseStore, reason: "resume-noop")
        case .unchanged(.duplicateCommand):
            log("resume-noop-duplicate-command")
            return try currentActivityOutcome(pauseStore: pauseStore, reason: "resume-noop")
        case .rejected(let rejection):
            log("resume-rejected", details: ["rejection": String(describing: rejection)])
            return try currentActivityOutcome(pauseStore: pauseStore, reason: "resume-rejected")
        }
    }

    private static func refreshLiveActivitiesFromSharedPauseState(defaults: UserDefaults) async {
        let pauseStore = ProtectionPauseStore(
            storage: ProtectionUserDefaultsStorage(defaults: defaults),
            lock: ProtectionNoopCriticalSectionLock()
        )
        if let pauseState = try? pauseStore.currentPauseState() {
            await updateLiveActivities(protectionState: .paused, resumeDate: pauseState.pausedUntil)
            return
        }

        await updateLiveActivities(protectionState: .on, resumeDate: nil)
    }

    private static func currentActivityOutcome(
        pauseStore: ProtectionPauseStore,
        reason: String
    ) throws -> LavaProtectionCommandOutcome {
        if let pauseState = try pauseStore.currentPauseState() {
            return LavaProtectionCommandOutcome(
                activityUpdate: LavaProtectionLiveActivityUpdate(
                    revision: pauseState.revision,
                    protectionState: .paused,
                    resumeDate: pauseState.pausedUntil,
                    reason: reason
                )
            )
        }

        return LavaProtectionCommandOutcome(
            activityUpdate: LavaProtectionLiveActivityUpdate(
                revision: try pauseStore.currentRevision(),
                protectionState: .on,
                resumeDate: nil,
                reason: reason
            )
        )
    }

    private static func updateLiveActivitiesIfCurrent(_ update: LavaProtectionLiveActivityUpdate) async {
        let defaults = LavaSecAppGroup.sharedDefaults
        let pauseStore = ProtectionPauseStore(
            storage: ProtectionUserDefaultsStorage(defaults: defaults),
            lock: ProtectionNoopCriticalSectionLock()
        )
        let currentRevision = (try? pauseStore.currentRevision()) ?? 0
        guard update.revision >= currentRevision else {
            log("activity-update-skipped-stale", details: [
                "revision": String(update.revision),
                "currentRevision": String(currentRevision),
                "reason": update.reason
            ])
            return
        }

        await updateLiveActivities(protectionState: update.protectionState, resumeDate: update.resumeDate)
    }

    private static func updateLiveActivities(
        protectionState: LavaActivityAttributes.ProtectionState,
        resumeDate: Date?
    ) async {
        let defaults = LavaSecAppGroup.sharedDefaults
        let pauseRequiresAuthentication = SecurityProtectedSurfaceStorage.isProtected(
            .protectionPause,
            defaults: defaults
        )

        let state = LavaActivityAttributes.ContentState(
            protectionState: protectionState,
            resumeDate: resumeDate,
            pauseRequiresAuthentication: pauseRequiresAuthentication,
            shieldStyle: persistedShieldStyle(defaults: defaults),
            pauseMinutes: persistedPauseMinutes(defaults: defaults)
        )
        // The transient states (paused, restarting) carry their self-resolve deadline
        // in resumeDate, which doubles as the staleDate so the activity also goes
        // stale at that instant.
        let content = ActivityContent(state: state, staleDate: resumeDate)

        let activities = Activity<LavaActivityAttributes>.activities
        log("activity-update-begin", details: [
            "count": String(activities.count),
            "state": protectionState.rawValue,
            "auth": String(pauseRequiresAuthentication)
        ])

        for activity in activities {
            await activity.update(content)
        }

        log("activity-update-finished", details: [
            "count": String(activities.count),
            "state": protectionState.rawValue
        ])
    }

    private static func persistedShieldStyle(defaults: UserDefaults) -> GuardianShieldStyle {
        guard let rawValue = defaults.string(forKey: LavaSecAppGroup.customizationLavaGuardLookDefaultsKey),
              let shieldStyle = GuardianShieldStyle(rawValue: rawValue)
        else {
            return .original
        }

        return shieldStyle
    }

    // Anchors the pause store's clock to the command's own timestamp so
    // pause-until math matches the moment the command was issued.
    private struct LavaProtectionCommandClock: ProtectionClock {
        let now: Date
    }

    private struct LavaProtectionCommandOutcome: Sendable {
        let activityUpdate: LavaProtectionLiveActivityUpdate
    }

    private struct LavaProtectionLiveActivityUpdate: Sendable {
        let revision: Int
        let protectionState: LavaActivityAttributes.ProtectionState
        let resumeDate: Date?
        let reason: String
    }

    private actor LavaProtectionCommandCoordinator {
        func perform(
            _ request: LavaLiveActivityActionRequest,
            now: Date,
            commandID: String?
        ) throws -> LavaProtectionCommandOutcome {
            try LavaProtectionCommandService.applyCommand(request, now: now, commandID: commandID)
        }
    }

    private actor LavaProtectionLiveActivityUpdateCoordinator {
        private var latestRevision = 0

        func schedule(_ update: LavaProtectionLiveActivityUpdate) {
            latestRevision = max(latestRevision, update.revision)
            Task.detached(priority: .utility) {
                guard await self.isCurrent(update.revision) else {
                    return
                }

                await LavaProtectionCommandService.updateLiveActivitiesIfCurrent(update)
            }
        }

        private func isCurrent(_ revision: Int) -> Bool {
            revision >= latestRevision
        }
    }

    private enum LavaProtectionCommandFileLock {
        static func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
            guard let lockURL = LavaSecAppGroup.containerURL?.appendingPathComponent(
                LavaSecAppGroup.protectionCommandLockFilename
            ) else {
                return try body()
            }

            // Open with O_CREAT only — deliberately NOT FileManager.createFile, which
            // on Darwin replaces an existing file's inode (temp + rename). Because
            // flock locks are bound to the inode, a createFile here would orphan the
            // current holder's lock and let every acquirer lock a fresh inode, so two
            // processes (app, tunnel, widget) could "acquire" concurrently — no real
            // mutual exclusion. O_CREAT without O_TRUNC/O_EXCL opens the existing inode
            // (or creates one), so all processes share a single lock object.
            let lockFileDescriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
            guard lockFileDescriptor >= 0 else {
                return try body()
            }

            defer {
                close(lockFileDescriptor)
            }

            guard flock(lockFileDescriptor, LOCK_EX) == 0 else {
                return try body()
            }

            defer {
                flock(lockFileDescriptor, LOCK_UN)
            }

            return try body()
        }
    }

    private static func log(_ event: String, details: [String: String] = [:]) {
        #if DEBUG || LAVA_QA_TOOLS
        LavaSecDeviceDebugLog.append(component: "live-activity-intent", event: event, details: details)
        #endif
    }
}
