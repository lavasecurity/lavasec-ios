import SwiftUI

/// Selection state for a ``LavaSelectableRow``. `.locked` renders a lock glyph for
/// rows still gated behind usage/Plus instead of the selection checkmark.
enum LavaRowSelectionState: Equatable {
    case selected
    case unselected
    case locked
}

/// The single selection glyph shared by every single- and multi-select list in the
/// app: a trailing checkmark for chosen rows (Apple's HIG single-select convention),
/// a lock for gated rows, and a reserved-width blank otherwise so row content stays
/// aligned whether or not a row is selected.
struct LavaSelectionAccessory: View {
    let state: LavaRowSelectionState
    var tint: Color = LavaStyle.safeGreen

    /// Reserved width so selected and unselected rows align identically.
    static let columnWidth: CGFloat = 24

    var body: some View {
        Group {
            switch state {
            case .selected:
                Image(systemName: "checkmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(tint)
            case .locked:
                Image(systemName: "lock.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LavaStyle.secondaryText)
            case .unselected:
                Color.clear
            }
        }
        .frame(width: Self.columnWidth, height: Self.columnWidth)
        .accessibilityHidden(true)
    }
}

/// Shared scaffold for selectable list rows. Arranges arbitrary leading `content`
/// against a trailing ``LavaSelectionAccessory``, and owns the row's selection
/// accessibility trait, disabled dimming, and tap target. Padding and min-height are
/// parameterized so each list keeps its own vertical rhythm while sharing one
/// selection mechanic and one glyph (Guard looks, DNS providers, blocklists).
struct LavaSelectableRow<Content: View>: View {
    let state: LavaRowSelectionState
    var isEnabled: Bool = true
    var accessoryTint: Color = LavaStyle.safeGreen
    var horizontalPadding: CGFloat = LavaRowHeight.horizontalInset
    var verticalPadding: CGFloat = 11
    var minHeight: CGFloat = LavaRowHeight.standard
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            LavaSelectionAccessory(state: state, tint: accessoryTint)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(minHeight: minHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.68)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(state == .selected ? .isSelected : [])
    }
}
