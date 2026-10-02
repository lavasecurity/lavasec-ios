//! LavaSec WireGuard engine core — production C ABI over boringtun's crypto
//! core (`Tunn`: Noise handshake, encapsulate/decapsulate, timers/rekey).
//! Consumed by the iOS packet tunnel (Phase 3) and by the Swift package's
//! macOS test slice (`swift test` drives this exact ABI).
//! Plan: lavasec-infra plans/2026-07-22-vpn-upstream-chaining-implementation-plan.md (D4/D5).
//! Header twin: include/lavasec_wireguard_core.h — keep the two in sync in the
//! same diff (pinned by a Swift source-introspection test once the SPM target
//! lands).
//!
//! ## Contracts the caller must uphold (mirrored in the header)
//!
//! - **Queue confinement.** A session has no internal concurrency design; the
//!   caller confines all calls for one session to one serial queue (the
//!   tunnel's WG queue — never `dnsStateQueue`, INV-QUEUE-1). The internal
//!   Mutex is a UB backstop, not a license to share.
//! - **Non-overlapping buffers.** `src` and `dst` for a call must not overlap.
//!   Rust materializes a `&[u8]` over `src` and a `&mut [u8]` over `dst`
//!   simultaneously; aliasing them is undefined behavior (and boringtun copies
//!   src→dst with `copy_from_slice` in both directions). The ABI rejects an
//!   overlap it can detect (`LAVA_WG_ERR_INVALID_ARGUMENT`), but the caller
//!   must not rely on that as a feature — do not decrypt/encrypt in place.
//! - **Uniform data-path buffers.** `dst` for `encapsulate`/`decapsulate` must
//!   be at least `LAVA_WG_MAX_DATAGRAM` bytes, and an `encapsulate` `src` must
//!   be at most `LAVA_WG_MAX_IP_PACKET` bytes. This single rule is what makes
//!   the engine's panic paths unreachable (see below): a `decapsulate` drain
//!   call re-encapsulates a queued outbound packet whose size is unrelated to
//!   the (empty) inbound datagram, so a per-call `dst >= src_len` bound is NOT
//!   enough — the buffer must always hold a full re-encapsulated packet.
//!   Phase-3 uses one `LAVA_WG_MAX_DATAGRAM`-sized scratch buffer per
//!   direction, which satisfies this for free.
//! - **Decapsulate drain.** When `lava_wg_decapsulate` returns
//!   `WRITE_TO_NETWORK`, send that datagram, then call it again with an EMPTY
//!   source until it stops returning `WRITE_TO_NETWORK` — that is how the
//!   engine flushes packets it queued before the session came up, plus queued
//!   handshake replies (boringtun's documented requirement).
//! - **Panic posture.** Release builds use `panic = "abort"`. The vendored
//!   engine `panic!`s (never errors) when a destination buffer is too small —
//!   in BOTH directions, including the drain re-encapsulation. The uniform
//!   `LAVA_WG_MAX_DATAGRAM` requirement above closes every one of those paths
//!   at the boundary, so an abort can only come from a genuine engine bug, not
//!   a caller sizing bug. (pinned: drain_with_undersized_buffer_is_error,
//!   undersized_dst_is_an_error_never_a_panic.)
//!
//! ## Allocation
//!
//! On the established data path the engine does not allocate at this boundary
//! (caller-owned buffers, in place). The one exception: while no session is
//! current — before the first handshake completes, or briefly after a session
//! expires (REJECT_AFTER_TIME) mid-flow — `encapsulate` queues a heap copy of
//! each outbound packet (bounded: MAX_QUEUE_DEPTH = 256 packets), which the
//! drain flushes and frees. Phase-3's INV-MEM-1 budget must account for that
//! bounded transient (~384 KB at a 1500-byte MTU), not assume strict
//! zero-alloc.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::os::raw::c_void;
use std::sync::Mutex;

use boringtun::noise::errors::WireGuardError;
use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};

// ---------------------------------------------------------------------------
// Stable ABI constants (header twin: lavasec_wireguard_core.h)
// ---------------------------------------------------------------------------

/// Nothing produced; state advanced. (Also: drain complete.)
pub const LAVA_WG_OP_NONE: i32 = 0;
/// `dst` holds a datagram that must be sent to the peer.
pub const LAVA_WG_OP_WRITE_TO_NETWORK: i32 = 1;
/// `dst` holds a decrypted IPv4 packet for the tunnel.
pub const LAVA_WG_OP_WRITE_TO_TUNNEL_V4: i32 = 2;
/// `dst` holds a decrypted IPv6 packet for the tunnel (Phase-3 policy: claim-and-drop).
pub const LAVA_WG_OP_WRITE_TO_TUNNEL_V6: i32 = 3;

/// Null/invalid pointer or argument combination (incl. detected src/dst overlap).
/// Never a wire condition.
pub const LAVA_WG_ERR_INVALID_ARGUMENT: i32 = -1;
/// `dst_cap` below the documented minimum for this call. Never a wire condition.
pub const LAVA_WG_ERR_DESTINATION_BUFFER_TOO_SMALL: i32 = -2;
/// No established session for a data-path call (handshake not complete/expired mid-flow).
pub const LAVA_WG_ERR_NO_CURRENT_SESSION: i32 = -3;
/// Peer/rate-limiter under load; retry after backoff.
pub const LAVA_WG_ERR_UNDER_LOAD: i32 = -4;
/// Packet failed parse/authentication (wrong key, MAC, counter, type, …).
/// One malformed/hostile datagram — drop it and continue; not a session-fatal signal.
pub const LAVA_WG_ERR_PROTOCOL: i32 = -5;
/// The WG session expired (REJECT_AFTER_TIME). Surfaced by `lava_wg_tick` (the
/// engine raises `ConnectionExpired` only from `update_timers`); Phase-3
/// reconnect logic treats it as its escalation signal (LAV-80 class: escalate
/// on rejected/expired, don't spin).
pub const LAVA_WG_ERR_CONNECTION_EXPIRED: i32 = -6;
/// Engine-internal failure (e.g. poisoned lock after a caller-side panic).
pub const LAVA_WG_ERR_INTERNAL: i32 = -7;
/// `encapsulate` `src_len` exceeds `LAVA_WG_MAX_IP_PACKET`. Rejecting oversize
/// packets at the boundary is what bounds the engine's queued-packet size, so
/// a later drain can never produce a packet that overflows `dst`.
pub const LAVA_WG_ERR_PACKET_TOO_LARGE: i32 = -8;

/// WG transport overhead: 4 type + 4 receiver + 8 counter + 16 AEAD tag.
/// (Vendored engine's `DATA_OVERHEAD_SZ`; pinned by `abi_overhead_matches_engine`.)
pub const LAVA_WG_DATA_OVERHEAD: u32 = 32;
/// Largest control message (handshake initiation = 148 bytes). Every `dst`
/// passed to tick/force-handshake must hold at least this.
/// (pinned: force_handshake_fills_exactly_the_control_minimum.)
pub const LAVA_WG_MIN_CONTROL_DST: u32 = 148;
/// Largest inner IP packet the caller may hand to `encapsulate`. Phase-3
/// configures the tunnel utun MTU at or below this, so packetFlow never yields
/// a larger packet; oversize input is rejected (`LAVA_WG_ERR_PACKET_TOO_LARGE`)
/// rather than queued, keeping every queued packet ≤ this bound.
pub const LAVA_WG_MAX_IP_PACKET: u32 = 1500;

/// The largest transport counter we will hand to the engine.
///
/// `2^64 - 2^13 - 1`, the WireGuard specification's `REJECT_AFTER_MESSAGES`. The vendored
/// boringtun 0.7.1 does NOT enforce it: every limit in `noise/timers.rs` is a `Duration`, and
/// `Session::receive_packet_data` validates only the receiver index, the replay window and the
/// AEAD tag. Verified 2026-07-30 — the identifier does not appear anywhere in the vendored crate.
///
/// The send side is unreachable and is NOT why this exists: our own counter starts at zero per
/// session and `REJECT_AFTER_TIME` retires it after 180 s, so wrapping would take order 10^17
/// packets per second.
///
/// The RECEIVE side is the reason. `noise/session.rs` does unchecked `u64` arithmetic on a
/// PEER-SUPPLIED counter — `counter + N_BITS < self.next`, then `self.next = counter + 1` — and
/// the release profile sets `panic = "abort"` but not `overflow-checks`, so a counter near
/// `u64::MAX` wraps rather than trapping. `will_accept`'s `if counter >= self.next` then admits
/// everything and the anti-replay window is neutralised for the rest of that session: up to 180
/// seconds. The specification's value is chosen so that `counter + N_BITS` cannot overflow,
/// which is what makes enforcing it here sufficient rather than merely helpful.
///
/// Reaching it needs the session key, so this is the malicious-or-compromised-upstream case, not
/// an off-path attacker. That is the threat model of a client claiming `0.0.0.0/0`: all of its
/// traffic crosses one peer, so a replay bypass there covers the whole tunnel rather than a
/// subset of it.
///
/// NARROWER THAN IT FIRST LOOKS, and the narrowing is worth stating precisely because it is the
/// kind of thing that gets rediscovered as a rebuttal. The poison only lands while
/// `self.next <= N_BITS - 1`: once the session is past its first `N_BITS` packets,
/// `counter + N_BITS` wraps to a value BELOW `self.next` and the packet is refused as
/// `InvalidCounter` on its own. So the reachable window is roughly the first 1023 counters of
/// each session — but sessions rekey on a ~120 s wall clock, so a hostile peer gets a fresh
/// window every rekey, and one successful poison lasts until `REJECT_AFTER_TIME` retires the
/// session 180 s later (review of infra#151).
///
/// Enforced HERE rather than in the engine because the vendored crate cannot be patched without
/// breaking the drift gate's byte-compare against the committed xcframework. If an engine ever
/// enforces it this becomes redundant rather than wrong.
pub const LAVA_WG_REJECT_AFTER_MESSAGES: u64 = u64::MAX - (1 << 13);

/// Byte offset of the counter in a transport datagram.
///
/// WireGuard whitepaper section 5.4.6, "Transport Data Messages": the layout is
/// `type(1) || reserved(3) || receiver_index(4) || counter(8) || packet(...)`, all little-endian.
/// Cited rather than left as a magic 8/16 for the same reason `LAVA_WG_DATA_OVERHEAD` carries its
/// engine reference: a reader without the message layout open cannot check it otherwise.
const TRANSPORT_COUNTER_OFFSET: usize = 8;
/// Smallest type-4 datagram carrying a complete counter field.
const TRANSPORT_HEADER_LEN: usize = 16;
/// WireGuard message type for a transport data packet.
const TRANSPORT_DATA_TYPE: u8 = 4;
/// Required size for any data-path `dst` (`encapsulate`/`decapsulate`): a full
/// re-encapsulated packet. `= LAVA_WG_MAX_IP_PACKET + LAVA_WG_DATA_OVERHEAD`.
/// (pinned: drain_with_undersized_buffer_is_error.)
pub const LAVA_WG_MAX_DATAGRAM: u32 = LAVA_WG_MAX_IP_PACKET + LAVA_WG_DATA_OVERHEAD;

/// Snapshot of session health for D1 latch health-monitoring and QA.
/// Layout is fixed (8+8+8+4+4 bytes, no padding); header twin must match.
#[repr(C)]
pub struct LavaWGStats {
    /// Milliseconds since the last completed handshake; -1 if there is no
    /// current established session (never completed, OR expired since).
    pub time_since_last_handshake_ms: i64,
    /// Plaintext bytes accepted for encapsulation since session creation.
    pub tx_bytes: u64,
    /// Plaintext bytes produced by decapsulation since session creation.
    pub rx_bytes: u64,
    /// Engine loss estimate in [0, 1].
    pub estimated_loss: f32,
    /// Engine RTT estimate in ms; -1 if unknown.
    pub estimated_rtt_ms: i32,
}

struct Session {
    tunn: Mutex<Tunn>,
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

/// Best-effort scrub of a stack key copy. `write_volatile` keeps the zeroing
/// from being optimized away; this is defense-in-depth (the authoritative key
/// lifetime is the caller's, and dalek's `StaticSecret` zeroizes on drop — but
/// the preshared key is a bare array with no such guarantee, so it needs this).
fn zero_key(bytes: &mut [u8; 32]) {
    for b in bytes.iter_mut() {
        // SAFETY: writing through a valid &mut.
        unsafe { std::ptr::write_volatile(b, 0) };
    }
}

fn key_bytes(ptr: *const u8) -> Option<[u8; 32]> {
    if ptr.is_null() {
        return None;
    }
    let mut bytes = [0u8; 32];
    // SAFETY: caller passes a 32-byte key buffer; null was rejected above.
    unsafe { std::ptr::copy_nonoverlapping(ptr, bytes.as_mut_ptr(), 32) };
    Some(bytes)
}

/// True if the byte range `[a, a+a_len)` overlaps `[b, b+b_len)`. Pointer
/// arithmetic as integers so no invalid references are formed.
/// Whether `packet` is a transport datagram whose counter is at or above the specification's
/// `REJECT_AFTER_MESSAGES`.
///
/// Only type-4 datagrams carry a counter; handshake messages have no such field and a
/// length-based read on one would be reading the wrong bytes.
///
/// A datagram too short to hold a counter is NOT rejected here. The engine's own length handling
/// owns that case, and duplicating it would put two layers in charge of deciding what a runt
/// packet is.
fn is_transport_counter_out_of_range(packet: &[u8]) -> bool {
    if packet.len() < TRANSPORT_HEADER_LEN || packet[0] != TRANSPORT_DATA_TYPE {
        return false;
    }
    let mut counter = [0u8; 8];
    counter.copy_from_slice(&packet[TRANSPORT_COUNTER_OFFSET..TRANSPORT_HEADER_LEN]);
    u64::from_le_bytes(counter) >= LAVA_WG_REJECT_AFTER_MESSAGES
}

fn ranges_overlap(a: *const u8, a_len: u32, b: *const u8, b_len: u32) -> bool {
    if a_len == 0 || b_len == 0 {
        return false;
    }
    let (a0, a1) = (a as usize, a as usize + a_len as usize);
    let (b0, b1) = (b as usize, b as usize + b_len as usize);
    a0 < b1 && b0 < a1
}

fn error_code(err: &WireGuardError) -> i32 {
    match err {
        WireGuardError::DestinationBufferTooSmall => LAVA_WG_ERR_DESTINATION_BUFFER_TOO_SMALL,
        WireGuardError::NoCurrentSession => LAVA_WG_ERR_NO_CURRENT_SESSION,
        WireGuardError::UnderLoad => LAVA_WG_ERR_UNDER_LOAD,
        WireGuardError::ConnectionExpired => LAVA_WG_ERR_CONNECTION_EXPIRED,
        WireGuardError::LockFailed => LAVA_WG_ERR_INTERNAL,
        // Everything else is a per-packet parse/auth failure: drop and continue.
        _ => LAVA_WG_ERR_PROTOCOL,
    }
}

/// Classify one TunnResult into (op-code, produced-length), copying the inner
/// packet's source address out for WriteToTunnel results when the caller asked
/// for it. Consumes the borrowed slice before returning — nothing escapes.
/// Decode the caller's peer address for boringtun's rate limiter.
///
/// `len` is 0 (address unknown), 4 (IPv4) or 16 (IPv6) — the same encoding the
/// `out_src_addr`/`out_src_addr_len` pair already uses in the other direction, so
/// there is one convention at this boundary rather than two.
///
/// Passing 0 is legal and means `None`, which is what a caller that genuinely does
/// not know the address must send. It is NOT the safe default: see the note on
/// `lava_wg_decapsulate` about what `None` costs.
///
/// # Safety
/// `ptr` points to `len` readable bytes when `len` is non-zero.
unsafe fn decode_peer_addr(ptr: *const u8, len: u32) -> Result<Option<IpAddr>, i32> {
    match len {
        0 => Ok(None),
        4 => {
            if ptr.is_null() {
                return Err(LAVA_WG_ERR_INVALID_ARGUMENT);
            }
            let mut octets = [0u8; 4];
            // SAFETY: non-null with 4 readable bytes per the caller contract.
            unsafe { std::ptr::copy_nonoverlapping(ptr, octets.as_mut_ptr(), 4) };
            Ok(Some(IpAddr::V4(Ipv4Addr::from(octets))))
        }
        16 => {
            if ptr.is_null() {
                return Err(LAVA_WG_ERR_INVALID_ARGUMENT);
            }
            let mut octets = [0u8; 16];
            // SAFETY: non-null with 16 readable bytes per the caller contract.
            unsafe { std::ptr::copy_nonoverlapping(ptr, octets.as_mut_ptr(), 16) };
            Ok(Some(IpAddr::V6(Ipv6Addr::from(octets))))
        }
        // A length we do not recognize is a caller bug, and guessing at it would feed
        // the rate limiter a wrong address — worse than admitting we have none.
        _ => Err(LAVA_WG_ERR_INVALID_ARGUMENT),
    }
}

fn classify(result: TunnResult, out_src_addr: *mut u8, out_src_addr_len: *mut u32) -> (i32, u32) {
    let mut addr_buf = [0u8; 16];
    let mut addr_len = 0u32;
    let (op, produced) = match result {
        TunnResult::Done => (LAVA_WG_OP_NONE, 0),
        TunnResult::Err(ref err) => (error_code(err), 0),
        TunnResult::WriteToNetwork(data) => (LAVA_WG_OP_WRITE_TO_NETWORK, data.len() as u32),
        TunnResult::WriteToTunnelV4(data, addr) => {
            addr_buf[..4].copy_from_slice(&addr.octets());
            addr_len = 4;
            (LAVA_WG_OP_WRITE_TO_TUNNEL_V4, data.len() as u32)
        }
        TunnResult::WriteToTunnelV6(data, addr) => {
            addr_buf.copy_from_slice(&addr.octets());
            addr_len = 16;
            (LAVA_WG_OP_WRITE_TO_TUNNEL_V6, data.len() as u32)
        }
    };
    if !out_src_addr.is_null() && !out_src_addr_len.is_null() {
        // SAFETY: caller contract — out_src_addr points to ≥16 writable bytes and
        // out_src_addr_len to a writable u32 (both null-checked above).
        unsafe {
            std::ptr::copy_nonoverlapping(addr_buf.as_ptr(), out_src_addr, 16);
            *out_src_addr_len = addr_len;
        }
    }
    (op, produced)
}

fn run_op<F>(
    session: *mut c_void,
    dst: *mut u8,
    dst_cap: u32,
    out_len: *mut u32,
    out_src_addr: *mut u8,
    out_src_addr_len: *mut u32,
    f: F,
) -> i32
where
    // HRTB: the closure may return a TunnResult borrowing the dst slice for any
    // lifetime; classify() consumes it before this function returns.
    F: for<'a> FnOnce(&mut Tunn, &'a mut [u8]) -> TunnResult<'a>,
{
    if session.is_null() || dst.is_null() || out_len.is_null() {
        return LAVA_WG_ERR_INVALID_ARGUMENT;
    }
    // Address out-params are optional but must come as a pair.
    if out_src_addr.is_null() != out_src_addr_len.is_null() {
        return LAVA_WG_ERR_INVALID_ARGUMENT;
    }
    // SAFETY: out_len null-checked above.
    unsafe { *out_len = 0 };
    // SAFETY: pointer provenance per lava_wg_session_new; freed pointers are a
    // caller contract violation the Swift wrapper's lifetime management prevents.
    let session = unsafe { &*(session as *const Session) };
    let Ok(mut tunn) = session.tunn.lock() else {
        return LAVA_WG_ERR_INTERNAL;
    };
    // SAFETY: caller supplies a dst_cap-sized writable buffer.
    let dst_slice = unsafe { std::slice::from_raw_parts_mut(dst, dst_cap as usize) };
    let (op, produced) = classify(f(&mut tunn, dst_slice), out_src_addr, out_src_addr_len);
    // SAFETY: out_len null-checked above.
    unsafe { *out_len = produced };
    op
}

// ---------------------------------------------------------------------------
// ABI
// ---------------------------------------------------------------------------

/// Create a WG session. `private_key` / `peer_public_key` are raw 32-byte
/// X25519 keys; `preshared_key` may be NULL. `keepalive_seconds == 0` means no
/// persistent keepalive. Returns NULL on invalid input. The key buffers are
/// copied, never retained — the caller should zero its own copies as soon as
/// this returns (the engine best-effort scrubs its own stack copies of both
/// the private and preshared keys).
///
/// # Safety
/// `private_key` and `peer_public_key` must each point to 32 readable bytes;
/// `preshared_key` is either NULL or 32 readable bytes.
#[no_mangle]
pub unsafe extern "C" fn lava_wg_session_new(
    private_key: *const u8,
    peer_public_key: *const u8,
    preshared_key: *const u8,
    keepalive_seconds: u16,
    index: u32,
) -> *mut c_void {
    let (Some(mut private_bytes), Some(peer_bytes)) =
        (key_bytes(private_key), key_bytes(peer_public_key))
    else {
        return std::ptr::null_mut();
    };
    let static_private = StaticSecret::from(private_bytes);
    zero_key(&mut private_bytes);
    let peer_public = PublicKey::from(peer_bytes);
    // `Option<[u8; 32]>` is `Copy`, so `Tunn::new` receives a copy and the local
    // stays usable — scrub it afterward (dalek does not zeroize a bare PSK array).
    let mut preshared = key_bytes(preshared_key);
    let keepalive = if keepalive_seconds == 0 {
        None
    } else {
        Some(keepalive_seconds)
    };
    // boringtun 0.7.1's `Tunn::new` is infallible (returns Self). Kept behind this
    // wrapper so a future maintained fork that returns Result is a one-line change.
    let tunn = Tunn::new(static_private, peer_public, preshared, keepalive, index, None);
    if let Some(ref mut psk) = preshared {
        zero_key(psk);
    }
    let session = Box::new(Session {
        tunn: Mutex::new(tunn),
    });
    Box::into_raw(session) as *mut c_void
}

/// # Safety
/// `session` must be a pointer previously returned by `lava_wg_session_new`
/// that has not already been freed. NULL is a no-op.
#[no_mangle]
pub unsafe extern "C" fn lava_wg_session_free(session: *mut c_void) {
    if session.is_null() {
        return;
    }
    drop(Box::from_raw(session as *mut Session));
}

/// Encrypt one outbound IP packet (or, with `src_len == 0`, emit a keepalive).
/// Requires `src_len <= LAVA_WG_MAX_IP_PACKET` and `dst_cap >=
/// LAVA_WG_MAX_DATAGRAM`; `src`/`dst` must not overlap. The uniform buffer
/// requirement (rather than a tight `src_len + overhead`) is what keeps the
/// engine's `format_packet_data` panic unreachable across the whole ABI,
/// including the drain path — see the module docs.
///
/// # Safety
/// `src` points to `src_len` readable bytes (or is NULL iff `src_len` is 0);
/// `src_addr` points to `src_addr_len` readable bytes, where `src_addr_len` is
/// 0, 4 or 16 (any other length, or NULL with a non-zero length, is rejected as
/// an invalid argument); `dst` points to `dst_cap` writable bytes; `out_len` is a writable `u32`.
#[no_mangle]
pub unsafe extern "C" fn lava_wg_encapsulate(
    session: *mut c_void,
    src: *const u8,
    src_len: u32,
    dst: *mut u8,
    dst_cap: u32,
    out_len: *mut u32,
) -> i32 {
    if src.is_null() && src_len > 0 {
        return LAVA_WG_ERR_INVALID_ARGUMENT;
    }
    if src_len > LAVA_WG_MAX_IP_PACKET {
        return LAVA_WG_ERR_PACKET_TOO_LARGE;
    }
    if dst_cap < LAVA_WG_MAX_DATAGRAM {
        return LAVA_WG_ERR_DESTINATION_BUFFER_TOO_SMALL;
    }
    if !dst.is_null() && ranges_overlap(src, src_len, dst, dst_cap) {
        return LAVA_WG_ERR_INVALID_ARGUMENT;
    }
    let src_slice = if src_len == 0 {
        &[][..]
    } else {
        // SAFETY: non-null src with src_len bytes per the check above.
        unsafe { std::slice::from_raw_parts(src, src_len as usize) }
    };
    run_op(
        session,
        dst,
        dst_cap,
        out_len,
        std::ptr::null_mut(),
        std::ptr::null_mut(),
        |tunn, dst_slice| tunn.encapsulate(src_slice, dst_slice),
    )
}

/// Decrypt one inbound UDP datagram, or drain queued packets/control replies
/// with `src_len == 0` (see the drain contract in the module docs). Requires
/// `dst_cap >= LAVA_WG_MAX_DATAGRAM`; `src`/`dst` must not overlap. The uniform
/// requirement is mandatory, not conservative: a drain call re-encapsulates a
/// queued OUTBOUND packet into `dst`, so a `dst >= src_len` bound (with
/// `src_len == 0`) would leave the engine's `format_packet_data` panic
/// reachable.
///
/// `src_addr`/`src_addr_len` carry the UDP peer the datagram arrived FROM: 0
/// bytes for "unknown", or 4/16 for IPv4/IPv6 — the same encoding the
/// `out_src_addr` pair uses in the other direction.
///
/// SUPPLY IT WHENEVER YOU HAVE IT. It is not a hint; it is what boringtun's DoS
/// mitigation runs on. Under load the engine answers a handshake with a COOKIE
/// the sender must echo back (mac2), which proves it holds the address it
/// claims. That path needs an address, and with `None` the limiter short-circuits
/// to a hard `UnderLoad` error before reaching it
/// (`noise/rate_limiter.rs`) — so the graceful mitigation is replaced by a hard
/// failure while the counter keeps incrementing on every MAC1-valid handshake
/// packet, our own legitimate ones included.
///
/// That is remotely exploitable, and cheaply: replaying a captured
/// server-to-client handshake response needs no forgery, and
/// `PEER_HANDSHAKE_RATE_LIMIT` is 10 per second against a 1-second reset. Above
/// that rate the real handshake response is discarded, the tunnel holds
/// `0.0.0.0/0` and `::/0` forwarding nothing until `REKEY_ATTEMPT_TIME` (90 s),
/// and the reconnect budget then surrenders chained mode for the rest of the
/// tunnel lifecycle. Roughly fifteen seconds of flooding buys that.
///
/// Passing 0 is legal because a caller may genuinely not know the address, and
/// silently inventing one would be worse. It is not the safe default.
///
/// For `WRITE_TO_TUNNEL_V4/V6` results, when `out_src_addr` is non-NULL it
/// receives the decrypted packet's source IP (4 or 16 bytes;
/// `*out_src_addr_len` says which) for Phase-3 allowed-IPs enforcement. Pass
/// both address params NULL or both non-NULL (`out_src_addr` must hold 16
/// bytes).
///
/// # Safety
/// `src` points to `src_len` readable bytes (or is NULL iff `src_len` is 0);
/// `src_addr` points to `src_addr_len` readable bytes, where `src_addr_len` is
/// 0, 4 or 16 (any other length, or NULL with a non-zero length, is rejected as
/// an invalid argument); `dst` points to `dst_cap` writable bytes; `out_len` is a writable `u32`;
/// `out_src_addr`/`out_src_addr_len` are NULL or 16 writable bytes / a
/// writable `u32` respectively.
#[no_mangle]
pub unsafe extern "C" fn lava_wg_decapsulate(
    session: *mut c_void,
    src: *const u8,
    src_len: u32,
    src_addr: *const u8,
    src_addr_len: u32,
    dst: *mut u8,
    dst_cap: u32,
    out_len: *mut u32,
    out_src_addr: *mut u8,
    out_src_addr_len: *mut u32,
) -> i32 {
    if src.is_null() && src_len > 0 {
        return LAVA_WG_ERR_INVALID_ARGUMENT;
    }
    // SAFETY: caller contract — src_addr points to src_addr_len readable bytes.
    let peer_addr = match unsafe { decode_peer_addr(src_addr, src_addr_len) } {
        Ok(addr) => addr,
        Err(code) => return code,
    };
    if dst_cap < LAVA_WG_MAX_DATAGRAM {
        return LAVA_WG_ERR_DESTINATION_BUFFER_TOO_SMALL;
    }
    // The fixed minimum above is NOT sufficient on its own, and the gap is remotely
    // reachable. For a type-4 transport datagram the engine panics on
    // `ct_len > dst.len()` (`noise/session.rs:242`) — and that check precedes BOTH the
    // `receiver_idx` comparison on the next line and any authentication. `handle_data`
    // only has to find an OCCUPIED slot at `sessions[receiver_idx % 8]` to get there, so
    // eight datagrams from any host that can reach our UDP port are enough. Under the
    // release profile (`panic = "abort"`) that is a tunnel abort.
    //
    // Requiring the destination to cover the whole inbound datagram closes it: a data
    // packet's plaintext is always shorter than its ciphertext, so `dst_cap >= src_len`
    // implies `dst_cap >= ct_len` without this layer parsing the packet. An over-MTU
    // datagram is reported as a too-small destination and dropped — the right outcome for
    // something we could not have carried anyway.
    if src_len > dst_cap {
        return LAVA_WG_ERR_DESTINATION_BUFFER_TOO_SMALL;
    }
    if !dst.is_null() && ranges_overlap(src, src_len, dst, dst_cap) {
        return LAVA_WG_ERR_INVALID_ARGUMENT;
    }
    let src_slice = if src_len == 0 {
        &[][..]
    } else {
        // SAFETY: non-null src with src_len bytes per the check above.
        unsafe { std::slice::from_raw_parts(src, src_len as usize) }
    };
    // EVERY ARGUMENT CHECK FIRST, THEN THE WIRE. Ordering is the contract here: an overlapping
    // src/dst, a null session, or a missing out-parameter is a CALLER bug and must report
    // LAVA_WG_ERR_INVALID_ARGUMENT. Classifying the counter ahead of them reported those as
    // LAVA_WG_ERR_PROTOCOL — hostile wire input — which hides an ABI violation in the one place a
    // caller would look for it. `run_op` re-checks these; the duplication buys the ordering, and
    // disagreeing with it would be caught by `a_null_session_is_rejected` (Codex, PR #496).
    if session.is_null() || dst.is_null() || out_len.is_null() {
        return LAVA_WG_ERR_INVALID_ARGUMENT;
    }
    // The address pair is BOTH-OR-NEITHER, and it belongs in this precheck for the same reason
    // the three above do: `run_op` rejects a half-supplied pair as an invalid argument, and
    // classifying the counter ahead of that reported a caller's mismatched out-parameters as
    // hostile wire input (Codex, PR #496).
    if out_src_addr.is_null() != out_src_addr_len.is_null() {
        return LAVA_WG_ERR_INVALID_ARGUMENT;
    }
    // AND ONLY NOW THE WIRE — see
    // `LAVA_WG_REJECT_AFTER_MESSAGES`. The engine does not enforce the limit and overflows
    // unchecked `u64` arithmetic on this field, which neutralises the anti-replay window for the
    // life of the session.
    //
    // Reported as a protocol error — drop this packet, keep the session — because that is
    // exactly the disposition. The datagram is malformed by the specification's own rule and
    // nothing about the session is compromised by refusing it. A dedicated code would have to be
    // mirrored into the C header and the Swift enum for a distinction neither can act on.
    if is_transport_counter_out_of_range(src_slice) {
        return LAVA_WG_ERR_PROTOCOL;
    }
    run_op(
        session,
        dst,
        dst_cap,
        out_len,
        out_src_addr,
        out_src_addr_len,
        |tunn, dst_slice| tunn.decapsulate(peer_addr, src_slice, dst_slice),
    )
}

/// Drive WG timers (handshake retries, keepalive, rekey). Call ~every 250 ms;
/// a `WRITE_TO_NETWORK` result must be sent to the peer, and a
/// `LAVA_WG_ERR_CONNECTION_EXPIRED` return is the reconnect-escalation signal.
/// Requires `dst_cap >= LAVA_WG_MIN_CONTROL_DST` (timers only ever emit control
/// messages, never re-encapsulated data).
///
/// # Safety
/// `dst` points to `dst_cap` writable bytes; `out_len` is a writable `u32`.
#[no_mangle]
pub unsafe extern "C" fn lava_wg_tick(
    session: *mut c_void,
    dst: *mut u8,
    dst_cap: u32,
    out_len: *mut u32,
) -> i32 {
    if dst_cap < LAVA_WG_MIN_CONTROL_DST {
        return LAVA_WG_ERR_DESTINATION_BUFFER_TOO_SMALL;
    }
    run_op(
        session,
        dst,
        dst_cap,
        out_len,
        std::ptr::null_mut(),
        std::ptr::null_mut(),
        |tunn, dst_slice| tunn.update_timers(dst_slice),
    )
}

/// Force a handshake initiation (used once at session start so the tunnel
/// comes up without waiting for first traffic). Requires
/// `dst_cap >= LAVA_WG_MIN_CONTROL_DST`.
///
/// # Safety
/// `dst` points to `dst_cap` writable bytes; `out_len` is a writable `u32`.
#[no_mangle]
pub unsafe extern "C" fn lava_wg_force_handshake(
    session: *mut c_void,
    dst: *mut u8,
    dst_cap: u32,
    out_len: *mut u32,
) -> i32 {
    if dst_cap < LAVA_WG_MIN_CONTROL_DST {
        return LAVA_WG_ERR_DESTINATION_BUFFER_TOO_SMALL;
    }
    run_op(
        session,
        dst,
        dst_cap,
        out_len,
        std::ptr::null_mut(),
        std::ptr::null_mut(),
        |tunn, dst_slice| tunn.format_handshake_initiation(dst_slice, true),
    )
}

/// Fill `out_stats` with the session-health snapshot (D1 latch monitoring, QA).
/// Returns `LAVA_WG_OP_NONE` on success or a negative error code.
///
/// # Safety
/// `session` per the provenance contract; `out_stats` points to a writable
/// `LavaWGStats`.
#[no_mangle]
pub unsafe extern "C" fn lava_wg_session_stats(
    session: *mut c_void,
    out_stats: *mut LavaWGStats,
) -> i32 {
    if session.is_null() || out_stats.is_null() {
        return LAVA_WG_ERR_INVALID_ARGUMENT;
    }
    // SAFETY: provenance per lava_wg_session_new.
    let session = unsafe { &*(session as *const Session) };
    let Ok(tunn) = session.tunn.lock() else {
        return LAVA_WG_ERR_INTERNAL;
    };
    let (since_handshake, tx, rx, loss, rtt) = tunn.stats();
    let stats = LavaWGStats {
        time_since_last_handshake_ms: since_handshake
            .map(|d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
            .unwrap_or(-1),
        tx_bytes: tx as u64,
        rx_bytes: rx as u64,
        estimated_loss: loss,
        estimated_rtt_ms: rtt.map(|ms| ms as i32).unwrap_or(-1),
    };
    // SAFETY: out_stats null-checked above.
    unsafe { std::ptr::write(out_stats, stats) };
    LAVA_WG_OP_NONE
}

#[cfg(test)]
mod transport_counter_tests {
    use super::*;

    fn transport(counter: u64) -> Vec<u8> {
        let mut p = vec![0u8; TRANSPORT_HEADER_LEN];
        p[0] = TRANSPORT_DATA_TYPE;
        p[TRANSPORT_COUNTER_OFFSET..TRANSPORT_HEADER_LEN].copy_from_slice(&counter.to_le_bytes());
        p
    }

    #[test]
    fn the_ceiling_is_the_specification_value_and_is_inclusive() {
        // THE VALUE ITSELF, spelled out, because the expression form hid an off-by-one that
        // shipped: `2^64 - 2^13 - 1` is `u64::MAX - 8192`, and this constant was written
        // `u64::MAX - (1 << 13) - 1` — one lower, rejecting a counter the specification permits.
        // Fail-closed, so nothing caught it; wrong all the same (Kilo, PR #496).
        assert_eq!(LAVA_WG_REJECT_AFTER_MESSAGES, 18_446_744_073_709_543_423);
        assert_eq!(u128::from(LAVA_WG_REJECT_AFTER_MESSAGES), (1u128 << 64) - (1 << 13) - 1);
        assert!(is_transport_counter_out_of_range(&transport(u64::MAX)));
        assert!(is_transport_counter_out_of_range(&transport(
            LAVA_WG_REJECT_AFTER_MESSAGES
        )));
        assert!(!is_transport_counter_out_of_range(&transport(
            LAVA_WG_REJECT_AFTER_MESSAGES - 1
        )));
        assert!(!is_transport_counter_out_of_range(&transport(0)));
    }

    #[test]
    fn the_limit_leaves_room_for_the_engines_own_window_arithmetic() {
        // The whole point of the specification's value: `counter + N_BITS` must not overflow,
        // because that expression is what `will_accept` evaluates unchecked.
        //
        // N_BITS is the engine's replay-window width, `WORD_SIZE * N_WORDS = 64 * 16 = 1024`
        // (`noise/session.rs:35-37`) — NOT 8192, which is what this assertion first used. Both
        // values pass, since the specification leaves 2^13 of headroom and 1024 fits inside
        // 8192; a test that passes for the wrong reason is not a test of anything.
        const ENGINE_REPLAY_WINDOW: u64 = 64 * 16;
        assert!((LAVA_WG_REJECT_AFTER_MESSAGES - 1)
            .checked_add(ENGINE_REPLAY_WINDOW)
            .is_some());
        // And the headroom the specification actually reserves, so a fork that widens its window
        // is still covered.
        assert!((LAVA_WG_REJECT_AFTER_MESSAGES - 1).checked_add(1 << 13).is_some());
    }

    #[test]
    fn only_transport_datagrams_carry_a_counter() {
        // Bytes 8..16 of a handshake initiation are key material. Reading them as a counter
        // would refuse handshakes at random — roughly one in 2^13.
        for message_type in [1u8, 2, 3] {
            let mut p = transport(u64::MAX);
            p[0] = message_type;
            assert!(
                !is_transport_counter_out_of_range(&p),
                "type {message_type} was read as a transport counter"
            );
        }
    }

    #[test]
    fn a_datagram_too_short_to_hold_a_counter_is_left_to_the_engine() {
        for len in 0..TRANSPORT_HEADER_LEN {
            let mut p = vec![0u8; len];
            if len > 0 {
                p[0] = TRANSPORT_DATA_TYPE;
            }
            assert!(!is_transport_counter_out_of_range(&p), "len {len}");
        }
    }
}
