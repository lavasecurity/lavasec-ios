import SwiftUI

/// Consolidated "My list" surface: the two-shelf (block / allow) view presented as a
/// full-screen cover with one unified Edit + Save. The edit draft is whole; "is editing" is
/// simply whether the shown filter has a per-filter draft (`viewModel.isFilterEditing`).
struct MyListCover: View {
    // The filter this page was opened for (nil = active). The page re-asserts this on appear so it
    // self-heals if something cleared/changed the global target while it stayed mounted but off
    // screen (a tab switch keeps it pushed; e.g. a Domain History action resets the target).
    let detailTargetID: String?

    init(detailTargetID: String?) {
        self.detailTargetID = detailTargetID
    }

    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var catalog: CatalogController
    @EnvironmentObject private var security: SecurityController
    @Environment(\.dismiss) private var dismiss
    @State private var activeSheet: BlockedDomainSheet?
    @State private var showingAddException = false
    @State private var showingConfirmation = false
    @State private var showingDiscardConfirmation = false
    // A non-active filter save reports validation/write failures inline (it has no prepare cover).
    @State private var nonActiveSaveError: String?

    var body: some View {
        LavaScreenContent(
            spacing: 22,
            // A non-active filter isn't loaded — honor "don't refresh nor load it": no
            // pull-to-refresh (the active filter keeps its catalog sync).
            refreshAction: viewModel.isViewingNonActiveFilter ? nil : {
                await catalog.sync()
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
        // The shown filter's own name — the active filter, or a non-active "View" target
        // (not a generic "My filter"); the inline title truncates when too long for the bar.
        .navigationTitle(viewModel.detailFilter.name)
        .navigationBarTitleDisplayMode(.inline)
        .lavaTier(.calm)
        // Hide the system Back button while editing so a stray tap can't abandon the
        // draft. An interactive edge-swipe can still pop the page; that path keeps a dirty
        // draft in its per-filter slot (see endViewingFilterDetail), so no edits are lost.
        .navigationBarBackButtonHidden(isEditing)
        .toolbar {
            if isEditing {
                FilterEditToolbar(
                    canSave: viewModel.filterDraftHasChanges,
                    closeEditing: closeEditing,
                    save: saveChanges
                )
            } else {
                // A ToolbarItemGroup lets the system merge the two glyphs into one
                // native glass capsule (with a divider) — no custom background. The
                // page is pushed, so the system Back button handles dismissal.
                ToolbarItemGroup(placement: .primaryAction) {
                    // A non-active filter isn't loaded, so there's nothing to refresh into
                    // effect — only the active filter shows the manual catalog-refresh glyph.
                    if !viewModel.isViewingNonActiveFilter {
                        NativeToolbarIconButton(
                            systemName: "arrow.clockwise",
                            accessibilityLabel: "Refresh now",
                            action: { Task { await catalog.sync() } }
                        )
                        .disabled(catalog.isSyncInFlight)
                    }

                    // A frozen (lapsed-Plus, over-cap) filter is read-only — inspect only, no Edit.
                    if !isReadOnly {
                        NativeToolbarIconButton(
                            systemName: "square.and.pencil",
                            accessibilityLabel: "Edit",
                            action: beginEditing
                        )
                    }
                }
            }
        }
        // NOTE: teardown (endViewingFilterDetail) is driven by the navigation binding in the
        // parent — NOT onDisappear. onDisappear also fires when a fullScreenCover (e.g. the
        // passcode auth prompt presented over Edit/Save) covers this page, which would wrongly
        // clear the non-active target/draft mid-flow; the binding only fires on a real pop.
        .onAppear {
            // If the non-active filter this page was opened for no longer exists (the library was
            // replaced off-screen by a restore/import while this stayed pushed), there's nothing to
            // show — dismiss rather than re-asserting a dead id (which would strand the page in
            // non-active mode with a no-op save).
            if let id = detailTargetID, viewModel.library.filter(id: id) == nil {
                dismiss()
                return
            }
            // Self-heal: if the global target no longer matches the filter this page was opened
            // for (e.g. a Domain History action under the Settings tab reset it while this page
            // stayed pushed on the Guard tab), re-establish it so the page shows its own filter
            // rather than the active one. Conditional so it's a no-op in the common case (and never
            // disturbs an active apply's preparation state, where target and detailTargetID stay nil).
            if viewModel.filterEditTargetID != detailTargetID {
                viewModel.beginViewingFilterDetail(id: detailTargetID)
            }
            // If the filter became read-only (Plus lapsed → frozen) while a draft was preserved,
            // drop the draft so the page resumes in read-only view mode instead of a stuck edit
            // mode whose Save silently no-ops.
            if isReadOnly, viewModel.filterEditDraft != nil {
                viewModel.cancelFilterEditing()
            }
        }
        .task {
            // Auto-refresh on open: cheap when nothing changed (the snapshot-identity
            // gate skips the re-encode + tunnel reload), so opening My list keeps the
            // lists current without a heavy rebuild or a spurious reconnect. Skip entirely
            // for a non-active filter — it isn't loaded, so there's nothing to refresh.
            if !viewModel.isViewingNonActiveFilter {
                await catalog.sync()
            }
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
        .alert(
            "Couldn't save",
            isPresented: Binding(
                get: { nonActiveSaveError != nil },
                set: { if !$0 { nonActiveSaveError = nil } }
            ),
            presenting: nonActiveSaveError
        ) { _ in
            Button("OK", role: .cancel) { nonActiveSaveError = nil }
        } message: { message in
            Text(message.lavaLocalized)
        }
    }

    @ViewBuilder private var rulesPanel: some View {
        if viewModel.isViewingNonActiveFilter {
            nonActiveRulesPanel
        } else {
            activeRulesPanel
        }
    }

    @ViewBuilder private var activeRulesPanel: some View {
        LavaInfoCard {
            VStack(alignment: .leading, spacing: 12) {
                LavaOverviewMetricBlock(
                    value: viewModel.configuredProtectedDomainNumberText,
                    label: "rules in effect"
                )

                if viewModel.library.activeFilter.isEmpty {
                    // A loaded filter with nothing to block is zero protection, not calm
                    // silence — alarm treatment, not the neutral freshness line.
                    (Text(Image(systemName: "exclamationmark.shield.fill"))
                        + Text(" \("Blocks nothing — not protected".lavaLocalized)"))
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(LavaStyle.lavaOrangeText)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    (Text(Image(systemName: viewModel.blocklistCatalogFreshnessSystemImage))
                        .foregroundColor(viewModel.blocklistCatalogFreshnessTint)
                        + Text(" \(viewModel.blocklistCatalogFreshnessTitle.lavaLocalized)")
                        .foregroundColor(LavaStyle.secondaryText))
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    /// A non-active filter isn't loaded, so it has no "in effect" / freshness state. Show its
    /// projected rule count and a plain "not in effect" line — honest about the fact that
    /// viewing/editing it changes nothing live until the user Applies it.
    @ViewBuilder private var nonActiveRulesPanel: some View {
        LavaInfoCard {
            VStack(alignment: .leading, spacing: 12) {
                LavaOverviewMetricBlock(
                    value: viewModel.filterRuleCount(for: viewModel.detailFilter).formatted(),
                    label: "rules"
                )

                if viewModel.detailFilter.isEmpty {
                    (Text(Image(systemName: "exclamationmark.shield.fill"))
                        + Text(" \("Blocks nothing".lavaLocalized)"))
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(LavaStyle.lavaOrangeText)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    (Text(Image(systemName: "pause.circle"))
                        + Text(" \("Not the filter in effect".lavaLocalized)"))
                        .font(.footnote)
                        .foregroundColor(LavaStyle.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    @ViewBuilder private var blockShelfRows: some View {
        let sourceIDs = viewModel.stagedBlocklistIDsForDisplay()
        let blockedDomains = viewModel.stagedBlockedDomainsForDisplay()
        if sourceIDs.isEmpty && blockedDomains.isEmpty {
            LavaEmptyListRow(
                title: "No blocklists enabled",
                subtitle: editSubtitle("Add a curated blocklist to start blocking known domains")
            )
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
            LavaEmptyListRow(
                title: "No allowed exceptions",
                subtitle: isEditing ? "Add only domains you trust" : nil
            )
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
        viewModel.isFilterEditing
    }

    /// A frozen (lapsed-Plus, over-cap) non-active filter is read-only — viewable but not editable.
    /// (The active filter is never frozen, so the active detail is always editable.)
    private var isReadOnly: Bool {
        guard let id = detailTargetID else { return false }
        return viewModel.isFilterFrozen(id)
    }

    private func closeEditing() {
        if viewModel.filterDraftHasChanges {
            showingDiscardConfirmation = true
        } else {
            viewModel.cancelFilterEditing()
        }
    }

    private func beginEditing() {
        // Frozen filters are read-only (the Edit affordance is hidden); guard here too so a stale
        // call can't start an edit that the save path would reject anyway.
        guard !isReadOnly else { return }
        Task {
            guard await security.requireAuthentication(for: .filterEditing, reason: "Edit filter") else {
                return
            }

            viewModel.beginFilterEditing()
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

            // A non-active filter isn't loaded, so its save is library-only: no prepare cover,
            // and no weaken-protection review (the diff copy "reduce your protection" would be
            // untrue for a filter that isn't running). A validation/write failure returns an
            // inline message instead of presenting the full-screen failure cover.
            if viewModel.isViewingNonActiveFilter {
                nonActiveSaveError = viewModel.saveNonActiveFilterDraft()
                return
            }

            let diff = viewModel.filterDraftDiff
            let weakensProtection = !diff.removedBlocklistIDs.isEmpty
                || !diff.removedBlockedDomains.isEmpty
                || !diff.addedAllowedDomains.isEmpty

            if weakensProtection {
                showingConfirmation = true
            } else {
                await viewModel.prepareAndApplyFilterDraft(origin: .filters)
            }
        }
    }
}

private enum BlockedDomainSheet: String, Identifiable {
    case blocklist
    case blockedDomain

    var id: String { rawValue }
}

private struct FilterEditToolbar: ToolbarContent {
    let canSave: Bool
    let closeEditing: () -> Void
    let save: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close edit mode", role: .cancel, accessibilityInputLabels: ["Close".lavaLocalized, "Done".lavaLocalized], action: closeEditing)
        }

        ToolbarItem(placement: .confirmationAction) {
            NativeToolbarIconButton(systemName: "checkmark", accessibilityLabel: "Save", role: .confirm, action: save)
                .disabled(!canSave)
        }
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
                    .lavaRowTitleText()
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
                .lavaRowTitleText()
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
        // Same floor as BlocklistEffectRow: it has to clear the 44pt edit-mode delete
        // button (44 + 18 vertical padding = 62) so the row keeps one height across
        // view and edit. The old 56 floor was below that, so entering edit grew a
        // single-domain row ~6pt and made it visibly jump while the taller blocklist
        // rows stayed put.
        .frame(minHeight: 64)
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
