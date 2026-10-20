import Combine
import UIKit
import LavaSecAppServices

/// Native operation/credential ownership survives read concealment, but never a
/// replacement visit or account. React receives only the current presentation.
@MainActor
final class LavaAccountBackupSession {
    let id: UUID
    let kind: String
    let accountID: String?
    var setup: BackupSetupSession?
    var restore: BackupRestoreSession?
    private weak var bridge: LavaAppBridge?
    private var subscriptions = Set<AnyCancellable>()
    private(set) var retired = false
    init(flow: LavaAppNativeFlow, bridge: LavaAppBridge) {
        id = flow.id; kind = flow.name; accountID = bridge.model.currentBackupAccountID; self.bridge = bridge
        if kind == "backupSetup" { setup = BackupSetupSession(backup: bridge.model.backup, isCurrent: { [weak self] in self?.isCurrent == true }) }
        if kind == "backupRestore" { restore = BackupRestoreSession(backup: bridge.model.backup, viewModel: bridge.model, isCurrent: { [weak self] in self?.isCurrent == true }) }
        bridge.model.account.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !retired, let bridge = self.bridge, bridge.flow?.id == id,
                      bridge.model.currentBackupAccountID != accountID else { return }
                retire(); bridge.accountBackupSession = nil; bridge.flow = nil; _ = bridge.publish()
            }
        }.store(in: &subscriptions)
        let sources = [setup?.objectWillChange, restore?.objectWillChange].compactMap { $0 }
        for source in sources { source.sink { [weak self] _ in Task { @MainActor [weak self] in guard let self, isCurrent else { return }; _ = bridge.publish() } }.store(in: &subscriptions) }
    }
    var isCurrent: Bool { !retired && bridge?.flow?.id == id && bridge?.model.currentBackupAccountID == accountID }
    var mayAccessCredentials: Bool { isCurrent && bridge?.canReadPresentation(.appSettings) == true }
    var blocksDismissal: Bool { setup?.blocksInteractiveDismiss == true || restore?.isRestoring == true }
    func retire() { guard !retired else { return }; retired = true; subscriptions.removeAll(); setup?.retire(); restore?.retire() }
    func projection() -> [String: Any] {
        guard let bridge else { return [:] }
        let s = setup, r = restore
        let status: Any
        if let r, r.restoreStatus != .choosing { status = ["title": r.restoreStatus.title.lavaLocalized, "detail": r.restoreStatus.detail.lavaLocalized, "tone": r.restoreStatus.tone] }
        else { status = NSNull() }
        let supportsPasskey: Bool; if #available(iOS 18.0, *) { supportsPasskey = true } else { supportsPasskey = false }
        // Account deletion revokes JS reads before dispatch. Deliver its error
        // through the fresh scoped projection, not an alert from the old epoch.
        // pinned: AccountBackupSessionSourceTests.testAccountDeletionFailureUsesTheFreshScopedProjection
        let accountError = kind == "account" && bridge.model.account.accountAuthMessageIsError ? bridge.model.account.accountAuthMessage : nil
        return ["kind": kind, "title": (kind == "account" ? "Account" : s.map { $0.setupComplete ? "Backup is ready" : $0.step.title } ?? "Restore Backup").lavaLocalized,
            "busy": s?.busy ?? r?.isRestoring ?? false,
            "canBack": s?.canBack ?? (r?.review != nil && r?.isRestoring != true), "canClose": s?.canClose ?? (r?.isRestoring != true),
            "success": s?.setupComplete == true || r?.restoreStatus == .success,
            "connections": bridge.model.account.accountConnections.map { ["provider": $0.provider == .apple ? "apple" : "google", "title": $0.email ?? "%@ account".lavaLocalizedFormat($0.provider.displayName)] },
            "deleting": bridge.model.account.isAccountDeletionInProgress,
            "step": s?.step.rawValue ?? "overview", "error": s?.errorMessage ?? accountError ?? "", "copied": s?.consent.copiedRecoveryPhrase ?? false,
            "canContinue": s.map { $0.step == .upload ? $0.canRetryUpload : $0.canAdvance } ?? r?.canContinue ?? false, "supportsPasskey": supportsPasskey,
            "selectedPasskey": s?.selectedPasskeyMode == .withPasskey,
            "saved": s?.consent.savedRecoveryPhrase ?? false, "understands": s?.consent.understandsNoRecovery ?? false,
            "uploading": s?.isUploadingSetup ?? false, "uploadError": s?.uploadError ?? "",
            "mode": r?.mode.rawValue ?? "deviceKey", "modes": BackupRestoreMode.allCases.map { ["id": $0.rawValue, "title": $0.title.lavaLocalized, "unavailable": $0.isUnavailable] },
            "status": status, "review": r?.reviewProjection().map { $0 as Any } ?? NSNull(),
            "resolverConfirmationRequired": r?.review?.plan.requiresResolverConfirmation ?? false, "resolverConfirmed": r?.resolverChangeConfirmed ?? false]
    }
}

extension LavaAppBridge {
    func accountBackupOwner(_ flow: LavaAppNativeFlow) -> LavaAccountBackupSession {
        if let accountBackupSession, accountBackupSession.id == flow.id { return accountBackupSession }
        accountBackupSession?.retire()
        let owner = LavaAccountBackupSession(flow: flow, bridge: self); accountBackupSession = owner; return owner
    }
    func accountBackupProjection(_ flow: LavaAppNativeFlow) -> [String: Any]? {
        guard ["account", "backupSetup", "backupRestore"].contains(flow.name), canReadPresentation(.appSettings) else { return nil }
        let owner = accountBackupOwner(flow)
        guard owner.isCurrent else { return nil }; return owner.projection()
    }
    func retireAccountBackup(_ id: UUID) { guard accountBackupSession?.id == id else { return }; accountBackupSession?.retire(); accountBackupSession = nil }
    func accountBackupBlocksDismissal(_ id: UUID) -> Bool { accountBackupSession?.id == id && accountBackupSession?.blocksDismissal == true }
    func accountBackupCommand(_ input: [String: Any]) async throws -> Any {
        guard let flow, input["id"] as? String == flow.id.uuidString,
              ["account", "backupSetup", "backupRestore"].contains(flow.name), let command = input["command"] as? [String: Any], let action = command["action"] as? String else { throw CommandError("The app screen closed before this action started.") }
        // Close retires the existing account-bound visit without recovering a
        // read grant or creating a credential owner. In-flight work still blocks it.
        // pinned: AccountBackupSessionSourceTests.testCloseRetiresOnlyTheExistingCurrentOwnerBeforeAuthentication
        if action == "close" {
            if let owner = accountBackupSession {
                guard owner.id == flow.id, owner.kind == flow.name, owner.isCurrent else { throw CommandError("The app screen closed before this action started.") }
                guard owner.setup?.canClose != false, owner.restore?.isRestoring != true else { return false }
            }
            retireAccountBackup(flow.id); self.flow = nil
            return NSNull()
        }
        let initiatingAccountID = model.currentBackupAccountID
        try await authorize(.appSettings, "Edit Account settings")
        // Authentication may suspend. Neither a replaced visit nor a new account
        // can inherit the preceding screen's callbacks or prepared review.
        guard self.flow?.id == flow.id, initiatingAccountID == model.currentBackupAccountID, canReadPresentation(.appSettings) else { throw CommandError("Read access changed.") }
        let owner = accountBackupOwner(flow)
        guard owner.isCurrent else { throw CommandError("The app screen closed before this action started.") }
        switch action {
        case "back": owner.setup?.back(); owner.restore?.backToMethods()
        case "account.signOut":
            guard flow.name == "account", !owner.blocksDismissal else { return false }; model.account.signOutAccount(); retireAccountBackup(flow.id); self.flow = nil
        case "account.delete":
            guard flow.name == "account", !owner.blocksDismissal, !model.account.isAccountDeletionInProgress else { return false }
            let deleted = await model.account.deleteAccount()
            if deleted, self.flow?.id == flow.id { retireAccountBackup(flow.id); self.flow = nil }
        case "setup.begin":
            guard let setup = owner.setup, let passkey = command["passkey"] as? Bool else { throw CommandError("Invalid app command.") }; setup.beginSetup(with: passkey ? .withPasskey : .withoutPasskey)
        case "setup.validate": owner.setup?.validatePasskey()
        case "setup.cancelValidation": owner.setup?.cancelPasskeyValidation()
        case "setup.copy": owner.setup?.copyPhrase()
        case "setup.consent":
            guard let saved = command["saved"] as? Bool, let understands = command["understands"] as? Bool else { throw CommandError("Invalid app command.") }; owner.setup?.setConsent(saved: saved, understands: understands)
        case "setup.finish": owner.setup?.advance()
        case "setup.retry": owner.setup?.retryUpload()
        case "restore.mode":
            guard let raw = command["mode"] as? String, let mode = BackupRestoreMode(rawValue: raw) else { throw CommandError("Invalid app command.") }; owner.restore?.setMode(mode)
        case "restore.consent": guard let value = command["value"] as? Bool else { throw CommandError("Invalid app command.") }; owner.restore?.setResolverConfirmed(value)
        case "restore.prepare": owner.restore?.prepareRestore()
        case "restore.confirm": owner.restore?.confirmRestore()
        default: throw CommandError("Invalid app command.")
        }
        return NSNull()
    }
}
