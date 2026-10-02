import SwiftUI
import LavaSecKit

/// A row owns its content insets once, regardless of first/last position or refresh.
struct LavaTableRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LavaRowHeight.horizontalInset)
            .padding(.vertical, LavaRowHeight.verticalInset)
            .frame(minHeight: LavaRowHeight.standard)
    }
}

struct LavaCondensedList<Content: View>: View {
    let content: Content
    let surface: LavaSurface.Role

    init(surface: LavaSurface.Role = .card, @ViewBuilder content: () -> Content) {
        self.surface = surface
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lavaSurface(surface)
    }
}

/// Placeholder row shown inside a card list whose data collection is empty. ONE scaffold —
/// the shared 15pt row-title role on `.primary` and standard row geometry — so every empty list renders
/// at the same height as the Filters shelves' empty rows. Screens must not hand-roll their own
/// placeholder `Text` with per-screen font/padding: that is exactly how the Network Activity
/// empty row drifted shorter (and grayer) than its siblings.
/// pinned: TypographyScaleSourceTests.testEmptyListRowIsSharedAndCarriesRowRole
struct LavaEmptyListRow: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.lavaLocalized)
                .font(LavaTypography.rowTitle)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle {
                Text(subtitle.lavaLocalized)
                    .lavaRowSubtitleText()
            }
        }
        .lavaRow()
    }
}

struct LavaCondensedDivider: View {
    var leadingInset: CGFloat = 16

    var body: some View {
        Divider()
            .padding(.leading, leadingInset)
            .padding(.trailing, 16)
    }
}

/// Which side of a filter a content row belongs to. The row owns the mark so the
/// blocked/allowed outline cannot drift between the filter detail and the import
/// review; see `LavaOutcomeSymbol.blockedOutline`.
enum LavaFilterContentOutcome {
    case blocked
    case allowed

    var symbol: String {
        switch self {
        case .blocked: LavaOutcomeSymbol.blockedOutline
        case .allowed: LavaOutcomeSymbol.allowedOutline
        }
    }
}

/// Shared blocklist/domain text row for View filter and import review. Reading a
/// shared setup uses the same type, insets and content height as reading a filter.
/// The accessory is supplied by edit mode; its absence never changes the row floor.
/// An optional `outcome` leads the row with the outcome's stroke-only mark.
struct LavaFilterContentRow<Accessory: View>: View {
    let title: String
    var metadata: String? = nil
    var isInactive = false
    var verbatimTitle = false
    var verbatimMetadata = false
    var outcome: LavaFilterContentOutcome? = nil
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: LavaSpacing.md) {
            // Stroke-only and untinted, matching the numbered marks on the DNS
            // and WireGuard list rows; the mark is decorative (the row label
            // carries the meaning for VoiceOver).
            if let outcome {
                Image(systemName: outcome.symbol)
                    .accessibilityHidden(true)
                    .padding(.vertical, LavaRowHeight.verticalInset)
            }

            VStack(alignment: .leading, spacing: LavaSpacing.xs) {
                Text(verbatimTitle ? title : title.lavaLocalized)
                    .lavaRowTitleText()
                    .foregroundStyle(isInactive ? LavaStyle.secondaryText : LavaStyle.primaryText)
                    .strikethrough(isInactive, color: LavaStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let metadata, !metadata.isEmpty {
                    Text(verbatimMetadata ? metadata : metadata.lavaLocalized)
                        .lavaMetadataText()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .padding(.vertical, LavaRowHeight.verticalInset)

            // Reserve the same width and height before an edit control appears,
            // so neither title wrapping nor the row floor changes with edit mode.
            // The 44pt hit area shares the content inset instead of adding to it.
            ZStack { accessory() }
                .frame(width: LavaToolbarMetrics.buttonSize)
                .frame(minHeight: LavaToolbarMetrics.buttonSize)
        }
        .padding(.horizontal, LavaRowHeight.horizontalInset)
        .frame(minHeight: LavaRowHeight.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isInactive ? 0.68 : 1)
    }
}

extension LavaFilterContentRow where Accessory == EmptyView {
    init(title: String, metadata: String? = nil, verbatimTitle: Bool = false, verbatimMetadata: Bool = false, outcome: LavaFilterContentOutcome? = nil) {
        self.init(title: title, metadata: metadata, verbatimTitle: verbatimTitle, verbatimMetadata: verbatimMetadata, outcome: outcome, accessory: { EmptyView() })
    }
}

struct LavaCondensedStatus {
    let text: String
    let foreground: Color
    let background: Color

    init(text: String, tint: Color, background: Color? = nil) {
        self.text = text
        self.foreground = tint
        self.background = background ?? tint.opacity(0.12)
    }

    init(text: String, foreground: Color, background: Color) {
        self.text = text
        self.foreground = foreground
        self.background = background
    }

    static let newlyAdded = LavaCondensedStatus(text: "New", tint: LavaStyle.safeGreen)
    static let pendingRemoval = LavaCondensedStatus(text: "Pending remove", tint: LavaStyle.lavaOrangeText)

    static func blocklistSizeBucket(entryCount: Int) -> LavaCondensedStatus {
        let bucket = BlocklistSourceSizeBucket.bucket(forEntryCount: entryCount)
        return LavaCondensedStatus(
            text: bucket.abbreviation,
            foreground: LavaStyle.secondaryText,
            background: LavaStyle.secondaryText.opacity(0.12)
        )
    }
}

struct LavaCondensedTrailingAction {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
}

private enum LavaCondensedListMetrics {
    static let metadataLineMinHeight: CGFloat = 20
}

struct LavaCondensedListItem<Leading: View>: View {
    let title: String
    var subtitle: String?
    var metadata: String?
    var metadataPrefixStatus: LavaCondensedStatus?
    var status: LavaCondensedStatus?
    var isInactive = false
    var titleFont: Font = LavaTypography.rowTitle
    var titleLineLimit = 2
    var trailingAction: LavaCondensedTrailingAction?
    private let leading: Leading

    init(
        title: String,
        subtitle: String? = nil,
        metadata: String? = nil,
        metadataPrefixStatus: LavaCondensedStatus? = nil,
        status: LavaCondensedStatus? = nil,
        isInactive: Bool = false,
        titleFont: Font = LavaTypography.rowTitle,
        titleLineLimit: Int = 2,
        trailingAction: LavaCondensedTrailingAction? = nil,
        @ViewBuilder leading: () -> Leading
    ) {
        self.title = title
        self.subtitle = subtitle
        self.metadata = metadata
        self.metadataPrefixStatus = metadataPrefixStatus
        self.status = status
        self.isInactive = isInactive
        self.titleFont = titleFont
        self.titleLineLimit = titleLineLimit
        self.trailingAction = trailingAction
        self.leading = leading()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leading
                .padding(.vertical, LavaRowHeight.verticalInset)

            VStack(alignment: .leading, spacing: 4) {
                Text(title.lavaLocalized)
                    .font(titleFont)
                    .lavaInactiveText(isInactive)
                    .lineLimit(titleLineLimit)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle {
                    Text(subtitle.lavaLocalized)
                        .lavaRowSubtitleText()
                }

                HStack(spacing: LavaSpacing.sm) {
                    if let metadataPrefixStatus {
                        LavaCondensedStatusPill(status: metadataPrefixStatus)
                    }

                    if let metadata {
                        Text(metadata.lavaLocalized)
                            .lavaMetadataText()
                    }

                    if let status {
                        LavaCondensedStatusPill(status: status)
                    }
                }
                .frame(minHeight: LavaCondensedListMetrics.metadataLineMinHeight, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            .padding(.vertical, LavaRowHeight.verticalInset)

            Spacer(minLength: 6)

            if let trailingAction {
                LavaToolbarIconButton(systemName: trailingAction.systemImage,
                                      accessibilityLabel: trailingAction.title,
                                      tint: trailingAction.tint, action: trailingAction.action)
            }
        }
        .padding(.horizontal, LavaRowHeight.horizontalInset)
        .frame(minHeight: LavaRowHeight.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(isInactive ? 0.68 : 1)
    }
}

extension LavaCondensedListItem where Leading == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        metadata: String? = nil,
        metadataPrefixStatus: LavaCondensedStatus? = nil,
        status: LavaCondensedStatus? = nil,
        isInactive: Bool = false,
        titleFont: Font = LavaTypography.rowTitle,
        titleLineLimit: Int = 2,
        trailingAction: LavaCondensedTrailingAction? = nil
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            metadata: metadata,
            metadataPrefixStatus: metadataPrefixStatus,
            status: status,
            isInactive: isInactive,
            titleFont: titleFont,
            titleLineLimit: titleLineLimit,
            trailingAction: trailingAction
        ) {
            EmptyView()
        }
    }
}

private struct LavaCondensedStatusPill: View {
    let status: LavaCondensedStatus

    var body: some View {
        Text(status.text.lavaLocalized)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(status.foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minHeight: LavaCondensedListMetrics.metadataLineMinHeight)
            .background(status.background, in: Capsule())
    }
}
