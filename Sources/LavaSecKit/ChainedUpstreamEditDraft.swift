import Foundation

/// An unsaved page edit. Existing rows retain metadata and their original index only;
/// new credentials stay in native memory until the page explicitly commits.
public struct ChainedUpstreamEditDraft: Sendable {
    /// A metadata row and, only for newly entered content, its replacement credentials.
    public struct Row: Sendable {
        /// Index in the original saved chain, never in a partially edited chain.
        public let originalIndex: Int?
        /// Public configuration metadata used to validate the complete draft.
        public var configuration: ChainedUpstreamConfiguration
        /// Newly submitted material; saved keys are never loaded into the draft.
        public let replacement: ChainedUpstreamRotation?
    }
    /// Fences late sheet results and unrelated page visits.
    public let id: String
    /// Orders metadata updates from native sheets and page actions.
    public private(set) var revision = 0
    /// Generation observed when editing began.
    public private(set) var generation: UInt64?
    /// Ordered draft rows.
    public private(set) var rows: [Row]
    private var originalRows: [ChainedUpstreamConfiguration]
    /// A successful profile write may still owe a failed preference write.
    public private(set) var hasPendingSettings = false
    /// Explicit recovery of unreadable storage, committed only by page Save.
    public private(set) var resetsStorage = false

    /// Creates a draft from non-secret metadata without writing or reading keys.
    public init(id: String, generation: UInt64?, configurations: [ChainedUpstreamConfiguration]) throws {
        // Each row is an independent profile; the saved exit also contains its old entry.
        let configurations = try configurations.map { try $0.withoutEntryHop() }
        self.id = id; self.generation = generation; self.originalRows = configurations
        self.rows = configurations.enumerated().map { Row(originalIndex: $0.offset, configuration: $0.element, replacement: nil) }
    }
    /// Whether page Save still has profile or preference changes to commit.
    public var hasChanges: Bool {
        hasPendingSettings || hasProfileChanges
    }
    /// Whether credential storage itself needs a new generation.
    public var hasProfileChanges: Bool {
        resetsStorage || rows.contains { $0.replacement != nil } || rows.map(\.configuration) != originalRows
            || rows.enumerated().contains { $0.element.originalIndex != $0.offset }
    }
    /// A full-tunnel entry or exit disables physical DNS fallback.
    public var containsFullTunnel: Bool { rows.contains { $0.configuration.isEnabled && $0.configuration.routingPolicy == .fullTunnel } }

    /// Stages a rename or new config, validating composition before replacing the draft.
    public mutating func save(index: Int, name: String, replacement: ChainedUpstreamRotation?) throws {
        guard index >= 0, index <= rows.count, index < 2 else { throw WireGuardChainFailure.changed }
        let old = rows.indices.contains(index) ? rows[index] : nil
        guard let configuration = replacement?.configuration ?? old?.configuration else { throw WireGuardChainFailure.missingSecret }
        let row = Row(originalIndex: old?.originalIndex, configuration: try configuration.withoutEntryHop().named(name).enabled(old?.configuration.isEnabled ?? true),
                      replacement: replacement ?? old?.replacement)
        var updated = rows
        if index == rows.count { updated.append(row) } else { updated[index] = row }
        try Self.validate(updated)
        rows = updated; revision += 1
    }
    /// Builds a row-toggle transaction. Only its explicit commit changes the runtime.
    public mutating func setEnabled(_ enabled: Bool, index: Int) throws {
        guard rows.indices.contains(index) else { throw WireGuardChainFailure.changed }
        var updated = rows
        updated[index].configuration = try updated[index].configuration.enabled(enabled)
        try Self.validate(updated)
        rows = updated; revision += 1
    }
    /// Removes a pending row without changing the saved chain or running VPN.
    public mutating func remove(index: Int) throws {
        guard rows.indices.contains(index) else { throw WireGuardChainFailure.changed }
        rows.remove(at: index); revision += 1
    }
    /// Exchanges whole rows, retaining each saved-key reference or new replacement.
    /// Validate before changing the draft so a refused order cannot partially apply.
    public mutating func swapOrder() throws {
        guard rows.count == 2 else { throw WireGuardChainFailure.changed }
        let updated = Array(rows.reversed())
        try Self.validate(updated)
        rows = updated; revision += 1
    }
    /// Stages the explicit delete-all recovery operation.
    public mutating func reset() { rows = []; resetsStorage = true; revision += 1 }
    /// Rebase after a profile write succeeds but the separate settings write fails.
    /// This keeps retries generation-fenced without retaining unnecessary new credentials.
    public mutating func didCommitProfiles(generation: UInt64?, awaitingSettings: Bool = false) {
        hasPendingSettings = awaitingSettings
        self.generation = generation; revision += 1; originalRows = rows.map(\.configuration); resetsStorage = false
        rows = originalRows.enumerated().map { Row(originalIndex: $0.offset, configuration: $0.element, replacement: nil) }
    }
    /// Completes the preference half after profiles have already committed.
    public mutating func didCommitSettings() { hasPendingSettings = false }
    private static func validate(_ rows: [Row]) throws {
        if rows.count == 2 { _ = try rows[1].configuration.withEntryHop(rows[0].configuration) }
    }
}
