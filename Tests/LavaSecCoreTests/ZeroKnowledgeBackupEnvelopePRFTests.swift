import XCTest
@testable import LavaSecCore

final class ZeroKnowledgeBackupEnvelopePRFTests: XCTestCase {
    private let phrase = "mavi nopa rytu seko hula pemi davo ciny"
    private let deviceSecret = "device-secret-32-byte-random-value"
    private let serverRecoveryShare = "server-share-32-byte-random-value"
    private let prfOutput = Data(repeating: 0x2A, count: 32)
    private let prfSalt = Data(repeating: 0x07, count: 32)

    private func makeEnvelope(
        payload: BackupConfigurationPayload
    ) throws -> ZeroKnowledgeBackupEnvelope {
        try ZeroKnowledgeBackupEnvelope.makeWithPRFForTesting(
            payload: payload,
            deviceSecret: deviceSecret,
            serverRecoveryShare: serverRecoveryShare,
            recoveryPhrase: phrase,
            passkeyPRFOutput: prfOutput,
            passkeyPRFSalt: prfSalt,
            passkeyCredentialID: "credential-id"
        )
    }

    func testPRFEnvelopeHasExpectedSlotsAndHKDFPasskeySlot() throws {
        let payload = BackupConfigurationPayload(
            configuration: AppConfiguration(allowedDomains: ["school.example"])
        )
        let envelope = try makeEnvelope(payload: payload)

        XCTAssertEqual(envelope.keySlots.map(\.kind), [.keychain, .assistedRecovery, .passkey])
        let passkeySlot = try XCTUnwrap(envelope.keySlots.first { $0.kind == .passkey })
        XCTAssertEqual(passkeySlot.kdf, "HKDF-SHA256")
        XCTAssertEqual(passkeySlot.credentialID, "credential-id")
        XCTAssertEqual(passkeySlot.salt, prfSalt.base64EncodedString())
    }

    func testRoundTripsWithMatchingPRFOutput() throws {
        let payload = BackupConfigurationPayload(
            configuration: AppConfiguration(
                enabledBlocklistIDs: ["hagezi-multi-pro-mini"],
                blockedDomains: ["casino.example"]
            )
        )
        let envelope = try makeEnvelope(payload: payload)

        XCTAssertEqual(try envelope.decryptWithPasskeyPRFOutput(prfOutput), payload)
    }

    func testRejectsWrongPRFOutput() throws {
        let payload = BackupConfigurationPayload(configuration: AppConfiguration())
        let envelope = try makeEnvelope(payload: payload)

        XCTAssertThrowsError(try envelope.decryptWithPasskeyPRFOutput(Data(repeating: 0x2B, count: 32)))
    }

    /// The other slots stay usable: keychain (device-local secret) and assisted recovery
    /// (user phrase + server share). This confirms the PRF rewrite did not regress them.
    func testKeychainAndAssistedRecoverySlotsStillWork() throws {
        let payload = BackupConfigurationPayload(
            configuration: AppConfiguration(allowedDomains: ["school.example"])
        )
        let envelope = try makeEnvelope(payload: payload)

        XCTAssertEqual(try envelope.decryptWithKeychainSecret(deviceSecret), payload)
        XCTAssertEqual(try envelope.decryptWithAssistedRecoveryPhrase(phrase), payload)
    }

    /// Zero-knowledge invariant for the passkey slot: nothing the server stores unwraps it.
    /// The server holds the full envelope JSON (ciphertext, salts, wrapped keys,
    /// `server_recovery_share`, credential ID) — but never the PRF output. So:
    /// (a) the PRF output must not appear anywhere in the serialized envelope, and
    /// (b) the old escrow path (a server-returned string secret via PBKDF2) cannot open the slot,
    ///     because the slot is HKDF-derived, not PBKDF2.
    func testPasskeySlotIsNotDecryptableFromAnyServerHeldValue() throws {
        let payload = BackupConfigurationPayload(
            configuration: AppConfiguration(blockedDomains: ["casino.example"])
        )
        let envelope = try makeEnvelope(payload: payload)

        let json = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        XCTAssertFalse(json.contains(prfOutput.base64EncodedString()))

        // The server holds server_recovery_share; it must not unwrap the passkey slot.
        let serverShare = try XCTUnwrap(envelope.serverRecoveryShare)
        XCTAssertThrowsError(try envelope.decryptWithPasskeySecret(serverShare))
        // No server-returned string secret can drive the (now HKDF) passkey slot at all.
        XCTAssertThrowsError(try envelope.decryptWithPasskeySecret("any-server-returned-secret"))
    }
}
