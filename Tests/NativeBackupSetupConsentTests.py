#!/usr/bin/env python3
"""Exercise the native setup's actual mode/phrase/consent transitions without UIKit.

Pass --setup-source PATH to replay a retained pre-fix source snapshot. Passkey
ceremonies and phrase generation are deterministic doubles; navigation and the
consent gates use the unmodified production methods.
"""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--setup-source', type=Path, default=root / 'LavaSecApp/BackupSetupView.swift')
args = parser.parse_args()
source = args.setup_source.read_text()

def declaration(text, marker):
    start = text.index(marker)
    cursor = text.index('{', start) + 1
    depth = 1
    while depth:
        if text[cursor] == '{': depth += 1
        elif text[cursor] == '}': depth -= 1
        cursor += 1
    return text[start:cursor]

methods = '\n'.join(declaration(source, marker).replace('private ', '', 1) for marker in [
    'private var canAdvance:', 'private func beginSetup(', 'private func validatePasskey()',
    'private func cancelPasskeyValidation()', 'private func ensureRecoveryPhrase()',
])
mode = declaration((root / 'LavaSecApp/BackupPasskeyCoordinator.swift').read_text(), 'enum BackupSetupPasskeyMode:')
consent = (root / 'Sources/LavaSecAppServices/BackupSetupConsent.swift').read_text()
stubs = r'''
enum BackupSetupStep { case overview, validatePasskey, recoveryPhrase, upload, complete }
@MainActor enum BackupRecoveryPhrase {
    static var sequence = 0
    static func generate() throws -> String { sequence += 1; return "synthetic phrase \(sequence)" }
}
enum FixtureError: Error { case registrationCancelled }
@MainActor final class BackupDouble {
    var failsRegistration = false
    func clearPendingBackupPasskey() {}
    func registerBackupPasskey() async throws {
        if failsRegistration { throw FixtureError.registrationCancelled }
    }
    func validateBackupPasskey() async throws {}
}
@MainActor final class Subject {
    var step = BackupSetupStep.overview
    var selectedPasskeyMode: BackupSetupPasskeyMode?
    var recoveryPhrase = ""
    var consent = BackupSetupConsent()
    var isPreparingPasskey = false
    var isValidatingPasskey = false
    var errorMessage: String?
    let backup = BackupDouble()
    func go(to step: BackupSetupStep) { self.step = step }
'''
tests = r'''
}
@main struct Main {
    @MainActor static func settle(_ subject: Subject) async {
        while subject.isPreparingPasskey || subject.isValidatingPasskey { await Task.yield() }
    }
    @MainActor static func acceptedPasskeyAttempt() async -> Subject {
        let subject = Subject()
        subject.ensureRecoveryPhrase()
        subject.beginSetup(with: .withPasskey)
        await settle(subject)
        subject.validatePasskey()
        await settle(subject)
        precondition(subject.step == .recoveryPhrase)
        subject.consent.savedRecoveryPhrase = true
        subject.consent.understandsNoRecovery = true
        precondition(subject.canAdvance && !subject.consent.copiedRecoveryPhrase,
                     "Both acknowledgments must allow setup without copying")
        return subject
    }
    @MainActor static func verifyNewAttempt(_ subject: Subject, oldPhrase: String, oldID: UUID) {
        precondition(subject.step == .recoveryPhrase)
        precondition(subject.recoveryPhrase != oldPhrase && !subject.recoveryPhrase.isEmpty,
                     "A changed or unknown setup method must generate a new phrase")
        precondition(subject.consent.attemptID != oldID && !subject.consent.copiedRecoveryPhrase,
                     "A new attempt clears the optional copy state")
        precondition(!subject.consent.savedRecoveryPhrase && !subject.consent.understandsNoRecovery)
        precondition(!subject.canAdvance, "A new attempt requires both acknowledgments again")
    }
    @MainActor static func main() async {
        do {
            let subject = await acceptedPasskeyAttempt()
            let oldPhrase = subject.recoveryPhrase
            let oldID = subject.consent.attemptID
            subject.consent.recordCopy()
            precondition(subject.canAdvance, "Optional copy must preserve the acknowledgments")
            subject.step = .overview // Recovery's ordinary Back retains this attempt.
            subject.beginSetup(with: .withPasskey)
            await settle(subject)
            subject.cancelPasskeyValidation()
            precondition(subject.selectedPasskeyMode == nil)
            subject.beginSetup(with: .withoutPasskey)
            verifyNewAttempt(subject, oldPhrase: oldPhrase, oldID: oldID)
        }
        do {
            let subject = await acceptedPasskeyAttempt()
            let oldPhrase = subject.recoveryPhrase
            let oldID = subject.consent.attemptID
            subject.step = .overview
            subject.backup.failsRegistration = true
            subject.beginSetup(with: .withPasskey)
            await settle(subject)
            precondition(subject.selectedPasskeyMode == nil)
            subject.beginSetup(with: .withoutPasskey)
            verifyNewAttempt(subject, oldPhrase: oldPhrase, oldID: oldID)
        }
        do {
            let subject = await acceptedPasskeyAttempt()
            let oldPhrase = subject.recoveryPhrase
            let oldConsent = subject.consent
            subject.step = .overview
            subject.beginSetup(with: .withPasskey)
            await settle(subject)
            subject.validatePasskey()
            await settle(subject)
            precondition(subject.recoveryPhrase == oldPhrase && subject.consent == oldConsent)
            precondition(subject.canAdvance, "Ordinary Back within the same attempt preserves explicit consent")
        }
        do {
            let subject = await acceptedPasskeyAttempt()
            let oldPhrase = subject.recoveryPhrase
            let oldID = subject.consent.attemptID
            subject.step = .overview
            subject.beginSetup(with: .withoutPasskey)
            verifyNewAttempt(subject, oldPhrase: oldPhrase, oldID: oldID)
        }
        print("PASS: 4 production setup-mode/phrase/consent transitions (cancel, registration failure, same-attempt Back, changed method)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='lava-backup-consent-') as directory:
    path = Path(directory)
    swift = path / 'Consent.swift'
    swift.write_text(consent + mode + stubs + methods + tests)
    env = os.environ.copy()
    env['CLANG_MODULE_CACHE_PATH'] = '/tmp/lava-backup-consent-clang'
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6', '-warnings-as-errors', str(swift), '-o', str(path / 'tests')], check=True, env=env)
    subprocess.run([str(path / 'tests')], check=True, env=env)
