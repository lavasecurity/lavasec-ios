import SwiftUI
import LavaSecPresentation
import LavaSecKit
import UIKit

/// Create a new filter: a name plus an optional "duplicate from" source (the filters
/// that existed when the sheet opened). An empty filter is allowed (0 rules) — it shows
/// the not-protected alarm when used.
struct CreateFilterSheet: View {
    @ObservedObject var library: FilterLibraryController
    let onCreateDraft: (String?) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var duplicateFromID: String?
    @State private var createError = false

    var body: some View {
        LavaTaskSheet(title: "New filter", close: dismiss.callAsFunction) {
            LavaSectionGroup("Start from") {
                VStack(spacing: LavaSpacing.md) {
                    LavaCondensedList {
                        templateRow("Create new", id: nil)
                    }
                    LavaCondensedList {
                        ForEach(Array(library.filters.enumerated()), id: \.element.id) { index, filter in
                            if index > 0 { LavaCondensedDivider() }
                            templateRow(filter.name, id: filter.id)
                        }
                    }
                }
            }
        } footer: {
            Button("Create".lavaLocalized) {
                if onCreateDraft(duplicateFromID) { dismiss() }
            }
            .buttonStyle(LavaStandaloneActionButtonStyle())
            .disabled(!library.canBeginCreatingFilter)
        }
    }

    private func templateRow(_ title: String, id: String?) -> some View {
        Button { duplicateFromID = id } label: {
            LavaSelectableRow(state: duplicateFromID == id ? .selected : .unselected) {
                Text(id == nil ? title.lavaLocalized : title).font(LavaTypography.rowTitle).foregroundStyle(LavaStyle.primaryText)
            }
        }.buttonStyle(.plain)
    }
}

/// One bounded identity edit: native fields, neutral cancellation and a single
/// confirmation action. Identity persists together, independently of rule edits.
struct RenameFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let isNameAvailable: (String) -> Bool
    let onRename: (String, String) -> Bool
    @State private var name: String
    @State private var emoji: String
    @State private var savedName: String
    @State private var savedEmoji: String
    @State private var showingDiscardConfirmation = false
    @State private var didSave = false
    @State private var saveFailed = false
    @FocusState private var isNameFieldFocused: Bool

    init(initialName: String, initialEmoji: String, isNameAvailable: @escaping (String) -> Bool,
         onRename: @escaping (String, String) -> Bool) {
        self.isNameAvailable = isNameAvailable
        self.onRename = onRename
        _name = State(initialValue: initialName)
        _emoji = State(initialValue: initialEmoji)
        _savedName = State(initialValue: initialName)
        _savedEmoji = State(initialValue: initialEmoji)
    }
    private var hasUnsavedChanges: Bool {
        !didSave && FilterIdentityPolicy.hasUnsavedChanges(name: name, emoji: emoji, savedName: savedName, savedEmoji: savedEmoji)
    }
    private var trimmed: String { FilterIdentityPolicy.normalizedName(name) }
    private var isDuplicate: Bool { !trimmed.isEmpty && !isNameAvailable(trimmed) }
    private var resolvedName: String? { FilterIdentityPolicy.nameForEdit(name, savedName: savedName) }
    private var canSave: Bool {
        resolvedName != nil && FilterIdentityPolicy.isValidEmoji(emoji) && !isDuplicate
    }
    private var message: String? {
        if saveFailed { return "Couldn’t save. Please try again." }
        if !name.isEmpty && resolvedName == nil { return "Use letters, numbers and spaces." }
        if !emoji.isEmpty && !FilterIdentityPolicy.isValidEmoji(emoji) { return "Choose one emoji." }
        if isDuplicate { return "You already have a filter with that name." }
        return nil
    }
    var body: some View {
        NavigationStack {
            LavaSheetScaffold {
                LavaTextInputPanel {
                    LavaTextInputRow(title: "Emoji") {
                        LavaEmojiField(value: $emoji)
                            .frame(minHeight: LavaToolbarMetrics.buttonSize)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("filter.identity.emoji.row")
                    Divider()
                    LavaTextInputRow(title: "Name") {
                        TextField("Filter name".lavaLocalized, text: $name)
                            .lavaTextInputBody(keyboardType: .default)
                            .textInputAutocapitalization(.words)
                            .focused($isNameFieldFocused)
                            .frame(minHeight: LavaToolbarMetrics.buttonSize)
                            .submitLabel(.done).onSubmit { save() }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("filter.identity.name.row")
                }
                if let message {
                    Text(message.lavaLocalized).lavaSupportingText().foregroundStyle(LavaStyle.errorText)
                }
            }
            .navigationTitle("Rename filter".lavaLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Cancel", role: .cancel, action: requestDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    NativeToolbarIconButton(systemName: "checkmark", accessibilityLabel: "Save", role: .confirm, action: save).disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .lavaConfirmInteractiveDismiss(hasUnsavedChanges, onAttempt: requestDismiss)
        .lavaConfirmationAlert { host in
            host.alert("Discard changes?".lavaLocalized, isPresented: $showingDiscardConfirmation) {
                Button("Keep Editing".lavaLocalized, role: .cancel) {}
                Button("Discard Changes".lavaLocalized, role: .destructive) { dismiss() }
            }
        }
    }
    private func requestDismiss() {
        if hasUnsavedChanges { showingDiscardConfirmation = true } else { dismiss() }
    }
    private func save() {
        guard canSave else { return }
        if onRename(name, emoji) { didSave = true; dismiss() } else { saveFailed = true }
    }
}

/// Reviews the complete library draft and commits once after explicit confirmation.
/// A stale baseline or failed persistence keeps the draft available for correction.
struct DeleteFiltersConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: FilterLibraryEditSession
    let confirm: () -> Bool
    @State private var failed = false
    @State private var committing = false
    var body: some View {
        NavigationStack {
            LavaSheetScaffold(spacing: 18, scrolls: true) {
                DiffGroup(title: "Added filters", added: session.additions.map(\.name), removed: [])
                ForEach(session.renames.keys.filter { !session.stagedDeletions.contains($0) }.sorted(), id: \.self) { id in
                    DiffGroup(title: "Renamed filter", added: [session.renames[id] ?? ""], removed: [session.baseline?.filter(id: id)?.name ?? ""])
                }
                ForEach(session.emojiChanges.keys.filter { !session.stagedDeletions.contains($0) }.sorted(), id: \.self) { id in
                    DiffGroup(title: "Emoji", added: [session.emojiChanges[id] ?? ""], removed: [session.baseline?.filter(id: id)?.emoji ?? ""])
                }
                DiffGroup(title: "Deleted filters", added: [], removed: (session.baseline?.filters ?? []).filter { session.stagedDeletions.contains($0.id) }.map(\.name))
                if !session.stagedDeletions.isEmpty {
                    Text("Deleting removes these filters and their custom changes. Restoring defaults recreates the original filters.".lavaLocalized)
                        .lavaSupportingText()
                }
                if failed {
                    Text("Your filters changed or could not be saved. Close Review and check your changes before trying again.".lavaLocalized)
                        .lavaSupportingText().foregroundStyle(LavaStyle.errorText)
                }
            } footer: {
                Button("Confirm changes") {
                    guard !committing else { return }
                    committing = true
                    if confirm() { dismiss() } else { failed = true; committing = false }
                }
                .buttonStyle(LavaStandaloneActionButtonStyle())
                .disabled(committing || failed)
            }
            .navigationTitle("Review".lavaLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Cancel", role: .cancel, action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.large])
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
struct AutoSwitchHowToSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            AutoSwitchHowToContent().toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close", role: .cancel, action: dismiss.callAsFunction)
                }.lavaToolbarChrome()
            }
        }.presentationDetents([.medium, .large])
    }
}

struct AutoSwitchHowToContent: View {
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
        LavaSheetScaffold(spacing: 20, scrolls: true) {
                LavaSettingsIntroduction(summary: "Switch filters on a schedule or with a Focus.")

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
            .navigationTitle("Auto-switch filters".lavaLocalized)
            .navigationBarTitleDisplayMode(.inline)
    }

    /// Numbered steps restart at 1 because each section is a self-contained path.
    /// The shared section owns its heading, instructions and action. The
    /// destination caveat stays below that single panel.
    /// `openURL` no-ops gracefully if the system URL cannot be built.
    @ViewBuilder
    private func howToSection(
        title: String,
        steps: [String],
        linkTitle: String,
        linkNote: String? = nil,
        url: URL?
    ) -> some View {
        LavaSetupSection(title: title, steps: steps, footer: linkNote) {
            if let url {
                LavaSetupAction(title: linkTitle, accessibilityHint: linkNote) { openURL(url) }
            }
        }
    }
}
