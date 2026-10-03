# wg-spike — throwaway Phase 0 de-risking spike

**This is disposable code, not the MVP.** It exists only to answer the chained-VPN
go/no-go: does a Rust-WireGuard data path stay under the NE jetsam cliff co-resident
with the filter, under load and during a reload? See
`lavasec-infra/plans/2026-07-22-vpn-upstream-chaining-implementation-plan.md` (Phase 0)
and the feasibility record alongside it.

It is **not** the Phase 1 engine packaging. Phase 1 is the real work: vendored boringtun
source + pinned toolchain + committed xcframework + a reproducible CI rebuild-drift gate
+ a `LavaSecChainedUpstream` SPM target wired through the build guardrails. None of that
is here — this pulls `boringtun` straight from crates.io and builds a bare static lib.

## Layout

| File | What it is |
|---|---|
| `Cargo.toml` / `rust-toolchain.toml` | Pinned `boringtun = "=0.7.1"`, iOS targets. |
| `src/lib.rs` | Minimal C ABI over boringtun's `Tunn` (handshake + transform). |
| `tests/handshake_roundtrip.rs` | Drives the C ABI through a full handshake + a byte-exact transport round-trip. |
| `include/lavasec_wg_spike.h` | C header for the bridging header. |
| `build-xcframework.sh` | Builds device+sim static libs → `LavaSecWGSpike.xcframework` (Mac only). |
| `WGSpikeSession.swift` | **Reference** packetFlow↔Tunn↔UDP wiring + `phys_footprint` sampler. Not a compiled target source. |
| `MEASUREMENT.md` | The on-device go/no-go protocol. |

## CI scope

This directory is outside every Xcode target and every CI scope root
(`scripts/check-comment-contracts.mjs` scans only `LavaSecApp/`, `LavaSecTunnel/`,
`LavaSecWidget/`, `LavaSecIntents/`, `Shared/`, `Sources/`). The Rust crate is not part
of the Swift package, so `swift test` never touches it; `WGSpikeSession.swift` is a
reference file, not a member of any target. Nothing here changes `project.yml` or any
pinned source — that is deliberate, so the spike can land without the guard fan-out that
Phase 1 will do properly.

## Verified from CI (Linux, no Xcode)

- `cargo build --release` → `liblavasec_wg_spike.a` links against real boringtun 0.7.1.
- `cargo test --release` → 2/2 green (handshake + transport round-trip through the C ABI; NULL-key rejection).
- `cargo clippy --release --all-targets` → clean.

## NOT verified here (needs a Mac + a device)

- The xcframework assembly (`build-xcframework.sh` needs `xcodebuild`).
- Compiling `WGSpikeSession.swift` into a tunnel target.
- **The actual `phys_footprint` measurement — the whole point of the spike.** That is the
  device-validation step this PR sets up; the numbers get reported back before Phase 1.
