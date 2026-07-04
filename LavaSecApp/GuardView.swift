import SwiftUI
import LavaSecCore
import UIKit

private enum ProtectionStatusMetrics {
    static let primaryActionMaxWidth: CGFloat = 300
    static let primaryActionHeight: CGFloat = 56
}

struct GuardView: View {
    @EnvironmentObject private var viewModel: AppViewModel
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
        viewModel.refreshDiagnostics()
        await viewModel.refreshProtectionStatus()
        await viewModel.sampleTunnelHealth()
    }
}

struct ProtectionStatusPanel: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var guardianOverrideState: GuardianMascotState?
    @State private var isGuardianTapAnimationRunning = false
    @State private var guardianTapAnimationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                SoftShieldGuardian(
                    size: 96,
                    state: guardianOverrideState ?? guardianState,
                    shieldStyle: viewModel.lavaGuardLook
                )
                .contentShape(Rectangle())
                .accessibilityHidden(true)
                .onTapGesture { playGuardianTapGratitude() }
                .onDisappear {
                    guardianTapAnimationTask?.cancel()
                    guardianTapAnimationTask = nil
                    isGuardianTapAnimationRunning = false
                    guardianOverrideState = nil
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Lava Security")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(LavaStyle.lavaOrangeText)

                    Text(viewModel.protectionTitle.lavaLocalized)
                        .font(.title.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(viewModel.protectionSubtitle.lavaLocalized)
                        .lavaBodySupportingText()
                }
                // One summary element with a STABLE, localized "Protection status" label and the
                // live protection state spoken as the value (state title + detail subtitle, both
                // localized). The label never changes with VPN state; only the value updates.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Protection status"))
                .accessibilityValue(Text(viewModel.protectionTitle.lavaLocalized) + Text(". ") + Text(viewModel.protectionSubtitle.lavaLocalized))
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: ProtectionStatusMetrics.primaryActionHeight)
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
                    summary: viewModel.guardActivityRowStat
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
