# iOS scripts

## VPN latency QA suite

Two device tools for the VPN action-latency work (see
`plans/backlog/2026-06-12-modular-speed-up-plan.md`, Track 0 / Track 5).
Both read the Debug/QA latency spans written to `vpn-debug-log.jsonl` in the
app group, so build and install a **Debug or QA** build first — Release emits
no latency events.

Device defaults target the QA iPhone `QA device` (devicectl
`YOUR_DEVICE_UUID`, xcodebuild
`YOUR_DEVICE_UDID`); override with `--device` / `--udid`.

### `vpn-latency-smoke.py` — PASS/FAIL gate

Builds, installs, and launches the app with the scripted lifecycle probe
(`-lava-vpn-lifecycle-smoke-test --lava-debug-vpn`), waits for it to finish,
pulls the log, and asserts the required spans exist and stay inside their
budgets. Use it as a regression gate. The probe drives a default-config
turn-on/pause/resume; it does **not** exercise a real blocklist or an
encrypted resolver, so the cold blocklist-compile path and the
`resolver.*`/handshake spans usually show `(not exercised)` here.

```sh
PATH="/tmp/lava-sec-ldshim:$PATH" python3 scripts/vpn-latency-smoke.py
```

### `vpn-latency-report.py` — diagnostic phase ranking

Pulls (or reads, with `--file`) the log and ranks where action latency
actually goes: phase ranking (count/p50/p95/max per span), `action.turnOn`
decomposition with the **unattributed remainder inside `prepareSnapshot`**
(the cold blocklist network fetch), cold-vs-warm turn-on from
`enable-reuse-*` events, the resolver/DNS breakdown by transport with
handshake observations, and anomaly flags (e.g. a pause that triggered a
snapshot load — plan F2). No rebuild needed; it analyzes whatever is on the
device.

```sh
# latest app session off the device:
python3 scripts/vpn-latency-report.py

# every session in a log you already pulled:
python3 scripts/vpn-latency-report.py --file /tmp/vpn-debug-log.jsonl --session all
```

### Capturing a cold turn-on with a real config

To attribute the cold-path latency (the slowest phase per the device
ranking), capture a genuine cold run:

1. Delete the app on device (this also clears the app-group log).
2. Build + install a Debug build (the smoke script's build/install steps, or
   `xcodebuild ... -configuration Debug` then `devicectl device install app`).
3. In the app, pick a DoH/DoT resolver and enable a blocklist, then turn on
   Guard and browse briefly so DNS/handshake spans fire.
4. `python3 scripts/vpn-latency-report.py` — the latest session is the cold
   turn-on, with `enable-reuse-rejected` reasons and the `prepareSnapshot`
   breakdown.
