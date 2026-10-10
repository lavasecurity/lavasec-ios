# Native presentation cache security

This document records the implementation boundary for infra #315 and LAV-206. It is not a
claim that every app-owned file is encrypted by the new cache, that the owner’s
latency report has been reproduced, or that device acceptance is complete.

## Retention and authorization are separate

`Sources/LavaSecAppServices/SecurePresentationCache.swift` owns a default-deny
registry. Activity may reuse AES-GCM ciphertext in memory; catalog, domains,
network, stats, sharing and domain mutation reviews are sensitive/no-store.
Unknown query types cannot obtain a read ticket. Existing authentication choices
still decide whether an interactive grant is necessary. An ungated surface does
not permit an ordinary JS-object cache. A native-confirmed Security-off page can
keep its already painted snapshot/query values through inactivity and the pending
foreground refresh; this display-only exception grants no read access or reusable
cache hit. Credentials/tokens never enter this API.

Each ticket binds a service instance, invalidation generation and SHA-256 digest
of canonical owner/resource/source revision/log policy/auth-policy generation/
schema/query identity. AES-GCM authenticates that context. Identity is not a grant:
every lookup and insertion requires a live native check, repeated before delivery.
The native caller must compare its captured policy/lifecycle/owner with current
values, not accept JavaScript booleans or a supplied generation as proof. Async
source results must validate their ticket before publication even when no-store.

Keys are random 256-bit CryptoKit keys, created only for an authorized insertion.
CryptoKit supplies a fresh random 96-bit nonce for each seal. Entries are bounded
(default eight, 512 KiB per entry, 30 seconds monotonic freshness). The only stored
payload is authenticated ciphertext. Identifying fields are not retained as
plaintext cache keys, written to disk or exported. Invalidation drops entries and
the sole service-owned key reference and replaces the generation; a pending old
read cannot write again. A new service cannot use another service's tickets.

### Explicit first-version key decision

| Condition | Decryption/access rule |
| --- | --- |
| Active authorized app turn | Native service can decrypt after the current-grant/scope check. |
| Surface left or grant revoked | Native current-turn checks reject delivery and React rejects late replies. Selected/unknown protection disposes private render values; a confirmed all-off page may retain only its prior inert display. |
| Background, device lock, Lava lock | Owner invalidates the cache. No reuse across that event in this version. |
| Credential/method/protection change | Invalidate before any subsequent read; old async work is rejected. |
| Sign-out/account change, log clear, restore/deletion | Invalidate; a changed owner/source/log identity cannot match earlier data. |
| App relaunch | No file or Keychain cache key exists; entries are lost. |
| Corrupt ciphertext, wrong key, changed context | Miss/eviction or crypto failure; never decode bytes as unsealed JSON. |
| No device passcode / unavailable authentication | No weaker key fallback; native authorization decides access. No cache Keychain item exists. |

Both Lava passcode and Face ID converge on the existing SecurityController's
current-turn authorization. This is **software-enforced key access**, not a
cryptographic wrapping of the cache key by a Lava passcode or biometric secret.
No salt/verifier is reused as a key and no short PIN is fed to encryption. There
is no separate OS-unlock-based recovery of this cache. Cross-lock/cross-session
reuse remains deliberately unavailable until a reviewed key-release design proves
that stronger binding. Runtime encryption cannot defend against arbitrary code
execution in an authorized app, an attacker who copies the key from its memory,
or guarantee zeroization of Swift/JS/OS render copies. It does protect an isolated
copied sealed entry without the ephemeral key; tests cover that narrower claim.

## Current-main reconciliation

The implementation is reconciled from `fix/native-title-transition` at `9584b320`
onto internal iOS main `bf5914261be4193935ffadc1dce140fa9cf78f6a`. Current main did
not contain the service, registry, local-report pipeline, private HTTP transport or
owned import cleanup. Those owners and their behavioral tests are reused here;
current onboarding, catalog, DNS patch, navigation and authentication choices are
preserved. Historical test counts and device receipts are not reused as evidence
for this candidate.

`LavaAppBridge.query` declares every query through `PresentationReadPolicy` before
reading any payload. It captures native owner, canonical query input, local source
revision, logging/clear controls and security revision. The live check includes
active app state, available protected data and `SecurityController`'s current grant.
Fresh and warm results carry a native validation closure to `command`; the bridge
runs it after the outer asynchronous call and immediately before synchronous JSON
serialization and callback delivery. There is no JS-provided grant or key.

Account publication, authentication revision, background and protected-data loss
invalidate the one cache. Native mutations invalidate pending tickets and advance
the source generation. Local diagnostics file revision and clear-control identity
also fence reads changed by other writers. The cache is a disposable derivative;
authoritative app/extension sources keep their existing storage contracts.

Activity and Domains compose from local diagnostics through
`AuthorizedLocalReportRead`. Initial reads, manual refresh and warm refresh do not
await tunnel health. The existing independent health loop, Feedback sampling and
explicit Nerd statistics remain available. A test holds the health reply forever
and verifies that local reads and refresh still finish without advancing a timer.

The JS adapter is no-store, including sharing. `AppStore` drops authoritative snapshots and
rejects old query epochs after a native privacy marker or inactivity. A confirmed
all-off frame retains already delivered values for display, without accepting new
inactive data. Its query identity excludes routine read-epoch/authentication-turn
changes but still binds the exact query, opaque account-owner revision, security
choices, logging choices and destructive source identity. Account status messages
and unrelated bridge mutations can revoke readers without erasing the existing
page. Native display identity advances on every successful log clear (including
network/progress), diagnostics clear-control changes and actual filter-library
replacement/edit; library cache metadata and persistence restamps are excluded.
The library tracker retains only a digest and hashes on library publication, not
every telemetry snapshot. Any change to display identity discards former values.
The same display rule applies to every query type, including an already visible
share page; no caller hint can override native concealment or retain a cache. Command
serialization retains completion only. `LiveRenderBoundary` retains the same-owner
scaffold and native scroll identity under concealment. Scoped query hooks still
discard protected render values on revocation; an explicit body-disposal option
remains for content without a safe shell. Native
snapshots check privacy before composing fields; account detail/messages and domain
history summaries require their current protected surface. Share actions and
asynchronous log-export presentation recheck native authorization.

Same-visit retention includes permitted transient presentation state such as list
selection/search, history range/decision, and Sudoku control selection. It is not
a query cache and does not authorize credentials, native confidential editor
buffers, expired review capabilities, or private rows from an old scope. The
`useRouteViewState` setter binds the current read epoch; concealment cannot adopt
fallback session values, and pre-lock callbacks cannot edit the restored visit.
Account/security-owner or policy replacement retires the route's retained state.
Internal lifecycle cleanup can use a reset-only callback that restores the
initial permitted state while its visit is mounted, including while concealed.
It cannot assign arbitrary values or act after that visit retires. User setters
remain fenced by current authority and their captured read epoch; stable native
responders resolve the current guarded action rather than capturing a first-render
setter. Derived animation state has its own cancellation lifetime.
Native confidential WireGuard content remains native-owned and is cleared on
retirement. Native-confirmed closing preserves only inert outgoing scaffold paint.

Guard alone can prepare its query-free, non-private layout before the first
authorized projection. It receives no native fields, cannot call the native port
without authority, and stays inert/inaccessible under the existing cover. First
authorization fills the same viewport instead of remounting it; an actual owner
or policy replacement still retires the body. Other private destinations continue
to wait for their first projection. Concealed Guard paint settles to the restored
state, so reveal does not replay a protection-activation animation.
The native host supplies public locale and text metrics separately from the
private snapshot, so the covered cold scaffold already uses the correct language
and font geometry. That metadata grants no data or action authority.

Initial authenticated presentation and protected warm resume use the same
`PresentationHydration` gate. First reveal requires navigation readiness, the
actual focused scaffold's nonzero native viewport, current owner preparation and
focused scoped reads. Their layout effects settle hydration in a microtask, so
replaced readers can register before release. The root then commits removal of
React's cover and acknowledges native on the next animation frame. This is one
frame handoff; hydration does not add a preceding frame wait.
The native viewport event is a structural admission signal; this is not a GPU
completion or a device frame-rate measurement.
Every runtime destination must use a measured Screen/Sheet/FlowSheet or attach
the same admission hook to its existing direct native viewport. This includes
Licenses, the QA gallery and Device QA. The separate visible onboarding modal
owns its measurement and waits for its drawing dimensions; a hidden Guard
viewport cannot admit it. Unavailable hosts and retired setup visits release
their tickets, while a retained same-visit host reuses its real measurement.
Offscreen readers retire their tickets; overtaken epochs and frame callbacks
cannot release a newer cover. A query error settles into an intentional error
view. Missing off-policy content has a recoverable branded fallback instead of an
empty successful frame. No fixed authentication delay is introduced, and none of
these presentation checks changes native authorization or cross-lock cache reuse.

A retained foreground shell is not a current native projection. Auto-switch and
Licenses renew missing projections beneath the cover using their existing App
Unlock boundary; filter-library entries still require filter-editing access.
Interrupted entry work reconsiders the current grant after the obsolete flight
settles, and failure exposes an explicit retry rather than invisible content.
Native-confirmed closing suppresses reentry. Feedback's internal preparation can
also run during hydration; field commits and user actions still require completed
interaction readiness.

Native Security policy chooses concealment. Selected or unavailable Security
state presents snapshot revocation as a static privacy cover. Initial authorized
content also stays under that selected cover until navigation, focused native
viewport and destination preparation are ready; no spinner or fixed delay is
added. An all-off root without an authorized projection shows an intentional
recoverable fallback. Its native-authorized constructor projection can paint
before JS AppState catches up, with queries, actions and accessibility still
revoked until active authorization. Later inactive events cannot create a new
frame after concealment.

Confirmed all-off state keeps the existing page and its numbers visible during
inactivity and pending foreground refresh. Interaction, accessibility and native
query delivery still wait for a new authorized active snapshot. A concealment
marker discards these display-only values immediately and cannot be undone by a
later inactive all-off marker. The same navigator and safe route scaffold stay
mounted while scoped private readers clear. On activation, native publishes the
current authorized projection before asynchronous DNS refresh; AppStore owns the
single JS foreground snapshot refresh. The shared hydration epoch keeps a
previously concealed page covered while its focused readers and destination
prepare. Current reads settle with either data or an intentional error. Stale
replies cannot release a later cover. A confirmed all-off projection bypasses a
warm concealment gate, including when the last protected choice is disabled.
Initial loads and intentional query/range changes keep their ordinary loading
behavior beneath the applicable policy cover.

Phone protected-data loss has the same separation: native read authorization and
cache tickets revoke before UIKit changes its availability bit, while the blocked
snapshot carries the current concealment choice. It cannot publish new fields.
A confirmed all-off frame stays painted through wake; selected or unknown security
still conceals. Native flow input and accessibility wait for protected-data recovery.
The pre-lock latch is observable and clears only on the availability notification,
so activation alone cannot restore native access.

See [the complete inventory](../security/presentation-cache-inventory.md) for
backing stores, alternate readers and cleanup ownership. Original diagnostic files
are not encrypted by this presentation cache. Runtime encryption cannot guarantee
zeroization of every render, Foundation, React or OS copy.

## Verification and remaining acceptance

`SecurePresentationCacheTests` execute authorization, scope isolation, AES-GCM
integrity, wrong-key/copied-entry rejection, expiry/bounds, lifecycle revocation,
no-store policy and reentrant invalidation. `AuthorizedLocalReportReadTests`
exercise cancellation and authorization changes after asynchronous source reads.
The React store/query/private-render suites exercise inactive/locked snapshots,
late replies, cancellation, sharing cleanup, stable route shells and all-off
display continuity through delayed snapshot/query refreshes.
`PresentationCacheBoundarySourceTests` check cross-target wiring and registry
coverage; source assertions do not replace those behavioral tests.

Physical Passcode/Face ID, app-switcher/accessibility concealment, account changes,
log clears/restores and at least 30 latency trials per auth method remain required.
Warm p95 at most 500 ms is the acceptance target, not an observed result. No disk or
cross-session reuse is enabled. Current candidate validation and the independent
backup disposition are recorded in the infra #315 implementation report.


## Read delivery and presentation order

Read-only query replies carry the validated result without rebuilding or broadcasting the
whole-app snapshot. Mutations and model observations retain their normal projection path.
JS checks its read epoch before accepting a result-only reply. Identical simultaneous reads
join one promise within the current connection/read/invalidation epoch; the entry is removed
when that request settles or authority retires. This is in-flight work sharing, not a JS
result cache, and does not extend native ciphertext or authorization lifetime.

After Activity navigation authorization has settled, its existing local summary query starts
alongside the native push. The mounted page can join that pending query and uses the admitted
snapshot's calendar dates directly. Failed preparation does not block navigation; the page's
normal read/error path remains authoritative. Diagnostics refresh once before pinning the
native read ticket, not again while composing the same result.

Security, local-log and notification rows use fixed ordered definitions. Native JSON keys
supply values only; serialization order never controls row position or identity. Tests vary
incoming key order and values while checking native control identity and viewport continuity.
Fixed-stage Instruments signposts use the shared QA-only emitter on devices; simulator timing logs remain
opt-in. Neither carries settings, reasons, identities, query arguments or returned data.
