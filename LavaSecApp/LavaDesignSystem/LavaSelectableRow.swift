import SwiftUI

/// Selection state for a ``LavaSelectableRow``. `.locked` renders a lock glyph for
/// rows still gated behind usage/Plus instead of the selection checkmark.
enum LavaRowSelectionState: Equatable {
    case selected
    case unselected
    case locked
}

/// The single selection glyph shared by every single- and multi-select list in the
/// app: a trailing filled check circle for chosen rows,
/// a lock for gated rows, and a reserved-width blank otherwise so row content stays
/// aligned whether or not a row is selected.
struct LavaSelectionAccessory: View {
    @Environment(\.isEnabled) private var environmentEnabled
    let state: LavaRowSelectionState
    var isEnabled = true

    /// Reserved width so selected and unselected rows align identically.
    static let columnWidth = LavaToolbarMetrics.buttonSize

    var body: some View {
        Group {
            switch state {
            case .selected:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: LavaNavigationRowMetrics.glyphPointSize, weight: .regular))
                    .foregroundStyle(isEnabled && environmentEnabled ? LavaStyle.safeGreen : LavaStyle.secondaryText)
            case .locked:
                Image(systemName: "lock.fill")
                    .font(.system(size: LavaNavigationRowMetrics.glyphPointSize, weight: .regular))
                    .foregroundStyle(LavaStyle.secondaryText)
            case .unselected:
                Color.clear
            }
        }
        .frame(width: Self.columnWidth, height: LavaToolbarMetrics.iconFrameSize)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .accessibilityHidden(true)
    }
}

/// Shared scaffold for selectable list rows. Arranges arbitrary leading `content`
/// against a trailing ``LavaSelectionAccessory``, and owns the row's selection
/// accessibility trait, disabled colour, and tap target. Padding and min-height are
/// parameterized so each list keeps its own vertical rhythm while sharing one
/// selection mechanic and one glyph (Guard looks, DNS providers, blocklists).
struct LavaSelectableRow<Content: View>: View {
    let state: LavaRowSelectionState
    var isEnabled: Bool = true
    var horizontalPadding: CGFloat = LavaRowHeight.horizontalInset
    var verticalPadding: CGFloat = LavaRowHeight.verticalInset
    var minHeight: CGFloat = LavaRowHeight.standard
    var spacing: CGFloat = LavaSpacing.md
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            LavaSelectionAccessory(state: state, isEnabled: isEnabled)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(minHeight: minHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .saturation(isEnabled ? 1 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(state == .selected ? .isSelected : [])
    }
}
