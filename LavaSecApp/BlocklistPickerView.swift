import SwiftUI
import LavaSecKit

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
    @State private var activeSectionID: String?
    /// Live height of the pinned header bar's content (category pills, plus the search
    /// field only in `.filterDraft`). Feeds the pill-jump top inset so the landing point
    /// tracks the header's real height instead of a fixed guess — the header is ~70pt
    /// shorter in `.onboardingSelection`, where the search field is absent, so no single
    /// constant clears both usages. See `BlocklistJumpMetrics.topInset(pinnedHeaderHeight:)`.
    @State private var pinnedHeaderHeight: CGFloat = 0
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
            // The scaffold hosts its OWN ScrollViewReader (`hostsScrollProxy`) so the pinned
            // jump-pills can scroll the list without wrapping the whole scaffold in a reader.
            // That external wrapping put the scaffold's fill-frame inside the reader, collapsing
            // the scroll surface — the footer floated mid-content and the pinned header landed
            // wrong (lavasec-ios#326 follow-up). The pills reach the list via the scaffold's
            // published `\.lavaSheetScrollProxy` inside `BlocklistJumpPillBar`.
            LavaSheetScaffold(spacing: 18, hostsScrollProxy: true) {
                    // Pinned header — category pills on top, then the search field —
                    // so they stay put against the title bar while the list scrolls
                    // (mirrors the Activity date-range picker's pinned header).
                    VStack(alignment: .leading, spacing: 12) {
                        // Tappable category pills that jump to each section (search
                        // also matches category names, so this list tracks results).
                        if !visibleSections.isEmpty {
                            BlocklistJumpPillBar(
                                sections: visibleSections,
                                activeSectionID: $activeSectionID
                            )
                        }

                        if usage == .filterDraft {
                            BlocklistSearchField(text: $searchText)
                        }
                    }
                    // Measure the pinned header so pill-jumps land the section title below
                    // it (not clipped under it). Tracks Dynamic Type growth and the search
                    // field's presence, both of which change the header height.
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { newHeight in
                        pinnedHeaderHeight = newHeight
                    }
            } content: {
                    VStack(alignment: .leading, spacing: 18) {
                        if visibleSections.isEmpty {
                            LavaCondensedList {
                                LavaEmptyListRow(
                                    title: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? "No blocklists available"
                                        : "No blocklists found"
                                )
                            }
                        } else {
                            ForEach(visibleSections) { section in
                                LavaSectionGroup(section.title) {
                                    BlocklistPickerList(
                                        items: section.items,
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
                                .blocklistJumpAnchor(id: section.id, pinnedHeaderHeight: pinnedHeaderHeight)
                            }
                        }

                        if let message {
                            DomainRejectPanel(title: "Selection cannot be added", message: message)
                        }
                    }
            } footer: {
                VStack(spacing: 9) {
                    Button(action: primaryAction) {
                        Text(actionButtonTitle.lavaLocalized)
                    }
                        .buttonStyle(LavaStandaloneActionButtonStyle())
                        .disabled(!canUsePrimaryAction)

                    FilterRuleBudgetBar(status: filterRuleBudgetStatus, isError: selectionStatusIsError)

                    Text(selectionStatusText.lavaLocalized)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(selectionStatusIsError ? LavaStyle.lavaOrangeText : LavaStyle.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(navigationTitle.lavaLocalized)
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
            // Select Blocklists + the Bring-your-own-list page it pushes are
            // Workshop-depth power-user surfaces.
            .lavaTier(.technical)
        }
        // Extended bottom sheet (single large detent, no resize/drag handle) —
        // matches the Share-my-filter sheet rather than a half-height detent.
        .presentationDetents([.large])
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

    /// The search-filtered picker grouped into display sections: one per non-empty
    /// blocklist category (in taxonomy order), then a trailing "Your Lists" section
    /// for custom lists. Drives both the jump-pills and the sectioned list.
    private var visibleSections: [BlocklistPickerSection] {
        let filtered = filteredPickerItems
        var sections: [BlocklistPickerSection] = []

        for category in BlocklistCategory.allCases.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let items = filtered.filter { $0.catalogCategory == category }
            if !items.isEmpty {
                sections.append(BlocklistPickerSection(id: category.rawValue, title: category.displayLabel, items: items))
            }
        }

        let customItems = filtered.filter(\.isCustom)
        if !customItems.isEmpty {
            sections.append(BlocklistPickerSection(id: "custom", title: "Your Lists", items: customItems))
        }

        return sections
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
            return (status.pendingLists == 1 ? "Calculating rule usage… (%@ list pending)" : "Calculating rule usage… (%@ lists pending)").lavaLocalizedFormat(status.pendingLists.formatted())
        }

        let used = AppViewModel.abbreviatedRuleCount(status.displayedRuleCount)
        let budget = AppViewModel.abbreviatedRuleCount(status.budget)
        var text: String
        if isFreeOverLimit {
            text = "About %1$@ of %2$@ rules · Upgrade or remove a list".lavaLocalizedFormat(used, budget)
        } else if selectionStatusIsError {
            text = "About %1$@ of %2$@ rules · Remove a list to continue".lavaLocalizedFormat(used, budget)
        } else {
            text = "About %1$@ of %2$@ rules".lavaLocalizedFormat(used, budget)
        }
        if status.pendingLists > 0 {
            text += " " + "(+%@ pending)".lavaLocalizedFormat(status.pendingLists.formatted())
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

            TextField("Search lists or categories", text: $text)
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

    /// The display category for a catalog source; `nil` for custom lists (which get
    /// their own trailing section).
    var catalogCategory: BlocklistCategory? {
        switch self {
        case .catalog(let source):
            source.category
        case .custom:
            nil
        }
    }

    var isCustom: Bool {
        if case .custom = self {
            return true
        }
        return false
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
            // Include the category label — both the English key and its localized
            // form — so a search for "ads"/"adult"/"gambling" (or the user's own
            // language) surfaces every list in that section, not just name matches.
            [source.name, source.licenseName, source.category.displayLabel, source.category.displayLabel.lavaLocalized]
        case .custom(let source):
            [source.displayName, source.sourceURL.absoluteString, "Custom List"]
        }
    }
}

private struct BlocklistPickerSection: Identifiable {
    let id: String
    let title: String
    let items: [BlocklistPickerItem]
}

/// Pinned-header wrapper that wires the category pills to the scaffold's scroll surface.
/// It reads the proxy the scaffold publishes via `\.lavaSheetScrollProxy` — this view is
/// rendered inside the scaffold's `hostsScrollProxy` reader, so the proxy is present. Reading
/// it HERE (not in `AddBlocklistSheet.body`, which sits outside the reader) is what lets the
/// pinned header drive the list without an external `ScrollViewReader` wrapping — and
/// collapsing — the whole scaffold (lavasec-ios#326 follow-up).
private struct BlocklistJumpPillBar: View {
    let sections: [BlocklistPickerSection]
    @Binding var activeSectionID: String?
    @Environment(\.lavaSheetScrollProxy) private var scrollProxy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BlocklistCategoryJumpPills(
            sections: sections,
            activeSectionID: activeSectionID
        ) { sectionID in
            activeSectionID = sectionID
            withAnimation(LavaFlowTransition.incidental(.easeInOut(duration: 0.25), reduceMotion: reduceMotion)) {
                scrollProxy?.scrollTo(BlocklistJumpMetrics.anchorID(for: sectionID), anchor: .top)
            }
        }
    }
}

/// A horizontally scrollable row of category pills shown under the search box. Tapping
/// a pill scrolls the list to that section. The active pill is tinted.
private struct BlocklistCategoryJumpPills: View {
    let sections: [BlocklistPickerSection]
    let activeSectionID: String?
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sections) { section in
                    let isActive = section.id == activeSectionID
                    Button {
                        onSelect(section.id)
                    } label: {
                        Text(section.title.lavaLocalized)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isActive ? Color.white : LavaStyle.primaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(isActive ? LavaStyle.lavaOrangeSelectedFill : LavaStyle.secondaryText.opacity(0.12))
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(section.title)
                    .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .accessibilityLabel("Jump to category")
    }
}

private enum BlocklistJumpMetrics {
    /// Visible breathing gap between the pinned header bar's bottom edge and a section
    /// title after a pill-jump.
    static let headerBottomGap: CGFloat = 12

    /// `LavaSheetScaffold.headerBar` wraps the header content in `.padding(.top, 12)` +
    /// `.padding(.bottom, 10)`; the measured `pinnedHeaderHeight` covers only the content,
    /// so this adds that chrome back when sizing the jump inset. Kept in sync with that
    /// scaffold padding by hand (the scaffold metric is file-private).
    static let scaffoldHeaderVerticalPadding: CGFloat = 22

    /// Inset placed above a section's jump anchor. `scrollTo(anchor: .top)` aligns the
    /// target to the scroll view's bounds top, which sits *behind* the pinned header bar
    /// (a `.safeAreaInset` header the scroll math doesn't subtract), so a zero inset tucks
    /// the section title up under the header and clips it. Sizing the inset from the LIVE
    /// header height lands the title a `headerBottomGap` below the header instead — and,
    /// unlike the old fixed 20pt, clears both usages: `.onboardingSelection` omits the
    /// search field, leaving a ~70pt shorter header, so one constant can't fit both. See
    /// `blocklistJumpAnchor(id:pinnedHeaderHeight:)`.
    static func topInset(pinnedHeaderHeight: CGFloat) -> CGFloat {
        pinnedHeaderHeight + scaffoldHeaderVerticalPadding + headerBottomGap
    }

    /// Scroll-anchor id for a section's jump target. Kept distinct from the section's
    /// own `section.id` (which `ForEach(visibleSections)` already registers as a scroll
    /// target via its element identity) so `scrollTo` resolves unambiguously to the
    /// offset anchor instead of the section frame — otherwise the jump can still land
    /// the title under the pinned header.
    static func anchorID(for sectionID: String) -> String {
        "jump-anchor-\(sectionID)"
    }
}

extension View {
    /// Marks a blocklist section as a jump target for the category pills. The actual
    /// scroll anchor lives in a zero-size background placed
    /// `BlocklistJumpMetrics.topInset(pinnedHeaderHeight:)` *above* the section, under a
    /// distinct id (`BlocklistJumpMetrics.anchorID(for:)`), so `scrollTo(anchor: .top)`
    /// leaves a gap below the pinned header instead of clipping the section title against
    /// it. The inset tracks the live `pinnedHeaderHeight` so it clears the header at any
    /// Dynamic Type size and in either usage. Hosting the anchor in a background keeps it
    /// out of the section's own layout (no visible spacing change).
    func blocklistJumpAnchor(id sectionID: String, pinnedHeaderHeight: CGFloat) -> some View {
        background(alignment: .top) {
            Color.clear
                .frame(width: 1, height: 1)
                .alignmentGuide(.top) { dimension in
                    dimension[.top] + BlocklistJumpMetrics.topInset(pinnedHeaderHeight: pinnedHeaderHeight)
                }
                .id(BlocklistJumpMetrics.anchorID(for: sectionID))
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
                        .padding(.leading, 16)
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
            LavaSelectableRow(
                state: isSelected ? .selected : .unselected,
                verticalPadding: 13
            ) {
                BlocklistPickerTextStack(
                    title: blocklist.name,
                    subtitle: subtitle,
                    metadata: metadata,
                    metadataPrefixStatus: metadataPrefixStatus,
                    titleLineLimit: 2
                )
            }
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
                LavaSelectableRow(
                    state: isSelected ? .selected : .unselected,
                    verticalPadding: 13
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title.lavaLocalized)
                            .lavaRowTitleText()
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
                }
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

private struct BlocklistPickerTextStack: View {
    let title: String
    let subtitle: String?
    let metadata: String?
    let metadataPrefixStatus: LavaCondensedStatus?
    var titleLineLimit = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.lavaLocalized)
                .lavaRowTitleText()
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
        .navigationTitle("Bring your own list".lavaLocalized)
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
                    TextField("https://example.com/pi-hole-style-list.txt", text: $customURL)
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
                    .foregroundStyle(LavaStyle.lavaOrangeText)
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
