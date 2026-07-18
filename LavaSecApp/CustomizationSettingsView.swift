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
    // Debounces the Guard-selection auth so a rapid re-tap on THIS handle is ignored while its
    // `.appSettings` auth is in flight — see `selectLavaGuardLook`. The cross-handle window (a selection
    // + toggle tap racing on the un-authenticated entry) is closed at the source by `SecurityController`'s
    // biometric coalescing, not by this per-view handle.
    @State private var guardianSelectionTask: Task<Void, Never>?

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
                    Text("Tells you when a Focus, Shortcut, or automation switches your filter while Lava is closed or in the background.".lavaLocalized)
                        .lavaQuietNoteText()

                    Toggle("Filter couldn't switch", isOn: notificationBinding(for: .filterCouldNotApply))
                        .font(.headline)
                        .tint(LavaStyle.safeGreen)
                        .lavaControlRowCard()

                    Toggle("Protection resumed", isOn: notificationBinding(for: .protectionResumed))
                        .font(.headline)
                        .tint(LavaStyle.safeGreen)
                        .lavaControlRowCard()
                    Text("Tells you when a pause ends and protection turns back on while Lava is closed or in the background.".lavaLocalized)
                        .lavaQuietNoteText()

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
            case .protectionResumed: return customization.notifiesProtectionResumed
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

    /// Applies a Lava Guard look chosen from the picker. Since the picker sheet now stays OPEN after
    /// a selection (it no longer dismisses), a rapid second tap could otherwise fire while the first
    /// `.appSettings` biometric auth is still in flight. DEBOUNCES rather than cancels — mirroring
    /// `authorizeAppSettingsThen` and `GuardView.selectLavaGuardLook`: a second tap while an auth is
    /// already in flight is ignored (guard on the tracked handle), and the task nils the handle on
    /// completion (`defer`) so a later tap works. It must NOT cancel-prior — `SecurityController`'s
    /// biometric prompt is not cancellation-aware (`evaluateBiometrics` wraps `LAContext.evaluatePolicy`
    /// in a bare `withCheckedContinuation`), so cancelling a task whose Face ID the user then completes
    /// would discard that successful auth, and the replacement tap would fan out a parallel prompt — the
    /// exact defect the settings-link auth was debounced to avoid (#401; Codex P2 on lavasec-ios#69). It
    /// deliberately does NOT route through `performAppSettingsMutation` (a bare, untracked `Task`) so a
    /// second tap can't slip past the debounce guard (Kilo review on #402).
    /// pinned: GuardLongPressPickerSourceTests.testCustomizationGuardSelectionDebouncesInFlightAuth
    private func selectLavaGuardLook(_ look: GuardianShieldStyle) {
        guard guardianSelectionTask == nil else { return }
        guardianSelectionTask = Task { @MainActor in
            defer { guardianSelectionTask = nil }
            guard await security.requireAuthentication(
                for: .appSettings,
                reason: "Edit Customization settings"
            ) else {
                return
            }
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
            LavaGuardLookPickerSheet(onSelect: onSelect)
                .environmentObject(viewModel)
                .environmentObject(customization)
                .environmentObject(security)
        }
    }
}

/// The Lava Guard catalog as a bottom sheet. Opens on the *current* Guard: its mascot, its
/// quote, and a short plain-language tip (the `LavaGuardSpotlightPanel`), then the radio-style
/// single-select list. The quiet unlock/privacy copy moved out of the top and now sits at the
/// bottom, below the catalog, so the sheet leads with the Guard rather than housekeeping.
///
/// The spotlight, the row checkmarks, and the Match App Icon toggle all read their state LIVE from the
/// `customization` environment object — there is no `selectedLook` snapshot seed — so a selection updates
/// them in place while the sheet stays open. A caller presenting this sheet must therefore supply the
/// shared `CustomizationController`, not a captured value (OCR review on lavasec-ios#69).
///
/// Internal (not file-private) so the Guard screen can present the same sheet from a long-press
/// on the Lava Guard mascot — the picker has one home, reached from Customization or the mascot.
struct LavaGuardLookPickerSheet: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var customization: CustomizationController
    // The sheet's `.appSettings`-gated actions — the unlock panel's Upgrade / Privacy & Data links
    // and the Match App Icon toggle — re-authenticate through `authorizeAppSettingsThen` before
    // taking effect, so opening the sheet from the read-only Guard tab can't bypass the lock.
    @EnvironmentObject private var security: SecurityController
    @Environment(\.dismiss) private var dismiss
    @State private var showUpgradePage = false
    @State private var showPrivacyDataPage = false
    @State private var appSettingsActionTask: Task<Void, Never>?

    let onSelect: (GuardianShieldStyle) -> Void

    var body: some View {
        NavigationStack {
            LavaSheetScaffold(spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    // The spotlight + row checkmark read the LIVE current look, not a snapshot, so
                    // selecting a Guard updates them in place while the sheet stays open.
                    LavaGuardSpotlightPanel(look: customization.lavaGuardLook)

                    LavaSectionGroup("Choose your Guard") {
                        LavaPlainCard {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(GuardianShieldStyle.allCases.enumerated()), id: \.element.id) { index, look in
                                    let availability = customization.lavaGuardAvailability(for: look)
                                    Button {
                                        guard availability.isSelectable else {
                                            return
                                        }
                                        // Selecting applies the look but keeps the sheet OPEN — the
                                        // user stays in the picker (the checkmark and spotlight track
                                        // `customization.lavaGuardLook` live) instead of bouncing back
                                        // to Customization / the Guard screen. The Close (X) is the
                                        // only dismiss.
                                        onSelect(look)
                                    } label: {
                                        LavaGuardLookOptionRow(
                                            look: look,
                                            availability: availability,
                                            isSelected: look == customization.lavaGuardLook
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

                    // The Match App Icon toggle moved off the Customization page into the picker,
                    // where the Guard it mirrors is chosen. It sits below the catalog on its own
                    // (not fused into the selection card) and above the quiet note.
                    Toggle("Match App Icon to Lava Guard", isOn: updatesAppIconBinding)
                        .font(.headline)
                        .tint(LavaStyle.safeGreen)
                        // Disabled while an `.appSettings` auth is already in flight: the setter debounces
                        // on `appSettingsActionTask` (a re-tap mid-auth is ignored), and since the sheet no
                        // longer auto-dismisses on selection a silently-inert toggle would read as broken —
                        // so surface the pending state instead of swallowing the tap (OCR review on
                        // lavasec-ios#69).
                        .disabled(appSettingsActionTask != nil)
                        .lavaControlRowCard()

                    // The quiet unlock + privacy note moved out of the top panel to the bottom,
                    // below the catalog — the sheet leads with the current Guard, not the copy.
                    if !viewModel.configuration.hasLavaSecurityPlus {
                        LavaGuardUnlockInfoPanel(
                            openUpgrade: { authorizeAppSettingsThen { showUpgradePage = true } },
                            openPrivacyData: { authorizeAppSettingsThen { showPrivacyDataPage = true } }
                        )
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

    /// The single `.appSettings` auth choke point for the sheet's gated actions: the Upgrade /
    /// Privacy & Data links (which reach `.appSettings` settings pages through an inline
    /// `navigationDestination`) and the Match App Icon toggle (an `.appSettings` preference
    /// mutation). Reaching this sheet does not itself pass that gate — the Guard mascot long-press
    /// opens it straight from the read-only Guard tab — so re-authenticate before running `action`,
    /// matching the `.appSettings` lock `RootView.openSettingsRoute` enforces on `.upgrade`/
    /// `.privacyData` and the Customization page enforces on its toggles. When the surface is
    /// already authenticated for this turn (e.g. a prior `.appSettings` mutation ran),
    /// `requireAuthentication` short-circuits and no second prompt appears; opening straight from
    /// the Guard long-press with no prior turn auth does present one, as intended.
    ///
    /// DEBOUNCES rather than cancels: a second gated tap (another link, or the toggle) while an auth
    /// is already in flight is ignored (guard on the tracked task handle), and the task nils the
    /// handle on completion so a later tap works. It must NOT cancel-prior — `SecurityController`'s
    /// biometric prompt is not cancellation-aware (`evaluateBiometrics` wraps
    /// `LAContext.evaluatePolicy` in a bare `withCheckedContinuation`), so cancelling a task whose
    /// Face ID the user then goes on to complete would discard that successful auth, and the
    /// replacement might apply nothing even though the user authenticated (Codex P2 on the 1.2.4
    /// sync). Ignoring the second tap instead lets the first auth complete and take effect, and
    /// avoids the parallel prompts the original fire-and-forget could fan out (OCR review on the
    /// 1.2.4 sync). This one handle keeps the sheet's OWN gated actions — the links and the toggle — to
    /// a single `.appSettings` prompt at a time. It does NOT cover the Guard-row *selection*, which the
    /// presenting view (`CustomizationSettingsView` / `GuardView`) debounces on its separate
    /// `guardianSelectionTask`. A simultaneous selection + toggle tap on the un-authenticated long-press
    /// entry no longer fans out two prompts: `SecurityController.evaluateBiometrics` coalesces concurrent
    /// biometric evaluations onto one (via `BiometricAuthenticationCoalescer`, mirroring its passcode
    /// single-flight), so the two handles' concurrent `.appSettings` gates share a single Face ID prompt
    /// (fan-out A; Codex/OCR review on lavasec-ios#69).
    ///
    /// `reason` is the user-facing `LAContext.evaluatePolicy` string: it defaults to "Open Settings"
    /// for the Upgrade / Privacy & Data links (which navigate to settings pages), but the Match App
    /// Icon toggle passes "Edit Customization settings" since it mutates a preference rather than
    /// opening Settings (Kilo review on lavasec-ios#69).
    private func authorizeAppSettingsThen(
        reason: String = "Open Settings",
        _ action: @escaping @MainActor () -> Void
    ) {
        guard appSettingsActionTask == nil else { return }
        appSettingsActionTask = Task { @MainActor in
            defer { appSettingsActionTask = nil }
            guard await security.requireAuthentication(for: .appSettings, reason: reason) else {
                return
            }

            action()
        }
    }

    /// Match App Icon toggle. Reads the live preference; writing goes through the shared
    /// `.appSettings` auth choke point, so the read-only Guard-tab entry can't flip it unlocked.
    private var updatesAppIconBinding: Binding<Bool> {
        Binding {
            customization.updatesAppIconWithLavaGuard
        } set: { isEnabled in
            authorizeAppSettingsThen(reason: "Edit Customization settings") { customization.setUpdatesAppIconWithLavaGuard(isEnabled) }
        }
    }
}

/// The picker sheet's header: the current Lava Guard on the left, its quote on the right, and a
/// short, plain-language tip beneath the quote. The tip unpacks the quote for a layman — the
/// sign-in Guard's quote pairs with a note that fake sites copy real login pages to steal
/// passwords — so the panel teaches a habit, not just a slogan. Everything is localized; the
/// quote reuses `settingsDescription` and the tip its paired `settingsTip`.
private struct LavaGuardSpotlightPanel: View {
    let look: GuardianShieldStyle

    var body: some View {
        LavaInfoCard(borderTint: look.dynamicIslandStatusGlyphColor) {
            HStack(alignment: .top, spacing: 16) {
                SoftShieldGuardian(
                    size: LavaGuardSpotlightMetrics.mascotSize,
                    state: .awake,
                    animates: false,
                    shieldStyle: look
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    Text(look.displayName.lavaLocalized)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(look.dynamicIslandStatusGlyphColor)

                    Text(look.settingsDescription.lavaLocalized)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(LavaStyle.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(look.settingsTip.lavaLocalized)
                        .lavaSupportingText()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

private enum LavaGuardSpotlightMetrics {
    static let mascotSize: CGFloat = 72
}

/// Moved out of the Customization screen into the picker sheet: the same unlock
/// and privacy copy, sitting below the catalog. No card/border — it reads as quiet
/// footer text on the sheet background, not a panel competing with the Guard rows.
private struct LavaGuardUnlockInfoPanel: View {
    let openUpgrade: () -> Void
    let openPrivacyData: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(.init("Keep Lava protecting you to unlock more Guards, or [**Upgrade**](lavasecurity://settings/upgrade) to unlock them all.".lavaLocalized))
                .lavaQuietNoteText()

            Text(.init("Lava Guard progress requires local logs. [**Review Privacy & Data**](lavasecurity://settings/privacy-data)".lavaLocalized))
                .lavaQuietNoteText()
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

    /// A bite-sized, layman tip that unpacks the Guard's quote (`settingsDescription`) into one
    /// concrete safety habit. Shown under the quote in the picker's spotlight panel. Catalog-only
    /// (localized at the display site via `.lavaLocalized`); keep each in sync with its quote.
    var settingsTip: String {
        switch self {
        case .original:
            "Lava quietly blocks domains known for scams and malware, so most threats never load."
        case .fireOpal:
            "A link can show one name but open another. Check where it really goes before you tap."
        case .purpleObsidian:
            "Switch on a blocklist once and Lava keeps catching those domains for you."
        case .obsidian:
            "Some fake sites copy a real login page to steal your password. Open the app or type the address yourself."
        case .cherryQuartz:
            "A real prize never needs your password or a one-time code. If it asks, it's a scam."
        case .emerald:
            "Keep Lava on while you browse and it watches for risky domains in the background."
        case .kiwiCreme:
            "Small habits help: pause before you tap, and let Lava handle the domains you should skip."
        }
    }
}
