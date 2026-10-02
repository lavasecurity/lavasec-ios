// LavaSec WireGuard engine core — C ABI (production; supersedes lavasec_wg_spike.h).
// Rust twin: ../src/lib.rs — keep the two in sync in the same diff.
// Plan: lavasec-infra plans/2026-07-22-vpn-upstream-chaining-implementation-plan.md (D4/D5).
//
// CONTRACTS (authoritative prose lives in the Rust module docs):
// - Queue confinement: all calls for one session on one serial queue (never
//   dnsStateQueue; INV-QUEUE-1). The internal Mutex is a UB backstop only.
// - Non-overlapping buffers: src and dst for a call MUST NOT overlap (Rust
//   forms &[u8] over src and &mut [u8] over dst at once — aliasing is UB, and
//   the engine memcpys src->dst). Do not encrypt/decrypt in place. A detected
//   overlap returns LAVA_WG_ERR_INVALID_ARGUMENT, but do not rely on that.
// - Uniform data-path buffers: encapsulate/decapsulate dst MUST be at least
//   LAVA_WG_MAX_DATAGRAM, and an encapsulate src at most LAVA_WG_MAX_IP_PACKET.
//   This is what makes the engine's panic paths unreachable: a decapsulate
//   DRAIN call (empty src) re-encapsulates a queued OUTBOUND packet into dst,
//   whose size is unrelated to the inbound datagram — so a per-call
//   dst >= src_len bound is NOT enough. Phase-3 uses one LAVA_WG_MAX_DATAGRAM
//   buffer per direction, satisfying this for free.
// - Decapsulate drain: after a WRITE_TO_NETWORK result from
//   lava_wg_decapsulate, send the datagram, then call again with an empty
//   source until it stops returning WRITE_TO_NETWORK (flushes packets queued
//   before the session came up, plus queued handshake replies).
// - Panic posture: release builds abort on panic; the engine panics (never
//   errors) on an undersized dst in BOTH directions incl. the drain
//   re-encapsulation. The LAVA_WG_MAX_DATAGRAM rule closes every such path
//   here, so an abort can only be a genuine engine bug, not a sizing bug.
// - Allocation: zero-alloc on the established data path (caller buffers, in
//   place). Exception: while no session is current (pre-first-handshake, or
//   briefly after expiry) encapsulate queues a bounded heap copy per packet
//   (MAX 256), flushed by the drain — Phase-3's memory budget must allow it.

#ifndef LAVASEC_WIREGUARD_CORE_H
#define LAVASEC_WIREGUARD_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Op codes (>= 0) — what the call produced in dst.
#define LAVA_WG_OP_NONE 0
#define LAVA_WG_OP_WRITE_TO_NETWORK 1
#define LAVA_WG_OP_WRITE_TO_TUNNEL_V4 2
#define LAVA_WG_OP_WRITE_TO_TUNNEL_V6 3

// Error codes (< 0). PROTOCOL is per-packet (drop and continue);
// CONNECTION_EXPIRED is the Phase-3 reconnect escalation signal (raised only by
// lava_wg_tick). INVALID_ARGUMENT also covers a detected src/dst overlap.
#define LAVA_WG_ERR_INVALID_ARGUMENT (-1)
#define LAVA_WG_ERR_DESTINATION_BUFFER_TOO_SMALL (-2)
#define LAVA_WG_ERR_NO_CURRENT_SESSION (-3)
#define LAVA_WG_ERR_UNDER_LOAD (-4)
#define LAVA_WG_ERR_PROTOCOL (-5)
#define LAVA_WG_ERR_CONNECTION_EXPIRED (-6)
#define LAVA_WG_ERR_INTERNAL (-7)
#define LAVA_WG_ERR_PACKET_TOO_LARGE (-8)

// Sizing. encapsulate: src_len <= LAVA_WG_MAX_IP_PACKET and dst_cap >=
// LAVA_WG_MAX_DATAGRAM. decapsulate: dst_cap >= LAVA_WG_MAX_DATAGRAM (mandatory
// — covers drain re-encapsulation). tick/force_handshake: dst_cap >=
// LAVA_WG_MIN_CONTROL_DST. LAVA_WG_MAX_DATAGRAM == MAX_IP_PACKET + DATA_OVERHEAD.
#define LAVA_WG_DATA_OVERHEAD 32u
#define LAVA_WG_MIN_CONTROL_DST 148u
#define LAVA_WG_MAX_IP_PACKET 1500u
#define LAVA_WG_MAX_DATAGRAM (LAVA_WG_MAX_IP_PACKET + LAVA_WG_DATA_OVERHEAD)

// Session-health snapshot (D1 latch monitoring, QA). Field layout matches the
// #[repr(C)] Rust struct: 8+8+8+4+4 bytes, no padding.
typedef struct LavaWGStats {
  int64_t time_since_last_handshake_ms; // -1 = no current established session
  uint64_t tx_bytes;
  uint64_t rx_bytes;
  float estimated_loss;   // [0, 1]
  int32_t estimated_rtt_ms; // -1 = unknown
} LavaWGStats;

// Keys are raw 32-byte X25519 (caller decodes base64). preshared_key may be
// NULL. keepalive_seconds == 0 disables persistent keepalive. Returns NULL on
// invalid input. Key buffers are copied, never retained — zero your copies
// after this returns (the engine scrubs its own private- and preshared-key
// stack copies).
void *lava_wg_session_new(const uint8_t *private_key,
                          const uint8_t *peer_public_key,
                          const uint8_t *preshared_key,
                          uint16_t keepalive_seconds,
                          uint32_t index);

// NULL is a no-op. Must be the last call for the pointer.
void lava_wg_session_free(void *session);

// Encrypt one outbound IP packet (src_len == 0 emits a keepalive).
int32_t lava_wg_encapsulate(void *session,
                            const uint8_t *src, uint32_t src_len,
                            uint8_t *dst, uint32_t dst_cap,
                            uint32_t *out_len);

// Decrypt one inbound datagram (src_len == 0 drains queued packets/replies).
// For WRITE_TO_TUNNEL_* results, out_src_addr (16 writable bytes) receives the
// inner packet's source IP and *out_src_addr_len its length (4 or 16) — for
// Phase-3 allowed-IPs enforcement. Pass both address params NULL to skip, or
// both non-NULL; mixing is LAVA_WG_ERR_INVALID_ARGUMENT.
// src_addr/src_addr_len are the UDP peer the datagram arrived FROM: 0 bytes for
// "unknown", or 4/16 for IPv4/IPv6. SUPPLY IT WHENEVER YOU HAVE IT — it is what
// boringtun's DoS mitigation runs on. With a zero length the engine cannot issue
// the cookie challenge that proves address ownership and short-circuits to a hard
// UnderLoad error, which a peer can drive remotely by replaying handshake packets
// at >10/sec until the tunnel surrenders to DNS-only. Zero is legal (a caller may
// genuinely not know) but it is not the safe default.
int32_t lava_wg_decapsulate(void *session,
                            const uint8_t *src, uint32_t src_len,
                            const uint8_t *src_addr, uint32_t src_addr_len,
                            uint8_t *dst, uint32_t dst_cap,
                            uint32_t *out_len,
                            uint8_t *out_src_addr,
                            uint32_t *out_src_addr_len);

// Drive timers (retries, keepalive, rekey). Call ~every 250 ms; send any
// WRITE_TO_NETWORK output to the peer; CONNECTION_EXPIRED = reconnect signal.
int32_t lava_wg_tick(void *session,
                     uint8_t *dst, uint32_t dst_cap,
                     uint32_t *out_len);

// Force a handshake initiation (session start).
int32_t lava_wg_force_handshake(void *session,
                                uint8_t *dst, uint32_t dst_cap,
                                uint32_t *out_len);

// Fill *out_stats; returns LAVA_WG_OP_NONE or a negative error code.
int32_t lava_wg_session_stats(void *session, LavaWGStats *out_stats);

#ifdef __cplusplus
}
#endif

#endif // LAVASEC_WIREGUARD_CORE_H
