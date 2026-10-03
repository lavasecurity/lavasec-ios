// THROWAWAY SPIKE — Phase 0 de-risking for chained VPN upstream.
// Plan: lavasec-infra plans/2026-07-22-vpn-upstream-chaining-feasibility-plan.md
// (spike spec) and .../2026-07-22-vpn-upstream-chaining-implementation-plan.md (Phase 0).
//
// Minimal C ABI over boringtun's `Tunn` (Noise handshake + WG transport transform).
// The ABI is deliberately primitive — opaque pointer, byte buffers, u32 lengths,
// i32 op codes — so the Swift side can bind with `@_silgen_name` and zero project
// changes (the DeviceDNSResolver.c shim is the in-repo precedent for that binding).
//
// Threading contract: the session is internally Mutex-guarded, but the Swift caller
// confines all calls to one serial queue anyway (the spike's `spike.wg` queue); the
// Mutex is a UB backstop, not a concurrency design.
//
// decapsulate contract (boringtun requirement): when a decapsulate call returns
// WRITE_TO_NETWORK, the caller must send that datagram and then call decapsulate
// again with an EMPTY source until it stops returning WRITE_TO_NETWORK — that is
// how queued handshake/cookie replies drain.

use std::os::raw::c_void;
use std::sync::Mutex;

use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};

pub const WG_SPIKE_OP_NONE: i32 = 0;
pub const WG_SPIKE_OP_WRITE_TO_NETWORK: i32 = 1;
pub const WG_SPIKE_OP_WRITE_TO_TUNNEL_V4: i32 = 2;
pub const WG_SPIKE_OP_WRITE_TO_TUNNEL_V6: i32 = 3;
pub const WG_SPIKE_OP_ERROR: i32 = -1;

struct Session {
    tunn: Mutex<Tunn>,
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

/// Create a WG session. `private_key` / `peer_public_key` are raw 32-byte X25519
/// keys (Swift decodes the base64). `preshared_key` may be NULL. Returns NULL on
/// construction failure.
///
/// # Safety
/// `private_key` and `peer_public_key` must each point to 32 readable bytes;
/// `preshared_key` is either NULL or 32 readable bytes.
#[no_mangle]
pub unsafe extern "C" fn wg_spike_session_new(
    private_key: *const u8,
    peer_public_key: *const u8,
    preshared_key: *const u8,
    keepalive_seconds: u16,
    index: u32,
) -> *mut c_void {
    let (Some(private_bytes), Some(peer_bytes)) =
        (key_bytes(private_key), key_bytes(peer_public_key))
    else {
        return std::ptr::null_mut();
    };
    let static_private = StaticSecret::from(private_bytes);
    let peer_public = PublicKey::from(peer_bytes);
    let preshared = key_bytes(preshared_key);
    let keepalive = if keepalive_seconds == 0 {
        None
    } else {
        Some(keepalive_seconds)
    };
    // boringtun 0.7.1's `Tunn::new` is infallible (returns Self). Kept behind this
    // wrapper so a future maintained fork that returns Result is a one-line change.
    let tunn = Tunn::new(static_private, peer_public, preshared, keepalive, index, None);
    let session = Box::new(Session {
        tunn: Mutex::new(tunn),
    });
    Box::into_raw(session) as *mut c_void
}

/// # Safety
/// `session` must be a pointer previously returned by `wg_spike_session_new`
/// that has not already been freed.
#[no_mangle]
pub unsafe extern "C" fn wg_spike_session_free(session: *mut c_void) {
    if session.is_null() {
        return;
    }
    drop(Box::from_raw(session as *mut Session));
}

// Classify one TunnResult into (op-code, produced-length). Kept as one match so the
// borrowed slice inside TunnResult never has to escape into a generic closure bound —
// the reason `run_op` inlines the session lock rather than delegating.
fn classify(result: TunnResult) -> (i32, u32) {
    match result {
        TunnResult::Done => (WG_SPIKE_OP_NONE, 0),
        TunnResult::Err(_) => (WG_SPIKE_OP_ERROR, 0),
        TunnResult::WriteToNetwork(data) => (WG_SPIKE_OP_WRITE_TO_NETWORK, data.len() as u32),
        TunnResult::WriteToTunnelV4(data, _) => (WG_SPIKE_OP_WRITE_TO_TUNNEL_V4, data.len() as u32),
        TunnResult::WriteToTunnelV6(data, _) => (WG_SPIKE_OP_WRITE_TO_TUNNEL_V6, data.len() as u32),
    }
}

fn run_op<F>(
    session: *mut c_void,
    dst: *mut u8,
    dst_cap: u32,
    out_len: *mut u32,
    f: F,
) -> i32
where
    // HRTB: the closure may return a TunnResult borrowing the dst slice for any lifetime;
    // classify() consumes it before this function returns, so nothing escapes.
    F: for<'a> FnOnce(&mut Tunn, &'a mut [u8]) -> TunnResult<'a>,
{
    if session.is_null() || dst.is_null() || out_len.is_null() {
        return WG_SPIKE_OP_ERROR;
    }
    // SAFETY: caller supplies a dst_cap-sized buffer and a valid out pointer.
    unsafe { *out_len = 0 };
    // SAFETY: pointer provenance per wg_spike_session_new; freed pointers are a caller
    // contract violation the Swift wrapper's lifetime management prevents.
    let session = unsafe { &*(session as *const Session) };
    let Ok(mut tunn) = session.tunn.lock() else {
        return WG_SPIKE_OP_ERROR;
    };
    let dst_slice = unsafe { std::slice::from_raw_parts_mut(dst, dst_cap as usize) };
    let (op, produced) = classify(f(&mut tunn, dst_slice));
    // SAFETY: out_len null-checked above.
    unsafe { *out_len = produced };
    op
}

/// Encrypt one outbound IP packet. dst must be at least src_len + 32 bytes
/// (148 bytes minimum for handshake-piggyback cases).
///
/// # Safety
/// `src` points to `src_len` readable bytes (or is NULL iff `src_len` is 0);
/// `dst` points to `dst_cap` writable bytes; `out_len` is a writable `u32`.
#[no_mangle]
pub unsafe extern "C" fn wg_spike_encapsulate(
    session: *mut c_void,
    src: *const u8,
    src_len: u32,
    dst: *mut u8,
    dst_cap: u32,
    out_len: *mut u32,
) -> i32 {
    if src.is_null() && src_len > 0 {
        return WG_SPIKE_OP_ERROR;
    }
    let src_slice = if src_len == 0 {
        &[][..]
    } else {
        // SAFETY: non-null src with src_len bytes per the check above.
        unsafe { std::slice::from_raw_parts(src, src_len as usize) }
    };
    run_op(session, dst, dst_cap, out_len, |tunn, dst_slice| {
        tunn.encapsulate(src_slice, dst_slice)
    })
}

/// Decrypt one inbound UDP datagram (or drain queued replies with src_len == 0 —
/// see the decapsulate contract at the top of this file).
///
/// # Safety
/// `src` points to `src_len` readable bytes (or is NULL iff `src_len` is 0);
/// `dst` points to `dst_cap` writable bytes; `out_len` is a writable `u32`.
#[no_mangle]
pub unsafe extern "C" fn wg_spike_decapsulate(
    session: *mut c_void,
    src: *const u8,
    src_len: u32,
    dst: *mut u8,
    dst_cap: u32,
    out_len: *mut u32,
) -> i32 {
    if src.is_null() && src_len > 0 {
        return WG_SPIKE_OP_ERROR;
    }
    let src_slice = if src_len == 0 {
        &[][..]
    } else {
        // SAFETY: non-null src with src_len bytes per the check above.
        unsafe { std::slice::from_raw_parts(src, src_len as usize) }
    };
    run_op(session, dst, dst_cap, out_len, |tunn, dst_slice| {
        tunn.decapsulate(None, src_slice, dst_slice)
    })
}

/// Drive WG timers (handshake retries, keepalive, rekey). Call ~every 250 ms;
/// a WRITE_TO_NETWORK result must be sent to the peer.
///
/// # Safety
/// `dst` points to `dst_cap` writable bytes; `out_len` is a writable `u32`.
#[no_mangle]
pub unsafe extern "C" fn wg_spike_tick(
    session: *mut c_void,
    dst: *mut u8,
    dst_cap: u32,
    out_len: *mut u32,
) -> i32 {
    run_op(session, dst, dst_cap, out_len, |tunn, dst_slice| {
        tunn.update_timers(dst_slice)
    })
}

/// Force a handshake initiation (used once at session start so the tunnel comes
/// up without waiting for first traffic).
///
/// # Safety
/// `dst` points to `dst_cap` writable bytes; `out_len` is a writable `u32`.
#[no_mangle]
pub unsafe extern "C" fn wg_spike_force_handshake(
    session: *mut c_void,
    dst: *mut u8,
    dst_cap: u32,
    out_len: *mut u32,
) -> i32 {
    run_op(session, dst, dst_cap, out_len, |tunn, dst_slice| {
        tunn.format_handshake_initiation(dst_slice, true)
    })
}
