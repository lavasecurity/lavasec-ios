#!/usr/bin/env bash
# Sourced by build-full-app.sh. Cleanup telemetry must not replace test status.
cleanup_simulator() {
  local device_id="$1" log_file="$2" output status
  output=$(xcrun simctl shutdown "$device_id" 2>&1) && status=0 || status=$?
  printf '[sim-cleanup] shutdown %s status=%s\n%s\n' "$device_id" "$status" "$output" >>"$log_file" || true
  output=$(xcrun simctl delete "$device_id" 2>&1) && status=0 || status=$?
  printf '[sim-cleanup] delete %s status=%s\n%s\n' "$device_id" "$status" "$output" >>"$log_file" || true
  if [ "$status" -ne 0 ]; then
    printf '::warning::Simulator cleanup failed for %s (status=%s); retained for nightly GC.\n' "$device_id" "$status" >&2 || true
  else
    printf '[sim-cleanup] deleted %s\n' "$device_id" || true
  fi
  return 0
}
