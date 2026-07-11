import SwiftUI
import LavaSecKit
import UIKit

private struct SettingsSystemSettingsRow: View {
    let title: String

    var body: some View {
        Button {
            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
                return
            }

            UIApplication.shared.open(settingsURL)
        } label: {
            HStack(spacing: 12) {
                Text(title.lavaLocalized)
                    .lavaCardTitleText()
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .lavaControlRowCard()
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

struct CustomizationSettingsView: View {
    // The customization-preference state + setters live on `customization` since the
    // Phase D5 peel. The hub stays observed too — deliberately, even though no property
    // below reads it textually: the Guard rows' availability inputs (Plus flag, unlock
    // ledger, LavaGuard progress, keep-progress flag) are HUB state the controller reads
    // through its bridge per call, so observing the hub is what re-renders this page
    // when an unlock or purchase lands mid-view — exactly as pre-peel.
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var customization: CustomizationController
    @EnvironmentObject private var security: SecurityController
    // The app's current system Dynamic Type size — reflects the real system setting while "Match
    // System" is on (no override applied), so it seeds the slider on the first opt-out.
    @Environment(\.dynamicTypeSize) private var systemDynamicTypeSize

    var body: some View {
        SettingsSubpageContent(
            title: "Customization",
            tier: .calm,
            intro: LavaInfoPanel(
                title: "Make Lava yours",
                description: "Pick how Lava looks and feels. None of these change how it protects you, so try anything.",
                systemImage: "slider.horizontal.3"
            )
        ) {
            LavaSectionGroup("Lava Guard") {
                LavaGuardLookPickerRow(
                    look: customization.lavaGuardLook,
                    availability: customization.lavaGuardAvailability(for: customization.lavaGuardLook),
                    onSelect: selectLavaGuardLook
                )
                .lavaTier(.celebratory)

                Toggle("Match App Icon to Lava Guard", isOn: updatesAppIconBinding)
                    .font(.headline)
                    .tint(LavaStyle.safeGreen)
                    .lavaControlRowCard()
            }

            LavaSectionGroup("Appearance") {
                Picker("Appearance", selection: appearanceBinding) {
                    ForEach(LavaAppearancePreference.allCases) { preference in
                        Text(preference.displayName.lavaLocalized)
                            .tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                .tint(LavaStyle.safeGreen)
                .lavaControlRowCard()
            }

            LavaSectionGroup("Text Size") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Match System", isOn: textSizeMatchesSystemBinding)
                        .font(.headline)
                        .tint(LavaStyle.safeGreen)
                        .lavaControlRowCard()

                    HStack(spacing: 12) {
                        Image(systemName: "textformat.size.smaller")
                            .foregroundStyle(LavaStyle.secondaryText)
                            .accessibilityHidden(true)
                        Slider(
                            value: textSizeSliderBinding,
                            in: 0...Double(LavaTextSize.allCases.count - 1),
                            step: 1
                        )
                        .tint(LavaStyle.safeGreen)
                        .accessibilityLabel("Text Size")
                        .accessibilityValue(customization.textSize.displayName.lavaLocalized)
                        Image(systemName: "textformat.size.larger")
                            .foregroundStyle(LavaStyle.secondaryText)
                            .accessibilityHidden(true)
                    }
                    .lavaControlRowCard()
                    // Grey out and disable the slider while "Match System" drives the size, so the
                    // control reads as inactive (a Differentiate-Without-Color-friendly state) and
                    // VoiceOver skips a knob that would do nothing.
                    .disabled(customization.textSizeMatchesSystem)
                    .opacity(customization.textSizeMatchesSystem ? 0.4 : 1)
                }
            }

            LavaSectionGroup("Notifications") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Filter changes", isOn: notificationBinding(for: .filterChanged))
                        .font(.headline)
                        .tint(LavaStyle.safeGreen)
                        .lavaControlRowCard()
                    Text("Tells you when a Focus switches your filter while Lava is closed or in the background.".lavaLocalized)
                        .lavaQuietNoteText()

                    Toggle("Filter couldn't switch", isOn: notificationBinding(for: .filterCouldNotApply))
                        .font(.headline)
                        .tint(LavaStyle.safeGreen)
                        .lavaControlRowCard()

                    Toggle("Connection updates", isOn: notificationBinding(for: .connectivity))
                        .font(.headline)
                        .tint(LavaStyle.safeGreen)
                        .lavaControlRowCard()
                    Text("Alerts when protection needs your help to reconnect on a network.".lavaLocalized)
                        .lavaQuietNoteText()
                }
            }

            if customization.canOfferLiveActivities {
                LavaSectionGroup("Live Activities") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Use Live Activities", isOn: usesLiveActivitiesBinding)
                            .font(.headline)
                            .tint(LavaStyle.safeGreen)
                            .lavaControlRowCard()

                        Text("Shows Lava status on the Lock Screen and Dynamic Island when available.".lavaLocalized)
                            .lavaQuietNoteText()

                        if customization.usesLiveActivities {
                            Stepper(
                                value: liveActivityPauseMinutesBinding,
                                in: LiveActivityPausePreference.minutesRange
                            ) {
                                Text(customization.liveActivityPauseLengthLabel)
                                    .font(.headline)
                            }
                            .tint(LavaStyle.safeGreen)
                            .lavaControlRowCard()
                        }
                    }
                }
            }

            LavaSectionGroup("Haptics") {
                Toggle("App Haptics", isOn: lavaHapticsBinding)
                    .font(.headline)
                    .tint(LavaStyle.safeGreen)
                    .lavaControlRowCard()
            }

            LavaSectionGroup("Language") {
                SettingsSystemSettingsRow(title: "Change in iOS Settings")
            }
        }
    }

    private var appearanceBinding: Binding<LavaAppearancePreference> {
        Binding {
            customization.appearancePreference
        } set: { preference in
            performAppSettingsMutation(reason: "Edit Customization settings") {
                customization.setAppearancePreference(preference)
            }
        }
    }

    private var textSizeMatchesSystemBinding: Binding<Bool> {
        Binding {
            customization.textSizeMatchesSystem
        } set: { matchesSystem in
            performAppSettingsMutation(reason: "Edit Customization settings") {
                customization.setTextSizeMatchesSystem(
                    matchesSystem,
                    seedingFrom: LavaTextSize.matching(systemDynamicTypeSize)
                )
            }
        }
    }

    private var textSizeSliderBinding: Binding<Double> {
        Binding {
            Double(LavaTextSize.allCases.firstIndex(of: customization.textSize) ?? 0)
        } set: { newValue in
            let index = min(max(Int(newValue.rounded()), 0), LavaTextSize.allCases.count - 1)
            let size = LavaTextSize.allCases[index]
            guard size != customization.textSize else {
                return
            }
            performAppSettingsMutation(reason: "Edit Customization settings") {
                customization.setTextSize(size)
            }
        }
    }

    private var usesLiveActivitiesBinding: Binding<Bool> {
        Binding {
            customization.usesLiveActivities
        } set: { isEnabled in
            performAppSettingsMutation(reason: "Edit Customization settings") {
                customization.setUsesLiveActivities(isEnabled)
            }
        }
    }

    private var liveActivityPauseMinutesBinding: Binding<Int> {
        Binding {
            customization.liveActivityPauseMinutes
        } set: { minutes in
            performAppSettingsMutation(reason: "Edit Customization settings") {
                customization.setLiveActivityPauseMinutes(minutes)
            }
        }
    }

    private var updatesAppIconBinding: Binding<Bool> {
        Binding {
            customization.updatesAppIconWithLavaGuard
        } set: { isEnabled in
            performAppSettingsMutation(reason: "Edit Customization settings") {
                customization.setUpdatesAppIconWithLavaGuard(isEnabled)
            }
        }
    }

    private var lavaHapticsBinding: Binding<Bool> {
        Binding {
            customization.usesLavaHaptics
        } set: { isEnabled in
            performAppSettingsMutation(reason: "Edit Customization settings") {
                customization.setUsesLavaHaptics(isEnabled)
            }
        }
    }

    private func notificationBinding(for category: LavaNotificationCategory) -> Binding<Bool> {
        Binding {
            switch category {
            case .filterChanged: return customization.notifiesFilterChanges
            case .filterCouldNotApply: return customization.notifiesFilterCouldNotApply
            case .connectivity: return customization.notifiesConnectivity
            }
        } set: { isEnabled in
            performAppSettingsMutation(reason: "Edit Customization settings") {
                customization.setNotificationCategoryEnabled(category, isEnabled)
            }
        }
    }

    private func performAppSettingsMutation(reason: String, action: @escaping @MainActor () -> Void) {
        Task {
            guard await security.requireAuthentication(for: .appSettings, reason: reason) else {
                return
            }

            action()
        }
    }

    private func selectLavaGuardLook(_ look: GuardianShieldStyle) {
        performAppSettingsMutation(reason: "Edit Customization settings") {
            customization.setLavaGuardLook(look)
        }
    }
}

/// The current Guard is a single tappable row that opens the catalog as a bottom
/// sheet (radio-style single select, mirroring the Select Blocklists scaffold)
/// rather than an inline disclosure that pushed the rest of the screen around.
private struct LavaGuardLookPickerRow: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var customization: CustomizationController
    @EnvironmentObject private var security: SecurityController
    @State private var isPresentingPicker = false

    let look: GuardianShieldStyle
    let availability: LavaGuardAvailability
    let onSelect: (GuardianShieldStyle) -> Void

    var body: some View {
        LavaPlainCard {
            Button {
                isPresentingPicker = true
            } label: {
                HStack(spacing: 12) {
                    LavaGuardLookContent(look: look, availability: availability)
                        .layoutPriority(1)

                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LavaStyle.secondaryText)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Lava Guard look".lavaLocalized)
            .accessibilityValue(availability.title(for: look).lavaLocalized)
            .accessibilityHint("Opens the Lava Guard picker".lavaLocalized)
        }
        .sheet(isPresented: $isPresentingPicker) {
            LavaGuardLookPickerSheet(selectedLook: look, onSelect: onSelect)
                .environmentObject(viewModel)
                .environmentObject(customization)
                .environmentObject(security)
        }
    }
}

/// The Lava Guard catalog as a bottom sheet: an info panel up top (when more
/// Guards are still locked) followed by the radio-style single-select list.
private struct LavaGuardLookPickerSheet: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var customization: CustomizationController
    @Environment(\.dismiss) private var dismiss
    @State private var showUpgradePage = false
    @State private var showPrivacyDataPage = false

    let selectedLook: GuardianShieldStyle
    let onSelect: (GuardianShieldStyle) -> Void

    var body: some View {
        NavigationStack {
            LavaSheetScaffold(spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    if !viewModel.configuration.hasLavaSecurityPlus {
                        LavaGuardUnlockInfoPanel(
                            openUpgrade: { showUpgradePage = true },
                            openPrivacyData: { showPrivacyDataPage = true }
                        )
                    }

                    LavaSectionGroup("Choose your Guard") {
                        LavaPlainCard {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(GuardianShieldStyle.allCases.enumerated()), id: \.element.id) { index, look in
                                    let availability = customization.lavaGuardAvailability(for: look)
                                    Button {
                                        guard availability.isSelectable else {
                                            return
                                        }
                                        onSelect(look)
                                        dismiss()
                                    } label: {
                                        LavaGuardLookOptionRow(
                                            look: look,
                                            availability: availability,
                                            isSelected: look == selectedLook
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!availability.isSelectable)

                                    if index + 1 < GuardianShieldStyle.allCases.count {
                                        Divider()
                                            .padding(.leading, LavaGuardLookRowMetrics.mascotFrameSize + 12)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Lava Guard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(
                        systemName: "xmark",
                        accessibilityLabel: "Close",
                        role: .cancel,
                        action: dismiss.callAsFunction
                    )
                }
            }
            .navigationDestination(isPresented: $showUpgradePage) {
                SettingsRouteDestinationView(route: .upgrade)
            }
            .navigationDestination(isPresented: $showPrivacyDataPage) {
                SettingsRouteDestinationView(route: .privacyData)
            }
        }
    }
}

/// Moved out of the Customization screen into the picker sheet: the same unlock
/// and privacy copy, now presented as an info panel above the catalog.
private struct LavaGuardUnlockInfoPanel: View {
    let openUpgrade: () -> Void
    let openPrivacyData: () -> Void

    var body: some View {
        LavaInfoCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(.init("Keep Lava protecting you to unlock more Guards, or [**Upgrade**](lavasecurity://settings/upgrade) to unlock them all.".lavaLocalized))
                    .lavaSupportingText()

                Text(.init("Lava Guard progress requires local logs. [**Review Privacy & Data**](lavasecurity://settings/privacy-data)".lavaLocalized))
                    .lavaSupportingText()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tint(LavaStyle.safeGreen)
            .environment(\.openURL, OpenURLAction { url in
                if url == URL(string: "lavasecurity://settings/upgrade") {
                    openUpgrade()
                    return .handled
                }

                if url == URL(string: "lavasecurity://settings/privacy-data") {
                    openPrivacyData()
                    return .handled
                }

                return .systemAction
            })
        }
    }
}

private enum LavaGuardLookRowMetrics {
    static let mascotSize: CGFloat = 48
    static let mascotFrameSize: CGFloat = 52
    static let minRowHeight: CGFloat = 64
    /// Proportion of the masked-icon frame used by the "?" placeholder glyph
    /// (the unknown/locked Guard look). Proportional, so it scales with the frame.
    static let unknownGlyphRatio: CGFloat = 0.44
}

private struct LavaGuardLookContent: View {
    let look: GuardianShieldStyle
    let availability: LavaGuardAvailability
    let showsDescription: Bool

    init(
        look: GuardianShieldStyle,
        availability: LavaGuardAvailability,
        showsDescription: Bool = true
    ) {
        self.look = look
        self.availability = availability
        self.showsDescription = showsDescription
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: LavaGuardLookRowMetrics.mascotFrameSize, height: LavaGuardLookRowMetrics.mascotFrameSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(availability.title(for: look).lavaLocalized)
                    .font(.headline)
                    .foregroundStyle(availability.titleColor(for: look))
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showsDescription, let subtitle = availability.subtitle(for: look) {
                    Text(subtitle.lavaLocalized)
                        .font(.subheadline)
                        .foregroundStyle(LavaStyle.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .minimumScaleFactor(0.82)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .frame(minHeight: LavaGuardLookRowMetrics.minRowHeight)
    }

    @ViewBuilder
    private var icon: some View {
        if availability.isRevealed {
            SoftShieldGuardian(
                size: LavaGuardLookRowMetrics.mascotSize,
                state: .awake,
                animates: false,
                shieldStyle: look
            )
        } else {
            MaskedLavaGuardIcon(size: LavaGuardLookRowMetrics.mascotSize)
        }
    }
}

private struct MaskedLavaGuardIcon: View {
    let size: CGFloat

    var body: some View {
        let contourSize = size * 1.12

        ZStack {
            LavaGuardianShieldShape()
                .stroke(
                    LavaStyle.secondaryText,
                    style: StrokeStyle(
                        lineWidth: max(1.8, size * 0.045),
                        lineCap: .round,
                        lineJoin: .round,
                        dash: [2, 4]
                    )
                )
                .frame(width: contourSize, height: contourSize)

            Text("?")
                .font(.system(size: size * LavaGuardLookRowMetrics.unknownGlyphRatio, weight: .bold, design: .rounded))
                .foregroundStyle(LavaStyle.secondaryText)
        }
        .frame(width: LavaGuardLookRowMetrics.mascotFrameSize, height: LavaGuardLookRowMetrics.mascotFrameSize)
    }
}

private struct LavaGuardLookOptionRow: View {
    let look: GuardianShieldStyle
    let availability: LavaGuardAvailability
    let isSelected: Bool

    var body: some View {
        // The card already insets its content by 16, so the row carries no padding
        // of its own — it just swaps the bespoke trailing radio for the shared
        // trailing checkmark (a lock for gated Guards) via LavaSelectableRow.
        LavaSelectableRow(
            state: selectionState,
            isEnabled: availability.isSelectable,
            horizontalPadding: 0,
            verticalPadding: 0,
            minHeight: LavaGuardLookRowMetrics.minRowHeight
        ) {
            LavaGuardLookContent(
                look: look,
                availability: availability,
                showsDescription: !availability.isRevealed
            )
        }
    }

    private var selectionState: LavaRowSelectionState {
        guard availability.isSelectable else {
            return .locked
        }

        return isSelected ? .selected : .unselected
    }
}

private extension LavaGuardAvailability {
    func title(for look: GuardianShieldStyle) -> String {
        guard !isRevealed else {
            return look.displayName
        }

        if let progress {
            return "Use Lava %d days".lavaLocalizedFormat(progress.requiredUsageDays)
        }

        return "Keep using Lava"
    }

    func subtitle(for look: GuardianShieldStyle) -> String? {
        guard !isRevealed else {
            return look.settingsDescription
        }

        guard isProgressEnabled else {
            return "Progress is off in Privacy & Data"
        }

        guard let progress else {
            return "Keep Lava protecting you to unlock this Guard."
        }

        guard showsProgressDetail else {
            return nil
        }

        let currentDays = min(progress.currentUsageDays, progress.requiredUsageDays)
        return "Currently at: %d days".lavaLocalizedFormat(currentDays)
    }

    func titleColor(for look: GuardianShieldStyle) -> Color {
        isRevealed ? look.dynamicIslandStatusGlyphColor : LavaStyle.ink
    }
}

private extension GuardianShieldStyle {
    var settingsDescription: String {
        switch self {
        case .original:
            "A Lava a day keeps bad domains away."
        case .fireOpal:
            "Always check the link first."
        case .purpleObsidian:
            "Block it once. Browse in peace."
        case .obsidian:
            "Sign in where you meant to sign in."
        case .cherryQuartz:
            "Giveaways should not ask for secrets."
        case .emerald:
            "Make me your web-surfing buddy!"
        case .kiwiCreme:
            "Hey I'm no rock but I take security paw-sonally. U know what I mean?"
        }
    }
}
