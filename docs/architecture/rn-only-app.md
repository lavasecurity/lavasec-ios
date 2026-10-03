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

## What remains native

RN still opens import/code/photo/QR scanning and review, account management,
backup setup/restore, passcode, filter creation/rename/delete, custom blocklist,
custom DNS, feedback, license and QA/VPN flows. Their SwiftUI scaffolds remain.
Onboarding, app lifecycle/security, purchases, mascot rendering, file and share
sheets, extensions, App Intents and the VPN/DNS services also remain native.

Files formerly named after settings pages can still hold live data adapters:
`CustomizationSettingsView.swift` supplies Guard availability/copy;
`LegalVersionSettingsView.swift` supplies version/diagnostics data and licenses;
`DiagnosticsNetworkActivity.swift` supplies network-event presentation metadata.
These are consumed by the RN bridge. `ReviewReferenceContent` supplies catalog
and legal content to both the fixture host and production RN app.

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
Live rendering, accessibility and navigation remain covered by RN's component
and route suites (`review-screens`, `settings-compositions`, `filter-route`,
`guard-material`, `full-sheet-header`, `app-queries`). Native source contracts for
fresh authentication, import completion/privacy, export privacy, filter editing,
backup and stats sampling now inspect the RN bridge entry points. Core service,
controller, tunnel and transaction tests remain in the Swift suite.
