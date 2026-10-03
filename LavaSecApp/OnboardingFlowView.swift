import SwiftUI
import UserNotifications
import LavaSecKit
import LavaSecAppServices
import LavaSecPresentation

struct LavaOnboardingView: View {
    @Binding var hasSeenOnboarding: Bool
    /// Installs the optional DNS configuration; selection remains an explicit Settings action.
    var installDNSProfile: () async throws -> Void = {}
    var supportsDNSProfile = false
    /// QA rehearsal: all setup actions and choices stay in this view's transient state.
    var isMock = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject private var handoff = LavaOnboardingHandoff.shared
    @State private var sourceFrame = CGRect.zero
    @State private var footerHeight: CGFloat = 0
    @State private var travelOrigin = CGRect.zero
    @State private var travelStarted: Date?
    @State private var opening = false
    @State private var surroundingsOpacity = 1.0
    @State private var sessionID: String?
    @State private var arrivalAttempt = 0
    @State private var arrivalFailed = false
    @State private var page: OnboardingPage = .lava
    @State private var pageHistory: [OnboardingPage] = []
    @State private var visitedPages: Set<OnboardingPage> = [.lava]
    @State private var didInstallVPN = false
    @State private var notificationsEnabled = false
    @State private var isInstallingVPN = false
    @State private var isRequestingNotifications = false
    @State private var isInstallingDNSProfile = false
    @State private var didInstallDNSProfile = false
    @State private var dnsProfileError: String?
    @State private var protectionLevel: OnboardingProtectionLevel = .recommended
    @State private var useEncryptedFallback = true
    @State private var useDNSProfile = true
    @State private var hasLoadedConnectionChoice = false
    @State private var expressionTask: Task<Void, Never>?
    @State private var blinkTrigger = 0
    @State private var finishTrigger = 0
    @State private var isSmiling = false
    private let panelFadeDelay = 0.1
    private let panelFadeDuration = 0.55

    private var vpnInstalled: Bool {
        if isMock { return didInstallVPN }
        #if targetEnvironment(simulator)
        return didInstallVPN || viewModel.isVPNConfigurationInstalled
        #else
        return viewModel.isVPNConfigurationInstalled
        #endif
    }
    // Trigger the panel with the return from grateful to awake; its brief delay
    // lets the face lead while the last part of the travel settles.
    private var panelReveal: Double { page == .done && travelStarted != nil && !isSmiling ? 1 : 0 }
    private var isBusy: Bool { isInstallingVPN || isRequestingNotifications || isInstallingDNSProfile || opening }
    private var mascotState: GuardianMascotState {
        if opening { return .sleeping }
        if page == .vpn && (!vpnInstalled || isInstallingVPN) { return .sleeping }
        return isSmiling ? .grateful : .awake
    }

    var body: some View {
        ZStack {
            if isMock {
                // Same root placement as RootView, outside the overlay's safe-area geometry.
                LavaAppHost(onboardingPreview: true).ignoresSafeArea(.all, edges: .bottom)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            GeometryReader { proxy in
                ZStack {
                    NavigationStack {
                        onboardingContent.lavaFullSheetHeader("", leading: {
                            if !pageHistory.isEmpty {
                                LavaToolbarIconButton(systemName: "chevron.left", accessibilityLabel: "Back", action: goBack)
                                    .disabled(isBusy).opacity(opening ? 0 : 1)
                            }
                        }, trailing: {
                            if isMock {
                                LavaToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close") { dismiss() }
                                    .opacity(opening ? 0 : 1)
                            }
                        })
                        .toolbarBackground(page == .lava || page == .done ? .hidden : .automatic, for: .navigationBar)
                    }
                    .mask { coverMask }
                    .opacity(surroundingsOpacity)
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: travelStarted == nil || handoff.phase != "arriving")) { timeline in
                        mascotAndAction(in: proxy, at: timeline.date)
                    }
                }
            }
        }
        .onAppear { sessionID = handoff.begin(mock: isMock) }
        .onDisappear { expressionTask?.cancel(); handoff.end(session: sessionID) }
    }

    private var coverMask: some View {
        GeometryReader { mask in
            Rectangle().overlay {
                if let panel = handoff.frames["panel"] {
                    Rectangle()
                        .frame(width: panel.width, height: panel.height)
                        .position(x: panel.midX - mask.frame(in: .global).minX,
                                  y: panel.midY - mask.frame(in: .global).minY)
                        .opacity(panelReveal)
                        .animation(.easeInOut(duration: panelFadeDuration)
                            .delay(panelReveal == 1 ? panelFadeDelay : 0), value: panelReveal)
                        .blendMode(.destinationOut)
                }
            }.compositingGroup()
        }.ignoresSafeArea()
    }

    private func mascotAndAction(in proxy: GeometryProxy, at date: Date) -> some View {
        let destination = handoff.frames["mascot"] ?? sourceFrame
        let progress = opening ? 1 : travelStarted.map { OnboardingGuardTravel.progress(at: date.timeIntervalSince($0)) } ?? 0
        let origin = travelStarted == nil ? sourceFrame : travelOrigin
        let center = CGPoint(x: origin.midX + (destination.midX - origin.midX) * progress,
                             y: origin.midY + (destination.midY - origin.midY) * progress)
        return ZStack {
            ZStack {
                SoftShieldGuardian(size: LavaGuardMetrics.mascotSize, state: mascotState,
                    animates: true, blinkTrigger: blinkTrigger, finishTrigger: finishTrigger, shieldStyle: viewModel.customization.lavaGuardLook,
                    keepsColorWhenSleeping: !opening)
                    .accessibilityHidden(true)
                // Expose the canonical drawing slot, not the changing outline's tight bounds.
                Color.clear.accessibilityElement().accessibilityLabel("Lava")
                    .accessibilityValue(mascotState.rawValue)
                    .accessibilityIdentifier("onboarding.mascot")
            }
            .frame(width: LavaGuardMetrics.mascotSize, height: LavaGuardMetrics.mascotSize)
            .position(x: center.x - proxy.frame(in: .global).minX,
                      y: center.y - proxy.frame(in: .global).minY)
            .opacity(page == .lava || handoff.phase == "released" ? 0 : 1)
            .animation(guardRevealAnimation, value: page == .lava)
            .allowsHitTesting(false)
            if page == .done, panelReveal == 1, let panel = handoff.frames["panel"] {
                Color.clear.frame(width: panel.width, height: panel.height)
                    .accessibilityElement().accessibilityLabel("Ready")
                    .accessibilityValue("Your next step to a safer internet.")
                    .accessibilityIdentifier("onboarding.ready")
                    .position(x: panel.midX - proxy.frame(in: .global).minX,
                              y: panel.midY - proxy.frame(in: .global).minY)
                    .allowsHitTesting(false)
            }
            if page == .done, panelReveal == 1, let action = handoff.frames["action"] {
                Button(action: openGuard) { Color.clear.contentShape(Rectangle()) }
                    .frame(width: action.width, height: action.height)
                    .position(x: action.midX - proxy.frame(in: .global).minX,
                              y: action.midY - proxy.frame(in: .global).minY)
                    .accessibilityLabel("Open Guard").accessibilityIdentifier("onboarding.primary")
                    .disabled(isBusy)
            }
        }
    }

    private var onboardingContent: some View {
        GeometryReader { proxy in
            ZStack {
                LavaStyle.groupedBackground.ignoresSafeArea()

                OnboardingLavaBackdrop()
                    .ignoresSafeArea()
                    .opacity(page == .lava ? 1 : 0)
                    .animation(reduceMotion ? .easeInOut(duration: 0.25) : .easeOut(duration: 0.7), value: page == .lava)
                    .allowsHitTesting(false)

                OnboardingLavaFloor(cornerRadius: 0, intensity: 1.35, isActive: page == .lava)
                    .ignoresSafeArea()
                    .offset(y: page == .lava || reduceMotion ? 0 : proxy.size.height * 1.1)
                    .opacity(reduceMotion && page != .lava ? 0 : 1)
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    // The slot remains in layout; one persistent drawing lives above the cover.
                    Color.clear
                        .frame(height: 128)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sourceFrame = $0 }

                    ZStack {
                        if page == .lava {
                            ScrollView {
                                internetIsLavaPage
                                    .padding(.horizontal, 24)
                                    .padding(.top, 72)
                                    .padding(.bottom, 24)
                                    .frame(maxWidth: 600)
                                    .frame(maxWidth: .infinity)
                            }
                            .scrollIndicators(.hidden)
                            // The outgoing copy rides the same distance and timing as the waves.
                            .transition(reduceMotion ? .opacity.animation(revealAnimation) :
                                .offset(y: proxy.size.height * 1.1).animation(revealAnimation))
                        } else {
                            ScrollView {
                                currentPage
                                    .padding(.horizontal, 24)
                                    .padding(.top, 8)
                                    .padding(.bottom, 24)
                                    .frame(maxWidth: 600)
                                    .frame(maxWidth: .infinity)
                            }
                            .scrollIndicators(.hidden)
                            .id(page)
                            .transition(.asymmetric(
                                insertion: .opacity.animation(page == .features ? guardRevealAnimation : pageChangeAnimation),
                                removal: .opacity.animation(pageChangeAnimation)))
                        }
                    }
                    .clipped()

                    if page == .done {
                        // Preserve the measured layout without retaining invisible controls.
                        Color.clear.frame(height: footerHeight).accessibilityHidden(true)
                    } else {
                        footer
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
                            .transition(.opacity)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            if !isMock && !hasLoadedConnectionChoice {
                useEncryptedFallback = viewModel.configuration.usesEncryptedDeviceDNSFallback
                hasLoadedConnectionChoice = true
            }
        }
        .task(id: scenePhase) {
            guard !isMock, scenePhase == .active else { return }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsEnabled = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            await viewModel.refreshProtectionStatus(force: true)
        }
        .task(id: "\(page.rawValue)-\(arrivalAttempt)") {
            guard page == .done else { return }
            // Wait for the real destination to report a valid layout; no guessed fallback.
            do {
                arrivalFailed = false
                let deadline = ContinuousClock.now + .seconds(8)
                while handoff.frames["mascot"] == nil || handoff.frames["panel"] == nil || handoff.frames["action"] == nil {
                    if ContinuousClock.now >= deadline { arrivalFailed = true; return }
                    try await Task.sleep(for: .milliseconds(80))
                }
                travelOrigin = sourceFrame
                let started = Date()
                travelStarted = started
                while isSmiling { try await Task.sleep(for: .milliseconds(40)) }
                // The return to awake has triggered the slightly delayed panel fade.
                // Keep the clock running until both visuals settle.
                let remainingTravel = OnboardingGuardTravel.duration - Date().timeIntervalSince(started)
                try await Task.sleep(for: .seconds(max(remainingTravel, panelFadeDelay + panelFadeDuration)))
                if !opening { handoff.setPhase("ready") }
            } catch { }
        }
        .task(id: opening) {
            guard opening else { return }
            do {
                handoff.setPhase("opening")
                withAnimation(.easeInOut(duration: 0.7)) { surroundingsOpacity = 0 }
                let duration = GuardianMascotAnimationPlan.animation(from: .awake, to: .sleeping).duration
                try await Task.sleep(for: .seconds(duration))
                // The drawing is now identical to the actual off mascot beneath it.
                handoff.setPhase("released")
                try await Task.sleep(for: .milliseconds(isMock ? 2080 : 80))
                if isMock { dismiss() } else { hasSeenOnboarding = true }
            } catch { }
        }
    }

    private func openGuard() {
        guard !isBusy, page == .done else { return }
        finishExpression()
        ProtectionHapticFeedback.play(.actionSucceeded)
        opening = true
    }

    @ViewBuilder
    private var currentPage: some View {
        switch page {
        case .lava: internetIsLavaPage
        case .features: guardScenePage
        case .vpn: vpnPage
        case .protectionLevel: protectionLevelPage
        case .connectionQuality: connectionQualityPage
        case .done: donePage
        }
    }

    private var internetIsLavaPage: some View {
        VStack(spacing: 24) {
            Text("The internet is lava")
                .font(.title.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .shadow(color: .black.opacity(0.22), radius: 12, y: 6)

            Text("Malicious domains are the hot spots. Your device can step around them before apps and websites connect.")
                .font(.title3.bold())
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    private var guardScenePage: some View {
        LavaSetupStepLayout(title: "Lava stands guard here") {
            OnboardingFeatureRow(systemImage: "shield",
                                 title: "Lava blocks your device's access to malicious domains")
            OnboardingFeatureRow(systemImage: "lock",
                                 title: "Local filter makes it safe, private and free")
            OnboardingFeatureRow(systemImage: "slider.horizontal.3",
                                 title: "You're in full control of what gets logged locally")
        }
    }

    private var protectionLevelPage: some View {
        LavaSetupStepLayout(title: "Pick how much Lava blocks") {
            OnboardingProtectionLevelPanel(selection: $protectionLevel)
        }
    }

    private var connectionQualityPage: some View {
        LavaSetupStepLayout(title: "Lastly, let’s keep your connection running smoothly.",
                            description: "Change these anytime in Settings.") {
            OnboardingConnectionPanel(useEncryptedFallback: $useEncryptedFallback,
                                      useDNSProfile: $useDNSProfile, supportsDNSProfile: supportsDNSProfile)
                .disabled(isInstallingDNSProfile)
            if let dnsProfileError {
                Text(dnsProfileError).lavaQuietNoteText().foregroundStyle(LavaStyle.errorText)
                Button("Set up later") { goForward() }
                    .buttonStyle(LavaSecondaryActionButtonStyle())
            }
        }
    }

    private var vpnPage: some View {
        LavaSetupStepLayout(title: "First, let’s get Lava ready to help.") {
            OnboardingPermissionButton(title: vpnInstalled ? "VPN installed" : "Install local VPN",
                systemImage: "shield",
                isComplete: vpnInstalled, isLoading: isInstallingVPN, action: installVPN)
                .disabled((!isMock && viewModel.isConfiguringVPN) || isBusy || vpnInstalled)
                .accessibilityIdentifier("onboarding.install-vpn")
            OnboardingPermissionButton(title: notificationsEnabled ? "Notifications enabled (optional)" : "Enable notifications (optional)",
                systemImage: "bell",
                isComplete: notificationsEnabled, isLoading: isRequestingNotifications, action: requestNotifications)
                .disabled(isBusy || notificationsEnabled)
                .accessibilityIdentifier("onboarding.notifications")
            if !isMock, viewModel.vpnMessageIsError, let message = viewModel.vpnMessage {
                Text(message).lavaQuietNoteText().foregroundStyle(LavaStyle.errorText)
            }
        }
    }

    private var donePage: some View {
        // The actual RN Guard panel is revealed through the cover at its canonical frame.
        VStack(spacing: 16) {
            if arrivalFailed {
                Text("Guard is still loading. Please try again.").lavaQuietNoteText()
                Button("Try again") {
                    handoff.setPhase("arriving", restart: true)
                    arrivalAttempt += 1
                }.buttonStyle(LavaSecondaryActionButtonStyle())
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 16) { pageDots; footerButtons }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 18)
    }

    private var pageDots: some View {
        HStack(spacing: 0) {
            ForEach(OnboardingPage.allCases) { dotPage in
                Button {
                    guard visitedPages.contains(dotPage) else { return }
                    navigate(to: dotPage)
                } label: {
                    Capsule().fill(dotPage == page ? activeDotColor : inactiveDotColor)
                        .frame(width: dotPage == page ? 24 : 8, height: 8)
                        .frame(width: dotPage == page ? 32 : 20, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!visitedPages.contains(dotPage) || isBusy || (dotPage.rawValue > OnboardingPage.vpn.rawValue && !vpnInstalled))
                .accessibilityLabel("Step %lld of %lld".lavaLocalizedFormat(dotPage.rawValue + 1, OnboardingPage.allCases.count))
                .accessibilityAddTraits(dotPage == page ? [.isSelected] : [])
            }
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
        switch page {
        case .lava, .features:
            OnboardingPrimaryButton(title: page == .lava ? "Meet Lava" : "Set Up Protection",
                                    usesWhiteOutline: page == .lava) { goForward() }
        case .vpn:
            OnboardingPrimaryButton(title: vpnInstalled ? "Next step" : "Install VPN first",
                                    isDisabled: !vpnInstalled || isBusy) { goForward() }
        case .protectionLevel:
            OnboardingPrimaryButton(title: "Next step", isDisabled: isBusy) { goForward() }
        case .connectionQuality:
            OnboardingPrimaryButton(title: "Next step", isLoading: isInstallingDNSProfile) { navigate(to: .done) }
        case .done:
            Color.clear.frame(height: 44)
        }
    }

    private var activeDotColor: Color { page == .lava ? .white : LavaStyle.safeGreen }
    private var inactiveDotColor: Color { page == .lava ? .white.opacity(0.28) : LavaStyle.secondaryText.opacity(0.22) }

    private func goForward() {
        guard let next = page.next else { return }
        go(to: next)
    }

    private func navigate(to next: OnboardingPage) {
        guard next != page, !isBusy else { return }
        finishExpression()
        if next == .done && supportsDNSProfile && useDNSProfile && !didInstallDNSProfile {
            isInstallingDNSProfile = true
            dnsProfileError = nil
            Task { @MainActor in
                defer { isInstallingDNSProfile = false }
                do {
                    if isMock { try await Task.sleep(for: .milliseconds(500)) }
                    else { try await installDNSProfile() }
                    guard !Task.isCancelled else { return }
                    didInstallDNSProfile = true
                    isInstallingDNSProfile = false
                    go(to: next)
                } catch {
                    isInstallingDNSProfile = false
                    go(to: .connectionQuality)
                    dnsProfileError = "Couldn't save your changes. Please try again.".lavaLocalized
                }
            }
        } else { go(to: next) }
    }

    private func go(to nextPage: OnboardingPage) {
        guard nextPage != page, !isBusy else { return }
        guard nextPage.rawValue <= OnboardingPage.vpn.rawValue || vpnInstalled else { return }
        applyCurrentStepChoiceIfNeeded(persistImmediately: nextPage != .done)
        if !isMock && nextPage == .done {
            viewModel.applyOnboardingRecommendedDefaults(protectionLevel: protectionLevel)
        }
        let shouldBlink = page == .protectionLevel && nextPage == .connectionQuality
        finishExpression()
        pageHistory.append(page)
        visitedPages.insert(nextPage)
        withAnimation(page == .lava || nextPage == .lava ? revealAnimation : pageChangeAnimation) { page = nextPage }
        if nextPage == .done { handoff.setPhase("arriving"); playGratitude() }
        else if shouldBlink { blinkTrigger += 1 }
    }

    private func goBack() {
        guard !isBusy, let previousPage = pageHistory.popLast() else { return }
        applyCurrentStepChoiceIfNeeded()
        if page == .done {
            handoff.setPhase("setup")
            withAnimation(.easeInOut(duration: 0.4)) { travelStarted = nil }
        }
        finishExpression()
        withAnimation(previousPage == .lava ? revealAnimation : pageChangeAnimation) { page = previousPage }
    }

    private var revealAnimation: Animation? { reduceMotion ? .easeInOut(duration: 0.25) : .easeInOut(duration: 1.1) }
    private var guardRevealAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .easeInOut(duration: 1.25).delay(0.15)
    }
    private var pageChangeAnimation: Animation? {
        reduceMotion ? .easeInOut(duration: 0.2) : LavaFlowTransition.animation(reduceMotion: false)
    }

    private func applyCurrentStepChoiceIfNeeded(persistImmediately: Bool = true) {
        guard !isMock else { return }
        switch page {
        case .protectionLevel:
            viewModel.selectOnboardingBlocklists(protectionLevel.enabledBlocklistIDs(), persistImmediately: persistImmediately)
        case .connectionQuality:
            viewModel.applyOnboardingConnectionPreferences(
                useEncryptedFallback: useEncryptedFallback,
                persistImmediately: persistImmediately
            )
        default: break
        }
    }

    private func finishExpression() {
        expressionTask?.cancel()
        expressionTask = nil
        isSmiling = false
        finishTrigger += 1
    }

    private func playGratitude() {
        expressionTask?.cancel()
        isSmiling = true
        expressionTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(GuardianMascotAnimationPlan.stateChangeDuration + 0.65))
                isSmiling = false
                try await Task.sleep(for: .seconds(GuardianMascotAnimationPlan.stateChangeDuration))
            } catch { } // The newer action owns the expression after cancellation.
        }
    }

    private func installVPN() {
        guard !isBusy, isMock || !viewModel.isConfiguringVPN else { return }
        finishExpression()
        isInstallingVPN = true
        Task { @MainActor in
            if isMock {
                try? await Task.sleep(for: .milliseconds(500))
                didInstallVPN = true
            } else {
                didInstallVPN = await viewModel.installLocalVPNProfileForOnboarding()
            }
            isInstallingVPN = false
        }
    }

    private func requestNotifications() {
        guard !isBusy else { return }
        finishExpression()
        isRequestingNotifications = true
        Task { @MainActor in
            if isMock {
                try? await Task.sleep(for: .milliseconds(500))
                notificationsEnabled = true
            } else {
                notificationsEnabled = await viewModel.requestProtectionNotificationAuthorizationForOnboarding()
            }
            if notificationsEnabled && vpnInstalled && page == .vpn { playGratitude() }
            isRequestingNotifications = false
        }
    }
}

private enum OnboardingPage: Int, CaseIterable, Identifiable {
    case lava, features, vpn, protectionLevel, connectionQuality, done
    var id: Int { rawValue }
    var next: OnboardingPage? { OnboardingPage(rawValue: rawValue + 1) }
}

private extension OnboardingProtectionLevel {
    // Concise descriptions share the same wrapping row anatomy for every choice.
    var leverSummary: LocalizedStringKey {
        switch self {
        case .essential:
            "Blocks malicious sites: phishing, scams, and malware."
        case .balanced:
            "Adds spam, fraud, and abuse coverage. Best for most."
        case .comprehensive:
            "Adds ads and trackers. May break some sites."
        }
    }
}

/// Setup choices share one trailing accessory and filled selection treatment.
private func updateOnboardingSelection(_ update: () -> Void) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) { update() }
}

private struct OnboardingProtectionLevelPanel: View {
    @Binding var selection: OnboardingProtectionLevel

    var body: some View {
        VStack(spacing: LavaSpacing.lg) {
            ForEach(OnboardingProtectionLevel.allCases, id: \.self) { level in
                Button { updateOnboardingSelection { selection = level } } label: {
                    OnboardingSelectionLabel(title: level.displayName, emoji: level.emoji,
                                             summary: level.leverSummary, isSelected: selection == level)
                }
                .buttonStyle(.plain)
                .accessibilityValue(Text(selection == level ? "On" : "Off"))
                .accessibilityAddTraits(selection == level ? .isSelected : [])
                .accessibilityIdentifier("onboarding.filter.\(level.rawValue)")
            }
        }
    }
}

private struct OnboardingConnectionPanel: View {
    @Binding var useEncryptedFallback: Bool
    @Binding var useDNSProfile: Bool
    let supportsDNSProfile: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: LavaSpacing.lg) {
            connectionChoice("Keep connections working", systemImage: "network",
                summary: "Try a backup DNS service when websites won't load. The default is Quad9",
                isOn: $useEncryptedFallback)
                .accessibilityIdentifier("onboarding.dns-fallback")
            if supportsDNSProfile {
                connectionChoice("Set up DNS profile", systemImage: "doc.text",
                    summary: "This helps Lava work well in iOS 27 with Connectivity Assist. Follow the orange dots for complete setups",
                    isOn: $useDNSProfile)
                    .accessibilityIdentifier("onboarding.dns-profile")
            }
        }
    }

    private func connectionChoice(_ title: String, systemImage: String, summary: LocalizedStringKey,
                                  isOn: Binding<Bool>) -> some View {
        Button { updateOnboardingSelection { isOn.wrappedValue.toggle() } } label: {
            OnboardingSelectionLabel(title: title, summary: summary, isSelected: isOn.wrappedValue,
                                     systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(isOn.wrappedValue ? "On" : "Off"))
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }
}

private struct OnboardingPermissionButton: View {
    let title: String
    let systemImage: String
    let isComplete: Bool
    let isLoading: Bool
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if isComplete {
            // A completed action is a status surface, so it retains full contrast.
            label.accessibilityElement(children: .combine)
        } else {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
        }
    }

    private var label: some View {
        OnboardingSelectionLabel(title: title, isSelected: isComplete,
                                 systemImage: systemImage, isLoading: isLoading)
    }
}

/// Matches the filter scaffold's content insets and reserved trailing glyph column.
private struct OnboardingSelectionLabel: View {
    let title: String
    var emoji: String? = nil
    var summary: LocalizedStringKey? = nil
    let isSelected: Bool
    var systemImage: String? = nil
    var isLoading = false

    var body: some View {
        HStack(spacing: LavaSpacing.md) {
            VStack(alignment: .leading, spacing: LavaSpacing.xs) {
                HStack(spacing: LavaSpacing.sm) {
                    if let emoji { Text(emoji).accessibilityHidden(true) }
                    Text(title.lavaLocalized)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .lavaRowTitleText()
                if let summary {
                    Text(summary).lavaSupportingText(color: isSelected ? .white.opacity(0.85) : LavaStyle.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Group {
                if isLoading {
                    ProgressView()
                } else if isSelected {
                    OnboardingRowGlyph(systemImage: "checkmark.circle.fill")
                } else if let systemImage {
                    OnboardingRowGlyph(systemImage: systemImage)
                } else {
                    Color.clear
                }
            }
            .frame(width: LavaSelectionAccessory.columnWidth, height: LavaToolbarMetrics.iconFrameSize)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, LavaRowHeight.horizontalInset)
        .padding(.vertical, LavaRowHeight.verticalInset)
        .frame(maxWidth: .infinity, minHeight: LavaRowHeight.standard, alignment: .leading)
        .foregroundStyle(isSelected ? Color.white : LavaStyle.ink)
        .background(isSelected ? LavaStyle.safeControlGreen : LavaStyle.cardBackground,
                    in: RoundedRectangle(cornerRadius: LavaSurface.controlCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: LavaSurface.controlCornerRadius))
        .accessibilityElement(children: .combine)
    }
}

/// Unadorned outline symbols match Settings rows; completed actions use its success glyph.
private struct OnboardingRowGlyph: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: LavaNavigationRowMetrics.glyphPointSize, weight: .regular))
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }
}

private struct OnboardingFeatureRow: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: LavaSpacing.md) {
            OnboardingRowGlyph(systemImage: systemImage)
            Text(title.lavaLocalized)
                .lavaRowTitleText()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(LavaStyle.ink)
        .padding(.horizontal, LavaRowHeight.horizontalInset)
        .padding(.vertical, LavaRowHeight.verticalInset)
        .frame(maxWidth: .infinity, minHeight: LavaRowHeight.standard, alignment: .leading)
        .lavaSurface(.card, cornerRadius: LavaSurface.controlCornerRadius)
    }
}

private struct OnboardingPrimaryButton: View {
    let title: String
    var isLoading = false
    var isDisabled = false
    var usesWhiteOutline = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LavaSpacing.sm) {
                if isLoading { ProgressView().controlSize(.small).tint(LavaStyle.actionForeground) }
                Text(title.lavaLocalized)
                    // Replace the label once; only the surrounding button material morphs.
                    .contentTransition(.identity)
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
            }
        }
        .buttonStyle(LavaStandaloneActionButtonStyle())
        .environment(\.lavaActionWhiteOutline, usesWhiteOutline)
        .disabled(isDisabled || isLoading)
        .accessibilityIdentifier("onboarding.primary")
    }
}

/// The rectangular top layer stays stationary while the curved curtain drains.
private struct OnboardingLavaBackdrop: View {
    static let colors: [Color] = [LavaStyle.lavaOrange.opacity(0.86), Color(red: 0.83, green: 0.08, blue: 0.02), Color(red: 0.48, green: 0.02, blue: 0.01)]

    var body: some View {
        LinearGradient(colors: Self.colors, startPoint: .top, endPoint: .bottom)
    }
}

private struct OnboardingLavaFloor: View {
    var cornerRadius: CGFloat = 28
    var intensity: CGFloat = 1
    var isActive = true
    @State private var startDate = Date.now

    var body: some View {
        // Keep the welcome waves alive in both motion modes; page movement still respects Reduce Motion.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isActive)) { timeline in
            let phase = OnboardingLavaWaveTimeline.phase(at: timeline.date.timeIntervalSince(startDate))
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                // Keep the curtain opaque below its wave edge without translating a rectangle.
                let leadingEdge = LavaWaveShape(phase: phase, amplitude: 18 * intensity, baseline: 0.18).path(in: rect)
                context.clip(to: leadingEdge)
                context.fill(Path(rect), with: .color(LavaStyle.groupedBackground))
                context.fill(Path(rect), with: .linearGradient(
                    Gradient(colors: OnboardingLavaBackdrop.colors),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                let waves: [(Double, CGFloat, CGFloat, Color)] = [
                    (phase, 18, 0.18, Color(red: 1, green: 0.50, blue: 0.13).opacity(0.74)),
                    (-phase + .pi * 0.35, 22, 0.34, Color(red: 0.92, green: 0.20, blue: 0.04).opacity(0.78)),
                    (phase * 2 + .pi, 14, 0.48, Color(red: 0.55, green: 0.03, blue: 0.01).opacity(0.70))
                ]
                for (phase, amplitude, baseline, color) in waves {
                    context.fill(LavaWaveShape(phase: phase, amplitude: amplitude * intensity, baseline: baseline).path(in: rect), with: .color(color))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct LavaWaveShape: Shape {
    var phase: Double
    var amplitude: CGFloat
    var baseline: CGFloat

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let baseY = rect.height * baseline
        let step = max(rect.width / 96, 1)

        path.move(to: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: baseY))

        for x in stride(from: 0, through: rect.width, by: step) {
            let progress = x / max(rect.width, 1)
            let primary = sin(Double(progress) * Double.pi * 2 + phase)
            let secondary = sin(Double(progress) * Double.pi * 4 - phase)
            let tertiary = sin(Double(progress) * Double.pi * 6 + phase * 2)
            let y = baseY
                + CGFloat(primary) * amplitude
                + CGFloat(secondary) * amplitude * 0.34
                + CGFloat(tertiary) * amplitude * 0.16
            path.addLine(to: CGPoint(x: x, y: y))
        }

        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.closeSubpath()
        return path
    }
}

#Preview("Onboarding") {
    LavaOnboardingView(hasSeenOnboarding: .constant(false), supportsDNSProfile: true, isMock: true)
        .environmentObject(AppViewModel(loadVPNState: false))
}

/// Transient presentation only. Geometry comes from the mounted Guard panel;
/// no VPN, notification, DNS, filter or onboarding preference is written here.
@MainActor
final class LavaOnboardingHandoff: ObservableObject {
    static let shared = LavaOnboardingHandoff()
    @Published private(set) var frames: [String: CGRect] = [:]
    @Published private(set) var phase = "setup"
    private var session: String?
    private var mock = false
    private var layoutRevision = 0

    // The measured finale belongs to Guard until the overlay has fully released it.
    // Mock previews must not constrain navigation in the real app beneath QA.
    var keepsGuardVisible: Bool { session != nil && !mock && phase != "setup" }

    var snapshot: Any {
        guard let session else { return NSNull() }
        return ["session": session, "mock": mock, "phase": phase, "layoutRevision": layoutRevision] as [String: Any]
    }
    func begin(mock: Bool) -> String {
        let id = UUID().uuidString
        session = id
        self.mock = mock
        frames = [:]
        phase = "setup"
        LavaAppBridge.shared.publish()
        return id
    }
    func setPhase(_ value: String, restart: Bool = false) {
        guard session != nil, phase != value || restart else { return }
        phase = value
        if value == "arriving" {
            layoutRevision += 1
            frames = [:]
            if !mock { LavaAppBridge.shared.requestNavigation(tab: "GuardTab", screen: "Guard") }
        }
        LavaAppBridge.shared.publish()
    }
    func end(session id: String?) {
        guard let id, session == id else { return }
        session = nil
        frames = [:]
        phase = "setup"
        LavaAppBridge.shared.publish()
    }
    func receive(_ input: [String: Any]) -> Bool {
        guard let session, input["session"] as? String == session, input["phase"] as? String == phase, input["layoutRevision"] as? Int == layoutRevision,
              let values = input["frames"] as? [String: [String: Double]] else { return false }
        var next: [String: CGRect] = [:]
        for name in ["panel", "mascot", "action"] {
            guard let value = values[name], let x = value["x"], let y = value["y"],
                  let width = value["width"], let height = value["height"],
                  [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return false }
            next[name] = CGRect(x: x, y: y, width: width, height: height)
        }
        guard let panel = next["panel"], let mascot = next["mascot"], let action = next["action"],
              panel.insetBy(dx: -1, dy: -1).contains(mascot), panel.insetBy(dx: -1, dy: -1).contains(action) else { return false }
        if next != frames { frames = next }
        return true
    }
}
