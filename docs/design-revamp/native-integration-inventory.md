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

## Native journeys retained by the full app

The dispatch source is `ReactNative/native-app/LavaAppFlows.swift`. These remain
real controllers with their existing authentication and persistence gates.

| Native destination | Shared presentation | Functional acceptance needed |
| --- | --- | --- |
| Filter preparation | Existing `FilterPreparationScreen`, shared palette/actions | Prepare, publish, cancel/fail and real tunnel result. |
| Import: camera, photo, code and deep link | Existing import stage machine and shared task scaffold; completed import uses `LavaSuccessScreen` | Cancel/reopen scanner, review, add/replace, authentication cancellation, confirmed result and Done. |
| Create filter | Existing `CreateFilterSheet` / shared fields | Actual library creation, limits, duplicate-name handling and cancellation. |
| Rename filter | Existing `RenameFilterSheet` / shared fields and circular controls | Persisted name, validation and cancellation. |
| Library changes / deletion | Existing `DeleteFiltersConfirmationSheet` / shared review/footer | Only reviewed changes committed; cancel retains the library. |
| Custom blocklist | Existing `BringYourOwnListView` / shared fields | Source validation, existing filter identity checks and entitlements. |
| Account connections | Existing `AccountSheet` / shared list and chrome | Apple/Google sign-in, connection status, sign-out and account deletion safeguards. |
| Backup setup | Existing passkey/recovery/controller; shared success after confirmed local setup | Passkey validation, recovery handling, cancellation and upload state in Account & Backup. |
| Backup restore | Existing prepare/review/confirm controller; shared success after confirmed restore | Correct review, resolver consent, restore failure/cancellation and resulting settings. |
| Passcode setup/authentication | Existing security controller and shared native chrome | Correct native presentation above RN sheets and protected-surface access. |
| Automation instructions | Existing `AutoSwitchHowToSheet` / shared sheet | Existing shortcut/Focus instructions and external transitions. |
| Feedback | Existing submission controller; shared success retains report ID and Copy ID | Real backend acceptance, retry, privacy mask, diagnostics opt-in and return. |
| Custom DNS | Existing `DNSResolverSettingsView` | Validation, persistence, DNS apply/reconnect and errors. |
| VPN chaining | Existing contained `LavaVPNNavigationPage` | Configuration/key handling, entitlement, authorized access, enable/disable and actual forwarding. |
| Legal notices | Existing notices view | Full attribution and usable navigation. |
| Device QA / QA sheet | Existing conditional QA tools | Visible only in the existing eligible QA/developer context. |

Success is a presentation change after the real operation, never simulated state.
Import now waits for Done before delivering its completion callback, with a
once-only guard; it cannot dismiss interactively during apply or the completed
stage. Replacement preserves the target's existing name. Backup setup confirms
local encrypted setup only: its existing controller starts cloud upload
asynchronously, so the success copy deliberately makes no cloud-upload claim.

Install-over compatibility also belongs to the native owner. The candidate reads
the same Keychain deletion-intent record as RC13: pending remote/local cleanup
blocks backup writers, and completed Off overrides stale local preferences.
Remote deletion and upload retries remain bound to the initiating account.
Explicit setup/restore may replace completed Off only after local persistence
succeeds; restore rechecks its account after applying the reviewed configuration.
These paths are tested with isolated service/storage doubles, without uploading
or deleting a person's real backup. They still require native build qualification.

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
