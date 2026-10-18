#!/usr/bin/env bash
# Check reproducibility using two clean builds on the active toolchain. Compiler
# upgrades can change ring's C objects; comparing to a historical host's bytes
# would reject a valid host switch. Consumers always build from pinned source.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/lavasec-wireguard-check.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for pass in first second; do
  bash "$repo_root/scripts/build-wireguard-core.sh" --output "$scratch/$pass"
done
if ! diff -rq "$scratch/first" "$scratch/second"; then
  echo "error: WireGuard clean builds differ under the same active toolchain" >&2
  exit 1
fi

# The following notices check must inspect the artifact we just verified.
out="$repo_root/ThirdParty/wireguard-core/build"
rm -rf "$out"
mv "$scratch/first" "$out"
echo "WireGuard clean builds match; verified source-built artifact installed at $out"
