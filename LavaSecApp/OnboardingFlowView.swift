import SwiftUI
import LavaSecCore

struct LavaOnboardingView: View {
    @Binding var hasSeenOnboarding: Bool
    /// Invoked when the user finishes setup via "Go to Settings" so the host can
    /// land them on the Settings tab instead of Guard.
    var onRequestOpenSettings: () -> Void = {}
    @EnvironmentObject private var viewModel: AppViewModel

    @State private var page: OnboardingPage = .lava
    @State private var pageHistory: [OnboardingPage] = []
    @State private var visitedPages: Set<OnboardingPage> = [.lava]
    @State private var featureTransitionElapsed = OnboardingFeatureTransitionPlan.totalDuration
    @State private var guardHeroBlinkTrigger = 0
    @State private var isInstallingVPN = false
    @State private var isRequestingNotifications = false
    @State private var isShowingAdditionalSetup = false

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
                LavaToolbarIconButton(systemName: "chevron.left", accessibilityLabel: "Back", action: goBack)
            } else {
                Color.clear
                    .frame(width: 44, height: 44)
            }

            Spacer()

            Color.clear
                .frame(width: 44, height: 44)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var currentPage: some View {
        switch page {
        case .lava:
            internetIsLavaPage
        case .guardIntro, .features:
            guardScenePage
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

    private var vpnPage: some View {
        OnboardingStepLayout(
            step: "Step 1",
            title: "Install Lava's local VPN",
            description: "This enforces the filter and does not route traffic to a server at all",
            contentPlacement: .centered
        ) {
            OnboardingVPNPermissionDialogIllustration()

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
            OnboardingNotificationPromptCard()
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
                .accessibilityLabel("Step \(dotPage.rawValue + 1)")
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
            VStack(spacing: 12) {
                OnboardingPrimaryButton(title: "Open Guard") {
                    hasSeenOnboarding = true
                }
                OnboardingSecondaryButton(title: "Additional setup") {
                    isShowingAdditionalSetup = true
                }
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

        if nextPage == .features {
            featureTransitionElapsed = 0
        }

        // The standalone "Decide how Lava works" step is gone, so its recommended
        // defaults are applied silently as setup wraps up on the final page.
        if nextPage == .done {
            viewModel.applyOnboardingRecommendedDefaults()
        }

        pageHistory.append(page)
        visitedPages.insert(nextPage)
        guard page != .guardIntro || nextPage != .features else {
            page = nextPage
            return
        }

        withAnimation(.easeInOut(duration: 0.22)) {
            page = nextPage
        }
    }

    private func goBack() {
        guard let previousPage = pageHistory.popLast() else {
            return
        }

        visitedPages.insert(previousPage)
        withAnimation(.easeInOut(duration: 0.22)) {
            page = previousPage
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
            Text(step.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(LavaStyle.safeGreen)
                .textCase(.uppercase)

            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(LavaStyle.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(description)
                .font(.title3)
                .foregroundStyle(LavaStyle.secondaryText)
                .lineLimit(3)
                .minimumScaleFactor(0.86)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

            Text(title)
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

            Text(title)
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
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var isConfirmingAccountDeletion = false

    var body: some View {
        let accountConnections = viewModel.accountConnections

        LavaSheetScaffold(spacing: 14, scrolls: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Account & Backup")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                LavaPlainCard {
                    if viewModel.isAccountSignedIn {
                        VStack(spacing: 12) {
                            ForEach(Array(accountConnections.enumerated()), id: \.element.provider) { index, connection in
                                OnboardingSignedInAccountRow(connection: connection)

                                if index < accountConnections.count - 1 {
                                    Divider()
                                }
                            }

                            Divider()

                            Button {
                                viewModel.signOutAccount()
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
                                    title: viewModel.isAccountDeletionInProgress ? "Deleting account" : "Delete my Lava account",
                                    systemImage: "trash",
                                    tint: .red,
                                    titleTint: .red,
                                    isLoading: viewModel.isAccountDeletionInProgress
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isAccountDeletionInProgress)
                        }
                    } else {
                        VStack(spacing: 12) {
                            Button {
                                viewModel.beginSignInWithApple()
                            } label: {
                                OnboardingAccountActionRow(
                                    title: viewModel.appleSignInActionTitle,
                                    systemImage: "apple.logo",
                                    tint: LavaStyle.ink,
                                    isLoading: viewModel.isAppleSignInInProgress
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isAccountSignInInProgress)

                            Divider()

                            Button {
                                viewModel.beginSignInWithGoogle()
                            } label: {
                                OnboardingAccountActionRow(
                                    title: viewModel.googleSignInActionTitle,
                                    systemImage: "g.circle.fill",
                                    tint: LavaStyle.safeGreen,
                                    isLoading: viewModel.isGoogleSignInInProgress
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isAccountSignInInProgress)
                        }
                    }
                }
            }
        }
        .presentationDetents([.height(viewModel.isAccountSignedIn && accountConnections.count > 1 ? 354 : viewModel.isAccountSignedIn ? 310 : 248)])
        .presentationDragIndicator(.visible)
        .lavaConfirmationAlert { host in
            host.alert(
                "Delete your Lava account?",
                isPresented: $isConfirmingAccountDeletion
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task {
                        if await viewModel.deleteAccount() {
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

            Text(connection.email ?? "\(connection.provider.displayName) account")
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

            Text(title)
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

                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
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
            Text(title)
                .font(.headline)
                .foregroundStyle(LavaStyle.panelActionGreen)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
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
                onRootBack: { route = nil },
                onSkip: onFinish,
                onImported: onFinish
            )
            .environmentObject(viewModel)
        case .scanCode:
            ImportFiltersFlow(
                startMode: .scanCode,
                showsSkip: true,
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
    @State private var startDate = Date.now

    var body: some View {
        TimelineView(.periodic(from: startDate, by: 1.0 / 60.0)) { timeline in
            let phase = OnboardingLavaWaveTimeline.phase(
                at: timeline.date.timeIntervalSince(startDate)
            )

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
    LavaOnboardingView(hasSeenOnboarding: .constant(false))
        .environmentObject(AppViewModel(loadVPNState: false))
}
