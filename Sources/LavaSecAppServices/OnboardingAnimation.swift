import Foundation
import LavaSecKit

/// Render values for one instant of the onboarding feature reveal.
public struct OnboardingFeatureTransitionState: Equatable, Sendable {
    /// Top spacing applied before the hero panel.
    public let heroTopSpacer: Double
    /// Rendered hero-panel height.
    public let heroHeight: Double
    /// Vertical translation applied to the hero panel.
    public let heroPanelOffsetY: Double
    /// Opacity of the introductory description.
    public let descriptionOpacity: Double
    /// Opacity of the feature rows.
    public let featureRowsOpacity: Double
    /// Vertical translation applied to the feature rows.
    public let featureRowsOffsetY: Double
    /// Top offset used to place the feature rows.
    public let featureRowsTopOffset: Double
    /// Whether feature rows participate in layout at this instant.
    public let featureRowsOccupyLayout: Bool
}

/// Timing and interpolation policy for the onboarding feature reveal.
public enum OnboardingFeatureTransitionPlan {
    /// Duration, in seconds, of the hero movement and description fade.
    public static let heroMoveDuration = 0.58
    /// Duration, in seconds, of the feature-row fade after hero movement.
    public static let featureFadeDuration = 0.34
    /// Complete transition duration, in seconds.
    public static let totalDuration = heroMoveDuration + featureFadeDuration

    package static let initialHeroTopSpacer = 36.0
    package static let finalHeroTopSpacer = 36.0
    package static let initialHeroHeight = 280.0
    package static let finalHeroHeight = 280.0
    package static let initialHeroPanelOffsetY = 0.0
    package static let finalHeroPanelOffsetY = -70.0
    package static let initialFeatureRowsOffsetY = 12.0
    package static let finalFeatureRowsOffsetY = 0.0
    package static let featureRowsTopOffset = 250.0

    /// Returns the clamped transition state for elapsed seconds.
    public static func state(at elapsed: Double) -> OnboardingFeatureTransitionState {
        let clampedElapsed = clamp(elapsed, lowerBound: 0, upperBound: totalDuration)
        let heroProgress = clampedElapsed / heroMoveDuration
        let clampedHeroProgress = clamp(heroProgress, lowerBound: 0, upperBound: 1)
        let featureProgress = (clampedElapsed - heroMoveDuration) / featureFadeDuration
        let clampedFeatureProgress = clamp(featureProgress, lowerBound: 0, upperBound: 1)

        return OnboardingFeatureTransitionState(
            heroTopSpacer: interpolate(
                from: initialHeroTopSpacer,
                to: finalHeroTopSpacer,
                progress: clampedHeroProgress
            ),
            heroHeight: interpolate(
                from: initialHeroHeight,
                to: finalHeroHeight,
                progress: clampedHeroProgress
            ),
            heroPanelOffsetY: interpolate(
                from: initialHeroPanelOffsetY,
                to: finalHeroPanelOffsetY,
                progress: clampedHeroProgress
            ),
            descriptionOpacity: 1 - clampedHeroProgress,
            featureRowsOpacity: clampedFeatureProgress,
            featureRowsOffsetY: interpolate(
                from: initialFeatureRowsOffsetY,
                to: finalFeatureRowsOffsetY,
                progress: clampedFeatureProgress
            ),
            featureRowsTopOffset: featureRowsTopOffset,
            featureRowsOccupyLayout: clampedElapsed >= heroMoveDuration
        )
    }

    private static func interpolate(from start: Double, to end: Double, progress: Double) -> Double {
        start + (end - start) * progress
    }

    private static func clamp(_ value: Double, lowerBound: Double, upperBound: Double) -> Double {
        min(max(value, lowerBound), upperBound)
    }
}

/// Repeating timeline that maps elapsed seconds to a full-circle lava-wave phase.
public enum OnboardingLavaWaveTimeline {
    /// Duration, in seconds, of one complete wave cycle.
    public static let duration = 4.8

    /// Returns a phase in the half-open range from zero to two pi for any finite elapsed time.
    public static func phase(at elapsed: Double) -> Double {
        guard duration > 0 else {
            return 0
        }

        let progress = elapsed.truncatingRemainder(dividingBy: duration) / duration
        let normalizedProgress = progress < 0 ? progress + 1 : progress
        return normalizedProgress * .pi * 2
    }
}
