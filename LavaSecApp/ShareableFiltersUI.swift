import SwiftUI
import LavaSecKit
import LavaSecAppServices
import PhotosUI
@preconcurrency import AVFoundation
import CoreImage.CIFilterBuiltins
import UIKit

// MARK: - Import result

enum ShareableFilterImportResult: Equatable {
    case success(ruleCount: Int)
    case failure(message: String)
}

// MARK: - QR code generation

enum LavaQRCode {
    /// Points drawn per module, so a caller holding only the image can recover the
    /// module count — and therefore the quiet zone the code needs around it.
    static let pointsPerModule: CGFloat = 12

    /// The image's width in modules, INCLUDING the one-module border
    /// `CIQRCodeGenerator` draws inside its own output.
    ///
    /// Read from the image rather than looked up from the QR version tables, because
    /// the version depends on the payload and the correction level that happened to
    /// fit. The shortest real Lava link is a 37-module symbol, whose modules are
    /// fatter — and so need a wider quiet zone — than the 45-module case this card
    /// was first reasoned about.
    static func moduleCount(of image: UIImage) -> CGFloat {
        max(1, (image.size.width / pointsPerModule).rounded())
    }

    /// Renders `string` as a crisp (non-interpolated) QR image suitable for
    /// on-screen display. Returns `nil` only if Core Image cannot build the code —
    /// which, for a fixed `correctionLevel`, means the payload exceeds what that
    /// level can carry. Callers step the level down rather than shorten the payload.
    static func image(
        for string: String,
        scale: CGFloat = LavaQRCode.pointsPerModule,
        correctionLevel: String = "M"
    ) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = correctionLevel

        guard let output = filter.outputImage else {
            return nil
        }

        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Share my filters

/// A contextual share request keeps the saved identity independent of the current filter.
enum ImportFiltersStartMode {
    case chooseMethod
    case enterCode
    case scanCode
    /// Opens directly at the review for a configuration a Universal Link already
    /// carried. The payload is only ever held for the life of this presentation —
    /// it is never persisted, and never queued across onboarding.
    case review(ShareableFilterConfiguration)
}

/// A staged intent to replace the filter currently in effect.
///
/// Deliberately a distinct type rather than a flag: it carries the exact
/// configuration and target the user chose, so the confirmation acts on precisely
/// what was selected and cannot drift if the library changes underneath it.
private struct PendingActiveReplacement: Identifiable {
    let id = UUID()
    let configuration: ShareableFilterConfiguration
    let originalConfiguration: ShareableFilterConfiguration
    let target: Filter
}

/// The native flow retains only the already-committed result across privacy
/// teardown. Input, decoded content and scanner state still belong to the view.
@MainActor
final class ImportFiltersCompletion: ObservableObject {
    @Published private(set) var filterName: String?
    private(set) var unavailableListCount = 0
    private var acknowledged = false

    func recordCommittedFilter(named name: String, unavailableListCount: Int = 0) {
        guard filterName == nil else { return }
        // SwiftUI may construct unused initial state objects during view rebuilds.
        // Claim only at the retained owner's actual commit, never in its initializer.
        let feedbackID = LavaFeedbackCoordinator.shared.begin("filter.import")
        self.unavailableListCount = unavailableListCount
        filterName = name
        // This retained commit owner survives privacy teardown; restored screen appearance is silent.
        LavaFeedbackCoordinator.shared.finish("filter.import", feedbackID, .succeeded)
    }

    func acknowledge() -> Bool {
        guard filterName != nil, !acknowledged else { return false }
        acknowledged = true
        return true
    }
}

/// Self-contained import experience reused by Filters and onboarding. Manages
/// its own simple stage machine so the freeform code-entry screen can own its
/// chevron-back / skip chrome exactly as designed.
struct ImportFiltersFlow: View {
    let startMode: ImportFiltersStartMode
    var showsSkip: Bool = false
    /// Overrides "back" from the first method screen (used by onboarding to
    /// return to its own chooser instead of dismissing the whole sheet).
    var onRootBack: (() -> Void)? = nil
    var onSkip: (() -> Void)? = nil
    /// Called once when Done acknowledges a successfully applied config.
    var onImported: (() -> Void)? = nil
    /// Fresh-auth gate run before applying an import — replacing filters is a
    /// filter-editing action. Defaults to allow (onboarding's first-run flow has
    /// no protected surface); the Filters entry point supplies the real check.
    var authorizeImport: () async -> Bool = { true }

    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var stage: Stage
    @State private var applyError: String?
    @StateObject private var completion: ImportFiltersCompletion
    /// Add-as-new at the filter cap routes here for a FREE user (upgrade to get more).
    @State private var showingPaywall = false
    /// A Plus user already at the 10-filter cap can't upgrade their way past it, so they get an
    /// informational "Maximum filters reached" note instead of the paywall.
    @State private var showingMaxFilters = false
    /// Whether the next stage swap reads as a push or a pop, so the slide matches
    /// the direction of travel. Set by `go(to:)` from the stage ordering.
    @State private var navDirection: LavaFlowDirection = .forward
    /// The in-effect filter chosen as a replacement target, held only while the
    /// destructive confirmation is on screen. Nothing has been authorised or
    /// mutated at this point — dismissing this leaves protection exactly as it was.
    @State private var pendingActiveReplacement: PendingActiveReplacement?

    init(
        startMode: ImportFiltersStartMode,
        showsSkip: Bool = false,
        onRootBack: (() -> Void)? = nil,
        onSkip: (() -> Void)? = nil,
        onImported: (() -> Void)? = nil,
        completion: ImportFiltersCompletion,
        authorizeImport: @escaping () async -> Bool = { true }
    ) {
        self.startMode = startMode
        self.showsSkip = showsSkip
        self.onRootBack = onRootBack
        self.onSkip = onSkip
        self.onImported = onImported
        self.authorizeImport = authorizeImport
        _completion = StateObject(wrappedValue: completion)
        _stage = State(initialValue: completion.filterName.map { .completed(filterName: $0) } ?? Stage(startMode: startMode))
    }

    enum Stage: Equatable {
        case chooseMethod
        case enterCode
        case scanCode
        case confirm(ShareableFilterConfiguration)
        case chooseReplace(ShareableFilterConfiguration)
        case reviewReplacement(original: ShareableFilterConfiguration, applied: ShareableFilterConfiguration, target: Filter)
        case applying(ShareableFilterConfiguration)
        case completed(filterName: String)

        init(startMode: ImportFiltersStartMode) {
            switch startMode {
            case .chooseMethod:
                self = .chooseMethod
            case .enterCode:
                self = .enterCode
            case .scanCode:
                self = .scanCode
            case .review(let configuration):
                // A link that already carries a decoded payload opens at the review,
                // not at a method chooser — but it opens at the SAME review every
                // other origin reaches, with the same confirm and auth gates.
                self = .confirm(configuration)
            }
        }

        /// Stable identity for the page transition (the associated config doesn't
        /// change which page is on screen, so it's deliberately excluded).
        var transitionID: String {
            switch self {
            case .chooseMethod: "chooseMethod"
            case .enterCode: "enterCode"
            case .scanCode: "scanCode"
            case .confirm: "confirm"
            case .chooseReplace: "chooseReplace"
            case .reviewReplacement: "reviewReplacement"
            case .applying: "applying"
            case .completed: "completed"
            }
        }

        /// Depth in the flow, so `go(to:)` can tell a push from a pop. Enter/scan
        /// share a depth — they're siblings off the chooser, never reached from
        /// one another.
        var order: Int {
            switch self {
            case .chooseMethod: 0
            case .enterCode, .scanCode: 1
            case .confirm: 2
            case .chooseReplace: 3
            case .reviewReplacement: 4
            case .applying: 5
            case .completed: 6
            }
        }
    }

    var body: some View {
        // One NavigationStack hosts every stage so each step renders the
        // shared full-sheet header (title + Back/Skip). The stage machine
        // swaps the stack's root content; back is driven by `stage`, not a push —
        // so the slide between stages is supplied here (a real push would give it
        // for free) to match the native page transitions elsewhere in the app.
        NavigationStack {
            ZStack {
                content
                    .lavaFlowTransition(
                        value: stage.transitionID,
                        direction: navDirection,
                        reduceMotion: reduceMotion
                    )
            }
            .background(LavaStyle.groupedBackground.ignoresSafeArea())
            .alert(
                "Couldn't import",
                isPresented: Binding(
                    get: { applyError != nil },
                    set: { if !$0 { applyError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { applyError = nil }
            } message: {
                Text((applyError ?? "").lavaLocalized)
            }
            .sheet(isPresented: $showingPaywall) {
                LavaPlusUpgradeSheet(context: "fullImport")
            }
            .lavaConfirmationAlert { host in
                host.alert(
                    "Maximum filters reached".lavaLocalized,
                    isPresented: $showingMaxFilters
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("You can host up to %d filters. Delete one to add another.".lavaLocalizedFormat(viewModel.configuration.limits.maxFilters))
                }
            }
            // The second gate before the filter in effect is replaced. Fresh auth
            // alone is not enough here: authenticating proves who you are, not that
            // you understood this changes what is protecting the device.
            .lavaConfirmationAlert { host in
                host.alert(
                    "Replace the filter in effect?".lavaLocalized,
                    isPresented: Binding(
                        get: { pendingActiveReplacement != nil },
                        set: { if !$0 { pendingActiveReplacement = nil } }
                    ),
                    presenting: pendingActiveReplacement
                ) { pending in
                    Button("Cancel", role: .cancel) { pendingActiveReplacement = nil }
                    Button("Replace active filter", role: .destructive) {
                        let confirmed = pending
                        pendingActiveReplacement = nil
                        // The ONLY place this flag is true: consent to replacing the
                        // filter in effect exists exactly where it was just given.
                        replace(
                            confirmed.configuration,
                            originalConfiguration: confirmed.originalConfiguration,
                            into: confirmed.target,
                            confirmedActiveReplacement: true
                        )
                    }
                } message: { pending in
                    Text(replacementConfirmationMessage(pending))
                }
            }
            .lavaTier(.calm)
        }
        .interactiveDismissDisabled(stage.transitionID == "applying" || stage.transitionID == "completed")
        .onChange(of: viewModel.configuration.hasLavaSecurityPlus) { _, enabled in
            if enabled { showingPaywall = false }
        }
        .onChange(of: completion.filterName, initial: true) { _, filterName in
            // A confirmed commit may finish after privacy teardown has already
            // recreated this view. Observe its owner instead of retaining drafts.
            if let filterName, stage != .completed(filterName: filterName) {
                go(to: .completed(filterName: filterName))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .chooseMethod:
            ImportMethodChooserView(
                onEnterCode: { go(to: .enterCode) },
                onScanCode: { go(to: .scanCode) },
                onDecodedFromPhoto: { go(to: .confirm($0)) },
                onClose: { dismiss() }
            )
        case .enterCode:
            ImportCodeEntryView(
                showsSkip: showsSkip,
                onBack: { goBackFromMethod() },
                onSkip: { onSkip?() },
                onDecoded: { config in go(to: .confirm(config)) }
            )
        case .scanCode:
            ImportQRScannerView(
                showsSkip: showsSkip,
                onBack: { goBackFromMethod() },
                onSkip: { onSkip?() },
                onDecoded: { config in go(to: .confirm(config)) }
            )
        case .confirm(let config):
            ImportPreviewView(
                configuration: config,
                onBack: { go(to: Stage(startMode: startMode)) },
                onAddNew: {
                    // Additive default — name a brand-new filter. At the cap, a free user trips the
                    // paywall (upgrade for more); a Plus user (already subscribed) can't pay past the
                    // 10-filter cap, so they get the "Maximum filters reached" note instead.
                    if viewModel.canCreateFilter {
                        addNew(config)
                    } else if viewModel.configuration.hasLavaSecurityPlus {
                        showingMaxFilters = true
                    } else {
                        showingPaywall = true
                    }
                },
                onReplace: { go(to: .chooseReplace(config)) },
                onUpgrade: { showingPaywall = true }
            )
        case .chooseReplace(let config):
            ImportChooseReplaceTargetView(
                onUpgrade: { showingPaywall = true },
                onBack: { go(to: .confirm(config)) },
                onReplace: { filter in
                    go(to: .reviewReplacement(original: config, applied: viewModel.importPlan(for: config).applied, target: filter))
                }
            )
        case .reviewReplacement(let original, let config, let filter):
            ImportReplacementReviewView(
                summary: config.replacementSummary(for: filter),
                onBack: { go(to: .chooseReplace(original)) },
                onReplace: {
                    // Active replacement still needs its explicit consequence confirmation.
                    // pinned: SharedFilterImportSourceTests.testSelectingTheActiveTargetOnlyStagesIt
                    if filter.id == viewModel.library.activeFilterID {
                        pendingActiveReplacement = PendingActiveReplacement(configuration: config, originalConfiguration: original, target: filter)
                    } else {
                        replace(config, originalConfiguration: original, into: filter)
                    }
                }
            )
        case .applying:
            ImportApplyingView()
        case .completed(let filterName):
            LavaSuccessScreen(title: "Filter imported",
                              message: "The shared filter was imported as “%@” in Your filters.".lavaLocalizedFormat(filterName),
                              done: finishImport) {
                if completion.unavailableListCount > 0 {
                    Text(Self.unavailableListsMessage(completion.unavailableListCount))
                        .lavaQuietNoteText()
                }
            }
        }
    }

    static func unavailableListsMessage(_ count: Int) -> String {
        (count == 1 ? "%@ list wasn’t imported because it’s no longer available."
                    : "%@ lists weren’t imported because they’re no longer available.").lavaLocalizedFormat(count.formatted())
    }

    private func finishImport() {
        guard case .completed = stage else { return }
        if completion.acknowledge() { onImported?() }
        dismiss()
    }

    /// Moves to `newStage`, sliding in the direction implied by the stage depth
    /// (deeper = push, shallower = pop) so the transition matches a native
    /// navigation stack.
    private func go(to newStage: Stage) {
        navDirection = newStage.order >= stage.order ? .forward : .backward
        withAnimation(LavaFlowTransition.animation(reduceMotion: reduceMotion)) {
            stage = newStage
        }
    }

    private func goBackFromMethod() {
        // Pattern-matched rather than compared: `.review` carries a payload, so the
        // enum no longer gets implicit Equatable and does not need it.
        if case .chooseMethod = startMode {
            go(to: .chooseMethod)
        } else if let onRootBack {
            onRootBack()
        } else {
            dismiss()
        }
    }

    private func replacementConfirmationMessage(_ pending: PendingActiveReplacement) -> String {
        let summary = pending.configuration.replacementSummary(for: pending.target)
        let impact = "This changes the filter protecting this device. “%@” keeps its name and receives the reviewed content.".lavaLocalizedFormat(pending.target.name)
        let removed = ImportReplacementReviewView.removalSummary(summary)
        let added = "Added: %1$lld blocklists, %2$lld blocked domains, %3$lld custom sources, %4$lld allowed exceptions.".lavaLocalizedFormat(
            summary.addedBlocklistIDs.count, summary.selectionDiff.addedBlockedDomains.count,
            summary.addedCustomBlocklists.count, summary.selectionDiff.addedAllowedDomains.count)
        return [impact, removed, added].joined(separator: "\n\n")
    }

    /// Add the imported setup as a brand-new filter (additive). Library-only — never touches the
    /// other filters or the live tunnel.
    private func addNew(_ config: ShareableFilterConfiguration) {
        guard stage.transitionID != "applying", stage.transitionID != "completed" else { return }
        // Capture what was reviewed before authentication can suspend or rebuild the sheet.
        let plan = viewModel.importPlan(for: config)
        let applied = plan.applied
        go(to: .applying(config))
        Task { @MainActor in
            // Adding a filter is a filter-editing action — gate it behind the same fresh-auth
            // surface the manual edit/save flow uses.
            guard await authorizeImport() else {
                go(to: .confirm(config))
                return
            }

            guard viewModel.importPlan(for: config).applied == applied else {
                applyError = "Something else updated your filter while this imported. Try again."
                go(to: .confirm(config))
                return
            }
            if let id = viewModel.addImportedShareableConfigurationAsNewFilter(applied),
               let saved = viewModel.library.filter(id: id) {
                completion.recordCommittedFilter(named: saved.name, unavailableListCount: plan.droppedCount(of: .unavailableBlocklist))
                go(to: .completed(filterName: saved.name))
            } else {
                applyError = "Couldn't add this filter. Please try again."
                go(to: .confirm(config))
            }
        }
    }

    /// Replace a chosen existing filter with the imported setup. Replacing the active filter
    /// reloads the tunnel; a non-active filter is replaced library-only.
    private func replace(
        _ config: ShareableFilterConfiguration,
        originalConfiguration: ShareableFilterConfiguration,
        into filter: Filter,
        confirmedActiveReplacement: Bool = false
    ) {
        guard stage.transitionID != "applying", stage.transitionID != "completed" else { return }
        go(to: .applying(config))
        Task { @MainActor in
            guard await authorizeImport() else {
                go(to: .chooseReplace(originalConfiguration))
                return
            }

            guard let current = viewModel.library.filter(id: filter.id),
                  current.strippingLocalCacheState() == filter.strippingLocalCacheState(),
                  viewModel.importPlan(for: originalConfiguration).applied == config else {
                applyError = "Something else updated your filter while this imported. Try again."
                go(to: .chooseReplace(originalConfiguration))
                return
            }

            // The target can BECOME the filter in effect while authentication is on
            // screen — a Focus or shortcut switch commits from another process. The
            // check at selection time is a snapshot, so re-read it here: acting on the
            // stale one would replace what is protecting the device having shown only
            // the ordinary confirmation. Route to the destructive one instead.
            // pinned: SharedFilterImportSourceTests.testActiveReplacementIsRecheckedAfterAuthentication
            guard confirmedActiveReplacement || filter.id != viewModel.library.activeFilterID else {
                pendingActiveReplacement = PendingActiveReplacement(
                    configuration: config,
                    originalConfiguration: originalConfiguration,
                    target: filter
                )
                go(to: .chooseReplace(originalConfiguration))
                return
            }

            // The reviewed subset passed the post-authentication comparison above.
            let applied = config
            let unavailableListCount = viewModel.importPlan(for: originalConfiguration).droppedCount(of: .unavailableBlocklist)
            let result = await viewModel.replaceFilterWithImportedShareableConfiguration(
                id: filter.id,
                applied,
                confirmedActiveReplacement: confirmedActiveReplacement
            )
            switch result {
            case .success:
                let filterName = viewModel.library.filter(id: filter.id)?.name ?? filter.name
                completion.recordCommittedFilter(named: filterName, unavailableListCount: unavailableListCount)
                go(to: .completed(filterName: filterName))
            case .failure(let message):
                applyError = message
                go(to: .chooseReplace(originalConfiguration))
            }
        }
    }
}

// MARK: Method chooser

private struct ImportMethodChooserView: View {
    let onEnterCode: () -> Void
    let onScanCode: () -> Void
    let onDecodedFromPhoto: (ShareableFilterConfiguration) -> Void
    let onClose: () -> Void

    @State private var photoItem: PhotosPickerItem?
    @State private var isDecodingPhoto = false
    @State private var photoError: String?

    var body: some View {
        LavaSheetScaffold(spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                LavaInfoCard(borderTint: LavaStyle.lavaOrange) {
                    Text("Check who shared this filter and review its contents carefully before importing. Shared filters aren’t reviewed by Lava.")
                        .lavaSupportingText(color: LavaStyle.primaryText)
                }

                LavaCondensedList {
                    ImportOptionRow(
                        systemImage: "qrcode.viewfinder",
                        title: "Scan a QR code",
                        subtitle: "",
                        accessory: .chevron,
                        action: onScanCode
                    )

                    LavaCondensedDivider()
                    photoImportRow
                    LavaCondensedDivider()

                    ImportOptionRow(
                        systemImage: "character.cursor.ibeam",
                        title: "Enter a code",
                        subtitle: "",
                        accessory: .chevron,
                        action: onEnterCode
                    )
                }
            }
        }
        // Cancelling the picker leaves `photoItem` nil, so the importer is untouched:
        // no error, no navigation, no state change.
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            decodePhoto(newItem)
        }
        .alert(
            "Couldn't read that image".lavaLocalized,
            isPresented: photoErrorBinding
        ) {
            Button("OK".lavaLocalized, role: .cancel) { photoError = nil }
        } message: {
            Text(photoError ?? "")
        }
        .lavaFullSheetHeader("Import a filter", close: onClose)
    }

    /// Extracted from `body` to keep the view builder inside the type checker's
    /// reach — inlined, this expression tips `ImportMethodChooserView` over.
    ///
    /// PhotosPicker supplies the privacy boundary: it runs out of process and hands
    /// back only the chosen item, so Lava never asks for — or holds — access to the
    /// whole library, and needs no NSPhotoLibraryUsageDescription.
    private var photoImportRow: some View {
        PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
            LavaNavigationCardLabel(
                badge: .systemImage("photo.on.rectangle", font: .title3.weight(.semibold)),
                badgeSize: 38,
                rowSpacing: 14,
                title: "Import from Photo",
                summary: .none,
                accessory: .chevron
            )
            .opacity(isDecodingPhoto ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDecodingPhoto)
        .accessibilityLabel(Text("Import from Photo".lavaLocalized))
        .accessibilityHint(Text("Use a saved card someone sent you".lavaLocalized))
    }

    private var photoErrorBinding: Binding<Bool> {
        Binding(
            get: { photoError != nil },
            set: { if !$0 { photoError = nil } }
        )
    }

    /// Loads the chosen item and decodes it off the main actor, publishing only the
    /// result back. The full-resolution data is confined to this scope so a photo of
    /// the user's library never outlives the decode.
    private func decodePhoto(_ item: PhotosPickerItem) {
        isDecodingPhoto = true
        Task { @MainActor in
            defer {
                isDecodingPhoto = false
                // Cleared so re-picking the same asset fires onChange again.
                photoItem = nil
            }
            do {
                // Loaded as a FILE, not as Data: `loadTransferable(type: Data.self)`
                // materializes the whole asset before any cap can look at it, so the
                // byte limit could not bound peak memory for an oversized RAW or
                // panorama. PickedImageFile refuses on the declared size instead.
                guard let picked = try await item.loadTransferable(type: PickedImageFile.self) else {
                    photoError = ShareableFilterImageDecodeError.unreadableImage.errorDescription
                    return
                }
                defer { try? FileManager.default.removeItem(at: picked.url) }
                let configuration = try await ShareableFilterImageDecoder.decode(fileURL: picked.url)
                // Joins the same review stage as camera, manual entry, and links —
                // a photo is another way in, never a shortcut past the review.
                onDecodedFromPhoto(configuration)
            } catch let error as ShareableFilterImageDecodeError {
                photoError = error.errorDescription
            } catch {
                photoError = ShareableFilterImageDecodeError.unreadableImage.errorDescription
            }
        }
    }
}

/// A picked image as a file on disk, never as bytes in memory.
///
/// The point is the order of operations: the size is read from the file and checked
/// *before* the asset is copied, and the decoder later memory-maps the copy instead
/// of reading it. An oversized asset is therefore refused while still costing
/// nothing but a stat call.
///
/// Refuses rather than falling back to a `Data` load when no file representation is
/// available. A fallback would be the unbounded path this type exists to remove, and
/// on this feature's threat model refusing to read a picture is the cheap failure.
private struct PickedImageFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let attributes = try FileManager.default.attributesOfItem(atPath: received.file.path)
            guard let byteCount = attributes[.size] as? Int else {
                throw ShareableFilterImageDecodeError.unreadableImage
            }
            do {
                try SharedFilterImageLimits.validate(byteCount: byteCount)
            } catch {
                throw ShareableFilterImageDecodeError.imageTooLarge
            }
            // `received.file` is only valid for the duration of this call.
            let copy = try PrivateImportFiles.copy(received.file)
            return PickedImageFile(url: copy)
        }
    }
}

struct ImportOptionRow: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let accessory: LavaNavigationCardAccessory
    let action: () -> Void

    var body: some View {
        LavaNavigationCardButton(action: action) {
            LavaNavigationCardLabel(
                badge: .systemImage(
                    systemImage,
                    font: .title3.weight(.semibold)
                ),
                badgeSize: 38,
                rowSpacing: 14,
                title: title,
                summary: subtitle.isEmpty ? .none : .localizedUnclamped(subtitle),
                accessory: accessory
            )
        }
    }
}

// MARK: Freeform code entry

private struct ImportCodeEntryView: View {
    let showsSkip: Bool
    let onBack: () -> Void
    let onSkip: () -> Void
    let onDecoded: (ShareableFilterConfiguration) -> Void

    @State private var enteredCode = ""
    @State private var errorMessage: String?

    var body: some View {
        LavaSheetScaffold(spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                LavaInfoPanel(
                    title: "Enter a setup code",
                    description: "Paste the setup code someone shared with you. It usually starts with \"LF1-\".",
                    systemImage: "character.cursor.ibeam"
                )

                LavaTextEditorInputRow(
                    title: "Setup code",
                    text: $enteredCode,
                    placeholder: "LF1-…",
                    minHeight: 180
                )
                .onChange(of: enteredCode) { _, _ in
                    errorMessage = nil
                }

                if let errorMessage {
                    Text(errorMessage.lavaLocalized)
                        .lavaQuietNoteText()
                        .foregroundStyle(LavaStyle.errorText)
                }
            }
        } footer: {
            Button("Continue") {
                continueTapped()
            }
            .buttonStyle(LavaStandaloneActionButtonStyle())
            .disabled(enteredCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .importFullSheetHeader("Enter a code", showsSkip: showsSkip, onBack: onBack, onSkip: onSkip)
    }

    private func continueTapped() {
        do {
            // Accepts a pasted canonical link as readily as a bare LF1- code: both
            // go through the one strict parser, so breadth here costs nothing.
            // pinned: SharedFilterImportSourceTests.testEveryImportOriginFunnelsThroughTheLinkParser
            let config = try ShareableFilterLink.decode(enteredCode)
            guard !config.isEmpty else {
                errorMessage = "This code doesn't contain a filter to import."
                return
            }
            onDecoded(config)
        } catch {
            errorMessage = ShareableFilterImportMessages.message(for: error)
        }
    }
}

// MARK: QR scanner

private struct ImportQRScannerView: View {
    let showsSkip: Bool
    let onBack: () -> Void
    let onSkip: () -> Void
    let onDecoded: (ShareableFilterConfiguration) -> Void

    @State private var errorMessage: String?
    @State private var cameraDenied = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        LavaSheetScaffold(spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                if cameraDenied {
                    cameraDeniedCard
                } else {
                    QRCodeScannerRepresentable(
                        onScan: { handleScan($0) },
                        onAttemptBegan: { errorMessage = nil },
                        onCameraDenied: { cameraDenied = true }
                    )
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(LavaStyle.safeGreen.opacity(0.6), lineWidth: 2)
                    }

                    Text("Hold the shared QR code inside the frame.")
                        .lavaSupportingText()

                    if let errorMessage {
                        Text(errorMessage.lavaLocalized)
                            .lavaQuietNoteText()
                            .foregroundStyle(LavaStyle.errorText)
                    }
                }
            }
        }
        .importFullSheetHeader("Scan a QR code", showsSkip: showsSkip, onBack: onBack, onSkip: onSkip)
        .onChange(of: scenePhase) { _, phase in
            // Returning from Settings (where the user may have granted access)
            // re-checks authorization so the scanner remounts instead of leaving
            // the user stuck on the recovery card.
            if phase == .active, cameraDenied,
               AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                cameraDenied = false
            }
        }
    }

    private var cameraDeniedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Camera access is off", systemImage: "video.slash.fill")
                .font(.headline)
                .foregroundStyle(LavaStyle.ink)

            Text("Allow camera access in Settings to scan a QR code — or tap back and enter the code instead.")
                .lavaSupportingText()

            Button("Open the Settings app") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(LavaStandaloneActionButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .lavaSurface(.card)
    }

    private func handleScan(_ scanned: String) -> Bool {
        do {
            // Every QR this app generates encodes the canonical link, not a bare
            // code, so a raw-code-only parser here would reject Lava's own cards.
            // pinned: SharedFilterImportSourceTests.testEveryImportOriginFunnelsThroughTheLinkParser
            let config = try ShareableFilterLink.decode(scanned)
            guard !config.isEmpty else {
                errorMessage = "That QR code doesn't contain a filter to import."
                return false
            }
            onDecoded(config)
            return true
        } catch {
            // Keep scanning; surface a hint but don't latch on a non-Lava code.
            errorMessage = ShareableFilterImportMessages.message(for: error)
            return false
        }
    }
}

struct QRCodeScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Bool
    var onAttemptBegan: () -> Void = {}
    var onCameraDenied: () -> Void = {}

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: QRScannerViewController, context: Context) {
        controller.onScan = onScan
        controller.onAttemptBegan = onAttemptBegan
        controller.onCameraAuthorizationDenied = onCameraDenied
    }
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Bool)?
    var onAttemptBegan: (() -> Void)?
    private var attempt = QRScanAttempt()
    var onCameraAuthorizationDenied: (() -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "app.lavasecurity.qrscanner.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureDevice: AVCaptureDevice?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()

        // Tap anywhere to refocus — useful when the phone parks focus on the
        // wrong plane while the QR is held close.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTapToFocus(_:)))
        view.addGestureRecognizer(tap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        attempt.appear(active: UIApplication.shared.applicationState == .active)
        onAttemptBegan?()
        registerAppActivityObservers()
        startSessionIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        attempt.disappear()
        unregisterAppActivityObservers()
        stopSession()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Power the capture session down whenever the app leaves the active state —
    /// app switcher (`.inactive`) or background — and bring it back on return.
    /// `viewWillDisappear` only fires on real navigation, not on resign-active, so
    /// without this the camera keeps running in the app switcher, including when
    /// Security choices require no `LavaPrivacyShield`. Restart re-checks camera
    /// authorization independently of snapshot concealment.
    private func registerAppActivityObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    private func unregisterAppActivityObservers() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
        center.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func appWillResignActive() {
        attempt.setActive(false)
        stopSession()
    }

    @objc private func appDidBecomeActive() {
        attempt.setActive(true)
        startSessionIfNeeded()
    }

    private func stopSession() {
        nonisolated(unsafe) let session = self.session
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func configureSession() {
        guard let device = Self.bestAvailableCaptureDevice(),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            return
        }

        session.beginConfiguration()

        // 1080p gives QR detection more pixels to work with for dense codes.
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }

        session.addInput(input)
        captureDevice = device
        configureContinuousFocus(for: device)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    /// Prefer a multi-lens virtual device so the system can switch between lenses
    /// (e.g. to the ultra-wide) to keep a close-held QR in focus. Falls back to
    /// the plain wide-angle camera, then any default video device.
    private static func bestAvailableCaptureDevice() -> AVCaptureDevice? {
        let preferredTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: preferredTypes,
            mediaType: .video,
            position: .back
        )
        for type in preferredTypes {
            if let match = discovery.devices.first(where: { $0.deviceType == type }) {
                return match
            }
        }
        return AVCaptureDevice.default(for: .video)
    }

    /// Continuous autofocus biased toward near subjects (QR codes are usually
    /// held close), with continuous auto-exposure.
    private func configureContinuousFocus(for device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else {
            return
        }
        defer { device.unlockForConfiguration() }

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = .near
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
    }

    @objc private func handleTapToFocus(_ gesture: UITapGestureRecognizer) {
        guard let device = captureDevice, let previewLayer else {
            return
        }

        let layerPoint = gesture.location(in: view)
        let focusPoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)

        guard device.isFocusPointOfInterestSupported || device.isExposurePointOfInterestSupported,
              (try? device.lockForConfiguration()) != nil
        else {
            return
        }
        defer { device.unlockForConfiguration() }

        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = focusPoint
            device.focusMode = device.isFocusModeSupported(.continuousAutoFocus) ? .continuousAutoFocus : .autoFocus
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = focusPoint
            device.exposureMode = device.isExposureModeSupported(.continuousAutoExposure) ? .continuousAutoExposure : .autoExpose
        }
    }

    private func startSessionIfNeeded() {
        let generation = attempt.generation
        guard attempt.permitsDelivery(generation: generation) else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startRunning()
        case .notDetermined:
            Task { @MainActor [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard let self, self.attempt.permitsDelivery(generation: generation) else { return }
                if granted {
                    self.startRunning()
                } else {
                    self.onCameraAuthorizationDenied?()
                }
            }
        default:
            // Denied or restricted — surface a recovery path instead of a black frame.
            onCameraAuthorizationDenied?()
        }
    }

    private func startRunning() {
        guard attempt.permitsDelivery(generation: attempt.generation) else { return }
        nonisolated(unsafe) let session = self.session
        sessionQueue.async {
            guard !session.isRunning else {
                return
            }
            session.startRunning()
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        // The delegate is installed on .main. Deliver synchronously so a queued
        // actor task cannot outlive navigation and claim a later visible attempt.
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        MainActor.assumeIsolated {
            let callback = onScan
            let generation = attempt.generation
            // The navigation callback may synchronously change visibility. Mutate
            // a value copy, then publish only while this attempt still owns it.
            var next = attempt
            let accepted = next.receive(value, generation: generation) { callback?($0) ?? false }
            if attempt.generation == generation { attempt = next }
            if accepted { stopSession() }
        }
    }
}

// MARK: Preview / confirm

private struct ImportPreviewView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var checkingCatalog = true
    @State private var catalogCheckFailed = false
    @State private var catalogCheckAttempt = 0

    let configuration: ShareableFilterConfiguration
    var closesAtRoot = false
    let onBack: () -> Void
    /// Add the imported setup as a brand-new filter (the additive default).
    let onAddNew: () -> Void
    /// Replace one of the user's existing filters with the imported setup.
    let onReplace: () -> Void

    var onUpgrade: (() -> Void)? = nil

    private struct ContentItem: Identifiable {
        let id: String
        let title: String
        var metadata: String?
        var verbatimTitle = false
    }

    var body: some View {
        let plan = viewModel.importPlan(for: configuration)
        // Break the planned subset down into the actual things being imported,
        // resolving curated IDs to their human names, rather than bare counts.
        let customIDs = Set(plan.applied.customBlocklists.map(\.id))
        let curatedIDs = plan.applied.enabledBlocklistIDs
            .subtracting(customIDs)
            .sorted { viewModel.blocklistName(for: $0).localizedCaseInsensitiveCompare(viewModel.blocklistName(for: $1)) == .orderedAscending }
        let customBlocklists = plan.applied.customBlocklists
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let blockedDomains = plan.applied.blockedDomains.sorted()
        let rows = curatedIDs.map { sourceID in
            ContentItem(id: "list:\(sourceID)", title: viewModel.blocklistName(for: sourceID),
                        metadata: warmRuleCountText(for: sourceID))
        } + customBlocklists.map { source in
            ContentItem(id: "list:\(source.id)", title: source.displayName,
                        metadata: [warmRuleCountText(for: source.id, customSource: source), source.sourceURL.absoluteString,
                                   plan.applied.enabledBlocklistIDs.contains(source.id) ? nil : "Not enabled".lavaLocalized]
                            .compactMap { $0 }.joined(separator: " · "), verbatimTitle: true)
        } + blockedDomains.map { domain in
            ContentItem(id: "domain:\(domain)", title: domain, verbatimTitle: true)
        }

        return LavaSheetScaffold(spacing: LavaSpacing.xl) {
            VStack(alignment: .leading, spacing: LavaSpacing.lg) {
                Text("Check who shared this filter and review its contents carefully before importing. Shared filters aren’t reviewed by Lava.".lavaLocalized)
                    .lavaSupportingText()
                    .foregroundStyle(LavaStyle.lavaOrangeText)
                if checkingCatalog {
                    ProgressView("Checking available lists…")
                } else if catalogCheckFailed {
                    Text("Couldn’t check available lists. Try again when you’re online.")
                        .lavaQuietNoteText()
                    Button("Try again") { catalogCheckAttempt += 1 }
                        .buttonStyle(LavaSecondaryActionButtonStyle())
                } else {
                    LavaSectionGroup("Lava blocks these") {
                        LavaCondensedList {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                if rows.isEmpty {
                                    LavaEmptyListRow(title: "Nothing to import")
                                }
                                ForEach(rows) { row in
                                    LavaFilterContentRow(title: row.title, metadata: row.metadata, verbatimTitle: row.verbatimTitle, verbatimMetadata: true, outcome: .blocked)
                                    if row.id != rows.last?.id {
                                        LavaCondensedDivider()
                                    }
                                }
                            }
                        }
                    }
                    LavaSectionGroup("Lava lets these through") {
                        LavaCondensedList {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                if let allowed = plan.applied.allowedDomains {
                                    if allowed.isEmpty { LavaEmptyListRow(title: "No allowed exceptions") }
                                    let domains = allowed.sorted()
                                    ForEach(domains, id: \.self) { domain in
                                        LavaFilterContentRow(title: domain, metadata: "Single domain".lavaLocalized, verbatimTitle: true, outcome: .allowed)
                                        if domain != domains.last { LavaCondensedDivider() }
                                    }
                                } else {
                                    LavaEmptyListRow(title: "Not included in this shared filter")
                                }
                            }
                        }
                    }
                    if let allowed = plan.applied.allowedDomains, !allowed.isEmpty {
                        Text("Allowed exceptions include subdomains and can let blocked sites through. Review every entry.".lavaLocalized)
                            .lavaSupportingText()
                    }
                    if !viewModel.configuration.hasLavaSecurityPlus,
                       plan.dropped.contains(where: { [.requiresUpgrade, .exceedsLimit, .exceedsRuleBudget].contains($0.kind) }),
                       let onUpgrade {
                        Button(action: onUpgrade) {
                            LavaOverviewBannerRow(systemImage: "plus.circle.fill", title: "Use Lava Plus for full import".lavaLocalized,
                                tint: LavaStyle.safeGreen, background: LavaStyle.softGreen, allowsTitleWrapping: true)
                        }
                        .buttonStyle(.plain)
                        ForEach(Array(plan.dropped.enumerated()), id: \.offset) { _, entry in
                            if [.requiresUpgrade, .exceedsLimit, .exceedsRuleBudget].contains(entry.kind) {
                                Button(action: onUpgrade) {
                                    LavaFilterContentRow(title: droppedEntryTitle(entry), metadata: "Not imported on this device".lavaLocalized,
                                        verbatimTitle: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if plan.hasUnsupportedEntries {
                        unsupportedSection(for: plan)
                    }
                }
            }
        } footer: {
            VStack(spacing: LavaSpacing.sm) {
                Button((plan.applied.isEmpty ? "Nothing to import" : "Add as a new filter").lavaLocalized) {
                    onAddNew()
                }
                .buttonStyle(LavaStandaloneActionButtonStyle())
                .disabled(checkingCatalog || catalogCheckFailed || plan.applied.isEmpty)

                if !checkingCatalog && !catalogCheckFailed && !plan.applied.isEmpty {
                    Button("Replace a filter instead") { onReplace() }
                        .buttonStyle(LavaSecondaryActionButtonStyle())
                }
            }
        }
        .importFullSheetHeader("Review import", showsSkip: false, onBack: onBack, onSkip: {})
        .task(id: catalogCheckAttempt) {
            checkingCatalog = true
            catalogCheckFailed = false
            do {
                try await viewModel.refreshCatalogForSharedImport(configuration)
            } catch {
                catalogCheckFailed = true
            }
            checkingCatalog = false
        }
    }

    /// Read only values already held locally. Unknown counts stay absent instead
    /// of implying zero, freshness or a requested update. A custom ID alone is not
    /// proof that an imported source matches the device's cached source.
    private func warmRuleCountText(for sourceID: String, customSource: CustomBlocklistSource? = nil) -> String? {
        let count: Int?
        if let customSource {
            guard viewModel.configuration.customBlocklists.contains(where: {
                $0.id == customSource.id && $0.sourceURL == customSource.sourceURL && $0.parseFormat == customSource.parseFormat
            }) else { return nil }
            count = viewModel.cachedBlockRuleSets[sourceID]?.count
        } else if let source = viewModel.sharedImportCatalogSourcesByID?[sourceID], source.entryCount > 0 {
            count = source.entryCount
        } else {
            count = viewModel.cachedBlockRuleSets[sourceID]?.count
        }
        return count.map { "%@ rules".lavaLocalizedFormat($0.formatted()) }
    }

    private struct ImportDisplayEntry {
        let id: String
        let title: String
        let metadata: String
    }

    private func droppedEntryTitle(_ entry: ShareableFilterImportPlan.DroppedEntry) -> String {
        guard entry.kind == .exceedsRuleBudget else { return entry.label }
        return viewModel.blocklistName(for: entry.label)
    }

    private func localCount(_ id: String, custom: CustomBlocklistSource? = nil) -> String {
        guard let count = viewModel.localBlocklistEntryCount(for: id, customSource: custom) else {
            return "Count unavailable".lavaLocalized
        }
        return "%@ rules".lavaLocalizedFormat(count.formatted())
    }

    @ViewBuilder
    private func unsupportedSection(for plan: ShareableFilterImportPlan) -> some View {
        let unavailable = plan.droppedCount(of: .unavailableBlocklist)
        let upgrade = plan.droppedCount(of: .requiresUpgrade)
        let overLimit = plan.droppedCount(of: .exceedsLimit)
        let unsafe = plan.droppedCount(of: .unsafeSource)
        let overBudget = plan.droppedCount(of: .exceedsRuleBudget)
        let invalid = plan.droppedCount(of: .invalidDomain)

        LavaSectionGroup("Not imported on this device") {
            VStack(spacing: 10) {
                if invalid > 0 { ImportAlertRow(title: "Some domains were invalid or cannot be allowed.".lavaLocalized) }
                if unavailable > 0 {
                    Text(ImportFiltersFlow.unavailableListsMessage(unavailable))
                        .lavaQuietNoteText()
                }
                if upgrade > 0 {
                    ImportAlertRow(
                        title: (upgrade == 1 ? "%@ custom blocklist needs Lava Security+" : "%@ custom blocklists need Lava Security+").lavaLocalizedFormat(upgrade.formatted())
                    )
                }
                if overLimit > 0 {
                    ImportAlertRow(
                        title: (overLimit == 1 ? "%@ domain is over your plan's limit" : "%@ domains are over your plan's limit").lavaLocalizedFormat(overLimit.formatted())
                    )
                }
                if unsafe > 0 {
                    ImportAlertRow(
                        title: (unsafe == 1 ? "%@ custom blocklist was skipped for safety" : "%@ custom blocklists were skipped for safety").lavaLocalizedFormat(unsafe.formatted())
                    )
                }
                if overBudget > 0 {
                    ImportAlertRow(
                        title: (overBudget == 1 ? "%@ blocklist didn't fit your plan's rule limit" : "%@ blocklists didn't fit your plan's rule limit").lavaLocalizedFormat(overBudget.formatted())
                    )
                }
            }
        }
    }
}

/// Alert-styled row calling out something that couldn't be imported.
private struct ImportAlertRow: View {
    let title: String

    var body: some View {
        LavaOverviewBannerRow(
            systemImage: "exclamationmark.triangle.fill",
            title: title,
            tint: LavaStyle.lavaOrange,
            background: LavaStyle.lavaOrangeSoft,
            allowsTitleWrapping: true
        )
    }
}

/// Presents the same package-owned content diff as backup restore, before any import mutation.
private struct ImportReplacementReviewView: View {
    let summary: FilterReplacementSummary
    let onBack: () -> Void
    let onReplace: () -> Void
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        LavaSheetScaffold(spacing: 18) {
            VStack(alignment: .leading, spacing: 16) {
                LavaInfoPanel(
                    title: "Review import",
                    description: "The selected filter keeps its name. Review the content changes below.",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                Text(summary.before?.name ?? "").font(.headline)
                Text(Self.removalSummary(summary)).lavaQuietNoteText()
                changes("Blocklists", removed: summary.removedBlocklistIDs.map { name($0, in: summary.before) },
                        added: summary.addedBlocklistIDs.map { name($0, in: summary.after) })
                changes("Blocked domains", removed: summary.selectionDiff.removedBlockedDomains,
                        added: summary.selectionDiff.addedBlockedDomains)
                changes("Custom blocklists", removed: summary.removedCustomBlocklists.map(sourceDescription),
                        added: summary.addedCustomBlocklists.map(sourceDescription))
                changes("Allowed Exceptions", removed: summary.selectionDiff.removedAllowedDomains,
                        added: summary.selectionDiff.addedAllowedDomains)
            }
        } footer: {
            Button("Replace a filter", role: .destructive, action: onReplace)
                .buttonStyle(LavaStandaloneActionButtonStyle())
        }
        .importFullSheetHeader("Review import", showsSkip: false, onBack: onBack, onSkip: {})
    }

    static func removalSummary(_ summary: FilterReplacementSummary) -> String {
        "Removed: %1$lld blocklists, %2$lld blocked domains, %3$lld custom sources, %4$lld allowed exceptions.".lavaLocalizedFormat(
            summary.removedBlocklistIDs.count,
            summary.selectionDiff.removedBlockedDomains.count,
            summary.removedCustomBlocklists.count,
            summary.selectionDiff.removedAllowedDomains.count)
    }

    @ViewBuilder
    private func changes(_ title: String, removed: [String], added: [String]) -> some View {
        if !removed.isEmpty || !added.isEmpty {
            LavaSectionGroup(title) {
                VStack(alignment: .leading, spacing: 8) {
                    if !removed.isEmpty {
                        Text("Removed").font(.subheadline.weight(.semibold))
                        Text(removed.joined(separator: "\n")).textSelection(.enabled)
                    }
                    if !added.isEmpty {
                        Text("Added").font(.subheadline.weight(.semibold))
                        Text(added.joined(separator: "\n")).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func name(_ id: String, in filter: Filter?) -> String {
        filter?.customBlocklists.first(where: { $0.id == id })?.displayName ?? viewModel.blocklistName(for: id)
    }

    private func sourceDescription(_ source: CustomBlocklistSource) -> String {
        "\(source.displayName) · \(source.sourceURL.absoluteString) · \(source.parseFormat.rawValue)"
    }
}

// MARK: Add-as-new (name) + Replace (picker) stages

/// Pick which existing filter the import should replace. Replacing the in-effect filter reloads
/// the tunnel; any other filter is replaced library-only. A frozen (lapsed-Plus) filter is
/// read-only and can't be a replace target.
private struct ImportChooseReplaceTargetView: View {
    var onUpgrade: (() -> Void)? = nil
    @EnvironmentObject private var viewModel: AppViewModel
    let onBack: () -> Void
    let onReplace: (Filter) -> Void

    var body: some View {
        LavaSheetScaffold(spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                LavaInfoPanel(
                    title: "Replace which filter?",
                    description: "The selected filter keeps its name. Review the content changes below.",
                    systemImage: "arrow.triangle.2.circlepath"
                )

                LavaSectionGroup("Your filters") {
                    LavaCondensedList {
                        let filters = viewModel.filters
                        ForEach(filters) { filter in
                            ImportReplaceTargetRow(
                                name: filter.name,
                                summary: summary(for: filter),
                                isReplaceable: !viewModel.isFilterFrozen(filter.id)
                            ) {
                                if viewModel.isFilterFrozen(filter.id) { onUpgrade?() } else { onReplace(filter) }
                            }

                            if filter.id != filters.last?.id {
                                LavaCondensedDivider()
                            }
                        }
                    }
                }
            }
        }
        .importFullSheetHeader("Replace a filter", showsSkip: false, onBack: onBack, onSkip: {})
    }

    private func summary(for filter: Filter) -> String {
        if viewModel.isFilterFrozen(filter.id) {
            return "Locked".lavaLocalized
        }
        let rules = filter.isEmpty
            ? "Blocks nothing".lavaLocalized
            : "%@ rules".lavaLocalizedFormat(viewModel.filterRuleCount(for: filter).formatted())
        if filter.id == viewModel.activeFilterID {
            return "%1$@ · %2$@".lavaLocalizedFormat(rules, "In effect".lavaLocalized)
        }
        return rules
    }
}

/// One row in the import replace-target picker: name + summary. Frozen rows keep
/// their lock styling and remain tappable to open the contextual Lava Plus view.
private struct ImportReplaceTargetRow: View {
    let name: String
    let summary: String
    let isReplaceable: Bool
    let action: () -> Void

    var body: some View {
        LavaNavigationCardButton(action: action) {
            LavaNavigationCardLabel(
                badge: .systemImage("line.3.horizontal.decrease.circle", tint: isReplaceable ? LavaStyle.safeGreen : LavaStyle.secondaryText),
                badgeSize: LavaToolbarMetrics.iconFrameSize,
                rowSpacing: LavaSpacing.md,
                title: name,
                localizesTitle: false,
                summary: .localizedUnclamped(summary),
                accessory: isReplaceable ? .chevron : .lock
            )
        }
    }
}

private struct ImportApplyingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Applying filter…")
                .lavaSupportingText()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LavaStyle.groupedBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: Shared import header (stage-machine Back and optional Skip)

private extension View {
    @MainActor
    func importFullSheetHeader(
        _ title: String,
        showsSkip: Bool,
        onBack: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) -> some View {
        lavaFullSheetHeader(title, leading: {
            NativeToolbarIconButton(systemName: "chevron.left", accessibilityLabel: "Back", action: onBack)
        }, trailing: {
            if showsSkip {
                Button("Skip", action: onSkip)
                    .lavaQuietLinkText()
                    .buttonStyle(.plain)
            }
        })
    }
}

// MARK: Error copy

enum ShareableFilterImportMessages {
    static func message(for error: Error) -> String {
        // The link parser wraps code errors rather than replacing them. Unwrap, or
        // every scan of an edited code would degrade to the generic message and
        // lose the one instruction that helps: ask for a fresh one.
        if let inputError = error as? ShareableFilterInputError {
            switch inputError {
            case .unrecognizedFormat, .invalidUniversalLink:
                return "That doesn't look like a Lava filter code."
            case .configurationCode(let codeError):
                return message(forCode: codeError)
            }
        }

        guard let codeError = error as? ShareableFilterConfigurationCodeError else {
            return "That code couldn't be read. Double-check it and try again."
        }
        return message(forCode: codeError)
    }

    private static func message(forCode codeError: ShareableFilterConfigurationCodeError) -> String {
        switch codeError {
        case .unrecognizedFormat:
            return "That doesn't look like a Lava filter code."
        case .integrityCheckFailed:
            return "This code looks edited or incomplete. Ask for a fresh one."
        case .unsupportedVersion:
            return "This code needs a newer version of Lava. Update the app and try again."
        case .malformedPayload:
            return "That code couldn't be read. Double-check it and try again."
        case .payloadTooLarge:
            return "This code is too large to import safely."
        }
    }
}
