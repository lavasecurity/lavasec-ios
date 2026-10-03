# React Native iOS review build

Open **Lava UI Review**, then **Open React Native**. The app has a separate bundle
identifier and preference domain. The native welcome screen explains the preview
boundary before opening the UI. Double-tap with three fingers (or use VoiceOver escape) to return to it
and destroy the React runtime. This keeps review controls outside product chrome.

This is a screen review build for LAV-168, not the completed parity gate.
The production app still uses SwiftUI. Android remains a later decision.

## Suggested review route

1. **Guard**: inspect the native guardian, protection panel, colors, typography,
   and native Liquid Glass tabs. Turn On explains the preview boundary.
2. **How Lava filters**: switch the educational connection state, inspect the
   diagram, open **Your filters**, and return using native back gestures.
3. **Now filtering** opens a saved filter. Tap **Edit filter**, then **Block a domain**,
   enter `tracker.example.net` and submit. **Review changes** opens the native-style
   review sheet; confirmation remains disabled in the isolated host. Cancel editing
   asks before discarding changes. Allowed exceptions have their own entry sheet.
4. Switch to **Settings**, then back to **Guard**. Each tab retains its stack.
5. On the native welcome screen choose **Activity sample → Empty/Example**, then
   open **What Lava has caught**. Activity has the native calendar/Today toolbar
   control, digest panel, domain-log routes and Privacy & Data link. **Today** opens
   the original SwiftUI **Change Dates** sheet. Close discards the draft; Show Activity
   confirms it. The example contains 3,246 requests on today only (2,648 allowed,
   598 blocked); ranges excluding today are empty. Seven days is retention copy,
   never an invented range switch. Fixture selection stays outside Activity.
6. **Settings → Customization**: change Light/Dark/System with the native segmented control. This is a real native
   preference round trip. Close/reopen React or relaunch the app to check persistence.
7. **Lava Guard** opens a sheet with Original selected and native locked progress rows.
   The fixture starts at zero days on the Free plan; it does not unlock paid artwork.
8. Explore the remaining Settings routes. The welcome screen’s **Open component gallery** opens review fixtures outside the product Settings screen.
   The pending-confirmation choice fixture emits your request while keeping its
   confirmed selection; the disabled choice retains native disabled behavior.

## What is native, shared, and still incomplete

| Surface | Current review implementation | Remaining work |
|---|---|---|
| Tabs and navigation | UITabBarController with native-stack per tab; iOS 26 Liquid Glass; native SF Symbols | Production auth/deep links, exhaustive reselect/rotation/device checks; Android mapping |
| Guardian | Existing `SoftShieldGuardian` hosted in a small Fabric component | Production availability/selection command, gratitude/easter eggs, interaction parity |
| Appearance | Existing native service, revisioned snapshots and persisted settings | Production protected-settings entry and full text-size integration |
| Guard / Filters / Activity | React Native layout and navigation, empty/example states, preview draft diff | Native feature snapshots/commands, complete controls/charts/menus, matched reference evidence |
| Other Settings routes | Native reference scaffolds: grouped rows, toggles, DNS providers, legal catalog, staged Feedback, and account/backup gating | Conditional signed-in/paid/error states, native commands/auth/purchases/reporting, and remaining visual/interaction audit |
| Text entry | Small native UIKit field/text-view components; native editing buffer, explicit reset and final submission events; production `DomainName` normalization | Device/IME matrix and remaining platform mapping |
| Rows, cards and text | Lava token colors, spacing, SF Symbols, Dynamic Type enabled | Exhaustive typography, truncation, accessibility, pressed-state and animation comparison |
| Choice controls | Semantic values/labels mapped to UIKit segmented controls; native selection, sizing and accessibility; React owns confirmed state | Matched reference appearance/interaction evidence, VoiceOver and large-text/device matrix; Android mapping |

The review app cannot start a tunnel, change production filters, authenticate,
request notification/camera permissions, purchase products, send feedback, or
create a backup. Those controls explain their unavailable status. Only the
appearance preference persists. The review welcome screen owns Activity fixture selection. Filter drafts and other interactive settings are review
session state. Sharing generates a real code/QR for the fixed curated-list fixture;
Copy writes only that fixture code to the clipboard, and Share opens the iOS share sheet. No preview action is reported as a successful native transaction.

The [reference audit](REFERENCE-PARITY.md) records screen-specific mismatches. A native
control mapping or passing UI journey does not establish screen parity.

[Captured review screens and validation](https://github.com/lavasecurity/lavasec-infra/blob/main/docs/review/ios-react-native-initial-host/2026-09-07-screen-review/README.md).

## Rebuild and artifacts

With the pinned toolchain in `ios/README.md`, run from the repository root:

```sh
bash ReactNative/scripts/build-review-host.sh
```

The recipe verifies the dependency boundary, builds with a bundled production JS
transform (no Metro connection), runs simulator UI journeys, and exports:

- `.artifacts/review-host/LavaSecUIReview-Simulator.zip`: unsigned arm64 simulator app.
- `.artifacts/review-host/screenshots/`: screenshots attached by the UI tests.
- `.artifacts/review-host/test-summary.json`: native test outcome.
- `.artifacts/review-host/generated-graph.json`: verified native dependency graph.
- `.artifacts/review-host/xcodebuild.log`, `runtime-metrics.json`, `build-cost.txt`.

Paths above are relative to `ReactNative/`. This ZIP is for an Apple Silicon iOS
Simulator, not an installable iPhone IPA. Device signing/TestFlight distribution
is not introduced by this slice. Neither passing tests nor these preview
screenshots constitute a 100% visual parity claim.

Native navigation reference:
[React Navigation native bottom tabs](https://reactnavigation.org/docs/native-bottom-tab-navigator/)
uses UITabBarController on iOS and BottomNavigationView on Android. The currently
unstable tab API is pinned and confined to the review shell. Android should own
its semantic mapping rather than inheriting iOS appearance settings.
