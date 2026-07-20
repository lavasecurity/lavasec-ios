import ActivityKit
import AppIntents
import LavaSecKit
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
                LavaLiveActivityStatusGlyphView(state: context.state, fontSize: LavaIconSize.control)
            } minimal: {
                LavaLiveActivityStatusGlyphView(state: context.state, fontSize: LavaIconSize.small)
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
            // Read the app-language pin PER RENDER (every 1 s timeline tick): the widget
            // process resolves its own bundle to the SYSTEM language — it never inherits
            // the app's per-app language override — and it outlives reboots. A pre-unlock
            // render reads the locked suite as nil and falls back to ambient; the first
            // post-unlock tick reads the pin and the activity self-heals in ≤1 s without a
            // process restart (incident plan Phase 3, lavasec-infra
            // plans/2026-07-14-reboot-first-unlock-data-reset-incident-plan.md).
            let languageCode = LavaNotificationLanguage.pinnedCode(in: LavaSecAppGroup.sharedDefaults)
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
            .accessibilityLabel(Self.accessibilityLabel(for: protectionState, languageCode: languageCode))
        }
    }

    private static func accessibilityLabel(
        for protectionState: LavaActivityAttributes.ProtectionState,
        languageCode: String?
    ) -> String {
        switch protectionState {
        case .on:
            LavaCoreStrings.localized("widget.state.on", languageCode: languageCode)
        case .paused:
            LavaCoreStrings.localized("widget.state.paused", languageCode: languageCode)
        case .restarting:
            LavaCoreStrings.localized("widget.a11y.restarting", languageCode: languageCode)
        }
    }
}

private struct LavaLiveActivityStatusGlyphView: View {
    let state: LavaActivityAttributes.ContentState
    let fontSize: CGFloat

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { timeline in
            let protectionState = state.effectiveProtectionState(now: timeline.date)
            // Per-render pin read — see LavaLiveActivityCompactGuardianView for the full
            // rationale (system-language widget process; ≤1 s post-unlock self-heal).
            let languageCode = LavaNotificationLanguage.pinnedCode(in: LavaSecAppGroup.sharedDefaults)
            Image(systemName: statusSymbolName(for: protectionState))
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(state.shieldStyle.dynamicIslandStatusGlyphColor)
                .accessibilityLabel(statusAccessibilityLabel(for: protectionState, languageCode: languageCode))
        }
    }

    private func statusSymbolName(for protectionState: LavaActivityAttributes.ProtectionState) -> String {
        switch protectionState {
        case .on:
            "checkmark"
        case .paused:
            "pause.fill"
        case .restarting:
            "arrow.triangle.2.circlepath"
        }
    }

    private func statusAccessibilityLabel(
        for protectionState: LavaActivityAttributes.ProtectionState,
        languageCode: String?
    ) -> String {
        switch protectionState {
        case .on:
            LavaCoreStrings.localized("widget.status.on", languageCode: languageCode)
        case .paused:
            LavaCoreStrings.localized("widget.status.paused", languageCode: languageCode)
        case .restarting:
            LavaCoreStrings.localized("widget.status.restarting", languageCode: languageCode)
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
            // Per-render pin read — see LavaLiveActivityCompactGuardianView for the full
            // rationale (system-language widget process; ≤1 s post-unlock self-heal).
            let languageCode = LavaNotificationLanguage.pinnedCode(in: LavaSecAppGroup.sharedDefaults)
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
                // Decorative mascot: the protection state is already carried by the title
                // text below and the Dynamic Island status glyph, so keep the duplicate
                // out of VoiceOver rather than announcing an unlabeled image.
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 10) {
                    Text(expandedTitle(for: protectionState, languageCode: languageCode))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        // The title is this surface's protection-state readout; expose it as a
                        // header so VoiceOver announces the state as the heading of the activity.
                        .accessibilityAddTraits(.isHeader)

                    // Action row. The Dynamic Island is reliable for user-initiated
                    // actions (a tap wakes the app to run the intent) even though it
                    // can't keep connectivity status fresh, so it leads with actions,
                    // not status.
                    switch protectionState {
                    case .on:
                        if !state.pauseRequiresAuthentication {
                            // Pause is the primary action and takes the row; Restart
                            // recedes to a small secondary icon beside it.
                            HStack(spacing: LavaLiveActivityStyle.expandedActionButtonSpacing) {
                                pauseButton(
                                    title: pauseButtonTitle(forMinutes: state.pauseMinutes, languageCode: languageCode),
                                    accessibilityLabel: pauseButtonAccessibilityLabel(forMinutes: state.pauseMinutes, languageCode: languageCode)
                                )
                                restartIconButton(languageCode: languageCode)
                            }
                        } else {
                            // Pause is locked behind authentication, so Restart stands
                            // alone — promote it to a full labelled control.
                            restartLabeledButton(languageCode: languageCode)
                        }
                    case .paused:
                        // The only meaningful action is Resume; it fills the row.
                        resumeButton(languageCode: languageCode)
                    case .restarting:
                        // Restart is in progress — the title carries the status and no
                        // action is offered until it settles.
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .activityBackgroundTint(LavaLiveActivityStyle.lockScreenBackgroundTint)
        .activitySystemActionForegroundColor(LavaLiveActivityStyle.lavaGreen)
    }

    // The Pause button draws the DURATION ONLY: the leading pause.fill glyph already carries the
    // "pause" verb, so repeating it as a word only crowded the label. The full verb phrase overran
    // the squeezed action row (Pause shares it with the Restart icon) and truncated to "…" in the
    // longer locales — field evidence: ja "15 分間一時停止", de "Für 15 Min. pausieren",
    // es "Pausar durante 15 min". LiveActivityPausePreference.minutesRange caps the value at two
    // digits, so the duration-only "15 min"/"15分"/"15 Min." always fits.
    private func pauseButtonTitle(forMinutes minutes: Int, languageCode: String?) -> String {
        LavaCoreStrings.localizedFormat("widget.action.pauseForMinutesShort", languageCode: languageCode, minutes)
    }

    // Dropping the visible verb is a VISUAL space fix, not an accessibility one: VoiceOver still
    // hears the full "Pause for N min" phrase (below), so the glyph-only shorthand never reaches
    // assistive tech and the primary control stays explicit when spoken.
    // pinned: AccessibilityLiveActivitySourceTests.testPauseButtonCarriesLocalizedAccessibilityLabel
    private func pauseButtonAccessibilityLabel(forMinutes minutes: Int, languageCode: String?) -> String {
        LavaCoreStrings.localizedFormat("widget.action.pauseForMinutes", languageCode: languageCode, minutes)
    }

    @ViewBuilder
    private func pauseButton(title: String, accessibilityLabel: String) -> some View {
        Button(intent: PauseLavaProtectionIntent()) {
            pauseActivityActionLabel(title)
        }
        .controlSize(.regular)
        .tint(LavaLiveActivityStyle.lavaGreen)
        .buttonBorderShape(.roundedRectangle(radius: LavaLiveActivityStyle.expandedActionButtonCornerRadius))
        // Speak the full localized "Pause for N min" phrase as the button's VoiceOver label so the
        // primary control reads clearly — the decorative pause glyph and the duration-only visible
        // title are not what assistive tech announces.
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func resumeButton(languageCode: String?) -> some View {
        Button(intent: ResumeLavaProtectionIntent()) {
            liveActivityActionLabel(LavaCoreStrings.localized("widget.action.resume", languageCode: languageCode))
        }
        .controlSize(.regular)
        .tint(LavaLiveActivityStyle.lavaGreen)
        .buttonBorderShape(.roundedRectangle(radius: LavaLiveActivityStyle.expandedActionButtonCornerRadius))
    }

    // Secondary recovery control shown beside Pause: a small grey icon so it never
    // competes with the primary green Pause. Reuses the existing reconnect command
    // (a full tunnel stop→start); a tap wakes the app to run it even from a locked
    // state, which is why the Dynamic Island can offer it reliably.
    @ViewBuilder
    private func restartIconButton(languageCode: String?) -> some View {
        Button(intent: ReconnectLavaProtectionIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.system(
                    size: LavaLiveActivityStyle.expandedActionSymbolFontSize,
                    weight: .semibold,
                    design: .rounded
                ))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .accessibilityLabel(LavaCoreStrings.localized("widget.action.restart", languageCode: languageCode))
        }
        .controlSize(.small)
        .tint(LavaLiveActivityStyle.lavaSecondaryGray)
        .buttonBorderShape(.roundedRectangle(radius: LavaLiveActivityStyle.expandedActionButtonCornerRadius))
    }

    // When Pause is locked behind authentication, Restart is the only action, so it
    // gets a full labelled button — still grey/secondary so it reads as recovery
    // rather than a primary control.
    @ViewBuilder
    private func restartLabeledButton(languageCode: String?) -> some View {
        Button(intent: ReconnectLavaProtectionIntent()) {
            restartActivityActionLabel(LavaCoreStrings.localized("widget.action.restart", languageCode: languageCode))
        }
        .controlSize(.regular)
        .tint(LavaLiveActivityStyle.lavaSecondaryGray)
        .buttonBorderShape(.roundedRectangle(radius: LavaLiveActivityStyle.expandedActionButtonCornerRadius))
    }

    private func restartActivityActionLabel(_ title: String) -> some View {
        HStack(spacing: LavaLiveActivityStyle.expandedActionLabelSpacing) {
            Image(systemName: "arrow.clockwise")
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
        .frame(maxWidth: .infinity)
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
        .frame(maxWidth: .infinity)
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
            .frame(maxWidth: .infinity)
    }

    private func expandedTitle(
        for protectionState: LavaActivityAttributes.ProtectionState,
        languageCode: String?
    ) -> String {
        switch protectionState {
        case .on:
            LavaCoreStrings.localized("widget.state.on", languageCode: languageCode)
        case .paused:
            LavaCoreStrings.localized("widget.state.paused", languageCode: languageCode)
        case .restarting:
            LavaCoreStrings.localized("widget.state.restartingTitle", languageCode: languageCode)
        }
    }
}

private enum LavaLiveActivityStyle {
    static let expandedMascotContentSpacing: CGFloat = 12
    // Gap between the primary Pause button and the secondary Restart icon when both
    // are shown in the On state.
    static let expandedActionButtonSpacing: CGFloat = 12

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

    // Muted neutral tint for the secondary Restart control so it reads as recovery,
    // not a primary action, against the prominent green Pause/Resume.
    static let lavaSecondaryGray = Color(
        uiColor: UIColor { traits in
            let white: CGFloat = traits.userInterfaceStyle == .dark ? 0.62 : 0.46
            return UIColor(white: white, alpha: 1)
        }
    )
}

private extension LavaActivityAttributes.ContentState {
    // Both transient states carry their self-resolve deadline in `resumeDate`, and
    // the expanded views advance on a 1-second TimelineView, so the Dynamic Island
    // resolves them on its OWN clock without a fresh push from the app:
    //  - paused → on at the resume time,
    //  - restarting → on at the restart deadline (so a restart killed mid-flight,
    //    before the app could restore state, can't strand the island on
    //    "Restarting…"; on-demand brings the tunnel back, and the next app wake
    //    reconciles the true state).
    func effectiveProtectionState(now: Date) -> LavaActivityAttributes.ProtectionState {
        switch protectionState {
        case .paused, .restarting:
            guard let resumeDate, resumeDate <= now else {
                return protectionState
            }
            return .on
        case .on:
            return .on
        }
    }
}
