/* THROWAWAY SPIKE — Phase 0 de-risking for chained VPN upstream.
 * C header for the boringtun FFI static lib. Mirrors ThirdParty/wg-spike/src/lib.rs.
 * Consumed by the throwaway tunnel branch via a bridging header (or @_silgen_name,
 * the DeviceDNSResolver.c precedent). Not the MVP UniFFI surface — deliberately raw. */
#ifndef LAVASEC_WG_SPIKE_H
#define LAVASEC_WG_SPIKE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* op codes returned by the transform calls */
#define WG_SPIKE_OP_NONE 0
#define WG_SPIKE_OP_WRITE_TO_NETWORK 1   /* send the produced bytes to the WG peer   */
#define WG_SPIKE_OP_WRITE_TO_TUNNEL_V4 2 /* write the produced bytes to packetFlow   */
#define WG_SPIKE_OP_WRITE_TO_TUNNEL_V6 3
#define WG_SPIKE_OP_ERROR (-1)

/* Create a session. private_key / peer_public_key are raw 32-byte X25519 keys.
 * preshared_key is 32 bytes or NULL. Returns NULL on failure. */
void *wg_spike_session_new(const uint8_t *private_key,
                           const uint8_t *peer_public_key,
                           const uint8_t *preshared_key,
                           uint16_t keepalive_seconds,
                           uint32_t index);

void wg_spike_session_free(void *session);

/* Encrypt one outbound IP packet. dst must be >= src_len + 32 bytes. */
int32_t wg_spike_encapsulate(void *session, const uint8_t *src, uint32_t src_len,
                             uint8_t *dst, uint32_t dst_cap, uint32_t *out_len);

/* Decrypt one inbound datagram. Per boringtun: on WRITE_TO_NETWORK, send and repeat
 * with src_len == 0 until the op is no longer WRITE_TO_NETWORK. */
int32_t wg_spike_decapsulate(void *session, const uint8_t *src, uint32_t src_len,
                             uint8_t *dst, uint32_t dst_cap, uint32_t *out_len);

/* Drive timers (~every 250 ms). WRITE_TO_NETWORK output goes to the peer. */
int32_t wg_spike_tick(void *session, uint8_t *dst, uint32_t dst_cap, uint32_t *out_len);

/* Force a handshake initiation at session start. */
int32_t wg_spike_force_handshake(void *session, uint8_t *dst, uint32_t dst_cap,
                                 uint32_t *out_len);

#ifdef __cplusplus
}
#endif

#endif /* LAVASEC_WG_SPIKE_H */
