import SwiftUI
import LavaSecCore

enum FilterReviewOrigin: String, Identifiable {
    case filters
    case domainHistory

    var id: String { rawValue }

    var failureBackTitle: String {
        switch self {
        case .filters:
            return "Back to Edit"
        case .domainHistory:
            return "Back to Review"
        }
    }
}

struct DomainRejectPanel: View {
    let title: String
    let message: String

    var body: some View {
        LavaInfoPanel(
            title: title,
            description: message,
            systemImage: "exclamationmark.triangle.fill",
            tint: LavaStyle.lavaOrange,
            borderTint: LavaStyle.lavaOrange
        )
    }
}

struct FilterConfirmationSheet: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    let origin: FilterReviewOrigin
    @State private var didConfirm = false

    var body: some View {
        NavigationStack {
            LavaSheetScaffold(spacing: 18) {
                Text("%@ will be prepared and saved locally.".lavaLocalizedFormat(viewModel.filterDraftChangeCountText))
                    .lavaBodySupportingText()
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let validationMessage = viewModel.filterDraftValidationMessage {
                    DomainRejectPanel(
                        title: "Review cannot continue",
                        message: validationMessage
                    )
                }

                let diff = viewModel.filterDraftDiff
                if !diff.addedAllowedDomains.isEmpty {
                    LavaInfoPanel(
                        title: "Be extra careful",
                        description: "Allowed exceptions let a site through even when a blocklist would catch it.",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: LavaStyle.lavaOrange
                    )
                }
                DiffGroup(
                    title: "Blocklists",
                    added: diff.addedBlocklistIDs.map { viewModel.blocklistName(for: $0) },
                    removed: diff.removedBlocklistIDs.map { viewModel.blocklistName(for: $0) }
                )
                DiffGroup(title: "Blocked Domains", added: diff.addedBlockedDomains, removed: diff.removedBlockedDomains)
                DiffGroup(title: "Allowed Exceptions", added: diff.addedAllowedDomains, removed: diff.removedAllowedDomains)
            } footer: {
                Button("Confirm Changes") {
                    didConfirm = true
                    dismiss()
                    Task {
                        await viewModel.prepareAndApplyFilterDraft(origin: origin)
                    }
                }
                .buttonStyle(LavaStandaloneActionButtonStyle())
                .disabled(!viewModel.filterDraftCanConfirm)
            }
            .navigationTitle("Review".lavaLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Cancel", role: .cancel) {
                        cancelIfStandaloneReview()
                        dismiss()
                    }
                }
            }
            .lavaTier(.calm)
        }
        .presentationDetents([.medium, .large])
        .onDisappear {
            cancelIfStandaloneReview()
        }
    }

    private func cancelIfStandaloneReview() {
        guard origin == .domainHistory, !didConfirm else {
            return
        }

        viewModel.cancelFilterEditing()
    }
}

struct DiffGroup: View {
    let title: String
    let added: [String]
    let removed: [String]

    var body: some View {
        if !added.isEmpty || !removed.isEmpty {
            LavaSectionGroup(title) {
                LavaCondensedList {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        FilterReviewChangeRow(symbol: row.symbol, title: row.title, tint: row.tint, localizesTitle: false)

                        if index < rows.count - 1 {
                            LavaCondensedDivider(leadingInset: 52)
                        }
                    }
                }
            }
        }
    }

    private var rows: [(symbol: String, title: String, tint: Color)] {
        added.map { ("+", $0, LavaStyle.safeGreen) } + removed.map { ("-", $0, LavaStyle.lavaOrange) }
    }
}

struct FilterReviewChangeRow: View {
    let symbol: String
    let title: String
    let tint: Color
    // Diff titles are usually fixed UI strings (localize them), but user-supplied values —
    // e.g. a filter's name in the delete-review sheet — must render raw: a name that happens
    // to match a localization key (`Cancel`, `Save`, the default `Filter`) would otherwise show
    // a translated UI string and misidentify what's being removed in non-English locales.
    var localizesTitle: Bool = true

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)

            Text(localizesTitle ? title.lavaLocalized : title)
                .font(.body.weight(.semibold))
                .foregroundStyle(LavaStyle.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.86)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var systemImage: String {
        symbol == "+" ? "plus" : "minus"
    }
}

struct FilterPreparationScreen: View {
    @EnvironmentObject private var viewModel: AppViewModel

    let origin: FilterReviewOrigin
    let returnToReview: (() -> Void)?

    init(origin: FilterReviewOrigin, returnToReview: (() -> Void)? = nil) {
        self.origin = origin
        self.returnToReview = returnToReview
    }

    var body: some View {
        ZStack {
            LavaStyle.groupedBackground
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                switch viewModel.filterPreparationState {
                case .idle:
                    SoftShieldGuardian(size: 76, state: .waking, shieldStyle: viewModel.lavaGuardLook)
                    PreparationTickerTitle(FilterPreparationPresentation.message(for: .downloading))

                case .preparing(let progress, let message):
                    if progress >= 1 {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: LavaIconSize.heroResult, weight: .bold))
                            .foregroundStyle(LavaStyle.safeGreen)
                        PreparationTickerTitle("Success")
                    } else {
                        SoftShieldGuardian(size: 76, state: .waking, shieldStyle: viewModel.lavaGuardLook)
                        PreparationTickerTitle(message)

                        ProgressView(value: progress, total: 1)
                            .tint(LavaStyle.safeGreen)
                            .frame(maxWidth: 280)
                    }

                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: LavaIconSize.heroResult, weight: .bold))
                        .foregroundStyle(LavaStyle.lavaOrange)

                    VStack(spacing: 10) {
                        Text("We couldn't update your filter")
                            .font(.title.bold())
                            .multilineTextAlignment(.center)
                        Text(message.lavaLocalized)
                            .lavaBodySupportingText()
                            .multilineTextAlignment(.center)
                        Text("Your previous filter is still active.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(LavaStyle.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(.top, 6)
                    }

                    VStack(spacing: 10) {
                        // A dead-end failure (switch target deleted/frozen mid-prepare) isn't
                        // retryable — retrying just re-fails — so "Keep Current Filter" is the
                        // only recovery there.
                        if viewModel.filterPreparationFailureIsRetryable {
                            Button("Try Again") {
                                viewModel.retryFilterPreparation()
                            }
                            .buttonStyle(LavaStandaloneActionButtonStyle())
                        }

                        // A filter switch has no editor/review to go back to, so hide the
                        // "Back to Edit"/"Back to Review" affordance for it.
                        if viewModel.filterPreparationFailureOffersEditReturn {
                            Button {
                                viewModel.returnToFilterEditAfterPrepareFailure()
                                returnToReview?()
                            } label: {
                                Text(origin.failureBackTitle.lavaLocalized)
                            }
                            .buttonStyle(LavaSecondaryActionButtonStyle())
                        }

                        Button(role: .cancel) {
                            viewModel.keepCurrentFiltersAfterPrepareFailure()
                        } label: {
                            Text("Keep Current Filter")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(LavaStyle.secondaryText)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: 320)
                }

                Spacer()
            }
            .padding(24)
        }
    }
}

struct PreparationTickerTitle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    @State private var displayedText: String
    @State private var titleOpacity = 1.0
    @State private var titleOffset: CGFloat = 0

    init(_ text: String) {
        self.text = text
        _displayedText = State(initialValue: text)
    }

    var body: some View {
        Text(displayedText.lavaLocalized)
            .font(.title.bold())
            .lineLimit(2)
            .minimumScaleFactor(0.86)
            .multilineTextAlignment(.center)
            .opacity(titleOpacity)
            .offset(y: titleOffset)
            .frame(maxWidth: 340)
            .frame(maxWidth: .infinity, minHeight: 76)
            .task(id: text) {
                guard displayedText != text else {
                    titleOpacity = 1
                    titleOffset = 0
                    return
                }

                withAnimation(.easeIn(duration: reduceMotion ? 0.08 : 0.14)) {
                    titleOpacity = 0
                    if reduceMotion {
                        titleOffset = 0
                    } else {
                        titleOffset = -18
                    }
                }
                try? await Task.sleep(nanoseconds: reduceMotion ? 80_000_000 : 140_000_000)
                guard !Task.isCancelled else {
                    return
                }

                displayedText = text
                if reduceMotion {
                    titleOffset = 0
                } else {
                    titleOffset = 18
                }
                withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.22)) {
                    titleOpacity = 1
                    titleOffset = 0
                }
            }
    }
}
