import Foundation
import LavaSecKit

public enum GuardianMascotState: Equatable, Sendable {
    case sleeping
    case waking
    case awake
    case paused
    case retrying
    case concerned
    case grateful

    public var allowedNextStates: [GuardianMascotState] {
        switch self {
        case .sleeping:
            [.waking]
        case .waking:
            [.awake, .retrying, .concerned, .sleeping]
        case .awake:
            [.sleeping, .paused, .retrying, .concerned, .grateful]
        case .paused:
            [.awake, .sleeping]
        case .retrying:
            [.awake, .concerned, .sleeping]
        case .concerned:
            [.awake, .retrying, .sleeping]
        case .grateful:
            [.awake]
        }
    }
}

public struct GuardianMascotFrame: Equatable, Sendable {
    public let shieldWakeAmount: Double
    public let shieldScale: Double
    public let glowAmount: Double
    public let sleepyEyeAmount: Double
    public let leftEyeOpenAmount: Double
    public let rightEyeOpenAmount: Double
    public let winkAmount: Double
    public let happyEyeAmount: Double
    public let concernAmount: Double
    public let pauseAmount: Double
    public let gratitudeAmount: Double
    public let mouthCurve: Double

    public init(
        shieldWakeAmount: Double,
        shieldScale: Double = 1,
        glowAmount: Double,
        sleepyEyeAmount: Double,
        leftEyeOpenAmount: Double,
        rightEyeOpenAmount: Double,
        winkAmount: Double = 0,
        happyEyeAmount: Double = 0,
        concernAmount: Double = 0,
        pauseAmount: Double = 0,
        gratitudeAmount: Double = 0,
        mouthCurve: Double
    ) {
        self.shieldWakeAmount = shieldWakeAmount
        self.shieldScale = shieldScale
        self.glowAmount = glowAmount
        self.sleepyEyeAmount = sleepyEyeAmount
        self.leftEyeOpenAmount = leftEyeOpenAmount
        self.rightEyeOpenAmount = rightEyeOpenAmount
        self.winkAmount = winkAmount
        self.happyEyeAmount = happyEyeAmount
        self.concernAmount = concernAmount
        self.pauseAmount = pauseAmount
        self.gratitudeAmount = gratitudeAmount
        self.mouthCurve = mouthCurve
    }

    static func interpolated(
        from start: GuardianMascotFrame,
        to end: GuardianMascotFrame,
        progress: Double
    ) -> GuardianMascotFrame {
        let easedProgress = smoothstep(clamp(progress))

        return GuardianMascotFrame(
            shieldWakeAmount: interpolate(start.shieldWakeAmount, end.shieldWakeAmount, easedProgress),
            shieldScale: interpolate(start.shieldScale, end.shieldScale, easedProgress),
            glowAmount: interpolate(start.glowAmount, end.glowAmount, easedProgress),
            sleepyEyeAmount: interpolate(start.sleepyEyeAmount, end.sleepyEyeAmount, easedProgress),
            leftEyeOpenAmount: interpolate(start.leftEyeOpenAmount, end.leftEyeOpenAmount, easedProgress),
            rightEyeOpenAmount: interpolate(start.rightEyeOpenAmount, end.rightEyeOpenAmount, easedProgress),
            winkAmount: interpolate(start.winkAmount, end.winkAmount, easedProgress),
            happyEyeAmount: interpolate(start.happyEyeAmount, end.happyEyeAmount, easedProgress),
            concernAmount: interpolate(start.concernAmount, end.concernAmount, easedProgress),
            pauseAmount: interpolate(start.pauseAmount, end.pauseAmount, easedProgress),
            gratitudeAmount: interpolate(start.gratitudeAmount, end.gratitudeAmount, easedProgress),
            mouthCurve: interpolate(start.mouthCurve, end.mouthCurve, easedProgress)
        )
    }
}

public struct GuardianMascotAnimationPlan: Equatable, Sendable {
    public static let sleepWakeDuration = 0.82
    public static let blinkDelayDuration = 0.5
    public static let blinkDuration = 0.46
    public static let wakeDuration = sleepWakeDuration + blinkDelayDuration + blinkDuration
    public static let sleepDuration = sleepWakeDuration
    public static let stateChangeDuration = 0.44
    public static let settleDuration = 0.22
    private static let awakeShieldWakeAmount = 1.0
    private static let awakeGlowAmount = 0.74
    private static let awakeMouthCurve = 1.0

    public let startState: GuardianMascotState
    public let endState: GuardianMascotState
    public let duration: Double

    private let style: Style

    private enum Style: Equatable, Sendable {
        case interpolate
        case hold(GuardianMascotState)
        case blink(GuardianMascotState)
        case sequence([GuardianMascotAnimationPlan])
    }

    private init(
        startState: GuardianMascotState,
        endState: GuardianMascotState,
        duration: Double,
        style: Style
    ) {
        self.startState = startState
        self.endState = endState
        self.duration = duration
        self.style = style
    }

    public static func transition(
        from startState: GuardianMascotState,
        to endState: GuardianMascotState,
        duration overrideDuration: Double? = nil
    ) -> GuardianMascotAnimationPlan {
        let touchesSleeping = (startState == .sleeping && (endState == .waking || endState == .awake))
            || (endState == .sleeping && startState != .sleeping)
        let defaultDuration: Double

        if touchesSleeping {
            defaultDuration = sleepWakeDuration
        } else if startState == .waking && endState == .awake {
            defaultDuration = settleDuration
        } else {
            defaultDuration = stateChangeDuration
        }

        return GuardianMascotAnimationPlan(
            startState: startState,
            endState: endState,
            duration: overrideDuration ?? defaultDuration,
            style: .interpolate
        )
    }

    public static func blink(
        on state: GuardianMascotState,
        duration overrideDuration: Double? = nil
    ) -> GuardianMascotAnimationPlan {
        GuardianMascotAnimationPlan(
            startState: state,
            endState: state,
            duration: overrideDuration ?? blinkDuration,
            style: .blink(state)
        )
    }

    public static func hold(
        on state: GuardianMascotState,
        duration overrideDuration: Double? = nil
    ) -> GuardianMascotAnimationPlan {
        GuardianMascotAnimationPlan(
            startState: state,
            endState: state,
            duration: overrideDuration ?? blinkDelayDuration,
            style: .hold(state)
        )
    }

    public static func sequence(
        from startState: GuardianMascotState,
        to endState: GuardianMascotState
    ) -> [GuardianMascotAnimationPlan] {
        let transitionPlan = transition(from: startState, to: endState)

        guard startState == .sleeping && (endState == .waking || endState == .awake) else {
            return [transitionPlan]
        }

        return [transitionPlan, hold(on: .awake), blink(on: .awake)]
    }

    public static func animation(
        from startState: GuardianMascotState,
        to endState: GuardianMascotState,
        duration overrideDuration: Double? = nil
    ) -> GuardianMascotAnimationPlan {
        let plans = scaledPlans(
            sequence(from: startState, to: endState),
            duration: overrideDuration
        )

        guard plans.count > 1 else {
            return plans[0]
        }

        return GuardianMascotAnimationPlan(
            startState: plans[0].startState,
            endState: plans[plans.count - 1].endState,
            duration: plans.reduce(0) { $0 + $1.duration },
            style: .sequence(plans)
        )
    }

    public static func stableFrame(for state: GuardianMascotState) -> GuardianMascotFrame {
        switch state {
        case .sleeping:
            GuardianMascotFrame(
                shieldWakeAmount: 0,
                glowAmount: 0,
                sleepyEyeAmount: 1,
                leftEyeOpenAmount: 0,
                rightEyeOpenAmount: 0,
                mouthCurve: awakeMouthCurve
            )
        case .waking, .awake:
            GuardianMascotFrame(
                shieldWakeAmount: awakeShieldWakeAmount,
                glowAmount: awakeGlowAmount,
                sleepyEyeAmount: 0,
                leftEyeOpenAmount: 1,
                rightEyeOpenAmount: 1,
                mouthCurve: awakeMouthCurve
            )
        case .paused:
            GuardianMascotFrame(
                shieldWakeAmount: awakeShieldWakeAmount,
                glowAmount: awakeGlowAmount,
                sleepyEyeAmount: 1,
                leftEyeOpenAmount: 0,
                rightEyeOpenAmount: 0,
                pauseAmount: 1,
                mouthCurve: awakeMouthCurve
            )
        case .retrying:
            // "Working on it" — relaxed lids (not wide/stunned, not sleepy), level eyes,
            // flat mouth. No concern tilt: this is the unworried, self-healing counterpart
            // to .concerned. Motion is carried by the status badge, not the face.
            GuardianMascotFrame(
                shieldWakeAmount: awakeShieldWakeAmount,
                glowAmount: awakeGlowAmount,
                sleepyEyeAmount: 0,
                leftEyeOpenAmount: 0.80,
                rightEyeOpenAmount: 0.80,
                mouthCurve: 0
            )
        case .concerned:
            GuardianMascotFrame(
                shieldWakeAmount: awakeShieldWakeAmount,
                glowAmount: awakeGlowAmount,
                sleepyEyeAmount: 0,
                leftEyeOpenAmount: 0.78,
                rightEyeOpenAmount: 0.78,
                concernAmount: 1,
                mouthCurve: -0.22
            )
        case .grateful:
            GuardianMascotFrame(
                shieldWakeAmount: 1,
                glowAmount: 0.88,
                sleepyEyeAmount: 0,
                leftEyeOpenAmount: 0,
                rightEyeOpenAmount: 0,
                happyEyeAmount: 1,
                gratitudeAmount: 1,
                mouthCurve: 1.18
            )
        }
    }

    public func frame(at elapsed: Double) -> GuardianMascotFrame {
        switch style {
        case .interpolate:
            if startState == .awake && endState == .grateful {
                return Self.awakeToGratefulFrame(at: duration <= 0 ? 1 : elapsed / duration)
            }
            if startState == .grateful && endState == .awake {
                return Self.gratefulToAwakeFrame(at: duration <= 0 ? 1 : elapsed / duration)
            }

            return GuardianMascotFrame.interpolated(
                from: Self.stableFrame(for: startState),
                to: Self.stableFrame(for: endState),
                progress: duration <= 0 ? 1 : elapsed / duration
            )
        case .hold(let state):
            return Self.stableFrame(for: state)
        case .blink(let state):
            return Self.blinkFrame(on: state, at: duration <= 0 ? 1 : elapsed / duration)
        case .sequence(let plans):
            return Self.sequenceFrame(plans, at: elapsed)
        }
    }

    private static func scaledPlans(
        _ plans: [GuardianMascotAnimationPlan],
        duration overrideDuration: Double?
    ) -> [GuardianMascotAnimationPlan] {
        guard let overrideDuration else {
            return plans
        }

        let currentDuration = plans.reduce(0) { $0 + $1.duration }
        guard currentDuration > 0 else {
            return plans
        }

        let scale = max(0, overrideDuration) / currentDuration
        return plans.map { plan in
            GuardianMascotAnimationPlan(
                startState: plan.startState,
                endState: plan.endState,
                duration: plan.duration * scale,
                style: plan.style
            )
        }
    }

    private static func sequenceFrame(
        _ plans: [GuardianMascotAnimationPlan],
        at elapsed: Double
    ) -> GuardianMascotFrame {
        guard let firstPlan = plans.first else {
            return stableFrame(for: .awake)
        }

        var remainingElapsed = max(0, elapsed)
        for plan in plans {
            if remainingElapsed <= plan.duration {
                return plan.frame(at: remainingElapsed)
            }
            remainingElapsed -= plan.duration
        }

        return plans.last?.frame(at: plans.last?.duration ?? 0)
            ?? firstPlan.frame(at: firstPlan.duration)
    }

    private static func awakeToGratefulFrame(at rawProgress: Double) -> GuardianMascotFrame {
        let progress = smoothstep(clamp(rawProgress))
        let lengthenProgress = smoothstep(clamp(progress / 0.44))
        let closeProgress = smoothstep(clamp((progress - 0.34) / 0.66))
        let awake = stableFrame(for: .awake)
        let grateful = stableFrame(for: .grateful)

        return GuardianMascotFrame(
            shieldWakeAmount: interpolate(awake.shieldWakeAmount, grateful.shieldWakeAmount, progress),
            shieldScale: interpolate(awake.shieldScale, grateful.shieldScale, progress),
            glowAmount: interpolate(awake.glowAmount, grateful.glowAmount, progress),
            sleepyEyeAmount: 0,
            leftEyeOpenAmount: interpolate(awake.leftEyeOpenAmount, grateful.leftEyeOpenAmount, closeProgress),
            rightEyeOpenAmount: interpolate(awake.rightEyeOpenAmount, grateful.rightEyeOpenAmount, closeProgress),
            happyEyeAmount: interpolate(awake.happyEyeAmount, grateful.happyEyeAmount, lengthenProgress),
            gratitudeAmount: interpolate(awake.gratitudeAmount, grateful.gratitudeAmount, progress),
            mouthCurve: interpolate(awake.mouthCurve, grateful.mouthCurve, progress)
        )
    }

    private static func gratefulToAwakeFrame(at rawProgress: Double) -> GuardianMascotFrame {
        let progress = smoothstep(clamp(rawProgress))
        let reverseProgress = 1 - progress
        let lengthenProgress = smoothstep(clamp(reverseProgress / 0.44))
        let closeProgress = smoothstep(clamp((reverseProgress - 0.34) / 0.66))
        let awake = stableFrame(for: .awake)
        let grateful = stableFrame(for: .grateful)

        return GuardianMascotFrame(
            shieldWakeAmount: interpolate(grateful.shieldWakeAmount, awake.shieldWakeAmount, progress),
            shieldScale: interpolate(grateful.shieldScale, awake.shieldScale, progress),
            glowAmount: interpolate(grateful.glowAmount, awake.glowAmount, progress),
            sleepyEyeAmount: 0,
            leftEyeOpenAmount: interpolate(awake.leftEyeOpenAmount, grateful.leftEyeOpenAmount, closeProgress),
            rightEyeOpenAmount: interpolate(awake.rightEyeOpenAmount, grateful.rightEyeOpenAmount, closeProgress),
            happyEyeAmount: interpolate(awake.happyEyeAmount, grateful.happyEyeAmount, lengthenProgress),
            gratitudeAmount: interpolate(grateful.gratitudeAmount, awake.gratitudeAmount, progress),
            mouthCurve: interpolate(grateful.mouthCurve, awake.mouthCurve, progress)
        )
    }

    private static func blinkFrame(on state: GuardianMascotState, at rawProgress: Double) -> GuardianMascotFrame {
        let progress = clamp(rawProgress)
        let baseFrame = stableFrame(for: state)
        let blinkAmount = triangle(progress, start: 0.12, peak: 0.45, end: 0.78)
        let eyeOpenAmount = 1 - blinkAmount

        return GuardianMascotFrame(
            shieldWakeAmount: baseFrame.shieldWakeAmount,
            shieldScale: baseFrame.shieldScale,
            glowAmount: baseFrame.glowAmount,
            sleepyEyeAmount: baseFrame.sleepyEyeAmount,
            leftEyeOpenAmount: baseFrame.leftEyeOpenAmount * eyeOpenAmount,
            rightEyeOpenAmount: baseFrame.rightEyeOpenAmount * eyeOpenAmount,
            winkAmount: 0,
            happyEyeAmount: baseFrame.happyEyeAmount,
            concernAmount: baseFrame.concernAmount,
            pauseAmount: baseFrame.pauseAmount,
            gratitudeAmount: baseFrame.gratitudeAmount,
            mouthCurve: baseFrame.mouthCurve
        )
    }
}

private func interpolate(_ start: Double, _ end: Double, _ progress: Double) -> Double {
    start + (end - start) * progress
}

private func triangle(_ value: Double, start: Double, peak: Double, end: Double) -> Double {
    guard peak > start, end > peak else {
        return 0
    }

    if value < start || value > end {
        return 0
    }

    if value <= peak {
        return clamp((value - start) / (peak - start))
    }

    return clamp((end - value) / (end - peak))
}

private func smoothstep(_ value: Double) -> Double {
    let clampedValue = clamp(value)
    return clampedValue * clampedValue * (3 - 2 * clampedValue)
}

private func clamp(_ value: Double) -> Double {
    min(max(value, 0), 1)
}
