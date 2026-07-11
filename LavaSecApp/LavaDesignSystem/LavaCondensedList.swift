import SwiftUI
import LavaSecKit

struct LavaCondensedList<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lavaSurface(.card)
    }
}

/// Placeholder row shown inside a card list whose data collection is empty. ONE scaffold —
/// the 15pt row-title face on `.primary` plus fixed 16pt insets — so every empty list renders
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LavaRowHeight.horizontalInset)
        .padding(.vertical, 16)
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

            VStack(alignment: .leading, spacing: 4) {
                Text(title.lavaLocalized)
                    .font(titleFont)
                    .lavaInactiveText(isInactive)
                    .lineLimit(titleLineLimit)
                    .minimumScaleFactor(0.82)
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
        .padding(.horizontal, LavaRowHeight.horizontalInset)
        .padding(.vertical, 11)
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
