# iOS Visual Accessibility Audit

Companion to `docs/accessibility/ios-assistive-navigation-audit.md`. Scope: the iOS app's **visual** accessibility behavior — Larger Text (Dynamic Type), Sufficient Contrast, Reduced Motion, and Dark Interface — for the common-task flows. Tracks the plan `plans/backlog/2026-07-04-ios-visual-accessibility-readiness-plan.md` (lavasec-infra).

## App Store label target

Once every row below passes its Task 6 gate, App Store Connect may mark:

- **Larger Text:** Yes
- **Sufficient Contrast:** Yes
- **Reduced Motion:** Yes
- **Dark Interface:** Yes (preserve the existing pass)

**No label may be claimed until every covered row has a recorded pass.** Source guardrails prove *presence* of the fix, not rendered behavior — the largest-text, contrast, reduce-motion, and dark passes are device/simulator gates (Task 6 of the plan), not a doc sign-off.

Covered common-task screens: Onboarding, Guard, Filters, DNS Resolver/Fallback, Privacy & Data, Backup/Account, Support/Bug Report, Activity/Reports.

Status legend: ❌ gap found · ⚠️ partial / verify · ✅ fixed + verified · ⏳ device gate pending.

---

## 1. Larger Text (Dynamic Type)

Risk: launch-critical text uses `.lineLimit(1)`, `minimumScaleFactor`, or fixed `height:` so it **shrinks or truncates** instead of reflowing at large accessibility sizes. Fix intent: wrap / `ViewThatFits` / min-height + flexible padding; keep one-line truncation only for repeat-list or decorative text whose full value is available elsewhere; keep ≥44 pt hit targets.

| Site | Pattern today | Meaning carried | Status |
|---|---|---|---|
| `GuardView.swift:100` | protection **title** `.lineLimit(1).minimumScaleFactor(0.75)` | primary Guard status — full text only in `.accessibilityValue` | ❌ |
| `LavaComponents.swift:413,417,429` | `LavaOverviewMetricBlock` value `.lineLimit(1).minimumScaleFactor(0.9)` in `.frame(height: 52)` inside tile `.frame(height: 74)` | metric value, not shown elsewhere | ❌ |
| `LavaComponents.swift:372,378` | `LavaMetricPill` value `.lineLimit(1).minimumScaleFactor(0.75)` in `.frame(height: 54)` | metric value | ❌ |
| `LavaComponents.swift:452,462` | `LavaOverviewBannerRow` title `.lineLimit(1)` (unless wrapping) + `.frame(height: 50)` | status/banner text | ❌ |
| `OnboardingFlowView.swift:634` | page headline `.largeTitle.bold().lineLimit(1).minimumScaleFactor(0.68)` | onboarding headline, no wrapped fallback | ❌ |
| `OnboardingFlowView.swift:1192,1197` | primary CTA `.lineLimit(1).minimumScaleFactor(0.82)` + `.frame(height: 52)` | primary button label | ❌ |
| `OnboardingFlowView.swift:1215,1218` | secondary CTA, same pattern | secondary button label | ❌ |
| `GuardView.swift:277` | `"Long-press for pause options".lineLimit(1).minimumScaleFactor(0.85)` | only affordance hint on the primary button | ❌ |
| `DiagnosticsView.swift:330-352` | metric row `Text(label)` + `Text(value).lineLimit(1).minimumScaleFactor(0.7)` in one `HStack` | activity metric value | ❌ |
| `DiagnosticsView.swift:970-975` | date endpoint `.lineLimit(1).minimumScaleFactor(0.72)` + `.frame(height: 56)` | activity date range | ❌ |
| `DiagnosticsView.swift:819-824` | date-range pill `.lineLimit(1).minimumScaleFactor(0.82)` + `.frame(height: 34)` | filter pill | ❌ |
| `BackupRestoreView.swift:84-85` | nav title `.lineLimit(1).minimumScaleFactor(0.8)` | screen title (`.isHeader`) | ❌ |
| `BackupSetupView.swift:85-86` | step title `.lineLimit(1).minimumScaleFactor(0.8)` | backup step title | ❌ |
| `SettingsView.swift:1553-1555` | `.lineLimit(1).minimumScaleFactor(0.78).fixedSize(horizontal: true, …)` | only `horizontal: true` fixedSize in the set — can push content off-screen | ❌ |
| `FiltersView.swift:2470-2477` | category jump-pill label (also a contrast site, §2) | navigation pill | ❌ |

Also-ran (lower launch-criticality): `OnboardingFlowView.swift:754`, `SettingsView.swift:1994`, `FiltersView.swift:611` (repeat-list filter name — full value is the row itself), `FiltersView.swift:1910`, `FiltersView.swift:1130`.

**Safe / good (do not "fix"):** `.fixedSize(horizontal: false, vertical: true)` is used widely (`LavaScaffold.swift:14-42`, `GuardView.swift:33,126`, `OnboardingFlowView.swift:283,838,889,905,940`, many in `SettingsView`) — these *allow* vertical growth and should stay.

### Typography scale (title roles)

Row and card titles now resolve through named roles in `LavaTypography` (`LavaTokens.swift`) — the size analog of the `LavaStyle` color tokens — so one kind of text is one size across every screen and cannot drift per view. All roles are Dynamic-Type-scaling semantic fonts except the fixed metric numeral, so this consolidation does **not** regress Larger Text.

| Role | Value | Applied via | Used for |
|---|---|---|---|
| `LavaTypography.rowTitle` | `.subheadline` semibold (15 pt) | `View.lavaRowTitleText()` (font only — the row keeps its own color) | primary title of a data/list row (filter name, blocklist name, blocked domain, resolver preset, custom DNS, bug-report topic) |
| `LavaTypography.cardTitle` | `.headline` (17 pt) | `View.lavaCardTitleText()` (font only) | title of a tappable entry card / navigation row (Settings nav / external-link / system-settings rows, `LavaNavigationRow`, `LavaDetailRow`, `ImportOptionRow`, the "Now filtering" card) |
| `LavaTypography.metricNumeral` | `.system(size: 42, .bold, .rounded)` | `.font(LavaTypography.metricNumeral)` | hero overview metric numeral (`LavaOverviewMetricBlock`) |

Outliers were corrected **down** to the row role: the blocklist-picker rows (`CustomBlocklistPickerRow`, `BlocklistPickerTextStack`) were `.headline.weight(.semibold)` (17) and the Custom DNS row was `.subheadline.weight(.medium)` (weight outlier); all now route through `rowTitle` (15). The compact `LavaMetricPill` (17 pt) and the 42 pt `LavaOverviewMetricBlock` numeral are **intentionally** different scales, not a drift to reconcile. The two body-copy helpers are documented in `LavaScaffold.swift`: `lavaSupportingText()` (15 pt, dense/secondary — the default) vs `lavaBodySupportingText()` (17 pt, primary paragraph copy). `TypographyScaleSourceTests` pins the token layer, the scaffold modifiers, and the migrated call sites.

---

## 2. Sufficient Contrast

Measured with WCAG 2.x relative-luminance from the literal `LavaTokens.swift` RGB values. Targets: **4.5:1** normal text, **3:1** large text and non-text affordances.

### Measured failures

| Pairing | Mode | Ratio | Target | Result |
|---|---|---|---|---|
| `lavaOrange` text on `lavaOrangeSoft` | light | **2.93:1** | 4.5 | ❌ |
| `lavaOrange` text on `lavaOrangeSoft` | dark | 5.84:1 | 4.5 | ✅ |
| `lavaOrange` text on panel background | light | **3.36:1** | 4.5 | ❌ |
| `lavaOrange` text on white card | light | **3.40:1** | 4.5 | ❌ |
| white text on `lavaOrange` (active pill) | light | **3.40:1** | 4.5 | ❌ |
| white text on `lavaOrange` (active pill) | dark | **2.33:1** | 4.5 | ❌ |

`lavaOrange` (light `rgb(0.95,0.34,0.18)`) is a bright accent — it clears 3:1 (fine as a non-text affordance/fill outline) but is too light to be **text** on any light background, and too light to carry **white text** as a fill.

### Fix (applied — signed off)

- New **`lavaOrangeText`** token (light `rgb(0.75,0.25,0.09)` = `#BF4017`; dark keeps the bright orange, which already passes). Used wherever orange is *foreground text/glyphs*; `lavaOrange` stays for accents/fills so the brand look is preserved. Measured **4.57:1** on `lavaOrangeSoft`, **5.30:1** on white (light); **5.84:1** on soft (dark). ✅
- New **`lavaOrangeSelectedFill`** token (light `#C7471F` / dark `#AD4726`) for the selected category pill (`FiltersView.swift:2477`), so white text clears **4.82:1** (light) / **5.64:1** (dark). Non-selected fills keep `lavaOrange`. ✅
- **`ColorContrastSourceTests`** guardrail added — it parses the literal RGB from `LavaTokens.swift` and **computes** the WCAG ratio, failing if a future edit lightens either token below 4.5:1 (not just a name pin).
- Non-text orange (bar fills, status icons, +/- glyph tints, borders) kept as `lavaOrange` — clears the 3:1 non-text bar. `ProtectionTintRole.color` and `RestoreStatus.tint` (icon accents) noted for the device pass.

### Orange-as-text sites to retint (once the token lands)

`GuardView.swift:96`; `BackupSetupView.swift:163,184,258`; `FiltersView.swift:169,185,193,909,1130,1161,1469,1498,1949,2109,2814`; `SettingsView.swift:1159`; `DiagnosticsView.swift:611,1398,1573`; `FilterReviewFlowView.swift:222`; `LavaComponents.swift:273`; `NetworkActivityThemePill` warning (`DiagnosticsView.swift:665,676`); `pendingRemoval` chip (`LavaCondensedList.swift:38,47`).

### Verify (not yet measured failing)

- white on `safeControlGreen` CTAs (`OnboardingFlowView.swift:758,915,980,1195`; `LavaComponents.swift:113`; `SettingsView.swift:3183`) — check both modes.
- `panelActionGreen` on `panelActionFill` (`LavaComponents.swift:88`; `OnboardingFlowView.swift:1214`).
- `dangerRed`/`.red` text (`OnboardingFlowView.swift:247`; `GuardView.swift:128`; `SettingsView.swift:1180,3400,3828`; `FiltersView.swift:645,830,1248,2678`).
- Hard-coded literal RGB gradient fills (`OnboardingFlowView.swift:1350,1353,1356`) — decorative, no light/dark variant; confirm no text sits on them.

---

## 3. Reduced Motion

A shared gate **already exists** — `LavaFlowTransition.animation(reduceMotion:)` / `.transition(_:reduceMotion:)` and the `lavaFlowTransition(value:direction:reduceMotion:)` modifier (`LavaScaffold.swift:753-789`), softening to a plain fade under Reduce Motion. It's consumed correctly in Onboarding hero choreography, Backup setup, Filter review, and Guard dwell timing.

**Fix (applied):** added `LavaFlowTransition.incidental(_:reduceMotion:)` to the same enum — it returns `nil` (no animation, instant) under Reduce Motion, for *incidental* motion where a fade does not fit (slides, expand/collapse, scrolls, press-scale). The **perceptible-movement** sites now route through it: onboarding segment slide + `matchedGeometryEffect` (740/748/766) ✅, encrypted-fallback expand/collapse (804/844/845) ✅, Filters category jump-pill animated scroll (2051) ✅, and all four shared button press-scale styles (`LavaComponents` 67/101/126/155 — one gate covers every standard button) ✅. **Remaining (low-severity, follow-up):** the Filters usage-bar fill (2594) and preview (1105), and the `DiagnosticsView`/`SettingsView` local press-scales (a 1–2% scale is barely perceptible). `GuardView:129 .transition(.opacity)` is intentionally left — a cross-fade carries no motion and is allowed under Reduce Motion.

| Site | Animation | Status |
|---|---|---|
| `OnboardingFlowView.swift:748,766` | segment-control `matchedGeometryEffect` + `withAnimation(.easeInOut)` selection | ❌ |
| `OnboardingFlowView.swift:740` | `.animation(.easeInOut, value: selection)` | ❌ |
| `OnboardingFlowView.swift:804,844,845` | encrypted-fallback section expand/collapse | ❌ |
| `FiltersView.swift:2051` | animated `scrollTo` on category jump pills | ❌ |
| `FiltersView.swift:2594` | usage/progress bar fill `.animation(.easeOut, value: fraction)` | ❌ |
| `FiltersView.swift:1105` | `.animation(.default, value: preview)` | ❌ |
| `GuardView.swift:129` | guard message `.transition(.opacity)` (low-motion, still ungated) | ⚠️ |
| `LavaComponents.swift:67,101,126,155` | shared button press `scaleEffect` + `.animation(.easeOut(0.12))` | ⚠️ |
| `DiagnosticsView.swift:836,989` | press-scale button style | ⚠️ |
| `SettingsView.swift:3196,4798` | press-scale | ⚠️ |
| `LavaScaffold.swift:162` | `withAnimation(.easeOut(0.24))` internal | ⚠️ |

High-value (motion the user actually perceives): the segment `matchedGeometryEffect`, the section expand/collapse, and the animated scroll. Press-scale items are low-severity (small, brief) but should still route through the shared policy for consistency.

---

## 4. Dark Interface

Strong today: `RootView.swift` applies `.preferredColorScheme(viewModel.preferredColorScheme)` (system or in-app theme), and `LavaTokens.swift` resolves every color via `adaptiveColor(light:dark:)` on `UITraitCollection.userInterfaceStyle`, so tokens carry a dark variant. **Fix intent:** keep the dark pass green after the contrast retint and large-text changes — re-verify every covered task in dark appearance (Task 5). One dark-specific contrast failure is already noted in §2 (white-on-`lavaOrange` pill, dark 2.33:1).

---

## Verification matrix (Task 6 gates)

Each cell: pass result · date · tester. Nothing may flip an App Store label until its column is all-pass.

| Screen | Larger Text | Contrast | Reduced Motion | Dark Interface |
|---|---|---|---|---|
| Onboarding | ⏳ | ⏳ | ⏳ | ⏳ |
| Guard | ⏳ | ⏳ | ⏳ | ⏳ |
| Filters | ⏳ | ⏳ | ⏳ | ⏳ |
| DNS Resolver/Fallback | ⏳ | ⏳ | ⏳ | ⏳ |
| Privacy & Data | ⏳ | ⏳ | ⏳ | ⏳ |
| Backup/Account | ⏳ | ⏳ | ⏳ | ⏳ |
| Support/Bug Report | ⏳ | ⏳ | ⏳ | ⏳ |
| Activity/Reports | ⏳ | ⏳ | ⏳ | ⏳ |

Gate commands (Task 6): `xcodebuild -list -project LavaSec.xcodeproj`; the source-guardrail test command (large-text, contrast, reduce-motion assertions); largest-accessibility-text pass; contrast pass (4.5:1 text / 3:1 non-text, light + dark); Reduce-Motion pass; Dark-Interface pass. Attach large-text + light/dark captures per screen.
