import Foundation
import UIKit
import LavaSecKit
import LavaSecAppServices

@MainActor
final class LavaFeedbackVisit {
    let id: UUID
    var draft = FeedbackDraftSession()
    var sampleRevision = 0
    var error = ""
    var receipt = ""
    var copied = false
    init(id: UUID) { self.id = id }
}

extension LavaAppBridge {
    func feedbackOwner(_ id: UUID) -> LavaFeedbackVisit {
        if let feedbackVisit, feedbackVisit.id == id { return feedbackVisit }
        feedbackVisit?.draft.retire()
        let visit = LavaFeedbackVisit(id: id); feedbackVisit = visit; return visit
    }
    func retireFeedback(_ id: UUID) {
        guard feedbackVisit?.id == id else { return }
        feedbackVisit?.draft.retire(); feedbackVisit = nil
        feedbackDraftIsDirty = false
        // An accepted POST may complete after forced navigation. Do not reset
        // its service state or make a replacement form eligible to send twice.
        if !model.reports.bugReportSendState.isSending { model.reports.discardBugReportDraft() }
    }
    func feedbackProjection(_ flow: LavaAppNativeFlow) -> [String: Any] {
        let visit = feedbackOwner(flow.id); let draft = visit.draft; let context = draft.context
        return ["topic": draft.topic?.rawValue ?? "", "site": draft.site, "details": draft.details, "email": draft.email,
            "diagnostics": draft.diagnostics, "step": draft.step, "furthest": draft.furthest,
            "revision": String(draft.revision), "review": draft.reviewRevision.map(String.init) ?? "",
            "normalizedSite": context.normalizedAffectedSite, "normalizedDetails": context.normalizedDetails,
            "normalizedEmail": context.normalizedContactEmail ?? "", "count": draft.details.count,
            "canContinue": draft.validContext, "dirty": draft.dirty,
            "busy": !draft.canDismiss || model.reports.bugReportSendState.isSending,
            "prepared": model.reports.bugReportDraft != nil, "sent": draft.phase == .sent,
            "error": visit.error, "receipt": visit.receipt, "copied": visit.copied,
            "topics": BugReportIssueType.allCases.map { ["id": $0.rawValue, "title": $0.title.lavaLocalized] }]
    }
    func feedbackCommand(_ action: String, _ input: [String: Any]) async throws -> Any {
        guard let flow, flow.name == "feedback", input["id"] as? String == flow.id.uuidString else { throw CommandError("The app screen closed before this action started.") }
        let visit = feedbackOwner(flow.id)
        try await authorize(.appUnlock, "Unlock Lava")
        guard canReadPresentation(.appUnlock), self.flow?.id == flow.id, feedbackVisit === visit, !visit.draft.retired else { throw CommandError("Read access changed.") }
        let reports = model.reports
        if action == "feedback.enter" {
            guard visit.draft.phase == .editing, !reports.bugReportSendState.isSending else { return NSNull() }
            visit.sampleRevision += 1; let sampling = visit.sampleRevision; let authorization = security.viewAuthenticationRevision
            await model.sampleReports(force: true)
            guard self.flow?.id == flow.id, feedbackVisit === visit, visit.sampleRevision == sampling,
                  canReadPresentation(.appUnlock), security.viewAuthenticationRevision == authorization,
                  visit.draft.phase == .editing, !reports.bugReportSendState.isSending else { throw CommandError("Read access changed.") }
            reports.prepareBugReport(context: visit.draft.context)
            visit.error = ""
            return NSNull()
        }
        if action == "feedback.preview" {
            let authorization = security.viewAuthenticationRevision
            let sections = reports.bugReportDraft?.previewSections.filter { $0.id != "context" }.map {
                ["id": $0.id, "title": $0.title, "purpose": $0.purpose,
                 "items": $0.items.map { ["id": $0.id, "label": $0.label, "value": $0.value] }] as [String: Any]
            } ?? []
            return AuthorizedPresentationResult(value: sections) { [self] in
                guard canReadPresentation(.appUnlock), security.viewAuthenticationRevision == authorization,
                      self.flow?.id == flow.id, feedbackVisit === visit else { throw CommandError("Read access changed.") }
            }
        }
        if action == "feedback.copy" {
            guard visit.draft.phase == .sent, !visit.receipt.isEmpty else { return false }
            UIPasteboard.general.string = visit.receipt; ProtectionHapticFeedback.play(.selectionConfirmed)
            visit.copied = UIPasteboard.general.string == visit.receipt
            return visit.copied
        }
        if action == "feedback.submit" {
            guard !reports.bugReportSendState.isSending, reports.bugReportDraft != nil,
                  let raw = input["review"] as? String, let review = UInt64(raw),
                  let reviewed = visit.draft.beginSubmission(review: review) else { throw CommandError("Review your feedback before submitting.") }
            foregroundDraftIsDirty = true; feedbackDraftIsDirty = true; visit.copied = false; visit.error = ""; publish()
            let feedbackID = LavaFeedbackCoordinator.shared.begin("feedback.send")
            let authorization = security.viewAuthenticationRevision
            await model.sampleReports(force: true)
            // Forced external navigation may retire preparation. Ordinary Cancel
            // is refused throughout this window and cannot retract an in-flight POST.
            guard feedbackVisit === visit, self.flow?.id == flow.id, canReadPresentation(.appUnlock),
                  security.viewAuthenticationRevision == authorization, visit.draft.beginSending() else {
                visit.draft.complete(sent: false)
                LavaFeedbackCoordinator.shared.finish("feedback.send", feedbackID, .failed, cancelled: true)
                if feedbackVisit === visit { feedbackDraftIsDirty = visit.draft.dirty; foregroundDraftIsDirty = visit.draft.dirty }
                throw CommandError("Read access changed.")
            }
            reports.prepareBugReport(context: reviewed); publish()
            await reports.sendBugReport(context: reviewed)
            let sent: Bool
            switch reports.bugReportSendState {
            case .sent(let id): sent = true; visit.receipt = id
            case .failed(let message): sent = false; visit.error = message
            default: sent = false
            }
            visit.draft.complete(sent: sent)
            LavaFeedbackCoordinator.shared.finish("feedback.send", feedbackID, sent ? .succeeded : .failed)
            if feedbackVisit === visit, self.flow?.id == flow.id {
                feedbackDraftIsDirty = visit.draft.dirty; foregroundDraftIsDirty = visit.draft.dirty
            }
            return sent
        }
        guard visit.draft.phase == .editing, !reports.bugReportSendState.isSending else { throw CommandError("Feedback is being submitted.") }
        switch action {
        case "feedback.topic":
            guard let raw = input["topic"] as? String, let topic = BugReportIssueType(rawValue: raw), visit.draft.selectTopic(topic) else { throw CommandError("Choose a topic") }
        case "feedback.change":
            guard let raw = input["field"] as? String, let field = FeedbackDraftSession.Field(rawValue: raw),
                  let value = input["value"] as? String, visit.draft.change(field, to: value) else { throw CommandError("Invalid app command.") }
        case "feedback.diagnostics":
            guard let value = input["value"] as? Bool, visit.draft.setDiagnostics(value) else { throw CommandError("Invalid app command.") }
        case "feedback.step":
            let accepted = input["next"] as? Bool == true ? visit.draft.advance() : visit.draft.navigate(to: input["step"] as? Int ?? -1)
            guard accepted else { throw CommandError("Complete this step before continuing.") }
        default: throw CommandError("Invalid app command.")
        }
        visit.error = ""; reports.resetBugReportSendState(); reports.refreshBugReportDraftContext(context: visit.draft.context)
        feedbackDraftIsDirty = visit.draft.dirty; foregroundDraftIsDirty = visit.draft.dirty
        return feedbackProjection(flow)
    }
}
