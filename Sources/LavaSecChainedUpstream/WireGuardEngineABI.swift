import Foundation

// C ABI bindings for the vendored WireGuard engine. The authoritative declaration is
// ThirdParty/wireguard-core/include/lavasec_wireguard_core.h (itself the twin of
// ThirdParty/wireguard-core/src/lib.rs); every signature and constant below mirrors it
// and must be updated in the same diff as the header.
// pinned: WireGuardEngineABISourceTests.testSwiftConstantsMatchTheEngineHeader
//
// Why `@_silgen_name` and not an `import`: the engine ships as a `binaryTarget`
// xcframework carrying a plain header with no module map, and the committed xcodegen
// guards reject the bridging-header / build-phase / plugin machinery that would be
// needed to synthesize one. Direct symbol binding is the same approach the Phase-0
// spike validated on device (lavasec-ios-internal #442).
//
// These are `internal`: the raw pointer surface never escapes this module. Callers use
// `WireGuardSession`, which owns the handle lifetime and the buffer contract.

@_silgen_name("lava_wg_session_new")
func lava_wg_session_new(
    _ privateKey: UnsafePointer<UInt8>?,
    _ peerPublicKey: UnsafePointer<UInt8>?,
    _ presharedKey: UnsafePointer<UInt8>?,
    _ keepaliveSeconds: UInt16,
    _ index: UInt32
) -> UnsafeMutableRawPointer?

@_silgen_name("lava_wg_session_free")
func lava_wg_session_free(_ session: UnsafeMutableRawPointer?)

@_silgen_name("lava_wg_encapsulate")
func lava_wg_encapsulate(
    _ session: UnsafeMutableRawPointer?,
    _ source: UnsafePointer<UInt8>?,
    _ sourceLength: UInt32,
    _ destination: UnsafeMutablePointer<UInt8>?,
    _ destinationCapacity: UInt32,
    _ outLength: UnsafeMutablePointer<UInt32>?
) -> Int32

@_silgen_name("lava_wg_decapsulate")
func lava_wg_decapsulate(
    _ session: UnsafeMutableRawPointer?,
    _ source: UnsafePointer<UInt8>?,
    _ sourceLength: UInt32,
    _ sourceAddress: UnsafePointer<UInt8>?,
    _ sourceAddressLength: UInt32,
    _ destination: UnsafeMutablePointer<UInt8>?,
    _ destinationCapacity: UInt32,
    _ outLength: UnsafeMutablePointer<UInt32>?,
    _ outSourceAddress: UnsafeMutablePointer<UInt8>?,
    _ outSourceAddressLength: UnsafeMutablePointer<UInt32>?
) -> Int32

@_silgen_name("lava_wg_tick")
func lava_wg_tick(
    _ session: UnsafeMutableRawPointer?,
    _ destination: UnsafeMutablePointer<UInt8>?,
    _ destinationCapacity: UInt32,
    _ outLength: UnsafeMutablePointer<UInt32>?
) -> Int32

@_silgen_name("lava_wg_force_handshake")
func lava_wg_force_handshake(
    _ session: UnsafeMutableRawPointer?,
    _ destination: UnsafeMutablePointer<UInt8>?,
    _ destinationCapacity: UInt32,
    _ outLength: UnsafeMutablePointer<UInt32>?
) -> Int32

/// Mirrors the C `LavaWGStats` struct exactly: 8 + 8 + 8 + 4 + 4 bytes, no padding.
/// The size is asserted against the ABI contract by `WireGuardSessionTests`.
struct LavaWGStatsRaw {
    var timeSinceLastHandshakeMilliseconds: Int64 = 0
    var txBytes: UInt64 = 0
    var rxBytes: UInt64 = 0
    var estimatedLoss: Float = 0
    var estimatedRoundTripMilliseconds: Int32 = 0
}

@_silgen_name("lava_wg_session_stats")
func lava_wg_session_stats(
    _ session: UnsafeMutableRawPointer?,
    _ outStats: UnsafeMutablePointer<LavaWGStatsRaw>?
) -> Int32

// Op codes (>= 0) and error codes (< 0) from the header.
enum WireGuardABI {
    static let opNone: Int32 = 0
    static let opWriteToNetwork: Int32 = 1
    static let opWriteToTunnelV4: Int32 = 2
    static let opWriteToTunnelV6: Int32 = 3

    static let errInvalidArgument: Int32 = -1
    static let errDestinationBufferTooSmall: Int32 = -2
    static let errNoCurrentSession: Int32 = -3
    static let errUnderLoad: Int32 = -4
    static let errProtocol: Int32 = -5
    static let errConnectionExpired: Int32 = -6
    static let errInternal: Int32 = -7
    static let errPacketTooLarge: Int32 = -8

    static let dataOverhead = 32
    static let minimumControlDestination = 148
    static let maximumIPPacket = 1500
    static let maximumDatagram = maximumIPPacket + dataOverhead
}
