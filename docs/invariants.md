# Invariant registry

Stable IDs for the load-bearing invariants that in-code comments cite. The rules:

- **In code, cite the ID** (`INV-DNS-1`) plus anything site-specific, instead of repeating
  the full essay at every touchpoint. The canonical statement lives here; the deepest
  rationale lives at the "home" code site listed per entry.
- **Cite durable anchors** — invariant IDs, PR numbers, plan files — never review-round
  shorthand ("P2 r5"): rounds are unresolvable later. When touching a file that still
  carries round-style references, fold what they protect into this registry or the home
  comment.
- **A diff that changes an invariant updates this file in the same PR.** If your change
  falsifies a comment anywhere, fix the comment — a stale invariant comment is worse than
  none (one was hand-caught in #300; the enforcement listed per entry is what makes the
  next one a test failure instead).
- Legacy codes `CON-3` and `OBS-C2` predate this registry and remain in older comments;
  they are `INV-MEM-1` and `INV-OBS-1` here.

## DNS filtering

### INV-DNS-1 — Never fail open
No failure path serves unfiltered DNS while filtering is configured. Degradation order is:
real snapshot → config-exact last-known-good (INV-DNS-3) → fail-closed (block-all)
`FailClosedRuntimeSnapshot`. BOTH the async path and the synchronous cold-start bootstrap
may serve config-exact LKG (founder decision 2026-07-09, UR-48 Phase 2a plan): the async
path already served LKG for hours on compile failure, so refusing it in the bootstrap for
the ~seconds compile window traded a block-all outage for no coherent security gain. LKG
is never fail-open — INV-DNS-3's exact-configuration gates apply everywhere it is served,
and with no LKG candidate the bootstrap still installs fail-closed.
- Home: `LavaSecTunnel/PacketTunnelProvider.swift` — `loadInitialSharedState` /
  `bootstrapResidentSnapshotFromDisk` / `serveLastKnownGoodOrFailClosed` comments.
- Enforced: `PacketTunnelDNSRuntimeSourceTests.testLoadInitialSharedStateWarmResumesFromDiskBeforeFailingClosed`
  (asserts fail-closed install remains when neither strict nor LKG serves, and pins the
  strict-before-LKG bootstrap sequence).

### INV-DNS-2 — Transient bootstrap DNS wait is bounded and never bypasses the filter
After a recent self-reconnect launch that strict-misses fast-resume, DNS requests may be
queued at most 64-deep for at most 4 s. Every exit except a committed current-lifecycle
snapshot — timeout, overflow, stale lifecycle, snapshot-unavailable — answers SERVFAIL.
Queued requests are only ever replayed *through the filter* after a real snapshot commits.
- Home: `Sources/LavaSecDNS/TransientBootstrapDNSWait.swift` (the state machine, Phase E2)
  + `PacketTunnelProvider.swift` — "Transient bootstrap DNS wait" section (#294) for the
  SERVFAIL/replay/logging wiring.
- Enforced: `TransientBootstrapDNSWaitTests` (executable bounds + transitions: 65th
  enqueue overflows, timeout drains everything SERVFAIL-bound, stale-lifecycle and
  expired-generation rejection, commit-only replay, teardown reset, plus the
  provider-shape `assumeIsolated` call-shape test) +
  `PacketTunnelDNSRuntimeSourceTests` transient-bootstrap-wait wiring pins.

### INV-DNS-3 — Last-known-good is config-exact
LKG reuse tolerates ONLY stale catalog/guardrail content hashes. Enabled-list set, manual
block/allow rules, custom-list fingerprints, and parser rules version must match exactly,
so LKG can serve stale rules but can never serve a *different configuration's* rules.
- Home: `PacketTunnelProvider.swift` — `lastKnownGoodCompactSnapshot` comment;
  `CompactFilterSnapshot.canServeAsLastKnownGood`.
- Enforced: `CompactFilterSnapshotTests.testCanServeAsLastKnownGoodToleratesRotatedCatalogHashButNotConfigChange`
  directly exercises the config-exact predicate, and
  `PacketTunnelDNSRuntimeSourceTests.testTunnelServesLastKnownGoodOnColdStartBuildFailure`
  pins the tunnel reader to that predicate.

### INV-DNS-4 — Resolver-health evidence keeps distinct owners and lifetimes
`ResolverHealthCoordinator` is the single owner of resolver identity, current-network
episode, tunnel-session, reconnect-episode, effect-delivery, and smoke-probe ownership
state. Identity-scoped rejected-response evidence survives network handoffs and clears
on a real configured-primary identity change, accepted-primary recovery, or tunnel-
lifecycle reset. Network-episode failure/fallback evidence resets at the documented
context boundaries. Session state retains tunnel-lifetime cumulative counters and
per-resolver metrics across identity and episode changes while allowing runtime-scoped
observations such as negotiated DoH protocol to clear on a full runtime reset. Probe
invalidation retires the latest opaque owner without resetting evidence; stale or
repeated completions cannot transition state.

`deviceDNSFallbackModeActive` is a latched network-episode state, not a derivation of
`deviceDNSFallbackEvidenceCount`. An organic total failure clears candidate evidence but
does not exit a mode already driving resolver scheduling. Until a non-Device-DNS organic
response, an accepted-primary smoke probe, a failed smoke probe, or a network,
configuration, or lifecycle context reset, the coordinator projects the same active bit
to both its scheduling view and `TunnelHealthSnapshot`. This intentionally removes the
former split-brain where runtime remained in Device DNS fallback while projected health
fell false after candidate evidence dropped below the activation threshold.

The provider owns the persisted snapshot envelope, per-query counters outside connectivity
policy, NetworkExtension work, and all IO effects. On `dnsStateQueue`, it applies each
coordinator projection before executing the emitted effects in order. Lifecycle
invalidation closes probe admission synchronously and generation-fences deferred path
callbacks, so stopped providers cannot create or accept new smoke evidence.
- Home: `Sources/LavaSecDNS/ResolverHealthEvidence.swift` for the lifetime model and reset
  matrix; `Sources/LavaSecDNS/ResolverHealthCoordinator.swift` for state/token ownership.
- Enforced: `ResolverHealthEvidenceTests` (reset matrix and field-wise projections),
  `ResolverHealthCoordinatorTests` (single-owner accumulation, latest-token completion,
  invalidation without evidence reset),
  `ResolverHealthOrganicEvidenceTests.testTotalFailuresPreserveActiveModeAndClearEncryptedCoverageOnlyAtThree`,
  `ResolverHealthSmokeEvidenceTests.testActiveFallbackModeRemainsStickyAfterOrganicFailureClearsCandidateCount`,
  and
  `PacketTunnelDNSRuntimeSourceTests.testResolverHealthContextWritersRouteDistinctEventsWithExactFencing` /
  `PacketTunnelDNSRuntimeSourceTests.testResolverHealthReducerOwnedWritersHaveNoProviderBypasses`.

### INV-DNS-5 — Captured device resolvers are never discarded on masked-read evidence alone
While the tunnel owns device DNS, the in-process resolver read is masked in steady state
(Phase 0, lavasec-infra plans/2026-06-21-network-handoff-device-dns-recapture-plan.md), so
an empty capture — including a fully-exhausted capture-retry window — carries NO evidence
of a resolver-changing handoff. The captured address list may only shrink on affirmative
evidence: a non-empty recapture that replaces it, or a configuration/lifecycle reset. A
preserved-but-suspect primary is judged by wire evidence, split by owner: probe outcomes
feed the health/wedge chain (recovery cadences, rejection trigger) but never the live
backoff map (`PacketTunnelDNSRuntimeSourceTests.testSmokeProbesDoNotMutateLiveResolverBackoff`
— a false-negative probe must not bench a working primary), while the first organic
failures bench the address via `recordUpstreamResult`, with the per-query encrypted
fallback carrying every no-response query under INV-DNS-1. Service yields to the fallback
on real failure and RETURNS when probes succeed again. Field origin: UR-55 (app 1.2.1 dropped a
working router resolver on a stable Wi-Fi at wake-exhaustion; the empty list blinded the
recovery probes, stranding the user on the encrypted fallback until restart). Fix plan:
lavasec-infra plans/2026-07-11-ur-55-device-dns-fallback-under-tunnel-plan.md.
- Home: `LavaSecTunnel/PacketTunnelProvider.swift` — `runDeviceDNSCaptureRetry` exhaustion
  branch; `Sources/LavaSecKit/DeviceDNSFallbackPolicy.swift` — `exhaustionVerificationDecision`.
- Enforced: `PacketTunnelDNSRuntimeSourceTests.testDeviceDNSCaptureExhaustionPreservesResolversAndVerifiesByProbe`
  (no address mutation after the exhaustion gate; probe wiring + observability), and
  `DeviceDNSFallbackPolicyTests` exhaustion-verification gating tests (probe-by-default and
  the two equivalent-evidence skips with their boundaries).

## Memory (NE jetsam ceiling ~50 MB)

### INV-MEM-1 — One compile peak at a time (legacy: CON-3)
The in-extension streaming compile (~32 MiB peak) runs behind `snapshotCompileGate` with
generation re-checks before, inside, and after the gate, so superseded reloads never spend
the peak and two compiles never overlap. Pre-decode no-op/over-budget gates prevent
2x-resident decode peaks.
- Home: `PacketTunnelProvider.swift` — `loadCompiledSnapshot` (#213 history).
- Enforced: `PacketTunnelDNSRuntimeSourceTests.testInExtensionCompileIsSingleFlightedAndSkipsDoomedGenerations`.

### INV-MEM-2 — Gate before decode, on the same bytes
Every artifact read checks identity + rule budget on the SAME `.mappedIfSafe` bytes it
would decode, so a concurrent atomic republish can never slip a different or over-budget
generation past the header check (TOCTOU-safe). Applies to app stores and the
tunnel-compiled retained artifact alike.
- Home: `PacketTunnelProvider.swift` — `reusableCompactSnapshot`,
  `lastKnownGoodCompactSnapshot`, and `reusablePreparedSnapshot`.
- Enforced: `PacketTunnelDNSRuntimeSourceTests.testTunnelArtifactReadsResolveThroughThePointer`,
  `PacketTunnelDNSRuntimeSourceTests.testTunnelServesLastKnownGoodOnColdStartBuildFailure`,
  and `PacketTunnelDNSRuntimeSourceTests.testReusablePreparedSnapshotRebindsToManifestAndRebudgetsAfterDecode`.

## Tier budget

### INV-TIER-1 — A compiled rule total never exceeds the tier budget, at any publish or serve point
The tier cap (`FeatureLimits.maxFilterRules`: free 500K / Plus 2M) binds the COMPILED,
deduped total — block-rule union + full guardrail + allowed + manual blocked — with NO
margin, everywhere an artifact is published, reused, or served: the cold prepare (the one
gate that THROWS the actionable error), the foreground persist's artifact-flip veto, the
background-refresh publish, warm-switch and protection-startup reuse, and the tunnel's
compact/prepared/LKG/in-extension-compile reads. Every gate binds the RECORDED
`tierBudgetRuleCount` (manifest / compact-header metadata / prepared summary) — never a
resident table sum, which under-counts the recorded formula by the full-guardrail term
(the resident guardrail is only the allowlist-overlap subset); the in-extension compiler
stamps its conservative equivalent so retained artifacts stay loadable. The ×1.10
`softCeilingMargin` applies ONLY to the selection-time per-list-sum ESTIMATE (which
over-counts cross-list overlap); it never applies to a compiled total. A recorded
`tierBudgetRuleCount` of nil fails closed for REUSE everywhere, but is kept distinct
from recorded-over ("tier-budget-unrecorded" vs "over-tier-budget"): only recorded-over
marks the in-extension recompile doomed — the unrecorded case's recompile is the repair
path that stamps the missing total for a legacy artifact. Over-budget state may persist in CONFIG (downgrade and
restore keep user data intact, with the existing tier message surfaced) but is never
published, reused from disk, or freshly loaded/compiled; tunnel-side violations degrade
in INV-DNS-1's order (LKG only if itself within the tier budget → fail-closed).
Deliberate carve-out: an ALREADY-RESIDENT tunnel snapshot (a mid-run lapse) keeps
serving until its next adopting reload or NE process restart — the direct consequence
of the no-reload-on-entitlement-change rule (`persistPaidPlanFlag`); serving extra
filtering is not an INV-DNS-1 fail-open. Field origin: 2026-07-10 report of a free-tier
device serving a 558,917-rule union — a lapsed-Plus selection kept fresh forever by the
then-ungated refresh republish.
- Home: `Sources/LavaSecKit/FilterRuleBudget.swift` — `fitsTierBudget`;
  `FilterSnapshotPreparationService.prepare` cap comment.
- Enforced: `FilterRuleBudgetTests` (`testCompiledTotalGetsNoSoftMargin`,
  `testNilRecordedTotalFailsClosed`) + `FilterSnapshotPreparationServiceTests` (cold-gate
  throw semantics) + `CompactFilterSnapshotTests` /
  `StreamingCompactSnapshotCompilerTests` (recorded-total round-trip and stamping) +
  `MultiFilterFoundationSourceTests` (warm-switch gate) +
  `TierBudgetEnforcementSourceTests` wiring pins on every gate site.

## Concurrency

### INV-QUEUE-1 — dnsStateQueue confinement
Mutable tunnel DNS state is `dnsStateQueue`-confined. Entry points that may already be
on-queue use the `DispatchQueue` specific-key re-entrancy pattern (`getSpecific` → run
inline, else `sync`/`async` hop). Any helper extracted from the provider must preserve
this dual-entry contract or move the state onto its own isolation domain.
Actors migration (complete for the extracted machines; provider-level actors remain
future work): extracted state machines are dispatch-backed actors whose executor IS
`dnsStateQueue` (now a `DispatchSerialQueue`), so confinement is compiler-enforced —
on-queue callers use synchronous `assumeIsolated` (traps on the wrong executor), new
code must hop. Migrated: `QueueConfinedRepeatingTimer` (slice 1),
`DeviceDNSCaptureRetryCycle` (slice 2), `TransientBootstrapDNSWait` (slice 3),
`SnapshotReloadCoordinator` (slice 4), `ResolverHealthCoordinator` (slice 5).
- Enforced (migrated types): the actor's isolation +
  `QueueConfinedRepeatingTimerTests.testAssumeIsolatedGivesSynchronousOnQueueAccess` +
  `DeviceDNSCaptureRetryCycleTests.testAssumeIsolatedGivesSynchronousOnQueueAccess` +
  `TransientBootstrapDNSWaitTests.testAssumeIsolatedGivesSynchronousOnQueueAccess` +
  `SnapshotReloadCoordinatorTests.testAssumeIsolatedProvidesSynchronousOnQueueAccess` +
  `ResolverHealthCoordinatorTests.testAssumeIsolatedProvidesSynchronousDNSQueueAccess`.
- Home: `PacketTunnelProvider.swift` — `dnsStateQueueSpecificKey` and its ~40 call sites.

## Observability

### INV-OBS-1 — Transient fail-closed windows are not ledgered at entry (legacy: OBS-C2)
The by-design seconds-long bootstrap fail-closed window is NOT recorded in the incident
ledger at entry (it happens on every affected start and would flood the 50-record ring).
Genuine unavailability marks `residentFailClosedDueToUnavailableSnapshot` and ledgers once
per transition.
- Home: `PacketTunnelProvider.swift` — bootstrap fail-closed branch comments.

### INV-IPC-1 — The tunnel polls; Darwin observers don't fire in the extension
CFNotification observers were measured at 0/14 callbacks inside the NE process; the tunnel
therefore POLLS shared config (Focus config poll) and only ever POSTS Darwin signals.
App→tunnel pushes use `sendProviderMessage` exclusively.
- Home: `PacketTunnelProvider.swift` — Focus config poll section.
- Enforced: `PacketTunnelDNSRuntimeSourceTests` (asserts observer APIs stay absent).

## App lock

### INV-LOCK-1 — The app lock is an anti-snooping UI gate, not a cryptographic boundary
Biometric/passcode success in `SecurityController` flips in-memory session flags that
unblock UI over the opt-in protected surfaces (`SecurityAccessPolicy`) — nothing
cryptographic hangs on the result. No keychain access-control (biometry-bound) item
exists anywhere in the codebase, and the app-group data stays headless-readable by
design: the tunnel, widget, and Focus engine never authenticate — they fail closed.
Threat model: the lock defends against a snooping holder of the unlocked device. A
jailbroken/hooking attacker reads the container files directly, so keychain-backed
auth on this gate would add biometry re-enrollment breakage for zero attacker-facing
delta (founder-accepted disposition 2026-07-12, PR #355; the mobsfscan
`ios_biometric_bool` suppression at the home site is the reviewed marker of this
decision). Crypto-backed depth for backup secrets stays on its own track (release-gate
review P2-4). A diff that makes auth success release key material falsifies this entry
— update it here and revisit the suppression in the same PR.
- Home: `LavaSecApp/SecurityController.swift` — `evaluateBiometrics(reason:)`.
- Enforced: `SecuritySettingsSourceTests.testBiometricGateStaysANonCryptographicUIBoundary`
  (fails if keychain access-control APIs appear in the controller, or if the reviewed
  suppression marker disappears while `evaluatePolicy` remains).

## Release

### INV-REL-1 — RC tags match the declared version and never regress
`vX.Y.Z-rcN` must equal `Config/Lava.xcconfig` `MARKETING_VERSION` and be ≥ the latest
public release tag; clean (non-rc) release tags are always a deliberate manual action.
- Home / enforced: `.github/workflows/tag-release.yml` guard job.
