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

    /// Number of equal steps the bar is divided into: the three preparation phases plus
    /// the terminal **Success** step. Each visible step owns one quarter, so the final
    /// Success fill is a consistent quarter rather than a jump.
    public static let stepCount = 4.0

    /// Re-maps the preparation service's uneven overall checkpoints (downloading
    /// ~0.05–0.2, compiling ~0.42–0.72, saving ~0.86) so each visible step fills an
    /// equal quarter of the bar: download 0–1/4, build 1/4–2/4, save 2/4–3/4, and the
    /// terminal Success step 3/4–1 (set by the caller when it finishes the apply).
    /// `rawProgress` only positions the fill within the phase's nominal sub-range — the
    /// magnitudes need to be monotonic, not exact — and is clamped to that quarter.
    public static func equalStepsProgress(phase: FilterPreparationPhase, rawProgress: Double) -> Double {
        let (index, rawStart, rawEnd): (Double, Double, Double)
        switch phase {
        case .downloading: (index, rawStart, rawEnd) = (0, 0.0, 0.42)
        case .compiling:   (index, rawStart, rawEnd) = (1, 0.42, 0.86)
        case .saving:      (index, rawStart, rawEnd) = (2, 0.86, 1.0)
        }

        let span = max(rawEnd - rawStart, 0.0001)
        let intra = min(max((rawProgress - rawStart) / span, 0), 1)
        return (index + intra) / stepCount
    }
}
