import Foundation
import LavaSecCore

/// Builds the `LavaSecCore.HeadlessFocusFilterSwitchEngine.Environment` from the App Group constants.
///
/// Lives in `Shared/` so the app target AND the App Intents extension construct a BYTE-IDENTICAL
/// environment — same container files, same publish + focus-switch locks, same shared defaults — and can
/// never drift on the paths the engine writes (LAV-100 Phase 4). `LavaSecAppGroup` is module-internal to
/// each target that compiles it, which is why the environment is assembled here rather than inside
/// LavaSecCore (which deliberately holds no App Group identifier).
enum FocusSwitchEnvironment {
    /// The warm-reuse cache freshness window. Mirrors `AppViewModel.catalogSyncFreshnessInterval`; a
    /// stale cache makes warm reuse fall back to the network-first cold path.
    static let catalogSyncFreshnessInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Build the environment and drive the shared engine. The single entry point used by BOTH the App
    /// Intents extension's `perform()` and any in-app caller, so they can't drift. Returns `.disallowed`
    /// when the App Group container is unavailable.
    @discardableResult
    static func performSwitch(toFilterID filterID: String) async -> HeadlessFocusSwitchOutcome {
        guard let env = make() else { return .disallowed }
        return await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: filterID, env: env)
    }

    // The Focus-off (nil-filter) edge is a pure no-op — see LavaFocusFilterIntent.perform() and the engine's
    // note on why the off-edge cannot safely cancel a marker (it carries no Focus identity). No entry here.

    /// `nil` when the App Group container is unavailable (the engine caller then reports `.disallowed`).
    static func make() -> HeadlessFocusFilterSwitchEngine.Environment? {
        guard let containerURL = LavaSecAppGroup.containerURL else { return nil }
        return HeadlessFocusFilterSwitchEngine.Environment(
            containerURL: containerURL,
            configurationURL: containerURL.appendingPathComponent(LavaSecAppGroup.configurationFilename),
            filterLibraryURL: containerURL.appendingPathComponent(LavaSecAppGroup.filterLibraryFilename),
            catalogCacheURL: containerURL.appendingPathComponent(LavaSecAppGroup.catalogCacheDirectoryName, isDirectory: true),
            backgroundWarmIndexURL: containerURL.appendingPathComponent(LavaSecAppGroup.backgroundWarmIndexFilename),
            publishLockURL: containerURL.appendingPathComponent(LavaSecAppGroup.filterArtifactPublishLockFilename),
            focusSwitchLockURL: containerURL.appendingPathComponent(LavaSecAppGroup.focusFilterSwitchLockFilename),
            configurationWriteLockURL: containerURL.appendingPathComponent(LavaSecAppGroup.configurationWriteLockFilename),
            pendingMarkerLockURL: containerURL.appendingPathComponent(LavaSecAppGroup.pendingFilterSwitchMarkerLockFilename),
            snapshotFilename: LavaSecAppGroup.snapshotFilename,
            compactSnapshotFilename: LavaSecAppGroup.compactSnapshotFilename,
            defaults: LavaSecAppGroup.sharedDefaults,
            catalogSyncFreshnessInterval: catalogSyncFreshnessInterval,
            // The engine's `log` defaults to a no-op. The Release-visible diagnostic is the always-on
            // FocusSwitchDiagnostics record (surfaced in the bug report), not the QA-only device log — so
            // we don't gate a device-log write here (which would also spread the internal-only build flag
            // into tracked source, which the merge-up contamination guard forbids).
            notifySwitchOutcome: { await notifySwitchOutcome(committed: $0, filterName: $1) }
        )
    }

    /// Post the user-facing "Switched to <name>" / "Couldn't switch to <name>" notification for a headless
    /// Focus switch — CLOSED/BACKGROUNDED ONLY. A foreground app shows the switch in its UI, so we skip the
    /// banner when the app-group foreground flag says the app is active; when it is closed/backgrounded
    /// (flag false/absent) the banner is the user's only signal — the mitigation for iOS deferring the
    /// extension launch for a suspended app. Category toggle + notification permission are enforced inside
    /// `LavaEventNotificationPoster`.
    ///
    /// AWAITED (not a detached Task): the engine awaits this, which the extension's `perform()` awaits, so the
    /// App Intents extension is kept alive until the banner is actually posted — a fire-and-forget Task could
    /// let `perform()` return and the extension suspend before `add()` runs, losing the banner in exactly the
    /// closed-app case this serves (Codex P2). The tap route is `guard` (the one the notification delegate
    /// handles) so a tap opens the app; Filters-specific navigation on tap is a polish follow-up.
    private static func notifySwitchOutcome(committed: Bool, filterName: String) async {
        let defaults = LavaSecAppGroup.sharedDefaults
        guard !defaults.bool(forKey: LavaSecAppGroup.appForegroundActiveDefaultsKey) else { return }

        let category: LavaNotificationCategory = committed ? .filterChanged : .filterCouldNotApply
        // Localized in LavaSecCore (Bundle.module) so it resolves in the extension's bundle too.
        let body = LavaEventNotificationPoster.filterSwitchBody(committed: committed, filterName: filterName)
        let userInfo = [
            LavaSecAppGroup.protectionNotificationRouteUserInfoKey:
                LavaSecAppGroup.protectionNotificationGuardRouteValue
        ]
        // One rolling banner per category (stable id ⇒ a newer switch replaces the prior banner rather
        // than stacking) — quiet, and always shows the latest state.
        let requestIdentifier = LavaSecAppGroup.eventNotificationRequestIdentifierPrefix + category.rawValue

        await LavaEventNotificationPoster.post(
            category: category,
            requestIdentifier: requestIdentifier,
            title: "Lava",
            body: body,
            userInfo: userInfo,
            defaults: defaults
        )
    }
}
