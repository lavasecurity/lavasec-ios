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
- **Transitive deps** are pinned by `Cargo.lock` checksums. Builds use `--locked`;
  dependency changes require a reviewed lockfile update.
- **Toolchain**: `rust-toolchain.toml` pins Rust and the three Apple targets.
  `scripts/build-wireguard-core.sh` provisions that toolchain on a fresh host and
  uses its active Xcode/SDK selection, including `DEVELOPER_DIR` when set.
  Detected compiler and SDK versions are recorded in `build/BUILD-TOOLCHAIN.txt`.
- **Source-to-artifact verification**: app, release and Swift CI preparation build
  the artifact they consume from source. A clean Cargo target directory prevents
  C objects from a previous Xcode being reused. Build failures stop preparation;
  the checked-in snapshot is never a fallback in these pipelines. App preparation
  also checks legal notices against the freshly built archive inventory.
- **Reproducibility**: `scripts/check-wireguard-core-drift.sh` compares two clean
  builds under the same active toolchain, including every generated file. It
  rejects unexpected files, symlinks and embedded build paths, then leaves the
  verified artifact for the notices check. Source, dependency or compiler changes
  may legitimately change bytes compared with the historical snapshot. Switching
  hosts or Xcode requires neither that old compiler nor an artifact re-baseline.
  The build normalizes Rust/C source paths and XCFramework plist ordering.

## Phase 1 progress

- [x] Packaging substrate (vendored boringtun, pins, toolchain) — slice 1.
- [x] C ABI (`src/lib.rs` + `include/lavasec_wireguard_core.h`) + executable
      handshake/transport tests (`tests/engine_abi.rs`) — slice 2. Uniform
      data-path buffer contract makes every engine panic path unreachable;
      buffer sizing tracks the ios-internal #442 co-residency measurement.
- [x] `scripts/build-wireguard-core.sh` → source-built 3-slice xcframework
      (`build/LavaSecWGCore.xcframework`, ios-arm64 / ios-arm64-simulator /
      macos-arm64) — slice 3. Clean builds are compared under the active toolchain.
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

## Building and the checked-in snapshot

```sh
bash scripts/build-wireguard-core.sh
# Optional reproducibility check (two independent builds):
bash scripts/check-wireguard-core-drift.sh
```

`build/LavaSecWGCore.xcframework` remains checked in for source-distribution and
attribution inspection without an Apple compiler. It is a historical convenience
snapshot, not a verified source-to-binary baseline or an approved fallback for app
builds. Node-only archive/notices checks establish structural and attribution
consistency, not payload provenance. Review changes to the snapshot as binary
changes; the fresh-build reproducibility gate does not certify its bytes. Its
recorded toolchain describes that snapshot; it does not constrain a new build. Before
building the app or running Swift package tests, regenerate it using the command above. The shared app
preparation entry point and Swift CI do this automatically, so QA and production
archives also consume fresh source builds. Rerun preparation after selecting a
new Xcode. A successful build replaces the local snapshot and sidecar; ordinary
host changes do not require committing those regenerated binaries.

The three static libraries contain Rust LTO bitcode and `ring` C/assembly objects.
Use this script rather than bare `cargo build` so the same path normalization,
locked dependency resolution, artifact layout and provenance checks apply.
