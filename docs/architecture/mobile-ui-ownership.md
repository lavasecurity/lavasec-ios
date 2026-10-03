# Mobile UI ownership and parity baseline

The mobile UI plan first separates native application ownership, then recreates
the iOS presentation in React Native for review. The production SwiftUI route and
native background/extension entry points remain available throughout this work.

Plan: [native scaffolding and React Native iOS parity](https://github.com/lavasecurity/lavasec-infra/blob/main/plans/2026-09-07-mobile-ui-portability-and-app-view-model-separation-plan.md).

## Inspected implementation

Baseline: `dd932711f3fee854c28414a7a40c1b0e50bd382b`. AppViewModel's main file and
its concern extensions still form one `@MainActor` owner. The concern-file split
is already complete; it does not independently isolate state or transaction
ownership. Existing package boundaries and scoped feature controllers are reused.

| Responsibility | Current owner/source | Intended boundary | Remaining slice |
|---|---|---|---|
| Native notification delivery | `ProtectionUserNotificationController` and Kit delivery/history policy | Injected `ProtectionNotificationPresenting`; policy/history stays native | 1B lifetime verification |
| Live Activity presentation | `LavaLiveActivityController`, AppViewModel observation/reconcile sites | Injected `AmbientProtectionPresenter`; existing activation lifetime retained | 1B lifetime verification |
| UIKit/Core Haptics playback | `ProtectionHapticFeedback` | App-only native component/effect adapter, with shared preference gate | Component integration in 2B |
| Filter draft editing/review | `FilterDraftController` owns sessions, edit commands, and preparation state; Kit editor; native apply in `+FilterDraftApply` | Focused review projections and complete apply command | 1C–1D |
| Library/switch/import | `FilterLibraryController` owns library presentation; `+FilterLibrary`, `+FilterSwitching`, `+ShareableFilters` retain native transactions | Native filter application service | 1C–1D |
| Configuration and shared writes | `+Persistence`, filter transactions, shared store/locks | Existing commit authority behind operation-specific interfaces | 1D |
| Catalog/preparation/recovery | CatalogController and `+CatalogSync`, `+WarmArtifacts` | Whole native transaction, preserving single-flight and publish semantics | 1D |
| Protection/health | `+ProtectionLifecycle`, `+ChainedConnectLifecycle`, `+TunnelHealth` | Native commands and coherent confirmed snapshots | 1D |
| Pause/resolver/Focus | TemporaryProtectionPauseController and corresponding concern files | Durable native operations independent of presentation | 1D |
| Account/backup/billing | Existing controllers with `+HubBridges` callbacks | Same feature owners with focused native dependencies | 1C–1E |
| Diagnostics/retention/export | DiagnosticsController and concern files | Native bounded queries, retention and export authority | 1C–1E |
| Onboarding/customization/security | Existing controllers plus app-model coordination | Focused presentation and native authorization operations | 1C–1E |
| App and mutating shortcuts | `LavaProtectionShortcutRuntime` | One explicitly composed application graph | 1E |
| Headless catalog work | `BackgroundCatalogRefresh` creates headless AppViewModel | Independent native service graph | 1E |
| Widget/intents/tunnel | Separate native process assemblies and shared command substrate | Retain permitted dependencies and durable coordination | Verify with each affected cut |

`LavaAppPlatformServices` is the first real construction boundary. It owns only
migrated notification/ambient dependencies and does not activate them. AppViewModel
retains its current observer startup/headless gates; later service extraction must
move those lifetimes as complete operations. No new mutable configuration cache or
command authority is introduced here.

## Draft ownership cut (1C)

`FilterDraftController` is the sole stored owner of per-filter drafts, the viewed
filter identity, and preparation presentation. `FilterDraftSessionState` in
Presentation makes per-filter preservation, clean/dirty teardown, invalidation,
and rollback executable without the app target. Domain edits continue to use the
existing Kit editor and validation. The controller reads live native inputs through
`FilterDraftContextProviding`, whose interface has no configuration setter or save.

Editing and preparation views observe the controller directly. AppViewModel keeps
compatibility projections and forwards the controller's observation for remaining
native metadata consumers; these forwards are removed as 1E retires the hub. Native
save/apply, switch, import, and backup transactions keep their complete existing
ordering and authorization. Library replacement resets a single session snapshot;
its rejected-before-write rollback restores drafts and target together. Closing a
screen does not own or cancel any accepted transaction task.

`FilterDraftReview` in Kit projects the selection diff and confirmation
eligibility from current draft, limits, and the native rule-budget decision. The
controller formats the existing messages; the confirmation sheet consumes one
projection per render. Executable tests cover absent/unchanged drafts, exact limits,
validation priority, and reprojection after entitlement changes or cancellation.
AppViewModel retains read-only compatibility forwards for native apply and other
screens. Dirty-state reads do not trigger native budget estimation.

The sheet still observes the native hub for metadata/entitlement changes and calls
its complete existing apply operation. This avoids an observation cycle through the
hub's draft-observation forward. A projection is not an accepted review token:
immutable review identity/stale-review handling, complete-operation ports, and
durable transaction extraction remain subsequent cuts. This does not finish 1C
or make a live React Native Filters service available yet.

## Library presentation cut (1C)

`AllFiltersView` owns one `FilterLibraryController` through `StateObject`; the create
sheet observes that same owner. Popping the library releases its edit session, while
temporary sheets and authentication covers retain it. `FilterLibraryEditSession`
owns edit mode and staged deletions, with executable coverage for staging, undo,
exit, and same-ID reuse after a restore. Modals and navigation bindings remain
local SwiftUI presentation state.

The controller reads the current native library through `FilterLibraryHubBridging`
and forwards its observation without storing a second writable library or tier.
`FilterLibraryAccessPolicy` in Kit now supplies both the screen's eligibility and
the existing native create/rename/delete/switch backstops. Tests cover lapsed-tier
ordering, an active-filter change, capacity, and trimmed case-insensitive names.

The bridge exposes complete existing operations and no persistence primitives or
replacement tokens. Native transaction ordering, fresh authentication before a
manual switch, rollback, warming, and accepted task lifetimes remain intact. Rule
counts still come from the native compiled/projected count owner. Share/import and
the durable transaction extraction remain subsequent cuts; this is not completion
of milestones 1 or 2.

## Reference route/state inventory

This inventory identifies the source of each reference; it does not claim that
device captures or React Native equivalents have been completed. Capture status
for every row is pending. Add fixture/build/device identifiers with the captures.

| Journey | SwiftUI reference | Required states/interactions |
|---|---|---|
| Root navigation | `RootView.swift` | All tabs, nested Back, sheets, deep links, authentication interruption |
| Onboarding | `OnboardingFlowView.swift` | Each step, permission outcomes, resume/commit, unavailable states |
| Guard | `GuardView.swift` | Off/connecting/on/recovering/paused, health/fallback, primary actions, mascot gestures |
| Filters overview/library | `FiltersView.swift`, `FilterLibraryView.swift` | Empty/populated, active selection, create/rename/delete, external switch |
| Filter editing/review | `FilterMyListView.swift`, `FilterDomainSheets.swift`, `FilterReviewFlowView.swift` | Draft changes/cancel, validation, stale review, prepare/apply/failure |
| Share/import | `ShareableFiltersUI.swift` | Link/code/QR paths, review, validation, unavailable/error outcomes |
| Activity | `DiagnosticsView.swift` and `Diagnostics*.swift` | Overview/date changes, Top Domains, history, empty/unavailable, domain actions |
| Resolver/chaining | `DNSResolverSettingsView.swift`, `VPNChainingSettingsView.swift` | Selection/edit/review, validation, health, entitlement states |
| Security/privacy | `PrivacySecuritySettingsView.swift` | Protected surfaces, authentication, retention changes, clear/export |
| Customization | `CustomizationSettingsView.swift` | Appearance/text size, icons, mascot picker, haptics/notification preferences |
| Account/backup | `AccountBackupSettingsView.swift`, `BackupSetupView.swift`, `BackupRestoreView.swift` | Signed out/in, setup, recovery/passkey, progress, failures, destructive review |
| Upgrade | `UpgradeSettingsView.swift` | Products, unavailable/pending/purchase/restore/entitlement outcomes |
| Diagnostics/feedback/legal | `BugReportSettingsView.swift`, `LegalVersionSettingsView.swift`, diagnostic detail views | Preparation, opt-ins, export/send/error, version/notices |
| Secondary experiences | `SudokuEasterEggView.swift`, developer/QA views where supported | Entry/exit, input, persistence, accessibility, release visibility |

Each journey needs the same device, OS, build SDK, language, text size, appearance,
content fixture, and relevant clock state in both implementations. Screenshots
must be accompanied by interaction checks for focus, keyboard, gestures, scroll,
transitions, VoiceOver, and reduced motion. Actual system controls remain native.

## Verification boundaries

Notification policy and long-press haptic curves already have executable Kit tests.
App-only composition and membership are source-pinned because the package test
target cannot import app code; the app build verifies the concrete protocol wiring.
Keep aggregate AppViewModel source coverage limited to the real class and its
extensions. Tests of moved adapter behavior read the adapter's registered source.

Physical notification/haptic/Live Activity checks and reference screenshots remain
required evidence; no source-only or package-only result claims to cover them.


## Appearance service and review host (2A)

`AppearancePreferencesService` now owns appearance-key reads/writes and coherent
native snapshots in LavaSecAppServices. Production CustomizationController retains
its SwiftUI-only appearance adapter and confirmed published value, and delegates
load/set operations through the injected service. The separate React Native review
host consumes the same service implementation in its own UserDefaults domain.
Its TurboModule and JS subscriber handle native confirmation, teardown, stale
responses, foreground refresh, and runtime recreation without importing AppViewModel.
This advances the service integration boundary; the remaining feature ownership and
native transaction cuts above are still open.
