# RN application and retained native components

The supported app entry point is `RootView` → `LavaAppHost` → the RN Guard and
Settings navigators. Build `ReactNative/native-app/LavaSecRN.xcworkspace` after
running `ReactNative/scripts/prepare-full-app.sh`. QA and Release use this same
app, with their existing identities and feature gates.

## What is retired

The SwiftUI tab root, Guard/Filters/Activity pages, their library/detail/picker
screens, and the duplicate account, customization, privacy, security, legal and
Nerd Stats pages no longer ship. The duplicate SwiftUI share chooser/detail and
website screenshot root are removed. RN owns these routes already; this cleanup
does not redesign them or change their stored settings.

The native onboarding and Sudoku renderers, old share-card image renderer, and
duplicate filter/feedback/license flow bodies and their unused change-row/icon-role
helpers are also removed. Their source pins, Debug-only native Sudoku launch
route, renderer-only animation/layout models and historical native sheet-layout
fixture do not provide coverage for the current RN
interface and are retired with those implementations.

## Presentation and native ownership

RN describes all app-owned foreground pages and tasks, including filter preparation,
import, account connections, backup setup/restore, passcode setup/authentication,
DNS help and internal Device QA. `ReactNative/src/flows/` contains reusable typed
screen modules. Their state and command ports are independent of `AppStore`, iOS
view controllers and the bridge transport. `ReactNative/review/*Adapter.ios.tsx`
binds those ports to the admitted iOS projection and native navigation.

Native code retains service and transaction authority: filter compilation/apply,
review comparisons and replacement generations, account operations, encrypted
backup, passkeys, credential validation, persistence and permissions. Every
command binds to the current visit/attempt, with authorization rechecked after
suspension. Progress is projected from native work; an animation cannot establish
success or commit configuration.

System-owned pickers, sharing, authentication prompts, camera/QR capture, calendar
controls, navigation chrome and reusable native control atoms remain native.
Recovery words, passcode bytes and QA configuration input remain in native-owned
credential buffers. RN chooses where those small atoms appear and commands the
surrounding task. No native component accepts a flow name and renders an entire
retired app screen.

Native runtime ownership begins in RN's managed `RCTInitializing` instance hook,
before requests or module invalidation. Codegen's discovery-only allocations and
native chrome snapshot observers acquire no runtime lease. This lets final
renderer teardown release native-origin credential entries even before their
first RN command, without a discovery instance keeping those entries alive.
Snapshot observation starts separately on the first JS method, after codegen has
installed its event callback. Eager observation during managed initialization
would race that callback's installation on the requesting JS thread. Teardown
removes the callback observer and retires the runtime lease independently.

The independent authentication window retains its system navigation bar. RN sends
the localized title and Cancel action metadata to the existing authentication
request before mounting its body. This preserves the original system bar geometry
and tint without introducing a second navigator. Header metadata cannot create an
authentication request, authorize reads or replace the native cancellation guard.

Migrated iOS adapters scope `NativeFlowMetrics` to their tasks: authored point
geometry remains fixed while the actual viewport and Dynamic Type stay active.
Public preferred-UIFont measurements preserve semantic font sizes and multiline
leading. Caller-specified typography remains explicit, and native inline
symbol-and-text measurement owns only one text run. DNS instruction rows inject
the native first-baseline envelope through a small layout port. These iOS
bindings do not change ordinary RN sizing or supply Android's typography. QA glyph
ports retain the original system SF Image leaf to preserve native image placement;
RN supplies its symbol, point size, weight, tint and allocated slot.
Passcode typography uses the same measured system Text atom for each title,
supporting sentence and error. RN supplies the text, semantic font, weight,
colors, box and multiline alignment, and composes the gaps and surrounding body.
The native atom retains only system text measurement and rendering.

The scene security window, App Unlock gates, snapshot privacy covers, app lifecycle,
purchases, extensions, App Intents and VPN/DNS services remain native. Privacy
covers must work before private RN content can mount; their availability does not
depend on JavaScript read permission.

Files formerly named after settings pages can still hold live data adapters:
`CustomizationSettingsView.swift` supplies Guard availability/copy;
`LegalVersionSettingsView.swift` supplies version/diagnostics data;
`DiagnosticsNetworkActivity.swift` supplies network-event presentation metadata.
`UpgradeSettingsView.swift` contains only `LavaPlusPresentation` offer/pitch helpers
and the system subscription-management action; its native sales screen and
fallback destination are retired. The RN Plus sheet keeps native navigation
containment and requires its initiating context.
`BackupSetupView.swift` and `BackupRestoreView.swift` now contain native session
owners rather than SwiftUI screen bodies. `ReviewReferenceContent` supplies catalog
and legal content to both the fixture host and production RN app.

## Adopting the flow modules on Android

Import the state/command contracts and screen modules from `ReactNative/src/flows`.
Provide the same native-confirmed projection and narrow command ports from the
Android services; do not reproduce transaction, entitlement or authentication
rules in a renderer. Platform-specific picker, scanner and secure-input atoms are
injected through ports. Secret values are deliberately absent from the contracts.

`flows/ui.ios.ts` maps semantic UI components to the existing iOS visual owners.
Android supplies `flows/ui.android.ts` and the app's shared foundation/control
mappings. The platform-neutral mapping fails explicitly until supplied; it never
loads an iOS screen renderer as an accidental Android fallback. iOS navigation,
platform prompts and app read-admission bindings stay in the adapters.

Reusing the portable `FlowInfo` composition also requires
`flows/info-ui.android.ts`, which maps its text, panel and inline symbol/text
leaves. Each platform owns the corresponding font metrics, wrapping and measured
height; UIKit measurements and SF Symbol names are not Android defaults. No
Android application or production adapter is delivered by this migration.

Keep these platform mappings on the same `.ts` extension: Metro checks extensions
before platform suffixes, so a portable `.ts` file can shadow an `.ios.tsx` file.
The production bundle verifies that the intended iOS mappings were selected.

System alert adapters receive RN-authored localized copy, button roles and a
semantic app/confirmation tint. iOS retains the native SwiftUI system alert
component to preserve system presentation and button styling; it does not retain
an app-owned SwiftUI screen. Their result selects a guarded RN callback;
showing a dialog never authorizes its mutation or refreshes private reads. iOS
binds each request to the existing owner, stage and read grant, and cancels it on
privacy revocation or owner retirement. Alert results and exact-request cleanup
remain independent of the ordinary command queue, so a pending dialog cannot
block Close. Android should preserve this lifetime and command separation.

The preparation motion model is shared and deterministic. It receives native
progress values and uses the same 550 ms determinate fill with either Reduce
Motion setting. Decorative title/mascot motion keeps the accessibility policy.
An attempt-scoped acknowledgement after confirmed native success and the
visible final fill releases the native presentation hold. A native eight-second
terminal deadline also bounds missing-renderer cleanup; one admitted success
layout can extend it by two seconds to finish the visible sequence. Native and
RN requests share one attempt-scoped announcement claim. Inline nonactive saves
and silent Focus switches retain their existing ownership and pacing.

## Why the base Xcode project remains

`project.yml` and its generated, committed `LavaSec.xcodeproj` define native target
membership, packages, signing identities, resources, capabilities and extension
embedding. The RN generator derives its workspace from this graph and checks it
for drift. This is build metadata, not a second app UI. Directly compiling its
app target fails with an instruction to prepare the RN workspace; it cannot
silently launch a placeholder. Native extension targets and core packages retain
their existing ownership.

## Build/release transition

The internal light-build lane, public simulator build, CodeQL build, local VPN
smoke script and both runner release lanes use the RN workspace. Merge the
companion [lavasec-runner PR #42](https://github.com/lavasecurity/lavasec-runner/pull/42) before any new release dispatch. Current runner
workflows reject `ui=native`; historical version-1 releases require their
historical source and runner revision. Private builds stay self-hosted.

The retired website/App Store screenshot scripts cannot exercise current RN
screens. Use `ReactNative/scripts/build-review-host.sh` for fixture captures or
`build-full-app.sh --journeys` for production-controller journeys. Store-ready
capture automation is a separate task.

## Verification ownership

Source assertions for deleted SwiftUI layouts are retired with their subjects.
Live rendering, accessibility and navigation are covered by RN's component
and route suites (`review-screens`, `settings-compositions`, `filter-route`,
`guard-material`, `full-sheet-header`, `app-queries`). Native source contracts for
fresh authentication, import completion/privacy, export privacy, filter editing,
backup and stats sampling now inspect the RN bridge entry points. Core service,
controller, tunnel and transaction tests remain in the Swift suite.

`RNOnlyAppSourceTests` rejects retired files on disk, in both app project manifests
and in the source-test registry, and checks the native compile graph for replaced
scaffold declarations. React-owned foreground routes have no fallback SwiftUI
render branches. Native game/state tests remain; RN component and full-app tests
own onboarding and Sudoku presentation. RN review and foreground-flow tests own
change-row accessibility; native tests retain preparation and shared glyph wiring.
Sharing uses the RN detail route and authenticated `share.query`, `share.card` and
`share.copy` commands; the unused `share.present` native route is retired.

## Packaged JavaScript

Both iOS bundle modes keep source-bearing maps in separate `.map` artifacts for
freshness verification and symbolication. Only the JavaScript is an app resource.
The bundler and packaged-app verifier reject embedded source maps; the latter also
rejects accidentally copied private sidecars. `ios-bundle.test.mjs` exercises the
pinned Metro implementation and those artifact boundaries.

Release and QA asset catalogs use Xcode's space optimization. The primary icon,
all seven alternate icons and their appearance variants remain configured; Debug
keeps the compiler's default optimization. Icon sources and selection mappings
retain their existing owners.
