import XCTest
@testable import LavaSecCore
@testable import LavaSecAppServices
@testable import LavaSecKit

/// Behavioural harness for the recovery-phrase unlock precedence that the restore path
/// delegates to (`ZeroKnowledgeBackupEnvelope.decryptWithNormalizedRecoveryPhrase` /
/// `rekeyingDeviceSlotWithNormalizedRecoveryPhrase`, extracted from AppViewModel in the
/// Phase D1 backup peel). Executes the candidate ordering (normalized → raw trimmed →
/// uppercased), the assisted-recovery-then-legacy slot fallback, and the PST-5 rule that a
/// newer-schema payload error is rethrown immediately instead of being masked by a later
/// candidate's crypto failure.
final class BackupRecoveryPhraseUnlockTests: XCTestCase {
    private let sealedPhrase = "ember vault canyon ribbon orbit cedar window quiet"

    private func makePayload(
        blocked: Set<String> = ["casino.example"]
    ) -> BackupConfigurationPayload {
        BackupConfigurationPayload(
            configuration: AppConfiguration(
                blockedDomains: blocked,
                keepDomainDiagnostics: true
            )
        )
    }

    private func makePasswordlessEnvelope(
        payload: BackupConfigurationPayload? = nil,
        deviceSecret: String = "device-secret-old",
        recoveryPhrase: String? = nil
    ) throws -> ZeroKnowledgeBackupEnvelope {
        try ZeroKnowledgeBackupEnvelope.makePasswordlessForTesting(
            payload: payload ?? makePayload(),
            deviceSecret: deviceSecret,
            recoveryPhrase: recoveryPhrase ?? sealedPhrase
        )
    }

    // MARK: - Candidate normalization

    func testNormalizedCandidateUnlocksMessyUserInput() throws {
        let payload = makePayload()
        let envelope = try makePasswordlessEnvelope(payload: payload)

        // Numbered, mixed-case, mixed-separator paste — words(from:)/phrase(from:)
        // normalization must reduce it to the sealed phrase.
        let messyInput = "1. Ember 2) VAULT\ncanyon, ribbon; orbit - cedar\twindow  quiet"

        XCTAssertEqual(try envelope.decryptWithNormalizedRecoveryPhrase(messyInput), payload)
    }

    func testRawTrimmedInputFallsBackWhenSealedPhraseWasNotNormalized() throws {
        // An envelope sealed with a NON-normalized phrase (mixed case): the normalized
        // candidate misses, the raw trimmed input must still unlock it.
        let payload = makePayload()
        let envelope = try makePasswordlessEnvelope(payload: payload, recoveryPhrase: "Ember Vault Canyon")

        XCTAssertEqual(
            try envelope.decryptWithNormalizedRecoveryPhrase("  Ember Vault Canyon  "),
            payload
        )
    }

    func testUppercasedInputFallsBackForUppercaseSealedPhrase() throws {
        let payload = makePayload()
        let envelope = try makePasswordlessEnvelope(payload: payload, recoveryPhrase: "EMBER VAULT CANYON")

        // Normalized and raw-trimmed candidates are both lowercase and miss; the
        // uppercased candidate must unlock.
        XCTAssertEqual(
            try envelope.decryptWithNormalizedRecoveryPhrase("ember vault canyon"),
            payload
        )
    }

    func testWrongPhraseThrowsAnUnlockError() throws {
        let envelope = try makePasswordlessEnvelope()

        XCTAssertThrowsError(
            try envelope.decryptWithNormalizedRecoveryPhrase("wrong phrase entirely")
        ) { error in
            XCTAssertFalse(
                error is BackupConfigurationPayloadError,
                "A failed unlock must surface a crypto/slot error, never a payload-schema error."
            )
        }
    }

    // MARK: - Slot precedence

    func testLegacyPasswordStyleRecoverySlotIsTriedAfterAssistedRecovery() throws {
        // A legacy envelope has password + password-style recovery slots and NO server
        // recovery share, so the assisted-recovery attempt throws and the loop must fall
        // through to the legacy `.recoveryPhrase` slot for the same candidate.
        let payload = makePayload()
        let envelope = try ZeroKnowledgeBackupEnvelope.makeForTesting(
            payload: payload,
            password: "lava2026!",
            recoveryPhrase: sealedPhrase
        )

        XCTAssertEqual(
            try envelope.decryptWithNormalizedRecoveryPhrase("EMBER vault canyon ribbon orbit cedar window quiet"),
            payload
        )
    }

    // MARK: - PST-5: newer-schema payloads

    func testNewerSchemaPayloadRethrowsImmediatelyInsteadOfMaskingAsBadPhrase() throws {
        // Seal a payload one schema ahead of what this build decodes. The FIRST (normalized)
        // candidate is correct and unwraps the envelope, but the payload decode throws
        // `unsupportedSchemaVersion`. The later candidates (raw/uppercased) are wrong and
        // would throw crypto errors — if the loop kept going, `lastError` would mislabel
        // this as a bad phrase (PST-5, Codex #218). The schema error must win.
        let futurePayload = BackupConfigurationPayload(
            schemaVersion: BackupConfigurationPayload.currentSupportedSchemaVersion + 1,
            enabledBlocklistIDs: [],
            allowedDomains: [],
            blockedDomains: ["casino.example"],
            resolverPresetID: DNSResolverPreset.cloudflareDoH.id,
            keepDomainDiagnostics: true,
            protectionEnabledHint: true
        )
        let envelope = try makePasswordlessEnvelope(payload: futurePayload)

        // Mixed-case input: the normalized candidate matches the sealed phrase; the raw and
        // uppercased fallbacks do not, so they would fail with masking crypto errors.
        XCTAssertThrowsError(
            try envelope.decryptWithNormalizedRecoveryPhrase("Ember Vault Canyon Ribbon Orbit Cedar Window Quiet")
        ) { error in
            XCTAssertEqual(
                error as? BackupConfigurationPayloadError,
                .unsupportedSchemaVersion(BackupConfigurationPayload.currentSupportedSchemaVersion + 1)
            )
        }
    }

    // MARK: - Device-slot rekey

    func testRekeyedDeviceSlotUnlocksWithTheNewDeviceSecretOnly() throws {
        let payload = makePayload()
        let envelope = try makePasswordlessEnvelope(payload: payload, deviceSecret: "device-secret-old")

        let rekeyed = try XCTUnwrap(
            envelope.rekeyingDeviceSlotWithNormalizedRecoveryPhrase(
                "EMBER vault canyon ribbon orbit cedar window quiet",
                newDeviceSecret: "device-secret-new"
            )
        )

        XCTAssertEqual(try rekeyed.decryptWithKeychainSecret("device-secret-new"), payload)
        XCTAssertThrowsError(try rekeyed.decryptWithKeychainSecret("device-secret-old"))
        // Every other unlock path keeps working after the rekey.
        XCTAssertEqual(try rekeyed.decryptWithNormalizedRecoveryPhrase(sealedPhrase), payload)
    }

    func testRekeyFallsBackToLegacyRecoverySlot() throws {
        // Legacy envelope: no assisted-recovery slot (and no keychain slot at all) — the
        // rekey must recover the payload key via the password-style `.recoveryPhrase` slot
        // and INSTALL a working keychain slot.
        let payload = makePayload()
        let envelope = try ZeroKnowledgeBackupEnvelope.makeForTesting(
            payload: payload,
            password: "lava2026!",
            recoveryPhrase: sealedPhrase
        )

        let rekeyed = try XCTUnwrap(
            envelope.rekeyingDeviceSlotWithNormalizedRecoveryPhrase(
                sealedPhrase,
                newDeviceSecret: "device-secret-new"
            )
        )

        XCTAssertEqual(try rekeyed.decryptWithKeychainSecret("device-secret-new"), payload)
    }

    func testRekeyReturnsNilForWrongPhrase() throws {
        let envelope = try makePasswordlessEnvelope()

        XCTAssertNil(
            envelope.rekeyingDeviceSlotWithNormalizedRecoveryPhrase(
                "wrong phrase entirely",
                newDeviceSecret: "device-secret-new"
            )
        )
    }
}
