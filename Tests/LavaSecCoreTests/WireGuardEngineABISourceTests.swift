import Foundation
import XCTest

@testable import LavaSecChainedUpstream

/// Pins the Swift `@_silgen_name` bindings against the engine's C header.
///
/// The compiler cannot see this seam: `Sources/LavaSecChainedUpstream` binds the
/// engine's symbols by name, so a header/Rust change that renumbers an error code,
/// resizes a buffer minimum, or renames a function produces **no** build error — just
/// silent misbehaviour (a wrong code interpreted as a different failure class, or an
/// undersized buffer reaching an engine that panics, which aborts the Network Extension
/// in release). That is exactly the cross-process wiring `<Feature>SourceTests` exist
/// for (CLAUDE.md, test conventions).
final class WireGuardEngineABISourceTests: XCTestCase {
    private func header() throws -> String {
        try readSource(.wireGuardCoreHeader)
    }

    /// Extracts `#define NAME value` as an integer, tolerating the `u` suffix and
    /// parenthesized negatives the header uses (`(-1)`).
    private func define(_ name: String, in header: String) throws -> Int {
        let pattern = "#define\\s+\(NSRegularExpression.escapedPattern(for: name))\\s+(\\(?-?\\d+\\)?u?)"
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(header.startIndex..<header.endIndex, in: header)
        guard
            let match = regex.firstMatch(in: header, range: range),
            let valueRange = Range(match.range(at: 1), in: header)
        else {
            XCTFail("header does not define \(name)")
            throw XCTSkip("missing define")
        }
        let raw = header[valueRange]
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "u", with: "")
        return try XCTUnwrap(Int(raw), "\(name) is not an integer literal")
    }

    func testSwiftConstantsMatchTheEngineHeader() throws {
        let header = try header()

        XCTAssertEqual(try define("LAVA_WG_OP_NONE", in: header), Int(WireGuardABI.opNone))
        XCTAssertEqual(
            try define("LAVA_WG_OP_WRITE_TO_NETWORK", in: header),
            Int(WireGuardABI.opWriteToNetwork)
        )
        XCTAssertEqual(
            try define("LAVA_WG_OP_WRITE_TO_TUNNEL_V4", in: header),
            Int(WireGuardABI.opWriteToTunnelV4)
        )
        XCTAssertEqual(
            try define("LAVA_WG_OP_WRITE_TO_TUNNEL_V6", in: header),
            Int(WireGuardABI.opWriteToTunnelV6)
        )

        XCTAssertEqual(
            try define("LAVA_WG_ERR_INVALID_ARGUMENT", in: header),
            Int(WireGuardABI.errInvalidArgument)
        )
        XCTAssertEqual(
            try define("LAVA_WG_ERR_DESTINATION_BUFFER_TOO_SMALL", in: header),
            Int(WireGuardABI.errDestinationBufferTooSmall)
        )
        XCTAssertEqual(
            try define("LAVA_WG_ERR_NO_CURRENT_SESSION", in: header),
            Int(WireGuardABI.errNoCurrentSession)
        )
        XCTAssertEqual(try define("LAVA_WG_ERR_UNDER_LOAD", in: header), Int(WireGuardABI.errUnderLoad))
        XCTAssertEqual(try define("LAVA_WG_ERR_PROTOCOL", in: header), Int(WireGuardABI.errProtocol))
        XCTAssertEqual(
            try define("LAVA_WG_ERR_CONNECTION_EXPIRED", in: header),
            Int(WireGuardABI.errConnectionExpired)
        )
        XCTAssertEqual(try define("LAVA_WG_ERR_INTERNAL", in: header), Int(WireGuardABI.errInternal))
        XCTAssertEqual(
            try define("LAVA_WG_ERR_PACKET_TOO_LARGE", in: header),
            Int(WireGuardABI.errPacketTooLarge)
        )

        XCTAssertEqual(try define("LAVA_WG_DATA_OVERHEAD", in: header), WireGuardABI.dataOverhead)
        XCTAssertEqual(
            try define("LAVA_WG_MIN_CONTROL_DST", in: header),
            WireGuardABI.minimumControlDestination
        )
        XCTAssertEqual(try define("LAVA_WG_MAX_IP_PACKET", in: header), WireGuardABI.maximumIPPacket)
        // MAX_DATAGRAM is derived in both twins; assert the derivation agrees rather than
        // re-parsing an expression.
        XCTAssertEqual(
            WireGuardABI.maximumDatagram,
            WireGuardABI.maximumIPPacket + WireGuardABI.dataOverhead
        )
        XCTAssertTrue(
            header.contains("#define LAVA_WG_MAX_DATAGRAM (LAVA_WG_MAX_IP_PACKET + LAVA_WG_DATA_OVERHEAD)"),
            "the header must derive MAX_DATAGRAM from the same two constants"
        )
    }

    func testEverySilgenNameBindingExistsInTheHeader() throws {
        let header = try header()
        let bindings = try readSource(.wireGuardCoreABIBindings)

        // Every symbol the Swift side binds by name must be declared by the header. A
        // rename on either side is otherwise a link-time or runtime surprise.
        let boundSymbols = try boundSilgenNames(in: bindings)
        XCTAssertEqual(
            boundSymbols.sorted(),
            [
                "lava_wg_decapsulate",
                "lava_wg_encapsulate",
                "lava_wg_force_handshake",
                "lava_wg_session_free",
                "lava_wg_session_new",
                "lava_wg_session_stats",
                "lava_wg_tick",
            ],
            "the Swift binding set changed — update the header twin and this pin together"
        )
        for symbol in boundSymbols {
            XCTAssertTrue(
                header.contains(symbol),
                "\(symbol) is bound in Swift but absent from the engine header"
            )
        }

        // The stats struct is read through a raw pointer, so its field order and width are
        // part of the ABI, not an implementation detail.
        XCTAssertEqual(MemoryLayout<LavaWGStatsRaw>.size, 32)
        for field in [
            "int64_t time_since_last_handshake_ms",
            "uint64_t tx_bytes",
            "uint64_t rx_bytes",
            "float estimated_loss",
            "int32_t estimated_rtt_ms",
        ] {
            XCTAssertTrue(header.contains(field), "header lost the \(field) field")
        }
    }

    private func boundSilgenNames(in source: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: "@_silgen_name\\(\"([a-z_]+)\"\\)")
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }
}
