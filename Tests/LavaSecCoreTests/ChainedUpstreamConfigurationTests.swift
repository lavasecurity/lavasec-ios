import XCTest

@testable import LavaSecChainedUpstream
@testable import LavaSecKit

/// The validation boundary in front of a C ABI that panics on some malformed input.
///
/// In release, inside a Network Extension, an engine panic is a tunnel abort — the user
/// sees protection drop. So the interesting cases here are not "does a good config parse"
/// but "does every shape that would reach the engine wrong get stopped first".
final class ChainedUpstreamConfigurationTests: XCTestCase {
    /// 32 non-zero bytes, base64.
    ///
    /// This was 32 ZERO bytes, described as "a structurally valid WireGuard public key".
    /// It is not one: the engine's own validator requires `len == 32 && zero != 0`
    /// (`boringtun/src/ffi/mod.rs`), so every positive assertion in this file was proving
    /// the type accepts a key the engine refuses. Not a real peer key — a fixed digest, so
    /// it is non-zero and reproducible without being anything a person holds.
    ///
    /// Built from bytes rather than written as a base64 literal on purpose: any literal
    /// that decodes to 32 bytes is indistinguishable from a real key to a secret scanner,
    /// and the first version of this fixture failed gitleaks. Constructing it removes the
    /// finding instead of allowlisting it, and makes "this is not a key" obvious to a
    /// reader too.
    private static let validKey = Data(1...32).base64EncodedString()

    /// The all-zero key, which an unfilled config template carries.
    private static let allZeroKey = Data(repeating: 0, count: 32).base64EncodedString()

    /// Varies every input the selection fingerprint is supposed to track, plus two it must ignore.
    private static func selectionConfiguration(
        host: String = "vpn.example.com",
        keepalive: UInt16 = 0,
        clientAddress: String = "10.64.0.5",
        allowedIPs: [String] = ["0.0.0.0/0"],
        dnsAddresses: [String] = ["10.64.0.1"]
    ) throws -> ChainedUpstreamConfiguration {
        try ChainedUpstreamConfiguration(
            endpointHost: host, endpointPort: 51_820, peerPublicKey: validKey,
            clientAddress: clientAddress, allowedIPs: allowedIPs,
            persistentKeepaliveSeconds: keepalive, dnsAddresses: dnsAddresses)
    }

    private static func make(
        host: String = "vpn.example.com",
        port: UInt16 = 51_820,
        key: String? = nil,
        keepalive: UInt16 = 0,
        dnsAddresses: [String] = []
    ) throws -> ChainedUpstreamConfiguration {
        try ChainedUpstreamConfiguration(
            endpointHost: host,
            endpointPort: port,
            peerPublicKey: key ?? validKey,
            clientAddress: "10.64.0.5", allowedIPs: ["0.0.0.0/0"],
            persistentKeepaliveSeconds: keepalive,
            dnsAddresses: dnsAddresses
        )
    }

    private func assertRejects(
        _ failure: ChainedUpstreamConfiguration.ValidationFailure,
        _ build: () throws -> ChainedUpstreamConfiguration,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try build()
            XCTFail("expected \(failure.rawValue): \(message)", file: file, line: line)
        } catch let error as ChainedUpstreamConfiguration.ValidationFailure {
            XCTAssertEqual(error, failure, message, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: - The key, which is the one that reaches C

    func testAKeyOfTheWrongLengthIsRejected() {
        // The engine reads 32 bytes unconditionally, so a short key is an over-read at the
        // FFI boundary — not a rejected argument, a read past the end of the buffer.
        for byteCount in [0, 1, 16, 31, 33, 64] {
            let key = Data(repeating: 7, count: byteCount).base64EncodedString()
            assertRejects(.malformedPeerPublicKey, { try Self.make(key: key) }, "\(byteCount) bytes must not pass")
        }
    }

    func testAKeyThatIsNotBase64IsRejected() {
        for key in ["", "not base64!!", "zzzz", "AAAA AAAA"] {
            assertRejects(.malformedPeerPublicKey, { try Self.make(key: key) }, "\(key.debugDescription) must not pass")
        }
    }

    func testAWellFormedKeyIsAccepted() throws {
        let config = try Self.make()
        XCTAssertEqual(config.peerPublicKey, Self.validKey)
    }

    // MARK: - Endpoint shapes users actually paste

    func testHostsThatAreReallySomethingElseAreRejected() {
        // Each of these is a real thing someone pastes into an endpoint field.
        for host in [
            "",                              // empty
            "   ",                           // whitespace only
            "vpn.example.com:51820",         // host:port pair
            "wireguard://vpn.example.com",   // a URL
            "https://vpn.example.com/x",     // a URL with a path
            "user@vpn.example.com",          // an SSH-style target
            "vpn example com",               // spaces
            "2001:db8::1",                   // bare IPv6 literal, ambiguous with host:port
            String(repeating: "a", count: 254),
        ] {
            assertRejects(.malformedEndpointHost, { try Self.make(host: host) }, "\(host.debugDescription) is not a host")
        }
    }

    func testOrdinaryHostsAndIPv4LiteralsAreAccepted() throws {
        for host in ["vpn.example.com", "203.0.113.7", "a.b.c.d.example", "xn--bcher-kva.example"] {
            XCTAssertEqual(try Self.make(host: host).endpointHost, host)
        }
    }

    func testSurroundingWhitespaceIsTrimmedRatherThanRejected() throws {
        // Pasting from a config file or a chat message carries whitespace. Refusing that
        // would read to the user as "my correct key does not work".
        XCTAssertEqual(try Self.make(host: "  vpn.example.com\n").endpointHost, "vpn.example.com")
    }

    func testPortZeroIsRejected() {
        assertRejects(.invalidEndpointPort, { try Self.make(port: 0) }, "port 0 is not a destination")
    }

    // MARK: - Keepalive, which is a battery decision

    func testAKeepaliveShortEnoughToHoldTheRadioAwakeIsRejected() {
        for seconds in [UInt16(1), 2, 4] {
            assertRejects(.keepaliveTooFrequent, { try Self.make(keepalive: seconds) }, "\(seconds)s is radio churn")
        }
    }

    func testKeepaliveOffAndOrdinaryIntervalsAreAccepted() throws {
        for seconds in [UInt16(0), ChainedUpstreamConfiguration.minimumKeepaliveSeconds, 25, 120] {
            XCTAssertEqual(try Self.make(keepalive: seconds).persistentKeepaliveSeconds, seconds)
        }
    }

    // MARK: - Leaking

    func testInterpolationCannotLeakTheEndpointOrKey() throws {
        // The resolver literal is distinctive so a summary that starts interpolating the
        // LIST instead of its count fails here — with an empty fixture list, the redaction
        // claim for `dnsAddresses` was prose the sweep below never exercised (S6 panel).
        let config = try Self.make(
            host: "secret-vpn.example.com", key: Self.validKey,
            dnsAddresses: ["203.0.113.53"])

        // Every conversion a log line might reach for.
        for rendered in ["\(config)", String(describing: config), String(reflecting: config), config.debugDescription] {
            XCTAssertEqual(rendered, config.redactedSummary)
            XCTAssertFalse(rendered.contains("secret-vpn"), "the endpoint host reached a log-facing string")
            XCTAssertFalse(rendered.contains(Self.validKey), "the peer key reached a log-facing string")
            XCTAssertFalse(rendered.contains("203.0.113.53"), "a resolver address reached a log-facing string")
        }
    }

    func testTheRedactedSummaryStillSaysEnoughToDebugWith() throws {
        let config = try Self.make(port: 51_820, keepalive: 25)
        // A redaction that removes everything is not a redaction, it is a deleted log line.
        XCTAssertTrue(config.redactedSummary.contains("51820"))
        XCTAssertTrue(config.redactedSummary.contains("25s"))
        XCTAssertTrue(config.redactedSummary.contains(config.peerKeyFingerprint))
    }

    func testTheFingerprintIsStableAndDoesNotContainTheKey() throws {
        let first = try Self.make()
        let second = try Self.make(host: "other.example.com")
        let different = try Self.make(key: Data(repeating: 9, count: 32).base64EncodedString())

        XCTAssertEqual(first.peerKeyFingerprint, second.peerKeyFingerprint, "the fingerprint keys on the peer, not the host")
        XCTAssertNotEqual(first.peerKeyFingerprint, different.peerKeyFingerprint)
        XCTAssertEqual(first.peerKeyFingerprint.count, 8)
        XCTAssertFalse(Self.validKey.contains(first.peerKeyFingerprint))
    }

    // MARK: - Persistence shape

    func testItRoundTripsThroughCodable() throws {
        let config = try Self.make(host: "vpn.example.com", port: 51_820, keepalive: 25)
        let decoded = try JSONDecoder().decode(
            ChainedUpstreamConfiguration.self,
            from: JSONEncoder().encode(config)
        )
        XCTAssertEqual(decoded, config)
    }

    func testNoSecretMaterialHasAPlaceToHide() throws {
        // The private key and any preshared key are Keychain-held and referenced, never
        // carried. This asserts the type's SHAPE rather than a value: if someone later adds
        // a field for them, the encoded form grows a key here and this fails.
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(try Self.make())
        ) as? [String: Any]
        XCTAssertEqual(
            Set(try XCTUnwrap(json).keys),
            [
                "endpointHost", "endpointPort", "peerPublicKey", "displayName", "precedingHops", "isEnabled",
                // Added by S8.2. Neither is secret material: the client address is this
                // device's address INSIDE the tunnel and is meaningless off it, and AllowedIPs
                // is routing the peer already knows because it published it. The private key
                // stays in the Keychain, referenced and never carried here.
                "clientAddress", "allowedIPs",
                "persistentKeepaliveSeconds",
                // Added by S6. Resolver addresses are infrastructure names like the
                // endpoint — withheld from logs, stored beside it — not key material.
                "dnsAddresses",
                // Added by Slice 2 (infra #198). Derived routing metadata — full vs split —
                // not secret material; today it is always "fullTunnel". The private key stays
                // in the Keychain, referenced and never carried here.
                "routingPolicy",
            ],
            "the upstream config gained a field — if it holds secret material it belongs in the Keychain"
        )

        // With the optional MTU set (C7), exactly one key is added — a link parameter,
        // not secret material.
        let withMTU = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(try Self.configuration(interfaceMTU: 1420))
        ) as? [String: Any]
        XCTAssertEqual(
            Set(try XCTUnwrap(withMTU).keys),
            [
                "endpointHost", "endpointPort", "peerPublicKey", "displayName", "precedingHops", "isEnabled",
                "clientAddress", "allowedIPs",
                "persistentKeepaliveSeconds", "interfaceMTU", "dnsAddresses",
                "routingPolicy",
            ]
        )
    }

    /// The seven canonical Curve25519 u-coordinates of order dividing 8.
    ///
    /// Written out here rather than read from `ChainedUpstreamConfiguration.smallOrderPoints`
    /// on purpose. Deriving the oracle from the production table makes this test agree with
    /// whatever that table says, including a value silently edited or dropped from it — which
    /// is the single thing the test exists to catch. These are the same seven the WireGuard
    /// and libsodium blacklists carry.
    private static let canonicalSmallOrderPoints: [[UInt8]] = [
        Array(repeating: 0x00, count: 32),
        [0x01] + Array(repeating: 0x00, count: 31),
        [0xe0, 0xeb, 0x7a, 0x7c, 0x3b, 0x41, 0xb8, 0xae, 0x16, 0x56, 0xe3, 0xfa, 0xf1, 0x9f,
         0xc4, 0x6a, 0xda, 0x09, 0x8d, 0xeb, 0x9c, 0x32, 0xb1, 0xfd, 0x86, 0x62, 0x05, 0x16,
         0x5f, 0x49, 0xb8, 0x00],
        [0x5f, 0x9c, 0x95, 0xbc, 0xa3, 0x50, 0x8c, 0x24, 0xb1, 0xd0, 0xb1, 0x55, 0x9c, 0x83,
         0xef, 0x5b, 0x04, 0x44, 0x5c, 0xc4, 0x58, 0x1c, 0x8e, 0x86, 0xd8, 0x22, 0x4e, 0xdd,
         0xd0, 0x9f, 0x11, 0x57],
        [0xec] + Array(repeating: 0xff, count: 30) + [0x7f],
        [0xed] + Array(repeating: 0xff, count: 30) + [0x7f],
        [0xee] + Array(repeating: 0xff, count: 30) + [0x7f],
    ]

    func testASmallOrderPeerKeyIsRefusedAtConstruction() {
        // This replaces a test that used the all-zero key alone. All-zero is one of the seven,
        // and it is the one an unfilled config template carries — so it was the case most
        // likely to be hit by accident and the least likely to be reached by an attacker. The
        // other six passed construction while the check looked present and had a test.
        //
        // The high-bit twins matter as much as the canonical spellings: bit 255 of the
        // u-coordinate is ignored during scalar multiplication, so `key | 0x80 << 248` reaches
        // the same curve point. Refusing only the canonical form is a check an attacker skips
        // by setting one bit.
        for (index, point) in Self.canonicalSmallOrderPoints.enumerated() {
            var twin = point
            twin[31] |= 0x80
            for (label, bytes) in [("canonical", point), ("high-bit twin", twin)] {
                assertRejects(
                    .unusablePeerPublicKey,
                    { try Self.make(key: Data(bytes).base64EncodedString()) },
                    "small-order point \(index) (\(label)) was accepted"
                )
            }
        }
    }

    func testTheSmallOrderTableIsBothCanonicalFormsOfEachPointAndNothingElse() {
        // Size is asserted separately from membership so the two failure modes read
        // differently: a missing point fails the loop above, while a point ADDED to the table
        // fails here. An over-broad table is its own bug — it refuses a legitimate peer key
        // and presents as "the server rejects my config" with no diagnosis.
        XCTAssertEqual(
            ChainedUpstreamConfiguration.smallOrderPointCount,
            Self.canonicalSmallOrderPoints.count * 2,
            "the small-order table changed size"
        )
    }

    func testAKeyOneBitAwayFromASmallOrderPointIsStillAccepted() {
        // The mutation guard for the two tests above. Without it, `isSmallOrderPoint`
        // returning true unconditionally passes both of them — every key refused, every
        // assertion satisfied, and chained mode simply never connects.
        var neighbour = Self.canonicalSmallOrderPoints[2]
        neighbour[0] ^= 0x01
        XCTAssertNoThrow(try Self.make(key: Data(neighbour).base64EncodedString()))
    }

    func testEndpointHostRejectsWhatCannotBeAHost() {
        // Each of these decodes to 32 bytes of nothing-wrong elsewhere, so the host is the
        // only reason to refuse. "?" and "#" are the pasted-URL cases; \u{0} and \u{200B}
        // are invisible in the field the user pasted into.
        let notHosts = [
            "vpn.example.com?query",
            "vpn.example.com#fragment",
            "vpn.example.com/path",
            "user@vpn.example.com",
            "vpn.example.com:51820",
            "https://vpn.example.com",
            "vpn..example.com",
            "vpn.example.com\u{0}",
            "[2001:db8::1]",
            String(repeating: "a", count: 64) + ".example.com",
        ]
        for host in notHosts {
            XCTAssertThrowsError(try Self.make(host: host), "accepted \(host)") { error in
                XCTAssertEqual(
                    error as? ChainedUpstreamConfiguration.ValidationFailure,
                    .malformedEndpointHost,
                    "wrong reason for \(host)"
                )
            }
        }
    }

    func testEndpointHostStillAcceptsUnusualButValidNames() throws {
        // The validator's stated job is to refuse input that cannot be a host, NOT to be a
        // resolver. Locking someone out of their own server is the failure it is written to
        // avoid, so the permissive cases are asserted rather than left implied.
        for host in [
            "vpn.example.com.",          // trailing dot is legal FQDN syntax
            "192.0.2.1",                 // IPv4 literal
            "vpn-01.example.com",
            "xn--bcher-kva.example",     // punycode IDN
            "münchen.example",           // unencoded IDN
            "localhost",
            "a." + String(repeating: "b", count: 63) + ".example",
        ] {
            XCTAssertNoThrow(try Self.make(host: host), "rejected \(host)")
        }
    }

    func testDecodingRevalidates() throws {
        // The bypass this guards: synthesized Decodable assigns stored properties directly,
        // so before init(from:) existed this JSON produced a configuration that the throwing
        // initializer would have refused outright. Persisted data is precisely where a stale
        // or hand-edited value comes from.
        let invalid = """
            {"endpointHost":"","endpointPort":0,"peerPublicKey":"bad","clientAddress":"10.64.0.5","allowedIPs":["0.0.0.0/0"],"persistentKeepaliveSeconds":1}
            """
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ChainedUpstreamConfiguration.self, from: Data(invalid.utf8))
        ) { error in
            XCTAssertTrue(
                error is ChainedUpstreamConfiguration.ValidationFailure,
                "decoding surfaced \(type(of: error)), not the validation failure"
            )
        }
    }

    func testDecodingRejectsEachFieldIndependently() throws {
        // One malformed field at a time, so a single over-broad guard cannot make this pass.
        let cases: [(String, ChainedUpstreamConfiguration.ValidationFailure)] = [
            (#"{"endpointHost":"a b","endpointPort":51820,"peerPublicKey":"\#(Self.validKey)","clientAddress":"10.64.0.5","allowedIPs":["0.0.0.0/0"],"persistentKeepaliveSeconds":0}"#, .malformedEndpointHost),
            (#"{"endpointHost":"vpn.example.com","endpointPort":0,"peerPublicKey":"\#(Self.validKey)","clientAddress":"10.64.0.5","allowedIPs":["0.0.0.0/0"],"persistentKeepaliveSeconds":0}"#, .invalidEndpointPort),
            (#"{"endpointHost":"vpn.example.com","endpointPort":51820,"peerPublicKey":"zzzz","clientAddress":"10.64.0.5","allowedIPs":["0.0.0.0/0"],"persistentKeepaliveSeconds":0}"#, .malformedPeerPublicKey),
            (#"{"endpointHost":"vpn.example.com","endpointPort":51820,"peerPublicKey":"\#(Self.allZeroKey)","clientAddress":"10.64.0.5","allowedIPs":["0.0.0.0/0"],"persistentKeepaliveSeconds":0}"#, .unusablePeerPublicKey),
            (#"{"endpointHost":"vpn.example.com","endpointPort":51820,"peerPublicKey":"\#(Self.validKey)","clientAddress":"10.64.0.5","allowedIPs":["0.0.0.0/0"],"persistentKeepaliveSeconds":1}"#, .keepaliveTooFrequent),
        ]
        for (json, expected) in cases {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    ChainedUpstreamConfiguration.self, from: Data(json.utf8)),
                "decoded \(expected)"
            ) { error in
                XCTAssertEqual(
                    error as? ChainedUpstreamConfiguration.ValidationFailure, expected)
            }
        }
    }

    func testIDNLabelsAreMeasuredAfterConversionNotBefore() throws {
        // The check used to measure the UTF-8 bytes of the Unicode spelling, which is not the
        // label that gets queried. It was wrong in both directions.
        //
        // Legal, and previously REJECTED: a "ü" label is legal up to 57 characters (the
        // A-label is "xn--td" plus one 'a' per character, so 57 -> 63 octets). The old byte
        // check refused anything from 32 up, capping a German or Nordic label at 31.
        for count in [31, 32, 45, 57] {
            let host = String(repeating: "ü", count: count) + ".example"
            XCTAssertNoThrow(try Self.make(host: host), "rejected a legal \(count)-character IDN label")
        }
        XCTAssertThrowsError(try Self.make(host: String(repeating: "ü", count: 58) + ".example")) {
            XCTAssertEqual(
                $0 as? ChainedUpstreamConfiguration.ValidationFailure, .malformedEndpointHost)
        }

        // Impossible, and previously ACCEPTED: punycode carries the basic code points
        // literally AND appends delta digits, so a mostly-ASCII label with one non-ASCII
        // character encodes LONGER than its UTF-8 spelling. 61 bytes in, 67 on the wire.
        XCTAssertThrowsError(
            try Self.make(host: String(repeating: "a", count: 59) + "ü.example"),
            "accepted a label whose A-label exceeds 63 octets"
        ) {
            XCTAssertEqual(
                $0 as? ChainedUpstreamConfiguration.ValidationFailure, .malformedEndpointHost)
        }
    }

    func testTheTotalLengthCapIsMeasuredOnTheWireForm() throws {
        // Three names that a naive measure gets wrong, in three different ways.

        // 1. Grapheme clusters under-count badly: `String.count` would let a ~700-octet name
        //    through a gate documented as capping at 253.
        let manyCJK = Array(repeating: "中中中", count: 40).joined(separator: ".")
        XCTAssertLessThan(manyCJK.count, 253)
        XCTAssertGreaterThan(manyCJK.utf8.count, 253)
        XCTAssertThrowsError(try Self.make(host: manyCJK), "accepted a name far past the DNS ceiling")

        // 2. UTF-8 octets OVER-count: punycode compresses long non-ASCII labels, so this is
        //    304 octets spelled and a 134-octet A-label — entirely legal, and rejecting it
        //    would be the lock-out this validator exists to avoid.
        let compressible = Array(repeating: String(repeating: "中", count: 20), count: 5)
            .joined(separator: ".")
        XCTAssertGreaterThan(compressible.utf8.count, 253)
        XCTAssertNoThrow(
            try Self.make(host: compressible),
            "rejected a legal name because its Unicode spelling is longer than its A-label"
        )

        // 3. ASCII is measured directly, because Foundation passes ASCII hosts through
        //    without validating them.
        let longASCII = Array(repeating: String(repeating: "a", count: 60), count: 5)
            .joined(separator: ".")
        XCTAssertGreaterThan(longASCII.utf8.count, 253)
        XCTAssertThrowsError(try Self.make(host: longASCII), "accepted an over-long ASCII name")
    }

    func testTheFingerprintIsStableAcrossEncodings() throws {
        // Base64 of 32 bytes has slack in its final character: the last data character
        // carries only two significant bits, so several spellings decode to the same key.
        // Hashing the STRING gave the same peer two different "stable" fingerprints.
        let canonical = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP8="
        let alternate = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP9="
        XCTAssertEqual(
            Data(base64Encoded: canonical), Data(base64Encoded: alternate),
            "fixture is wrong — these must decode identically"
        )
        let a = try Self.make(key: canonical)
        let b = try Self.make(key: alternate)
        XCTAssertEqual(a.peerKeyFingerprint, b.peerKeyFingerprint)
        XCTAssertFalse(a.peerKeyFingerprint.contains(canonical))
    }

    func testTheSelectionFingerprintTracksOnlySelectionInputs() throws {
        // It answers ONE question: could this configuration change decide resolver admission
        // differently? `ChainedTunnelResolverSelection` reads `allowedIPs`, `dnsAddresses` and
        // `clientAddress` — nothing else — so nothing else may move the fingerprint. Tripping on
        // an endpoint or keepalive edit would tell the user to restart protection for a change
        // that cannot alter a single verdict.
        let base = try Self.selectionConfiguration()
        XCTAssertEqual(
            base.resolverSelectionFingerprint,
            try Self.selectionConfiguration(host: "other.example.com", keepalive: 25)
                .resolverSelectionFingerprint,
            "endpoint and keepalive cannot change which resolvers are admitted")

        // THE CASE THAT FORCED THIS (Codex, PR #575): full tunnel to split. The chosen fallback
        // is untouched, and the verdict reverses.
        XCTAssertNotEqual(
            base.resolverSelectionFingerprint,
            try Self.selectionConfiguration(allowedIPs: ["10.0.0.0/8"])
                .resolverSelectionFingerprint,
            "an AllowedIPs change decides admission and must move the fingerprint")
        XCTAssertNotEqual(
            base.resolverSelectionFingerprint,
            try Self.selectionConfiguration(dnsAddresses: ["10.64.0.9"])
                .resolverSelectionFingerprint,
            "the conf's own DNS decides T0 dedup and must move the fingerprint")
        XCTAssertNotEqual(
            base.resolverSelectionFingerprint,
            try Self.selectionConfiguration(clientAddress: "10.64.0.6")
                .resolverSelectionFingerprint,
            "the client address is refused as a resolver, so it must move the fingerprint")
    }

    func testTheSelectionFingerprintKeepsItsFieldBoundariesAndCarriesNoFields() throws {
        // The classic concatenation ambiguity — a value sliding between two joined fields — is
        // closed TWICE here, and the first close is the boundary's, not the fingerprint's: the
        // initializer refuses a prefix containing a comma outright (`malformedAllowedIPs`), so
        // the within-list forgery is unconstructible through this type. Asserting it would test
        // the validator, not the hash. What remains testable is that the same value in a
        // DIFFERENT field is a different configuration.
        XCTAssertThrowsError(
            try Self.selectionConfiguration(allowedIPs: ["10.0.0.0/8,10.1.0.0/16"]),
            "fixture assumption: a comma-joined prefix is refused before it can reach the hash")
        XCTAssertNotEqual(
            try Self.selectionConfiguration(dnsAddresses: ["10.64.0.1", "10.64.0.2"])
                .resolverSelectionFingerprint,
            try Self.selectionConfiguration(dnsAddresses: ["10.64.0.1"])
                .resolverSelectionFingerprint,
            "a second resolver is a different selection input")

        // It travels in a health snapshot, which travels in bug reports. The fields it covers
        // name the operator's infrastructure the way the endpoint does, so none may survive it.
        let fingerprint = try Self.selectionConfiguration().resolverSelectionFingerprint
        for field in ["10.64.0.5", "0.0.0.0/0", "10.64.0.1"] {
            XCTAssertFalse(
                fingerprint.contains(field), "the fingerprint must not carry \(field)")
        }
        XCTAssertEqual(fingerprint.count, 8, "SHA-256 truncated to 4 bytes, as peerKeyFingerprint is")
    }
    // MARK: - Client address and AllowedIPs (S8.2)

    func testAClientAddressIsRequiredAndMustBeAUsableIPv4Host() {
        // The peer accepts a client's inner packets only from the source its AllowedIPs for
        // that client permits. A wrong address here has NO local symptom — handshake completes,
        // tunnel reports up, and replies simply never arrive — so it has to be rejected at the
        // boundary rather than diagnosed in the field.
        let rejected = [
            "", "  ", "10.64.0", "10.64.0.5.1", "10.64.0.256", "10.64.0.-1",
            "0.0.0.0",            // unspecified
            "0.1.2.3",            // 0.0.0.0/8 "this network"
            "127.0.0.1",          // loopback
            "169.254.10.5",       // link-local: what a host assigns itself when config failed
            "224.0.0.1",          // multicast
            "239.255.255.250",    // multicast (SSDP), a real value people paste
            "240.0.0.1",          // reserved
            "255.255.255.255",    // limited broadcast
            "010.064.000.005",    // leading zeros: a second spelling of 10.64.0.5
            "fd00::5",            // v6: chained mode claims ::/0 to DROP it, never to carry it
            "10.64.0.5/32",       // a prefix, not a host address
            "0x0a400005",         // inet_aton would take this; two spellings of one address
        ]
        for address in rejected {
            XCTAssertThrowsError(try Self.configuration(clientAddress: address), "accepted \(address)") {
                XCTAssertEqual(
                    $0 as? ChainedUpstreamConfiguration.ValidationFailure, .malformedClientAddress,
                    "wrong failure for \(address)")
            }
        }
        XCTAssertEqual(try Self.configuration(clientAddress: " 10.64.0.5 ").clientAddress, "10.64.0.5")

        // Private ranges are the ORDINARY case for a WireGuard peer handing out client
        // addresses, so the non-unicast rule must not sweep them up.
        for address in ["10.64.0.5", "172.16.3.9", "192.168.1.7", "100.64.0.2", "203.0.113.9"] {
            XCTAssertNoThrow(try Self.configuration(clientAddress: address), "rejected \(address)")
        }
    }

    func testACoveringAllowedIPsSetIsAcceptedAsAFullTunnel() throws {
        // A set whose IPv4 prefixes COVER the default route derives `.fullTunnel` and is
        // accepted (coverage, not a literal 0.0.0.0/0 entry — infra #198 §2 gap #3). Split
        // shapes (a gap) are no longer refused here — Slice 3 routes them; see
        // `testASplitAllowedIPsSetIsAcceptedAsSplitTunnel`.
        XCTAssertEqual(try Self.configuration(allowedIPs: ["0.0.0.0/0"]).routingPolicy, .fullTunnel)
        // The shape a real config has: v4 default route beside the v6 one. The v6 half is
        // stored inert (blackholed by the full tunnel's ::/0 claim), so it is accepted here.
        XCTAssertEqual(
            try Self.configuration(allowedIPs: ["0.0.0.0/0", "::/0"]).routingPolicy, .fullTunnel)
        XCTAssertNoThrow(try Self.configuration(allowedIPs: ["0.0.0.0/0", "fd00::/8", "2001:db8::/32"]))
        // The boundaries of each family's length range, so "0...128" is asserted rather than
        // assumed, and so a future tightening cannot quietly exclude a legal prefix.
        XCTAssertNoThrow(try Self.configuration(allowedIPs: ["0.0.0.0/0", "::/128", "::/0"]))

        // `00.00.00.00/0` must NOT be accepted as the default route: it is the leading-zero
        // spelling, refused as MALFORMED upstream of the coverage check, so recognising it as a
        // covering prefix would mean two spellings of the one prefix this whole rule turns on.
        XCTAssertThrowsError(try Self.configuration(allowedIPs: ["00.00.00.00/0"])) {
            XCTAssertEqual(
                $0 as? ChainedUpstreamConfiguration.ValidationFailure, .malformedAllowedIPs)
        }
    }

    func testASplitAllowedIPsSetIsAcceptedAsSplitTunnel() throws {
        // Slice 3 (infra #198 §3): a non-empty set of well-formed IPv4 prefixes that does NOT
        // cover the default route is a split tunnel — accepted, with `.splitTunnel` derived.
        // The route plan claims exactly these prefixes; the rest egresses direct.
        for split in [
            ["100.64.0.0/10"],                    // Tailscale non-exit peer / CGNAT
            ["10.0.0.0/8", "192.168.0.0/16"],     // corporate site-to-site
            ["0.0.0.0/1"],                        // only the lower half — a real gap
            ["10.1.2.3/8"],                       // host bits present; masked to the network
        ] {
            let config = try Self.configuration(allowedIPs: split)
            XCTAssertEqual(config.routingPolicy, .splitTunnel, "\(split) should be split")
            // Stored as written (host bits and all) — the SHAPE decided the mode, the route
            // plan does the masking.
            XCTAssertEqual(config.allowedIPs, split, "AllowedIPs stored verbatim")
        }
    }

    func testAnIPv6OnlyOrEmptyAllowedIPsIsRefusedTruthfully() throws {
        // No usable IPv4 inner route: the earlier coverage check reported the misdirecting
        // `allowedIPsOmitDefaultRoute` (infra #198 §2 gap #11 — the file DOES carry a default,
        // just the v6 one). Now each gets a truthful surface, and NOT the coverage message.
        // Empty: a peer that routes nothing.
        assertRejects(.allowedIPsEmpty, { try Self.configuration(allowedIPs: []) },
            "empty AllowedIPs routes nothing")
        // v6-only / ::/0-only: an IPv6 upstream the IPv4-inner data path cannot carry.
        for v6Only in [["::/0"], ["fd00::/8"], ["::/0", "2001:db8::/32"]] {
            assertRejects(.ipv6OnlyUpstreamUnsupported,
                { try Self.configuration(allowedIPs: v6Only) },
                "\(v6Only) has no IPv4 inner route")
        }
    }

    func testASplitConfigCarryingIPv6AllowedIPsIsRefused() throws {
        // infra #198 §3.4 open-Q #3: split's IPv6 is the plan's own `::/0` blackhole, so a v6
        // AllowedIPs entry beside a routable IPv4 split set could never be honored (the data
        // path carries no IPv6). Refused, not dropped.
        for leaky in [
            ["10.0.0.0/8", "::/0"],
            ["100.64.0.0/10", "fd00::/8"],
            ["2001:db8::/32", "192.168.0.0/16"],
        ] {
            assertRejects(.splitTunnelCarriesIPv6AllowedIPs,
                { try Self.configuration(allowedIPs: leaky) },
                "\(leaky) would leak the v6 half direct")
        }
        // The full-tunnel counterpart stays accepted: a covering v4 set blackholes the v6 half
        // via ::/0 rather than leaking it, so a v6 prefix there is fine.
        XCTAssertEqual(
            try Self.configuration(allowedIPs: ["0.0.0.0/0", "::/0"]).routingPolicy, .fullTunnel)
    }

    func testASubFloorMTUIsRefusedInBothTunnelModes() {
        // The 1280 floor binds BOTH modes. Full tunnel claims ::/0 (RFC 8200 §5); split is
        // IPv4-only and has no v6 floor of its own, but `ChainedPacketQueueLimits.forChainedTunnel`
        // still rejects any MTU below 1280 and the session factory would then downgrade the
        // profile to DNS-only — so a sub-1280 split config could never run. Refused here on the
        // same constant instead of accepted-then-degraded (Codex #546 P2; infra #198 §3.3).
        assertRejects(.mtuBelowIPv6Floor,
            { try Self.configuration(allowedIPs: ["100.64.0.0/10"], interfaceMTU: 1000) },
            "split is refused on the same 1280 — the session factory's queue-limit floor")
        assertRejects(.mtuBelowIPv6Floor,
            { try Self.configuration(allowedIPs: ["0.0.0.0/0"], interfaceMTU: 1000) },
            "full tunnel claims ::/0, so the v6 floor applies")
    }

    func testTheTwoHalvesIdiomIsAcceptedAsAFullTunnel() throws {
        // P10 / infra #198 gap #3: `0.0.0.0/1, 128.0.0.0/1` is the well-known way a VPN
        // front-end overrides the system default route without deleting it, and the two halves
        // claim exactly the same space as `0.0.0.0/0`. The old literal check refused it — a
        // FULL tunnel wrongly read as split. It is now accepted, and it is a full tunnel.
        let viaHalves = try Self.configuration(allowedIPs: ["0.0.0.0/1", "128.0.0.0/1"])
        XCTAssertEqual(viaHalves.routingPolicy, .fullTunnel)
        // Order must not matter, and the v6 default may ride alongside — a real config's shape.
        XCTAssertNoThrow(try Self.configuration(allowedIPs: ["128.0.0.0/1", "0.0.0.0/1"]))
        XCTAssertNoThrow(
            try Self.configuration(allowedIPs: ["0.0.0.0/1", "128.0.0.0/1", "::/0"]))
        // A finer partition also covers: four /2 quarters span the space with no gap.
        XCTAssertNoThrow(
            try Self.configuration(
                allowedIPs: ["0.0.0.0/2", "64.0.0.0/2", "128.0.0.0/2", "192.0.0.0/2"]))
    }

    func testTheCoveringUnionIsWhatSelectsFullVersusSplit() throws {
        // The coverage helper's own correctness, exercised through the boundary: it is the
        // full-vs-split discriminator. A set that leaves ANY gap in the 32-bit space is a split
        // tunnel — now ACCEPTED with `.splitTunnel` (Slice 3), where before it was refused.
        // Breaking the coverage union (reading a non-covering set as covering) flips the mode.
        for split in [
            ["100.64.0.0/10"],                 // one narrow block, most of the space missing
            ["10.0.0.0/8", "192.168.0.0/16"],  // two private blocks, a genuine split tunnel
            ["0.0.0.0/1"],                      // only the lower half — the upper half is a gap
            ["128.0.0.0/1"],                    // only the upper half
            ["0.0.0.0/2", "128.0.0.0/1"],       // 64.0.0.0/2 is the hole between them
        ] {
            XCTAssertEqual(
                try Self.configuration(allowedIPs: split).routingPolicy, .splitTunnel,
                "gapped set \(split) should derive split")
        }
        // A covering set with a redundant, out-of-order, overlapping block: the two halves
        // already cover, and `1.0.0.0/8` sits inside the lower half. This proves the sweep sorts
        // and tolerates overlap rather than tripping on a block it has already passed — and it
        // is a FULL tunnel.
        XCTAssertEqual(
            try Self.configuration(allowedIPs: ["1.0.0.0/8", "0.0.0.0/1", "128.0.0.0/1"]).routingPolicy,
            .fullTunnel)
    }

    func testMalformedAllowedIPsEntriesAreRejectedRatherThanIgnored() {
        // Ignoring an unparseable entry would let a config that reads as a full tunnel be
        // stored as something narrower, and the difference would only appear as traffic that
        // silently does not flow.
        for entry in [
            "10.0.0.0/33", "10.0.0.0/", "/0", "10.0.0.0", "not-a-prefix", "10.0.0.0/abc",
            // Colon alone is not IPv6 recognition — these rode through beside a valid default
            // route and were persisted verbatim into a field a device log is read against.
            "foo:bar", "::garbage", "0.0.0.0:bad",
            // Punctuation is not parsing. Each of these carries a colon AND a slash and is
            // still not a prefix — and each is rejected by `ChainedIPPrefix` downstream, so
            // accepting them here meant reporting ready for data the data path cannot read.
            "foo:/bar", "::/129", "::/", "::/-1", "2001:db8::/abc", "gggg::/64",
            // Non-canonical length, matching the octet rule.
            "0.0.0.0/00", "::/08",
            // Leading zeros again, on the prefix side.
            "010.0.0.0/8",
        ] {
            XCTAssertThrowsError(
                try Self.configuration(allowedIPs: ["0.0.0.0/0", entry]), "accepted \(entry)"
            ) {
                XCTAssertEqual(
                    $0 as? ChainedUpstreamConfiguration.ValidationFailure, .malformedAllowedIPs,
                    "wrong failure for \(entry)")
            }
        }
    }

    func testTheNewFieldsSurviveARoundTripThroughTheValidatingDecoder() throws {
        let original = try Self.configuration(
            clientAddress: "10.64.0.5", allowedIPs: ["0.0.0.0/0", "::/0"])
        let decoded = try JSONDecoder().decode(
            ChainedUpstreamConfiguration.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.clientAddress, "10.64.0.5")
        XCTAssertEqual(decoded.allowedIPs, ["0.0.0.0/0", "::/0"])
    }

    func testDecodingAConfigWithoutTheNewFieldsFailsRatherThanDefaulting() {
        // A default client address is one no peer agreed to, which is the silent failure these
        // fields exist to prevent — so absence is an error, not a fallback. Safe to require
        // because no production `ChainedUpstreamSecretStore` conformer exists yet, so there is
        // no persisted configuration to stay compatible with.
        let legacy = #"{"endpointHost":"vpn.example.com","endpointPort":51820,"peerPublicKey":"\#(Self.validKey)","persistentKeepaliveSeconds":0}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ChainedUpstreamConfiguration.self, from: Data(legacy.utf8)))
    }

    func testAClientAddressOnTheTunnelDNSProxyIsRefusedByName() {
        // Representable only since C7: while the tunnel address was hardcoded, no configured
        // value could put the interface ON the DNS proxy's address. Now one can, and an
        // interface that owns 10.255.0.1 has the OS deliver every DNS query locally instead
        // of routing it into the tunnel — interception never sees it, so DNS dies while the
        // tunnel reports healthy. A named refusal, because "malformed" would tell the user
        // to fix a spelling that is not wrong.
        assertRejects(
            .clientAddressCollidesWithTunnelDNS,
            { try Self.configuration(clientAddress: "10.255.0.1") },
            "the DNS proxy's own address is not a client address")

        // Only the proxy collides. 10.255.0.2 — the DNS-only tunnel address — is an odd
        // choice but a working one: the proxy stays distinct, so interception is unharmed.
        XCTAssertNoThrow(try Self.configuration(clientAddress: "10.255.0.2"))
    }

    func testASubFloorInterfaceMTUIsRefusedNotClamped() {
        // The chained plan always claims ::/0, so RFC 8200 §5's 1280 floor always applies.
        // Refused rather than clamped: a clamped value installs an interface whose MTU
        // disagrees with the file the user is debugging against.
        for mtu in [UInt16(0), 576, 1279] {
            assertRejects(
                .mtuBelowIPv6Floor,
                { try Self.configuration(interfaceMTU: mtu) },
                "MTU \(mtu) is below the IPv6 floor")
        }
        XCTAssertEqual(try Self.configuration(interfaceMTU: 1280).interfaceMTU, 1280)
        XCTAssertEqual(try Self.configuration(interfaceMTU: 1420).interfaceMTU, 1420)
    }

    func testTheInterfaceMTUSurvivesTheValidatingDecoderAndItsAbsenceMeansNil() throws {
        // Present: round-trips, and a bad persisted value is refused by the same validator
        // as a constructed one — the decode-through-the-throwing-init rule.
        let encoded = try JSONEncoder().encode(try Self.configuration(interfaceMTU: 1420))
        XCTAssertEqual(
            try JSONDecoder().decode(ChainedUpstreamConfiguration.self, from: encoded).interfaceMTU,
            1420)

        let subFloor = #"{"endpointHost":"vpn.example.com","endpointPort":51820,"peerPublicKey":"\#(Self.validKey)","clientAddress":"10.64.0.5","allowedIPs":["0.0.0.0/0"],"persistentKeepaliveSeconds":0,"interfaceMTU":1000}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(ChainedUpstreamConfiguration.self, from: Data(subFloor.utf8))
        ) {
            XCTAssertEqual(
                $0 as? ChainedUpstreamConfiguration.ValidationFailure, .mtuBelowIPv6Floor)
        }

        // Absent: decodes as nil — the route plan's 1280 default is the documented answer
        // to a config file with no MTU line (D5). Deliberately the OPPOSITE of the client
        // address above, whose absence fails: a default MTU is protocol-correct, a default
        // address is one no peer agreed to. This is also what keeps a configuration
        // committed before the field existed decodable.
        let legacy = #"{"endpointHost":"vpn.example.com","endpointPort":51820,"peerPublicKey":"\#(Self.validKey)","clientAddress":"10.64.0.5","allowedIPs":["0.0.0.0/0"],"persistentKeepaliveSeconds":0}"#
        XCTAssertNil(
            try JSONDecoder().decode(ChainedUpstreamConfiguration.self, from: Data(legacy.utf8))
                .interfaceMTU)
    }

    private static func configuration(
        clientAddress: String = "10.64.0.5",
        allowedIPs: [String] = ["0.0.0.0/0"],
        interfaceMTU: UInt16? = nil,
        dnsAddresses: [String] = []
    ) throws -> ChainedUpstreamConfiguration {
        try ChainedUpstreamConfiguration(
            endpointHost: "vpn.example.com",
            endpointPort: 51820,
            peerPublicKey: Self.validKey,
            clientAddress: clientAddress,
            allowedIPs: allowedIPs,
            interfaceMTU: interfaceMTU,
            dnsAddresses: dnsAddresses)
    }

    func testDNSAddressesMustBeIPLiterals() throws {
        // The boundary refuses what cannot be an IP literal; USABILITY (family, ranges,
        // local-delivery collisions) is `ChainedTunnelResolverSelection`'s question and is
        // deliberately not asked here.
        for bad in ["dns.example.com", "1.1.1.1:53", "010.0.0.1", "10.64.0"] {
            XCTAssertThrowsError(
                try Self.configuration(dnsAddresses: [bad, "10.64.0.1"]), "accepted \(bad)"
            ) {
                XCTAssertEqual(
                    $0 as? ChainedUpstreamConfiguration.ValidationFailure, .malformedDNSAddress,
                    "wrong failure for \(bad)")
            }
        }
        // Both families are storable — stored as the file spells them, trimmed, with empty
        // entries dropped like AllowedIPs.
        let stored = try Self.configuration(
            dnsAddresses: [" 10.64.0.1 ", "", "2606:4700:4700::1111"])
        XCTAssertEqual(stored.dnsAddresses, ["10.64.0.1", "2606:4700:4700::1111"])
        // Absent means "no DNS = line", the ordinary pre-S6 shape.
        XCTAssertEqual(try Self.configuration().dnsAddresses, [])
    }

    func testAConfigurationStoredBeforeTheDNSFieldExistedStillDecodes() throws {
        // The compatibility obligation `init(from:)` records: a config committed before the
        // field existed keeps decoding, and its absence is a READINESS refusal (cannot
        // latch), never `configurationUnusable` ("re-enter it").
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.make()))
                as? [String: Any])
        json.removeValue(forKey: "dnsAddresses")
        let decoded = try JSONDecoder().decode(
            ChainedUpstreamConfiguration.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.dnsAddresses, [])
    }

    func testRoutingPolicyIsDerivedFromAllowedIPsAndSurvivesARoundTrip() throws {
        // `make()` carries a covering `0.0.0.0/0`, so its derived policy is `.fullTunnel`, and
        // it is encoded (a diagnostic) and re-derived on decode to the same value.
        let original = try Self.make()
        XCTAssertEqual(original.routingPolicy, .fullTunnel)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        XCTAssertEqual(json["routingPolicy"] as? String, "fullTunnel")

        let decoded = try JSONDecoder().decode(
            ChainedUpstreamConfiguration.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.routingPolicy, .fullTunnel)
        XCTAssertEqual(decoded, original)

        // A split config round-trips too: the policy is derived from `allowedIPs`, which
        // round-trips, so the decoded policy matches even though it is not read from its key.
        let split = try Self.configuration(allowedIPs: ["100.64.0.0/10"])
        XCTAssertEqual(split.routingPolicy, .splitTunnel)
        let decodedSplit = try JSONDecoder().decode(
            ChainedUpstreamConfiguration.self, from: JSONEncoder().encode(split))
        XCTAssertEqual(decodedSplit.routingPolicy, .splitTunnel)
        XCTAssertEqual(decodedSplit, split)
    }

    func testRoutingPolicyIsReDerivedOnDecodeNotTrustedFromTheStoredKey() throws {
        // `routingPolicy` is a pure function of `allowedIPs`, so `init(from:)` re-derives it
        // rather than decoding the stored key. That is stronger than `decodeIfPresent`: a
        // persisted value that DISAGREES with the routes (tampering, or a config committed
        // before the derivation rule changed) cannot survive — the routes win. A config
        // committed before the key existed also decodes with no special case. (Codex #545 P2:
        // a trusted policy field would let a persistable config carry split-tunnel metadata
        // over full-tunnel routes.)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.make()))
                as? [String: Any])
        // The stored key lies: claim split over a covering (full) set. Decode must ignore it.
        json["routingPolicy"] = "splitTunnel"
        XCTAssertEqual(
            try JSONDecoder().decode(
                ChainedUpstreamConfiguration.self,
                from: JSONSerialization.data(withJSONObject: json)).routingPolicy,
            .fullTunnel,
            "the routes, not the stored key, decide the policy")

        // Absent entirely: still derived from allowedIPs.
        json.removeValue(forKey: "routingPolicy")
        XCTAssertEqual(
            try JSONDecoder().decode(
                ChainedUpstreamConfiguration.self,
                from: JSONSerialization.data(withJSONObject: json)).routingPolicy,
            .fullTunnel)
    }

    func testAPersistedSplitTunnelPolicyCannotOverrideFullTunnelRoutes() throws {
        // The invariant the field documents: `routingPolicy` is DERIVED from the routes and can
        // never disagree with them. A hand-edited or downgraded persisted blob that asserts
        // `splitTunnel` while its `AllowedIPs` still COVER the default route must decode as
        // `.fullTunnel` — the routes win, the stored policy is not trusted. (Codex #545 P2: a
        // trusted policy field would let a validated, persistable config carry split-tunnel
        // metadata over full-tunnel routes, and a downstream consumer branching on the field
        // would then apply split behaviour to a full tunnel.) Mutation witness: restoring the
        // old `decodeIfPresent(...) ?? .fullTunnel` that trusted the key decodes this as
        // `.splitTunnel`, turning this assertion RED.
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.make()))
                as? [String: Any])
        json["routingPolicy"] = "splitTunnel"
        let decoded = try JSONDecoder().decode(
            ChainedUpstreamConfiguration.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.routingPolicy, .fullTunnel)
    }

    func testAStoredDNSAddressIsRevalidatedOnDecode() throws {
        // Same claim the type makes for every field: it cannot exist in an invalid state,
        // including values round-tripped through disk.
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.make()))
                as? [String: Any])
        json["dnsAddresses"] = ["dns.example.com"]
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ChainedUpstreamConfiguration.self,
                from: JSONSerialization.data(withJSONObject: json))
        ) {
            XCTAssertEqual(
                $0 as? ChainedUpstreamConfiguration.ValidationFailure, .malformedDNSAddress)
        }
    }

    func testTheValidatorIsNeverLooserThanTheDataPathParser() throws {
        // The defect this guards: a validator that accepts what the representation downstream
        // rejects lets a config be stored and reported READY for data the data path cannot
        // read. Asserted across the shapes review found, plus the legal ones, rather than
        // spot-checked — the failure mode is a form nobody thought to try.
        let shapes = [
            "0.0.0.0/0", "10.0.0.0/8", "0.0.0.0/32", "255.255.255.0/24",
            "::/0", "::/128", "fd00::/8", "2001:db8::/32",
            "foo:/bar", "::/129", "::/", "::/-1", "2001:db8::/abc", "gggg::/64",
            "10.0.0.0/33", "10.0.0.0/", "/0", "not-a-prefix", "10.0.0.0/abc",
            "foo:bar", "::garbage", "0.0.0.0:bad",
        ]
        for shape in shapes {
            let mine = (try? Self.configuration(allowedIPs: ["0.0.0.0/0", shape])) != nil
            let dataPath = ChainedIPPrefix(shape) != nil
            if mine {
                XCTAssertTrue(
                    dataPath,
                    "validator accepted \(shape) but ChainedIPPrefix rejects it — ready for unreadable data")
            }
        }
    }

}
