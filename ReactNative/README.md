# Lava React Native iOS presentation

The full Lava application now has an RN foreground composition in
[`native-app`](native-app/README.md). It retains the native engine, extensions,
authentication and feature controllers. The isolated host described below remains
a development fixture; phone QA must use the full-app build.


This private package contains the **2B component foundation** and an isolated
**2A native iOS review host** for [LAV-168](https://linear.app/lavasecurity/issue/LAV-168).
The host now opens a Guard/Settings review shell with native iOS tabs and stacks,
React Native screens, native SF Symbols, and the shared SwiftUI guardian drawing.
Appearance uses typed commands and confirmed native snapshots. Activity now reuses
the production SwiftUI date-range sheet behind a typed date-selection command. The welcome screen explains the isolated sample data used by feature
screens; they cannot run a VPN or
apply a production filter. See [the review guide](REVIEW.md) for the route and gaps. Production SwiftUI and every extension still
build without Node or React Native. Full-screen parity work remains in progress.

The [mobile UI plan](https://github.com/lavasecurity/lavasec-infra/blob/main/plans/2026-09-07-mobile-ui-portability-and-app-view-model-separation-plan.md)
owns the remaining slices. Product UI replacement and Android implementation wait
for the operator's review of the full 2F parity build.

## Package ownership and checks

The source lives in the private iOS repository alongside its Swift reference. It is
included by the existing tracked-source export process; no separate repository,
package registry publication, or production dependency is introduced. `private: true`
prevents accidental npm publication. React Native **0.87.1** and React **19.2.3** are
pinned, with an npm lockfile for the development graph. Node 24 is used in CI; the
engine range follows the pinned React Native release. npm installation scripts are
disabled. The separate native host explicitly runs the pinned CocoaPods/codegen
integration described in [ios/README.md](ios/README.md).

From `ReactNative/`:

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm test
npm run bundle:ios
```

The bundle is written to ignored `.artifacts/LavaComponentGallery.js`. Metro
checks the actual iOS module resolution and production JS transform. Jest executes
component interactions against React Native's test environment; neither proves
native rendering, VoiceOver behavior, or visual equivalence. CI runs these checks
on code PRs, including Swift-token edits, in both private and public repositories.
Documentation-only PRs report their classification without installing dependencies.

## CI validation levels

Every code PR keeps React component, query, authentication and feature contracts,
project/dependency policies, TypeScript and both gallery and full-app bundle checks. The measured JS lane
took about 48 seconds, including 309 component/unit tests in 11.8 seconds.
Swift tests and the independent native app/extension compile remain in CI.

The **full app with RN** compile and 26 UIKit regressions run when a complete diff
contains native inputs or unknown paths. Changes confined to UI JS/TS files under
`app`, `review`, `src`, `gallery` and known fast test files, plus documentation, skip
that cold native rebuild. Generated-graph tests, bridge/codegen specs, Swift/Objective-C, dependencies, project and
build configuration always compile. Renames, missing ranges and classifier
failures cannot hide native changes. PRs and main pushes use local Git diffs,
avoiding GitHub event-filter limits; manual runs always request native validation.

The previous cold native job took about 24 minutes (17m26s in Xcode), mostly
because its isolated build directory cannot reuse Xcode's incremental compilation.
That cost is retained for changes affecting native integration and explicit checks,
instead of charging every ordinary screen edit. Signed releases still build the
complete native app through lavasec-runner.

The isolated preview app and long user-journey tours are retained for deliberate
device/parity review instead of rebuilding both apps on every edit. In the
**React Native UI** workflow, choose:

| Validation | Native work |
| --- | --- |
| `compile` (default) | Full RN app compile and UIKit scaffold regressions |
| `full-app-journeys` | Full RN app journeys, screenshots, lifecycle traces and simulator app |
| `parity-review` | Full-app journeys, followed by the isolated preview tour |

For example, run `gh workflow run react-native-ui.yml --ref <branch> -f validation=full-app-journeys`.
The native jobs remain serial when both are requested. Forks still use hosted
Linux contract checks and never execute native builds on the private Mac runner.
Dependency/SDK, native navigation, presentation or accessibility changes warrant
an explicit journey run and the relevant device checks.

`scripts/build-full-app.sh --compile` builds without XCTest journeys. Its
`validation.json` says `journeysExecuted: false`; it retains the native scaffold
report, generated graph and build log, without uploading a large simulator ZIP.
`--journeys` retains test results, recordings and the app ZIP. Calling the script
without arguments preserves the existing journey default. Neither mode signs or
uploads a device release; those continue through lavasec-runner.

## Shared API and iOS implementation

Consumers import from `src/index.ts`. `contracts.ts` expresses text/surface/action
roles, localized strings, values, and callbacks. It exposes no platform color names,
glass parameters, tunnel handles, or persistence operations. `components.ios.tsx`
owns iOS rendering; Metro's base module explicitly rejects unsupported platforms
until their mappings exist. Android does not silently inherit iOS design.

| Component | Current reference | Foundation behavior |
|---|---|---|
| `LavaText` | `LavaTypography` | Semantic Dynamic Type ramps; fixed rounded metric with tabular digits |
| `LavaCard` | `LavaPlainCard` / `LavaSurface` | Card and panel color, continuous corners, content inset |
| `LavaToggleRow` | Settings Toggle / `lavaRow()` | Headline label, minimum row floor, native switch with `safeGreen` tint, controlled value |
| `LavaActionButton` | Panel/standalone/secondary button styles | Role colors, minimum height, readable disabled state, pressed fill/scale, callback |
| `LavaChoice` | Segmented `Picker` in Customization and Activity | Stable values and localized labels; UIKit segmented control, native intrinsic height/accessibility and disabled state; controlled selection |

Controls request an action. The owning feature must supply confirmed state; the
library never infers a successful durable operation from a press. The gallery's
local state only demonstrates this controlled contract and is not a service adapter.
`LavaChoice` carries values independently of display labels/order. Its iOS Fabric
view restores the confirmed selection before emitting a request, so rejected or
pending operations retain the accepted value. UIKit owns segment accessibility
and intrinsic height; these details are absent from the shared contract.

`npm run tokens` generates `src/generated/tokens.ts` from the current
`LavaSecApp/LavaDesignSystem/LavaTokens.swift`. The older hand-maintained
`design/lava-design-tokens.json` is not used as the native parity baseline. The
parser rejects unsupported expressions instead of silently dropping definitions.
Native label colors remain `PlatformColor` references; adaptive colors resolve
with `DynamicColorIOS`. Custom RGB fractions are quantized to React Native's 8-bit
sRGB format at the iOS boundary. Typography's semantic point sizes follow UIKit;
the semantic ramp is passed to native text rather than imposing a maximum scale.

The pinned RN 0.87 Fabric renderer accepts both Swift and Objective-C color names
([native selector normalization](https://github.com/react/react-native/blob/v0.87.1/packages/react-native/ReactCommon/react/renderer/graphics/platform/ios/react/renderer/graphics/RCTPlatformColorUtils.mm#L149))
and maps `ui-rounded` to `UIFontDescriptorSystemDesignRounded`
([native font design mapping](https://github.com/react/react-native/blob/v0.87.1/packages/react-native/ReactCommon/react/renderer/textlayoutmanager/platform/ios/react/renderer/textlayoutmanager/RCTFontUtils.mm#L320)).
These mappings establish API support; they do not replace the pending device comparison.

Useful platform references:
[DynamicColorIOS](https://reactnative.dev/docs/dynamiccolorios),
[PlatformColor](https://reactnative.dev/docs/platformcolor),
[Text / Dynamic Type](https://reactnative.dev/docs/text), and
[platform files](https://reactnative.dev/docs/platform-specific-code).

## Review gallery

`gallery/index.ts` registers **LavaComponentGallery**. The 2A host supplies safe
area containment and native appearance. The full app separately uses the native
localization catalog and text-size preferences. The current gallery
includes card/panel, each text tone, fixed metric, on/off/disabled toggles, a long
label, native choices with pending-confirmation/disabled fixtures, and all three
action roles in enabled/disabled states. Its copy is review
fixture data, not product text ready for localization rollout.

The [September 7 host evidence](https://github.com/lavasecurity/lavasec-infra/blob/main/docs/review/ios-react-native-initial-host/2026-09-07-host/README.md)
records the early service and lifecycle round trip. It is historical review evidence.
Capture both implementations on the same OS,
device, SDK, appearance, language, content, and text size. Verify VoiceOver focus,
label taps, disabled actions, switch gestures, large text, and reduced motion.
No screenshot or 100% parity claim follows from the JS checks.

Known differences and remaining work:

- Action press styling currently changes immediately. The Swift reference's 120 ms
  incidental animation and reduced-motion policy need the native comparison pass.
- UIKit/SwiftUI text layout, continuous-corner geometry, panel stroke placement,
  native switch tint/disabled treatment, and color rounding need device comparison.
- The isolated host keeps fixture feature data. Native tabs/Liquid Glass, stacks,
  SF Symbols and the guardian are shared with the full application. Full-app
  feature adapters and authentication are described in `native-app/README.md`;
  signed phone testing still needs the device pass.
- The 2A review host now proves native commands, subscriptions, teardown, runtime
  recreation, foreground refresh, and persisted relaunch. It uses the same appearance
  service as CustomizationController, with a separate review-app defaults domain.
  Further feature services and platform mappings remain in their planned slices.

The former SwiftUI app is preserved only in Git history at
`native-ui-reference-2026-09-08`; current app builds use the RN workspace. RN device
review uses the separate QA identity; see the [full-app build and release
instructions](native-app/README.md).
The native appearance service retains its existing preference key; no production
data migration is involved.


## Shared UX rules

The September UX decisions are tracked in [infra review #235](https://github.com/lavasecurity/lavasec-infra/pull/235). Use these shared components when adding or changing screens:

- `LavaIconButton` takes a semantic action, accessible title, optional item and neutral/destructive/accent role. iOS maps it to a centred native glyph in a 44-point circle. An Android adapter should choose its native glyph and minimum touch target while retaining the circular shape and centred alignment. Do not export SF Symbol names or iOS colours through the shared contract. System-owned navigation buttons keep system chrome.
- `AccessorySlot` gives inline row actions one trailing column. Its centre is anchored to the existing play indicator; swapping delete, undo, lock or chevron does not move the column. Indicators do not become new actions solely because they share a slot.
- Use `AdaptivePair` for label/value rows. It stacks under width or text-size pressure without reducing the font. `DomainInput` follows the app's text-scale override and uses the native editor's measured line height.
- Action heights are minimums, not fixed text boxes. Keep disabled labels readable and indicate disabled state through native controls, colour and accessibility state; do not compound opacity on entire rows.
- Place validation and quotas before the action they affect. Use `QuietFooter` for concise supporting copy plus a destination link, with its existing 44-point target.
- Keep QR reveal/conceal variants in the same content region. Hidden QR pixels and controls stay out of accessibility. First-load query rows identify themselves as busy; refreshes retain accepted content until its identity or permission changes.
- Explain a consequence once, where the user makes the relevant choice. Omit repeated definitions, reassurance and instructions already evident from a label. Retain destructive confirmations, private-key handling and exact legal notices. Legal disclosures reduce default density without removing attribution.
- Guard identity colours come from the native canonical palette. Generic warning orange does not identify every Guard.

“Now filtering” names the selected filter independently of Guard's on/off state. That behavior is intentional.

## Native lifecycle and identity rules

The app uses the pinned RN New Architecture, generated Fabric/TurboModule
bindings, native stacks/tabs, automatic scroll insets and retained query data.
These are a foundation, not a guarantee of native lifecycle correctness.

- `LavaNativeContainment` is the one mounting path for SwiftUI feature pages and
  Guard artwork. Establish the controller parent before loading/adding its view;
  give it the container's bounds before attachment. Off-window retention does not
  revoke containment. Detach only for actual removal, parent transfer or recycle.
- `LavaNativeInteractionGate` blocks input/accessibility while authorization is
  pending without changing SwiftUI's enabled environment. Backgrounding does not
  gray out metadata or controls. Actual unavailable settings remain disabled.
  Resume still reauthorizes; native child destinations retain their own action
  authentication, and callbacks from a recycled route cannot affect a new visit.
- `Group` preserves child keys. Conditional insertion/removal must retain the
  identity, draft and native control state of surviving rows. Callers that reorder
  collections must supply stable domain keys.
- React owns the outer route and tab stack. The current VPN adapter retains its
  native child stack for configuration/DNS/Plus flows; treat this boundary as a
  required transition test, not a pattern to copy casually to new pages. Avoid
  fixed inset corrections, timing delays and disabling animations to hide jumps.
- Native tabs use a pinned experimental API behind one adapter and a checked
  compatibility patch. Recheck reselection, scroll-to-top, child navigation and
  safe areas on dependency/SDK upgrades. Do not change freezing or detachment
  defaults without evidence and lifecycle tests.

Routine CI executes the production UIKit scaffold in a small simulator test app
alongside the full-app compile (`scripts/test-native-containment.sh`). On-demand
full-app journeys additionally exercise native child navigation, protected resume,
configuration metadata/geometry retention, and Fabric recycling. Jest verifies
conditional row insertion does not discard an existing editor's draft. Settled
screenshots alone are insufficient evidence for a transition fix.
