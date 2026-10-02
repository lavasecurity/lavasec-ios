# Full app contract audit

Status: source audit and local RN regression checks pass. Native package tests and the full RN app/extension simulator compile passed before the final review follow-up; CI requalifies that follow-up, simulator journeys, PR review, and signed export before release. No new RN QA tag has been cut.

The SwiftUI app is the behavioral reference. Every route is checked for displayed state, available actions, authentication, confirmation, mutation target, cancellation, failure handling, persistence, and lifecycle. Calling the same controller method alone does not establish parity.

Reference: `native-ui-reference-2026-09-08` (`ab431736f50afc3dc697a7f390aadc0fa50610fb`). That historical tag retains the original standalone SwiftUI app. Current source
uses `LavaSec.xcodeproj` only as the native target manifest; build the application
through the RN workspace. Shared SwiftUI forms below are deliberately reused native components, including their validation and cancellation.

## Inventory and evidence

Paths below are relative to `LavaSecApp/` and `ReactNative/`. “Reviewed” means both implementations were inspected. It does not mean physical-device acceptance. Component tests execute React handlers with a mocked native boundary; native simulator journeys execute the real controllers and storage.

| Area | Native owner | RN path and audited contract |
| --- | --- | --- |
| Launch, onboarding, lifecycle, external links | RootView, LavaProtectionShortcutRuntime, SecurityController | Reviewed: `native-app/LavaAppHost` embeds presentation in the original root/runtime. App delegate, onboarding, background work, external imports, shortcut callbacks and privacy masks remain native. Full-app import/App Unlock journey checks teardown of private input. |
| Tabs and navigation authorization | RootView tab selection/security turns | Reviewed: native-tabs patch, navigation-turn and `review/navigation`. Native reselection pops nested stacks to root. Guard at root is a no-op; expanded Settings stays still and scrolled Settings uses native adjusted-inset scrolling; inactive stacks are retained. Navigation tests reject late authorization after pop/background and allow Face ID inactivity. Native repeated-tap/redirect journey. |
| Guard, enable/disable, pause/resume | GuardView and protection commands | Reviewed: native status, disabled/configuring/tint state, primary action, pause durations and auth gates are projected. UIKit pause context menu and VoiceOver actions; shared native gratitude/ramp haptics. Physical VPN and haptic feel remain device checks. |
| Filters overview and automation | FiltersView, AutoSwitchHowToSheet | Reviewed: connection illustration is explanatory local state; Now Filtering opens active identity; native Import and automation help are reused. Full-app automation/import journey. |
| Library, create/rename/duplicate/delete/switch | FilterLibraryView, FilterLibraryController | Fixed: authenticated edit mode, staged multi-delete/Undo, discard on exit, confirmation sheet, capacity and frozen gating, direct active-row navigation. Original create/duplicate/rename/delete forms and controller perform validation/writes. Component cancellation/staging/form tests; added native rename/staging/relaunch journey. |
| Filter detail, drafts, cancel, refresh | FilterMyListView, FilterDraftController | Fixed: native staged display rows/Undo and canSave state, active-only initial/manual/pull refresh, actual-pop teardown. Inactive saves persist directly; active safe changes prepare directly; weakening changes require Review. Save disposition/duplicate-tap tests and real inactive-save/relaunch journey. |
| Blocklist picker and custom lists | BlocklistPickerView, BringYourOwnListView | Reviewed: temporary checkbox selection, localized search, native budget summary/tier limits, pending selections, custom-source mutation and cancellation retained. Native custom-list entry reused; catalog and cancellation regressions. |
| Blocked domains and exceptions | native domain sheets, FilterDraftController | Fixed: Free-at-cap Upgrade and Plus-at-cap disabled Add, native rejection title/message, raw input validated by native editor, one pending add, independent remove/Undo. Quota, rejection, cancellation, rapid mutation and identity tests. |
| Review/apply/failure/retry | FilterReviewFlowView, preparation controller | Fixed: Save determines whether review is needed; native canConfirm/validation and three diff groups. Native preparation owns retry/keep current/back to edit. Exact reviewed identity/draft/baseline checked at apply; no forced duplicate fresh-auth prompt after Save. Tests cover stale tokens, retries, origin, cancellation, and preparation-before-dismiss ordering. |
| Share/import | ShareFilterPicker, sharing service, ImportFiltersFlow | Reviewed: empty/oversize gating, verbatim names, native LF1 code/QR, copy and system share card. Native import/scanner retains deferred fresh-auth and replacement review. Share regressions and native import security journeys. |
| Activity/date ranges/review dwell | DiagnosticsView, DiagnosticsDateControls | Reviewed: native date sheet and cancellation, inclusive date ranges, native summary and refresh sampling, token-owned foreground dwell. No seven-day UI switch. Activity range/lifecycle tests. |
| Top Domains and Domain History | native diagnostics pages/controllers | Fixed: native long-press Copy/Block/Allow menu, decision metadata and validation, owned standalone review; history page resets on native retained-event count changes. Native sampling precedes reads. Tests cover empty/filter/paging/late stage/cancel/Copy. |
| Network log | DiagnosticsNetworkActivity, LocalLogPagination | Fixed: 30 initial rows and 30 per page; reset on entry-count change, retain on unchanged-count refresh; native clear effects/action, activity auth, durable success-only announcement. Paging and clear tests. |
| Nerd stats | native Nerd Stats views | Reviewed: native tier values, aligned columns, native sampling action, build/source conditional row and authoritative counters. Render regression and native query projection. |
| Settings summaries/root reselection | SettingsView | Reviewed: native DNS/security/privacy summaries, native version/build/source, QA tools and links. No fixture-only destinations registered in the full app. Summary/localization and repeated-tab journeys. |
| Account providers/sign-out/delete | AccountSettingsView, AccountSheet, AccountController | Reviewed: native provider availability/connected/busy state. Original AccountSheet owns sign-out/deletion confirmations and account operations. RN tests check signed-out gating; actual provider and account operations are device acceptance. |
| Backup setup/restore/manual/automatic/maintenance | BackupController, native backup views | Fixed: exact shared native delete/disable confirmations and effects, busy/provider/manual upload state, signed-out/off appearance. Native setup/recovery/restore retained. Disable deletes remote copy before local teardown; failure leaves backup configured. Delete-copy keeps backup enabled. Automatic toggle only changes scheduling. Confirmation/gating tests; native core backup invariants; remote acceptance remains device-only. |
| Upgrade/restore/manage subscription | UpgradeSettingsView, Plus controller | Reviewed: shared native displayed offers and lazy product retry after an empty StoreKit lookup, localized pitch and commitment totals, active/loading states, plan-dependent disclosure, busy controls and StoreKit presentation. Purchase-state tests; actual StoreKit acceptance on device. |
| DNS/provider/transport/fallback/custom/chaining | DNSResolverSettingsView, VPNChainingSettingsView | Fixed: inline Custom Resolver draft with Save/Clear, validation, discard/cancel, selected-state and metadata; primary/fallback writes use native setters and reset rules. Context rechecked after auth to reject stale writes. Native VPN chaining form retained. Clear/provider/discard/validation/fallback tests, including draft teardown after native fallback disable, same-frame toggle/Save serialization, a native fallback-enabled context guard, and retention after cancelled authentication. |
| Privacy/log preferences/clear/export | PrivacySecuritySettingsView, DiagnosticsController | Fixed: share native disable and clear confirmation definitions for all log targets. Native durable writes/export with domain history excluded from the standard flow, direct system Files presentation, progress/failure and success-only announcement. Export/clear/disable regressions. |
| Security/passcode/biometrics/surfaces | SecurityController, native credential forms | Fixed: native hasAuthenticationMethod, protected-surface pending serialization and no optimistic toggles. Native passcode setup/removal and biometric authentication retained. Cancellation tests and real passcode/backgrounded-sheet journey. |
| Appearance/text size/Guards/haptics/icon | CustomizationController | Reviewed: native preferences, UIFontMetrics/localization, unlock availability, selection and icon single-flight, correct Plus footer. Native haptic/Guard gestures retained. Text-size, persistence and protected icon journeys; icon/haptic device acceptance. |
| Notifications/Live Activities/pause | CustomizationController and native preferences | Reviewed: original notification categories, platform availability, native 1–30 minute stepper, matching-system text-size seeding and OS settings link. Non-preset pause persistence journey and component test. |
| Feedback/attachments | BugReportSheetView, reports controller | Reviewed: original native report/topic/attachment/send flow; full app routes and rage shake reach this flow, with Settings underneath. Fixture Feedback is not registered in the full app; native notification/deep-link redirects dismiss the bridged feedback sheet, including direct Settings entry. Real delivery requires a deliberately submitted report. |
| Legal/notices | LegalVersionSettingsView, BundledLibraryNoticesView | Reviewed: native legal links and bundled notices, including generated RN dependency notices; native licenses flow reused. Bundle/license policy checks. |
| Sudoku | SudokuEasterEggView, native Sudoku persistence | Reviewed: five-tap entry, native generation, values/notes persistence only when progress logs allow it, drag/notes/assist/clear/new-puzzle behavior and native haptics. Board, model, persistence, privacy and busy-action tests. |

## Corrections from this audit

- **A01–A04:** backup meaning and progress, per-target destructive log confirmations, network pagination, and native security availability/pending state.
- **A05–A06:** full Library transaction scaffold/native forms, and inline Custom DNS draft lifecycle.
- **A07:** native Save disposition, staged list/domain Undo, quota and rejection contracts, and Review/preparation ordering.
- **A08:** UIKit context menus, Guard pause accessibility, gratitude/long-press haptics, and Sudoku interaction haptics.
- **A09:** preview-only destinations excluded from full app; protected navigation rejects late completion after leaving/backgrounding; native feature flows return to their real owning route.
- **A10:** native diagnostics sampling, history count-driven paging reset, and manual retry after cancelled authentication.
- **A11:** final review: bridged Feedback dismissal on redirects, localized connection selection/VoiceOver value, fallback-DNS toggle/Save serialization, shared native subscription fallback offers/retry/pitch/commitment totals, complete native mascot-state mapping, and a distinct Upgrade route when Plus lapses during custom-DNS Save.

- **A12:** app-scoped pending groups claim purchase/restore/manage, account-provider sign-in, and backup upload/delete/disable before enqueueing. Rapid or competing taps cannot replay after cancellation, and screen recreation retains the pending group until the native operation completes. Backup scheduling stays independently editable; protection commands retain their immediate queue-bypass path. Library/filter/DNS/security/diagnostic operations retain their existing pending guards.

- **A13:** restore Domain History’s native off-state opt-in under Activity authentication, preserve Top Domains’ distinct off-state guidance, show the native empty-search reason, and show domain-action guidance only with rows. Component checks cover pending/cancel/retry and authoritative state; a native opt-in/relaunch journey verifies persistence.

- **A14:** discard the matching local filter draft without reauthentication after backgrounding, while preserving active preparation. Keep blocklist catalog rows mounted during selection-total queries, disable Save while totals are stale, and exclude duplicate saves. Query identity changes clear retained data even when query arguments match. Component regressions cover retained rows and identity isolation; the native authentication journey also exercises discard after backgrounding.

- **A15:** preserve native catalog-backed VoiceOver labels, status values and actions on Guard, Activity, blocklist deletion and Sudoku. Sudoku uses the native localized cell/notes/remaining-count formats, including positional 64-bit integer placeholders. German and Japanese component regressions exercise both visible and accessibility presentation.

- **A16:** share the synchronous pending guard across Device DNS mode, fallback, provider, transport and custom Save. Competing callbacks cannot cross primary/fallback roles while waiting for the native snapshot; all associated controls disable together and cancellation retains authoritative state. Tappable scaffold rows expose localized metadata/prefixes through their accessibility value, including DNS addresses and disabled sharing reasons. Regressions cover each DNS mutation through success/cancellation plus English/German/Japanese metadata.

- **A17:** expose the existing Apple/Google controller tasks and await them at the RN bridge. The sign-in pending group now covers the actual provider operation and its completion hooks, including normal provider cancellation, rather than ending immediately after task creation. Existing SwiftUI call sites keep their fire-and-forget behavior. Executable regressions cover pending exclusion through screen recreation and provider cancellation; native boundary pins enforce awaiting the real returned task. Purchase, restore/manage and backup bridge actions were also checked and already await their native operations.

A stale custom-DNS write is explicitly rejected after authentication if its target/configuration changed. This preserves the native configuration owner rather than applying a draft to a different primary/fallback resolver. The primary resolver preserves its discard confirmation, while the native fallback picker’s transient draft resets on provider selection or departure. No storage format, backup deletion semantics, entitlement, or tunnel engine changes are introduced.

## Qualification history and current release gate

The original audit shipped in source PR #709, merged as
`38a1f8c4bb350f0b5c47d4b7a3c03c5ed12824fc`, and immutable tag
`v1.5.0-rc3-rn`: LavaSec QA `1.5.0 (1788946040)`.
Qualification passed 210 React tests, 4,743 native package tests, seven isolated
host journeys and ten full-app journeys, followed by a signed dry inspection and
successful QA upload. The infra plan contains the exact CI and upload receipts.

The subsequent phone review identified native presentation/interaction gaps that
those checks did not cover. [DEVICE-FEEDBACK-2026-09-09.md](DEVICE-FEEDBACK-2026-09-09.md)
records all 20 reports, fixes, regressions, evidence and remaining physical checks.
Current release gates are final native/core and React checks, generated full-app
policy, isolated-host and full-app journeys, resolved PR review and normal merge,
then a signed dry inspection from that exact merged SHA. Only after that inspection
may the next unused immutable `v1.5.0-rcN-rn` tag dispatch its single RN QA upload.
Verify the actual uploaded source/version/build; keep the SwiftUI reference.

The September 10 follow-up, [DEVICE-FEEDBACK-2026-09-10.md](DEVICE-FEEDBACK-2026-09-10.md),
adds a pushed native VPN page, memory-only read reuse and stable Activity/domain
scaffolds with lifecycle, privacy, search and navigation regressions.

Detailed device journeys are in [DEVICE-ACCEPTANCE.md](DEVICE-ACCEPTANCE.md).
The pre-existing QA Google OAuth configuration is absent; Google provider
acceptance still requires that QA-specific client configuration.

Simulator/source checks do not establish physical VPN/DNS traffic, reboot,
Shortcuts/Focus/widget/Live Activities, account providers, sandbox purchases,
remote backup maintenance, camera/scanner, haptic strength or icon behavior.
No production backup or account was deleted during this audit.
