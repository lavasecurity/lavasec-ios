import AppIntents
import Foundation

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
// `.systemOwnedDialog`, so the engine's closed-app banner stays OFF — the system (Siri/Shortcuts) delivers
// this intent's dialog and errors in every context, and the banner would double-notify (Codex #325; see
// `FocusSwitchEnvironment.OutcomeFeedback`). This intent is a thin front-end that maps the engine's
// outcome to a spoken/printed dialog — it adds NO switch logic of its own.
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
        // `.systemOwnedDialog`: the SYSTEM delivers this intent's feedback in every context — Siri speaks
        // the returned dialog, the Shortcuts app displays it, and the thrown `.disallowed` error below is
        // surfaced by Shortcuts itself (including its failure notification when a silent automation errors)
        // — so the engine's closed-app banner is suppressed for this caller; keeping it would double-notify
        // a backgrounded Siri/Shortcuts run (Codex #325). A committed switch from a SILENT automation is
        // deliberately silent: the user authored the automation, and Shortcuts' own "Notify When Run"
        // toggle is the platform affordance for run receipts. The Focus extension keeps the banner — that
        // path has no dialog and lives with the deferred-launch gap (see `OutcomeFeedback`).
        let outcome = await FocusSwitchEnvironment.performSwitch(
            toFilterID: filter.id,
            feedback: .systemOwnedDialog
        )

        // Map the engine's outcome to a localized dialog. The filter name is bound through
        // `LocalizedStringResource` interpolation → each String Catalog key carries a `%@` placeholder
        // (LavaSecApp/Localizable.xcstrings, all 10 locales; resolved from the APP bundle, since this intent
        // is app-target). "Lava" is the brand name and stays untranslated in every locale (guard-tab/brand
        // rule).
        let dialog: IntentDialog
        switch outcome {
        case .committed:
            dialog = IntentDialog(LocalizedStringResource("Switched to \(filter.name)."))
        case .alreadyActive:
            dialog = IntentDialog(LocalizedStringResource("\(filter.name) is already your active filter."))
        case .deferred:
            // The headless path only commits a WARM switch; with no reusable warm artifact (new filter,
            // stale catalog, cache miss) the engine records a durable pending marker and defers. That marker
            // is drained ONLY by the foreground reconcile (AppViewModel/RootView) — the tunnel poll never
            // cold-compiles it, and an App Intent's short window can't either — so a switch run while Lava
            // stays closed applies on the NEXT app open, not "shortly". Say so honestly (Codex #325); the
            // switch itself is the same tolerated, self-healing deferral the Focus path already carries.
            dialog = IntentDialog(LocalizedStringResource("\(filter.name) will apply the next time you open Lava."))
        case .disallowed:
            // Auth-to-edit gate on (or the impossible container-unavailable case). A headless intent can't
            // prompt for auth, so the engine safely no-ops — and the switch DID NOT HAPPEN, so this is an
            // ERROR, not a result: throwing halts any downstream shortcut actions that assumed the switch,
            // Siri speaks the message, the Shortcuts app displays it, and a failed silent automation is
            // reported by Shortcuts' own failure notification — which is what preserves failure feedback
            // with the engine banner suppressed for this caller (Codex #325).
            throw SwitchFilterDisallowedError(filterName: filter.name)
        }
        return .result(dialog: dialog)
    }
}

/// `.disallowed` surfaced the AppIntents-idiomatic way: a thrown, localized error. Reuses the SAME String
/// Catalog key the old disallowed dialog used (all 10 locales, `%@` placeholder), so no new translation.
struct SwitchFilterDisallowedError: Error, CustomLocalizedStringResourceConvertible {
    let filterName: String
    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource("Couldn't switch to \(filterName). Open Lava to check your filter settings.")
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
