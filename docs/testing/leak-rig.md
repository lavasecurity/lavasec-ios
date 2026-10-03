# Network-leak test rig (S9 #8 / #10)

Proves that no traffic escapes the tunnel it should ride — no cleartext DNS to an unintended
resolver, no global IPv6 while full-tunnel drops v6, no non-peer IPv4 egressing direct. Built in
slices; this doc covers the semantics and the load-bearing rules. `scripts/analyze-leak-capture.mjs`
is the detector; the device/lab capture is layered on top.

## The one rule that makes it sound

The **external pcap is the sole leak oracle.** A leak is, by definition, a packet that *escaped* the
tunnel — so it never enters `NEPacketTunnelProvider.packetFlow`, and the tunnel's own counters
(`droppedIPv6Count`, `forwardedNonDNSByteCount`, `tunnelDNSAnswered`) can only ever count what *did*
enter. Those counters and `Library/vpn-debug-log.jsonl` corroborate and label a run; they never prove
absence. On-device capture (`rvictl`, `xctrace`) is also structurally useless here for the same
reason, independent of whether Apple's tooling works this cycle — capture must be **off-device**.

## Capture topology: Mac Internet Sharing

The off-device capture point is the build Mac. macOS Internet Sharing turns it into the phone's
router with no extra hardware: the Mac shares its upstream internet over its own Wi-Fi SSID, the
phone joins that SSID, and **every** packet the phone emits crosses the Mac's Internet-Sharing
`bridgeN` interface, where `tcpdump` records it. This is the concrete rig for Slice 5/6.

Three properties make the capture *complete* — miss any one and the rig is **blind** (a false
"no leak"), which is exactly what the positive control (#8) exists to catch before any real run:

1. **The Mac's uplink is a DIFFERENT interface from the Wi-Fi it shares on.** Share *from* Ethernet
   (USB-Ethernet / Thunderbolt dongle) or iPhone-USB, *to* Wi-Fi. One radio cannot both uplink and
   host the AP — a Wi-Fi-only Mac needs a USB-Ethernet dongle (or a second tether) for its uplink.
2. **The phone has exactly ONE uplink.** Airplane Mode ON → Wi-Fi back ON → join the Mac's SSID;
   **cellular OFF**. A live cellular path carries egress the Mac never sees. One Mac-visible uplink,
   one `utun`, is the precondition every negative verdict depends on.
3. **Capture on the phone's bridge, not `en0` — and don't assume the number.** Internet Sharing
   creates a `bridgeN` interface: `bridge100` on a clean Mac, but a **higher** number (`bridge101`, …)
   when another bridge already exists — a VM/`vmnet` bridge commonly squats `bridge100` at
   `192.168.2.1`. Find the interface the phone is actually on: `arp -a -n | grep <phone-ip>` names the
   bridge, or `ifconfig | grep -B3 192.168` shows each bridge's subnet. Capturing `en0`, or the wrong
   bridge, misses the phone entirely (a blind rig). *(Real #8/#10: the phone's bridge was `bridge101`
   at `192.168.3.x`; `bridge100`/`192.168.2.1` was a pre-existing VM bridge.)*

Setup (macOS 15+):

1. System Settings → General → Sharing → **Internet Sharing** — configure, do not enable yet.
2. *Share your connection from:* the Mac's uplink (e.g. "USB 10/100/1000 LAN", or "iPhone USB").
3. *To computers using:* **Wi-Fi** → Wi-Fi Options: set a Network Name + WPA2 password; note both.
4. Toggle **Internet Sharing ON** (menu bar shows the sharing glyph).
5. Phone: **Airplane Mode ON → Wi-Fi ON → join the Mac's SSID**; cellular stays off. Confirm the
   phone gets a `192.168.x.x` address from the Mac (note it — it identifies the bridge in step 3).
   *(Airplane Mode does NOT stop Wi-Fi Calling — it re-registers over Wi-Fi, so the carrier's IPsec
   keepalives will appear on the wire; see "On-LAN & OS-below-NE traffic" below.)*
6. Mac: identify the phone's bridge (step 3), then `sudo tcpdump -i <bridgeN> -n -Z $(whoami) -w
   run.pcap` (the founder runs the sudo capture; `-Z <user>` drops privileges so the pcap is readable
   without sudo afterwards). Sanity-check first: `sudo tcpdump -i <bridgeN> -n` and watch for the
   phone's address.
7. Reproduce the scenario: connect Lava chained; fire the canary (Slice 5 / #8) or browse the matrix
   (Slice 6 / #10). Then Ctrl-C.
8. Analyze: `node scripts/analyze-leak-capture.mjs --pcap run.pcap --mode full-tunnel --peer-ip <PEER>
   --peer-port <PORT> --endpoint-host <HOST> --lan-cidr <phone-/24> --lan-cidr <bridge-ULA-/64>
   [--ipsec-endpoint <ePDG-ip>] --expect no-leak` — declare the capture segment's on-link prefixes so
   same-segment noise isn't flagged, and add `--ipsec-endpoint` only if Wi-Fi Calling is on (see
   "On-LAN & OS-below-NE traffic"). For the positive-control run use `--expect canary --canary-nonce
   <NONCE>` (no on-link flags needed) — same analyzer, invoked identically.

Blind-rig pitfalls (each violates the sole-oracle rule → a false clean run):

- **Cellular left on** → egress the Mac can't see. Airplane-then-Wi-Fi is not optional.
- **Capturing `en0` instead of `bridge100`** → the Mac's own traffic, not the phone's.
- **A v4-only upstream** → the IPv6 leak axis physically cannot fire, so a v6-broken guard reads
  clean. The IPv6 positive control catches this: if the planted v6 canary is not `canarySeen`, the
  segment has no v6 to leak and the run is **invalid for the v6 assertion** (valid for v4/DNS only).
- **Falling back to a commodity travel router** with client/AP isolation → the router drops
  phone-to-capture visibility. Internet Sharing doesn't isolate (the Mac IS the router), but if you
  substitute a router, confirm it sees the phone's packets before trusting any negative verdict.

## Positive control first (#8)

A "no leak detected" verdict from a **blind** rig (wrong capture interface, client-isolated AP, a
cellular uplink the Mac can't see, an all-IPv4 segment with no v6 to leak) is worthless. So before
any real run, plant a **known** leak and require the analyzer to report `canarySeen: true` — on the
**identical topology** the real run will use. The planted leak is not a mock: it defeats the actual
guard (an unbound socket forcing `.systemChosen` while chained; a QA route plan that omits the `::/0`
claim). If the rig catches that, it can catch the real thing. The positive-control detector and the
real-run detector are the **byte-identical** analyzer, invoked identically.

## What counts as a leak, by mode

The mode is the on-the-wire discriminator — the same packet is a leak in one mode and intended in
another, so the analyzer must be told the mode (and, for split, the `AllowedIPs` set).

| Mode | Sanctioned on the physical interface | A leak |
| --- | --- | --- |
| **full-tunnel** | WG-outer UDP to the single peer `IP:port`; the **one** endpoint-hostname bootstrap DNS lookup (`ChainedResolverEgress.EndpointBootstrapEgress`, discloses the endpoint name by design) and its reply; **purely on-link traffic** (BOTH endpoints inside one declared `--lan-cidr`, incl. directed broadcast) and LAN-scoped link-local/service noise | any cleartext DNS that isn't the bootstrap — **including Do53/DoT to a LAN resolver**; any global IPv6; any non-peer **global** IPv4 — a "noise" service port (mDNS/SSDP) aimed at a **global** address, IKE/IPsec NAT-T (reported `ipsec-natt-os-below-ne` unless the peer is a declared `--ipsec-endpoint`), and any global no-port packet (ICMP/ICMPv6/ESP) |
| **split-tunnel** | WG-outer to peer; **all** non-`AllowedIPs` IPv4 direct egress, **including cleartext DNS to any IPv4 resolver** (the accepted dns-only-grade scope reduction, `docs/invariants.md` §3.3); link-local noise. IPv6 is NOT sanctioned on the physical interface since 2026-09-19 — the plan claims `::/0` and drops v6, so any global IPv6 on the wire is a leak | **only** `AllowedIPs`-destined traffic egressing direct instead of via WG; any global IPv6 |
| **dns-only** | DNS to the configured resolver(s); everything non-DNS goes direct | DNS (Do53/DoT, by port) reaching a resolver that isn't configured; DoH (443) to a **known-resolver IP** that isn't configured (`--doh-resolver-ip` extends the allowlist) |

## On-LAN & OS-below-NE traffic (what the real #10 run surfaced)

A full-tunnel capture on a real phone is never *only* WG-outer. Two classes of non-peer traffic are
**expected and not leaks**, and the analyzer classifies them so a genuine no-leak verdict isn't
drowned in on-segment noise:

- **Purely on-link traffic** — a packet whose **both** endpoints sit inside **one operator-declared
  on-link prefix** (`--lan-cidr`, repeatable: the phone's `/24` and the sharing bridge's IPv6-ULA
  `/64`). The full-tunnel default route captures the *Internet*, not the more-specific on-link subnet
  route, so same-segment traffic rides the physical interface by design. The exemption is scoped to the
  **actual segment, not all RFC1918/ULA** — a packet to a *different* private subnet (e.g.
  `192.168.3.2 → 10.0.0.5`) routes via the default route → the tunnel, so egressing it direct is a real
  bypass; likewise an inbound datagram from the *global* peer host is internet ingress. Empty
  `--lan-cidr` ⇒ **no exemption** (fail-closed). **DNS is the other exception** — a cleartext Do53/DoT
  query to a LAN resolver (a router or Pi-hole at `192.168.x:53`) is exactly the escape this rig hunts,
  so DNS-port / QNAME packets are never on-link-exempt even inside a declared prefix.
- **IKE/IPsec NAT-T (UDP 500/4500) to a global address** — an OS-managed encrypted tunnel that lives
  *below* the NetworkExtension layer (most commonly **carrier Wi-Fi Calling** to an ePDG), which a
  `NEPacketTunnelProvider` can neither capture nor prevent. It is **fail-closed by default** (a real
  IPsec exfil looks identical, and a port match alone is forgeable — any app can hit a controlled
  `:4500`) and reported as `ipsec-natt-os-below-ne`. For a fully-green automated no-leak gate, either
  **disable Wi-Fi Calling** for the capture (Settings → Cellular → Wi-Fi Calling) or declare the exact
  ePDG with **`--ipsec-endpoint <ip>`** — only IKE/NAT-T to *that* host is then acknowledged.

**#10 result (2026-08-16, device `test-phone`, full-tunnel chained, peer `198.51.100.10:51820`) — PASS.**
16943/17035 packets rode WG-outer; **zero cleartext DNS on the wire** (independently grep-verified);
zero global-scope direct egress. The 92 non-peer packets were all on-link (82 phone↔Mac IPv6-ULA over
the sharing bridge + Dropbox/Spotify subnet broadcasts) or Wi-Fi-Calling IPsec keepalives to T-Mobile.
Invoked with `--lan-cidr 192.168.3.0/24 --lan-cidr fd7f:2561:4e47:746b::/64 --ipsec-endpoint
198.51.100.20 --expect no-leak` → exit 0, and the #8 positive control passed on the identical topology,
so the negative verdict is valid.

> **Addresses in this document are documentation-range placeholders** (RFC 5737 TEST-NET-2,
> `198.51.100.0/24`) and the device is a generic label. A real peer endpoint here would publish a
> reachable address for a live account — this file is tracked and the repository is exported
> publicly (`scripts/export-public-source.sh` ships the current tree). Keep the shape, never the
> real values. This is enforced by a scan that runs on every internal CI build and again against
> the archive the exporter produces, so a reintroduced value fails before it can be published.
> Keep packet captures and packaged/compressed files local. To commit evidence, unpack it and
> sanitize the individual files first; the publication gate rejects recognized archives.

## Running the analyzer

```bash
# CI / offline: a pre-parsed packet array (see the file header for the packet shape)
node scripts/analyze-leak-capture.mjs --json capture.json --mode full-tunnel \
  --peer-ip 198.51.100.10 --peer-port 51820 --endpoint-host wg.example.net --expect no-leak

# Lab: a pcap captured off-device (needs tcpdump)
node scripts/analyze-leak-capture.mjs --pcap run.pcap --mode full-tunnel \
  --peer-ip <PEER_IP> --peer-port <PEER_PORT> --canary-nonce <NONCE> --expect canary
```

`--expect canary` fails unless the planted canary is seen (the #8 gate). `--expect no-leak` fails on
any candidate leak (the #10 assertion) **and** on a capture with no liveness marker — no WG-outer to
the peer (full/split) or no DNS on the wire (dns-only) — so an empty, stopped, or blind capture can
never pass. Every negative verdict is valid **only** if the positive control passed on the same
topology and the phone had exactly one Mac-visible uplink (airplane + Wi-Fi-only, single utun).

**Bounding the negative-run window (procedure, Slice 5/6).** The liveness marker is the analyzer's
floor — it proves the capture saw *some* protected traffic, not that it spanned the whole tested
workload (a capture stopped right after a WG keepalive still has a marker). A stronger guarantee is a
deliberate **run-specific end-beacon** emitted after the workload; the analyzer certifies only if it
appears. This cannot live purely in the offline analyzer: in full-tunnel no cleartext marker is
observable in the capture without itself being a leak, so the window is bounded **procedurally**
(start capture → run the fixed workload → stop immediately after), while for dns-only an end-beacon
DNS to the *configured* resolver can be asserted directly. The end-beacon is designed with the lab
capture procedure and reuses the Slice-2 canary emitter — tracked as a Slice 5/6 follow-up.

## Slice status

- [x] Slice 1 — offline analyzer + unit test (`scripts/analyze-leak-capture.mjs`, PR #562).
- [x] Slice 2 — DNS leak canary + QA launch flags, Debug / internal-QA-tools only, never Release (PR #563).
- [ ] Slice 3 — Release-gate source pin (the leak primitive is unreachable from Release).
- [ ] Slice 4 — IPv6 canary + drop-`::/0` route override (the v6 positive control).
- [x] Slice 5 (lab) — capture topology + fire the canary → `canarySeen` (the #8 gate; device-confirmed 2026-08-16).
- [~] Slice 6 (lab) — full-tunnel #10 run **PASS** (see above); split-tunnel / dns-only / IPv6 matrix rows still to run.
