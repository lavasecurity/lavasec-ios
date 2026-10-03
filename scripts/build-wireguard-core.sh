#!/usr/bin/env bash
# Build the LavaSec WireGuard engine (ThirdParty/wireguard-core) into a 3-slice
# xcframework and write it to ThirdParty/wireguard-core/build/. Phase 1 of the
# chained-VPN-upstream plan (lavasec-infra
# plans/2026-07-22-vpn-upstream-chaining-implementation-plan.md, D4).
#
# The output is REPRODUCIBLE: run twice on any Mac with the pinned toolchain and
# the bytes are identical. That is a hard requirement, not a nicety —
# scripts/check-wireguard-core-drift.sh re-runs this and byte-compares against the
# committed artifact (the AGPL provenance answer: the public tree carries source +
# pinned toolchain + a CI-verified bit-identical rebuild). This script is the SOLE
# authority for producing the committed artifact; never build it with a bare
# `cargo build` (that would embed machine-specific paths — see below).
#
# Determinism levers:
#   - profile pins (Cargo.toml): lto + codegen-units=1 + strip=debuginfo.
#   - --remap-path-prefix (here): panic-location metadata embeds absolute source
#     paths for the crate, the cargo registry, and the rust sysroot; those vary by
#     machine, so they are remapped to fixed virtual roots. (Cargo 1.94 has not
#     stabilized the `trim-paths` profile option, so this is done via RUSTFLAGS.)
#   - SOURCE_DATE_EPOCH + deterministic `ar` (Rust's default) keep archive member
#     metadata stable.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ThirdParty/wireguard-core" && pwd)"
out="${here}/build"
xcframework="${out}/LavaSecWGCore.xcframework"
lib_basename="liblavasec_wireguard_core.a"

if ! command -v rustup >/dev/null 2>&1; then
  echo "error: rustup not found on PATH." >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found (Xcode required)." >&2
  exit 1
fi

# Run every rustc/cargo/rustup command from the crate dir so the pinned
# rust-toolchain.toml is the active override. This is load-bearing on a machine
# with NO default toolchain set (e.g. the CI runner): from a directory with no
# toolchain file, `rustc`/`rustup target list` would fail with "no default
# toolchain configured" even though the pinned toolchain and targets are present.
cd "$here"

# Device + iOS simulator + macOS (the macOS slice lets executable package tests
# drive the real Noise state machine under `swift test`).
targets=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)
for t in "${targets[@]}"; do
  if ! rustup target list --installed | grep -qx "$t"; then
    echo "error: rust target $t not installed (for the pinned toolchain)." >&2
    echo "       cd ThirdParty/wireguard-core && rustup target add $t" >&2
    exit 1
  fi
done

# Stable virtual roots for embedded source paths. The cargo registry index hash is
# a function of the crates.io URL (identical across machines for a given cargo), so
# remapping CARGO_HOME/registry normalizes every dependency path.
cargo_home="${CARGO_HOME:-$HOME/.cargo}"
sysroot="$(rustc --print sysroot)"
export RUSTFLAGS="${RUSTFLAGS:-} \
  --remap-path-prefix=${here}=/lavasec-wireguard-core \
  --remap-path-prefix=${cargo_home}=/cargo \
  --remap-path-prefix=${sysroot}=/rustc"
# RUSTFLAGS only remaps rustc-compiled code. `ring` (our transitive crypto dep)
# compiles C (curve25519.c, aes_nohw.c, …) via its own build.rs + the cc crate,
# which bakes the absolute registry path into each object. `-ffile-prefix-map`
# (honored by the cc crate through CFLAGS, covering both debug info and __FILE__)
# remaps those to the same virtual root. Without this the .a is NOT reproducible.
export CFLAGS="${CFLAGS:-} -ffile-prefix-map=${cargo_home}=/cargo -ffile-prefix-map=${here}=/lavasec-wireguard-core"
# Fixed timestamp for any archive/member metadata that honors it.
export SOURCE_DATE_EPOCH=0

echo "==> building static libs (reproducible)"
# Remove ONLY the generated artifacts, never the whole build/ directory: it also holds
# the committed BUILD-TOOLCHAIN.txt sidecar, which is regenerated below. An
# `rm -rf "$out"` here silently deleted a committed file once. (.gitattributes used to live
# here too and now sits one level up, where it is scannable and diffable.)
rm -rf "$xcframework"
mkdir -p "$out"
for t in "${targets[@]}"; do
  ( cd "$here" && cargo build --release --target "$t" )
done

device_lib="${here}/target/aarch64-apple-ios/release/${lib_basename}"
sim_lib="${here}/target/aarch64-apple-ios-sim/release/${lib_basename}"
macos_lib="${here}/target/aarch64-apple-darwin/release/${lib_basename}"

echo "==> assembling ${xcframework}"
rm -rf "$xcframework"
xcodebuild -create-xcframework \
  -library "$device_lib" -headers "${here}/include" \
  -library "$sim_lib" -headers "${here}/include" \
  -library "$macos_lib" -headers "${here}/include" \
  -output "$xcframework"

# Canonicalize Info.plist: `xcodebuild -create-xcframework` orders the
# AvailableLibraries array nondeterministically (identical entries, swapped
# run-to-run — the slice .a bytes are stable, only this ordering is not), which
# alone would defeat the byte-compare drift gate. Sort the array by
# LibraryIdentifier and re-emit with sorted keys so the plist is a pure function
# of the inputs. Done via plutil + the json module (not plistlib) so it does not
# depend on a working pyexpat.
plist="${xcframework}/Info.plist"
plist_json="${out}/Info.plist.json"
plutil -convert json -o "$plist_json" "$plist"
python3 - "$plist_json" <<'PYEOF'
import json, sys
p = sys.argv[1]
with open(p) as f:
    data = json.load(f)
libs = data.get("AvailableLibraries")
if isinstance(libs, list):
    data["AvailableLibraries"] = sorted(libs, key=lambda d: d.get("LibraryIdentifier", ""))
with open(p, "w") as f:
    json.dump(data, f, sort_keys=True)
PYEOF
plutil -convert xml1 -o "$plist" "$plist_json"
rm -f "$plist_json"

# Record the toolchain that produced these bytes. The .a is reproducible only
# under a FIXED Xcode as well as the pinned rustc: `ring` compiles its C crypto
# (curve25519.c, aes_nohw.c, …) with the ambient Xcode clang, so a different
# Xcode changes those objects (the Rust code, same rustc, stays identical). This
# file lets the drift gate report an Xcode-driven mismatch in plain language
# instead of an opaque byte diff. It is metadata, not part of the byte-compared
# xcframework.
xcode_build="$(xcodebuild -version | awk '/^Build version/{print $3}')"
{
  echo "rustc: $(rustc --version)"
  echo "xcode-build: ${xcode_build}"
} > "${out}/BUILD-TOOLCHAIN.txt"

echo "==> done"
for lib in "$device_lib" "$sim_lib" "$macos_lib"; do
  printf '    %-52s %s\n' "$(basename "$(dirname "$(dirname "$lib")")")" "$(shasum -a 256 "$lib" | cut -d' ' -f1)"
done
