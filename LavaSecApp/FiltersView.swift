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
    @State private var isShowingAllFilters = false

    init(scrollToTopTrigger: Int = 0, embedsNavigationStack: Bool = true) {
        self.scrollToTopTrigger = scrollToTopTrigger
        self.embedsNavigationStack = embedsNavigationStack
    }

    /// Withholds the in-app import sheet while App Unlock is pending OR the
    /// app-switcher privacy mask is up. The sheet presents above the root
    /// app-unlock overlay and runs a live QR scanner / import preview, so on a
    /// background-lock it must be torn down — not just covered — so the camera
    /// stops and no scanned/preview content sits above the lock. Keying on the
    /// privacy-mask flag too (set on `.inactive`, before `.background` flips the
    /// lock) keeps the live scanner out of the app-switcher snapshot. The
    /// fresh-auth gate only protects *applying* an import, not reading the sheet.
    /// While obscured the binding reads `false` (no sheet); once clear the staged
    /// request re-presents. Mirrors the deeplink importer's `importDeepLinkSheetItem`.
    private var importFiltersSheetBinding: Binding<Bool> {
        Binding {
            isImportingFilters && !(security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible)
        } set: { newValue in
            isImportingFilters = newValue
        }
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
        .sheet(isPresented: importFiltersSheetBinding) {
            ImportFiltersFlow(
                startMode: .chooseMethod,
                authorizeImport: {
                    await security.requireFreshAuthentication(for: .filterEditing, reason: "Import filter")
                }
            )
            .environmentObject(viewModel)
        }
        // Single owner for the filter-preparation cover across the whole Filters tab. Both
        // MyListCover (edit-apply) and AllFiltersView (switch) — including a MyListCover pushed
        // from AllFiltersView — are nav-pushed under this body, so binding the cover once here
        // avoids two covers racing on the same isFilterPreparationScreenPresented state. This tab
        // body stays mounted, so ALSO gate on a Filters origin: otherwise a Domain History action
        // (Diagnostics tab) would present this cover with the wrong origin / no "back to review".
        .fullScreenCover(isPresented: Binding(
            get: { viewModel.isFilterPreparationScreenPresented && viewModel.filterPreparationOrigin == .filters },
            set: { if !$0 { viewModel.isFilterPreparationScreenPresented = false } }
        )) {
            FilterPreparationScreen(origin: .filters)
                .environmentObject(viewModel)
        }
    }

    private var filtersScreen: some View {
        LavaPrimaryTabScreenContent(
            title: "Filters",
            scrollToTopTrigger: scrollToTopTrigger,
            refreshAction: {
                await viewModel.syncCatalog()
            }
        ) {
            FiltersOverviewPanel()
        } content: {
            LavaSectionGroup("What's filtering?") {
                VStack(spacing: 10) {
                    FilterInEffectRow {
                        // "Now filtering" opens the ACTIVE filter. Per-filter drafts mean opening it
                        // resumes only the active filter's own draft — no other filter's edit is at
                        // risk, so no discard confirmation is needed.
                        viewModel.beginViewingFilterDetail(id: nil)
                        isShowingMyList = true
                    }

                    ImportOptionRow(
                        // Same list glyph as Guard's "How Lava filters" row (LavaIconRole.filters),
                        // so the library entry reads as the same concept across surfaces.
                        systemImage: "line.3.horizontal.decrease.circle",
                        title: "Your filters",
                        subtitle: "Switch or manage the filters"
                    ) {
                        isShowingAllFilters = true
                    }
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
        .navigationDestination(
            // Same teardown-on-pop as the All-filters detail: a transient cover (auth prompt)
            // must not tear down the edit context, only a genuine pop. Active filter here, so
            // teardown routes through endViewingFilterDetail (drops a clean draft, keeps a dirty one).
            isPresented: Binding(
                get: { isShowingMyList },
                set: { presented in
                    isShowingMyList = presented
                    if !presented { viewModel.endViewingFilterDetail() }
                }
            )
        ) {
            // "Now filtering" always shows the active filter.
            MyListCover(detailTargetID: nil)
                .environmentObject(viewModel)
                .environmentObject(security)
        }
        .navigationDestination(isPresented: $isShowingAllFilters) {
            AllFiltersView()
                .environmentObject(viewModel)
                .environmentObject(security)
        }
        .navigationDestination(isPresented: $isSharingFilters) {
            ChooseFilterToShareView()
                .environmentObject(viewModel)
        }
    }
}

/// The "Filter in effect" row on the Filters tab: the loaded filter's name + a status
/// line (rule count + freshness), or an alarm treatment when the loaded filter would
/// block nothing — a loaded-but-empty filter is zero protection, not calm silence.
private struct FilterInEffectRow: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let action: () -> Void

    var body: some View {
        let activeFilter = viewModel.library.activeFilter
        let isUnprotected = activeFilter.isEmpty
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: isUnprotected ? "exclamationmark.shield.fill" : "play.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isUnprotected ? LavaStyle.lavaOrange : LavaStyle.safeGreen)
                    .frame(width: 38, height: 38)
                    .background(
                        (isUnprotected ? LavaStyle.lavaOrange.opacity(0.12) : LavaStyle.softGreen),
                        in: RoundedRectangle(cornerRadius: LavaSurface.iconBadgeCornerRadius)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Now filtering".lavaLocalized)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if isUnprotected {
                        Text("Blocks nothing — not protected".lavaLocalized)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LavaStyle.lavaOrange)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        // Description is the active filter's name; truncate (don't shrink)
                        // so a long name stays at full size with a trailing ellipsis.
                        Text(activeFilter.name)
                            .font(.subheadline)
                            .foregroundStyle(LavaStyle.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lavaSurface(.card)
            .contentShape(RoundedRectangle(cornerRadius: LavaSurface.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// The "All filters" library: the user hosts many filters but loads one. Tap a filter
/// to use it (switch); the in-effect filter opens its detail. Edit mode adds / renames /
/// deletes. Creating a 2nd filter is Plus-gated; on a lapsed Plus the extra filters are
/// frozen (read-only, can't be switched to) but never deleted.
private struct AllFiltersView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController

    @State private var isEditing = false
    @State private var isShowingCreate = false
    @State private var isShowingPaywall = false
    // Tapping the moon glyph opens the Focus-filter how-to (all tiers — no paywall).
    @State private var isShowingFocusInfo = false
    @State private var isShowingDetail = false
    // Blocklist-style staged deletion: tapping a row's delete only marks it here; the toolbar
    // checkmark (enabled only while this is non-empty) opens a confirmation bottom sheet that
    // commits. Cleared on cancel/exit so leaving edit mode discards unconfirmed deletions.
    @State private var stagedDeletions: Set<String> = []
    @State private var isShowingDeleteConfirm = false
    // Tapping xmark with staged (unconfirmed) deletions confirms before discarding them.
    @State private var isShowingDiscardConfirm = false
    @State private var renamingFilter: Filter?
    @State private var isShowingRestoreConfirm = false
    // Plus user tried to add past the 10-filter cap (free users hit the paywall instead).
    @State private var isShowingMaxFiltersAlert = false
    // A non-active filter was tapped: offer Apply (switch to it) or View (open its detail to
    // read/edit it without loading it). The active filter opens its detail directly (no dialog).
    @State private var filterActionChoice: Filter?
    // Which filter the pushed detail page was opened for (nil = active), so MyListCover can
    // re-assert its identity if the global target is changed out from under it.
    @State private var detailNavTargetID: String?

    var body: some View {
        LavaScreenContent(spacing: 22) {
            // Brief orientation panel; uses the same glyph as the "Your filters" entry row.
            LavaInfoPanel(
                title: "How filters work",
                description: "Each filter is its own set of blocklists. Apply one to make it the filter in effect — your others stay saved.",
                systemImage: "line.3.horizontal.decrease.circle",
                tint: LavaStyle.safeGreen
            )

            LavaCondensedList {
                let filters = viewModel.filters
                ForEach(filters) { filter in
                    FilterLibraryRow(
                        filter: filter,
                        isActive: filter.id == viewModel.activeFilterID,
                        isFrozen: viewModel.isFilterFrozen(filter.id),
                        isEditing: isEditing,
                        isPendingDeletion: stagedDeletions.contains(filter.id),
                        canDelete: filters.count > 1
                            && filter.id != viewModel.activeFilterID
                            && !viewModel.isFilterFrozen(filter.id),
                        ruleSummary: ruleSummary(for: filter),
                        // Tapping a non-active filter asks Apply-or-View; the actual switch
                        // (with its fresh-auth gate) runs from the dialog's Apply button.
                        chooseAction: { filterActionChoice = filter },
                        openDetail: {
                            // Per-filter drafts: opening the active filter resumes only its own
                            // draft, so no discard confirmation is needed.
                            presentActiveDetail()
                        },
                        rename: { renamingFilter = filter },
                        // Deletion only STAGES here (blocklist-style); the toolbar checkmark
                        // confirms via a bottom sheet. Tapping again un-stages.
                        toggleDelete: { toggleStagedDeletion(filter.id) }
                    )

                    if filter.id != filters.last?.id {
                        LavaCondensedDivider()
                    }
                }

                if isEditing {
                    FilterAddButton(title: "Add a filter", systemImage: "plus") {
                        if viewModel.canCreateFilter {
                            isShowingCreate = true
                        } else if viewModel.configuration.hasLavaSecurityPlus {
                            // Plus is at its 10-filter cap — inform, don't paywall (already Plus).
                            isShowingMaxFiltersAlert = true
                        } else {
                            isShowingPaywall = true
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                }
            }

            if isEditing {
                restoreDefaultsButton
            }

            filtersFooterNote
        }
        .navigationTitle("Your filters".lavaLocalized)
        .navigationBarTitleDisplayMode(.inline)
        .lavaTier(.calm)
        // Leaving edit mode by ANY path (xmark, restore-defaults, etc.) discards unconfirmed
        // staged deletions — so a stale stage can't survive into the next edit session and act on
        // same-ID restored defaults (Codex P2). The commit path deletes before this fires.
        .onChange(of: isEditing) { _, editing in
            if !editing { stagedDeletions = [] }
        }
        // Hide the system Back button while editing so the leading slot is the xmark
        // close (matching My filter's edit mode); a stray back-tap can't slip out.
        .navigationBarBackButtonHidden(isEditing)
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close edit mode", role: .cancel) {
                        // Confirm before discarding staged deletions; otherwise just leave edit mode
                        // (onChange(of: isEditing) clears the — empty — staged set).
                        if stagedDeletions.isEmpty {
                            isEditing = false
                        } else {
                            isShowingDiscardConfirm = true
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Blocklist-style: the checkmark is the prominent (blue) confirm only while
                    // there are staged deletions; tapping it opens the confirmation bottom sheet.
                    // With nothing staged it's dimmed/disabled — leave edit mode via the xmark.
                    NativeToolbarIconButton(systemName: "checkmark", accessibilityLabel: "Confirm deletions", role: .confirm) {
                        isShowingDeleteConfirm = true
                    }
                    .disabled(stagedDeletions.isEmpty)
                }
            } else {
                ToolbarItemGroup(placement: .primaryAction) {
                    // A moon "signpost" to the Focus auto-switch how-to, immediately LEFT of the
                    // edit pencil and only in the non-editing branch (so it's hidden in edit mode).
                    // Focus auto-switch is available to all tiers (no paywall), so every user gets
                    // the how-to.
                    NativeToolbarIconButton(
                        systemName: "moon",
                        accessibilityLabel: "Switch filters with a Focus"
                    ) {
                        isShowingFocusInfo = true
                    }
                    NativeToolbarIconButton(systemName: "square.and.pencil", accessibilityLabel: "Edit") {
                        Task {
                            // Edit mode enables add / rename / delete — gate it on the
                            // filter-editing surface, like My filter's edit entry point.
                            guard await security.requireAuthentication(
                                for: .filterEditing,
                                reason: "Manage filters"
                            ) else { return }
                            isEditing = true
                        }
                    }
                }
            }
        }
        .navigationDestination(
            // Tear down the detail edit context when the page is actually POPPED (back button or
            // edge-swipe flip this binding to false), not when a transient fullScreenCover (auth
            // passcode prompt) merely covers it — onDisappear can't tell those apart, and clearing
            // a non-active target/draft mid-auth would silently re-point Edit/Save at the active
            // filter.
            isPresented: Binding(
                get: { isShowingDetail },
                set: { presented in
                    isShowingDetail = presented
                    if !presented { viewModel.endViewingFilterDetail() }
                }
            )
        ) {
            MyListCover(detailTargetID: detailNavTargetID)
                .environmentObject(viewModel)
                .environmentObject(security)
        }
        .sheet(isPresented: $isShowingCreate) {
            CreateFilterSheet()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $isShowingPaywall) {
            LavaPlusUpgradeSheet()
        }
        .sheet(isPresented: $isShowingFocusInfo) {
            FocusFilterHowToSheet()
        }
        .sheet(item: $renamingFilter) { filter in
            RenameFilterSheet(
                initialName: filter.name,
                isNameAvailable: { viewModel.isFilterNameAvailable($0, excluding: filter.id) }
            ) { newName in
                viewModel.renameFilter(id: filter.id, to: newName)
            }
        }
        .sheet(isPresented: $isShowingDeleteConfirm) {
            DeleteFiltersConfirmationSheet(
                names: stagedDeletionNames,
                confirm: commitStagedDeletions
            )
        }
        .lavaConfirmationAlert { host in
            host.alert(
                "Restore default filters?".lavaLocalized,
                isPresented: $isShowingRestoreConfirm
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Restore", role: .destructive) {
                    viewModel.restoreFiltersToDefault()
                    isEditing = false
                }
            } message: {
                Text("This replaces your filters with the three defaults — Core, Balanced, and Extra — with Balanced in effect.".lavaLocalized)
            }
        }
        .lavaConfirmationAlert { host in
            host.alert(
                "Discard changes?".lavaLocalized,
                isPresented: $isShowingDiscardConfirm
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Discard", role: .destructive) {
                    // onChange(of: isEditing) clears the staged set on exit.
                    isEditing = false
                }
            } message: {
                Text("Your staged filter deletions won't be applied.".lavaLocalized)
            }
        }
        .lavaConfirmationAlert { host in
            host.alert(
                "Maximum filters reached".lavaLocalized,
                isPresented: $isShowingMaxFiltersAlert
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("You can host up to %d filters. Delete one to add another.".lavaLocalizedFormat(viewModel.configuration.limits.maxFilters))
            }
        }
        .lavaConfirmationAlert { host in
            host.alert(
                filterActionChoice?.name ?? "",
                isPresented: Binding(
                    get: { filterActionChoice != nil },
                    set: { if !$0 { filterActionChoice = nil } }
                ),
                presenting: filterActionChoice
            ) { filter in
                // Apply (switch) and View act directly — per-filter drafts mean neither destroys
                // another filter's edit. A FROZEN (lapsed-Plus) filter drops Apply — it can't be
                // switched to — but keeps a read-only View so its lists stay inspectable.
                // Cancel comes last so it sits at the bottom of the stacked alert.
                if !viewModel.isFilterFrozen(filter.id) {
                    Button("Apply".lavaLocalized) {
                        filterActionChoice = nil
                        applyFilter(filter)
                    }
                }
                // A frozen filter is read-only, so it stays "View"; an editable one is "View & edit".
                Button((viewModel.isFilterFrozen(filter.id) ? "View" : "View & edit").lavaLocalized) {
                    filterActionChoice = nil
                    viewFilter(filter)
                }
                Button("Cancel".lavaLocalized, role: .cancel) { filterActionChoice = nil }
            } message: { filter in
                Text(viewModel.isFilterFrozen(filter.id)
                     ? "This filter is locked. View opens it to read its lists; upgrade to Lava Plus to switch to or edit it.".lavaLocalized
                     : "Apply makes this the filter in effect. View & edit opens it to read or edit without switching.".lavaLocalized)
            }
        }
    }

    /// Open the active filter's detail page. (Any draft-discard confirmation happens before this.)
    private func presentActiveDetail() {
        detailNavTargetID = nil
        viewModel.beginViewingFilterDetail(id: nil)
        isShowingDetail = true
    }

    /// Switch the active filter to `filter` (gated behind the same fresh-auth surface as
    /// save/import so it can't bypass protected filter editing). `switchToFilter` clears any
    /// in-progress draft as part of the swap.
    private func applyFilter(_ filter: Filter) {
        Task {
            guard await security.requireFreshAuthentication(
                for: .filterEditing,
                reason: "Switch filter"
            ) else { return }
            await viewModel.switchToFilter(id: filter.id)
        }
    }

    /// Open the detail page pointed at this non-active filter: it reads/edits the filter without
    /// loading it (no refresh, no recompile, no tunnel reload). `beginViewingFilterDetail` drops
    /// any draft from a different filter.
    private func viewFilter(_ filter: Filter) {
        detailNavTargetID = filter.id
        viewModel.beginViewingFilterDetail(id: filter.id)
        isShowingDetail = true
    }

    // Stage / un-stage a filter for deletion (blocklist-style). Nothing is removed until the
    // toolbar checkmark opens the confirmation sheet and the user confirms.
    private func toggleStagedDeletion(_ id: String) {
        if stagedDeletions.contains(id) {
            stagedDeletions.remove(id)
        } else {
            stagedDeletions.insert(id)
        }
    }

    // Names of the staged filters in library order, for the confirmation sheet.
    private var stagedDeletionNames: [String] {
        viewModel.filters.filter { stagedDeletions.contains($0.id) }.map(\.name)
    }

    // Commit: actually delete the staged filters, then leave edit mode (which clears staging
    // via onChange — after this loop has consumed the set).
    private func commitStagedDeletions() {
        for id in stagedDeletions {
            viewModel.deleteFilter(id: id)
        }
        isShowingDeleteConfirm = false
        isEditing = false
    }

    @ViewBuilder private var restoreDefaultsButton: some View {
        // Gray secondary action button, sitting just below the green "Add a filter" button.
        // The destructive confirmation lives in the restore alert it opens.
        Button {
            isShowingRestoreConfirm = true
        } label: {
            Label("Restore default filters".lavaLocalized, systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(LavaSecondaryActionButtonStyle())
    }

    @ViewBuilder private var filtersFooterNote: some View {
        // Plus is capped (10) rather than unlimited, so key the messaging on the subscription
        // itself — not hasUnlimitedFilters (now false for everyone).
        if viewModel.configuration.hasLavaSecurityPlus {
            Text("Lava blocks using the filter in effect. Switch any time — your other filters stay saved.".lavaLocalized)
                .lavaQuietNoteText()
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            // Inline "Upgrade" link in a quiet note (same pattern as the Guard/Custom-DNS
            // upgrade nudges): a markdown link routed to the paywall via openURL.
            Text(.init("[**Upgrade**](lavasecurity://settings/upgrade) to Lava Plus to manage more than three lists".lavaLocalized))
                .lavaQuietNoteText()
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .tint(LavaStyle.safeGreen)
                .environment(\.openURL, OpenURLAction { url in
                    if url == URL(string: "lavasecurity://settings/upgrade") {
                        isShowingPaywall = true
                        return .handled
                    }
                    return .systemAction
                })
        }
    }

    /// The active filter shows its live in-effect rule count; other filters show the
    /// projected count from their enabled lists. An empty filter blocks nothing.
    private func ruleSummary(for filter: Filter) -> String {
        if filter.isEmpty {
            return "Blocks nothing".lavaLocalized
        }
        return "%@ rules".lavaLocalizedFormat(viewModel.filterRuleCount(for: filter).formatted())
    }
}

/// One row in the All-filters list. Dumb: the page owns all state and passes flags +
/// closures. The whole row is the action (choose Apply/View for a non-active filter, or open
/// the in-effect filter's detail); edit mode swaps in a rename tap + a delete button.
private struct FilterLibraryRow: View {
    let filter: Filter
    let isActive: Bool
    let isFrozen: Bool
    let isEditing: Bool
    let isPendingDeletion: Bool
    let canDelete: Bool
    let ruleSummary: String
    let chooseAction: () -> Void
    let openDetail: () -> Void
    let rename: () -> Void
    let toggleDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: rowAction) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(filter.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(isFrozen ? LavaStyle.secondaryText : LavaStyle.primaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                                .strikethrough(isPendingDeletion)

                            // (2) The rename pencil sits right beside the name (not rightmost),
                            // only in edit mode for an editable, not-being-deleted row.
                            if isEditing && !isFrozen && !isPendingDeletion {
                                Image(systemName: "pencil")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(LavaStyle.secondaryText)
                            }
                        }

                        Text(ruleSummary)
                            .lavaMetadataText()
                            .lineLimit(1)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 6)

                    trailingAccessory
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(rowActionDisabled)

            if isEditing && canDelete {
                // (4) Delete only STAGES (toggle); the row strikes through and this becomes an
                // undo. The toolbar checkmark confirms the staged set via a bottom sheet.
                Button(action: toggleDelete) {
                    Image(systemName: isPendingDeletion ? "arrow.uturn.backward.circle.fill" : "minus.circle.fill")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(isPendingDeletion ? LavaStyle.safeGreen : .red)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPendingDeletion ? "Undo delete".lavaLocalized : "Delete".lavaLocalized)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 64)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(rowOpacity)
    }

    private var rowOpacity: Double {
        if isPendingDeletion { return 0.55 }
        return isFrozen ? 0.7 : 1
    }

    private func rowAction() {
        if isEditing {
            // Frozen (lapsed-Plus) filters are read-only — no rename; a staged-for-delete row
            // ignores taps (use the undo button to bring it back).
            if !isFrozen && !isPendingDeletion { rename() }
        } else if isActive {
            openDetail()
        } else {
            // Non-active: offer Apply + View (read/edit without loading). A FROZEN filter is
            // still tappable — the dialog drops Apply and opens a READ-ONLY View so its lists
            // stay inspectable; only switching/editing is gated behind Plus.
            chooseAction()
        }
    }

    private var rowActionDisabled: Bool {
        // Every non-active filter is tappable now (a frozen one opens a read-only View). Only an
        // editing-mode frozen row has no action (rename is gated), but leaving it enabled is
        // harmless — the rowAction no-ops there.
        false
    }

    @ViewBuilder private var trailingAccessory: some View {
        if isPendingDeletion {
            // No trailing label — the strikethrough name + the undo button convey the staged state.
            EmptyView()
        } else if isFrozen {
            // Read-only in every mode — never a pencil/edit affordance.
            (Text(Image(systemName: "lock.fill"))
                + Text(" \("Locked".lavaLocalized)"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LavaStyle.secondaryText)
        } else if isActive {
            // (3) The in-effect filter is marked by the same "Now filtering" play glyph used on the
            // Filters tab's in-effect row — sized and framed to match the delete glyph so the active
            // row's marker and an editable row's delete control occupy the same trailing slot.
            Image(systemName: "play.circle.fill")
                .font(.headline.weight(.semibold))
                .foregroundStyle(LavaStyle.safeGreen)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Now filtering".lavaLocalized)
        }
    }
}

/// "Choose a filter to share" — the first screen of the share flow. Same list style as
/// the All-filters library (no edit mode); each row shares that filter. A filter that
/// can't fit a shareable code (too big) — or has nothing to share — is greyed out and
/// non-tappable, with a "Too big to share" note after its rule count.
private struct ChooseFilterToShareView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var shareItem: ShareCodeItem?

    var body: some View {
        LavaScreenContent(spacing: 22) {
            LavaSectionGroup("Your filters") {
                LavaCondensedList {
                    let filters = viewModel.filters
                    ForEach(filters) { filter in
                        ShareFilterPickerRow(
                            name: filter.name,
                            summary: shareSummary(for: filter),
                            isShareable: viewModel.isFilterShareable(filter)
                        ) {
                            shareItem = ShareCodeItem(code: viewModel.shareableFilterCode(for: filter))
                        }

                        if filter.id != filters.last?.id {
                            LavaCondensedDivider()
                        }
                    }
                }
            }
        }
        .navigationTitle("Choose a filter to share".lavaLocalized)
        .navigationBarTitleDisplayMode(.inline)
        .lavaTier(.calm)
        .sheet(item: $shareItem) { item in
            ShareFiltersSheet(code: item.code)
        }
    }

    private func shareSummary(for filter: Filter) -> String {
        if filter.isEmpty {
            return "Blocks nothing".lavaLocalized
        }
        let rules = "%@ rules".lavaLocalizedFormat(viewModel.filterRuleCount(for: filter).formatted())
        guard viewModel.isFilterShareable(filter) else {
            return "%1$@ · %2$@".lavaLocalizedFormat(rules, "Too big to share".lavaLocalized)
        }
        return rules
    }
}

private struct ShareCodeItem: Identifiable {
    let code: String
    var id: String { code }
}

/// One row in the share-filter picker: name + a rule/size summary, greyed and
/// non-tappable when the filter can't be shared (empty, or too big for a code).
private struct ShareFilterPickerRow: View {
    let name: String
    let summary: String
    let isShareable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isShareable ? LavaStyle.primaryText : LavaStyle.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text(summary)
                        .lavaMetadataText()
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if isShareable {
                    Image(systemName: "chevron.right")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(minHeight: 64)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isShareable)
        .opacity(isShareable ? 1 : 0.5)
    }
}

/// Create a new filter: a name plus an optional "duplicate from" source (the filters
/// that existed when the sheet opened). An empty filter is allowed (0 rules) — it shows
/// the not-protected alarm when used.
private struct CreateFilterSheet: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var duplicateFromID: String?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDuplicate: Bool { !trimmed.isEmpty && !viewModel.isFilterNameAvailable(trimmed) }
    private var canCreate: Bool { !trimmed.isEmpty && !isDuplicate }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Filter name".lavaLocalized, text: $name)
                        .textInputAutocapitalization(.words)
                } footer: {
                    if isDuplicate {
                        Text("You already have a filter with that name.".lavaLocalized)
                            .foregroundStyle(LavaStyle.errorText)
                    }
                }

                Section("Start from".lavaLocalized) {
                    Picker("Start from".lavaLocalized, selection: $duplicateFromID) {
                        Text("Empty filter".lavaLocalized).tag(String?.none)
                        ForEach(viewModel.filters) { filter in
                            Text(filter.name).tag(Optional(filter.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("New filter".lavaLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".lavaLocalized) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create".lavaLocalized) {
                        viewModel.createFilter(name: name, duplicatingFilterID: duplicateFromID)
                        dismiss()
                    }
                    .disabled(!canCreate)
                }
            }
        }
    }
}

/// Rename sheet for a filter — modeled on the Add-allowed-exception panel: a compact dedicated
/// panel (named field + green wide action button + xmark), not a full form page.
private struct RenameFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initialName: String
    /// Whether a candidate name is free to use (excludes the filter being renamed). Lets the sheet
    /// disable Save + warn on a duplicate, matching the model-layer uniqueness rule.
    let isNameAvailable: (String) -> Bool
    let onRename: (String) -> Void
    @State private var name: String
    @FocusState private var isNameFieldFocused: Bool

    init(initialName: String, isNameAvailable: @escaping (String) -> Bool, onRename: @escaping (String) -> Void) {
        self.initialName = initialName
        self.isNameAvailable = isNameAvailable
        self.onRename = onRename
        _name = State(initialValue: initialName)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDuplicate: Bool { !trimmed.isEmpty && !isNameAvailable(trimmed) }
    private var canSave: Bool { !trimmed.isEmpty && !isDuplicate }

    var body: some View {
        NavigationStack {
            LavaSheetScaffold(spacing: 18, scrolls: true) {
                LavaTextInputPanel {
                    LavaTextInputRow(title: "Name") {
                        TextField("Filter name".lavaLocalized, text: $name)
                            .lavaTextInputBody(keyboardType: .default)
                            .textInputAutocapitalization(.words)
                            .focused($isNameFieldFocused)
                            .submitLabel(.done)
                            .onSubmit { save() }
                    }
                }

                Button(action: save) {
                    Text("Save".lavaLocalized)
                }
                .buttonStyle(LavaStandaloneActionButtonStyle())
                .disabled(!canSave)

                if isDuplicate {
                    Text("You already have a filter with that name.".lavaLocalized)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LavaStyle.lavaOrange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Rename filter".lavaLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Cancel", role: .cancel, action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.height(300)])
        .task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            isNameFieldFocused = true
        }
    }

    private func save() {
        guard canSave else { return }
        onRename(trimmed)
        dismiss()
    }
}

/// Confirmation bottom sheet for staged filter deletions (blocklist-style: stage in the list,
/// confirm here). Lists what will be removed and commits on confirm.
private struct DeleteFiltersConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let names: [String]
    let confirm: () -> Void

    private var title: String {
        names.count == 1 ? "Delete this filter?".lavaLocalized : "Delete these filters?".lavaLocalized
    }

    var body: some View {
        NavigationStack {
            LavaSheetScaffold(spacing: 18, scrolls: true) {
                LavaInfoPanel(
                    title: "This can't be undone",
                    description: "Removing a filter deletes its lists and settings. The filter in effect is never deleted.",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: LavaStyle.lavaOrange,
                    borderTint: LavaStyle.lavaOrange
                )

                // Same compact, aligned change-row scaffold as the "Now filtering" review sheet
                // (DiffGroup → FilterReviewChangeRow): a simple "minus" glyph and the shared row
                // format, so staged removals read identically to a filter edit's removed rows.
                LavaCondensedList {
                    ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                        // Filter names are user data — render them raw (don't localize), so a name
                        // matching a localization key still identifies the exact filter being removed.
                        FilterReviewChangeRow(symbol: "-", title: name, tint: LavaStyle.lavaOrange, localizesTitle: false)

                        if index < names.count - 1 {
                            LavaCondensedDivider(leadingInset: 52)
                        }
                    }
                }

                Button {
                    confirm()
                    dismiss()
                } label: {
                    Text(names.count == 1 ? "Delete filter".lavaLocalized : "Delete %d filters".lavaLocalizedFormat(names.count))
                }
                .buttonStyle(LavaStandaloneActionButtonStyle())
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Cancel", role: .cancel, action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.height(360)])
    }
}

/// How-to for the Focus auto-switch (LAV-100 Phase 4). The capability is a
/// `SetFocusFilterIntent` (`LavaFocusFilterIntent`) the user wires up in
/// Settings › Focus; iOS exposes no deep link into the Focus section, so this
/// explains the four steps and offers a jump to the Settings app. Reached from
/// the moon glyph on the filters list (shown to all tiers — Focus auto-switch has no paywall).
private struct FocusFilterHowToSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let steps: [String] = [
        "Open the Settings app, then tap Focus.",
        "Choose a Focus like Sleep or Work — or create one.",
        "Tap Focus Filters, then Add Filter.",
        "Choose Lava, then pick the filter to switch to."
    ]

    var body: some View {
        NavigationStack {
            LavaSheetScaffold(spacing: 18, scrolls: true) {
                LavaInfoPanel(
                    // Raw literals: LavaInfoPanel self-localizes title + description (matches every
                    // other call site). The steps/tip/button below go through plain Text, so they
                    // keep their own .lavaLocalized.
                    title: "Switch filters automatically",
                    description: "Pick a filter for a Focus and Lava switches to it on its own whenever that Focus turns on — no taps needed.",
                    systemImage: "moon"
                )

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(LavaStyle.safeGreen)
                                .frame(width: 22, height: 22)
                                .background(LavaStyle.softGreen, in: Circle())
                            Text(step.lavaLocalized)
                                .font(.subheadline)
                                .foregroundStyle(LavaStyle.primaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("Tip: put the Focus on a schedule to switch filters automatically by time of day.".lavaLocalized)
                    .font(.footnote)
                    .foregroundStyle(LavaStyle.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(settingsURL)
                } label: {
                    Text("Open Settings".lavaLocalized)
                }
                .buttonStyle(LavaStandaloneActionButtonStyle())
            }
            .navigationTitle("Focus filters".lavaLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close", role: .cancel, action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.medium, .large])
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
                        .font(.system(size: LavaIconSize.node, weight: .regular))
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
                        .font(.system(size: LavaIconSize.node, weight: .regular))
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
            .font(.system(size: LavaIconSize.small, weight: .semibold))
            .foregroundStyle(LavaStyle.secondaryText.opacity(0.6))
            .frame(height: iconBoxHeight)
    }
}

/// Consolidated "My list" surface: the two-shelf (block / allow) view presented as a
/// full-screen cover with one unified Edit + Save. The edit draft is whole; "is editing" is
/// simply whether the shown filter has a per-filter draft (`viewModel.isFilterEditing`).
private struct MyListCover: View {
    // The filter this page was opened for (nil = active). The page re-asserts this on appear so it
    // self-heals if something cleared/changed the global target while it stayed mounted but off
    // screen (a tab switch keeps it pushed; e.g. a Domain History action resets the target).
    let detailTargetID: String?
    @EnvironmentObject private var viewModel: AppViewModel
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
                    // A non-active filter isn't loaded, so there's nothing to refresh into
                    // effect — only the active filter shows the manual catalog-refresh glyph.
                    if !viewModel.isViewingNonActiveFilter {
                        NativeToolbarIconButton(
                            systemName: "arrow.clockwise",
                            accessibilityLabel: "Refresh now",
                            action: { Task { await viewModel.syncCatalog() } }
                        )
                        .disabled(viewModel.isSyncingCatalog)
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
                await viewModel.syncCatalog()
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
            Text(message)
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
                        .foregroundColor(LavaStyle.lavaOrange)
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
                        .foregroundColor(LavaStyle.lavaOrange)
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

struct LavaPlusUpgradeSheet: View {
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
    static let iconPointSize: CGFloat = LavaIconSize.inline
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
    @State private var activeSectionID: String?
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
            // ScrollViewReader must wrap the scaffold so its proxy controls the
            // scaffold's own ScrollView (a reader *inside* the scroll view has no
            // descendant scroll view to drive, and the jump-pills wouldn't scroll).
            ScrollViewReader { proxy in
                LavaSheetScaffold(spacing: 18) {
                    // Pinned header — category pills on top, then the search field —
                    // so they stay put against the title bar while the list scrolls
                    // (mirrors the Activity date-range picker's pinned header).
                    VStack(alignment: .leading, spacing: 12) {
                        // Tappable category pills that jump to each section (search
                        // also matches category names, so this list tracks results).
                        if !visibleSections.isEmpty {
                            BlocklistCategoryJumpPills(
                                sections: visibleSections,
                                activeSectionID: activeSectionID
                            ) { sectionID in
                                activeSectionID = sectionID
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    proxy.scrollTo(BlocklistJumpMetrics.anchorID(for: sectionID), anchor: .top)
                                }
                            }
                        }

                        if usage == .filterDraft {
                            BlocklistSearchField(text: $searchText)
                        }
                    }
            } content: {
                    VStack(alignment: .leading, spacing: 18) {
                        if visibleSections.isEmpty {
                            LavaPlainCard {
                                EmptyFilterRow(
                                    title: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? "No blocklists available"
                                        : "No blocklists found",
                                    subtitle: nil
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
                                .blocklistJumpAnchor(id: section.id)
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
                                    .fill(isActive ? LavaStyle.lavaOrange : LavaStyle.secondaryText.opacity(0.12))
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
    /// Gap left between the pinned header bar (category pills + search field) and a
    /// section title when the pills jump to it. `scrollTo(.top)` otherwise aligns the
    /// section's top with the scroll view's top edge, tucking the title up under the
    /// header's material and clipping it. Landing the jump roughly half the header
    /// lower clears it. See `blocklistJumpAnchor(id:)`.
    static let topInset: CGFloat = 20

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
    /// scroll anchor lives in a zero-size background placed `BlocklistJumpMetrics.topInset`
    /// *above* the section, under a distinct id (`BlocklistJumpMetrics.anchorID(for:)`),
    /// so `scrollTo(anchor: .top)` leaves a gap below the pinned header instead of
    /// clipping the section title against it. Hosting the anchor in a background keeps
    /// it out of the section's own layout (no visible spacing change).
    func blocklistJumpAnchor(id sectionID: String) -> some View {
        background(alignment: .top) {
            Color.clear
                .frame(width: 1, height: 1)
                .alignmentGuide(.top) { dimension in
                    dimension[.top] + BlocklistJumpMetrics.topInset
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
            .navigationTitle("Add Blocked Domain".lavaLocalized)
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
                LavaInfoPanel(
                    title: "Before you allow a site",
                    description: "A site you allow here always gets through, even if a blocklist would block it. Only add sites you fully trust.",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: LavaStyle.lavaOrange,
                    borderTint: LavaStyle.lavaOrange
                )

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
            .navigationTitle("Add Allowed Exception".lavaLocalized)
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
        420
    }

    private func addDomain() {
        let addResult = viewModel.addAllowedDomainToDraft(domain)
        result = addResult
        if addResult.isAccepted {
            dismiss()
        }
    }
}
