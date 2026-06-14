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
            let defaults = UserDefaults(suiteName: LavaSecAppGroup.identifier) ?? .standard
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
            case .pauseFiveMinutes, .pauseTenMinutes, .pauseFifteenMinutes:
                guard let duration = request.pauseDuration else {
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

    // Restart the tunnel for an explicit Dynamic Island "Reconnect" tap.
    // loadAllFromPreferences is scoped to this app's NE configurations, so the
    // first manager is Lava's. Connect-On-Demand is already enabled, so this just
    // forces an immediate connect; the app's status reconcile returns the Live
    // Activity to .on once connected.
    private static func performReconnect() async throws {
        // Select and start inside the completion handler so the non-Sendable
        // manager never crosses the continuation boundary (Swift 6 concurrency).
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let manager = (managers ?? []).first else {
                    log("reconnect-no-manager")
                    continuation.resume()
                    return
                }

                do {
                    try manager.connection.startVPNTunnel()
                    log("reconnect-started")
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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
        let defaults = UserDefaults(suiteName: LavaSecAppGroup.identifier) ?? .standard
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
        let defaults = UserDefaults(suiteName: LavaSecAppGroup.identifier) ?? .standard
        let pauseRequiresAuthentication = SecurityProtectedSurfaceStorage.isProtected(
            .protectionPause,
            defaults: defaults
        )

        let state = LavaActivityAttributes.ContentState(
            protectionState: protectionState,
            resumeDate: resumeDate,
            pauseRequiresAuthentication: pauseRequiresAuthentication,
            shieldStyle: persistedShieldStyle(defaults: defaults)
        )
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

            _ = FileManager.default.createFile(atPath: lockURL.path, contents: nil)
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
