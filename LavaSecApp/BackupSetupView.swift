import LavaSecCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BackupSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: AppViewModel

    @State private var step: BackupSetupStep = .overview
    @State private var selectedPasskeyMode: BackupSetupPasskeyMode?
    @State private var recoveryPhrase = ""
    @State private var copiedRecoveryPhrase = false
    @State private var savedRecoveryPhrase = false
    @State private var understandsNoRecovery = false
    @State private var isPreparingPasskey = false
    @State private var isFinishingSetup = false
    @State private var errorMessage: String?

    var body: some View {
        LavaSheetScaffold {
            VStack(alignment: .leading, spacing: 14) {
                stepHeader
                stepContent
            }
        } footer: {
            footer
        }
        .navigationTitle("Set Up Encrypted Backup".lavaLocalized)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ensureRecoveryPhrase()
        }
    }

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(step.title.lavaLocalized)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(step.subtitle.lavaLocalized)
                .lavaBodySupportingText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .overview:
            overviewStep
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
                        detail: "A local unlock is saved in Keychain. Lava never sees it."
                    )

                    Divider()

                    BackupSetupFactRow(
                        systemImage: "person.badge.key.fill",
                        title: "Passkey",
                        detail: "Optional. Saved in your password manager; lets Lava help restore on a new device. The recovery phrase, by contrast, keeps your backup decryptable only by you."
                    )

                    Divider()

                    BackupSetupFactRow(
                        systemImage: "text.badge.checkmark",
                        title: "Recovery phrase",
                        detail: "Use it with your signed-in account to restore on a new device."
                    )
                }
            }

            VStack(spacing: 10) {
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
                .buttonStyle(LavaPanelActionButtonStyle(height: 44, cornerRadius: 12))
                .disabled(isPreparingPasskey)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LavaStyle.lavaOrange)
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
                    } label: {
                        Label((copiedRecoveryPhrase ? "Copied" : "Copy phrase").lavaLocalized, systemImage: copiedRecoveryPhrase ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(LavaPanelActionButtonStyle())
                    .disabled(recoveryPhrase.isEmpty)
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
                    .foregroundStyle(LavaStyle.lavaOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if step == .overview {
            EmptyView()
        } else {
        HStack(spacing: 12) {
            if step != .overview {
                Button("Back") {
                    step = step.previous
                }
                .buttonStyle(LavaPanelActionButtonStyle())
            }

            Button(step.primaryButtonTitle.lavaLocalized) {
                advance()
            }
            .buttonStyle(LavaStandaloneActionButtonStyle())
            .disabled(!canAdvance || isFinishingSetup)
        }
        }
    }

    private var recoveryWords: [String] {
        BackupRecoveryPhrase.words(from: recoveryPhrase)
    }

    private var canAdvance: Bool {
        switch step {
        case .overview:
            selectedPasskeyMode != nil && !recoveryPhrase.isEmpty
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
            viewModel.clearPendingBackupPasskey()
            step = .recoveryPhrase
            return
        }

        isPreparingPasskey = true
        Task {
            do {
                try await viewModel.prepareBackupPasskey()
                step = .recoveryPhrase
            } catch {
                selectedPasskeyMode = nil
                errorMessage = error.localizedDescription
            }
            isPreparingPasskey = false
        }
    }

    private func advance() {
        switch step {
        case .overview:
            step = .recoveryPhrase
        case .recoveryPhrase:
            step = .confirm
        case .confirm:
            guard !isFinishingSetup else {
                return
            }

            isFinishingSetup = true
            Task {
                do {
                    try await viewModel.turnOnEncryptedBackup(recoveryPhrase: recoveryPhrase)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                    isFinishingSetup = false
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
}

private enum BackupSetupStep {
    case overview
    case recoveryPhrase
    case confirm

    var title: String {
        switch self {
        case .overview:
            "Set Up Encrypted Backup"
        case .recoveryPhrase:
            "Save your recovery phrase"
        case .confirm:
            "Turn on encrypted backup"
        }
    }

    var subtitle: String {
        switch self {
        case .overview:
            "Your lists are encrypted on your device before upload. With your recovery phrase, only you can decrypt them. An optional Passkey makes new-device restore easier — but Lava stores a recovery secret for that path, so it isn't fully private to you."
        case .recoveryPhrase:
            "Save these eight words outside Lava. Copying is optional."
        case .confirm:
            "Setup finishes after the recovery phrase is saved."
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .overview, .recoveryPhrase:
            "Continue"
        case .confirm:
            "Turn On Backup"
        }
    }

    var previous: BackupSetupStep {
        switch self {
        case .overview, .recoveryPhrase:
            .overview
        case .confirm:
            .recoveryPhrase
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

            VStack(alignment: .leading, spacing: 3) {
                Text(title.lavaLocalized)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(detail.lavaLocalized)
                    .lavaBodySupportingText()
            }

            Spacer(minLength: 0)
        }
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
