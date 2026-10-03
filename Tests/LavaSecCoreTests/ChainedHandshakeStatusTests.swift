import XCTest

@testable import LavaSecKit

final class ChainedHandshakeStatusTests: XCTestCase {

    func testProviderIncarnationWakeBoundaryAndRuntimeConditionSurviveWireAndAdaptation() throws {
        let health = TunnelHealthSnapshot(startedAt: Date(timeIntervalSince1970: 1_000))
        for condition in [ChainedRuntimeCondition.normal, .suspended, .recovering, .offline, .retired] {
            let reply = ChainedHandshakeStatus(isChained: true, hasHandshake: true,
                everHandshaked: true, receivedByteCount: 91, sessionGeneration: 4,
                transportGeneration: 2, providerLifecycleID: "test-provider-incarnation",
                verificationEpoch: 3, forwardingBaseline: 90, runtimeCondition: condition, health: health)
            let decoded = try XCTUnwrap(ChainedHandshakeStatus.decode(reply.encoded()))
            XCTAssertEqual(decoded, reply)
            guard case .chained(let session?) = ChainedRuntimeObservation.fromTunnelReply(decoded) else {
                return XCTFail("Expected live chained session")
            }
            XCTAssertEqual(session.providerLifecycleID, "test-provider-incarnation")
            XCTAssertEqual(session.verificationEpoch, 3)
            XCTAssertEqual(session.forwardingBaseline, 90)
            XCTAssertEqual(session.forwardedBytes, 91)
            XCTAssertEqual(session.runtimeCondition, condition)
            XCTAssertEqual(session.health, health)
        }
    }

    func testLegacyReplyDoesNotInventProviderOrWakeIdentity() throws {
        let legacy = Data(#"{"isChained":true,"hasHandshake":true,"everHandshaked":true,"sessionGeneration":1,"transportGeneration":1,"receivedByteCount":12,"lifecycleIsActive":true}"#.utf8)
        let decoded = try XCTUnwrap(ChainedHandshakeStatus.decode(legacy))
        XCTAssertNil(decoded.providerLifecycleID)
        XCTAssertNil(decoded.verificationEpoch)
        XCTAssertNil(decoded.health)
        XCTAssertEqual(decoded.forwardingBaseline, 0)
        XCTAssertEqual(decoded.runtimeCondition, .normal)
        let roundTrip = try XCTUnwrap(ChainedHandshakeStatus.decode(decoded.encoded()))
        XCTAssertEqual(roundTrip, decoded)
        guard case .chained(let session?) = ChainedRuntimeObservation.fromTunnelReply(roundTrip) else {
            return XCTFail("Expected conservative legacy fresh-reply adaptation")
        }
        XCTAssertNil(session.providerLifecycleID)
        XCTAssertNil(session.verificationEpoch)
    }

    func testUnknownOrMalformedRuntimeMetadataIsNotANormalReply() throws {
        let reply = ChainedHandshakeStatus(isChained: true, hasHandshake: true,
            everHandshaked: true, sessionGeneration: 1, transportGeneration: 1,
            providerLifecycleID: "test-provider", verificationEpoch: 1)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: reply.encoded()) as? [String: Any])
        for (key, value) in [("runtimeCondition", "future-condition"),
                             ("verificationEpoch", "not-a-number"),
                             ("forwardingBaseline", "not-a-number")] {
            var malformed = original
            malformed[key] = value
            XCTAssertNil(ChainedHandshakeStatus.decode(try JSONSerialization.data(withJSONObject: malformed)),
                "Unrecognized metadata must not be decoded as normal current evidence")
        }
    }

    func testSetupReadinessRequiresExplicitProviderHandshakeAndCurrentWireEvidence() throws {
        for handshake in [false, true] {
            let reply = ChainedHandshakeStatus(isChained: true, hasHandshake: handshake,
                everHandshaked: true, sessionGeneration: 1, transportGeneration: 1, setupReady: true)
            let decoded = try XCTUnwrap(ChainedHandshakeStatus.decode(reply.encoded()))
            XCTAssertEqual(decoded, reply)
            guard case .chained(let session?) = ChainedRuntimeObservation.fromTunnelReply(decoded) else {
                return XCTFail("Expected live session")
            }
            XCTAssertEqual(session.setupReady, handshake)
        }
        let legacy = Data(#"{"isChained":true,"hasHandshake":true,"everHandshaked":true,"sessionGeneration":1,"transportGeneration":1,"lifecycleIsActive":true}"#.utf8)
        XCTAssertFalse(try XCTUnwrap(ChainedHandshakeStatus.decode(legacy)).setupReady)
    }

    func testTransportIncarnationSurvivesWireRoundTripAndRuntimeAdaptation() throws {
        let status = ChainedHandshakeStatus(isChained: true, hasHandshake: true,
            everHandshaked: true, receivedByteCount: 42, sessionGeneration: 7,
            transportGeneration: 3)
        let decoded = try XCTUnwrap(ChainedHandshakeStatus.decode(status.encoded()))
        XCTAssertEqual(decoded, status)
        XCTAssertEqual(ChainedRuntimeObservation.fromTunnelReply(decoded),
            .chained(session: .init(generation: 7, forwardedBytes: 42, transportGeneration: 3)))
    }

    func testAMissingTunnelReplyRemainsAnUnknownRuntimeObservation() {
        XCTAssertNil(ChainedRuntimeObservation.fromTunnelReply(nil))
    }

    func testAnInactiveLifecycleOutranksItsPreviouslyLatchedMode() {
        let inactive = ChainedHandshakeStatus(
            isChained: true,
            hasHandshake: true,
            everHandshaked: true,
            receivedByteCount: 12,
            sessionGeneration: 9,
            lifecycleIsActive: false)

        XCTAssertEqual(
            ChainedRuntimeObservation.fromTunnelReply(inactive),
            .inactive)
    }

    func testAnActiveNonChainedLifecycleIsDNSOnly() {
        let dnsOnly = ChainedHandshakeStatus(
            isChained: false,
            hasHandshake: false,
            everHandshaked: false,
            lifecycleIsActive: true)

        XCTAssertEqual(
            ChainedRuntimeObservation.fromTunnelReply(dnsOnly),
            .dnsOnly)
    }

    /// An app upgrade can leave the previous extension process running. That extension omitted the
    /// lifecycle bit and reported `isChained == false` both for DNS-only and for a chained runner
    /// gap, so the adapter must keep that one legacy shape unknown instead of stopping sampling.
    func testALegacyFalseModeReplyRemainsUnknownWithoutLifecycleProvenance() throws {
        let legacy = Data(
            """
            {
              "isChained": false,
              "hasHandshake": false,
              "everHandshaked": false
            }
            """.utf8)

        let decoded = try XCTUnwrap(ChainedHandshakeStatus.decode(legacy))

        XCTAssertTrue(decoded.lifecycleIsActive)
        XCTAssertNil(ChainedRuntimeObservation.fromTunnelReply(decoded))
    }

    func testLegacyAndExplicitActiveFalseRepliesAreNotEqualBecauseTheyAdaptDifferently() throws {
        let legacy = try XCTUnwrap(
            ChainedHandshakeStatus.decode(
                Data(
                    """
                    {
                      "isChained": false,
                      "hasHandshake": false,
                      "everHandshaked": false
                    }
                    """.utf8)))
        let explicitDNSOnly = ChainedHandshakeStatus(
            isChained: false,
            hasHandshake: false,
            everHandshaked: false,
            lifecycleIsActive: true)

        XCTAssertNotEqual(legacy, explicitDNSOnly)
        XCTAssertNil(ChainedRuntimeObservation.fromTunnelReply(legacy))
        XCTAssertEqual(ChainedRuntimeObservation.fromTunnelReply(explicitDNSOnly), .dnsOnly)
    }

    func testLegacyFalseReplyRoundTripPreservesMissingLifecycleProvenance() throws {
        let legacy = try XCTUnwrap(
            ChainedHandshakeStatus.decode(
                Data(
                    """
                    {
                      "isChained": false,
                      "hasHandshake": false,
                      "everHandshaked": false
                    }
                    """.utf8)))

        let reencoded = legacy.encoded()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        let roundTripped = try XCTUnwrap(ChainedHandshakeStatus.decode(reencoded))

        XCTAssertNil(object["lifecycleIsActive"])
        XCTAssertEqual(roundTripped, legacy)
        XCTAssertNil(ChainedRuntimeObservation.fromTunnelReply(roundTripped))
    }

    func testANullLifecycleFieldDoesNotFabricateExplicitActiveProvenance() throws {
        let malformed = Data(
            """
            {
              "isChained": false,
              "hasHandshake": false,
              "everHandshaked": false,
              "lifecycleIsActive": null
            }
            """.utf8)

        let decoded = try XCTUnwrap(ChainedHandshakeStatus.decode(malformed))

        XCTAssertTrue(decoded.lifecycleIsActive)
        XCTAssertNil(ChainedRuntimeObservation.fromTunnelReply(decoded))
    }

    func testGenerationZeroIsAChainedLifecycleWithoutACurrentSession() {
        let runnerGap = ChainedHandshakeStatus(
            isChained: true,
            hasHandshake: false,
            everHandshaked: false,
            receivedByteCount: 0,
            sessionGeneration: 0,
            lifecycleIsActive: true)

        XCTAssertEqual(
            ChainedRuntimeObservation.fromTunnelReply(runnerGap),
            .chained(session: nil))
    }

    func testANonzeroGenerationCarriesTheSessionIdentityAndForwardingEvidence() {
        let liveSession = ChainedHandshakeStatus(
            isChained: true,
            hasHandshake: false,
            everHandshaked: false,
            receivedByteCount: 42,
            sessionGeneration: 7,
            lifecycleIsActive: true)

        XCTAssertEqual(
            ChainedRuntimeObservation.fromTunnelReply(liveSession),
            .chained(session: .init(generation: 7, forwardedBytes: 42)))
    }

    /// Callers compiled before the lifecycle field existed do not pass it. Removing the initializer
    /// default breaks their source compatibility even though the JSON decoder stays tolerant.
    func testTheSourceCompatibleInitializerDefaultsLifecycleActive() {
        let defaulted = ChainedHandshakeStatus(
            isChained: false,
            hasHandshake: false,
            everHandshaked: false)

        XCTAssertTrue(defaulted.lifecycleIsActive)
    }

    /// Removing any tolerant field decode makes an app talking to the oldest extension lose the
    /// whole status reply. Lifecycle safely defaults active because an older payload was emitted
    /// only by a provider handling the prompt message; its absent evidence fields safely default 0.
    func testAnOlderReplyWithoutLifecycleActivityDefaultsActive() throws {
        let legacy = Data(
            """
            {
              "isChained": true,
              "hasHandshake": false,
              "everHandshaked": false
            }
            """.utf8)

        let decoded = try XCTUnwrap(ChainedHandshakeStatus.decode(legacy))

        XCTAssertTrue(decoded.lifecycleIsActive)
        XCTAssertEqual(decoded.receivedByteCount, 0)
        XCTAssertEqual(decoded.sessionGeneration, 0)
        XCTAssertEqual(decoded.transportGeneration, 0)
    }

    /// Omitting the field from encode, hard-coding it on decode, or changing the initializer default
    /// all lose an explicit inactive lifecycle and collapse the new third truth back into ambiguity.
    func testAnExplicitInactiveLifecycleSurvivesTheWireRoundTrip() throws {
        let inactive = ChainedHandshakeStatus(
            isChained: true,
            hasHandshake: false,
            everHandshaked: false,
            receivedByteCount: 0,
            sessionGeneration: 0,
            lifecycleIsActive: false)

        let decoded = try XCTUnwrap(ChainedHandshakeStatus.decode(inactive.encoded()))

        XCTAssertEqual(decoded, inactive)
        XCTAssertFalse(decoded.lifecycleIsActive)
    }
}
