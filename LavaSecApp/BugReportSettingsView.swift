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
    private let usesPageNavigation: Bool
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
    /// Set SYNCHRONOUSLY by `submitReport()`, because `bugReportSendState` does not become
    /// `.sending` until `sendBugReport` runs — and since PR #620 there is an `await` before it,
    /// for the tunnel-health flush that carries the suppressed-failure tail. That await is a
    /// window in which the button was still enabled, so a second tap started a second task and
    /// both went on to submit (Codex P2, PR #620).
    @State private var isPreparingSubmission = false
    /// The in-flight submission, retained so a discard can CANCEL it. The task is unstructured —
    /// the sheet's `.task` cancellation does not reach it — so without this a Submit followed by
    /// "Discard feedback" during the flush await would resume and send the freshly reset draft
    /// (Codex P2, PR #620).
    @State private var isDismissed = false
    @State private var submissionTask: Task<Void, Never>?
    @AccessibilityFocusState private var isThankYouHeadingFocused: Bool

    init(
        isReportDirty: Binding<Bool> = .constant(false),
        onDismissRequested: (() -> Void)? = nil,
        usesPageNavigation: Bool = false
    ) {
        self._externalIsReportDirty = isReportDirty
        self.onDismissRequested = onDismissRequested
        self.usesPageNavigation = usesPageNavigation
    }

    var body: some View {
        Group {
            if isShowingThankYou {
                thankYouPage
            } else {
                SettingsSubpageContent(title: "Feedback", tier: .calm, spacing: SettingsSubpageLayout.feedbackSpacing) {
                    BugReportStepProgressView(
                        currentStep: currentStep,
                        furthestVisitedStep: furthestVisitedStep,
                        selectStep: goToStep
                    )
                    currentPage
                }
                .safeAreaInset(edge: .bottom) { feedbackBottomActionBar }
            }
        }
        .navigationBarBackButtonHidden(usesPageNavigation || (isReportDirty && onDismissRequested == nil))
        .toolbar {
            if usesPageNavigation || (isReportDirty && onDismissRequested == nil) {
                ToolbarItem(placement: .topBarLeading) {
                    NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Cancel", role: .cancel, action: requestDismiss)
                }
                .lavaToolbarChrome()
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
            // Forced: this is a one-shot capture, not the 5 s poll the throttle was written
            // for, and the report is the only reading of this session anyone gets. The
            // tunnel hands back its suppressed unanswered-query tail on the flush this
            // triggers (PR #620), so a throttled skip would silently truncate it.
            await viewModel.sampleReports(force: true)
            // `sampleReports()` isn't cancellation-aware, so the app may have
            // locked during the await (this task is cancelled, but execution
            // resumes). Re-check before refreshing the draft so we never rebuild
            // it above the lock — the unlock transition starts a fresh task.
            guard !Task.isCancelled, !isDismissed, !isAppUnlockMaskVisible else { return }
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
        // Mask all form content and the pinned Submit/Continue footer. The
        // rendered header is added afterward so Cancel remains reachable, like
        // the pushed page's native Back; neither action reveals or submits data.
        .overlay {
            if isAppUnlockMaskVisible {
                LavaSheetLockMask(
                    unlock: { Task { await security.authenticateAppUnlockIfNeeded() } }
                )
            }
        }
        .lavaFullSheetHeader("Feedback", isPresented: onDismissRequested != nil && !usesPageNavigation && !isShowingThankYou, leading: {
            NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Cancel", role: .cancel, action: requestDismiss)
        }, trailing: { EmptyView() })
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
            LavaSettingsIntroduction(summary: "Lava only sends feedback after you review it and tap Submit")

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

            LavaQuietFooter("Optional diagnostics include anonymized Lava Data like VPN status, network logs, and filter snapshot. They help the Lava team better investigate what went wrong.") {
                NavigationLink {
                    BugReportDiagnosticsInfoView(sections: diagnosticPreviewSections)
                } label: {
                    Text("See what information is sent".lavaLocalized)
                        .lavaQuietLinkText()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
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
        LavaSuccessScreen(title: "Feedback sent", message: thankYouTitle,
                          done: dismissAfterSubmit) {
            VStack(spacing: LavaSpacing.sm) {
                Text("Report ID:".lavaLocalized)
                    .lavaMetadataText()
                Text(submittedReportID)
                    .font(.footnote.monospaced())
                    .foregroundStyle(LavaStyle.secondaryText)
                    .textSelection(.enabled)
                Button(action: copySubmittedReportID) {
                    Text((didCopySubmittedReportID ? "Copied!" : "Copy ID").lavaLocalized)
                        .contentTransition(.identity)
                }
                .buttonStyle(LavaPanelActionButtonStyle())
                .disabled(submittedReportID.isEmpty)
            }
        }
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
                refreshDraftContext()
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
                .buttonStyle(LavaSecondaryActionButtonStyle())

                Button {
                    refreshDraftContext()
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
                .buttonStyle(LavaSecondaryActionButtonStyle())
                // PREPARATION IS PART OF SUBMITTING. This button was already disabled while
                // `.sending`; the flush await sits immediately before that and is no more
                // interruptible, so leaving Back live for those few seconds created an edit the
                // submission could not honour — the send overwrites `bugReportDraft` with the
                // bundle it sent, so the edit was silently lost (Codex P2, PR #620).
                .disabled(isPreparingSubmission || reports.bugReportSendState.isSending)

                Button {
                    submitReport()
                } label: {
                    Text(submitButtonTitle.lavaLocalized)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LavaStandaloneActionButtonStyle())
                .disabled(
                    !canContinueFromContext
                        || isPreparingSubmission
                        || reports.bugReportSendState.isSending
                        || reports.bugReportDraft == nil)
            }
        }
    }

    private func goToStep(_ step: BugReportStep) {
        // Same rule as the Back button: no step navigation once a submission is under way,
        // through the flush await as well as the send (Codex P2, PR #620).
        guard !isPreparingSubmission, !reports.bugReportSendState.isSending else {
            return
        }
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
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedIssueType = type
        }
        if type != .websiteAccess {
            affectedSite = ""
        }
        reports.resetBugReportSendState()
    }

    private func requestDismiss() {
        // ONE RULE FOR EVERY PRESENTER: no navigation out of a submission that is under way,
        // matching Back and the step progress. Cancelling here instead would be wrong in the
        // other direction — the alert's "Cancel" branch keeps the draft, and the user who takes
        // it did not ask to abandon their submit. And once the POST is on the wire no local
        // cancel retracts it anyway, so the honest fix is to not open the exit at all while a
        // report is being prepared or sent (Codex P2, PR #620).
        guard !isPreparingSubmission, !reports.bugReportSendState.isSending else {
            return
        }

        if isReportDirty {
            isShowingDiscardConfirmation = true
        } else {
            dismissAfterSubmit()
        }
    }

    private func discardAndDismiss() {
        // BEFORE the reset, so a submission still inside the flush await cannot resume against
        // the cleared draft. Cancellation alone is not enough — the task re-checks after each
        // await, because an unstructured task keeps running through a cancel until it looks.
        cancelAnyPreparingSubmission()
        isDismissed = true
        reports.discardBugReportDraft()
        dismissAfterSubmit()
    }

    private func cancelAnyPreparingSubmission() {
        submissionTask?.cancel()
        submissionTask = nil
        isPreparingSubmission = false
    }

    private func dismissAfterSubmit() {
        isDismissed = true
        externalIsReportDirty = false
        if let onDismissRequested {
            onDismissRequested()
        } else {
            dismiss()
        }
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
        // Both synchronous, before the Task: the guard closes the double-tap window even if the
        // button's disabled state has not been re-evaluated yet.
        guard !isPreparingSubmission else {
            return
        }
        isPreparingSubmission = true
        didCopySubmittedReportID = false
        // SNAPSHOT THE REVIEWED DRAFT AT THE TAP, so what was reviewed is what is sent. Back and
        // the step progress are frozen for the duration (see their guards), which is the primary
        // fix; this is the defence in depth, and it is what a pin can assert. Reading
        // `currentContext` after the await would submit content that never passed through Review
        // or `canContinueFromContext` (Codex P2, PR #620).
        let reviewedContext = currentContext
        let feedbackID = LavaFeedbackCoordinator.shared.begin("feedback.send")
        submissionTask = Task {
            defer {
                isPreparingSubmission = false
                submissionTask = nil
            }
            // Re-sample BEFORE the draft is rebuilt, not only on sheet appearance. The whole
            // point of leaving Feedback open is to reproduce the failure with the sheet up, and
            // everything that happens while it is open is held by the tunnel's 30 s suppressor
            // until something flushes it — so submitting inside the poll window would send a
            // report describing the reproduction with the reproduction's own tail missing
            // (Codex P2, PR #620). Forced for the same reason the appearance sample is: this is
            // a one-shot capture, not the 5 s poll the throttle was written for.
            await viewModel.sampleReports(force: true)
            // Re-checked because `sampleReports` is not cancellation-aware: a discard during the
            // flush cancels this task, but execution still resumes here, and rebuilding the draft
            // would recreate the report the user just threw away — then send it.
            guard !Task.isCancelled else {
                return
            }
            refreshDraft(context: reviewedContext)
            await reports.sendBugReport(context: reviewedContext)
            if case .sent = reports.bugReportSendState {
                LavaFeedbackCoordinator.shared.finish("feedback.send", feedbackID, .succeeded)
                isShowingThankYou = true
            } else if case .failed = reports.bugReportSendState {
                LavaFeedbackCoordinator.shared.finish("feedback.send", feedbackID, .failed)
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

    /// - Parameter context: the draft to build, defaulting to whatever is on screen NOW. The
    ///   submit path passes the context it snapshotted at the tap instead, because the fields can
    ///   change during its await — see `submitReport()`.
    private func refreshDraft(context: BugReportContext? = nil) {
        reports.prepareBugReport(context: context ?? currentContext)
    }

    private func refreshDraftContext() {
        guard !isDismissed else { return }
        reports.refreshBugReportDraftContext(context: currentContext)
    }

    private func syncReportDirtyState() {
        externalIsReportDirty = isReportDirty
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
/// Internal, not private: the Device QA sheet presents the same way (above RootView's
/// overlays) and holds a pasted WireGuard private key, so it needs the identical mask.
/// One implementation rather than two, for the reason every duplicated guard in this
/// codebase has eventually earned — two copies of a privacy mask drift, and the drift is
/// invisible until a snapshot carries something it should not.
struct LavaSheetLockMask: View {
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
        .accessibilityIdentifier("sheetLockMask")
    }
}

private struct BugReportTopicOptionRow: View, Equatable {
    let title: String
    let isSelected: Bool

    var body: some View {
        LavaSelectableRow(state: isSelected ? .selected : .unselected) {
            Text(title.lavaLocalized)
                .lavaRowTitleText()
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                        BugReportReviewRow(label: "Details", value: "VPN status, network kind, resolver status, failure counters".lavaLocalized)
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
        LavaStepNavigation(
            steps: BugReportStep.allCases,
            title: { "\($0.displayNumber) \($0.title.lavaLocalized)" },
            isSelected: { $0 == currentStep },
            isEnabled: { !isUnavailableStep($0) },
            select: selectStep)
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
                        LavaDiagnosticValueRow(title: item.label, value: item.value)
                    }
                }
            }
        }
    }
}
