#!/usr/bin/env bash
# Run a CI command under the maintenance sweep's shared lock on self-hosted
# runners. GitHub-hosted runners execute directly but still create the existing
# ~/.lava-ci directory, preserving the inline workflow blocks' behavior.
#
# Usage:
#   ci/run-with-maintenance-lock.sh -- command [argument ...]
#
# LAVA_CI_FLOCK_BIN may be set to an authoritative executable path. The normal
# workflow leaves it unset and discovers flock from PATH or the two Homebrew
# locations used by the self-hosted macOS runner.
set -euo pipefail

usage() {
  echo "usage: ci/run-with-maintenance-lock.sh -- command [argument ...]" >&2
  exit 64
}

[ "$#" -ge 2 ] || usage
[ "$1" = "--" ] || usage
shift
[ "$#" -gt 0 ] || usage

lock="${HOME:?HOME must be set}/.lava-ci/maintenance.lock"
mkdir -p "${lock%/*}"

if [ "${RUNNER_ENVIRONMENT:-}" != "self-hosted" ]; then
  exec "$@"
fi

flock_bin=""
if [ "${LAVA_CI_FLOCK_BIN+x}" = x ]; then
  flock_bin="$LAVA_CI_FLOCK_BIN"
else
  flock_bin="$(command -v flock || true)"
  if [ -z "$flock_bin" ]; then
    for candidate in /opt/homebrew/bin/flock /usr/local/bin/flock; do
      if [ -x "$candidate" ]; then
        flock_bin="$candidate"
        break
      fi
    done
  fi
fi

if [ -z "$flock_bin" ] || [ ! -x "$flock_bin" ]; then
  echo "::error::flock required on self-hosted runner (brew install flock)" >&2
  exit 1
fi

exec "$flock_bin" -s "$lock" "$@"
