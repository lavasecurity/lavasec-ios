# iOS Accessibility — Device QA Checklist

Execution handoff for the on-device / on-simulator verification that closes out both accessibility plans. Every code change they track is **merged**; what remains is human verification on real settings, which no source guardrail can prove.

- **Assistive-navigation plan** — VoiceOver, Voice Control, Differentiate Without Color. Spine: [`ios-assistive-navigation-audit.md`](./ios-assistive-navigation-audit.md). This checklist *is* plan **Task 8** (device verification pass).
- **Visual-accessibility plan** — Larger Text, Sufficient Contrast, Reduced Motion, Dark Interface. Spine: [`ios-visual-accessibility-audit.md`](./ios-visual-accessibility-audit.md). This checklist *is* plan **Task 5/6** (device/simulator gate).

> **Why a human has to do this.** The source-introspection guardrail suites (`AccessibilityLargeTextSourceTests`, `ColorContrastSourceTests`, `AccessibilityReducedMotionSourceTests`, `TypographyScaleSourceTests`, the VoiceOver/Voice-Control/DWC pins) prove the *fix shape is present in source* and lock it against regression. They cannot prove what a VoiceOver user *hears*, that a pill doesn't clip at `AX5`, or that a cue survives grayscale. That is this document.

---

## Before you start

### What you need
- A **physical iPhone** for the full pass. **Voice Control cannot run in the Simulator** — its rows are device-only. Larger Text, Reduced Motion, Contrast, and Dark can be exercised in the Simulator, but a device is preferred (real VoiceOver rotor, real Dynamic Type steps, real system tint).
- A build from `main` at or after `d644e85` (the merge of visual Task 2).
- Two people or two sessions help: one to drive, one to record — VoiceOver + Voice Control passes are slow.

### Enabling each mode

| Mode | Where | Notes |
|---|---|---|
| **VoiceOver** | Settings → Accessibility → VoiceOver (or triple-click side button if set as the Accessibility Shortcut) | Learn the rotor + two-finger swipe-up "read from top". |
| **Voice Control** | Settings → Accessibility → Voice Control → **Show Names** (also enable *Show Numbers*/*Show Grid* as fallbacks) | **Device only.** "Show Names" overlays the spoken name on every control — that overlay is what you verify. |
| **Differentiate Without Color** | Settings → Accessibility → Display & Text Size → **Differentiate Without Color** (ON). Also test **Color Filters → Grayscale**, and iterate the **Protanopia / Deuteranopia / Tritanopia** filters | Grayscale is the strictest single check; run the three CVD sims for confidence. |
| **Larger Text** | Settings → Accessibility → Display & Text Size → **Larger Text** → enable *Larger Accessibility Sizes* → drag to **maximum (AX5)** | Test at AX5; spot-check the default and one mid step for "invisible at default" regressions. |
| **Reduced Motion** | Settings → Accessibility → Motion → **Reduce Motion** (ON) | Toggle mid-flow to compare motion on/off. |
| **Dark Interface** | System: Settings → Display & Brightness → **Dark**. In-app theme override: Lava → **Settings → Customization → Appearance** (`CustomizationSettingsView`). | Verify both the system switch and the in-app override. |

### Result legend
`Pending` · `Pass (YYYY-MM-DD, @handle)` · `Fail — <note>` · `N/A — <why>`

Record the result **in the row**, and capture a screenshot for every Larger-Text (AX5) and each light/dark contrast check. Attach captures alongside this file or in the verification log at the bottom.

### The six dimensions — what "pass" means

1. **VoiceOver** — every control is reachable, has a meaningful label, and its *state/value* is spoken (not just its name). Order of focus is logical. Transitions (protection on↔off, clear-success, save) are **announced**. Modal focus lands inside sheets and returns on dismiss.
2. **Voice Control** — with *Show Names* on, every actionable control shows a **speakable, unique** name matching its visible text (or a sensible alias). No two targets share a name on screen. Icon-only controls expose an input label.
3. **Differentiate Without Color** — no meaning is carried by hue alone. State/selection/warnings read via **text, glyph, shape, or position** in grayscale and under protan/deutan/tritan.
4. **Larger Text** — at **AX5**, launch-critical text **reflows/wraps or grows** instead of truncating or clipping; nothing critical is cut off; tap targets stay ≥44 pt; and at the **default** size the screen looks **identical** to before (the min-height changes must be invisible).
5. **Reduced Motion** — perceptible movement (slides, `matchedGeometryEffect`, expand/collapse, animated scroll, press-scale) becomes instant or a plain fade. Nothing slides across the screen. Essential cross-fades are allowed.
6. **Dark Interface** — every screen is fully themed in dark (no light-mode leak), text stays legible, and the retinted contrast tokens still pass. Test system-dark **and** the in-app theme override.

---

## Per-screen checklist

Each row: verify the described behavior, then set the **Result**. Code references name the **view / token** (stable) plus an *approximate* line number (as of the `main` merge); if a line has drifted, the named symbol is authoritative. Contrast targets are split by kind — **text 4.5:1** vs **non-text affordance (icon / fill / border) 3:1**.

### 1 · Onboarding — `OnboardingFlowView.swift`
**Task:** complete onboarding on the default protection path (also enter "Import a filter" → §9).

| Dimension | Verify | Result |
|---|---|---|
| VoiceOver | Each page header announced; progress reads **"Step X of Y"** (not "dot dot dot"); feature/status cards read their meaning as text; primary CTA states its **action**. | Pending |
| Voice Control | "Back", "Import a filter", and the CTA are addressable by their **visible text**. | Pending |
| Diff. w/o Color | Progress + current step are conveyed by **text**, not the fill color of the dots. | Pending |
| Larger Text (AX5) | Page **headline wraps** (no shrink-to-one-line); primary + secondary **CTA labels wrap** and the buttons grow (min-height 52, still ≥44 pt). Default size unchanged. | Pending |
| Reduced Motion | Segment-control selection does **not slide** (`matchedGeometryEffect` gated); encrypted-fallback section expand/collapse is instant/fade. | Pending |
| Contrast | **Text (4.5:1):** white on `safeControlGreen` CTAs (`OnboardingFlowView.swift` ~`:761,918,1196`), `panelActionGreen` text (~`:1212,1303`), and the destructive **"Delete my Lava account" title** rendered in `.red` (`OnboardingAccountActionRow` `titleTint`, ~`:1042`) — check the `.red` especially in **light** mode. **Non-text (3:1):** that row's red `trash` icon, and confirm **no text sits on** the decorative `LinearGradient` (~`:1335`). Light + dark. | Pending |
| Dark | Fully themed; hero gradient art still legible; retinted accents correct. | Pending |

### 2 · Guard (protection on/off + read state) — `GuardView.swift`
**Task:** turn protection on and off; read status, resolver, and recent-activity summary.

| Dimension | Verify | Result |
|---|---|---|
| VoiceOver | Status reads e.g. **"Protection status: On, Device DNS"** / "Off"; the primary button announces its action; the **on↔off transition is announced**; status panel + resolver card + metric blocks read in a coherent grouped order. | Pending |
| Voice Control | "Turn On" / "Turn Off" work; **pause options** are reachable as actions (long-press menu). | Pending |
| Diff. w/o Color | Protection state carried by **title/subtitle text + symbol**, not the mascot color alone; metric/state meaning in text, not tint. | Pending |
| Larger Text (AX5) | Protection **title wraps**; **"Long-press for pause options"** hint wraps; primary-action label **grows** (min-height, no clip). | Pending |
| Reduced Motion | Guard message cross-fade OK (allowed); button **press-scale** gated (no bounce). | Pending |
| Contrast | Orange-as-text at the status detail (`GuardView.swift:96`) uses `lavaOrangeText` — legible on its background, light + dark. | Pending |
| Dark | Fully themed; status tints correct both modes. | Pending |

### 3 · Filters — `FiltersView.swift`
**Task:** open Filters, inspect enabled lists, change a filter selection, add/remove a blocklist.

| Dimension | Verify | Result |
|---|---|---|
| VoiceOver | Each row reads **name + enabled/disabled value**; a selection change is **announced**; add/remove outcomes spoken. | Pending |
| Voice Control | Row names are **unique** and match visible text; "Confirm", "Save" addressable. | Pending |
| Diff. w/o Color | Checkmark / toggle state / count legible in **grayscale**; the **selected category pill** reads as selected via more than hue. | Pending |
| Larger Text (AX5) | Row titles (15 pt `rowTitle`) and blocklist-picker rows scale; category **jump-pill grows** in its scroller without clipping. | Pending |
| Reduced Motion | Category jump-pill **animated scroll** gated (no glide). *(Usage-bar fill + preview are known low-severity follow-ups — note if perceptible.)* | Pending |
| Contrast | Selected pill = **white on `lavaOrangeSelectedFill`** (≈4.82:1 light / 5.64:1 dark); orange-as-text sites use `lavaOrangeText`. Verify both modes. | Pending |
| Dark | Fully themed; all retinted orange text/fills correct. | Pending |

### 4 · Settings → DNS Resolver / Fallback — `SettingsView.swift · DNSResolverSettingsView`
**Task:** open DNS resolver / fallback settings; understand and change the selected provider.

| Dimension | Verify | Result |
|---|---|---|
| VoiceOver | Provider reads **name + "selected"**; warnings read as **text**. | Pending |
| Voice Control | Provider names + "Custom" addressable. | Pending |
| Diff. w/o Color | Selected state + warnings carried by **text + icon**, not orange/red only. | Pending |
| Larger Text (AX5) | Resolver preset rows and the **custom-DNS row** (now semibold 15 pt, matching siblings) scale without truncation. | Pending |
| Reduced Motion | Any fallback expand/collapse is instant/fade. | Pending |
| Contrast | The DNS screen's own pairs (`DNSResolverSettingsView`, `SettingsView.swift:2150`): provider / custom-resolver rows (`ResolverPresetRowContent`, selectable-row states ~`:2245-2338`), the custom-resolver **Save button** (white on `safeControlGreen`, `CustomResolverSaveButtonStyle` `:3183,3190`), and the validation warning panel (`DomainRejectPanel`) all clear 4.5:1 text / 3:1 non-text, light + dark. | Pending |
| Dark | Fully themed both modes. | Pending |

### 5 · Settings → Privacy & Data — `SettingsView.swift · privacy subpage`
**Task:** open Privacy & Data; clear local logs/counts through the confirmation alert.

| Dimension | Verify | Result |
|---|---|---|
| VoiceOver | Count labels read; **clear-success is announced**; the confirm-alert takes focus, and focus returns on dismiss. | Pending |
| Voice Control | "Clear" + confirm/cancel addressable by visible text. | Pending |
| Diff. w/o Color | Counts + state read as text. | Pending |
| Larger Text (AX5) | Buttons/labels grow; nothing clips. | Pending |
| Reduced Motion | No incidental motion regressions. | Pending |
| Contrast | On the Privacy & Data subpage (`PrivacyDataSettingsView`, `SettingsView.swift:3348`): the log-export **error text** (`.red`, `:3400`) plus the clear-action controls / counts / status tints clear 4.5:1 text / 3:1 non-text, light + dark. | Pending |
| Dark | Fully themed both modes. | Pending |

### 6 · Backup / Account — `BackupSetupView.swift` / `BackupRestoreView.swift`
**Task:** start account/backup setup and back out safely; open restore.

| Dimension | Verify | Result |
|---|---|---|
| VoiceOver | Controls labeled; **signed-in/out + status spoken**; safe back-out with **restored focus**. | Pending |
| Voice Control | Setup step names + "Back", "Cancel" addressable. | Pending |
| Diff. w/o Color | State conveyed by text. | Pending |
| Larger Text (AX5) | Nav title / step title **wrap** (centered between spacers); CTAs grow. | Pending |
| Reduced Motion | Backup setup choreography softens to fade (already routed through `LavaFlowTransition`). | Pending |
| Contrast | The error-message **text** uses `lavaOrangeText` (`BackupSetupView.swift` `Text(errorMessage)` ~`:162,183,257`), 4.5:1, light + dark. | Pending |
| Dark | Fully themed both modes. | Pending |

### 7 · Support / Bug Report — `SettingsView.swift · feedback / bug-report subpage`
**Task:** open Support or bug report; understand what will be sent; send.

| Dimension | Verify | Result |
|---|---|---|
| VoiceOver | Topic reads **"selected"**; the **"what will be sent" summary** is grouped and readable; "Send" labeled. | Pending |
| Voice Control | Topic names + "Send" addressable. | Pending |
| Diff. w/o Color | Selected topic + step by text, not tint only. | Pending |
| Larger Text (AX5) | Labels/summary wrap; nothing clips. | Pending |
| Reduced Motion | No incidental motion regressions. | Pending |
| Contrast | All rendered text (topic labels, "what will be sent" summary, Send) and any selected-topic / danger tint clear 4.5:1 text / 3:1 non-text, light + dark. | Pending |
| Dark | Fully themed both modes. | Pending |

### 8 · Activity / Reports — `DiagnosticsView.swift`
**Task:** open Activity, read the metrics, change the date range.

| Dimension | Verify | Result |
|---|---|---|
| VoiceOver | Metric rows read **label + value** grouped; the date range is readable; "Change Activity dates" reachable. | Pending |
| Voice Control | The date pill reads **"Change Activity dates"**; picker controls addressable. | Pending |
| Diff. w/o Color | The warning theme pill reads via **text + icon**, not orange alone. | Pending |
| Larger Text (AX5) | Metric row **relaxes to two lines** (keeps gentle shrink); date **endpoint tiles reflow** (grow via min-height). The **date-range pill in the nav bar stays compact one line and shrinks-to-fit — confirm it does NOT clip or collide** (it is a toolbar title accessory and intentionally does not reflow; the full range is reachable in the picker sheet). | Pending |
| Reduced Motion | Press-scales on the date controls gated / imperceptible. | Pending |
| Contrast | **Text (4.5:1):** the warning-activity pill text uses `lavaOrangeText` (`NetworkActivityTheme.tint`, `DiagnosticsView.swift` ~`:611,665`) on its `lavaOrangeSoft` fill (~`:676`). **Non-text (3:1):** blocked-state SF Symbol **glyphs** stay on `lavaOrange` — `rowIconColor` (~`:1358,1397`) and the `TopDomainRow` icon (~`:1572`) — verify as affordances, not text. Both modes. | Pending |
| Dark | Fully themed both modes. | Pending |

### 9 · Filter review flow *(Task-7 surface)* — `FilterReviewFlowView.swift`
Reached from Onboarding "Import a filter" (§1) and Filters (§3).

| Dimension | Verify | Result |
|---|---|---|
| VoiceOver | Review controls labeled; **outcome** (added / skipped / error) spoken. | Pending |
| Voice Control | Review actions addressable by visible text. | Pending |
| Diff. w/o Color | Include/exclude/added state by text + glyph, not tint. | Pending |
| Larger Text (AX5) | Review rows scale; nothing clips. | Pending |
| Reduced Motion | The preparation ticker (`PreparationTickerTitle` in `FilterReviewFlowView.swift`) softens to fade / instant under Reduce Motion (routes through `LavaFlowTransition`) — no visible ticker motion. The audit names Filter review as a reduce-motion-consuming surface. | Pending |
| Contrast | General review **text** clears 4.5:1. **Non-text (3:1):** the removed-item "−" indicator (`lavaOrange`, `FilterReviewFlowView.swift` ~`:132`) and the decorative hero result glyph (`Image`, ~`:222`, `.accessibilityHidden`) — verify as affordances. Both modes. | Pending |
| Dark | Fully themed both modes. | Pending |

### 10 · Live Activity / Widget / Dynamic Island *(Task-7 surface)* — `LavaLiveActivityController.swift` / `LavaSecWidget` / `LavaLiveActivityIntents.swift`
Lock Screen + Dynamic Island (always-on protection).

| Dimension | Verify | Result |
|---|---|---|
| VoiceOver | Protection **state readable**; the **pause control is operable** from the Lock Screen / island. | Pending |
| Voice Control | *(Not testable on the Lock Screen — note the pause intent name for the in-app control.)* | N/A — Lock Screen |
| Diff. w/o Color | Protection state by **text/glyph**, not color fill alone. | Pending |
| Larger Text | Widget respects the system size within its fixed frame; no critical clipping. | Pending |
| Reduced Motion | The widget adds no app-driven animation (no `withAnimation`/`.animation` in `LavaSecWidget.swift`); Live Activity content transitions are system-driven and honor the system setting. | N/A — no app-driven motion |
| Contrast | Widget / Live-Activity title (`LavaSecWidget.swift:139`) + action labels (`:253,276,291`) and their tints clear 4.5:1 text / 3:1 non-text on both Lock Screen appearances (light + dark). | Pending |
| Dark | Legible on both Lock Screen appearances. | Pending |

---

## App Store label gates

**No label may be marked "Yes" in App Store Connect until every row it depends on reads `Pass`.**

| Label | Passes when | Depends on |
|---|---|---|
| **VoiceOver** | every *VoiceOver* row above passes on a device | §1–§10 |
| **Voice Control** | every *Voice Control* row passes on a **device** "Show Names" pass | §1–§9 |
| **Differentiate Without Color Alone** | every *Diff. w/o Color* row passes in grayscale **and** protan/deutan/tritan | §1–§10 |
| **Larger Text** | every *Larger Text (AX5)* row passes, and default-size appearance is unchanged | §1–§9 (widget §10 within-frame) |
| **Sufficient Contrast** | every *Contrast* row passes at 4.5:1 text / 3:1 non-text, **light + dark** | §1–§10 (every surface with rendered UI text — the audit's 8-screen Task 6 Contrast column, the filter-review surface, **and** the widget / Live-Activity title + action labels) |
| **Reduced Motion** | every *Reduced Motion* row passes (no perceptible movement) | §1–§9 (incl. the filter-review ticker; §10 widget is N/A — no app-driven motion) |
| **Dark Interface** | every *Dark* row passes both system-dark and in-app theme | §1–§10 (preserve existing pass) |

Do **not** claim Captions or Audio Descriptions — Lava ships no dialogue/video in these flows.

---

## Sign-off log

| Date | Label(s) | Screens covered | Device / iOS | Tester | Notes |
|------|----------|-----------------|--------------|--------|-------|
| — | — | — | — | — | Populate as passes complete. One entry per session; link screenshots. |

When a full column is green, update the matching row in the two audit docs (`ios-assistive-navigation-audit.md` "Verification log" and `ios-visual-accessibility-audit.md` "Verification matrix"), then flip the App Store Connect label.
