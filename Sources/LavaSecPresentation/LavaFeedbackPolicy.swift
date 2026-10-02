import Foundation

/// Platform-independent meanings; hardware and the user's preference belong to the renderer.
public enum LavaFeedbackSemantic: String, Sendable { case selected, engaged, succeeded, attentionRequired, failed, acknowledged, inspectionEmpty }
/// Restored and automatic work never produces interaction feedback.
public enum LavaFeedbackOrigin: Sendable { case directUser, automatic, restoredUI }

/// Bounded operation consumption and changed-value selection filtering. The caller supplies time.
public struct LavaFeedbackPolicy: Sendable {
    private var operations: [String: UUID] = [:]
    private var selections: [String: (value: String, time: TimeInterval)] = [:]
    private struct InteractionIdentity: Hashable, Sendable {
        let control: String
        let value: String
        let semantic: LavaFeedbackSemantic
    }
    private var consumedInteractions: [InteractionIdentity] = []
    public init() {}
    /// Starting a newer operation in the same lane invalidates its predecessor.
    public mutating func begin(_ lane: String) -> UUID {
        if operations.count >= 128 { operations.removeAll(keepingCapacity: true) }
        let id = UUID(); operations[lane] = id; return id
    }
    /// Consumes terminal results even when inactive, preventing later wake replay.
    public mutating func finish(_ lane: String, id: UUID, semantic: LavaFeedbackSemantic,
                                active: Bool, cancelled: Bool = false, origin: LavaFeedbackOrigin = .directUser) -> LavaFeedbackSemantic? {
        guard operations[lane] == id else { return nil }
        operations.removeValue(forKey: lane)
        return active && !cancelled && origin == .directUser ? semantic : nil
    }
    /// Selection crossings remember the latest value even when rate-limited; no backlog is replayed.
    public mutating func interaction(_ semantic: LavaFeedbackSemantic, control: String, value: String?,
                                     now: TimeInterval, active: Bool, origin: LavaFeedbackOrigin = .directUser) -> LavaFeedbackSemantic? {
        // UI-owned terminal/gesture events carry an operation token, unlike selected values.
        // Consume before the foreground check so a delayed repeat cannot announce background work.
        if semantic != .selected && semantic != .inspectionEmpty, let value {
            let identity = InteractionIdentity(control: control, value: value, semantic: semantic)
            guard !consumedInteractions.contains(identity) else { return nil }
            if consumedInteractions.count >= 128 { consumedInteractions.removeFirst() }
            consumedInteractions.append(identity)
        }
        guard active, origin == .directUser else { return nil }
        if semantic == .selected || semantic == .inspectionEmpty {
            guard let value else { return nil }
            let previous = selections[control]
            guard previous?.value != value else { return nil }
            if selections.count >= 128 { selections.removeAll(keepingCapacity: true) }
            let allowed = previous.map { now - $0.time >= 0.05 } ?? true
            selections[control] = (value, allowed ? now : previous!.time)
            return allowed ? semantic : nil
        }
        return semantic
    }
}
