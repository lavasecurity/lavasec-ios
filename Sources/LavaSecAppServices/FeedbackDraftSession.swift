import Foundation

/// Ephemeral feedback visit shared by presentation adapters. Submission consumes
/// the reviewed context once; navigation cannot reopen the preparation/send gate.
public struct FeedbackDraftSession: Sendable {
    public enum Phase: String, Sendable { case editing, preparing, sending, sent }
    public enum Field: String, Sendable { case site, details, email }
    public private(set) var topic: BugReportIssueType?
    public private(set) var site = ""
    public private(set) var details = ""
    public private(set) var email = ""
    public private(set) var diagnostics = false
    public private(set) var step = 0
    public private(set) var furthest = 0
    public private(set) var revision: UInt64 = 0
    public private(set) var reviewRevision: UInt64?
    public private(set) var phase = Phase.editing
    public private(set) var retired = false
    private var presentationEdited = false
    public init() {}
    public var context: BugReportContext {
        BugReportContext(issueType: topic ?? .other, affectedSite: topic == .websiteAccess ? site : "",
            details: details, contactEmail: email, includeDiagnostics: diagnostics)
    }
    public var validContext: Bool {
        topic != nil && !context.normalizedDetails.isEmpty && (topic != .websiteAccess || !context.normalizedAffectedSite.isEmpty)
    }
    public var canDismiss: Bool { phase != .preparing && phase != .sending }
    public var dirty: Bool {
        phase != .sent && (presentationEdited || topic != nil || !site.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || diagnostics)
    }
    /// Blocks interactive dismissal while presentation edits await native input
    /// acknowledgement. This changes no report context or reviewed revision.
    /// Only this editing visit can acquire the guard; retirement and sending
    /// cannot use it to authorize or reopen a draft.
    @discardableResult public mutating func markPresentationEdited() -> Bool {
        guard phase == .editing, !retired else { return false }
        presentationEdited = true; return true
    }
    private mutating func edited() { revision &+= 1; reviewRevision = nil }
    @discardableResult public mutating func selectTopic(_ value: BugReportIssueType) -> Bool {
        guard phase == .editing, !retired else { return false }
        topic = value; if value != .websiteAccess { site = "" }; edited(); return true
    }
    @discardableResult public mutating func change(_ field: Field, to value: String) -> Bool {
        guard phase == .editing, !retired else { return false }
        let previous = context
        switch field {
        case .site: site = String(value.prefix(BugReportInputLimits.affectedSite))
        case .details: details = String(value.prefix(BugReportInputLimits.details))
        case .email: email = String(value.prefix(BugReportInputLimits.contactEmail))
        }
        if context != previous { edited() }; return true
    }
    @discardableResult public mutating func setDiagnostics(_ value: Bool) -> Bool {
        guard phase == .editing, !retired else { return false }
        diagnostics = value; edited(); return true
    }
    @discardableResult public mutating func navigate(to destination: Int) -> Bool {
        guard phase == .editing, !retired, (0...furthest).contains(destination) else { return false }
        step = destination; if destination == 2 { reviewRevision = revision }; return true
    }
    @discardableResult public mutating func advance() -> Bool {
        guard phase == .editing, !retired, step < 2, step == 0 ? topic != nil : validContext else { return false }
        step += 1; furthest = max(step, furthest); if step == 2 { reviewRevision = revision }; return true
    }
    public mutating func beginSubmission(review: UInt64) -> BugReportContext? {
        guard !retired, phase == .editing, step == 2, validContext,
              reviewRevision == review, revision == review else { return nil }
        phase = .preparing; return context
    }
    @discardableResult public mutating func beginSending() -> Bool {
        guard !retired, phase == .preparing else { return false }
        phase = .sending; return true
    }
    public mutating func complete(sent: Bool) { phase = sent ? .sent : .editing }
    /// Forced external navigation can retire a preparing visit. An in-flight
    /// POST is not retracted; its completion belongs to the retired owner only.
    public mutating func retire() { retired = true }
}
