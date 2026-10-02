# lavasec-wireguard-core

Production packaging of the WireGuard engine (boringtun's crypto core) for the
chained-VPN-upstream feature. Plan: `lavasec-infra`
`plans/2026-07-22-vpn-upstream-chaining-implementation-plan.md` (D4). Supersedes the
Phase-0 throwaway in `ThirdParty/wg-spike/` (which stays until the QA-4 pre-release
run no longer needs its harness).

## Packaging contract (D4)

- **Vendored engine source**: `boringtun/` is the exact contents of the crates.io
  `boringtun-0.7.1` tarball (sha256
  `15dd6a8a89cbe8997f37ca0cf035e6ea4d64cd2ecea4aed83ffb9f99f7126939`), consumed as a
  path dependency. BSD-3-Clause (declared in `boringtun/Cargo.toml`; the tarball
  ships no license text file — the full BSD-3 text, the app-side
  `ThirdPartyLegalNotice` category, and `lavasec-doc` attribution land with the
  Phase-1 legal-notice deliverable). No local patches — any future patch is a
  reviewable diff against this baseline.
- **Transitive deps** are pinned by `Cargo.lock` sha256 checksums, not vendored: the
  built xcframework is committed, so release builds never run cargo; only the CI
  rebuild-drift gate fetches (hash-verified, pinned toolchain).
- **Toolchain**: `rust-toolchain.toml` pins the exact rustc and the three targets —
  `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `aarch64-apple-darwin` (the macOS
  slice is what lets executable package tests drive the real Noise state machine
  under `swift test`).
- **Determinism**: release profile uses `lto = true` + `codegen-units = 1` +
  `strip = "debuginfo"`; the drift gate byte-compares a from-source rebuild against
  the committed artifact (the AGPL provenance answer — the public tree carries
  source + pins + a CI-verified bit-identical rebuild). The build script normalizes
  the machine-specific leaks (`--remap-path-prefix` for rustc code, `-ffile-prefix-map`
  for `ring`'s C objects, `AvailableLibraries` plist ordering).
- **Xcode is part of the pin.** `ring` compiles its C crypto with the ambient Xcode
  clang, so the artifact is reproducible under a *fixed Xcode* as well as the pinned
  rustc — a different Xcode changes those C objects (the Rust code stays identical).
  The **canonical build environment is the CI runner's Xcode**; the committed artifact
  is built there, and `build/BUILD-TOOLCHAIN.txt` records the exact rustc + Xcode build
  version. A local rebuild on a different Xcode will (correctly) report drift naming the
  version gap — rebuild on the runner (or a matching Xcode) to reproduce. An intentional
  runner Xcode upgrade means re-baselining the artifact.

## Phase 1 progress

- [x] Packaging substrate (vendored boringtun, pins, toolchain) — slice 1.
- [x] C ABI (`src/lib.rs` + `include/lavasec_wireguard_core.h`) + executable
      handshake/transport tests (`tests/engine_abi.rs`) — slice 2. Uniform
      data-path buffer contract makes every engine panic path unreachable;
      buffer sizing tracks the ios-internal #442 co-residency measurement.
- [x] `scripts/build-wireguard-core.sh` → committed 3-slice xcframework
      (`build/LavaSecWGCore.xcframework`, ios-arm64 / ios-arm64-simulator /
      macos-arm64) — slice 3. Byte-reproducible across machine / `$HOME` /
      `CARGO_HOME` / checkout path (verified), so the drift gate can byte-compare.
- [x] CI rebuild-drift gate: `scripts/check-wireguard-core-drift.sh` +
      the `wireguard-core-drift` job in `light-build.yml` (internal-repo-only).
      The `changes` job classifies the engine inputs on Linux, so PRs that do not
      touch them skip at scheduling time instead of occupying a Mac runner slot to
      self-skip; every main push still invokes the job, which completes green after
      self-skipping the rebuild when nothing changed. (This job is not a required
      status check; if it ever becomes one, re-read the note at the job.)
- [x] `LavaSecChainedUpstream` SPM target/product, guard integration, Swift FFI
      wrapper, and executable macOS-slice handshake tests are implemented.
      The Swift tests exercise the engine handshake and transport flow.
- [x] Legal-notice category + anchor attribution — slice 5. `ThirdPartyLegalNoticeCategory`
      gains `bundledLibrary` (code the app *contains*, as opposed to a service it talks
      to), and `ThirdPartyLegalNotices.bundledLibraryNotices` carries BoringTun's upstream
      copyright line, the BSD-3-Clause reference, and the WireGuard trademark disclaimer.
      Pinned against the vendored `Cargo.toml` (license, repository) and `boringtun/src/lib.rs`
      (owner, copyright year), so an engine upgrade that changes any of them fails the test
      instead of shipping a stale attribution. The verbatim license text lives at
      `LICENSE-boringtun.txt` — BSD-3-Clause clause 2 requires the condition list and
      disclaimer to be *reproduced* with a binary redistribution, which a URL does not do.
- [x] **Complete bundled-library attribution.**
      `scripts/generate-wireguard-core-notices.mjs` builds notices for the crates in the
      shipped Apple-target archives and the pinned Rust sysroot corpus. It writes
      `THIRD-PARTY-NOTICES.txt` and `third-party-notices-index.json`; the app resource is
      byte-identical. The generator's `--check` / `--verify-committed` modes reconcile
      the index with the shipped archives, including which crates are excluded.
      `BundledLibraryAttributionSourceTests` checks the committed license text, inventory,
      and target declarations. The public disclosure is in `lavasec-doc` PR #40.
- [x] **In-app disclosure is wired.** The packet-tunnel target links
      `LavaSecChainedUpstream`; Settings → Legal Notices lists bundled libraries, and
      **Full License Texts** opens the generated notice resource. The affiliation disclaimer
      includes bundled software. The source test
      `testLinkingTheEngineRequiresRenderingItsNotices` checks the engine product link
      and the presence of bundled-library disclosure code; it does not test navigation.
- [x] This repo's `docs/legal/third-party-notices.md` — bundled-libraries section and the
      binary-vs-runtime distinction.
- [x] `lavasec-doc` `docs/legal/third-party-notices.md` public disclosure (PR #40).

## The committed artifact

`build/LavaSecWGCore.xcframework` is a checked-in binary (~19 MB per static-lib
slice: LTO bitcode + `ring`'s asm objects; the members are LLVM bitcode, so
`nm`/`objdump` can't read them — they resolve at Xcode link time, verified by a
C link+run test). `build/BUILD-TOOLCHAIN.txt` records the rustc + Xcode build
version it was built with. Rebuild it ONLY via `scripts/build-wireguard-core.sh`
(never a bare `cargo build`) **on the CI runner's Xcode** (the canonical
environment); the drift gate enforces that the committed bytes equal a
from-source rebuild there.
