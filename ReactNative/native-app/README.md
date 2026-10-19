# Full Lava app with React Native presentation

This target is derived from the complete native application project. It retains
its app delegate, app-group storage, packet tunnel, widget, App Intents, background
tasks, authentication, purchases, security gates, and native feature controllers.
The foreground presentation is React Native. `LAVA_REACT_NATIVE` identifies the
RN integration for shared native components. `LavaSec.xcodeproj` is the generated
native target manifest used to validate sources, signing and extensions; build
the app through `LavaSecRN.xcworkspace`. The former SwiftUI tab app is retired.
The isolated `ios/LavaSecUIReview` project remains a fixture tool, not a phone QA
release candidate.

The RN adapter attaches to `LavaProtectionShortcutRuntime.shared`; it must never
construct a second foreground AppViewModel or make optimistic protection claims.
Native commands enforce the original authentication and transaction boundaries.
RN owns app screen and task composition; the shared root retains native service
owners, system dialogs, navigation chrome and bounded platform control atoms.
See the [current ownership contract](../../docs/architecture/rn-only-app.md).


Install the [build prerequisites](../../README.md#building), then
build with `bash ReactNative/scripts/prepare-full-app.sh /absolute/build /absolute/evidence`,
then use `ReactNative/native-app/LavaSecRN.xcworkspace`, scheme `LavaSec`.
`build-full-app.sh` defaults to creating its own Simulator, running real-controller
UI journeys, and exporting the app and evidence. `--compile` builds the complete
app without journeys; `--containment` runs only the independent UIKit regression
app without RN preparation or a complete app build. Simulator tests use ad-hoc signing so native
keychain/app-group gates remain active. A direct app build of `LavaSec.xcodeproj` fails with instructions to prepare
the RN workspace, preventing accidental placeholder or legacy app builds.

The preparation script preserves the tracked project byte for byte and checks
all native targets, sources, resources, identities, signing settings, extensions
and entitlements against it. Only the explicitly listed RN additions and pinned
CocoaPods phases are accepted. `configure-native-tabs.mjs` applies a hash-checked
adaptation to the pinned navigation package: UIKit owns repeated-tab pop-to-root
and scrolling using its current adjusted content inset. Only Guard's root scroll
is disabled. Protected Settings entry authenticates before selection; its active
tab still accepts native reselection.

VPN chaining, account connections, backup setup/restore, import, filter
preparation, passcode setup/authentication, DNS help and Device QA use RN screen
composition. Their commands use the existing foreground runtime and enforce
native authentication, limits, review identity and commit boundaries. Native
credential buffers keep recovery words, passcodes and private configuration out
of JavaScript; system authentication, file/photo pickers, scanner capture,
sharing and calendar controls remain native. Date ranges, domain history,
pagination, local-log settings and Sudoku use the native stores. RN text metrics
and translated copy come from the native customization settings and localization
catalog. Migrated iOS tasks retain authored point geometry and native semantic
text metrics through their scoped adapters; ordinary RN window sizing is unchanged.

Plain `v2.0.0-rc1` and later version-2-or-higher RC tags dispatch the complete RN
app to both TestFlight lanes: production identity (`com.lavasec.app`, internal
testers) and QA identity (`com.lavasec.dev.qa`). Both lanes validate the exact
source, version and signed archive before upload. Runner support for both RN
lanes must be merged before tagging; the dispatcher uses runner `main`.

Explicit `vX.Y.Z-rcN-rn` tags remain QA-only. For a QA rehearsal, use the merged
source SHA with `ui=react-native` and `dry_run=true`, then inspect the signed IPA
and archive receipt. Do not manually duplicate a tag-triggered upload. Historical version-1 builds require their historical source and runner revision. Neither an internal
RC nor a production app identity authorizes an external/App Store release.
See [the behavioral contract audit](../FULL-APP-CONTRACT-AUDIT.md) for route coverage and release gates.
Old `rn-review-*` tags are fixture builds and are rejected by the full-app lane.
The retired SwiftUI application remains available in Git history at
`native-ui-reference-2026-09-08`; it is not a current build or release option.
