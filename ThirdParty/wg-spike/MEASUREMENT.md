# Phase 0 spike — on-device measurement protocol

The go/no-go for chained VPN upstream rests on one question (feasibility record,
`lavasec-infra/plans/2026-07-22-vpn-upstream-chaining-feasibility-plan.md`): **does a
Rust-WG data path stay under the jetsam cliff co-resident with the filter, including
under load and during a filter reload?** This file is how to answer it. Everything here
is throwaway; none of it is the MVP.

## Build & wire (Mac + device)

1. `rustup target add aarch64-apple-ios aarch64-apple-ios-sim`
2. `./build-xcframework.sh` → `build/LavaSecWGSpike.xcframework`
3. On a **throwaway** `LavaSecTunnel` branch, behind the internal QA-tools build flag:
   link the xcframework, add the bridging header (`include/lavasec_wg_spike.h`), drop in
   `WGSpikeSession.swift`, flip the route to `0.0.0.0/0` (+`::/0`), hardcode one test
   peer, and route non-DNS packets through `WGSpikeSession`. Keep the DNS path
   (`10.255.0.1` + `matchDomains`) exactly as-is.
4. Resolve the endpoint hostname via a physical-interface bootstrap, never the tunnel's
   own `10.255.0.1` (that would deadlock — see the plan's D5 endpoint-resolution note).

## Devices

Measure on at least two: a current Pro **and a low-end / low-jetsam model** (the
feasibility record is explicit — the low-end device is the one that decides it). Load
the filter to a near-cap config; test at **both 1M and 2M** rule totals.

## Scenarios (log `PhysFootprint` MiB at each)

1. **Steady state, tunnel up, idle** → expect well under the 32 MB target.
2. **Sustained throughput** (~50–100+ Mbps download / speed test) → the wireguard-go
   jetsam scenario; watch the buffer spike and the drop counter.
3. **Filter reload while passing traffic** → the worst-case collision; **this is the
   number that decides it.**
4. Whether jetsam fires on the low-end device in any of the above.

## Pass / fail

**Pass** = peak `phys_footprint` stays under the ~40 MB observed cliff (ideally under
the 32 MB target) on the **lowest-end supported device** across all three scenarios,
with no jetsam and acceptable throughput.

**Fail** ⇒ one of: drop the chaining cap below 1M; make app-prepared-only snapshotting
mandatory while chaining; or (worst case) Option A is memory-infeasible on older
hardware and becomes newer-device-only or stays shelved.

## Secondary

Throughput actually achieved (is boringtun fast enough on-device?) and battery/thermal
over a sustained session (cross-ref `lavasec-infra/plans/2026-05-16-battery-impact-reduction-plan.md`).

## Reporting

Record the numbers (device, config, scenario, peak MiB, jetsam y/n, Mbps) back into the
implementation plan's Phase 0 section and this PR before any Phase 1 work starts.
