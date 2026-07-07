import Foundation
import LavaSecKit

public struct OnboardingFeatureTransitionState: Equatable, Sendable {
    public let heroTopSpacer: Double
    public let heroHeight: Double
    public let heroPanelOffsetY: Double
    public let descriptionOpacity: Double
    public let featureRowsOpacity: Double
    public let featureRowsOffsetY: Double
    public let featureRowsTopOffset: Double
    public let featureRowsOccupyLayout: Bool
}

public enum OnboardingFeatureTransitionPlan {
    public static let heroMoveDuration = 0.58
    public static let featureFadeDuration = 0.34
    public static let totalDuration = heroMoveDuration + featureFadeDuration

    public static let initialHeroTopSpacer = 36.0
    public static let finalHeroTopSpacer = 36.0
    public static let initialHeroHeight = 280.0
    public static let finalHeroHeight = 280.0
    public static let initialHeroPanelOffsetY = 0.0
    public static let finalHeroPanelOffsetY = -70.0
    public static let initialFeatureRowsOffsetY = 12.0
    public static let finalFeatureRowsOffsetY = 0.0
    public static let featureRowsTopOffset = 250.0

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

public enum OnboardingLavaWaveTimeline {
    public static let duration = 4.8

    public static func phase(at elapsed: Double) -> Double {
        guard duration > 0 else {
            return 0
        }

        let progress = elapsed.truncatingRemainder(dividingBy: duration) / duration
        let normalizedProgress = progress < 0 ? progress + 1 : progress
        return normalizedProgress * .pi * 2
    }
}
