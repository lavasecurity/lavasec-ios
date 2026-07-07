#!/usr/bin/env bash
set -euo pipefail

# iOS-scoped GPL blocklist distribution guardrails.
#
# Lava references third-party (often GPL-licensed) blocklists by source URL only;
# it must never bundle or redistribute their list bytes, nor enable GPL sources
# by default. This is the iOS slice of the org-wide compliance check (the server
# slice lives in the infra repo). See docs/legal/ for the source-url-only policy.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

echo "Checking GPL blocklist distribution guardrails (iOS)..."

search() {
  local pattern="$1"; shift
  if command -v rg >/dev/null 2>&1; then
    rg -n "$pattern" "$@"
  else
    grep -RInE "$pattern" "$@"
  fi
}

# The vendored canonical catalog index (Catalog/blocklist-catalog.json) is the
# "adopted" copy of the public spec. It legitimately names GPL providers in their
# attribution/source URLs but carries NO list bytes (it is structured metadata:
# ids, names, licenses, source URLs). Exclude only that one validated file from the
# list-DATA scan below — any other .txt/.json with list fingerprints still trips it.
CATALOG_METADATA_FILE="Catalog/blocklist-catalog.json"

search_globbed_files() {
  local pattern="$1"; local root="$2"; shift 2
  if command -v rg >/dev/null 2>&1; then
    rg -n "$pattern" "$root" "$@" --glob "!$CATALOG_METADATA_FILE"
  else
    find "$root" \( -name "*.txt" -o -name "*.json" \) ! -path "*/$CATALOG_METADATA_FILE" -print0 | xargs -0 grep -InE "$pattern"
  fi
}

if search "raw_mirror_app_processing|normalized_mirror|modified_mirror" Sources; then
  echo "Third-party blocklists must use source_url_only; Lava must not mirror list bytes." >&2
  exit 1
fi

if search "/v1/blocklists|download_path|manifest_path|artifact_kind|download_hash" Sources; then
  echo "App code must not expose Lava-controlled blocklist artifact URLs." >&2
  exit 1
fi

if search "enabledBlocklistIDs:[[:space:]]*\[[[:space:]]*DefaultCatalog\.(hagezi|oisd|adGuard)" Sources LavaSecApp; then
  echo "Production iOS defaults must not enable GPL blocklist sources." >&2
  exit 1
fi

if search_globbed_files "hagezi|oisd|AdGuardSDNSFilter|big\\.oisd|small\\.oisd" . --glob "*.txt" --glob "*.json"; then
  echo "Production iOS app paths must not bundle GPL list data." >&2
  exit 1
fi

if ! search "source_url_only" docs/legal >/dev/null; then
  echo "source_url_only policy must be recorded in docs/legal." >&2
  exit 1
fi

echo "GPL blocklist distribution guardrails (iOS) passed."
