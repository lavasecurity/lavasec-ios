import LavaSecCore
import SwiftUI

struct BackupRestoreView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var recoveryPhrasePaste = ""
    @State private var recoveryWords = Array(repeating: "", count: BackupRecoveryPhrase.wordCount)
    @State private var mode: BackupRestoreMode = .deviceKey
    @State private var message: String?
    @State private var isError = false
    @State private var isRestoring = false

    var body: some View {
        LavaScreenContent(spacing: 22) {
            LavaInfoPanel(
                title: "Restore backup",
                description: "Unlock happens on this device",
                systemImage: "arrow.clockwise.icloud.fill"
            )

            LavaSectionGroup("Unlock") {
                LavaPlainCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Unlock method", selection: $mode) {
                            ForEach(BackupRestoreMode.allCases, id: \.self) { mode in
                                Text(mode.title.lavaLocalized).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        switch mode {
                        case .deviceKey:
                            Label("Use this device's keychain".lavaLocalized, systemImage: "iphone")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        case .passkey:
                            Label("Use your saved passkey".lavaLocalized, systemImage: "person.badge.key")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        case .recoveryCode:
                            recoveryPhraseFields
                        }
                    }
                }
            }

            Button {
                restore()
            } label: {
                Label((isRestoring ? "Restoring" : "Restore Backup").lavaLocalized, systemImage: "arrow.clockwise")
            }
            .buttonStyle(LavaStandaloneActionButtonStyle())
            .disabled(mode.isUnavailable || (mode.requiresTypedSecret && restoreSecret.isEmpty) || isRestoring)

            if let message {
                Text(message.lavaLocalized)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isError ? LavaStyle.lavaOrange : LavaStyle.safeGreen)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .navigationTitle("Restore Backup".lavaLocalized)
    }

    private var recoveryPhraseFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Paste full phrase".lavaLocalized, text: $recoveryPhrasePaste, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .onChange(of: recoveryPhrasePaste) { _, newValue in
                    recoveryWords = BackupRecoveryPhrase.fillSlots(from: newValue)
                }

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
                        word: recoveryWordBinding(index: index)
                    )
                }
            }

            Text("Spaces and capitalization do not matter.".lavaLocalized)
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

    private func restore() {
        isRestoring = true
        let unlockSecret = restoreSecret
        Task {
            do {
                try await viewModel.restoreEncryptedBackup(secret: unlockSecret, mode: mode)
                await MainActor.run {
                    message = "Backup restored. Lava will use the restored settings on this device."
                    isError = false
                    isRestoring = false
                }
            } catch {
                await MainActor.run {
                    message = error.localizedDescription
                    isError = true
                    isRestoring = false
                }
            }
        }
    }
}

private struct BackupRecoveryWordField: View {
    let number: Int
    @Binding var word: String

    var body: some View {
        HStack(spacing: 7) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)

            TextField("Word \(number)".lavaLocalized, text: $word)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
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
