import SwiftUI
import LavaSecKit
import LavaSecAppServices
import UIKit

private enum BugReportStep: Int, CaseIterable, Identifiable {
    case topic
    case context
    case review

    var id: Int { rawValue }
    var stepNumber: Int { rawValue + 1 }
    var displayNumber: String {
        switch self {
        case .topic:
            "1."
        case .context:
            "2."
        case .review:
            "3."
        }
    }

    var title: String {
        switch self {
        case .topic:
            "Topic"
        case .context:
            "Details"
        case .review:
            "Review"
        }
    }
}

struct BugReportSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: AppViewModel
    // The diagnostics scope (Phase D4 peel): the bug-report draft + send state machine lives here.
    @EnvironmentObject private var reports: DiagnosticsController
    @EnvironmentObject private var security: SecurityController
    @Binding private var externalIsReportDirty: Bool
    private let onDismissRequested: (() -> Void)?
    @State private var selectedIssueType: BugReportIssueType?
    @State private var affectedSite = ""
    @State private var details = ""
    @State private var contactEmail = ""
    @State private var includeDiagnostics = false
    @State private var currentStep: BugReportStep = .topic
    @State private var furthestVisitedStep: BugReportStep = .topic
    @State private var isShowingDiscardConfirmation = false
    @State private var isShowingThankYou = false
    @State private var didCopySubmittedReportID = false

    init(
        isReportDirty: Binding<Bool> = .constant(false),
        onDismissRequested: (() -> Void)? = nil
    ) {
        self._externalIsReportDirty = isReportDirty
        self.onDismissRequested = onDismissRequested
    }

    var body: some View {
        SettingsSubpageContent(title: "Feedback", tier: .calm, spacing: SettingsSubpageLayout.feedbackSpacing, scrolls: !isShowingThankYou) {
            if isShowingThankYou {
                thankYouPage
            } else {
                BugReportStepProgressView(
                    currentStep: currentStep,
                    furthestVisitedStep: furthestVisitedStep,
                    selectStep: goToStep
                )
                currentPage
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isShowingThankYou {
                thankYouBottomActionBar
            } else {
                feedbackBottomActionBar
            }
        }
        .navigationBarBackButtonHidden(isReportDirty && onDismissRequested == nil)
        .toolbar {
            if isReportDirty && onDismissRequested == nil {
                ToolbarItem(placement: .topBarLeading) {
                    NativeToolbarIconButton(systemName: "chevron.left", accessibilityLabel: "Back", action: requestDismiss)
                }
            }

            if onDismissRequested != nil && !isShowingThankYou {
                ToolbarItem(placement: .cancellationAction) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Cancel", role: .cancel, action: requestDismiss)
                }
            }
        }
        .lavaConfirmationAlert { host in
            host.alert("Discard feedback?", isPresented: $isShowingDiscardConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Discard", role: .destructive) {
                    discardAndDismiss()
                }
            } message: {
                Text("Your feedback draft will be removed.")
            }
        }
        .task(id: isAppUnlockMaskVisible) {
            // Don't sample device diagnostics (connectivity/health/network log)
            // while the content is masked for App Unlock; re-sample once the mask
            // drops on unlock so the draft carries fresh, post-unlock diagnostics.
            guard !isAppUnlockMaskVisible else { return }
            await viewModel.sampleReports()
            // `sampleReports()` isn't cancellation-aware, so the app may have
            // locked during the await (this task is cancelled, but execution
            // resumes). Re-check before refreshing the draft so we never rebuild
            // it above the lock — the unlock transition starts a fresh task.
            guard !Task.isCancelled, !isAppUnlockMaskVisible else { return }
            refreshDraft()
            syncReportDirtyState()
        }
        .onDisappear {
            externalIsReportDirty = false
        }
        .onChange(of: selectedIssueType) { _, newValue in
            if newValue != .websiteAccess && !affectedSite.isEmpty {
                affectedSite = ""
            }
            refreshDraftContext()
            syncReportDirtyState()
        }
        .onChange(of: affectedSite) { _, _ in reportInputChanged() }
        .onChange(of: details) { _, _ in reportInputChanged() }
        .onChange(of: contactEmail) { _, _ in reportInputChanged() }
        .onChange(of: includeDiagnostics) { _, _ in reportInputChanged() }
        .onChange(of: isShowingThankYou) { _, _ in syncReportDirtyState() }
        // Opaque, hit-blocking mask over the WHOLE sheet (form + bottom action
        // bar) while App Unlock is pending or the privacy mask is up. Placed as
        // the last modifier so it composes over `.safeAreaInset` (the Submit /
        // Continue bar) — content stays unreadable and unsubmittable above the
        // lock overlay. The toolbar Cancel/Back buttons live in nav chrome above
        // this overlay and are intentionally left reachable: they only dismiss
        // (never reveal or submit content).
        .overlay {
            if isAppUnlockMaskVisible {
                BugReportSheetLockMask(
                    unlock: { Task { await security.authenticateAppUnlockIfNeeded() } }
                )
            }
        }
    }

    @ViewBuilder
    private var currentPage: some View {
        switch currentStep {
        case .topic:
            topicPage
        case .context:
            contextPage
        case .review:
            reviewPage
        }
    }

    private var topicPage: some View {
        VStack(spacing: 18) {
            LavaInfoPanel(
                title: "No silent telemetry",
                description: "Lava only sends feedback after you review it and tap Submit",
                systemImage: "ladybug"
            )

            LavaSectionGroup("Choose a topic") {
                LavaCondensedList {
                    ForEach(Array(BugReportIssueType.allCases.enumerated()), id: \.element.id) { index, type in
                        Button {
                            selectIssueType(type)
                        } label: {
                            EquatableView(content: BugReportTopicOptionRow(
                                title: type.title,
                                isSelected: selectedIssueType == type
                            ))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedIssueType == type ? [.isSelected] : [])

                        if index < BugReportIssueType.allCases.count - 1 {
                            LavaCondensedDivider()
                        }
                    }
                }
            }
        }
    }

    private var contextPage: some View {
        VStack(spacing: 18) {
            LavaSectionGroup("Tell us more") {
                VStack(spacing: 10) {
                    LavaTextInputPanel {
                        if selectedIssueType == .websiteAccess {
                            LavaTextInputRow(title: "Site or domain") {
                                TextField("Site or domain".lavaLocalized, text: $affectedSite)
                                    .lavaTextInputBody(keyboardType: .URL)
                                    // Implicit cap for the URL field — enforced silently, no counter (UR-29).
                                    .onChange(of: affectedSite) { _, newValue in
                                        if newValue.count > BugReportInputLimits.affectedSite {
                                            affectedSite = String(newValue.prefix(BugReportInputLimits.affectedSite))
                                        }
                                    }
                            }

                            Divider()
                        }

                        // Details carries an explicit live counter; the others stay implicit (UR-29).
                        LavaTextEditorInputRow(
                            title: "Details",
                            text: $details,
                            placeholder: "What were you trying to do? What did Lava do instead?",
                            characterLimit: BugReportInputLimits.details
                        )

                        Divider()

                        LavaTextInputRow(title: "Email for follow-up (optional)") {
                            TextField("Email for follow-up (optional)".lavaLocalized, text: $contactEmail)
                                .lavaTextInputBody(keyboardType: .emailAddress)
                                // Implicit cap for the email field — enforced silently, no counter (UR-29).
                                .onChange(of: contactEmail) { _, newValue in
                                    if newValue.count > BugReportInputLimits.contactEmail {
                                        contactEmail = String(newValue.prefix(BugReportInputLimits.contactEmail))
                                    }
                                }
                        }
                    }

                    Toggle("Include optional diagnostic", isOn: $includeDiagnostics)
                        .font(.headline)
                        .tint(LavaStyle.safeGreen)
                        .lavaControlRowCard()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Optional diagnostics include anonymized Lava Data like VPN status, network logs, and filter snapshot. They help the Lava team better investigate what went wrong.")
                    .lavaQuietNoteText()

                NavigationLink {
                    BugReportDiagnosticsInfoView(sections: diagnosticPreviewSections)
                } label: {
                    Text("See what information is sent".lavaLocalized)
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LavaStyle.safeGreen)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var reviewPage: some View {
        VStack(spacing: 18) {
            LavaSectionGroup("Review and submit") {
                VStack(spacing: 10) {
                    // Mirror the "Tell us more" panel layout (stacked label-above-value rows in
                    // a single card) so the review reads as a read-only echo of what was typed,
                    // instead of every field claiming its own fixed-width header column (UR-26).
                    LavaTextInputPanel {
                        BugReportReviewRow(label: "Topic", value: selectedIssueType.map { $0.title.lavaLocalized } ?? "Not selected".lavaLocalized)

                        if selectedIssueType == .websiteAccess {
                            Divider()

                            BugReportReviewRow(label: "Site or domain", value: normalizedAffectedSite)
                        }

                        Divider()

                        BugReportReviewRow(label: "Details", value: normalizedDetails.isEmpty ? "Not provided".lavaLocalized : normalizedDetails)

                        Divider()

                        BugReportReviewRow(label: "Email", value: normalizedContactEmail.isEmpty ? "Not provided".lavaLocalized : normalizedContactEmail)

                        Divider()

                        BugReportReviewRow(label: "Diagnostics", value: includeDiagnostics ? "Sent".lavaLocalized : "Not sent".lavaLocalized)
                    }
                }
            }

            bugReportStatusView
        }
    }

    private var thankYouPage: some View {
        VStack(spacing: 20) {
            FeedbackThankYouMascot()

            VStack(spacing: 12) {
                Text(thankYouTitle.lavaLocalized)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 6) {
                    Text("Report ID:".lavaLocalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LavaStyle.secondaryText)

                    Text(submittedReportID)
                        .font(.footnote.monospaced())
                        .foregroundStyle(LavaStyle.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var thankYouBottomActionBar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                Button {
                    copySubmittedReportID()
                } label: {
                    Text((didCopySubmittedReportID ? "Copied!" : "Copy ID").lavaLocalized)
                        .contentTransition(.identity)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LavaPanelActionButtonStyle())
                .disabled(submittedReportID.isEmpty)

                Button {
                    dismissAfterSubmit()
                } label: {
                    Text("Done".lavaLocalized)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LavaStandaloneActionButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(LavaStyle.groupedBackground)
    }

    @ViewBuilder
    private var feedbackBottomActionBar: some View {
        VStack(spacing: 0) {
            Divider()

            feedbackBottomActionButtons
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .background(LavaStyle.groupedBackground)
    }

    @ViewBuilder
    private var feedbackBottomActionButtons: some View {
        switch currentStep {
        case .topic:
            Button {
                refreshDraft()
                markStepVisited(.context)
                currentStep = .context
            } label: {
                Text("Continue".lavaLocalized)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(LavaStandaloneActionButtonStyle())
            .disabled(selectedIssueType == nil)
        case .context:
            HStack(spacing: 12) {
                Button {
                    moveBack()
                } label: {
                    Text("Back".lavaLocalized)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LavaSecondaryActionButtonStyle(disabledOpacity: 0.55))

                Button {
                    refreshDraft()
                    markStepVisited(.review)
                    currentStep = .review
                } label: {
                    Text("Review".lavaLocalized)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LavaStandaloneActionButtonStyle())
                .disabled(!canContinueFromContext)
            }
        case .review:
            HStack(spacing: 12) {
                Button {
                    moveBack()
                } label: {
                    Text("Back".lavaLocalized)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LavaSecondaryActionButtonStyle(disabledOpacity: 0.55))
                .disabled(reports.bugReportSendState.isSending)

                Button {
                    submitReport()
                } label: {
                    Text(submitButtonTitle.lavaLocalized)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LavaStandaloneActionButtonStyle())
                .disabled(!canContinueFromContext || reports.bugReportSendState.isSending || reports.bugReportDraft == nil)
            }
        }
    }

    private func goToStep(_ step: BugReportStep) {
        guard step.rawValue <= furthestVisitedStep.rawValue else {
            return
        }

        currentStep = step
    }

    private func markStepVisited(_ step: BugReportStep) {
        if step.rawValue > furthestVisitedStep.rawValue {
            furthestVisitedStep = step
        }
    }

    private func moveBack() {
        switch currentStep {
        case .topic:
            break
        case .context:
            currentStep = .topic
        case .review:
            currentStep = .context
        }
    }

    @ViewBuilder
    private var bugReportStatusView: some View {
        switch reports.bugReportSendState {
        case .idle, .sent, .sending:
            EmptyView()
        case .failed(let message):
            LavaInfoPanel(
                title: "Could not send feedback",
                description: message,
                systemImage: "exclamationmark.triangle.fill",
                tint: LavaStyle.lavaOrange
            )
        }
    }

    private func selectIssueType(_ type: BugReportIssueType) {
        selectedIssueType = type
        if type != .websiteAccess {
            affectedSite = ""
        }
        reports.resetBugReportSendState()
    }

    private func requestDismiss() {
        if isReportDirty {
            isShowingDiscardConfirmation = true
        } else {
            dismissAfterSubmit()
        }
    }

    private func discardAndDismiss() {
        resetReport()
        dismissAfterSubmit()
    }

    private func dismissAfterSubmit() {
        externalIsReportDirty = false
        if let onDismissRequested {
            onDismissRequested()
        } else {
            dismiss()
        }
    }

    private func resetReport() {
        selectedIssueType = nil
        affectedSite = ""
        details = ""
        contactEmail = ""
        includeDiagnostics = false
        currentStep = .topic
        furthestVisitedStep = .topic
        isShowingThankYou = false
        didCopySubmittedReportID = false
        reports.resetBugReportSendState()
        refreshDraft()
        syncReportDirtyState()
    }

    private func reportInputChanged() {
        reports.resetBugReportSendState()
        // Typing only changes the user-entered context; reuse the environment
        // snapshot captured on appear/step-change instead of rebuilding the
        // whole diagnostics bundle on every keystroke (UR-5: Feedback typing lag).
        refreshDraftContext()
        syncReportDirtyState()
    }

    private func submitReport() {
        refreshDraft()
        didCopySubmittedReportID = false
        Task {
            await reports.sendBugReport(context: currentContext)
            if case .sent = reports.bugReportSendState {
                isShowingThankYou = true
            }
        }
    }

    private var currentContext: BugReportContext {
        BugReportContext(
            issueType: selectedIssueType ?? .other,
            affectedSite: selectedIssueType == .websiteAccess ? affectedSite : "",
            details: details,
            contactEmail: contactEmail,
            includeDiagnostics: includeDiagnostics
        )
    }

    private func copySubmittedReportID() {
        guard !submittedReportID.isEmpty else {
            return
        }

        UIPasteboard.general.string = submittedReportID
        ProtectionHapticFeedback.play(.selectionConfirmed)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            didCopySubmittedReportID = UIPasteboard.general.string == submittedReportID
        }
    }

    /// True while the sheet's content must be hidden behind the in-sheet lock
    /// mask: when App Unlock is pending (locked device) OR the app-switcher
    /// privacy mask is up (`.inactive`, before `.background` flips the lock).
    /// Keying on the privacy-mask flag too closes the app-switcher-snapshot gap —
    /// the bug-report sheet presents above RootView's privacy/lock overlays, so
    /// those don't cover it and this view must mask itself.
    private var isAppUnlockMaskVisible: Bool {
        security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible
    }

    private var isReportDirty: Bool {
        guard !isShowingThankYou else {
            return false
        }

        return selectedIssueType != nil
            || !affectedSite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !contactEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || includeDiagnostics
    }

    private var canContinueFromContext: Bool {
        selectedIssueType != nil
            && !normalizedDetails.isEmpty
            && (selectedIssueType != .websiteAccess || !normalizedAffectedSite.isEmpty)
    }

    // Route through the same BugReportContext normalization used by makeRequestBody so the
    // review screen and the continue/submit validation reflect exactly what will be sent —
    // including the sanitization that strips zero-width / control / bidi characters. Trimming
    // alone would let an all-zero-width "Details" look non-empty here yet submit empty (UR-29).
    private var normalizedAffectedSite: String {
        currentContext.normalizedAffectedSite
    }

    private var normalizedDetails: String {
        currentContext.normalizedDetails
    }

    private var normalizedContactEmail: String {
        currentContext.normalizedContactEmail ?? ""
    }

    private var diagnosticPreviewSections: [BugReportPreviewSection] {
        reports.bugReportDraft?.previewSections.filter { $0.id != "context" } ?? []
    }

    private var thankYouTitle: String {
        if normalizedContactEmail.isEmpty {
            return "Thank you, Lava will look into this"
        }

        return "Thank you, Lava will look into this and reach out if needed"
    }

    private var submittedReportID: String {
        if case .sent(let reportID) = reports.bugReportSendState {
            return reportID
        }

        return ""
    }

    private var submitButtonTitle: String {
        switch reports.bugReportSendState {
        case .failed:
            "Retry"
        case .sending:
            "Submitting"
        case .idle, .sent:
            "Submit"
        }
    }

    private func refreshDraft() {
        reports.prepareBugReport(context: currentContext)
    }

    private func refreshDraftContext() {
        reports.refreshBugReportDraftContext(context: currentContext)
    }

    private func syncReportDirtyState() {
        externalIsReportDirty = isReportDirty
    }
}

private struct FeedbackThankYouMascot: View {
    @EnvironmentObject private var customization: CustomizationController
    @State private var mascotState: GuardianMascotState = .awake

    var body: some View {
        SoftShieldGuardian(size: 96, state: mascotState, shieldStyle: customization.lavaGuardLook)
            .task {
                mascotState = .awake
                try? await Task.sleep(nanoseconds: 550_000_000)
                guard !Task.isCancelled else { return }
                mascotState = .grateful
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                mascotState = .awake
            }
    }
}

/// Opaque, hit-blocking cover for the bug-report sheet while App Unlock is
/// pending. The sheet stays mounted (so an in-progress draft survives), and this
/// mask hides its content above the lock overlay. It uses an OPAQUE fill (never
/// translucent `.regularMaterial`) so the draft can't bleed through, swallows all
/// taps/scroll/keyboard hits via `contentShape`, and is an `.isModal`
/// accessibility container so VoiceOver can't reach the masked fields underneath.
///
/// It mirrors `SecurityLockOverlay` and carries its OWN "Unlock Lava" button:
/// the root lock overlay renders *behind* this window-level sheet and the sheet
/// can't be swiped away while the draft is dirty, so without an in-mask unlock
/// affordance a user who cancels the passcode prompt would be stuck (forced to
/// discard the draft). Tapping it re-surfaces the App Unlock prompt.
private struct BugReportSheetLockMask: View {
    let unlock: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(LavaStyle.groupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: LavaIconSize.hero, weight: .semibold))
                    .foregroundStyle(LavaStyle.safeGreen)

                Text("Lava Locked")
                    .font(.title.bold())

                Button("Unlock Lava", action: unlock)
                    .buttonStyle(.borderedProminent)
                    .tint(LavaStyle.safeControlGreen)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("bugReportSheetLockMask")
    }
}

private struct BugReportTopicOptionRow: View, Equatable {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(isSelected ? LavaStyle.safeGreen : LavaStyle.secondaryText)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            Text(title.lavaLocalized)
                .lavaRowTitleText()
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct BugReportReviewRow: View {
    let label: String
    let value: String

    var body: some View {
        // Reuse the editable screen's row scaffold (label stacked above the value) so the
        // review echo lines up pixel-for-pixel with "Tell us more", just read-only (UR-26).
        LavaTextInputRow(title: label) {
            Text(value)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct BugReportDiagnosticsInfoView: View {
    let sections: [BugReportPreviewSection]

    var body: some View {
        SettingsSubpageContent(
            title: "Information Sent",
            tier: .technical,
            intro: LavaInfoPanel(
                title: "Diagnostics",
                description: "These examples show the technical summary Lava can send when you turn on optional diagnostics",
                systemImage: "doc.text.magnifyingglass"
            )
        ) {
            LavaSectionGroup("Information sent") {
                if sections.isEmpty {
                    LavaPlainCard {
                        Text("Lava will show App & Device, VPN Status, Tunnel Lifecycle, Network & Resolver Health, Filter Snapshot, and Local Activity Summary when a local summary is ready.")
                            .lavaRowSubtitleText()
                    }
                } else {
                    VStack(spacing: 10) {
                        ForEach(sections) { section in
                            BugReportPreviewSectionCard(section: section)
                        }
                    }
                }
            }

            LavaSectionGroup(
                "Lifecycle log examples",
                footer: "Lifecycle entries use safe event names and counters. Recent DNS and domain events are not included."
            ) {
                LavaPlainCard {
                    VStack(alignment: .leading, spacing: 10) {
                        BugReportReviewRow(label: "App", value: "enable-begin, enable-finished, reconnect-requested")
                        Divider()
                        BugReportReviewRow(label: "Tunnel", value: "startTunnel-ready, network-path-changed, resolver-reset")
                        Divider()
                        BugReportReviewRow(label: "Details", value: "VPN status, network kind, resolver status, failure counters")
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BugReportStepProgressView: View {
    let currentStep: BugReportStep
    let furthestVisitedStep: BugReportStep
    let selectStep: (BugReportStep) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(BugReportStep.allCases) { step in
                if isUnavailableStep(step) {
                    stepLabel(for: step)
                } else {
                    Button {
                        selectStep(step)
                    } label: {
                        stepLabel(for: step)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func stepLabel(for step: BugReportStep) -> some View {
        Text("\(step.displayNumber) \(step.title.lavaLocalized)")
            // Current step also carries a heavier weight — a non-color cue so the active step
            // survives grayscale, not just the selection tint swap.
            .font(.caption.weight(step == currentStep ? .heavy : .semibold))
            .foregroundStyle(isUnavailableStep(step) ? LavaStyle.tertiaryText : Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .lavaSurface(.selection(isSelected: step == currentStep))
            .opacity(isUnavailableStep(step) ? 0.55 : 1)
            .contentShape(Rectangle())
            .accessibilityAddTraits(step == currentStep ? [.isSelected] : [])
    }

    private func isUnavailableStep(_ step: BugReportStep) -> Bool {
        step.rawValue > furthestVisitedStep.rawValue
    }
}

private struct BugReportPreviewSectionCard: View {
    let section: BugReportPreviewSection

    var body: some View {
        LavaPlainCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.title.lavaLocalized)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(section.purpose.lavaLocalized)
                        .lavaRowSubtitleText()
                }

                Divider()

                VStack(spacing: 8) {
                    ForEach(section.items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Text(item.label.lavaLocalized)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(LavaStyle.secondaryText)
                                .frame(width: 110, alignment: .leading)

                            Text(item.value)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
