// Executable proof that the production C ABI drives a real boringtun Noise
// handshake and transport round-trip, and that every documented ABI contract
// holds — in particular that the engine's panic-on-undersized-dst paths are
// unreachable through this ABI (release aborts on panic, so a sizing bug must
// surface as an error code, not a crash). Ported from the Phase-0 spike's
// handshake_roundtrip.rs and extended; the same flow runs again from Swift
// against the macOS slice once the SPM target lands (Phase 1, later slice).

use lavasec_wireguard_core::*;
use std::os::raw::c_void;

fn keypair(seed: u8) -> ([u8; 32], [u8; 32]) {
    let secret = boringtun::x25519::StaticSecret::from([seed; 32]);
    let public = boringtun::x25519::PublicKey::from(&secret);
    (secret.to_bytes(), public.to_bytes())
}

// Every data-path dst must be >= LAVA_WG_MAX_DATAGRAM; use one comfortable size.
struct Buf([u8; 2048]);
impl Buf {
    fn new() -> Self {
        Buf([0u8; 2048])
    }
}

/// One decapsulate call with fresh out-params; returns (op, produced bytes).
fn decap(
    s: *mut c_void,
    src: &[u8],
    dst: &mut Buf,
    addr: Option<(&mut [u8; 16], &mut u32)>,
) -> (i32, u32) {
    let mut out_len = 0u32;
    let (addr_ptr, addr_len_ptr) = match addr {
        Some((buf, len)) => (buf.as_mut_ptr(), len as *mut u32),
        None => (std::ptr::null_mut(), std::ptr::null_mut()),
    };
    let src_ptr = if src.is_empty() {
        std::ptr::null()
    } else {
        src.as_ptr()
    };
    let op = unsafe {
        lava_wg_decapsulate(
            s,
            src_ptr,
            src.len() as u32,
            // Address unknown: this helper predates the parameter and its callers are
            // testing other things. decap_from covers the parameter itself.
            std::ptr::null(),
            0,
            dst.0.as_mut_ptr(),
            dst.0.len() as u32,
            &mut out_len,
            addr_ptr,
            addr_len_ptr,
        )
    };
    (op, out_len)
}

fn encap(s: *mut c_void, src: &[u8], dst: &mut Buf) -> (i32, u32) {
    let mut out_len = 0u32;
    let op = unsafe {
        lava_wg_encapsulate(
            s,
            src.as_ptr(),
            src.len() as u32,
            dst.0.as_mut_ptr(),
            dst.0.len() as u32,
            &mut out_len,
        )
    };
    (op, out_len)
}

fn ipv4_packet() -> [u8; 40] {
    let mut p = [0u8; 40];
    p[0] = 0x45; // IPv4, IHL 5
    p[3] = 40; // total length (must match for byte-exact round-trip)
    p[9] = 17; // protocol = UDP
    p[12..16].copy_from_slice(&[192, 168, 1, 2]); // src
    p[16..20].copy_from_slice(&[192, 168, 1, 3]); // dst
    for (i, b) in p.iter_mut().enumerate().skip(20) {
        *b = i as u8;
    }
    p
}

/// A valid `len`-byte IPv4 packet (len in 40..=65535). Total-length field is
/// set so boringtun's decapsulate accepts it byte-for-byte.
fn ipv4_packet_of(len: usize) -> Vec<u8> {
    assert!((40..=65535).contains(&len));
    let mut p = vec![0u8; len];
    p[0] = 0x45;
    p[2] = (len >> 8) as u8;
    p[3] = (len & 0xff) as u8;
    p[9] = 17;
    p[12..16].copy_from_slice(&[192, 168, 1, 2]);
    p[16..20].copy_from_slice(&[192, 168, 1, 3]);
    for (i, b) in p.iter_mut().enumerate().skip(20) {
        *b = i as u8;
    }
    p
}

fn ipv6_packet() -> [u8; 40] {
    // Minimal valid IPv6 header, payload length 0 (header only).
    let mut p = [0u8; 40];
    p[0] = 0x60; // version 6
    p[4] = 0x00; // payload length hi
    p[5] = 0x00; // payload length lo = 0
    p[6] = 59; // next header = No Next Header
    p[7] = 64; // hop limit
    // src ::1, dst ::2 (distinct, valid)
    p[8..24].copy_from_slice(&[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
    p[24..40].copy_from_slice(&[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]);
    p
}

/// Runs the 4-leg handshake and returns established (a, b) sessions.
fn established_pair() -> (*mut c_void, *mut c_void) {
    let (a_priv, a_pub) = keypair(1);
    let (b_priv, b_pub) = keypair(2);
    let a = unsafe { lava_wg_session_new(a_priv.as_ptr(), b_pub.as_ptr(), std::ptr::null(), 25, 1) };
    let b = unsafe { lava_wg_session_new(b_priv.as_ptr(), a_pub.as_ptr(), std::ptr::null(), 25, 2) };
    assert!(!a.is_null() && !b.is_null(), "session construction failed");

    let mut wire = Buf::new();
    let mut wire_len = 0u32;
    let op =
        unsafe { lava_wg_force_handshake(a, wire.0.as_mut_ptr(), wire.0.len() as u32, &mut wire_len) };
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_NETWORK, "handshake init expected");
    assert_eq!(
        wire_len, LAVA_WG_MIN_CONTROL_DST,
        "handshake initiation is exactly the documented control minimum"
    );

    let mut resp = Buf::new();
    let (op, resp_len) = decap(b, &wire.0[..wire_len as usize], &mut resp, None);
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_NETWORK, "handshake response expected");

    let mut keepalive = Buf::new();
    let (op, ka_len) = decap(a, &resp.0[..resp_len as usize], &mut keepalive, None);
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_NETWORK, "completion keepalive expected");

    let mut sink = Buf::new();
    let (op, _) = decap(b, &keepalive.0[..ka_len as usize], &mut sink, None);
    assert_eq!(op, LAVA_WG_OP_NONE, "keepalive finalizes B's session");
    (a, b)
}

/// Establishes a pair whose initiator A has ONE outbound packet queued inside
/// the engine (encapsulated before the session came up), and returns
/// (a, b, the queued plaintext). This is the exact Phase-3 bring-up ordering
/// that reaches the drain re-encapsulation path.
fn pair_with_queued_packet() -> (*mut c_void, *mut c_void, Vec<u8>) {
    let (a_priv, a_pub) = keypair(7);
    let (b_priv, b_pub) = keypair(8);
    let a = unsafe { lava_wg_session_new(a_priv.as_ptr(), b_pub.as_ptr(), std::ptr::null(), 25, 1) };
    let b = unsafe { lava_wg_session_new(b_priv.as_ptr(), a_pub.as_ptr(), std::ptr::null(), 25, 2) };

    // First outbound packet with no session: engine queues it and emits the
    // handshake initiation (the documented reason encapsulate needs a control-
    // capable dst). This is what later drains — the P0 re-encapsulation path.
    // Deliberately a large (1400-byte) packet: re-encapsulated it is 1432 bytes,
    // so a control-sized (156-byte) drain buffer would OVERFLOW and panic the
    // vendored engine under the pre-fix `dst_cap >= 148` check — that is exactly
    // what the uniform data-minimum must reject instead.
    let payload = ipv4_packet_of(1400);
    let mut init = Buf::new();
    let (op, init_len) = encap(a, &payload, &mut init);
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_NETWORK, "first packet triggers handshake init");

    let mut resp = Buf::new();
    let (op, resp_len) = decap(b, &init.0[..init_len as usize], &mut resp, None);
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_NETWORK, "handshake response");

    let mut keepalive = Buf::new();
    let (op, ka_len) = decap(a, &resp.0[..resp_len as usize], &mut keepalive, None);
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_NETWORK, "A completes handshake");

    let mut sink = Buf::new();
    let (op, _) = decap(b, &keepalive.0[..ka_len as usize], &mut sink, None);
    assert_eq!(op, LAVA_WG_OP_NONE, "B established; payload still queued on A");
    (a, b, payload)
}

#[test]
fn handshake_transport_roundtrip_addr_stats_and_drain() {
    let (a, b) = established_pair();

    // Stats after handshake: A has a completed handshake and no data yet.
    let mut stats = LavaWGStats {
        time_since_last_handshake_ms: -2,
        tx_bytes: 99,
        rx_bytes: 99,
        estimated_loss: -1.0,
        estimated_rtt_ms: -2,
    };
    let rc = unsafe { lava_wg_session_stats(a, &mut stats) };
    assert_eq!(rc, LAVA_WG_OP_NONE);
    assert!(
        stats.time_since_last_handshake_ms >= 0,
        "handshake completed ⇒ non-negative age"
    );

    // Transport round-trip, byte-exact, with the source-address out-param.
    let payload = ipv4_packet();
    let mut enc = Buf::new();
    let (op, enc_len) = encap(a, &payload, &mut enc);
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_NETWORK);

    let mut dec = Buf::new();
    let mut addr = [0u8; 16];
    let mut addr_len = 0u32;
    let (op, dec_len) = decap(
        b,
        &enc.0[..enc_len as usize],
        &mut dec,
        Some((&mut addr, &mut addr_len)),
    );
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_TUNNEL_V4);
    assert_eq!(&dec.0[..dec_len as usize], &payload[..], "byte-exact round-trip");
    assert_eq!(addr_len, 4, "IPv4 source address length");
    assert_eq!(&addr[..4], &[192, 168, 1, 2], "inner source address surfaced");

    // No queue on this session ⇒ empty-src drain is NONE.
    let mut drain = Buf::new();
    let (op, drained) = decap(b, &[], &mut drain, None);
    assert_eq!(op, LAVA_WG_OP_NONE, "empty queue drains to NONE");
    assert_eq!(drained, 0);

    // Data counters moved.
    let rc = unsafe { lava_wg_session_stats(a, &mut stats) };
    assert_eq!(rc, LAVA_WG_OP_NONE);
    assert!(stats.tx_bytes >= payload.len() as u64, "A counted tx plaintext");
    let rc = unsafe { lava_wg_session_stats(b, &mut stats) };
    assert_eq!(rc, LAVA_WG_OP_NONE);
    assert!(stats.rx_bytes >= payload.len() as u64, "B counted rx plaintext");

    unsafe {
        lava_wg_session_free(a);
        lava_wg_session_free(b);
    }
}

#[test]
fn ipv6_decapsulates_and_surfaces_a_16_byte_source() {
    let (a, b) = established_pair();
    let payload = ipv6_packet();
    let mut enc = Buf::new();
    let (op, enc_len) = encap(a, &payload, &mut enc);
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_NETWORK);

    let mut dec = Buf::new();
    let mut addr = [0xFFu8; 16];
    let mut addr_len = 0u32;
    let (op, dec_len) = decap(
        b,
        &enc.0[..enc_len as usize],
        &mut dec,
        Some((&mut addr, &mut addr_len)),
    );
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_TUNNEL_V6, "V6 op code");
    assert_eq!(&dec.0[..dec_len as usize], &payload[..], "V6 byte-exact round-trip");
    assert_eq!(addr_len, 16, "IPv6 source address length");
    assert_eq!(&addr[..16], &payload[8..24], "V6 inner source address surfaced");

    unsafe {
        lava_wg_session_free(a);
        lava_wg_session_free(b);
    }
}

#[test]
fn drain_flushes_a_queued_packet_and_undersized_drain_is_error_not_panic() {
    // The P0 regression pin: a packet queued before the session came up is
    // re-encapsulated on the empty-src drain path. With a control-sized (but
    // sub-LAVA_WG_MAX_DATAGRAM) buffer the vendored engine PANICS in
    // format_packet_data — pre-diff this ABI passed that buffer through
    // (dst_cap >= 148) and aborted the tunnel. The uniform LAVA_WG_MAX_DATAGRAM
    // requirement must reject it as an error instead.
    let (a, b, payload) = pair_with_queued_packet();

    // Drain with a buffer that clears the control minimum but is below the data
    // minimum: must be a clean error, never reaching the engine.
    let mut small = [0u8; (LAVA_WG_MIN_CONTROL_DST as usize) + 8]; // 156, well under 1532
    let mut out_len = 0u32;
    let op = unsafe {
        lava_wg_decapsulate(
            a,
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            small.as_mut_ptr(),
            small.len() as u32,
            &mut out_len,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    assert_eq!(
        op, LAVA_WG_ERR_DESTINATION_BUFFER_TOO_SMALL,
        "drain with a data-undersized buffer must error, not panic"
    );

    // Now drain with a proper buffer: the queued packet flushes as WRITE_TO_NETWORK.
    let mut full = Buf::new();
    let (op, flushed_len) = decap(a, &[], &mut full, None);
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_NETWORK, "queued packet flushes on drain");
    assert!(flushed_len > 0);

    // It really is our packet: B decrypts it back byte-exact.
    let mut dec = Buf::new();
    let (op, dec_len) = decap(b, &full.0[..flushed_len as usize], &mut dec, None);
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_TUNNEL_V4);
    assert_eq!(&dec.0[..dec_len as usize], &payload[..], "flushed packet round-trips");

    unsafe {
        lava_wg_session_free(a);
        lava_wg_session_free(b);
    }
}

#[test]
fn undersized_dst_is_an_error_never_a_panic() {
    let (a, b) = established_pair();
    let payload = ipv4_packet();
    let mut out_len = 0u32;

    // Encapsulate on an established session with dst below LAVA_WG_MAX_DATAGRAM:
    // one below the boundary must reject, exactly at it must pass.
    let mut just_under = [0u8; (LAVA_WG_MAX_DATAGRAM as usize) - 1];
    let op = unsafe {
        lava_wg_encapsulate(
            a,
            payload.as_ptr(),
            payload.len() as u32,
            just_under.as_mut_ptr(),
            just_under.len() as u32,
            &mut out_len,
        )
    };
    assert_eq!(op, LAVA_WG_ERR_DESTINATION_BUFFER_TOO_SMALL, "one below the data minimum");

    let mut exact = vec![0u8; LAVA_WG_MAX_DATAGRAM as usize];
    let op = unsafe {
        lava_wg_encapsulate(
            a,
            payload.as_ptr(),
            payload.len() as u32,
            exact.as_mut_ptr(),
            exact.len() as u32,
            &mut out_len,
        )
    };
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_NETWORK, "exactly the data minimum succeeds");

    // Oversize src is rejected before it can be queued (bounds the drain path).
    let big_src = vec![0u8; (LAVA_WG_MAX_IP_PACKET as usize) + 1];
    let mut dst = vec![0u8; LAVA_WG_MAX_DATAGRAM as usize];
    let op = unsafe {
        lava_wg_encapsulate(
            a,
            big_src.as_ptr(),
            big_src.len() as u32,
            dst.as_mut_ptr(),
            dst.len() as u32,
            &mut out_len,
        )
    };
    assert_eq!(op, LAVA_WG_ERR_PACKET_TOO_LARGE, "oversize src rejected");

    // Decapsulate below the data minimum rejects regardless of src size.
    let mut small_dst = [0u8; (LAVA_WG_MAX_DATAGRAM as usize) - 1];
    let real_src = [0u8; 200];
    let op = unsafe {
        lava_wg_decapsulate(
            b,
            real_src.as_ptr(),
            real_src.len() as u32,
            std::ptr::null(),
            0,
            small_dst.as_mut_ptr(),
            small_dst.len() as u32,
            &mut out_len,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    assert_eq!(op, LAVA_WG_ERR_DESTINATION_BUFFER_TOO_SMALL, "decap below data minimum");

    unsafe {
        lava_wg_session_free(a);
        lava_wg_session_free(b);
    }
}

#[test]
fn overlapping_src_and_dst_are_rejected() {
    let (a, b) = established_pair();
    // One buffer used as both src and dst — the in-place UB footgun. Must be
    // rejected before any &[u8]/&mut [u8] aliasing forms.
    let mut buf = vec![0u8; LAVA_WG_MAX_DATAGRAM as usize];
    let ptr = buf.as_mut_ptr();
    let mut out_len = 0u32;
    let op = unsafe {
        lava_wg_encapsulate(a, ptr, 40, ptr, buf.len() as u32, &mut out_len)
    };
    assert_eq!(op, LAVA_WG_ERR_INVALID_ARGUMENT, "overlap rejected (encapsulate)");
    let op = unsafe {
        lava_wg_decapsulate(
            b,
            ptr,
            40,
            std::ptr::null(),
            0,
            ptr,
            buf.len() as u32,
            &mut out_len,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    assert_eq!(op, LAVA_WG_ERR_INVALID_ARGUMENT, "overlap rejected (decapsulate)");

    unsafe {
        lava_wg_session_free(a);
        lava_wg_session_free(b);
    }
}

#[test]
fn abi_overhead_matches_engine() {
    // Behavioral pin: transport ciphertext is exactly plaintext +
    // LAVA_WG_DATA_OVERHEAD. If the vendored engine's DATA_OVERHEAD_SZ ever
    // changes (fork/upgrade), the ABI constant that sizes every buffer check
    // must change with it — this test is that link.
    let (a, b) = established_pair();
    let payload = ipv4_packet();
    let mut enc = Buf::new();
    let (op, enc_len) = encap(a, &payload, &mut enc);
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_NETWORK);
    assert_eq!(
        enc_len as usize - payload.len(),
        LAVA_WG_DATA_OVERHEAD as usize,
        "WG transport overhead == LAVA_WG_DATA_OVERHEAD"
    );
    unsafe {
        lava_wg_session_free(a);
        lava_wg_session_free(b);
    }
}

#[test]
fn control_calls_enforce_the_control_minimum() {
    let (a, b) = established_pair();
    let mut tiny = [0u8; (LAVA_WG_MIN_CONTROL_DST as usize) - 1]; // 147
    let mut out_len = 0u32;
    let op = unsafe { lava_wg_tick(a, tiny.as_mut_ptr(), tiny.len() as u32, &mut out_len) };
    assert_eq!(op, LAVA_WG_ERR_DESTINATION_BUFFER_TOO_SMALL);
    let op =
        unsafe { lava_wg_force_handshake(a, tiny.as_mut_ptr(), tiny.len() as u32, &mut out_len) };
    assert_eq!(op, LAVA_WG_ERR_DESTINATION_BUFFER_TOO_SMALL);

    unsafe {
        lava_wg_session_free(a);
        lava_wg_session_free(b);
    }
}

#[test]
fn force_handshake_fills_exactly_the_control_minimum() {
    // Pins LAVA_WG_MIN_CONTROL_DST == the engine's handshake-initiation size:
    // a dst of exactly the minimum must succeed AND produce a full initiation.
    // If a fork grows the message, this fails instead of silently making every
    // control-sized caller buffer under-provisioned.
    let (a_priv, a_pub) = keypair(5);
    let (_b_priv, b_pub) = keypair(6);
    let a = unsafe { lava_wg_session_new(a_priv.as_ptr(), b_pub.as_ptr(), std::ptr::null(), 0, 1) };
    let mut exact = [0u8; LAVA_WG_MIN_CONTROL_DST as usize];
    let mut out_len = 0u32;
    let op = unsafe {
        lava_wg_force_handshake(a, exact.as_mut_ptr(), exact.len() as u32, &mut out_len)
    };
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_NETWORK);
    assert_eq!(
        out_len, LAVA_WG_MIN_CONTROL_DST,
        "initiation exactly fills the control minimum"
    );
    let _ = a_pub;
    unsafe { lava_wg_session_free(a) };
}

#[test]
fn invalid_arguments_and_sentinels() {
    let (a_priv, a_pub) = keypair(3);

    // Construction null-key cases.
    let s = unsafe {
        lava_wg_session_new(std::ptr::null(), a_pub.as_ptr(), std::ptr::null(), 0, 1)
    };
    assert!(s.is_null());
    let s = unsafe {
        lava_wg_session_new(a_priv.as_ptr(), std::ptr::null(), std::ptr::null(), 0, 1)
    };
    assert!(s.is_null());

    let (_b_priv, b_pub) = keypair(4);
    let a = unsafe { lava_wg_session_new(a_priv.as_ptr(), b_pub.as_ptr(), std::ptr::null(), 0, 1) };
    assert!(!a.is_null());

    let mut buf = Buf::new();
    let mut out_len = 0u32;

    // Null session / null dst / null out_len.
    let op = unsafe {
        lava_wg_tick(std::ptr::null_mut(), buf.0.as_mut_ptr(), buf.0.len() as u32, &mut out_len)
    };
    assert_eq!(op, LAVA_WG_ERR_INVALID_ARGUMENT);
    let op = unsafe { lava_wg_tick(a, std::ptr::null_mut(), 2048, &mut out_len) };
    assert_eq!(op, LAVA_WG_ERR_INVALID_ARGUMENT);
    let op = unsafe {
        lava_wg_tick(a, buf.0.as_mut_ptr(), buf.0.len() as u32, std::ptr::null_mut())
    };
    assert_eq!(op, LAVA_WG_ERR_INVALID_ARGUMENT);

    // Null src with a nonzero length.
    let op = unsafe {
        lava_wg_encapsulate(
            a,
            std::ptr::null(),
            8,
            buf.0.as_mut_ptr(),
            buf.0.len() as u32,
            &mut out_len,
        )
    };
    assert_eq!(op, LAVA_WG_ERR_INVALID_ARGUMENT);

    // Mismatched address out-param pair.
    let mut addr = [0u8; 16];
    let op = unsafe {
        lava_wg_decapsulate(
            a,
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            buf.0.as_mut_ptr(),
            buf.0.len() as u32,
            &mut out_len,
            addr.as_mut_ptr(),
            std::ptr::null_mut(),
        )
    };
    assert_eq!(op, LAVA_WG_ERR_INVALID_ARGUMENT);

    // Stats null cases + both sentinels on a fresh (never-handshaked) session.
    let op = unsafe { lava_wg_session_stats(a, std::ptr::null_mut()) };
    assert_eq!(op, LAVA_WG_ERR_INVALID_ARGUMENT);
    let mut stats = LavaWGStats {
        time_since_last_handshake_ms: 0,
        tx_bytes: 0,
        rx_bytes: 0,
        estimated_loss: 0.0,
        estimated_rtt_ms: 0,
    };
    let op = unsafe { lava_wg_session_stats(std::ptr::null_mut(), &mut stats) };
    assert_eq!(op, LAVA_WG_ERR_INVALID_ARGUMENT);
    let op = unsafe { lava_wg_session_stats(a, &mut stats) };
    assert_eq!(op, LAVA_WG_OP_NONE);
    assert_eq!(stats.time_since_last_handshake_ms, -1, "no handshake ⇒ -1");
    assert_eq!(stats.estimated_rtt_ms, -1, "unknown rtt ⇒ -1");

    // Free-null is a no-op; real free closes out.
    unsafe {
        lava_wg_session_free(std::ptr::null_mut());
        lava_wg_session_free(a);
    }
}

#[test]
fn protocol_garbage_is_a_per_packet_error() {
    let (a, b) = established_pair();
    // 200 bytes of garbage that parses as no valid WG message type.
    let garbage = [0xABu8; 200];
    let mut dst = Buf::new();
    let (op, produced) = decap(b, &garbage, &mut dst, None);
    assert_eq!(op, LAVA_WG_ERR_PROTOCOL, "malformed datagram ⇒ per-packet PROTOCOL error");
    assert_eq!(produced, 0);

    // The session survives: a real round-trip still works afterwards.
    let payload = ipv4_packet();
    let mut enc = Buf::new();
    let (op, enc_len) = encap(a, &payload, &mut enc);
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_NETWORK);
    let mut dec = Buf::new();
    let (op, _) = decap(b, &enc.0[..enc_len as usize], &mut dec, None);
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_TUNNEL_V4, "session survives garbage");

    unsafe {
        lava_wg_session_free(a);
        lava_wg_session_free(b);
    }
}

#[test]
fn an_oversized_inbound_datagram_is_rejected_before_it_can_panic_the_engine() {
    // Companion to the drain regression above, and the more dangerous half: that one
    // needed a packet WE queued, this one needs only a hostile UDP sender.
    //
    // The engine writes a type-4 datagram's plaintext into `dst` and panics when
    // `ct_len > dst.len()` — before authentication and before the receiver index is
    // fully compared. Under the release profile that panic aborts the extension, so a
    // fixed `dst_cap >= LAVA_WG_MAX_DATAGRAM` minimum is not enough on its own: it says
    // nothing about how large the INBOUND datagram is. Anyone able to reach our UDP port
    // could drop the tunnel with one packet.
    let (a, b) = established_pair();

    // Shaped as a type-4 transport datagram, larger than the destination buffer.
    //
    // The receiver index matters: handle_data indexes sessions[r_idx % 8] and returns
    // NoCurrentSession for an empty slot, so a zero index would be rejected before the
    // panic and the test would pass vacuously. Sweeping all eight slots guarantees the
    // occupied one is hit — which is also the attacker's cost here: eight packets, no
    // key knowledge, because the size check at session.rs:242 precedes BOTH the
    // receiver_idx comparison at :246 and any authentication.
    let mut oversized = vec![0u8; (LAVA_WG_MAX_DATAGRAM as usize) + 64];
    oversized[0] = 4; // WireGuard message type: transport data

    for slot in 0u8..8 {
        oversized[4] = slot; // receiver index, little-endian low byte

    // Buf is deliberately larger than the contract, so the cap is passed explicitly —
    // the caller's real buffer is exactly LAVA_WG_MAX_DATAGRAM.
        let mut dst = Buf::new();
        let mut out_len = 0u32;
        let op = unsafe {
            lava_wg_decapsulate(
                a,
                oversized.as_ptr(),
                oversized.len() as u32,
                std::ptr::null(),
                0,
                dst.0.as_mut_ptr(),
                LAVA_WG_MAX_DATAGRAM,
                &mut out_len,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(
            op, LAVA_WG_ERR_DESTINATION_BUFFER_TOO_SMALL,
            "an over-buffer datagram must be refused at the boundary (slot {slot}), never handed to the engine"
        );
    }

    // The session survives: refusing one datagram is a per-packet verdict, not a
    // session-level fault. A rejection that poisoned the session would hand the same
    // attacker a cheaper denial of service.
    let payload = ipv4_packet();
    let mut sealed = Buf::new();
    let (op, sealed_len) = encap(a, &payload, &mut sealed);
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_NETWORK, "session still usable after the rejection");

    let mut opened = Buf::new();
    let (op, opened_len) = decap(b, &sealed.0[..sealed_len as usize], &mut opened, None);
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_TUNNEL_V4);
    assert_eq!(&opened.0[..opened_len as usize], &payload[..]);

    unsafe {
        lava_wg_session_free(a);
        lava_wg_session_free(b);
    }
}

/// The peer address is what boringtun's DoS mitigation runs on, so the encoding has to be
/// exact: a wrong length must be refused rather than guessed at, because feeding the
/// limiter a bogus address is worse than admitting we have none.
#[test]
fn peer_address_length_must_be_zero_four_or_sixteen() {
    let (a, _b) = established_pair();
    let mut dst = Buf::new();
    let mut out_len = 0u32;
    let v4 = [192u8, 0, 2, 1];
    let v6 = [0x20u8, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1];

    // Accepted lengths. A drain call (empty source) is enough to exercise the decode
    // without needing a real datagram.
    for (ptr, len) in [
        (std::ptr::null(), 0u32),
        (v4.as_ptr(), 4u32),
        (v6.as_ptr(), 16u32),
    ] {
        let op = unsafe {
            lava_wg_decapsulate(
                a, std::ptr::null(), 0, ptr, len,
                dst.0.as_mut_ptr(), dst.0.len() as u32, &mut out_len,
                std::ptr::null_mut(), std::ptr::null_mut(),
            )
        };
        assert_ne!(
            op, LAVA_WG_ERR_INVALID_ARGUMENT,
            "a {len}-byte peer address should be accepted"
        );
    }

    // Rejected lengths, including ones that look plausible.
    for len in [1u32, 3, 5, 8, 15, 17, 32, u32::MAX] {
        let op = unsafe {
            lava_wg_decapsulate(
                a, std::ptr::null(), 0, v6.as_ptr(), len,
                dst.0.as_mut_ptr(), dst.0.len() as u32, &mut out_len,
                std::ptr::null_mut(), std::ptr::null_mut(),
            )
        };
        assert_eq!(
            op, LAVA_WG_ERR_INVALID_ARGUMENT,
            "a {len}-byte peer address should be rejected, not guessed at"
        );
    }

    // NULL with a positive length is the one combination that would read unmapped memory.
    for len in [4u32, 16] {
        let op = unsafe {
            lava_wg_decapsulate(
                a, std::ptr::null(), 0, std::ptr::null(), len,
                dst.0.as_mut_ptr(), dst.0.len() as u32, &mut out_len,
                std::ptr::null_mut(), std::ptr::null_mut(),
            )
        };
        assert_eq!(op, LAVA_WG_ERR_INVALID_ARGUMENT, "NULL with len {len} must be refused");
    }
}

/// Supplying an address must not change the outcome of an ordinary exchange — the
/// parameter feeds the rate limiter, it does not gate the data path.
#[test]
fn supplying_a_peer_address_does_not_disturb_a_normal_handshake() {
    let (a_priv, a_pub) = keypair(11);
    let (b_priv, b_pub) = keypair(12);
    let a =
        unsafe { lava_wg_session_new(a_priv.as_ptr(), b_pub.as_ptr(), std::ptr::null(), 25, 1) };
    let b =
        unsafe { lava_wg_session_new(b_priv.as_ptr(), a_pub.as_ptr(), std::ptr::null(), 25, 2) };
    assert!(!a.is_null() && !b.is_null());

    let mut wire = Buf::new();
    let mut wire_len = 0u32;
    let op = unsafe {
        lava_wg_force_handshake(a, wire.0.as_mut_ptr(), wire.0.len() as u32, &mut wire_len)
    };
    assert_eq!(op, LAVA_WG_OP_WRITE_TO_NETWORK, "handshake initiation");

    let v4 = [198u8, 51, 100, 7];
    let mut reply = Buf::new();
    let mut out_len = 0u32;
    let op = unsafe {
        lava_wg_decapsulate(
            b,
            wire.0.as_ptr(),
            wire_len,
            v4.as_ptr(),
            4,
            reply.0.as_mut_ptr(),
            reply.0.len() as u32,
            &mut out_len,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    assert_eq!(
        op, LAVA_WG_OP_WRITE_TO_NETWORK,
        "the responder should answer the initiation when given a source address"
    );
    assert!(out_len > 0, "the handshake response should carry bytes");
}

/// The reason the parameter exists: with an address the engine can answer a flood with a
/// COOKIE challenge; without one it hard-fails.
///
/// boringtun counts every MAC1-valid handshake packet against PEER_HANDSHAKE_RATE_LIMIT
/// (10 per second). Past that it wants to reply with a cookie the sender must echo back,
/// proving it holds the address it claims — and that path needs an address. Passing None
/// short-circuits it to Err(UnderLoad) instead, which is what made a replayed handshake
/// flood able to starve the real handshake and drive the tunnel to DNS-only.
///
/// Replay needs no forgery: the same captured initiation is MAC1-valid every time, which
/// is exactly what this test does.
#[test]
fn a_handshake_flood_gets_a_cookie_when_the_peer_address_is_known() {
    fn flood(with_address: bool) -> Vec<(i32, Vec<u8>)> {
        let (a_priv, a_pub) = keypair(21);
        let (b_priv, b_pub) = keypair(22);
        let a = unsafe {
            lava_wg_session_new(a_priv.as_ptr(), b_pub.as_ptr(), std::ptr::null(), 25, 1)
        };
        let b = unsafe {
            lava_wg_session_new(b_priv.as_ptr(), a_pub.as_ptr(), std::ptr::null(), 25, 2)
        };
        let mut wire = Buf::new();
        let mut wire_len = 0u32;
        let op = unsafe {
            lava_wg_force_handshake(a, wire.0.as_mut_ptr(), wire.0.len() as u32, &mut wire_len)
        };
        assert_eq!(op, LAVA_WG_OP_WRITE_TO_NETWORK);
        let initiation = wire.0[..wire_len as usize].to_vec();

        let v4 = [203u8, 0, 113, 9];
        let (addr_ptr, addr_len) = if with_address {
            (v4.as_ptr(), 4u32)
        } else {
            (std::ptr::null(), 0u32)
        };

        // Replay the SAME initiation well past the limit, keeping what each call produced
        // rather than only its status: the point is what the engine SENDS back.
        let mut results: Vec<(i32, Vec<u8>)> = Vec::new();
        for _ in 0..15 {
            let mut dst = Buf::new();
            let mut out_len = 0u32;
            let op = unsafe {
                lava_wg_decapsulate(
                    b,
                    initiation.as_ptr(),
                    initiation.len() as u32,
                    addr_ptr,
                    addr_len,
                    dst.0.as_mut_ptr(),
                    dst.0.len() as u32,
                    &mut out_len,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                )
            };
            results.push((op, dst.0[..out_len as usize].to_vec()));
        }
        unsafe {
            lava_wg_session_free(a);
            lava_wg_session_free(b);
        }
        results
    }

    let without = flood(false);
    let with = flood(true);

    assert!(
        without.iter().any(|(op, _)| *op == LAVA_WG_ERR_UNDER_LOAD),
        "without an address the limiter should hard-fail; got {:?}",
        without.iter().map(|(op, _)| *op).collect::<Vec<_>>()
    );

    // POSITIVE assertion, deliberately. Requiring merely the ABSENCE of UNDER_LOAD would
    // pass for any other outcome — a run of protocol errors, or plain NONE results — none
    // of which mitigates anything. What proves the mitigation is the engine actually
    // EMITTING a cookie reply: WireGuard message type 3, 64 bytes
    // (4 type/reserved + 4 receiver index + 24 nonce + 32 encrypted cookie).
    const COOKIE_REPLY_TYPE: u8 = 3;
    const COOKIE_REPLY_LEN: usize = 64;
    let cookies = with
        .iter()
        .filter(|(op, bytes)| {
            *op == LAVA_WG_OP_WRITE_TO_NETWORK
                && bytes.len() == COOKIE_REPLY_LEN
                && bytes[0] == COOKIE_REPLY_TYPE
        })
        .count();
    assert!(
        cookies > 0,
        "with an address the engine should EMIT cookie replies (type 3, 64 bytes); got {:?}",
        with.iter().map(|(op, b)| (*op, b.len(), b.first().copied())).collect::<Vec<_>>()
    );
    assert!(
        !with.iter().any(|(op, _)| *op == LAVA_WG_ERR_UNDER_LOAD),
        "with an address the engine should not hard-fail"
    );
}

/// A transport datagram whose counter is at or above REJECT_AFTER_MESSAGES never reaches the
/// engine.
///
/// boringtun 0.7.1 does not enforce the limit — every constant in `noise/timers.rs` is a
/// `Duration` — and `noise/session.rs` then does unchecked `u64` arithmetic on this
/// peer-supplied field: `counter + N_BITS < self.next`, and `self.next = counter + 1`. The
/// release profile sets `panic = "abort"` but not `overflow-checks`, so a counter near
/// `u64::MAX` wraps rather than trapping, `will_accept`'s `counter >= self.next` then admits
/// everything, and the anti-replay window is gone for the rest of that session.
///
/// Reaching the vulnerable arithmetic needs the session key, so this is the compromised-upstream
/// case — which is the threat model for a client that routes every packet through one peer.
#[test]
fn a_transport_counter_past_the_specification_limit_is_refused() {
    let (a, b) = established_pair();
    let mut out = Buf::new();
    let mut out_len = 0u32;

    // A well-formed type-4 header is enough: the refusal must precede the engine, so it also
    // precedes decryption. The counter is the only field under test.
    let mut datagram = vec![0u8; 64];
    datagram[0] = 4;
    datagram[8..16].copy_from_slice(&u64::MAX.to_le_bytes());

    let rc = unsafe {
        lava_wg_decapsulate(
            b,
            datagram.as_ptr(),
            datagram.len() as u32,
            std::ptr::null(),
            0,
            out.0.as_mut_ptr(),
            out.0.len() as u32,
            &mut out_len,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    assert_eq!(
        rc, LAVA_WG_ERR_PROTOCOL,
        "a counter of u64::MAX reached the engine, where `self.next = counter + 1` overflows and \
         disables the replay window for the life of the session"
    );

    // THE BOUNDARY IS NOT ASSERTED HERE, and the reason is the same one that moved the type
    // discrimination out of this file: a crafted below-limit datagram has a zero receiver index
    // and no valid AEAD tag, so the engine refuses it with the SAME code our guard returns. An
    // `assert_ne!` on that is an assertion with no failing case. The boundary is pinned where it
    // is observable — `the_ceiling_is_the_specification_value_and_is_inclusive` in `src/lib.rs`,
    // against the literal specification value (Codex, PR #496).

    // The type discrimination — a handshake message has no counter field — cannot be asserted
    // through this door: the engine answers a malformed handshake with the same
    // `LAVA_WG_ERR_PROTOCOL` this guard returns, so the two are indistinguishable by return code.
    // It is a unit test on `is_transport_counter_out_of_range` in `src/lib.rs` instead.

    unsafe {
        lava_wg_session_free(a);
        lava_wg_session_free(b);
    }
}
