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
serialization retains completion only. `LiveRenderBoundary` disposes private screen
bodies when live data is unavailable while preserving the navigator shell. Native
snapshots check privacy before composing fields; account detail/messages and domain
history summaries require their current protected surface. Share actions and
asynchronous log-export presentation recheck native authorization.

Selected or unavailable Security state presents snapshot revocation as a static
privacy cover. Loading or read readiness alone never selects that cover; no
startup spinner or branded loading screen exists. An all-off native root waits
for an authorized projection before mounting React. Its constructor handoff can
paint those native-authorized all-off fields before JS AppState catches up, with
queries, actions and accessibility still revoked until active authorization.
Later inactive events cannot create a new frame after concealment.
Confirmed all-off state keeps the existing page and its
numbers visible during inactivity and the pending foreground refresh, without
intermediate loading placeholders. Interaction, accessibility and native query
delivery still wait for a new authorized active snapshot. A concealment marker
discards this frame immediately and cannot be undone by a later inactive all-off
marker. Covered states keep the same navigator with private bodies disposed.
On activation, native publishes the current authorized projection before asynchronous
DNS refresh; AppStore owns the single JS foreground snapshot refresh. A shared
hydration epoch keeps a previously concealed warm page covered while its focused
query readers reload. The cover retires after the mounted layout and all current
reads settle with either data or an explicit error; stale replies cannot release
a later cover. A confirmed all-off projection bypasses this gate, including when
the last protected choice is disabled during hydration. Cold initial
loads and intentional query/range changes keep their ordinary loading behavior.

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
