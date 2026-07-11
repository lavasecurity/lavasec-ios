import SwiftUI
import LavaSecKit
import UIKit

/// The "All filters" library: the user hosts many filters but loads one. Tap a filter
/// to use it (switch); the in-effect filter opens its detail. Edit mode adds / renames /
/// deletes. Creating a 2nd filter is Plus-gated; on a lapsed Plus the extra filters are
/// frozen (read-only, can't be switched to) but never deleted.
struct AllFiltersView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController

    @State private var isEditing = false
    @State private var isShowingCreate = false
    @State private var isShowingPaywall = false
    // Tapping the moon glyph opens the auto-switch how-to — Automation + Focus (all tiers — no paywall).
    @State private var isShowingAutoSwitchInfo = false
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
        // same-ID restored defaults. The commit path deletes before this fires.
        .onChange(of: isEditing) { _, editing in
            if !editing { stagedDeletions = [] }
        }
        // Hide the system Back button while editing so the leading slot is the xmark
        // close (matching My filter's edit mode); a stray back-tap can't slip out.
        .navigationBarBackButtonHidden(isEditing)
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close edit mode", role: .cancel, accessibilityInputLabels: ["Close".lavaLocalized, "Done".lavaLocalized]) {
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
                    // A moon "signpost" to the auto-switch how-to, immediately LEFT of the edit
                    // pencil and only in the non-editing branch (so it's hidden in edit mode). The
                    // how-to now covers BOTH hands-free paths (an Automation and a Focus); auto-
                    // switch is available to all tiers (no paywall), so every user gets it.
                    NativeToolbarIconButton(
                        systemName: "moon",
                        accessibilityLabel: "Switch filters automatically",
                        accessibilityInputLabels: ["Auto switch".lavaLocalized]
                    ) {
                        isShowingAutoSwitchInfo = true
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
        .sheet(isPresented: $isShowingAutoSwitchInfo) {
            AutoSwitchHowToSheet()
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
                                .lavaRowTitleText()
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
struct ChooseFilterToShareView: View {
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
                        .lavaRowTitleText()
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
                        .foregroundStyle(LavaStyle.lavaOrangeText)
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

/// How-to for automatic filter switching (LAV-100 Phase 4). Two hands-free paths switch the active Lava
/// filter for you, and this sheet covers BOTH — framed generically as "switch filters on a schedule or
/// with a Focus", one section each, in a few plain steps:
///   • Automation — the DISCOVERABLE `SwitchFilterIntent` ("Switch Filter" action) a user drives from a
///     Shortcuts time/place/event trigger.
///   • Focus mode — `LavaFocusFilterIntent` (a `SetFocusFilterIntent`) wired under Settings › Focus.
/// Reached from the moon glyph on the filters list (shown to all tiers — auto-switch has no paywall).
///
/// Deep links (focus-mode-sheet revamp): each section offers a jump to where its setup lives. `shortcuts://`
/// opens the Shortcuts app; `UIApplication.openSettingsURLString` opens the Settings app. iOS exposes NO
/// deep link to a Focus (or to Settings root), so that link lands on Lava's OWN Settings pane — from there
/// the user taps back to the Settings root and into Focus (the numbered steps guide that manual path). The
/// Focus button is therefore labelled "Open the Settings app" (matching step 1's wording), NOT "Open
/// Focus": it only gets the user INTO Settings, it does not land on the Focus screen. The label stays
/// deliberately honest so it cannot read as "this takes me to Focus."
private struct AutoSwitchHowToSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    // Automation via the discoverable "Switch Filter" action. "Lava" is the brand name (untranslated).
    private let automationSteps: [String] = [
        "In Shortcuts, create an automation for a time, place, or event.",
        "Add the Lava Switch Filter action, then pick a filter."
    ]

    // Focus via Settings › Focus. "Settings"/"Focus"/"Focus Filters" are iOS system names; "Lava" is brand.
    private let focusSteps: [String] = [
        "Open the Settings app, then tap Focus.",
        "Choose a Focus like Sleep or Work — or create one.",
        "Tap Focus Filters, then Add Filter.",
        "Choose Lava, then pick the filter to switch to."
    ]

    var body: some View {
        NavigationStack {
            LavaSheetScaffold(spacing: 20, scrolls: true) {
                LavaInfoPanel(
                    // Raw literals: LavaInfoPanel self-localizes title + description (matches every other
                    // call site). The section steps/labels below go through plain Text with .lavaLocalized.
                    title: "Switch filters automatically",
                    description: "Switch filters on a schedule or with a Focus — no taps needed.",
                    systemImage: "moon"
                )

                // Automation FIRST, then Focus mode (task order). Each is numbered from 1.
                howToSection(
                    title: "Automation",
                    steps: automationSteps,
                    linkTitle: "Open Shortcuts",
                    url: URL(string: "shortcuts://")
                )

                howToSection(
                    title: "Focus mode",
                    steps: focusSteps,
                    // "Open the Settings app" — NOT "Open Settings"/"Open Focus". openSettingsURLString
                    // lands on Lava's OWN Settings pane (iOS exposes no Focus/root deep link), so the label
                    // promises only what it delivers: it gets the user INTO Settings. Because that pane has
                    // no Focus row, the note below spells out the extra back-navigation so the deep link
                    // cannot strand a user who followed step 1 literally.
                    linkTitle: "Open the Settings app",
                    linkNote: "Opens Lava's page in Settings — tap back, then Focus.",
                    url: URL(string: UIApplication.openSettingsURLString)
                )
            }
            .navigationTitle("Switch filters automatically".lavaLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close", role: .cancel, action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// One titled section, rendered as its OWN card: a header, numbered steps (restarting at 1 —
    /// each section is a self-contained path), and a deep-link button into the system app where the
    /// setup lives. The card boundary keeps the two sections' numbered lists visually separate so the
    /// per-section restart cannot read as one continuous 1→…→N path. `openURL`
    /// no-ops gracefully if the URL can't be built — matching the app-settings pattern elsewhere.
    @ViewBuilder
    private func howToSection(
        title: String,
        steps: [String],
        linkTitle: String,
        linkNote: String? = nil,
        url: URL?
    ) -> some View {
        LavaInfoCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(title.lavaLocalized)
                    .lavaSectionLabelText()
                    .accessibilityAddTraits(.isHeader)

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

                if let url {
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            openURL(url)
                        } label: {
                            HStack(spacing: 6) {
                                Text(linkTitle.lavaLocalized)
                                    .font(.subheadline.weight(.semibold))
                                Image(systemName: "arrow.up.right")
                                    .font(.footnote.weight(.semibold))
                            }
                            .foregroundStyle(LavaStyle.safeGreen)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(linkTitle.lavaLocalized)

                        // Honest destination caveat (e.g. the Focus link lands on Lava's own Settings
                        // pane, not the Focus screen) so the deep link cannot strand the user.
                        if let linkNote {
                            Text(linkNote.lavaLocalized)
                                .lavaQuietNoteText()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
