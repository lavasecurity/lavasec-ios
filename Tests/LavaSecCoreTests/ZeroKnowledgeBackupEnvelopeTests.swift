import CommonCrypto
import XCTest
@testable import LavaSecCore
@testable import LavaSecAppServices
@testable import LavaSecKit

final class ZeroKnowledgeBackupEnvelopeTests: XCTestCase {
    func testPersistedEnvelopeVocabularyMatchesCurrentCryptoFormat() throws {
        XCTAssertEqual(
            [
                ZeroKnowledgeBackupKeySlotKind.assistedRecovery,
                .password,
                .recoveryPhrase,
                .keychain,
                .passkey,
            ].map(\.rawValue),
            ["assistedRecovery", "password", "recoveryPhrase", "keychain", "passkey"]
        )
        XCTAssertEqual(ZeroKnowledgeBackupEnvelope.currentSchemaVersion, 1)
        XCTAssertEqual(ZeroKnowledgeBackupEnvelope.currentEnvelopeVersion, 1)

        let envelope = try ZeroKnowledgeBackupEnvelope.makeForTesting(
            payload: BackupConfigurationPayload(configuration: AppConfiguration()),
            password: "lava2026!",
            recoveryPhrase: "ember vault canyon ribbon orbit cedar window quiet"
        )

        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertEqual(envelope.envelopeVersion, 1)
        XCTAssertEqual(envelope.cipher, "AES-256-GCM")
        XCTAssertEqual(Set(envelope.keySlots.map(\.kdf)), ["PBKDF2-HMAC-SHA256"])
    }

    func testLegacySerializedEnvelopeDecodesMissingOptionalRecoveryFieldsAsNil() throws {
        let legacyJSON = #"""
        {
          "schemaVersion": 1,
          "envelopeVersion": 1,
          "cipher": "AES-256-GCM",
          "payloadCiphertext": "AA==",
          "keySlots": [
            {
              "kind": "password",
              "kdf": "PBKDF2-HMAC-SHA256",
              "salt": "AA==",
              "iterations": 8,
              "wrappedKey": "AA=="
            }
          ],
          "ciphertextByteSize": 1,
          "createdAt": 0
        }
        """#.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(ZeroKnowledgeBackupEnvelope.self, from: legacyJSON)

        XCTAssertNil(envelope.serverRecoveryShare)
        XCTAssertNil(try XCTUnwrap(envelope.keySlots.first).credentialID)
    }

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

    func testResealingPayloadUpdatesContentsButKeepsEveryUnlockPath() throws {
        let sampleDeviceSecretValue = "device-secret-32-byte-random-value"
        let phrase = "mavi nopa rytu seko hula pemi davo ciny"
        let serverRecoveryShare = "server-share-32-byte-random-value"

        let original = BackupConfigurationPayload(
            configuration: AppConfiguration(enabledBlocklistIDs: ["a"]),
            filterLibrary: FilterLibrary(filters: [Filter(id: "default", name: "Default")], activeFilterID: "default")
        )
        let envelope = try ZeroKnowledgeBackupEnvelope.makePasswordlessForTesting(
            payload: original,
            deviceSecret: sampleDeviceSecretValue,
            serverRecoveryShare: serverRecoveryShare,
            recoveryPhrase: phrase
        )

        // A post-turn-on change: a 2nd filter is now hosted + active.
        let updated = BackupConfigurationPayload(
            configuration: AppConfiguration(enabledBlocklistIDs: ["a", "b"]),
            filterLibrary: FilterLibrary(
                filters: [Filter(id: "default", name: "Default"), Filter(id: "f2", name: "Work")],
                activeFilterID: "f2"
            )
        )
        let resealed = try envelope.resealingPayload(updated, deviceSecret: sampleDeviceSecretValue)

        // Key slots are byte-identical, so EVERY existing unlock path still works — and now
        // decrypts the updated payload (the new filter survives a restore).
        XCTAssertEqual(resealed.keySlots, envelope.keySlots)
        XCTAssertEqual(try resealed.decryptWithKeychainSecret(sampleDeviceSecretValue), updated)
        XCTAssertEqual(try resealed.decryptWithAssistedRecoveryPhrase(phrase), updated)
        XCTAssertEqual(try resealed.decryptWithKeychainSecret(sampleDeviceSecretValue).restoredFilterLibrary()?.filters.count, 2)
        // The original envelope is untouched (value semantics).
        XCTAssertEqual(try envelope.decryptWithKeychainSecret(sampleDeviceSecretValue), original)
    }

    func testRekeyingDeviceSlotLetsANewDeviceReSeal() throws {
        let phrase = "mavi nopa rytu seko hula pemi davo ciny"
        let serverRecoveryShare = "server-share-32-byte-random-value"
        let payload = BackupConfigurationPayload(
            configuration: AppConfiguration(enabledBlocklistIDs: ["a"]),
            filterLibrary: FilterLibrary(filters: [Filter(id: "default", name: "Default")], activeFilterID: "default")
        )
        let envelope = try ZeroKnowledgeBackupEnvelope.makePasswordlessForTesting(
            payload: payload,
            deviceSecret: "old-device-secret-value",
            serverRecoveryShare: serverRecoveryShare,
            recoveryPhrase: phrase
        )

        // A new-device restore via recovery phrase: re-key the device slot with THIS device's
        // own secret (the old device secret isn't available here).
        let sampleNewDeviceSecretValue = "new-device-secret-value"
        let rekeyed = try envelope.rekeyingDeviceSlot(
            newDeviceSecret: sampleNewDeviceSecretValue,
            unlockingAssistedRecoveryPhrase: phrase
        )

        // Same slot kinds, payload unchanged. The new device secret unlocks; the recovery
        // phrase still works; the OLD device secret no longer unlocks the re-keyed slot — so a
        // later re-seal on the new device can recover the payload key via its own secret.
        XCTAssertEqual(rekeyed.keySlots.map(\.kind), envelope.keySlots.map(\.kind))
        XCTAssertEqual(try rekeyed.decryptWithKeychainSecret(sampleNewDeviceSecretValue), payload)
        XCTAssertEqual(try rekeyed.decryptWithAssistedRecoveryPhrase(phrase), payload)
        XCTAssertThrowsError(try rekeyed.decryptWithKeychainSecret("old-device-secret-value"))

        // And re-sealing on the new device now works with its own secret.
        let updated = BackupConfigurationPayload(
            configuration: AppConfiguration(enabledBlocklistIDs: ["a", "b"]),
            filterLibrary: FilterLibrary(
                filters: [Filter(id: "default", name: "Default"), Filter(id: "f2", name: "Work")],
                activeFilterID: "f2"
            )
        )
        let resealed = try rekeyed.resealingPayload(updated, deviceSecret: sampleNewDeviceSecretValue)
        XCTAssertEqual(try resealed.decryptWithKeychainSecret(sampleNewDeviceSecretValue), updated)
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

    func testRejectsExcessiveStoredPBKDFWorkBeforeUnlock() throws {
        let envelope = try ZeroKnowledgeBackupEnvelope.makeForTesting(
            payload: BackupConfigurationPayload(configuration: AppConfiguration()),
            password: "test-password",
            recoveryPhrase: "test-recovery"
        )
        let slot = try XCTUnwrap(envelope.keySlots.first { $0.kind == .password })
        let changed = replacingIterations(1_000_001, in: slot, envelope: envelope)

        XCTAssertThrowsError(try changed.decryptWithPassword("test-password")) { error in
            XCTAssertEqual(error as? ZeroKnowledgeBackupEnvelopeError,
                           .keyDerivationFailed(Int32(kCCParamError)))
        }
    }

    func testRejectsExcessivePBKDFWorkWhenCreatingEnvelope() throws {
        XCTAssertThrowsError(try ZeroKnowledgeBackupEnvelope.make(
            payload: BackupConfigurationPayload(configuration: AppConfiguration()),
            password: "test-password", recoveryPhrase: "test-recovery",
            passwordIterations: 1_000_001
        )) { error in
            XCTAssertEqual(error as? ZeroKnowledgeBackupEnvelopeError,
                           .keyDerivationFailed(Int32(kCCParamError)))
        }
    }

    func testAllPBKDFUnlockPathsRejectUnsupportedWork() throws {
        let envelope = try ZeroKnowledgeBackupEnvelope.makeForTesting(
            payload: BackupConfigurationPayload(configuration: AppConfiguration()),
            password: "test-password", recoveryPhrase: "test-recovery"
        )
        let original = try XCTUnwrap(envelope.keySlots.first)
        for kind in [ZeroKnowledgeBackupKeySlotKind.password, .recoveryPhrase,
                     .keychain, .assistedRecovery, .passkey] {
            for iterations in [Int.min, -1, 0, 1_000_001, Int(UInt32.max), Int.max] {
                let slot = ZeroKnowledgeBackupKeySlot(
                    kind: kind, kdf: original.kdf, salt: original.salt,
                    iterations: iterations, wrappedKey: original.wrappedKey
                )
                let changed = ZeroKnowledgeBackupEnvelope(
                    payloadCiphertext: envelope.payloadCiphertext, keySlots: [slot],
                    serverRecoveryShare: "test-share", ciphertextByteSize: envelope.ciphertextByteSize
                )
                let unlock: () throws -> BackupConfigurationPayload = {
                    switch kind {
                    case .password: try changed.decryptWithPassword("test-password")
                    case .recoveryPhrase: try changed.decryptWithRecoveryPhrase("test-recovery")
                    case .keychain: try changed.decryptWithKeychainSecret("test-device")
                    case .assistedRecovery: try changed.decryptWithAssistedRecoveryPhrase("test-recovery")
                    case .passkey: try changed.decryptWithPasskeySecret("test-passkey")
                    }
                }
                XCTAssertThrowsError(try unlock(), "\(kind), \(iterations)") { error in
                    XCTAssertEqual(error as? ZeroKnowledgeBackupEnvelopeError,
                                   .keyDerivationFailed(Int32(kCCParamError)))
                }
            }
        }
    }

    func testSupportedPBKDFBoundaryCountsRoundTripWithoutClamping() throws {
        let payload = BackupConfigurationPayload(configuration: AppConfiguration(blockedDomains: ["blocked.example"]))
        for iterations in [1, 8, 210_000, 1_000_000] {
            let envelope = try ZeroKnowledgeBackupEnvelope.make(
                payload: payload, password: "test-password", recoveryPhrase: "test-recovery",
                passwordIterations: iterations
            )
            XCTAssertTrue(envelope.keySlots.allSatisfy { $0.iterations == iterations })
            XCTAssertEqual(try envelope.decryptWithPassword("test-password"), payload)
        }
    }

    func testPRFRestoreCannotCopyExcessiveDeviceSlotWorkIntoRekey() throws {
        let payload = BackupConfigurationPayload(configuration: AppConfiguration())
        let prfOutput = Data(repeating: 0x2A, count: 32)
        let envelope = try ZeroKnowledgeBackupEnvelope.makeWithPRFForTesting(
            payload: payload, deviceSecret: "test-device", recoveryPhrase: "test-recovery",
            passkeyPRFOutput: prfOutput, passkeyPRFSalt: Data(repeating: 0x07, count: 32),
            passkeyCredentialID: "test-credential"
        )
        let deviceSlot = try XCTUnwrap(envelope.keySlots.first { $0.kind == .keychain })
        let changed = replacingIterations(1_000_001, in: deviceSlot, envelope: envelope)
        // HKDF does not use PBKDF rounds, but the subsequent device rekey does.
        XCTAssertEqual(try changed.decryptWithPasskeyPRFOutput(prfOutput), payload)
        XCTAssertThrowsError(try changed.rekeyingDeviceSlot(
            newDeviceSecret: "new-test-device", unlockingPasskeyPRFOutput: prfOutput
        )) { error in
            XCTAssertEqual(error as? ZeroKnowledgeBackupEnvelopeError,
                           .keyDerivationFailed(Int32(kCCParamError)))
        }
        XCTAssertThrowsError(try changed.resealingPayload(payload, deviceSecret: "test-device")) { error in
            XCTAssertEqual(error as? ZeroKnowledgeBackupEnvelopeError,
                           .keyDerivationFailed(Int32(kCCParamError)))
        }
    }

    private func replacingIterations(
        _ iterations: Int, in slot: ZeroKnowledgeBackupKeySlot,
        envelope: ZeroKnowledgeBackupEnvelope
    ) -> ZeroKnowledgeBackupEnvelope {
        ZeroKnowledgeBackupEnvelope(
            payloadCiphertext: envelope.payloadCiphertext,
            keySlots: envelope.keySlots.map { candidate in
                guard candidate.kind == slot.kind else { return candidate }
                return ZeroKnowledgeBackupKeySlot(
                    kind: candidate.kind, kdf: candidate.kdf, salt: candidate.salt,
                    iterations: iterations, wrappedKey: candidate.wrappedKey,
                    credentialID: candidate.credentialID
                )
            },
            serverRecoveryShare: envelope.serverRecoveryShare,
            ciphertextByteSize: envelope.ciphertextByteSize,
            createdAt: envelope.createdAt
        )
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
