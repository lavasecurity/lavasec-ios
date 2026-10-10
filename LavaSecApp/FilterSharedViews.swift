import SwiftUI
import LavaSecKit

struct LavaPlusUpgradeSheet: View {
    var context: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                #if LAVA_REACT_NATIVE
                if let context, LavaAppPlusContent.makeRoot != nil {
                    LavaAppPlusContent(context: context)
                } else {
                    LavaPlusUpgradeDestination()
                }
                #else
                LavaPlusUpgradeDestination()
                #endif
            }
            .lavaFullSheetHeader("Lava Plus", close: dismiss.callAsFunction)
        }
    }
}

private enum FilterActionLabelMetrics {
    static let iconFrameSize: CGFloat = 16
    static let iconPointSize: CGFloat = LavaIconSize.inline
    static let iconTextSpacing: CGFloat = 7
}

struct FilterActionLabel: View {
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
                .lavaRowTitleText()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}
