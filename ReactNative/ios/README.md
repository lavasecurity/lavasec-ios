# Isolated iOS review host

`LavaSecUIReview` is an isolated app with its own preference domain. Debug and
Release remain unsigned Simulator configurations. `QAReview` is a Release configuration
for TestFlight device review under the existing QA bundle ID `com.lavasec.dev.qa`. It uses the existing iOS 18 deployment floor. Its native fallback opens
React Native lazily and remains available after closing the React screen. The
production `LavaSec.xcodeproj`, tunnel, widget, and App Intents targets have no React
dependency, JS entry point, CocoaPods integration, or changed entitlement.

## Service and lifecycle

`AppearancePreferencesService` in LavaSecAppServices owns the existing native
appearance key. Production CustomizationController delegates its load/set commands
to that service. The review app creates the same service against its isolated
UserDefaults suite (`com.lavasecurity.lavasec.ui-review.appearance`); JS never reads
defaults or implements persistence. This also isolates appearance from the native QA
app when TestFlight replaces that app under the same QA bundle ID. The lifecycle
journey seeds a native QA preference and verifies it survives RN changes and relaunch.

`NativeLavaAppearance.ts` generates a TurboModule command/snapshot/event contract.
The native adapter uses the main queue, subscribes only when a runtime calls it,
and synchronously removes its observer before module invalidation completes. The
codegen discovery-only provider instance acquires no observer. Service lifetime
belongs to the app, so closing React does not erase accepted native preferences.
The JS store subscribes before reading, rejects stale revisions/connection epochs,
and waits for native confirmation. Reconnection/foreground reads do not replay
commands. Screenshots, native lifecycle results, and measured costs are in
[the initial evidence](https://github.com/lavasecurity/lavasec-infra/blob/main/docs/review/ios-react-native-initial-host/2026-09-07-host/README.md).

## Build and dependency boundary

Tooling is pinned to RN 0.87.1, React 19.2.3, CocoaPods 1.16.2, xcodeproj 1.27.0,
Ruby 3.3.12/Bundler 4.0.16 in CI, Node 24, and XcodeGen 2.45.4. CocoaPods is the
supported native integration; the new experimental RN SwiftPM integration is not
used. npm, gem, and pod lockfiles pin the dependency graphs.

`project.json` is a closed XcodeGen input for the review app and its UI tests.
Generated projects, Pods, codegen output, and JS bundles are ignored. No generated
project is hand-edited. `review-host-policy.mjs` validates the input, and the generated
graph check pins app sources/resources/package products, all dependency target
identities, script-phase bodies, and the hashes of the inspected script files.
`native-dependencies.json` records those approved RN/CocoaPods outputs; it is not an
automatic baseline updater. Native dependency/tool upgrades require reviewing its
changes and rerunning the policy fixtures and native lifecycle test.

`ModuleBoundarySourceTests` explicitly classifies both non-production targets.
Root production project guards retain their original policy. The native build
recipe also verifies CocoaPods left the root project and manifest byte-identical.
Review-only CocoaPods script execution is never admitted into a production target.

From the repository root, with the pinned Ruby/Node tooling on PATH:

```sh
bash ReactNative/scripts/build-review-host.sh
```

This installs pinned dependencies, generates and verifies the workspace, creates a
private simulator, runs the lifecycle test, and exports evidence plus an unsigned
simulator app to `ReactNative/.artifacts/review-host/`. It deletes its temporary
build/gem directory and its own simulator on exit. CI runs the command under the
existing maintenance lock, uploads the artifact for seven days, and removes its
installed review dependencies. The native job runs only for owned private PRs;
public/fork CI continues running the JS and policy checks on Linux.

For iterative work, use `npm ci --ignore-scripts`, `npm run bundle:review`, generate
`ios/LavaSecUIReview.xcodeproj` from `ios/project.json` with XcodeGen, and run `bundle exec pod install --deployment`
from `ios/`. Open `LavaSecUIReview.xcworkspace`, not the production project.

The host has native Guard/Settings tabs, a separate native stack per tab, focused
SF Symbol/guardian components, native UIKit text editors and segmented controls, and the screen journeys in [the review guide](../REVIEW.md).
React Navigation native bottom tabs 7.18.18, native-stack 7.18.10, native 7.3.18,
react-native-screens 4.27.0, and safe-area-context 5.9.1 are pinned. The two new
Pods are static libraries with no additional scripts or frameworks. The extra
Lava products are Presentation for the existing guardian animation and Kit for
domain normalization. The shared activity-attribute file supplies the guardian
style value type. No Live Activity
is started by the review app.

Production feature adapters, authorization, localization/text-size integration,
and complete visual/interaction parity remain in 2B–2F. Reverting the host leaves existing native preferences
compatible. This checkpoint does not complete milestone 1 or 2.

## Full-app TestFlight QA and historical native source

This directory is the isolated Simulator review host. Device QA uses the complete
application in [native-app](../native-app/README.md), which is the authoritative
release runbook. The trusted `lavasec-runner` `release-qa.yml` workflow accepts
`ui=react-native` and an immutable `rn-qa-vX.Y.Z-rcN` source tag whose version matches
`Config/Lava.xcconfig`. Old `rn-review-*` preview tags are rejected.
Run with `dry_run=true`, inspect the signed IPA and archive receipt, then run the
same tag with `dry_run=false`. The full app includes the real native runtime,
tunnel, widget, App Intents, and RN foreground screens under **LavaSec QA** in
TestFlight. The isolated host and its fixture limitations do not describe that build.

**Lava Security** uses the production app identity and can stay installed alongside
LavaSec QA. Plain version-2-or-higher RC tags select the complete RN app in both
TestFlight lanes. Explicit `-rn` tags remain QA-only. Both current runner workflows
accept only `ui=react-native`; plain version-1 RC tags are rejected by the current
dispatcher. Manual QA requires an immutable RC tag, or a full merged commit SHA
with `dry_run=true`. See the [full-app release runbook](../native-app/README.md).

The source tag `native-ui-reference-2026-09-08` preserves historical commit
`ab431736f50afc3dc697a7f390aadc0fa50610fb`. Rebuilding that SwiftUI application
requires its historical source **and runner workflow revision**. Current source
retains `LavaSec.xcodeproj` only as the native target manifest used to generate and
validate the RN workspace; its app target cannot build a standalone SwiftUI UI.
Installing an RN QA build replaces the previous **QA** build, not **Lava Security**.

The only generated dependency-script changes for QAReview repeat the existing Release
framework/resource installation blocks for that configuration. Removing those two
new blocks reproduces the previous reviewed SHA-256 hashes exactly. Pod versions and
checksums are unchanged; only the Podfile checksum records the configuration mapping.
