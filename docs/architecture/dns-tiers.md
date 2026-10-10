# The DNS tier scaffold

**Canonical.** This document defines what T0, T1 and T2 mean. Every resolver decision in the
app — which resolver is asked, in what order, on which interface, and what a surface calls it —
derives from these three tiers. New DNS behaviour is expressed as a rule about a tier, not as a
new policy type beside them.

## The three tiers

The scaffold numbers the **user's intent**, not the order of attempts in a given session.

| Tier | What it is | Where it comes from | Exists when |
| --- | --- | --- | --- |
| **T0** | The chained upstream's own resolver | the WireGuard profile's `DNS =` | only while chaining is latched |
| **T1** | The resolver the user selected | `resolverPresetID` + the `customResolver*` fields | always |
| **T2** | The fallback the user selected — what answers the names T1 could not | `fallbackToDeviceDNS`, or `usesEncryptedDeviceDNSFallback` + `fallbackResolverPresetID`; which one follows T1 | whenever the user has enabled it |

Two consequences follow, and they are the whole point of numbering intent rather than attempts:

- **A tier keeps its number in every mode.** The resolver in Settings is T1 whether or not
  chaining is on. Turning chaining on does not renumber it; it inserts T0 *above* it.
- **A tier is a setting, so only the user moves it.** Lava may decline to reach a tier — no
  upstream, a refused egress, an unreachable resolver — and it may fall past one. It never
  rewrites which resolver a tier names, and no surface may report a tier as though the user had
  changed it (`ChainedSurfaceState`, PR #636).

For a two-profile stack, T0 uses the full profile's usable DNS entries (row 2
when both are full), or the first profile when both are split. Its packets follow the stack's fixed
destination selection; a full profile anywhere disables physical T1/T2 fallback.
This is not domain/suffix-specific DNS routing. See `wireguard-chain.md`.

## The ladder

Resolution walks downward and stops at the first rung that serves.

```
chained, latched            DNS-only
────────────────────        ────────────────────
T0  upstream DNS =          (absent)
 ↓  through the tunnel
T1  user's resolver         T1  user's resolver
 ↓  physical, split only     ↓  physical
[one rung, by T1's transport — see below]
 ↓
(fail closed, INV-DNS-1)    (fail closed, INV-DNS-1)
```

The ladder never fails open (`INV-DNS-1`). Running out of rungs is a refusal, not a bypass.

Cache admission shares `DNSResolverSmokeProbe.indicatesServedAnswer` with live service evidence:
only structurally valid NOERROR/NODATA or NXDOMAIN replies may enter, using the full EDNS RCODE.
Errors remain uncacheable even with answer records or an authority SOA, so replay cannot bypass
fresh recovery attempts. TTL and negative-SOA bounds apply after this shared gate.
`DNSResponseCacheTests.testCacheAdmissionUsesTheWholeResponseCodeForEverySectionShape` and
`testCacheRefusesRepliesTheSharedServiceValidatorCannotAccept` enforce the boundary.

### T2 is one optional, explicitly selected rung

DNS settings presents T1 and optional T2 as an ordered list. Each choice is a
provider/transport pair; either tier may be Device DNS, a built-in alternative,
or a validated custom resolver (Plus). Two alternatives may be stacked. An exact
duplicate is rejected. Removing T1 promotes T2; the final remaining row cannot
be removed. In edit mode, the panel footer offers Add with one row and Swap order
with two, using the same action scaffold as the VPN profile list. Swaps remain
pending until Save and Cancel discards them. Editing and picker/custom drafts
never publish partial ladders. In normal mode each numbered row has a native switch.
Inactive rows keep their provider and position; at least one row must stay active,
enforced at the configuration boundary as well as by disabling the last active switch.
The effective ladder skips inactive rows without changing their saved order. Toggle
commits reuse the resolver reload/route reapply path; editing and Swap wait for Save.
Backup schema 3 retains inactive selections; older clients refuse that schema.

`usesExplicitDNSTiers` marks configurations saved by this editor. Before that
marker exists, the legacy transport-dependent toggle semantics remain unchanged:
Device DNS uses `usesEncryptedDeviceDNSFallback`; other primaries use
`fallbackToDeviceDNS`. Dormant preferences never become active during migration.
With explicit tiers, those existing fields encode the single secondary choice:
Device DNS or an alternative in `fallbackResolverPresetID` and its custom fields.
`ResolverTierTwo` still resolves exactly one rung and its nested plan has no fallback.

System DNS profile selection is separate from this local resolution ladder. Its
DoT/DoH provider controls system lookups while Guard is stopped; Guard captures its
exact endpoints while running. Profile installation and system selection are read
back independently. Saving a changed provider automatically reconnects an active Guard through its existing
intent-fenced lifecycle, so endpoint routes follow the new profile. A stopped Guard stays off.

### What differs between the two columns

Only **T0's presence** and **T1's egress**. While chained, T1 is a separate rung on the
PHYSICAL interface and is permitted only under a split tunnel
(`ChainedResolverEgress.permitsTierOneFallbackOnPhysicalInterface`, `INV-CHAIN-5`); under a full
tunnel there is no T1 rung at all, because the leak it would cause is the thing chaining was
turned on to prevent. In DNS-only mode T1 is simply the plan's own route and runs physically by
the ordinary ladder.

Whatever rung sits beneath T1 is the same in both columns, and while chained it runs on the
RUNG'S own interface rather than the orchestrator's (`INV-CHAIN-7`).

## Naming rules

- Identifiers say `tierZero`, `tierOne`, `tierTwo` and mean exactly the rows above. A tier token
  in a name is a claim about the user's setting, so it must be true in both modes.
- Code that means "whichever tier this session's runtime plan was built from" says **`planned`**,
  never a tier number. `planned` is T0 while chained and T1 while DNS-only — deliberately
  relative, because the plan builder has already resolved it and a number there would be false in
  one of the two modes.
- Diagnostics and log events use the same tokens (`chained-tier-one-relatched`), so a capture can
  be read against this table.

### The numbering this replaces

Before PR #637 the code numbered **attempts within a chained session** and started at one, so the
same setting carried different numbers in different modes:

| old name | meant | now |
| --- | --- | --- |
| "tier-1" | the plan's primary route | `planned` (T0 chained, T1 DNS-only) |
| "tier-2", `tierTwo*` | the chained physical rung — the user's own resolver | **T1**, `tierOne*` |
| "tier-3" | the encrypted fallback | **T2** |

`AppConfiguration.chainedTierTwoFallbackEnabled` was renamed to `chainedTierOneFallbackEnabled`;
its encoded key is pinned to the old spelling, because the numbering was wrong and the persisted
configuration is not.

The old scheme is why `AppConfiguration` had to carry the sentence *"the ONE selection the user
makes — serves both modes, tier-1 in DNS-only and tier-2 while chained"*, and why
`ChainedResolverEgress` had to carry *"there the chosen resolver IS tier-1"* as an aside. Both
were describing one setting with two numbers. Under this scaffold neither sentence is needed.

## Request lifetime across tiers

T0, T1 and T2 consume one lookup budget. Forwarding and broker work have eight active
slots, at most 128 queued jobs / 512 KiB, and a 12-second continuous-clock deadline.
Coalesced clients share the first lookup's remaining lifetime; the waiter owner caps
256 clients, 16 per key, and 1 MiB including query/key bytes and metadata allowance.
These small independent limits bound outage bursts below the extension's ~50 MiB
process ceiling; they do not reserve memory or replace the separate filter/engine budgets.
A macOS allocation sample of the package owners under 10,000 distinct 4 KiB queries
retained 1,750,224 bytes with 126 waiters and 118 pending jobs. The waiter value was
96 bytes, within the 128-byte metadata allowance. This measures the queue/registry
sample, not the complete NetworkExtension process or its physical-device peak.

Overload and expiry return SERVFAIL to current clients. Runtime reset purges queued
jobs; stopped lifecycles cannot write old responses. Active work retains its slot until
its transport callback finishes. Completion identities prevent a late response from
settling a fresh lookup of the same name. Every new attempt rechecks the original
runtime and deadline while preserving the tier's existing egress rules. Encrypted work
that expires before sending is neutral for endpoint health and keeps its connection
pool. Completed attempts still contribute evidence after client expiry, once only,
without counting a late answer as delivered service or fallback rescue. See `INV-DNS-6`.

## Enforcement

- `DNSTierScaffoldTests` — the tier tokens keep their canonical meanings and the retired
  numbering does not return to DNS code.
- `INV-CHAIN-5` — chained DNS egresses through the tunnel, with T1-under-split as the one named
  exception.
- `INV-CHAIN-7` — the T1 rung runs the full ladder beneath it, on its own interface.
- `INV-DNS-1` — the bottom of the ladder is a refusal.

### Tier-owned health and recovery

Execution and recovery use the same canonical tier identity. `DNSResolutionResult.tierEvidence`
seals each raw T0, T1 and T2 leg before fallback attempts or replies merge. A promoted Device
DNS fallback is still T2. Each leg carries its resolver source, actual egress, lifecycle/latch
identity, send/launch path epoch, and its own service/reply/failure/refusal outcome. A physical
rung whose destinations follow profile `AllowedIPs` reports tunnel or mixed egress, rather
than claiming that every socket admitted by the split exception is physically carried.

`ResolverTierHealth` keeps independent bounded counters and repair state for all three tiers.
T2 rescuing a query cannot clear T1's failure; T0 serving a different query cannot clear T2's.
Valid NOERROR/NODATA/NXDOMAIN is service evidence for its own tier. A source-matched reply
without service ends that tier's no-response condition but retains separate rejection evidence.
Policy refusal, suppression, abandoned work and expiry before sending do not establish a
resolver failure. A completed reply after the client deadline is liveness, not delivered service.

Recovery follows the tier's resolver capability:

| Resolver source | Typed repair owner | Cold restart grant |
| --- | --- | --- |
| T0 upstream | Existing chained session/outage supervisor | Its existing bounded session/surrender ladder |
| Fixed T1 or T2 endpoint | Existing endpoint backoff/recovery launch | Never from fixed endpoint failure alone |
| Physical Device DNS at T1 or T2 | In-place capture, then guarded cold recapture | A fresh independent failure confirms the first failure |

A Device timeout is evidence about one lookup, not proof that the resolver stopped answering.
The 2026-10-02 EVA Air capture showed concurrent Device lookups replying while another timed
out and caused a restart. The first real no-response failure therefore records suspicion and
requests confirmation of that same configured tier. Confirmation must reach the wire after
the first failure was observed. Concurrent failures and UDP/TCP retries within one lookup
cannot confirm each other. DNS-queue sequences order send admission and observed completion;
no elapsed-time window or wall-clock threshold decides whether confirmation is independent.

A same-tier reply retires the suspicion, including a resolver-declared error or a reply after
the client deadline. A failure sent before a newer Device reply cannot re-establish silence
when it eventually completes. Source-matched UDP and TCP replies are observed before a retry
or another endpoint can delay the leg, including truncated or mismatched DNS replies that
prove reachability without service. Raw replies retain their original observation order
through slower leg or lower-tier completion; historical counters still record the lookup's
actual outcome.

The Device grant is independent of aggregate connectivity. The provider requires current
lifecycle/latch/path evidence, permitted physical egress, available filtering, a satisfied live
path, and attempted addresses that still belong to the captured network resolvers and are
outside profile coverage. Full/strict tunnels, mixed/tunnel egress, masked capture alone,
missing/forbidden addresses and resolver-declared errors cannot grant cold recapture.

One owned confirmation uses the existing Device executor and captured resolver addresses.
It is scoped to the failed tier and rechecks its physical allowance, destination coverage,
runtime, lifecycle, latch and path before sending or observing a reply. Context replacement
retires admission; outstanding work retains its slot until completion or discard. Generic
physical health probes remain suspended while chained. Full/strict tunnels cannot run this
confirmation. Local send failures, backoff and synthetic probe timeouts are neutral; a canary
reply establishes liveness without crediting service delivered to a client. Confirmation
returns after its first source-matched reply, without a TCP retry to complete a client answer.
Organic lookups retain their normal UDP/TCP behavior. Legacy Device recovery triggers use
this same confirmation rule.

One coordinator commits every process restart. It revalidates the scoped Device grant on a
fresh DNS queue turn, shares the persisted 90-second cooldown and 600-second attempt window
with wedge recovery, and caps unproductive recaptures at three per window. A single timer
requests fresh confirmation at the next budget opportunity; a stored timeout cannot cancel
the tunnel merely because its cooldown expired. A same-tier reply retires the no-response
opportunity; path, configuration, latch and lifecycle changes retire the entire observation
context. A fallback-mode promotion within the same configured ladder does not erase failure
evidence.

Productive recapture credit requires an accepted, deliverable Device DNS response. T0 or a
fixed alternative cannot erase its attempt. Credit reduces the window count but preserves a
separate durable cooldown marker. The shared snapshot and connectivity diagnostics expose
per-tier counters, actual routes, evidence times and typed repair status without queried names,
resolver endpoints or network identifiers.

`ResolverTierEvidenceTests`, `ResolverOrchestratorTests`, `TunnelSelfReconnectPolicyTests`,
`DNSResolverTierHealthSnapshotTests`, `DNSResolverTierHealthPresentationTests` and
`ResolverTierRecoverySourceTests` enforce the execution, admission, persistence and pane seams.

### Encrypted endpoint recovery

DoH, DoT, and DoQ use the existing resolver backoff owner. Healthy alternatives retain
priority. When every permitted endpoint is suppressed, the owner grants at most one recovery
launch per second across concurrent queries, choosing the first endpoint in the caller's
order. A failed launch does not walk the rest of the suppressed list. The normal endpoint
penalties and lifecycle/latch/egress gates still apply; a recovery grant never authorizes a
physical fallback in full-tunnel mode. This applies to both the selected resolver and an
encrypted fallback. `ResolverBackoffPolicyTests`, `ResolverOrchestratorTests`, and
`ResolverBackoffRecoverySourceTests` cover the policy, ladder, and provider isolation.

### Answer aliases and filtering

The shared response path checks reachable answer-section CNAME and queried HTTPS/SVCB
names before forwarding or caching. `DNSResponseAliases` reuses the bounded wire-name
reader, caps retained alias descriptors at 128 and traversal at 16 lookup nodes after the
question, and refuses malformed targets, cycles and over-limit graphs before caching. A permitted
question receives SERVFAIL when its aliases cannot be inspected safely.
Unrelated owners and authority/additional records do not become filter targets.

Each client response, including a cache hit, uses the current filter snapshot and pause
state. Each name retains its existing explicit-allow and threat-guardrail precedence;
allowing a question does not implicitly allow a different destination named by a resolver.
A current pause permits would-block aliases with a short TTL; resumed protection blocks
them. Bootstrap responses keep their existing precedence. The same path serves DNS-only
and chained modes without changing tier selection or egress permissions.

Forwarded queries record their final filtering decision at settlement. The startup latency
metric stays at dispatch, including the distinct paused-forward label; it does not measure
upstream response time. Wake replays carry
the existing recorded-decision marker; a discarded upstream attempt cannot double-count
the eventual answer. Resolver-failure evidence excludes clients served replacement blocks.
This inspects DNS names, not IP traffic, HTTPS content or in-app encrypted DNS.

### Unavailable filtering notice

Warm-artifact reuse, compatible last-known-good fallback and temporary loading stay silent.
The tunnel confirms current service after the full fallback search. Shared artifact triage
also requires a fresh app repair outcome for the current configuration: selected rules
still exceed the budget after refresh, or a custom source requires a permitted foreground
refresh. A 30-second debounce and recent blocked client query establish sustained impact;
they do not establish that recovery is exhausted. Unknown causes, ordinary source/network
failures and active repair stay silent. This applies to DNS-only and chained sessions.

The notice names the required selection review or custom-source refresh. App-side refresh can
download and publish rules; the tunnel's cache-only compiler cannot fetch missing lists and
is deliberately suppressed while the chained engine is resident. An over-budget selection or
unavailable custom source may need further review; opening Lava does not guarantee repair. A usable
warm artifact never needs a precautionary notification or a forced foreground refresh.

Recovery, temporary pause and session end clear the notice without waiting for a resolver
probe. The
provider rechecks its lifecycle, failure, preferences and foreground state after permission
lookup. The app rechecks shared history across notification suspension points so a pending
resolver notice cannot overwrite the higher-priority filter incident. The notice contains no
domains and only opens the Guard page; it cannot change protection or complete onboarding.
Only successful system submission records delivery. One in-flight submission and the
existing 60-second grace bound retries; current history and posture are rechecked on completion.
Executable policy tests cover grace, freshness and deduplication. Source checks and simulator
compilation cover wiring; physical notification delivery remains a device-QA item.

### Coverage and essential services

DNS filtering applies to queries Lava receives. In-app encrypted DNS and direct IP
connections can bypass name filtering, including with chaining. DNS activity can originate
in the background and does not establish page visits. Settings and activity screens state
these limits explicitly.

Downloaded catalog and custom lists retain all valid domain rules, including Apple,
sign-in and Lava service domains. There are no built-in service-domain exemptions.
Explicit allowed exceptions override ordinary list and manual blocks; reviewed threat
guardrails retain their separate precedence. Parser rules version 5 invalidates parsed
caches and prepared snapshots that omitted service-domain rules. Existing raw payloads
can be parsed again without requiring an upstream content change.

### Ordered two-hop WireGuard chains

For two active profiles, T0 follows the full provider (the second for two full
profiles) or the first of two split profiles. Its transport follows the ordered routing
model. Physical T1/T2 fallback requires every active profile to be split
tunnel, as well as the user's fallback consent. A full-tunnel entry therefore
blocks physical fallback even with a split exit. See [WireGuard chains](wireguard-chain.md)
for capture scope, secret storage, and the transport contract.
