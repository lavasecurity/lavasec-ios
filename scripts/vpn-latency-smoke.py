#!/usr/bin/env python3
"""VPN lifecycle latency smoke for a physical device.

Builds, installs, and launches the Debug app with the lifecycle smoke probe
(-lava-vpn-lifecycle-smoke-test --lava-debug-vpn), waits for the probe to
finish, pulls vpn-debug-log.jsonl from the app group, and asserts that the
required latency spans exist and stay inside their budgets.

Budgets are initial gates with Debug-build slack; tighten them once
baseline variance is established.
"""

import argparse
import json
import pathlib
import subprocess
import sys
import tempfile
import time

DEFAULT_DEVICECTL_ID = "YOUR_DEVICE_UUID"
DEFAULT_XCODEBUILD_UDID = "YOUR_DEVICE_UDID"
BUNDLE_ID = "com.lavasec.app"
APP_GROUP = "group.com.lavasec"
PROJECT_DIR = pathlib.Path(__file__).resolve().parent.parent
LOG_FILENAME = "vpn-debug-log.jsonl"

REQUIRED_EVENTS = [
    "app-init",
    "probe-lifecycle-begin",
    "pause-defaults-updated",
    "pause-state-refreshed",
    "probe-lifecycle-after-pause",
    "resume-defaults-cleared",
    "probe-lifecycle-after-resume",
    "probe-finished",
]

# The lifecycle probe drives pause/resume through LavaProtectionCommandService
# directly, so user-action spans (action.pause/.resume) and provider-message
# spans only appear when the corresponding app paths happen to run; they are
# budget-checked when present rather than required.
REQUIRED_SPANS = [
    "tunnel.start",
    "tunnel.setNetworkSettings",
    "tunnel.snapshotLoad",
    "action.turnOn",
]

OPTIONAL_SPANS = [
    "action.pause",
    "action.resume",
    "action.turnOff",
    "provider.message.reply",
    # Resolver-path phases (Track 0 transport seams). Informational, no budget:
    # endpointAttempt fires per wire attempt, deviceFallback/bootstrap only on
    # those paths. Worst-of-window duration is printed to feed Track 5 ranking.
    "resolver.endpointAttempt",
    "resolver.deviceFallback",
    "resolver.bootstrap",
]

# spanName -> budget in milliseconds (initial gates, generous Debug slack).
SPAN_BUDGETS_MS = {
    "action.turnOn": 20_000,
    "action.pause": 1_500,
    "action.resume": 4_000,
    "action.turnOff": 5_000,
    "tunnel.snapshotLoad": 3_000,
    "tunnel.setNetworkSettings": 5_000,
    "tunnel.start": 20_000,
    "provider.message.reply": 3_000,
}
FIRST_DNS_DECISION_BUDGET_MS = 5_000


def run(cmd, check=True, capture=False):
    return subprocess.run(cmd, check=check, text=True, capture_output=capture)


def build(udid):
    print("[smoke] building Debug app for device...")
    run([
        "xcodebuild", "build",
        "-project", str(PROJECT_DIR / "LavaSec.xcodeproj"),
        "-scheme", "LavaSec",
        "-destination", f"platform=iOS,id={udid}",
        "-configuration", "Debug",
        "-allowProvisioningUpdates",
        "-quiet",
    ])


def built_app_path(udid):
    result = run([
        "xcodebuild",
        "-project", str(PROJECT_DIR / "LavaSec.xcodeproj"),
        "-scheme", "LavaSec",
        "-destination", f"platform=iOS,id={udid}",
        "-configuration", "Debug",
        "-showBuildSettings",
    ], capture=True)
    settings = {}
    for line in result.stdout.splitlines():
        line = line.strip()
        if " = " in line:
            key, _, value = line.partition(" = ")
            settings.setdefault(key, value)
    return pathlib.Path(settings["TARGET_BUILD_DIR"]) / settings["WRAPPER_NAME"]


def install(devicectl_id, app_path):
    print(f"[smoke] installing {app_path.name}...")
    run(["xcrun", "devicectl", "device", "install", "app",
         "--device", devicectl_id, str(app_path)], capture=True)


def launch(devicectl_id):
    print("[smoke] launching with lifecycle smoke probe...")
    run(["xcrun", "devicectl", "device", "process", "launch", "--terminate-existing",
         "--device", devicectl_id, BUNDLE_ID, "--",
         "--lava-debug-vpn", "-lava-vpn-lifecycle-smoke-test"], capture=True)


def pull_log(devicectl_id, destination):
    result = run(["xcrun", "devicectl", "device", "copy", "from",
                  "--device", devicectl_id,
                  "--domain-type", "appGroupDataContainer",
                  "--domain-identifier", APP_GROUP,
                  "--source", LOG_FILENAME,
                  "--destination", str(destination)], check=False, capture=True)
    return result.returncode == 0 and destination.exists()


def parse_events(path, baseline_lines):
    events = []
    with open(path, errors="ignore") as handle:
        lines = handle.read().splitlines()
    if len(lines) < baseline_lines:
        baseline_lines = 0  # log rotated; parse everything
    for line in lines[baseline_lines:]:
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events


def wait_for_probe(devicectl_id, baseline_lines, timeout_seconds, workdir):
    deadline = time.monotonic() + timeout_seconds
    log_path = workdir / "smoke-log.jsonl"
    while time.monotonic() < deadline:
        time.sleep(5)
        if not pull_log(devicectl_id, log_path):
            continue
        events = parse_events(log_path, baseline_lines)
        names = {event.get("event") for event in events}
        if "probe-lifecycle-error" in names or "probe-lifecycle-skipped" in names:
            return events, "probe reported failure"
        if "probe-finished" in names and "probe-lifecycle-after-resume" in names:
            return events, None
    return [], f"probe did not finish within {timeout_seconds}s"


def span_durations(events):
    """spanName -> list of (durationMs or None, status detail)."""
    durations = {}
    for event in events:
        if event.get("event") != "latency-span-end":
            continue
        name = event.get("spanName", "unknown")
        raw = event.get("durationMs")
        try:
            duration = int(raw) if raw is not None else None
        except ValueError:
            duration = None
        durations.setdefault(name, []).append((duration, event.get("status", "")))
    return durations


def evaluate(events):
    failures = []
    names = [event.get("event") for event in events]
    present = set(names)

    for required in REQUIRED_EVENTS:
        if required not in present:
            failures.append(f"missing required event: {required}")

    durations = span_durations(events)
    print("\nspan durations (ms):")
    for span in REQUIRED_SPANS + OPTIONAL_SPANS:
        rows = durations.get(span, [])
        if not rows:
            if span in REQUIRED_SPANS:
                failures.append(f"missing required span: {span}")
                print(f"  {span:32}  MISSING")
            else:
                print(f"  {span:32}  (not exercised)")
            continue
        budget = SPAN_BUDGETS_MS.get(span)
        worst = max((duration for duration, _ in rows if duration is not None), default=None)
        label = "n/a" if worst is None else str(worst)
        verdict = ""
        if budget is not None and worst is not None and worst > budget:
            verdict = f"  OVER BUDGET ({budget})"
            failures.append(f"span {span} took {worst}ms, budget {budget}ms")
        print(f"  {span:32} {label:>8}{verdict}")

    first_dns = [event for event in events if event.get("spanName") == "tunnel.firstDNSDecision"]
    if not first_dns:
        # Requires ambient DNS traffic after tunnel start; warn rather than fail
        # when the capture window saw none.
        print(f"  {'tunnel.firstDNSDecision':32}  (no DNS observed in window)")
    else:
        raw = first_dns[-1].get("elapsedMs", "unknown")
        print(f"  {'tunnel.firstDNSDecision':32} {raw:>8}")
        try:
            if int(raw) > FIRST_DNS_DECISION_BUDGET_MS:
                failures.append(
                    f"first DNS decision at {raw}ms, budget {FIRST_DNS_DECISION_BUDGET_MS}ms"
                )
        except ValueError:
            pass

    # Pause must not trigger snapshot work (plan F2).
    pause_reloads = [
        event for event in events
        if event.get("event", "").startswith("loadSnapshot")
        and "pause" in event.get("reason", "")
    ]
    if pause_reloads:
        failures.append(f"pause triggered {len(pause_reloads)} snapshot load(s)")

    paused = [event for event in events if event.get("event") == "probe-lifecycle-after-pause"]
    if paused and paused[-1].get("isProtectionTemporarilyPaused") != "true":
        failures.append("after-pause state did not report paused")
    resumed = [event for event in events if event.get("event") == "probe-lifecycle-after-resume"]
    if resumed and resumed[-1].get("isProtectionTemporarilyPaused") != "false":
        failures.append("after-resume state still reports paused")

    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default=DEFAULT_DEVICECTL_ID, help="devicectl device id")
    parser.add_argument("--udid", default=DEFAULT_XCODEBUILD_UDID, help="xcodebuild destination id")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--skip-install", action="store_true")
    parser.add_argument("--timeout", type=int, default=180, help="probe wait timeout in seconds")
    args = parser.parse_args()

    if not args.skip_build:
        build(args.udid)
    if not args.skip_install:
        install(args.device, built_app_path(args.udid))

    with tempfile.TemporaryDirectory() as raw_workdir:
        workdir = pathlib.Path(raw_workdir)
        baseline_path = workdir / "baseline-log.jsonl"
        baseline_lines = 0
        if pull_log(args.device, baseline_path):
            with open(baseline_path, errors="ignore") as handle:
                baseline_lines = sum(1 for _ in handle)

        launch(args.device)
        events, error = wait_for_probe(args.device, baseline_lines, args.timeout, workdir)
        if error:
            print(f"[smoke] FAILED: {error}", file=sys.stderr)
            return 1

        failures = evaluate(events)

    if failures:
        print("\n[smoke] FAILED:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    print("\n[smoke] PASSED: all required spans present and within budgets.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
