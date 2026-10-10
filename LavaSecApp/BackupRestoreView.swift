import LavaSecKit
import LavaSecAppServices
import SwiftUI

struct BackupRestoreView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var backup: BackupController
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var recoveryPhrasePaste = ""
    @State private var recoveryWords = Array(repeating: "", count: BackupRecoveryPhrase.wordCount)
    @State private var mode: BackupRestoreMode = .deviceKey
    @State private var restoreStatus: RestoreStatus = .choosing
    @State private var isRestoring = false
    @State private var review: BackupRestoreReview?
    @State private var resolverChangeConfirmed = false
    @State private var restoreTask: Task<Void, Never>?
    @FocusState private var focusedWord: Int?

    var body: some View {
        if restoreStatus == .success {
            LavaSuccessScreen(title: RestoreStatus.success.title,
                              message: RestoreStatus.success.detail,
                              done: dismiss.callAsFunction)
        } else {
            restorePage
        }
    }

    private var restorePage: some View {
        LavaTaskSheet(title: "Restore Backup", back: sheetBackAction,
                      actionsDisabled: isRestoring, close: dismiss.callAsFunction) {
            LavaInfoPanel(
                title: "Bring your settings back",
                description: "Unlock your backup, review its changes, then restore.",
                systemImage: "icloud.and.arrow.down"
            )

            if let review {
                restoreReview(review.plan)
            } else {
                LavaSectionGroup(
                    "Unlock method"
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        if restoreStatus != .choosing { RestoreStatusPanel(status: restoreStatus) }

                        LavaPlainCard {
                            VStack(alignment: .leading, spacing: 14) {
                                LavaSegmentedPicker(label: "Unlock method", options: BackupRestoreMode.allCases,
                                                    selection: $mode) { $0.title.lavaLocalized }
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
                .disabled(isRestoring)
            }
        } footer: {
            Button {
                if let review {
                    confirmRestore(review)
                } else {
                    prepareRestore()
                }
            } label: {
                Label((isRestoring ? "Restoring" : (review == nil ? "Review Backup" : "Restore Backup")).lavaLocalized,
                      systemImage: "icloud.and.arrow.down")
            }
            .buttonStyle(LavaStandaloneActionButtonStyle())
            .disabled(isRestoring || (review.map { $0.plan.requiresResolverConfirmation && !resolverChangeConfirmed }
                ?? (mode.isUnavailable || (mode.requiresTypedSecret && restoreSecret.isEmpty))))
        }
        .lavaTier(.calm)
        .interactiveDismissDisabled(isRestoring)
        .onDisappear {
            restoreTask?.cancel()
            if let review { backup.discardPreparedBackupRestore(id: review.id) }
        }
    }

    private func restoreReview(_ plan: BackupRestorePlan) -> some View {
        LavaSectionGroup(
            "Review Backup",
            footer: "Restoring replaces your current filters and settings."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                RestoreStatusPanel(status: restoreStatus)
                Text("Current → Backup".lavaLocalized).font(.caption).foregroundStyle(.secondary)
                reviewRow("Protection on this device", before: state(plan.previousConfiguration.protectionEnabled),
                          after: state(plan.configuration.protectionEnabled))
                reviewRow("Primary DNS", before: LavaStrings.resolverName(plan.previousConfiguration.resolverPreset, customName: plan.previousConfiguration.customResolverName),
                          after: LavaStrings.resolverName(plan.configuration.resolverPreset, customName: plan.configuration.customResolverName))
                reviewRow("Fallback DNS", before: LavaStrings.resolverName(plan.previousConfiguration.fallbackResolverPreset, customName: plan.previousConfiguration.fallbackCustomResolverName),
                          after: LavaStrings.resolverName(plan.configuration.fallbackResolverPreset, customName: plan.configuration.fallbackCustomResolverName))
                reviewRow("Fallback to Device DNS", before: state(plan.previousConfiguration.fallbackToDeviceDNS),
                          after: state(plan.configuration.fallbackToDeviceDNS))
                reviewRow("Fallback to alternative DNS", before: state(plan.previousConfiguration.usesEncryptedDeviceDNSFallback),
                          after: state(plan.configuration.usesEncryptedDeviceDNSFallback))
                reviewRow("Saved custom DNS", before: savedCustomDNS(plan.previousConfiguration),
                          after: savedCustomDNS(plan.configuration))
                reviewRow("Filtering Counts", before: state(plan.previousConfiguration.keepFilteringCounts),
                          after: state(plan.configuration.keepFilteringCounts))
                reviewRow("Domain diagnostics", before: state(plan.previousConfiguration.keepDomainDiagnostics),
                          after: state(plan.configuration.keepDomainDiagnostics))
                reviewRow("Network Activity", before: state(plan.previousConfiguration.keepNetworkActivity),
                          after: state(plan.configuration.keepNetworkActivity))
                reviewRow("Lava Guard progress", before: state(plan.previousConfiguration.keepLavaGuardProgress),
                          after: state(plan.configuration.keepLavaGuardProgress))
                reviewRow("Unlocked Lava Guards", before: unlocks(plan.previousConfiguration.lavaGuardUnlocks),
                          after: unlocks(plan.configuration.lavaGuardUnlocks))
                reviewRow("Active filter", before: plan.previousLibrary.activeFilter.name,
                          after: plan.library.activeFilter.name)
                reviewRow("Filters", before: orderedFilters(plan.previousLibrary), after: orderedFilters(plan.library))
                ForEach(Array(plan.filterChanges.enumerated()), id: \.offset) { _, change in
                    filterReview(change)
                }
                if plan.requiresResolverConfirmation {
                    Toggle("I confirm these DNS changes".lavaLocalized, isOn: $resolverChangeConfirmed)
                        .disabled(isRestoring)
                }
            }
        }
    }

    private func orderedFilters(_ library: FilterLibrary) -> String {
        library.filters.enumerated().map { "\($0.offset + 1). \($0.element.name)" }.joined(separator: "\n")
    }

    private func reviewRow(_ title: String, before: String, after: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.lavaLocalized).font(.subheadline.weight(.semibold))
            Text(before + " → " + after).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func filterReview(_ change: FilterReplacementSummary) -> some View {
        LavaPlainCard {
            VStack(alignment: .leading, spacing: 8) {
                reviewRow("Filters", before: change.before?.name ?? "None yet".lavaLocalized,
                          after: change.after?.name ?? "None yet".lavaLocalized)
                reviewRow("Blocklists", before: String(change.before?.enabledBlocklistIDs.count ?? 0),
                          after: String(change.after?.enabledBlocklistIDs.count ?? 0))
                if !change.removedBlocklistIDs.isEmpty {
                    reviewRow("Removed", before: change.removedBlocklistIDs.map { blocklistName(for: $0, in: change.before) }.joined(separator: ", "),
                              after: "None yet".lavaLocalized)
                }
                if !change.addedBlocklistIDs.isEmpty {
                    reviewRow("Added", before: "None yet".lavaLocalized,
                              after: change.addedBlocklistIDs.map { blocklistName(for: $0, in: change.after) }.joined(separator: ", "))
                }
                domainReview("Blocked domains", before: change.before?.blockedDomains ?? [],
                             after: change.after?.blockedDomains ?? [],
                             added: change.selectionDiff.addedBlockedDomains, removed: change.selectionDiff.removedBlockedDomains)
                domainReview("Allowed domains", before: change.before?.allowedDomains ?? [],
                             after: change.after?.allowedDomains ?? [],
                             added: change.selectionDiff.addedAllowedDomains, removed: change.selectionDiff.removedAllowedDomains)
                reviewRow("Custom blocklists", before: customSources(change.before?.customBlocklists ?? []),
                          after: customSources(change.after?.customBlocklists ?? []))
                if !change.changedCustomContentVersionIDs.isEmpty {
                    Text("Saved list content will change for:".lavaLocalized + " " +
                         change.changedCustomContentVersionIDs.map { blocklistName(for: $0, in: change.after) }.joined(separator: ", "))
                        .font(.subheadline)
                    Text("Cached rules may be replaced or unavailable.".lavaLocalized).lavaQuietNoteText()
                }
            }
        }
    }

    private func domainReview(_ title: String, before: Set<String>, after: Set<String>,
                              added: [String], removed: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            reviewRow(title, before: String(before.count), after: String(after.count))
            if !added.isEmpty {
                Text("%@: %@".lavaLocalizedFormat("Added".lavaLocalized, domains(Set(added)))).font(.subheadline)
            }
            if !removed.isEmpty {
                Text("%@: %@".lavaLocalizedFormat("Removed".lavaLocalized, domains(Set(removed)))).font(.subheadline)
            }
        }
    }

    private func blocklistName(for id: String, in filter: Filter?) -> String {
        filter?.customBlocklists.first(where: { $0.id == id })?.displayName
            ?? viewModel.blocklistName(for: id)
    }

    private func domains(_ values: Set<String>) -> String {
        String(values.count) + ": " + values.sorted().joined(separator: ", ")
    }

    private func unlocks(_ ledger: LavaGuardAchievementLedger) -> String {
        let names = ledger.records.map { record in
            GuardianShieldStyle(rawValue: record.guardID)?.displayName.lavaLocalized ?? record.guardID
        }.sorted()
        return String(names.count) + ": " + names.joined(separator: ", ")
    }

    private func customSources(_ sources: [CustomBlocklistSource]) -> String {
        sources.map { $0.displayName + " (" + $0.sourceURL.absoluteString + "; " + $0.parseFormat.rawValue + ")" }.joined(separator: "\n")
    }

    private func savedCustomDNS(_ configuration: AppConfiguration) -> String {
        let primary = [configuration.customResolverName, configuration.customResolverAddress, configuration.customResolverSecondaryAddress].compactMap { $0 }.joined(separator: ", ")
        let fallback = [configuration.fallbackCustomResolverName, configuration.fallbackCustomResolverAddress, configuration.fallbackCustomResolverSecondaryAddress].compactMap { $0 }.joined(separator: ", ")
        return "%@: %@".lavaLocalizedFormat("Primary DNS".lavaLocalized, primary) + "\n"
            + "%@: %@".lavaLocalizedFormat("Fallback DNS".lavaLocalized, fallback)
    }

    private func state(_ value: Bool) -> String { (value ? "On" : "Off").lavaLocalized }

    private var sheetBackAction: (() -> Void)? {
        guard review != nil else { return nil }
        return { backToMethods() }
    }

    private func backToMethods() {
        guard !isRestoring else { return }
        if let review { backup.discardPreparedBackupRestore(id: review.id) }
        review = nil
        resolverChangeConfirmed = false
        restoreStatus = .choosing
    }

    private var recoveryPhraseFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use only a recovery phrase you saved yourself.".lavaLocalized).lavaQuietNoteText()
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

    private func prepareRestore() {
        guard !isRestoring else { return }
        isRestoring = true
        restoreStatus = .restoring
        let unlockSecret = restoreSecret
        let unlockMode = mode
        restoreTask = Task {
            defer { isRestoring = false }
            do {
                let prepared = try await backup.prepareEncryptedBackupRestore(secret: unlockSecret, mode: unlockMode)
                guard !Task.isCancelled else {
                    backup.discardPreparedBackupRestore(id: prepared.id)
                    throw CancellationError()
                }
                review = prepared
                recoveryPhrasePaste = ""
                recoveryWords = Array(repeating: "", count: BackupRecoveryPhrase.wordCount)
                resolverChangeConfirmed = false
                restoreStatus = .reviewing
                LavaAccessibilityAnnouncer.announce(RestoreStatus.reviewing.title.lavaLocalized)
            } catch {
                if error is CancellationError { restoreStatus = .cancelled }
                else { reportRestoreFailure(error) }
            }
        }
    }

    private func confirmRestore(_ review: BackupRestoreReview) {
        guard !isRestoring else { return }
        isRestoring = true
        let feedbackID = LavaFeedbackCoordinator.shared.begin("backup.restore")
        restoreTask = Task {
            defer { isRestoring = false }
            do {
                let completion = try await backup.confirmPreparedBackupRestore(id: review.id, resolverChangeConfirmed: resolverChangeConfirmed)
                backup.discardPreparedBackupRestore(id: review.id)
                self.review = nil
                restoreStatus = completion == .complete ? .success : .restoredNeedsAttention
                LavaFeedbackCoordinator.shared.finish("backup.restore", feedbackID,
                    completion == .complete ? .succeeded : .attentionRequired)
                LavaAccessibilityAnnouncer.announce(
                    restoreStatus.title.lavaLocalized + " " + restoreStatus.detail.lavaLocalized
                )
            } catch {
                backup.discardPreparedBackupRestore(id: review.id)
                self.review = nil
                reportRestoreFailure(error)
                let cancelled: Bool
                if case .cancelled = Self.failureStatus(for: error) { cancelled = true } else { cancelled = false }
                LavaFeedbackCoordinator.shared.finish("backup.restore", feedbackID, .failed, cancelled: cancelled)
            }
        }
    }

    private func reportRestoreFailure(_ error: Error) {
        let status = Self.failureStatus(for: error)
        restoreStatus = status
        LavaAccessibilityAnnouncer.announce(status.title.lavaLocalized + " " + status.detail.lavaLocalized)
    }

    // A short, mapped reason — not the raw error dump. EncryptedBackupError and
    // BackupPasskeyError are already friendly one-liners; a user-cancelled passkey
    // sheet is surfaced as a calm "cancelled", not a failure.
    private static func failureStatus(for error: Error) -> RestoreStatus {
        if let passkeyError = error as? BackupPasskeyError, case .canceled = passkeyError {
            return .cancelled
        }

        if let reviewError = error as? BackupRestorePlanError {
            switch reviewError {
            case .invalidResolver(let message): return .failed(reason: message)
            case .customDNSRequiresPlus:
                return .failed(reason: "This backup uses custom DNS, which requires Lava Security Plus.".lavaLocalized)
            case .staleReview:
                return .failed(reason: "Your settings changed. Review the backup again.".lavaLocalized)
            case .resolverConfirmationRequired:
                return .failed(reason: "Confirm the DNS changes before restoring.".lavaLocalized)
            }
        }
        return .failed(reason: error.localizedDescription)
    }
}

private enum RestoreStatus: Equatable {
    case choosing
    case restoring
    case reviewing
    case success
    case restoredNeedsAttention
    case failed(reason: String)
    case cancelled

    var title: String {
        switch self {
        case .choosing:
            "Choose a method"
        case .restoring:
            "Restoring…"
        case .reviewing:
            "Review Backup"
        case .success:
            "Restored successfully"
        case .restoredNeedsAttention:
            "Backup restored"
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
        case .reviewing:
            "No changes were made."
        case .success:
            "Lava will use the restored settings on this device."
        case .restoredNeedsAttention:
            "Filtering could not update."
        case .failed(let reason):
            reason
        case .cancelled:
            "No changes were made."
        }
    }

    var tint: Color {
        switch self {
        case .choosing, .restoring, .reviewing, .success:
            LavaStyle.safeGreen
        case .failed, .restoredNeedsAttention:
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
                .accessibilityHidden(true)

            TextField("Word %lld".lavaLocalizedFormat(number), text: $word)
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
        .lavaRecoveryWordSurface()
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
