import LavaSecCore
import SwiftUI

struct BackupRestoreView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var recoveryPhrasePaste = ""
    @State private var recoveryWords = Array(repeating: "", count: BackupRecoveryPhrase.wordCount)
    @State private var mode: BackupRestoreMode = .deviceKey
    @State private var restoreStatus: RestoreStatus = .choosing
    @State private var isRestoring = false
    @FocusState private var focusedWord: Int?

    var body: some View {
        LavaScreenContent(spacing: 22) {
            LavaSectionGroup("Unlock and restore locally") {
                VStack(alignment: .leading, spacing: 14) {
                    RestoreStatusPanel(status: restoreStatus)

                    LavaPlainCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker("Unlock method", selection: $mode) {
                                ForEach(BackupRestoreMode.allCases, id: \.self) { mode in
                                    Text(mode.title.lavaLocalized).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            // Switching method means the user is re-choosing, so a
                            // prior success/failure/cancel banner shouldn't linger.
                            .onChange(of: mode) { _, _ in
                                if restoreStatus != .restoring {
                                    restoreStatus = .choosing
                                }
                            }

                            switch mode {
                            case .deviceKey:
                                RestoreMethodHint(systemImage: "iphone", title: "Use this device's keychain")
                            case .passkey:
                                RestoreMethodHint(systemImage: "person.badge.key", title: "Use your saved passkey")
                            case .recoveryCode:
                                recoveryPhraseFields
                            }
                        }
                    }
                }
            }

            Button {
                restore()
            } label: {
                Label((isRestoring ? "Restoring" : "Restore Backup").lavaLocalized, systemImage: "icloud.and.arrow.down")
            }
            .buttonStyle(LavaStandaloneActionButtonStyle())
            .disabled(mode.isUnavailable || (mode.requiresTypedSecret && restoreSecret.isEmpty) || isRestoring)
        }
        .navigationTitle("Restore Backup".lavaLocalized)
    }

    private var recoveryPhraseFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            LavaTextInputPanel {
                LavaTextEditorInputRow(
                    title: "Paste full phrase",
                    text: $recoveryPhrasePaste,
                    placeholder: "Paste the full recovery phrase",
                    minHeight: 60
                )
                .onChange(of: recoveryPhrasePaste) { _, newValue in
                    recoveryWords = BackupRecoveryPhrase.fillSlots(from: newValue)
                }

                Divider()

                LavaTextInputRow(title: "Words") {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)
                        ],
                        spacing: 8
                    ) {
                        ForEach(0..<BackupRecoveryPhrase.wordCount, id: \.self) { index in
                            BackupRecoveryWordField(
                                number: index + 1,
                                word: recoveryWordBinding(index: index),
                                fieldIndex: index,
                                focusedField: $focusedWord,
                                onSpace: { advanceFocus(after: index) }
                            )
                        }
                    }
                }
            }

            Text("Spaces and capitalization do not matter. Press space to jump to the next word.".lavaLocalized)
                .lavaQuietNoteText()
        }
    }

    private var restoreSecret: String {
        switch mode {
        case .deviceKey, .passkey:
            ""
        case .recoveryCode:
            recoverySecretForRestore
        }
    }

    private var recoverySecretForRestore: String {
        let phrase = BackupRecoveryPhrase.phrase(from: recoveryWords)
        guard recoveryWords.allSatisfy({ !BackupRecoveryPhrase.normalizedWord($0).isEmpty }) else {
            return recoveryPhrasePaste.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return phrase
    }

    private func recoveryWordBinding(index: Int) -> Binding<String> {
        Binding {
            guard recoveryWords.indices.contains(index) else {
                return ""
            }

            return recoveryWords[index]
        } set: { newValue in
            guard recoveryWords.indices.contains(index) else {
                return
            }

            recoveryWords[index] = newValue
        }
    }

    // A space inside a word field means "I'm done with this word" — strip it and
    // jump to the next field (or dismiss the keyboard on the last word), so typing
    // "word1 word2 word3" walks the grid the way a recovery phrase reads.
    private func advanceFocus(after index: Int) {
        let next = index + 1
        if next < BackupRecoveryPhrase.wordCount {
            focusedWord = next
        } else {
            focusedWord = nil
        }
    }

    private func restore() {
        isRestoring = true
        restoreStatus = .restoring
        let unlockSecret = restoreSecret
        Task {
            do {
                try await viewModel.restoreEncryptedBackup(secret: unlockSecret, mode: mode)
                await MainActor.run {
                    restoreStatus = .success
                    isRestoring = false
                }
            } catch {
                await MainActor.run {
                    restoreStatus = Self.failureStatus(for: error)
                    isRestoring = false
                }
            }
        }
    }

    // A short, mapped reason — not the raw error dump. EncryptedBackupError and
    // BackupPasskeyError are already friendly one-liners; a user-cancelled passkey
    // sheet is surfaced as a calm "cancelled", not a failure.
    private static func failureStatus(for error: Error) -> RestoreStatus {
        if let passkeyError = error as? BackupPasskeyError, case .canceled = passkeyError {
            return .cancelled
        }

        return .failed(reason: error.localizedDescription)
    }
}

private enum RestoreStatus: Equatable {
    case choosing
    case restoring
    case success
    case failed(reason: String)
    case cancelled

    var title: String {
        switch self {
        case .choosing:
            "Choose a method"
        case .restoring:
            "Restoring…"
        case .success:
            "Restored successfully"
        case .failed:
            "Restore failed"
        case .cancelled:
            "Restore cancelled"
        }
    }

    // Always one short line so the panel keeps a steady height across states.
    var detail: String {
        switch self {
        case .choosing:
            "Unlock happens on this device."
        case .restoring:
            "Unlocking on this device…"
        case .success:
            "Lava will use the restored settings on this device."
        case .failed(let reason):
            reason
        case .cancelled:
            "No changes were made."
        }
    }

    var tint: Color {
        switch self {
        case .choosing, .restoring, .success:
            LavaStyle.safeGreen
        case .failed:
            LavaStyle.lavaOrange
        case .cancelled:
            LavaStyle.secondaryText
        }
    }
}

private struct RestoreStatusPanel: View {
    let status: RestoreStatus

    var body: some View {
        LavaInfoPanel(
            title: status.title,
            description: status.detail,
            systemImage: "icloud.and.arrow.down.fill",
            tint: status.tint
        )
    }
}

private struct RestoreMethodHint: View {
    let systemImage: String
    let title: String

    var body: some View {
        Label(title.lavaLocalized, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

private struct BackupRecoveryWordField: View {
    let number: Int
    @Binding var word: String
    let fieldIndex: Int
    @FocusState.Binding var focusedField: Int?
    let onSpace: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)

            TextField("Word \(number)".lavaLocalized, text: $word)
                .focused($focusedField, equals: fieldIndex)
                .lavaTextInputBody(submitLabel: .next)
                .onChange(of: word) { _, newValue in
                    guard newValue.contains(" ") else {
                        return
                    }

                    word = newValue.replacingOccurrences(of: " ", with: "")
                    onSpace()
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
    }
}

enum BackupRestoreMode: String, CaseIterable, Equatable {
    case deviceKey
    case passkey
    case recoveryCode

    var title: String {
        switch self {
        case .deviceKey:
            "This Device"
        case .passkey:
            "Passkey"
        case .recoveryCode:
            "Recovery"
        }
    }

    var requiresTypedSecret: Bool {
        switch self {
        case .deviceKey, .passkey:
            false
        case .recoveryCode:
            true
        }
    }

    var isUnavailable: Bool {
        switch self {
        case .deviceKey, .passkey, .recoveryCode:
            false
        }
    }
}
