#!/usr/bin/env bash
# Fails when the committed WireGuard-engine xcframework
# (ThirdParty/wireguard-core/build/LavaSecWGCore.xcframework) does not match a
# from-source rebuild with the pinned toolchain. This is the AGPL provenance gate
# for a Rust artifact the Xcode/SPM build cannot itself produce (shell build
# phases are rejected by the xcodegen boundary guards): the public tree carries
# source + pinned toolchain + Cargo.lock + this CI-verified bit-identical rebuild.
# Phase 1, plan D4 (lavasec-infra
# plans/2026-07-22-vpn-upstream-chaining-implementation-plan.md).
#
# scripts/build-wireguard-core.sh is deterministic across machine / $HOME /
# CARGO_HOME / checkout path (see its determinism levers), so a matching rebuild
# is expected; any mismatch means the committed artifact was hand-edited, built
# with a different toolchain/deps, or the source changed without re-running the
# build script.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
crate="${repo_root}/ThirdParty/wireguard-core"
xcframework="${crate}/build/LavaSecWGCore.xcframework"

if [ ! -d "$xcframework" ]; then
  echo "check-wireguard-core-drift: committed artifact missing at $xcframework" >&2
  echo "fix: run scripts/build-wireguard-core.sh and commit ThirdParty/wireguard-core/build/." >&2
  exit 1
fi
for tool in rustup cargo xcodebuild shasum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "check-wireguard-core-drift: $tool not found" >&2; exit 2; }
done

# Digest EVERY file under build/ — not just the slice binaries. This directory is
# byte-verified independently of the textual QA-enablement scan. That scan excludes
# only the three compiled Rust archives (machine code is not Swift build settings),
# while headers, metadata and unexpected files remain text-scanned in both repositories.
# This internal gate additionally checks provenance for EVERY file under build/.
# Anything added, modified, or removed here fails this gate.
# Path-relative so the manifest is location-independent.
#
# 🔴 The manifest ALONE is not sufficient, and this is subtle. The rebuild below removes
# only the xcframework (build-wireguard-core.sh keeps that narrow, because an `rm -rf` of
# the whole directory once deleted a committed sidecar). So a file added under build/ that
# is NOT part of the xcframework SURVIVES the rebuild and appears byte-identical in both
# the committed and rebuilt manifests — it compares equal and passes. The manifest
# alone would therefore wrongly vouch for the unapproved file's
# provenance. The text scan only checks QA enablement; it cannot establish provenance.
#
# assert_build_dir_allowlist closes that: the SET of paths under build/ must be exactly the
# generated artifact plus the approved toolchain sidecar. Reproducibility is checked by the
# manifest; membership is checked here.
assert_build_dir_allowlist() {
  local root="$1" unexpected
  unexpected="$( cd "$root" && find . -type f | sed 's|^\./||' | sort | grep -vE \
      '^(BUILD-TOOLCHAIN\.txt|LavaSecWGCore\.xcframework/.*)$' || true )"
  # Entry TYPE, not just name. Both the allowlist below and digest_manifest enumerate with
  # `find -type f`, so a SYMLINK under build/ is invisible to both: it is not a regular
  # file, so it never appears in either manifest, and it is not caught as an unexpected
  # name either. A committed symlink could then point anywhere — including out of the
  # artifact tree — and have no byte provenance, the same hole as an unapproved file. Nothing here is legitimately a symlink: every entry is
  # either a generated artifact or an approved sidecar.
  local irregular
  irregular="$( cd "$root" && find . ! -type d ! -type f | sed 's|^\./||' | sort || true )"
  if [ -n "$irregular" ]; then
    echo "check-wireguard-core-drift: non-regular file(s) under build/ — symlinks and other" >&2
    echo "  special entries are enumerated by neither the manifest nor the allowlist, so" >&2
    echo "  they would ship without byte provenance. Remove them:" >&2
    printf '%s\n' "$irregular" | sed 's/^/    /' >&2
    exit 1
  fi

  local missing=""
  for required in BUILD-TOOLCHAIN.txt; do
    [ -f "${root}/${required}" ] || missing="${missing}${required}"$'\n'
  done
  if [ -n "$missing" ]; then
    echo "check-wireguard-core-drift: required file(s) missing from build/ — the allowlist" >&2
    echo "  is a SET assertion in both directions; deleting an approved sidecar must fail" >&2
    echo "  as loudly as adding an unapproved file:" >&2
    printf '%s' "$missing" | sed 's/^/    /' >&2
    exit 1
  fi
  if [ -n "$unexpected" ]; then
    echo "check-wireguard-core-drift: unexpected file(s) under build/ — this directory" >&2
    echo "  must contain only generated artifacts and approved metadata. The rebuild" >&2
    echo "  cannot establish provenance for these files. Remove them, or add them to the" >&2
    echo "  allowlist in this script with a reason:" >&2
    echo "$unexpected" | sed 's/^/    /' >&2
    exit 1
  fi
}

digest_manifest() {
  local root="$1"
  ( cd "$root" && find . -type f | sort \
      | while read -r f; do printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"; done )
}

build_dir="${crate}/build"
assert_build_dir_allowlist "$build_dir"
committed_manifest="$(digest_manifest "$build_dir")"
committed_toolchain="$(cat "${crate}/build/BUILD-TOOLCHAIN.txt" 2>/dev/null || echo "(none recorded)")"
current_xcode="$(xcodebuild -version | awk '/^Build version/{print $3}')"

# Preserve the committed artifact; the build script rewrites build/ in place.
backup="$(mktemp -d)"
trap 'rm -rf "$backup"' EXIT
cp -R "$build_dir" "$backup/committed-build"

restore() {
  rm -rf "$build_dir"
  cp -R "$backup/committed-build" "$build_dir"
}

echo "check-wireguard-core-drift: rebuilding from source (pinned toolchain)…"
if ! bash "${repo_root}/scripts/build-wireguard-core.sh" >/dev/null; then
  restore
  echo "check-wireguard-core-drift: build script FAILED" >&2
  exit 1
fi

rebuilt_manifest="$(digest_manifest "$build_dir")"

# Reproducibility sanity: no machine-specific absolute path may survive in a slice
# (a new dependency embedding an un-remapped path would break future rebuilds).
leak=0
while IFS= read -r lib; do
  if strings -a "$lib" | grep -Eq "${HOME}|${CARGO_HOME:-$HOME/.cargo}"; then
    echo "check-wireguard-core-drift: WARNING absolute build path embedded in $(basename "$(dirname "$lib")")/$(basename "$lib")" >&2
    leak=1
  fi
done < <(find "$xcframework" -name '*.a')

# Restore the committed bytes regardless of outcome (non-destructive check).
restore

if [ "$committed_manifest" != "$rebuilt_manifest" ]; then
  echo "check-wireguard-core-drift: DRIFT — committed xcframework != from-source rebuild" >&2
  echo "--- committed ---" >&2; echo "$committed_manifest" >&2
  echo "--- rebuilt ---" >&2; echo "$rebuilt_manifest" >&2
  # The most common non-source cause is an Xcode change: `ring`'s C objects are
  # compiled by the ambient Xcode clang, so the committed artifact is tied to the
  # Xcode that built it. Surface that explicitly.
  echo "--- toolchain ---" >&2
  echo "artifact was built with:" >&2; echo "$committed_toolchain" | sed 's/^/  /' >&2
  echo "  this environment's xcode-build: ${current_xcode}" >&2
  if ! printf '%s' "$committed_toolchain" | grep -q "xcode-build: ${current_xcode}$"; then
    echo "→ Xcode build versions differ. The canonical artifact is built on the CI runner's" >&2
    echo "  pinned Xcode; rebuild there (or on a matching Xcode) and commit, OR re-baseline" >&2
    echo "  deliberately if the runner's Xcode was upgraded." >&2
  else
    echo "→ Same Xcode, so this is a genuine source/deps change: run" >&2
    echo "  scripts/build-wireguard-core.sh and commit ThirdParty/wireguard-core/build/." >&2
  fi
  exit 1
fi

if [ "$leak" -ne 0 ]; then
  echo "check-wireguard-core-drift: reproducibility at risk (see WARNING above)" >&2
  exit 1
fi

echo "check-wireguard-core-drift: committed xcframework matches a from-source rebuild."
