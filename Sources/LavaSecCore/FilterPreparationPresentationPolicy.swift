import Foundation

public enum FilterPreparationPhase: String, Codable, Sendable {
    case downloading
    case compiling
    case saving
}

public struct FilterPreparationPresentationPolicy: Equatable, Sendable {
    public let minimumPhaseDuration: TimeInterval

    public init(minimumPhaseDuration: TimeInterval = 0.85) {
        self.minimumPhaseDuration = minimumPhaseDuration
    }

    public func holdDurationBeforePresenting(
        currentPhase: FilterPreparationPhase?,
        phaseStartedAt: Date?,
        nextPhase: FilterPreparationPhase,
        now: Date = Date()
    ) -> TimeInterval {
        guard let currentPhase,
              currentPhase != nextPhase,
              let phaseStartedAt
        else {
            return 0
        }

        let elapsed = now.timeIntervalSince(phaseStartedAt)
        return max(0, minimumPhaseDuration - elapsed)
    }
}
