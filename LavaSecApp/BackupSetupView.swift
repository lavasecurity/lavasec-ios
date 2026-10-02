import LavaSecAppServices
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BackupSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var backup: BackupController

    @State private var step: BackupSetupStep = .overview
    /// Whether the next step swap reads as a push or a pop, so the slide matches
    /// the direction of travel. Set by `go(to:)` from the step ordering.
    @State private var navDirection: LavaFlowDirection = .forward
    @State private var selectedPasskeyMode: BackupSetupPasskeyMode?
    @State private var recoveryPhrase = ""
    @State private var consent = BackupSetupConsent()
    @State private var setupAttemptID: UUID?
    @State private var setupFeedbackID: UUID?
    @State private var didClose = false
    @State private var isPreparingPasskey = false
    @State private var isValidatingPasskey = false
    @State private var isFinishingSetup = false
    @State private var setupComplete = false
    @State private var errorMessage: String?

    var body: some View {
        if setupComplete {
            LavaSuccessScreen(title: "Backup is ready",
                              message: "Your encrypted backup is set up on this device.",
                              done: dismiss.callAsFunction)
        } else {
            setupPage
        }
    }

    private var setupPage: some View {
        LavaTaskSheet(title: step.title, back: sheetBackAction,
                      actionsDisabled: isStepActionInFlight, scrolls: step != .complete, close: closeFlow) {
            // Native task chrome stays fixed while the step body changes.
            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 14) {
                    // The landing step leads with a boxed intro panel (matching
                    // BackupRestoreView's on-ramp); later steps use the quieter
                    // per-step supporting subtitle.
                    if step == .overview {
                        LavaInfoPanel(
                            title: "Your backup stays private",
                            description: step.subtitle,
                            systemImage: "lock.shield.fill"
                        )
                    } else if step != .complete {
                        Text(step.subtitle.lavaLocalized)
                            .lavaSupportingText()
                    }

                    stepContent
                }
                .lavaFlowTransition(value: step, direction: navDirection, reduceMotion: reduceMotion)
            }
        } footer: {
            footer
        }
        // Block the sheet's interactive swipe-to-dismiss while a passkey/setup
        // task is awaiting, and on .validatePasskey — that step holds a
        // registered-but-unvalidated passkey that only the Cancel/Back path
        // (cancelPasskeyValidation) cleans up, so a drag-dismiss there would
        // leave orphaned pending passkey state in the backup controller. The
        // disabled toolbar only covers the buttons; without this the gesture
        // reintroduces the same race.
        .interactiveDismissDisabled(blocksInteractiveDismiss)
        .onAppear {
            ensureRecoveryPhrase()
        }
        .onChange(of: backup.setupUploadProgress) { _, _ in updateUploadProgress() }
        .lavaTier(.calm)
    }

    private var sheetBackAction: (() -> Void)? {
        guard step != .overview, step != .complete, step != .upload else { return nil }
        return { headerBack() }
    }

    private func closeFlow() {
        guard !isStepActionInFlight, !didClose else { return }
        didClose = true
        if let setupFeedbackID {
            LavaFeedbackCoordinator.shared.finish("backup.setup", setupFeedbackID, .failed, cancelled: true)
            self.setupFeedbackID = nil
        }
        consent.reset()
        backup.clearPendingBackupPasskey()
        recoveryPhrase = ""
        dismiss()
    }

    private var isStepActionInFlight: Bool {
        isPreparingPasskey || isValidatingPasskey || isFinishingSetup
    }

    // Swipe-to-dismiss is blocked while a task is in flight and on the
    // validatePasskey step, whose pending passkey only the Cancel/Back path
    // cleans up. The chevron stays enabled on validatePasskey (it routes through
    // cancelPasskeyValidation), so leaving that step still runs cleanup.
    private var blocksInteractiveDismiss: Bool {
        isStepActionInFlight || step == .validatePasskey
    }

    private func headerBack() {
        switch step {
        case .overview:
            dismiss()
        case .validatePasskey:
            cancelPasskeyValidation()
        case .recoveryPhrase:
            go(to: step.previous)
        case .upload, .complete:
            break
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .overview:
            overviewStep
        case .validatePasskey:
            validatePasskeyStep
        case .recoveryPhrase:
            recoveryPhraseStep
        case .upload:
            uploadStep
        case .complete:
            completionStep
        }
    }

    private var overviewStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            LavaPlainCard {
                VStack(alignment: .leading, spacing: 12) {
                    BackupSetupFactRow(
                        systemImage: "key.fill",
                        title: "This device",
                        detail: "A local unlock key stays on this device."
                    )

                    Divider()

                    BackupSetupFactRow(
                        systemImage: "person.badge.key.fill",
                        title: "Passkey",
                        detail: "Restore with your password manager."
                    )

                    Divider()

                    BackupSetupFactRow(
                        systemImage: "text.badge.checkmark",
                        title: "Recovery phrase",
                        detail: "Keep it safe to restore with your account."
                    )
                }
            }

            if let errorMessage {
                Text(errorMessage.lavaLocalized)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LavaStyle.lavaOrangeText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var validatePasskeyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            LavaPlainCard {
                VStack(alignment: .leading, spacing: 12) {
                    BackupSetupFactRow(
                        systemImage: "checkmark.shield.fill",
                        title: "How restore works",
                        detail: "You'll use your passkey once more. This is the same step a new device runs to unlock your backup, so it confirms restore will work."
                    )
                }
            }

            if let errorMessage {
                Text(errorMessage.lavaLocalized)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LavaStyle.lavaOrangeText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var recoveryPhraseStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            LavaPlainCard {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(
                        columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)
                        ],
                        spacing: 8
                    ) {
                        ForEach(Array(recoveryWords.enumerated()), id: \.offset) { index, word in
                            BackupRecoveryPhraseWord(number: index + 1, word: word)
                        }
                    }

                    Button {
                        let expirationDate = Date().addingTimeInterval(600)
                        UIPasteboard.general.setItems(
                            [[UTType.plainText.identifier: recoveryPhrase]],
                            options: [
                                UIPasteboard.OptionsKey.localOnly: true,
                                UIPasteboard.OptionsKey.expirationDate: expirationDate
                            ]
                        )
                        consent.recordCopy()
                        ProtectionHapticFeedback.play(.selectionConfirmed)
                    } label: {
                        Label((consent.copiedRecoveryPhrase ? "Copied" : "Copy phrase").lavaLocalized, systemImage: consent.copiedRecoveryPhrase ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(LavaPanelActionButtonStyle())
                    .disabled(recoveryPhrase.isEmpty)
                    // The visible label flips to "Copied" after a tap. Surface the stable "Copy
                    // phrase" / "Copy" commands FIRST (Voice Control's Show Names uses the first
                    // entry), then append the *current* visible label so a user reading "Copied" can
                    // still say "tap Copied" to re-copy. Pre-tap the label is already "Copy phrase",
                    // so only the "Copied" state needs appending.
                    .accessibilityInputLabels(["Copy phrase".lavaLocalized, "Copy".lavaLocalized] + (consent.copiedRecoveryPhrase ? ["Copied".lavaLocalized] : []))
                }
            }
            LavaCondensedList {
                LavaToggleRow(
                    title: "I have saved my recovery phrase in a secure, accessible place",
                    isOn: $consent.savedRecoveryPhrase
                )
                LavaCondensedDivider()
                LavaToggleRow(
                    title: "I understand that if I lose every unlock method, I may not be able to restore my backup",
                    isOn: $consent.understandsNoRecovery
                )
            }
            .disabled(isFinishingSetup)
            if let errorMessage {
                Text(errorMessage.lavaLocalized)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LavaStyle.lavaOrangeText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var completionStep: some View {
        LavaCompletionContent(title: "Encrypted backup is ready", message: "Your encrypted backup is saved online.")
    }

    private var uploadStep: some View {
        VStack(spacing: 18) {
            if isUploadingSetup { ProgressView().controlSize(.large) }
            Text("Set up on this device. Your online backup is pending.".lavaLocalized)
                .lavaSupportingText()
            if let uploadError {
                Text(uploadError.lavaLocalized).lavaQuietNoteText()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var isUploadingSetup: Bool {
        backup.setupUploadProgress?.id == setupAttemptID && backup.setupUploadProgress?.state == .uploading
    }

    private var uploadError: String? {
        guard backup.setupUploadProgress?.id == setupAttemptID else {
            return "Backup upload paused. Return to Account & Backup to continue."
        }
        switch backup.setupUploadProgress?.state {
        case .failed(let message): return message
        case .unavailable: return "Backup upload paused. Return to Account & Backup to continue."
        default: return nil
        }
    }

    private func updateUploadProgress() {
        guard !didClose, step == .upload, let setupAttemptID,
              backup.isSetupUploadConfirmed(attemptID: setupAttemptID) else { return }
        if let setupFeedbackID {
            LavaFeedbackCoordinator.shared.finish("backup.setup", setupFeedbackID, .succeeded)
            self.setupFeedbackID = nil
        }
        LavaAccessibilityAnnouncer.announce("Backup is ready".lavaLocalized)
        setupComplete = true
    }

    // Every step's actions live on the sheet's grey footer bar (back is the header
    // chevron, matching the import-filters flow).
    @ViewBuilder
    private var footer: some View {
        switch step {
        case .overview:
            overviewActions
        case .validatePasskey:
            validatePasskeyActions
        case .recoveryPhrase:
            Button(step.primaryButtonTitle.lavaLocalized) {
                advance()
            }
            .buttonStyle(LavaStandaloneActionButtonStyle())
            .disabled(!canAdvance || isFinishingSetup)
        case .upload:
            VStack(spacing: 10) {
                Button("Retry upload".lavaLocalized) {
                    guard let setupAttemptID else { return }
                    Task { await backup.retrySetupUpload(attemptID: setupAttemptID) }
                }
                .buttonStyle(LavaStandaloneActionButtonStyle())
                .disabled(isUploadingSetup)
                Button("Return to Account & Backup".lavaLocalized, action: closeFlow)
                    .buttonStyle(LavaPanelActionButtonStyle())
            }
        case .complete:
            Button("Done".lavaLocalized, action: closeFlow)
                .buttonStyle(LavaStandaloneActionButtonStyle())
        }
    }

    @ViewBuilder
    private var overviewActions: some View {
        VStack(spacing: 10) {
            // Zero-knowledge passkey backup needs the WebAuthn PRF extension (iOS 18+). On
            // iOS 17 there is no passkey option to offer, so the flow is a single entry point
            // that sets up the device + recovery-phrase backup.
            if #available(iOS 18.0, *) {
                Button {
                    beginSetup(with: .withPasskey)
                } label: {
                    Label(
                        (isPreparingPasskey && selectedPasskeyMode == .withPasskey ? "Opening Passkey" : "Set up with Passkey").lavaLocalized,
                        systemImage: "person.badge.key.fill"
                    )
                }
                .buttonStyle(LavaStandaloneActionButtonStyle())
                .disabled(isPreparingPasskey)

                Button {
                    beginSetup(with: .withoutPasskey)
                } label: {
                    Text("Set up without Passkey".lavaLocalized)
                }
                .buttonStyle(LavaPanelActionButtonStyle())
                .disabled(isPreparingPasskey)
            } else {
                Button {
                    beginSetup(with: .withoutPasskey)
                } label: {
                    Text("Begin Setup".lavaLocalized)
                }
                .buttonStyle(LavaStandaloneActionButtonStyle())
                .disabled(isPreparingPasskey)
            }
        }
    }

    @ViewBuilder
    private var validatePasskeyActions: some View {
        VStack(spacing: 10) {
            Button {
                validatePasskey()
            } label: {
                Label(
                    (isValidatingPasskey ? "Checking Passkey" : "Validate the passkey").lavaLocalized,
                    systemImage: "person.badge.key.fill"
                )
            }
            .buttonStyle(LavaStandaloneActionButtonStyle())
            .disabled(isValidatingPasskey)

            Button {
                cancelPasskeyValidation()
            } label: {
                Text("Cancel".lavaLocalized)
            }
            .buttonStyle(LavaPanelActionButtonStyle())
            .disabled(isValidatingPasskey)
        }
    }

    private var recoveryWords: [String] {
        BackupRecoveryPhrase.words(from: recoveryPhrase)
    }

    private var canAdvance: Bool {
        switch step {
        case .overview:
            selectedPasskeyMode != nil && !recoveryPhrase.isEmpty
        case .validatePasskey:
            false
        case .recoveryPhrase:
            selectedPasskeyMode != nil && !recoveryPhrase.isEmpty && consent.canFinish
        case .upload, .complete:
            false
        }
    }

    private func beginSetup(with mode: BackupSetupPasskeyMode) {
        // A cancelled/failed ceremony clears the selected method. Unknown
        // provenance is a new attempt too, never permission to reuse consent.
        if selectedPasskeyMode != mode {
            recoveryPhrase = ""
            consent.reset()
            ensureRecoveryPhrase()
        }
        selectedPasskeyMode = mode
        errorMessage = nil

        guard mode == .withPasskey else {
            backup.clearPendingBackupPasskey()
            go(to: .recoveryPhrase)
            return
        }

        isPreparingPasskey = true
        Task {
            do {
                try await backup.registerBackupPasskey()
                go(to: .validatePasskey)
            } catch {
                selectedPasskeyMode = nil
                errorMessage = error.localizedDescription
            }
            isPreparingPasskey = false
        }
    }

    private func validatePasskey() {
        errorMessage = nil
        isValidatingPasskey = true
        Task {
            let failure: String?
            do {
                try await backup.validateBackupPasskey()
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            isValidatingPasskey = false
            // Ignore a result that lands after the user already left this step, so a
            // canceled validation can't advance the flow or surface a stale error.
            guard step == .validatePasskey else {
                return
            }
            if let failure {
                errorMessage = failure
            } else {
                go(to: .recoveryPhrase)
            }
        }
    }

    private func cancelPasskeyValidation() {
        backup.clearPendingBackupPasskey()
        selectedPasskeyMode = nil
        errorMessage = nil
        go(to: .overview)
    }

    private func advance() {
        switch step {
        case .overview:
            go(to: .recoveryPhrase)
        case .validatePasskey:
            break
        case .upload, .complete:
            break
        case .recoveryPhrase:
            guard canAdvance, !isFinishingSetup else {
                return
            }

            isFinishingSetup = true
            let feedbackID = LavaFeedbackCoordinator.shared.begin("backup.setup")
            setupFeedbackID = feedbackID
            Task {
                do {
                    try await backup.turnOnEncryptedBackup(recoveryPhrase: recoveryPhrase)
                    setupAttemptID = backup.setupUploadProgress?.id
                    recoveryPhrase = ""
                    consent.reset()
                    isFinishingSetup = false
                    go(to: .upload)
                    updateUploadProgress()
                } catch {
                    errorMessage = error.localizedDescription
                    isFinishingSetup = false
                    let cancelled: Bool
                    if let passkeyError = error as? BackupPasskeyError, case .canceled = passkeyError { cancelled = true }
                    else { cancelled = error is CancellationError }
                    LavaFeedbackCoordinator.shared.finish("backup.setup", feedbackID, .failed, cancelled: cancelled)
                    setupFeedbackID = nil
                }
            }
        }
    }

    private func ensureRecoveryPhrase() {
        guard step != .complete, step != .upload, recoveryPhrase.isEmpty else {
            return
        }

        do {
            recoveryPhrase = try BackupRecoveryPhrase.generate()
            consent.reset()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Moves to `newStep`, sliding in the direction implied by the step ordering
    /// (later = push, earlier = pop) so the transition matches a native
    /// navigation stack.
    private func go(to newStep: BackupSetupStep) {
        navDirection = newStep.order >= step.order ? .forward : .backward
        withAnimation(LavaFlowTransition.animation(reduceMotion: reduceMotion)) {
            step = newStep
        }
    }
}

private enum BackupSetupStep {
    case overview
    case validatePasskey
    case recoveryPhrase
    case upload
    case complete

    var title: String {
        switch self {
        case .overview:
            "Set Up Encrypted Backup"
        case .validatePasskey:
            "Confirm your passkey"
        case .recoveryPhrase:
            "Save your recovery phrase"
        case .upload:
            "Uploading backup"
        case .complete:
            "Backup is ready"
        }
    }

    var subtitle: String {
        switch self {
        case .overview:
            "Encrypted on this device. Only you can unlock your backup."
        case .validatePasskey:
            "Use your passkey once more so Lava can confirm it unlocks this backup, then save your recovery phrase."
        case .recoveryPhrase:
            "Copy these eight words, then save them somewhere safe outside Lava."
        case .upload, .complete:
            ""
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .overview, .validatePasskey:
            "Continue"
        case .recoveryPhrase:
            "Turn On Backup"
        case .upload:
            "Retry upload"
        case .complete:
            "Done"
        }
    }

    var previous: BackupSetupStep {
        switch self {
        case .overview, .validatePasskey, .recoveryPhrase:
            .overview
        case .upload, .complete:
            .recoveryPhrase
        }
    }

    /// Depth in the flow, so `go(to:)` can tell a push from a pop. validatePasskey
    /// and recoveryPhrase are both reached straight from overview, so either can
    /// follow it as a forward step.
    var order: Int {
        switch self {
        case .overview: 0
        case .validatePasskey: 1
        case .recoveryPhrase: 2
        case .upload: 3
        case .complete: 4
        }
    }
}

private struct BackupSetupFactRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(LavaStyle.safeGreen)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title.lavaLocalized)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(detail.lavaLocalized)
                    .lavaBodySupportingText()
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct BackupRecoveryPhraseWord: View {
    let number: Int
    let word: String
    @ScaledMetric(relativeTo: .caption) private var numberWidth = 18.0

    var body: some View {
        HStack(spacing: 7) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: numberWidth, alignment: .trailing)

            Text(word)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .lavaRecoveryWordSurface()
        .accessibilityElement(children: .combine)
    }
}
