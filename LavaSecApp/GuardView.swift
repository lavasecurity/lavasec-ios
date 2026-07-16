import SwiftUI
import LavaSecKit
import LavaSecPresentation
import UIKit

private enum ProtectionStatusMetrics {
    static let primaryActionMaxWidth: CGFloat = 300
    static let primaryActionHeight: CGFloat = 56
}

struct GuardView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    // The diagnostics scope (Phase D4 peel): the refresh loop below drives its store read.
    @EnvironmentObject private var reports: DiagnosticsController
    @Binding var navigationPath: [GuardDestination]
    let scrollToTopTrigger: Int
    let refreshesProtectionState: Bool

    init(
        navigationPath: Binding<[GuardDestination]> = .constant([]),
        scrollToTopTrigger: Int = 0,
        refreshesProtectionState: Bool = true
    ) {
        self._navigationPath = navigationPath
        self.scrollToTopTrigger = scrollToTopTrigger
        self.refreshesProtectionState = refreshesProtectionState
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            LavaPrimaryTabScreenContent(
                title: "Guard",
                scrollToTopTrigger: scrollToTopTrigger
            ) {
                ProtectionStatusPanel()
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            } content: {
                GuardExploreSection()
            }
            .navigationDestination(for: GuardDestination.self) { destination in
                GuardDestinationView(destination: destination)
            }
            .task {
                guard refreshesProtectionState else {
                    return
                }

                await refreshGuardProtectionState()

                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else {
                        return
                    }

                    await refreshGuardProtectionState()
                }
            }
        }
    }

    private func refreshGuardProtectionState() async {
        reports.refreshDiagnostics()
        await viewModel.refreshProtectionStatus()
        await viewModel.sampleTunnelHealth()
    }
}

struct ProtectionStatusPanel: View {
    @EnvironmentObject private var viewModel: AppViewModel
    // The mascot look lives on the customization controller (Phase D5 peel).
    @EnvironmentObject private var customization: CustomizationController
    // A long-press on the mascot changes the Lava Guard look — an auth-gated Customization
    // mutation — so this panel needs the same security gate the Customization page uses.
    @EnvironmentObject private var security: SecurityController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var guardianOverrideState: GuardianMascotState?
    @State private var isGuardianTapAnimationRunning = false
    @State private var guardianTapAnimationTask: Task<Void, Never>?
    @State private var isPresentingLavaGuardPicker = false
    @State private var guardianLongPressRampTask: Task<Void, Never>?
    @State private var guardianRevealTask: Task<Void, Never>?
    @State private var guardianSelectionTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                SoftShieldGuardian(
                    size: 96,
                    state: guardianOverrideState ?? guardianState,
                    shieldStyle: customization.lavaGuardLook
                )
                .contentShape(Rectangle())
                .accessibilityHidden(true)
                .onTapGesture { playGuardianTapGratitude() }
                // Long-press (2s) opens the Lava Guard picker — the same sheet the Customization
                // page presents. The hold plays an escalating haptic "charge"
                // (GuardianLongPressHaptics): its floor is the very same light impact as the tap
                // above, and it balloons up into a crescendo at the reveal.
                .onLongPressGesture(minimumDuration: GuardianLongPressHaptics.holdDuration) {
                    presentLavaGuardPickerFromLongPress()
                } onPressingChanged: { isPressing in
                    if isPressing {
                        startGuardianLongPressRamp()
                    } else {
                        stopGuardianLongPressRamp()
                    }
                }
                .onDisappear {
                    guardianTapAnimationTask?.cancel()
                    guardianTapAnimationTask = nil
                    isGuardianTapAnimationRunning = false
                    guardianOverrideState = nil
                    stopGuardianLongPressRamp()
                    // Cancel an in-flight reveal/auth OR look-selection/auth task on a GENUINE
                    // navigate-away so a prompt still resolving can't fire the reveal haptic, flip the
                    // picker flag, or apply a look on a dismissed view (Kilo + OCR review on the 1.2.4
                    // sync) — but NOT when this onDisappear IS the passcode auth cover: `.appSettings`
                    // auth can present SecurityPasscodeAuthenticationView as a `fullScreenCover`
                    // (RootView), which fires onDisappear here while a task is awaiting that very
                    // passcode; cancelling then skips the reveal/selection after a successful passcode and
                    // locks passcode / biometric-fallback users out of the long-press picker (Codex P2 on
                    // the 1.2.4 sync). onDisappear can't tell the two apart, so gate on the live passcode
                    // request — the same fullScreenCover/onDisappear conflation FilterMyListView /
                    // FilterLibraryView already document. // pinned: GuardLongPressPickerSourceTests.testGuardMascotLongPressRevealsPickerWithEscalatingHaptic
                    if security.passcodeAuthenticationRequest == nil {
                        guardianRevealTask?.cancel()
                        guardianRevealTask = nil
                        guardianSelectionTask?.cancel()
                        guardianSelectionTask = nil
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Lava Security")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(LavaStyle.lavaOrangeText)

                    Text(viewModel.protectionTitle.lavaLocalized)
                        .font(.title.bold())

                    Text(viewModel.protectionSubtitle.lavaLocalized)
                        .lavaBodySupportingText()
                }
                // One summary element with a STABLE, localized "Protection status" label and the
                // live protection state spoken as the value (state title + detail subtitle, both
                // localized). The label never changes with VPN state; only the value updates.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Protection status"))
                .accessibilityValue(Text(viewModel.protectionTitle.lavaLocalized) + Text(". ") + Text(viewModel.protectionSubtitle.lavaLocalized))
                // The long-press picker reveal hangs off the accessibilityHidden mascot, so VoiceOver /
                // Switch Control / Full Keyboard Access users can't reach it from the Guard tab. Expose it
                // as a custom action on this protection-status element — the same
                // presentLavaGuardPickerFromLongPress path, including its .appSettings auth gate — so the
                // picker isn't reachable only via the Customization page (Codex P3 + OCR on the 1.2.4 sync).
                .accessibilityAction(named: Text("Change Lava Guard".lavaLocalized)) {
                    presentLavaGuardPickerFromLongPress()
                }
            }

            ProtectionPrimaryActionButton()

            if let message = viewModel.guardPanelMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if viewModel.guardPanelMessageIsError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .accessibilityHidden(true)
                    }

                    Text(message.lavaLocalized)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(viewModel.guardPanelMessageIsError ? LavaStyle.errorText : LavaStyle.secondaryText)
                .transition(.opacity)
            }

        }
        .padding(18)
        .lavaPanelBackground()
        .sheet(isPresented: $isPresentingLavaGuardPicker) {
            LavaGuardLookPickerSheet(
                selectedLook: customization.lavaGuardLook,
                onSelect: selectLavaGuardLook
            )
            .environmentObject(viewModel)
            .environmentObject(customization)
            .environmentObject(security)
        }
        .onChange(of: viewModel.protectionTitle + " " + viewModel.protectionSubtitle) { _, _ in
            // Announce the settled protection state to VoiceOver. Key on the FULL accessible value
            // (title + subtitle): the title alone maps healthy AND DNS-fallback both to "Protected",
            // so keying on it would miss fallback/recovery transitions where only the subtitle moves.
            // `.onChange` fires only on a DISTINCT value, so the Guard screen's 5-second poll (which
            // re-reads the same state) does not re-announce — only a real transition speaks.
            LavaAccessibilityAnnouncer.announce(
                viewModel.protectionTitle.lavaLocalized + ". " + viewModel.protectionSubtitle.lavaLocalized
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            // The long-press ramp schedules its escalating pulses with `Task.sleep`; finger-lift and
            // navigate-away already cancel it, but leaving the foreground does not. A 2s hold begun
            // just before the app backgrounds (or goes inactive for the app switcher / a system
            // alert) would otherwise keep firing haptics — even land the reveal crescendo — on a
            // surface the user is no longer looking at. Stop the ramp on any non-active phase (OCR
            // review on the 1.2.4 sync).
            if newPhase != .active {
                stopGuardianLongPressRamp()
            }
        }
    }

    /// Drives the long-press haptic "charge": schedules each escalating pulse from the pure
    /// `GuardianLongPressHaptics` curve against the clock. `onPressingChanged(true)` fires on
    /// finger-down, so the schedule's first pulse waits out `GuardianLongPressHaptics.gracePeriod`
    /// — a quick tap or aborted press is cancelled before it and stays silent (no double-haptic on
    /// an awake tap, no buzz in sleeping/paused states). From there the pulses crowd toward the
    /// reveal so the buildup accelerates. Cancelled the moment the finger lifts — whether the press
    /// completed or was released early.
    private func startGuardianLongPressRamp() {
        guardianLongPressRampTask?.cancel()
        guardianLongPressRampTask = Task { @MainActor in
            var firedDelay: TimeInterval = 0
            for pulse in GuardianLongPressHaptics.schedule {
                let wait = pulse.delay - firedDelay
                firedDelay = pulse.delay
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                }
                if Task.isCancelled {
                    return
                }
                ProtectionHapticFeedback.playGuardianLongPressStep(pulse.step)
            }
        }
    }

    private func stopGuardianLongPressRamp() {
        guardianLongPressRampTask?.cancel()
        guardianLongPressRampTask = nil
    }

    /// The long press completed (held the full `holdDuration`): stop the ramp and reveal the
    /// Lava Guard picker. The sheet shows Customization-only data — the Guard catalog and unlock
    /// progress (`lavaGuardAvailability`) — so the reveal itself is gated behind `.appSettings`
    /// auth. Otherwise the mascot long-press would expose that settings/progress data from the
    /// read-only Guard tab without passing the settings lock (only the later selection and the
    /// unlock-panel links re-authenticate). `requireAuthentication` short-circuits when the surface
    /// is unprotected or already authenticated this turn, so users without the lock — and the
    /// Customization entry point — see no prompt. The crescendo fires on the real reveal, once auth
    /// succeeds.
    private func presentLavaGuardPickerFromLongPress() {
        // Re-entrancy guard: the picker now has TWO triggers — the mascot long-press and the
        // protection-status `.accessibilityAction` — so a second activation while the sheet is
        // already up (or its reveal already committed) must be a no-op, or a stale reveal would fire
        // a second crescendo haptic over the presented sheet. Gate on the sheet flag, not the task
        // handle: the task is not nil'd on completion, so a `guardianRevealTask == nil` check would
        // wrongly block every reveal after the first until `.onDisappear` clears it (OCR review on
        // the 1.2.4 sync). An in-flight reveal (flag still false) is instead superseded by the
        // cancel-prior + `Task.isCancelled` guard below.
        guard !isPresentingLavaGuardPicker else { return }
        stopGuardianLongPressRamp()
        // Track the reveal/auth task so `.onDisappear` can cancel it (mirrors the ramp task). The
        // auth prompt is async; without tracking, navigating away from the Guard tab mid-prompt would
        // let the fire-and-forget task resolve on a dismissed view and fire the reveal haptic + flip
        // the picker flag (Kilo review on the 1.2.4 sync). The `Task.isCancelled` guard after the
        // await closes the race where the view disappears between auth returning and the reveal.
        guardianRevealTask?.cancel()
        guardianRevealTask = Task { @MainActor in
            guard await security.requireAuthentication(
                for: .appSettings,
                reason: "Open Settings"
            ) else {
                return
            }
            guard !Task.isCancelled else { return }

            ProtectionHapticFeedback.playGuardianLongPressStep(GuardianLongPressHaptics.revealStep)
            isPresentingLavaGuardPicker = true
        }
    }

    /// Applies a Lava Guard look chosen from the picker. Mirrors the Customization page: the
    /// change is an app-settings mutation, so it goes through the same authentication gate.
    ///
    /// Tracked in `guardianSelectionTask` (mirroring the reveal task) so a rapid second tap cancels
    /// the first in-flight auth instead of fanning out into parallel prompts, and so `.onDisappear`
    /// can cancel a still-awaiting task on a genuine navigate-away rather than applying a look on a
    /// view the user has already left. The `Task.isCancelled` guard after the await closes the race
    /// where the cancel lands while auth is returning (OCR review on the 1.2.4 sync).
    private func selectLavaGuardLook(_ look: GuardianShieldStyle) {
        guardianSelectionTask?.cancel()
        guardianSelectionTask = Task { @MainActor in
            guard await security.requireAuthentication(
                for: .appSettings,
                reason: "Edit Customization settings"
            ) else {
                return
            }
            guard !Task.isCancelled else { return }

            customization.setLavaGuardLook(look)
        }
    }

    private var guardianState: GuardianMascotState {
        if viewModel.isProtectionTemporarilyPaused {
            return .paused
        }

        switch viewModel.vpnStatus {
        case .connected:
            switch viewModel.protectionConnectivitySeverity {
            case .healthy, .usingDeviceDNSFallback, .usingEncryptedFallback:
                return .awake
            case .recovering, .networkUnavailable:
                return .retrying
            case .dnsSlow, .needsReconnect:
                return .concerned
            }
        case .connecting, .reasserting:
            return .waking
        default:
            return .sleeping
        }
    }

    /// A tap on the awake Lava Guard plays a brief `awake -> grateful -> awake` thank-you
    /// animation. The light haptic fires on *every* awake tap — it is intentionally NOT gated
    /// by the animation, so rapid repeated taps keep returning tactile feedback. The visual
    /// sequence is still de-duped (ignored while one is already running) so it doesn't restart
    /// and stutter. Neither fires from states that communicate real protection status
    /// (sleeping/waking/paused/retrying/concerned).
    private func playGuardianTapGratitude() {
        guard guardianState == .awake else {
            return
        }

        // Haptic first and ungated: a tap during an in-flight animation still gives feedback.
        ProtectionHapticFeedback.play(.guardianTapAcknowledged)

        // Only the visual thank-you is rate-limited — ignore tap-spam while it's already running.
        guard !isGuardianTapAnimationRunning else {
            return
        }

        isGuardianTapAnimationRunning = true

        let dwell = reduceMotion ? 0.20 : 0.35
        let stateChange = GuardianMascotAnimationPlan.stateChangeDuration

        guardianTapAnimationTask?.cancel()
        guardianTapAnimationTask = Task { @MainActor in
            guardianOverrideState = .grateful
            try? await Task.sleep(for: .seconds(stateChange + dwell))
            if Task.isCancelled { return }

            // Clear the override so the mascot animates grateful -> the live base state.
            // If protection status changed mid-tap, this stays honest instead of forcing .awake.
            guardianOverrideState = nil
            try? await Task.sleep(for: .seconds(stateChange))

            isGuardianTapAnimationRunning = false
        }
    }
}

private struct ProtectionPrimaryActionButton: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController

    var body: some View {
        VStack(spacing: 10) {
            Button {
                Task {
                    if viewModel.isProtectionTemporarilyPaused {
                        viewModel.resumeProtectionNow()
                        return
                    }

                    guard await security.requireFreshAuthentication(
                        for: .protectionControl,
                        reason: "Change Lava protection"
                    ) else {
                        return
                    }

                    viewModel.performProtectionPrimaryAction()
                }
            } label: {
                actionLabel
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.protectionButtonTint)
            .disabled(viewModel.protectionPrimaryActionIsDisabled)
            .accessibilityHint("Controls Lava's local DNS protection.".lavaLocalized)
            .frame(maxWidth: ProtectionStatusMetrics.primaryActionMaxWidth)
            .contextMenu {
                if viewModel.showsTemporaryProtectionPauseControls {
                    ForEach(ProtectionPauseDuration.allCases) { option in
                        Button(option.label.lavaLocalized) {
                            Task {
                                guard await security.requireFreshAuthentication(
                                    for: .protectionPause,
                                    reason: "Pause Lava protection"
                                ) else {
                                    return
                                }

                                viewModel.pauseProtectionTemporarily(for: option)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actionLabel: some View {
        HStack(spacing: 8) {
            if viewModel.isConfiguringVPN {
                ProgressView()
            }

            VStack(spacing: 2) {
                Text(viewModel.protectionButtonTitle.lavaLocalized)
                    .font(.title3.bold())

                if viewModel.showsTemporaryProtectionPauseControls {
                    Text("Long-press for pause options".lavaLocalized)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: ProtectionStatusMetrics.primaryActionHeight)
    }
}

enum GuardDestination: Hashable {
    case filters
    case activity
}

private struct GuardDestinationView: View {
    let destination: GuardDestination

    var body: some View {
        switch destination {
        case .filters:
            FiltersView(embedsNavigationStack: false)
        case .activity:
            ActivityView(embedsNavigationStack: false)
        }
    }
}

/// The two explainer rows that replace the old internet-flow graph: a quick way
/// to understand — and jump into — how Lava filters and what it has caught, now
/// that Filters and Activity no longer live in the tab bar. Each row carries a
/// short live stat instead of a paragraph, so it reads at a glance.
///
/// Wrapped in a `LavaSectionGroup` like every other content screen (e.g. Filters'
/// "Manage filters"): the header is the visual break that makes the scaffold's
/// 18pt panel→section gap and the 10pt row→row gap read as one intentional
/// rhythm rather than two mismatched gaps.
private struct GuardExploreSection: View {
    @EnvironmentObject private var viewModel: AppViewModel
    // Observes the diagnostics controller so the caught-today stat re-renders on store changes (Phase D4 peel).
    @EnvironmentObject private var reports: DiagnosticsController

    var body: some View {
        LavaSectionGroup("Learn more") {
            VStack(spacing: 10) {
                LavaNavigationRow(
                    icon: .filters,
                    title: "How Lava filters",
                    summary: viewModel.guardFiltersRowStat
                ) {
                    GuardDestinationView(destination: .filters)
                }

                LavaNavigationRow(
                    icon: .activity,
                    title: "What Lava has caught",
                    summary: reports.guardActivityRowStat
                ) {
                    GuardDestinationView(destination: .activity)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
private struct ProtectionStatusPreviewCase: Identifiable {
    let id: String
    let label: String
    let health: TunnelHealthSnapshot

    static func all(now: Date = Date()) -> [ProtectionStatusPreviewCase] {
        [
            ProtectionStatusPreviewCase(
                id: "protected",
                label: "Protected",
                health: TunnelHealthSnapshot()
            ),
            ProtectionStatusPreviewCase(
                id: "recovering",
                label: "Network Changed",
                health: TunnelHealthSnapshot(
                    lastNetworkChangeAt: now.addingTimeInterval(-5),
                    lastResolverRuntimeResetAt: now.addingTimeInterval(-4),
                    resolverRuntimeResetCount: 1
                )
            ),
            ProtectionStatusPreviewCase(
                id: "device-dns",
                label: "Device DNS Fallback",
                health: TunnelHealthSnapshot(
                    lastDNSSmokeProbeAt: now.addingTimeInterval(-4),
                    lastDNSSmokeProbeSucceeded: false,
                    dnsSmokeProbeFailureCount: 1,
                    lastDeviceDNSFallbackActivatedAt: now.addingTimeInterval(-3),
                    deviceDNSFallbackActivationCount: 1,
                    lastNetworkChangeAt: now.addingTimeInterval(-5)
                )
            ),
            ProtectionStatusPreviewCase(
                id: "network-lost",
                label: "Network Lost",
                health: TunnelHealthSnapshot(
                    networkPathIsSatisfied: false,
                    lastNetworkChangeAt: now.addingTimeInterval(-5),
                    networkChangeCount: 1
                )
            ),
            ProtectionStatusPreviewCase(
                id: "reconnect",
                label: "Reconnect Needed",
                health: TunnelHealthSnapshot(
                    lastDNSSmokeProbeAt: now.addingTimeInterval(-3),
                    lastDNSSmokeProbeSucceeded: false,
                    dnsSmokeProbeFailureCount: 1,
                    lastNetworkChangeAt: now.addingTimeInterval(-5)
                )
            )
        ]
    }
}

#Preview("Protection States") {
    ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(ProtectionStatusPreviewCase.all()) { previewCase in
                VStack(alignment: .leading, spacing: 8) {
                    Text(previewCase.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LavaStyle.secondaryText)

                    ProtectionStatusPanel()
                        .environmentObject(AppViewModel.previewProtectionState(health: previewCase.health))
                }
            }
        }
        .padding()
    }
    .background(LavaStyle.groupedBackground)
}
#endif
