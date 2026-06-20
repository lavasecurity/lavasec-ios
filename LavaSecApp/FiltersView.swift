import SwiftUI
import LavaSecCore

struct FiltersView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    let scrollToTopTrigger: Int
    let embedsNavigationStack: Bool

    @State private var isSharingFilters = false
    @State private var isImportingFilters = false
    @State private var isShowingMyList = false

    init(scrollToTopTrigger: Int = 0, embedsNavigationStack: Bool = true) {
        self.scrollToTopTrigger = scrollToTopTrigger
        self.embedsNavigationStack = embedsNavigationStack
    }

    var body: some View {
        Group {
            if embedsNavigationStack {
                NavigationStack {
                    filtersScreen
                }
            } else {
                filtersScreen
            }
        }
        .sheet(isPresented: $isSharingFilters) {
            ShareFiltersSheet()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $isImportingFilters) {
            ImportFiltersFlow(
                startMode: .chooseMethod,
                authorizeImport: {
                    await security.requireFreshAuthentication(for: .filterEditing, reason: "Import filter")
                }
            )
            .environmentObject(viewModel)
        }
    }

    private var filtersScreen: some View {
        LavaPrimaryTabScreenContent(
            title: "Filter",
            scrollToTopTrigger: scrollToTopTrigger,
            refreshAction: {
                await viewModel.syncCatalog()
            }
        ) {
            FiltersOverviewPanel()
        } content: {
            LavaSectionGroup("My filter") {
                ImportOptionRow(
                    systemImage: "slider.horizontal.3",
                    title: "View & edit",
                    subtitle: "What Lava blocks and lets through"
                ) {
                    isShowingMyList = true
                }
                .frame(maxWidth: .infinity)
            }

            LavaSectionGroup("Got a good filter?") {
                VStack(spacing: 10) {
                    ImportOptionRow(
                        systemImage: "square.and.arrow.up",
                        title: "Share my filter",
                        subtitle: "Share via QR or code"
                    ) {
                        isSharingFilters = true
                    }

                    ImportOptionRow(
                        systemImage: "square.and.arrow.down",
                        title: "Import a filter",
                        subtitle: "Scan a QR or code"
                    ) {
                        isImportingFilters = true
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationDestination(isPresented: $isShowingMyList) {
            MyListCover()
                .environmentObject(viewModel)
                .environmentObject(security)
        }
    }
}

private struct FiltersOverviewPanel: View {
    var body: some View {
        // Diagram + explainer back together inside the card (the "below the panel"
        // placement read too faint); the card stays content-sized.
        LavaInfoCard {
            VStack(spacing: 14) {
                FiltersFlowDiagram()

                Text("Lava uses a local filter to block your phone's access to unwanted sites.".lavaLocalized)
                    .lavaBodySupportingText()
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// One-glance explanation of where Lava sits: your phone reaches the internet
/// through Lava acting as a local filter. Laid out with fixed object:arrow width
/// ratios (≈3.5:1) so the nodes stay large and the spacing scales with the card.
private struct FiltersFlowDiagram: View {
    private let iconBoxHeight: CGFloat = 62
    private let nodeRatio: CGFloat = 0.28
    private let arrowRatio: CGFloat = 0.08

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(alignment: .top, spacing: 0) {
                node(label: "Phone".lavaLocalized) {
                    Image(systemName: "iphone")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(LavaStyle.secondaryText)
                }
                .frame(width: width * nodeRatio)

                connector.frame(width: width * arrowRatio)

                node(label: "Lava") {
                    SoftShieldGuardian(size: 62, state: .awake, animates: false)
                }
                .frame(width: width * nodeRatio)

                connector.frame(width: width * arrowRatio)

                node(label: "Internet".lavaLocalized) {
                    Image(systemName: "globe")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(LavaStyle.secondaryText)
                }
                .frame(width: width * nodeRatio)
            }
            .frame(width: width)
        }
        .frame(height: iconBoxHeight + 24)
    }

    @ViewBuilder
    private func node<Icon: View>(label: String, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 8) {
            icon()
                .frame(height: iconBoxHeight)

            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(LavaStyle.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private var connector: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(LavaStyle.secondaryText.opacity(0.6))
            .frame(height: iconBoxHeight)
    }
}

/// Consolidated "My list" surface: the two-shelf (block / allow) view presented as a
/// full-screen cover with one unified Edit + Save. The edit draft is whole, so a single
/// `FilterEditScope` (`.blockedDomains`) is reused only as the edit-mode flag.
private struct MyListCover: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    @State private var activeSheet: BlockedDomainSheet?
    @State private var showingAddException = false
    @State private var showingConfirmation = false
    @State private var showingDiscardConfirmation = false

    var body: some View {
        LavaScreenContent(
            spacing: 22,
            refreshAction: {
                await viewModel.syncCatalog()
            }
        ) {
            rulesPanel

            LavaSectionGroup("Lava blocks these") {
                LavaCondensedList {
                    blockShelfRows

                    if isEditing {
                        FilterAddButton(title: "Add a blocklist", systemImage: "plus") {
                            activeSheet = .blocklist
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                        FilterAddButton(title: "Block a domain", systemImage: "plus") {
                            activeSheet = .blockedDomain
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                    }
                }
            }

            LavaSectionGroup("Lava lets these through") {
                LavaCondensedList {
                    allowShelfRows

                    if isEditing {
                        FilterAddButton(title: "Add an exception", systemImage: "plus") {
                            showingAddException = true
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                    }
                }
            }
        }
        .navigationTitle("My filter".lavaLocalized)
        .navigationBarTitleDisplayMode(.inline)
        // Hide the system Back button while editing so a stray tap can't abandon the
        // draft. An interactive edge-swipe can still pop the page; that path preserves a
        // dirty draft (see cancelFilterEditingOnPageDisappear), so no edits are lost.
        .navigationBarBackButtonHidden(isEditing)
        .toolbar {
            if isEditing {
                FilterEditToolbar(
                    isEditing: true,
                    canSave: viewModel.filterDraftHasChanges,
                    beginEditing: beginEditing,
                    closeEditing: closeEditing,
                    save: saveChanges
                )
            } else {
                // A ToolbarItemGroup lets the system merge the two glyphs into one
                // native glass capsule (with a divider) — no custom background. The
                // page is pushed, so the system Back button handles dismissal.
                ToolbarItemGroup(placement: .primaryAction) {
                    NativeToolbarIconButton(
                        systemName: "arrow.clockwise",
                        accessibilityLabel: "Refresh now",
                        action: { Task { await viewModel.syncCatalog() } }
                    )
                    .disabled(viewModel.isSyncingCatalog)

                    NativeToolbarIconButton(
                        systemName: "square.and.pencil",
                        accessibilityLabel: "Edit",
                        action: beginEditing
                    )
                }
            }
        }
        .onDisappear {
            viewModel.cancelFilterEditingOnPageDisappear(.blockedDomains)
        }
        .task {
            // Auto-refresh on open: cheap when nothing changed (the snapshot-identity
            // gate skips the re-encode + tunnel reload), so opening My list keeps the
            // lists current without a heavy rebuild or a spurious reconnect.
            await viewModel.syncCatalog()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .blocklist:
                AddBlocklistSheet(
                    initialSelection: viewModel.filterEditDraft?.enabledBlocklistIDs ?? viewModel.configuration.enabledBlocklistIDs
                )
                    .environmentObject(viewModel)
            case .blockedDomain:
                AddBlockedDomainSheet()
                    .environmentObject(viewModel)
            }
        }
        .sheet(isPresented: $showingAddException) {
            AddAllowedExceptionSheet()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showingConfirmation) {
            FilterConfirmationSheet(origin: .filters)
                .environmentObject(viewModel)
        }
        .fullScreenCover(isPresented: $viewModel.isFilterPreparationScreenPresented) {
            FilterPreparationScreen(origin: .filters)
                .environmentObject(viewModel)
        }
        .lavaConfirmationAlert { host in
            host.alert("Discard changes?", isPresented: $showingDiscardConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Discard", role: .destructive) {
                    viewModel.cancelFilterEditing()
                }
            } message: {
                Text("Your draft changes will be removed. The current saved filter will stay active.")
            }
        }
    }

    @ViewBuilder private var rulesPanel: some View {
        LavaInfoCard {
            VStack(alignment: .leading, spacing: 12) {
                LavaOverviewMetricBlock(
                    value: viewModel.configuredProtectedDomainNumberText,
                    label: "rules in effect"
                )

                (Text(Image(systemName: viewModel.blocklistCatalogFreshnessSystemImage))
                    .foregroundColor(viewModel.blocklistCatalogFreshnessTint)
                    + Text(" \(viewModel.blocklistCatalogFreshnessTitle.lavaLocalized)")
                    .foregroundColor(LavaStyle.secondaryText))
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    @ViewBuilder private var blockShelfRows: some View {
        let sourceIDs = viewModel.stagedBlocklistIDsForDisplay()
        let blockedDomains = viewModel.stagedBlockedDomainsForDisplay()
        if sourceIDs.isEmpty && blockedDomains.isEmpty {
            EmptyFilterRow(
                title: "No blocklists enabled",
                subtitle: editSubtitle("Add a curated blocklist to start blocking known domains"),
                titleFont: .body
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        } else {
            ForEach(sourceIDs, id: \.self) { sourceID in
                BlocklistEffectRow(sourceID: sourceID, isEditing: isEditing)

                if sourceID != sourceIDs.last || !blockedDomains.isEmpty {
                    LavaCondensedDivider()
                }
            }

            ForEach(blockedDomains, id: \.self) { domain in
                DomainEffectRow(
                    domain: domain,
                    isNew: viewModel.isBlockedDomainNewInDraft(domain),
                    isPendingRemoval: viewModel.isBlockedDomainPendingRemoval(domain),
                    isEditing: isEditing,
                    remove: { viewModel.removeBlockedDomainFromDraft(domain) },
                    undo: { viewModel.undoBlockedDomainDraftChange(domain) }
                )

                if domain != blockedDomains.last {
                    LavaCondensedDivider()
                }
            }
        }
    }

    @ViewBuilder private var allowShelfRows: some View {
        let domains = viewModel.stagedAllowedDomainsForDisplay()
        if domains.isEmpty {
            EmptyFilterRow(
                title: "No allowed exceptions",
                subtitle: isEditing ? "Add only domains you trust" : nil,
                titleFont: .body
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        } else {
            ForEach(domains, id: \.self) { domain in
                DomainEffectRow(
                    domain: domain,
                    isNew: viewModel.isAllowedDomainNewInDraft(domain),
                    isPendingRemoval: viewModel.isAllowedDomainPendingRemoval(domain),
                    isEditing: isEditing,
                    remove: { viewModel.removeAllowedDomainFromDraft(domain) },
                    undo: { viewModel.undoAllowedDomainDraftChange(domain) }
                )

                if domain != domains.last {
                    LavaCondensedDivider()
                }
            }
        }
    }

    private func editSubtitle(_ value: String) -> String? {
        isEditing ? value : nil
    }

    private var isEditing: Bool {
        viewModel.isFilterEditing(.blockedDomains)
    }

    private func closeEditing() {
        if viewModel.filterDraftHasChanges {
            showingDiscardConfirmation = true
        } else {
            viewModel.cancelFilterEditing()
        }
    }

    private func beginEditing() {
        Task {
            guard await security.requireAuthentication(for: .filterEditing, reason: "Edit filter") else {
                return
            }

            viewModel.beginFilterEditing(.blockedDomains)
        }
    }

    /// Fresh auth on every Save. Safe edits (only strengthening/neutral changes) apply
    /// straight to the prepare screen; edits that weaken protection (remove a blocklist
    /// or blocked domain, or add an allowed exception) show the review confirmation first.
    private func saveChanges() {
        Task {
            guard await security.requireFreshAuthentication(for: .filterEditing, reason: "Save filter") else {
                return
            }

            let diff = viewModel.filterDraftDiff
            let weakensProtection = !diff.removedBlocklistIDs.isEmpty
                || !diff.removedBlockedDomains.isEmpty
                || !diff.addedAllowedDomains.isEmpty

            if weakensProtection {
                showingConfirmation = true
            } else {
                await viewModel.prepareAndApplyFilterDraft()
            }
        }
    }
}

private enum BlockedDomainSheet: String, Identifiable {
    case blocklist
    case blockedDomain

    var id: String { rawValue }
}

private struct LavaPlusUpgradeSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LavaPlusUpgradeDestination()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close", role: .close, action: dismiss.callAsFunction)
                    }
                }
        }
    }
}

private struct FilterEditToolbar: ToolbarContent {
    let isEditing: Bool
    let canSave: Bool
    let beginEditing: () -> Void
    let closeEditing: () -> Void
    let save: () -> Void

    var body: some ToolbarContent {
        if isEditing {
            ToolbarItem(placement: .cancellationAction) {
                NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close edit mode", role: .cancel, action: closeEditing)
            }

            ToolbarItem(placement: .confirmationAction) {
                NativeToolbarIconButton(systemName: "checkmark", accessibilityLabel: "Save", role: .confirm, action: save)
                    .disabled(!canSave)
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                NativeToolbarIconButton(systemName: "square.and.pencil", accessibilityLabel: "Edit", action: beginEditing)
            }
        }
    }
}


private struct LavaInlineInfoContent: View {
    let title: String
    let description: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            (Text(Image(systemName: systemImage))
                .foregroundColor(tint)
                + Text(" \(title)")
                .foregroundColor(LavaStyle.ink))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(description.lavaLocalized)
                .lavaSupportingText()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyFilterRow: View {
    let title: String
    let subtitle: String?
    var titleFont: Font = .headline

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.lavaLocalized)
                .font(titleFont)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle {
                Text(subtitle.lavaLocalized)
                    .lavaRowSubtitleText()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

private struct BlocklistEffectRow: View {
    @EnvironmentObject private var viewModel: AppViewModel

    let sourceID: String
    let isEditing: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.blocklistName(for: sourceID).lavaLocalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(pendingRemoval ? LavaStyle.secondaryText : LavaStyle.primaryText)
                    .strikethrough(pendingRemoval, color: LavaStyle.secondaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)

                if let metadata = viewModel.blocklistMetadataText(for: sourceID) {
                    Text(metadata.lavaLocalized)
                        .lavaMetadataText()
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 6)

            if let trailingAction {
                Button(action: trailingAction.action) {
                    Image(systemName: trailingAction.systemImage)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(trailingAction.tint)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(trailingAction.title.lavaLocalized)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 64)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(pendingRemoval ? 0.68 : 1)
    }

    private var trailingAction: LavaCondensedTrailingAction? {
        guard isEditing else {
            return nil
        }

        let isUndo = pendingRemoval || (isNew && !viewModel.isCustomBlocklist(sourceID))
        return LavaCondensedTrailingAction(
            title: isUndo ? "Undo" : "Remove",
            systemImage: isUndo ? "arrow.uturn.backward.circle.fill" : "minus.circle.fill",
            tint: isUndo ? LavaStyle.safeGreen : .red
        ) {
            if isUndo {
                viewModel.undoBlocklistDraftChange(sourceID)
            } else {
                viewModel.removeBlocklistFromDraft(sourceID)
            }
        }
    }

    private var pendingRemoval: Bool {
        viewModel.isBlocklistPendingRemoval(sourceID)
    }

    private var isNew: Bool {
        viewModel.isBlocklistNewInDraft(sourceID)
    }
}

private struct DomainEffectRow: View {
    let domain: String
    let isNew: Bool
    let isPendingRemoval: Bool
    let isEditing: Bool
    let remove: () -> Void
    let undo: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(domain.lavaLocalized)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isPendingRemoval ? LavaStyle.secondaryText : LavaStyle.primaryText)
                .strikethrough(isPendingRemoval, color: LavaStyle.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let trailingAction {
                Button(action: trailingAction.action) {
                    Image(systemName: trailingAction.systemImage)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(trailingAction.tint)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(trailingAction.title.lavaLocalized)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isPendingRemoval ? 0.68 : 1)
    }

    private var trailingAction: LavaCondensedTrailingAction? {
        guard isEditing else {
            return nil
        }

        let isUndo = isPendingRemoval || isNew
        return LavaCondensedTrailingAction(
            title: isUndo ? "Undo" : "Remove",
            systemImage: isUndo ? "arrow.uturn.backward.circle.fill" : "minus.circle.fill",
            tint: isUndo ? LavaStyle.safeGreen : .red
        ) {
            if isUndo {
                undo()
            } else {
                remove()
            }
        }
    }
}

private struct FilterAddButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FilterActionLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(LavaPanelActionButtonStyle())
    }
}

private enum FilterActionLabelMetrics {
    static let iconFrameSize: CGFloat = 16
    static let iconPointSize: CGFloat = 13
    static let iconTextSpacing: CGFloat = 7
}

private struct FilterActionLabel: View {
    let title: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: FilterActionLabelMetrics.iconTextSpacing) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: FilterActionLabelMetrics.iconPointSize, weight: .semibold))
                    .frame(
                        width: FilterActionLabelMetrics.iconFrameSize,
                        height: FilterActionLabelMetrics.iconFrameSize
                    )
                    .accessibilityHidden(true)
            }

            Text(title.lavaLocalized)
        }
        .frame(maxWidth: .infinity)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
    }
}

private struct DomainEntryForm: View {
    @Binding var domain: String
    @FocusState private var isDomainFieldFocused: Bool
    @State private var showUpgradePage = false

    let placeholder: String
    let primaryActionTitle: String
    let usageText: String
    let usageTextIsError: Bool
    let isSubmitDisabled: Bool
    let submit: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            DomainTextField(
                placeholder: placeholder,
                text: $domain,
                isFocused: $isDomainFieldFocused
            )
                .submitLabel(.done)
                .onSubmit {
                    if !isSubmitDisabled {
                        primaryAction()
                    }
                }

            Button(action: primaryAction) {
                Text(primaryActionTitle.lavaLocalized)
            }
            .buttonStyle(LavaStandaloneActionButtonStyle())
            .disabled(isSubmitDisabled)

            Text(usageText.lavaLocalized)
                .font(.footnote.weight(.medium))
                .foregroundStyle(usageTextIsError ? LavaStyle.lavaOrange : LavaStyle.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showUpgradePage) {
            LavaPlusUpgradeSheet()
        }
        .task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else {
                return
            }

            isDomainFieldFocused = true
        }
    }

    private func primaryAction() {
        if primaryActionTitle == "Upgrade" {
            showUpgradePage = true
            return
        }

        submit()
    }
}

private struct DomainTextField: View {
    let placeholder: String
    @Binding var text: String
    let isFocused: FocusState<Bool>.Binding

    var body: some View {
        LavaTextInputPanel {
            LavaTextInputRow(title: "Domain") {
                TextField(placeholder.lavaLocalized, text: $text)
                    .lavaTextInputBody(keyboardType: .URL)
                    .focused(isFocused)
            }
        }
    }
}

private enum AddBlocklistRoute: Hashable {
    case bringYourOwnList
}

struct AddBlocklistSheet: View {
    enum Usage {
        case filterDraft
        case onboardingSelection
    }

    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    let usage: Usage
    let onSelect: ((Set<String>) -> Void)?
    /// The selection captured when the picker first appeared. Held as `@State` (set
    /// once via `State(initialValue:)`) so it survives SwiftUI re-creating this value-
    /// type view when the draft changes. A plain `let` would be re-assigned from the
    /// live `initialSelection` argument on every re-render — after a custom-list add it
    /// drifts to match the mutated draft and re-greys Save. The Save button compares
    /// the live `selectedIDs` against this open-time snapshot.
    @State private var initialSelectedIDs: Set<String>
    @State private var navigationPath: [AddBlocklistRoute] = []
    @State private var selectedIDs = Set<String>()
    @State private var searchText = ""
    @State private var message: String?
    @State private var customDeleteConfirmation: CustomBlocklistSource?
    @State private var showUpgradePage = false

    init(
        usage: Usage = .filterDraft,
        initialSelection: Set<String> = [],
        onSelect: ((Set<String>) -> Void)? = nil
    ) {
        self.usage = usage
        self.onSelect = onSelect
        _initialSelectedIDs = State(initialValue: initialSelection)
        _selectedIDs = State(initialValue: initialSelection)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            LavaSheetScaffold(spacing: 18) {
                VStack(alignment: .leading, spacing: 22) {
                    if usage == .filterDraft {
                        BlocklistSearchField(text: $searchText)
                    }

                    LavaSectionGroup("All blocklists") {
                        if filteredPickerItems.isEmpty {
                            LavaPlainCard {
                                EmptyFilterRow(
                                    title: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? "No blocklists available"
                                        : "No blocklists found",
                                    subtitle: nil
                                )
                            }
                        } else {
                            BlocklistPickerList(
                                items: filteredPickerItems,
                                selectedIDs: selectedIDs,
                                catalogSubtitle: viewModel.blocklistCatalogSubtitleText(for:),
                                catalogMetadata: viewModel.blocklistRuleCountText(for:),
                                catalogMetadataPrefixStatus: blocklistSizeStatus(for:),
                                customTitle: viewModel.customBlocklistPickerTitle(for:),
                                customEntryCount: viewModel.customBlocklistEntryCount(for:),
                                toggle: toggle(_:),
                                requestDeleteCustomSource: { source in
                                    customDeleteConfirmation = source
                                }
                            )
                        }
                    }

                    if let message {
                        DomainRejectPanel(title: "Selection cannot be added", message: message)
                    }
                }
            } footer: {
                VStack(spacing: 9) {
                    Button(actionButtonTitle, action: primaryAction)
                        .buttonStyle(LavaStandaloneActionButtonStyle())
                        .disabled(!canUsePrimaryAction)

                    FilterRuleBudgetBar(status: filterRuleBudgetStatus, isError: selectionStatusIsError)

                    Text(selectionStatusText.lavaLocalized)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(selectionStatusIsError ? LavaStyle.lavaOrange : LavaStyle.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Cancel", role: .cancel, action: dismiss.callAsFunction)
                }

                if usage == .filterDraft {
                    ToolbarItem(placement: .topBarTrailing) {
                        NativeToolbarIconButton(
                            systemName: "plus",
                            accessibilityLabel: "Bring your own list",
                            action: openBringYourOwnList
                        )
                    }
                }
            }
            .navigationDestination(for: AddBlocklistRoute.self) { route in
                switch route {
                case .bringYourOwnList:
                    BringYourOwnListView(
                        isOverBudget: viewModel.enabledIDsExceedSoftRuleBudget(selectedIDs),
                        allowsCustomBlocklists: viewModel.configuration.limits.allowsCustomBlocklists,
                        addCustomSource: addCustomSource(displayName:rawURL:),
                        showUpgrade: {
                            showUpgradePage = true
                        }
                    )
                }
            }
        }
        .presentationDetents([.fraction(0.62), .large])
        .lavaConfirmationAlert { host in
            host.alert("Delete custom list?", isPresented: deleteConfirmationIsPresented, presenting: customDeleteConfirmation) { source in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    deleteCustomSource(id: source.id)
                }
            } message: { source in
                Text("This removes the custom blocklist from your saved lists. \(viewModel.customBlocklistPickerTitle(for: source)) can be added again later.")
            }
        }
        .sheet(isPresented: $showUpgradePage) {
            LavaPlusUpgradeSheet()
                .environmentObject(viewModel)
        }
    }

    private var deleteConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { customDeleteConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    customDeleteConfirmation = nil
                }
            }
        )
    }

    private var pickerItems: [BlocklistPickerItem] {
        let catalogItems = availableBlocklists.map(BlocklistPickerItem.catalog)
        guard usage == .filterDraft else {
            return catalogItems
        }

        let customItems = viewModel.stagedCustomBlocklistsForPicker().map(BlocklistPickerItem.custom)
        return catalogItems + customItems
    }

    private var filteredPickerItems: [BlocklistPickerItem] {
        pickerItems.filter { item in
            item.matchesSearch(searchText)
        }
    }

    private var availableBlocklists: [BlocklistSource] {
        switch usage {
        case .filterDraft:
            viewModel.blocklists
        case .onboardingSelection:
            viewModel.blocklists
        }
    }

    private var filterRuleBudgetStatus: AppViewModel.FilterRuleBudgetStatus {
        viewModel.filterRuleBudgetStatus(forEnabledIDs: selectedIDs)
    }

    private var selectionStatusText: String {
        let status = filterRuleBudgetStatus
        // Nothing counted yet but lists are still resolving — don't imply "0 of
        // budget" headroom we can't vouch for.
        if status.isIndeterminate {
            let lists = status.pendingLists == 1 ? "list" : "lists"
            return "Calculating rule usage… (\(status.pendingLists) \(lists) pending)"
        }

        let used = AppViewModel.abbreviatedRuleCount(status.displayedRuleCount)
        let budget = AppViewModel.abbreviatedRuleCount(status.budget)
        var text: String
        if isFreeOverLimit {
            text = "About \(used) of \(budget) rules · Upgrade or remove a list"
        } else if selectionStatusIsError {
            text = "About \(used) of \(budget) rules · Remove a list to continue"
        } else {
            text = "About \(used) of \(budget) rules"
        }
        if status.pendingLists > 0 {
            text += " (+\(status.pendingLists) pending)"
        }
        return text
    }

    // Blocks the primary action only once the *known* rules pass the soft
    // ceiling (tier budget + ~10% margin for cross-list dedup). The exact,
    // post-union cap is enforced at compile time, so a selection in the margin
    // is allowed through and resolved there.
    private var selectionStatusIsError: Bool {
        viewModel.enabledIDsExceedSoftRuleBudget(selectedIDs)
    }

    private var isFreeOverLimit: Bool {
        !viewModel.configuration.hasLavaSecurityPlus && selectionStatusIsError
    }

    private var canUsePrimaryAction: Bool {
        if actionButtonTitle == "Upgrade" {
            return true
        }

        switch usage {
        case .filterDraft:
            return selectedIDs != initialSelectedIDs && !selectionStatusIsError
        case .onboardingSelection:
            return !selectedIDs.isEmpty && !selectionStatusIsError
        }
    }

    private func blocklistSizeStatus(for blocklist: BlocklistSource) -> LavaCondensedStatus? {
        guard let entryCount = viewModel.blocklistEntryCount(for: blocklist) else {
            return nil
        }

        return .blocklistSizeBucket(entryCount: entryCount)
    }

    private var actionButtonTitle: String {
        if isFreeOverLimit {
            return "Upgrade"
        }

        switch usage {
        case .filterDraft:
            return "Save Selection"
        case .onboardingSelection:
            return "Use Selection"
        }
    }

    private var navigationTitle: String {
        switch usage {
        case .filterDraft:
            "Choose Blocklists"
        case .onboardingSelection:
            "Choose Blocklist"
        }
    }

    private func toggle(_ sourceID: String) {
        if selectedIDs.contains(sourceID) {
            selectedIDs.remove(sourceID)
        } else {
            selectedIDs.insert(sourceID)
        }
    }

    private func primaryAction() {
        if actionButtonTitle == "Upgrade" {
            showUpgradePage = true
            return
        }

        addSelection()
    }

    private func addSelection() {
        switch usage {
        case .filterDraft:
            if let error = viewModel.setDraftBlocklists(selectedIDs) {
                message = error
            } else {
                dismiss()
            }
        case .onboardingSelection:
            onSelect?(selectedIDs)
            dismiss()
        }
    }

    private func addCustomSource(displayName: String, rawURL: String) -> String? {
        let result = viewModel.addCustomBlocklistToDraft(displayName: displayName, rawURL: rawURL)
        if result == nil {
            selectedIDs = viewModel.filterEditDraft?.enabledBlocklistIDs ?? selectedIDs
        }
        return result
    }

    private func deleteCustomSource(id: String) {
        viewModel.deleteCustomBlocklistFromDraft(id)
        selectedIDs.remove(id)
        customDeleteConfirmation = nil
    }

    private func openBringYourOwnList() {
        navigationPath.append(.bringYourOwnList)
    }
}

private struct BlocklistSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LavaStyle.secondaryText)
                .frame(width: 18)

            TextField("Search list name", text: $text)
                .font(.body)
                .foregroundStyle(LavaStyle.primaryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LavaStyle.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .lavaSurface(.panel, cornerRadius: LavaSurface.compactCornerRadius, borderTint: LavaSurface.panelStroke.opacity(0.65))
    }
}

private enum BlocklistPickerItem: Identifiable {
    case catalog(BlocklistSource)
    case custom(CustomBlocklistSource)

    var id: String {
        switch self {
        case .catalog(let source):
            source.id
        case .custom(let source):
            source.id
        }
    }

    func matchesSearch(_ rawQuery: String) -> Bool {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return true
        }

        return searchableText.contains { value in
            value.localizedCaseInsensitiveContains(query)
        }
    }

    private var searchableText: [String] {
        switch self {
        case .catalog(let source):
            [source.name, source.licenseName]
        case .custom(let source):
            [source.displayName, source.sourceURL.absoluteString, "Custom List"]
        }
    }
}

private struct BlocklistPickerList: View {
    let items: [BlocklistPickerItem]
    let selectedIDs: Set<String>
    let catalogSubtitle: (BlocklistSource) -> String?
    let catalogMetadata: (BlocklistSource) -> String?
    let catalogMetadataPrefixStatus: (BlocklistSource) -> LavaCondensedStatus?
    let customTitle: (CustomBlocklistSource) -> String
    let customEntryCount: (CustomBlocklistSource) -> Int?
    let toggle: (String) -> Void
    let requestDeleteCustomSource: (CustomBlocklistSource) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                switch item {
                case .catalog(let blocklist):
                    BlocklistPickerRow(
                        blocklist: blocklist,
                        isSelected: selectedIDs.contains(blocklist.id),
                        subtitle: catalogSubtitle(blocklist),
                        metadata: catalogMetadata(blocklist),
                        metadataPrefixStatus: catalogMetadataPrefixStatus(blocklist),
                        toggle: toggle
                    )
                case .custom(let source):
                    CustomBlocklistPickerRow(
                        source: source,
                        isSelected: selectedIDs.contains(source.id),
                        title: customTitle(source),
                        entryCount: customEntryCount(source),
                        toggle: toggle,
                        requestDelete: requestDeleteCustomSource
                    )
                }

                if index + 1 < items.count {
                    Divider()
                        .padding(.leading, 58)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FilterRuleBudgetBar: View {
    let status: AppViewModel.FilterRuleBudgetStatus
    let isError: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LavaStyle.secondaryText.opacity(0.16))
                // While counts are still resolving, leave the track empty rather
                // than painting a confident green 0% fill.
                if !status.isIndeterminate {
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(0, geo.size.width * status.fraction))
                }
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.2), value: status.fraction)
        .accessibilityElement()
        .accessibilityLabel("Filter rule budget")
        .accessibilityValue(status.isIndeterminate ? "calculating" : "\(Int((status.fraction * 100).rounded())) percent used")
    }

    private var barColor: Color {
        (isError || status.isAtOrOverBudget) ? LavaStyle.lavaOrange : LavaStyle.safeGreen
    }
}

private struct BlocklistPickerRow: View {
    let blocklist: BlocklistSource
    let isSelected: Bool
    let subtitle: String?
    let metadata: String?
    let metadataPrefixStatus: LavaCondensedStatus?
    let toggle: (String) -> Void

    var body: some View {
        Button {
            toggle(blocklist.id)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                BlocklistPickerSelectionGlyph(isSelected: isSelected)

                BlocklistPickerTextStack(
                    title: blocklist.name,
                    subtitle: subtitle,
                    metadata: metadata,
                    metadataPrefixStatus: metadataPrefixStatus,
                    titleLineLimit: 2
                )
                .layoutPriority(1)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CustomBlocklistPickerRow: View {
    let source: CustomBlocklistSource
    let isSelected: Bool
    let title: String
    let entryCount: Int?
    let toggle: (String) -> Void
    let requestDelete: (CustomBlocklistSource) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                toggle(source.id)
            } label: {
                HStack(alignment: .center, spacing: 14) {
                    BlocklistPickerSelectionGlyph(isSelected: isSelected)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title.lavaLocalized)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(LavaStyle.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .minimumScaleFactor(0.82)

                        Text("Custom List".lavaLocalized)
                            .lavaRowSubtitleText()

                        HStack(spacing: 8) {
                            BlocklistPickerStatusPill(status: metadataPrefixStatus)

                            Text(metadataText.lavaLocalized)
                                .lavaMetadataText()
                        }
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                requestDelete(source)
            } label: {
                Image(systemName: "trash")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete custom blocklist")
        }
    }

    private var metadataPrefixStatus: LavaCondensedStatus {
        if let entryCount {
            return .blocklistSizeBucket(entryCount: entryCount)
        }

        return LavaCondensedStatus(
            text: "?",
            foreground: LavaStyle.secondaryText,
            background: LavaStyle.secondaryText.opacity(0.12)
        )
    }

    private var metadataText: String {
        guard let entryCount else {
            return "Pending refresh"
        }

        return "%@ rules".lavaLocalizedFormat(entryCount.formatted())
    }
}

private struct BlocklistPickerSelectionGlyph: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3.weight(.semibold))
            .foregroundStyle(isSelected ? LavaStyle.safeGreen : LavaStyle.secondaryText)
            .frame(width: 44, height: 44)
    }
}

private struct BlocklistPickerTextStack: View {
    let title: String
    let subtitle: String?
    let metadata: String?
    let metadataPrefixStatus: LavaCondensedStatus?
    var titleLineLimit = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.lavaLocalized)
                .font(.headline.weight(.semibold))
                .foregroundStyle(LavaStyle.primaryText)
                .lineLimit(titleLineLimit)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle {
                Text(subtitle.lavaLocalized)
                    .lavaRowSubtitleText()
            }

            if metadataPrefixStatus != nil || metadata != nil {
                HStack(spacing: 8) {
                    if let metadataPrefixStatus {
                        BlocklistPickerStatusPill(status: metadataPrefixStatus)
                    }

                    if let metadata {
                        Text(metadata.lavaLocalized)
                            .lavaMetadataText()
                    }
                }
            }
        }
    }
}

private struct BlocklistPickerStatusPill: View {
    let status: LavaCondensedStatus

    var body: some View {
        Text(status.text.lavaLocalized)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(status.foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(status.background, in: Capsule())
    }
}

private enum CustomBlocklistFocusField: Hashable {
    case displayName
    case url
}

private struct BringYourOwnListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var customDisplayName = ""
    @State private var customURL = ""
    @State private var customMessage: String?
    @FocusState private var focusedField: CustomBlocklistFocusField?

    let isOverBudget: Bool
    let allowsCustomBlocklists: Bool
    let addCustomSource: (String, String) -> String?
    let showUpgrade: () -> Void

    var body: some View {
        LavaSheetScaffold(spacing: 18, scrolls: true) {
            if allowsCustomBlocklists {
                customListForm
            } else {
                upgradeRow
            }
        }
        .navigationTitle("Bring your own list")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var customListForm: some View {
        VStack(spacing: 12) {
            LavaTextInputPanel {
                LavaTextInputRow(title: "Name (optional)") {
                    TextField("My blocklist".lavaLocalized, text: $customDisplayName)
                        .lavaTextInputBody()
                        .focused($focusedField, equals: .displayName)
                }

                Divider()

                LavaTextInputRow(title: "Blocklist URL") {
                    TextField("https://example.com/pi-hole-style-list.txt".lavaLocalized, text: $customURL)
                        .lavaTextInputBody(keyboardType: .URL)
                        .focused($focusedField, equals: .url)
                }
            }

            Button(action: submit) {
                FilterActionLabel(title: "Add Blocklist", systemImage: "plus")
            }
                .buttonStyle(LavaStandaloneActionButtonStyle())
                .disabled(!canAddCustomSource)

            if let customSourceFooterText {
                Text(customSourceFooterText.lavaLocalized)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(LavaStyle.lavaOrange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            if let customMessage {
                DomainRejectPanel(title: "Custom source cannot be added", message: customMessage)
            }
        }
    }

    private var upgradeRow: some View {
        LavaPlainCard {
            Button {
                showUpgrade()
            } label: {
                HStack(spacing: 12) {
                    // One concatenated Text so the line flows and wraps as a single
                    // paragraph instead of "Upgrade" sitting in its own column beside
                    // a separately-wrapping remainder.
                    (Text("Upgrade".lavaLocalized)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(LavaStyle.safeGreen)
                     + Text(" to Lava Security Plus to bring your own list".lavaLocalized)
                        .font(.footnote)
                        .foregroundStyle(LavaStyle.secondaryText))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LavaStyle.panelActionGreen)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
    }

    private var trimmedCustomURL: String {
        customURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAddCustomSource: Bool {
        !trimmedCustomURL.isEmpty && !isOverBudget
    }

    private var customSourceFooterText: String? {
        if isOverBudget {
            return "Remove a list before adding another — you're at your filter-rule limit."
        }

        return nil
    }

    private func submit() {
        customMessage = nil
        if let error = addCustomSource(customDisplayName, trimmedCustomURL) {
            customMessage = error
            return
        }

        customDisplayName = ""
        customURL = ""
        dismiss()
    }
}

private struct AddBlockedDomainSheet: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var domain = ""
    @State private var result: DomainDraftResult?

    var body: some View {
        NavigationStack {
            LavaSheetScaffold(spacing: 18, scrolls: true) {
                DomainEntryForm(
                    domain: $domain,
                    placeholder: "example.com",
                    primaryActionTitle: primaryActionTitle,
                    usageText: usageText,
                    usageTextIsError: usageTextIsError,
                    isSubmitDisabled: isSubmitDisabled,
                    submit: addDomain
                )

                if let result, !result.isAccepted {
                    DomainRejectPanel(title: result.title, message: result.message)
                }
            }
            .navigationTitle("Add Blocked Domain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Cancel", role: .cancel, action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.height(sheetHeight)])
    }

    private var draftCount: Int {
        viewModel.filterEditDraft?.blockedDomains.count ?? viewModel.configuration.blockedDomains.count
    }

    private var limit: Int {
        viewModel.configuration.limits.maxBlockedDomains
    }

    private var usageText: String {
        if isFreeAtLimit {
            return "%d/%d blocked domains used - Upgrade or remove entries".lavaLocalizedFormat(draftCount, limit)
        }

        if draftCount >= limit {
            return "%d/%d blocked domains used - Remove entries to continue".lavaLocalizedFormat(draftCount, limit)
        }

        return "%d/%d blocked domains used".lavaLocalizedFormat(draftCount, limit)
    }

    private var usageTextIsError: Bool {
        draftCount >= limit
    }

    private var isFreeAtLimit: Bool {
        !viewModel.configuration.hasLavaSecurityPlus && draftCount >= limit
    }

    private var primaryActionTitle: String {
        isFreeAtLimit ? "Upgrade" : "Add Domain"
    }

    private var isSubmitDisabled: Bool {
        if isFreeAtLimit {
            return false
        }

        return domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftCount >= limit
    }

    private var sheetHeight: CGFloat {
        340
    }

    private func addDomain() {
        let addResult = viewModel.addBlockedDomainToDraft(domain)
        result = addResult
        if addResult.isAccepted {
            dismiss()
        }
    }
}

private struct AddAllowedExceptionSheet: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var domain = ""
    @State private var result: DomainDraftResult?

    var body: some View {
        NavigationStack {
            LavaSheetScaffold(spacing: 18, scrolls: true) {
                DomainEntryForm(
                    domain: $domain,
                    placeholder: "trusted.example.com",
                    primaryActionTitle: primaryActionTitle,
                    usageText: usageText,
                    usageTextIsError: usageTextIsError,
                    isSubmitDisabled: isSubmitDisabled,
                    submit: addDomain
                )

                if let result, !result.isAccepted {
                    DomainRejectPanel(title: result.title, message: result.message)
                }
            }
            .navigationTitle("Add Allowed Exception")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Cancel", role: .cancel, action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.height(sheetHeight)])
    }

    private var draftCount: Int {
        viewModel.filterEditDraft?.allowedDomains.count ?? viewModel.configuration.allowedDomains.count
    }

    private var limit: Int {
        viewModel.configuration.limits.maxAllowedDomains
    }

    private var usageText: String {
        if isFreeAtLimit {
            return "%d/%d exceptions used - Upgrade or remove entries".lavaLocalizedFormat(draftCount, limit)
        }

        if draftCount >= limit {
            return "%d/%d exceptions used - Remove entries to continue".lavaLocalizedFormat(draftCount, limit)
        }

        return "%d/%d exceptions used".lavaLocalizedFormat(draftCount, limit)
    }

    private var usageTextIsError: Bool {
        draftCount >= limit
    }

    private var isFreeAtLimit: Bool {
        !viewModel.configuration.hasLavaSecurityPlus && draftCount >= limit
    }

    private var primaryActionTitle: String {
        isFreeAtLimit ? "Upgrade" : "Add Exception"
    }

    private var isSubmitDisabled: Bool {
        if isFreeAtLimit {
            return false
        }

        return domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftCount >= limit
    }

    private var sheetHeight: CGFloat {
        340
    }

    private func addDomain() {
        let addResult = viewModel.addAllowedDomainToDraft(domain)
        result = addResult
        if addResult.isAccepted {
            dismiss()
        }
    }
}
