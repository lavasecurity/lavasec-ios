#!/usr/bin/env node
// Offline analyzer for the S9 network-leak rig (#8 positive control, #10 leak matrix).
//
// It is the SINGLE detector both runs invoke: the positive control asserts it reports
// `canarySeen: true` for a deliberately-planted leak, and the real run asserts it reports zero
// candidate leaks. "Sees the canary" and "sees nothing" being the SAME code is the whole point —
// a detector that cannot see a planted leak cannot certify absence of a real one.
//
// A leak = any packet on the PHYSICAL interface that the tunnel mode should have tunnelled,
// dropped, or filtered. The external pcap is the SOLE oracle: the tunnel's own counters only count
// what ENTERED the tunnel, and a leak by definition never did. Classification is keyed on the MODE
// (the same packet is a leak in full-tunnel and intended in split / dns-only), so the caller must
// pass the mode and, for split, the AllowedIPs set.
//
// Two front-ends feed the same classifier:
//   - `--json <file>`  a pre-parsed packet array (CI + when no capture tool is present)
//   - `--pcap <file>`  read via `tcpdump -nn -tt -r` and parse (lab path)
// The classifier is exported (`analyzeCapture`) so tests drive it directly with fixtures.
//
// A normalized packet: { v: 4|6, proto: "udp"|"tcp"|"other", src, dst, sport?, dport?, dns? }
//   sport/dport = source/destination port, ABSENT for portless packets (ICMP/ICMPv6/ESP). A
//     classifier that keys "leak" on a port must therefore treat an absent port as "not that port",
//     never as "safe" — a global ICMPv6 escaping full-tunnel has no port and is still a leak.
//   dns = the queried QNAME (lowercased) when the packet is a cleartext DNS query, else undefined.
//     Its ABSENCE never proves "not DNS": a DoT connection (port 853) and every DNS *reply* carry
//     no cleartext QNAME. Port, not QNAME presence, decides whether a packet is DNS.

import fs from "node:fs";
import { spawnSync } from "node:child_process";

// ---- address helpers -------------------------------------------------------

function ipv4ToInt(ip) {
  const parts = ip.split(".");
  if (parts.length !== 4) return null;
  let n = 0;
  for (const p of parts) {
    const o = Number(p);
    if (!Number.isInteger(o) || o < 0 || o > 255) return null;
    n = (n << 8) | o;
  }
  return n >>> 0;
}

function ipv4InCidr(ip, cidr) {
  const [net, bitsRaw] = cidr.split("/");
  const bits = bitsRaw === undefined ? 32 : Number(bitsRaw);
  const a = ipv4ToInt(ip);
  const b = ipv4ToInt(net);
  if (a === null || b === null || bits < 0 || bits > 32) return false;
  if (bits === 0) return true;
  const mask = bits === 32 ? 0xffffffff : (~((1 << (32 - bits)) - 1)) >>> 0;
  return (a & mask) === (b & mask);
}

// Strict IPv4 CIDR (or bare address = /32). Anchored and \d-only, so a space-padded or malformed
// entry is REJECTED rather than silently failing to match — a non-matching AllowedIPs entry reads
// as intended-direct and can hide a real escape. (Codex P1, PR #562.)
function isValidIPv4Cidr(cidr) {
  if (typeof cidr !== "string") return false;
  const m = cidr.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?:\/(\d{1,2}))?$/);
  if (!m) return false;
  for (let i = 1; i <= 4; i += 1) {
    if (Number(m[i]) > 255) return false;
  }
  return m[5] === undefined || Number(m[5]) <= 32;
}

const isIPv6 = (ip) => typeof ip === "string" && ip.includes(":");

// Expand an IPv6 literal (incl. "::" compression, dropping any %zone) to a 128-bit BigInt, or null if
// malformed. Needed for on-link-prefix matching: the on-LAN exemption must be scoped to the capture
// segment's ACTUAL /64, not all of ULA space (Codex/Kilo P1, PR #564).
function ipv6ToBigInt(ip) {
  if (typeof ip !== "string") return null;
  const s = ip.toLowerCase().split("%")[0];
  if (s.includes(".")) return null; // v4-mapped / embedded-v4 forms are out of scope here
  let parts;
  if (s.includes("::")) {
    if (s.indexOf("::") !== s.lastIndexOf("::")) return null; // at most one "::"
    const [head, tail] = s.split("::");
    const h = head ? head.split(":") : [];
    const t = tail ? tail.split(":") : [];
    const missing = 8 - (h.length + t.length);
    if (missing < 0) return null;
    parts = [...h, ...Array(missing).fill("0"), ...t];
  } else {
    parts = s.split(":");
  }
  if (parts.length !== 8) return null;
  let n = 0n;
  for (const p of parts) {
    if (!/^[0-9a-f]{1,4}$/.test(p)) return null;
    n = (n << 16n) | BigInt(parseInt(p, 16));
  }
  return n;
}

function ipv6InCidr(ip, cidr) {
  const [net, bitsRaw] = cidr.split("/");
  const bits = bitsRaw === undefined ? 128 : Number(bitsRaw);
  if (!Number.isInteger(bits) || bits < 0 || bits > 128) return false;
  const a = ipv6ToBigInt(ip);
  const b = ipv6ToBigInt(net);
  if (a === null || b === null) return false;
  if (bits === 0) return true;
  const mask = (~0n << BigInt(128 - bits)) & ((1n << 128n) - 1n);
  return (a & mask) === (b & mask);
}

// Version-dispatching membership test. A v6 address is only ever in a v6 CIDR and vice-versa.
const ipInCidr = (ip, cidr) => (isIPv6(cidr) ? ipv6InCidr(ip, cidr) : ipv4InCidr(ip, cidr));
const isValidCidr = (cidr) => {
  if (typeof cidr !== "string") return false;
  if (isIPv6(cidr)) {
    const [net, bitsRaw] = cidr.split("/");
    if (bitsRaw !== undefined && !/^\d{1,3}$/.test(bitsRaw)) return false;
    return ipv6ToBigInt(net) !== null && (bitsRaw === undefined || Number(bitsRaw) <= 128);
  }
  return isValidIPv4Cidr(cidr);
};
// A bare IP literal (no prefix) of either family — for the IPsec ePDG endpoint allowlist.
const isValidIP = (ip) => (isIPv6(ip) ? ipv6ToBigInt(ip) !== null : ipv4ToInt(ip) !== null);

// Link-local / narrowly-scoped multicast / broadcast / autoconf — never routed off the segment, so
// never an internet-egress leak. Multicast is SCOPE-checked, not blanket-exempted: a globally scoped
// multicast (IPv6 ffXe:: scope e, or IPv4 routable multicast 224.0.1.0–238.255.255.255) IS a leak in
// full tunnel and must reach the classifier. (Codex P1/P2, PR #562.)
function isLocalScope(ip) {
  if (!ip) return true;
  if (isIPv6(ip)) {
    const l = ip.toLowerCase();
    if (l === "::" || l === "::1") return true;
    if (l.startsWith("fe80:")) return true; // link-local unicast
    // Multicast ffFS…: F = flags nibble, S = scope nibble. Exempt only interface-local (1) / link-local (2).
    const mc = l.match(/^ff[0-9a-f]([0-9a-f])/);
    if (mc) return mc[1] === "1" || mc[1] === "2";
    return false;
  }
  return (
    ipv4InCidr(ip, "169.254.0.0/16") || // link-local unicast
    ipv4InCidr(ip, "224.0.0.0/24") || // link-local multicast (mDNS/LLMNR/…)
    ipv4InCidr(ip, "239.0.0.0/8") || // administratively-scoped multicast (SSDP)
    ip === "255.255.255.255" ||
    ip === "0.0.0.0"
  );
}

// Private unicast (RFC1918 / ULA) — a LAN address, not the public Internet. Distinct from
// isLocalScope (link-local/multicast/broadcast): a DHCP unicast renew targets the LAN gateway's
// private unicast address, which is neither.
function isPrivateUnicast(ip) {
  if (!ip) return false;
  if (isIPv6(ip)) {
    const l = ip.toLowerCase();
    return l.startsWith("fc") || l.startsWith("fd"); // ULA fc00::/7
  }
  return (
    ipv4InCidr(ip, "10.0.0.0/8") ||
    ipv4InCidr(ip, "172.16.0.0/12") ||
    ipv4InCidr(ip, "192.168.0.0/16")
  );
}
// On-LAN = link-local/multicast/broadcast OR private unicast. Traffic here never reaches the
// public Internet, so it can never be an internet-egress leak.
const isLanScope = (ip) => isLocalScope(ip) || isPrivateUnicast(ip);

// Ports that carry only local-segment service traffic (DHCP, mDNS, LLMNR, SSDP) — allowlisted noise.
const LOCAL_SERVICE_PORTS = new Set([67, 68, 546, 547, 5353, 5355, 1900, 5350, 5351]);

// Local-segment housekeeping only. A packet is noise when EITHER endpoint is link-local/multicast
// (ARP/ND, mDNS, DHCP) — NOT merely because it has no L4 port. A global-scope packet with no port
// (a global ICMPv6 echo, an ESP tunnel to a non-peer host) is NOT noise; it must reach the mode
// classifier, which is where "any global IPv6 / any non-peer IPv4 is a leak" is decided. (Codex P1,
// PR #562: allowlisting all proto:"other" by type let global ICMP/ESP escape a clean verdict.)
function isLinkLocalNoise(pkt) {
  // DNS-port traffic (Do53/DoT) is NEVER noise — it must reach the mode classifier even to a
  // link-local/multicast endpoint. A cleartext DNS query to an unconfigured link-local resolver
  // (e.g. an IPv6 RDNSS at fe80::1) is a DNS-capture bypass, not housekeeping. mDNS/LLMNR are
  // DNS-*like* but use their OWN service ports (5353/5355) and are handled below. (Codex P1, #562.)
  const isDNS = pkt.dport !== undefined && DNS_PORTS.has(pkt.dport);
  // Exempt on the DESTINATION scope only. A link-local SOURCE with a GLOBAL destination is real
  // egress (any global IPv6 / non-peer IPv4 is a leak), so source locality alone must not exempt a
  // globally-destined packet. (Codex P1, PR #562.)
  if (!isDNS && isLocalScope(pkt.dst)) return true;
  // A service port is noise ONLY when it stays on the LAN. A service port to a GLOBAL address
  // (8.8.8.8:5353, 8.8.8.8:1900) is non-peer Internet egress hiding behind a "noise" port — it
  // must reach the mode classifier. (Codex P1, PR #562.)
  if (pkt.dport !== undefined && LOCAL_SERVICE_PORTS.has(pkt.dport) && isLanScope(pkt.dst)) return true;
  return false;
}

const DNS_PORTS = new Set([53, 853]); // Do53 + DoT. DoH (443) is ambiguous with all HTTPS, so it is
const isDNSPortDst = (p) => p.dport !== undefined && DNS_PORTS.has(p.dport); // caught only against a
const isDNSPortSrc = (p) => p.sport !== undefined && DNS_PORTS.has(p.sport); // known-resolver allowlist.

// Well-known public DoH resolver IPs. Because port 443 carries all HTTPS, DoH can only be detected
// against an allowlist: 443 to one of THESE addresses that is not the configured resolver is DoH
// escaping the intended resolver, not ordinary web traffic. Extend per-run via `dohResolverIPs`.
// (Codex P1, PR #562: DoH is the app's commonly-supported transport and was outside the check.)
const KNOWN_DOH_RESOLVER_IPS = new Set([
  "1.1.1.1", "1.0.0.1", // Cloudflare
  "8.8.8.8", "8.8.4.4", // Google
  "9.9.9.9", "149.112.112.112", // Quad9
  "94.140.14.14", "94.140.15.15", // AdGuard
  "2606:4700:4700::1111", "2606:4700:4700::1001",
  "2001:4860:4860::8888", "2001:4860:4860::8844",
  "2620:fe::fe", "2620:fe::9",
]);

// ---- the classifier --------------------------------------------------------

/**
 * @param {Array} packets  normalized packets (see file header)
 * @param {object} config
 *   mode: "full-tunnel" | "split-tunnel" | "dns-only"
 *   peerIP, peerPort: the WG outer endpoint (the ONLY sanctioned internet egress in full/split)
 *   endpointHost: the endpoint hostname whose ONE cleartext bootstrap DNS lookup is allowlisted (optional)
 *   allowedIPs: [cidr] the split-tunnel protected set (traffic to these must ride WG)
 *   resolverIPs: [ip] the configured DNS resolver(s) — dns-only allowlist / everything-else-is-a-leak basis
 *   canaryNonce: a unique token expected in the planted DNS canary's QNAME
 *   canaryLiteral: the planted IPv6 canary's destination address
 * @returns {{ canarySeen: boolean, candidateLeaks: Array, allowedCount: number }}
 */
export function analyzeCapture(packets, config) {
  const {
    mode,
    peerIP,
    peerPort,
    endpointHost,
    allowedIPs = [],
    resolverIPs = [],
    dohResolverIPs = [],
    canaryNonce,
    canaryLiteral,
    lanCIDRs = [],
    ipsecEndpoints = [],
  } = config;

  // ---- input validation: a misconfigured run must FAIL, never silently certify -------------------
  // All of these are checked BEFORE the loop, because an empty or noise-only capture never reaches a
  // per-packet check — so a bad mode/nonce/CIDR would otherwise let `--expect` exit 0. (Codex P1, #562.)
  const VALID_MODES = new Set(["full-tunnel", "split-tunnel", "dns-only"]);
  if (!VALID_MODES.has(mode)) {
    throw new Error(`unknown mode ${JSON.stringify(mode)} — use full-tunnel | split-tunnel | dns-only`);
  }
  // An empty nonce (e.g. `--canary-nonce "$VAR"` with VAR unset) makes `dns.includes("")` match every
  // DNS packet, so the bootstrap lookup alone would satisfy --expect canary.
  if (canaryNonce !== undefined && String(canaryNonce).trim() === "") {
    throw new Error("--canary-nonce must be nonempty: an empty nonce matches every DNS query");
  }
  if (mode === "split-tunnel") {
    // Empty set → every destination reads intended-direct and a leak of protected traffic hides.
    if (allowedIPs.length === 0) {
      throw new Error(
        "split-tunnel analysis requires a nonempty --allowed-ips set: with none, every destination " +
          "reads as intended-direct and a leak of protected-prefix traffic cannot be detected.");
    }
    // A malformed or space-padded CIDR silently fails ipv4InCidr, so its traffic reads intended-
    // direct — reject rather than ignore.
    const bad = allowedIPs.filter((c) => !isValidIPv4Cidr(c));
    if (bad.length > 0) {
      throw new Error(
        `invalid --allowed-ips entr${bad.length > 1 ? "ies" : "y"}: ${bad.map((c) => JSON.stringify(c)).join(", ")} ` +
          "(want an IPv4 CIDR like 100.64.0.0/10)");
    }
  }
  // A malformed --lan-cidr would silently fail to match and re-flag on-LAN noise (merely noisy), but a
  // malformed --ipsec-endpoint would silently fail to match and RE-FLAG the acknowledged IPsec — safe
  // direction — so both are validated for good error messages, not because a bad entry hides a leak.
  const badLan = lanCIDRs.filter((c) => !isValidCidr(c));
  if (badLan.length > 0) {
    throw new Error(
      `invalid --lan-cidr entr${badLan.length > 1 ? "ies" : "y"}: ${badLan.map((c) => JSON.stringify(c)).join(", ")} ` +
        "(want an on-link CIDR like 192.168.3.0/24 or fd7f:2561:4e47:746b::/64)");
  }
  const badEpdg = ipsecEndpoints.filter((ip) => !isValidIP(ip));
  if (badEpdg.length > 0) {
    throw new Error(
      `invalid --ipsec-endpoint entr${badEpdg.length > 1 ? "ies" : "y"}: ${badEpdg.map((ip) => JSON.stringify(ip)).join(", ")} ` +
        "(want a bare ePDG IP like 198.51.100.20)");
  }

  const dohTargets = new Set([...KNOWN_DOH_RESOLVER_IPS, ...dohResolverIPs]);
  const isEscapedDoH = (p) => p.dport === 443 && dohTargets.has(p.dst) && !resolverIPs.includes(p.dst);

  // IKE / IPsec NAT-T (UDP 500/4500). To a GLOBAL address this is an OS-managed encrypted tunnel that
  // lives BELOW the NetworkExtension layer — most commonly carrier Wi-Fi Calling to an ePDG — which a
  // NEPacketTunnelProvider can neither capture nor prevent. Matched on port in either direction.
  const isIpsecNatT = (p) =>
    p.proto === "udp" && (p.dport === 500 || p.dport === 4500 || p.sport === 500 || p.sport === 4500);
  // A port match ALONE must never acknowledge a leak: any app can send UDP to a controlled :4500
  // server. An IPsec datagram is treated as OS-below-NE ONLY when its counterpart is an operator-
  // declared ePDG (--ipsec-endpoint). Absent that, port-500/4500 to a global host stays a candidate
  // leak, self-labeled so the operator can allowlist the real ePDG. (Codex P1, PR #564.)
  const isAcknowledgedIpsec = (p) =>
    isIpsecNatT(p) && (ipsecEndpoints.includes(p.dst) || ipsecEndpoints.includes(p.src));
  // Purely on-link traffic = BOTH endpoints inside ONE operator-declared on-link prefix (--lan-cidr:
  // the phone's /24 and the segment's ULA /64). Scoped to the ACTUAL segment, NOT all RFC1918/ULA — a
  // packet to a DIFFERENT private subnet routes via the full-tunnel default route, so egressing it
  // direct is a real bypass. Empty --lan-cidr ⇒ no exemption (fail-closed). (Codex/Kilo P1, PR #564.)
  const bothOnLink = (p) => lanCIDRs.some((c) => ipInCidr(p.src, c) && ipInCidr(p.dst, c));

  // WG-outer is UDP to/from the peer ENDPOINT — pinned on port in BOTH directions. The inbound
  // branch must pin the source port too (Kilo, PR #562): in full-tunnel the peer endpoint is the
  // only sanctioned physical egress, so a non-WG UDP datagram that merely originates from the peer
  // IP (some other service on that host) must not be allowlisted as if it were the tunnel.
  const isWGOuter = (p) =>
    p.proto === "udp" &&
    ((p.dst === peerIP && p.dport === peerPort) ||
      (p.src === peerIP && p.sport === peerPort));

  const isBootstrapDNS = (p) =>
    p.dns !== undefined &&
    isDNSPortDst(p) &&
    endpointHost !== undefined &&
    p.dns === String(endpointHost).toLowerCase();

  const isCanary = (p) =>
    (canaryNonce !== undefined && p.dns !== undefined && p.dns.includes(String(canaryNonce).toLowerCase())) ||
    (canaryLiteral !== undefined && (p.dst === canaryLiteral || p.src === canaryLiteral));

  const destInAllowedIPs = (p) => {
    if (isIPv6(p.dst)) return false; // v4-only AllowedIPs sets in practice; extend if v6 AllowedIPs appear
    return allowedIPs.some((cidr) => ipv4InCidr(p.dst, cidr));
  };

  // The resolver IPs whose DNS *query* is sanctioned — so their DNS *reply* (source port 53/853, no
  // QNAME, ephemeral dst port) is not mistaken for a non-peer egress. In full-tunnel the sanctioned
  // resolver is whoever answered the one endpoint bootstrap lookup; a reply from anyone else stays a
  // leak. (Codex P1, PR #562: the bootstrap reply has no `dns` field and was flagged non-peer-ipv4.)
  const bootstrapResolvers = new Set(
    packets.filter((p) => isBootstrapDNS(p) && p.dst !== undefined).map((p) => p.dst),
  );
  // A DNS reply from the bootstrap resolver, over UDP OR TCP — the endpoint lookup falls back to
  // TCP on a truncated UDP answer, and tcpdump labels that reply proto:"tcp". (Codex P2, PR #562.)
  const isSanctionedDNSReply = (p) =>
    (p.proto === "udp" || p.proto === "tcp") && isDNSPortSrc(p) && bootstrapResolvers.has(p.src);

  let canarySeen = false;
  const candidateLeaks = [];
  let allowedCount = 0;
  let sawWGOuter = false;
  let sawDNSPort = false;

  for (const p of packets) {
    if (isWGOuter(p)) sawWGOuter = true;
    if (isDNSPortDst(p) || isDNSPortSrc(p)) sawDNSPort = true;
    const canary = isCanary(p);
    if (canary) canarySeen = true;

    // A canary is, by construction, a leak that escaped the guard — always a finding (that IS the
    // positive control), even though it is the one leak we planted on purpose.
    if (canary) {
      candidateLeaks.push({ ...p, reason: "planted-canary" });
      continue;
    }

    if (isLinkLocalNoise(p)) {
      allowedCount++;
      continue;
    }

    if (mode === "full-tunnel") {
      // INV-CHAIN-1: the ONLY sanctioned physical egress is WG-outer to the peer, plus the one
      // endpoint-hostname bootstrap DNS lookup (and its reply). Everything else — any cleartext DNS,
      // any GLOBAL IPv6 (v6 is dropped in full tunnel), any non-peer global IPv4, any global no-port
      // packet (ICMP/ESP) — is a leak.
      if (isWGOuter(p) || isBootstrapDNS(p) || isSanctionedDNSReply(p)) {
        allowedCount++;
        continue;
      }
      // Purely on-link traffic (BOTH endpoints inside one operator-declared --lan-cidr, e.g. the
      // phone's /24 and the segment's ULA /64) is delivered on the local segment and never reaches the
      // public Internet: the full-tunnel default route captures the Internet, not the more-specific
      // on-link subnet route, so it riding the physical interface is expected, not a leak. BOTH
      // endpoints must be on-link — an inbound datagram from the GLOBAL peer host to the phone's
      // address, or a packet to a DIFFERENT private subnet (routed via the default route → the
      // tunnel), is real internet traffic, NOT on-LAN noise. DNS is the other exception — a cleartext
      // DNS query to a LAN resolver (a router/Pi-hole at 192.168.x:53) IS the escape this rig hunts —
      // so DNS-port / QNAME-bearing packets are NEVER exempted here and fall through to the
      // cleartext-dns check below. Empty --lan-cidr ⇒ no exemption. (Codex/Kilo P1, PR #564; real #10:
      // 82 phone↔Mac IPv6-ULA datagrams + Dropbox/Spotify subnet broadcasts, all same-segment.)
      const isDNSPacket = isDNSPortDst(p) || isDNSPortSrc(p) || p.dns !== undefined;
      if (!isDNSPacket && bothOnLink(p)) {
        allowedCount++;
        continue;
      }
      // IKE/IPsec NAT-T to a GLOBAL address (Wi-Fi Calling & friends) rides below the NE layer and is
      // uncapturable/unpreventable by the tunnel. Acknowledged ONLY when its counterpart is a declared
      // ePDG (--ipsec-endpoint); otherwise it stays a candidate leak, self-labeled, fail-closed.
      if (isIpsecNatT(p)) {
        if (isAcknowledgedIpsec(p)) {
          allowedCount++;
        } else {
          candidateLeaks.push({ ...p, reason: "ipsec-natt-os-below-ne" });
        }
        continue;
      }
      if (isIPv6(p.dst)) {
        candidateLeaks.push({ ...p, reason: "ipv6-egress-in-full-tunnel" });
      } else if (isDNSPortDst(p) || p.dns !== undefined) {
        candidateLeaks.push({ ...p, reason: "cleartext-dns-not-bootstrap" });
      } else {
        candidateLeaks.push({ ...p, reason: "non-peer-ipv4-egress" });
      }
      continue;
    }

    if (mode === "split-tunnel") {
      // Split scopes the tunnel's protection to AllowedIPs for IPv4, and since 2026-09-19 claims
      // `::/0` in order to DROP IPv6 (docs/invariants.md §3.3 amended). So AllowedIPs-destined
      // traffic egressing direct is the leak it always was, AND any global IPv6 on the wire is now
      // a leak too — a v6 resolver answering outside the filter is exactly the 2026-09-17/19 field
      // escape. Non-AllowedIPs IPv4, INCLUDING cleartext DNS to an IPv4 resolver, still leaves
      // direct and is INTENDED (the accepted dns-only-grade scope reduction).
      // (Codex P2, PR #562 for the IPv4 direct case; Kilo, PR #738 for the IPv6 flip.)
      if (isWGOuter(p)) {
        allowedCount++;
        continue;
      }
      if (isIPv6(p.dst)) {
        candidateLeaks.push({ ...p, reason: "ipv6-egress-in-split-tunnel" });
        continue;
      }
      if (destInAllowedIPs(p)) {
        candidateLeaks.push({ ...p, reason: "allowedips-traffic-not-tunnelled" });
        continue;
      }
      allowedCount++; // intended direct IPv4 egress (incl. cleartext DNS to an IPv4 resolver)
      continue;
    }

    if (mode === "dns-only") {
      // dns-only tunnels NOTHING but DNS: non-DNS goes direct (fine). A DNS query to a resolver that
      // is not the configured one is the leak — detected by PORT (53/853) so encrypted DoT with no
      // cleartext QNAME is caught. DoH (443 to a known-resolver IP that isn't configured) is the
      // same escape over the ambiguous HTTPS port. (Codex P1, PR #562.)
      //
      // No bootstrap exemption here: it is full-tunnel-only (docs/testing/leak-rig.md). dns-only has
      // no WG endpoint to bootstrap, so a query to the endpoint hostname at an unconfigured resolver
      // is a leak like any other. (Codex P1, PR #562.)
      if (isDNSPortDst(p) && !resolverIPs.includes(p.dst)) {
        candidateLeaks.push({ ...p, reason: "dns-to-unconfigured-resolver" });
        continue;
      }
      if (isEscapedDoH(p)) {
        candidateLeaks.push({ ...p, reason: "doh-to-unconfigured-resolver" });
        continue;
      }
      allowedCount++;
      continue;
    }

    throw new Error(`unknown mode: ${mode}`);
  }

  // Liveness: proof the capture actually observed the phone's protected traffic, so an empty, blind,
  // or stopped-early negative-run file cannot certify "no leak" (Codex P1, PR #562). full/split: the
  // tunnel's own WG-outer datagrams must appear on the physical interface; dns-only: any DNS on the wire.
  const livenessObserved = mode === "dns-only" ? sawDNSPort : sawWGOuter;
  return { canarySeen, candidateLeaks, allowedCount, analyzedPacketCount: packets.length, livenessObserved };
}

// ---- expectation gate (shared by CLI + tests) ------------------------------

/**
 * Decide pass/fail for a run given its declared expectation. Exported so the "a canary present in a
 * real run is itself a failure" rule (Codex P1 / Kilo, PR #562) is unit-tested, not buried in main().
 * @returns {{ ok: boolean, lines: string[] }}
 */
export function evaluateExpect(result, expect) {
  // No expectation supplied → report-only (the JSON was already printed); never a failure.
  if (expect === undefined || expect === null) return { ok: true, lines: [] };

  if (expect === "canary") {
    if (!result.canarySeen) {
      return {
        ok: false,
        lines: [
          "FAIL: expected the planted canary but the rig saw NOTHING — capture is blind " +
            "(topology/uplink/phone-prep). Fix before trusting any 'no leak'.",
        ],
      };
    }
    return { ok: true, lines: ["ok: positive control — the rig saw the planted canary."] };
  }

  if (expect === "no-leak") {
    // Fail on EVERY candidate, planted-canary included: a canary on the wire during a real run means
    // the emitter was left enabled (or a real query collided with the nonce) — exactly the blind
    // false-certification the positive control exists to prevent. Do NOT filter it out.
    if (result.candidateLeaks.length > 0) {
      const lines = [`FAIL: ${result.candidateLeaks.length} candidate leak(s) on the physical interface:`];
      for (const c of result.candidateLeaks) {
        const tag = c.reason === "planted-canary"
          ? "  [canary emitter still ACTIVE — it must be disabled for a real no-leak run]"
          : "";
        lines.push(`  - ${c.reason}: ${c.proto} ${c.src ?? "?"} > ${c.dst}${c.dns ? ` (${c.dns})` : ""}${tag}`);
      }
      return { ok: false, lines };
    }
    // No candidates is only meaningful if the capture SAW the protected traffic. An empty, blind, or
    // stopped-early file has no candidates for the trivial reason that it observed nothing. (Codex P1.)
    if (result.livenessObserved === false) {
      return {
        ok: false,
        lines: [
          "FAIL: no liveness marker in the capture (no WG-outer to the peer; for dns-only, no DNS on " +
            "the wire) — it may be empty, stopped early, or blind. A clean no-leak verdict requires " +
            "evidence the capture actually observed the phone's protected traffic.",
        ],
      };
    }
    return {
      ok: true,
      lines: [
        "ok: no candidate leaks. NOTE: valid ONLY if the positive control passed on this same " +
          "topology and the phone had exactly one Mac-visible uplink.",
      ],
    };
  }

  // An explicit but unrecognized value (a misspelled gate like --expect no-leaks) must NOT pass
  // silently — it would exit 0 over a nonempty candidate set and falsely certify the run.
  // (Codex P1, PR #562.)
  return {
    ok: false,
    lines: [`FAIL: unknown --expect value ${JSON.stringify(expect)} — use "canary" or "no-leak" (or omit for report-only).`],
  };
}

// ---- tcpdump front-end (lab path) -----------------------------------------

// Split a tcpdump endpoint token into [address, port]. tcpdump appends ".<port>" to the address for
// L4 flows and appends NOTHING for portless packets (ICMP/ICMPv6/ESP). IPv4 addresses already carry
// dots, so a port is only the 5th dotted group — never the 4th octet (Codex P2, PR #562: a naive
// "last dotted group is the port" split truncated ICMP IPv4 addresses). IPv6 addresses carry colons,
// so a trailing ".<digits>" is unambiguously the port.
function splitAddrPort(token, isV6) {
  if (isV6) {
    const m = token.match(/^(.+)\.(\d+)$/);
    if (m && token.includes(":")) return [m[1], Number(m[2])];
    return [token, undefined];
  }
  const parts = token.split(".");
  if (parts.length === 5) return [parts.slice(0, 4).join("."), Number(parts[4])];
  return [token, undefined]; // 4 groups = bare IPv4 (portless), or an unexpected shape kept verbatim
}

// Parse `tcpdump -nn -tt -r <pcap>` text into normalized packets. Covers IPv4/IPv6 UDP, TCP, and
// PORTLESS packets (ICMP/ICMPv6/ESP), and extracts DNS QNAMEs from Do53 query lines. Non-IP lines
// (ARP) are skipped. tcpdump prints "src[.port] > dst[.port]: description".
export function parseTcpdump(text) {
  const packets = [];
  for (const rawLine of text.split("\n")) {
    const l = rawLine.trim();
    if (!l) continue;
    if (!/\bIP6?\b/.test(l)) continue; // skip ARP and other non-IP records
    const isV6 = /\bIP6\b/.test(l);
    // "src > dst:" — dst may itself contain colons (IPv6), so end it at the FIRST ": " (colon-space)
    // or end-of-line, never at the first bare colon.
    const m = l.match(/\bIP6?\s+(\S+)\s+>\s+(.+?):(?:\s|$)/);
    if (!m) continue;
    const [src, sport] = splitAddrPort(m[1], isV6);
    const [dst, dport] = splitAddrPort(m[2], isV6);
    if (!src || !dst) continue;
    let proto;
    if (/\bFlags \[|\btcp\b/.test(l)) {
      proto = "tcp";
    } else if (/\bUDP\b/.test(l) || sport === 53 || dport === 53 || sport === 853 || dport === 853) {
      proto = "udp";
    } else if (sport !== undefined || dport !== undefined) {
      proto = "udp"; // ports present, protocol word absent — an L4 datagram; default to udp
    } else {
      proto = "other"; // no ports at all — ICMP / ICMPv6 / ESP
    }
    const pkt = { v: isV6 ? 6 : 4, proto, src, dst };
    if (sport !== undefined) pkt.sport = sport;
    if (dport !== undefined) pkt.dport = dport;
    // DNS query name: tcpdump prints e.g. "... A? example.com. (29)"
    const dnsQ = l.match(/\s([A-Za-z]{1,10})\? ([^\s]+?)\.? \(/);
    if (dnsQ && (dport === 53 || dport === 853)) {
      pkt.dns = dnsQ[2].toLowerCase().replace(/\.$/, "");
    }
    packets.push(pkt);
  }
  return packets;
}

function readPcap(pcapPath) {
  const res = spawnSync("tcpdump", ["-nn", "-tt", "-r", pcapPath], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (res.status !== 0) {
    throw new Error(`tcpdump failed (${res.status}): ${res.stderr}`);
  }
  return parseTcpdump(res.stdout);
}

// ---- CLI -------------------------------------------------------------------

/**
 * The expectation gate is the rig's only hard pass/fail (the blind-capture rule, PR #562), so a
 * `--expect` with no value must be a USAGE ERROR rather than a silent downgrade to report-only.
 * A CI driver writing `--expect $EXPECT` with an unset variable would otherwise turn a must-fail
 * gate green (security review S-5).
 */
function requireExpectValue(value) {
  if (value === undefined || value === null || value === "") {
    throw new Error("--expect requires a value: canary | no-leak (omit the flag for report-only)");
  }
  return value;
}

export function parseArgs(argv) {
  const cfg = { allowedIPs: [], resolverIPs: [], dohResolverIPs: [], lanCIDRs: [], ipsecEndpoints: [] };
  let jsonPath;
  let pcapPath;
  let expect; // "no-leak" | "canary"
  // Comma-separated lists tolerate the spaces a copy-paste from a WireGuard config carries
  // ("100.64.0.0/10, 192.168.0.0/16"); analyzeCapture still rejects a genuinely malformed CIDR.
  const splitList = (s) => s.split(",").map((x) => x.trim()).filter(Boolean);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    switch (a) {
      case "--json": jsonPath = next(); break;
      case "--pcap": pcapPath = next(); break;
      case "--mode": cfg.mode = next(); break;
      case "--peer-ip": cfg.peerIP = next(); break;
      case "--peer-port": cfg.peerPort = Number(next()); break;
      case "--endpoint-host": cfg.endpointHost = next().toLowerCase(); break;
      case "--allowed-ips": cfg.allowedIPs = splitList(next()); break;
      case "--resolver-ip": cfg.resolverIPs = splitList(next()); break;
      case "--doh-resolver-ip": cfg.dohResolverIPs = splitList(next()); break;
      case "--canary-nonce": cfg.canaryNonce = next(); break;
      case "--canary-literal": cfg.canaryLiteral = next(); break;
      case "--lan-cidr": cfg.lanCIDRs.push(...splitList(next())); break;
      case "--ipsec-endpoint": cfg.ipsecEndpoints.push(...splitList(next())); break;
      case "--expect": expect = requireExpectValue(next()); break;
      default: throw new Error(`unknown arg: ${a}`);
    }
  }
  return { cfg, jsonPath, pcapPath, expect };
}

function main() {
  const { cfg, jsonPath, pcapPath, expect } = parseArgs(process.argv.slice(2));
  if (!cfg.mode) throw new Error("--mode is required (full-tunnel | split-tunnel | dns-only)");
  const packets = jsonPath
    ? JSON.parse(fs.readFileSync(jsonPath, "utf8"))
    : pcapPath
    ? readPcap(pcapPath)
    : (() => { throw new Error("one of --json or --pcap is required"); })();

  const result = analyzeCapture(packets, cfg);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);

  const verdict = evaluateExpect(result, expect);
  for (const line of verdict.lines) console.error(line);
  if (!verdict.ok) process.exit(1);
}

if (process.argv[1] && import.meta.url === `file://${process.argv[1]}`) {
  main();
}
