import Foundation

/// A failure reported by the WireGuard engine across the C ABI.
///
/// Negative ABI codes split into two families that Phase-3 callers must treat
/// differently: `protocolViolation` is a *per-packet* verdict (drop the datagram and
/// keep the session), while `connectionExpired` is the session-level reconnect
/// escalation signal. Conflating them produces the reconnect storms the LAV-80 class
/// of bugs is made of.
public enum WireGuardEngineError: Error, Equatable, Sendable {
    /// A null pointer, a malformed argument pair, or overlapping `src`/`dst` buffers.
    case invalidArgument
    /// The destination buffer was smaller than the call's documented minimum.
    case destinationBufferTooSmall
    /// A data-path call ran with no established session (handshake incomplete or expired).
    case noCurrentSession
    /// The peer or its rate limiter is under load; retry after a backoff.
    case underLoad
    /// One datagram failed parse or authentication. Drop it and continue.
    case protocolViolation
    /// An inbound datagram larger than ``WireGuardSession/maximumDatagramByteCount``.
    ///
    /// A per-packet verdict like ``protocolViolation``, and separated from
    /// ``destinationBufferTooSmall`` on purpose. Both used to surface as the latter, which
    /// made a datagram whose size a REMOTE sender chose look identical to our own buffer
    /// being mis-sized — so a consumer could reasonably read hostile traffic as a caller
    /// bug and tear the session down. The size is not ours to control; the buffer is.
    case oversizedDatagram
    /// The session passed its rekey/reject deadline — the reconnect escalation signal.
    case connectionExpired
    /// An engine-internal failure (for example a lock poisoned by an earlier fault).
    case engineInternal
    /// An outbound packet exceeded ``WireGuardSession/maximumIPPacketByteCount``.
    case packetTooLarge
    /// The engine refused to construct a session from the supplied key material.
    case sessionCreationFailed
    /// The engine returned a code this wrapper does not know — treat as fatal and
    /// resynchronize the wrapper with the ABI header.
    case unrecognized(code: Int32)

    init?(code: Int32) {
        switch code {
        case WireGuardABI.errInvalidArgument: self = .invalidArgument
        case WireGuardABI.errDestinationBufferTooSmall: self = .destinationBufferTooSmall
        case WireGuardABI.errNoCurrentSession: self = .noCurrentSession
        case WireGuardABI.errUnderLoad: self = .underLoad
        case WireGuardABI.errProtocol: self = .protocolViolation
        case WireGuardABI.errConnectionExpired: self = .connectionExpired
        case WireGuardABI.errInternal: self = .engineInternal
        case WireGuardABI.errPacketTooLarge: self = .packetTooLarge
        default:
            guard code < 0 else { return nil }
            self = .unrecognized(code: code)
        }
    }
}

/// What a completed engine call produced in the caller's destination buffer.
public enum WireGuardOperation: Equatable, Sendable {
    /// Nothing to emit; the engine advanced its own state. Also ends a drain loop.
    case none
    /// The buffer holds a datagram that must be sent to the peer.
    case writeToNetwork(byteCount: Int)
    /// The buffer holds a decrypted IPv4 packet for the tunnel.
    case writeToTunnelIPv4(byteCount: Int)
    /// The buffer holds a decrypted IPv6 packet for the tunnel.
    case writeToTunnelIPv6(byteCount: Int)

    /// Bytes written into the destination buffer; zero for ``none``.
    public var byteCount: Int {
        switch self {
        case .none: return 0
        case let .writeToNetwork(count), let .writeToTunnelIPv4(count), let .writeToTunnelIPv6(count):
            return count
        }
    }
}

/// The source address of a decrypted inner packet. Capture is allocation-free (the bytes
/// land in inline storage the caller reuses), so Phase-3's allowed-IPs check can run per
/// packet without churn; only ``octets`` allocates, and it exists for diagnostics.
/// The UDP endpoint an inbound datagram arrived FROM.
///
/// Not to be confused with ``WireGuardSourceAddress``, which is the source IP of the
/// decrypted INNER packet. They are different addresses answering different questions —
/// this one is "who sent us this", that one is "who does the plaintext claim to be from" —
/// and a separate type is what stops them being passed to each other's parameter.
///
/// ## Supply it whenever you have it
///
/// This is not a diagnostic. It is what boringtun's DoS mitigation runs on. Above
/// `PEER_HANDSHAKE_RATE_LIMIT` (10 handshake packets/second) the engine wants to answer
/// with a COOKIE the sender must echo back, proving it holds the address it claims — and
/// that path needs an address. With ``unknown`` the limiter short-circuits to a hard
/// `underLoad` error instead, while its counter keeps incrementing on every MAC1-valid
/// handshake packet, our own legitimate ones included.
///
/// The gap is remotely exploitable and cheap: replaying a captured handshake needs no
/// forgery, so a flood above that rate starves the real handshake, the tunnel holds
/// `0.0.0.0/0` and `::/0` forwarding nothing until `REKEY_ATTEMPT_TIME` (90 s), and the
/// reconnect budget then surrenders chained mode for the rest of the lifecycle.
///
/// ``unknown`` remains available because a caller may genuinely not have the address and
/// inventing one would be worse. It is not the safe default.
/// pinned: WireGuardSessionTests.testAHandshakeFloodIsAnsweredWithCookiesWhenThePeerIsKnown
public struct WireGuardPeerAddress: Equatable, Sendable {
    private var storage: (UInt64, UInt64) = (0, 0)

    /// Significant bytes: 4 for IPv4, 16 for IPv6, 0 when the address is not known.
    public private(set) var byteCount: Int = 0

    /// No address available. Legal, and weaker — see the type's documentation.
    public static let unknown = WireGuardPeerAddress()

    private init() {}

    /// Wraps 4 (IPv4) or 16 (IPv6) octets in network order. Any other length is rejected
    /// rather than padded, because a wrong address feeds the rate limiter a lie.
    public init?(octets: [UInt8]) {
        guard octets.count == 4 || octets.count == 16 else { return nil }
        byteCount = octets.count
        withUnsafeMutableBytes(of: &storage) { raw in
            raw.copyBytes(from: octets)
        }
    }

    /// Wraps octets that already exist somewhere else, without allocating an `Array` to
    /// carry them.
    ///
    /// Same acceptance rule as ``init(octets:)`` — 4 or 16 bytes, rejected rather than
    /// padded — and it exists for one reason: the array form is an allocation, and the
    /// data path would otherwise pay it on a hot path. In practice the chained runner
    /// builds a peer address ONCE per channel generation rather than per datagram, because
    /// a connected socket makes provenance constant; this initialiser is what makes the
    /// remaining construction sites free, and it keeps ``octets`` — which allocates and
    /// says so — off the data path entirely.
    public init?(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        byteCount = bytes.count
        withUnsafeMutableBytes(of: &storage) { raw in
            raw.copyBytes(from: bytes)
        }
    }

    /// The octets in network order, or empty when unknown. Allocates — diagnostics only.
    public var octets: [UInt8] {
        guard byteCount > 0 else { return [] }
        return withUnsafeBytes(of: storage) { Array($0.prefix(byteCount)) }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.byteCount == rhs.byteCount && lhs.storage == rhs.storage
    }

    func withUnsafeOctets<Result>(
        _ body: (UnsafePointer<UInt8>?, UInt32) throws -> Result
    ) rethrows -> Result {
        guard byteCount > 0 else { return try body(nil, 0) }
        return try withUnsafeBytes(of: storage) { raw in
            // SCOPED rebind, for the same reason `withMutableStorage` below uses one:
            // `bindMemory` rebinds PERMANENTLY, so after this returns every later typed
            // access to `storage` as its declared `(UInt64, UInt64)` — including the
            // implicit ones a struct copy or an `==` performs — would touch memory bound to
            // something else, which optimized builds may miscompile. This value is a
            // let-bound property the caller keeps using, so only the restoring form is sound.
            try raw.withMemoryRebound(to: UInt8.self) { octets in
                try body(octets.baseAddress, UInt32(byteCount))
            }
        }
    }
}

public struct WireGuardSourceAddress: Equatable, Sendable {
    private var storage: (UInt64, UInt64) = (0, 0)

    /// Significant bytes: 4 for IPv4, 16 for IPv6, 0 when nothing was captured.
    public private(set) var byteCount: Int = 0

    /// Creates an empty address for reuse across calls.
    public init() {}

    /// The captured octets in network order, or an empty array when nothing was captured.
    /// Allocates — call it only off the hot path (diagnostics, tests, logging).
    public var octets: [UInt8] {
        guard byteCount > 0 else { return [] }
        return withUnsafeBytes(of: storage) { Array($0.prefix(byteCount)) }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.byteCount == rhs.byteCount && lhs.storage == rhs.storage
    }

    /// This address as a 32-bit IPv4 value in host order, or `nil` when it is not IPv4.
    ///
    /// Allocation-free, for the reason ``withUnsafeOctets(_:)`` exists: the reachability
    /// accounting reads this on every delivered packet, and `octets` allocates. `WireGuardPeerAddress`
    /// deliberately has no counterpart — the peer is the tunnel's own endpoint, not a destination
    /// anything is waiting on, and its `withUnsafeOctets` is the pointer-plus-length C ABI form
    /// rather than this one.
    public var ipv4Address: UInt32? {
        guard byteCount == 4 else { return nil }
        return withUnsafeOctets { octets in
            (UInt32(octets[0]) << 24) | (UInt32(octets[1]) << 16) | (UInt32(octets[2]) << 8)
                | UInt32(octets[3])
        }
    }

    /// The captured octets, without allocating.
    ///
    /// `octets` allocates and says so, which is fine for diagnostics and wrong for the inbound
    /// packet path: the AllowedIPs check runs on every decrypted packet, inside a process
    /// bounded at ~50 MB, and a per-packet array allocation defeats the point of a check whose
    /// job is to be cheap enough to always run.
    ///
    /// Scoped rebind, for the reason spelled out on `withMutableStorage` below: the storage is
    /// declared as `UInt64` and stays usable afterwards, so the binding has to be restored.
    public func withUnsafeOctets<Result>(
        _ body: (UnsafeBufferPointer<UInt8>) throws -> Result
    ) rethrows -> Result {
        try withUnsafeBytes(of: storage) { raw in
            try raw.withMemoryRebound(to: UInt8.self) { bound in
                try body(UnsafeBufferPointer(rebasing: bound.prefix(byteCount)))
            }
        }
    }

    mutating func withMutableStorage<Result>(
        _ body: (UnsafeMutablePointer<UInt8>) throws -> Result
    ) rethrows -> Result {
        try withUnsafeMutableBytes(of: &storage) { raw in
            // SCOPED rebind. `assumingMemoryBound` would be a false promise (the storage is
            // bound to UInt64, not UInt8), but `bindMemory` is wrong in the other
            // direction: it rebinds PERMANENTLY, so every later typed access to `storage`
            // as its declared type — including the implicit ones a struct copy performs —
            // would touch memory bound to something else. `withMemoryRebound` restores the
            // original binding when the closure returns, which is the only form that is
            // sound for storage the caller keeps using afterwards.
            try raw.withMemoryRebound(to: UInt8.self) { bound in
                try body(bound.baseAddress!)
            }
        }
    }

    mutating func setByteCount(_ count: UInt32) {
        byteCount = Int(count)
    }
}

/// A point-in-time view of session health, for the D1 latch's monitoring and QA.
public struct WireGuardStatistics: Equatable, Sendable {
    /// Milliseconds since the last completed handshake, or `nil` when there is no
    /// currently established session (never handshaked, or expired since).
    public let timeSinceLastHandshake: Duration?
    /// Plaintext bytes accepted for encapsulation since the session was created.
    public let transmittedByteCount: UInt64
    /// Plaintext bytes produced by decapsulation since the session was created.
    public let receivedByteCount: UInt64
    /// The engine's packet-loss estimate in `0...1`.
    public let estimatedLoss: Float
    /// The engine's round-trip estimate, or `nil` when unknown.
    public let estimatedRoundTrip: Duration?
}

/// A WireGuard peer session: Noise handshake, transport encapsulation/decapsulation,
/// and timer/rekey management, wrapping the vendored engine's C ABI.
///
/// ## Contracts
///
/// - **Queue confinement.** The engine has no internal concurrency design; confine all
///   calls for one instance to a single serial queue. In the tunnel that is the WG
///   queue — never `dnsStateQueue` (`INV-QUEUE-1`). This type is deliberately not
///   `Sendable`.
/// - **Buffer discipline.** Destination buffers are caller-owned and meant to be reused
///   across calls; this wrapper allocates nothing per packet. The engine does have one
///   bounded exception the consumer must budget for: while no session is current (before
///   the first handshake, or briefly after expiry) it heap-copies each outbound packet
///   into a queue capped at 256 entries, released by ``drain(into:)``. Data-path buffers must hold at
///   least ``maximumDatagramByteCount`` — that single rule is what makes the engine's
///   internal panic paths unreachable, including the drain path, where the engine
///   re-encapsulates a packet it queued earlier whose size is unrelated to the inbound
///   datagram (`INV-MEM-1` sizing lives with the Phase-3 data path).
/// - **Drain.** After any call returns ``WireGuardOperation/writeToNetwork(byteCount:)``
///   from ``decapsulate(_:into:)``, send that datagram and then call ``drain(into:)``
///   repeatedly until it stops returning `writeToNetwork`.
public final class WireGuardSession {
    /// Largest inner IP packet ``encapsulate(_:into:)`` accepts.
    public static let maximumIPPacketByteCount = WireGuardABI.maximumIPPacket
    /// Required capacity for any data-path destination buffer.
    public static let maximumDatagramByteCount = WireGuardABI.maximumDatagram
    /// Required capacity for a control-only destination buffer (tick, handshake).
    public static let minimumControlByteCount = WireGuardABI.minimumControlDestination
    /// Bytes the transport adds to an inner IP packet: `maximumDatagramByteCount` minus
    /// `maximumIPPacketByteCount`.
    ///
    /// Public so a caller can size a buffer, or reason about an MTU, without reaching for
    /// `WireGuardABI` — which is internal to this module, so the arithmetic would otherwise
    /// be re-derived by hand at every call site and drift the moment the constant moved.
    public static let datagramOverheadByteCount =
        WireGuardABI.maximumDatagram - WireGuardABI.maximumIPPacket

    private var handle: UnsafeMutableRawPointer?

    /// Creates a session for one peer.
    ///
    /// The key material is copied into the engine and never retained by this object; the
    /// engine scrubs its own copies, and the caller should zero its arrays once this
    /// returns.
    ///
    /// - Parameters:
    ///   - privateKey: This endpoint's 32-byte X25519 private key.
    ///   - peerPublicKey: The peer's 32-byte X25519 public key.
    ///   - presharedKey: Optional 32-byte preshared key.
    ///   - keepaliveSeconds: Persistent-keepalive period; `0` disables it.
    ///   - index: Local session index used in the WireGuard wire protocol.
    /// - Throws: ``WireGuardEngineError/sessionCreationFailed`` when a key is not exactly
    ///   32 bytes (checked here — the engine reads 32 bytes unconditionally and would
    ///   over-read a short buffer) or when the engine itself refuses construction.
    public init(
        privateKey: [UInt8],
        peerPublicKey: [UInt8],
        presharedKey: [UInt8]? = nil,
        keepaliveSeconds: UInt16 = 0,
        index: UInt32 = 0
    ) throws {
        guard privateKey.count == 32, peerPublicKey.count == 32 else {
            throw WireGuardEngineError.sessionCreationFailed
        }
        if let presharedKey, presharedKey.count != 32 {
            throw WireGuardEngineError.sessionCreationFailed
        }
        let created: UnsafeMutableRawPointer? = privateKey.withUnsafeBufferPointer { privatePointer in
            peerPublicKey.withUnsafeBufferPointer { publicPointer in
                func create(_ preshared: UnsafePointer<UInt8>?) -> UnsafeMutableRawPointer? {
                    lava_wg_session_new(
                        privatePointer.baseAddress,
                        publicPointer.baseAddress,
                        preshared,
                        keepaliveSeconds,
                        index
                    )
                }
                if let presharedKey {
                    return presharedKey.withUnsafeBufferPointer { create($0.baseAddress) }
                }
                return create(nil)
            }
        }
        guard let created else { throw WireGuardEngineError.sessionCreationFailed }
        handle = created
    }

    deinit {
        lava_wg_session_free(handle)
        handle = nil
    }

    /// Emits a handshake initiation so the tunnel comes up without waiting for traffic.
    /// - Parameter buffer: At least ``minimumControlByteCount`` bytes.
    @discardableResult
    public func forceHandshake(into buffer: inout [UInt8]) throws -> WireGuardOperation {
        try requireCapacity(buffer.count, Self.minimumControlByteCount)
        return try run(into: &buffer) { session, destination, capacity, outLength in
            lava_wg_force_handshake(session, destination, capacity, outLength)
        }
    }

    /// Drives handshake retries, keepalives, and rekeys. Call roughly every 250 ms and
    /// send any `writeToNetwork` output to the peer.
    /// - Parameter buffer: At least ``minimumControlByteCount`` bytes.
    @discardableResult
    public func tick(into buffer: inout [UInt8]) throws -> WireGuardOperation {
        try requireCapacity(buffer.count, Self.minimumControlByteCount)
        return try run(into: &buffer) { session, destination, capacity, outLength in
            lava_wg_tick(session, destination, capacity, outLength)
        }
    }

    /// Encrypts one outbound IP packet.
    ///
    /// An empty `packet` emits a keepalive **only while a keypair is current**, and that
    /// qualifier is load-bearing. `Tunn::encapsulate` takes the keepalive branch inside
    /// `if let Some(ref session) = self.sessions[current % N_SESSIONS]`; with no current session
    /// it instead QUEUES the packet — a zero-length one takes a slot like any other — and
    /// returns a handshake initiation, which answers `Done` when a handshake is already in
    /// flight. So an empty encapsulate during a rekey window emits nothing at all, silently.
    ///
    /// This comment previously said "an empty `packet` emits a keepalive" with no qualifier,
    /// and a design was built on it (R2). Check `statistics().timeSinceLastHandshake != nil`
    /// before relying on the keepalive — that is exactly `sessions[current].is_some()`.
    ///
    /// Before the handshake completes the engine queues the packet and returns the
    /// handshake initiation instead; the queued packet is released later by
    /// ``drain(into:)``.
    ///
    /// - Parameters:
    ///   - packet: At most ``maximumIPPacketByteCount`` bytes.
    ///   - buffer: At least ``maximumDatagramByteCount`` bytes; must not alias `packet`.
    @discardableResult
    public func encapsulate(_ packet: [UInt8], into buffer: inout [UInt8]) throws -> WireGuardOperation {
        try packet.withUnsafeBytes { try encapsulate($0, into: &buffer) }
    }

    /// Encrypts one outbound IP packet that already exists in memory somewhere else.
    ///
    /// The overload the data path actually calls. `NEPacketTunnelFlow` hands back `Data`,
    /// and `Data.withUnsafeBytes` yields exactly this — so the packet reaches the engine
    /// without an `Array` being materialised for it. The `[UInt8]` form above now delegates
    /// here, so there is ONE implementation of the FFI call rather than two that can drift.
    ///
    /// Ownership on the pre-handshake path is the engine's, not the caller's: while no
    /// session is current the engine heap-copies the packet into its own 256-entry queue and
    /// releases it through ``drain(into:)``. A caller that ALSO queues the packet stores it
    /// twice and retransmits it on drain. See the type's buffer-discipline note.
    ///
    /// - Parameters:
    ///   - packet: At most ``maximumIPPacketByteCount`` bytes.
    ///   - buffer: At least ``maximumDatagramByteCount`` bytes; must not alias `packet`.
    @discardableResult
    public func encapsulate(
        _ packet: UnsafeRawBufferPointer,
        into buffer: inout [UInt8]
    ) throws -> WireGuardOperation {
        guard packet.count <= Self.maximumIPPacketByteCount else {
            throw WireGuardEngineError.packetTooLarge
        }
        try requireCapacity(buffer.count, Self.maximumDatagramByteCount)
        let source = packet.bindMemory(to: UInt8.self)
        return try run(into: &buffer) { session, destination, capacity, outLength in
            lava_wg_encapsulate(
                session,
                source.baseAddress,
                UInt32(source.count),
                destination,
                capacity,
                outLength
            )
        }
    }

    /// Decrypts one inbound datagram.
    /// - Parameters:
    ///   - datagram: The received bytes.
    ///   - buffer: At least ``maximumDatagramByteCount`` bytes; must not alias `datagram`.
    @discardableResult
    public func decapsulate(
        _ datagram: [UInt8],
        from peer: WireGuardPeerAddress,
        into buffer: inout [UInt8]
    ) throws -> WireGuardOperation {
        try datagram.withUnsafeBytes { try decapsulate($0, from: peer, into: &buffer) }
    }

    /// Decrypts one inbound datagram that already exists in memory somewhere else.
    ///
    /// The overload the data path calls: the socket receives into a reused buffer, and this
    /// hands the engine that buffer directly rather than copying it into an `Array` first.
    /// - Parameters:
    ///   - datagram: The received bytes.
    ///   - buffer: At least ``maximumDatagramByteCount`` bytes; must not alias `datagram`.
    @discardableResult
    public func decapsulate(
        _ datagram: UnsafeRawBufferPointer,
        from peer: WireGuardPeerAddress,
        into buffer: inout [UInt8]
    ) throws -> WireGuardOperation {
        try decapsulate(
            datagram, from: peer, into: &buffer, addressPointer: nil, lengthPointer: nil)
    }

    /// Decrypts one inbound datagram and captures the inner packet's source address for
    /// allowed-IPs enforcement.
    /// - Parameters:
    ///   - datagram: The received bytes.
    ///   - buffer: At least ``maximumDatagramByteCount`` bytes; must not alias `datagram`.
    ///   - address: Receives the inner source address on a `writeToTunnel` result.
    @discardableResult
    public func decapsulate(
        _ datagram: [UInt8],
        from peer: WireGuardPeerAddress,
        into buffer: inout [UInt8],
        capturingSourceAddress address: inout WireGuardSourceAddress
    ) throws -> WireGuardOperation {
        try datagram.withUnsafeBytes {
            try decapsulate($0, from: peer, into: &buffer, capturingSourceAddress: &address)
        }
    }

    /// Decrypts one inbound datagram from borrowed memory and captures the inner packet's
    /// source address for allowed-IPs enforcement.
    ///
    /// The form the chained runner uses on every inbound datagram: `INV-CHAIN-1` claims
    /// `0.0.0.0/0`, so a decrypted packet is delivered into the TUN only after its inner
    /// source is checked against the peer's allowed IPs, and capturing that source is how
    /// the check gets its input without re-parsing the packet.
    /// - Parameters:
    ///   - datagram: The received bytes.
    ///   - buffer: At least ``maximumDatagramByteCount`` bytes; must not alias `datagram`.
    ///   - address: Receives the inner source address on a `writeToTunnel` result.
    @discardableResult
    public func decapsulate(
        _ datagram: UnsafeRawBufferPointer,
        from peer: WireGuardPeerAddress,
        into buffer: inout [UInt8],
        capturingSourceAddress address: inout WireGuardSourceAddress
    ) throws -> WireGuardOperation {
        var captured = WireGuardSourceAddress()
        var capturedLength: UInt32 = 0
        let operation = try withUnsafeMutablePointer(to: &capturedLength) { lengthPointer in
            try captured.withMutableStorage { addressPointer in
                try decapsulate(
                    datagram,
                    from: peer,
                    into: &buffer,
                    addressPointer: addressPointer,
                    lengthPointer: lengthPointer
                )
            }
        }
        captured.setByteCount(capturedLength)
        address = captured
        return operation
    }

    /// Releases work the engine queued while no session was established, and flushes
    /// queued handshake replies. Call repeatedly until it returns ``WireGuardOperation/none``.
    /// - Parameter buffer: At least ``maximumDatagramByteCount`` bytes.
    @discardableResult
    public func drain(into buffer: inout [UInt8]) throws -> WireGuardOperation {
        // A drain has no inbound datagram, so there is no peer to name. This is the one
        // caller for which `.unknown` is correct rather than a concession.
        try decapsulate([], from: .unknown, into: &buffer)
    }

    /// Reads the session-health snapshot.
    public func statistics() throws -> WireGuardStatistics {
        var raw = LavaWGStatsRaw()
        let code = lava_wg_session_stats(handle, &raw)
        if let error = WireGuardEngineError(code: code) { throw error }
        return WireGuardStatistics(
            timeSinceLastHandshake: raw.timeSinceLastHandshakeMilliseconds < 0
                ? nil
                : .milliseconds(raw.timeSinceLastHandshakeMilliseconds),
            transmittedByteCount: raw.txBytes,
            receivedByteCount: raw.rxBytes,
            estimatedLoss: raw.estimatedLoss,
            estimatedRoundTrip: raw.estimatedRoundTripMilliseconds < 0
                ? nil
                : .milliseconds(Int64(raw.estimatedRoundTripMilliseconds))
        )
    }

    // MARK: - Internals

    private func decapsulate(
        _ datagram: UnsafeRawBufferPointer,
        from peer: WireGuardPeerAddress,
        into buffer: inout [UInt8],
        addressPointer: UnsafeMutablePointer<UInt8>?,
        lengthPointer: UnsafeMutablePointer<UInt32>?
    ) throws -> WireGuardOperation {
        try requireCapacity(buffer.count, Self.maximumDatagramByteCount)
        // Reject an over-MTU datagram HERE, so the ABI's
        // `destinationBufferTooSmall` keeps exactly one meaning: our buffer was wrong.
        // The engine returns that same code for `src_len > dst_cap`, a bound on the
        // INBOUND datagram — which any host able to reach our UDP port controls. Letting
        // the two share a case is what would let a remote sender's packet be read as our
        // defect. Checked before the capacity of `datagram` is ever handed across the FFI
        // boundary, so nothing downstream has to disambiguate.
        guard datagram.count <= Self.maximumDatagramByteCount else {
            throw WireGuardEngineError.oversizedDatagram
        }
        let source = datagram.bindMemory(to: UInt8.self)
        return try peer.withUnsafeOctets { peerOctets, peerLength in
            try run(into: &buffer) { session, destination, capacity, outLength in
                lava_wg_decapsulate(
                    session,
                    // Drain is spelled by LENGTH, not by pointer. The engine keys on
                    // `src_len == 0` (its null check only fires when the length is
                    // positive, and its overlap check short-circuits at zero length), so
                    // either pointer value is accepted there. Do not "fix" this to force a
                    // nil source: an empty Swift array does NOT reliably yield a nil
                    // baseAddress — on Darwin it projects the empty-array singleton — and
                    // passing nil with a positive length is the one combination the ABI
                    // rejects. That reasoning is unchanged now the parameter is a raw
                    // buffer: `drain` still spells itself with count 0 and lets the
                    // pointer be whatever the empty projection yields.
                    source.baseAddress,
                    UInt32(source.count),
                    peerOctets,
                    peerLength,
                    destination,
                    capacity,
                    outLength,
                    addressPointer,
                    lengthPointer
                )
            }
        }
    }

    private func requireCapacity(_ actual: Int, _ required: Int) throws {
        guard actual >= required else { throw WireGuardEngineError.destinationBufferTooSmall }
    }

    private func run(
        into buffer: inout [UInt8],
        _ call: (
            UnsafeMutableRawPointer?,
            UnsafeMutablePointer<UInt8>?,
            UInt32,
            UnsafeMutablePointer<UInt32>?
        ) -> Int32
    ) throws -> WireGuardOperation {
        var outLength: UInt32 = 0
        let code = buffer.withUnsafeMutableBufferPointer { destination in
            call(handle, destination.baseAddress, UInt32(destination.count), &outLength)
        }
        if let error = WireGuardEngineError(code: code) { throw error }
        let byteCount = Int(outLength)
        switch code {
        case WireGuardABI.opNone: return .none
        case WireGuardABI.opWriteToNetwork: return .writeToNetwork(byteCount: byteCount)
        case WireGuardABI.opWriteToTunnelV4: return .writeToTunnelIPv4(byteCount: byteCount)
        case WireGuardABI.opWriteToTunnelV6: return .writeToTunnelIPv6(byteCount: byteCount)
        default: throw WireGuardEngineError.unrecognized(code: code)
        }
    }
}
