import SwiftUI
import LavaSecCore

struct LavaOnboardingView: View {
    @Binding var hasSeenOnboarding: Bool
    /// Invoked when the user finishes setup via "Go to Settings" so the host can
    /// land them on the Settings tab instead of Guard.
    var onRequestOpenSettings: () -> Void = {}
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var page: OnboardingPage = .lava
    @State private var pageHistory: [OnboardingPage] = []
    @State private var visitedPages: Set<OnboardingPage> = [.lava]
    @State private var featureTransitionElapsed = OnboardingFeatureTransitionPlan.totalDuration
    @State private var guardHeroBlinkTrigger = 0
    @State private var isInstallingVPN = false
    @State private var isRequestingNotifications = false
    @State private var isShowingAdditionalSetup = false
    @State private var protectionLevel: OnboardingProtectionLevel = .recommended
    @State private var useEncryptedFallback = true
    @State private var fallbackResolverPresetID = DNSResolverPreset.mullvadDoH.id

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LavaStyle.groupedBackground
                    .ignoresSafeArea()

                OnboardingLavaFloor(cornerRadius: 0, intensity: 1.35)
                    .ignoresSafeArea()
                    .opacity(page == .lava ? 1 : 0)

                VStack(spacing: 0) {
                    topBar

                    ScrollView {
                        currentPage
                            .padding(.horizontal, page == .lava ? 0 : 24)
                            .padding(.top, page == .lava ? 0 : 12)
                            .padding(.bottom, page == .lava ? 0 : 24)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: max(520, proxy.size.height - 154), alignment: .top)
                    }
                    .scrollIndicators(.hidden)

                    footer
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: $isShowingAdditionalSetup) {
            OnboardingAdditionalSetupSheet(
                onGoToSettings: {
                    onRequestOpenSettings()
                    hasSeenOnboarding = true
                },
                onFinish: {
                    hasSeenOnboarding = true
                }
            )
            .environmentObject(viewModel)
        }
        .onAppear {
            prepareAnimations(for: page)
        }
        .onChange(of: page) { _, newPage in
            prepareAnimations(for: newPage)
        }
    }

    private var topBar: some View {
        HStack {
            if !pageHistory.isEmpty {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: LavaIconSize.control, weight: .semibold))
                        .foregroundStyle(LavaStyle.ink)
                        .frame(width: 38, height: 38)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(LavaStyle.secondaryText.opacity(0.18), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            } else {
                Color.clear
                    .frame(width: 38, height: 38)
            }

            Spacer()

            // "Import a filter" action (the old .done "Additional setup" on-ramp), shown
            // ONLY on the final page: its sheet can finish onboarding (Skip/import/settings
            // set hasSeenOnboarding), so reaching it earlier would let setup complete before
            // the VPN/notification/protection/connection steps run (Codex P2).
            if page == .done {
                Button {
                    isShowingAdditionalSetup = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import a filter")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LavaStyle.ink)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(LavaStyle.secondaryText.opacity(0.18), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Import a filter")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var currentPage: some View {
        switch page {
        case .lava:
            internetIsLavaPage
        case .guardIntro, .features:
            guardScenePage
        case .protectionLevel:
            protectionLevelPage
        case .connectionQuality:
            connectionQualityPage
        case .vpn:
            vpnPage
        case .notifications:
            notificationsPage
        case .done:
            donePage
        }
    }

    private var internetIsLavaPage: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 24)

            Text("The internet is lava")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
                .padding(.horizontal, 28)
                .padding(.top, 86)

            Text("Malicious domains are the hot spots. Your phone can step around them before apps and websites connect.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)

            Spacer(minLength: 160)
        }
    }

    private var guardScenePage: some View {
        let transition = page == .features
            ? OnboardingFeatureTransitionPlan.state(at: featureTransitionElapsed)
            : OnboardingFeatureTransitionPlan.state(at: 0)

        return ZStack(alignment: .top) {
            VStack(spacing: 22) {
                OnboardingGuardHero(blinkTrigger: guardHeroBlinkTrigger)
                    .frame(maxWidth: .infinity)
                    .frame(height: CGFloat(transition.heroHeight))
                    .offset(y: CGFloat(transition.heroPanelOffsetY))

                Text("Lava checks domain names on this phone before apps and websites connect.")
                    .font(.title3)
                    .foregroundStyle(LavaStyle.secondaryText)
                    .multilineTextAlignment(.center)
                    .opacity(transition.descriptionOpacity)
                    .clipped()
            }
            .padding(.top, CGFloat(transition.heroTopSpacer))

            if transition.featureRowsOccupyLayout {
                VStack(spacing: 12) {
                    OnboardingFeatureRow(
                        systemImage: "hand.raised.fill",
                        title: "Lava blocks your phone's access to malicious domains"
                    )
                    OnboardingFeatureRow(
                        systemImage: "lock.shield.fill",
                        title: "Local filter makes it safe, private and free"
                    )
                    OnboardingFeatureRow(
                        systemImage: "slider.horizontal.3",
                        title: "You're in full control of what gets logged locally"
                    )
                }
                .opacity(transition.featureRowsOpacity)
                .offset(y: CGFloat(transition.featureRowsOffsetY))
                .padding(.top, CGFloat(transition.featureRowsTopOffset))
            }
        }
    }

    private var protectionLevelPage: some View {
        OnboardingStepLayout(
            step: "Step 3",
            title: "Pick how much Lava blocks",
            description: "Choose your protection level. You can change this anytime in Filters.",
            contentPlacement: .centered
        ) {
            OnboardingProtectionLevelPanel(selection: $protectionLevel)
        }
    }

    private var connectionQualityPage: some View {
        OnboardingStepLayout(
            step: "Step 4",
            title: "Improve connection quality",
            description: "Stay covered if your device's DNS can't be reached after a network change.",
            contentPlacement: .centered
        ) {
            OnboardingConnectionPanel(
                useEncryptedFallback: $useEncryptedFallback,
                fallbackResolverPresetID: $fallbackResolverPresetID
            )
        }
    }

    private var vpnPage: some View {
        OnboardingStepLayout(
            step: "Step 1",
            title: "Install Lava's local VPN",
            description: "This enforces the filter and does not route traffic to a server at all",
            contentPlacement: .centered
        ) {
            // Decorative preview of the upcoming iOS system prompt — its fake "Allow"/"Don't
            // Allow" buttons are not real controls, so hide it from assistive tech. The page
            // heading + description already convey what the real prompt will ask.
            OnboardingVPNPermissionDialogIllustration()
                .accessibilityHidden(true)

            if viewModel.vpnMessageIsError, let message = viewModel.vpnMessage {
                Text(message)
                    .lavaQuietNoteText()
                    .foregroundStyle(LavaStyle.errorText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var notificationsPage: some View {
        OnboardingStepLayout(
            step: "Step 2",
            title: "Let Lava ask for help",
            description: "Turn on notifications in case Lava needs your help to unblock network issues",
            contentPlacement: .centered
        ) {
            // Decorative preview of the iOS notification prompt (fake buttons); hide from
            // assistive tech — the heading + description carry the meaning.
            OnboardingNotificationPromptCard()
                .accessibilityHidden(true)
        }
    }

    private var donePage: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 54)

            OnboardingReadyMascot()

            Text("Lava is ready")
                .font(.largeTitle.bold())
                .foregroundStyle(LavaStyle.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text("We are happy to serve you!\nThe setup is complete. You can change everything later in Settings.")
                .font(.title3)
                .foregroundStyle(LavaStyle.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        VStack(spacing: 16) {
            pageDots
            footerButtons
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .background(page == .lava ? Color.clear : LavaStyle.groupedBackground)
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingPage.allCases) { dotPage in
                Button {
                    guard visitedPages.contains(dotPage) else {
                        return
                    }
                    go(to: dotPage)
                } label: {
                    Capsule()
                        .fill(dotPage == page ? activeDotColor : inactiveDotColor)
                        .frame(width: dotPage == page ? 24 : 8, height: 8)
                }
                .buttonStyle(.plain)
                .disabled(!visitedPages.contains(dotPage))
                .accessibilityLabel("Step \(dotPage.rawValue + 1) of \(OnboardingPage.allCases.count)")
                .accessibilityAddTraits(dotPage == page ? [.isSelected] : [])
            }
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
        switch page {
        case .lava:
            OnboardingPrimaryButton(title: "Meet Lava") {
                goForward()
            }
        case .guardIntro:
            OnboardingPrimaryButton(title: "Continue") {
                goForward()
            }
        case .features:
            OnboardingPrimaryButton(title: "Set Up Protection") {
                goForward()
            }
        case .protectionLevel, .connectionQuality:
            // The choice is applied on departure (applyCurrentStepChoiceIfNeeded in go(to:)),
            // so Continue and a forward page-dot jump both persist it.
            OnboardingPrimaryButton(title: "Continue") {
                goForward()
            }
        case .vpn:
            OnboardingPrimaryButton(
                title: "Install Local VPN",
                isLoading: isInstallingVPN,
                isDisabled: viewModel.isConfiguringVPN
            ) {
                installVPNThenContinue()
            }
        case .notifications:
            HStack(spacing: 12) {
                OnboardingSecondaryButton(title: "Not Now") {
                    goForward()
                }
                OnboardingPrimaryButton(
                    title: "Enable",
                    isLoading: isRequestingNotifications
                ) {
                    requestNotificationsThenContinue()
                }
            }
        case .done:
            OnboardingPrimaryButton(title: "Open Guard") {
                hasSeenOnboarding = true
            }
        }
    }

    private var activeDotColor: Color {
        page == .lava ? .white : LavaStyle.safeGreen
    }

    private var inactiveDotColor: Color {
        page == .lava ? .white.opacity(0.28) : LavaStyle.secondaryText.opacity(0.22)
    }

    private func goForward() {
        guard let next = page.next else {
            return
        }
        go(to: next)
    }

    private func go(to nextPage: OnboardingPage) {
        guard nextPage != page else {
            return
        }

        // Persist the leaving step's surfaced choice so jumping away via the page dots
        // (which call go(to:) directly) applies it too, not just the Continue button (Codex P2).
        applyCurrentStepChoiceIfNeeded()

        // Reduce Motion: never leave the settled features layout — skipping the reset
        // here (not just in prepareAnimations) avoids even a one-frame unsettled pass
        // between the page change and the onChange-driven prepareAnimations call.
        if nextPage == .features, !reduceMotion {
            featureTransitionElapsed = 0
        }

        // The standalone "Decide how Lava works" step is gone, so its recommended
        // defaults are applied silently as setup wraps up on the final page.
        if nextPage == .done {
            viewModel.applyOnboardingRecommendedDefaults(protectionLevel: protectionLevel)
        }

        pageHistory.append(page)
        visitedPages.insert(nextPage)
        guard page != .guardIntro || nextPage != .features else {
            page = nextPage
            return
        }

        withAnimation(pageChangeAnimation) {
            page = nextPage
        }
    }

    private func goBack() {
        guard let previousPage = pageHistory.popLast() else {
            return
        }

        applyCurrentStepChoiceIfNeeded()
        visitedPages.insert(previousPage)
        withAnimation(pageChangeAnimation) {
            page = previousPage
        }
    }

    /// Reduce Motion: swap pages INSTANTLY (nil transaction). The design system's
    /// reduced-motion fade (`LavaFlowTransition.animation`) is designed to pair with its
    /// `lavaFlowTransition` modifier on the swapped content; this view has no transition
    /// modifier, so a non-nil animation would hard-swap the page content while still
    /// ANIMATING page-dependent layout (lava opacity, footer background, page-dot
    /// widths) — residual motion, the opposite of the setting's intent.
    private var pageChangeAnimation: Animation? {
        reduceMotion ? nil : LavaFlowTransition.animation(reduceMotion: false)
    }

    /// Persist the choice made on the step we're leaving. Called from every navigation
    /// path (Continue, page dots, back) so a surfaced choice is applied no matter how the
    /// user moves on — idempotent for the blocklist (no-op when unchanged).
    private func applyCurrentStepChoiceIfNeeded() {
        switch page {
        case .protectionLevel:
            viewModel.selectOnboardingBlocklists(protectionLevel.enabledBlocklistIDs())
        case .connectionQuality:
            viewModel.applyOnboardingConnectionPreferences(
                useEncryptedFallback: useEncryptedFallback,
                fallbackResolverPresetID: fallbackResolverPresetID
            )
        default:
            break
        }
    }

    private func installVPNThenContinue() {
        guard !isInstallingVPN else {
            return
        }

        Task { @MainActor in
            isInstallingVPN = true
            let didInstall = await viewModel.installLocalVPNProfileForOnboarding()
            isInstallingVPN = false
            if didInstall {
                goForward()
            }
        }
    }

    private func requestNotificationsThenContinue() {
        guard !isRequestingNotifications else {
            return
        }

        Task { @MainActor in
            isRequestingNotifications = true
            _ = await viewModel.requestProtectionNotificationAuthorizationForOnboarding()
            isRequestingNotifications = false
            goForward()
        }
    }

    private func prepareAnimations(for nextPage: OnboardingPage) {
        switch nextPage {
        case .features:
            // Reduce Motion: skip the hero-uplift choreography (and its blink)
            // and present the settled features layout directly.
            guard !reduceMotion else {
                featureTransitionElapsed = OnboardingFeatureTransitionPlan.totalDuration
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard page == .features else {
                    return
                }
                withAnimation(.easeInOut(duration: OnboardingFeatureTransitionPlan.heroMoveDuration)) {
                    featureTransitionElapsed = OnboardingFeatureTransitionPlan.heroMoveDuration
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08 + OnboardingFeatureTransitionPlan.heroMoveDuration) {
                guard page == .features else {
                    return
                }
                guardHeroBlinkTrigger += 1
                withAnimation(.easeOut(duration: OnboardingFeatureTransitionPlan.featureFadeDuration)) {
                    featureTransitionElapsed = OnboardingFeatureTransitionPlan.totalDuration
                }
            }
        default:
            featureTransitionElapsed = OnboardingFeatureTransitionPlan.totalDuration
        }
    }
}

private enum OnboardingPage: Int, CaseIterable, Identifiable {
    case lava
    case guardIntro
    case features
    case vpn
    case notifications
    case protectionLevel
    case connectionQuality
    case done

    var id: Int { rawValue }

    var next: OnboardingPage? {
        OnboardingPage(rawValue: rawValue + 1)
    }
}

private struct OnboardingGuardHero: View {
    let blinkTrigger: Int

    var body: some View {
        VStack(spacing: 14) {
            SoftShieldGuardian(size: 132, state: .awake, animates: true, blinkTrigger: blinkTrigger)

            Text("Lava stands guard here")
                .font(.largeTitle.bold())
                .foregroundStyle(LavaStyle.ink)
                .multilineTextAlignment(.center)
        }
    }
}

private struct OnboardingReadyMascot: View {
    @State private var mascotState: GuardianMascotState = .awake

    var body: some View {
        SoftShieldGuardian(size: 124, state: mascotState)
            .task {
                mascotState = .awake
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else {
                    return
                }
                mascotState = .grateful
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else {
                    return
                }
                mascotState = .awake
            }
    }
}

private enum OnboardingStepContentPlacement {
    case top
    case centered
}

private struct OnboardingStepLayout<Content: View>: View {
    let step: String
    let title: String
    let description: String
    let contentPlacement: OnboardingStepContentPlacement
    let content: Content

    init(
        step: String,
        title: String,
        description: String,
        contentPlacement: OnboardingStepContentPlacement = .top,
        @ViewBuilder content: () -> Content
    ) {
        self.step = step
        self.title = title
        self.description = description
        self.contentPlacement = contentPlacement
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            OnboardingStepHeading(
                step: step,
                title: title,
                description: description
            )

            switch contentPlacement {
            case .top:
                content
                Spacer(minLength: 0)
            case .centered:
                Spacer(minLength: 0)
                content.frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 18)
    }
}

private struct OnboardingStepHeading: View {
    let step: String
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step.lavaLocalized)
                .font(.caption.weight(.bold))
                .foregroundStyle(LavaStyle.safeGreen)
                .textCase(.uppercase)

            Text(title.lavaLocalized)
                .font(.largeTitle.bold())
                .foregroundStyle(LavaStyle.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            Text(description.lavaLocalized)
                .font(.title3)
                .foregroundStyle(LavaStyle.secondaryText)
                .lineLimit(3)
                .minimumScaleFactor(0.86)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension OnboardingProtectionLevel {
    // Short labels so the segmented control reads at full size (no shrink-to-fit). Sourced from
    // the canonical `displayName` (Core / Balanced / Extra) so the lever and the seeded filters
    // in "Your filters" always match.
    var leverTitle: LocalizedStringKey {
        LocalizedStringKey(displayName)
    }

    // Kept short (≤2 lines) so the description slot can reserve a fixed height and the
    // panel never changes size when the selection changes.
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

/// The whole Step-3 protection control as ONE coherent panel, matching the Step-2
/// permission-dialog style: a `.panel` surface (clean black/white background) with a
/// green border, a segmented selector on top whose selected pill is filled Lava control
/// green with a bold white label, the selected level's description, then the
/// constant-height "what this turns on" checklist. The panel keeps a fixed size across
/// selections — only the green pill slides, the description swaps within its reserved
/// slot, and each checklist row lights up / dims.
private struct OnboardingProtectionLevelPanel: View {
    @Binding var selection: OnboardingProtectionLevel
    @Namespace private var segmentNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The full superset of category rows (from the broadest level) so the checklist
    // keeps a constant height — only each row's enabled state changes.
    private var allGroups: [(category: BlocklistCategory, sources: [BlocklistSource])] {
        let widestIDs = OnboardingProtectionLevel.comprehensive.enabledBlocklistIDs()
        return DefaultCatalog.curatedSourcesByCategory.compactMap { entry in
            let included = entry.sources.filter { widestIDs.contains($0.id) }
            return included.isEmpty ? nil : (entry.category, included)
        }
    }

    var body: some View {
        let enabledCategories = Set(selection.enabledCategories())
        return VStack(alignment: .leading, spacing: 20) {
            segments

            Text(selection.leverSummary)
                .font(.title3)
                .foregroundStyle(LavaStyle.secondaryText)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                ForEach(allGroups, id: \.category) { group in
                    let isOn = enabledCategories.contains(group.category)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isOn ? LavaStyle.safeGreen : LavaStyle.secondaryText.opacity(0.35))
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.category.displayLabel.lavaLocalized)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(isOn ? LavaStyle.ink : LavaStyle.secondaryText)

                            Text(group.sources.map(\.name).joined(separator: ", "))
                                .font(.subheadline)
                                .foregroundStyle(LavaStyle.secondaryText.opacity(isOn ? 1 : 0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .opacity(isOn ? 1 : 0.5)
                    // The included/excluded state was conveyed only by the glyph + dimming; give
                    // VoiceOver an explicit On/Off value (icon hidden as decorative) so grayscale
                    // and non-visual users get the same meaning.
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(Text(isOn ? "On" : "Off"))
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lavaSurface(.panel, cornerRadius: 26, borderTint: LavaStyle.safeGreen)
        .animation(LavaFlowTransition.incidental(.easeInOut(duration: 0.2), reduceMotion: reduceMotion), value: selection)
    }

    private var segments: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingProtectionLevel.allCases, id: \.self) { level in
                let isSelected = selection == level
                Button {
                    withAnimation(LavaFlowTransition.incidental(.easeInOut(duration: 0.2), reduceMotion: reduceMotion)) {
                        selection = level
                    }
                } label: {
                    Text(level.leverTitle)
                        .font(.body.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .foregroundStyle(isSelected ? Color.white : LavaStyle.secondaryText)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(LavaStyle.safeControlGreen)
                                    .overlay(
                                        Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 1)
                                    )
                                    .matchedGeometryEffect(id: "selectedSegment", in: segmentNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }
}

/// Step 4 — the encrypted-fallback control, matching the Step-3 panel style: a toggle
/// (default on), a DoH provider picker (transport pinned, not surfaced), and an inline
/// privacy disclosure naming the chosen third-party resolver and that it's used only
/// transiently during recovery.
private struct OnboardingConnectionPanel: View {
    @Binding var useEncryptedFallback: Bool
    @Binding var fallbackResolverPresetID: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let providers: [DNSResolverPreset] = [
        .mullvadDoH, .cloudflareDoH, .quad9SecureDoH, .googleDoH
    ]

    private func providerName(_ preset: DNSResolverPreset) -> String {
        if preset.id == DNSResolverPreset.mullvadDoH.id { return "Mullvad" }
        if preset.id == DNSResolverPreset.cloudflareDoH.id { return "Cloudflare" }
        if preset.id == DNSResolverPreset.quad9SecureDoH.id { return "Quad9" }
        if preset.id == DNSResolverPreset.googleDoH.id { return "Google" }
        return preset.displayName
    }

    private var selectedProviderName: String {
        providerName(providers.first { $0.id == fallbackResolverPresetID } ?? .mullvadDoH)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle(isOn: $useEncryptedFallback.animation(LavaFlowTransition.incidental(.easeInOut(duration: 0.2), reduceMotion: reduceMotion))) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Encrypted fallback")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LavaStyle.ink)
                    Text("Recommended")
                        .font(.footnote)
                        .foregroundStyle(LavaStyle.secondaryText)
                }
            }
            .tint(LavaStyle.safeControlGreen)

            if useEncryptedFallback {
                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Provider")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LavaStyle.secondaryText)
                        .textCase(.uppercase)

                    VStack(spacing: 0) {
                        ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                            if index > 0 {
                                Divider()
                            }
                            providerRow(provider)
                        }
                    }
                }

                Text("If your device's DNS can't be reached, allowed requests briefly use %1$@ over an encrypted connection, then switch back automatically. %2$@ is an outside provider, used only for recovery.".lavaLocalizedFormat(selectedProviderName, selectedProviderName))
                    .font(.footnote)
                    .foregroundStyle(LavaStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lavaSurface(.panel, cornerRadius: 26, borderTint: LavaStyle.safeGreen)
        .animation(LavaFlowTransition.incidental(.easeInOut(duration: 0.2), reduceMotion: reduceMotion), value: useEncryptedFallback)
        .animation(LavaFlowTransition.incidental(.easeInOut(duration: 0.2), reduceMotion: reduceMotion), value: fallbackResolverPresetID)
    }

    private func providerRow(_ provider: DNSResolverPreset) -> some View {
        let isSelected = provider.id == fallbackResolverPresetID
        return Button {
            fallbackResolverPresetID = provider.id
        } label: {
            HStack(spacing: 12) {
                Text(providerName(provider))
                    .font(.body)
                    .foregroundStyle(LavaStyle.ink)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LavaStyle.safeControlGreen)
                }
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct OnboardingFeatureRow: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.headline.weight(.bold))
                .foregroundStyle(LavaStyle.safeGreen)
                .frame(width: 38, height: 38)
                .background(LavaStyle.softGreen, in: Circle())

            Text(title.lavaLocalized)
                .font(.headline)
                .foregroundStyle(LavaStyle.ink)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lavaSurface(.panel, cornerRadius: LavaSurface.compactCornerRadius)
    }
}

private struct OnboardingVPNPermissionDialogIllustration: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\"Lava Security\" Would Like to Add VPN Configurations")
                .font(.headline)
                .foregroundStyle(LavaStyle.ink)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline.weight(.bold))

                    Text("Allow")
                        .font(.subheadline.weight(.bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(LavaStyle.safeControlGreen, in: Capsule())

                Text("Don't Allow")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LavaStyle.secondaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(LavaStyle.secondaryText.opacity(0.14), in: Capsule())
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lavaSurface(.panel, cornerRadius: 26)
    }
}

private struct OnboardingNotificationPromptCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\"Lava Security\" Would Like to Send You Notifications")
                .font(.headline)
                .foregroundStyle(LavaStyle.ink)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                promptAction(
                    title: "Allow",
                    systemImage: "checkmark.circle.fill",
                    tint: LavaStyle.safeControlGreen,
                    isPrimary: true
                )

                promptAction(
                    title: "Allow in Scheduled Summary",
                    systemImage: nil,
                    tint: LavaStyle.secondaryText,
                    isPrimary: false
                )

                promptAction(
                    title: "Don't Allow",
                    systemImage: nil,
                    tint: Color.blue,
                    isPrimary: false
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .lavaSurface(.panel, cornerRadius: 26)
    }

    private func promptAction(title: String, systemImage: String?, tint: Color, isPrimary: Bool) -> some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.bold))
            }

            Text(title.lavaLocalized)
                .font(.headline)
        }
        .foregroundStyle(isPrimary ? .white : LavaStyle.ink)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(isPrimary ? tint : LavaStyle.secondaryText.opacity(0.14), in: Capsule())
        .overlay {
            if isPrimary {
                Capsule()
                    .stroke(.white.opacity(0.28), lineWidth: 1)
            }
        }
        .shadow(color: isPrimary ? tint.opacity(0.28) : .clear, radius: 14, y: 6)
    }
}

private struct OnboardingAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: AccountController
    @State private var isConfirmingAccountDeletion = false

    var body: some View {
        let accountConnections = account.accountConnections

        LavaSheetScaffold(spacing: 14, scrolls: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Account & Backup")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                LavaPlainCard {
                    if account.isAccountSignedIn {
                        VStack(spacing: 12) {
                            ForEach(Array(accountConnections.enumerated()), id: \.element.provider) { index, connection in
                                OnboardingSignedInAccountRow(connection: connection)

                                if index < accountConnections.count - 1 {
                                    Divider()
                                }
                            }

                            Divider()

                            Button {
                                account.signOutAccount()
                                dismiss()
                            } label: {
                                OnboardingAccountActionRow(
                                    title: "Sign out of all accounts",
                                    systemImage: "rectangle.portrait.and.arrow.right",
                                    tint: LavaStyle.ink
                                )
                            }
                            .buttonStyle(.plain)

                            Divider()

                            Button(role: .destructive) {
                                isConfirmingAccountDeletion = true
                            } label: {
                                OnboardingAccountActionRow(
                                    title: account.isAccountDeletionInProgress ? "Deleting account" : "Delete my Lava account",
                                    systemImage: "trash",
                                    tint: .red,
                                    titleTint: .red,
                                    isLoading: account.isAccountDeletionInProgress
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(account.isAccountDeletionInProgress)
                        }
                    } else {
                        VStack(spacing: 12) {
                            Button {
                                account.beginSignInWithApple()
                            } label: {
                                OnboardingAccountActionRow(
                                    title: account.appleSignInActionTitle,
                                    systemImage: "apple.logo",
                                    tint: LavaStyle.ink,
                                    isLoading: account.isAppleSignInInProgress
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(account.isAccountSignInInProgress)

                            Divider()

                            Button {
                                account.beginSignInWithGoogle()
                            } label: {
                                OnboardingAccountActionRow(
                                    title: account.googleSignInActionTitle,
                                    systemImage: "g.circle.fill",
                                    tint: LavaStyle.safeGreen,
                                    isLoading: account.isGoogleSignInInProgress
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(account.isAccountSignInInProgress)
                        }
                    }
                }
            }
        }
        .presentationDetents([.height(account.isAccountSignedIn && accountConnections.count > 1 ? 354 : account.isAccountSignedIn ? 310 : 248)])
        .presentationDragIndicator(.visible)
        .lavaConfirmationAlert { host in
            host.alert(
                "Delete your Lava account?",
                isPresented: $isConfirmingAccountDeletion
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task {
                        if await account.deleteAccount() {
                            dismiss()
                        }
                    }
                }
            } message: {
                Text("This deletes the signed-in Lava account and its encrypted backup from Lava's servers. Local protection settings stay on this device.")
            }
        }
    }
}

private struct OnboardingSignedInAccountRow: View {
    let connection: AccountAuthConnection

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 28, height: 28)

            Text(connection.email ?? "%@ account".lavaLocalizedFormat(connection.provider.displayName))
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        switch connection.provider {
        case .apple:
            Image(systemName: "apple.logo")
                .font(.title3.weight(.semibold))
                .foregroundStyle(LavaStyle.ink)
        case .google:
            Image("GoogleSignInG")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 23, height: 23)
                .accessibilityHidden(true)
        }
    }
}

private struct OnboardingAccountActionRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    var titleTint: Color = .primary
    var isLoading = false

    var body: some View {
        HStack(spacing: 12) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
            }

            Text(title.lavaLocalized)
                .font(.headline)
                .foregroundStyle(titleTint)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct OnboardingPrimaryButton: View {
    let title: String
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }

                Text(title.lavaLocalized)
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(LavaStyle.safeControlGreen, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isLoading)
        .opacity(isDisabled || isLoading ? 0.7 : 1)
    }
}

private struct OnboardingSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.lavaLocalized)
                .font(.headline)
                .foregroundStyle(LavaStyle.panelActionGreen)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .background(LavaStyle.panelActionFill, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

/// The branch off the final "Lava is ready" screen: bring in a shared setup by
/// code or QR, or jump straight to Settings. "Skip" anywhere finishes setup and
/// opens Guard as usual.
private struct OnboardingAdditionalSetupSheet: View {
    let onGoToSettings: () -> Void
    let onFinish: () -> Void

    @EnvironmentObject private var viewModel: AppViewModel
    @State private var route: Route?

    private enum Route {
        case enterCode
        case scanCode
    }

    var body: some View {
        switch route {
        case .none:
            chooser
        case .enterCode:
            ImportFiltersFlow(
                startMode: .enterCode,
                showsSkip: true,
                // Onboarding seeds the three default filters (the free cap), so "add as new" can't
                // apply here — the import becomes the active filter instead.
                allowsAddingNewFilter: false,
                onRootBack: { route = nil },
                onSkip: onFinish,
                onImported: onFinish
            )
            .environmentObject(viewModel)
        case .scanCode:
            ImportFiltersFlow(
                startMode: .scanCode,
                showsSkip: true,
                allowsAddingNewFilter: false,
                onRootBack: { route = nil },
                onSkip: onFinish,
                onImported: onFinish
            )
            .environmentObject(viewModel)
        }
    }

    private var chooser: some View {
        NavigationStack {
            LavaSheetScaffold(spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Have a setup to use? Bring it in, or open Settings to fine-tune everything yourself.")
                        .lavaSupportingText()

                    ImportOptionRow(
                        systemImage: "qrcode.viewfinder",
                        title: "Scan a QR code",
                        subtitle: "Use a setup someone shared with you"
                    ) {
                        route = .scanCode
                    }

                    ImportOptionRow(
                        systemImage: "character.cursor.ibeam",
                        title: "Enter a code",
                        subtitle: "Paste or type a config code"
                    ) {
                        route = .enterCode
                    }

                    ImportOptionRow(
                        systemImage: "gearshape",
                        title: "Go to Settings",
                        subtitle: "Open Lava's settings instead of Guard"
                    ) {
                        onGoToSettings()
                    }
                }
            }
            .navigationTitle("Additional setup".lavaLocalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip", action: onFinish)
                        .font(.headline)
                        .foregroundStyle(LavaStyle.panelActionGreen)
                }
            }
        }
    }
}

private struct OnboardingLavaFloor: View {
    var cornerRadius: CGFloat = 28
    var intensity: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate = Date.now

    var body: some View {
        Group {
            if reduceMotion {
                // Reduce Motion: hold the lava at the wave loop's first frame
                // instead of advancing the 60fps timeline.
                waves(phase: OnboardingLavaWaveTimeline.phase(at: 0))
            } else {
                TimelineView(.periodic(from: startDate, by: 1.0 / 60.0)) { timeline in
                    waves(phase: OnboardingLavaWaveTimeline.phase(
                        at: timeline.date.timeIntervalSince(startDate)
                    ))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func waves(phase: Double) -> some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [
                    LavaStyle.lavaOrange.opacity(0.86),
                    Color(red: 0.83, green: 0.08, blue: 0.02),
                    Color(red: 0.48, green: 0.02, blue: 0.01)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LavaWaveShape(phase: phase, amplitude: 18 * intensity, baseline: 0.18)
                .fill(Color(red: 1.0, green: 0.50, blue: 0.13).opacity(0.74))

            LavaWaveShape(phase: -phase + .pi * 0.35, amplitude: 22 * intensity, baseline: 0.34)
                .fill(Color(red: 0.92, green: 0.20, blue: 0.04).opacity(0.78))

            LavaWaveShape(phase: phase * 2 + .pi, amplitude: 14 * intensity, baseline: 0.48)
                .fill(Color(red: 0.55, green: 0.03, blue: 0.01).opacity(0.70))
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
    LavaOnboardingView(hasSeenOnboarding: .constant(false))
        .environmentObject(AppViewModel(loadVPNState: false))
}
