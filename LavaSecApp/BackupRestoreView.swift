import LavaSecKit
import LavaSecAppServices
import Combine
import Foundation

/// The prepared review and every unlock secret remain native, bound to one visit.
@MainActor
final class BackupRestoreSession: ObservableObject {
    @Published private var recoveryInput = BackupRecoveryPhraseInput()
    var recoveryPhrasePaste: String { recoveryInput.pastedPhrase }
    var recoveryWords: [String] { recoveryInput.words }
    @Published private(set) var mode: BackupRestoreMode = .deviceKey
    @Published private(set) var restoreStatus: RestoreStatus = .choosing
    @Published private(set) var isRestoring = false
    @Published private(set) var review: BackupRestoreReview?
    @Published private(set) var resolverChangeConfirmed = false
    private let backup: BackupController
    private let viewModel: AppViewModel
    private let isCurrent: () -> Bool
    private var restoreTask: Task<Void, Never>?
    private var retired = false
    init(backup: BackupController, viewModel: AppViewModel, isCurrent: @escaping () -> Bool) {
        self.backup = backup; self.viewModel = viewModel; self.isCurrent = isCurrent
    }
    var restoreSecret: String {
        guard mode == .recoveryCode else { return "" }
        return recoveryInput.secret
    }
    var canContinue: Bool { !isRestoring && (review.map { !$0.plan.requiresResolverConfirmation || resolverChangeConfirmed } ?? (!mode.isUnavailable && (!mode.requiresTypedSecret || !restoreSecret.isEmpty))) }
    func retire() { guard !retired else { return }; retired = true; restoreTask?.cancel(); if let review { backup.discardPreparedBackupRestore(id: review.id) }; review = nil; clearSecret() }
    func setMode(_ value: BackupRestoreMode) { guard !isRestoring, review == nil else { return }; mode = value; restoreStatus = .choosing }
    func setResolverConfirmed(_ value: Bool) { guard !isRestoring, review != nil else { return }; resolverChangeConfirmed = value }
    func setPastedPhrase(_ value: String) { guard !isRestoring, mode == .recoveryCode, isCurrent() else { return }; recoveryInput.setPastedPhrase(value) }
    func setWord(_ value: String, at index: Int) { guard !isRestoring, mode == .recoveryCode, isCurrent() else { return }; recoveryInput.setWord(value, at: index) }
    func backToMethods() { guard !isRestoring else { return }; if let review { backup.discardPreparedBackupRestore(id: review.id) }; review = nil; resolverChangeConfirmed = false; restoreStatus = .choosing }
    func prepareRestore() {
        guard canContinue, review == nil, !retired, isCurrent() else { return }
        isRestoring = true; restoreStatus = .restoring
        let unlockSecret = restoreSecret, unlockMode = mode
        restoreTask = Task { [weak self] in
            guard let self else { return }; defer { if !retired { isRestoring = false } }
            do {
                let prepared = try await backup.prepareEncryptedBackupRestore(secret: unlockSecret, mode: unlockMode)
                guard !Task.isCancelled, !retired, isCurrent() else { backup.discardPreparedBackupRestore(id: prepared.id); throw CancellationError() }
                review = prepared; clearSecret(); resolverChangeConfirmed = false; restoreStatus = .reviewing
                LavaAccessibilityAnnouncer.announce(RestoreStatus.reviewing.title.lavaLocalized)
            } catch { guard !retired, isCurrent() else { return }; if error is CancellationError { restoreStatus = .cancelled } else { reportRestoreFailure(error) } }
        }
    }
    func confirmRestore() {
        guard canContinue, let review, !retired, isCurrent() else { return }
        isRestoring = true
        let feedbackID = LavaFeedbackCoordinator.shared.begin("backup.restore")
        restoreTask = Task { [weak self] in
            guard let self else { return }; defer { if !retired { isRestoring = false } }
            do {
                let completion = try await backup.confirmPreparedBackupRestore(id: review.id, resolverChangeConfirmed: resolverChangeConfirmed)
                backup.discardPreparedBackupRestore(id: review.id)
                guard !Task.isCancelled, !retired, isCurrent() else { LavaFeedbackCoordinator.shared.finish("backup.restore", feedbackID, .failed, cancelled: true); return }
                self.review = nil; restoreStatus = completion == .complete ? .success : .restoredNeedsAttention
                LavaFeedbackCoordinator.shared.finish("backup.restore", feedbackID, completion == .complete ? .succeeded : .attentionRequired)
                LavaAccessibilityAnnouncer.announce(restoreStatus.title.lavaLocalized + " " + restoreStatus.detail.lavaLocalized)
            } catch {
                backup.discardPreparedBackupRestore(id: review.id)
                guard !retired, isCurrent() else { LavaFeedbackCoordinator.shared.finish("backup.restore", feedbackID, .failed, cancelled: true); return }
                self.review = nil; reportRestoreFailure(error)
                let cancelled: Bool; if case .cancelled = Self.failureStatus(for: error) { cancelled = true } else { cancelled = false }
                LavaFeedbackCoordinator.shared.finish("backup.restore", feedbackID, .failed, cancelled: cancelled)
            }
        }
    }
    private func clearSecret() { recoveryInput = BackupRecoveryPhraseInput() }
    private func reportRestoreFailure(_ error: Error) { restoreStatus = Self.failureStatus(for: error); LavaAccessibilityAnnouncer.announce(restoreStatus.title.lavaLocalized + " " + restoreStatus.detail.lavaLocalized) }
    private static func failureStatus(for error: Error) -> RestoreStatus {
        if let passkeyError = error as? BackupPasskeyError, case .canceled = passkeyError { return .cancelled }
        if let reviewError = error as? BackupRestorePlanError {
            switch reviewError {
            case .invalidResolver(let message): return .failed(reason: message)
            case .customDNSRequiresPlus: return .failed(reason: "This backup uses custom DNS, which requires Lava Security Plus.".lavaLocalized)
            case .staleReview: return .failed(reason: "Your settings changed. Review the backup again.".lavaLocalized)
            case .resolverConfirmationRequired: return .failed(reason: "Confirm the DNS changes before restoring.".lavaLocalized)
            }
        }
        return .failed(reason: error.localizedDescription)
    }
    func reviewProjection() -> [[String: Any]]? {
        guard let plan = review?.plan else { return nil }
        func row(_ title: String, _ before: String, _ after: String) -> [String: Any] { ["title": title.lavaLocalized, "before": before, "after": after] }
        func state(_ value: Bool) -> String { (value ? "On" : "Off").lavaLocalized }
        func resolver(_ config: AppConfiguration, fallback: Bool = false) -> String { fallback ? LavaStrings.resolverName(config.fallbackResolverPreset, customName: config.fallbackCustomResolverName) : LavaStrings.resolverName(config.resolverPreset, customName: config.customResolverName) }
        let a = plan.previousConfiguration, b = plan.configuration
        var rows = [row("Protection on this device", state(a.protectionEnabled), state(b.protectionEnabled)), row("Primary DNS", resolver(a), resolver(b)), row("Fallback DNS", resolver(a, fallback: true), resolver(b, fallback: true)), row("Fallback to Device DNS", state(a.fallbackToDeviceDNS), state(b.fallbackToDeviceDNS)), row("Fallback to alternative DNS", state(a.usesEncryptedDeviceDNSFallback), state(b.usesEncryptedDeviceDNSFallback)), row("Saved custom DNS", savedCustomDNS(a), savedCustomDNS(b)), row("Filtering Counts", state(a.keepFilteringCounts), state(b.keepFilteringCounts)), row("Domain diagnostics", state(a.keepDomainDiagnostics), state(b.keepDomainDiagnostics)), row("Network Activity", state(a.keepNetworkActivity), state(b.keepNetworkActivity)), row("Lava Guard progress", state(a.keepLavaGuardProgress), state(b.keepLavaGuardProgress)), row("Unlocked Lava Guards", unlocks(a.lavaGuardUnlocks), unlocks(b.lavaGuardUnlocks)), row("Active filter", plan.previousLibrary.activeFilter.name, plan.library.activeFilter.name)]
        rows.append(row("Filters", orderedFilters(plan.previousLibrary), orderedFilters(plan.library)))
        var sections: [[String: Any]] = [["id": "settings", "rows": rows, "notes": [[String: String]]()]]
        for (index, change) in plan.filterChanges.enumerated() {
            var filterRows = [row("Filters", change.before?.name ?? "None yet".lavaLocalized, change.after?.name ?? "None yet".lavaLocalized), row("Blocklists", String(change.before?.enabledBlocklistIDs.count ?? 0), String(change.after?.enabledBlocklistIDs.count ?? 0))]
            if !change.removedBlocklistIDs.isEmpty { filterRows.append(row("Removed", change.removedBlocklistIDs.map { blocklistName(for: $0, in: change.before) }.joined(separator: ", "), "None yet".lavaLocalized)) }
            if !change.addedBlocklistIDs.isEmpty { filterRows.append(row("Added", "None yet".lavaLocalized, change.addedBlocklistIDs.map { blocklistName(for: $0, in: change.after) }.joined(separator: ", "))) }
            var notes: [[String: String]] = []
            for (title, before, after, added, removed) in [("Blocked domains", change.before?.blockedDomains ?? [], change.after?.blockedDomains ?? [], change.selectionDiff.addedBlockedDomains, change.selectionDiff.removedBlockedDomains), ("Allowed domains", change.before?.allowedDomains ?? [], change.after?.allowedDomains ?? [], change.selectionDiff.addedAllowedDomains, change.selectionDiff.removedAllowedDomains)] {
                var domainRow = row(title, String(before.count), String(after.count))
                var domainNotes: [String] = []
                if !added.isEmpty { domainNotes.append("%@: %@".lavaLocalizedFormat("Added".lavaLocalized, domains(Set(added)))) }
                if !removed.isEmpty { domainNotes.append("%@: %@".lavaLocalizedFormat("Removed".lavaLocalized, domains(Set(removed)))) }
                domainRow["notes"] = domainNotes; filterRows.append(domainRow)
            }
            filterRows.append(row("Custom blocklists", customSources(change.before?.customBlocklists ?? []), customSources(change.after?.customBlocklists ?? [])))
            if !change.changedCustomContentVersionIDs.isEmpty {
                notes.append(["text": "Saved list content will change for:".lavaLocalized + " " + change.changedCustomContentVersionIDs.map { blocklistName(for: $0, in: change.after) }.joined(separator: ", "), "role": "contentChange"])
                notes.append(["text": "Cached rules may be replaced or unavailable.".lavaLocalized, "role": "cacheWarning"])
            }
            sections.append(["id": "filter-\(index)", "rows": filterRows, "notes": notes])
        }
        return sections
    }
    private func orderedFilters(_ library: FilterLibrary) -> String { library.filters.enumerated().map { "\($0.offset + 1). \($0.element.name)" }.joined(separator: "\n") }
    private func blocklistName(for id: String, in filter: Filter?) -> String { filter?.customBlocklists.first(where: { $0.id == id })?.displayName ?? viewModel.blocklistName(for: id) }
    private func domains(_ values: Set<String>) -> String { String(values.count) + ": " + values.sorted().joined(separator: ", ") }
    private func unlocks(_ ledger: LavaGuardAchievementLedger) -> String { let names = ledger.records.map { GuardianShieldStyle(rawValue: $0.guardID)?.displayName.lavaLocalized ?? $0.guardID }.sorted(); return String(names.count) + ": " + names.joined(separator: ", ") }
    private func customSources(_ sources: [CustomBlocklistSource]) -> String { sources.map { $0.displayName + " (" + $0.sourceURL.absoluteString + "; " + $0.parseFormat.rawValue + ")" }.joined(separator: "\n") }
    private func savedCustomDNS(_ c: AppConfiguration) -> String { let primary = [c.customResolverName, c.customResolverAddress, c.customResolverSecondaryAddress].compactMap { $0 }.joined(separator: ", "); let fallback = [c.fallbackCustomResolverName, c.fallbackCustomResolverAddress, c.fallbackCustomResolverSecondaryAddress].compactMap { $0 }.joined(separator: ", "); return "%@: %@".lavaLocalizedFormat("Primary DNS".lavaLocalized, primary) + "\n" + "%@: %@".lavaLocalizedFormat("Fallback DNS".lavaLocalized, fallback) }
}

enum RestoreStatus: Equatable {
    case choosing, restoring, reviewing, success, restoredNeedsAttention, failed(reason: String), cancelled
    var title: String { switch self { case .choosing: "Choose a method"; case .restoring: "Restoring…"; case .reviewing: "Review Backup"; case .success: "Restored successfully"; case .restoredNeedsAttention: "Backup restored"; case .failed: "Restore failed"; case .cancelled: "Restore cancelled" } }
    var detail: String { switch self { case .choosing: "Unlock happens on this device."; case .restoring: "Unlocking on this device…"; case .reviewing, .cancelled: "No changes were made."; case .success: "Lava will use the restored settings on this device."; case .restoredNeedsAttention: "Filtering could not update."; case .failed(let reason): reason } }
    var tone: String { switch self { case .failed, .restoredNeedsAttention: "warning"; case .cancelled: "neutral"; default: "green" } }
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
