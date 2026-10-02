import SwiftUI
import LavaSecKit

enum BackupMaintenanceAction: Identifiable {
    case clear
    case disable

    var id: String {
        switch self {
        case .clear:
            return "clear"
        case .disable:
            return "disable"
        }
    }

    var buttonTitle: String {
        switch self {
        case .clear:
            return "Delete online backup copy"
        case .disable:
            return "Turn off & delete backup"
        }
    }

    var title: String {
        switch self {
        case .clear:
            return "Delete online backup copy?"
        case .disable:
            return "Turn off & delete backup?"
        }
    }

    var actionTitle: String {
        switch self {
        case .clear:
            return "Delete online backup copy"
        case .disable:
            return "Turn off & delete backup"
        }
    }

    var message: String {
        switch self {
        case .clear:
            return "Permanently deletes your account's encrypted backup — this can't be undone. Backup stays on, and a fresh copy uploads next time."
        case .disable:
            return "Turns off backup on this device and permanently deletes your account's copy. This can't be undone — you can set up a new backup later."
        }
    }

    var authReason: String {
        switch self {
        case .clear:
            return "Clear encrypted backup"
        case .disable:
            return "Disable encrypted backup"
        }
    }
}

struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: AccountController
    @EnvironmentObject private var security: SecurityController
    @State private var isConfirmingAccountDeletion = false

    var body: some View {
        let accountConnections = account.accountConnections

        NavigationStack {
            LavaSheetScaffold(spacing: 14) {
                LavaCondensedList {
                    ForEach(Array(accountConnections.enumerated()), id: \.element.provider) { index, connection in
                        AccountConnectionRow(connection: connection)
                            .lavaRow()

                        if index < accountConnections.count - 1 {
                            LavaCondensedDivider()
                        }
                    }

                    LavaCondensedDivider()

                    Button {
                        performAppSettingsMutation(reason: "Edit Account settings") {
                            account.signOutAccount()
                            dismiss()
                        }
                    } label: {
                        SettingsActionRow(title: "Sign out of all accounts", iconTint: LavaStyle.secondaryText) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.title3.weight(.semibold))
                        }
                        .lavaRow()
                    }
                    .buttonStyle(.plain)

                    LavaCondensedDivider()

                    Button(role: .destructive) {
                        performAppSettingsMutation(reason: "Edit Account settings") {
                            isConfirmingAccountDeletion = true
                        }
                    } label: {
                        SettingsActionRow(
                            title: account.isAccountDeletionInProgress ? "Deleting account" : "Delete my Lava account",
                            iconTint: .red,
                            titleTint: .red
                        ) {
                            if account.isAccountDeletionInProgress {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "trash")
                                    .font(.title3.weight(.semibold))
                            }
                        }
                        .lavaRow()
                    }
                    .buttonStyle(.plain)
                    .disabled(account.isAccountDeletionInProgress)
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close", role: .close, action: dismiss.callAsFunction)
                }
                .lavaToolbarChrome()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .lavaConfirmationAlert { host in
            host.alert(
                "Delete your Lava account?",
                isPresented: $isConfirmingAccountDeletion
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task {
                        if await account.deleteAccount() {
                            dismiss()
                        }
                    }
                }
            } message: {
                Text("This deletes the signed-in Lava account and its encrypted backup from Lava's servers. Local protection settings stay on this device.")
            }
        }
    }

    private func performAppSettingsMutation(reason: String, action: @escaping @MainActor () -> Void) {
        Task {
            guard await security.requireAuthentication(for: .appSettings, reason: reason) else {
                return
            }

            action()
        }
    }
}

private struct AccountConnectionRow: View {
    let connection: AccountAuthConnection

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 28, height: 28)

            Text(connection.email ?? "%@ account".lavaLocalizedFormat(connection.provider.displayName))
                .font(LavaTypography.rowTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        switch connection.provider {
        case .apple:
            Image(systemName: "apple.logo")
                .font(.title3.weight(.semibold))
                .foregroundStyle(LavaStyle.primaryText)
        case .google:
            GoogleSignInIcon()
        }
    }
}

private struct GoogleSignInIcon: View {
    var body: some View {
        Image("GoogleSignInG")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: 23, height: 23)
            .accessibilityHidden(true)
    }
}
