#!/usr/bin/env bash
# THROWAWAY SPIKE — Phase 0 de-risking for chained VPN upstream.
# Builds the boringtun FFI static libs for iOS device + simulator and assembles an
# xcframework the throwaway tunnel branch links. Runs on a Mac with the Rust toolchain
# and Xcode installed; it does NOT run in CI (the spike's device measurement is manual).
#
# This is NOT the Phase 1 MVP packaging (vendored source + committed xcframework +
# reproducible CI rebuild-drift gate). It is the minimum to get measurable bits onto a
# device. See ./README.md and ./MEASUREMENT.md.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${here}/build"
xcframework="${out}/LavaSecWGSpike.xcframework"
lib_basename="liblavasec_wg_spike.a"

# Pinned in rust-toolchain.toml; fail loudly if the targets are missing rather than
# silently building the host arch.
targets=(aarch64-apple-ios aarch64-apple-ios-sim)
for t in "${targets[@]}"; do
  if ! rustup target list --installed | grep -qx "$t"; then
    echo "error: rust target $t not installed. Run: rustup target add $t" >&2
    exit 1
  fi
done

echo "==> building static libs"
rm -rf "$out"
mkdir -p "$out"
for t in "${targets[@]}"; do
  ( cd "$here" && cargo build --release --target "$t" )
done

device_lib="${here}/target/aarch64-apple-ios/release/${lib_basename}"
sim_lib="${here}/target/aarch64-apple-ios-sim/release/${lib_basename}"

echo "==> assembling ${xcframework}"
rm -rf "$xcframework"
xcodebuild -create-xcframework \
  -library "$device_lib" -headers "${here}/include" \
  -library "$sim_lib" -headers "${here}/include" \
  -output "$xcframework"

echo "==> done: ${xcframework}"
echo "    device lib size: $(du -h "$device_lib" | cut -f1)"
echo "    Link it into a throwaway LavaSecTunnel branch and drive it from"
echo "    WGSpikeSession.swift. Follow MEASUREMENT.md for the go/no-go protocol."
