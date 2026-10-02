import SwiftUI
import UniformTypeIdentifiers
import LavaSecKit

@MainActor
struct LavaAppNativeFlow: Identifiable {
    let id = UUID()
    let name: String
    var wireGuardIndex = 0
    var wireGuardGeneration: UInt64? = nil
    var wireGuardName = ""
    var wireGuardExists = false
    var saveWireGuardDraft: ((String, String?) -> String?)? = nil
    var filterID: String? = nil
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
    var isImport: Bool { ["import", "importCode", "importScan", "deepLinkImport"].contains(name) }
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
                flowContent(flow.name).overlay {
                    if security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible {
                        LavaSheetLockMask { Task { await security.authenticateAppUnlockIfNeeded() } }
                    }
                }
            }
        }
        .allowsHitTesting(security.protectedDataIsAvailableForPresentation)
        .accessibilityHidden(!security.protectedDataIsAvailableForPresentation)
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
        #if DEBUG || LAVA_QA_TOOLS
        case "vpnConfiguration":
            VPNChainingConfigurationEditor(
                reportRemovalFailure: { flow.reportConfigurationRemovalFailure?($0) },
                onFinish: { bridge.model.refreshDNSSettingsPresentation(); bridge.flow = nil; bridge.publish() },
                rowIndex: flow.wireGuardIndex, expectedGeneration: flow.wireGuardGeneration,
                initialName: flow.wireGuardName, isExisting: flow.wireGuardExists,
                savePendingDraft: flow.saveWireGuardDraft ?? { _, _ in WireGuardChainFailure.changed.localizedDescription })
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
