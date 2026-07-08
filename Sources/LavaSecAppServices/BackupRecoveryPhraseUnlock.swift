import Foundation

// Recovery-phrase unlock: candidate normalization + slot precedence, extracted from the
// app's restore path (Phase D1, lavasec-infra
// plans/2026-07-07-ios-modularization-scaffolding-plan.md) so the candidate ordering and
// the PST-5 schema-error rethrow are executable (BackupRecoveryPhraseUnlockTests) instead
// of source-pinned.
extension ZeroKnowledgeBackupEnvelope {
    /// Candidate secrets tried, in order, for a user-entered recovery phrase: the
    /// normalized phrase (lowercased words, separators/numbering collapsed — the form
    /// setup seals), then the raw trimmed input, then the uppercased input (legacy
    /// fallbacks for envelopes sealed before normalization). Empty candidates are dropped.
    private static func recoveryPhraseCandidates(for secret: String) -> [String] {
        let normalizedPhrase = BackupRecoveryPhrase.phrase(
            from: BackupRecoveryPhrase.words(from: secret)
        )
        return [
            normalizedPhrase,
            secret.trimmingCharacters(in: .whitespacesAndNewlines),
            secret.uppercased()
        ].filter { !$0.isEmpty }
    }

    /// Decrypt the payload with a user-entered recovery phrase, trying each normalized
    /// candidate against BOTH recovery slots: the assisted-recovery slot (phrase + server
    /// share) first, then the legacy password-style recovery slot. Throws the last unlock
    /// error when no candidate works.
    ///
    /// PST-5 (Codex #218): reaching the payload decode means a candidate DID unwrap the
    /// envelope — the phrase is correct, the payload schema is just newer than this build
    /// supports. `BackupConfigurationPayloadError` is rethrown immediately so a later wrong
    /// candidate's crypto error can't overwrite it and mislabel the failure as a bad phrase.
    /// pinned: BackupRecoveryPhraseUnlockTests.testNewerSchemaPayloadRethrowsImmediatelyInsteadOfMaskingAsBadPhrase
    public func decryptWithNormalizedRecoveryPhrase(_ secret: String) throws -> BackupConfigurationPayload {
        var lastError: Error = ZeroKnowledgeBackupEnvelopeError.missingKeySlot
        for candidate in Self.recoveryPhraseCandidates(for: secret) {
            do {
                return try decryptWithAssistedRecoveryPhrase(candidate)
            } catch let error as BackupConfigurationPayloadError {
                throw error
            } catch {
                lastError = error
            }

            do {
                return try decryptWithRecoveryPhrase(candidate)
            } catch let error as BackupConfigurationPayloadError {
                throw error
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    /// Re-key the envelope's device (`.keychain`) slot with a fresh device secret,
    /// recovering the payload key via the recovery phrase — trying the same normalized
    /// candidates as `decryptWithNormalizedRecoveryPhrase(_:)`, and both the
    /// assisted-recovery and password-style recovery slots. Returns the re-keyed
    /// envelope, or `nil` if no candidate worked.
    public func rekeyingDeviceSlotWithNormalizedRecoveryPhrase(
        _ secret: String,
        newDeviceSecret: String
    ) -> ZeroKnowledgeBackupEnvelope? {
        for candidate in Self.recoveryPhraseCandidates(for: secret) {
            if let rekeyed = try? rekeyingDeviceSlot(
                newDeviceSecret: newDeviceSecret, unlockingAssistedRecoveryPhrase: candidate
            ) {
                return rekeyed
            }
            if let rekeyed = try? rekeyingDeviceSlot(
                newDeviceSecret: newDeviceSecret, unlockingRecoveryPhrase: candidate
            ) {
                return rekeyed
            }
        }
        return nil
    }
}
