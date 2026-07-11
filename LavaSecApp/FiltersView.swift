import SwiftUI
import LavaSecKit

struct FiltersView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var catalog: CatalogController
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
                await catalog.sync()
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
        // The normal description is user data, so it stays verbatim and truncates
        // (rather than shrinking) at one line. The warning remains localized.
        let summary: LavaNavigationCardSummary = isUnprotected
            ? .warningLocalized("Blocks nothing — not protected")
            : .verbatimSingleLine(activeFilter.name)

        Button(action: action) {
            LavaNavigationCardLabel(
                badge: .systemImage(
                    isUnprotected ? "exclamationmark.shield.fill" : "play.circle.fill",
                    font: .title3.weight(.semibold),
                    tint: isUnprotected ? LavaStyle.lavaOrangeText : LavaStyle.safeGreen,
                    background: isUnprotected ? LavaStyle.lavaOrange.opacity(0.12) : LavaStyle.softGreen
                ),
                badgeSize: 38,
                rowSpacing: 14,
                title: "Now filtering",
                titleLineLimit: 1,
                summary: summary,
                accessory: .chevron
            )
        }
        .buttonStyle(.plain)
    }
}

/// The two connection states the overview card lets the user preview to learn how
/// Lava behaves. Purely educational (user-driven) — NOT wired to live tunnel health.
/// "Poor" teaches the fail-closed behavior: when the PHONE can't reach the internet, Lava
/// blocks sites to stay safe (the same precautionary block that, mislabelled, used to fill
/// the Blocked tab with false positives). Framed as the phone's connectivity, NOT "Lava
/// can't reach its filter" — the filter is local, so that framing is misleading.
private enum FilterConnectionPreview: CaseIterable {
    case normal
    case poor

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .poor: return "Poor"
        }
    }

    var caption: String {
        switch self {
        case .normal:
            return "Lava uses a local filter to block your phone's access to unwanted sites."
        case .poor:
            return "When your phone can't reach the internet, Lava blocks sites to stay safe — they load again once your connection is back."
        }
    }
}

private struct FiltersOverviewPanel: View {
    @State private var preview: FilterConnectionPreview = .normal
    @State private var showingPicker = false

    var body: some View {
        // Diagram + explainer back together inside the card (the "below the panel"
        // placement read too faint); the card stays content-sized.
        LavaInfoCard {
            VStack(spacing: 14) {
                connectionSelector

                FiltersFlowDiagram(blockedSecondHop: preview == .poor)

                Text(preview.caption.lavaLocalized)
                    .lavaBodySupportingText()
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    // Keep the card height stable across the shorter/longer captions so the
                    // diagram doesn't jump when the user toggles states.
                    .animation(.default, value: preview)
            }
        }
    }

    // "Connection [Normal ▾]" — a lead-in label plus a tappable state chip. Tapping opens an
    // in-place popover (comic-dialog bubble on iPhone via compact adaptation) to pick the state.
    private var connectionSelector: some View {
        HStack(spacing: 8) {
            Text("When the connection is".lavaLocalized)
                .font(.subheadline)
                .foregroundStyle(LavaStyle.secondaryText)
                // The lead-in reads as part of the picker's own label below, so don't
                // announce it as a separate VoiceOver element.
                .accessibilityHidden(true)

            Button {
                showingPicker = true
            } label: {
                HStack(spacing: 4) {
                    Text(preview.label.lavaLocalized)
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(LavaStyle.lavaOrangeText)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(LavaStyle.lavaOrangeSoft))
            }
            .buttonStyle(.plain)
            // Announce this as a picker: a stable label with the current option as the value.
            .accessibilityLabel(Text("When the connection is".lavaLocalized))
            .accessibilityValue(Text(preview.label.lavaLocalized))
            .popover(isPresented: $showingPicker) {
                connectionPickerPopover
                    .presentationCompactAdaptation(.popover)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var connectionPickerPopover: some View {
        VStack(spacing: 0) {
            ForEach(Array(FilterConnectionPreview.allCases.enumerated()), id: \.offset) { index, option in
                Button {
                    preview = option
                    showingPicker = false
                } label: {
                    HStack(spacing: 16) {
                        Text(option.label.lavaLocalized)
                            .font(.subheadline)
                            .foregroundStyle(LavaStyle.primaryText)
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LavaStyle.lavaOrangeText)
                            .opacity(option == preview ? 1 : 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The selected option is shown by a checkmark (a non-color shape cue); also
                // expose it to VoiceOver as the selected element.
                .accessibilityAddTraits(option == preview ? [.isSelected] : [])

                if index < FilterConnectionPreview.allCases.count - 1 {
                    Divider()
                }
            }
        }
        .frame(minWidth: 168)
    }
}

/// One-glance explanation of where Lava sits: your phone reaches the internet
/// through Lava acting as a local filter. Laid out with fixed object:arrow width
/// ratios (≈3.5:1) so the nodes stay large and the spacing scales with the card.
private struct FiltersFlowDiagram: View {
    /// When true the Lava→Internet hop is shown blocked (a small X on the arrow) — the
    /// "Poor connection" fail-closed preview. Phone→Lava always stays open.
    var blockedSecondHop: Bool = false

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

                connector(blocked: false).frame(width: width * arrowRatio)

                node(label: "Lava") {
                    SoftShieldGuardian(size: 62, state: .awake, animates: false)
                }
                .frame(width: width * nodeRatio)

                connector(blocked: blockedSecondHop).frame(width: width * arrowRatio)

                node(label: "Internet".lavaLocalized) {
                    Image(systemName: "globe")
                        .font(.system(size: LavaIconSize.node, weight: .regular))
                        .foregroundStyle(LavaStyle.secondaryText.opacity(blockedSecondHop ? 0.35 : 1))
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

    private func connector(blocked: Bool) -> some View {
        ZStack {
            Image(systemName: "arrow.right")
                .font(.system(size: LavaIconSize.small, weight: .semibold))
                .foregroundStyle(LavaStyle.secondaryText.opacity(blocked ? 0.3 : 0.6))

            if blocked {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LavaStyle.dangerRed)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: iconBoxHeight)
    }
}
