import LavaSecAppServices
import Combine
import UIKit
import UniformTypeIdentifiers

/// Native credential and transaction owner for the React-owned setup flow.
@MainActor
final class BackupSetupSession: ObservableObject {
    @Published private(set) var step: BackupSetupStep = .overview
    @Published private(set) var selectedPasskeyMode: BackupSetupPasskeyMode?
    @Published private(set) var recoveryPhrase = ""
    @Published private(set) var consent = BackupSetupConsent()
    @Published private(set) var isPreparingPasskey = false
    @Published private(set) var isValidatingPasskey = false
    @Published private(set) var isFinishingSetup = false
    @Published private(set) var setupComplete = false
    @Published private(set) var errorMessage: String?
    private let backup: BackupController
    private let isCurrent: () -> Bool
    private var setupAttemptID: UUID?
    private var setupFeedbackID: UUID?
    private var retired = false
    private var task: Task<Void, Never>?
    private var progressSubscription: AnyCancellable?

    init(backup: BackupController, isCurrent: @escaping () -> Bool) {
        self.backup = backup; self.isCurrent = isCurrent
        ensureRecoveryPhrase()
        progressSubscription = backup.$setupUploadProgress.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send(); self?.updateUploadProgress() }
        }
    }
    var busy: Bool { isPreparingPasskey || isValidatingPasskey || isFinishingSetup || isUploadingSetup }
    // Upload owns the button after the local setup has committed. Leaving the
    // sheet retires credentials without cancelling the controller-owned upload.
    var canClose: Bool { !busy || step == .upload }
    var blocksInteractiveDismiss: Bool { !canClose || step == .validatePasskey }
    var canBack: Bool { !busy && [.validatePasskey, .recoveryPhrase].contains(step) }
    var canAdvance: Bool { step == .recoveryPhrase && selectedPasskeyMode != nil && !recoveryPhrase.isEmpty && consent.canFinish }
    var recoveryWords: [String] { BackupRecoveryPhrase.words(from: recoveryPhrase) }
    var isUploadingSetup: Bool {
        guard let progress = backup.setupUploadProgress, progress.id == setupAttemptID else { return false }
        return progress.state == .pending || progress.state == .uploading
    }
    var canRetryUpload: Bool {
        guard let progress = backup.setupUploadProgress, progress.id == setupAttemptID else { return false }
        if case .failed = progress.state { return true }
        return false
    }
    var uploadError: String? {
        guard backup.setupUploadProgress?.id == setupAttemptID else { return "Backup upload paused. Return to Account & Backup to continue." }
        switch backup.setupUploadProgress?.state {
        case .failed(let message): return message
        case .unavailable: return "Backup upload paused. Return to Account & Backup to continue."
        default: return nil
        }
    }
    func retire() {
        guard !retired else { return }; retired = true; task?.cancel(); task = nil
        if let setupFeedbackID { LavaFeedbackCoordinator.shared.finish("backup.setup", setupFeedbackID, .failed, cancelled: true) }
        setupFeedbackID = nil; consent.reset(); recoveryPhrase = ""; backup.clearPendingBackupPasskey()
    }
    func back() { guard canBack else { return }; if step == .validatePasskey { cancelPasskeyValidation() } else { step = .overview } }
    func setConsent(saved: Bool, understands: Bool) { guard !busy, step == .recoveryPhrase else { return }; consent.savedRecoveryPhrase = saved; consent.understandsNoRecovery = understands }
    func copyPhrase() {
        guard !retired, isCurrent(), step == .recoveryPhrase, !recoveryPhrase.isEmpty else { return }
        UIPasteboard.general.setItems([[UTType.plainText.identifier: recoveryPhrase]], options: [UIPasteboard.OptionsKey.localOnly: true, UIPasteboard.OptionsKey.expirationDate: Date().addingTimeInterval(600)])
        consent.recordCopy(); ProtectionHapticFeedback.play(.selectionConfirmed)
    }
    func beginSetup(with mode: BackupSetupPasskeyMode) {
        guard !busy, step == .overview, !retired, isCurrent() else { return }
        if selectedPasskeyMode != mode { recoveryPhrase = ""; consent.reset(); ensureRecoveryPhrase() }
        selectedPasskeyMode = mode; errorMessage = nil
        guard mode == .withPasskey else { backup.clearPendingBackupPasskey(); step = .recoveryPhrase; return }
        isPreparingPasskey = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await backup.registerBackupPasskey()
                guard !Task.isCancelled, !retired, isCurrent(), step == .overview else { return }
                step = .validatePasskey
            } catch {
                guard !retired, isCurrent() else { return }
                selectedPasskeyMode = nil; errorMessage = error.localizedDescription
            }
            isPreparingPasskey = false
        }
    }
    func validatePasskey() {
        guard !busy, step == .validatePasskey, !retired, isCurrent() else { return }
        errorMessage = nil; isValidatingPasskey = true
        task = Task { [weak self] in
            guard let self else { return }
            let failure: String?
            do { try await backup.validateBackupPasskey(); failure = nil } catch { failure = error.localizedDescription }
            guard !Task.isCancelled, !retired, isCurrent(), step == .validatePasskey else { return }
            isValidatingPasskey = false
            if let failure { errorMessage = failure } else { step = .recoveryPhrase }
        }
    }
    func cancelPasskeyValidation() {
        guard !busy, step == .validatePasskey else { return }; backup.clearPendingBackupPasskey(); selectedPasskeyMode = nil; errorMessage = nil; step = .overview
    }
    func advance() {
        guard canAdvance, !busy, !retired, isCurrent() else { return }
        isFinishingSetup = true
        let feedbackID = LavaFeedbackCoordinator.shared.begin("backup.setup"); setupFeedbackID = feedbackID
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await backup.turnOnEncryptedBackup(recoveryPhrase: recoveryPhrase)
                guard !Task.isCancelled, !retired, isCurrent() else { return }
                // Keep the accepted phrase and consent in place while the same
                // button waits for the online copy. Clear credentials on success
                // or retirement, not during the transition into an upload.
                setupAttemptID = backup.setupUploadProgress?.id; step = .upload; isFinishingSetup = false; updateUploadProgress()
            } catch {
                guard !retired, isCurrent() else { return }
                errorMessage = error.localizedDescription; isFinishingSetup = false
                let cancelled: Bool
                if let passkeyError = error as? BackupPasskeyError, case .canceled = passkeyError { cancelled = true } else { cancelled = error is CancellationError }
                LavaFeedbackCoordinator.shared.finish("backup.setup", feedbackID, .failed, cancelled: cancelled); setupFeedbackID = nil
            }
        }
    }
    func retryUpload() {
        guard !busy, !retired, isCurrent(), step == .upload, canRetryUpload, let setupAttemptID else { return }
        isFinishingSetup = true
        task = Task { [weak self] in
            guard let self else { return }
            await backup.retrySetupUpload(attemptID: setupAttemptID)
            isFinishingSetup = false; updateUploadProgress()
        }
    }
    private func ensureRecoveryPhrase() {
        guard step != .complete, step != .upload, recoveryPhrase.isEmpty else { return }
        do { recoveryPhrase = try BackupRecoveryPhrase.generate(); consent.reset() } catch { errorMessage = error.localizedDescription }
    }
    private func updateUploadProgress() {
        guard !retired, isCurrent(), !setupComplete, step == .upload, let setupAttemptID, backup.isSetupUploadConfirmed(attemptID: setupAttemptID) else { return }
        if let setupFeedbackID { LavaFeedbackCoordinator.shared.finish("backup.setup", setupFeedbackID, .succeeded); self.setupFeedbackID = nil }
        LavaAccessibilityAnnouncer.announce("Backup is ready".lavaLocalized); setupComplete = true; recoveryPhrase = ""; consent.reset()
    }
}

enum BackupSetupStep: String {
    case overview, validatePasskey, recoveryPhrase, upload, complete
    var title: String {
        switch self {
        case .overview: "Set Up Encrypted Backup"
        case .validatePasskey: "Confirm your passkey"
        case .recoveryPhrase: "Save your recovery phrase"
        case .upload: "Save your recovery phrase"
        case .complete: "Backup is ready"
        }
    }
}
