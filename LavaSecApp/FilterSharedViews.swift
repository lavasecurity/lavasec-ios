import SwiftUI
import LavaSecKit

struct LavaPlusUpgradeSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LavaPlusUpgradeDestination()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close", role: .close, action: dismiss.callAsFunction)
                    }
                }
        }
    }
}

struct FilterAddButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FilterActionLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(LavaPanelActionButtonStyle())
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
        }
        .frame(maxWidth: .infinity)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
    }
}
