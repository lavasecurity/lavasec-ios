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
An existing-but-UNREADABLE config (Data Protection on a boot start before first unlock,
INV-PERSIST-1) is NOT "no filters": the bootstrap fails closed instead of taking the
empty-config pass-through, the background reload aborts rather than adopting the boot
placeholder, and the refresh marker stays nil so retries continue until the real config
is adopted after unlock. Post-INV-PERSIST-2, control-plane files carry
`NSFileProtectionNone`, so a pre-unlock boot normally reads the real config/artifacts and
serves real filtering; the fail-closed branch remains for transient unreadability.
- Home: `LavaSecTunnel/PacketTunnelProvider.swift` — `loadInitialSharedState` /
  `bootstrapResidentSnapshotFromDisk` / `serveLastKnownGoodOrFailClosed` comments; the
  block-all snapshot itself is `Sources/LavaSecKit/FailClosedRuntimeSnapshot.swift`.
- Enforced: `FailClosedRuntimeSnapshotTests` (executable: the fail-closed snapshot blocks
  every domain — including non-normalizable input — with `.protectionUnavailable`, never
  a forged `.blocklist` verdict) +
  `PacketTunnelDNSRuntimeSourceTests.testLoadInitialSharedStateWarmResumesFromDiskBeforeFailingClosed`
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

## Persistence

### INV-PERSIST-1 — Unreadable is never absent; no seed persists over an unreadable store
Every shared-state read distinguishes existing-but-UNREADABLE (Data Protection between
reboot and first unlock, or transient I/O — the user's data is intact) from genuinely
absent/corrupt, and no seed/migration/default may be persisted while any part of the
store classified unreadable. Collapsing the two wiped the filter library on a
reboot-before-first-unlock launch (2026-07-14 incident; lavasec-infra
`plans/2026-07-14-reboot-first-unlock-data-reset-incident-plan.md`): the launch reseed
stamped seeded defaults at a winning monotonic generation over the user's locked files.
Guards are layered — reader classification, launch-load persist gating + funnel refusal
with post-unlock reload, the shared writer's refuse-to-replace-unreadable fence, and the
automatic-backup suppression that keeps a reseed from propagating to the server copy.
Phase 2 (INV-PERSIST-2) removes the common pre-unlock unreadability for control-plane
files; these guards remain the backstop for the privacy stores (still Class C) and for
transient I/O unreadability.
- Home: `Sources/LavaSecKit/SharedStateFileReader.swift` (classifier);
  `SharedFilterStatePersistence.writeConfigurationAndLibrary` (writer fence);
  `AppViewModel.loadPersistedConfiguration` / `loadOrMigrateFilterLibrary` /
  `reloadSharedStateIfBlockedByDataProtection` (load gating + recovery);
  `BackupController.scheduleAutomaticBackupAfterConfigurationChange` (blast radius).
- Home (tunnel half): `LavaSecTunnel/PacketTunnelProvider.swift` —
  `loadConfigurationClassified` (fail-closed bootstrap + reload abort + nil refresh
  marker on unreadable) and `beginFreshProtectionVPNSession` (canary-deferred suite
  writes).
- Enforced: `SharedStateFileReaderTests` (executable classification, including a
  chmod-based unreadable fixture), `SharedFilterStatePersistenceTests`
  (`testWriteRefusesToReplaceExistingUnreadable*` — executable writer fence),
  `RebootFirstUnlockGuardSourceTests` (pins the load gating, funnel refusal, recovery
  wiring, and backup suppression), and `TunnelPreUnlockGuardSourceTests` (pins the
  tunnel's fail-closed bootstrap, refresh retry, reload abort, and canary-gated suite
  writes).

### INV-PERSIST-2 — Control-plane files carry NSFileProtectionNone; privacy stores stay Class C
The boot-needed CONTROL-PLANE files in the shared App Group — the
`app-configuration.json`/`filter-library.json` pair, `tunnel-health.json`, the versioned
artifact area (`filter-artifacts/`, token trios + the `current.json` pointer), the legacy
root artifact trio, and the tunnel's retained compile
(`catalog-cache/tunnel-compiled-artifact/`) — carry `NSFileProtectionNone`. A DNS filter
that boots with the device (Connect-On-Demand fires between reboot and first unlock, when
Class C content is still locked) needs its selection/rules state readable pre-unlock to
serve REAL filtering instead of the fail-closed block-all placeholder; these files hold
filter selections, custom rules, and tunnel health — no browsing history — so trading
their at-rest class for boot availability is deliberate (2026-07-14 incident, phase 2;
lavasec-infra `plans/2026-07-14-reboot-first-unlock-data-reset-incident-plan.md`). The
PRIVACY stores — `dns-events.sqlite`, `diagnostics.json`, `network-activity-log.json`,
`incident-ledger.json`, `vpn-debug-log.jsonl`, and the `catalog-cache` downloads outside
the retained-compile subdirectory — record user activity and nothing at boot needs them,
so they deliberately stay at the iOS default Class C. The advisory lock files are also
deliberately EXCLUDED: they are content-free, every pre-unlock toucher is try-only or
degrades on a failed open, and the shared `FilterPublishLock` open site also creates the
privacy vpn-debug rotate lock, so a blanket re-class there would leak class-None into a
privacy path for zero boot benefit.
CANARY CONSEQUENCE: the tunnel's protected-content canary
(`sharedProtectedContentIsReadable` and its static twin) must probe a file that STAYS
Class C — it probes the shared-defaults SUITE PLIST
(`Library/Preferences/<group>.plist`), NOT the config: re-classing the config to
Class-None made it readable pre-unlock, so a config probe would report "unlocked" while
the suite plist, diagnostics, and incident ledger are all still locked, silently
reopening every INV-PERSIST-1 window the #377 gates closed. `diagnostics.json` is also
disqualified as a probe: it can be legitimately absent long past install (counts +
history disabled before the tunnel ever persists diagnostics) while the locked suite
exists. The suite plist is the deferred writes' own clobber target, so both semantics
are exact: existing-but-unreadable means locked (defer), absent means no suite content
exists to clobber (proceed; the pre-unlock create fails harmlessly and retries). Class
keys unlock atomically at first user authentication, so its readability also signals for
the diagnostics/ledger writers. Because config readability no longer proves unlock, the
refresh's `.loaded` mtime stamp is gated on no pending begin — a pre-unlock `.loaded`
tick must keep the flush reachable past the unchanged-mtime gate. The tunnel-health
write closure is deliberately UNGATED: its file is control-plane Class-None and health
is never reloaded from disk, so it has no locked-file clobber class.
MARKER CONSEQUENCE: the durable recovery-reseed backup-suppression marker guards
`filter-library.json`, which is now Class-None, so a reboot-before-first-unlock launch can
ACCEPT the library while the device is still locked — and must be able to read AND durably
WRITE the marker in lockstep with it. A Class-C `UserDefaults` marker could do NEITHER: its
read returned a spurious `false` while the standard defaults were locked (lifting the
suppression, so the next automatic backup would upload the seeded defaults over the user's
last good server envelope), and its write could not land durably pre-unlock — and
`UserDefaults.synchronize()` is a no-op on modern iOS, so the stamp/clear "crash barrier" the
old ordering relied on never existed. The marker is therefore a Class-None FILE
(`reseed-suppression.marker`, `ReseedSuppressionMarkerStore`): its existence is
metadata-readable while locked and its atomic write lands durably pre-unlock, exactly matching
the library it guards. For a 1.2.5-native device the accept branch honors it INLINE — a direct
read of the pre-unlock-readable file marker, no protected-data gate. The ONE case that cannot
decide inline is a device upgrading from 1.2.4 whose pre-1.2.5 Class-C
`recoveryReseedBackupSuppression` defaults key has NOT migrated to the file yet AND whose first
post-upgrade launch is pre-first-unlock: the file marker is absent and the legacy store is
unreadable, so the marker read returns a third `absentUnconfirmed` state and the accept
conservatively FREEZES the suppression, re-deriving it once protected data is readable (wired to
the same first-unlock notification + foreground re-check as the INV-PERSIST-1 reload, since an
accepted readable library never sets `sharedStateUnavailableAtLoad`). The legacy key is read
only while protected data is available, migrated forward to the durable file AND then CONSUMED
(removed) in the same step — and a leftover key (a migration killed between its mark and consume)
is likewise cleared on any later readable launch that already sees the file marker, so it can
never be migrated back after a reset and re-suppress backups (Codex P2 ×2 on #385) — so the
freeze is one-time per upgrading device; a 1.2.5-native device's state lives in the readable file marker and never
freezes (Codex P1 on #385). Symmetrically on the DROP side: every user-authoritative reseed that
LIFTS the suppression — restore-from-backup, restore-to-default, and the onboarding seed — drops
the durable marker only AFTER its config/library pair reaches disk (the in-memory flag lifts first
so the persist's backup hook runs unsuppressed). A reseed persist that fails before the pair lands
KEEPS the marker, so the next launch still suppresses over the un-replaced on-disk reseed instead
of letting automatic backup clobber the last good server envelope; clearing the durable marker
before the write would strand the reseed unmarked (Codex P1 round 4 on #376 for restore-from-backup;
restore-to-default + onboarding brought into the same lockstep on the 1.2.5 sync, since the
post-#385 durable file-marker clear — unlike the pre-#385 best-effort Class-C key — reliably lands).
The marker carries app-state (a boolean, by
existence), never browsing history, so Class-None is the same deliberate trade as the rest of
the control plane (Codex P1 on the 1.2.4 public sync; Kilo/OCR durability follow-up). Enforced
by
`RebootFirstUnlockGuardSourceTests.testAcceptedLibraryHonorsDurableFileMarker`, the deferred-drop
pin `RebootFirstUnlockGuardSourceTests.testExplicitReseedDefersDurableMarkerDropUntilPersistLands`,
and the executable `ReseedSuppressionMarkerStoreTests`.
- Home: `Sources/LavaSecKit/SharedStateFileProtection.swift` (the single options/
  attributes source every control-plane writer funnels through); writer call sites in
  `SharedFilterStatePersistence`, `FilterArtifactStore` / `FilterArtifactStoreVersioned`,
  `StreamingCompactSnapshotCompiler` (scratch creation + post-promotion re-stamp), the
  tunnel-health write in `PacketTunnelProvider`, and the reseed-suppression marker in
  `Sources/LavaSecKit/ReseedSuppressionMarkerStore.swift` (Class-None existence marker);
  `Sources/LavaSecKit/ControlPlaneProtectionMigration.swift` + the
  `AppViewModel.setAppForegroundActive` post-unlock hook (one-shot re-stamp of
  pre-phase-2 files).
- Enforced: `SharedStateFileProtectionTests` (executable platform-fallback + round-trip),
  `ReseedSuppressionMarkerStoreTests` (executable marker existence / mark / clear + idempotent
  no-write), `ControlPlaneProtectionMigrationTests` (executable target selection + one-shot
  semantics), and `ControlPlaneProtectionSourceTests` (pins every writer call site, the
  compiler's creation attributes + promotion re-stamp, the foreground migration hook, and the
  re-stamp's post-write class verification that keeps a false-success `setAttributes` from
  latching a still-locked file).

## Release

### INV-REL-1 — RC tags match the declared version and never regress
`vX.Y.Z-rcN` must equal `Config/Lava.xcconfig` `MARKETING_VERSION` and be ≥ the latest
public release tag; clean (non-rc) release tags are always a deliberate manual action.
- Home / enforced: `.github/workflows/tag-release.yml` guard job.
