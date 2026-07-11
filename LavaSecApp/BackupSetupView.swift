import LavaSecAppServices
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BackupSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var backup: BackupController

    @State private var step: BackupSetupStep = .overview
    /// Whether the next step swap reads as a push or a pop, so the slide matches
    /// the direction of travel. Set by `go(to:)` from the step ordering.
    @State private var navDirection: LavaFlowDirection = .forward
    @State private var selectedPasskeyMode: BackupSetupPasskeyMode?
    @State private var recoveryPhrase = ""
    @State private var copiedRecoveryPhrase = false
    @State private var savedRecoveryPhrase = false
    @State private var understandsNoRecovery = false
    @State private var isPreparingPasskey = false
    @State private var isValidatingPasskey = false
    @State private var isFinishingSetup = false
    @State private var errorMessage: String?

    var body: some View {
        LavaSheetScaffold {
            header
        } content: {
            // The chevron-back header and footer actions stay put on the sheet
            // while the step body slides, mirroring a native push/pop (the title
            // bar and toolbar holding still as the page underneath moves).
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
                    } else {
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
        // disabled chevron only covers the button; without this the gesture
        // reintroduces the same race.
        .interactiveDismissDisabled(blocksInteractiveDismiss)
        .onAppear {
            ensureRecoveryPhrase()
        }
        .lavaTier(.calm)
    }

    // Mirror the import-filters sheet chrome: a chevron-back / centered-title bar on
    // the sheet's material header instead of a pushed navigation bar, so the flow
    // covers the tab bar.
    private var header: some View {
        HStack {
            // Disabled while a passkey/setup task is awaiting, matching the footer
            // buttons — otherwise Back could fire cancelPasskeyValidation() mid
            // validation and let the in-flight task still advance the flow.
            LavaToolbarIconButton(systemName: "chevron.left", accessibilityLabel: "Back", action: headerBack)
                .disabled(isStepActionInFlight)

            Spacer()

            Text(step.title.lavaLocalized)
                .font(.headline)
                .foregroundStyle(LavaStyle.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            Color.clear.frame(width: 44, height: 44)
        }
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
        case .recoveryPhrase, .confirm:
            go(to: step.previous)
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
        case .confirm:
            confirmStep
        }
    }

    private var overviewStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            LavaPlainCard {
                VStack(alignment: .leading, spacing: 12) {
                    BackupSetupFactRow(
                        systemImage: "key.fill",
                        title: "This device",
                        detail: "A local unlock key is kept safe on this phone. Lava never sees it."
                    )

                    Divider()

                    BackupSetupFactRow(
                        systemImage: "person.badge.key.fill",
                        title: "Passkey",
                        detail: "Optional (iOS 18+). Saved in your password manager to restore on a new device. Your phone makes the key itself, so Lava still can't read your backup."
                    )

                    Divider()

                    BackupSetupFactRow(
                        systemImage: "text.badge.checkmark",
                        title: "Recovery phrase",
                        detail: "Use it with your signed-in account to restore on a new device."
                    )
                }
            }

            if let errorMessage {
                Text(errorMessage)
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
                Text(errorMessage)
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
                        columns: [
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
                        copiedRecoveryPhrase = true
                        ProtectionHapticFeedback.play(.selectionConfirmed)
                    } label: {
                        Label((copiedRecoveryPhrase ? "Copied" : "Copy phrase").lavaLocalized, systemImage: copiedRecoveryPhrase ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(LavaPanelActionButtonStyle())
                    .disabled(recoveryPhrase.isEmpty)
                    // The visible label flips to "Copied" after a tap. Surface the stable "Copy
                    // phrase" / "Copy" commands FIRST (Voice Control's Show Names uses the first
                    // entry), then append the *current* visible label so a user reading "Copied" can
                    // still say "tap Copied" to re-copy. Pre-tap the label is already "Copy phrase",
                    // so only the "Copied" state needs appending.
                    .accessibilityInputLabels(["Copy phrase".lavaLocalized, "Copy".lavaLocalized] + (copiedRecoveryPhrase ? ["Copied".lavaLocalized] : []))
                }
            }
        }
    }

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            LavaInfoPanel(
                title: "Encrypted backup is ready",
                description: "New-device restore can use a Passkey or this recovery phrase with your signed-in Lava account",
                systemImage: "lock.shield.fill"
            )

            LavaPlainCard {
                VStack(alignment: .leading, spacing: 12) {
                    BackupConfirmationToggle(
                        title: "I saved the recovery phrase",
                        isOn: $savedRecoveryPhrase
                    )

                    BackupConfirmationToggle(
                        title: "I understand that if I lose every unlock method, I may not be able to restore my backup",
                        isOn: $understandsNoRecovery
                    )
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LavaStyle.lavaOrangeText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
        case .recoveryPhrase, .confirm:
            Button(step.primaryButtonTitle.lavaLocalized) {
                advance()
            }
            .buttonStyle(LavaStandaloneActionButtonStyle())
            .disabled(!canAdvance || isFinishingSetup)
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
                    selectedPasskeyMode = .withPasskey
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
                    selectedPasskeyMode = .withoutPasskey
                    beginSetup(with: .withoutPasskey)
                } label: {
                    Text("Set up without Passkey".lavaLocalized)
                }
                .buttonStyle(LavaPanelActionButtonStyle())
                .disabled(isPreparingPasskey)
            } else {
                Button {
                    selectedPasskeyMode = .withoutPasskey
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
            !recoveryPhrase.isEmpty
        case .confirm:
            savedRecoveryPhrase && understandsNoRecovery
        }
    }

    private func beginSetup(with mode: BackupSetupPasskeyMode) {
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
        case .recoveryPhrase:
            go(to: .confirm)
        case .confirm:
            guard !isFinishingSetup else {
                return
            }

            isFinishingSetup = true
            Task {
                do {
                    try await backup.turnOnEncryptedBackup(recoveryPhrase: recoveryPhrase)
                    ProtectionHapticFeedback.play(.actionSucceeded)
                    // Success dismisses the sheet immediately, so there is no on-screen
                    // confirmation for VoiceOver to land on — announce that backup is on.
                    LavaAccessibilityAnnouncer.announce("Encrypted backup is ready".lavaLocalized)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                    isFinishingSetup = false
                    ProtectionHapticFeedback.play(.actionFailed)
                }
            }
        }
    }

    private func ensureRecoveryPhrase() {
        guard recoveryPhrase.isEmpty else {
            return
        }

        do {
            recoveryPhrase = try BackupRecoveryPhrase.generate()
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
    case confirm

    var title: String {
        switch self {
        case .overview:
            "Set Up Encrypted Backup"
        case .validatePasskey:
            "Confirm your passkey"
        case .recoveryPhrase:
            "Save your recovery phrase"
        case .confirm:
            "Turn on encrypted backup"
        }
    }

    var subtitle: String {
        switch self {
        case .overview:
            "Your lists are encrypted on your device before upload. Only you can unlock them — with your recovery phrase or a Passkey. Lava only ever stores encrypted data."
        case .validatePasskey:
            "Use your passkey once more so Lava can confirm it unlocks this backup, then save your recovery phrase."
        case .recoveryPhrase:
            "Save these eight words outside Lava. Copying is optional."
        case .confirm:
            "Setup finishes after the recovery phrase is saved."
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .overview, .validatePasskey, .recoveryPhrase:
            "Continue"
        case .confirm:
            "Turn On Backup"
        }
    }

    var previous: BackupSetupStep {
        switch self {
        case .overview, .validatePasskey, .recoveryPhrase:
            .overview
        case .confirm:
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
        case .confirm: 3
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

    var body: some View {
        HStack(spacing: 7) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)

            Text(word)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct BackupConfirmationToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title.lavaLocalized)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tint(LavaStyle.safeControlGreen)
    }
}
