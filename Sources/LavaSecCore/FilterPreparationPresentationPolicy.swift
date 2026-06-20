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

    /// Re-maps the preparation service's uneven overall checkpoints (downloading
    /// ~0.05–0.2, compiling ~0.42–0.72, saving ~0.86) so the displayed bar gives each
    /// phase an equal third: download fills 0–1/3, build 1/3–2/3, save 2/3–1.
    /// `rawProgress` only positions the fill within the phase's nominal sub-range —
    /// the magnitudes need to be monotonic, not exact — and is clamped to that third.
    public static func equalThirdsProgress(phase: FilterPreparationPhase, rawProgress: Double) -> Double {
        let (index, rawStart, rawEnd): (Double, Double, Double)
        switch phase {
        case .downloading: (index, rawStart, rawEnd) = (0, 0.0, 0.42)
        case .compiling:   (index, rawStart, rawEnd) = (1, 0.42, 0.86)
        case .saving:      (index, rawStart, rawEnd) = (2, 0.86, 1.0)
        }

        let span = max(rawEnd - rawStart, 0.0001)
        let intra = min(max((rawProgress - rawStart) / span, 0), 1)
        return (index + intra) / 3
    }
}
