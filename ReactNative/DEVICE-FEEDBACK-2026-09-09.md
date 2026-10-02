# RN device feedback — 2026-09-09

Baseline: `v1.5.0-rc3-rn`, LavaSec QA `1.5.0 (1788946040)`, source
`38a1f8c4bb350f0b5c47d4b7a3c03c5ed12824fc`. The operator completed a phone
review and authorized fixing the full batch and delivering another tagged QA
build. Prior simulator qualification did not establish these device outcomes.

| ID | Report and required result | Evidence / status |
| --- | --- | --- |
| D01 | Sudoku cell haptics are too strong; reuse the native cell-selection feedback. | Native tap versus 6-point drag semantics restored; board scrubbing uses selection feedback even over givens. React Sudoku tests pass; physical strength remains a phone check. |
| D02 | Sudoku top controls are clipped into the status bar; retain native safe-area layout. | Full-screen Sudoku owns its SafeAreaProvider. Native iPhone 16 toolbar starts at y=67 below its 59-point safe area; screenshot and journey pass. |
| D03 | A loading indicator flashes on every app launch; present the full app without that flash. | RN receives its first authoritative snapshot in native initial properties. Regression fails on RC3 and passes here, including a delayed older snapshot. |
| D04 | Guard's Turn on interaction and haptic feel good; preserve them. | Protection button and native protection haptic path unchanged. |
| D05 | Automatic filter refresh plus repeated Edit taps stalls, then crashes near entry to edit mode. Exclude competing operations and preserve navigation/draft lifetime. | Refresh no longer occupies the JS mutation queue. Edit is single-flight in JS/native, rechecks its presentation epoch after authentication, and preserves an existing draft. Deferred-refresh/repeated-Edit regression passes. No crash log was supplied, so the exact reported crash cause is unconfirmed; native refresh plus eight repeated Edit taps produces one clean draft and cancels successfully. |
| D06 | Opening Extra / the list in use sometimes stalls; investigate refresh blocking entry. | Filter open/close reach native independently of refresh. A held-refresh regression blocks on RC3 and completes here. Native catalog network/compile work already runs asynchronously. |
| D07 | Guard → Settings movement is irregular. Repeated tab taps from nested pages return to that tab's root. Guard at root stays still; Settings already at expanded top stays still; scrolled Settings returns to native compact-title top. Native navigation/scrolling should own this behavior. | UIKit owns repeated-tab pop and adjusted-inset scrolling. Removed the JS scroll offset. Protected Settings entry remains authenticated. The complete native pass confirms unchanged tab-bar position, expanded/compact behavior, both nested stack pops and inactive-stack retention. |
| D08 | Moon and refresh glyphs shift horizontally during transitions; keep a common center. | Shared native toolbar items use equal 44-point slots for moon and refresh. Native frame comparison passes within one point. |
| D09 | Plus mascot must animate awake → smile, not remain at the smile/grateful pose. | Both presentations use shared GuardianThankYouAnimation: awake → grateful → awake with native 650/900 ms timing and the selected Guard look. Native animation wiring tests pass; subscription phone state remains an acceptance check. |
| D10 | Customization's Lava Guard row is too narrow; match native dimensions and spacing. | Guard row uses native 52×64 leading frame, 48-point mascot and 96-point row floor. Native 96-point row geometry and screenshot checks pass. |
| D11 | Switches sit above row centers; correct the shared toggle scaffold and verify every consumer. | Shared Fabric control centers and measures UIKit UISwitch intrinsic bounds (63×28 on tested iOS 26 versus RN’s legacy 64×34 slot). Pending changes block duplicate input without dimming; completion/cancellation reconciles the authoritative value. Component cancellation regression passes; native switch/label center comparison passes within 1.5 points, and a preference change persists through relaunch. |
| D12 | IP is missing from DNS transport; preserve native choice availability. | Primary and fallback expose the selected native provider’s available transports, including IP. Removed forced fallback IP→DoH conversion. Executable DNS runtime test verifies Device DNS plus plain-IP alternative. |
| D13 | Remove redundant explanatory copy below DNS transport. | Removed both trailing transport explanations from RN and SwiftUI; retained native provider and Device DNS descriptions. Native source checks pass. |
| D14 | Changing conditional settings causes visible flicker; keep stable layout and native state. | Stable DNS content container gates touches while saving without dimming/remounting every conditional control. Shared toggle retains its pending appearance and reconciles on completion. Eight competing-callback success/cancellation cases pass. |
| D15 | Nerd Stats changes after a DNS setting mutation, without an observed VPN indicator flash. Verify applied tunnel configuration and DNS behavior, not only displayed preferences. | Traced RN setters through native configuration persistence, reloadConfigurationMessage, provider forced refresh, resolver-identity comparison and DNS runtime/network-settings reapplication. Existing native runtime tests and new IP-alternative test pass. No physical packet/tunnel measurement yet; Nerd Stats and VPN icon alone are not proof of applied traffic behavior. |
| D16 | Account must use the native partial-height sheet. | Outer native host now sets the Account UIKit custom detent from the same shared 288/332-point helper as SwiftUI. Signed-in presentation remains a phone acceptance check. |
| D17 | Standard exports must exclude domain history and expose no opt-in. Any inclusion capability must remain QA-only. | Removed standard UI opt-in from both versions. Both ordinary export callers force includeDomainHistory:false; bridge ignores a forged domains request. QA archive support remains separate. Export/privacy regressions pass. |
| D18 | Export shows an empty intermediate sheet; present the real export flow directly. | Native host presents UIDocumentPicker directly, with no empty SwiftUI export host. Its own protected temporary file is cleaned on save/cancel/failure. Native journey verifies the actual Files filename field, pull-down cancellation and immediate return to an enabled Export action. |
| D19 | Share QR concealment is too weak and layered; prefer a single stronger blurred pane. | Both presentations use one 24-point blurred background filling the entire rounded card, including its padding. This incorporates the follow-up rejection of an inset square. Reveal controls are centered; revealing preserves the square QR and white scanning margin. Dark Simulator render checked; the light-appearance Share journey also passes. |
| D20 | Taking a screenshot and returning to Lava clears Share detail into Loading / Unavailable before the QR returns. | Only share.query can retain the same filter scope during inactivity; the QR separately conceals. Errors, missing/unshareable filters, changed identity and leaving the screen still clear it. Protected diagnostics continue clearing on inactivity. Interruption regression fails on RC3 and passes here; native reveal/background/resume journey passes with no Loading or Unavailable state. |

The attached phone recordings and screenshots remain in the task; account details
and private diagnostic contents are not copied into this repository. Record
observed evidence separately from hypotheses. Add regression journeys for the
reported transitions and compare their native reference behavior before release.

Release gate: complete the checklist, pass appropriate regression and native UI
checks, review and merge normally, inspect a signed dry export of the exact merged
source, then create the next unused `v1.5.0-rcN-rn` tag. Verify its single automatic
QA upload and record the actual source/version/build. Preserve the native reference.

Qualification evidence: `npm test` passes 216 React tests across 15 suites,
TypeScript, localization/token generation, and host-policy checks.
`swift test --package-path . -Xswiftc -warnings-as-errors` passes 4,744 tests.
The complete final local iPhone 16 / iOS 26.5 run passes all 12 native journeys
with zero failures or skips (499 seconds). This includes tab position and native
reselection, Sudoku/filter/toolbar geometry, native switch persistence,
Share/Files cancellation, protected imports and passcode flows, text size,
Library cancellation and inactive-filter Save. The source PR CI separately
qualifies the final head and its isolated review host before release.

Earlier local passes failed on XCTest selectors/gestures (ambiguous nested text,
a swipe landing on a control, a case-sensitive QR label, a status-bar query that
XCTest does not expose, and Files' non-hittable synthetic Cancel element).
Those passes are not counted as qualified; the corrected complete run above is.
The first PR repository gate also caught the shortened export note missing from
the native catalog. Its ten existing translations were shortened consistently,
and React translations regenerated; localization and string coverage now pass.
