import AppIntents
import Foundation

// MARK: - Focus filter App Intent (LAV-100 Phase 4)
//
// `SetFocusFilterIntent` is the system mechanism that lets a Focus switch the active Lava filter
// hands-free. The user adds "Lava Filter" under a Focus in Settings › Focus › Focus Filters and picks
// which saved filter to apply; when that Focus turns on, the system runs `perform()`. This intent lives
// in the App Intents EXTENSION (LavaSecIntents), so `perform()` runs even when Lava is fully closed —
// the system background-launches the extension (an app-target intent only runs in the foreground app,
// WWDC22 §10121). perform() drives the shared headless switch engine via
// `FocusSwitchEnvironment.performSwitch` → `HeadlessFocusFilterSwitchEngine`
// (LavaSecFilterPipeline).
//
// perform() runs for BOTH activation and deactivation — the system re-runs it whenever the configured
// parameters change, and there is no explicit on/off signal. We infer the edge from whether the
// (deliberately OPTIONAL) `filter` parameter is set: on activation it carries the chosen filter →
// switch to it; on deactivation it is nil → we intentionally do nothing. A filter is a sticky choice
// (another Focus, or a manual tap, is what changes it next), so there is no "revert on Focus-off".
// Making the parameter optional is REQUIRED: a non-optional parameter is only delivered on activation,
// so the deactivation edge would silently reuse the last value.
//
// The security gate (OFF whenever "require auth to edit filters" is on — Focus auto-switch is available
// to all tiers, no Plus paywall) and every switch semantic live in the engine, reached through
// `FocusSwitchEnvironment.performSwitch`. perform() runs unattended in the background and cannot prompt
// for authentication, so a gated-out switch is a silent no-op — never a partial or unauthenticated change.

struct LavaFocusFilterIntent: SetFocusFilterIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Lava Filter"
    nonisolated(unsafe) static var description = IntentDescription(
        "Switch your active Lava filter automatically when a Focus turns on."
    )
    // Configured in Settings › Focus, not the Shortcuts app. Focus eligibility comes from
    // `SetFocusFilterIntent` conformance, not from discoverability; keeping it out of Shortcuts avoids a
    // stray "run once" action that has no Focus context.
    nonisolated(unsafe) static var isDiscoverable = false

    // OPTIONAL on purpose — see the file header. A nil value is the Focus turning OFF (or no filter
    // chosen yet); we leave the active filter untouched in that case.
    @Parameter(title: "Filter")
    var filter: LavaFilterEntity?

    init() {}

    var displayRepresentation: DisplayRepresentation {
        filter?.displayRepresentation ?? DisplayRepresentation(title: "No filter")
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Switch to \(\.$filter)")
    }

    func perform() async throws -> some IntentResult {
        // Focus turning OFF (or nothing configured): a pure no-op. A filter is a sticky choice (another Focus
        // or a manual tap is what changes it next), so there is no "revert on Focus-off". We also must NOT
        // cancel a still-deferred marker here: perform(nil) carries NO Focus identity, so the off-edge cannot
        // tell WHICH Focus turned off and would risk clearing a DIFFERENT, still-active Focus's just-recorded
        // switch (a lost update). The foreground reconcile's supersession + already-active/target-gone guards
        // drop genuinely-stale markers, and a deferred switch re-applying is the tolerated, self-healing
        // direction (LAV-100 Phase 4 round-5 panel P1).
        guard let filter else {
            return .result()
        }
        // `.closedAppBanner`: a Focus intent returns no dialog and iOS can defer this extension's launch
        // for a suspended app, so the engine's closed-app banner is this path's only user feedback.
        await FocusSwitchEnvironment.performSwitch(toFilterID: filter.id, feedback: .closedAppBanner)
        return .result()
    }
}

// The `LavaFilterEntity` AppEntity + `LavaFilterEntityQuery` moved to `Shared/LavaFilterEntity.swift` so
// the app-target `SwitchFilterIntent` (App Shortcuts register from the app bundle, not this extension) and
// this extension's Focus intent share ONE entity/query — no duplicate AppEntity record across targets.
