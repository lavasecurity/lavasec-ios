/// Reuses a derived eligibility flag for an unchanged saved library. It retains
/// no filter contents, sharing code, or authorization. Drafts must bypass it.
public struct FilterShareabilityMemo: Sendable {
    private var revision: String?
    private var values: [String: Bool] = [:]

    /// Creates an empty process-local memo.
    public init() {}

    /// Computes once per filter and authoritative library revision. The caller
    /// still owns authorization and supplies a revision for every content change.
    public mutating func value(for id: String, revision: String, compute: () -> Bool) -> Bool {
        if self.revision != revision { reset(); self.revision = revision }
        if let value = values[id] { return value }
        let value = compute()
        values[id] = value
        return value
    }

    /// Discards derived flags when their native owner retires.
    public mutating func reset() { revision = nil; values.removeAll() }
}
