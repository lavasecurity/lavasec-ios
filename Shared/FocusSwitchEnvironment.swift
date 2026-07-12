import Foundation
import LavaSecFilterPipeline
import LavaSecKit

/// Builds the `LavaSecFilterPipeline.HeadlessFocusFilterSwitchEngine.Environment` from the App Group constants.
///
/// Lives in `Shared/` so the app target AND the App Intents extension construct a BYTE-IDENTICAL
/// environment — same container files, same publish + focus-switch locks, same shared defaults — and can
/// never drift on the paths the engine writes (LAV-100 Phase 4). `LavaSecAppGroup` is module-internal to
/// each target that compiles it, which is why the environment is assembled here rather than inside
/// LavaSecFilterPipeline (which deliberately holds no App Group identifier).
enum FocusSwitchEnvironment {
    /// The warm-reuse cache freshness window. Mirrors `AppViewModel.catalogSyncFreshnessInterval`; a
    /// stale cache makes warm reuse fall back to the network-first cold path.
    static let catalogSyncFreshnessInterval: TimeInterval = 7 * 24 * 60 * 60

    /// How a headless switch's outcome reaches the user, chosen PER CALLER. The caller's own feedback
    /// channel is the only reliable discriminator: AppIntents does not expose the runtime context
    /// (Siri voice vs Shortcuts-app run vs silent automation) to `perform()`, so a runtime toggle
    /// cannot be built — but each call SITE knows statically whether the system delivers feedback
    /// for it (Codex #325 double-notify).
    enum OutcomeFeedback {
        /// The caller has NO feedback channel of its own — the Focus extension returns no dialog, and
        /// iOS can defer its launch ~5–7 min for a suspended app — so the engine's closed-app banner
        /// is the user's only signal (and the deferral mitigation). Foreground suppression unchanged.
        case closedAppBanner
        /// The SYSTEM owns feedback for this caller (the Shortcuts/Siri intent): Siri speaks the
        /// returned dialog, the Shortcuts app displays it, and a THROWN error is surfaced by Shortcuts
        /// itself — including its failure notification for silent automations. The engine banner would
        /// double-notify every one of those, so the notify hook stays the engine's default no-op.
        case systemOwnedDialog
    }

    /// Build the environment and drive the shared engine. The single entry point used by BOTH the App
    /// Intents extension's `perform()` and the app-target Shortcuts intent, so they can't drift on
    /// anything except the one thing that legitimately differs — who reports the outcome (`feedback`).
    /// Returns `.disallowed` when the App Group container is unavailable.
    @discardableResult
    static func performSwitch(
        toFilterID filterID: String,
        feedback: OutcomeFeedback
    ) async -> HeadlessFocusSwitchOutcome {
        guard let env = make(feedback: feedback) else { return .disallowed }
        return await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: filterID, env: env)
    }

    // The Focus-off (nil-filter) edge is a pure no-op — see LavaFocusFilterIntent.perform() and the engine's
    // note on why the off-edge cannot safely cancel a marker (it carries no Focus identity). No entry here.

    /// `nil` when the App Group container is unavailable (the engine caller then reports `.disallowed`).
    static func make(feedback: OutcomeFeedback) -> HeadlessFocusFilterSwitchEngine.Environment? {
        guard let containerURL = LavaSecAppGroup.containerURL else { return nil }
        // The banner hook is wired ONLY for the `.closedAppBanner` caller (Focus extension); a
        // `.systemOwnedDialog` caller keeps the engine's default no-op notify — the system delivers
        // that caller's dialog/error, and a banner on top would double-notify (Codex #325).
        // (Explicitly typed: the two closure literals don't unify under ternary inference.)
        let notify: @Sendable (Bool, String) async -> Void = switch feedback {
        case .closedAppBanner: { await notifySwitchOutcome(committed: $0, filterName: $1) }
        case .systemOwnedDialog: { _, _ in }
        }
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
            notifySwitchOutcome: notify
        )
    }

    /// Post the user-facing "Switched to <name>" / "Couldn't switch to <name>" notification for a headless
    /// Focus switch — the `.closedAppBanner` caller only (see `OutcomeFeedback`), and CLOSED/BACKGROUNDED
    /// ONLY. A foreground app shows the switch in its UI, so we skip the
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
        guard !defaults.bool(forKey: LavaSecAppGroup.appForegroundActiveDefaultsKeyName) else { return }

        let category: LavaNotificationCategory = committed ? .filterChanged : .filterCouldNotApply
        // Localized in LavaSecKit (Bundle.module) so it resolves in the extension's bundle too. The pinned
        // app language (published by the app on foreground) makes the extension render in the SAME language
        // as the app UI — the extension process does not inherit the app's iOS per-app language override.
        let languageCode = LavaNotificationLanguage.pinnedCode(in: defaults)
        let body = LavaEventNotificationPoster.filterSwitchBody(
            committed: committed,
            filterName: filterName,
            languageCode: languageCode
        )
        let userInfo = [
            LavaSecAppGroup.protectionNotificationRouteUserInfoKeyName:
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
