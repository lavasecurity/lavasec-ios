import Foundation
import LavaSecCore

/// Owns the temporary-protection-pause state machine that previously lived
/// inline in `AppViewModel`: the `ProtectionPauseStore`, the one-shot resume
/// timer, and the legacy app-group / standard `UserDefaults` mirror cleanup.
///
/// `AppViewModel` keeps the `@Published temporaryProtectionPauseUntil` the views
/// bind to, and all pause/resume *orchestration* (command service, latency
/// tracing, tunnel IPC, filter restore, Live Activities) — that work is woven
/// into the snapshot/tunnel pipeline and stays put. It reads the authoritative
/// pause-until via `currentPauseUntil()` and drives the timer through
/// `scheduleResume`/`onPauseCleared`/`clear`. The only coupling back into
/// `AppViewModel` is the `onFire` closure the resume timer invokes on expiry.
@MainActor
final class TemporaryProtectionPauseController {
    private let store: ProtectionPauseStore
    private let appGroupDefaults: UserDefaults
    private let standardDefaults: UserDefaults
    private let pausedUntilDefaultsKey: String
    private let pausedSessionIDDefaultsKey: String
    private var resumeTask: Task<Void, Never>?

    init(
        appGroupDefaults: UserDefaults,
        standardDefaults: UserDefaults = .standard,
        pausedUntilDefaultsKey: String = LavaSecAppGroup.protectionTemporaryPauseUntilDefaultsKey,
        pausedSessionIDDefaultsKey: String = LavaSecAppGroup.protectionTemporaryPauseSessionIDDefaultsKey
    ) {
        self.appGroupDefaults = appGroupDefaults
        self.standardDefaults = standardDefaults
        self.pausedUntilDefaultsKey = pausedUntilDefaultsKey
        self.pausedSessionIDDefaultsKey = pausedSessionIDDefaultsKey
        store = ProtectionPauseStore(
            storage: ProtectionUserDefaultsStorage(defaults: appGroupDefaults),
            lock: ProtectionNSLock()
        )
    }

    deinit {
        resumeTask?.cancel()
    }

    /// Authoritative current pause-until from the store (session binding + expiry
    /// are applied by `ProtectionPauseStore`); `nil` when not paused.
    func currentPauseUntil() -> Date? {
        (try? store.currentPauseState())?.pausedUntil
    }

    /// Called when the store reports no active pause: cancel the resume timer and
    /// drop any stale mirror keys (mirrors the old `loadTemporaryProtectionPause`
    /// cleanup branch).
    func onPauseCleared() {
        resumeTask?.cancel()
        resumeTask = nil
        removeStoredStateIfPresent()
    }

    /// Schedules a one-shot resume at `until` (or after `retryDelay`), invoking
    /// `onFire` on the main actor when it elapses. Cancels any pending timer; a
    /// `nil` `until` just cancels.
    func scheduleResume(
        until: Date?,
        retryDelay: TimeInterval? = nil,
        onFire: @escaping @MainActor () async -> Void
    ) {
        resumeTask?.cancel()

        guard let until else {
            resumeTask = nil
            return
        }

        let delay = retryDelay ?? max(0, until.timeIntervalSinceNow)
        resumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
            guard !Task.isCancelled else {
                return
            }

            self?.resumeTask = nil
            await onFire()
        }
    }

    /// Clears the active pause: cancels the timer, clears the store, and removes
    /// the standard-defaults mirror keys.
    func clear() {
        resumeTask?.cancel()
        resumeTask = nil
        try? store.clearStoredPause()
        standardDefaults.removeObject(forKey: pausedUntilDefaultsKey)
        standardDefaults.removeObject(forKey: pausedSessionIDDefaultsKey)
    }

    // Runs on every status refresh via `onPauseCleared`; the existence check
    // avoids a per-tick cfprefsd round trip when no mirror key is present.
    private func removeStoredStateIfPresent() {
        if appGroupDefaults.object(forKey: pausedUntilDefaultsKey) != nil
            || appGroupDefaults.object(forKey: pausedSessionIDDefaultsKey) != nil {
            try? store.clearStoredPause()
        }
        for key in [pausedUntilDefaultsKey, pausedSessionIDDefaultsKey]
        where standardDefaults.object(forKey: key) != nil {
            standardDefaults.removeObject(forKey: key)
        }
    }

    private static func nanoseconds(for duration: TimeInterval) -> UInt64 {
        guard duration > 0 else {
            return 0
        }

        return UInt64((duration * 1_000_000_000).rounded(.up))
    }
}
