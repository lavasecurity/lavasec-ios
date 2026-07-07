import CommonCrypto
import LavaSecKit
import CryptoKit
import Foundation
import Security

public enum ZeroKnowledgeBackupEnvelopeError: Error, Equatable, Sendable {
    case invalidBase64
    case invalidCiphertext
    case keyDerivationFailed(Int32)
    case missingKeySlot
    case missingServerRecoveryShare
    case randomBytesFailed(Int32)
    case unsupportedKeyDerivationFunction(String)
    case unsupportedEnvelopeVersion(Int)
}

public enum ZeroKnowledgeBackupKeySlotKind: String, Codable, Equatable, Sendable {
    case assistedRecovery
    case password
    case recoveryPhrase
    case keychain
    case passkey
}

public enum BackupAssistedRecoverySecret {
    public static func makeServerShare() throws -> String {
        try BackupDeviceSecret.generate()
    }

    public static func combinedSecret(recoveryPhrase: String, serverRecoveryShare: String) -> String {
        let normalizedPhrase = BackupRecoveryPhrase.phrase(
            from: BackupRecoveryPhrase.words(from: recoveryPhrase)
        )
        let material = "LavaSec assisted recovery v1\u{0}\(serverRecoveryShare)\u{0}\(normalizedPhrase)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct ZeroKnowledgeBackupKeySlot: Codable, Equatable, Sendable {
    public let kind: ZeroKnowledgeBackupKeySlotKind
    public let kdf: String
    public let salt: String
    public let iterations: Int
    public let wrappedKey: String
    public let credentialID: String?

    public init(
        kind: ZeroKnowledgeBackupKeySlotKind,
        kdf: String,
        salt: String,
        iterations: Int,
        wrappedKey: String,
        credentialID: String? = nil
    ) {
        self.kind = kind
        self.kdf = kdf
        self.salt = salt
        self.iterations = iterations
        self.wrappedKey = wrappedKey
        self.credentialID = credentialID
    }
}

public struct ZeroKnowledgeBackupEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let currentEnvelopeVersion = 1
    public static let defaultPasswordIterations = 210_000
    public static let testingPasswordIterations = 8
    private static let supportedKeyDerivationFunction = "PBKDF2-HMAC-SHA256"
    private static let prfKeyDerivationFunction = "HKDF-SHA256"
    private static let prfHKDFInfo = Data("LavaSec passkey backup PRF v1".utf8)

    public let schemaVersion: Int
    public let envelopeVersion: Int
    public let cipher: String
    public let payloadCiphertext: String
    public let keySlots: [ZeroKnowledgeBackupKeySlot]
    public let serverRecoveryShare: String?
    public let ciphertextByteSize: Int
    public let createdAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        envelopeVersion: Int = currentEnvelopeVersion,
        cipher: String = "AES-256-GCM",
        payloadCiphertext: String,
        keySlots: [ZeroKnowledgeBackupKeySlot],
        serverRecoveryShare: String? = nil,
        ciphertextByteSize: Int,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.envelopeVersion = envelopeVersion
        self.cipher = cipher
        self.payloadCiphertext = payloadCiphertext
        self.keySlots = keySlots
        self.serverRecoveryShare = serverRecoveryShare
        self.ciphertextByteSize = ciphertextByteSize
        self.createdAt = createdAt
    }

    public static func estimatedByteSize(
        for payload: BackupConfigurationPayload,
        keySlotCount: Int
    ) throws -> Int {
        let encoder = makeJSONEncoder()
        let payloadSize = try encoder.encode(payload).count
        return payloadSize + 1_024 + max(0, keySlotCount) * 512
    }

    public static func make(
        payload: BackupConfigurationPayload,
        password: String,
        recoveryPhrase: String,
        passwordIterations: Int = defaultPasswordIterations
    ) throws -> ZeroKnowledgeBackupEnvelope {
        return try make(
            payload: payload,
            password: password,
            recoveryPhrase: recoveryPhrase,
            passwordIterations: passwordIterations,
            createdAt: Date()
        )
    }

    public static func makeForTesting(
        payload: BackupConfigurationPayload,
        password: String,
        recoveryPhrase: String
    ) throws -> ZeroKnowledgeBackupEnvelope {
        return try make(
            payload: payload,
            password: password,
            recoveryPhrase: recoveryPhrase,
            passwordIterations: testingPasswordIterations,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    public static func makePasswordless(
        payload: BackupConfigurationPayload,
        deviceSecret: String,
        serverRecoveryShare: String? = nil,
        recoveryPhrase: String,
        passkeySecret: String? = nil,
        passkeyCredentialID: String? = nil,
        passwordIterations: Int = defaultPasswordIterations
    ) throws -> ZeroKnowledgeBackupEnvelope {
        let effectiveServerRecoveryShare = try serverRecoveryShare ?? BackupAssistedRecoverySecret.makeServerShare()
        let assistedRecoverySecret = BackupAssistedRecoverySecret.combinedSecret(
            recoveryPhrase: recoveryPhrase,
            serverRecoveryShare: effectiveServerRecoveryShare
        )
        var slotSecrets: [(kind: ZeroKnowledgeBackupKeySlotKind, secret: String, salt: Data?, credentialID: String?)] = [
            (.keychain, deviceSecret, nil, nil)
        ]
        slotSecrets.append((.assistedRecovery, assistedRecoverySecret, nil, nil))
        if let passkeySecret, !passkeySecret.isEmpty {
            slotSecrets.append((.passkey, passkeySecret, nil, passkeyCredentialID))
        }

        return try make(
            payload: payload,
            slotSecrets: slotSecrets,
            passwordIterations: passwordIterations,
            serverRecoveryShare: effectiveServerRecoveryShare,
            createdAt: Date()
        )
    }

    public static func makePasswordlessForTesting(
        payload: BackupConfigurationPayload,
        deviceSecret: String,
        serverRecoveryShare: String? = nil,
        recoveryPhrase: String,
        passkeySecret: String? = nil,
        passkeyCredentialID: String? = nil
    ) throws -> ZeroKnowledgeBackupEnvelope {
        let effectiveServerRecoveryShare = try serverRecoveryShare ?? BackupAssistedRecoverySecret.makeServerShare()
        let assistedRecoverySecret = BackupAssistedRecoverySecret.combinedSecret(
            recoveryPhrase: recoveryPhrase,
            serverRecoveryShare: effectiveServerRecoveryShare
        )
        var slotSecrets: [(kind: ZeroKnowledgeBackupKeySlotKind, secret: String, salt: Data?, credentialID: String?)] = [
            (.keychain, deviceSecret, nil, nil)
        ]
        slotSecrets.append((.assistedRecovery, assistedRecoverySecret, nil, nil))
        if let passkeySecret, !passkeySecret.isEmpty {
            slotSecrets.append((.passkey, passkeySecret, nil, passkeyCredentialID))
        }

        return try make(
            payload: payload,
            slotSecrets: slotSecrets,
            passwordIterations: testingPasswordIterations,
            serverRecoveryShare: effectiveServerRecoveryShare,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// Build a passwordless envelope whose passkey slot is wrapped with an authenticator
    /// **PRF / `hmac-secret`** output (HKDF-derived), not a server-stored secret. The PRF output
    /// never leaves the client, so this passkey slot is genuinely zero-knowledge: no server-held
    /// value unwraps it. The `passkeyPRFSalt` is the non-secret PRF input persisted in the slot so
    /// restore can reproduce the same PRF output.
    public static func makeWithPRF(
        payload: BackupConfigurationPayload,
        deviceSecret: String,
        serverRecoveryShare: String? = nil,
        recoveryPhrase: String,
        passkeyPRFOutput: Data,
        passkeyPRFSalt: Data,
        passkeyCredentialID: String,
        passwordIterations: Int = defaultPasswordIterations,
        createdAt: Date = Date()
    ) throws -> ZeroKnowledgeBackupEnvelope {
        let effectiveServerRecoveryShare = try serverRecoveryShare ?? BackupAssistedRecoverySecret.makeServerShare()
        let assistedRecoverySecret = BackupAssistedRecoverySecret.combinedSecret(
            recoveryPhrase: recoveryPhrase,
            serverRecoveryShare: effectiveServerRecoveryShare
        )

        let payloadData = try makeJSONEncoder().encode(payload)
        let rawPayloadKey = try randomData(byteCount: 32)
        let payloadKey = SymmetricKey(data: rawPayloadKey)
        let sealedPayload = try AES.GCM.seal(payloadData, using: payloadKey)

        guard let payloadCiphertext = sealedPayload.combined else {
            throw ZeroKnowledgeBackupEnvelopeError.invalidCiphertext
        }

        let keySlots = [
            try makeKeySlot(
                kind: .keychain,
                secret: deviceSecret,
                rawPayloadKey: rawPayloadKey,
                iterations: passwordIterations
            ),
            try makeKeySlot(
                kind: .assistedRecovery,
                secret: assistedRecoverySecret,
                rawPayloadKey: rawPayloadKey,
                iterations: passwordIterations
            ),
            try makePRFKeySlot(
                rawPayloadKey: rawPayloadKey,
                prfOutput: passkeyPRFOutput,
                salt: passkeyPRFSalt,
                credentialID: passkeyCredentialID
            )
        ]

        return ZeroKnowledgeBackupEnvelope(
            payloadCiphertext: payloadCiphertext.base64EncodedString(),
            keySlots: keySlots,
            serverRecoveryShare: effectiveServerRecoveryShare,
            ciphertextByteSize: payloadCiphertext.count,
            createdAt: createdAt
        )
    }

    public static func makeWithPRFForTesting(
        payload: BackupConfigurationPayload,
        deviceSecret: String,
        serverRecoveryShare: String? = nil,
        recoveryPhrase: String,
        passkeyPRFOutput: Data,
        passkeyPRFSalt: Data,
        passkeyCredentialID: String
    ) throws -> ZeroKnowledgeBackupEnvelope {
        try makeWithPRF(
            payload: payload,
            deviceSecret: deviceSecret,
            serverRecoveryShare: serverRecoveryShare,
            recoveryPhrase: recoveryPhrase,
            passkeyPRFOutput: passkeyPRFOutput,
            passkeyPRFSalt: passkeyPRFSalt,
            passkeyCredentialID: passkeyCredentialID,
            passwordIterations: testingPasswordIterations,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    public func decryptWithPassword(_ password: String) throws -> BackupConfigurationPayload {
        try decrypt(using: password, slotKind: .password)
    }

    public func decryptWithKeychainSecret(_ secret: String) throws -> BackupConfigurationPayload {
        try decrypt(using: secret, slotKind: .keychain)
    }

    public func decryptWithRecoveryPhrase(_ phrase: String) throws -> BackupConfigurationPayload {
        try decrypt(using: phrase, slotKind: .recoveryPhrase)
    }

    public func decryptWithAssistedRecoveryPhrase(_ phrase: String) throws -> BackupConfigurationPayload {
        guard let serverRecoveryShare, !serverRecoveryShare.isEmpty else {
            throw ZeroKnowledgeBackupEnvelopeError.missingServerRecoveryShare
        }

        let assistedRecoverySecret = BackupAssistedRecoverySecret.combinedSecret(
            recoveryPhrase: phrase,
            serverRecoveryShare: serverRecoveryShare
        )
        return try decrypt(using: assistedRecoverySecret, slotKind: .assistedRecovery)
    }

    public func decryptWithPasskeySecret(_ secret: String) throws -> BackupConfigurationPayload {
        try decrypt(using: secret, slotKind: .passkey)
    }

    /// Decrypt the PRF-derived passkey slot using the authenticator's PRF output. The slot's stored
    /// salt is the PRF input; the caller obtains `prfOutput` from a passkey assertion with that
    /// salt. No server-held value participates.
    public func decryptWithPasskeyPRFOutput(_ prfOutput: Data) throws -> BackupConfigurationPayload {
        guard envelopeVersion == Self.currentEnvelopeVersion else {
            throw ZeroKnowledgeBackupEnvelopeError.unsupportedEnvelopeVersion(envelopeVersion)
        }

        guard let slot = keySlots.first(where: { $0.kind == .passkey }) else {
            throw ZeroKnowledgeBackupEnvelopeError.missingKeySlot
        }

        guard slot.kdf == Self.prfKeyDerivationFunction else {
            throw ZeroKnowledgeBackupEnvelopeError.unsupportedKeyDerivationFunction(slot.kdf)
        }

        let salt = try decodeBase64(slot.salt)
        let wrappedPayloadKey = try decodeBase64(slot.wrappedKey)
        let wrappingKey = Self.derivePRFKey(prfOutput: prfOutput, salt: salt)
        let wrappedKeyBox = try AES.GCM.SealedBox(combined: wrappedPayloadKey)
        let rawPayloadKey = try AES.GCM.open(wrappedKeyBox, using: wrappingKey)
        let payloadKey = SymmetricKey(data: rawPayloadKey)
        let payloadCiphertextData = try decodeBase64(payloadCiphertext)
        let payloadBox = try AES.GCM.SealedBox(combined: payloadCiphertextData)
        let payloadData = try AES.GCM.open(payloadBox, using: payloadKey)

        return try Self.makeJSONDecoder().decode(BackupConfigurationPayload.self, from: payloadData)
    }

    private static func make(
        payload: BackupConfigurationPayload,
        password: String,
        recoveryPhrase: String,
        passwordIterations: Int,
        createdAt: Date
    ) throws -> ZeroKnowledgeBackupEnvelope {
        try make(
            payload: payload,
            slotSecrets: [
                (.password, password, nil, nil),
                (.recoveryPhrase, recoveryPhrase, nil, nil)
            ],
            passwordIterations: passwordIterations,
            serverRecoveryShare: nil,
            createdAt: createdAt
        )
    }

    private static func make(
        payload: BackupConfigurationPayload,
        slotSecrets: [(kind: ZeroKnowledgeBackupKeySlotKind, secret: String, salt: Data?, credentialID: String?)],
        passwordIterations: Int,
        serverRecoveryShare: String?,
        createdAt: Date
    ) throws -> ZeroKnowledgeBackupEnvelope {
        let payloadData = try makeJSONEncoder().encode(payload)
        let rawPayloadKey = try randomData(byteCount: 32)
        let payloadKey = SymmetricKey(data: rawPayloadKey)
        let sealedPayload = try AES.GCM.seal(payloadData, using: payloadKey)

        guard let payloadCiphertext = sealedPayload.combined else {
            throw ZeroKnowledgeBackupEnvelopeError.invalidCiphertext
        }

        let keySlots = try slotSecrets.map { slot in
            try makeKeySlot(
                kind: slot.kind,
                secret: slot.secret,
                rawPayloadKey: rawPayloadKey,
                salt: slot.salt,
                credentialID: slot.credentialID,
                iterations: passwordIterations
            )
        }

        return ZeroKnowledgeBackupEnvelope(
            payloadCiphertext: payloadCiphertext.base64EncodedString(),
            keySlots: keySlots,
            serverRecoveryShare: serverRecoveryShare,
            ciphertextByteSize: payloadCiphertext.count,
            createdAt: createdAt
        )
    }

    private static func makeKeySlot(
        kind: ZeroKnowledgeBackupKeySlotKind,
        secret: String,
        rawPayloadKey: Data,
        salt providedSalt: Data? = nil,
        credentialID: String? = nil,
        iterations: Int
    ) throws -> ZeroKnowledgeBackupKeySlot {
        let salt = try providedSalt ?? randomData(byteCount: 16)
        let wrappingKey = try deriveKey(secret: secret, salt: salt, iterations: iterations)
        let sealedKey = try AES.GCM.seal(rawPayloadKey, using: wrappingKey)

        guard let wrappedKey = sealedKey.combined else {
            throw ZeroKnowledgeBackupEnvelopeError.invalidCiphertext
        }

        return ZeroKnowledgeBackupKeySlot(
            kind: kind,
            kdf: supportedKeyDerivationFunction,
            salt: salt.base64EncodedString(),
            iterations: iterations,
            wrappedKey: wrappedKey.base64EncodedString(),
            credentialID: credentialID
        )
    }

    private static func makePRFKeySlot(
        rawPayloadKey: Data,
        prfOutput: Data,
        salt: Data,
        credentialID: String
    ) throws -> ZeroKnowledgeBackupKeySlot {
        let wrappingKey = derivePRFKey(prfOutput: prfOutput, salt: salt)
        let sealedKey = try AES.GCM.seal(rawPayloadKey, using: wrappingKey)

        guard let wrappedKey = sealedKey.combined else {
            throw ZeroKnowledgeBackupEnvelopeError.invalidCiphertext
        }

        return ZeroKnowledgeBackupKeySlot(
            kind: .passkey,
            kdf: prfKeyDerivationFunction,
            salt: salt.base64EncodedString(),
            iterations: 0,
            wrappedKey: wrappedKey.base64EncodedString(),
            credentialID: credentialID
        )
    }

    private static func derivePRFKey(prfOutput: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: prfOutput),
            salt: salt,
            info: prfHKDFInfo,
            outputByteCount: 32
        )
    }

    private func decrypt(
        using secret: String,
        slotKind: ZeroKnowledgeBackupKeySlotKind
    ) throws -> BackupConfigurationPayload {
        let payloadKey = SymmetricKey(data: try recoverRawPayloadKey(secret: secret, slotKind: slotKind))
        let payloadCiphertextData = try decodeBase64(payloadCiphertext)
        let payloadBox = try AES.GCM.SealedBox(combined: payloadCiphertextData)
        let payloadData = try AES.GCM.open(payloadBox, using: payloadKey)

        return try Self.makeJSONDecoder().decode(BackupConfigurationPayload.self, from: payloadData)
    }

    /// Recover the shared raw payload key by unwrapping it with the given slot's secret.
    private func recoverRawPayloadKey(
        secret: String,
        slotKind: ZeroKnowledgeBackupKeySlotKind
    ) throws -> Data {
        guard envelopeVersion == Self.currentEnvelopeVersion else {
            throw ZeroKnowledgeBackupEnvelopeError.unsupportedEnvelopeVersion(envelopeVersion)
        }

        guard let slot = keySlots.first(where: { $0.kind == slotKind }) else {
            throw ZeroKnowledgeBackupEnvelopeError.missingKeySlot
        }

        guard slot.kdf == Self.supportedKeyDerivationFunction else {
            throw ZeroKnowledgeBackupEnvelopeError.unsupportedKeyDerivationFunction(slot.kdf)
        }

        let salt = try decodeBase64(slot.salt)
        let wrappedPayloadKey = try decodeBase64(slot.wrappedKey)
        let wrappingKey = try Self.deriveKey(
            secret: secret,
            salt: salt,
            iterations: slot.iterations
        )
        let wrappedKeyBox = try AES.GCM.SealedBox(combined: wrappedPayloadKey)
        return try AES.GCM.open(wrappedKeyBox, using: wrappingKey)
    }

    /// Re-encrypt the envelope's payload with an updated `BackupConfigurationPayload`,
    /// keeping every existing key slot intact. The shared payload key is recovered from the
    /// device-secret (`.keychain`) slot — the only secret available without user
    /// interaction — and the new payload is re-sealed under it. Because the key slots are
    /// unchanged, every existing unlock path (recovery phrase, passkey, assisted recovery)
    /// still works. This lets a backup reflect post-turn-on config/library changes without a
    /// full re-enrollment (the envelope is otherwise only built at turn-on/restore).
    public func resealingPayload(
        _ newPayload: BackupConfigurationPayload,
        deviceSecret: String
    ) throws -> ZeroKnowledgeBackupEnvelope {
        let rawPayloadKey = try recoverRawPayloadKey(secret: deviceSecret, slotKind: .keychain)
        let payloadKey = SymmetricKey(data: rawPayloadKey)
        let payloadData = try Self.makeJSONEncoder().encode(newPayload)
        let sealedPayload = try AES.GCM.seal(payloadData, using: payloadKey)

        guard let payloadCiphertext = sealedPayload.combined else {
            throw ZeroKnowledgeBackupEnvelopeError.invalidCiphertext
        }

        return ZeroKnowledgeBackupEnvelope(
            schemaVersion: schemaVersion,
            envelopeVersion: envelopeVersion,
            cipher: cipher,
            payloadCiphertext: payloadCiphertext.base64EncodedString(),
            keySlots: keySlots,
            serverRecoveryShare: serverRecoveryShare,
            ciphertextByteSize: payloadCiphertext.count,
            createdAt: createdAt
        )
    }

    /// Replace the device-secret (`.keychain`) slot with one wrapped under a NEW device
    /// secret, recovering the shared payload key via the assisted-recovery phrase. Used on a
    /// recovery-phrase restore to a NEW device (which has no pre-existing device secret) so
    /// the restoring device can later re-seal updates with its own device secret. The payload
    /// and every other key slot are unchanged, so all unlock paths keep working.
    public func rekeyingDeviceSlot(
        newDeviceSecret: String,
        unlockingAssistedRecoveryPhrase phrase: String
    ) throws -> ZeroKnowledgeBackupEnvelope {
        guard let serverRecoveryShare, !serverRecoveryShare.isEmpty else {
            throw ZeroKnowledgeBackupEnvelopeError.missingServerRecoveryShare
        }
        let assistedRecoverySecret = BackupAssistedRecoverySecret.combinedSecret(
            recoveryPhrase: phrase,
            serverRecoveryShare: serverRecoveryShare
        )
        let rawPayloadKey = try recoverRawPayloadKey(secret: assistedRecoverySecret, slotKind: .assistedRecovery)
        return try rekeyedDeviceSlot(rawPayloadKey: rawPayloadKey, newDeviceSecret: newDeviceSecret)
    }

    /// Re-key the device slot via a password-style `.recoveryPhrase` slot (older envelopes).
    public func rekeyingDeviceSlot(
        newDeviceSecret: String,
        unlockingRecoveryPhrase phrase: String
    ) throws -> ZeroKnowledgeBackupEnvelope {
        let rawPayloadKey = try recoverRawPayloadKey(secret: phrase, slotKind: .recoveryPhrase)
        return try rekeyedDeviceSlot(rawPayloadKey: rawPayloadKey, newDeviceSecret: newDeviceSecret)
    }

    /// Re-key the device slot via the passkey PRF output (passkey restore to a new device).
    public func rekeyingDeviceSlot(
        newDeviceSecret: String,
        unlockingPasskeyPRFOutput prfOutput: Data
    ) throws -> ZeroKnowledgeBackupEnvelope {
        guard envelopeVersion == Self.currentEnvelopeVersion else {
            throw ZeroKnowledgeBackupEnvelopeError.unsupportedEnvelopeVersion(envelopeVersion)
        }
        guard let slot = keySlots.first(where: { $0.kind == .passkey }) else {
            throw ZeroKnowledgeBackupEnvelopeError.missingKeySlot
        }
        guard slot.kdf == Self.prfKeyDerivationFunction else {
            throw ZeroKnowledgeBackupEnvelopeError.unsupportedKeyDerivationFunction(slot.kdf)
        }
        let salt = try decodeBase64(slot.salt)
        let wrappedPayloadKey = try decodeBase64(slot.wrappedKey)
        let wrappingKey = Self.derivePRFKey(prfOutput: prfOutput, salt: salt)
        let wrappedKeyBox = try AES.GCM.SealedBox(combined: wrappedPayloadKey)
        let rawPayloadKey = try AES.GCM.open(wrappedKeyBox, using: wrappingKey)
        return try rekeyedDeviceSlot(rawPayloadKey: rawPayloadKey, newDeviceSecret: newDeviceSecret)
    }

    private func rekeyedDeviceSlot(
        rawPayloadKey: Data,
        newDeviceSecret: String
    ) throws -> ZeroKnowledgeBackupEnvelope {
        // Preserve the existing keychain slot's iteration count (so testing/production
        // costs are unchanged); fall back to the production default if there's no keychain slot.
        let iterations = keySlots.first(where: { $0.kind == .keychain })?.iterations
            ?? Self.defaultPasswordIterations
        let newKeychainSlot = try Self.makeKeySlot(
            kind: .keychain,
            secret: newDeviceSecret,
            rawPayloadKey: rawPayloadKey,
            iterations: iterations
        )
        var slots = keySlots.filter { $0.kind != .keychain }
        slots.insert(newKeychainSlot, at: 0)
        return ZeroKnowledgeBackupEnvelope(
            schemaVersion: schemaVersion,
            envelopeVersion: envelopeVersion,
            cipher: cipher,
            payloadCiphertext: payloadCiphertext,
            keySlots: slots,
            serverRecoveryShare: serverRecoveryShare,
            ciphertextByteSize: ciphertextByteSize,
            createdAt: createdAt
        )
    }

    private static func deriveKey(secret: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let outputByteCount = 32
        var derivedBytes = [UInt8](repeating: 0, count: outputByteCount)
        let passwordData = Data(secret.utf8)
        guard let rounds = UInt32(exactly: iterations), rounds > 0 else {
            throw ZeroKnowledgeBackupEnvelopeError.keyDerivationFailed(Int32(kCCParamError))
        }

        let status = passwordData.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                derivedBytes.withUnsafeMutableBufferPointer { derivedBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        rounds,
                        derivedBuffer.baseAddress,
                        outputByteCount
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw ZeroKnowledgeBackupEnvelopeError.keyDerivationFailed(status)
        }

        return SymmetricKey(data: derivedBytes)
    }

    private static func randomData(byteCount: Int) throws -> Data {
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, bytes.baseAddress!)
        }

        guard status == errSecSuccess else {
            throw ZeroKnowledgeBackupEnvelopeError.randomBytesFailed(status)
        }

        return data
    }

    private func decodeBase64(_ value: String) throws -> Data {
        guard let data = Data(base64Encoded: value) else {
            throw ZeroKnowledgeBackupEnvelopeError.invalidBase64
        }

        return data
    }

    private static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeJSONDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}
