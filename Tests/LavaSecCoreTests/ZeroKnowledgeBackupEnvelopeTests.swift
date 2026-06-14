import XCTest
@testable import LavaSecCore

final class ZeroKnowledgeBackupEnvelopeTests: XCTestCase {
    func testEstimateUsesPayloadAndKeySlotOverhead() throws {
        let payload = BackupConfigurationPayload(configuration: AppConfiguration())
        let estimate = try ZeroKnowledgeBackupEnvelope.estimatedByteSize(for: payload, keySlotCount: 3)

        XCTAssertGreaterThan(estimate, 1024)
        XCTAssertLessThan(estimate, 8192)
    }

    func testEnvelopeDoesNotContainPlaintextDomains() throws {
        let payload = BackupConfigurationPayload(
            configuration: AppConfiguration(
                allowedDomains: ["school.example"],
                blockedDomains: ["casino.example"]
            )
        )

        let envelope = try ZeroKnowledgeBackupEnvelope.makeForTesting(
            payload: payload,
            password: "lava2026!",
            recoveryPhrase: "ember vault canyon ribbon orbit cedar window quiet"
        )
        let data = try JSONEncoder().encode(envelope)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(json.contains("school.example"))
        XCTAssertFalse(json.contains("casino.example"))
        XCTAssertGreaterThan(envelope.ciphertextByteSize, 0)
    }

    func testEnvelopePreservesCustomBlocklistURLsWithoutPlaintextLeak() throws {
        let customSource = try CustomBlocklistSource(
            id: "custom-private-feed",
            displayName: "Private Feed",
            rawURL: "https://private.example.com/lists/pi-hole-style-list.txt",
            lastAcceptedHash: String(repeating: "c", count: 64)
        )
        let payload = BackupConfigurationPayload(
            configuration: AppConfiguration(
                enabledBlocklistIDs: [customSource.id],
                customBlocklists: [customSource]
            )
        )

        let envelope = try ZeroKnowledgeBackupEnvelope.makeForTesting(
            payload: payload,
            password: "lava2026!",
            recoveryPhrase: "ember vault canyon ribbon orbit cedar window quiet"
        )
        let data = try JSONEncoder().encode(envelope)
        let json = String(decoding: data, as: UTF8.self)
        let restored = try envelope.decryptWithPassword("lava2026!")

        XCTAssertFalse(json.contains(customSource.sourceURL.absoluteString))
        XCTAssertFalse(json.contains("private.example.com"))
        XCTAssertEqual(restored.enabledBlocklistIDs, [customSource.id])
        XCTAssertEqual(restored.customBlocklists, [customSource])
    }

    func testDecryptsWithBackupPassword() throws {
        let payload = BackupConfigurationPayload(
            configuration: AppConfiguration(
                enabledBlocklistIDs: ["hagezi-multi-pro-mini"],
                allowedDomains: ["school.example"],
                resolverPresetID: DNSResolverPreset.quad9SecureDoH.id
            )
        )
        let envelope = try ZeroKnowledgeBackupEnvelope.makeForTesting(
            payload: payload,
            password: "lava2026!",
            recoveryPhrase: "ember vault canyon ribbon orbit cedar window quiet"
        )

        let restored = try envelope.decryptWithPassword("lava2026!")

        XCTAssertEqual(restored, payload)
    }

    func testDecryptsWithRecoveryPhrase() throws {
        let payload = BackupConfigurationPayload(
            configuration: AppConfiguration(blockedDomains: ["casino.example"])
        )
        let phrase = "ember vault canyon ribbon orbit cedar window quiet"
        let envelope = try ZeroKnowledgeBackupEnvelope.makeForTesting(
            payload: payload,
            password: "lava2026!",
            recoveryPhrase: phrase
        )

        let restored = try envelope.decryptWithRecoveryPhrase(phrase)

        XCTAssertEqual(restored, payload)
    }

    func testPasswordlessEnvelopeDecryptsWithDeviceSecretAndAssistedRecoveryPhrase() throws {
        let payload = BackupConfigurationPayload(
            configuration: AppConfiguration(allowedDomains: ["school.example"])
        )
        let phrase = "mavi nopa rytu seko hula pemi davo ciny"
        let serverRecoveryShare = "server-share-32-byte-random-value"
        let envelope = try ZeroKnowledgeBackupEnvelope.makePasswordlessForTesting(
            payload: payload,
            deviceSecret: "device-secret-32-byte-random-value",
            serverRecoveryShare: serverRecoveryShare,
            recoveryPhrase: phrase
        )

        XCTAssertEqual(envelope.keySlots.map(\.kind), [.keychain, .assistedRecovery])
        XCTAssertEqual(envelope.serverRecoveryShare, serverRecoveryShare)
        XCTAssertEqual(try envelope.decryptWithKeychainSecret("device-secret-32-byte-random-value"), payload)
        XCTAssertEqual(try envelope.decryptWithAssistedRecoveryPhrase(phrase), payload)
        XCTAssertThrowsError(try envelope.decryptWithRecoveryPhrase(phrase))
        XCTAssertThrowsError(try envelope.decryptWithPassword("device-secret-32-byte-random-value"))
    }

    func testPasswordlessEnvelopeCanIncludeServerGatedPasskeySlot() throws {
        let payload = BackupConfigurationPayload(
            configuration: AppConfiguration(blockedDomains: ["casino.example"])
        )
        let envelope = try ZeroKnowledgeBackupEnvelope.makePasswordlessForTesting(
            payload: payload,
            deviceSecret: "device-secret-32-byte-random-value",
            serverRecoveryShare: "server-share-32-byte-random-value",
            recoveryPhrase: "mavi nopa rytu seko hula pemi davo ciny",
            passkeySecret: "server-gated-passkey-secret",
            passkeyCredentialID: "credential-id"
        )

        XCTAssertEqual(envelope.keySlots.map(\.kind), [.keychain, .assistedRecovery, .passkey])
        XCTAssertEqual(envelope.keySlots.last?.credentialID, "credential-id")
        XCTAssertEqual(try envelope.decryptWithPasskeySecret("server-gated-passkey-secret"), payload)
        XCTAssertThrowsError(try envelope.decryptWithPasskeySecret("wrong-passkey-secret"))
    }

    func testAssistedRecoveryRequiresServerShareAndUserPhrase() throws {
        let payload = BackupConfigurationPayload(
            configuration: AppConfiguration(
                enabledBlocklistIDs: ["hagezi-multi-pro-mini"],
                allowedDomains: ["school.example"]
            )
        )
        let phrase = "mavi nopa rytu seko hula pemi davo ciny"
        let serverRecoveryShare = "server-share-32-byte-random-value"
        let envelope = try ZeroKnowledgeBackupEnvelope.makePasswordlessForTesting(
            payload: payload,
            deviceSecret: "device-secret-32-byte-random-value",
            serverRecoveryShare: serverRecoveryShare,
            recoveryPhrase: phrase
        )

        XCTAssertThrowsError(try envelope.decryptWithAssistedRecoveryPhrase(""))
        XCTAssertThrowsError(try envelope.decryptWithAssistedRecoveryPhrase("wrong phrase"))
        XCTAssertEqual(try envelope.decryptWithAssistedRecoveryPhrase(phrase), payload)

        let envelopeWithoutServerShare = ZeroKnowledgeBackupEnvelope(
            payloadCiphertext: envelope.payloadCiphertext,
            keySlots: envelope.keySlots,
            ciphertextByteSize: envelope.ciphertextByteSize,
            createdAt: envelope.createdAt
        )
        XCTAssertThrowsError(try envelopeWithoutServerShare.decryptWithAssistedRecoveryPhrase(phrase))
    }

    func testDecryptsLegacyEnvelopeProducedByOriginalPBKDF2Implementation() throws {
        let keySlot = ZeroKnowledgeBackupKeySlot(
            kind: .password,
            kdf: "PBKDF2-HMAC-SHA256",
            salt: "oKGio6SlpqeoqaqrrK2urw==",
            iterations: 8,
            wrappedKey: "ICEiIyQlJicoKSorEQFga6I/cWE8bW6YzbgDYLR8AyuTll3cw1gAQ7l6V7YH9IiQlNVPQsHyxK1486b3"
        )
        let envelope = ZeroKnowledgeBackupEnvelope(
            payloadCiphertext: "EBESExQVFhcYGRobycnbdOcUa8AvFPD2B6O4Ga+wQrukXJ22LqJas9E1/QWWgBP7BA7YnVzygtztSS5qq9LbsWbqjzZd5RVTM42DZJC9GjRNNC91vZ7xjQw2Rj0P1X98rHCO8xPiZC1CxuMoOyePNVWxsNyWXOAVgAi11UYtjcAPQEMwPMcr6ZYOV64CzrxVhIac8lZK/INV08SAShxkvlJmw9aDBnZUmFrtQE0FGACuhr9+UNkOZ7bHcvUuE17yuoBWd86NqlIE8YxeIb/oFRHgzMQORgIovsvod38bkRxAVBE4CJlgyeEX+0AlRpcWRCJ194547haXQ6km3riqu3djMnYXSq4YcX/X/gJ0XgsdG51mwMyyxnAdGPwHLvLy7cqvrIrMhT2NHHq4eUWdKj6KsW58z2qN25RoQYwIPMBSdIubia2m8aaEPPFnudXuEKVouETWCLKGEqUkYZJok5uYQ9PY/DuNRuFzMn76eSnwSYrc6Msma6s978a26M0=",
            keySlots: [keySlot],
            ciphertextByteSize: 383,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let expected = BackupConfigurationPayload(
            enabledBlocklistIDs: ["hagezi-multi-pro-mini"],
            allowedDomains: ["school.example"],
            blockedDomains: ["casino.example"],
            resolverPresetID: DNSResolverPreset.quad9SecureDoH.id,
            keepDomainDiagnostics: true,
            protectionEnabledHint: true,
            catalogVersionHint: "legacy-catalog"
        )

        let restored = try envelope.decryptWithPassword("legacy-lava-2026!")

        XCTAssertEqual(restored, expected)
    }

    func testRejectsWrongPassword() throws {
        let payload = BackupConfigurationPayload(configuration: AppConfiguration())
        let envelope = try ZeroKnowledgeBackupEnvelope.makeForTesting(
            payload: payload,
            password: "lava2026!",
            recoveryPhrase: "ember vault canyon ribbon orbit cedar window quiet"
        )

        XCTAssertThrowsError(try envelope.decryptWithPassword("wrong2026!"))
    }

    func testRejectsUnsupportedKeyDerivationFunction() throws {
        let payload = BackupConfigurationPayload(configuration: AppConfiguration())
        let envelope = try ZeroKnowledgeBackupEnvelope.makeForTesting(
            payload: payload,
            password: "lava2026!",
            recoveryPhrase: "ember vault canyon ribbon orbit cedar window quiet"
        )
        let passwordSlot = try XCTUnwrap(envelope.keySlots.first { $0.kind == .password })
        let unsupportedSlot = ZeroKnowledgeBackupKeySlot(
            kind: passwordSlot.kind,
            kdf: "PBKDF2-HMAC-SHA1",
            salt: passwordSlot.salt,
            iterations: passwordSlot.iterations,
            wrappedKey: passwordSlot.wrappedKey
        )
        let unsupportedEnvelope = ZeroKnowledgeBackupEnvelope(
            payloadCiphertext: envelope.payloadCiphertext,
            keySlots: [unsupportedSlot],
            ciphertextByteSize: envelope.ciphertextByteSize,
            createdAt: envelope.createdAt
        )

        XCTAssertThrowsError(try unsupportedEnvelope.decryptWithPassword("lava2026!")) { error in
            XCTAssertEqual(
                error as? ZeroKnowledgeBackupEnvelopeError,
                .unsupportedKeyDerivationFunction("PBKDF2-HMAC-SHA1")
            )
        }
    }
}
