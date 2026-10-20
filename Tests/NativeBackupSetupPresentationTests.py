#!/usr/bin/env python3
"""Run production setup presentation transitions with isolated upload/feedback I/O."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'LavaSecApp/BackupSetupView.swift').read_text()

def body(marker):
    start = source.index('    ' + marker)
    pos = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[pos] == '{') - (source[pos] == '}')
        pos += 1
    return source[start:pos].replace('private ', '', 1)

methods = '\n'.join(body(marker) for marker in [
    'var busy:', 'var canClose:', 'var blocksInteractiveDismiss:', 'var canAdvance:', 'var canCopyPhrase:', 'var isUploadingSetup:', 'var canRetryUpload:',
    'func copyPhrase()', 'func advance()', 'func retryUpload()', 'private func updateUploadProgress()',
])
consent = (root / 'Sources/LavaSecAppServices/BackupSetupConsent.swift').read_text()
swift = r'''
import Foundation
struct UTType { let identifier: String; static let plainText = UTType(identifier: "public.plain-text") }
@MainActor final class UIPasteboard {
    enum OptionsKey { case localOnly, expirationDate }
    static let general = UIPasteboard()
    var writes = 0
    func setItems(_ items: [[String: Any]], options: [OptionsKey: Any]) { writes += 1 }
}
enum ProtectionHapticFeedback { case selectionConfirmed; static func play(_ value: Self) {} }
struct Progress { enum State: Equatable { case pending, uploading, failed, complete, unavailable }; let id: UUID; var state: State }
enum BackupSetupStep { case recoveryPhrase, upload, validatePasskey }
enum BackupSetupPasskeyMode { case withoutPasskey }
enum BackupPasskeyError: Error { case canceled }
extension String { var lavaLocalized: String { self } }
@MainActor enum LavaAccessibilityAnnouncer { static var count = 0; static func announce(_ value: String) { count += 1 } }
@MainActor enum LavaFeedbackCoordinator {
    static var shared = LavaFeedbackCoordinatorState()
}
@MainActor struct LavaFeedbackCoordinatorState {
    enum Outcome { case failed, succeeded }
    func begin(_ value: String) -> UUID { UUID() }
    func finish(_ value: String, _ id: UUID, _ outcome: Outcome, cancelled: Bool = false) {}
}
@MainActor final class UploadDouble {
    var setupUploadProgress: Progress?
    var starts = 0; var retries = 0
    func turnOnEncryptedBackup(recoveryPhrase: String) async throws {
        starts += 1; setupUploadProgress = Progress(id: UUID(), state: .uploading)
    }
    func retrySetupUpload(attemptID: UUID) async {
        retries += 1; setupUploadProgress?.state = .uploading
    }
    func isSetupUploadConfirmed(attemptID: UUID) -> Bool {
        setupUploadProgress?.id == attemptID && setupUploadProgress?.state == .complete
    }
}
@MainActor final class Subject {
    var step = BackupSetupStep.recoveryPhrase
    var selectedPasskeyMode: BackupSetupPasskeyMode? = .withoutPasskey
    var recoveryPhrase = "synthetic recovery phrase"
    var consent = BackupSetupConsent()
    var isPreparingPasskey = false; var isValidatingPasskey = false; var isFinishingSetup = false
    var retired = false; var current = true; var setupComplete = false
    var errorMessage: String?; var setupAttemptID: UUID?; var setupFeedbackID: UUID?
    var task: Task<Void, Never>?
    let backup = UploadDouble()
    func isCurrent() -> Bool { current }
'''
swift += methods + r'''
}
@main struct Main {
    @MainActor static var assertions = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }
    @MainActor static func main() async {
        let s = Subject()
        s.consent.savedRecoveryPhrase = true; s.consent.understandsNoRecovery = true
        let phrase = s.recoveryPhrase
        s.copyPhrase()
        check(s.canCopyPhrase && UIPasteboard.general.writes == 1, "The accepted recovery phrase can be copied")
        s.advance(); s.advance()
        check(s.busy, "Finish must synchronously prevent repeat activation")
        check(!s.canClose && s.blocksInteractiveDismiss, "Local setup must finish before dismissal")
        await s.task?.value
        check(s.backup.starts == 1 && s.busy, "Upload owns the existing button until confirmed")
        check(s.step == .upload && !s.setupComplete, "Starting an upload cannot report completion")
        check(s.recoveryPhrase == phrase && s.consent.canFinish, "Waiting must retain the accepted page")
        check(s.canClose && !s.blocksInteractiveDismiss, "A slow upload cannot trap the user in setup")
        s.copyPhrase()
        check(s.canCopyPhrase && UIPasteboard.general.writes == 2, "An active upload must not disable phrase copying")
        s.backup.setupUploadProgress?.state = .pending
        check(s.busy, "Queued upload must keep the button loading before the task starts")
        check(s.canClose, "A queued upload must leave Close available")
        s.backup.setupUploadProgress?.state = .failed; s.updateUploadProgress()
        check(!s.busy && !s.setupComplete && s.recoveryPhrase == phrase, "Failure leaves the same page ready to retry")
        check(s.canRetryUpload, "Only the matching failed upload offers retry")
        s.copyPhrase()
        check(s.canCopyPhrase && UIPasteboard.general.writes == 3, "A failed upload must keep phrase copying available")
        s.current = false; s.copyPhrase()
        check(!s.canCopyPhrase && UIPasteboard.general.writes == 3, "A replaced visit cannot copy retained credentials")
        s.current = true
        s.retryUpload(); s.retryUpload()
        check(s.busy, "Retry must synchronously exclude duplicate commands")
        check(s.canClose, "Retry owns the button but cannot block Close")
        await s.task?.value
        check(s.backup.retries == 1 && s.busy, "Retry must wait for upload confirmation")
        s.backup.setupUploadProgress?.state = .complete; s.updateUploadProgress(); s.updateUploadProgress()
        check(s.setupComplete && s.recoveryPhrase.isEmpty && !s.consent.canFinish, "Only confirmed completion clears credentials")
        s.copyPhrase()
        check(!s.canCopyPhrase && UIPasteboard.general.writes == 3, "Confirmed completion revokes phrase copying")
        check(LavaAccessibilityAnnouncer.count == 1, "Completion is announced once")
        let retired = Subject(); retired.retired = true; retired.setupAttemptID = UUID(); retired.step = .upload
        retired.retryUpload(); check(retired.task == nil, "A retired visit cannot retry")
        retired.copyPhrase(); check(!retired.canCopyPhrase && UIPasteboard.general.writes == 3, "A retired visit cannot copy credentials")
        let unavailable = Subject(); unavailable.setupAttemptID = UUID(); unavailable.step = .upload
        unavailable.backup.setupUploadProgress = Progress(id: unavailable.setupAttemptID!, state: .unavailable)
        check(!unavailable.canRetryUpload && unavailable.canClose, "Unavailable upload disables retry and allows Close")
        unavailable.retryUpload(); check(unavailable.task == nil, "Unavailable upload cannot start a no-op retry")
        unavailable.backup.setupUploadProgress = Progress(id: UUID(), state: .failed)
        unavailable.retryUpload(); check(!unavailable.canRetryUpload && unavailable.task == nil, "A replacement attempt cannot retry")
        unavailable.backup.setupUploadProgress = nil
        unavailable.retryUpload(); check(!unavailable.canRetryUpload && unavailable.task == nil, "Missing progress cannot retry")
        print("Backup setup presentation: \(assertions) executable assertions passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='lava-backup-setup-') as tmp:
    folder = Path(tmp)
    (folder / 'Consent.swift').write_text(consent)
    (folder / 'Main.swift').write_text(swift)
    subprocess.run(['swiftc', '-parse-as-library', str(folder / 'Consent.swift'), str(folder / 'Main.swift'), '-o', str(folder / 'test')], check=True)
    subprocess.run([str(folder / 'test')], check=True)
