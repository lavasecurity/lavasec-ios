#!/usr/bin/env bash
# Classify a GitHub event as a docs-only pull request.
#
# Usage:
#   ci/detect-docs-only.sh --event EVENT [--base SHA] [--head SHA]
#
# Stdout is intentionally machine-only: exactly `true` or `false`. Diagnostics
# go to stderr so workflows can capture the result for $GITHUB_OUTPUT. Any
# missing or indeterminate PR range fails safe to `false` with a successful exit.
set -euo pipefail

usage() {
  echo "usage: ci/detect-docs-only.sh --event EVENT [--base SHA] [--head SHA]" >&2
  exit 64
}

event=""
event_set=0
base=""
head=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --event)
      [ "$#" -ge 2 ] || usage
      event="$2"
      event_set=1
      shift 2
      ;;
    --base)
      [ "$#" -ge 2 ] || usage
      base="$2"
      shift 2
      ;;
    --head)
      [ "$#" -ge 2 ] || usage
      head="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done
[ "$event_set" = 1 ] || usage

if [ "$event" != "pull_request" ]; then
  echo "not a PR -> run fully" >&2
  echo false
  exit 0
fi

if [ -z "$base" ] || [ -z "$head" ]; then
  echo "missing PR diff endpoint -> run fully" >&2
  echo false
  exit 0
fi

# Rename detection must stay disabled. Otherwise moving a buildable source file
# into docs/ or to a *.md destination can hide the source deletion and skip a
# build for a tree that lost production code.
if ! files="$(git diff --no-renames --name-only "$base..$head" --)"; then
  echo "unable to determine changed files -> run fully" >&2
  echo false
  exit 0
fi

echo "changed files:" >&2
printf '%s\n' "$files" >&2

if [ -z "$files" ]; then
  echo "empty diff -> run fully" >&2
  echo false
  exit 0
fi

# Avoid a `printf | grep -q` pipeline here. Under pipefail, grep can exit after
# the first non-doc path and SIGPIPE printf on a large diff, inverting the
# classification. Reading the captured list in this shell keeps it fail-safe.
docs_only=true
while IFS= read -r file; do
  case "$file" in
    docs/*|*.md) ;;
    *)
      docs_only=false
      break
      ;;
  esac
done <<< "$files"

if [ "$docs_only" = true ]; then
  echo "docs-only -> expensive work may short-circuit" >&2
  echo true
else
  echo "non-docs changes present -> run fully" >&2
  echo false
fi
