import ActivityKit
import AppIntents
import LavaSecCore
import SwiftUI
import UIKit
import WidgetKit

@main
struct LavaSecWidgetBundle: WidgetBundle {
    var body: some Widget {
        LavaProtectionLiveActivityWidget()
    }
}

struct LavaProtectionLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LavaActivityAttributes.self) { context in
            LavaLiveActivityLockScreenView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    LavaLiveActivityExpandedView(state: context.state)
                }
            } compactLeading: {
                LavaLiveActivityCompactGuardianView(state: context.state)
            } compactTrailing: {
                LavaLiveActivityStatusGlyphView(state: context.state, fontSize: 17)
            } minimal: {
                LavaLiveActivityStatusGlyphView(state: context.state, fontSize: 16)
            }
            .keylineTint(context.state.shieldStyle.dynamicIslandStatusGlyphColor.opacity(0.55))
        }
    }

}

private struct LavaLiveActivityCompactGuardianView: View {
    let state: LavaActivityAttributes.ContentState

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { timeline in
            let protectionState = state.effectiveProtectionState(now: timeline.date)
            SoftShieldGuardian(
                size: 22,
                state: protectionState.guardianState,
                animates: false,
                minimumFeatureScale: 0.42,
                maskExpressionWhenPrivacyRedacted: true,
                keepsShieldVisibleWhenRedacted: true,
                shieldStyle: state.shieldStyle
            )
            .frame(width: 24, height: 24, alignment: .center)
            // The compact trailing glyph is labeled for VoiceOver; the mascot was
            // not, leaving the compactLeading element unlabeled.
            .accessibilityLabel(Self.accessibilityLabel(for: protectionState))
        }
    }

    private static func accessibilityLabel(for protectionState: LavaActivityAttributes.ProtectionState) -> String {
        switch protectionState {
        case .on:
            "Lava Security is on"
        case .paused:
            "Lava Security is paused"
        case .reconnecting:
            "Lava Security is reconnecting"
        case .needsReconnect:
            "Lava Security needs to reconnect"
        case .networkUnavailable:
            "Lava Security is waiting for the network"
        }
    }
}

private struct LavaLiveActivityStatusGlyphView: View {
    let state: LavaActivityAttributes.ContentState
    let fontSize: CGFloat

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { timeline in
            let protectionState = state.effectiveProtectionState(now: timeline.date)
            Image(systemName: statusSymbolName(for: protectionState))
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(state.shieldStyle.dynamicIslandStatusGlyphColor)
                .accessibilityLabel(statusAccessibilityLabel(for: protectionState))
        }
    }

    private func statusSymbolName(for protectionState: LavaActivityAttributes.ProtectionState) -> String {
        switch protectionState {
        case .on:
            "checkmark"
        case .paused:
            "pause.fill"
        case .reconnecting:
            "arrow.triangle.2.circlepath"
        case .needsReconnect:
            "exclamationmark.triangle.fill"
        case .networkUnavailable:
            "wifi.slash"
        }
    }

    private func statusAccessibilityLabel(for protectionState: LavaActivityAttributes.ProtectionState) -> String {
        switch protectionState {
        case .on:
            "On"
        case .paused:
            "Paused"
        case .reconnecting:
            "Reconnecting"
        case .needsReconnect:
            "Reconnection needed"
        case .networkUnavailable:
            "Waiting for network"
        }
    }
}

private struct LavaLiveActivityLockScreenView: View {
    let state: LavaActivityAttributes.ContentState

    var body: some View {
        LavaLiveActivityExpandedView(state: state)
            .padding(16)
    }
}

private struct LavaLiveActivityExpandedView: View {
    let state: LavaActivityAttributes.ContentState

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { timeline in
            let protectionState = state.effectiveProtectionState(now: timeline.date)
            HStack(alignment: .center, spacing: LavaLiveActivityStyle.expandedMascotContentSpacing) {
                SoftShieldGuardian(
                    size: 76,
                    state: protectionState.guardianState,
                    animates: false,
                    maskExpressionWhenPrivacyRedacted: true,
                    keepsShieldVisibleWhenRedacted: true,
                    shieldStyle: state.shieldStyle
                )
                .frame(width: 82, height: 86)

                VStack(alignment: .leading, spacing: 10) {
                    Text(expandedTitle(for: protectionState))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    switch protectionState {
                    case .on:
                        if !state.pauseRequiresAuthentication {
                            HStack(spacing: LavaLiveActivityStyle.expandedActionButtonSpacing) {
                                pauseFiveMinutesButton("5 min")
                                pauseTenMinutesButton("10 min")
                            }
                        }
                    case .paused:
                        Button(intent: ResumeLavaProtectionIntent()) {
                            liveActivityActionLabel("Resume")
                        }
                        .controlSize(.regular)
                        .tint(LavaLiveActivityStyle.lavaGreen)
                        .buttonBorderShape(.roundedRectangle(radius: LavaLiveActivityStyle.expandedActionButtonCornerRadius))
                    case .needsReconnect:
                        Button(intent: ReconnectLavaProtectionIntent()) {
                            liveActivityActionLabel("Reconnect")
                        }
                        .controlSize(.regular)
                        .tint(LavaLiveActivityStyle.lavaGreen)
                        .buttonBorderShape(.roundedRectangle(radius: LavaLiveActivityStyle.expandedActionButtonCornerRadius))
                    case .reconnecting, .networkUnavailable:
                        // Both recover on their own (DNS re-establishing / network
                        // returning); offering Pause or Reconnect here would be a
                        // no-op, so the state stays purely informational.
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .activityBackgroundTint(LavaLiveActivityStyle.lockScreenBackgroundTint)
        .activitySystemActionForegroundColor(LavaLiveActivityStyle.lavaGreen)
    }

    @ViewBuilder
    private func pauseFiveMinutesButton(_ title: String) -> some View {
        Button(intent: PauseLavaProtectionFiveMinutesIntent()) {
            pauseActivityActionLabel(title)
        }
        .controlSize(.regular)
        .tint(LavaLiveActivityStyle.lavaGreen)
        .buttonBorderShape(.roundedRectangle(radius: LavaLiveActivityStyle.expandedActionButtonCornerRadius))
    }

    @ViewBuilder
    private func pauseTenMinutesButton(_ title: String) -> some View {
        Button(intent: PauseLavaProtectionTenMinutesIntent()) {
            pauseActivityActionLabel(title)
        }
        .controlSize(.regular)
        .tint(LavaLiveActivityStyle.lavaGreen)
        .buttonBorderShape(.roundedRectangle(radius: LavaLiveActivityStyle.expandedActionButtonCornerRadius))
    }

    private func pauseActivityActionLabel(_ title: String) -> some View {
        HStack(spacing: LavaLiveActivityStyle.expandedActionLabelSpacing) {
            Image(systemName: "pause.fill")
                .font(.system(
                    size: LavaLiveActivityStyle.expandedActionSymbolFontSize,
                    weight: .semibold,
                    design: .rounded
                ))

            Text(title)
                .font(.system(
                    size: LavaLiveActivityStyle.expandedActionFontSize,
                    weight: .semibold,
                    design: .rounded
                ))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: LavaLiveActivityStyle.expandedActionButtonWidth)
    }

    private func liveActivityActionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(
                size: LavaLiveActivityStyle.expandedActionFontSize,
                weight: .semibold,
                design: .rounded
            ))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: LavaLiveActivityStyle.expandedResumeButtonWidth)
    }

    private func expandedTitle(for protectionState: LavaActivityAttributes.ProtectionState) -> String {
        switch protectionState {
        case .on:
            "Lava Security is On"
        case .paused:
            "Lava Security is Paused"
        case .reconnecting:
            "Lava Security is reconnecting"
        case .needsReconnect:
            "Lava Security needs to reconnect"
        case .networkUnavailable:
            "Waiting for network"
        }
    }
}

private enum LavaLiveActivityStyle {
    static let expandedMascotContentSpacing: CGFloat = 12
    static let expandedActionButtonSpacing: CGFloat = 12
    static let expandedActionButtonWidth: CGFloat = 82
    static var expandedResumeButtonWidth: CGFloat {
        expandedActionButtonWidth * 2 + expandedActionButtonSpacing
    }

    static let expandedActionFontSize: CGFloat = 16
    static let expandedActionSymbolFontSize: CGFloat = 15
    static let expandedActionLabelSpacing: CGFloat = 8
    static let expandedActionButtonCornerRadius: CGFloat = 14

    static let lockScreenBackgroundTint = Color(
        uiColor: UIColor { traits in
            let alpha: CGFloat = traits.userInterfaceStyle == .dark ? 0.34 : 0.52
            return UIColor.systemBackground.withAlphaComponent(alpha)
        }
    )

    static let lavaGreen = Color(
        uiColor: UIColor { traits in
            let components: (red: CGFloat, green: CGFloat, blue: CGFloat) = traits.userInterfaceStyle == .dark
                ? (0.45, 0.86, 0.63)
                : (0.12, 0.40, 0.28)

            return UIColor(
                red: components.red,
                green: components.green,
                blue: components.blue,
                alpha: 1
            )
        }
    )
}

private extension LavaActivityAttributes.ContentState {
    func effectiveProtectionState(now: Date) -> LavaActivityAttributes.ProtectionState {
        guard protectionState == .paused,
              let resumeDate,
              resumeDate <= now
        else {
            return protectionState
        }

        return .on
    }
}
