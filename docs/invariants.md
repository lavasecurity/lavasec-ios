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

Resolver tiers are canonical and defined once in `docs/architecture/dns-tiers.md`: **T0**
is the chained upstream's own `DNS =`, **T1** the resolver the user selected, **T2** their
selected fallback. The invariants below use those names; a tier keeps its number in every
mode, so chaining inserts T0 above T1 rather than renumbering it.

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
- Home: `LavaSecTunnel/Provider/PacketTunnelProvider+StartupState.swift` — `loadInitialSharedState`;
  `LavaSecTunnel/Provider/PacketTunnelProvider+SnapshotCompile.swift` —
  `bootstrapResidentSnapshotFromDisk` / `serveLastKnownGoodOrFailClosed` comments; the
  block-all snapshot itself is `Sources/LavaSecKit/FailClosedRuntimeSnapshot.swift`.
- Enforced: `FailClosedRuntimeSnapshotTests` (executable: the fail-closed snapshot blocks
  every domain — including non-normalizable input — with `.protectionUnavailable`, never
  a forged `.blocklist` verdict) +
  `PacketTunnelDNSRuntimeSourceTests.testLoadInitialSharedStateWarmResumesFromDiskBeforeFailingClosed`
  (asserts fail-closed install remains when neither strict nor LKG serves, and pins the
  strict-before-LKG bootstrap sequence).

Forwarded answers and cache hits also inspect reachable answer aliases. CNAME and queried
HTTPS/SVCB targets use the existing per-name filter precedence under one current snapshot
per client. Malformed, cyclic and over-limit graphs are refused before caching; permitted
questions receive SERVFAIL, and no checked prefix is accepted. A current pause permits would-block destinations with a short TTL.
- Home: `Sources/LavaSecDNS/DNSResponseAliases.swift`, `DNSQueryDispatcher.swift` and the
  provider's existing forwarding/response concerns.
- Enforced: `DNSResponseAliasesTests`, `DNSAliasFilterDecisionTests`,
  `DNSAliasPauseDecisionTests` and
  `PacketTunnelDNSRuntimeSourceTests.testAliasesAreCheckedForCachedAndFreshAnswers`.

### INV-DNS-2 — Transient bootstrap DNS wait is bounded and never bypasses the filter
After a recent self-reconnect launch that strict-misses fast-resume, DNS requests may be
queued at most 64-deep for at most 4 s. Every wait exit except a committed
current-lifecycle snapshot — timeout, overflow, stale lifecycle, snapshot-unavailable —
settles the queue through the shared failure responder: SERVFAIL, or a block if current
filtering now requires one. One deliberate exception to the answer (PR #524): a request
whose OWN accepting session has ended by the time it reaches the per-request fence — the
replay pre-drain answers stale batches, but staleness landing after that check is
DROPPED, because `writeDNSResponse` has no lifecycle gate and a SERVFAIL built for a
retired session would be injected into the live packet flow (PR #508). Queued requests
are only ever replayed *through the filter* after a real snapshot commits, and are
enqueued under the generation that accepted them, never a live re-read.
- Home: `Sources/LavaSecDNS/TransientBootstrapDNSWait.swift` (the state machine, Phase E2)
  + `LavaSecTunnel/Provider/PacketTunnelProvider+TransientBootstrapWait.swift` (#294) for the
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

That split is named rather than restated per call site: every snapshot input belongs to
exactly one of `PreparedFilterSnapshotIdentity.selectionInputFieldNames` (WHICH rules the
user asked for) or `.freshnessInputFieldNames` (HOW FRESH the catalog content is), and the
freshness set is exactly what `hasSameConfigurationInputs` — the predicate
`canServeAsLastKnownGood` decides on — ignores. `reuseMismatchReason` is the one producer of
the on-device reason string for both the app manifest and the tunnel, so a `freshness:` miss
is legible as the tolerable class and an `inputs:` miss as a different filter.

Ordering follows from the same split: **a stale copy of the right filter outranks a fresh
copy of the wrong one.** A resident snapshot suppresses the LKG search only while it still
answers the request (no `selectionMismatches` against the expected identity). A resident for
a superseded selection yields to a config-exact LKG, which is itself budget-gated and
single-resident, so `INV-MEM-1`'s 2x-resident reasoning is unaffected. Field 2026-09-01: a
mid-session switch to a lighter preset published a selection-exact artifact rejected on
`selectedSourceVersionIDs`+`selectedSourceHashes` alone; with the heavier preset resident the
search was skipped and 21 reloads kept the superseded preset enforced for 40 minutes, until a
protection restart — a fresh process with no resident — accepted the very same artifact.
- Home: `LavaSecTunnel/Provider/PacketTunnelProvider+SnapshotCompile.swift` — `lastKnownGoodCompactSnapshot` and
  `serveLastKnownGoodOrFailClosed` comments; `CompactFilterSnapshot.canServeAsLastKnownGood`;
  `PreparedFilterSnapshotIdentity` classification API.
- Enforced: `CompactFilterSnapshotTests.testCanServeAsLastKnownGoodToleratesRotatedCatalogHashButNotConfigChange`
  directly exercises the config-exact predicate;
  `PreparedFilterSnapshotIdentityClassificationTests` asserts the partition is total and that
  it matches what that predicate tolerates, field by field;
  `PacketTunnelDNSRuntimeSourceTests.testTunnelServesLastKnownGoodOnColdStartBuildFailure`
  pins the tunnel reader to the predicate and the resident gate to selection; and
  `FilterSwitchPublishDiagnosticsSourceTests.testAStaleCorrectFilterOutranksAFreshResidentOne`
  pins the ordering rule.

### INV-DNS-4 — Resolver-health evidence keeps distinct owners and lifetimes
`ResolverHealthCoordinator` is the single owner of aggregate resolver identity, current-network
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

Canonical tier evidence is owned by `ResolverTierHealth`, separately from the aggregate
service projection. Raw T0/T1/T2 legs are stamped before merging; another tier's rescue
cannot clear failure evidence. Current lifecycle/latch/path admission precedes reduction.
A source-matched same-tier reply clears its no-response condition; rejected replies retain their own
evidence. Late replies after client expiry establish liveness without delivered service credit.
Configuration, capture, path, latch and lifecycle context replacement retire scoped grants and
timers. A temporary fallback promotion preserves the configured ladder's evidence.

A current physical Device DNS T1/T2 no-response failure records suspicion, independently of
aggregate health. Automatic cold recapture requires a second lookup whose first wire attempt
starts after the first failure is observed and also returns no response, with no intervening
same-tier reply. DNS-queue send and completion sequences establish this order; concurrent
failures, retries within one lookup, local failures and synthetic probe timeouts cannot confirm
it. A newer Device reply makes an older lookup's eventual failure obsolete for recapture.
Source-matched UDP/TCP replies retire silence before retries or another endpoint delay the
leg, and their observation order survives later completion. One owned confirmation follows
the already-permitted Device rung and ends at its first reply, including a truncated or
mismatched reply; it never requires client-service completion or grants service credit.
Generic chained physical probes remain suspended. Legacy Device recovery triggers share this
rule, and cooldown expiry requests fresh confirmation rather than replaying a stale grant.
Full/strict routing, profile-covered destinations, mixed egress, unavailable filtering,
stale work, no-wire refusals, masked reads alone and per-domain error replies cannot grant it.
The final teardown rechecks the grant, Guard intent, confirmed on-demand and live path. All
process restarts share a durable budget; Device recapture credit requires deliverable Device
service and never erases cooldown.
The pane consumes this same typed state and publishes no queried names or endpoint identity.
- Enforced: `ResolverTierEvidenceTests`, `ResolverOrchestratorTests`,
  `TunnelSelfReconnectPolicyTests`, `ResolverTierRecoverySourceTests` and
  `DNSResolverTierHealthPresentationTests`.

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
- Home: `LavaSecTunnel/Provider/PacketTunnelProvider+DeviceDNSCapture.swift` — `runDeviceDNSCaptureRetry` exhaustion
  branch; `Sources/LavaSecKit/DeviceDNSFallbackPolicy.swift` — `exhaustionVerificationDecision`.
- Enforced: `PacketTunnelDNSRuntimeSourceTests.testDeviceDNSCaptureExhaustionPreservesResolversAndVerifiesByProbe`
  (no address mutation after the exhaustion gate; probe wiring + observability), and
  `DeviceDNSFallbackPolicyTests` exhaustion-verification gating tests (probe-by-default and
  the two equivalent-evidence skips with their boundaries).

### INV-DNS-6 — Queued DNS work has a bounded lifetime and a unique completion owner
Forwarded lookups and bootstrap-broker work share eight active resolver slots and a
FIFO capped at 128 pending jobs / 512 KiB of declared retained data. The DNS waiter
registry independently caps 256 clients, 16 per question, and 1 MiB of declared data.
The provider counts both query and key bytes plus waiter metadata; rejection retains
nothing and promptly settles a current client through the shared failure responder.

One 12-second continuous-clock deadline covers queue wait and the complete resolver
ladder. Runtime/lifecycle invalidation prevents queued launch and subsequent sends;
every reset and teardown share one queue purge and retain the immediate-SERVFAIL or retired-
lifecycle drop rule. There is no handoff grace. Client expiry drains only its unique
resolution identity. It never frees an active I/O slot: only that work's once-only
completion can do so, and a late result cannot consume a successor's waiters or earn
service credit. Bootstrap expiry and late completion share one client-settlement claim;
lifecycle and resolver identity are read together on the DNS state queue. TCP connect,
send, length and body share one attempt deadline, capped
by the remaining lookup deadline; partial progress cannot renew it. Expiry before an
encrypted DNS send is neutral for endpoint health and keeps healthy pooled connections.
Actual completed attempts are recorded once even after client expiry; late responses
cannot earn aggregate service or fallback credit. An invalidated runtime leaves its
waiters for the reset/teardown owner.

- Home: `BoundedWorkAdmission`, `InFlightDNSQueryCoalescer`, `DNSResolutionLifetime`,
  `SocketResolvers`, and the provider forwarding/transport seams.
- Enforced: `BoundedWorkAdmissionTests`, `InFlightDNSQueryCoalescerTests`,
  `DNSResolutionLifetimeTests`, `CompletionClaimTests`, `DNSWorkMemoryBudgetTests`, socket trickle/stalled-send
  tests, encrypted transport expiry tests, and
  `PacketTunnelDNSRuntimeSourceTests.testForwardedLifetimeReachesAdmissionTransportsAndDelivery`,
  `testEveryResolverResetPurgesPendingAdmissionWork`, `testResolverLifetimeReadsOneCoherentRuntimeIdentity`,
  `testClientReplyAndWorkRetirementShareTheCompletionClaimPolicy`,
  `testExpiredCompletionPreservesEvidenceBeforeClientSettlement`,
  `testAPreWireRefusalStillReachesTheUnansweredTrace`,
  `DNSTransportOutcomeTests.testExpiryBeforeSendIsNeutralAndEndsTheResolverLadder`,
  `ResolverHealthOrganicEvidenceTests.testClientExpiryPreservesFailureEvidenceWithoutServiceCredit`,
  and `SocketResolverTests.testAnExpiredTCPConnectRestoresTheDescriptorsOriginalFlags`.

### INV-DNS-7 — The DNS capture set is the route set
Every mode captures the SYSTEM resolver: `NEDNSSettings` carries `matchDomains = [""]`, so the
resolver iOS hands apps is the in-tunnel proxy whatever else is routed. What differs is the app
that ignores it and dials a resolver address itself. That datagram is filterable only where the
tunnel CLAIMED the route to its destination — an unclaimed destination never enters the NE, so no
interception can apply to it — which makes the capture set a property of the ROUTE SET and not of
"chained vs DNS-only":
- **full tunnel** (`0.0.0.0/0` **and** `::/0`) — `DNSCaptureScope.everyDestination`: every
  clear-text IPv4 DNS datagram on the device is captured and filtered, hardcoded resolvers
  included (`ChainedOutboundPacketClassifier` gates on DESTINATION PORT 53, never on resolver
  address), and IPv6 is claimed in order to be dropped (`INV-CHAIN-1`), so a v6 query fails
  closed rather than escaping. BOTH claims are required, and the v6 claim must be INSTALLABLE:
  a plan taking `0.0.0.0/0` while claiming no `::/0` leaves IPv6 on the physical interface
  (`TunnelRoutePlan.leaksIPv6AroundTheTunnel`, which the scope reads directly so the leak guard
  and the coverage claim cannot disagree), and a plan claiming `::/0` without an IPv6 address
  and prefix length leaves it there too — the provider installs `NEIPv6Settings` only when all
  three are present, so a route array is a claim rather than an installation
  (`TunnelRoutePlan.installsIPv6Settings`). `make` sets them together, so this narrows arbitrary
  plans, not running ones (Codex, PR #728).
- **split tunnel** (`AllowedIPs` + the DNS-capture `/24` + the in-tunnel v6 DNS server's on-link
  `/64` + the capture-floor host routes) and **DNS-only** (the `/24` alone) —
  `DNSCaptureScope.systemResolverAndClaimedRoutes`: the system resolver plus whatever
  those prefixes cover. A hardcoded resolver the profile's own `AllowedIPs` happen to cover IS
  captured, on the same port-53 rule; one at any other IPv4 destination egresses DIRECT and
  unfiltered UNLESS the capture floor claims it. The floor has two sources: F1's versioned in-tree
  curated public-resolver set (`DNSCaptureFloor.curatedPublicResolverAddresses`) and F3b's
  network-advertised resolvers, both claimed as `/32`/`/128` host routes in a CHAINED SPLIT only.
  DNS-only claims NEITHER: its packet loop has no forwarding rung, so a claim there would draw a
  resolver's non-53 traffic (HTTPS/QUIC `:443`, ICMP) into the NE and silently drop it — the
  `https://1.1.1.1` breakage that scoped F1 to the chained path (Kilo, PR #752). A hardcoded
  clear-text resolver in DNS-only therefore still escapes; that residual is disclosed (F5), not
  claimed. IPv6 no
  longer escapes in split: since F3c (2026-09-19) split claims the in-tunnel DNS server's on-link
  `/64` and serves filtered v6 rather than blackholing `::/0`, closing the v6-DNS escape
  reproduced on 2026-09-17 and 2026-09-19
  (`plans/2026-09-17-path-independent-dns-capture-floor.md`). So this scope captures a growing set
  of hardcoded-resolver IPv4 destinations but still not all of them, and which ones is a property
  of the profile and the floor rather than of the scope — hence
  `capturesEveryHardcodedResolverDestination` rather than a bare
  "captures hardcoded resolvers", which would under-report it (Codex, PR #728). What is unfiltered
  here is the signed-off `INV-DNS-1` scope for the IPv4 direct portion (infra `#198` §3.3), not a
  fail-open: the tunnel is not serving that query, it never sees it. F4 adds one more consequence
  of the same route set: an encrypted-DNS (`:853`, DoT/DoQ) flow to a destination this scope
  CLAIMS is refused as unfilterable (`ChainedOutboundPacketClassifier`'s claimed-destination arm,
  via `ChainedClaimedResolverDestinations`), because the claim is what drew the flow into the NE
  where the filter cannot read it and the IPv4-only peer will not carry it. `:853` to an UNCLAIMED
  destination is left alone — in split it egresses direct, which is the T1 rung's path.

So a chained→DNS-only surrender NARROWS coverage as well as dropping the upstream, and a coverage
claim that does not name its mode is an over-claim. The scope is derived
(`TunnelRoutePlan.dnsCaptureScope`), never stored or re-spelled per mode, and is logged beside the
claimed route at every settings-apply site — initial install, startup DNS-patch drain and
ordinary reapply — so a field
capture shows the coverage the session actually got. Every site, because the device log is bounded: it
is 8 MB-capped with whole-file rotation keeping ONE prior generation, and a bug report reads the
last 40 entries (an export, 5,000). So on a long-lived session the startup record eventually ages
out of what a capture can see — past the report window first, and past the retained generation
later — leaving the reapply record as the only settings-apply evidence. Instrumenting one site
would then answer the coverage question for a session that flapped recently and not for one that
did not (Codex, PR #728; log mechanics verified by Kilo, same PR). The key is exported rather than dropped —
`BugReportBundle.allowedDetailKeys` carries `dnsCapture`, without which the bundle would render
`_withheld` and the promise above would hold for the raw log only (Kilo, PR #728).

DNS-patch discovery explicitly settles before the initial settings snapshot or post.
Its exact observed destinations and the classifier's claimed set are captured together
on `dnsStateQueue`, so an already discoverable translation does not require a second
cold settings transaction. The physical discovery runs independently of installed
tunnel settings and packet intake. A failure or cancellation before the first post
cannot admit that post.
Observations during startup installation are retained; real capture-membership changes
and ordinary settings refresh requests require a serialized follow-up install. A refresh
while discovery is collecting is absorbed by the initial atomic snapshot; it cannot post
settings before discovery. Startup readiness first requires an
explicit initial result for both Wi-Fi and cellular: inactive paths settle without
an endpoint, while active paths require an admitted endpoint. One overall five-second
deadline also bounds missing initial monitor callbacks. Failure or expiry fails startup;
empty observations and a silent timeout never approve unknown translated capture.
Admitted endpoints are delivered before settlement, and readiness waits for their
routes to be installed. Literal duplicates and equivalent IPv6 spellings add no post.
Stop, failure and lifecycle changes discard the pending drain; a retained discovery-wait
completion is consumed and cancelled exactly once. `DNSPatchInitialDiscoveryPolicyTests`
and `DNSPatchStartupInstallPolicyTests` enforce the transitions;
`DNSPatchRouteDiscoverySourceTests` pin atomic capture, classifier coherence,
callback ordering, cancellation and the queue-owned readiness boundary.
- Home: `Sources/LavaSecKit/DNSCaptureScope.swift`; the routes it reads are
  `Sources/LavaSecKit/TunnelRoutePlan.swift` and `Sources/LavaSecKit/DNSCaptureFloor.swift`
  (the F1 curated set and the F3b captured-resolver host routes, claimed in a chained split), and
  the port-53 interception it
  depends on is `Sources/LavaSecChainedUpstream/ChainedOutboundPacketClassifier.swift`.
- Enforced: `DNSCaptureScopeTests` (executable: the scope each real `TunnelRoutePlan` produces,
  including the split-tunnel case and the two-halves prefix idiom, and that only the full tunnel
  captures EVERY hardcoded-resolver destination) +
  `ChainedOutboundPacketClassifierTests.testADNSQueryToAPublicResolverIsStillIntercepted`
  (destination-independence of the capture itself) +
  `ChainedOutboundPacketClassifierTests.testDotToAClaimedResolverDestinationIsDroppedInSplit`
  (F4: `:853` to a claimed destination is refused in split, to an unclaimed one it is not) +
  `ChainedOutboundPacketClassifierTests.testDotToACuratedPublicResolverDestinationIsDroppedInSplit`
  (F1: the curated public set is part of the claimed set) +
  `TunnelRoutePlanTests.testTheCuratedPublicResolverFloorIsClaimedInChainedSplitOnly` and
  `TunnelRoutePlanSourceTests.testTheProviderPassesCaptureFloorAddressesOnlyForAChainedPath`
  (F1: the floor is merged into the chained split only; DNS-only passes `[]`) +
  `DNSCaptureScopeTests.testTheProviderLogsTheCaptureScopeBesideTheClaimedRoute` (the provider
  wiring, which no value-type test can observe).

## Memory (NE jetsam ceiling ~50 MB)

### INV-MEM-1 — One compile peak at a time (legacy: CON-3)
The in-extension streaming compile (~32 MiB peak) runs behind `snapshotCompileGate` with
generation re-checks before, inside, and after the gate, so superseded reloads never spend
the peak and two compiles never overlap. Pre-decode no-op/over-budget gates prevent
2x-resident decode peaks.
- Home: `LavaSecTunnel/Provider/PacketTunnelProvider+SnapshotCompile.swift` — `loadCompiledSnapshot` (#213 history).
- Enforced: `PacketTunnelDNSRuntimeSourceTests.testInExtensionCompileIsSingleFlightedAndSkipsDoomedGenerations`.

### INV-MEM-2 — Gate before decode, on the same bytes
Every artifact read checks identity + rule budget on the SAME `.mappedIfSafe` bytes it
would decode, so a concurrent atomic republish can never slip a different or over-budget
generation past the header check (TOCTOU-safe). Applies to app stores and the
tunnel-compiled retained artifact alike.
- Home: `LavaSecTunnel/Provider/PacketTunnelProvider+SnapshotCompile.swift` — `reusableCompactSnapshot`,
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

## Chained upstream

Plan: lavasec-infra `plans/2026-07-22-vpn-upstream-chaining-implementation-plan.md` (D7).
The chained data path itself is Phase 3; the entries below record what is landed and
enforced today, and name the half that is not.

### INV-CHAIN-1 — Fail safe to DNS-only
**The data path is live as of the S8.8b flip slice**
(`TunnelDataPathLatchSourceTests.testTheBuildFlagIsFlippedAndStillConsulted`): the provider
constructs the session runtime per start, `readPackets` branches whole batches to the outage
driver, and the surrender path restarts into DNS-only behind a persisted suppression — for a
surrender a network change can lift. `ChainedStartupContract` fails the start for every other
refusal rather than substituting DNS-only for a chain the saved setting asked for; that exception
is what keeps `ChainedSurrenderAutoRecovery` reachable, since it only runs from a lifecycle whose
latch resolved `.chainedSurrendered`. App and provider use `ChainedSurrenderReason` to classify
that exception consistently. Only `chained-recovery-ready:budgetExhausted`, written after
confirmed suppression persistence, authorizes recovery; legacy or unconfirmed surrender markers
remain terminal. A confirmed recoverable marker cannot disable the app's On-Demand mirror or
armed profile. Terminal reconciliation revalidates marker generation, user intent, and live status
under the lifecycle fence before destructive actions.

- Enforced: `ChainedStartupFailureReconciliationTests`, `ProtectionOnDemandSourceTests`.

The tunnel never advertises a route it cannot forward, **except the IPv6 DEFAULT route, which
chained mode claims in order to blackhole**. The exception is scoped to `::/0` deliberately:
it exists to stop IPv6 escaping the tunnel entirely, and nothing about being IPv6 earns a
route a general exemption. A future partial IPv6 route — one subnet the upstream really
carries — would be bound by the rule like any IPv4 route.

The carve-out is the same rule applied to a dual-stack network. Claiming only `0.0.0.0/0`
would leave IPv6 application traffic on the physical interface, outside the tunnel entirely,
which in a privacy feature is a leak rather than a missing feature. Claiming `::/0` fails
CLOSED at the ROUTE: packets are drawn into the tunnel instead of escaping around it, and with
no IPv6 upstream they will go nowhere.

Both halves are landed as of the S8.8b flip. The ROUTE claim is what stops IPv6 escaping
around the tunnel, and it stood alone before the loop existed — the privacy outcome is the
same either way, which is why the claim could ship first. The loop now turns it into an
EXPLICIT, COUNTED discard on each direction: the classifier's `.dropOutboundIPv6` verdict
(`droppedIPv6Count`) for traffic `::/0` captured, and a separate drop at delivery
(`droppedInboundIPv6Count`) for decrypted inbound IPv6. The counters are what make the drop
observable rather than merely implied.

So the subject of this invariant is that no traffic silently escapes the tunnel's protection.
Forwarding what it claims is how that will hold for IPv4; claiming what it blackholes is how
it holds for the IPv6 default route. Read literally the sentence would forbid the one
behaviour that keeps IPv6 from leaking, which is why the exception is stated here rather than
left to be rediscovered in the route plan.

**Split tunnel scopes "the tunnel's protection" to `AllowedIPs` — and claims `::/0` to drop
IPv6.** Everything above describes the FULL tunnel, which claims `0.0.0.0/0` + `::/0` and
therefore owns every destination. A split tunnel (`routingPolicy == .splitTunnel`,
lavasec-infra #198 §3, Option A) deliberately claims ONLY its `AllowedIPs` IPv4 prefixes plus
the DNS-capture route; everything outside them — all non-`AllowedIPs` IPv4 — leaves DIRECT on
the physical interface, and in this mode the protected set is exactly `AllowedIPs` and that
direct egress is INTENDED, not a leak (**founder-signed, §3.3**). **Since 2026-09-19 it also
claims `::/0`, in order to DROP IPv6**, because a plan that left IPv6 direct let a dual-stack
network's IPv6 resolvers answer outside the filter — field-reproduced on 2026-09-17 and
2026-09-19 and recorded in `plans/2026-09-17-path-independent-dns-capture-floor.md`. The v6
drop is the same one full tunnel does, through the same classifier and `ChainedIPv6DNSPolicy`;
the cost, stated rather than hidden, is that a split user loses IPv6 to the open internet and a
v6-only destination fails closed. The `leaksIPv6AroundTheTunnel` predicate is scoped to full
tunnel by its `claimsDefaultRoute` term: a split plan does not claim the whole IPv4 space, so
it is correctly not flagged, and that false is now about the IPv4 term alone. DNS is still
filtered on everything the plan captures (system-resolver DNS reaches the local filter exactly
as in dns-only); the remaining scope reduction is that a raw socket to a hardcoded resolver at
a direct IPv4 destination egresses unfiltered — dns-only-grade for the direct portion
(INV-DNS-1 scope note, §3.3), not a fail-open. Producing a split config is not reachable in a
Release build yet — only the QA staging hook and tests derive `.splitTunnel` — so field
behaviour is unchanged until the §3.6 Slice 6 producer lands behind its C8 gate.

**Privacy will fail closed; connectivity will not always.** Once the data path exists, a
destination that also has IPv4 reaches it through the tunnel where the client races families —
the ordinary WireGuard-client outcome for a peer with no IPv6 `AllowedIPs`. An IPv6-only
destination, an IPv6-only network, or a client that does not race will hang or fail instead.
That is an accepted connectivity cost of the design and the reason forwarding IPv6 is a
planned slice rather than a nicety. Nothing here is measured on device yet; the on-device
battery in Phase 3 (S9) is where the claim gets evidence.
- IPv6 home: `Sources/LavaSecKit/TunnelRoutePlan.swift` (`make(for: .chainedUpstream)`,
  `claimsIPv6DefaultRoute`, `leaksIPv6AroundTheTunnel`, `mtuIsLegalForClaimedFamilies`) and
  `Sources/LavaSecChainedUpstream/ChainedDataPathPolicy.swift` (`dropIPv6`).
- Enforced — the ROUTE SHAPE, which is all that is landed:
  `TunnelRoutePlanTests.testChainedClaimsIPv6SoItCannotEscapeTheTunnel`,
  `TunnelRoutePlanTests.testNoModeCarriesIPv4WhileLeakingIPv6`,
  `TunnelRoutePlanTests.testTheLeakPredicateActuallyDetectsALeak`, and
  `TunnelRoutePlanTests.testEveryModeRunsALegalMTUForWhatItClaims` for the RFC 8200 floor the
  claim brings with it.
- Enforced — the SPLIT scoping (non-`AllowedIPs` IPv4 direct is intended; since F3c split
  claims only its in-tunnel DNS server's on-link ULA `/64` plus capture-floor host routes, so
  general v6 is direct and the system resolver stays filtered over both families. F3b (landed,
  PR #747) captures the network's own resolvers as `/32`/`/128` host routes in a chained split,
  and F1 (2026-09-20) adds the curated public-resolver set in the same chained split only —
  DNS-only passes `[]`, Kilo PR #752):
  `TunnelRoutePlanTests.testSplitTunnelClaimsOnlyAllowedIPsPlusTheDNSRoute`,
  `TunnelRoutePlanTests.testSplitLeavesGeneralIPv6DirectWhileStillCarryingItsDNSBlock`, and
  `TunnelRoutePlanTests.testTheCuratedPublicResolverFloorIsClaimedInChainedSplitOnly`;
  the configuration boundary that derives the mode and refuses the leaky shapes is enforced by
  `ChainedUpstreamConfigurationTests` (`testASplitAllowedIPsSetIsAcceptedAsSplitTunnel`,
  `testASplitConfigCarryingIPv6AllowedIPsIsRefused`,
  `testAnIPv6OnlyOrEmptyAllowedIPsIsRefusedTruthfully`,
  `testASubFloorMTUIsRefusedInBothTunnelModes`). A split resolver must itself be reachable
  through the tunnel — a `DNS =` outside `AllowedIPs` would have its reply dropped as a spoof —
  so `ChainedTunnelResolverSelection` excludes it, enforced by
  `ChainedTunnelResolverSelectionTests.testASplitResolverOutsideAllowedIPsIsNotSelected`.
- Enforced — the CLASSIFIER's inbound verdict:
  `ChainedDataPathPolicyTests.testDecryptedIPv6IsDroppedDeliberatelyRatherThanDelivered`. It
  exercises `writeToTunnelIPv6`, which `decapsulate` produces for a packet arriving FROM the
  peer. Since the S8.8b flip the classifier is LIVE — `ChainedSessionRunner.classifyAndAct`
  consults it for every packet the read loop hands over — so the verdict now decides real
  drops rather than describing a design.
- Outbound narrow-`AllowedIPs` disclosure is precluded at VALIDATION rather than filtered
  per packet: `ChainedUpstreamConfiguration` refuses a configuration whose `AllowedIPs`
  omits the default route (`allowedIPsOmitDefaultRoute`), so every packet the loop
  encapsulates goes to a peer entitled to the whole route by its own configuration. IPv6
  captured by `::/0` still goes nowhere, on two SEPARATE runner paths with separate
  tallies: outbound IPv6 is the classifier's `.dropOutboundIPv6` verdict
  (`droppedIPv6Count`), and decrypted inbound IPv6 is dropped at delivery
  (`droppedInboundIPv6Count`) — the claim-and-drop this exception exists for, enforced on
  both directions.
- What happens to this exception once IPv6 is forwarded is deliberately not predicted here.
  Whether the `::/0` claim is retained is a routing decision of that slice, and the MTU floor
  is imposed conditionally on a plan carrying IPv6 rather than requiring chained mode to carry
  it forever.

The data-path mode is latched once
per session in `loadInitialSharedState`, before any network settings are applied, and all
settings call sites read that latch rather than live configuration — so no mid-session
configuration write and no network flap can change what the tunnel claims. Every refusal
path resolves DNS-only and carries the reason it did, and DNS-only is a fully protective
mode: filtering is unaffected, so degrading here never trades away `INV-DNS-1`.
- Home: `Sources/LavaSecKit/TunnelDataPathLatch.swift`,
  `Sources/LavaSecKit/TunnelRoutePlan.swift`, and
  `LavaSecTunnel/Provider/PacketTunnelProvider+Lifecycle.swift` —
  `latchDataPathMode`, `currentTunnelDataPathMode`, `makeTunnelNetworkSettings(for:)`.
- Enforced: `TunnelDataPathLatchTests.testChainedRequiresEveryTermAndNothingLess`,
  `TunnelDataPathLatchTests.testEveryDNSOnlyResolutionSaysWhyAndEveryChainedOneDoesNot`,
  `TunnelDataPathLatchSourceTests.testAllSettingsCallSitesReadTheLatchAndTheOldLiveReadingSeamIsGone`,
  `TunnelDataPathLatchSourceTests.testChainingIsNotPartOfTheResolverReconnectIdentity`,
  and `TunnelRoutePlanSourceTests.testNoRoutingLiteralSurvivesInTheProvider`.
- The upstream-validity half is ENFORCED since S8.11b/S8.8b: `readyUpstream` is produced by
  `ChainedUpstreamReadiness.evaluate` over the real secret store (wired at the latch,
  `TunnelDataPathLatchSourceTests.testFlippingTheBuildFlagCannotShipWithPlaceholderInputs`),
  and the live-session precondition is the construction ordering — a chained latch whose
  first session cannot be built is downgraded to DNS-only BEFORE any settings read it
  (`ChainedProviderConstructionSourceTests.testConstructionFailureDowngradesBeforeAnySettingsAreBuilt`),
  so the default route is claimed only over a built session.

### INV-CHAIN-3 — The blackhole budget is armed whenever the device is awake
From the moment an outage begins until it ends, chaining is surrendered, **the device
suspends, or the tunnel retires the driver**, **at least one deadline timer is armed, and no
armed instant is later than `outageStart + maximumBlackholeSeconds` on the same clock that
produced `outageStart`.** After a surrender: nothing is armed, the engine tick is cancelled,
and the surrender is reported exactly once. After a retirement (`ChainedOutageDriver.retire()`,
the teardown funnel's half of the driver's lifetime): nothing is armed, the runner is released
— breaking the driver↔runner retain cycle that `deinit` cannot — and every later entry point
is a no-op, so a late wake or path update cannot open an outage for a tunnel that no longer
claims the routes one would blackhole.

**Suspension is an explicit exemption, not an oversight.** `sleep()` quiesces the outage
deadline, the retry delay and the live attempt's watchdog while leaving the outage itself
open, so between a sleep and its paired wake the driver is timing an outage with nothing
armed. That window is deliberate and it is bounded by the same reasoning the sleep refund
rests on: the process is suspended, so nothing is being blackholed and there is nothing for
a budget to bound. Arming across it would be worse than useless — a one-shot delivered
during suspension can only surrender, and a paired wake cannot undo a surrender.
The invariant therefore holds ACROSS the boundary rather than through it: the wake either
ends the outage or, finding no runner, begins a fresh one with a fresh deadline, so every
interval in which the tunnel can actually blackhole traffic is bounded.

**This exemption is about BLACKHOLING and does not extend to key lifetime.** "The process is
suspended, so nothing is being blackholed" is an argument about traffic the user is waiting
on; it says nothing about whether the engine may still encrypt. The quiesced window is one in
which `tick()` decides nothing while `handleOutboundBatch` is not quiesced at all, and
boringtun enforces `REJECT_AFTER_TIME` only inside `update_timers` — so the same window that
is safe to leave unarmed is one in which a session could be used past its specified lifetime.
That is a separate obligation, discharged separately by
`ChainedSessionRunner.engineTimersAreFreshOnQueue()`. Recorded here because the reasoning
above reads like it covers both, and it does not.
Chained mode claims `0.0.0.0/0` (`INV-CHAIN-1`), so a tunnel with no working peer is a
blackhole rather than a degraded link — the budget is the only thing bounding it, and a
window with nothing armed is a window with no bound at all. Stated over observables rather
than over a state enum, because "exactly one of three states" is enforced by the compiler
and asserts nothing.
The object that AUTHORIZES an attempt is the object that arms its watchdog, in one
indivisible step on the engine queue with a single clock reading: the value recording a live
attempt requires its timer non-optionally, so an authorization nothing is bounding is not a
representable state.
- Home: `Sources/LavaSecChainedUpstream/ChainedOutageDriver.swift`
  (`startAuthorizedAttempt`, `finishAttempt`, `beginOutage`), `ChainedOutageSupervisor.swift`.
- Enforced: `ChainedOutageDriverTests`
  (`testSomethingIsAlwaysArmedInsideTheBudgetAndNothingBeyondIt`,
  `testTheSuspensionExemptionIsBoundedByTheWakeThatFollowsIt`,
  `testTheWatchdogIsArmedAtTheAuthorizedInstantHoweverLateTheAttemptStarts`,
  `testAnAttemptIsAlreadyArmedWhenItsSessionBuildFails`,
  `testARetiredAttemptTakesItsWatchdogWithIt`,
  `testADeadPathReachesTheRetryLadderWithoutWaitingForTheEngine`).
Two causes start the clock, each detecting a different fault with the evidence only it can
produce. The LINK cause detects that the WIREGUARD LINK is not working — an obliging send
with no authenticated answer — and deliberately does NOT attempt to detect a peer whose link
is healthy but whose EGRESS is dead: those two produce a byte-identical observation stream at
this layer and differ only in scope, which is measurable only against a destination known to
be live; the user's traffic contains none, an adversary chooses which destinations appear in
it, and this system has no probe target of its own. The predicate that tried anyway was
satisfiable by any web page. Worst-case user-visible blackhole is therefore
`linkSilenceThreshold + maximumBlackholeSeconds` = 36 s, not 15.
The TUNNEL-DNS cause (S6) covers the DNS-scoped subset of dead egress the link cause cannot
see: sent-and-unanswered tunnel DNS across at least two distinct query names, sustained past
`tunnelDNSUnservedThresholdSeconds`, reported by the provider's tunnelled resolution path
through `reportTunnelDNSObservation`. Its evidence is FORGEABLE by chosen traffic — an
attacker's subdomains supply distinct names for free — which is why it is capped at
`maximumTunnelDNSOutagesPerLifecycle` and why the unforgeability argument above belongs to
the link cause alone. A TC answer, and any per-domain failure while other names answer, is
resolver LIVENESS and never arms it (resolved decision 3).
- NOT detected at all: a peer forwarding nothing while keeping its link alive, for traffic
  other than DNS. The engine offers no backstop either —
  `timer_tick(TimeLastPacketReceived)` clears `want_handshake`, so a keepaliving peer
  suppresses the re-handshake indefinitely. The DNS-scoped detection above bounds the case
  where the user's foreground experience is DNS-first; the general-egress gap remains an
  accepted, recorded one.

### INV-CHAIN-2 — Chained availability gate
Chained mode is offered only when
`Plus ∧ (RAM ≥ ~3.4 GB ∨ experimentalChainedOverride) ∧ ¬startupCrashLoopTripped`. The same
predicate gates the Settings toggle and the tunnel latch, so a synced or restored
chaining-on configuration does not inherit another device's decision. There is no chained
rule cap — where chaining is available the full tier budget applies unchanged. The
in-extension streaming compile
(~32 MiB peak, `INV-MEM-1`) is suppressed while chained, degrading through the
last-known-good ladder rather than running a peak that cannot coexist with the resident
engine under the ~50 MB ceiling.

When the shared configuration is readable and asks for chaining, the provider constructs the
chained runtime and claims its routes whenever the latch allows it. When the latch refuses — an
unreadable configuration or device state, an unbuildable upstream, an ineligible device, a
standing surrender — the provider completes the latched DNS-only path instead of failing
`startTunnel`, records the refusal for disclosure, and retains the saved chaining-on state. A
system failure is never permission to leave the device unfiltered, never an automatic OFF and
never a disarmed Connect-On-Demand: Guard stays on and the refusal is surfaced with an explicit
Restart until the user turns protection off or a later start chains successfully. DNS-only
startup remains valid when the saved setting is off, and on the pre-first-unlock placeholder
where the real setting is explicitly unreadable rather than known-on.

Setup disclosure and the chaining request are separate device-local choices. Opening setup
never enables chaining. Closing setup commits chaining OFF in the same configuration write,
while retaining credentials. The user-facing configuration editor preserves the current routing
choice; first save leaves chaining OFF. A new ON request requires setup open, a readable saved
configuration and its key, and device/account eligibility. OFF remains available when credentials
are missing or unreadable. Full deletion persists OFF before deleting either credential half;
a failed OFF write deletes nothing, and failed key cleanup leaves OFF with a retry. Only routing
changes use the existing buffered reconnect. Old known-ON configurations with missing credentials
fail the app's start/reconnect preflight with setup recovery copy; unknown storage never silently
withdraws the chaining request. The provider startup contract remains the final cross-process gate.
`WireGuardSetupTests`, `WireGuardSetupSourceTests`, and `ProtectionSettingsApplySourceTests`
cover these boundaries. Backup restore preserves both local choices. Guard uses
`GuardStatusMessagePolicy` for its one message slot: an automatic chaining disable retires
only its owned setup error and recovery action, while unrelated errors and failed reconnects
remain visible even when setup is collapsed. `GuardStatusMessagePolicyTests` covers selection.

A lifecycle marker is an unknown-hard-exit breadcrumb, not proof of memory termination. The
startup breaker advances only for repeated exits from the same exact installed extension binary
before chained forwarding was proven. The identity includes a streaming SHA-256 of the executable,
because local builds share a marketing version/build number and carry no source revision; an
unreadable executable identity fails startup closed instead of reusing a colliding identity. First
inbound forwarding proves that lifecycle healthy; build replacement, legacy marker state, a
proven-forwarding lifecycle, or controlled teardown cannot add a strike. The build and per-lifecycle
nonce identify forwarding proof outside the shared lifecycle marker, so
a delayed callback cannot clobber or bless a replacement lifecycle. Proof publication, marker
consumption, replacement-marker installation, teardown, surrender, every other lifecycle-record
mutation, and explicit-start recovery share one identity-namespaced, bounded transaction across app
and tunnel processes. Consumption returns the complete live post-transition snapshot, while
marker-clearing writers re-read and fence against the lifecycle ID captured by their own provider
(never one adopted from a fresh shared-store read), so neither stale decision fields nor a newer
provider can be misclassified, erased, or resurrected. Marker installation refuses
while a newer active marker exists, so a superseded startup
also fails closed instead of overwriting its replacement; unavailable coordination fails closed
instead of hanging startup. An explicit Guard start clears the breaker and surrender atomically
around the current marker before retrying; the app never erases tunnel-owned evidence, and the
replacement provider consumes a stale marker before installing its own. Automatic
Connect-On-Demand starts cannot erase evidence. No separate product Reset control is required or
exposed.

A stored preference that the device or account can no longer honour is cleared, so
Settings can never read "on" while nothing happens. Revocation is a strict subset of
ineligibility: a lapsed subscription and hardware below the floor clear the flag, but the
startup-loop breaker does not — it is device-local and an explicit Guard start clears it, so
revoking the preference too would hide the contradiction instead of retrying it. Safety does
not depend on reconcile: the latch refuses independently and the startup contract keeps Guard off.
- Home: `Sources/LavaSecKit/ChainedAvailabilityPolicy.swift` (`ChainedAvailability.reconcile`,
  `revokesStoredPreference`), `ChainedDeviceEligibilityStore.swift`,
  `ChainedStartupContract.swift`, the latch, `LavaSecTunnel/Provider/PacketTunnelProvider+Lifecycle.swift` —
  startup contract — `LavaSecTunnel/Provider/PacketTunnelProvider+ChainedDataPath.swift` — forwarding
  proof — `LavaSecTunnel/Provider/PacketTunnelProvider+SnapshotCompile.swift` — `loadCompiledSnapshot`'s mode
  check — and `LavaSecApp/AppViewModel/AppViewModel+FilterRulesBudget.swift` —
  `reconcileChainedUpstreamAfterEligibilityChange`, folded into `persistPaidPlanFlag`'s write
  (`LavaSecApp/AppViewModel/AppViewModel+HubBridges.swift`).
- Enforced: `ChainedAvailabilityTests`, `ChainedStartupCrashLoopPolicyTests`,
  `ChainedDeviceEligibilityStoreTests`, `ChainedStartupContractTests`,
  `ChainedOutageDriverTests.testForwardingProvesTheLifecycleHealthyExactlyOnce`,
  `ChainedUpstreamReconcileTests` +
  `ChainedUpstreamReconcileSourceTests.testALapseClearsTheChainingFlagInTheSameWrite` +
  `TunnelDataPathLatchTests.testTheDeviceRefusalCarriesTheSameCauseThePolicyReports` +
  `TunnelDataPathLatchSourceTests.testSavedChainingCannotSilentlyStartDNSOnly` and
  `testForwardingProofIsPersistedForTheExactLatchedLifecycle`.

### INV-CHAIN-4 — One rotation, one generation, one commit point
The chained upstream is stored as TWO halves — the configuration in the shared App Group
file `chained-upstream.json` (Class C, see `INV-PERSIST-2`) and the private key in a
Keychain generic password at `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` in a
shared access group — and **a reader can never observe a configuration from one rotation
with a key from another.**

Both halves are namespaced per BUILD IDENTITY, and both by the same one. The key half gets
it from the config-scoped `LAVA_KEYCHAIN_SHARING_GROUP` (production
`com.lavasec.app.chained-upstream`, QA `com.lavasec.dev.qa.chained-upstream`); the file
half has no entitlement to ride on, because `group.com.lavasec` is identical in both builds
and they install side by side, so it is namespaced by FILENAME instead
(`chained-upstream.qa.json` and `chained-upstream-write.qa.lock`) via
`ChainedUpstreamStoreIdentity`, selected on the QA build configuration's own compilation
condition — the same one that scopes the sharing group above. (Named here only by
description: the contamination guard reserves the literal flag for approved source and
analyzer paths, and this document is not one.) Namespacing only one half is worse than namespacing neither: a QA
rotation would replace the generation the production tunnel reads while its key landed in
the QA-only group, stranding production at `Refusal.noPrivateKeyStored` until reconfigured.

The split is product-motivated, not incidental. `ThisDeviceOnly` items are excluded from
every backup and do not survive device migration; the app-group file does. A migrated
device therefore legitimately holds a configuration whose key is gone, which is
`Refusal.noPrivateKeyStored` ("re-enter your key") rather than `noConfigurationStored`
("set the feature up"). Collapsing both halves into ONE Keychain item would make tearing
impossible AND make that refusal unreachable, trading the migration story for a
consistency property the commit protocol already provides.

The key item is ADDRESSED BY generation (`upstream-key/<hex>`), so account and value land
in one `SecItemAdd` and the stamp cannot disagree with the secret it names. The
configuration's stamp is a required, non-defaulted field inside the committed blob —
never a sidecar (a third read that tears) and never an attribute updated separately from
the value (which tears WITHIN one item). `0` is reserved and refused on read, so two
independently damaged halves cannot both decode to a default and compare equal.

The commit protocol has exactly one commit point:
1. add the key at the new generation — ADDITIVE, the committed pair is untouched;
2. atomically replace the configuration file — one `rename(2)`, THE commit point;
3. delete every other key account — idempotent, best-effort.

Killed after (1) the reader sees the old pair; after (2) the new pair plus a harmless
orphan; mid-(3) the new pair. No INTERRUPTION of a writer produces a mismatched pair, so
the durable torn write is unrepresentable rather than merely detectable — which matters
because a durable mismatch would report `Refusal.storeKeptChanging` on every evaluation
for the life of the install, a refusal whose own documentation says the store "simply
never held still".

CONCURRENCY is a second obligation and needs a second mechanism, because step (3) has a
window the protocol's ordering cannot close: the sweep re-reads the committed generation
after enumerating, but nothing is atomic between that recheck and the deletes it
authorizes, so a `rename(2)` landing in that gap commits a generation whose key the sweep
then deletes — a configuration without a key, at a stable generation, durable. So every
public writer runs under an exclusive advisory lock on `chained-upstream-write.lock` that
FAILS CLOSED (`FilterPublishLock.withRequiredExclusiveLock`): a writer that cannot open or
lock the file refuses with `writerExclusionUnavailable` rather than proceeding unlocked,
which is the opposite of the filter-publish path's deliberate degrade-open. `flock` is
advisory, so what makes that sufficient is that every writer of these two halves is a
public entry point of `ChainedUpstreamKeychainStore`. Readers never take the lock.

The generation is drawn fresh per rotation and refuses both `0` and the currently
committed value. A monotonic counter is NOT acceptable for this store: incrementing
requires reading the previous value, and the previous value can be gone (restored backup,
migrated device, deleted key), so the counter re-issues a number an existing half already
carries. A commit timestamp fails the same way on clock rollback.

Successful chain/fallback preference changes, rotation saves and full deletion schedule
a foreground reconnect only for an already-active Guard. `ProtectionSettingsApplyState`
waits 500 ms after the latest commit and keeps one restart in flight; edits during it
merge into one follow-up. A failed commit cannot schedule an apply, and a settings
change cannot create a new Guard-ON intent. Each ticket captures the strict durable
external-Restart generation as well as the app intent revision, so a newer Live Activity
Restart consumes older pending work. The app revalidates both after the lifecycle
fence, reads the live manager before stopping, and carries that validation through the
replacement start. A failed generation read never impersonates the initial generation
or a harmless mismatch: the apply stops and publishes the read failure, even if it
occurs after claiming the ticket. A later successful apply clears that error. Early refusal releases inherited teardown.
`ProtectionSettingsApplyStateTests` exercises timing and intent cancellation;
`ProtectionSettingsApplySourceTests` pins persistence and native lifecycle wiring.
The running-generation comparison remains authoritative; a saved preference alone
does not prove the new tunnel adopted its configuration. Actual reconnection and
traffic remain device acceptance.
- Home: `Sources/LavaSecKit/ChainedUpstreamSecretStorage.swift`,
  `Sources/LavaSecKit/ChainedUpstreamKeychainStore.swift`,
  `Sources/LavaSecKit/ChainedUpstreamKeyItemStore.swift`, and the retroactive conformance
  in `Sources/LavaSecChainedUpstream/ChainedUpstreamKeychainSecretStore.swift`.
- Enforced: `ChainedUpstreamKeychainStoreTests`
  (`testARotationKilledAfterTheKeyAddLeavesThePreviousPairUntouched`,
  `testARotationKilledAfterTheCommitPointIsCompleteAndLeavesOnlyAnOrphan`,
  `testAFailedKeyAddCommitsNothing`, `testASweepThatRacesARotationDeletesNothing`,
  `testASweepRefusesRatherThanRunningWithoutWriterExclusion`,
  `testACommitRefusesRatherThanWritingWithoutWriterExclusion`,
  `testRemoveAllRefusesRatherThanDeletingWithoutWriterExclusion`,
  `testAQABuildAndAProductionBuildDoNotShareOneUpstreamRecord`,
  `testASweepOverAnUnreadableConfigurationDeletesNothing`,
  `testTheKeyIsFetchedUnderTheCommittedGenerationSoTheHalvesCannotDisagree`,
  `testAZeroGenerationIsRefusedRatherThanMatched`) and
  `ChainedUpstreamSecretStorageTests` (`testTheSweepNeverNamesTheCommittedGeneration`,
  `testTheCommittedGenerationIsNeverReissued`, `testTheReservedZeroGenerationIsNeverMinted`,
  `testTheQAIdentityAddressesDifferentFilesThanProduction`), plus the cross-process wiring
  pin `ChainedUpstreamEntitlementSourceTests.testTheFileHalfIsNamespacedByTheSameConfigurationAsTheKeyHalf`.
- NOT enforced, and it cannot be from a host test: that a single-item `SecItemAdd` is
  atomic is Apple's guarantee; that the app and the tunnel actually see one another's
  items needs a signed on-device round trip (the simulator does not enforce keychain
  access groups at all, so a green simulator run is not evidence); and whether the mint's
  entropy source is a CSPRNG is a property of the injected closure — a counter injected in
  its place satisfies every refusal the suite can assert.
- NOT decided: an undecodable-but-readable stored configuration currently reaches the
  tunnel as `Refusal.storeUnavailable` ("retry later") even though it never gets better on
  its own. The store reports it distinctly (`configurationUnusable`); adding a `Refusal`
  case is a plan-owned change to an enum the latch and the log surface enumerate.

### INV-CHAIN-5 — Chained DNS egresses through the tunnel, with one named exception
While chained is latched, user and filter DNS is carried as plain UDP DNS through the
session to the latched configuration's SELECTED resolvers
(`ChainedTunnelResolverSelection`). Every physical-interface transport — device DNS, the
encrypted presets, plain DNS on an unpinned socket, and the T0 ladder — is refused
with a fail-closed answer per `INV-DNS-1`. The route consult precedes the egress
allowance, so the allowance keeps answering only the physical-interface question.

**THE INVARIANT IS NOW CONDITIONAL ON THE LATCHED ROUTE PLAN, and this is the one place it
bends (PR #590).** In a **full tunnel** it is absolute and unchanged: the answer stays no,
including for the fallback ladder. In a **split tunnel** exactly one rung may leave —
the user's chosen T1 alternative resolver, on the physical interface.

Why it may bend there and only there: in a split tunnel the data path to that destination
ALREADY goes direct, so the local network already holds the address and the TLS SNI for
every site visited. Refusing to send the NAME over a path already carrying the CONNECTION
protects nothing and costs the lookup. In a full tunnel the observer sees none of it, so
the same relaxation would be a genuine leak — which is why the discriminator is the
latched `ChainedRoutingPolicy` for that session, never a stored setting a changed profile
could inherit.

Field evidence that forced it: rc8 (`8006a2a`) and rc9 (`0d367ca`) both shipped a T1
routed THROUGH the peer. rc9's capture (build 1787723354) measured three attempts and
three drops — `AllowedIPs` says where we send, and cannot make a peer forward. The
dependency on the peer being an exit node is what this exception removes.

Six conditions gate the exception, and all six are enforced in code rather than by
convention:
1. **Split tunnel only** — `ChainedResolverEgressPolicy.permitsTierOneFallbackOnPhysicalInterface`
   answers false for `.fullTunnel` and for DNS-only, and the allowance
   (`EgressAllowance.chainedSplitTunnelMode`) differs from `chainedMode` in that one field.
2. **A resolver that can be a rung** — the user's ONE selection, which serves both modes.
   The opt-in toggle and the second, plain-IPv4-only picker behind it are deleted (the
   plan's S4): they existed because the rung rode the tunnel, which carries plain UDP :53
   and nothing else, and the rung stopped riding it in PR #590. EVERY transport the picker
   offers is eligible, device DNS included (PR #592): a split-tunnel chained user whose
   selection is Device DNS is exactly a native Tailscale user with MagicDNS and no global
   nameservers — the tailnet's own `DNS =` serves what it owns, and the rest falls through
   to the resolver this network handed out. Refusing that rung left the chained user
   strictly worse off than running the tunnel client directly, for an exposure they had
   already chosen, and Lava's blocklist still runs before the upstream query either way.
3. **T0 declined to serve** — no response after a wire attempt, a resolver error
   (full RCODE other than NOERROR/NXDOMAIN), or a malformed response. Structurally
   valid NXDOMAIN and NOERROR/NODATA stay T0's, so a split-DNS name never receives
   a stranger's negative. Local refusals alone do not open the physical rung.
4. **The user's ALTERNATIVE selection, never their primary** — device DNS may be
   SELECTED as the rung (condition 2) but never IMPOSED on it: the device-DNS fallback
   MODE is ignored when building the rung's plan, so a fallback episode that arose from the
   PRIMARY's health can never rewrite the rung into a device-DNS plan the user did not pick
   (`LAV-87`). The distinction is the whole of the threat model here: a user who chose
   device DNS accepted the network's resolver; a user who chose 1.1.1.1 did not, and an
   outage must not silently hand their names to the network anyway.

   The rung's configuration used to ALSO force `fallbackToDeviceDNS` off, and no longer
   does — it carries the user's own value. That flag gates a PER-QUERY fallback the user
   asked for, which is not an imposition; the mode above is the imposition, and it is
   enforced independently. The forcing was in any case inert until the rung began running
   the full ladder, because the flag is read in `resolveUpstream` and the rung was
   dispatched into `resolvePrimaryUpstream` (`INV-CHAIN-7`).
5. **Only ADMITTED addresses, for a PLAIN selection** — `restrictingPlainAddresses(to:)`
   narrows the plan to the set `fallbackOutcomes` publishes as admitted, so an address that
   deduped into T0 or failed a usability gate never reaches the wire. Nothing admitted
   means no rung. The gate is plain-only by construction: both its questions ("is this
   already the conf's own `DNS =`", "can this IPv4 literal ever answer") are unaskable of a
   DoH URL or a DoT hostname, and running them over one reports the user's working resolver
   as unusable. An encrypted selection is a rung without an address question.

   **A DEVICE-DNS selection is address-gated too** (PR #592), because its captured resolvers
   ARE plain IP literals. One consequence is worth naming rather than leaving to be
   rediscovered: on an IPv6-only or NAT64 network whose capture contains no usable IPv4
   resolver, every entry is `.unusableIPv6` and there is no rung. That is not an oversight
   inherited from the plain tier — it is `INV-CHAIN-1` above. Chained mode claims `::/0`
   deliberately, to blackhole IPv6, and the rung's socket is `.systemChosen` for an ordinary
   destination (condition 6) — unbound and subject to that claim like any other socket;
   condition 6's floor-claim case pins physical or refuses, so a claimed destination is
   never swallowed. An IPv6 rung would be drawn into the tunnel and dropped by the very
   route that exists to stop IPv6 escaping.
   Admitting it would trade a NAMED refusal the panel can explain for a silent timeout.
   `DeviceDNSFallbackPolicy.isUsableResolverAddress` accepting IPv6 and NAT64 is not in
   conflict: it answers the structural question "can this address ever be a resolver", for
   the DNS-ONLY ladder, where no `::/0` claim exists. Giving these users a rung needs an
   IPv6 upstream or a pinned physical socket — a change to `INV-CHAIN-1`'s bargain, not to
   this gate (Codex P1, PR #592).
6. **Never pinned to the tunnel** — `ChainedResolverEgressPolicy.tierOneSocketBinding()`
   never yields `.boundToTunnel`. It is CONDITIONAL, and F2 (PR #747) is the condition:
   - an ordinary destination, or one the profile's own `AllowedIPs` already carry, yields
     `.permitted(.systemChosen)` — unbound, the routing table decides;
   - a destination the DNS capture floor claimed (F3b) and the profile does NOT carry
     yields `.permitted(.boundToPhysical(interfaceIndex:))`, pinned to the live physical
     interface so the claimed route cannot draw the query back into the tunnel;
   - a claimed, profile-uncovered destination with no known physical index REFUSES
     (`.refusedNoPhysicalInterface`, the missing-PHYSICAL-pin case, distinct from the
     missing-tunnel-interface `.refusedNoTunnelInterface` so a log does not name the wrong
     condition) rather than fall back to `.systemChosen`, which would re-enter the claim;
     the query fails closed per `INV-DNS-1`.
   The tunnel still claims no T1 route of its own. NOTE the limit of the unbound case:
   `.systemChosen` does not pin the rung away from the tunnel either. A profile whose own
   `AllowedIPs` cover the resolver still carries it through the peer — deliberately,
   because overriding the user's own routes would disclose a name their configuration
   places inside the tunnel.

Carried queries advertise an EDNS0 payload capped at 1232 bytes and never above what the
client itself advertised (`DNSEDNS0`); a residual truncated answer on the TUNNELLED path
fails CLOSED — the TC answer is never relayed, there is no TCP retry — and is resolver
LIVENESS to the outage supervisor, never an arming cause (resolved decision 3). The
physical rung is not subject to that limit: it has a TCP retry, on the same egress
interface as its UDP hop. Endpoint bootstrap (S1) remains a separate sanctioned
physical-interface DNS egress, distinguishable at capture by its own egress type
(`ChainedResolverEgressPolicy.EndpointBootstrapEgress`).

The proof is assembled at seams, because no single test can drive
readPackets → classifier → serveDNS → orchestrator → socket: the orchestrator's
executor-count captures (no physical executor runs for the T0 ladder while a route is
supplied, and none at all in full tunnel), the socket layer's binding refusal
(`socketBinding` yields no system-chosen socket for T0 while chained — the T1
rung's binding is a SEPARATE function so the two cannot be confused), the tunnelled loop's
capture of the capped query at the socket seam, and the real-peer session harness proving
socket → tunnel egress byte-for-byte (`ChainedTunnelDNSCaptureTests`).
- Home: `Sources/LavaSecDNS/TunnelledPlainDNSResolution.swift`,
  `Sources/LavaSecDNS/DNSEDNS0.swift`,
  `Sources/LavaSecDNS/ResolverOrchestrator.swift` — the hoisted tunnelled consult, the
  T1 rung and `merging`,
  `Sources/LavaSecChainedUpstream/ChainedResolverEgress.swift`,
  `Sources/LavaSecChainedUpstream/ChainedTunnelResolverSelection.swift`, and
  `LavaSecTunnel/PacketTunnelProvider.swift` — the `tunnelledPlainDNSRoute` closure in the
  orchestrator's initializer, `LavaSecTunnel/Provider/PacketTunnelProvider+EncryptedBootstrap.swift` —
  `resolveTunnelledPlainDNS`, and `LavaSecTunnel/Provider/PacketTunnelProvider+Configuration.swift` —
  `currentTierOneFallbackPlan`.
- Enforced: `TunnelledPlainDNSResolutionTests` (the capped-query capture, the TC
  fail-closed/liveness split, the unanswered classification) +
  `ResolverOrchestratorTests` (`testATunnelledRouteCarriesPlainDNSThroughTheSessionNotThePhysicalInterface`,
  `testTheRouteConsultPrecedesTheAllowanceRatherThanBeingGatedByIt`,
  `testChainedModeRefusesPlainDNSWhenNoRouteIsSupplied`, and for the exception
  `testASplitTunnelTierOneRungRunsOnThePhysicalInterface`, `testAFullTunnelNeverRunsTheRung`,
  `testNoRungRunsWhenTheUserHasNotOptedIntoATierOneFallback`,
  `testTheRungResolvesTheAlternativePlanRatherThanThePrimary`,
  `testTheRungResolvesADeviceDNSSelectionOnThePhysicalInterface`,
  `testAFullTunnelStillRefusesADeviceDNSRung`,
  `testTheTierOneRungPermitsEveryTransportAndNeverSpawnsARung`,
  `testTheChainedPrimaryAllowancesStillRefuseDeviceDNS`,
  `testAnAuthoritativeNegativeFromTierZeroIsNotSecondGuessed`,
  `testTheRungAsksForThePhysicalInterface`) +
  `ChainedResolverEgressTests` (`testChainedNeverYieldsASystemChosenSocket` — T0 only,
  `testTheTierOneRungIsNeverBoundToTheTunnel`,
  `testTheTierOneBindingDoesNotOverrideTheProfilesOwnRoutes`) +
  `DNSResolverRuntimePlanTests` (`testTheRungPlanKeepsOnlyAdmittedPlainAddresses`) +
  `AppConfigurationTests` (`testTheTierOneConfigurationIsTheUsersOwnResolverSelection`,
  `testADeviceDNSSelectionIsEligibleAsTheRung`) +
  `ChainedTunnelResolverSelectionTests`
  (`testAnEncryptedTierOneEndpointIsAdmittedWithoutAnIPv4Gate`,
  `testAnEncryptedTierOneEndpointIsStillUnavailableInAFullTunnel`) +
  `ChainedTunnelDNSCaptureTests` + the provider wiring pins in
  `TunnelDataPathLatchSourceTests`.

## Concurrency

### INV-CHAIN-6 — The per-destination reachability signal reports and never gates
The chained data path counts sends and receipts per in-tunnel destination
(`ChainedDestinationTable`) and judges each one with
`ChainedDestinationReachabilityPolicy`. The verdict is REPORT ONLY: it never feeds
`ChainedEstablishmentPolicy`, never declares an outage, never surrenders, and never
contributes to a recommended action.

**Why the signal exists.** A split-tunnel chained session had no forwarding-health
detection at all, and its one forwarding counter was not a forwarding counter. Two
correct decisions composed into that hole. PR #558 empties `resolverSourceAddresses` in
split tunnel — there DNS is often the only captured traffic, and excluding it would starve
the connect gate and false-close a healthy split tunnel — so the DNS-reply exclusion
excludes nothing and `forwardedNonDNSByteCount` counts DNS replies. PR #567 then confined
the egress-dead arm to `.fullTunnel`, because in split tunnel the runner still carries the
configured `AllowedIPs` traffic and a flat aggregate is not proof of dead egress.

Field evidence: 2026-08-27 06:04, build `1787806128` (`fbe33cdc96af`), split tunnel over a
conf with `AllowedIPs = 100.64.0.0/10` and `DNS = 100.100.100.100`. Total connection
failure to the one host the user wanted, and the tunnel reported `hasHandshake true`, zero
outages, and `rxBytes == forwardedNonDNSByteCount == 338311` — equal to the byte, because
the resolver sits INSIDE the claimed range so every DNS reply landed in the "forwarding"
figure. The panel said healthy throughout. A session eleven minutes later, with
byte-identical telemetry, worked perfectly.

**Why no aggregate can replace it.** The question is not "is the chain forwarding" but "is
THIS destination answering". In that capture the range was carrying traffic while the
wanted host was silent, and every range- or session-scoped counter reads healthy in exactly
that case — which is the case that matters, since a split tunnel's claimed range is usually
a whole tailnet and one node being down is ordinary.

**Why reporting does not reopen what PR #558 and PR #567 closed.** Both of those reasons
are about GATING, and neither reaches a read-only signal. The egress-dead DECLARATION stays
confined to `.fullTunnel`, unchanged and pinned; only the REPORT is produced under both
routing policies.
- `ChainedOutageDriverTests.testASplitTunnelNeverDeclaresAnEgressDeadOutage` — the gate is
  untouched.
- `ChainedOutageDriverTests.testASplitTunnelStillReportsAnUnansweredDestination` — the
  report is produced anyway.
- `DataPathHealthTests.testAnUnansweredDestinationIsReportedWithoutAnyRecommendedAction` —
  the surfaced verdict cannot become `.reconnect`. The exclusion is structural:
  `ConnectivityHealthSupervisor` never consults the data-path verdict for
  `recommendedAction`, so a new reason on that signal inherits the guarantee rather than
  asking for it.

It is also not a prober: no synthetic packets are ever sent. It reads traffic the user
already generated, exactly as the egress-dead arm does.

**What the connect gate does with a missing verdict (PR #629).** `ChainedEstablishmentPolicy`
still requires a positive forwarded-byte delta before anything may say "Protected", and this
signal still does not feed it. What changed is the consequence of the evidence being absent:
the gate resolves UNCONFIRMED and leaves the tunnel up behind an honest non-green surface,
where it once turned the user's protection off. The reason is the hole described above seen
from the other side — in split tunnel the routed set is the tailnet plus the resolver, so an
IDLE tailnet yields no forwarded bytes on a chain that is entirely healthy. On 2026-08-30
that produced three consecutive connect failures on `702afb17` with `hasHandshake true`,
`outageCount 0` and `channelSendFailEdges 0`, each tearing down working DNS filtering. The
gate was demanding evidence of demand nobody had made. "The chain went dead in steady state"
remains the ladder's question — link-silence, tunnel-DNS-unserved, and the `.fullTunnel`
egress-dead arm — because those carry a demand term the connect gate has never had.

**Memory and privacy.** The table is fixed at 32 entries and allocation-free on the packet
path after warm-up (`INV-MEM-1`); eviction is by last activity, so the destination the user
is actively sending to is the last one dropped. Its keys are IPv4 only, because `INV-CHAIN-1`
blackholes outbound IPv6 and a v6 row could only record sends this process itself discarded.
What crosses into `TunnelHealthSnapshot` is a COUNT and a DURATION and never an address: a
tailnet address names the user's network as surely as a resolver address does
(`redactingChainedFallbackAddresses`, PR #575, PR #592), so keeping addresses out entirely
leaves nothing for that fold to reach and no further road into a bug report.

### INV-CHAIN-7 — The T1 rung runs the full fallback ladder, on the rung's own interface
The chained T1 rung resolves through `ResolverOrchestrator.resolveUpstream`, the same
entry a DNS-only query uses — not `resolvePrimaryUpstream`. Every cross-route fallback
beneath it (`shouldFallbackToDeviceDNS`, `shouldFallbackToEncrypted`) is therefore reachable
from the rung, and each one reads the RUNG'S allowance and the RUNG'S egress interface
rather than the orchestrator's.

**Why.** `resolvePrimaryUpstream` runs "only the plan's primary route, including ordered
endpoint failover but no cross-route fallback" — its own words. Dispatching the rung there
gave a chained user a strictly shorter chain than a DNS-only user asking the identical
question: one route, versus a route plus a device fallback plus an encrypted fallback. It
is also why forcing `fallbackToDeviceDNS` off in `chainedTierOneResolverConfiguration` was
inert, and why setting it (PR #593) changed nothing and was reverted — the flag is read one
level up, on a path the rung never entered. One dispatch bug, two symptoms.

**Field evidence.** 2026-08-27 18:32/18:38/18:46 JST, build `fbe33cdc96af`, split tunnel on
a moving train, selection Device DNS. The device-resolver capture is frozen at `startTunnel`
for the life of a session — the in-process system read is masked while the tunnel owns
device DNS, so every wake logs `count: 0` and every retry cycle exhausts — and no
`network-path-changed` fired across ~40 minutes of tower handover. The rung was therefore
asking resolvers captured on a tower the phone had left, with nothing beneath it. The user's
workaround was a full off/on, which is the only thing that recaptures.

**Scope, honestly.** T0 answered ~98% of queries in those captures, so the missing ladder
is the design defect the evidence establishes, not a proven account of the browsing failure.
The frozen capture and the invisible handover are tracked separately in
`plans/2026-08-27-chained-resolver-adaptation-and-tier-three.md` (lavasec-infra).

**What this does NOT relax.** `tierOneFallbackAllowance` was already permissive of every
transport and already sets `permitsTierOneFallbackOnPhysicalInterface: false`, so no egress
permission changed and a rung still cannot spawn a rung — structurally, because
`.tierOneFallback.consultsTunnelledRoute` is false and the T0 block is unreachable from
it. Device DNS may still never be IMPOSED on the rung: the fallback MODE is ignored at the
plan site (`INV-CHAIN-5` condition 4, `LAV-87`).

**Enforcement.**
- `ResolverOrchestratorTests.testTheTierOneRungRunsTheFullFallbackLadder` — the rung's device
  fallback runs, and runs on `.physical`. A fallback that reverted to `.providerDefault`
  would aim the rescue back down the tunnel that just declined the name.
- `ResolverOrchestratorTests.testTheRungsLadderReachesTheEncryptedFallback` — the ladder
  reaches T2.
- `ResolverOrchestratorTests.testTheEncryptedFallbackDoesNotReRunTheChainedLadder` — the
  re-entry PR #590 closed stays closed for `.planned`.

### INV-QUEUE-1 — dnsStateQueue confinement
Mutable tunnel DNS state is `dnsStateQueue`-confined. Entry points that may already be
on-queue use the `DispatchQueue` specific-key re-entrancy pattern (`getSpecific` → run
inline, else `sync`/`async` hop). Any helper extracted from the provider must preserve
this dual-entry contract or move the state onto its own isolation domain.
Against the chained engine queue the coupling is ONE-WAY: `dnsStateQueue` work may wait
on the engine queue (`retire()`, `wake()` via `engineQueue.run`), and NOTHING on the
engine queue ever waits on `dnsStateQueue` — the DNS serving seam hops to its own serial
queue before any dual-entry read, and the observation door enqueues asynchronously. A
synchronous hop in the other direction is the deadlock shape the teardown funnel's
ordering exists to forbid (`ChainedTunnelSeamAdapters` serving-queue contract; the
provider's sleep-override, teardown-funnel and surrender-sink comments each carry the
engine-side half).
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
- Home: `LavaSecTunnel/PacketTunnelProvider.swift` — `dnsStateQueueSpecificKey`; its ~60 call
  sites span the `LavaSecTunnel/Provider/` files.

## Observability

### INV-OBS-1 — Transient fail-closed windows are not ledgered at entry (legacy: OBS-C2)
The by-design seconds-long bootstrap fail-closed window is NOT recorded in the incident
ledger at entry (it happens on every affected start and would flood the 50-record ring).
Genuine unavailability marks `residentFailClosedDueToUnavailableSnapshot` and ledgers once
per transition.
- Home: `LavaSecTunnel/Provider/PacketTunnelProvider+StartupState.swift` and
  `LavaSecTunnel/Provider/PacketTunnelProvider+Diagnostics.swift` — bootstrap fail-closed branch comments.

### INV-IPC-1 — The tunnel polls; Darwin observers don't fire in the extension
CFNotification observers were measured at 0/14 callbacks inside the NE process; the tunnel
therefore POLLS shared config (Focus config poll) and only ever POSTS Darwin signals.
App→tunnel pushes use `sendProviderMessage` exclusively.
- Home: `LavaSecTunnel/Provider/PacketTunnelProvider+FocusConfigPoll.swift`.
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
Class-C preference loading is independently deferred until protected data and the real
shared configuration are available; a readable Class-None control plane does not authorize
loading or writing fallback customization, progress or saved-game values. First-unlock
and foreground recovery load the snapshot once before dependent effects/writes. Automatic
backup suspends on unreadable Keychain evidence without persisting Off over saved consent;
its unavailable-state retry restores the existing choice without scheduling an upload.
- Home: `Sources/LavaSecKit/SharedStateFileReader.swift` (classifier);
  `SharedFilterStatePersistence.writeConfigurationAndLibrary` (writer fence);
  `AppViewModel.loadPersistedConfiguration` / `loadOrMigrateFilterLibrary` /
  `reloadSharedStateIfBlockedByDataProtection` (load gating + recovery);
  `BackupController.scheduleAutomaticBackupAfterConfigurationChange` (blast radius).
- Home (protected preferences): `ProtectedPreferenceRecovery`,
  `AppViewModel.loadProtectedPreferencesIfAvailable`, `CustomizationController.loadCustomizationPreferences`,
  and `BackupController.loadAutomaticBackupPreference` / `refreshUnavailableBackupStateAfterUnlock`.
- Home (tunnel half): `LavaSecTunnel/Provider/PacketTunnelProvider+FilterDecision.swift` —
  `loadConfigurationClassified` (fail-closed bootstrap + reload abort + nil refresh
  marker on unreadable) and `LavaSecTunnel/Provider/PacketTunnelProvider+ProtectionPause.swift` —
  `beginFreshProtectionVPNSession` (canary-deferred suite writes).
- Enforced: `SharedStateFileReaderTests` (executable classification, including a
  chmod-based unreadable fixture), `SharedFilterStatePersistenceTests`
  (`testWriteRefusesToReplaceExistingUnreadable*` — executable writer fence),
  `RebootFirstUnlockGuardSourceTests` (pins the load gating, funnel refusal, recovery
  wiring, and backup suppression), and `TunnelPreUnlockGuardSourceTests` (pins the
  tunnel's fail-closed bootstrap, refresh retry, reload abort, and canary-gated suite
  writes).
- Enforced (protected preferences): `ProtectedPreferenceRecoveryTests` (executable
  availability/load-once policy), `ProtectedPreferenceRecoverySourceTests` (platform
  lifecycle/effect wiring), `Tests/NativeProtectedPreferenceRecoveryTests.py` (production
  loaders and writers with isolated locked/unlocked storage), and
  `Tests/NativeBackupDeletionCompatibilityTests.py` (consent survives unavailable Keychain,
  recovery respects explicit Off and completed deletion).

### INV-PERSIST-2 — Control-plane files carry NSFileProtectionNone; privacy stores stay Class C

`security-gates.json` carries app-published authentication availability, effective gates and
migration/notice state as one atomic Class-None record. It holds no credential material.
Only app-main-actor writers update it; missing or unreadable state cannot authorize headless
actions. Credential creation requires successful conservative publication first.
The boot-needed CONTROL-PLANE files in the shared App Group — the
`app-configuration.json`/`filter-library.json` pair, the explicit restore-intent sidecar
`protection-restore-intent.json`, `tunnel-health.json`, the versioned artifact area
(`filter-artifacts/`, token trios + the `current.json` pointer), the legacy root artifact trio,
and the tunnel's retained compile
(`catalog-cache/tunnel-compiled-artifact/`) — carry `NSFileProtectionNone`. A DNS filter
that boots with the device (Connect-On-Demand fires between reboot and first unlock, when
Class C content is still locked) needs its selection/rules state readable pre-unlock to
serve REAL filtering instead of the fail-closed block-all placeholder; these files hold
filter selections, custom rules, and tunnel health — no browsing history — so trading
their at-rest class for boot availability is deliberate (2026-07-14 incident, phase 2;
lavasec-infra `plans/2026-07-14-reboot-first-unlock-data-reset-incident-plan.md`). `app-configuration.json` also persists custom resolver URLs, whose path or query can carry
provider credentials. Those values share the deliberate Class-None boot-availability trade;
they are not moved into the app-only passcode keychain by UI authentication.
The
PRIVACY stores — `dns-events.sqlite`, `diagnostics.json`, `network-activity-log.json`,
`incident-ledger.json`, `vpn-debug-log.jsonl`, `chained-upstream.json` (which names the
server a user routes ALL of their traffic through — `INV-CHAIN-4`), and the `catalog-cache`
downloads outside the retained-compile subdirectory — record user activity and nothing at boot needs them,
so they deliberately stay at the iOS default Class C. Three lifecycle-coordination files are
deliberate Class-None exceptions: `protection-lifecycle-state.json`, the required command/state
lock `protection-command.lock`, and the required NetworkExtension mutation fence
`protection-lifecycle-mutation.lock`. Automatic restore and a direct Live Activity Restart can
coordinate before first unlock; their required locks fail CLOSED rather than degrading open, so a
Class-C lock would wedge the very boot-time exclusion they enforce. The versioned v2 migration
re-stamps all three on already-installed devices. Other, best-effort/privacy advisory lock files
remain deliberately EXCLUDED: they are content-free, no pre-unlock toucher is wedged by a failed
open (each is try-only, degrades open, or — `chained-upstream-write.lock`, whose only touchers are
foreground-app writers that run after first unlock by construction — refuses that one write and
reports it; see `INV-CHAIN-4`), and the shared `FilterPublishLock` open site also creates the
privacy vpn-debug rotate lock, so a blanket re-class there would leak Class-None into a privacy
path for zero boot benefit.
The shared notification history (`protection-notification-history.json`) contains only incident
kind, request ID and delivery time. Its atomic writes use Class None; its dedicated try-only
lock may refuse a pre-unlock notification update without affecting DNS filtering. Both app and
tunnel use this one file owner for delivery claims and recovery cleanup.
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
  `Sources/LavaSecKit/ReseedSuppressionMarkerStore.swift` (Class-None existence marker), plus
  `Sources/LavaSecKit/ProtectionRestoreIntentStore.swift` (Class-None explicit-intent sidecar);
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

### INV-PERSIST-3 — Explicit protection restore intent is durable and pair-isolated
An accepted user turn-off, turn-on, or user-initiated reconnect is durably recorded in the
app-owned `protection-restore-intent.json` sidecar, never by mutating the shared
`app-configuration.json`/`filter-library.json` pair. The sidecar is atomically replaced with
the control-plane protection options and has a single writer: the foreground app while it owns
the protection lifecycle mutation fence. An explicit OFF commits `false` before any
session-end, on-demand disarm, profile removal, or tunnel-stop side effect; a persistence error
surfaces to the user and aborts that teardown. Explicit ON and user reconnect similarly commit
`true` before their start/reconnect lifecycle mutations, so an earlier durable OFF cannot
outlive a later accepted choice. Automatic restore and QA/system reconnect paths are read-only.

For backward compatibility, an absent sidecar falls back to the loaded configuration hint. A
valid sidecar value is authoritative. A corrupt, unreadable, or unavailable sidecar is
restore-ineligible — it does not fall back to a possibly stale `protectionEnabled == true` and
therefore cannot surprise-enable protection. This is deliberately not a traffic “fail-closed”
claim: it governs only automatic restore eligibility. By never writing the contested pair, the
sidecar cannot clobber a newer headless Focus generation, change the active filter/library, or
create the pair writer's config-first crash window.

Connected protection arms recovery independently of UI observation. Confirmation requires
saved-preference readback with On-Demand enabled and exactly one unconditional any-interface
Connect rule; an enabled switch alone cannot confirm recovery. A bounded three-attempt repair
reloads the saved manager inside the descendant mutation fence and revalidates the connection,
durable ON intent, and external-Restart ownership across suspensions. OFF, cancellation, or a
newer lifecycle retires the work. A foreground boundary may retry an unconfirmed connected
profile; a missing ownership capture requires a fresh observation epoch rather than rebasing
the old descendant onto a newer Restart generation.
A fresh observation epoch supersedes a pending arm from the old epoch; its late completion
cannot confirm the new connection. A retry within the same epoch never admits a duplicate arm.
The fresh foreground profile read, cache publication, and synchronous reducer admission share
the arm's mutation fence. A disabled snapshot read during a pending save must never replace
the manager whose readback confirms recovery. Waiting/read completion revalidates foreground
activity generation, connection, and intent; sampler shutdown alone does not retire the read.
Admission may create a new epoch and never awaits its arm
while owning the fence.

The sidecar is new after the `INV-PERSIST-2` migration: upgrades legitimately begin with it
absent, and its first atomic write stamps Class-None directly. It therefore needs no pair
migration or backfill; rewriting legacy configuration merely to manufacture an intent record
would reintroduce the contested-pair crash and generation hazards this invariant excludes.
- Home: `Sources/LavaSecKit/ProtectionRestoreIntentStore.swift` (atomic sidecar + read policy);
  `LavaSecApp/AppViewModel/AppViewModel+Persistence.swift` — `recoverUserProtectionIntentFromDurableState`,
  `persistExplicitProtectionIntent`; `LavaSecApp/AppViewModel/AppViewModel+ProtectionLifecycle.swift` — the owned
  enable/disable/reconnect paths.
- Enforced: `ProtectionRestoreIntentStoreTests` (executable absent/valid/corrupt/unreadable
  policy, cold-relaunch restore refusal, atomic replacement, later true superseding false,
  unreadable-write fence, and Focus-pair byte preservation) +
  `ProtectionRestoreIntentSourceTests` (app-target fence/order, recursion forwarding, and
  conservative recovery wiring), `ProtectionOnDemandArmTests` (saved-rule shape, bounded
  retries, cancellation and serialized foreground read/publication), `ChainedConnectLifecyclePolicyTests` (foreground repair epochs),
  and `ProtectionOnDemandSourceTests` (inactive capture, readback and intent/fence wiring).

## Release

### INV-REL-1 — RC tags match the declared version and never regress
`vX.Y.Z-rcN` must equal `Config/Lava.xcconfig` `MARKETING_VERSION`, and that version must be
strictly greater than the latest public release tag (equal = forgot to bump after releasing,
below = regression); clean (non-rc) release tags are always a deliberate manual action.
- Home / enforced: `.github/workflows/tag-release.yml` guard job (RC-tag push) and
  `.github/workflows/light-build.yml` `version-guard` job (every non-draft PR — drafts
  skip it until `ready_for_review`, as with the build/guard jobs PR #784 gated; the
  security scan lane is the deliberate draft-time exception; catches a stale
  `MARKETING_VERSION` before an RC tag is ever cut).

### Ordered-chain extension to INV-CHAIN-4 and INV-CHAIN-5

Page Save commits both profiles' secrets under one Keychain generation and
one atomic metadata envelope. Row removal and native sheet Save only modify a
pending profile draft; they never write saved profiles or reconnect. Switches persist
independently and do not enter profile edit mode. A later profile Save preserves the
current switch choices; an unchanged Save does not reconnect. Cancel releases the draft. Navigation and the shared app-lock owner handle page
privacy; inactive/foreground events never replace the VPN page with an empty screen. Stale per-row editors cannot overwrite a newer
chain. Stored keys never enter an editor or RN snapshot. A full first profile
carries the second profile's transport; a split first profile uses independent
destination-selected tunnels. Selected traffic never switches VPN because of
failure, and a nested second profile never opens a direct socket. Either full-tunnel
profile prohibits physical DNS fallback. See `docs/architecture/wireguard-chain.md`;
`ChainedUpstreamKeychainStoreTests.testTwoHopAtomicSaveRenameRemoveAndStaleEditorFence`,
`ChainedUpstreamKeychainStoreTests.testPageDraftDoesNotWriteUntilCommitAndPreservesRetainedHopIdentity`,
the VPN screen/navigation tests, `ChainedStackRoutingTests`,
`ChainedStackTransportTests`, and `ChainedStackAddressTranslationTests` exercise these boundaries.


### INV-CHAIN-BOOT-1 — A locked startup does not permanently select DNS-only

A normal-profile tunnel that observes protected storage unreadable at startup and
latches `configurationUnreadable`, `deviceStateUnavailable` or `upstreamUnavailable`
keeps DNS filtering while waiting for first unlock. Only that observed boot lifecycle
may schedule recovery. After unlock, fresh configuration, explicit user intent,
on-demand confirmation, path viability, device eligibility and credentials must all
permit chaining. Successful readiness grants at most one restart; the new, already
unlocked start cannot re-arm recovery. Surrender/exclusion state is never reset.

Offline first unlock retains bounded dormant eligibility without a recovery timer and
spends no readiness/window budget. A delivered matching-generation physical/health
path starts a 60-second monotonic online window; at most three windows and three
readiness reads are admitted per provider generation, with five seconds between reads.
Network loss suspends polling without extending the deadline. Returning before expiry
resumes that window; expiry at equality rejects its result. A successor requires a
genuine combined unsatisfied-to-satisfied edge, never a duplicate or interface change.
One physical Keychain read is allowed across all lifecycles of
a reused provider; invalidation cancels logical work without freeing a wedged read's
slot. Generation/window/read identities isolate logical authorization from physical
ownership. After an owned slot drains, one eligible current window can admit fresh
work without another path edge; the old result cannot restart an expired/new window.
Final user-intent and lifecycle checks run while the app/intent mutation fence
is owned nonblockingly. Explicit OFF, superseding lifecycle, lost on-demand or
path viability prevents cancellation. Strict all-network profiles keep their startup
contract and never run a DNS-only substitute. Keys and privacy logs retain Class C.

- Home: `Sources/LavaSecKit/ChainedBootRecoveryPolicy.swift`;
  `LavaSecTunnel/Provider/PacketTunnelProvider+BootRecovery.swift`.
- Enforcement: `ChainedBootRecoveryPolicyTests` (policy, combined-path gate and physical ownership),
  `ChainedBootRecoverySourceTests` (provider wiring);
  physical reboot/first-unlock forwarding criteria in infra's
  `docs/engineering/reboot-first-unlock-qa-protocol.md`.
