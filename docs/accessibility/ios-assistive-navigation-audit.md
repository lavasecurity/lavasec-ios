# iOS Assistive Navigation — Accessibility Audit Map

> Spine for the plan **iOS Assistive Navigation Accessibility Readiness**
> (`lavasec-infra: plans/backlog/2026-07-04-ios-assistive-navigation-accessibility-plan.md`,
> sized in `plans/reviews/2026-07-04-ios-assistive-navigation-accessibility-work-breakdown.md`).
> One row per covered common task. **No App Store label may be marked "Yes" until every row for that
> label reads `Pass` with a date + tester.**

## App Store label targets

| Label | Target | Gate |
|-------|--------|------|
| VoiceOver | Yes | Every row's *Spoken outcome* verified on a **device** VoiceOver pass. |
| Voice Control | Yes | Every row's *Voice Control names* verified on a **device** "Show Names" pass (the Simulator cannot run Voice Control). |
| Differentiate Without Color Alone | Yes | Every row's *Non-color cue* verified in grayscale **and** a protan/deutan/tritan simulation. |

Do **not** claim Captions or Audio Descriptions — Lava ships no dialogue/video content in these flows.

Result legend: `Pending` (not yet verified) · `Pass (YYYY-MM-DD, @handle)` · `Fail — <note>`.

## Covered common tasks

| # | Screen (file · view) | Task | Primary controls | Spoken outcome (VoiceOver) | Voice Control names | Non-color cue | Result |
|---|----------------------|------|------------------|----------------------------|---------------------|---------------|--------|
| 1 | Onboarding (`OnboardingFlowView.swift` · `LavaOnboardingView`) | Complete onboarding with the default protection path | Page headers, progress dots, feature/status cards, Back, "Import a filter", primary CTA | Each page header announced; "Step X of Y"; card meaning as text; CTA states its action | "Back", "Import a filter", CTA visible text | Progress + current step conveyed by text, not the fill color | Pending |
| 2 | Guard (`GuardView.swift` · `ProtectionStatusPanel` / `ProtectionPrimaryActionButton`) | Turn Lava protection on and off | Status summary, primary action button, pause context menu, mascot | "Protection status: On, Device DNS" / "Off"; button announces action; on/off transition announced | "Turn On"/"Turn Off"; pause options reachable as actions | Status carried by title/subtitle text + symbol, not mascot color alone | Pending |
| 3 | Guard (`GuardView.swift` · `GuardExploreSection` + resolver/metric cards) | Read protection state, resolver state, recent activity summary | Status panel, resolver card, "Learn more" rows, metric blocks | Title + value + state read in a coherent grouped order | Row/label visible text | Metric/state meaning in text, not tint alone | Pending |
| 4 | Filters (`FiltersView.swift` · `AllFiltersView` / `FilterLibraryRow` / `MyListCover`) | Open Filters, inspect enabled lists, change a filter selection | Filter rows, enabled/disabled toggles, add/remove, selection | Row name + enabled/disabled value; selection change announced | Unique per-row names; "Confirm", "Save" | Checkmark / toggle state / count, legible in grayscale | Pending |
| 5 | Settings → DNS (`SettingsView.swift` · `DNSResolverSettingsView` / `ResolverPresetRowContent`) | Open DNS Resolver / fallback settings, understand the selected provider | Provider list, fallback toggle, warnings | Provider name + "selected" value; warning read as text | Provider names; "Custom" | Selected state + warnings as text + icon, not orange/red only | Pending |
| 6 | Settings → Privacy & Data (`SettingsView.swift` · privacy subpage) | Open Privacy & Data, clear local logs or counts | Clear buttons, confirmation alert, counts | Count labels; clear-success announced; confirm-alert focus lands | "Clear"; confirm/cancel visible text | Counts + state as text | Pending |
| 7 | Backup (`BackupSetupView.swift` / `BackupRestoreView.swift`) | Start account/backup setup and back out safely | Setup/restore controls, signed-in state, back/dismiss | Controls labeled; signed-in/out + status spoken; safe back-out with restored focus | Setup step names; "Back", "Cancel" | State conveyed by text | Pending |
| 8 | Support / Bug report (`SettingsView.swift` · feedback / bug-report subpage) | Open Support or bug report, understand what will be sent | Topic selector, payload summary, send | Topic "selected"; "what will be sent" summary grouped + readable | Topic names; "Send" | Selected topic + step by text, not tint only | Pending |

## Task 7 surfaces routed into by the tasks above

These are near-zero on accessibility today and are covered by plan **Task 7** (with the shared primitives from Task 6).

| Screen (file) | Reached from | Needs | Result |
|---------------|--------------|-------|--------|
| `FilterReviewFlowView.swift` | Onboarding "Import a filter" (task 1), Filters (task 4) | Labeled review controls + outcomes | Pending |
| `LavaLiveActivityController.swift` / `LavaSecWidget` / `LavaLiveActivityIntents.swift` | Lock Screen / Dynamic Island (always-on protection) | Readable state + operable pause control | Pending |

## Verification log

| Date | Label(s) | Pass covered | Tester | Notes |
|------|----------|--------------|--------|-------|
| — | — | — | — | Populate as device passes are completed (plan Task 8). |
