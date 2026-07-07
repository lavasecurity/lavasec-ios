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
`FailClosedRuntimeSnapshot`. The synchronous cold-start bootstrap deliberately serves NO
last-known-good (under-blocking risk); only the async path may.
- Home: `LavaSecTunnel/PacketTunnelProvider.swift` — `loadInitialSharedState` /
  `serveLastKnownGoodOrFailClosed` comments.
- Enforced: `PacketTunnelDNSRuntimeSourceTests.testLoadInitialSharedStateWarmResumesFromDiskBeforeFailingClosed`
  (asserts fail-closed install + absence of LKG in the sync bootstrap).

### INV-DNS-2 — Transient bootstrap DNS wait is bounded and never bypasses the filter
After a recent self-reconnect launch that strict-misses fast-resume, DNS requests may be
queued at most 64-deep for at most 4 s. Every exit except a committed current-lifecycle
snapshot — timeout, overflow, stale lifecycle, snapshot-unavailable — answers SERVFAIL.
Queued requests are only ever replayed *through the filter* after a real snapshot commits.
- Home: `PacketTunnelProvider.swift` — "Transient bootstrap DNS wait" section (#294).
- Enforced: `PacketTunnelDNSRuntimeSourceTests` transient-bootstrap-wait tests.

### INV-DNS-3 — Last-known-good is config-exact
LKG reuse tolerates ONLY stale catalog/guardrail content hashes. Enabled-list set, manual
block/allow rules, custom-list fingerprints, and parser rules version must match exactly,
so LKG can serve stale rules but can never serve a *different configuration's* rules.
- Home: `PacketTunnelProvider.swift` — `lastKnownGoodCompactSnapshot` comment;
  `CompactFilterSnapshot.canServeAsLastKnownGood`.
- Enforced: `PacketTunnelDNSRuntimeSourceTests.testTunnelKeepsLastKnownGoodOnFailedReloadAndDoesNotFlicker`.

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
- Home: `PacketTunnelProvider.swift` — `reusableCompactSnapshot` / `reusablePreparedSnapshot`.
- Enforced: `PacketTunnelDNSRuntimeSourceTests` bootstrap/store contract tests.

## Concurrency

### INV-QUEUE-1 — dnsStateQueue confinement
Mutable tunnel DNS state is `dnsStateQueue`-confined. Entry points that may already be
on-queue use the `DispatchQueue` specific-key re-entrancy pattern (`getSpecific` → run
inline, else `sync`/`async` hop). Any helper extracted from the provider must preserve
this dual-entry contract or move the state onto its own isolation domain.
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

## Release

### INV-REL-1 — RC tags match the declared version and never regress
`vX.Y.Z-rcN` must equal `Config/Lava.xcconfig` `MARKETING_VERSION` and be ≥ the latest
public release tag; clean (non-rc) release tags are always a deliberate manual action.
- Home / enforced: `.github/workflows/tag-release.yml` guard job.
