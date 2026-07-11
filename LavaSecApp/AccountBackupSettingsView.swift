import SwiftUI
import LavaSecKit

struct AccountSettingsView: View {
    @EnvironmentObject private var account: AccountController
    @EnvironmentObject private var backup: BackupController
    @EnvironmentObject private var security: SecurityController
    @State private var isShowingAccountSheet = false
    @State private var isSettingUpBackup = false
    @State private var isRestoringBackup = false
    @State private var backupMaintenanceTarget: BackupMaintenanceAction?

    var body: some View {
        SettingsSubpageContent(
            title: "Account & Backup",
            tier: .calm,
            intro: LavaInfoPanel(
                title: backup.encryptedBackupInfoTitle,
                description: "Lava works without an account. Sign in only to back up your settings online — encrypted, so only you can restore them on a new phone.",
                systemImage: "person.crop.circle"
            )
        ) {
            LavaSectionGroup(
                "Account",
                footer: "Account login is only needed for encrypted backup upload, support history, or paid account management."
            ) {
                LavaCondensedList {
                    Button {
                        performAppSettingsMutation(reason: "Edit Account settings") {
                            if account.isAppleAccountConnected {
                                isShowingAccountSheet = true
                            } else {
                                account.beginSignInWithApple()
                            }
                        }
                    } label: {
                        SettingsActionRow(
                            title: account.appleSignInActionTitle,
                            iconTint: LavaStyle.primaryText
                        ) {
                            AppleSignInStatusIcon(
                                isSigningIn: account.isAppleSignInInProgress
                            )
                        }
                        .lavaRow()
                    }
                    .buttonStyle(.plain)
                    .disabled(account.isAccountSignInInProgress)

                    LavaCondensedDivider()

                    Button {
                        performAppSettingsMutation(reason: "Edit Account settings") {
                            if account.isGoogleAccountConnected {
                                isShowingAccountSheet = true
                            } else {
                                account.beginSignInWithGoogle()
                            }
                        }
                    } label: {
                        SettingsActionRow(title: account.googleSignInActionTitle) {
                            if account.isGoogleSignInInProgress {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                GoogleSignInIcon()
                            }
                        }
                        .lavaRow()
                    }
                    .buttonStyle(.plain)
                    .disabled(account.isAccountSignInInProgress)
                }
            }
            .sheet(isPresented: $isShowingAccountSheet) {
                AccountSheet()
                    .environmentObject(account)
            }
            // The backup setup/restore flows present as full bottom sheets (like
            // Import filters) so they cover the tab bar and put their actions on the
            // sheet's footer bar.
            .sheet(isPresented: $isSettingUpBackup) {
                BackupSetupView()
                    .environmentObject(backup)
            }
            .sheet(isPresented: $isRestoringBackup) {
                BackupRestoreView()
                    .environmentObject(backup)
            }

            LavaSectionGroup("Encrypted Backup") {
                VStack(alignment: .leading, spacing: 10) {
                    LavaCondensedList {
                        if backup.isEncryptedBackupConfigured {
                            Button {
                                Task {
                                    guard await security.requireAuthentication(
                                        for: .appSettings,
                                        reason: "Back up settings"
                                    ) else {
                                        return
                                    }

                                    await backup.backUpNow()
                                }
                            } label: {
                                SettingsActionRow(title: backup.isBackingUpNow ? "Backing Up" : "Back Up Now") {
                                    if backup.isBackingUpNow {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "icloud.and.arrow.up.fill")
                                            .font(.title3.weight(.semibold))
                                    }
                                }
                                .lavaRow()
                            }
                            .buttonStyle(.plain)
                            .disabled(!account.isAccountSignedIn || backup.isBackingUpNow || backup.isBackupMaintenanceInProgress)
                            .opacity(account.isAccountSignedIn ? 1 : 0.45)
                        } else {
                            Button {
                                isSettingUpBackup = true
                            } label: {
                                SettingsActionRow(title: "Set Up Encrypted Backup") {
                                    Image(systemName: "key.fill")
                                        .font(.title3.weight(.semibold))
                                }
                                .lavaRow()
                            }
                            .buttonStyle(.plain)
                            .disabled(!account.isAccountSignedIn)
                            .opacity(account.isAccountSignedIn ? 1 : 0.45)
                        }

                        LavaCondensedDivider()

                        Button {
                            isRestoringBackup = true
                        } label: {
                            SettingsActionRow(title: "Restore Backup") {
                                Image(systemName: "icloud.and.arrow.down.fill")
                                    .font(.title3.weight(.semibold))
                            }
                            .lavaRow()
                        }
                        .buttonStyle(.plain)
                        .disabled(!account.isAccountSignedIn)
                        .opacity(account.isAccountSignedIn ? 1 : 0.45)
                    }

                    BackupOptionControl(
                        title: "Automatic Backup",
                        detail: "Lava waits 30 minutes after your last settings change before it tries an automatic upload.",
                        isOn: automaticBackupBinding
                    )
                    .disabled(!backup.isEncryptedBackupConfigured)
                    .opacity(backup.isEncryptedBackupConfigured ? 1 : 0.45)

                    if backup.isEncryptedBackupConfigured {
                        VStack(alignment: .leading, spacing: 8) {
                            LavaCondensedList {
                                backupMaintenanceButton(.clear)

                                LavaCondensedDivider()

                                backupMaintenanceButton(.disable)
                            }

                            Text("Delete online backup copy removes the server copy but keeps backups on. Turn off & delete backup stops them too. Either way, it's gone for good.".lavaLocalized)
                                .lavaQuietNoteText()
                        }
                    }
                }
            }
        }
        .lavaConfirmationAlert { host in
            host.alert(
                backupMaintenanceTarget?.title.lavaLocalized ?? "",
                isPresented: backupMaintenanceConfirmationBinding,
                presenting: backupMaintenanceTarget
            ) { target in
                Button("Cancel", role: .cancel) {}
                Button(target.actionTitle.lavaLocalized, role: .destructive) {
                    performBackupMaintenance(target)
                }
            } message: { target in
                Text(target.message.lavaLocalized)
            }
        }
    }

    private func backupMaintenanceButton(_ target: BackupMaintenanceAction) -> some View {
        Button(role: .destructive) {
            backupMaintenanceTarget = target
        } label: {
            SettingsActionRow(title: target.buttonTitle, iconTint: .red, titleTint: .red) {
                Image(systemName: "trash")
                    .font(.title3.weight(.semibold))
            }
            .lavaRow()
        }
        .buttonStyle(.plain)
        .disabled(backup.isBackupMaintenanceInProgress || backup.isBackingUpNow)
    }

    private var backupMaintenanceConfirmationBinding: Binding<Bool> {
        Binding {
            backupMaintenanceTarget != nil
        } set: { isPresented in
            if !isPresented {
                backupMaintenanceTarget = nil
            }
        }
    }

    private func performBackupMaintenance(_ target: BackupMaintenanceAction) {
        Task {
            guard await security.requireAuthentication(for: .appSettings, reason: target.authReason) else {
                return
            }

            switch target {
            case .clear:
                await backup.clearEncryptedBackup()
            case .disable:
                await backup.disableEncryptedBackup()
            }
        }
    }

    private var automaticBackupBinding: Binding<Bool> {
        Binding {
            backup.isAutomaticBackupEnabled
        } set: { isEnabled in
            performAppSettingsMutation(reason: "Edit backup settings") {
                backup.setAutomaticBackupEnabled(isEnabled)
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

private enum BackupMaintenanceAction: Identifiable {
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

private struct BackupOptionControl: View {
    let title: String
    let detail: String
    let isOn: Binding<Bool>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(title.lavaLocalized, isOn: isOn)
                .font(.headline)
                .tint(LavaStyle.safeGreen)
                .lavaControlRowCard()

            Text(detail.lavaLocalized)
                .lavaQuietNoteText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AppleSignInStatusIcon: View {
    let isSigningIn: Bool

    var body: some View {
        if isSigningIn {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: "apple.logo")
                .font(.title3.weight(.semibold))
        }
    }
}

private struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: AccountController
    @EnvironmentObject private var security: SecurityController
    @State private var isConfirmingAccountDeletion = false

    var body: some View {
        let accountConnections = account.accountConnections

        NavigationStack {
            LavaSheetScaffold(spacing: 14, scrolls: false) {
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
            }
        }
        .presentationDetents([.height(accountSheetHeight)])
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

    private var accountSheetHeight: CGFloat {
        account.accountConnections.count > 1 ? 332 : 288
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

            Text(connection.email ?? "\(connection.provider.displayName) account")
                .font(.headline)
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
