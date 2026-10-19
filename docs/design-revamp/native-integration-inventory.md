# Native integration and shared visual system

This inventory belongs to `feature/newui-v2`. It describes the full application,
not the isolated RN preview target.

## Shared owners

| Concern | Canonical native owner | RN relationship |
| --- | --- | --- |
| Adaptive colors, spacing, surfaces and typography | `LavaSecApp/LavaDesignSystem/LavaTokens.swift` | The token generator reads these semantic declarations. Page is warm cream / neutral charcoal; generic information and cards use neutral surfaces, and story surfaces opt into soft green. |
| Glyph chrome and role states | `LavaScaffold.swift`: `LavaCircularIconLabel` | Native toolbar and inline wrappers use one 44-point circle. Valid confirmation fills green; disabled, destructive and ordinary actions keep their respective semantics. |
| Native SF Symbols in RN | `ReactNative/ios/LavaSecUIReview/LavaDecorationContent.swift` | Maps semantic tones directly to `LavaStyle`, including regular-weight utility glyphs. No parallel hardcoded green palette. |
| Forms, rows, field cells and actions | `LavaComponents.swift`, `LavaCondensedList.swift`, `LavaSelectableRow.swift` | Native task rows use 17-point Dynamic Type titles and 15-point supporting copy. Native recovery display and entry share one field surface. |
| Task layout and fixed footer | `LavaTaskSheet`, `LavaSheetScaffold` | Shared page, navigation and footer materials; content scrolls independently of primary actions. |
| Completed task | `LavaSuccessScreen` | Circular green check, title and stable message centered in available content space; large text scrolls and Done remains at the bottom. Onboarding may retain its mascot. |
| Artwork | Existing `SoftShieldGuardian` and canonical shield assets | Existing selected identity is preserved. Native glyphs do not substitute an unrelated mascot. |

Default info panels no longer draw an implicit border. Deliberate warning or
selected-Guard accent outlines use inset strokes, so their width is not clipped
by the surface boundary. Semantic danger red and orange caution remain distinct.

## App journeys and retained native elements

The supported app root is React Native. All app-owned screen composition and
stage navigation live in RN, including preparation, import, account/backup,
passcode, DNS help and internal QA. See the [ownership contract](../architecture/rn-only-app.md)
for the reusable modules and Android adapter boundary.

| Journey | RN owns | Native retains |
| --- | --- | --- |
| Filter preparation | Phase/progress, Guardian, success/failure, recovery controls | Current attempt, real compilation/apply, recovery capabilities, haptics, completion/dismiss authority |
| Filter import | Method/code/scanner instructions, review/replacement, applying/completion | Photo picker, camera capture, bounded decode, fresh authentication, reviewed transaction and once-only completion |
| Account connections | Connections, sign-out and delete-account presentation | Provider authentication, server operations, initiating-account checks |
| Backup setup/restore | Steps, explanations, consent, review, progress and completion | Passkey prompts, recovery credential atoms, cryptography, reviewed commit, account-bound persistence and upload |
| Passcode setup/authentication | Titles, messages, typography choices, body layout and navigation commands | System authentication bar, measured system Text and input/digit atoms, credential bytes, verification/storage, biometric prompts and scene security window |
| Custom DNS/blocklist and VPN configuration | Existing RN forms and editor | Native buffer for private configuration, validation, persistence, file picker and apply |
| DNS help and automation | Instructions and destination actions | Opening system Settings/Shortcuts/browser |
| Device QA | Search, rows, forms, results, guided checks and modal stages | Eligible-build gate, privileged QA actions, confidential configuration atom and system control atoms |
| Sharing/export/calendar | App-owned selection/detail presentation | System share/file sheets and calendar date controls |

Native hosts retain UIKit containment, detents, navigation chrome, keyboard
integration and privacy overlays. Small native UI atoms may render platform
controls; a whole retired SwiftUI task is not retained behind an RN wrapper.

Import waits for Done before delivering its completion callback, with a once-only
guard. Applying/completed stages cannot dismiss interactively. Replacement
preserves the existing target name. Backup setup confirms local encrypted setup;
cloud upload remains asynchronous and the completion copy makes no upload claim.

Install-over compatibility remains with the native owner. Pending account deletion
blocks backup writers, completed Off overrides stale preferences, and retries
stay bound to the initiating account. Setup/restore can replace completed Off only
after local persistence succeeds. Native service tests and RN behavior tests cover
those boundaries; source assertions alone do not qualify visual/device behavior.

## Truthful connection and Guard data

`AppSnapshot.connection` is an additive optional projection used behind Settings'
existing authorization boundary. It contains the active saved filter identity and
count, the primary resolver and enabled configured fallback from
`resolverLadderInputs`, and VPN visibility eligibility plus the user's chaining
preference. Resolver order is not reconstructed in JavaScript.

The VPN preference is not a health reading. `configured`, custom name and status
are optional and remain absent when they have not been inspected. The recurring
snapshot must not read `chainedUpstreamSurfaceStatus`: that opens the configuration
store and Keychain and may block for up to 250 ms. Detailed VPN inspection belongs
to its existing authorized destination.

`protection.today` carries the current calendar day's permitted aggregate allowed
and blocked counts and whether counting is enabled. This uses `dailySummary(on:)`
so crossing midnight cannot relabel yesterday's summary as Today. There is no
public intraday bucket series in the current store; Guard must omit the mini chart
rather than derive it from protected domain history or invent a distribution.
The changes add no timer, per-request observer, domain read or log export.

## Responsive host contract

The full app already targets iPhone and iPad (`TARGETED_DEVICE_FAMILY = 1,2`).
The new candidate permits portrait and both landscape orientations on iPhone;
iPad additionally permits upside-down portrait. `UIRequiresFullScreen` is false.
Native task sheets keep system containment and safe areas. Rotation, iPad split
windows, keyboard presence and large Dynamic Type need rendered/device checks;
changing orientation metadata alone is not responsiveness evidence.
