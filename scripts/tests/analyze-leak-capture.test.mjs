import assert from "node:assert/strict";
import test from "node:test";

import { analyzeCapture, evaluateExpect, parseArgs, parseTcpdump } from "../analyze-leak-capture.mjs";

// The WG peer + config a full-tunnel run would be given.
const FULL = {
  mode: "full-tunnel",
  peerIP: "198.51.100.10",
  peerPort: 51820,
  endpointHost: "wg.example.net",
  canaryNonce: "abc123nonce",
  canaryLiteral: "2001:db8:dead::1",
};

const wgOuter = { v: 4, proto: "udp", src: "10.0.0.2", dst: FULL.peerIP, dport: FULL.peerPort };
const bootstrap = { v: 4, proto: "udp", src: "10.0.0.2", dst: "10.0.0.1", dport: 53, dns: "wg.example.net" };
const mdns = { v: 4, proto: "udp", src: "10.0.0.2", dst: "224.0.0.251", dport: 5353 };
const ndp = { v: 6, proto: "other", src: "fe80::1", dst: "ff02::1" };

test("full-tunnel clean capture reports zero candidate leaks", () => {
  const r = analyzeCapture([wgOuter, wgOuter, bootstrap, mdns, ndp], FULL);
  assert.equal(r.candidateLeaks.length, 0);
  assert.equal(r.canarySeen, false);
  assert.equal(r.allowedCount, 5);
});

test("the DNS canary is SEEN and enumerated (positive control, #8)", () => {
  const canary = { v: 4, proto: "udp", src: "10.0.0.2", dst: "9.9.9.9", dport: 53, dns: `${FULL.canaryNonce}.leak-canary.lavasec.invalid` };
  const r = analyzeCapture([wgOuter, canary], FULL);
  assert.equal(r.canarySeen, true, "the rig MUST see the planted canary");
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "planted-canary");
});

test("the IPv6 canary literal is SEEN (positive control, #8)", () => {
  const v6canary = { v: 6, proto: "udp", src: "fd00::2", dst: FULL.canaryLiteral, dport: 443 };
  const r = analyzeCapture([wgOuter, v6canary], FULL);
  assert.equal(r.canarySeen, true);
  assert.equal(r.candidateLeaks[0].reason, "planted-canary");
});

test("full-tunnel flags a global IPv6 egress (v6 must be dropped)", () => {
  const v6leak = { v: 6, proto: "tcp", src: "2606:4700::1", dst: "2606:4700:4700::1111", dport: 443 };
  const r = analyzeCapture([wgOuter, v6leak], FULL);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "ipv6-egress-in-full-tunnel");
});

test("full-tunnel flags cleartext DNS that is not the endpoint bootstrap", () => {
  const dnsLeak = { v: 4, proto: "udp", src: "10.0.0.2", dst: "8.8.8.8", dport: 53, dns: "tracker.example.com" };
  const r = analyzeCapture([wgOuter, dnsLeak], FULL);
  assert.equal(r.candidateLeaks[0].reason, "cleartext-dns-not-bootstrap");
});

test("full-tunnel flags non-peer IPv4 egress (direct, not via WG)", () => {
  const direct = { v: 4, proto: "tcp", src: "10.0.0.2", dst: "142.250.72.14", dport: 443 };
  const r = analyzeCapture([wgOuter, direct], FULL);
  assert.equal(r.candidateLeaks[0].reason, "non-peer-ipv4-egress");
});

test("dns-only: DNS to the configured resolver is fine, non-DNS direct is fine", () => {
  const cfg = { mode: "dns-only", resolverIPs: ["10.64.0.1"] };
  const good = { v: 4, proto: "udp", src: "10.0.0.2", dst: "10.64.0.1", dport: 53, dns: "example.com" };
  const https = { v: 4, proto: "tcp", src: "10.0.0.2", dst: "142.250.72.14", dport: 443 };
  const r = analyzeCapture([good, https, mdns], cfg);
  assert.equal(r.candidateLeaks.length, 0);
});

test("dns-only: DNS to an UNCONFIGURED resolver is a leak", () => {
  const cfg = { mode: "dns-only", resolverIPs: ["10.64.0.1"] };
  const leak = { v: 4, proto: "udp", src: "10.0.0.2", dst: "8.8.8.8", dport: 53, dns: "example.com" };
  const r = analyzeCapture([leak], cfg);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "dns-to-unconfigured-resolver");
});

test("split-tunnel: non-AllowedIPs IPv4 direct (incl. cleartext DNS) is INTENDED; un-tunnelled AllowedIPs and ANY IPv6 are leaks", () => {
  // docs/invariants.md §3.3 (amended 2026-09-19): split scopes IPv4 protection to AllowedIPs and
  // claims `::/0` to DROP IPv6, so global IPv6 is now a leak rather than intended direct egress.
  const cfg = { mode: "split-tunnel", peerIP: FULL.peerIP, peerPort: FULL.peerPort, allowedIPs: ["100.64.0.0/10"], resolverIPs: ["100.100.100.100"] };
  const directV4 = { v: 4, proto: "tcp", src: "10.0.0.2", dst: "142.250.72.14", dport: 443 }; // non-AllowedIPs IPv4 → intended
  const directV6 = { v: 6, proto: "tcp", src: "2001:db8::2", dst: "2606:4700:4700::1111", dport: 443 }; // v6 → leak
  const wg = { v: 4, proto: "udp", src: "10.0.0.2", dst: FULL.peerIP, dport: FULL.peerPort };
  const directDNS = { v: 4, proto: "udp", src: "10.0.0.2", sport: 5000, dst: "8.8.8.8", dport: 53, dns: "corp.internal" }; // accepted direct IPv4 (INV §3.3)
  const untunnelled = { v: 4, proto: "tcp", src: "10.0.0.2", dst: "100.64.5.5", dport: 22 }; // AllowedIPs dest direct → leak
  const r = analyzeCapture([directV4, directV6, wg, directDNS, untunnelled], cfg);
  const reasons = r.candidateLeaks.map((c) => c.reason).sort();
  assert.deepEqual(reasons, ["allowedips-traffic-not-tunnelled", "ipv6-egress-in-split-tunnel"]);
});

test("parseTcpdump extracts proto, addresses, ports, and DNS QNAMEs", () => {
  const text = [
    "1699999999.123456 IP 10.0.0.2.51234 > 1.1.1.1.53: 12345+ A? tracker.example.com. (36)",
    "1699999999.223456 IP 10.0.0.2.51820 > 198.51.100.10.51820: UDP, length 148",
    "1699999999.323456 IP6 fe80::1.5353 > ff02::fb.5353: 0 [2q] PTR (63)",
  ].join("\n");
  const pkts = parseTcpdump(text);
  assert.equal(pkts.length, 3);
  assert.equal(pkts[0].dns, "tracker.example.com");
  assert.equal(pkts[0].dport, 53);
  assert.equal(pkts[1].dst, "198.51.100.10");
  assert.equal(pkts[1].dport, 51820);
  assert.equal(pkts[2].v, 6);
});

// ---- review-hardening (Codex + Kilo, PR #562) ------------------------------

test("full-tunnel: the endpoint bootstrap DNS reply (src port 53, no QNAME) is allowlisted", () => {
  // Codex P1: the reply to the sanctioned bootstrap lookup has source port 53, an ephemeral dst
  // port, and no `dns` field — it must not be reported as a non-peer egress.
  const query = { v: 4, proto: "udp", src: "10.0.0.2", sport: 51234, dst: "10.0.0.1", dport: 53, dns: "wg.example.net" };
  const reply = { v: 4, proto: "udp", src: "10.0.0.1", sport: 53, dst: "10.0.0.2", dport: 51234 };
  const r = analyzeCapture([wgOuter, query, reply], FULL);
  assert.equal(r.candidateLeaks.length, 0);
  assert.equal(r.allowedCount, 3);
});

test("full-tunnel: a DNS reply from a NON-bootstrap resolver is STILL a leak", () => {
  // The reply allowlist is scoped to the resolver that answered the bootstrap — not "any DNS reply".
  const reply = { v: 4, proto: "udp", src: "8.8.8.8", sport: 53, dst: "10.0.0.2", dport: 51234 };
  const r = analyzeCapture([wgOuter, reply], FULL);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "non-peer-ipv4-egress");
});

test("full-tunnel: a global ICMPv6 packet (proto other, no ports) escaping is a leak", () => {
  // Codex P1: proto:"other" must not be blanket-allowlisted; a global v6 egress is a leak.
  const icmp6 = { v: 6, proto: "other", src: "2001:db8::2", dst: "2606:4700:4700::1111" };
  const r = analyzeCapture([wgOuter, icmp6], FULL);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "ipv6-egress-in-full-tunnel");
});

test("full-tunnel: a global ICMP (IPv4, proto other, no ports) to a non-peer is a leak", () => {
  const icmp4 = { v: 4, proto: "other", src: "10.0.0.2", dst: "8.8.8.8" };
  const r = analyzeCapture([wgOuter, icmp4], FULL);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "non-peer-ipv4-egress");
});

test("full-tunnel: link-local ICMPv6 (ND, proto other) is still allowlisted noise", () => {
  const nd = { v: 6, proto: "other", src: "fe80::1", dst: "ff02::1" };
  const r = analyzeCapture([wgOuter, nd], FULL);
  assert.equal(r.candidateLeaks.length, 0);
});

test("dns-only: a DoT connection (port 853, no QNAME) to an UNCONFIGURED resolver is a leak", () => {
  // Codex P1 / Kilo: keyed on DNS PORT, not on a decoded QNAME — encrypted DoT carries none.
  const cfg = { mode: "dns-only", resolverIPs: ["10.64.0.1"] };
  const dot = { v: 4, proto: "tcp", src: "10.0.0.2", sport: 44321, dst: "1.1.1.1", dport: 853 };
  const r = analyzeCapture([dot], cfg);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "dns-to-unconfigured-resolver");
});

test("dns-only: a DoT connection to the CONFIGURED resolver is allowed", () => {
  const cfg = { mode: "dns-only", resolverIPs: ["10.64.0.1"] };
  const dot = { v: 4, proto: "tcp", src: "10.0.0.2", sport: 44321, dst: "10.64.0.1", dport: 853 };
  const r = analyzeCapture([dot], cfg);
  assert.equal(r.candidateLeaks.length, 0);
});

test("split-tunnel: a DoT connection to a non-AllowedIPs resolver is accepted direct, NOT a leak (INV §3.3)", () => {
  const cfg = { mode: "split-tunnel", peerIP: FULL.peerIP, peerPort: FULL.peerPort, allowedIPs: ["100.64.0.0/10"], resolverIPs: ["100.100.100.100"] };
  const dot = { v: 4, proto: "tcp", src: "10.0.0.2", sport: 5555, dst: "1.1.1.1", dport: 853 };
  const r = analyzeCapture([dot], cfg);
  assert.equal(r.candidateLeaks.length, 0);
});

// ---- second review round (Codex, PR #562) ----------------------------------

test("full-tunnel: a service-port packet to a GLOBAL address is a leak, not noise", () => {
  // Codex P1: LOCAL_SERVICE_PORTS noise must require a LAN destination — 8.8.8.8:1900 is egress.
  const ssdp = { v: 4, proto: "udp", src: "10.0.0.2", sport: 40000, dst: "8.8.8.8", dport: 1900 };
  const r = analyzeCapture([wgOuter, ssdp], FULL);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "non-peer-ipv4-egress");
});

test("full-tunnel: a DHCP unicast renew to a private LAN gateway is allowlisted noise", () => {
  const dhcp = { v: 4, proto: "udp", src: "10.0.0.2", sport: 68, dst: "192.168.1.1", dport: 67 };
  const r = analyzeCapture([wgOuter, dhcp], FULL);
  assert.equal(r.candidateLeaks.length, 0);
});

// ---- full-tunnel on-LAN scope refinement (from the real #10 capture, task #55 / PR #564) -----------
// The real no-leak run's only non-peer traffic was on-link: 82 phone↔Mac IPv6-ULA datagrams over the
// Internet-Sharing bridge + Dropbox/Spotify subnet broadcasts, plus the carrier's Wi-Fi-Calling IPsec.
// None reaches the public Internet, so none is an egress leak — but the exemption must be surgical:
// scoped to the operator-declared on-link prefix(es), NOT all of RFC1918/ULA (Codex/Kilo P1).
const LAN_V4 = "192.168.3.0/24";                 // the phone's actual sharing subnet
const LAN_V6 = "fd7f:2561:4e47:746b::/64";        // the sharing bridge's ULA /64
const LAN = { ...FULL, lanCIDRs: [LAN_V4, LAN_V6] };
const EPDG = "198.51.100.20";                      // the carrier ePDG (Wi-Fi Calling), declared per-run

test("full-tunnel: on-LAN IPv6-ULA unicast (non-DNS), both ends in the declared /64, is NOT a leak (real #10)", () => {
  const ula = { v: 6, proto: "udp", src: "fd7f:2561:4e47:746b::ac15", sport: 60964, dst: "fd7f:2561:4e47:746b::8271", dport: 49211 };
  const r = analyzeCapture([wgOuter, ula], LAN);
  assert.equal(r.candidateLeaks.length, 0);
  assert.equal(r.allowedCount, 2);
});

test("full-tunnel: a directed subnet broadcast (non-DNS) within the declared /24 is NOT a leak (Dropbox/Spotify, real #10)", () => {
  const bcast = { v: 4, proto: "udp", src: "192.168.3.2", sport: 17500, dst: "192.168.3.255", dport: 17500 };
  const r = analyzeCapture([wgOuter, bcast], LAN);
  assert.equal(r.candidateLeaks.length, 0);
});

test("full-tunnel: a same-subnet unicast (non-DNS) is on-LAN, not a leak", () => {
  const lan = { v: 4, proto: "tcp", src: "192.168.3.2", sport: 40000, dst: "192.168.3.9", dport: 445 };
  const r = analyzeCapture([wgOuter, lan], LAN);
  assert.equal(r.candidateLeaks.length, 0);
});

test("full-tunnel: with NO --lan-cidr, on-LAN traffic is NOT exempted (fail-closed default)", () => {
  // The exemption is opt-in per capture; absent a declared prefix the analyzer stays strict.
  const ula = { v: 6, proto: "udp", src: "fd7f:2561:4e47:746b::ac15", sport: 60964, dst: "fd7f:2561:4e47:746b::8271", dport: 49211 };
  const r = analyzeCapture([wgOuter, ula], FULL);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "ipv6-egress-in-full-tunnel");
});

test("full-tunnel GUARD (Codex/Kilo P1): a private dest on a DIFFERENT subnet than the phone is NOT on-LAN-exempt", () => {
  // 192.168.3.2 → 10.0.0.5 is private-to-private but cross-subnet: it routes via the full-tunnel
  // default route → the tunnel, so seeing it direct is a genuine bypass. Both-ends-private is NOT
  // enough; both ends must be in ONE declared on-link prefix.
  const crossSubnet = { v: 4, proto: "tcp", src: "192.168.3.2", sport: 40001, dst: "10.0.0.5", dport: 445 };
  const r = analyzeCapture([wgOuter, crossSubnet], LAN);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "non-peer-ipv4-egress");
});

test("full-tunnel GUARD: an IPv6-ULA dest in a DIFFERENT /64 than declared is NOT on-LAN-exempt", () => {
  const otherUla = { v: 6, proto: "udp", src: "fd7f:2561:4e47:746b::ac15", sport: 5060, dst: "fd00:dead:beef::1", dport: 5060 };
  const r = analyzeCapture([wgOuter, otherUla], LAN);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "ipv6-egress-in-full-tunnel");
});

test("full-tunnel GUARD: cleartext DNS to a LAN resolver is STILL a leak even when its subnet is on-LAN — the exemption must NOT open a DNS hole", () => {
  // A Do53 query to a router/Pi-hole is exactly the escape this rig hunts. Declaring 192.168.11.0/24
  // on-LAN must NOT exempt it: DNS is never on-LAN-exempt.
  const cfg = { ...FULL, lanCIDRs: [LAN_V4, "192.168.11.0/24"] };
  const lanDNS = { v: 4, proto: "udp", src: "192.168.3.2", sport: 5000, dst: "192.168.11.2", dport: 53, dns: "tracker.example.com" };
  const r = analyzeCapture([wgOuter, lanDNS], cfg);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "cleartext-dns-not-bootstrap");
});

test("full-tunnel GUARD: a DoT connection (port 853, no QNAME) to an on-LAN resolver is STILL a leak", () => {
  const cfg = { ...FULL, lanCIDRs: [LAN_V4, "192.168.11.0/24"] };
  const lanDoT = { v: 4, proto: "tcp", src: "192.168.3.2", sport: 5001, dst: "192.168.11.2", dport: 853 };
  const r = analyzeCapture([wgOuter, lanDoT], cfg);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "cleartext-dns-not-bootstrap");
});

test("full-tunnel: IKE/IPsec NAT-T to a global host is flagged ipsec-natt, fail-closed WITHOUT a declared ePDG", () => {
  // Real #10: T-Mobile Wi-Fi Calling keepalives 192.168.3.2:4500 → 198.51.100.20:4500 (isakmp-nat-keep-alive).
  const natt = { v: 4, proto: "udp", src: "192.168.3.2", sport: 4500, dst: EPDG, dport: 4500 };
  const r = analyzeCapture([wgOuter, natt], LAN);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "ipsec-natt-os-below-ne");
});

test("full-tunnel: IKE on port 500 to a global host is also the ipsec-natt class", () => {
  const ike = { v: 4, proto: "udp", src: "192.168.3.2", sport: 500, dst: EPDG, dport: 500 };
  const r = analyzeCapture([wgOuter, ike], LAN);
  assert.equal(r.candidateLeaks[0].reason, "ipsec-natt-os-below-ne");
});

test("full-tunnel: IPsec NAT-T to the DECLARED ePDG (--ipsec-endpoint) is acknowledged → not a leak", () => {
  const natt = { v: 4, proto: "udp", src: "192.168.3.2", sport: 4500, dst: EPDG, dport: 4500 };
  const r = analyzeCapture([wgOuter, natt], { ...LAN, ipsecEndpoints: [EPDG] });
  assert.equal(r.candidateLeaks.length, 0);
});

test("full-tunnel GUARD (Codex P1): IPsec-port traffic to a NON-declared endpoint stays flagged even when another ePDG is declared", () => {
  // Any app can send UDP to a controlled :4500 server; the port alone must not acknowledge it. Only
  // the declared ePDG is exempt — a :4500 datagram to a different host is still a candidate leak.
  const evil = { v: 4, proto: "udp", src: "192.168.3.2", sport: 40002, dst: "203.0.113.9", dport: 4500 };
  const r = analyzeCapture([wgOuter, evil], { ...LAN, ipsecEndpoints: [EPDG] });
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "ipsec-natt-os-below-ne");
});

test("split-tunnel: the full-tunnel on-LAN exemption does NOT leak into split — a private-unicast AllowedIPs dest is STILL a leak", () => {
  const cfg = { mode: "split-tunnel", peerIP: FULL.peerIP, peerPort: FULL.peerPort, allowedIPs: ["192.168.50.0/24"], lanCIDRs: [LAN_V4] };
  const untunnelled = { v: 4, proto: "tcp", src: "10.0.0.2", sport: 40000, dst: "192.168.50.9", dport: 445 }; // in AllowedIPs + direct → leak
  const r = analyzeCapture([wgOuter, untunnelled], cfg);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "allowedips-traffic-not-tunnelled");
});

test("full-tunnel GUARD: an inbound datagram from a GLOBAL non-peer host to the phone's address is NOT on-LAN-exempt", () => {
  // The exemption requires BOTH endpoints in the declared prefix. A global source reaching the phone
  // is internet ingress — keying the exemption on the phone's address alone would swallow it.
  const inbound = { v: 4, proto: "udp", src: "203.0.113.7", sport: 4444, dst: "192.168.3.2", dport: 51234 };
  const r = analyzeCapture([wgOuter, inbound], LAN);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "non-peer-ipv4-egress");
});

test("analyzeCapture rejects a malformed --lan-cidr and --ipsec-endpoint before the loop", () => {
  assert.throws(() => analyzeCapture([wgOuter], { ...FULL, lanCIDRs: ["192.168.3.0/33"] }), /invalid --lan-cidr/);
  assert.throws(() => analyzeCapture([wgOuter], { ...FULL, lanCIDRs: ["not-a-cidr"] }), /invalid --lan-cidr/);
  assert.throws(() => analyzeCapture([wgOuter], { ...FULL, ipsecEndpoints: ["198.51.100"] }), /invalid --ipsec-endpoint/);
});

test("dns-only: DoH (443) to a known-resolver IP that isn't configured is a leak", () => {
  // Codex P1: DoH is the common app transport; 443 to a known DoH IP != configured is an escape.
  const cfg = { mode: "dns-only", resolverIPs: ["10.64.0.1"] };
  const doh = { v: 4, proto: "tcp", src: "10.0.0.2", sport: 50001, dst: "1.1.1.1", dport: 443 };
  const r = analyzeCapture([doh], cfg);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "doh-to-unconfigured-resolver");
});

test("dns-only: DoH to the CONFIGURED resolver, and 443 to an ordinary site, are both allowed", () => {
  const cfg = { mode: "dns-only", resolverIPs: ["1.1.1.1"] };
  const configuredDoH = { v: 4, proto: "tcp", src: "10.0.0.2", sport: 50002, dst: "1.1.1.1", dport: 443 };
  const website = { v: 4, proto: "tcp", src: "10.0.0.2", sport: 50003, dst: "142.250.72.14", dport: 443 };
  const r = analyzeCapture([configuredDoH, website], cfg);
  assert.equal(r.candidateLeaks.length, 0);
});

test("evaluateExpect: an unknown explicit --expect value FAILS; omitting it is report-only", () => {
  // Codex P1: a misspelled gate (--expect no-leaks) must not exit 0 over a nonempty candidate set.
  const dirty = { canarySeen: false, candidateLeaks: [{ reason: "non-peer-ipv4-egress" }], allowedCount: 0 };
  assert.equal(evaluateExpect(dirty, "no-leaks").ok, false);
  assert.equal(evaluateExpect(dirty, undefined).ok, true);
  assert.equal(evaluateExpect(dirty, undefined).lines.length, 0);
});

// ---- third review round (Codex, PR #562) -----------------------------------

test("split-tunnel analysis REJECTS an empty AllowedIPs set (config error, not a clean run)", () => {
  // Codex P1: with no protected set, every destination reads intended-direct and a real escape hides.
  assert.throws(
    () => analyzeCapture([], { mode: "split-tunnel", peerIP: FULL.peerIP, peerPort: FULL.peerPort }),
    /allowed-ips|nonempty/,
  );
  // A nonempty set analyzes normally.
  assert.doesNotThrow(
    () => analyzeCapture([], { mode: "split-tunnel", peerIP: FULL.peerIP, peerPort: FULL.peerPort, allowedIPs: ["100.64.0.0/10"] }),
  );
});

test("full-tunnel: a bootstrap DNS query+reply over TCP (truncation fallback) is allowlisted", () => {
  // Codex P2: after a truncated UDP answer the lookup retries over TCP; the TCP reply must be allowed.
  const q = { v: 4, proto: "tcp", src: "10.0.0.2", sport: 51234, dst: "10.0.0.1", dport: 53, dns: "wg.example.net" };
  const reply = { v: 4, proto: "tcp", src: "10.0.0.1", sport: 53, dst: "10.0.0.2", dport: 51234 };
  const r = analyzeCapture([wgOuter, q, reply], FULL);
  assert.equal(r.candidateLeaks.length, 0);
  assert.equal(r.allowedCount, 3);
});

// ---- fourth review round (Codex, PR #562): input validation before analysis ------------------

test("analyzeCapture rejects an empty canary nonce (it would match every DNS packet)", () => {
  assert.throws(() => analyzeCapture([bootstrap], { ...FULL, canaryNonce: "" }), /canary-nonce|nonempty/);
  assert.throws(() => analyzeCapture([bootstrap], { ...FULL, canaryNonce: "   " }), /canary-nonce|nonempty/);
});

test("analyzeCapture rejects an unknown mode BEFORE the loop (empty/noise capture can't certify)", () => {
  assert.throws(() => analyzeCapture([], { mode: "full-tunel" }), /unknown mode/);
  assert.throws(() => analyzeCapture([mdns], { mode: "dns_only", canaryNonce: "x" }), /unknown mode/);
});

test("split-tunnel rejects a malformed AllowedIPs CIDR instead of silently ignoring it", () => {
  const base = { mode: "split-tunnel", peerIP: FULL.peerIP, peerPort: FULL.peerPort };
  assert.throws(() => analyzeCapture([], { ...base, allowedIPs: ["100.64.0.0/10", "192.168.0/16"] }), /invalid --allowed-ips/);
  assert.throws(() => analyzeCapture([], { ...base, allowedIPs: ["300.0.0.0/8"] }), /invalid --allowed-ips/);
  assert.throws(() => analyzeCapture([], { ...base, allowedIPs: [" 192.168.0.0/16"] }), /invalid --allowed-ips/);
  assert.doesNotThrow(() => analyzeCapture([], { ...base, allowedIPs: ["100.64.0.0/10", "192.168.0.0/16"] }));
});

// ---- fifth review round (Codex, PR #562) -----------------------------------

test("dns-only: a query to the endpoint hostname at an unconfigured resolver is STILL a leak", () => {
  // Codex P1: the bootstrap exemption is full-tunnel-only; dns-only has no endpoint to bootstrap.
  const cfg = { mode: "dns-only", resolverIPs: ["10.64.0.1"], endpointHost: "wg.example.net" };
  const q = { v: 4, proto: "udp", src: "10.0.0.2", sport: 5000, dst: "8.8.8.8", dport: 53, dns: "wg.example.net" };
  const r = analyzeCapture([q], cfg);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "dns-to-unconfigured-resolver");
});

test("full-tunnel: a globally-scoped IPv6 multicast (ff0e::) is a leak, not local noise", () => {
  // Codex P2: IPv6 multicast scope is in the address; only interface/link-local (1/2) is noise.
  const g = { v: 6, proto: "udp", src: "2001:db8::2", sport: 5000, dst: "ff0e::1234", dport: 5000 };
  const r = analyzeCapture([wgOuter, g], FULL);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "ipv6-egress-in-full-tunnel");
});

test("full-tunnel: link-local IPv6 multicast (ff02::) stays local noise", () => {
  const ll = { v: 6, proto: "udp", src: "fe80::2", sport: 5353, dst: "ff02::fb", dport: 5353 };
  const r = analyzeCapture([wgOuter, ll], FULL);
  assert.equal(r.candidateLeaks.length, 0);
});

test("full-tunnel: routable IPv4 multicast (224.0.1.x) is a leak; link-local 224.0.0.x is noise", () => {
  const routable = { v: 4, proto: "udp", src: "10.0.0.2", sport: 5000, dst: "224.0.1.1", dport: 5000 };
  const mdns2 = { v: 4, proto: "udp", src: "10.0.0.2", sport: 5353, dst: "224.0.0.251", dport: 5353 };
  const r = analyzeCapture([wgOuter, routable, mdns2], FULL);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "non-peer-ipv4-egress");
});

// ---- sixth review round (Codex, PR #562) -----------------------------------

test("a cleartext DNS query to an unconfigured LINK-LOCAL resolver is NOT exempted as noise", () => {
  // Codex P1: DNS-port traffic must reach the mode classifier even to a link-local endpoint.
  const llDNS6 = { v: 6, proto: "udp", src: "fe80::2", sport: 5000, dst: "fe80::1", dport: 53, dns: "tracker.example.com" };
  assert.equal(analyzeCapture([wgOuter, llDNS6], FULL).candidateLeaks.length, 1, "full-tunnel: only the bootstrap is allowed");

  const llDNS4 = { v: 4, proto: "udp", src: "10.0.0.2", sport: 5000, dst: "169.254.0.1", dport: 53, dns: "tracker.example.com" };
  const rDns = analyzeCapture([llDNS4], { mode: "dns-only", resolverIPs: ["10.64.0.1"] });
  assert.equal(rDns.candidateLeaks.length, 1);
  assert.equal(rDns.candidateLeaks[0].reason, "dns-to-unconfigured-resolver");
});

test("mDNS to a link-local multicast address is still exempted noise (its own port, not 53/853)", () => {
  const m = { v: 4, proto: "udp", src: "10.0.0.2", sport: 5353, dst: "224.0.0.251", dport: 5353 };
  assert.equal(analyzeCapture([wgOuter, m], FULL).candidateLeaks.length, 0);
});

// ---- seventh review round (Codex, PR #562) ---------------------------------

test("full-tunnel: a link-local SOURCE with a GLOBAL destination is a leak (source locality doesn't exempt)", () => {
  // Codex P1: exemption is by DESTINATION scope; a global dest from an fe80 source is real egress.
  const p = { v: 6, proto: "udp", src: "fe80::2", sport: 5000, dst: "2606:4700:4700::1111", dport: 5000 };
  const r = analyzeCapture([wgOuter, p], FULL);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "ipv6-egress-in-full-tunnel");
});

test("analyzeCapture reports livenessObserved: WG-outer for full/split, DNS for dns-only", () => {
  assert.equal(analyzeCapture([wgOuter], FULL).livenessObserved, true);
  assert.equal(analyzeCapture([mdns], FULL).livenessObserved, false); // noise only → no protected traffic seen
  const dnsCfg = { mode: "dns-only", resolverIPs: ["10.64.0.1"] };
  const dnsPkt = { v: 4, proto: "udp", src: "10.0.0.2", sport: 5000, dst: "10.64.0.1", dport: 53, dns: "a.com" };
  const httpsOnly = { v: 4, proto: "tcp", src: "10.0.0.2", sport: 5000, dst: "1.2.3.4", dport: 443 };
  assert.equal(analyzeCapture([dnsPkt], dnsCfg).livenessObserved, true);
  assert.equal(analyzeCapture([httpsOnly], dnsCfg).livenessObserved, false);
});

test("evaluateExpect: a no-leak run with NO liveness marker fails (empty/blind/stopped capture)", () => {
  // Codex P1: an empty capture has no candidates for the trivial reason that it observed nothing.
  const blind = { canarySeen: false, candidateLeaks: [], allowedCount: 0, analyzedPacketCount: 0, livenessObserved: false };
  const v = evaluateExpect(blind, "no-leak");
  assert.equal(v.ok, false);
  assert.match(v.lines.join("\n"), /liveness|blind|empty/i);
  // A candidate leak still takes priority over the liveness message.
  const withLeak = { ...blind, candidateLeaks: [{ reason: "non-peer-ipv4-egress", proto: "tcp", dst: "8.8.8.8" }] };
  assert.equal(evaluateExpect(withLeak, "no-leak").ok, false);
  assert.match(evaluateExpect(withLeak, "no-leak").lines.join("\n"), /candidate leak/);
});

test("full-tunnel: inbound UDP from the peer IP on a NON-WG source port is a leak", () => {
  // Kilo: the inbound WG predicate must pin the source port too, not just the peer IP.
  const notWG = { v: 4, proto: "udp", src: FULL.peerIP, sport: 12345, dst: "10.0.0.2", dport: 51234 };
  const r = analyzeCapture([notWG], FULL);
  assert.equal(r.candidateLeaks.length, 1);
  assert.equal(r.candidateLeaks[0].reason, "non-peer-ipv4-egress");
});

test("full-tunnel: the inbound WG reply from the peer endpoint port IS allowlisted", () => {
  const wgIn = { v: 4, proto: "udp", src: FULL.peerIP, sport: FULL.peerPort, dst: "10.0.0.2", dport: 51234 };
  const r = analyzeCapture([wgIn], FULL);
  assert.equal(r.candidateLeaks.length, 0);
  assert.equal(r.allowedCount, 1);
});

test("evaluateExpect: a canary present during a no-leak run FAILS (emitter left active)", () => {
  // Codex P1 / Kilo: --expect no-leak must NOT silently drop planted-canary candidates.
  const result = { canarySeen: true, candidateLeaks: [{ reason: "planted-canary", proto: "udp", src: "10.0.0.2", dst: "9.9.9.9" }], allowedCount: 1 };
  const v = evaluateExpect(result, "no-leak");
  assert.equal(v.ok, false);
  assert.match(v.lines.join("\n"), /canary emitter still ACTIVE/);
});

test("evaluateExpect: clean passes no-leak; blind canary run fails; seen canary passes canary", () => {
  assert.equal(evaluateExpect({ canarySeen: false, candidateLeaks: [], allowedCount: 5, livenessObserved: true }, "no-leak").ok, true);
  assert.equal(evaluateExpect({ canarySeen: false, candidateLeaks: [], allowedCount: 5 }, "canary").ok, false);
  assert.equal(evaluateExpect({ canarySeen: true, candidateLeaks: [{ reason: "planted-canary" }], allowedCount: 0 }, "canary").ok, true);
});

test("parseTcpdump: a portless ICMPv6 line keeps both addresses and has no ports", () => {
  // Codex P2: a naive ".<last group> is the port" split dropped/truncated portless packets.
  const text = "1699999999.500000 IP6 2001:db8::2 > 2606:4700:4700::1111: ICMP6, echo request, seq 1, length 64";
  const pkts = parseTcpdump(text);
  assert.equal(pkts.length, 1);
  assert.equal(pkts[0].v, 6);
  assert.equal(pkts[0].proto, "other");
  assert.equal(pkts[0].src, "2001:db8::2");
  assert.equal(pkts[0].dst, "2606:4700:4700::1111");
  assert.equal(pkts[0].sport, undefined);
  assert.equal(pkts[0].dport, undefined);
});

test("parseTcpdump: a portless IPv4 ICMP line does not truncate the addresses into ports", () => {
  const text = "1699999999.600000 IP 10.0.0.2 > 8.8.8.8: ICMP echo request, id 1, seq 1, length 64";
  const pkts = parseTcpdump(text);
  assert.equal(pkts.length, 1);
  assert.equal(pkts[0].v, 4);
  assert.equal(pkts[0].proto, "other");
  assert.equal(pkts[0].src, "10.0.0.2");
  assert.equal(pkts[0].dst, "8.8.8.8");
  assert.equal(pkts[0].dport, undefined);
});

// ---- S-5: the expectation gate cannot be silently disarmed -------------------

test("parseArgs: a dangling --expect is a usage error, not report-only", () => {
  // `--expect $EXPECT` with an unset variable used to leave `expect` undefined, which
  // `evaluateExpect` treats as report-only — turning a must-fail gate green (security review S-5).
  assert.throws(
    () => parseArgs(["--mode", "full-tunnel", "--json", "c.json", "--expect"]),
    /--expect requires a value: canary \| no-leak/
  );
});

test("parseArgs: an EMPTY --expect fails through the same value-missing check", () => {
  // `--expect ""` is the shell-expansion shape of the same mistake. It must fail for the SAME
  // reason as the dangling flag, so a refactor cannot keep one green while the other regresses
  // through an incidental path.
  assert.throws(
    () => parseArgs(["--mode", "full-tunnel", "--json", "c.json", "--expect", ""]),
    /--expect requires a value: canary \| no-leak/
  );
});

test("parseArgs: omitting --expect is still report-only", () => {
  const { expect } = parseArgs(["--mode", "full-tunnel", "--json", "c.json"]);
  assert.equal(expect, undefined);
  assert.deepEqual(evaluateExpect({ candidates: [], canarySeen: false }, expect), { ok: true, lines: [] });
});

test("parseArgs: a valid --expect still parses", () => {
  assert.equal(parseArgs(["--mode", "full-tunnel", "--json", "c.json", "--expect", "no-leak"]).expect, "no-leak");
  assert.equal(parseArgs(["--mode", "full-tunnel", "--json", "c.json", "--expect", "canary"]).expect, "canary");
});
