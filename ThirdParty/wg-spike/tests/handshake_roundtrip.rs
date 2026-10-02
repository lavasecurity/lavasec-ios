// THROWAWAY SPIKE test — proves the C ABI drives a real boringtun handshake and a
// transport round-trip. This is the GREEN evidence that the FFI surface the Swift side
// binds against is wired correctly; it is NOT the on-device memory/throughput
// measurement (that requires a physical device — see the spike README).

use lavasec_wg_spike::{
    wg_spike_decapsulate, wg_spike_encapsulate, wg_spike_force_handshake, wg_spike_session_free,
    wg_spike_session_new, WG_SPIKE_OP_NONE as OP_NONE,
    WG_SPIKE_OP_WRITE_TO_NETWORK as OP_WRITE_TO_NETWORK,
    WG_SPIKE_OP_WRITE_TO_TUNNEL_V4 as OP_WRITE_TO_TUNNEL_V4,
};

// x25519 keypairs generated deterministically for the test (clamped scalars). We derive
// the public keys through boringtun's own x25519 so we do not hand-roll curve math.
fn keypair(seed: u8) -> ([u8; 32], [u8; 32]) {
    let secret = boringtun::x25519::StaticSecret::from([seed; 32]);
    let public = boringtun::x25519::PublicKey::from(&secret);
    (secret.to_bytes(), public.to_bytes())
}

struct Buf([u8; 2048]);
impl Buf {
    fn new() -> Self {
        Buf([0u8; 2048])
    }
}

#[test]
fn handshake_and_transport_roundtrip_through_c_abi() {
    let (a_priv, a_pub) = keypair(1);
    let (b_priv, b_pub) = keypair(2);

    let a = unsafe {
        wg_spike_session_new(a_priv.as_ptr(), b_pub.as_ptr(), std::ptr::null(), 25, 1)
    };
    let b = unsafe {
        wg_spike_session_new(b_priv.as_ptr(), a_pub.as_ptr(), std::ptr::null(), 25, 2)
    };
    assert!(!a.is_null() && !b.is_null(), "session construction failed");

    // A initiates.
    let mut wire = Buf::new();
    let mut wire_len: u32 = 0;
    let op = unsafe {
        wg_spike_force_handshake(a, wire.0.as_mut_ptr(), wire.0.len() as u32, &mut wire_len)
    };
    assert_eq!(op, OP_WRITE_TO_NETWORK, "handshake init must produce a wire packet");
    assert!(wire_len > 0);

    // B receives the init; boringtun answers with the handshake response.
    let mut resp = Buf::new();
    let mut resp_len: u32 = 0;
    let op = unsafe {
        wg_spike_decapsulate(
            b,
            wire.0.as_ptr(),
            wire_len,
            resp.0.as_mut_ptr(),
            resp.0.len() as u32,
            &mut resp_len,
        )
    };
    assert_eq!(op, OP_WRITE_TO_NETWORK, "handshake response expected");
    assert!(resp_len > 0);

    // A consumes the response and emits a keepalive (WG's 4th handshake leg). That
    // keepalive MUST reach B or B never finalizes its session and rejects data.
    let mut keepalive = Buf::new();
    let mut keepalive_len: u32 = 0;
    let op = unsafe {
        wg_spike_decapsulate(
            a,
            resp.0.as_ptr(),
            resp_len,
            keepalive.0.as_mut_ptr(),
            keepalive.0.len() as u32,
            &mut keepalive_len,
        )
    };
    assert_eq!(op, OP_WRITE_TO_NETWORK, "handshake completion keepalive expected");
    assert!(keepalive_len > 0);

    // B consumes the keepalive; its session is now established (Done).
    let mut sink = Buf::new();
    let mut sink_len: u32 = 0;
    let op = unsafe {
        wg_spike_decapsulate(
            b,
            keepalive.0.as_ptr(),
            keepalive_len,
            sink.0.as_mut_ptr(),
            sink.0.len() as u32,
            &mut sink_len,
        )
    };
    assert_eq!(op, OP_NONE, "keepalive finalizes B's session");

    // A now encapsulates a well-formed IPv4 packet. boringtun's decapsulate validates
    // the decrypted bytes as IP and truncates to the header's total-length field, so the
    // length field (bytes 2-3) must equal the real length for a byte-exact round-trip.
    let mut payload: [u8; 40] = [0u8; 40];
    payload[0] = 0x45; // IPv4, IHL 5
    payload[2] = 0x00;
    payload[3] = 40; // total length = 40
    payload[9] = 17; // protocol = UDP
    payload[12..16].copy_from_slice(&[192, 168, 1, 2]); // src
    payload[16..20].copy_from_slice(&[192, 168, 1, 3]); // dst
    for (i, byte) in payload.iter_mut().enumerate().skip(20) {
        *byte = i as u8; // recognizable body
    }
    let mut enc = Buf::new();
    let mut enc_len: u32 = 0;
    let op = unsafe {
        wg_spike_encapsulate(
            a,
            payload.as_ptr(),
            payload.len() as u32,
            enc.0.as_mut_ptr(),
            enc.0.len() as u32,
            &mut enc_len,
        )
    };
    assert_eq!(op, OP_WRITE_TO_NETWORK, "established session must encrypt payload");
    assert!(enc_len as usize > payload.len(), "ciphertext carries WG overhead");

    // B decapsulates back to the original plaintext.
    let mut dec = Buf::new();
    let mut dec_len: u32 = 0;
    let op = unsafe {
        wg_spike_decapsulate(
            b,
            enc.0.as_ptr(),
            enc_len,
            dec.0.as_mut_ptr(),
            dec.0.len() as u32,
            &mut dec_len,
        )
    };
    assert_eq!(op, OP_WRITE_TO_TUNNEL_V4, "decrypted IPv4 packet expected");
    assert_eq!(&dec.0[..dec_len as usize], &payload[..], "round-trip must be byte-exact");

    unsafe {
        wg_spike_session_free(a);
        wg_spike_session_free(b);
    }
}

#[test]
fn null_key_construction_returns_null() {
    let session = unsafe {
        wg_spike_session_new(std::ptr::null(), std::ptr::null(), std::ptr::null(), 0, 1)
    };
    assert!(session.is_null());
}
