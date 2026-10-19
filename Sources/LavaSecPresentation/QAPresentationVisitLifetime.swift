/// Admission for a QA route whose authentication may outlive its React visit.
/// Closed visits cannot recreate their unpublished configuration buffer.
public struct QAPresentationVisitLifetime: Equatable, Sendable {
    /// The one admitted QA visit.
    public private(set) var currentID: String?
    private var pendingID: String?
    private var generation = 0
    private var retiredIDs = Set<String>()

    /// Creates a lifetime without an admitted visit.
    public init() {}

    /// Claims a ticket before authentication; another request supersedes it.
    public mutating func requestEntry(id: String) -> Int? {
        guard !retiredIDs.contains(id), currentID == nil || currentID == id else { return nil }
        generation &+= 1
        pendingID = id
        return generation
    }

    /// Admits only the still-current request after authentication.
    public mutating func admit(id: String, ticket: Int) -> Bool {
        guard pendingID == id, generation == ticket, !retiredIDs.contains(id),
              currentID == nil || currentID == id else { return false }
        currentID = id
        pendingID = nil
        return true
    }

    /// Retires drafts and pending entry without revoking a newer visit's ticket.
    public mutating func retire(id: String) {
        retiredIDs.insert(id)
        if currentID == id { currentID = nil }
        if pendingID == id { pendingID = nil; generation &+= 1 }
    }

    /// A new native QA flow takes the visit even if the covered page is still
    /// awaiting authentication and has not created its session yet.
    public mutating func retireSuperseded(by id: String) {
        if let currentID, currentID != id { retire(id: currentID) }
        if let pendingID, pendingID != id { retire(id: pendingID) }
    }
}
