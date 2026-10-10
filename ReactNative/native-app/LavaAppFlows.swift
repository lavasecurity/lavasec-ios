import SwiftUI
import UniformTypeIdentifiers
import UIKit
import LavaSecKit
import LavaSecPresentation

/// Immutable bundled text is read once, rather than on every native publication.
@MainActor private enum BundledForegroundNotices {
    static let texts: [String: String] = {
        var result: [String: String] = [:]
        for name in ["THIRD-PARTY-NOTICES", "ReactNativeNotices"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "txt"),
               let text = try? String(contentsOf: url, encoding: .utf8) { result[name] = text }
        }
        return result
    }()
    static var combined: String {
        ["THIRD-PARTY-NOTICES", "ReactNativeNotices"].map {
            texts[$0] ?? "Notice file unavailable in this build.".lavaLocalized
        }.joined(separator: "\n\n")
    }
}

@MainActor
struct LavaAppNativeFlow: Identifiable {
    let id = UUID()
    let name: String
    var wireGuardIndex = 0
    var wireGuardGeneration: UInt64? = nil
    var wireGuardDraftID: String? = nil
    var wireGuardDraftRevision: Int? = nil
    var wireGuardName = ""
    var wireGuardExists = false
    var saveWireGuardDraft: ((String, String?) -> String?)? = nil
    var filterID: String? = nil
    var filterVisitEpoch: Int? = nil
    var library: FilterLibraryController? = nil
    var filterName: String? = nil
    var filterEmoji: String? = nil
    var createFilterDraft: ((String?) -> Bool)? = nil
    var confirmLibraryDeletion: (() -> Bool)? = nil
    var blocklistSelection: Set<String>? = nil
    var externalRequestID: UUID? = nil
    var importStartMode: ImportFiltersStartMode? = nil
    var importCompletion = ImportFiltersCompletion()
    var onDismiss: (() -> Void)? = nil
    /// The VPN chaining editor reports a failed deletion (nil after a success) so the
    /// page can keep its retry affordance after the flow is dismissed.
    var reportConfigurationRemovalFailure: ((String?) -> Void)? = nil
    var showWelcome: (() -> Void)? = nil
    var customDNSInitial: DNSResolutionSelection? = nil
    var saveDNSDraft: ((DNSResolutionSelection) -> String?)? = nil
    var reviewedLibrarySession: FilterLibraryEditSession? = nil
    var isImport: Bool { ["import", "importCode", "importScan", "deepLinkImport"].contains(name) }
}

extension LavaAppBridge {
    func foregroundFlowProjection() -> [String: Any]? {
        guard let flow, flow.usesReactPresentation else { return nil }
        guard canReadPresentation(.appUnlock) else { return nil }
        if ["createFilter", "renameFilter", "deleteFilters"].contains(flow.name), !canReadPresentation(.filterEditing) { return nil }
        var result: [String: Any] = ["id": flow.id.uuidString, "kind": flow.name,
            "name": flow.filterName ?? "", "emoji": flow.filterEmoji ?? "🌿",
            "dismissAttempt": foregroundDismissAttempt, "canCreate": flow.library?.canBeginCreatingFilter ?? false,
            "templates": (flow.library?.filters ?? []).map { ["id": $0.id, "name": $0.name] }]
        if let session = flow.reviewedLibrarySession {
            var groups: [[String: Any]] = []
            func group(_ title: String, _ added: [String], _ removed: [String]) {
                if !added.isEmpty || !removed.isEmpty { groups.append(["title": title, "added": added, "removed": removed]) }
            }
            group("Added filters", session.additions.map(\.name), [])
            for id in session.renames.keys.filter({ !session.stagedDeletions.contains($0) }).sorted() {
                group("Renamed filter", [session.renames[id] ?? ""], [session.baseline?.filter(id: id)?.name ?? ""])
            }
            for id in session.emojiChanges.keys.filter({ !session.stagedDeletions.contains($0) }).sorted() {
                group("Emoji", [session.emojiChanges[id] ?? ""], [session.baseline?.filter(id: id)?.emoji ?? ""])
            }
            group("Deleted filters", [], (session.baseline?.filters ?? []).filter { session.stagedDeletions.contains($0.id) }.map(\.name))
            result["groups"] = groups
            result["hasDeletions"] = !session.stagedDeletions.isEmpty
        }
        if flow.name == "licenses" {
            result["notices"] = BundledForegroundNotices.combined
        }
        if flow.name == "feedback" { result["feedback"] = feedbackProjection(flow) }
        if flow.name == "vpnConfiguration" { result["vpnEditor"] = wireGuardEditorProjection(flow).map { $0 as Any } ?? NSNull() }
        return result
    }

    func foregroundFlowCommand(_ action: String, _ input: [String: Any]) async throws -> Any {
        guard let flow, flow.usesReactPresentation, input["id"] as? String == flow.id.uuidString else {
            throw CommandError("The app screen closed before this action started.")
        }
        if action == "foreground.dismiss" {
            if flow.name == "vpnConfiguration" {
                // Native Content and file imports can become dirty before RN
                // observes their projection. Only explicit Discard may retire
                // that current dirty visit; probing Close never creates one.
                if let visit = wireGuardEditorVisit {
                    guard visit.id == flow.id else { throw CommandError("The app screen closed before this action started.") }
                    guard !visit.dirty || input["discardConfirmed"] as? Bool == true else { return false }
                    visit.retire(); wireGuardEditorVisit = nil
                }
            }
            if flow.name == "feedback" {
                guard feedbackOwner(flow.id).draft.canDismiss, !model.reports.bugReportSendState.isSending else { return false }
                retireFeedback(flow.id)
            }
            self.flow = nil; foregroundDraftIsDirty = false
            return NSNull()
        }
        if action == "foreground.dirty" {
            if flow.name == "feedback" {
                guard input["dirty"] as? Bool == true, canReadPresentation(.appUnlock),
                      feedbackOwner(flow.id).draft.markPresentationEdited() else { throw CommandError("Read access changed.") }
                feedbackDraftIsDirty = true; foregroundDraftIsDirty = true
            } else {
                guard flow.name == "renameFilter" else { throw CommandError("Invalid app command.") }
                foregroundDraftIsDirty = input["dirty"] as? Bool ?? false
            }
            return NSNull()
        }
        // Read-only help/notices follow native.flow's App Unlock boundary.
        // Library entry and every editing command retain their stronger scope.
        if action == "foreground.enter", ["automation", "licenses"].contains(flow.name) {
            try await authorize(.appUnlock, "Unlock Lava")
        } else {
            try await authorize(.filterEditing, "Manage filters")
        }
        guard UIApplication.shared.applicationState == .active, self.flow?.id == flow.id else { throw CommandError("Authentication cancelled.") }
        if action == "foreground.enter" { return NSNull() }
        if action == "foreground.identity" {
            guard flow.name == "renameFilter", let name = input["name"] as? String, let emoji = input["emoji"] as? String else { throw CommandError("The app screen closed before this action started.") }
            let resolvedName = FilterIdentityPolicy.nameForEdit(name, savedName: flow.filterName ?? "")
            let available = flow.library.map { $0.isFilterNameAvailable(FilterIdentityPolicy.normalizedName(name), excluding: flow.filterID) }
                ?? model.isFilterNameAvailable(FilterIdentityPolicy.normalizedName(name), excluding: flow.filterID)
            let message: String = resolvedName == nil && !name.isEmpty ? "Use letters, numbers and spaces."
                : !emoji.isEmpty && !FilterIdentityPolicy.isValidEmoji(emoji) ? "Choose one emoji."
                : !available && !name.isEmpty ? "You already have a filter with that name." : ""
            return ["valid": resolvedName != nil && FilterIdentityPolicy.isValidEmoji(emoji) && available,
                "dirty": FilterIdentityPolicy.hasUnsavedChanges(name: name, emoji: emoji, savedName: flow.filterName ?? "", savedEmoji: flow.filterEmoji ?? "🌿"), "message": message.lavaLocalized]
        }
        guard action == "foreground.submit" else { throw CommandError("Invalid app command.") }
        let accepted: Bool
        switch flow.name {
        case "createFilter": accepted = flow.createFilterDraft?(input["template"] as? String) ?? false
        case "deleteFilters": accepted = flow.confirmLibraryDeletion?() ?? false
        case "renameFilter":
            guard let id = flow.filterID, let name = input["name"] as? String, let emoji = input["emoji"] as? String else { throw CommandError("The app screen closed before this action started.") }
            if let library = flow.library {
                guard library.editSession == flow.reviewedLibrarySession, !library.isFilterFrozen(id) else { throw CommandError("Your filters changed. Close Review and check your changes.") }
                accepted = library.renameFilter(id: id, to: name, emoji: emoji)
            } else {
                guard flow.filterVisitEpoch == filterPresentationEpoch, (model.filterEditTargetID ?? model.activeFilterID) == id,
                      model.filterEditDraft != nil, !model.isFilterFrozen(id) else { throw CommandError("The displayed filter changed. Reopen it before editing.") }
                accepted = model.renameFilter(id: id, to: name, emoji: emoji)
            }
        default: throw CommandError("Invalid app command.")
        }
        guard accepted else { throw CommandError("Couldn’t save. Please try again.") }
        self.flow = nil; foregroundDraftIsDirty = false
        return true
    }
    func customEntryProjection() -> [String: Any]? {
        guard let entry = pushedCustomEntry else { return nil }
        let isDNS = entry.name == "customDNSDraft"
        guard canReadPresentation(isDNS ? .appSettings : .filterEditing) else { return nil }
        return ["id": entry.id.uuidString, "kind": isDNS ? "dns" : "blocklist",
            "name": entry.customDNSInitial?.name ?? "", "primary": entry.customDNSInitial?.primary ?? "",
            "secondary": entry.customDNSInitial?.secondary ?? "",
            "allowed": isDNS ? model.configuration.limits.allowsCustomDNS : model.configuration.limits.allowsCustomBlocklists,
            "overBudget": !isDNS && model.enabledIDsExceedSoftRuleBudget(entry.blocklistSelection ?? [])]
    }

    func enterCustomEntry(_ input: [String: Any]) async throws -> Any {
        guard let entry = pushedCustomEntry, input["id"] as? String == entry.id.uuidString else {
            throw CommandError("The app screen closed before this action started.")
        }
        let isDNS = entry.name == "customDNSDraft"
        let surface: SecurityProtectedSurface = isDNS ? .appSettings : .filterEditing
        try await authorize(surface, isDNS ? "Edit DNS settings" : "Edit filter")
        guard pushedCustomEntry?.id == entry.id, canReadPresentation(surface), !Task.isCancelled else {
            throw CommandError("Read access changed.")
        }
        return NSNull()
    }

    func saveCustomEntry(_ input: [String: Any]) async throws -> Any {
        guard let token = input["id"] as? String, let entry = pushedCustomEntry,
              token == entry.id.uuidString else { throw CommandError("The app screen closed before this action started.") }
        let isDNS = entry.name == "customDNSDraft"
        try await authorize(isDNS ? .appSettings : .filterEditing, isDNS ? "Edit DNS settings" : "Edit filter")
        // Authentication may yield. A replacement visit never inherits the old
        // form's save callback, even when it displays the same filter or DNS tier.
        guard UIApplication.shared.applicationState == .active, pushedCustomEntry?.id == entry.id,
              let name = input["name"] as? String else { throw CommandError("The app screen closed before this action started.") }
        let message: String?
        if isDNS {
            guard model.configuration.limits.allowsCustomDNS, let primary = input["primary"] as? String,
                  let secondary = input["secondary"] as? String, let save = entry.saveDNSDraft else {
                throw CommandError("Reopen the DNS editor before saving.")
            }
            message = save(DNSResolutionSelection(id: DNSResolverPreset.customID, name: name, primary: primary, secondary: secondary))
        } else {
            guard entry.name == "customBlocklist", model.configuration.limits.allowsCustomBlocklists,
                  let id = entry.filterID, entry.filterVisitEpoch == filterPresentationEpoch,
                  (model.filterEditTargetID ?? model.activeFilterID) == id,
                  model.filterEditDraft != nil, !model.isFilterFrozen(id),
                  !model.enabledIDsExceedSoftRuleBudget(entry.blocklistSelection ?? []),
                  let url = input["url"] as? String else {
                throw CommandError("The displayed filter changed. Reopen it before editing.")
            }
            message = model.filterDrafts.addCustomBlocklistToDraft(displayName: name, rawURL: url)
            reviewedFilter = nil
        }
        if let message { throw CommandError(message) }
        return true
    }
}

extension LavaAppNativeFlow {
    var usesReactPresentation: Bool { ["createFilter", "renameFilter", "deleteFilters", "automation", "licenses", "feedback", "vpnConfiguration"].contains(name) }
}

/// Native system and security flows retain their established presentation,
/// cancellation and credential handling beneath the React-owned screen shell.
struct LavaAppNativeFlowView: View {
    let flow: LavaAppNativeFlow
    @ObservedObject private var bridge = LavaAppBridge.shared
    @EnvironmentObject private var security: SecurityController
    var body: some View {
        Group {
            if flow.isImport && (security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible) {
                // Unmount immediately, before UIKit's dismissal completes, so a
                // live scanner and its preview cannot survive behind the mask.
                Color.clear
            } else {
                Group {
                    if flow.usesReactPresentation {
                        // Feedback's scroll body paints through the bottom
                        // container inset; its shared footer owns safe padding.
                        LavaAppForegroundContent(id: flow.id.uuidString)
                            .ignoresSafeArea(.container, edges: flow.name == "feedback" ? .bottom : [])
                    }
                    else { flowContent(flow.name) }
                }.overlay {
                    if security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible {
                        LavaSheetLockMask { Task { await security.authenticateAppUnlockIfNeeded() } }
                    }
                }
            }
        }
        .allowsHitTesting(security.protectedDataIsAvailableForPresentation)
        .accessibilityHidden(!security.protectedDataIsAvailableForPresentation)
        .background(LavaStyle.groupedBackground.ignoresSafeArea())
    }
    @ViewBuilder private func flowContent(_ name: String) -> some View {
        switch name {
        case "preparation": FilterPreparationScreen(origin: bridge.model.filterPreparationOrigin)
        case "deepLinkImport": ImportFiltersFlow(startMode: flow.importStartMode ?? .chooseMethod,
            completion: flow.importCompletion,
            authorizeImport: { await security.requireFreshAuthentication(for: .filterEditing, reason: "Import filter") })
        #if DEBUG || LAVA_QA_TOOLS
        case "phoneQASheet": PhoneQASheetView(showWelcome: { flow.showWelcome?() }, showUserBugReport: { bridge.flow = LavaAppNativeFlow(name: "feedback") })
        #endif
        case "account": AccountSheet()
        case "backupSetup": BackupSetupView()
        case "backupRestore": BackupRestoreView()
        case "passcode": SecurityPasscodeSetupView()
        case "automation": AutoSwitchHowToSheet()
        case "createFilter":
            if let library = flow.library, let create = flow.createFilterDraft { CreateFilterSheet(library: library, onCreateDraft: create) }
        case "renameFilter":
            if let library = flow.library, let id = flow.filterID {
                RenameFilterSheet(initialName: flow.filterName ?? "", initialEmoji: flow.filterEmoji ?? "🌿", isNameAvailable: { library.isFilterNameAvailable($0, excluding: id) }, onRename: { library.renameFilter(id: id, to: $0, emoji: $1) })
            } else if let id = flow.filterID {
                RenameFilterSheet(initialName: flow.filterName ?? "", initialEmoji: flow.filterEmoji ?? "🌿",
                    isNameAvailable: { bridge.model.isFilterNameAvailable($0, excluding: id) },
                    onRename: { name, emoji in
                        let model = bridge.model
                        guard (model.filterEditTargetID ?? model.activeFilterID) == id,
                              model.filterEditDraft != nil, !model.isFilterFrozen(id) else { return false }
                        return model.renameFilter(id: id, to: name, emoji: emoji)
                    })
            }
        case "deleteFilters":
            if let library = flow.library { DeleteFiltersConfirmationSheet(session: library.editSession, confirm: { flow.confirmLibraryDeletion?() ?? false }) }
        case "import", "importCode", "importScan":
            ImportFiltersFlow(startMode: name == "importCode" ? .enterCode : name == "importScan" ? .scanCode : .chooseMethod,
                completion: flow.importCompletion,
                authorizeImport: { await security.requireFreshAuthentication(for: .filterEditing, reason: "Import filter") })
        case "licenses": NavigationStack { BundledLibraryNoticesView().lavaFullSheetHeader("Full License Texts", close: { bridge.flow = nil }) }
        case "feedback": BugReportSheetView(isReportDirty: $bridge.feedbackDraftIsDirty)
        case "customDNS": NavigationStack { DNSResolverSettingsView(onDismissRequested: { bridge.flow = nil }) }
        case "vpnConfiguration":
            VPNChainingConfigurationEditor(
                reportRemovalFailure: { flow.reportConfigurationRemovalFailure?($0) },
                onFinish: { bridge.model.refreshDNSSettingsPresentation(); bridge.flow = nil; bridge.publish() },
                rowIndex: flow.wireGuardIndex, expectedGeneration: flow.wireGuardGeneration,
                initialName: flow.wireGuardName, isExisting: flow.wireGuardExists,
                savePendingDraft: flow.saveWireGuardDraft ?? { _, _ in WireGuardChainFailure.changed.localizedDescription })
        #if DEBUG || LAVA_QA_TOOLS
        case "phoneQA": NavigationStack { PhoneQASettingsView().lavaFullSheetHeader("Phone QA", close: { bridge.flow = nil }) }
        #endif
        case "customBlocklist": NavigationStack {
            BringYourOwnListView(isOverBudget: bridge.model.enabledIDsExceedSoftRuleBudget(flow.blocklistSelection ?? []),
                allowsCustomBlocklists: bridge.model.configuration.limits.allowsCustomBlocklists,
                upgradeAccessory: .chevron,
                addCustomSource: { name, url in
                    guard let id = flow.filterID, (bridge.model.filterEditTargetID ?? bridge.model.activeFilterID) == id,
                          bridge.model.filterEditDraft != nil, !bridge.model.isFilterFrozen(id) else {
                        return "The displayed filter changed. Reopen it before editing."
                    }
                    return bridge.model.filterDrafts.addCustomBlocklistToDraft(displayName: name, rawURL: url)
                },
                showUpgrade: { bridge.flow = nil; bridge.requestNavigation(tab: "SettingsTab", screen: "Upgrade") })
                .lavaFullSheetHeader("Bring your own list", close: { bridge.flow = nil })
        }
        default: EmptyView()
        }
    }
}

/// Uses the very same custom-entry scaffold as BringYourOwnListView. Save only
/// returns a validated choice to the picker; tier persistence belongs to its parent.
struct LavaCustomDNSDraftView: View {
    @State private var name: String
    @State private var primary: String
    @State private var secondary: String
    @State private var message: String?
    let save: (DNSResolutionSelection) -> String?

    init(initial: DNSResolutionSelection?, save: @escaping (DNSResolutionSelection) -> String?) {
        _name = State(initialValue: initial?.name ?? "")
        _primary = State(initialValue: initial?.primary ?? "")
        _secondary = State(initialValue: initial?.secondary ?? "")
        self.save = save
    }
    var body: some View {
        LavaSheetScaffold(spacing: 18, scrolls: true) {
            LavaCustomEntryForm(actionTitle: "Save", actionSymbol: "checkmark", enabled: !primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, submit: {
                message = save(DNSResolutionSelection(id: DNSResolverPreset.customID, name: name, primary: primary, secondary: secondary))
            }) {
                LavaTextInputRow(title: "Name (optional)") {
                    TextField("Custom DNS".lavaLocalized, text: $name).lavaTextInputBody()
                }
                Divider()
                LavaTextInputRow(title: "Primary DNS") {
                    TextField("IPv4/6, https://, tls://, doq://, quic://, or sdns://".lavaLocalized, text: $primary).lavaTextInputBody(keyboardType: .URL)
                }
                Divider()
                LavaTextInputRow(title: "Secondary DNS (optional)") {
                    TextField("Same transport as Primary".lavaLocalized, text: $secondary).lavaTextInputBody(keyboardType: .URL)
                }
            } notice: {
                if let message { DomainRejectPanel(title: "Custom DNS cannot be saved", message: message) }
            }
        }
    }
}
