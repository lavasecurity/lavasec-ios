#!/usr/bin/env python3
"""VPN latency phase-ranking report for a physical device (or a saved log).

Companion to vpn-latency-smoke.py. Where the smoke is a PASS/FAIL gate that
drives a scripted lifecycle, this is the DIAGNOSTIC: it pulls (or reads)
vpn-debug-log.jsonl, isolates the session(s) you care about, and ranks where
VPN action latency actually goes -- so the Track 5 "rank the slowest phases"
work runs against real device numbers instead of guesses.

It reports:
  * Phase ranking: every latency span by name -> count / p50 / p95 / max.
  * action.turnOn decomposition with each sub-span as a % of the parent, and
    the UNATTRIBUTED remainder inside turnOn.prepareSnapshot (the gap that is
    almost always the cold blocklist network fetch).
  * Cold vs warm turn-on, from enable-reuse-rejected reasons.
  * Resolver/DNS breakdown: resolver.endpointAttempt by transport, device
    fallback / bootstrap activity, and per-transport handshake observations.
  * Anomaly flags (e.g. pause that triggered a snapshot load -- plan F2).

Latency events are Debug/QA only, so build/install a Debug or QA build first
(see vpn-latency-smoke.py for the device build recipe).

Examples:
  # Pull the current log off the device and report the latest app session:
  python3 scripts/vpn-latency-report.py

  # Report every session in a log you already pulled:
  python3 scripts/vpn-latency-report.py --file /tmp/vpn-debug-log.jsonl --session all
"""

import argparse
import json
import math
import pathlib
import subprocess
import sys
import tempfile
from collections import defaultdict

DEFAULT_DEVICECTL_ID = "YOUR_DEVICE_UUID"
APP_GROUP = "group.com.lavasec"
LOG_FILENAME = "vpn-debug-log.jsonl"

# Spans whose sub-spans roll up under a parent, for the decomposition view.
TURN_ON_SUBSPANS = ["turnOn.prepareSnapshot", "turnOn.persistArtifacts",
                    "turnOn.managerSetup", "turnOn.statusWait"]
PREPARE_SUBSPANS = ["prepare.catalogSync", "prepare.mergeRules", "prepare.buildSnapshot"]


def pull_log(devicectl_id, destination):
    result = subprocess.run(
        ["xcrun", "devicectl", "device", "copy", "from", "--device", devicectl_id,
         "--domain-type", "appGroupDataContainer", "--domain-identifier", APP_GROUP,
         "--source", LOG_FILENAME, "--destination", str(destination)],
        check=False, text=True, capture_output=True)
    return result.returncode == 0 and destination.exists()


def read_events(path):
    events = []
    with open(path, errors="ignore") as handle:
        for line in handle.read().splitlines():
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def split_sessions(events):
    """Split into app sessions. A session begins at app-init (the app process
    launch); tunnel events that precede the first app-init join session 0."""
    sessions, current = [], []
    for event in events:
        if event.get("event") == "app-init" and current:
            sessions.append(current)
            current = []
        current.append(event)
    if current:
        sessions.append(current)
    return sessions


def pct(values, p):
    if not values:
        return None
    ordered = sorted(values)
    rank = max(0, math.ceil(p * len(ordered)) - 1)
    return ordered[min(rank, len(ordered) - 1)]


def span_durations(events):
    durations = defaultdict(list)
    for event in events:
        if event.get("event") != "latency-span-end":
            continue
        raw = event.get("durationMs")
        try:
            durations[event.get("spanName", "?")].append(int(raw))
        except (TypeError, ValueError):
            continue
    return durations


def span_begin_details(events, span_name, key):
    """Collect a begin-event detail (e.g. transport) for spans of one name."""
    values = []
    for event in events:
        if event.get("event") == "latency-span-begin" and event.get("spanName") == span_name:
            values.append(event.get(key, "?"))
    return values


def fmt(value):
    return "n/a" if value is None else str(value)


def report_ranking(durations):
    print("\nphase ranking (latency spans, ms) -- sorted by p95")
    print(f"  {'span':30} {'n':>4} {'p50':>7} {'p95':>7} {'max':>7}")
    ranked = sorted(durations.items(), key=lambda kv: (pct(kv[1], 0.95) or 0), reverse=True)
    for name, values in ranked:
        print(f"  {name:30} {len(values):>4} "
              f"{fmt(pct(values, 0.5)):>7} {fmt(pct(values, 0.95)):>7} {fmt(max(values)):>7}")


def report_turn_on_decomposition(durations):
    turn_on = durations.get("action.turnOn")
    if not turn_on:
        return
    parent = pct(turn_on, 0.95) or max(turn_on)
    print(f"\naction.turnOn decomposition (p95 = {parent} ms)")
    for name in TURN_ON_SUBSPANS:
        values = durations.get(name)
        if not values:
            continue
        worst = pct(values, 0.95) or max(values)
        share = f"{100 * worst / parent:.0f}%" if parent else "-"
        print(f"  {name:30} {worst:>7} ms  ({share} of turnOn)")
    prepare = durations.get("turnOn.prepareSnapshot")
    if prepare:
        prepare_worst = pct(prepare, 0.95) or max(prepare)
        attributed = 0
        for name in PREPARE_SUBSPANS:
            values = durations.get(name)
            if values:
                worst = pct(values, 0.95) or max(values)
                print(f"    {name:28} {worst:>7} ms")
                attributed += worst
        gap = prepare_worst - attributed
        if gap > 250:
            print(f"    {'>> UNATTRIBUTED in prepareSnapshot':28} {gap:>7} ms  "
                  f"(likely cold blocklist network fetch -- add finer sub-spans here)")


def report_cold_warm(events, durations):
    rejected = [e for e in events if e.get("event") == "enable-reuse-rejected"]
    reused = [e for e in events if e.get("event") == "enable-reuse-prepared-snapshot"]
    print("\nturn-on cache path")
    print(f"  reuse accepted (warm): {len(reused)}    reuse rejected (cold): {len(rejected)}")
    reasons = defaultdict(int)
    for event in rejected:
        reasons[event.get("reason", "?")] += 1
    for reason, count in sorted(reasons.items(), key=lambda kv: -kv[1]):
        print(f"    cold reason: {reason} x{count}")


def report_resolver(events, durations):
    print("\nresolver / DNS")
    attempts = durations.get("resolver.endpointAttempt", [])
    transports = span_begin_details(events, "resolver.endpointAttempt", "transport")
    by_transport = defaultdict(list)
    # Align begins and ends by order within the session (best-effort breakdown).
    ends = [e for e in events if e.get("event") == "latency-span-end"
            and e.get("spanName") == "resolver.endpointAttempt"]
    begins = [e for e in events if e.get("event") == "latency-span-begin"
              and e.get("spanName") == "resolver.endpointAttempt"]
    span_transport = {e.get("spanID"): e.get("transport", "?") for e in begins}
    for end in ends:
        try:
            dur = int(end.get("durationMs"))
        except (TypeError, ValueError):
            continue
        by_transport[span_transport.get(end.get("spanID"), "?")].append(dur)
    if attempts:
        print(f"  resolver.endpointAttempt: n={len(attempts)} "
              f"p50={fmt(pct(attempts, 0.5))} p95={fmt(pct(attempts, 0.95))} max={max(attempts)}")
        for transport, values in sorted(by_transport.items()):
            print(f"    transport={transport:8} n={len(values):<4} "
                  f"p50={fmt(pct(values, 0.5))} p95={fmt(pct(values, 0.95))}")
    else:
        print("  resolver.endpointAttempt: (none in window)")
    dev = durations.get("resolver.deviceFallback")
    boot = durations.get("resolver.bootstrap")
    print(f"  deviceFallback: {('n=%d p95=%s' % (len(dev), fmt(pct(dev, 0.95)))) if dev else '(none)'}")
    print(f"  bootstrap:      {('n=%d p95=%s' % (len(boot), fmt(pct(boot, 0.95)))) if boot else '(none)'}")
    handshakes = defaultdict(list)
    for event in events:
        name = event.get("event", "")
        if name.endswith("-connection-ready") and event.get("handshakeMs") is not None:
            try:
                handshakes[name].append(int(event["handshakeMs"]))
            except (TypeError, ValueError):
                continue
    if handshakes:
        print("  handshake observations:")
        for name, values in sorted(handshakes.items()):
            print(f"    {name:28} n={len(values):<4} p50={fmt(pct(values, 0.5))} "
                  f"p95={fmt(pct(values, 0.95))} max={max(values)}")
    else:
        print("  handshake observations: (none -- plain resolver or all reused)")
    first_dns = [e for e in events if e.get("spanName") == "tunnel.firstDNSDecision"]
    if first_dns:
        print(f"  tunnel.firstDNSDecision: {first_dns[-1].get('elapsedMs', '?')} ms")


def report_anomalies(events):
    flags = []
    pause_loads = [e for e in events if e.get("event", "").startswith("loadSnapshot")
                   and "pause" in e.get("reason", "")]
    if pause_loads:
        flags.append(f"pause triggered {len(pause_loads)} snapshot load(s) (plan F2 violation)")
    if flags:
        print("\nanomalies")
        for flag in flags:
            print(f"  !! {flag}")


def report_session(events, label):
    print(f"\n{'=' * 64}\n{label}  ({len(events)} events)\n{'=' * 64}")
    durations = span_durations(events)
    if not durations:
        print("  (no latency spans -- is this a Debug/QA build?)")
        return
    report_ranking(durations)
    report_turn_on_decomposition(durations)
    report_cold_warm(events, durations)
    report_resolver(events, durations)
    report_anomalies(events)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--device", default=DEFAULT_DEVICECTL_ID, help="devicectl device id")
    parser.add_argument("--file", help="read a saved log instead of pulling from the device")
    parser.add_argument("--session", choices=["last", "all"], default="last",
                        help="report only the latest app session (default) or every session")
    args = parser.parse_args()

    if args.file:
        log_path = pathlib.Path(args.file)
        if not log_path.exists():
            print(f"[report] no such file: {log_path}", file=sys.stderr)
            return 1
        events = read_events(log_path)
        run(events, args.session)
        return 0

    with tempfile.TemporaryDirectory() as workdir:
        log_path = pathlib.Path(workdir) / LOG_FILENAME
        if not pull_log(args.device, log_path):
            print("[report] failed to pull log from device "
                  "(app installed? Debug/QA build? device unlocked?)", file=sys.stderr)
            return 1
        events = read_events(log_path)
        run(events, args.session)
    return 0


def run(events, session_mode):
    sessions = split_sessions(events)
    print(f"[report] {len(events)} events across {len(sessions)} app session(s)")
    if session_mode == "all":
        for index, session in enumerate(sessions):
            report_session(session, f"session {index + 1}/{len(sessions)}")
    else:
        report_session(sessions[-1] if sessions else events, "latest session")


if __name__ == "__main__":
    sys.exit(main())
