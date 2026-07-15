import AppIntents
import Foundation
import LavaSecKit

// MARK: - Switch Filter App Intent (Shortcuts / Automations / Siri)
//
// The user-driven twin of `LavaFocusFilterIntent`. Where the Focus intent is configured hands-free under
// Settings › Focus, THIS intent is DISCOVERABLE — it shows up as a "Switch Filter" action in Shortcuts,
// in Automations, and to Siri — so a person (or a time/location automation they build) can switch the
// active Lava filter on demand. SWITCHING ONLY: there is deliberately no pause/resume or any other intent
// here (founder decision) — protection on/off stays a device-global control the user drives in-app.
//
// WHY THIS INTENT IS IN THE APP TARGET (not the LavaSecIntents extension, where `LavaFocusFilterIntent`
// lives): App Shortcuts and the `AppShortcutsProvider` register from the MAIN APP bundle — iOS discovers
// them from the app's `Metadata.appintents`, not an app extension's, so a provider compiled only into the
// extension will not reliably surface the Siri/Shortcuts-gallery action. A plain `AppIntent` also does not
// need the extension to run closed-app: for an automation fired while Lava is closed, iOS background-
// launches the APP to run a non-UI `AppIntent` (`openAppWhenRun == false`). By contrast, a
// `SetFocusFilterIntent` genuinely requires the extension — the system runs Focus-filter `perform()` in the
// APP process only while the app is foregrounded (WWDC22 §10121), so hands-free Focus switching while Lava
// is closed is only possible from the background-launched extension. Hence: Focus intent → extension;
// Shortcuts/Siri switch intent → app. Both drive the SAME shared engine, so behavior is identical.
//
// Everything load-bearing is REUSED, not re-implemented: the switch semantics, the single security gate
// (auth-to-edit — enforced ONLY inside the engine, the one security boundary), the cross-process
// generation CAS + flock, the warm-only commit, the durable pending-switch marker, and the Release-visible
// FocusSwitchDiagnostics ALL come from the shared LavaSecFilterPipeline headless engine reached through
// `FocusSwitchEnvironment.performSwitch` (LAV-100 Phase 4 lineage; the same `Shared/` factory the
// extension uses). The ONE deliberate divergence from the Focus path is feedback: this caller passes
// `.systemOwnedDialog` — the system (Siri/Shortcuts) delivers this intent's dialog and errors in every
// context, so FAILURES post no engine banner (Shortcuts surfaces the thrown error itself, including its
// failure notification for silent automations; a banner would double-report — Codex #325). A COMMITTED
// switch posts the engine hook's closed/backgrounded-only banner under the SAME `filterChanged`
// category/toggle as the Focus path (one user-visible event, one "Filter changes" row — founder
// 2026-07-12): a silent automation displays no dialog, so that banner is its only success signal (see
// `FocusSwitchEnvironment.OutcomeFeedback`). This intent stays a thin front-end that maps the engine's
// outcome to a spoken/printed dialog — it adds NO switch logic and NO notification posting of its own.
//
// A headless intent cannot prompt for authentication, so when the auth-to-edit gate is on the engine
// returns `.disallowed` and we report a "open Lava" dialog — a safe no-op, never a partial or
// unauthenticated change (same contract as the Focus path).

/// Switches the active Lava filter to a chosen saved filter, on demand from Shortcuts, an Automation, or Siri.
///
/// Discoverable (unlike `LavaFocusFilterIntent`) so it appears as a "Switch Filter" action. Runs headless
/// (`openAppWhenRun == false`) — the shared engine performs the switch and the system-delivered dialog
/// (or thrown error) is the user's feedback in every context, so the app is never brought to the
/// foreground just to switch a filter. Lives in the APP target because App Shortcuts register from the
/// app bundle; see the file header for the full app-vs-extension rationale.
struct SwitchFilterIntent: AppIntent {
    // `nonisolated(unsafe) static var` metadata bindings, matching `LavaFocusFilterIntent` EXACTLY — the
    // AppIntents metadata processor records these from mutable statics, and the #142 const-value-protocols
    // gotcha is about the AppEntity QUERY link (const bindings), not these title/description statics. The
    // held values are Sendable literals, so `unsafe` is sound under Swift 6 (no shared mutable state races).
    nonisolated(unsafe) static var title: LocalizedStringResource = "Switch Filter"
    nonisolated(unsafe) static var description = IntentDescription(
        "Switch your active Lava filter to a saved filter you choose."
    )
    // The OPPOSITE of the Focus intent: DISCOVERABLE, so Shortcuts / Automations / Siri surface it.
    nonisolated(unsafe) static var isDiscoverable = true
    // Headless: the engine + dialog/banner are the whole interaction; never foreground the app to switch.
    nonisolated(unsafe) static var openAppWhenRun = false

    // NON-OPTIONAL — the opposite of the Focus intent's optional parameter. Shortcuts/automations/Siri
    // ALWAYS supply a value; only `LavaFocusFilterIntent`'s deactivation edge needed the nil-means-off
    // distinction (see its file header). REUSES `LavaFilterEntity` + its `LavaFilterEntityQuery` from
    // `Shared/LavaFilterEntity.swift` — the SAME shared entity/query the Focus intent uses (no duplicate).
    @Parameter(title: "Filter")
    var filter: LavaFilterEntity

    init() {}

    static var parameterSummary: some ParameterSummary {
        // Interpolating the parameter KeyPath — appintentsmetadataprocessor lowers `\(\.$filter)` to the
        // catalog token `${filter}`, resolved from the APP bundle (this intent is app-target), so the key
        // "Switch to ${filter}" lives in LavaSecApp/Localizable.xcstrings.
        Summary("Switch to \(\.$filter)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Drive the SAME shared engine any in-app or Focus caller uses — the single gated boundary. We do
        // NOT re-run the gate, the CAS, the flock, or the diagnostics here; `performSwitch` owns all of it.
        //
        // `.systemOwnedDialog`: the SYSTEM delivers this intent's dialog and errors in every context —
        // Siri speaks the returned dialog, the Shortcuts app displays it, and the thrown `.disallowed`
        // error below is surfaced by Shortcuts itself (including its failure notification when a silent
        // automation errors) — so FAILURES post no engine banner for this caller (it would always
        // double-report — Codex #325). A COMMITTED switch posts the engine hook's closed/backgrounded-only
        // banner under the SAME `filterChanged` category as the Focus path (one "Filter changes" toggle —
        // founder 2026-07-12): a silent automation displays no dialog, so that banner is its only success
        // signal — superseding the earlier always-silent stance that pointed users at Shortcuts' "Notify
        // When Run". The Focus extension additionally banners refusals ("Couldn't switch") — that path has
        // no dialog and lives with the deferred-launch gap (see `OutcomeFeedback`).
        let outcome = await FocusSwitchEnvironment.performSwitch(
            toFilterID: filter.id,
            feedback: .systemOwnedDialog
        )

        // Map the engine's outcome to a dialog, PRE-RESOLVED in THIS (app) process to the app's pinned UI
        // language — NOT handed to Shortcuts as a bare `LocalizedStringResource`. A bare resource is resolved
        // by the SYSTEM at DISPLAY time in the SYSTEM locale, so a user whose app runs in another language
        // (an iOS per-app language override, or a device whose system language differs from the app's) sees
        // this dialog in English while the rest of the app is localized — the Switch-Filter twin of the
        // 2026-07-14 Live Activity "stuck-English" incident (lavasec-infra
        // `plans/2026-07-14-reboot-first-unlock-data-reset-incident-plan.md`, Phase 3). `LavaCoreStrings`
        // resolves the dialog copy from the pinned `.lproj` of `Bundle.module` via the same direct-`.strings`
        // read the committed banner (`FocusSwitchEnvironment.postSwitchBanner`) and the Live Activity use, so
        // the dialog renders in the app's language and stays CONSISTENT with the banner that appears alongside
        // it on an interactive run. The filter name is a `%@` placeholder substituted here; the built-in level
        // names (Core / Balanced / Extra) and "Lava" stay untranslated in every locale (guard-tab/brand rule).
        // pinned: SwitchFilterDialogLocalizationTests.testEveryDialogKeyIsTranslatedInEveryLocaleAndNeverLeaksTheRawKey
        // pinned: FocusFilterIntentWiringSourceTests.testSwitchPerformDrivesSharedEngineAndReturnsDialogWithCommittedOnlyEngineBanner
        //
        // Read the SAME shared pin the banner and Live Activity read — the deliberate single source of truth
        // that keeps every cross-process localized surface mutually consistent. The pin is republished on each
        // post-unlock foreground, so it lags an iOS per-app language change made BEFORE the app is next opened:
        // a switch run in that window renders in the previous language (Codex P2 on #388). That staleness is a
        // property of the pin's refresh cadence — shared by the banner and Live Activity, not dialog-specific —
        // and self-heals on the next foreground; preferring this process's fresher `currentAppLocalization()`
        // for the dialog ALONE would de-sync it from the banner it co-displays with, which is worse. The right
        // fix is to tighten the cadence (republish on a per-app language change), updating all three surfaces
        // together. When the pin is absent (no post-unlock foreground yet) `LavaCoreStrings` falls back to
        // ambient `Bundle.module` resolution — correct in this app process.
        let languageCode = LavaNotificationLanguage.pinnedCode(in: LavaSecAppGroup.sharedDefaults)
        let dialog: IntentDialog
        switch outcome {
        case .committed:
            dialog = IntentDialog(stringLiteral:
                LavaCoreStrings.localizedFormat("dialog.filterSwitchedTo", languageCode: languageCode, filter.name))
        case .alreadyActive:
            dialog = IntentDialog(stringLiteral:
                LavaCoreStrings.localizedFormat("dialog.filterAlreadyActive", languageCode: languageCode, filter.name))
        case .deferred:
            // The headless path only commits a WARM switch; with no reusable warm artifact (new filter,
            // stale catalog, cache miss) the engine records a durable pending marker and defers. That marker
            // is drained ONLY by the foreground reconcile (AppViewModel/RootView) — the tunnel poll never
            // cold-compiles it, and an App Intent's short window can't either — so a switch run while Lava
            // stays closed applies on the NEXT app open, not "shortly". Say so honestly (Codex #325); the
            // switch itself is the same tolerated, self-healing deferral the Focus path already carries.
            dialog = IntentDialog(stringLiteral:
                LavaCoreStrings.localizedFormat("dialog.filterWillApplyNextOpen", languageCode: languageCode, filter.name))
        case .disallowed:
            // Auth-to-edit gate on (or the impossible container-unavailable case). A headless intent can't
            // prompt for auth, so the engine safely no-ops — and the switch DID NOT HAPPEN, so this is an
            // ERROR, not a result: throwing halts any downstream shortcut actions that assumed the switch,
            // Siri speaks the message, the Shortcuts app displays it, and a failed silent automation is
            // reported by Shortcuts' own failure notification — which is what preserves failure feedback
            // with the engine banner suppressed for this caller (Codex #325). The message is pre-resolved
            // HERE (app process) for the SAME reason as the dialogs above — `localizedStringResource` may be
            // read in the Shortcuts process, which is not in the app group and cannot read the pin.
            throw SwitchFilterDisallowedError(
                localizedMessage: LavaCoreStrings.localizedFormat(
                    "dialog.filterSwitchDisallowed", languageCode: languageCode, filter.name))
        }
        return .result(dialog: dialog)
    }
}

/// `.disallowed` surfaced the AppIntents-idiomatic way: a thrown, localized error. The message is resolved
/// to the app's pinned UI language in `perform()` (the app process) and carried here as FINAL text, because
/// AppIntents may read `localizedStringResource` in the Shortcuts process — which is not in the app group and
/// cannot read the language pin, so resolving there would fall back to the system locale (English for an app
/// running in another language), the same defect the outcome dialogs avoid.
struct SwitchFilterDisallowedError: Error, CustomLocalizedStringResourceConvertible {
    /// Already localized to the app's UI language in `perform()`; rendered verbatim.
    let localizedMessage: String
    var localizedStringResource: LocalizedStringResource {
        // The text is final. Wrapping a runtime string as a `LocalizedStringResource` uses it as its own
        // lookup key: the catalog miss falls back to the string itself, so Shortcuts displays the
        // app-language message we already resolved rather than re-localizing it in the system locale.
        LocalizedStringResource(stringLiteral: localizedMessage)
    }
}

// MARK: - App Shortcuts provider (Siri phrases)

/// Registers `SwitchFilterIntent` as an App Shortcut so Siri and the Shortcuts gallery surface it with
/// spoken phrases. Lives in the APP target because App Shortcuts register from the app bundle (see the
/// file header). One shortcut only — switching is the sole intent this app vends (founder decision).
struct LavaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SwitchFilterIntent(),
            phrases: [
                // Every phrase MUST contain `\(.applicationName)` (Apple requirement) and is deliberately
                // NON-parameterized: Siri resolves WHICH filter interactively through
                // `LavaFilterEntityQuery.suggestedEntities()` at run time. A parameterized App Shortcut
                // phrase re-introduces the const-metadata fragility this design avoids (#142 lineage).
                "Switch \(.applicationName) filter",
                "Change my \(.applicationName) filter",
                "Switch filter in \(.applicationName)"
            ],
            shortTitle: "Switch Filter",
            // Reuses the app's filter glyph (LavaIconRole.filters / FiltersView toolbar) so the Shortcuts
            // action reads as "the filter action".
            systemImageName: "line.3.horizontal.decrease.circle"
        )
    }
}
